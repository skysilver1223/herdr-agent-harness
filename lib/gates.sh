# herdr-harness: 상태 전이와 게이트 — 계획 승인, 증빙(AC 실행), 교차 검토, 통합, Milestone 승인.
# harness.sh가 source한다. 단독 실행하지 않는다.

TRANSITIONS=" draft>ready ready>active active>submitted active>blocked active>handover_required blocked>active submitted>reviewing reviewing>changes_requested reviewing>awaiting_approval changes_requested>ready handover_required>ready awaiting_approval>completed awaiting_approval>changes_requested "

# 상태를 바꾸는 명령은 Harness가 띄운 Agent 안에서 실행할 수 없다. dispatch가 Pane에
# HARNESS_AGENT를 심고, herdr pane current --current(터미널 기준)도 대조한다.
# 같은 사용자 권한의 Agent는 이 파일도 고칠 수 있으므로 가드레일이지 보안 경계는 아니다.
require_human() {
  local pane="" m
  [[ -z "${HARNESS_AGENT:-}" ]] ||
    die "$1은(는) Harness가 띄운 Agent($HARNESS_AGENT) 안에서 실행할 수 없습니다. 상태 결정은 사람·Orchestrator가 한다."
  if command -v herdr >/dev/null 2>&1; then pane="$(jfield "$(herdr pane current --current 2>/dev/null || true)" pane_id)"; fi
  [[ -n "$pane" ]] || return 0
  for m in "$ROOT"/.harness/runtime/*.meta; do
    [[ -f "$m" ]] && ! grep -q '^closed=' "$m" || continue
    [[ "$(meta_get "$m" pane)" != "$pane" ]] ||
      die "$1은(는) Harness가 띄운 Agent Pane($pane)에서 실행할 수 없습니다."
  done
  return 0
}

# --------------------------------------------------------------------------
# 계획 승인 스냅숏 — 사용자가 승인한 Task·등급·AC 지문. 이후 AC가 바뀌면 진행을 막는다
# (우회 모드 Agent가 command를 true로 바꿔 가짜 PASS를 만드는 경로를 닫는다).
# --------------------------------------------------------------------------
plan_file() { printf '%s/.harness/decisions/%s-plan-approval.md' "$ROOT" "$1"; }

plan_row() {  # TASK → 승인 표의 그 Task 행 (없으면 빈 값)
  local m f
  m="$(yget "$(task_file "$1")" milestone_id)"
  f="$(plan_file "$m")"
  [[ -f "$f" ]] || return 0
  grep -m1 "^| $1 |" "$f" || true
}

plan_check() {  # TASK → 승인된 계획과 AC가 같은지
  local row tf
  tf="$(task_file "$1")"
  row="$(plan_row "$1")"
  [[ -n "$row" ]] || die "$1이(가) 계획 승인에 없습니다. approve-plan $(yget "$tf" milestone_id) --confirm-user-approval"
  [[ "$row" == *"| $(ac_hash "$tf") |"* ]] ||
    die "$1의 Acceptance Criteria가 계획 승인 이후 바뀌었습니다. 바뀐 계약은 사용자가 approve-plan으로 다시 승인한다."
}

plan_cell() {  # TASK 열이름 → 계획 승인 표에서 그 Task 행의 값 (열은 머리줄 이름으로 찾는다)
  local m f
  m="$(yget "$(task_file "$1")" milestone_id)"
  f="$(plan_file "$m")"
  [[ -f "$f" ]] || return 0
  awk -F'|' -v t="$1" -v c="$2" '
    /^\| Task \|/ { for (i = 2; i < NF; i++) { h = $i; gsub(/^[ \t]+|[ \t]+$/, "", h); idx[h] = i } next }
    { id = $2; gsub(/^[ \t]+|[ \t]+$/, "", id) }
    id == t && (c in idx) { v = $(idx[c]); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }
  ' "$f"
}
plan_tier()  { plan_cell "$1" "$( [[ "$2" == worker ]] && echo 'Worker 등급' || echo 'Reviewer 등급')"; }
plan_model() { plan_cell "$1" "$( [[ "$2" == worker ]] && echo 'Worker 모델' || echo 'Reviewer 모델')"; }

# --------------------------------------------------------------------------
# AC 실행 — Task 작업 공간에서(원격 모드면 원격에서) 직접 실행하고 표를 기록에 붙인다.
# 같은 명령은 한 번만 실행한다. 결과는 AC_RESULT(PASS|FAIL).
# --------------------------------------------------------------------------
run_checks() {  # TASK RECORD TITLE [CWD] — CWD가 없으면 Task 작업 공간 (재검증은 본 저장소를 준다)
  local task="$1" record="$2" title="$3" cwd limit i id cmd out rc tail cell label
  local pass=0 fail=0 manual=0 rows="" where
  local -A seen_rc=() seen_out=()
  if [[ -n "${4:-}" ]]; then cwd="$4"; else cwd="$(task_cwd "$task")"; fi
  limit="$(pnum limits ac_timeout_seconds 600)"
  where="$cwd"
  if remote_enabled; then where="원격 ($(sed -n 's/^  path:[[:space:]]*//p' "$ROOT/.harness/remote.yaml" | head -n 1))"; fi
  for i in "${!AC_ID[@]}"; do
    id="${AC_ID[$i]}"; cmd="${AC_CMD[$i]}"
    if [[ "${AC_TYPE[$i]}" == manual-review ]]; then
      manual=$((manual + 1))
      rows+="| $id | manual-review | - | MANUAL | - | Reviewer가 직접 확인 |"$'\n'
      continue
    fi
    if [[ -z "${seen_rc[$cmd]+x}" ]]; then
      info "AC 실행: $id — $cmd"
      rc=0
      if remote_enabled; then
        out="$(bash "$HARNESS_BIN" -C "$ROOT" remote run "timeout -k 10 $limit bash -c $(printf '%q' "$cmd")" 2>&1 </dev/null)" || rc=$?
      else
        # -k 없이는 TERM을 무시하는 명령이 전이를 영원히 붙잡는다.
        out="$(cd "$cwd" && timeout -k 10 "$limit" bash -c "$cmd" 2>&1 </dev/null)" || rc=$?
      fi
      seen_rc[$cmd]=$rc; seen_out[$cmd]="$out"
    fi
    rc="${seen_rc[$cmd]}"; out="${seen_out[$cmd]}"
    if (( rc == 0 )); then pass=$((pass + 1)); else fail=$((fail + 1)); fi
    tail="$(printf '%s' "$out" | tail -n 5 | tr '\n\r\t' '   ' | cut -c1-300)"
    if has_secret <<<"$out"; then tail="(Secret 의심 — 원문 생략)"; fi
    cell="${cmd//|/\\|}"; tail="${tail//|/\\|}"
    rows+="| $id | command | $rc | $( ((rc == 0)) && echo PASS || echo FAIL ) | \`$cell\` | $tail |"$'\n'
  done
  AC_RESULT=PASS
  (( fail == 0 )) || AC_RESULT=FAIL
  case "$title" in "AC 검증") label='AC 요약' ;; "통합 AC 검증") label='통합 AC 요약' ;; *) label="$title 요약" ;; esac
  {
    printf '\n## %s %s\n\n실행 위치: %s · 명령당 제한 %s초\n\n' "$title" "$(now)" "$where" "$limit"
    printf '| Criterion | 유형 | 종료 코드 | 결과 | 명령 | 출력 끝부분 |\n|---|---|---|---|---|---|\n%s\n' "$rows"
    printf -- '- %s: %s (pass %s / fail %s / manual %s / 전체 %s)\n' "$label" "$AC_RESULT" "$pass" "$fail" "$manual" "${#AC_ID[@]}"
  } >>"$record"
}

# --------------------------------------------------------------------------
# 게이트
# --------------------------------------------------------------------------
dep_done() {  # 선행 Task가 통합까지 끝났는가 (Milestone 승인 전에도 뒤 Task가 시작할 수 있게)
  local f="$ROOT/.harness/tasks/$1.yaml" st
  if [[ ! -f "$f" ]]; then archived_task "$1"; return; fi
  st="$(yget "$f" status)"
  [[ "$st" == awaiting_approval || "$st" == completed ]]
}

gate_ready() {
  spec_approved || die "SPEC이 승인되지 않았습니다. .harness/SPEC.md의 '- 상태: approved'는 사용자가 정한다."
  plan_check "$1"
}

gate_active() {
  local task="$1" tf="$2" dep other theirs mine active=0 max deps scopes_txt wt branch code
  local -a scopes=()
  git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null || die "Git 기준 commit이 없습니다 (git add -A && git commit)."
  plan_check "$task"
  deps="$(ylist "$tf" dependencies)"
  while IFS= read -r dep; do
    [[ -z "$dep" ]] || dep_done "$dep" || die "선행 Task $dep가 아직 교차 검토·통합 전입니다."
  done <<<"$deps"
  scopes_txt="$(ylist "$tf" write_scope)"
  [[ -n "$scopes_txt" ]] || die "$task의 write_scope가 비어 있습니다."
  mapfile -t scopes <<<"$scopes_txt"
  max="$(pnum limits max_parallel_workers 5)"
  # 작업 공간을 나누지 않는 모드(원격·worktree 꺼짐)는 통합 전 Task가 하나뿐이어야 검증이 섞이지 않는다.
  local shared=0
  if ! worktree_enabled; then shared=1; max=1; fi
  # 상한은 active만 센다. 범위 충돌은 아직 본 브랜치에 통합되지 않은 Task 전부와 비교한다
  # (작업 공간이 나뉘어 있어도 겹치는 범위는 통합 때 충돌한다).
  while IFS= read -r other; do
    [[ "$other" != "$task" ]] || continue
    case "$(yget "$ROOT/.harness/tasks/$other.yaml" status)" in
      active) active=$((active + 1)) ;;
      submitted|reviewing|changes_requested|blocked|handover_required) (( shared == 0 )) || active=$((active + 1)) ;;
      ready)  # 재작업 대기: 통합되지 않은 변경이 작업 공간에 남아 있다
        (( $(last_attempt "$other") > 0 )) || continue
        (( shared == 0 )) || active=$((active + 1)) ;;
      *) continue ;;
    esac
    while IFS= read -r theirs; do
      [[ -n "$theirs" ]] || continue
      for mine in "${scopes[@]}"; do
        if overlap "$mine" "$theirs"; then die "write_scope 충돌: '$mine'($task) ↔ '$theirs'($other)"; fi
      done
    done <<<"$(ylist "$ROOT/.harness/tasks/$other.yaml" write_scope)"
  done < <(task_ids)
  (( active < max )) || die "동시 Worker 상한($max)에 도달했습니다.$( ((shared)) && echo ' 작업 공간을 나누지 않는 모드(원격·worktree 꺼짐)는 Task를 하나씩 통합까지 진행한다.')"

  if worktree_enabled; then
    wt="$ROOT/.harness/worktrees/$task"; branch="hh/$task"; code="$(code_dir)"
    if [[ -e "$wt" ]] && ! is_task_worktree "$wt"; then
      die "작업 공간 폴더가 git worktree가 아닙니다(이전 정리 실패): $wt — 내용을 확인해 지운 뒤 다시 착수한다."
    fi
    if [[ ! -d "$wt" ]]; then
      mkdir -p "$ROOT/.harness/worktrees"
      git -C "$code" worktree prune >/dev/null 2>&1 || true
      # 이미 본 브랜치에 통합된 브랜치(사용자 반려 뒤 재작업)는 현재 본 브랜치로 옮겨 이어서 작업한다.
      if git -C "$code" merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
        git -C "$code" branch -f "$branch" HEAD >/dev/null
      fi
      if git -C "$code" rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
        hcap git -C "$code" worktree add -q "$wt" "$branch"
      else
        hcap git -C "$code" worktree add -q -b "$branch" "$wt" HEAD
      fi
      (( RC == 0 )) || die "작업 공간을 만들지 못했습니다 ($wt): $OUT"
      info "작업 공간: $(rel "$wt") (브랜치 $branch)"
    fi
  fi
}

# 선행 Task 문제 — 없는 ID(오타·대체·TEMPLATE), 자기 자신. 문제가 있으면 이유를 출력한다(빈 출력 = 없음).
dep_problem() {  # TASK DEP
  if [[ "$2" == "$1" ]]; then echo "자기 자신을 선행 Task로 둠"; return 0; fi
  if [[ "$2" == TEMPLATE || ! -f "$ROOT/.harness/tasks/$2.yaml" ]] && ! archived_task "$2"; then
    echo "선행 Task가 없습니다 — $2 (dependencies 확인)"
  fi
  return 0
}

# 진행 중 Task들의 선행 관계를 따라가 자기 자신으로 돌아오는가. 서로 기다리는 Task는 영원히 착수되지 않는다.
dep_cycle() {  # TASK
  local start="$1" cur nxt f
  local -A seen=()
  local -a queue=("$1")
  while (( ${#queue[@]} )); do
    cur="${queue[0]}"; queue=("${queue[@]:1}")
    f="$ROOT/.harness/tasks/$cur.yaml"
    [[ -f "$f" ]] || continue
    [[ "$cur" == "$start" || "$(yget "$f" status 2>/dev/null)" != completed ]] || continue   # 끝난 Task는 막지 않는다
    while IFS= read -r nxt; do
      [[ -n "$nxt" ]] || continue
      [[ "$nxt" != "$start" ]] || return 0
      [[ -z "${seen[$nxt]:-}" ]] || continue
      seen[$nxt]=1; queue+=("$nxt")
    done < <( (ylist "$f" dependencies) 2>/dev/null || true)
  done
  return 1
}

worker_busy() {  # TASK → Worker Agent가 아직 working인가
  local m name
  m="$(meta_file "$1" worker)"
  [[ -f "$m" ]] && ! grep -q '^closed=' "$m" || return 1
  name="$(meta_get "$m" agent)"
  command -v herdr >/dev/null 2>&1 || return 1
  [[ "$(jfield "$(herdr agent get "$name" 2>/dev/null || true)" agent_status)" == working ]]
}

gate_submitted() {
  local task="$1" tf="$2" n report record missing start cwd sha
  ac_load "$tf"
  [[ -z "$AC_ERR" ]] || die "$AC_ERR ($(rel "$tf"))"
  plan_check "$task"
  n="$(last_attempt "$task")"
  (( n > 0 )) || die "dispatch 기록이 없습니다. Worker는 dispatch로만 기동한다."
  report="$(att_report "$task" "$n")"; record="$(att_record "$task" "$n")"
  ! grep -q '^- 기동 실패:' "$record" || die "attempt $n은 Agent 기동에 실패한 기록입니다. 다시 dispatch한다."
  [[ "$(rec_last "$record" 결과)" == settled ]] || die "attempt $n의 Agent가 작업을 마친 기록(settled)이 없습니다. observe로 확인한다."
  ! ac_passed "$record" || die "attempt $n은 이미 제출된 시도입니다. 수정은 새 dispatch로 한다."
  ! worker_busy "$task" || die "Worker가 아직 working입니다. 끝난 뒤 제출한다."
  [[ -s "$report" ]] || die "Worker 보고서가 없습니다: $(rel "$report")"
  start="$(rec_get "$record" '시작(epoch)')"
  [[ "$(stat -c %Y "$report")" -ge "${start:-0}" ]] || die "보고서가 이번 dispatch보다 먼저 작성됐습니다: $(rel "$report")"
  missing="$(missing_ids "$report" "${AC_ID[@]}")"
  [[ -z "$missing" ]] || die "보고서에 AC 결과가 빠졌습니다: ${missing}($(rel "$report"))"
  run_checks "$task" "$record" "AC 검증"
  [[ "$AC_RESULT" == PASS ]] || { commit_harness "$task attempt $n AC FAIL"; die "AC 검증 실패 — 증빙: $(rel "$record")"; }
  # 증빙을 정확한 코드 상태에 묶는다: 작업 공간의 변경을 Task 브랜치에 commit한다.
  if worktree_enabled; then
    cwd="$(task_cwd "$task")"
    git -C "$cwd" add -A -- . ':(exclude).harness' >/dev/null
    if ! git -C "$cwd" diff --cached --quiet; then
      hcap git -C "$cwd" commit -q -m "$task attempt $n (AC PASS)"
      if (( RC != 0 )); then
        local why; why="$(tail -n 3 <<<"$OUT" | tr '\n' ' ' | cut -c1-300)"
        if has_secret <<<"$why"; then why="(Secret 의심 — 생략)"; fi
        printf -- '- AC 요약: FAIL (AC는 통과했지만 commit 실패 — hook 등: %s)\n' "$why" >>"$record"
        commit_harness "$task attempt $n commit 실패"
        die "AC는 통과했지만 Task 브랜치 commit이 실패했습니다(hook 등). 원인을 고친 뒤 다시 submitted: $why"
      fi
    fi
    sha="$(git -C "$cwd" rev-parse HEAD)"
    printf -- '- 검증 commit: %s (브랜치 hh/%s)\n' "$sha" "$task" >>"$record"
  fi
  info "AC 검증 통과 — 증빙: $(rel "$record")"
}

gate_reviewing() {
  local task="$1" tf="$2" w r
  plan_check "$task"
  w="$(yget "$tf" primary_worker)"; r="$(yget "$tf" reviewer)"
  local req
  req="$(required_level "$task")"   # $( ) 안의 die는 삼켜지므로 먼저 받아 실패가 전파되게 한다
  [[ "$w" != "$r" || "$req" != cross_provider ]] ||
    die "Worker와 Reviewer가 같은 Provider($w)입니다. 다른 회사 검토가 기본이며, 예외(회사 정책·쿼터 소진)는 review-level 명령(사용자 결정)으로만 허용한다."
  ac_passed "$(att_record "$task" "$(last_attempt "$task")")" || die "최신 attempt에 AC 통과 증빙이 없습니다."
}

# Task 브랜치에 본 브랜치를 합쳐 통합 상태로 AC를 다시 돌린 뒤 본 브랜치를 fast-forward한다.
# 본 브랜치는 한 번도 검증되지 않은 상태를 거치지 않는다. 결과는 기록에 남긴다.
# 결과는 INTEG: OK | CONFLICT·FAIL(Worker가 고친다) | BLOCKED(사람이 본 저장소를 정리한다).
integrate() {  # TASK RECORD
  local task="$1" record="$2" code wt main verified dirty
  INTEG=OK
  worktree_enabled || return 0
  code="$(code_dir)"; wt="$ROOT/.harness/worktrees/$task"
  integ_stop() { INTEG="$1"; printf -- '- 통합: %s (%s)\n' "$1" "$2" >>"$record"; }
  main="$(git -C "$code" symbolic-ref --short HEAD 2>/dev/null)" || { integ_stop BLOCKED "본 저장소가 브랜치에 있지 않음"; return 0; }
  # 폴더만 남은 껍데기에서 git을 돌리면 본 저장소를 되돌리게 된다. 진짜 worktree일 때만 진행한다.
  is_task_worktree "$wt" || { integ_stop BLOCKED "작업 공간이 없거나 git worktree가 아님: $wt"; return 0; }
  # 본 브랜치에는 검증된 commit만 들어간다. 검증 뒤 생긴 commit은 아무도 검증하지 않았다.
  verified="$(rec_last "$(att_record "$task" "$(last_attempt "$task")")" '검증 commit' | cut -d' ' -f1)"
  [[ -n "$verified" ]] || { integ_stop BLOCKED "검증 commit 기록이 없음"; return 0; }
  # 검증 commit 이후의 commit·변경(리뷰 중 재실행 산출물 등)은 아무도 검증하지 않았다 — 기록하고 버린다.
  if [[ "$(git -C "$wt" rev-parse HEAD)" != "$verified" ]]; then
    git -C "$wt" merge-base --is-ancestor "$verified" HEAD 2>/dev/null ||
      { integ_stop BLOCKED "작업 공간 HEAD가 검증 commit $verified과 이어지지 않음"; return 0; }
    printf -- '- 검증 commit 이후 commit 버림:\n%s\n' "$(git -C "$wt" log --oneline "$verified..HEAD" | sed 's/^/    /')" >>"$record"
  fi
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null)" || dirty=""
  if [[ -n "$dirty" || "$(git -C "$wt" rev-parse HEAD)" != "$verified" ]]; then
    git -C "$wt" reset -q --hard "$verified" && git -C "$wt" clean -fdq ||
      { integ_stop BLOCKED "작업 공간을 검증 commit으로 되돌리지 못함"; return 0; }
    [[ -z "$dirty" ]] || printf -- '- 검증 commit 이후 변경 버림 (%s건):\n%s\n' "$(wc -l <<<"$dirty")" "$(head -n 20 <<<"$dirty" | sed 's/^/    /')" >>"$record"
  fi
  [[ -z "$(git -C "$code" status --porcelain --untracked-files=no -- . ':(exclude).harness' 2>/dev/null)" ]] ||
    { integ_stop BLOCKED "본 저장소($main)에 커밋되지 않은 변경이 있음"; return 0; }
  hcap git -C "$wt" merge --no-edit -q "$main"
  if (( RC != 0 )); then
    git -C "$wt" merge --abort >/dev/null 2>&1 || true
    integ_stop CONFLICT "$main와 충돌 — Worker가 작업 디렉터리에서 git merge $main로 해결"
    return 0
  fi
  ac_load "$(task_file "$task")"
  run_checks "$task" "$record" "통합 AC 검증"
  [[ "$AC_RESULT" == PASS ]] || { integ_stop FAIL "통합 후 AC 실패"; return 0; }
  hcap git -C "$code" merge --ff-only -q "hh/$task"
  if (( RC != 0 )); then
    git -C "$wt" reset -q --hard "$verified" || true   # 다음 시도가 다시 검증 commit에서 시작하도록 merge를 되돌린다
    integ_stop BLOCKED "fast-forward 불가: $(head -n 1 <<<"$OUT")"
    return 0
  fi
  printf -- '- 통합: OK %s → %s\n' "$(git -C "$code" rev-parse HEAD)" "$main" >>"$record"
  git -C "$code" worktree remove --force "$wt" >/dev/null 2>&1 ||
    warn "작업 공간을 지우지 못했습니다: $wt — 남은 파일을 정리한다(통합은 끝났다)."
  return 0
}

gate_review() {  # changes_requested·awaiting_approval 공통: dispatch된 최신 Review가 근거다
  local task="$1" tf="$2" to="$3" r n file record verdict target rp wp missing start req act
  r="$(last_review "$task")"
  (( r > 0 )) || die "dispatch된 Review가 없습니다. Reviewer는 dispatch로만 기동한다."
  file="$(rev_file "$task" "$r")"; record="$(rev_record "$task" "$r")"
  if [[ "$to" == changes_requested && "$(yget "$tf" status)" == awaiting_approval ]]; then
    local rej
    rej="$(latest_rejection "$task")"
    [[ -n "$rej" && "$(rec_get "$rej" '대상 Review')" == ".harness/reviews/$task-review-$r.md" ]] ||
      die "승인 대기 Task는 사용자 반려 기록이 있어야 되돌릴 수 있습니다 (reject $task --reason \"사유\" --confirm-user-approval)."
    return 0
  fi
  if [[ "$to" == changes_requested && "$(rec_last "$record" 통합)" =~ ^(CONFLICT|FAIL) ]]; then return 0; fi
  ! grep -q '^- 기동 실패:' "$record" || die "review $r는 Agent 기동에 실패한 기록입니다."
  [[ "$(rec_last "$record" 결과)" == settled ]] || die "review $r의 Reviewer가 작업을 마친 기록(settled)이 없습니다."
  [[ -s "$file" ]] || die "Review 파일이 없습니다: $(rel "$file")"
  start="$(rec_get "$record" '시작(epoch)')"
  [[ "$(stat -c %Y "$file")" -ge "${start:-0}" ]] || die "Review가 이번 dispatch보다 먼저 작성됐습니다: $(rel "$file")"
  verdict="$(review_verdict "$file")"
  if [[ "$to" == changes_requested ]]; then
    [[ "$verdict" == CHANGES_REQUESTED ]] || die "최신 Review 판정이 CHANGES_REQUESTED가 아닙니다 (${verdict:-없음})."
    return 0
  fi
  [[ "$verdict" == APPROVED ]] || die "최신 Review 판정이 APPROVED가 아닙니다 (${verdict:-없음}): $(rel "$file")"
  n="$(last_attempt "$task")"
  target="$(review_target "$file")"
  [[ "$target" == "$n" ]] || die "Review가 최신 attempt $n을 대상으로 하지 않습니다 (대상 Attempt: ${target:-없음})."
  [[ "$(rec_get "$record" '검토 대상')" == "attempt $n "* ]] ||
    die "review $r는 attempt $n 대상으로 dispatch되지 않았습니다 (Harness 기록: $(rec_get "$record" '검토 대상')). Reviewer를 다시 dispatch한다."
  plan_check "$task"
  # 검토 독립성: 실제 기록(Provider·모델)로 판정한다. 다른 회사가 기본, 예외는 결정 기록이 있는 수준까지만.
  rp="$(rec_get "$record" Provider)"; wp="$(rec_get "$(att_record "$task" "$n")" Provider)"
  [[ -n "$rp" && -n "$wp" ]] || die "검토 기록에 Provider가 없습니다."
  req="$(required_level "$task")"
  act="$(actual_level "$wp" "$(rec_get "$(att_record "$task" "$n")" 모델)" "$rp" "$(rec_get "$record" 모델)")"
  (( $(level_rank "$act") >= $(level_rank "$req") )) ||
    die "검토 독립성이 부족합니다: 실제 $(level_name "$act") < 필요 $(level_name "$req") (Worker $wp, Reviewer $rp)"
  [[ "$(rec_last "$record" '검토 수준')" == "$act (필요: $req)" ]] || printf -- '- 검토 수준: %s (필요: %s)\n' "$act" "$req" >>"$record"
  ac_load "$tf"
  missing="$(missing_ids "$file" ${AC_ID[@]+"${AC_ID[@]}"})"
  [[ -z "$missing" ]] || die "Review가 다음 AC의 증빙 대조를 빠뜨렸습니다: $missing"
  integrate "$task" "$record"
  case "$INTEG" in
    OK) ;;
    BLOCKED) commit_harness "$task 통합 보류"
      die "통합 보류 — $(rec_last "$record" 통합). 사람이 본 저장소를 정리한 뒤 다시 transition $task awaiting_approval." ;;
    *) commit_harness "$task 통합 실패"
      die "통합 실패 — $(rec_last "$record" 통합). changes_requested로 돌려 Worker가 해결한다." ;;
  esac
}

gate_completed() {
  local task="$1" m f r
  m="$(yget "$(task_file "$task")" milestone_id)"
  f="$ROOT/.harness/decisions/$m-approval.md"
  r="$(last_review "$task")"
  [[ -f "$f" ]] && grep -qxF '승인: yes' "$f" && grep -q "^| $task | .harness/reviews/$task-review-$r.md |" "$f" ||
    die "$task의 Milestone 승인 기록이 없습니다 (approve $m --confirm-user-approval)."
}

set_status() { set_field "$1" status "$2"; }

do_transition() {
  local task="$1" to="$2" tf from
  tf="$(task_file "$task")"
  from="$(yget "$tf" status)"
  [[ "$TRANSITIONS" == *" $from>$to "* ]] || die "허용되지 않은 전이: $from -> $to ($task)"
  case "$to" in
    ready) gate_ready "$task" ;;
    active) gate_active "$task" "$tf" ;;
    submitted) gate_submitted "$task" "$tf" ;;
    reviewing) gate_reviewing "$task" "$tf" ;;
    changes_requested|awaiting_approval) gate_review "$task" "$tf" "$to" ;;
    handover_required)
      compgen -G "$ROOT/.harness/handovers/$task-handover-*.md" >/dev/null ||
        die "인계 문서가 없습니다: .harness/handovers/$task-handover-N.md (harness-handover)" ;;
    completed) gate_completed "$task" ;;
  esac
  set_status "$tf" "$to"
  commit_harness "$task: $from -> $to"
  printf '%s: %s -> %s\n' "$task" "$from" "$to"
}

cmd_transition() {
  [[ $# -eq 2 ]] || die "사용법: transition TASK STATE"
  require_human transition
  do_transition "$1" "$2"
}

# --------------------------------------------------------------------------
# 사용자 결정 — 계획 승인과 Milestone 완료 승인. 사용자가 채팅에서 명시했을 때만
# Orchestrator가 --confirm-user-approval과 함께 부른다.
# --------------------------------------------------------------------------
need_confirm() {
  local a
  for a in "$@"; do [[ "$a" != --confirm-user-approval ]] || return 0; done
  die "사용자가 명시적으로 승인했을 때만 --confirm-user-approval과 함께 호출한다."
}

cmd_approve_plan() {
  local m="${1:-}" id tf w r wt rt wm rm_ mm req planned basis dep why rows="" tasks=()
  [[ -n "$m" ]] || die "사용법: approve-plan MILESTONE --confirm-user-approval"
  need_id "$m"; shift; need_confirm "$@"
  require_human approve-plan
  spec_approved || die "SPEC이 먼저 승인돼야 합니다."
  mapfile -t tasks < <(milestone_tasks "$m")
  (( ${#tasks[@]} > 0 )) || die "$m에 속한 Task가 없습니다 (Task YAML의 milestone_id)."
  for id in "${tasks[@]}"; do
    tf="$(task_file "$id")"
    [[ "$(yget "$tf" task_id)" == "$id" ]] || die "$id: 파일명과 task_id가 다릅니다."
    ac_load "$tf"; [[ -z "$AC_ERR" ]] || die "$id: $AC_ERR"
    [[ -f "$ROOT/$(yget "$tf" intent)" ]] || die "$id: intent 파일이 없습니다."
    ylist "$tf" write_scope >/dev/null; ylist "$tf" dependencies >/dev/null
    # 착수할 수 없는 선행 관계는 승인하지 않는다 (승인 뒤에는 착수 게이트에서 영원히 기다린다)
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      why="$(dep_problem "$id" "$dep")"
      [[ -z "$why" ]] || die "$id: $why"
    done <<<"$(ylist "$tf" dependencies)"
    grep -qxF -- "$id" <<<"$(ylist "$tf" dependencies)" || ! dep_cycle "$id" || die "$id: 선행 Task가 순환합니다 (서로 기다려 착수되지 않는다)"
    w="$(yget "$tf" primary_worker)"; r="$(yget "$tf" reviewer)"
    is_provider "$w" && is_provider "$r" || die "$id: Worker/Reviewer 배정 오류 ($w / $r)"
    wt="$(task_tier "$tf" worker)"; rt="$(task_tier "$tf" reviewer)"
    wm="$(task_model "$tf" worker "$w")"; rm_="$(task_model "$tf" reviewer "$r")"
    for mm in "$wm" "$rm_"; do
      [[ -z "$mm" || "$mm" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]] || die "$id: 모델 이름 형식이 올바르지 않습니다: $mm"
    done
    req="$(required_level "$id")"
    planned="$(actual_level "$w" "$wm" "$r" "$rm_")"
    (( $(level_rank "$planned") >= $(level_rank "$req") )) ||
      die "$id: 계획된 검토 수준($(level_name "$planned"): $w/${wm:-Provider 기본값} → $r/${rm_:-Provider 기본값})이 필요 수준($(level_name "$req"))보다 낮습니다. 다른 회사 Reviewer를 쓰거나, 같은 회사면 Reviewer 모델을 다르게(reviewer_model·reviewer_tier) 지정한다."
    basis="task:$(last_n "$ROOT/.harness/decisions" "$id-review-level-" .md) project:$(last_n "$ROOT/.harness/decisions" "review-level-" .md)"
    rows+="| $id | $w | $r | $wt | $rt | ${wm:-Provider 기본값} | ${rm_:-Provider 기본값} | $req | $basis | $(ac_hash "$tf") |"$'\n'
  done
  write_atomic "$(plan_file "$m")" <<EOF
# 계획 승인: $m

이 파일은 approve-plan만 쓴다. AC가 이 표와 달라지거나, 비싼 모델(premium·매핑에 없는 모델)이 이 표와 다르면 진행이 막힌다.

승인: yes
승인 시각: $(now)
명시 확인: --confirm-user-approval

| Task | Worker | Reviewer | Worker 등급 | Reviewer 등급 | Worker 모델 | Reviewer 모델 | 검토 수준 | 수준 근거 | AC 지문 |
|---|---|---|---|---|---|---|---|---|---|
$rows
EOF
  for id in "${tasks[@]}"; do
    [[ "$(yget "$(task_file "$id")" status)" != draft ]] || do_transition "$id" ready
  done
  commit_harness "$m 계획 승인"
  info "계획 승인 기록: $(rel "$(plan_file "$m")")"
}

cmd_approve() {
  local m="${1:-}" id tf st r lv rq rows="" tasks=() problems=""
  [[ -n "$m" ]] || die "사용법: approve MILESTONE --confirm-user-approval"
  need_id "$m"; shift; need_confirm "$@"
  require_human approve
  mapfile -t tasks < <(milestone_tasks "$m")
  (( ${#tasks[@]} > 0 )) || die "$m에 속한 Task가 없습니다."
  for id in "${tasks[@]}"; do
    tf="$(task_file "$id")"; st="$(yget "$tf" status)"; r="$(last_review "$id")"
    if [[ "$st" != awaiting_approval ]]; then problems+="$id($st) "; continue; fi
    [[ "$(review_verdict "$(rev_file "$id" "$r")")" == APPROVED ]] || problems+="$id(Review) "
    ! worktree_enabled || grep -q '^- 통합: OK' "$(rev_record "$id" "$r")" || problems+="$id(통합) "
    lv="$(review_level_of "$id" "$r")"
    rq="$(required_level "$id")"
    (( $(level_rank "${lv:-x}") >= $(level_rank "$rq") )) || problems+="$id(검토 수준 $(level_name "${lv:-없음}") < 필요 $(level_name "$rq")) "
    rows+="| $id | .harness/reviews/$id-review-$r.md | $(rec_get "$(att_record "$id" "$(last_attempt "$id")")" Provider) | $(rec_get "$(rev_record "$id" "$r")" Provider) | ${lv:-?} |"$'\n'
  done
  [[ -z "$problems" ]] || die "아직 승인할 수 없는 Task가 있습니다: $problems"
  write_atomic "$ROOT/.harness/decisions/$m-approval.md" <<EOF
# Milestone 완료 승인: $m

승인: yes
승인 시각: $(now)
코드 commit: $(git -C "$(code_dir)" rev-parse HEAD 2>/dev/null || echo '-')
명시 확인: --confirm-user-approval

| Task | 근거 Review | Worker | Reviewer | 검토 수준 |
|---|---|---|---|---|
$rows
EOF
  for id in "${tasks[@]}"; do do_transition "$id" completed; done
  archive_milestone "$m" "${tasks[@]}"
}

# 검토 수준 결정 기록. 사용자 결정(review-level 명령)과 자동 하향(review.fallback_level)이 같은 형식으로 남는다.
record_level() {  # TASK|"" LEVEL PREVIOUS REASON DECIDER [FALLBACK]
  local prefix k fb="" fbline=""
  if [[ -n "$1" ]]; then prefix="$1-review-level-"
  else prefix="review-level-"; fb="${6:-$(fallback_level)}"; fbline=$'\n'"- 자동 하향 허용: $fb"; fi
  k=$(( $(last_n "$ROOT/.harness/decisions" "$prefix" .md) + 1 ))
  write_atomic "$ROOT/.harness/decisions/$prefix$k.md" <<EOF
# 검토 수준 결정: ${1:-프로젝트} #$k

- 수준: $2
- 이전: $3${fbline}
- 범위: ${1:-project}
- 결정: $5
- 시각: $(now)

## 사유

$4
EOF
  if [[ -n "$1" ]]; then upsert_field "$(task_file "$1")" review_level "$2"
  else pset review level "'$2'"; pset review fallback_level "'$fb'"; fi
}

# 한 회사만 쓸 수 있는 환경(회사 정책·쿼터 소진)을 위한 예외. 낮추는 것과 자동 하향을 허용하는 것은 사용자 결정이다.
#   review-level LEVEL [--task T]           검토 수준 (Task 단위 또는 프로젝트)
#   review-level [LEVEL] --fallback FB       다른 회사가 없을 때 자동으로 낮출 수 있는 최저 수준 (프로젝트만)
cmd_review_level() {
  local lv="" task="" reason="" confirm=0 cur fb="" curfb loosen=0
  if valid_level "${1:-}"; then lv="$1"; shift; fi
  while (( $# )); do
    case "$1" in
      --task) task="${2:-}"; need_id "$task"; shift 2 ;;
      --fallback) [[ "${2:-}" =~ ^(none|cross_model|same_model)$ ]] || die "--fallback은 none | cross_model | same_model"; fb="$2"; shift 2 ;;
      --reason) [[ -n "${2:-}" ]] || die "--reason에 사유가 필요합니다."; reason="$2"; shift 2 ;;
      --confirm-user-approval) confirm=1; shift ;;
      *) die "알 수 없는 review-level 옵션: $1" ;;
    esac
  done
  [[ -n "$lv" || -n "$fb" ]] ||
    die "사용법: review-level [cross_provider|cross_model|same_model] [--task TASK] [--fallback none|cross_model|same_model] --reason \"사유\" [--confirm-user-approval]"
  [[ -z "$task" || -z "$fb" ]] || die "--fallback은 프로젝트 단위 설정이라 --task와 함께 쓸 수 없습니다."
  [[ -n "$reason" ]] || die "--reason \"사유\"가 필요합니다 (결정 기록에 남는다)."
  ! has_secret <<<"$reason" || die "사유에 Secret 의심 패턴이 있습니다."
  require_human review-level
  # 현재 수준은 결정 기록에서 읽는다: 설정 줄이 손으로 바뀌어 다른 명령이 막힌 상태도 이 명령으로 바로잡는다.
  cur="$(recorded_level "$task")"
  curfb="$(fallback_level)"
  lv="${lv:-$cur}"; fb="${fb:-$curfb}"
  if [[ "$fb" != none ]] && { [[ "$curfb" == none ]] || (( $(level_rank "$fb") < $(level_rank "$curfb") )); }; then loosen=1; fi
  if (( $(level_rank "$lv") < $(level_rank "$cur") || loosen )); then
    (( confirm )) || die "검토 수준을 낮추거나 자동 하향을 허용하는 것은 사용자 결정입니다. 사용자가 명시했을 때만 --confirm-user-approval과 함께 호출한다."
  fi
  record_level "$task" "$lv" "$cur" "$reason" "사용자$( ((confirm)) && echo ' (--confirm-user-approval)')" "$fb"
  commit_harness "검토 수준 ${task:-프로젝트}: $cur → $lv$( [[ -n "$task" ]] || echo ", 자동 하향 $curfb → $fb")"
  info "검토 수준 ${task:-프로젝트}: $(level_name "$cur") → $(level_name "$lv")$( [[ -n "$task" ]] || echo " · 자동 하향 허용: $(level_name "$curfb") → $(level_name "$fb")") (결정 기록: $(rel "$(latest_level_record "$task")"))"
}

review_level_of() {  # TASK [REVIEW_N] → 그 리뷰의 실제 검토 수준 (기록 줄이 없으면 Provider·모델 기록으로 계산)
  local r rr ar lv
  r="${2:-$(last_review "$1")}"; rr="$(rev_record "$1" "$r")"
  lv="$(rec_last "$rr" '검토 수준' | cut -d' ' -f1)"
  if [[ -z "$lv" && -f "$rr" ]]; then
    ar="$(att_record "$1" "$(rec_get "$rr" '검토 대상' | sed -n 's/^attempt \([0-9]*\).*/\1/p')")"
    [[ -f "$ar" ]] || ar="$(att_record "$1" "$(last_attempt "$1")")"
    lv="$(actual_level "$(rec_get "$ar" Provider)" "$(rec_get "$ar" 모델)" "$(rec_get "$rr" Provider)" "$(rec_get "$rr" 모델)")"
  fi
  printf '%s' "$lv"
}

latest_rejection() {  # TASK → 최신 사용자 반려 기록 경로 (없으면 빈 값)
  local k
  k="$(last_n "$ROOT/.harness/decisions" "$1-rejection-" .md)"
  (( k == 0 )) || printf '%s/.harness/decisions/%s-rejection-%s.md' "$ROOT" "$1" "$k"
}

# 사용자가 승인 대기 결과를 반려한다. 사유는 다음 Worker·Reviewer 지시서에 그대로 들어가고,
# 재작업 상한은 반려 시점부터 새로 센다.
cmd_reject() {
  local task="${1:-}" reason="" confirm=0 tf st r k
  [[ -n "$task" ]] || die "사용법: reject TASK --reason \"사유\" --confirm-user-approval"
  shift
  while (( $# )); do
    case "$1" in
      --reason) [[ -n "${2:-}" ]] || die "--reason에 사유가 필요합니다."; reason="$2"; shift 2 ;;
      --confirm-user-approval) confirm=1; shift ;;
      *) die "알 수 없는 reject 옵션: $1" ;;
    esac
  done
  (( confirm )) || die "사용자가 반려를 명시했을 때만 --confirm-user-approval과 함께 호출한다."
  [[ -n "$reason" ]] || die "--reason \"사유\"가 필요합니다 (다음 Worker가 받는다)."
  ! has_secret <<<"$reason" || die "사유에 Secret 의심 패턴이 있습니다."
  require_human reject
  tf="$(task_file "$task")"; st="$(yget "$tf" status)"
  [[ "$st" == awaiting_approval ]] || die "$task는 승인 대기(awaiting_approval)가 아닙니다 ($st)."
  r="$(last_review "$task")"
  k=$(( $(last_n "$ROOT/.harness/decisions" "$task-rejection-" .md) + 1 ))
  write_atomic "$ROOT/.harness/decisions/$task-rejection-$k.md" <<EOF
# 사용자 반려: $task #$k

- 반려: yes
- 시각: $(now)
- 시각(epoch): $(date +%s)
- 대상 Review: .harness/reviews/$task-review-$r.md
- 반려 시 attempt: $(last_attempt "$task")
- 명시 확인: --confirm-user-approval

## 사유

$reason
EOF
  do_transition "$task" changes_requested
  info "반려 기록: .harness/decisions/$task-rejection-$k.md — run으로 재작업을 이어 간다."
}

# 파일 이름이 ID로 시작해도, 더 긴 다른 Task ID로 시작하면 그 Task의 기록이다 (task-12-1의 기록은 task-12의 것이 아니다).
task_owns() {  # TASK BASENAME
  local f o
  for f in "$ROOT"/.harness/tasks/*.yaml "$ROOT"/.harness/archive/*/tasks/*.yaml; do
    o="${f##*/}"; o="${o%.yaml}"
    [[ -f "$f" && "$o" != "$1" && "$o" == "$1"-* ]] || continue
    [[ "$2" != "$o"-* && "$2" != "$o".* ]] || return 1
  done
  return 0
}

# 승인된 Milestone을 보관함으로 옮긴다. 진행 중인 것만 앞에 남겨 지시서·상태 확인이
# 작업 기간과 무관하게 가볍게 유지된다. 원본은 git 태그로 언제든 되살릴 수 있다.
archive_milestone() {
  local m="$1" dst id f tag code attempts=0 n rows=""
  shift
  dst="$ROOT/.harness/archive/$m"
  mkdir -p "$dst/tasks" "$dst/intents" "$dst/attempts" "$dst/reviews" "$dst/handovers" "$dst/decisions" "$dst/verifications"
  for id in "$@"; do
    n="$(last_attempt "$id")"; attempts=$((attempts + n))
    rows+="| $id | $(yget "$ROOT/.harness/tasks/$id.yaml" title) | $(yget "$ROOT/.harness/tasks/$id.yaml" primary_worker) | $(yget "$ROOT/.harness/tasks/$id.yaml" reviewer) | $n | $(rec_last "$(att_record "$id" "$n")" 'AC 요약' | cut -d' ' -f1) | $(review_verdict "$(rev_file "$id" "$(last_review "$id")")") | $(review_level_of "$id") |"$'\n'
    f="$(yget "$ROOT/.harness/tasks/$id.yaml" intent)"
    [[ -z "$f" || ! -f "$ROOT/$f" ]] || mv -- "$ROOT/$f" "$dst/intents/"
    mv -- "$ROOT/.harness/tasks/$id.yaml" "$dst/tasks/"
    # 결정 기록·Intent 폴더의 부속 파일은 Task ID로 시작하는 것 전부를 함께 옮긴다
    # (반려·검토 수준 기록, v1에서 이전된 결정 메모·추가 지시 포함).
    for f in "$ROOT"/.harness/attempts/"$id"-attempt-* "$ROOT"/.harness/reviews/"$id"-review-* \
             "$ROOT"/.harness/handovers/"$id"-handover-* "$ROOT"/.harness/decisions/"$id"-* \
             "$ROOT"/.harness/intents/"$id"-* "$ROOT"/.harness/verifications/"$id"-verify-*; do
      [[ -e "$f" ]] && task_owns "$id" "${f##*/}" || continue
      mv -- "$f" "$dst/${f#"$ROOT/.harness/"}"
    done
    rm -f -- "$ROOT"/.harness/runtime/"$id"-worker.* "$ROOT"/.harness/runtime/"$id"-reviewer.* \
             "$ROOT"/.harness/runtime/"$id"-worker-[0-9]*.log "$ROOT"/.harness/runtime/"$id"-reviewer-[0-9]*.log
    code="$(code_dir)"
    git -C "$code" branch -d "hh/$id" >/dev/null 2>&1 || true
  done
  for f in "$(plan_file "$m")" "$ROOT/.harness/decisions/$m-approval.md"; do
    [[ ! -f "$f" ]] || mv -- "$f" "$dst/decisions/"
  done
  find "$dst" -type d -empty -delete
  tag="$m-approved"
  {
    printf '# Milestone 요약: %s\n\n- 승인: %s\n- 코드 commit: %s\n- 태그: %s (상세 원본은 이 태그로 복원)\n- 시도 합계: %s\n\n' \
      "$m" "$(now)" "$(git -C "$(code_dir)" rev-parse HEAD 2>/dev/null || echo -)" "$tag" "$attempts"
    printf '| Task | 제목 | Worker | Reviewer | 시도 | 최종 AC | Review | 검토 수준 |\n|---|---|---|---|---|---|---|---|\n%s\n' "$rows"
    printf '## 지표\n\n'
    metrics_table "$dst"
  } >"$dst/SUMMARY.md"
  [[ -f "$ROOT/.harness/HISTORY.md" ]] || printf '# 완료 이력\n\n| 날짜 | Milestone | Task | 시도 합계 | 태그 |\n|---|---|---|---|---|\n' >"$ROOT/.harness/HISTORY.md"
  printf '| %s | %s | %s개 | %s | %s |\n' "$(date +%F)" "$m" "$#" "$attempts" "$tag" >>"$ROOT/.harness/HISTORY.md"
  rm -f -- "$ROOT/.harness/runtime/run-$m.log" "$ROOT/.harness/runtime/run-$m.result"
  commit_harness "$m 완료 승인·보관"
  if git -C "$ROOT" cat-file -e "HEAD:.harness/archive/$m/SUMMARY.md" 2>/dev/null; then
    git -C "$ROOT" tag -f "$tag" >/dev/null 2>&1 || warn "태그 생성 실패: $tag"
  else
    warn "보관 commit이 확인되지 않아 태그를 만들지 않았습니다. 기록을 commit한 뒤 git tag $tag"
  fi
  info "$m 보관 완료: $(rel "$dst") · 태그 $tag"
}

# 오래된 보관함의 상세 파일을 지우고 요약만 남긴다. 원본은 태그에 남아 있다.
cmd_prune() {
  local m="${1:-}" dst
  [[ -n "$m" ]] || die "사용법: prune MILESTONE  (요약만 남기고 상세 파일 삭제, 원본은 태그 $m-approved)"
  need_id "$m"; require_human prune
  dst="$ROOT/.harness/archive/$m"
  [[ -f "$dst/SUMMARY.md" ]] || die "보관된 Milestone이 아닙니다: $m"
  git -C "$ROOT" cat-file -e "$m-approved:.harness/archive/$m/SUMMARY.md" 2>/dev/null ||
    die "태그 $m-approved에 보관 원본이 없어 삭제하지 않습니다."
  find "$dst" -mindepth 1 -maxdepth 1 ! -name SUMMARY.md -exec rm -rf -- {} +
  commit_harness "$m 보관함 정리 (원본: 태그 $m-approved)"
  info "$m: SUMMARY.md만 남겼습니다. 원본 확인: git show $m-approved:.harness/archive/$m/"
}

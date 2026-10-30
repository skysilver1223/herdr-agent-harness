# herdr-harness: 상태 보기·지표·검사·점검. 손으로 고치는 상태 파일 없이 Task 파일과 기록에서 계산한다.
# harness.sh가 source한다. 단독 실행하지 않는다.

# 기록 파일에서 성과 지표를 계산한다. 어느 에이전트·등급에 어떤 일을 맡겨야 쿼터를 덜 쓰는지의 근거다.
metrics_table() {  # DIR... (진행 중 기록 폴더, 보관함 한 곳, 또는 .harness 전체)
  local f p k tier ac v n tasks=0 sum=0 rework=0 base
  local -A w_try=() w_pass=() w_fail=() w_first=() r_cnt=() r_ok=() r_cr=() t_try=()
  while IFS= read -r -d '' f; do
    p="$(rec_get "$f" Provider)"; tier="$(rec_get "$f" 등급)"; k="${p:-?}|${tier:-?}"
    ac="$(rec_last "$f" 'AC 요약')"; ac="${ac%% *}"
    w_try[$k]=$(( ${w_try[$k]:-0} + 1 ))
    case "$ac" in PASS) w_pass[$k]=$(( ${w_pass[$k]:-0} + 1 )) ;; FAIL) w_fail[$k]=$(( ${w_fail[$k]:-0} + 1 )) ;; esac
    base="${f##*/}"; n="${base##*-attempt-}"; n="${n%.harness.md}"; base="${base%-attempt-*}"
    [[ "$n" != 1 || "$ac" != PASS ]] || w_first[$k]=$(( ${w_first[$k]:-0} + 1 ))
    (( 10#$n <= ${t_try[$base]:-0} )) || t_try[$base]=$((10#$n))
  done < <(find "$@" -name '*-attempt-*.harness.md' -print0 2>/dev/null)
  while IFS= read -r -d '' f; do
    p="$(rec_get "$f" Provider)"; p="${p:-?}"
    v="$(review_verdict "${f%.harness.md}.md")"
    r_cnt[$p]=$(( ${r_cnt[$p]:-0} + 1 ))
    case "$v" in APPROVED) r_ok[$p]=$(( ${r_ok[$p]:-0} + 1 )) ;; CHANGES_REQUESTED) r_cr[$p]=$(( ${r_cr[$p]:-0} + 1 )) ;; esac
  done < <(find "$@" -name '*-review-*.harness.md' -print0 2>/dev/null)
  if (( ${#w_try[@]} == 0 && ${#r_cnt[@]} == 0 )); then printf '아직 기록이 없습니다.\n'; return 0; fi
  printf '| Worker | 등급 | 시도 | AC 통과 | AC 실패 | 첫 시도 통과 |\n|---|---|---|---|---|---|\n'
  for k in $(printf '%s\n' "${!w_try[@]}" | sort); do
    printf '| %s | %s | %s | %s | %s | %s |\n' "${k%%|*}" "${k#*|}" "${w_try[$k]}" "${w_pass[$k]:-0}" "${w_fail[$k]:-0}" "${w_first[$k]:-0}"
  done
  printf '\n| Reviewer | 리뷰 | 승인 | 수정 요청 |\n|---|---|---|---|\n'
  for p in $(printf '%s\n' "${!r_cnt[@]}" | sort); do
    printf '| %s | %s | %s | %s |\n' "$p" "${r_cnt[$p]}" "${r_ok[$p]:-0}" "${r_cr[$p]:-0}"
  done
  for k in "${!t_try[@]}"; do tasks=$((tasks + 1)); sum=$((sum + t_try[$k])); (( t_try[$k] <= 1 )) || rework=$((rework + 1)); done
  (( tasks == 0 )) || printf '\nTask %s개 · 평균 시도 %s.%s회 · 재작업한 Task %s개\n' \
    "$tasks" "$((sum / tasks))" "$(( (sum * 10 / tasks) % 10 ))" "$rework"
  return 0
}

cmd_metrics() {
  printf '# 지표 — 진행 중\n\n'; metrics_table "$ROOT/.harness/attempts" "$ROOT/.harness/reviews"
  printf '\n# 지표 — 전체 (보관함 포함)\n\n'; metrics_table "$ROOT/.harness"
}

cmd_status() {
  local id tf st m n r ac v pending="" rows="" line lock res tier
  local -A ms_total=() ms_done=() ms_wait=() ms_run=() ms_draft=() ms_hold=()
  printf '# %s (harness %s)\n\n목표: %s\n' "$(pget project name)" "$HARNESS_VERSION" "$(pget project goal)"
  spec_approved || pending+="- SPEC 승인 필요: .harness/SPEC.md의 '- 상태: approved' (사용자)"$'\n'
  while IFS= read -r id; do
    tf="$ROOT/.harness/tasks/$id.yaml"
    st="$(yget "$tf" status)"; m="$(yget "$tf" milestone_id)"; m="${m:-(없음)}"
    n="$(last_attempt "$id")"; r="$(last_review "$id")"
    ac="-"; v="-"
    if (( n > 0 )); then ac="$n ($(rec_last "$(att_record "$id" "$n")" 'AC 요약' | cut -d' ' -f1))"; fi
    if (( r > 0 )); then v="$r ($(review_verdict "$(rev_file "$id" "$r")"))"; fi
    # die하는 함수는 $( ) 안의 || 로 막을 수 없다(exit가 서브셸째 끝낸다). 대입 뒤에 받는다.
    tier="$(task_tier "$tf" worker 2>/dev/null)" || tier='?'
    rows+="| $id | $m | $(yget "$tf" title) | $st | $(yget "$tf" primary_worker) ($tier) | $(yget "$tf" reviewer) | $ac | $v |"$'\n'
    ms_total[$m]=$(( ${ms_total[$m]:-0} + 1 ))
    case "$st" in
      completed) ms_done[$m]=$(( ${ms_done[$m]:-0} + 1 )) ;;
      awaiting_approval) ms_wait[$m]=$(( ${ms_wait[$m]:-0} + 1 )) ;;
      draft) ms_draft[$m]=$(( ${ms_draft[$m]:-0} + 1 )) ;;
      blocked|handover_required) ms_hold[$m]=$(( ${ms_hold[$m]:-0} + 1 )); pending+="- $id: $st — 사용자 판단 필요"$'\n' ;;
      *) ms_run[$m]=$(( ${ms_run[$m]:-0} + 1 )) ;;
    esac
  done < <(task_ids)

  printf '\n## Milestone 진행\n\n| Milestone | Task | 완료 | 승인 대기 | 진행 중 | 계획 | 보류 | 계획 승인 | 자동 진행 |\n|---|---|---|---|---|---|---|---|---|\n'
  for m in $(printf '%s\n' "${!ms_total[@]}" | sort); do
    lock="$ROOT/.harness/runtime/run-$m.lock"; res="-"
    if [[ -d "$lock" ]] && kill -0 "$(cat "$lock/pid" 2>/dev/null || echo 0)" 2>/dev/null; then res="실행 중"
    elif [[ -f "$ROOT/.harness/runtime/run-$m.result" ]]; then res="$(cut -d' ' -f2 "$ROOT/.harness/runtime/run-$m.result")"; fi
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' "$m" "${ms_total[$m]}" "${ms_done[$m]:-0}" "${ms_wait[$m]:-0}" \
      "${ms_run[$m]:-0}" "${ms_draft[$m]:-0}" "${ms_hold[$m]:-0}" "$([[ -f "$(plan_file "$m")" ]] && echo yes || echo no)" "$res"
    (( ${ms_draft[$m]:-0} == 0 )) || pending+="- $m: 계획 승인 필요 (draft ${ms_draft[$m]}개) → approve-plan $m --confirm-user-approval"$'\n'
    (( ${ms_wait[$m]:-0} + ${ms_done[$m]:-0} != ${ms_total[$m]} || ${ms_wait[$m]:-0} == 0 )) ||
      pending+="- $m: 모든 Task가 교차 검토·통합을 통과했습니다 → 결과 확인 후 approve $m --confirm-user-approval"$'\n'
    [[ "$res" != user_needed ]] || pending+="- $m: 자동 진행이 사용자 판단을 기다립니다 (.harness/runtime/run-$m.log)"$'\n'
  done

  printf '\n## Task\n\n| Task | Milestone | 제목 | 상태 | Worker (등급) | Reviewer | 최신 Attempt | 최신 Review |\n|---|---|---|---|---|---|---|---|\n%s' "$rows"

  printf '\n## Agent (Harness가 띄운 것)\n\n| Task | Role | Agent | Pane | Herdr | 판정 |\n|---|---|---|---|---|---|\n'
  local f task role name state expect verdict
  for f in "$ROOT"/.harness/runtime/*.meta; do
    [[ -f "$f" ]] && ! grep -q '^closed=' "$f" || continue
    task="${f##*/}"; task="${task%.meta}"; role="${task##*-}"; task="${task%-*}"
    name="$(meta_get "$f" agent)"; state=missing
    if command -v herdr >/dev/null 2>&1; then
      hcap herdr agent get "$name"
      (( RC != 0 )) || state="$(jfield "$OUT" agent_status)"
    fi
    st="$(yget "$ROOT/.harness/tasks/$task.yaml" status 2>/dev/null)" || st=""
    expect=0
    [[ ! "$role:$st" =~ ^(worker:(active|blocked)|reviewer:reviewing)$ ]] || expect=1
    if [[ "$state" == missing ]]; then verdict="$( ((expect)) && echo 'DRIFT (Agent 없음)' || echo '종료됨 — close로 정리')"
    else verdict="$( ((expect)) && echo OK || echo 'ORPHAN — close 필요')"; fi
    printf '| %s | %s | %s | %s | %s | %s |\n' "$task" "$role" "$name" "$(meta_get "$f" pane)" "$state" "$verdict"
  done

  printf '\n## 사용자 판단 대기\n\n%s' "${pending:-- 없음}"$'\n'
  printf '\n## 다음 할 일 (BACKLOG 상위 5)\n\n'
  line="$(grep -E '^- \[ \]' "$ROOT/.harness/BACKLOG.md" 2>/dev/null | head -n 5 || true)"
  printf '%s\n' "${line:-- 없음}"
  printf '\n## 최근 완료\n\n'
  line="$(grep -E '^\| [0-9]{4}-' "$ROOT/.harness/HISTORY.md" 2>/dev/null | tail -n 3 || true)"
  printf '%s\n' "${line:-- 없음}"
  printf '\n## 지표 (진행 중 — 전체는 metrics)\n\n'
  metrics_table "$ROOT/.harness/attempts" "$ROOT/.harness/reviews" | head -n 14 || true
  line="$(git -C "$(code_dir)" status --short 2>&1 | head -n 20 || true)"
  printf '\n## Git (%s)\n\n%s\n' "$(code_dir)" "${line:-(변경 없음)}"
}

cmd_validate() {
  local problems=0 id tf st w r dep other open=0 active=0 s1 s2 max_open max_par intent row t deps scope_txt
  local -A scopes=()
  ok()  { printf '[OK]   %s\n' "$*"; }
  bad() { printf '[FAIL] %s\n' "$*"; problems=$((problems + 1)); }
  if git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then ok "Git 기준 commit"; else bad "Git 기준 commit 없음"; fi
  if spec_approved; then ok "SPEC 승인됨"; else ok "SPEC 미승인 (계획 승인 전 사용자 승인 필요)"; fi
  w="$(pget providers primary_worker)"; r="$(pget providers reviewer)"
  if [[ "$w" != "$r" ]] && is_provider "$w" && is_provider "$r"; then ok "기본 Worker($w) ≠ Reviewer($r)"; else bad "project.yaml Worker/Reviewer 배정 오류 ($w / $r)"; fi
  case "$(pget agents approval_mode ask)" in ask|auto|bypass) ok "approval_mode=$(pget agents approval_mode ask)" ;; *) bad "approval_mode 값 오류" ;; esac
  for t in max_parallel_workers max_open_tasks max_rework ac_timeout_seconds; do
    [[ "$(pget limits "$t" 1)" =~ ^[0-9]+$ ]] || bad "limits.$t는 숫자여야 합니다"
  done
  if worktree_enabled; then ok "Task 작업 공간 분리(worktree) 사용 — 코드: $(code_dir)"
  elif remote_enabled; then ok "원격 모드 — Task를 순서대로 실행 (코드: $(code_dir))"
  else ok "작업 공간 분리 꺼짐 — 코드: $(code_dir)"; fi
  while IFS= read -r id; do
    tf="$ROOT/.harness/tasks/$id.yaml"
    [[ "$(yget "$tf" task_id)" == "$id" ]] || bad "$id: 파일명과 task_id가 다릅니다"
    ! archived_task "$id" || bad "$id: 보관된 Task와 ID가 겹칩니다 (새 번호를 쓴다)"
    [[ -n "$(yget "$tf" milestone_id)" ]] || bad "$id: milestone_id가 없습니다"
    st="$(yget "$tf" status)"
    [[ "$TRANSITIONS" == *">$st "* || "$st" == draft ]] || bad "$id: 알 수 없는 status=$st"
    w="$(yget "$tf" primary_worker)"; r="$(yget "$tf" reviewer)"
    { is_provider "$w" && is_provider "$r" && [[ "$w" != "$r" ]]; } || bad "$id: Worker/Reviewer 오류 ($w / $r)"
    ( task_tier "$tf" worker && task_tier "$tf" reviewer && task_effort "$tf" worker && task_effort "$tf" reviewer ) >/dev/null 2>&1 ||
      bad "$id: 등급·생각 깊이 값 오류"
    ( ylist "$tf" write_scope && ylist "$tf" dependencies ) >/dev/null 2>&1 || bad "$id: write_scope·dependencies는 [a, b] 형식"
    ac_load "$tf"
    [[ -z "$AC_ERR" ]] || bad "$id: $AC_ERR"
    [[ "$st" == completed ]] || open=$((open + 1))
    if [[ "$st" != draft ]]; then
      intent="$(yget "$tf" intent)"
      [[ -n "$intent" && -f "$ROOT/$intent" ]] || bad "$id: intent 파일이 없습니다 (${intent:-미지정})"
      row="$(plan_row "$id")"
      if [[ -z "$row" ]]; then bad "$id: 계획 승인 기록에 없습니다"
      elif [[ "$row" != *"| $(ac_hash "$tf") |"* ]]; then bad "$id: AC가 계획 승인 이후 바뀌었습니다 (approve-plan으로 재승인)"; fi
    fi
    deps="$(ylist "$tf" dependencies 2>/dev/null)" || deps=""
    scope_txt="$(ylist "$tf" write_scope 2>/dev/null)" || scope_txt=""
    if [[ "$st" == ready || "$st" == active ]]; then
      while IFS= read -r dep; do
        [[ -z "$dep" ]] || dep_done "$dep" || bad "$id: 선행 Task $dep가 아직 통합 전입니다"
      done <<<"$deps"
    fi
    if [[ "$st" == active ]]; then
      active=$((active + 1))
      while IFS= read -r s1; do
        [[ -n "$s1" ]] || continue
        for other in "${!scopes[@]}"; do
          while IFS= read -r s2; do
            [[ -z "$s2" ]] || ! overlap "$s1" "$s2" || bad "write_scope 충돌: '$s1'($id) ↔ '$s2'($other)"
          done <<<"${scopes[$other]}"
        done
      done <<<"$scope_txt"
      scopes[$id]="$scope_txt"
    fi
  done < <(task_ids)
  max_open="$(pnum limits max_open_tasks 10)"; max_par="$(pnum limits max_parallel_workers 5)"
  if (( open <= max_open )); then ok "열린 Task $open / $max_open"; else bad "열린 Task 상한 초과: $open > $max_open"; fi
  if (( active <= max_par )); then ok "동시 Worker $active / $max_par"; else bad "동시 Worker 상한 초과: $active > $max_par"; fi
  if (( problems == 0 )); then printf '\nvalidate: 통과\n'; return 0; fi
  printf '\nvalidate: %s개 문제\n' "$problems"
  exit 1
}

cmd_doctor() {
  local c fail=0
  printf 'harness %s (%s)\n' "$HARNESS_VERSION" "$HARNESS_BIN"
  if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then printf '[OK]      bash %s\n' "$BASH_VERSION"
  else printf '[FAIL]    bash %s (4.4 이상 필요)\n' "$BASH_VERSION"; fail=1; fi
  for c in git herdr timeout sha256sum; do
    if command -v "$c" >/dev/null 2>&1; then printf '[OK]      %s\n' "$c"; else printf '[FAIL]    %s 없음\n' "$c"; fail=1; fi
  done
  if git config user.name >/dev/null 2>&1 && git config user.email >/dev/null 2>&1; then printf '[OK]      git user.name/email\n'
  else printf '[FAIL]    git user.name/email 없음 (Harness가 증빙을 commit한다)\n'; fail=1; fi
  for c in $(providers) jq ssh sshfs; do
    if command -v "$c" >/dev/null 2>&1; then printf '[OK]      %s\n' "$c"; else printf '[OPTION]  %s 없음\n' "$c"; fi
  done
  if [[ "${HERDR_ENV:-}" == 1 ]]; then printf '[OK]      Herdr Pane 안\n'; else printf '[INFO]    Herdr Pane 밖 (dispatch·run은 Pane 안에서)\n'; fi
  (( fail == 0 )) || exit 1
}

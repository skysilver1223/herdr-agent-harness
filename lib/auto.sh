# herdr-harness: 자동 진행(run)과 교체 규칙.
# run은 상주하지 않는다. 사람 결정이 필요한 지점·시간 상한·더 진행할 것이 없을 때 끝난다.
# 각 단계는 별도 프로세스의 harness 명령으로 실행하므로 모든 게이트를 그대로 거친다.
# harness.sh가 source한다. 단독 실행하지 않는다.

RUN_LOG=""

run_log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$RUN_LOG"; }

run_child() {  # 하위 명령을 실행하고 결과 한 줄을 로그에 남긴다 → OUT·RC
  harness_child "$@"
  run_log "  $* → $( ((RC == 0)) && echo ok || echo "실패: $(last_line)")"
  return "$RC"
}

last_line() { grep -v '^\[harness\]' <<<"$OUT" | grep -v '^[[:space:]]*$' | tail -n 1; }

reviews_for_attempt() {  # TASK N → 그 attempt를 대상으로 dispatch된 Review 수
  local f c=0
  for f in "$ROOT"/.harness/reviews/"$1"-review-*.harness.md; do
    [[ -f "$f" ]] || continue
    [[ "$(rec_get "$f" '검토 대상')" != "attempt $2 "* ]] || c=$((c + 1))
  done
  printf '%s' "$c"
}

# --------------------------------------------------------------------------
# 교체 규칙 — project.yaml failover.<사유>가 auto일 때만 자동으로 교체한다. 기본은 ask
# (멈추고 사용자에게). Reviewer와 같은 Provider는 건너뛰어 교차 검토를 유지한다.
# --------------------------------------------------------------------------
failover() {  # TASK ROLE REASON DETAIL → 0 자동 교체함, 1 사용자 판단 필요
  local t="$1" role="$2" reason="$3" detail="$4" tf cur other next p k max n hand cwd
  [[ "$(pget failover "$reason" ask)" == auto ]] || return 1
  tf="$(task_file "$t")"
  max="$(pnum failover max_per_task 1)"
  k="$(grep -l '^- 자동 교체: yes' "$ROOT"/.harness/handovers/"$t"-handover-*.md 2>/dev/null | wc -l)"
  (( k < max )) || return 1
  if [[ "$role" == worker ]]; then cur="$(yget "$tf" primary_worker)"; other="$(yget "$tf" reviewer)"
  else cur="$(yget "$tf" reviewer)"; other="$(yget "$tf" primary_worker)"; fi
  next=""
  for p in $(pget providers fallback_chain | tr -d '[],'); do
    if [[ "$p" != "$cur" && "$p" != "$other" ]] && is_provider "$p"; then next="$p"; break; fi
  done
  [[ -n "$next" ]] || return 1
  harness_child close "$t" "$role" --force
  n=$(( $(last_n "$ROOT/.harness/handovers" "$t-handover-" .md) + 1 ))
  hand="$ROOT/.harness/handovers/$t-handover-$n.md"
  cwd="$(task_cwd "$t")"
  mkdir -p "$(dirname "$hand")"
  {
    printf '# Handover: %s-handover-%s (자동)\n\n- 자동 교체: yes\n- 일시: %s\n- 역할: %s\n- 사유: %s %s\n- 원작업자: %s → 대상: %s\n\n' \
      "$t" "$n" "$(now)" "$role" "$reason" "$detail" "$cur" "$next"
    printf '## 작업 공간 상태 (%s)\n\n```text\n%s\n```\n\n' "$cwd" "$(git -C "$cwd" status --short 2>/dev/null || true)"
    printf '## 다음 한 단계\n\n%s가 같은 작업 공간에서 이어서 수행한다. 직전 Harness 증빙과 보고서를 먼저 읽는다.\n' "$next"
  } >"$hand"
  if [[ "$role" == worker ]]; then
    if [[ "$(yget "$tf" status)" == active ]]; then
      harness_child transition "$t" handover_required; (( RC == 0 )) || return 1
    fi
    set_field "$tf" primary_worker "$next"
    harness_child transition "$t" ready; (( RC == 0 )) || return 1
  else
    set_field "$tf" reviewer "$next"
  fi
  commit_harness "$t 자동 교체 $cur → $next ($reason)"
  run_log "  자동 교체: $t $role $cur → $next ($reason)"
  return 0
}

hold() {  # TASK REASON — 이 Task는 사용자 판단 전까지 건너뛴다
  STEP_STOP="$2"
  run_log "  보류: $1 — $2"
}

on_agent_failure() {  # TASK ROLE REASON DETAIL
  if failover "$1" "$2" "$3" "$4"; then STEP_PROGRESS=1
  else hold "$1" "$2 $3 ${4:-} — 교체 규칙이 없어 사용자 승인 필요 (project.yaml failover)"; fi
}

step_worker() {
  local t="$1" meta res report n
  meta="$(meta_file "$t" worker)"
  if [[ ! -f "$meta" ]] || grep -q '^closed=' "$meta"; then
    if run_child dispatch "$t" worker; then
      STEP_PROGRESS=1; STEP_RUNNING=1
      if grep -q '^quota_signal=' <<<"$OUT"; then on_agent_failure "$t" worker quota_exhausted "$(sed -n 's/^quota_signal=//p' <<<"$OUT")"; fi
    else
      res="$(sed -n 's/^dispatch_result=//p' <<<"$OUT")"
      if [[ -z "$res" ]]; then hold "$t" "$(last_line)"; else on_agent_failure "$t" worker agent_error "$res"; fi
    fi
    return 0
  fi
  run_child observe "$t" worker || { hold "$t" "$(last_line)"; return 0; }
  res="$(sed -n 's/^observe_result=//p' <<<"$OUT")"
  if grep -q '^quota_signal=' <<<"$OUT"; then on_agent_failure "$t" worker quota_exhausted "$(sed -n 's/^quota_signal=//p' <<<"$OUT")"; return 0; fi
  case "$res" in
    running) STEP_RUNNING=1 ;;
    settled)
      run_child close "$t" worker || { hold "$t" "$(last_line)"; return 0; }
      n="$(last_attempt "$t")"; report="$(att_report "$t" "$n")"
      if [[ ! -s "$report" ]]; then hold "$t" "Worker가 보고서 없이 끝났습니다 (막힘 여부를 로그로 확인: $(rel "$(meta_get "$meta" log)"))"; return 0; fi
      if grep -q '결과: BLOCKED' "$report"; then hold "$t" "Worker가 BLOCKED를 보고했습니다: $(rel "$report")"; return 0; fi
      STEP_PROGRESS=1
      if run_child transition "$t" submitted; then
        run_child transition "$t" reviewing || { hold "$t" "$(last_line)"; return 0; }
        if run_child dispatch "$t" reviewer; then STEP_RUNNING=1
        else on_agent_failure "$t" reviewer agent_error "$(sed -n 's/^dispatch_result=//p' <<<"$OUT")"; fi
      elif ! grep -Eq 'AC 검증 실패|AC 결과가 빠졌습니다' <<<"$OUT"; then
        hold "$t" "$(last_line)"
      fi ;;   # AC 실패는 증빙이 남았고 다음 순회에서 새 attempt를 띄운다(상한은 dispatch가 강제)
    blocked) hold "$t" "Worker가 입력을 기다립니다 (blocked) — Pane에서 확인" ;;
    agent_lost) on_agent_failure "$t" worker agent_error agent_lost ;;
    *) hold "$t" "Worker 상태 $res — 확인 필요" ;;
  esac
  return 0
}

apply_verdict() {
  local t="$1" r v n
  r="$(last_review "$t")"; v="$(review_verdict "$(rev_file "$t" "$r")")"
  case "$v" in
    APPROVED)
      if run_child transition "$t" awaiting_approval; then STEP_PROGRESS=1
      elif grep -Eq '^- 통합: (CONFLICT|FAIL)' "$(rev_record "$t" "$r")"; then
        run_child transition "$t" changes_requested && STEP_PROGRESS=1 || hold "$t" "$(last_line)"
      else
        n="$(last_attempt "$t")"
        if (( $(reviews_for_attempt "$t" "$n") < 2 )); then
          run_child dispatch "$t" reviewer && { STEP_PROGRESS=1; STEP_RUNNING=1; } || hold "$t" "$(last_line)"
        else hold "$t" "Review가 게이트를 통과하지 못했습니다: $(last_line)"; fi
      fi ;;
    CHANGES_REQUESTED) run_child transition "$t" changes_requested && STEP_PROGRESS=1 || hold "$t" "$(last_line)" ;;
    *) hold "$t" "Review 판정을 읽을 수 없습니다: $(rel "$(rev_file "$t" "$r")")" ;;
  esac
  return 0
}

step_reviewer() {
  local t="$1" meta res r n
  meta="$(meta_file "$t" reviewer)"
  if [[ ! -f "$meta" ]] || grep -q '^closed=' "$meta"; then
    r="$(last_review "$t")"; n="$(last_attempt "$t")"
    # 끝난 Review가 최신 attempt 대상이면 판정을 반영하고, 아니면 Reviewer를 띄운다.
    if (( r > 0 )) && [[ "$(rec_last "$(rev_record "$t" "$r")" 결과)" == settled && "$(review_target "$(rev_file "$t" "$r")")" == "$n" ]]; then
      apply_verdict "$t"; return 0
    fi
    if (( $(reviews_for_attempt "$t" "$n") >= 2 )); then hold "$t" "Reviewer가 두 번 판정을 남기지 못했습니다"; return 0; fi
    if run_child dispatch "$t" reviewer; then STEP_PROGRESS=1; STEP_RUNNING=1
    else on_agent_failure "$t" reviewer agent_error "$(sed -n 's/^dispatch_result=//p' <<<"$OUT")"; fi
    return 0
  fi
  run_child observe "$t" reviewer || { hold "$t" "$(last_line)"; return 0; }
  res="$(sed -n 's/^observe_result=//p' <<<"$OUT")"
  if grep -q '^quota_signal=' <<<"$OUT"; then on_agent_failure "$t" reviewer quota_exhausted "$(sed -n 's/^quota_signal=//p' <<<"$OUT")"; return 0; fi
  case "$res" in
    running) STEP_RUNNING=1 ;;
    settled) run_child close "$t" reviewer || { hold "$t" "$(last_line)"; return 0; }; apply_verdict "$t" ;;
    blocked) hold "$t" "Reviewer가 입력을 기다립니다 (blocked)" ;;
    agent_lost) on_agent_failure "$t" reviewer agent_error agent_lost ;;
    *) hold "$t" "Reviewer 상태 $res — 확인 필요" ;;
  esac
  return 0
}

step_task() {  # TASK → STEP_PROGRESS STEP_RUNNING STEP_STOP STEP_WAIT
  local t="$1" st
  STEP_PROGRESS=0; STEP_RUNNING=0; STEP_STOP=""; STEP_WAIT=""
  st="$(yget "$ROOT/.harness/tasks/$t.yaml" status)"
  case "$st" in
    ready)
      # 착수 실패(선행 Task·동시 상한·범위 충돌)는 다른 Task가 진행되면 풀리므로 대기로 둔다.
      if run_child transition "$t" active; then STEP_PROGRESS=1; else STEP_WAIT="$t: $(last_line)"; fi ;;
    active) step_worker "$t" ;;
    submitted) run_child transition "$t" reviewing && STEP_PROGRESS=1 || hold "$t" "$(last_line)" ;;
    reviewing) step_reviewer "$t" ;;
    changes_requested) run_child transition "$t" ready && STEP_PROGRESS=1 || hold "$t" "$(last_line)" ;;
    blocked|handover_required) hold "$t" "$st — 사용자 판단 필요" ;;
    draft) hold "$t" "draft — 계획 승인 필요" ;;
  esac
  return 0
}

cmd_run() {
  local m="${1:-}" max_min poll=30 in_pane=0 lock deadline result="" progressed running t st
  local -a tasks=() waits=()
  local -A held=()
  [[ -n "$m" ]] || die "사용법: run MILESTONE [--max-minutes N] [--poll SEC] [--in-pane]"
  need_id "$m"; shift
  max_min="$(pnum limits run_max_minutes 240)"
  while (( $# )); do
    case "$1" in
      --max-minutes) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "--max-minutes에는 분이 필요합니다."; max_min="$2"; shift 2 ;;
      --poll) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "--poll에는 초가 필요합니다."; poll="$2"; shift 2 ;;
      --in-pane) in_pane=1; shift ;;
      *) die "알 수 없는 run 옵션: $1" ;;
    esac
  done
  require_human run
  command -v herdr >/dev/null 2>&1 || die "herdr 명령이 없습니다."
  [[ "${HERDR_ENV:-}" == 1 ]] || die "run은 Herdr Pane 안(HERDR_ENV=1)에서 실행한다."
  mapfile -t tasks < <(milestone_tasks "$m")
  (( ${#tasks[@]} > 0 )) || die "$m에 속한 Task가 없습니다."
  [[ -f "$(plan_file "$m")" ]] || die "$m 계획이 승인되지 않았습니다 (approve-plan $m --confirm-user-approval)."

  if (( in_pane )); then
    # Orchestrator의 도구 실행 시간 제한을 피해 별도 Pane에서 돌린다.
    hcap herdr pane split --current --direction down --cwd "$ROOT" --no-focus
    (( RC == 0 )) || die "herdr pane split 실패: $OUT"
    t="$(jfield "$OUT" pane_id)"
    herdr pane run "$t" "$(printf '%q ' bash "$HARNESS_BIN" -C "$ROOT" run "$m" --max-minutes "$max_min" --poll "$poll")" >/dev/null ||
      die "Pane $t에서 run을 시작하지 못했습니다."
    info "자동 진행을 Pane $t에서 시작했습니다. 확인: status · 로그: .harness/runtime/run-$m.log"
    return 0
  fi

  mkdir -p "$ROOT/.harness/runtime"
  lock="$ROOT/.harness/runtime/run-$m.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    if kill -0 "$(cat "$lock/pid" 2>/dev/null || echo 0)" 2>/dev/null; then die "$m 자동 진행이 이미 실행 중입니다 (pid $(cat "$lock/pid"))."; fi
    rm -rf -- "$lock"; mkdir "$lock"
  fi
  printf '%s\n' "$$" >"$lock/pid"
  trap 'rm -rf -- "'"$lock"'"; rm -f -- ${TMP_FILES[@]+"${TMP_FILES[@]}"}' EXIT
  RUN_LOG="$ROOT/.harness/runtime/run-$m.log"
  deadline=$(( $(date +%s) + max_min * 60 ))
  run_log "run $m 시작 (Task ${#tasks[@]}개, 상한 ${max_min}분)"

  while :; do
    progressed=0; running=0; waits=()
    for t in "${tasks[@]}"; do
      [[ -z "${held[$t]:-}" ]] || continue
      step_task "$t"
      (( STEP_PROGRESS == 0 )) || progressed=1
      (( STEP_RUNNING == 0 )) || running=$((running + 1))
      [[ -z "$STEP_WAIT" ]] || waits+=("$STEP_WAIT")
      [[ -z "$STEP_STOP" ]] || held[$t]="$STEP_STOP"
    done
    result=milestone_ready
    for t in "${tasks[@]}"; do
      st="$(yget "$ROOT/.harness/tasks/$t.yaml" status)"
      [[ "$st" == awaiting_approval || "$st" == completed ]] || { result=""; break; }
    done
    [[ -z "$result" ]] || break
    if (( $(date +%s) >= deadline )); then result=time_limit; break; fi
    if (( progressed == 0 && running == 0 )); then
      if (( ${#held[@]} > 0 )); then result=user_needed; else result=stuck; fi
      break
    fi
    (( progressed )) || nap "$poll"
  done

  run_log "run $m 종료: $result"
  printf '\n## %s 자동 진행 결과: %s\n\n' "$m" "$result"
  for t in "${tasks[@]}"; do
    printf -- '- %s: %s%s\n' "$t" "$(yget "$ROOT/.harness/tasks/$t.yaml" status)" "${held[$t]:+ — ${held[$t]}}"
  done
  (( ${#waits[@]} == 0 )) || printf '\n착수 대기:\n%s\n' "$(printf -- '- %s\n' "${waits[@]}")"
  case "$result" in
    milestone_ready) printf '\n다음: 사용자가 결과를 확인하고 승인하면 approve %s --confirm-user-approval\n' "$m" ;;
    user_needed) printf '\n다음: 위 보류 사유를 사용자와 해결한 뒤 run %s를 다시 실행한다.\n' "$m" ;;
    time_limit) printf '\n다음: 진행 중인 Agent는 그대로 둔다. run %s를 다시 실행하면 이어서 진행한다.\n' "$m" ;;
    stuck) printf '\n다음: 진행할 수 있는 Task가 없습니다. status로 원인을 확인한다.\n' ;;
  esac
  printf '%s %s\n' "$(now)" "$result" >"$ROOT/.harness/runtime/run-$m.result"
  printf 'run_result=%s\n' "$result"
}

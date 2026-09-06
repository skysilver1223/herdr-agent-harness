# Part of herdr-harness. Sourced by harness.sh — do not run directly.

# ---------------------------------------------------------------------------
# quota-retry — opt-in. 연속 저쿼터가 확인되면 Provider를 fallback_chain의
# 다음 값으로 바꾸고 handover_required까지 자동 전이한다. 거기서 멈춘다:
# ready로 재개하려면 사람이 .harness/decisions/TASK-failover-approval.md에
# "승인: yes"를 쓴 뒤 herdr-harness transition을 직접 실행해야 한다.
# cmd_transition/cmd_close_agent를 그대로 호출하므로 두 함수의 모든
# 전제조건(예: submitted에 필요한 Attempt/Evidence, working Agent 보호)을
# 그대로 물려받는다 — 이 함수는 재구현하지 않는다.
# ---------------------------------------------------------------------------

cmd_quota_retry() {
  local path="${1:-}" task_id="${2:-}" role="${3:-}"
  [[ -n "$path" && -n "$task_id" && -n "$role" && $# -eq 3 ]] ||
    die "사용법: quota-retry PATH TASK_ID ROLE(worker|reviewer)"
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"

  local root task_file policy_file
  root="$(project_root "$path")"
  task_file="$root/.harness/tasks/$task_id.yaml"
  [[ -f "$task_file" ]] || die "Task YAML을 찾을 수 없습니다: $task_file"

  policy_file="$root/.harness/policies/quota-policy.yaml"
  [[ -f "$policy_file" ]] || die "quota-policy.yaml이 없습니다: $policy_file"
  local automatic_failover
  automatic_failover="$(_runtime_yaml_scalar "$policy_file" automatic_failover)"
  [[ "$automatic_failover" == "true" ]] ||
    die "automatic_failover가 꺼져 있습니다(.harness/policies/quota-policy.yaml). quota-retry는 opt-in 기능입니다."

  local task_status
  task_status="$(yaml_scalar "$task_file" status)"
  [[ "$task_status" == active ]] ||
    die "Task 상태가 active가 아닙니다(현재 $task_status). quota-retry는 active Task에만 적용됩니다."

  local used_marker="$root/.harness/runtime/$task_id-$role.auto-retry-used"
  [[ ! -f "$used_marker" ]] ||
    die "이 Task/Role에는 이미 자동 재시도를 1회 사용했습니다(flapping 방지). handover_required로 전이한 뒤 사람이 직접 처리하세요: $used_marker"

  local confirm_needed=2 cooldown=300 stale_seconds=600 configured
  configured="$(_runtime_yaml_scalar "$policy_file" low_confirm_count)"
  [[ "$configured" =~ ^[0-9]+$ ]] && confirm_needed="$configured"
  configured="$(_runtime_yaml_scalar "$policy_file" cooldown_seconds)"
  [[ "$configured" =~ ^[0-9]+$ ]] && cooldown="$configured"
  configured="$(_runtime_yaml_scalar "$policy_file" stale_lock_seconds)"
  [[ "$configured" =~ ^[0-9]+$ ]] && stale_seconds="$configured"

  local streak_file="$root/.harness/runtime/$task_id-$role.quota-streak"
  [[ -f "$streak_file" ]] ||
    die "연속 저쿼터 기록이 없습니다. 먼저 herdr-harness quota-check PATH $task_id $role 을 실행하세요: $streak_file"
  local streak_count last_low_at first_low_at
  streak_count="$(_runtime_meta_value "$streak_file" count)"
  last_low_at="$(_runtime_meta_value "$streak_file" last_low_at)"
  first_low_at="$(_runtime_meta_value "$streak_file" first_low_at)"
  [[ "$streak_count" =~ ^[0-9]+$ ]] || streak_count=0
  (( streak_count >= confirm_needed )) ||
    die "연속 저쿼터 판정이 부족합니다($streak_count/$confirm_needed). quota-check를 다시 실행해 확인하세요."
  if [[ -n "$first_low_at" && -n "$last_low_at" ]]; then
    local first_epoch last_epoch
    first_epoch="$(date -u -d "$first_low_at" +%s 2>/dev/null || printf 0)"
    last_epoch="$(date -u -d "$last_low_at" +%s 2>/dev/null || printf 0)"
    (( last_epoch - first_epoch >= cooldown )) ||
      die "연속 저쿼터 판정 간격이 cooldown(${cooldown}초)보다 짧습니다. 시간을 두고 quota-check를 다시 실행하세요."
  fi

  local token
  token="$(_runtime_lock_acquire "$root" "$task_id" quota-retry "$stale_seconds")" ||
    die "Task Lock 획득에 실패했습니다: $task_id"
  trap "_runtime_lock_release '$root' '$task_id' '$token'" EXIT INT TERM

  append_event "$root" quota_retry_start "$task_id" "$task_status" "" "role=$role"

  cmd_close_agent "$root" "$task_id" "$role" --force

  local role_key current_provider next_provider
  if [[ "$role" == worker ]]; then role_key=primary_worker; else role_key=reviewer; fi
  current_provider="$(_runtime_yaml_scalar "$task_file" "$role_key")"
  next_provider="$(_runtime_next_fallback_provider "$task_file" "$current_provider")" ||
    die "Task의 fallback_chain에서 다음 Provider를 찾지 못했습니다: $task_file"

  _runtime_set_task_provider "$task_file" "$role_key" "$next_provider"

  # handover_required 진입 게이트(cmd_transition)가 Handover 문서를 요구한다.
  # harness-handover §3의 "문서 작성 → 전이" 순서대로, 전이 직전에 stub을 남긴다.
  # (자동 경로가 인계 문맥 없이 원작업자를 종료하던 결함 — BACKLOG 9-3-3)
  local handover_n=1 existing hb_num handover_file
  shopt -s nullglob
  for existing in "$root/.harness/handovers/$task_id-handover-"*.md; do
    hb_num="${existing##*-handover-}"; hb_num="${hb_num%.md}"
    [[ "$hb_num" =~ ^[0-9]+$ ]] && (( hb_num >= handover_n )) && handover_n=$(( hb_num + 1 ))
  done
  shopt -u nullglob
  handover_file="$root/.harness/handovers/$task_id-handover-$handover_n.md"
  {
    printf '# Handover: %s-handover-%s\n\n' "$task_id" "$handover_n"
    printf '## 메타데이터\n'
    printf -- '- Task ID: %s\n- Handover 번호: %s\n- 인계 일시: %s\n' \
      "$task_id" "$handover_n" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- 원작업자 (Source): %s\n- 수신자 (Target): %s\n- 인계 사유: quota_exhausted\n\n' \
      "$current_provider" "$next_provider"
    printf '`quota-retry`가 자동 생성한 stub이다. 연속 저쿼터 확인(count>=%s) 후 %s(%s) Provider를 %s → %s로 교체했다. 세부 내용은 사람이 %s 규격에 맞춰 보완한다.\n\n' \
      "$confirm_needed" "$task_id" "$role" "$current_provider" "$next_provider" ".harness/handovers/TEMPLATE.md"
    printf '## 2. 미완료 작업 및 작업 트리 상태 (Pending Work & Git State)\n\n- `git status --short`:\n```text\n'
    git -C "$root" status --short 2>&1 || true
    printf '```\n- `git diff --stat`:\n```text\n'
    git -C "$root" diff --stat 2>&1 || true
    printf '```\n\n## 5. 다음 담당자를 위한 즉각적 행동 지침 (Next Single Action)\n\n'
    printf '사람이 `.harness/decisions/%s-failover-approval.md`에 "승인: yes"를 기록한 뒤 `herdr-harness transition %s %s ready`를 직접 실행한다. 그 전까지 재개하지 않는다.\n' \
      "$task_id" "$path" "$task_id"
  } >"$handover_file"
  chmod 0644 "$handover_file"

  cmd_transition "$root" "$task_id" handover_required --note "quota-retry: $current_provider -> $next_provider (handover $handover_n)"

  _runtime_atomic_text "$used_marker" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  rm -f -- "$streak_file"

  append_event "$root" quota_retry_done "$task_id" "$task_status" handover_required "provider $current_provider -> $next_provider"

  printf 'quota_retry: %s(%s) provider %s -> %s, 상태 handover_required (handover stub: %s)\n' \
    "$task_id" "$role" "$current_provider" "$next_provider" "${handover_file#"$root/"}"
  printf '다음 단계(사람 몫): handover stub을 확인·보완하고, .harness/decisions/%s-failover-approval.md 에 "승인: yes"를 쓴 뒤 herdr-harness transition %s %s ready 를 직접 실행하세요.\n' \
    "$task_id" "$path" "$task_id"
}

# ---------------------------------------------------------------------------
# auto-step — opt-in. 유한 턴(정책 상한 이하) 동안만 동작하는 스텝 실행기다.
# 상주 루프가 아니다: 호출 1회가 반드시 끝난다. Turn 1에서만 dispatch로
# Pane 하나를 새로 만들고, 이후 턴은 그 같은 Agent를 observe로만 재조회한다
# (dispatch를 반복하면 매번 새 Pane이 생겨 이전 Pane이 고아가 된다 — 그래서
# 반복하지 않는다). settled/blocked/agent_lost/error 중 하나에 도달하면
# 판단을 사람에게 넘기고 즉시 멈춘다. reviewing·awaiting_approval·completed
# 로 이어지는 호출은 이 함수 안에 존재하지 않는다.
# ---------------------------------------------------------------------------

cmd_auto_step() {
  local path="${1:-}" task_id="${2:-}" max_turns=0
  [[ -n "$path" && -n "$task_id" ]] || die "사용법: auto-step PATH TASK_ID [--max-turns N]"
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-turns)
        [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--max-turns에는 양의 정수가 필요합니다."
        max_turns="$2"; shift 2 ;;
      *) die "알 수 없는 auto-step 옵션: $1" ;;
    esac
  done
  _runtime_require_id "$task_id"

  local root task_file policy_file
  root="$(project_root "$path")"
  task_file="$root/.harness/tasks/$task_id.yaml"
  [[ -f "$task_file" ]] || die "Task YAML을 찾을 수 없습니다: $task_file"

  policy_file="$root/.harness/policies/loop-policy.yaml"
  [[ -f "$policy_file" ]] || die "loop-policy.yaml이 없습니다: $policy_file"
  local enabled
  enabled="$(_runtime_yaml_scalar "$policy_file" enabled)"
  [[ "$enabled" == "true" ]] ||
    die "auto-step가 꺼져 있습니다(.harness/policies/loop-policy.yaml). opt-in 기능입니다."

  local ceiling=5 stale_seconds=600 configured
  configured="$(_runtime_yaml_scalar "$policy_file" max_turns_ceiling)"
  [[ "$configured" =~ ^[0-9]+$ ]] && ceiling="$configured"
  configured="$(_runtime_yaml_scalar "$policy_file" stale_lock_seconds)"
  [[ "$configured" =~ ^[0-9]+$ ]] && stale_seconds="$configured"
  [[ "$max_turns" -gt 0 ]] || max_turns="$ceiling"
  (( max_turns <= ceiling )) ||
    die "--max-turns($max_turns)이 정책 상한(max_turns_ceiling=$ceiling)을 넘었습니다."

  local task_status
  task_status="$(yaml_scalar "$task_file" status)"
  case "$task_status" in
    ready|active) ;;
    *) die "Task 상태가 ready/active가 아닙니다(현재 $task_status). auto-step은 이 두 상태에서만 동작합니다." ;;
  esac

  local token
  token="$(_runtime_lock_acquire "$root" "$task_id" auto-step "$stale_seconds")" ||
    die "Task Lock 획득에 실패했습니다: $task_id"
  trap "_runtime_lock_release '$root' '$task_id' '$token'" EXIT INT TERM

  if [[ "$task_status" == ready ]]; then
    cmd_transition "$root" "$task_id" active --note "auto-step"
  fi

  local turn=1 result
  set +e
  result="$(cmd_dispatch "$root" "$task_id" worker)"
  set -e
  result="${result#*dispatch_result=}"
  append_event "$root" auto_step_turn "$task_id" active "$result" "turn=$turn/$max_turns action=dispatch"

  local continue_states=" stalled timeout "
  while :; do
    if [[ "$continue_states" != *" $result "* ]]; then
      printf 'auto_step: turn=%s result=%s — 정지(사람 확인 필요)\n' "$turn" "$result"
      return 0
    fi
    if (( turn >= max_turns )); then
      printf 'auto_step: max_turns(%s) 소진, 마지막 result=%s — 정지\n' "$max_turns" "$result"
      return 0
    fi
    turn=$((turn + 1))
    set +e
    result="$(cmd_observe "$root" "$task_id" worker)"
    set -e
    result="${result#*observe_result=}"
    append_event "$root" auto_step_turn "$task_id" active "$result" "turn=$turn/$max_turns action=observe"
  done
}

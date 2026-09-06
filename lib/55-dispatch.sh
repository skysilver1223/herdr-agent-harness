# Part of herdr-harness. Sourced by harness.sh — do not run directly.


cmd_dispatch() {
  local path="${1:-}" task_id="${2:-}" role="${3:-}" timeout=120000
  [[ -n "$path" && -n "$task_id" && -n "$role" ]] || die "사용법: dispatch PATH TASK_ID ROLE(worker|reviewer) [--timeout MS]"
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--timeout에는 양의 밀리초가 필요합니다."; timeout="$2"; shift 2 ;;
      *) die "알 수 없는 dispatch 옵션: $1" ;;
    esac
  done
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"

  local root task_file runtime_dir context provider attempt started_at baseline
  local pane_output pane_status pane_id agent_name start_output start_status
  local prompt_output prompt_status get_output get_status read_output read_status result
  local attempt_file evidence_file temporary
  root="$(project_root "$path")"
  task_file="$root/.harness/tasks/$task_id.yaml"
  [[ -f "$task_file" ]] || die "Task YAML을 찾을 수 없습니다: $task_file"
  command -v herdr >/dev/null 2>&1 || die "herdr 명령을 찾을 수 없습니다."
  [[ "${HERDR_ENV:-}" == 1 ]] || die "dispatch는 Herdr Pane 안에서 실행해야 합니다."
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Git 저장소가 아닙니다: $root"

  runtime_dir="$root/.harness/runtime"
  mkdir -p "$runtime_dir" "$root/.harness/attempts" "$root/.harness/evidence"
  context="$runtime_dir/$task_id-context-$role.md"
  if ! _runtime_context_packet "$root" "$task_id" "$role" "$task_file" "$context"; then
    _runtime_write_result "$root" "$task_id" "$role" error
    printf '경고: Context Packet에서 Secret 의심 패턴이 발견되어 저장하거나 전송하지 않았습니다.\n' >&2
    printf 'dispatch_result=error\n'
    return 1
  fi

  if [[ "$role" == worker ]]; then
    provider="$(_runtime_yaml_scalar "$task_file" primary_worker)"
  else
    provider="$(_runtime_yaml_scalar "$task_file" reviewer)"
  fi
  [[ "$provider" =~ ^(claude|codex|agy)$ ]] || die "Task의 Provider가 유효하지 않습니다: $provider"
  attempt="$(_runtime_next_attempt "$root" "$task_id")"
  started_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  baseline="$(git -C "$root" rev-parse HEAD 2>/dev/null || printf 'unborn')"
  local task_slug="${task_id,,}"
  agent_name="hh-${task_slug//[^a-z0-9_-]/-}-${role:0:1}-$attempt"
  agent_name="${agent_name:0:32}"
  [[ "$agent_name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "생성된 Agent 이름이 유효하지 않습니다: $agent_name"

  set +e
  pane_output="$(herdr pane split --current --direction right --cwd "$root" --no-focus 2>&1)"
  pane_status=$?
  set -e
  if (( pane_status != 0 )); then
    _runtime_write_result "$root" "$task_id" "$role" error
    printf '%s\n' "$pane_output" >&2
    printf 'dispatch_result=error\n'
    return 1
  fi
  pane_id="$(_runtime_json_field "$pane_output" pane_id)"
  [[ -n "$pane_id" ]] || die "Herdr Pane ID를 추출하지 못했습니다."

  _runtime_write_meta "$root" "$task_id" "$role" "$agent_name" "$pane_id" "$provider" "$attempt"
  attempt_file="$root/.harness/attempts/$task_id-attempt-$attempt.md"
  temporary="$(mktemp "$root/.harness/attempts/.attempt.XXXXXX")"
  {
    printf '# Attempt %s: %s\n\n' "$attempt" "$task_id"
    printf -- '- Started: %s\n- Role: %s\n- Provider: %s\n- Pane ID: %s\n- Agent name: %s\n- Baseline commit: %s\n' "$started_at" "$role" "$provider" "$pane_id" "$agent_name" "$baseline"
  } >"$temporary"
  _runtime_atomic_copy "$temporary" "$attempt_file"
  rm -f -- "$temporary"

  set +e
  start_output="$(_runtime_start_agent_when_ready "$agent_name" "$provider" "$pane_id" "$timeout")"
  start_status=$?
  set -e
  if (( start_status != 0 )); then
    result=error
    get_output=""
    get_status=1
    prompt_output="$start_output"
    prompt_status="$start_status"
    read_output=""
    read_status=1
  else
    set +e
    prompt_output="$(herdr agent prompt "$agent_name" "$(cat "$context")" --wait --timeout "$timeout" 2>&1)"
    prompt_status=$?
    get_output="$(herdr agent get "$agent_name" 2>&1)"
    get_status=$?
    read_output="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 200 2>&1)"
    read_status=$?
    set -e
    result="$(_runtime_normalize_state "$get_status" "$get_output" "$prompt_status" "$prompt_output")"
  fi

  local quota_signal
  quota_signal="$(_runtime_scan_quota_signal "$prompt_output"$'\n'"$read_output" || true)"

  evidence_file="$root/.harness/evidence/$task_id-$role-attempt-$attempt.md"
  temporary="$(mktemp "$root/.harness/evidence/.capture.XXXXXX")"
  {
    printf '# Evidence: %s / %s / Attempt %s\n\n' "$task_id" "$role" "$attempt"
    printf -- '- Captured: %s\n- Dispatch result: %s\n- Prompt exit: %s\n- Agent get exit: %s\n- Agent read exit: %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$result" "$prompt_status" "$get_status" "$read_status"
    printf '## Git status --short\n\n'
    git -C "$root" status --short 2>&1 || true
    printf '\n## Git diff --stat\n\n'
    git -C "$root" diff --stat 2>&1 || true
    printf '\n## Agent state\n\n%s\n' "$get_output"
    printf '\n## Dispatch 명령 출력\n\n%s\n' "$prompt_output"
    printf '\n## Agent output\n\n%s\n' "$read_output"
    if [[ -n "$quota_signal" ]]; then
      printf '\n## 쿼터 신호(자동 감지 — 확정 아님)\n\n%s\n\n실패로 확정되지 않았으므로 이 신호만으로 Provider를 바꾸지 않는다. `herdr-harness quota-check`로 확인 후 판단한다.\n' "$quota_signal"
    fi
  } >"$temporary"
  if _runtime_has_secret "$temporary"; then
    : >"$temporary"
    printf '# Evidence withheld\n\n경고: Secret 의심 패턴이 발견되어 원문을 저장하지 않았습니다.\n' >"$temporary"
    printf '경고: Agent 출력에서 Secret 의심 패턴이 발견되어 Evidence 원문을 저장하지 않았습니다.\n' >&2
  fi
  _runtime_atomic_copy "$temporary" "$evidence_file"
  rm -f -- "$temporary"
  _runtime_write_result "$root" "$task_id" "$role" "$result"
  printf 'dispatch_result=%s\n' "$result"
  [[ "$result" == settled || "$result" == blocked ]]
}

cmd_observe() {
  local path="${1:-}" task_id="${2:-}" role="${3:-worker}"
  [[ -n "$path" && -n "$task_id" ]] || die "사용법: observe PATH TASK_ID [ROLE]"
  [[ $# -le 3 ]] || die "사용법: observe PATH TASK_ID [ROLE]"
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"
  local root meta agent_name pane_id attempt evidence addition get_output get_status read_output read_status result
  root="$(project_root "$path")"
  meta="$root/.harness/runtime/$task_id-$role.meta"
  [[ -f "$meta" ]] || die "Runtime 기록을 찾을 수 없습니다: $meta"
  agent_name="$(_runtime_meta_value "$meta" agent_name)"
  pane_id="$(_runtime_meta_value "$meta" pane_id)"
  attempt="$(_runtime_meta_value "$meta" attempt)"
  [[ -n "$agent_name" && -n "$pane_id" && "$attempt" =~ ^[0-9]+$ ]] || die "Runtime 기록이 손상되었습니다: $meta"
  set +e
  get_output="$(herdr agent get "$agent_name" 2>&1)"
  get_status=$?
  read_output="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 200 2>&1)"
  read_status=$?
  set -e
  result="$(_runtime_normalize_state "$get_status" "$get_output" 0 "")"
  local quota_signal
  quota_signal="$(_runtime_scan_quota_signal "$read_output" || true)"
  evidence="$root/.harness/evidence/$task_id-$role-attempt-$attempt.md"
  addition="$(mktemp "$root/.harness/evidence/.observe.XXXXXX")"
  {
    printf '\n## Observation %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Result: %s\n- Pane ID: %s\n- Agent get exit: %s\n- Agent read exit: %s\n\n' "$result" "$pane_id" "$get_status" "$read_status"
    printf '### Agent state\n\n%s\n\n### Agent output\n\n%s\n' "$get_output" "$read_output"
    if [[ -n "$quota_signal" ]]; then
      printf '\n### 쿼터 신호(자동 감지 — 확정 아님)\n\n%s\n' "$quota_signal"
    fi
  } >"$addition"
  _runtime_append_evidence "$evidence" "$addition"
  rm -f -- "$addition"
  _runtime_write_result "$root" "$task_id" "$role" "$result"
  printf 'observe_result=%s\n' "$result"
}

cmd_close_agent() {
  local path="${1:-}" task_id="${2:-}" role=worker force=0
  [[ -n "$path" && -n "$task_id" ]] || die "사용법: close-agent PATH TASK_ID [ROLE] [--force]"
  shift 2
  if [[ $# -gt 0 && "$1" != --force ]]; then role="$1"; shift; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in --force) force=1 ;; *) die "알 수 없는 close-agent 옵션: $1" ;; esac
    shift
  done
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"
  local root meta agent_name pane_id get_output get_status state close_output close_status
  root="$(project_root "$path")"
  meta="$root/.harness/runtime/$task_id-$role.meta"
  [[ -f "$meta" ]] || die "Harness Runtime 기록이 없어 Pane 정리를 거부합니다: $meta"
  agent_name="$(_runtime_meta_value "$meta" agent_name)"
  pane_id="$(_runtime_meta_value "$meta" pane_id)"
  [[ -n "$agent_name" && -n "$pane_id" ]] || die "Runtime 기록이 손상되었습니다: $meta"
  set +e
  get_output="$(herdr agent get "$agent_name" 2>&1)"
  get_status=$?
  set -e
  if (( get_status == 0 )); then
    state="$(_runtime_json_field "$get_output" agent_status)"
    [[ "$state" != working || "$force" -eq 1 ]] || die "Agent가 working 상태입니다. --force 없이는 닫지 않습니다: $agent_name"
  fi
  set +e
  close_output="$(herdr pane close "$pane_id" 2>&1)"
  close_status=$?
  set -e
  if (( close_status != 0 )); then
    printf '%s\n' "$close_output" >&2
    die "Harness Pane 정리에 실패했습니다: $pane_id"
  fi
  _runtime_atomic_text "$root/.harness/runtime/$task_id-$role.closed" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  info "Agent Pane 정리 완료: $agent_name ($pane_id)"
}

_runtime_state_tasks() {
  local state_file="$1"
  awk -F'|' '
    /^\|/ && NF >= 6 {
      task=$2; status=$6
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", task)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
      if (task != "Task" && task !~ /^-+$/ && task != "") print task "\t" status
    }
  ' "$state_file"
}

cmd_quota_check() {
  # 능동 쿼터 확인. agy는 --print "/usage"로 바로 조회하지만 claude·codex는
  # 비대화형 조회 수단이 없어 이미 떠 있는 Agent Pane에 "/status"를 보내 읽는다
  # (그래서 claude·codex는 TASK_ID ROLE로 실행 중인 Agent를 지정해야 한다).
  # 자동으로 아무것도 바꾸지 않는다 — 결과를 evidence에 남기고 판단은 사람 몫이다.
  local path="${1:-}" task_id="" role="" provider="" root
  [[ -n "$path" ]] || die "사용법: quota-check PATH TASK_ID ROLE(worker|reviewer) | quota-check PATH --provider PROVIDER"
  shift
  if [[ "${1:-}" == --provider ]]; then
    [[ $# -ge 2 ]] || die "--provider 값이 필요합니다."
    provider="$2"
  else
    task_id="${1:-}"; role="${2:-}"
    [[ -n "$task_id" && -n "$role" ]] || die "사용법: quota-check PATH TASK_ID ROLE(worker|reviewer) | quota-check PATH --provider PROVIDER"
    [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
    _runtime_require_id "$task_id"
  fi
  root="$(project_root "$path")"

  if [[ -z "$provider" ]]; then
    local task_file
    task_file="$root/.harness/tasks/$task_id.yaml"
    [[ -f "$task_file" ]] || die "Task YAML을 찾을 수 없습니다: $task_file"
    if [[ "$role" == worker ]]; then
      provider="$(_runtime_yaml_scalar "$task_file" primary_worker)"
    else
      provider="$(_runtime_yaml_scalar "$task_file" reviewer)"
    fi
  fi
  [[ "$provider" =~ ^(claude|codex|agy)$ ]] || die "Provider가 유효하지 않습니다: $provider"

  # low_warning_threshold_pct는 quota-policy.yaml이 정본이다 — 여기 상수를
  # 못박지 않는다(설정과 코드가 따로 노는 함정을 피한다). 정책 파일이나 키가
  # 없으면 25로 물러난다.
  local low_threshold=25 policy_file
  policy_file="$root/.harness/policies/quota-policy.yaml"
  if [[ -f "$policy_file" ]]; then
    local configured
    configured="$(_runtime_yaml_scalar "$policy_file" low_warning_threshold_pct || true)"
    [[ "$configured" =~ ^[0-9]+$ ]] && low_threshold="$configured"
  fi

  local output status status_word=unknown detail min_pct evidence_file addition
  case "$provider" in
    agy)
      command -v agy >/dev/null 2>&1 || die "agy 명령을 찾을 수 없습니다."
      set +e
      output="$(agy --print "/usage" 2>&1)"
      status=$?
      set -e
      if (( status == 0 )); then
        # 탭 구분 표: <모델군> <지표명> <남은%> <초기화시각>. 세 번째 열의
        # 최솟값을 대표값으로 쓰되, 전체 표는 evidence에 그대로 남긴다.
        min_pct="$(printf '%s\n' "$output" | awk -F'\t' '
          NF>=3 { v=$3; gsub(/%/,"",v); v=v+0; if (seen==0 || v<min) { min=v; seen=1 } }
          END { if (seen==1) print min }
        ')"
        if [[ -n "$min_pct" ]]; then
          detail="최소 남은 한도 ${min_pct}%(임계값 ${low_threshold}%, agy --print /usage 전체 내역은 evidence 참고)"
          if (( min_pct < low_threshold )); then status_word=low; else status_word=ok; fi
        else
          detail="agy --print /usage 출력 형식을 해석하지 못했습니다(원문은 evidence 참고)"
        fi
      else
        detail="agy --print /usage 호출 실패(exit $status)"
      fi
      ;;
    claude|codex)
      [[ -n "$task_id" ]] || die "claude/codex 쿼터 확인은 실행 중인 Task Agent가 필요합니다: quota-check PATH TASK_ID ROLE"
      command -v herdr >/dev/null 2>&1 || die "herdr 명령을 찾을 수 없습니다."
      [[ "${HERDR_ENV:-}" == 1 ]] || die "quota-check(claude/codex)는 Herdr Pane 안에서 실행해야 합니다."
      local meta agent_name
      meta="$root/.harness/runtime/$task_id-$role.meta"
      [[ -f "$meta" ]] || die "Runtime 기록을 찾을 수 없습니다(먼저 dispatch로 Agent를 띄우세요): $meta"
      agent_name="$(_runtime_meta_value "$meta" agent_name)"
      [[ -n "$agent_name" ]] || die "Runtime 기록이 손상되었습니다: $meta"
      set +e
      herdr agent prompt "$agent_name" "/status" --wait --timeout 30000 >/dev/null 2>&1
      output="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 80 2>&1)"
      status=$?
      set -e
      local scan
      scan="$(_runtime_scan_quota_signal "$output" || true)"
      if [[ -n "$scan" ]]; then
        detail="$scan"
        status_word=low
      else
        detail="/status 출력에서 알려진 경고 문구를 못 찾음 — 여유가 있거나 문구 형식이 다른 것일 수 있다(원문은 evidence 참고)"
      fi
      ;;
  esac

  if [[ -n "$task_id" ]]; then
    evidence_file="$root/.harness/evidence/$task_id-$role-quota.md"
    # quota-retry가 참고하는 연속 low 판정 스트릭. low가 아니면 스트릭을
    # 끊는다 — "연속" 판정만 인정한다(오탐 한 번에 반응하지 않기 위함).
    local streak_file="$root/.harness/runtime/$task_id-$role.quota-streak"
    if [[ "$status_word" == low ]]; then
      local prev_count=0 first_low_at="" streak_content
      if [[ -f "$streak_file" ]]; then
        prev_count="$(_runtime_meta_value "$streak_file" count)"
        first_low_at="$(_runtime_meta_value "$streak_file" first_low_at)"
      fi
      [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
      [[ -n "$first_low_at" ]] || first_low_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
      streak_content="$(printf 'count=%s\nfirst_low_at=%s\nlast_low_at=%s' \
        "$((prev_count + 1))" "$first_low_at" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')")"
      mkdir -p "$root/.harness/runtime"
      _runtime_atomic_text "$streak_file" "$streak_content"
    else
      rm -f -- "$streak_file"
    fi
  else
    evidence_file="$root/.harness/evidence/quota-$provider.md"
  fi
  mkdir -p "$root/.harness/evidence"
  addition="$(mktemp "$root/.harness/evidence/.quota.XXXXXX")"
  {
    printf '## 쿼터 확인 %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Provider: %s\n- 판정: %s\n- 근거: %s\n\n' "$provider" "$status_word" "$detail"
    printf '### 원문\n\n%s\n' "$output"
  } >"$addition"
  _runtime_append_evidence "$evidence_file" "$addition"
  rm -f -- "$addition"

  printf 'quota_check: provider=%s status=%s detail=%s\n' "$provider" "$status_word" "$detail"
}


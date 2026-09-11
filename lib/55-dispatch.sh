# Part of herdr-harness. Sourced by harness.sh — do not run directly.


cmd_dispatch() {
  local path="${1:-}" task_id="${2:-}" role="${3:-}" timeout=120000 print_only=0
  local extra_prompt="" agent_cwd=""
  [[ -n "$path" && -n "$task_id" && -n "$role" ]] || die "사용법: dispatch PATH TASK_ID ROLE(worker|reviewer) [--timeout MS] [--print-only] [--extra-prompt FILE] [--cwd DIR]"
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--timeout에는 양의 밀리초가 필요합니다."; timeout="$2"; shift 2 ;;
      --print-only) print_only=1; shift ;;
      # 이 Task에만 필요한 추가 지시(리뷰 중점, 오판 방지 경고 등)를 Packet 끝에
      # 붙인다. 이게 없으면 그런 지시를 담으려고 사람이 Agent를 직접 띄우게 되고,
      # 그 순간 Attempt·Evidence·추적이 통째로 빠진다.
      --extra-prompt)
        [[ $# -ge 2 ]] || die "--extra-prompt에는 파일 경로가 필요합니다."
        [[ -f "$2" ]] || die "--extra-prompt 파일을 찾을 수 없습니다: $2"
        extra_prompt="$2"; shift 2 ;;
      # Agent를 띄울 디렉터리. Provider의 Sandbox 쓰기 범위가 이 디렉터리
      # 기준으로 정해진다(codex --sandbox workspace-write 등). 계획·상태
      # 문서를 담은 Harness 워크스페이스와 수정 대상 코드 저장소가 서로 다른
      # 디렉터리일 때 필요하다 — 기본값(워크스페이스)으로는 Worker가
      # write_scope에 적힌 코드를 건드릴 수 없다.
      --cwd)
        [[ $# -ge 2 ]] || die "--cwd에는 디렉터리 경로가 필요합니다."
        [[ -d "$2" ]] || die "--cwd 디렉터리를 찾을 수 없습니다: $2"
        agent_cwd="$2"; shift 2 ;;
      *) die "알 수 없는 dispatch 옵션: $1" ;;
    esac
  done
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"

  local root task_file runtime_dir context provider attempt started_at baseline
  local pane_output pane_status pane_id agent_name start_output start_status
  local prompt_output prompt_status get_output get_status read_output read_status result
  local prompt_resent=0
  local attempt_file evidence_file temporary
  root="$(project_root "$path")"
  # --cwd를 주지 않으면 지금까지와 같이 워크스페이스에서 띄운다.
  if [[ -n "$agent_cwd" ]]; then
    agent_cwd="$(cd "$agent_cwd" && pwd -P)" || die "--cwd 경로를 해석할 수 없습니다."
  else
    agent_cwd="$root"
  fi
  task_file="$root/.harness/tasks/$task_id.yaml"
  [[ -f "$task_file" ]] || die "Task YAML을 찾을 수 없습니다: $task_file"
  # --print-only는 Pane을 만들지도 Agent를 띄우지도 않는다. Context Packet과
  # 실행할 명령만 출력하므로 Herdr 안이 아니어도 된다 — Herdr나 Provider가
  # 깨졌을 때 수동으로 진행하기 위한 폴백 경로다.
  if (( print_only == 0 )); then
    command -v herdr >/dev/null 2>&1 || die "herdr 명령을 찾을 수 없습니다."
    [[ "${HERDR_ENV:-}" == 1 ]] || die "dispatch는 Herdr Pane 안에서 실행해야 합니다."
  fi
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Git 저장소가 아닙니다: $root"

  runtime_dir="$root/.harness/runtime"
  mkdir -p "$runtime_dir" "$root/.harness/attempts" "$root/.harness/evidence"
  context="$runtime_dir/$task_id-context-$role.md"
  if ! _runtime_context_packet "$root" "$task_id" "$role" "$task_file" "$context" "$extra_prompt"; then
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

  # 도구 실행 승인만 정책으로 건너뛴다. 작업 방향성(상태 전이·완료 승인)은
  # 여기서 바뀌지 않는다 — transition/approve를 거쳐야만 움직인다.
  local approval_mode approval_args_raw agent_args_raw selected_model model_source model_record model_approval
  local model_degradation="" model_failure_reason="" model_quarantine=""
  local -a agent_args=()
  approval_mode="$(_runtime_approval_mode "$root")"
  # _runtime_agent_args는 die하지 않고 반환값으로 실패를 알린다 — auto-step처럼
  # cmd_dispatch가 커맨드 치환 안에서 불릴 때 안쪽 die가 삼켜지면 검증 실패가
  # 조용한 무인수 실행으로 바뀌기 때문이다. 여기서 명시적으로 멈춘다.
  if ! approval_args_raw="$(_runtime_agent_args "$root" "$provider")"; then
    die "agent-policy.yaml의 승인 정책 값이 유효하지 않아 dispatch를 중단합니다."
  fi
  read -r -a agent_args <<<"$approval_args_raw"
  if ! _runtime_select_model "$root" "$task_file" "$role" "$provider" "$task_id"; then
    die "프리미엄 모델 정책을 안전하게 적용할 수 없어 dispatch를 중단합니다."
  fi
  selected_model="$RUNTIME_MODEL"
  model_source="$RUNTIME_MODEL_SOURCE"
  model_approval="$RUNTIME_MODEL_APPROVAL"
  model_degradation="$RUNTIME_MODEL_DEGRADATION"
  # task-008의 실제 목록 조회를 dispatch 사전 경고에도 재사용한다. 조회 경로가
  # 없거나 조회가 실패한 Provider는 추측하지 않고 기동 출력 스캔으로 넘긴다.
  _runtime_warn_model_policy_mismatch "$root" "$provider"
  model_record="${selected_model:-Provider 기본값 (Harness 미지정)}"
  agent_args_raw="$approval_args_raw"
  if [[ -n "$selected_model" ]]; then
    agent_args+=(--model "$selected_model")
    agent_args_raw="${agent_args_raw:+$agent_args_raw }--model $selected_model"
  fi

  attempt="$(_runtime_next_attempt "$root" "$task_id")"
  started_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  baseline="$(git -C "$root" rev-parse HEAD 2>/dev/null || printf 'unborn')"
  local task_slug="${task_id,,}"
  agent_name="hh-${task_slug//[^a-z0-9_-]/-}-${role:0:1}-$attempt"
  agent_name="${agent_name:0:32}"
  [[ "$agent_name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "생성된 Agent 이름이 유효하지 않습니다: $agent_name"

  if (( print_only == 1 )); then
    # 여기서 상태를 남기지 않는다 — 아직 아무것도 시작하지 않았기 때문이다.
    # Attempt·Evidence·meta는 사람이 실제로 Agent를 띄운 뒤 adopt가 만든다.
    # 출력한 줄은 사람이 그대로 복사해 셸에 붙여 넣는다. 경로에 공백이나
    # 세미콜론이 있으면 잘못 분리되거나 명령이 하나 더 실행된다 — %q로 인용한다.
    local quoted_root quoted_context quoted_path quoted_cwd
    printf -v quoted_root '%q' "$root"
    printf -v quoted_context '%q' "$context"
    printf -v quoted_path '%q' "$path"
    printf -v quoted_cwd '%q' "$agent_cwd"
    printf 'Context Packet: %s\n\n' "$context"
    printf '아래를 Herdr Pane 안에서 차례로 실행한 뒤, 마지막 adopt로 Harness에 등록한다.\n'
    printf '(PANE_ID는 첫 명령이 출력하는 pane_id로 바꾼다.)\n\n'
    printf '  herdr pane split --current --direction right --cwd %s --no-focus\n' "$quoted_cwd"
    if [[ -n "$agent_args_raw" ]]; then
      printf '  herdr agent start %s --kind %s --pane PANE_ID --timeout %s -- %s\n' \
        "$agent_name" "$provider" "$timeout" "$agent_args_raw"
    else
      printf '  herdr agent start %s --kind %s --pane PANE_ID --timeout %s\n' \
        "$agent_name" "$provider" "$timeout"
    fi
    printf '  herdr agent prompt %s "$(cat %s)" --wait --timeout %s\n' "$agent_name" "$quoted_context" "$timeout"
    printf '  %s adopt %s %s %s --pane PANE_ID --agent %s\n\n' \
      "$SCRIPT_NAME" "$quoted_path" "$task_id" "$role" "$agent_name"
    printf '승인 모드: %s / Provider 인수: %s\n' "$approval_mode" "${agent_args_raw:-(없음)}"
    printf '모델: %s / 출처: %s\n' "$model_record" "$model_source"
    printf '프리미엄 모델 승인: %s\n' "$model_approval"
    [[ -z "$model_degradation" ]] || printf '모델 강등: %s (실행 결과를 성공으로 간주하지 말 것)\n' "$model_degradation"
    printf 'Agent 작업 디렉터리: %s%s\n' "$agent_cwd" "$( [[ "$agent_cwd" == "$root" ]] && printf ' (워크스페이스 기본값)' || printf ' (--cwd)')"
    printf 'dispatch_result=print_only\n'
    return 0
  fi

  set +e
  pane_output="$(herdr pane split --current --direction right --cwd "$agent_cwd" --no-focus 2>&1)"
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

  _runtime_write_meta "$root" "$task_id" "$role" "$agent_name" "$pane_id" "$provider" "$attempt" 0 \
    "$selected_model" "$model_source" "$model_approval" "$model_degradation"
  attempt_file="$root/.harness/attempts/$task_id-attempt-$attempt.md"
  temporary="$(mktemp "$root/.harness/attempts/.attempt.XXXXXX")"
  {
    printf '# Attempt %s: %s\n\n' "$attempt" "$task_id"
    printf -- '- Started: %s\n- Role: %s\n- Provider: %s\n- Model: %s\n- Model source: %s\n- Model approval: %s\n- Model degradation: %s\n- Pane ID: %s\n- Agent name: %s\n- Baseline commit: %s\n- Approval mode: %s\n- Provider args: %s\n- Agent cwd: %s\n' "$started_at" "$role" "$provider" "$model_record" "$model_source" "$model_approval" "${model_degradation:-(없음)}" "$pane_id" "$agent_name" "$baseline" "$approval_mode" "${agent_args_raw:-(없음)}" "$agent_cwd"
    if [[ "$agent_cwd" != "$root" ]] && git -C "$agent_cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      printf -- '- Agent cwd baseline commit: %s\n' \
        "$(git -C "$agent_cwd" rev-parse HEAD 2>/dev/null || printf 'unborn')"
    fi
  } >"$temporary"
  _runtime_atomic_copy "$temporary" "$attempt_file"
  rm -f -- "$temporary"

  set +e
  start_output="$(_runtime_start_agent_when_ready "$agent_name" "$provider" "$pane_id" "$timeout" 30 "${agent_args[@]}")"
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
    # Provider REPL이 입력을 받을 수 있게 될 때까지 기다린다. 이 대기가 없으면
    # 부팅·신뢰 확인·로그인 화면이 Packet을 먹고 Agent는 idle로 남는다.
    _runtime_wait_repl_ready "$agent_name" "$(_runtime_repl_boot_seconds "$provider")"
    set +e
    prompt_output="$(herdr agent prompt "$agent_name" "$(cat "$context")" --wait --timeout "$timeout" 2>&1)"
    prompt_status=$?
    get_output="$(herdr agent get "$agent_name" 2>&1)"
    get_status=$?
    read_output="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 200 2>&1)"
    read_status=$?
    set -e
    result="$(_runtime_normalize_state "$get_status" "$get_output" "$prompt_status" "$prompt_output")"

    # Herdr가 lifecycle 변화를 관측하지 못했고 Agent도 계속 idle인 경우에만
    # 재전송한다. 정상 settled 턴은 화면 출력에 Packet 본문이 보이지 않아도
    # 이미 실행된 것이므로 재전송하면 안 된다.
    if _runtime_prompt_needs_retry "$get_status" "$get_output" "$prompt_status" "$prompt_output"; then
      info "Provider REPL이 첫 프롬프트를 받지 않은 것으로 확인됐습니다 — 1회 재전송합니다."
      prompt_resent=1
      _runtime_wait_repl_ready "$agent_name" 3
      set +e
      prompt_output="$prompt_output"$'\n'"$(herdr agent prompt "$agent_name" "$(cat "$context")" --wait --timeout "$timeout" 2>&1)"
      prompt_status=$?
      get_output="$(herdr agent get "$agent_name" 2>&1)"
      get_status=$?
      read_output="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 200 2>&1)"
      read_status=$?
      set -e
      result="$(_runtime_normalize_state "$get_status" "$get_output" "$prompt_status" "$prompt_output")"
    fi
  fi

  # 정규화 함수와 섞지 않는다. Herdr 상태가 settled여도 Provider가 모델 거부를
  # 명시하면 별도의 실패다. Harness가 --model로 명시 전달한 경우만 격리한다.
  RUNTIME_MODEL_FAILURE_REASON=""
  if _runtime_quarantine_model_failure "$root" "$provider" "$selected_model" \
      "$([[ -n "$selected_model" ]] && printf 1 || printf 0)" \
      "$prompt_output"$'\n'"$read_output" "$task_id" "$attempt"; then
    model_failure_reason="$RUNTIME_MODEL_FAILURE_REASON"
    model_quarantine="$(_runtime_model_quarantine_path "$root" "$provider")"
    model_degradation="지정 모델 $selected_model 격리; 다음 dispatch에서 Provider 기본값으로 강등; 해제: $model_quarantine"
    result=model_quarantined
    printf '경고: 지정 모델 %s의 기동 실패를 확인해 격리했습니다 (%s). 다음 dispatch에서는 이 모델을 건너뛰며, 자동 재시도하지 않습니다. 해제하려면 사람이 %s에서 해당 기록을 지우거나 파일을 삭제하세요.\n' \
      "$selected_model" "$model_failure_reason" "$model_quarantine" >&2
    _runtime_write_meta "$root" "$task_id" "$role" "$agent_name" "$pane_id" "$provider" "$attempt" 0 \
      "$selected_model" "$model_source" "$model_approval" "$model_degradation"
    printf -- '- Model quarantine: %s\n- Model failure reason: %s\n' \
      "$model_quarantine" "$model_failure_reason" >>"$attempt_file"
  elif [[ -n "$model_degradation" ]]; then
    # Provider 기본값/비프리미엄으로 작업이 끝나도 요청 모델대로 성공한 것은
    # 아니다. 강등을 독립 결과로 올려 Orchestrator가 반드시 보게 한다.
    result="$(_runtime_model_degraded_result "$result" "$model_degradation")"
  fi

  local quota_signal
  quota_signal="$(_runtime_scan_quota_signal "$prompt_output"$'\n'"$read_output" || true)"

  evidence_file="$(_runtime_evidence_raw_path "$root" "$task_id" "$role" "$attempt")"
  mkdir -p "$(dirname "$evidence_file")"
  temporary="$(mktemp "$root/.harness/evidence/.capture.XXXXXX")"
  {
    printf '# Evidence: %s / %s / Attempt %s\n\n' "$task_id" "$role" "$attempt"
    printf -- '- Captured: %s\n- Dispatch result: %s\n- Model: %s\n- Model source: %s\n- Model approval: %s\n- Model degradation: %s\n- Model failure reason: %s\n- Model quarantine: %s\n- Approval mode: %s\n- Prompt exit: %s\n- Agent get exit: %s\n- Agent read exit: %s\n- Prompt 재전송: %s\n- 추가 지시 파일: %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$result" "$model_record" "$model_source" "$model_approval" "${model_degradation:-(없음)}" "${model_failure_reason:-(없음)}" "${model_quarantine:-(없음)}" "$approval_mode" "$prompt_status" "$get_status" "$read_status" "$( ((prompt_resent==1)) && printf 'yes(1회)' || printf 'no')" "${extra_prompt:-(없음)}"
    printf '## Git status --short\n\n'
    git -C "$root" status --short 2>&1 || true
    printf '\n## Git diff --stat\n\n'
    git -C "$root" diff --stat 2>&1 || true
    if [[ "$agent_cwd" != "$root" ]] && git -C "$agent_cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      printf '\n## Git status --short (Agent cwd: %s)\n\n' "$agent_cwd"
      git -C "$agent_cwd" status --short 2>&1 || true
      printf '\n## Git diff --stat (Agent cwd: %s)\n\n' "$agent_cwd"
      git -C "$agent_cwd" diff --stat 2>&1 || true
    fi
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
  # 정본은 판단에 쓰이는 6필드 YAML이다. Reviewer와 transition은 이것만 읽는다.
  _runtime_write_evidence_yaml "$root" "$task_id" "$role" "$attempt" "$result" \
    "dispatch 결과 $result (Provider $provider, 모델 $model_record, 출처 $model_source, 프리미엄 모델 승인 $model_approval, 모델 강등 ${model_degradation:-(없음)}, 모델 실패 ${model_failure_reason:-(없음)}, 승인 모드 $approval_mode). 원문은 raw 참조." 0
  _runtime_write_result "$root" "$task_id" "$role" "$result"
  printf 'dispatch_result=%s\n' "$result"
  [[ "$result" == settled || "$result" == blocked ]]
}

# ---------------------------------------------------------------------------
# adopt — 사람이 직접 띄운 Agent를 Harness 추적에 되돌려 넣는다.
#
# 기본 경로는 dispatch가 Pane 생성·Agent 실행·프롬프트까지 한 번에 하는 것이다
# (그래야 Attempt·Evidence가 빠짐없이 남고 transition의 게이트가 성립한다).
# adopt는 그 경로가 막혔을 때 — Herdr나 Provider CLI가 깨졌거나, 이미 띄워 둔
# Agent를 이어서 쓰고 싶을 때 — 쓰는 폴백이다. `dispatch --print-only`가
# 출력하는 마지막 명령이 바로 이것이다.
# ---------------------------------------------------------------------------
cmd_adopt() {
  local path="${1:-}" task_id="${2:-}" role="${3:-}" pane_id="" agent_name="" provider=""
  [[ -n "$path" && -n "$task_id" && -n "$role" ]] ||
    die "사용법: adopt PATH TASK_ID ROLE(worker|reviewer) --pane PANE_ID --agent AGENT_NAME [--provider P]"
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pane) [[ $# -ge 2 ]] || die "--pane 값이 필요합니다."; pane_id="$2"; shift 2 ;;
      --agent) [[ $# -ge 2 ]] || die "--agent 값이 필요합니다."; agent_name="$2"; shift 2 ;;
      --provider) [[ $# -ge 2 ]] || die "--provider 값이 필요합니다."; provider="$2"; shift 2 ;;
      *) die "알 수 없는 adopt 옵션: $1" ;;
    esac
  done
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"
  [[ -n "$pane_id" ]] || die "--pane PANE_ID가 필요합니다(herdr pane split이 출력한 값)."
  [[ -n "$agent_name" ]] || die "--agent AGENT_NAME이 필요합니다(herdr agent start에 쓴 이름)."
  [[ "$agent_name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "Agent 이름 형식이 올바르지 않습니다: $agent_name"

  local root task_file attempt baseline get_output get_status temporary attempt_file
  root="$(project_root "$path")"
  # --cwd를 주지 않으면 지금까지와 같이 워크스페이스에서 띄운다.
  if [[ -n "$agent_cwd" ]]; then
    agent_cwd="$(cd "$agent_cwd" && pwd -P)" || die "--cwd 경로를 해석할 수 없습니다."
  else
    agent_cwd="$root"
  fi
  task_file="$root/.harness/tasks/$task_id.yaml"
  [[ -f "$task_file" ]] || die "Task YAML을 찾을 수 없습니다: $task_file"
  command -v herdr >/dev/null 2>&1 || die "herdr 명령을 찾을 수 없습니다."

  if [[ -z "$provider" ]]; then
    if [[ "$role" == worker ]]; then
      provider="$(_runtime_yaml_scalar "$task_file" primary_worker)"
    else
      provider="$(_runtime_yaml_scalar "$task_file" reviewer)"
    fi
  fi
  [[ "$provider" =~ ^(claude|codex|agy)$ ]] || die "Provider가 유효하지 않습니다: $provider"

  # 등록하기 전에 그 Agent가 실제로 살아 있는지 확인한다. 죽은 이름을 등록하면
  # observe·close-agent가 조용히 agent_lost만 반복하게 된다.
  set +e
  get_output="$(herdr agent get "$agent_name" 2>&1)"
  get_status=$?
  set -e
  (( get_status == 0 )) || {
    printf '%s\n' "$get_output" >&2
    die "그 이름의 Agent를 Herdr에서 찾지 못했습니다: $agent_name"
  }
  # --pane 값을 그대로 믿지 않는다. 사용자가 오타를 내면 observe·close-agent가
  # 엉뚱한 Pane을 보게 되고, 호출자 게이트도 잘못된 pane을 기준으로 판단한다.
  local actual_pane
  actual_pane="$(_runtime_json_field "$get_output" pane_id)"
  [[ -n "$actual_pane" ]] ||
    die "Herdr가 $agent_name 의 pane_id를 알려주지 않았습니다."
  [[ "$actual_pane" == "$pane_id" ]] ||
    die "--pane 값이 Herdr가 아는 Agent Pane과 다릅니다: 입력=$pane_id, 실제=$actual_pane"

  mkdir -p "$root/.harness/runtime" "$root/.harness/attempts" "$root/.harness/evidence"
  attempt="$(_runtime_next_attempt "$root" "$task_id")"
  baseline="$(git -C "$root" rev-parse HEAD 2>/dev/null || printf 'unborn')"
  _runtime_write_meta "$root" "$task_id" "$role" "$agent_name" "$pane_id" "$provider" "$attempt" 1

  attempt_file="$root/.harness/attempts/$task_id-attempt-$attempt.md"
  temporary="$(mktemp "$root/.harness/attempts/.attempt.XXXXXX")"
  {
    printf '# Attempt %s: %s\n\n' "$attempt" "$task_id"
    printf -- '- Started: %s\n- Role: %s\n- Provider: %s\n- Pane ID: %s\n- Agent name: %s\n- Baseline commit: %s\n- Adopted: yes (사람이 띄운 Agent를 adopt로 등록)\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$role" "$provider" "$pane_id" "$agent_name" "$baseline"
  } >"$temporary"
  _runtime_atomic_copy "$temporary" "$attempt_file"
  rm -f -- "$temporary"

  append_event "$root" agent_adopted "$task_id" "" "" "role=$role agent=$agent_name pane=$pane_id provider=$provider"
  info "Agent를 Harness에 등록했습니다: $agent_name ($pane_id, attempt $attempt)"
  printf '이제 %s observe %s %s %s 로 출력을 Evidence에 담을 수 있습니다.\n' "$SCRIPT_NAME" "$path" "$task_id" "$role"
  printf 'adopt_result=ok\n'
}

cmd_observe() {
  local path="${1:-}" task_id="${2:-}" role="${3:-worker}"
  [[ -n "$path" && -n "$task_id" ]] || die "사용법: observe PATH TASK_ID [ROLE]"
  [[ $# -le 3 ]] || die "사용법: observe PATH TASK_ID [ROLE]"
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"
  local root meta agent_name pane_id attempt evidence addition get_output get_status read_output read_status result
  local model model_source model_degradation model_summary previous_result
  root="$(project_root "$path")"
  meta="$root/.harness/runtime/$task_id-$role.meta"
  [[ -f "$meta" ]] || die "Runtime 기록을 찾을 수 없습니다: $meta"
  agent_name="$(_runtime_meta_value "$meta" agent_name)"
  pane_id="$(_runtime_meta_value "$meta" pane_id)"
  attempt="$(_runtime_meta_value "$meta" attempt)"
  model="$(_runtime_meta_value "$meta" model)"
  model_source="$(_runtime_meta_value "$meta" model_source)"
  model_degradation="$(_runtime_meta_value "$meta" model_degradation)"
  if [[ -n "$model_source" ]]; then
    model_summary=" 모델 ${model:-Provider 기본값 (Harness 미지정)}, 출처 $model_source."
  else
    model_summary=""
  fi
  [[ -z "$model_degradation" ]] || model_summary+=" 모델 강등 $model_degradation."
  [[ -n "$agent_name" && -n "$pane_id" && "$attempt" =~ ^[0-9]+$ ]] || die "Runtime 기록이 손상되었습니다: $meta"
  set +e
  get_output="$(herdr agent get "$agent_name" 2>&1)"
  get_status=$?
  read_output="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 200 2>&1)"
  read_status=$?
  set -e
  result="$(_runtime_normalize_state "$get_status" "$get_output" 0 "")"
  previous_result="$(cat "$root/.harness/runtime/$task_id-$role.result" 2>/dev/null || true)"
  if [[ "$previous_result" == model_quarantined ]]; then
    # 같은 Agent가 자동 복구된 적은 없다. 화면 상태만 settled로 바뀌었다고
    # 모델 거부가 사라진 것으로 쓰면 격리 실패가 다시 성공으로 보인다.
    result=model_quarantined
  else
    result="$(_runtime_model_degraded_result "$result" "$model_degradation")"
  fi
  local quota_signal
  quota_signal="$(_runtime_scan_quota_signal "$read_output" || true)"
  evidence="$(_runtime_evidence_raw_path "$root" "$task_id" "$role" "$attempt")"
  mkdir -p "$(dirname "$evidence")"
  addition="$(mktemp "$root/.harness/evidence/.observe.XXXXXX")"
  {
    printf '\n## Observation %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Result: %s\n- Model degradation: %s\n- Pane ID: %s\n- Agent get exit: %s\n- Agent read exit: %s\n\n' "$result" "${model_degradation:-(없음)}" "$pane_id" "$get_status" "$read_status"
    printf '### Agent state\n\n%s\n\n### Agent output\n\n%s\n' "$get_output" "$read_output"
    if [[ -n "$quota_signal" ]]; then
      printf '\n### 쿼터 신호(자동 감지 — 확정 아님)\n\n%s\n' "$quota_signal"
    fi
  } >"$addition"
  _runtime_append_evidence "$evidence" "$addition"
  rm -f -- "$addition"
  local observations
  observations="$(_runtime_evidence_observations "$(_runtime_evidence_yaml_path "$root" "$task_id" "$role" "$attempt")")"
  _runtime_write_evidence_yaml "$root" "$task_id" "$role" "$attempt" "$result" \
    "observe 결과 $result.$model_summary 원문은 raw 참조." "$((observations + 1))"
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
  # "Harness가 만든 Pane만 정리한다"는 불변식. adopt로 등록한 Pane은 사람이
  # 만든 것이므로 --force로 명시할 때만 닫는다.
  local adopted
  adopted="$(_runtime_meta_value "$meta" adopted)"
  [[ "$adopted" != 1 || "$force" -eq 1 ]] ||
    die "adopt로 등록한(사람이 만든) Pane입니다. --force 없이는 닫지 않습니다: $pane_id"
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

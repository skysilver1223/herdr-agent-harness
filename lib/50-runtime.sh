# Part of herdr-harness. Sourced by harness.sh — do not run directly.

# ---------------------------------------------------------------------------
# 스텝 실행기 — dispatch / observe / close-agent / status --live
# 호출 1회 = 1스텝. 재시도, 상태 전이, failover, blocked 응답을 하지 않는다.
# ---------------------------------------------------------------------------

_runtime_require_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "잘못된 Task ID입니다: $1"
}

_runtime_atomic_copy() {
  local source="$1" destination="$2" parent temporary
  parent="$(dirname "$destination")"
  mkdir -p "$parent"
  temporary="$(mktemp "$parent/.runtime-write.XXXXXX")"
  if ! cp -- "$source" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$destination"
}

_runtime_atomic_text() {
  local destination="$1" value="$2" parent temporary
  parent="$(dirname "$destination")"
  mkdir -p "$parent"
  temporary="$(mktemp "$parent/.runtime-write.XXXXXX")"
  printf '%s\n' "$value" >"$temporary"
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$destination"
}

_runtime_json_field() {
  local input="$1" field="$2" value=""
  # herdr 호출은 전부 2>&1로 캡처한다. 경고 한 줄이 stderr에 섞여도 파싱이
  # 죽지 않도록, 첫 '{'부터 마지막 '}'까지만 남기고 자른다(BACKLOG.md #3).
  if [[ "$input" == *"{"* && "$input" == *"}"* ]]; then
    input="${input#*\{}"
    input="{${input}"
    input="${input%\}*}"
    input="${input}}"
  fi
  if command -v jq >/dev/null 2>&1; then
    value="$(printf '%s' "$input" | jq -r ".. | objects | .$field? // empty" 2>/dev/null | head -n 1 || true)"
  else
    # 앞쪽 탐욕적 .* 는 같은 키가 여러 번 나오면 마지막 값을 뽑는다(BACKLOG.md #2).
    # grep -o 로 겹치지 않는 첫 매치만 취해 jq 경로(첫 값)와 결과를 맞춘다.
    value="$(printf '%s' "$input" | tr -d '\n' \
      | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | head -n 1 \
      | sed -n 's/.*:[[:space:]]*"\([^"]*\)"/\1/p')"
  fi
  printf '%s' "$value"
}

_runtime_yaml_scalar() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      sub("^[[:space:]]*" key ":[[:space:]]*", "")
      gsub(/^['\''"]|['\''"]$/, "")
      print
      exit
    }
  ' "$file"
}

_runtime_has_secret() {
  LC_ALL=C grep -Eqi 'AKIA[0-9A-Z]{8,}|BEGIN[[:space:]]+(RSA |EC |OPENSSH )?PRIVATE KEY|password[[:space:]]*=|token[[:space:]]*=|api[_-]?key[[:space:]]*=' "$1"
}

# 쿼터 경고 신호 스캔. 자동으로 Provider를 바꾸지 않는다 — 확인만 하고 정보로
# 남긴다(ARCHITECTURE.md §8 "Provider 교체는 실패가 확인된 경우에만"). 못 찾으면
# 아무것도 출력하지 않는다: 감지 실패를 "쿼터 여유 있음"으로 착각하면 안 된다.
_runtime_scan_quota_signal() {
  local text="$1" pct
  pct="$(printf '%s' "$text" | grep -Eio '[0-9]+% of your (weekly|daily|five.hour) limit' | grep -Eo '^[0-9]+' | sort -n | head -n 1)"
  if [[ -n "$pct" ]]; then
    printf '남은 한도 %s%% 부근 경고 문구 감지("...%s%% of your ... limit")' "$pct" "$pct"
    return 0
  fi
  if printf '%s' "$text" | grep -Eqi 'usage limit reached|rate.?limit exceeded|quota.?exceeded|429 too many requests'; then
    printf '쿼터·Rate Limit 소진 문구 감지'
    return 0
  fi
  return 1
}

_runtime_next_attempt() {
  local root="$1" task_id="$2" path base number maximum=0
  shopt -s nullglob
  for path in "$root/.harness/attempts/$task_id-attempt-"*.md; do
    base="${path##*/}"
    number="${base#"$task_id-attempt-"}"
    number="${number%.md}"
    [[ "$number" =~ ^[0-9]+$ ]] || continue
    (( number > maximum )) && maximum="$number"
  done
  shopt -u nullglob
  printf '%s\n' "$((maximum + 1))"
}

_runtime_write_result() {
  local root="$1" task_id="$2" role="$3" result="$4"
  _runtime_atomic_text "$root/.harness/runtime/$task_id-$role.result" "$result"
}

_runtime_write_meta() {
  local root="$1" task_id="$2" role="$3" agent_name="$4" pane_id="$5" provider="$6" attempt="$7"
  local destination temporary
  destination="$root/.harness/runtime/$task_id-$role.meta"
  temporary="$(mktemp "$root/.harness/runtime/.meta.XXXXXX")"
  {
    printf 'task_id=%s\n' "$task_id"
    printf 'role=%s\n' "$role"
    printf 'agent_name=%s\n' "$agent_name"
    printf 'pane_id=%s\n' "$pane_id"
    printf 'provider=%s\n' "$provider"
    printf 'attempt=%s\n' "$attempt"
  } >"$temporary"
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$destination"
}

_runtime_meta_value() {
  local file="$1" key="$2"
  sed -n "s/^$key=//p" "$file" | head -n 1
}

# ---------------------------------------------------------------------------
# Task Lock — mkdir 기반 권고적(advisory) 잠금이다. SQLite Lease나 Fencing
# Token이 아니다: quota-retry/auto-step처럼 harness.sh를 거치는 자동화 경로
# 끼리만 같은 Task에 동시에 들어가는 것을 막는다. 사람이 같은 Task에
# 수동으로 dispatch/transition을 실행하는 것까지는 막지 않는다 — 자동
# 명령이 도는 동안은 `status --live`로 확인하고 수동 개입을 삼가야 한다.
# ---------------------------------------------------------------------------

_runtime_lock_dir() {
  printf '%s/.harness/runtime/%s.lock' "$1" "$2"
}

_runtime_lock_acquire() {
  local root="$1" task_id="$2" purpose="$3" stale_seconds="${4:-600}"
  local lock_dir holder pid acquired_at now acquired_epoch token
  lock_dir="$(_runtime_lock_dir "$root" "$task_id")"
  mkdir -p "$root/.harness/runtime"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    holder="$lock_dir/holder"
    if [[ ! -f "$holder" ]]; then
      printf 'Task Lock 디렉터리가 손상되었습니다: %s\n' "$lock_dir" >&2
      return 1
    fi
    pid="$(_runtime_meta_value "$holder" pid)"
    acquired_at="$(_runtime_meta_value "$holder" acquired_at)"
    now="$(date -u +%s)"
    acquired_epoch="$(date -u -d "$acquired_at" +%s 2>/dev/null || printf 0)"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && (( now - acquired_epoch > stale_seconds )); then
      append_event "$root" lock_reclaim_stale "$task_id" "" "" "purpose=$purpose pid=$pid"
      rm -rf -- "$lock_dir"
      if ! mkdir "$lock_dir" 2>/dev/null; then
        printf 'Task Lock 획득에 실패했습니다(경합): %s\n' "$task_id" >&2
        return 1
      fi
    else
      printf 'Task가 다른 프로세스에 의해 잠겨 있습니다: %s (owner=%s pid=%s since=%s)\n' \
        "$task_id" "$(_runtime_meta_value "$holder" owner)" "$pid" "$acquired_at" >&2
      return 1
    fi
  fi
  token="$$-$(date -u +%s)-$RANDOM"
  local holder_content
  holder_content="$(printf 'owner=%s\npid=%s\nacquired_at=%s\ntoken=%s' \
    "$purpose" "$$" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$token")"
  _runtime_atomic_text "$lock_dir/holder" "$holder_content"
  printf '%s' "$token"
}

_runtime_lock_release() {
  local root="$1" task_id="$2" token="$3" lock_dir current_token
  lock_dir="$(_runtime_lock_dir "$root" "$task_id")"
  [[ -d "$lock_dir" ]] || return 0
  current_token="$(_runtime_meta_value "$lock_dir/holder" token 2>/dev/null || true)"
  [[ "$current_token" == "$token" ]] || return 0
  rm -rf -- "$lock_dir"
}

# 다음 Fallback Provider 계산: Task 자신의 fallback_chain에서 현재 Provider
# 다음 값(끝이면 처음 값으로 순환)을 고른다. dispatch/observe/transition을
# 재구현하지 않는 것과 같은 이유로, Provider를 실제로 갈아끼우는 로직은
# 여기 한 곳에만 둔다.
_runtime_next_fallback_provider() {
  local task_file="$1" current="$2"
  local -a chain=()
  local item
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    chain+=("$item")
  done < <(yaml_flow_list "$task_file" fallback_chain)
  (( ${#chain[@]} > 0 )) || return 1
  local i
  for ((i = 0; i < ${#chain[@]}; i++)); do
    if [[ "${chain[$i]}" == "$current" ]]; then
      if (( i + 1 < ${#chain[@]} )); then
        printf '%s' "${chain[$((i + 1))]}"
      else
        printf '%s' "${chain[0]}"
      fi
      return 0
    fi
  done
  printf '%s' "${chain[0]}"
}

# cmd_transition의 원자적 status 갱신과 같은 관용구(mktemp+awk+grep 검증+mv)
# 를 그대로 따른다. Task YAML의 primary_worker/reviewer 한 필드만 바꾼다.
_runtime_set_task_provider() {
  local task_file="$1" field="$2" new_provider="$3" temporary quote="'"
  temporary="$(mktemp "$(dirname "$task_file")/.harness-provider.XXXXXX")"
  trap "rm -f -- '$temporary'" RETURN
  awk -v key="$field" -v val="$new_provider" -v q="$quote" '
    !done_flag && index($0, key ":") == 1 { print key ": " q val q; done_flag = 1; next }
    { print }
  ' "$task_file" >"$temporary"
  grep -q "^${field}: '${new_provider}'$" "$temporary" || {
    rm -f "$temporary"
    die "Provider 갱신에 실패했습니다: $task_file"
  }
  chmod 0644 "$temporary"
  mv "$temporary" "$task_file"
}

_runtime_append_evidence() {
  local evidence="$1" addition="$2" temporary
  temporary="$(mktemp "$(dirname "$evidence")/.evidence.XXXXXX")"
  trap "rm -f -- '$temporary'" RETURN
  [[ ! -f "$evidence" ]] || cp -- "$evidence" "$temporary"
  cat -- "$addition" >>"$temporary"
  if _runtime_has_secret "$temporary"; then
    : >"$temporary"
    printf '# Evidence withheld\n\n경고: Secret 의심 패턴이 발견되어 원문을 저장하지 않았습니다.\n' >"$temporary"
  fi
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$evidence"
}

_runtime_normalize_state() {
  local get_status="$1" get_output="$2" prompt_status="${3:-0}" prompt_output="${4:-}"
  local state combined
  combined="$prompt_output $get_output"
  # Agent가 실제로 사라졌으면 stalled보다 agent_lost가 더 실행 가능한 정보다.
  if (( get_status != 0 )); then
    printf 'agent_lost'
    return
  fi
  if printf '%s' "$combined" | grep -qi 'agent_prompt_stalled'; then
    printf 'stalled'
    return
  fi
  if (( prompt_status != 0 )) && printf '%s' "$combined" | grep -Eqi 'timed?[ -]?out|timeout'; then
    printf 'timeout'
    return
  fi
  state="$(_runtime_json_field "$get_output" agent_status)"
  case "$state" in
    idle|done) printf 'settled' ;;
    blocked) printf 'blocked' ;;
    *) printf 'error' ;;
  esac
}

_runtime_spec_section() {
  # init이 만드는 SPEC.md는 "## N. 제목" 형식의 고정 섹션 7개로 구성된다.
  # 번호(N)로 매칭해 그 섹션을 다음 "## " 헤더 전까지 그대로 출력한다.
  local file="$1" number="$2"
  awk -v n="$number" '
    $0 ~ "^## " n "\\." { printing=1 }
    printing && /^## / && $0 !~ "^## " n "\\." { exit }
    printing { print }
  ' "$file"
}

_runtime_context_packet() {
  local root="$1" task_id="$2" role="$3" task_file="$4" destination="$5"
  local temporary spec_file
  temporary="$(mktemp "$root/.harness/runtime/.context.XXXXXX")"
  trap "rm -f -- '$temporary'" RETURN
  spec_file="$root/.harness/SPEC.md"
  {
    printf '# Context Packet: %s / %s\n\n' "$task_id" "$role"
    printf '## Specification excerpt\n\n'
    if [[ -f "$spec_file" ]]; then
      # 줄 수로 자르지 않는다(200줄을 넘으면 Acceptance Criteria·제약이 통째로
      # 빠지던 결함 — BACKLOG.md #5). 실행에 필요한 절만 번호로 골라 전부 담는다.
      local section_number
      for section_number in 1 3 4 5 6; do
        _runtime_spec_section "$spec_file" "$section_number"
        printf '\n'
      done
    fi
    printf '\n## Task Contract\n\n'
    cat "$task_file"
    printf '\n`write_scope`, `resources`, `inputs`, `acceptance_criteria`는 위 Task Contract YAML 안에 있다. 착수 게이트·제외 범위·불변식은 `%s`를 읽는다.\n' "$(_runtime_yaml_scalar "$task_file" intent)"
    printf '\n## Next step\n\n'
    if [[ "$role" == worker ]]; then
      printf '이 Task만 수행하고 검증 결과와 Attempt 산출물을 남긴 뒤 submitted를 제안한다. 상태를 직접 전이하거나 completed로 만들지 않는다.\n'
    else
      printf 'Diff, Task Criteria와 Evidence를 읽기 전용으로 검토하고 Review 산출물에 판정과 근거를 기록한다. 소스와 Task 상태를 수정하지 않는다.\n'
    fi
  } >"$temporary"
  if _runtime_has_secret "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  _runtime_atomic_copy "$temporary" "$destination"
  rm -f -- "$temporary"
}

_runtime_start_agent_when_ready() {
  # 분할 직후 Pane은 Herdr가 "available shell"로 인정하기까지 수 초가 걸린다.
  # 측정 결과 4~7초. 그동안 agent start는 agent_pane_busy로 실패한다.
  # 이 대기는 Pane 준비 조건만 재확인하며, 실패한 Agent 턴을 재시도하지 않는다.
  local agent_name="$1" provider="$2" pane_id="$3" timeout="$4"
  local deadline_s="${5:-30}"
  local waited=0 output status
  while :; do
    set +e
    output="$(herdr agent start "$agent_name" --kind "$provider" --pane "$pane_id" --timeout "$timeout" 2>&1)"
    status=$?
    set -e
    if (( status == 0 )); then
      printf '%s' "$output"
      return 0
    fi
    if ! printf '%s' "$output" | grep -q 'agent_pane_busy'; then
      printf '%s' "$output"
      return "$status"
    fi
    if (( waited >= deadline_s * 2 )); then
      printf '%s' "$output"
      return "$status"
    fi
    sleep 0.5
    waited=$((waited + 1))
  done
}

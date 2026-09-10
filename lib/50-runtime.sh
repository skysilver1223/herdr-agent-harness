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

# 값이 Prompt로 나가기 전에 거르는 마지막 그물이다. '=' 만 보던 좁은 규칙은
# YAML/헤더 형태('token: ...', 'Authorization: Bearer ...')와 Provider 토큰
# 접두사를 통째로 놓쳤다 — Evidence·Review를 Context Packet에 넣기 시작하면서
# 사람이 붙여 넣은 값이 그대로 Agent에게 흘러갈 수 있는 경로가 생겼다.
_runtime_has_secret() {
  LC_ALL=C grep -Eqi \
    'AKIA[0-9A-Z]{8,}|BEGIN[[:space:]]+(RSA |EC |DSA |OPENSSH )?PRIVATE KEY|(password|passwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret)[[:space:]]*[:=][[:space:]]*[^[:space:]]|authorization[[:space:]]*:[[:space:]]*(bearer|basic)[[:space:]]|(gh[pousr]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.)' \
    "$1"
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

# adopted=1은 "Harness가 만들지 않고 사람이 띄운 Agent를 등록했다"는 뜻이다.
# close-agent가 이 값을 보고 --force 없이는 닫지 않는다 — Harness가 만든
# Pane만 정리한다는 불변식을 adopt 경로에서도 지키기 위해서다.
_runtime_write_meta() {
  local root="$1" task_id="$2" role="$3" agent_name="$4" pane_id="$5" provider="$6" attempt="$7"
  local adopted="${8:-0}"
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
    printf 'adopted=%s\n' "$adopted"
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

# ---------------------------------------------------------------------------
# Evidence — 정본은 구조화 YAML, 원문 덤프는 raw/ 로 분리한다.
#
# Reviewer와 transition이 읽어야 하는 것은 "Worker가 말한 것과 실제 repository
# 상태가 일치하는가" 하나다. Agent 출력 200줄과 prompt 전문은 그 판단에 쓰이지
# 않으면서 파일만 키운다(메타데이터가 코드보다 커지는 문제). 그래서 판단에
# 쓰이는 6필드만 정본으로 두고, 원문은 디버깅용으로 raw/에 남긴다.
# raw/는 init이 만드는 .gitignore에 이미 들어 있어 커밋되지 않는다.
# ---------------------------------------------------------------------------
_runtime_evidence_yaml_path() {
  printf '%s/.harness/evidence/%s-%s-attempt-%s.yaml' "$1" "$2" "$3" "$4"
}

_runtime_evidence_raw_path() {
  printf '%s/.harness/evidence/raw/%s-%s-attempt-%s.md' "$1" "$2" "$3" "$4"
}

# 정본 YAML을 통째로 다시 쓴다. 제자리 수정(sed)으로 필드를 갈아끼우지 않는
# 이유는, 값이 전부 호출자가 아는 것이라 재생성이 더 단순하고 깨지지 않기
# 때문이다 — observe가 여러 번 돌아도 결과는 항상 같은 모양이다.
_runtime_write_evidence_yaml() {
  local root="$1" task_id="$2" role="$3" attempt="$4" status="$5" summary="$6"
  local observations="${7:-0}"
  local destination temporary raw_relative line
  destination="$(_runtime_evidence_yaml_path "$root" "$task_id" "$role" "$attempt")"
  raw_relative=".harness/evidence/raw/$task_id-$role-attempt-$attempt.md"
  temporary="$(mktemp "$root/.harness/evidence/.evidence-yaml.XXXXXX")"
  {
    printf 'task: %s\n' "$(yaml_quote "$task_id")"
    printf 'role: %s\n' "$(yaml_quote "$role")"
    printf 'attempt: %s\n' "$attempt"
    printf 'result:\n  summary: %s\n' "$(yaml_quote "$summary")"
    printf 'changes:\n'
    # git status --short 의 경로만 담는다. diff 본문은 raw에 있다.
    if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        printf '  - %s\n' "$(yaml_quote "$line")"
      done < <(git -C "$root" status --short 2>/dev/null || true)
    fi
    printf 'checks:\n'
    printf '  # acceptance_criteria 실행 결과는 transition submitted 시점에 Harness가\n'
    printf '  # 직접 실행해 %s-attempt-%s-checks.yaml 로 기록한다.\n' "$task_id" "$attempt"
    printf 'notes:\n'
    printf '  - %s\n' "$(yaml_quote "관측 횟수: $observations")"
    printf 'status: %s\n' "$(yaml_quote "$status")"
    printf 'raw: %s\n' "$(yaml_quote "$raw_relative")"
  } >"$temporary"
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$destination"
}

_runtime_evidence_observations() {
  local yaml_file="$1" value
  [[ -f "$yaml_file" ]] || { printf '0'; return 0; }
  value="$(sed -n "s/^  - '관측 횟수: \([0-9]*\)'\$/\1/p" "$yaml_file" | head -n 1)"
  printf '%s' "${value:-0}"
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

# 직전 라운드 요약 — 최신 Attempt 정본(Evidence YAML), AC 검증 결과, 최신 Review
# 판정·지적사항. 셋 다 없으면 아무것도 출력하지 않는다(첫 시도).
# "가장 큰 attempt 번호"가 아니라 "그 파일이 실제로 있는 가장 최근 attempt"를
# 찾는다. 번호만 보면, Attempt는 2까지 갔는데 2번 dispatch가 Agent를 띄우기
# 전에 죽어 Evidence가 없는 경우 1번의 증적과 AC 결과가 통째로 사라진다 —
# Packet은 "직전 시도" 절만 비어 있는 채로 나가고, 재시도가 같은 실수를
# 반복하는 것을 막지 못한다(이 기능이 막으려던 바로 그 상황).
# Packet에 넣는 조각의 상한. Review나 checks는 사람이 쓰거나 명령 출력이
# 들어가서 크기를 예측할 수 없다 — 통째로 cat하면 Context Packet이 무한히
# 커져, 전체 문서를 던지지 않는다는 Packet의 존재 이유가 무너진다.
# 줄 수와 줄 길이를 함께 자른다(거대한 한 줄도 막아야 하므로).
_runtime_excerpt() {
  local file="$1" max_lines="${2:-80}" max_columns="${3:-500}" total
  [[ -f "$file" ]] || return 0
  total="$(wc -l <"$file" 2>/dev/null || printf 0)"
  head -n "$max_lines" "$file" | cut -c "1-$max_columns"
  if (( total > max_lines )); then
    printf '... (%s줄 중 %s줄만 표시 — 전문은 원본 파일 참조)\n' "$total" "$max_lines"
  fi
}

_runtime_latest_existing() {
  # $1=root $2=글롭 앞부분 $3=글롭 뒷부분 → 가장 큰 N을 출력(없으면 빈 값)
  local root="$1" prefix="$2" suffix="$3" path base number maximum=""
  shopt -s nullglob
  for path in "$root/.harness/evidence/$prefix"*"$suffix"; do
    base="${path##*/}"
    number="${base#"$prefix"}"
    number="${number%"$suffix"}"
    [[ "$number" =~ ^[0-9]+$ ]] || continue
    [[ -n "$maximum" ]] && (( number <= maximum )) && continue
    maximum="$number"
  done
  shopt -u nullglob
  printf '%s' "$maximum"
}

_runtime_previous_round() {
  local root="$1" task_id="$2"
  local attempt evidence checks checks_attempt review verdict printed=0
  local role

  for role in worker reviewer; do
    attempt="$(_runtime_latest_existing "$root" "$task_id-$role-attempt-" ".yaml")"
    [[ -n "$attempt" ]] || continue
    evidence="$(_runtime_evidence_yaml_path "$root" "$task_id" "$role" "$attempt")"
    [[ -f "$evidence" ]] || continue
    (( printed == 1 )) || { printf '\n## 직전 시도\n\n'; printed=1; }
    printf '### Evidence (%s, Attempt %s)\n\n```yaml\n' "$role" "$attempt"
    _runtime_excerpt "$evidence"
    printf '```\n\n'
  done

  checks_attempt="$(_runtime_latest_existing "$root" "$task_id-attempt-" "-checks.yaml")"
  if [[ -n "$checks_attempt" ]]; then
    checks="$root/.harness/evidence/$task_id-attempt-$checks_attempt-checks.yaml"
    if [[ -f "$checks" ]]; then
      (( printed == 1 )) || { printf '\n## 직전 시도\n\n'; printed=1; }
      printf '### Acceptance Criteria 검증 결과 (Attempt %s)\n\n```yaml\n' "$checks_attempt"
      _runtime_excerpt "$checks"
      printf '```\n\n'
    fi
  fi

  review="$(latest_task_review "$root" "$task_id")"
  if [[ -n "$review" && -f "$review" ]]; then
    verdict="$(review_verdict "$review")"
    (( printed == 1 )) || { printf '\n## 직전 시도\n\n'; printed=1; }
    printf '### 최신 Review 판정: %s\n\n' "${verdict:-불명}"
    printf '출처: %s\n\n' "${review#"$root/"}"
    _runtime_excerpt "$review"
    printf '\n'
  fi

  (( printed == 0 )) || printf '위 지적을 먼저 해소한다. 같은 접근을 그대로 반복하지 않는다.\n'
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
    # 직전 시도 결과를 넣지 않으면 changes_requested로 돌아온 재시도에서 Worker가
    # Reviewer 지적을 못 본 채 같은 접근을 반복한다(Rework의 주된 원인).
    # 전체 이력이 아니라 "최신 한 번"만 넣어 Packet이 부풀지 않게 한다.
    _runtime_previous_round "$root" "$task_id"
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

# ---------------------------------------------------------------------------
# 호출자 게이트 — "상태 전이·완료 승인은 사람 몫"을 지시가 아니라 코드로 막는다.
#
# agent-policy.yaml이 도구 실행 승인을 건너뛰게 되면서, dispatch가 띄운 Agent는
# 셸 명령을 물어보지 않고 실행할 수 있게 됐다. 그러면 Agent가 스스로
# `herdr-harness approve ... --confirm-user-approval`을 호출해 completed까지
# 갈 수 있다 — Context Packet의 "직접 전이하지 않는다"는 지시는 기술적 게이트가
# 아니기 때문이다.
#
# dispatch/adopt는 자기가 띄운 Agent의 pane_id를 .harness/runtime/*.meta에 적어
# 둔다. `herdr pane current`가 답한 현재 pane이 거기 있으면, 지금 명령을 부른
# 주체가 Harness가 관리하는 Agent라는 뜻이므로 거부한다.
# 사람과 Orchestrator Pane은 meta에 없으므로 영향을 받지 않는다.
#
# 이것은 가드레일이지 보안 경계가 아니다. Agent는 사용자와 같은 권한으로
# 돌기 때문에 .meta를 고치거나 이 파일 자체를 고칠 수 있다 — 적대적 Agent를
# 막으려면 OS 수준 분리(별도 계정·컨테이너)가 필요하고, 그건 적용안에서
# Deferred로 미뤄 둔 항목이다. 여기서 막는 것은 "지시를 따르다가 흘러가서"
# 스스로 완료를 선언하는 기본 동작이다.
# ---------------------------------------------------------------------------
# 현재 pane id를 구한다. HERDR_PANE_ID 환경변수를 그대로 믿지 않는다 —
# `env -u HERDR_PANE_ID herdr-harness approve ...` 한 줄로 지워지기 때문이다.
# `herdr pane current`는 환경변수가 아니라 터미널을 보고 답하므로 그 우회가
# 통하지 않는다. herdr가 없으면(= Herdr 밖이면) 빈 값이다.
_runtime_current_pane_id() {
  local output
  if command -v herdr >/dev/null 2>&1; then
    output="$(herdr pane current 2>/dev/null || true)"
    output="$(_runtime_json_field "$output" pane_id)"
    if [[ -n "$output" ]]; then
      printf '%s' "$output"
      return 0
    fi
  fi
  printf '%s' "${HERDR_PANE_ID:-}"
}

_runtime_caller_is_managed_agent() {
  local root="$1" pane meta recorded
  pane="$(_runtime_current_pane_id)"
  [[ -n "$pane" ]] || return 1
  shopt -s nullglob
  for meta in "$root"/.harness/runtime/*.meta; do
    recorded="$(_runtime_meta_value "$meta" pane_id)"
    if [[ -n "$recorded" && "$recorded" == "$pane" ]]; then
      shopt -u nullglob
      printf '%s' "${meta##*/}"
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

_runtime_require_human_caller() {
  local root="$1" action="$2" meta
  meta="$(_runtime_caller_is_managed_agent "$root")" || return 0
  die "$action 은(는) Harness가 추적 중인 Agent Pane에서 실행할 수 없습니다 (pane=$(_runtime_current_pane_id), 기록=$meta).
작업 방향성에 대한 결정은 사람이 자기 Pane에서 직접 내려야 합니다 — Agent는 결과를 제출(submitted)까지만 할 수 있습니다."
}

# ---------------------------------------------------------------------------
# Agent 승인 정책 — .harness/policies/agent-policy.yaml
#
# 여기서 정하는 것은 "도구 실행 승인"뿐이다. 리눅스 명령을 하나 돌릴 때마다
# yes/no를 묻는 것은 진행을 막기만 하므로 Provider CLI 인수로 건너뛴다.
# 반대로 작업 방향성에 대한 결정(상태 전이, 완료 승인, Provider 교체)은 이
# 설정과 무관하게 사람이 herdr-harness transition/approve로만 할 수 있다.
#
# 정책 파일이 없는 기존 프로젝트에서는 아무 인수도 붙지 않는다(= 종전 동작).
# ---------------------------------------------------------------------------
# Provider별로 "승인 정책에 쓸 수 있는 인수"만 허용한다.
#
# 문자 집합만 검사하면 --add-dir / 나 --dangerously-* 같은 전혀 다른 옵션이
# 정책 파일 한 줄로 들어와 auto 모드가 사실상 full-access로 바뀐다(기록에는
# 계속 auto로 남는다). 그래서 표는 "어떤 승인 플래그를 쓸지"만 고를 수 있고,
# 임의의 argv를 넣는 통로가 되지는 않는다.
#
# 형식: '<플래그>' 또는 '<플래그>=<허용값1>,<허용값2>,...'
# Provider뿐 아니라 mode별로도 나눈다. auto가 bypass 수준 플래그를 받아들이면
# 기록에는 auto로 남으면서 실제 권한만 full-access가 된다 — 정책 파일 한 줄로
# 감사 기록과 실제 권한이 어긋나는 것이 여기서 가장 위험한 경우다.
_runtime_agent_arg_allowlist() {
  local provider="$1" mode="$2"
  case "$provider:$mode" in
    claude:auto) printf '%s\n' \
      '--permission-mode=acceptEdits,plan' ;;
    claude:bypass) printf '%s\n' \
      '--permission-mode=acceptEdits,bypassPermissions,plan,dontAsk,auto,manual' \
      '--dangerously-skip-permissions' ;;
    codex:auto) printf '%s\n' \
      '--ask-for-approval=on-request,never' \
      '-a=on-request,never' \
      '--sandbox=read-only,workspace-write' \
      '-s=read-only,workspace-write' ;;
    codex:bypass) printf '%s\n' \
      '--ask-for-approval=on-request,never' \
      '-a=on-request,never' \
      '--sandbox=read-only,workspace-write,danger-full-access' \
      '-s=read-only,workspace-write,danger-full-access' \
      '--dangerously-bypass-approvals-and-sandbox' ;;
    agy:auto) printf '%s\n' \
      '--mode=accept-edits,plan' \
      '--sandbox' ;;
    agy:bypass) printf '%s\n' \
      '--mode=accept-edits,plan' \
      '--dangerously-skip-permissions' \
      '--sandbox' ;;
    *) return 1 ;;
  esac
}

# 실패는 die가 아니라 반환값으로 알린다.
#
# cmd_dispatch는 auto-step 안에서 커맨드 치환으로 불린다. 그 안에서 die하면
# 가장 안쪽 subshell만 끝나고 호출자는 "인수 없음"으로 계속 진행해 버린다 —
# 검증 실패가 조용한 무인수 실행으로 바뀐다. 반환값으로 올리면 호출자가
# 자기 문맥에서 멈출 수 있다.
# 반환: 0=인수를 출력했다(없을 수도 있다), 1=정책 값이 유효하지 않다.
_runtime_agent_args() {
  local root="$1" provider="$2" policy mode value token flag flag_value
  local -a allowed=()
  policy="$root/.harness/policies/agent-policy.yaml"
  [[ -f "$policy" ]] || return 0
  mode="$(_runtime_yaml_scalar "$policy" approval_mode)"
  [[ -n "$mode" ]] || mode=ask
  case "$mode" in
    ask) return 0 ;;
    auto|bypass) ;;
    *)
      printf '경고: agent-policy.yaml의 approval_mode 값이 유효하지 않습니다: %s (ask로 취급)\n' "$mode" >&2
      return 0
      ;;
  esac
  value="$(_runtime_yaml_scalar "$policy" "${provider}_${mode}")"
  [[ -n "$value" ]] || return 0

  # 먼저 원문 전체를 본다 — 분리한 뒤에 검사하면 * 같은 문자가 경로 확장에
  # 먼저 걸려 검사망을 빠져나간다.
  if [[ ! "$value" =~ ^[-A-Za-z0-9=_./\ ]+$ ]]; then
    printf 'agent-policy.yaml의 %s_%s 값에 허용되지 않는 문자가 있습니다: %s\n' \
      "$provider" "$mode" "$value" >&2
    return 1
  fi

  mapfile -t allowed < <(_runtime_agent_arg_allowlist "$provider" "$mode") || true
  (( ${#allowed[@]} > 0 )) || {
    printf 'Provider 또는 모드가 유효하지 않습니다: %s / %s\n' "$provider" "$mode" >&2
    return 1
  }

  # 플래그와 값을 짝지어 확인한다. "다음 토큰이 값"인 플래그는 허용값 목록이
  # 있는 항목뿐이고, 그 밖의 토큰은 어느 것도 통과하지 않는다.
  local -a tokens=()
  read -r -a tokens <<<"$value"
  local i=0 entry matched expected
  while (( i < ${#tokens[@]} )); do
    token="${tokens[$i]}"
    matched=0
    for entry in "${allowed[@]}"; do
      flag="${entry%%=*}"
      [[ "$token" == "$flag" ]] || continue
      matched=1
      if [[ "$entry" == *=* ]]; then
        expected="${entry#*=}"
        (( i + 1 < ${#tokens[@]} )) || {
          printf 'agent-policy.yaml의 %s_%s: %s 뒤에 값이 없습니다.\n' "$provider" "$mode" "$flag" >&2
          return 1
        }
        flag_value="${tokens[$((i + 1))]}"
        case ",$expected," in
          *",$flag_value,"*) ;;
          *)
            printf 'agent-policy.yaml의 %s_%s: %s 에 허용되지 않는 값입니다: %s (허용: %s)\n' \
              "$provider" "$mode" "$flag" "$flag_value" "$expected" >&2
            return 1
            ;;
        esac
        i=$((i + 1))
      fi
      break
    done
    if (( matched == 0 )); then
      printf 'agent-policy.yaml의 %s_%s: 승인 정책에 쓸 수 없는 인수입니다: %s\n' \
        "$provider" "$mode" "$token" >&2
      printf '  (허용 인수: %s)\n' "${allowed[*]%%=*}" >&2
      return 1
    fi
    i=$((i + 1))
  done
  printf '%s' "$value"
}

_runtime_approval_mode() {
  local root="$1" policy mode
  policy="$root/.harness/policies/agent-policy.yaml"
  [[ -f "$policy" ]] || { printf 'ask (정책 파일 없음)'; return 0; }
  mode="$(_runtime_yaml_scalar "$policy" approval_mode)"
  printf '%s' "${mode:-ask}"
}

_runtime_start_agent_when_ready() {
  # 분할 직후 Pane은 Herdr가 "available shell"로 인정하기까지 수 초가 걸린다.
  # 측정 결과 4~7초. 그동안 agent start는 agent_pane_busy로 실패한다.
  # 이 대기는 Pane 준비 조건만 재확인하며, 실패한 Agent 턴을 재시도하지 않는다.
  #
  # 6번째 인자부터는 Provider CLI에 그대로 넘길 인수다(_runtime_agent_args).
  local agent_name="$1" provider="$2" pane_id="$3" timeout="$4"
  local deadline_s="${5:-30}"
  shift 5
  local -a agent_args=("$@")
  local waited=0 output status
  while :; do
    set +e
    if (( ${#agent_args[@]} > 0 )); then
      output="$(herdr agent start "$agent_name" --kind "$provider" --pane "$pane_id" --timeout "$timeout" -- "${agent_args[@]}" 2>&1)"
    else
      output="$(herdr agent start "$agent_name" --kind "$provider" --pane "$pane_id" --timeout "$timeout" 2>&1)"
    fi
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

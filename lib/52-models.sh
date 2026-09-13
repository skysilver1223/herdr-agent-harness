# Part of herdr-harness. Sourced by harness.sh — do not run directly.

# ---------------------------------------------------------------------------
# 모델 정책 조회·갱신
#
# Provider 목록 조회와 정책 파일 편집을 분리한다. _models_query_* 3종은
# self-test가 함수 스텁으로 바꿀 수 있어, 테스트 중 Agent CLI·네트워크를 전혀
# 사용하지 않는다. 조회는 --refresh일 때만 호출한다. agy·codex의 조회 결과는
# _runtime_model_id_valid를 통과한 값만 *_models 허용 목록에 쓴다. claude의
# 조회 결과(별칭)는 참고 출력 전용이며 claude_models에는 쓰지 않는다 — 별칭이
# 가리키는 실제 모델이 계정·설정에 따라 달라 Attempt에서 어느 모델이 돌았는지
# 복원할 수 없기 때문이다(task-013 결정).
# ---------------------------------------------------------------------------

_models_query_agy() {
  # cmd_test가 띄우는 하위 harness 프로세스에서도 실 Provider 조회가 새어
  # 나가지 않게 한다. models 자체 검사는 이 함수를 로컬 스텁으로 덮어쓴다.
  [[ "${HH_HARNESS_SELFTEST:-0}" != 1 ]] || return 125
  command agy models
}

_models_query_codex() {
  [[ "${HH_HARNESS_SELFTEST:-0}" != 1 ]] || return 125
  # jq는 선택 의존성이다(lib/50-runtime.sh·lib/70-status.sh 선례). 없으면
  # codex CLI조차 부르지 않는다. 127은 실제 codex 실행 파일 부재에 남겨 두고,
  # jq 부재는 별도 상태로 돌려 원인이 뒤바뀐 진단을 막는다.
  command -v jq >/dev/null 2>&1 || return 200
  command -v codex >/dev/null 2>&1 || return 127
  command codex debug models
}

_models_query_claude() {
  [[ "${HH_HARNESS_SELFTEST:-0}" != 1 ]] || return 125
  command claude -p "/model"
}

_models_now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_models_policy_key_exists() {
  local policy="$1" key="$2"
  grep -Eq "^[[:space:]]*$key:" "$policy"
}

_models_policy_scalar() {
  local policy="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      value = $0
      sub("^[[:space:]]*" key ":[[:space:]]*", "", value)
      sub(/^[[:space:]]*/, "", value)
      if (substr(value, 1, 1) == "\047" || substr(value, 1, 1) == "\042") {
        quote = substr(value, 1, 1)
        value = substr(value, 2)
        closing = index(value, quote)
        if (closing) print substr(value, 1, closing - 1)
        exit
      }
      sub(/[[:space:]]+#.*$/, "", value)
      sub(/[[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "$policy"
}

_models_read_policy_list() {
  local policy="$1" key="$2" output_name="$3"
  local -n output_ref="$output_name"
  local value token
  local -a tokens=()
  output_ref=()
  value="$(_models_policy_scalar "$policy" "$key")"
  [[ -n "$value" ]] || return 0
  [[ "$value" =~ ^[-A-Za-z0-9=_./\ ]+$ ]] || return 2
  read -r -a tokens <<<"$value"
  for token in "${tokens[@]}"; do
    _runtime_model_id_valid "$token" || return 2
    output_ref+=("$token")
  done
}

_models_join() {
  local output="" item
  for item in "$@"; do
    [[ -z "$output" ]] || output+=" "
    output+="$item"
  done
  printf '%s' "$output"
}

_models_list_contains() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$needle" == "$item" ]] && return 0
  done
  return 1
}

_models_append_unique() {
  local list="$1" value="$2" item
  local -a items=()
  [[ -n "$list" ]] && read -r -a items <<<"$list"
  for item in "${items[@]}"; do
    [[ "$item" == "$value" ]] && { printf '%s' "$list"; return 0; }
  done
  if [[ -n "$list" ]]; then
    printf '%s %s' "$list" "$value"
  else
    printf '%s' "$value"
  fi
}

# agy models는 모델 ID와 표시명을 행 단위로 돌려준다. 표시 형식의 장식이나
# 헤더는 정책 값으로 들어가면 안 되므로 첫 필드(또는 목록 기호 뒤 필드)에서
# 안전한 모델 ID처럼 생긴 값만 꺼낸다. 출력 원문은 오류 메시지에 싣지 않는다.
_models_parse_agy_output() {
  local line first second candidate
  local -A seen=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    read -r first second _ <<<"$line"
    candidate="$first"
    case "$candidate" in
      -|\*) candidate="$second" ;;
    esac
    if [[ "$candidate" =~ ^[0-9]+[.]$ || "$candidate" =~ ^[0-9]+\)$ ]]; then
      candidate="$second"
    fi
    candidate="${candidate%:}"
    [[ "$candidate" =~ [A-Za-z] && "$candidate" == *[-./=]* ]] || continue
    _runtime_model_id_valid "$candidate" || continue
    [[ -z "${seen[$candidate]+x}" ]] || continue
    seen[$candidate]=1
    printf '%s\n' "$candidate"
  done | LC_ALL=C sort
}

# codex debug models는 순수 JSON 카탈로그를 낸다(실측: {"models":[{"slug":...,
# "visibility":...,"supported_in_api":...}, ...]}). visibility가 "list"가
# 아니거나 supported_in_api가 false인 항목(예: gpt-reserve, codex-auto-review)은
# 계정에 보이지 않거나 API로 못 쓰는 모델이라 제외한다.
_models_parse_codex_output() {
  local slug
  jq -r '
    .models[]? |
    select(.visibility == "list" and .supported_in_api == true) |
    .slug // empty
  ' 2>/dev/null |
  while IFS= read -r slug; do
    _runtime_model_id_valid "$slug" || continue
    printf '%s\n' "$slug"
  done | LC_ALL=C sort
}

# claude -p "/model"은 "Available: a, b, c, or a full model ID." 줄에 별칭
# 목록을 낸다. 참고 출력 전용이라 _runtime_model_id_valid로 거르지 않는다 —
# `sonnet[1m]` 같은 별칭은 대괄호 때문에 그 검사를 통과 못 하지만, 정책에
# 쓰지 않으므로 걸러서 정보를 숨길 이유가 없다.
_models_parse_claude_output() {
  local line rest token
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    case "$line" in
      *Available:*)
        rest="${line#*Available: }"
        rest="${rest%%, or a full model ID.*}"
        rest="${rest//,/ }"
        for token in $rest; do
          printf '%s\n' "$token"
        done
        ;;
    esac
  done
}

_models_last_refresh() {
  local policy="$1" provider="$2"
  awk -v key="${provider}_models:" -v suffix="(${provider} models)" '
    index($0, key) && $0 ~ "^[[:space:]]*" key {
      if (previous ~ /^[[:space:]]*# 마지막 조회: / && index(previous, suffix)) {
        value = previous
        sub(/^[[:space:]]*# 마지막 조회: /, "", value)
        sub(/[[:space:]]+\([^()]+ models\)[[:space:]]*$/, "", value)
        print value
      }
      exit
    }
    { previous = $0 }
  ' "$policy"
}

_models_rewrite_key() {
  local file="$1" key="$2" value="$3" next
  next="$(mktemp "$(dirname "$file")/.models-key.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      match($0, /^[[:space:]]*/)
      indent = substr($0, 1, RLENGTH)
      rest = $0
      sub("^[[:space:]]*" key ":[[:space:]]*", "", rest)
      comment = ""
      if (match(rest, /[[:space:]]+#.*$/)) comment = substr(rest, RSTART)
      print indent key ": \047" value "\047" comment
      found = 1
      next
    }
    { print }
    END {
      if (!found) print "  " key ": \047" value "\047"
    }
  ' "$file" >"$next"
  chmod --reference="$file" "$next"
  mv -- "$next" "$file"
}

_models_rewrite_refresh_comment() {
  local file="$1" provider="$2" timestamp="$3" next
  next="$(mktemp "$(dirname "$file")/.models-comment.XXXXXX")"
  awk -v key="${provider}_models:" -v provider="$provider" -v timestamp="$timestamp" '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (lines[i] ~ "^[[:space:]]*# 마지막 조회: .*\\(" provider " models\\)[[:space:]]*$" &&
            i < NR && lines[i + 1] ~ "^[[:space:]]*" key) {
          continue
        }
        if (lines[i] ~ "^[[:space:]]*" key) {
          match(lines[i], /^[[:space:]]*/)
          print substr(lines[i], 1, RLENGTH) "# 마지막 조회: " timestamp " (" provider " models)"
        }
        print lines[i]
      }
    }
  ' "$file" >"$next"
  chmod --reference="$file" "$next"
  mv -- "$next" "$file"
}

# MODELS_WRITE_VALUES/KEYS와 선택적 MODELS_WRITE_REFRESH_*를 한 임시 파일에
# 모두 반영한 뒤 한 번만 교체한다. 중간 실패가 정책 파일의 일부만 바꾸지 않는다.
# MODELS_WRITE_REFRESH_PROVIDER는 배열이다 — 조회 가능한 Provider가 둘 이상
# 이어도(agy·codex) 각자의 _models 키 위에 각자의 조회 시각 주석을 남긴다.
_models_write_policy() {
  local policy="$1" temporary key provider
  temporary="$(mktemp "$(dirname "$policy")/.agent-policy.models.XXXXXX")"
  cp -p -- "$policy" "$temporary"
  for key in "${MODELS_WRITE_KEYS[@]}"; do
    _models_rewrite_key "$temporary" "$key" "${MODELS_WRITE_VALUES[$key]}"
  done
  for provider in "${MODELS_WRITE_REFRESH_PROVIDER[@]}"; do
    _models_rewrite_refresh_comment "$temporary" "$provider" "${MODELS_WRITE_REFRESH_TIME[$provider]}"
  done
  if cmp -s "$temporary" "$policy"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod --reference="$policy" "$temporary"
  mv -- "$temporary" "$policy"
}

_models_print_values() {
  local label="$1" value="$2"
  printf '  %s: %s\n' "$label" "${value:-(비어 있음)}"
}

_models_print_premium_status() {
  local premium="$1" allowed="$2" item
  local -a premium_items=() allowed_items=()
  [[ -n "$premium" ]] && read -r -a premium_items <<<"$premium"
  [[ -n "$allowed" ]] && read -r -a allowed_items <<<"$allowed"
  if (( ${#premium_items[@]} == 0 )); then
    printf '  프리미엄 선언: (비어 있음)\n'
    return 0
  fi
  printf '  프리미엄 선언:\n'
  for item in "${premium_items[@]}"; do
    if _models_list_contains "$item" "${allowed_items[@]}"; then
      printf '    %s (적용)\n' "$item"
    else
      printf '    %s (미적용 — 허용 목록에 정확히 일치하는 값 없음)\n' "$item"
    fi
  done
}

_models_print_tier_status() {
  local provider="$1" tier="$2" value="$3" allowed="$4"
  local -a allowed_items=()
  [[ -n "$allowed" ]] && read -r -a allowed_items <<<"$allowed"
  if [[ -z "$value" ]]; then
    printf '  현재 %s_tier_%s: (미설정)\n' "$provider" "$tier"
  elif ! _runtime_model_id_valid "$value"; then
    printf '  현재 %s_tier_%s: (해석 불가 — 안전한 단일 모델 ID가 아님)\n' "$provider" "$tier"
  elif _models_list_contains "$value" "${allowed_items[@]}"; then
    printf '  현재 %s_tier_%s: %s (해석: %s)\n' "$provider" "$tier" "$value" "$value"
  else
    printf '  현재 %s_tier_%s: %s (해석 불가 — %s_models 허용 목록에 없음)\n' \
      "$provider" "$tier" "$value" "$provider"
  fi
}

_models_print_selection_guide() {
  printf '%s\n' \
    '' \
    '등급·속도 선택 기준' \
    '  light: 기계적 변경 — 문자열 치환, 문서 재배치, 정해진 패턴 적용' \
    '  standard: 일반 구현 — 설계는 정해졌고 코드로 옮기는 작업' \
    '  premium: 설계 판단 포함, 또는 보안 경계·상태 전이·정책 해석 변경' \
    '  속도: high — 설계 판단·우회 검토·원인 추적 / medium — 일반 구현 / low — 기계적 변경·정형 출력' \
    '  Reviewer: premium Worker라면 한 단계 상향을 고려할 수 있으나 권고일 뿐 강제 규칙은 아님'
}

_models_print_diff() {
  local current="$1" actual_name="$2" premium="$3" item suffix
  local -n _models_diff_actual_ptr="$actual_name"
  local -a current_items=() premium_items=()
  [[ -n "$current" ]] && read -r -a current_items <<<"$current"
  [[ -n "$premium" ]] && read -r -a premium_items <<<"$premium"
  for item in "${_models_diff_actual_ptr[@]}"; do
    if ! _models_list_contains "$item" "${current_items[@]}"; then
      printf '  + %s (추가)\n' "$item"
    fi
  done
  for item in "${current_items[@]}"; do
    if ! _models_list_contains "$item" "${_models_diff_actual_ptr[@]}"; then
      suffix=""
      if _models_list_contains "$item" "${premium_items[@]}"; then
        suffix=" — 프리미엄 선언도 미적용 예정"
      fi
      printf '  - %s (조회 결과에 없음 — 삭제%s)\n' "$item" "$suffix"
    fi
  done
  for item in "${_models_diff_actual_ptr[@]}"; do
    if _models_list_contains "$item" "${current_items[@]}"; then
      printf '    %s (유지)\n' "$item"
    fi
  done
  return 0
}

cmd_models() {
  local root_arg="" refresh=0 apply=0 premium_spec provider model previous
  local root policy current_refresh query_output=""
  local -a providers=(claude codex agy) list_providers=(agy codex)
  local -a actual_agy=() actual_codex=() actual_claude=() parsed=()
  local -A premium_seen=() premium_requested=()
  local -A current_models=() current_premium=() invalid_models=() invalid_premium=()
  local -A current_tier=() current_default=()
  local -A query_ok=() query_status=() query_time=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --refresh) refresh=1; shift ;;
      --apply) apply=1; shift ;;
      --premium)
        [[ $# -ge 2 ]] || die "--premium 값(PROVIDER=MODEL)이 필요합니다."
        premium_spec="$2"; shift 2
        [[ "$premium_spec" == *=* ]] || die "--premium은 PROVIDER=MODEL 형식이어야 합니다."
        provider="${premium_spec%%=*}"; model="${premium_spec#*=}"
        valid_provider "$provider" || die "지원하지 않는 --premium Provider입니다: $provider"
        if [[ -n "$model" ]] && ! _runtime_model_id_valid "$model"; then
          die "--premium 모델은 안전한 전체 모델 ID 한 개여야 합니다."
        fi
        premium_seen[$provider]=1
        if [[ -z "$model" ]]; then
          premium_requested[$provider]=""
        else
          previous="${premium_requested[$provider]-}"
          premium_requested[$provider]="$(_models_append_unique "$previous" "$model")"
        fi
        ;;
      -h|--help)
        printf '사용법: %s models PATH [--refresh] [--premium PROVIDER=MODEL]... [--apply]\n' "$SCRIPT_NAME"
        printf '기본은 조회·diff 미리보기뿐이다. 실제 정책 갱신은 --apply를 함께 준다.\n'
        return 0
        ;;
      -*) die "알 수 없는 models 옵션: $1" ;;
      *)
        [[ -z "$root_arg" ]] || die "models에는 프로젝트 PATH를 하나만 지정할 수 있습니다."
        root_arg="$1"; shift
        ;;
    esac
  done
  [[ -n "$root_arg" ]] || die "models에는 Harness 프로젝트 PATH가 필요합니다."

  root="$(project_root "$root_arg")"
  require_git_baseline "$root"
  policy="$root/.harness/policies/agent-policy.yaml"
  [[ -f "$policy" ]] || die "agent-policy.yaml이 없습니다: $policy"

  local key count tier role role_tier role_effort
  for role in worker reviewer; do
    for key in "${role}_default_tier" "${role}_default_effort"; do
      count="$(grep -Ec "^[[:space:]]*$key:" "$policy" 2>/dev/null || true)"
      (( count <= 1 )) || die "agent-policy.yaml에 키가 중복되었습니다: $key"
    done
  done
  for provider in "${providers[@]}"; do
    for key in "${provider}_models" "${provider}_default_model" \
      "${provider}_tier_light" "${provider}_tier_standard" "${provider}_tier_premium" \
      "${provider}_premium_models"; do
      count="$(grep -Ec "^[[:space:]]*$key:" "$policy" 2>/dev/null || true)"
      (( count <= 1 )) || die "agent-policy.yaml에 키가 중복되었습니다: $key"
    done
    current_default[$provider]="$(_models_policy_scalar "$policy" "${provider}_default_model")"
    for tier in light standard premium; do
      current_tier["$provider:$tier"]="$(_models_policy_scalar "$policy" "${provider}_tier_${tier}")"
    done
    parsed=()
    if _models_read_policy_list "$policy" "${provider}_models" parsed; then
      current_models[$provider]="$(_models_join "${parsed[@]}")"
      invalid_models[$provider]=0
    else
      current_models[$provider]=""
      invalid_models[$provider]=1
    fi
    parsed=()
    if _models_read_policy_list "$policy" "${provider}_premium_models" parsed; then
      current_premium[$provider]="$(_models_join "${parsed[@]}")"
      invalid_premium[$provider]=0
    else
      current_premium[$provider]=""
      invalid_premium[$provider]=1
    fi
  done

  # 실제 조회는 --refresh일 때만 한다. 그렇지 않으면 --premium만 주거나
  # 인수 없이 부른 호출에서도 매번 agy·codex·claude CLI를 때려 조회를 오인하게
  # 만든다(task-013 제보). 실패 출력 원문은 인증 정보가 섞일 수 있어 버리고,
  # 정책 보존 경고만 낸다.
  if [[ "$refresh" -eq 1 ]]; then
    for provider in "${list_providers[@]}"; do
      local -n _models_actual_ptr="actual_$provider"
      _models_actual_ptr=()
      query_output=""
      if query_output="$("_models_query_$provider" 2>/dev/null)"; then
        mapfile -t _models_actual_ptr < <("_models_parse_${provider}_output" <<<"$query_output")
        if (( ${#_models_actual_ptr[@]} > 0 )); then
          query_ok[$provider]=1
          query_time[$provider]="$(_models_now_utc)"
        else
          query_ok[$provider]=0
          query_status[$provider]=1
        fi
      else
        query_status[$provider]=$?
        query_ok[$provider]=0
      fi
    done

    query_output=""
    if query_output="$(_models_query_claude 2>/dev/null)"; then
      mapfile -t actual_claude < <(_models_parse_claude_output <<<"$query_output")
      if (( ${#actual_claude[@]} > 0 )); then
        query_ok[claude]=1
        query_time[claude]="$(_models_now_utc)"
      else
        query_ok[claude]=0
        query_status[claude]=1
      fi
    else
      query_status[claude]=$?
      query_ok[claude]=0
    fi
  fi

  printf '\n역할 기본 선언\n'
  for role in worker reviewer; do
    role_tier="$(_models_policy_scalar "$policy" "${role}_default_tier")"
    role_effort="$(_models_policy_scalar "$policy" "${role}_default_effort")"
    if [[ -n "$role_tier" ]] && ! _runtime_model_tier_valid "$role_tier"; then
      printf '  %s_default_tier: (해석 불가 — light|standard|premium 중 하나가 아님)\n' "$role"
    else
      printf '  %s_default_tier: %s\n' "$role" "${role_tier:-(미설정)}"
    fi
    if [[ -n "$role_effort" ]] && ! _runtime_effort_valid "$role_effort"; then
      printf '  %s_default_effort: (해석 불가 — low|medium|high 중 하나가 아님)\n' "$role"
    else
      printf '  %s_default_effort: %s\n' "$role" "${role_effort:-(미설정)}"
    fi
  done

  _models_print_selection_guide

  if [[ "$refresh" -eq 1 || ${#premium_seen[@]} -gt 0 ]]; then
    if [[ "$apply" -eq 1 ]]; then
      info "적용 모드 — 아래 모델 정책 변경을 agent-policy.yaml에 반영합니다."
    else
      info "미리보기 모드(기본값) — 실제로 갱신하려면 --apply. 아래는 바뀔 내용이다."
    fi
  fi

  local shown_models shown_premium last_refresh item
  local -a old_premium_items=() new_premium_items=()
  for provider in "${providers[@]}"; do
    local -n _models_actual_ptr="actual_$provider"
    printf '\n%s' "$provider"
    if [[ "$provider" == claude ]]; then
      printf '   참고 조회 전용(별칭) — claude_models는 계속 사람이 관리합니다\n'
    else
      last_refresh="$(_models_last_refresh "$policy" "$provider")"
      printf '   마지막 조회: %s\n' "${last_refresh:-기록 없음}"
    fi

    if [[ "${invalid_models[$provider]}" -eq 1 ]]; then
      printf '  현재 %s_models: (정책 값 오류 — 안전한 모델 ID 목록이 아님)\n' "$provider"
    else
      _models_print_values "현재 ${provider}_models" "${current_models[$provider]}"
    fi
    _models_print_values "현재 ${provider}_default_model" "${current_default[$provider]}"
    for tier in light standard premium; do
      _models_print_tier_status "$provider" "$tier" \
        "${current_tier["$provider:$tier"]}" "${current_models[$provider]}"
    done
    if [[ "${invalid_premium[$provider]}" -eq 1 ]]; then
      printf '  현재 %s_premium_models: (정책 값 오류 — 안전한 모델 ID 목록이 아님)\n' "$provider"
    else
      _models_print_values "현재 ${provider}_premium_models" "${current_premium[$provider]}"
    fi

    shown_models="${current_models[$provider]}"
    shown_premium="${current_premium[$provider]}"
    if [[ "$provider" != claude && "$refresh" -eq 1 && "${query_ok[$provider]:-0}" -eq 1 ]]; then
      shown_models="$(_models_join "${_models_actual_ptr[@]}")"
    fi
    if [[ -n "${premium_seen[$provider]+x}" ]]; then
      shown_premium="${premium_requested[$provider]}"
      old_premium_items=(); new_premium_items=()
      [[ -n "${current_premium[$provider]}" ]] && read -r -a old_premium_items <<<"${current_premium[$provider]}"
      [[ -n "$shown_premium" ]] && read -r -a new_premium_items <<<"$shown_premium"
      printf '  %s_premium_models 변경:\n' "$provider"
      for item in "${old_premium_items[@]}"; do
        if ! _models_list_contains "$item" "${new_premium_items[@]}"; then
          printf '  - %s (프리미엄에서 제거 — 승인 범위 축소)\n' "$item"
        fi
      done
      for item in "${new_premium_items[@]}"; do
        if ! _models_list_contains "$item" "${old_premium_items[@]}"; then
          printf '  + %s (프리미엄으로 선언)\n' "$item"
        fi
      done
      if [[ "${current_premium[$provider]}" == "$shown_premium" ]]; then
        printf '    (변경 없음)\n'
      fi
    fi

    if [[ "$provider" == claude ]]; then
      if [[ "$refresh" -eq 1 ]]; then
        if [[ "${query_ok[claude]:-0}" -eq 1 ]]; then
          printf '  참고 조회: %s (claude /model, 허용 목록에는 반영하지 않음)\n' "${query_time[claude]}"
          _models_print_values "참고: 조회된 별칭" "$(_models_join "${actual_claude[@]}")"
        else
          printf '  참고: claude 별칭 조회 실패(상태 %s) — claude_models는 항상 사람이 관리하므로 영향 없습니다.\n' "${query_status[claude]:-}"
        fi
      fi
    else
      if [[ "$refresh" -eq 1 ]]; then
        if [[ "${query_ok[$provider]:-0}" -eq 1 ]]; then
          printf '  이번 조회: %s (%s models)\n' "${query_time[$provider]}" "$provider"
          _models_print_values "조회된 적용 가능 모델" "$(_models_join "${_models_actual_ptr[@]}")"
          _models_print_diff "${current_models[$provider]}" "actual_$provider" "$shown_premium"
        elif [[ "$provider" == codex && "${query_status[codex]:-}" -eq 200 ]]; then
          printf '  경고: jq가 없어 codex 모델을 조회하지 못했습니다 — 삭제를 계산하지 않고 기존 정책을 보존합니다. jq 설치 후 --refresh를 다시 실행하세요.\n'
        elif [[ "$provider" == codex && "${query_status[codex]:-}" -eq 127 ]]; then
          printf '  경고: codex CLI 실행 파일을 찾지 못해 모델을 조회하지 못했습니다 — 삭제를 계산하지 않고 기존 정책을 보존합니다. codex 설치와 PATH를 확인하세요.\n'
        else
          printf '  경고: %s models 조회 실패(상태 %s 또는 빈 목록) — 삭제를 계산하지 않고 기존 정책을 보존합니다.\n' "$provider" "${query_status[$provider]:-}"
        fi
      fi
    fi
    _models_print_premium_status "$shown_premium" "$shown_models"
  done

  MODELS_WRITE_KEYS=()
  declare -gA MODELS_WRITE_VALUES=()
  MODELS_WRITE_REFRESH_PROVIDER=()
  declare -gA MODELS_WRITE_REFRESH_TIME=()
  local proposed_changes=0 desired_models existing_value

  if [[ "$refresh" -eq 1 ]]; then
    for provider in "${list_providers[@]}"; do
      local -n _models_actual_ptr="actual_$provider"
      if [[ "${query_ok[$provider]:-0}" -eq 1 ]]; then
        desired_models="$(_models_join "${_models_actual_ptr[@]}")"
        if [[ "${invalid_models[$provider]}" -eq 1 || "${current_models[$provider]}" != "$desired_models" ]] ||
           ! _models_policy_key_exists "$policy" "${provider}_models"; then
          MODELS_WRITE_KEYS+=("${provider}_models")
          MODELS_WRITE_VALUES["${provider}_models"]="$desired_models"
          proposed_changes=$((proposed_changes + 1))
        fi
        current_refresh="$(_models_last_refresh "$policy" "$provider")"
        # 동일 목록의 연속 적용은 byte-for-byte 멱등이다. 조회 주석은 목록이 실제로
        # 바뀌거나 아직 없을 때만 갱신한다. Provider가 둘 이상이어도 각자 독립
        # 판단이다 — codex가 멱등이어도 agy가 바뀌었으면 agy 주석만 갱신한다.
        if [[ -z "$current_refresh" || "${current_models[$provider]}" != "$desired_models" || "${invalid_models[$provider]}" -eq 1 ]]; then
          MODELS_WRITE_REFRESH_PROVIDER+=("$provider")
          MODELS_WRITE_REFRESH_TIME[$provider]="${query_time[$provider]}"
          proposed_changes=$((proposed_changes + 1))
        fi
      else
        info "경고: $provider --refresh를 적용하지 않았습니다. 조회 실패는 모델 삭제로 바꾸지 않습니다."
      fi
    done
  fi

  for provider in "${providers[@]}"; do
    [[ -n "${premium_seen[$provider]+x}" ]] || continue
    key="${provider}_premium_models"
    existing_value="${current_premium[$provider]}"
    if [[ "${invalid_premium[$provider]}" -eq 1 || "$existing_value" != "${premium_requested[$provider]}" ]] ||
       ! _models_policy_key_exists "$policy" "$key"; then
      MODELS_WRITE_KEYS+=("$key")
      MODELS_WRITE_VALUES[$key]="${premium_requested[$provider]}"
      proposed_changes=$((proposed_changes + 1))
    fi
  done

  if [[ "$apply" -eq 1 && "$proposed_changes" -gt 0 ]]; then
    if _models_write_policy "$policy"; then
      info "모델 정책을 적용했습니다: $policy"
    else
      info "모델 정책은 이미 동일합니다."
    fi
  elif [[ "$apply" -eq 1 ]]; then
    info "적용할 모델 정책 변경이 없습니다."
  elif [[ "$proposed_changes" -gt 0 ]]; then
    info "요약: 변경 $proposed_changes · 미리보기뿐이라 실제로는 안 바뀜(적용하려면 --apply)"
  fi
}

# Part of herdr-harness. Sourced by harness.sh — do not run directly.

# ---------------------------------------------------------------------------
# 제한 스키마 YAML 리더
# 범용 YAML 파서를 흉내 내지 않는다. Harness가 생성한 고정 스키마만 엄격히 읽고,
# 정확히 한 번 매칭되지 않으면 실패한다.
# ---------------------------------------------------------------------------

yaml_unquote() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  case "$value" in
    \'*\') value="${value:1:${#value}-2}"; value="${value//\'\'/\'}" ;;
    \"*\") value="${value:1:${#value}-2}" ;;
  esac
  printf '%s' "$value"
}

yaml_scalar() {
  local file="$1" key="$2" required="${3:-required}"
  local count line
  [[ -f "$file" ]] || die "YAML 파일이 없습니다: $file"
  count="$(grep -c "^${key}:" "$file" 2>/dev/null || true)"
  if [[ "$count" -eq 0 ]]; then
    [[ "$required" == optional ]] || die "필수 키가 없습니다: $key ($file)"
    return 0
  fi
  [[ "$count" -eq 1 ]] || die "키가 중복되었습니다: $key ($file)"
  line="$(grep -m1 "^${key}:" "$file")"
  yaml_unquote "${line#"${key}":}"
}

yaml_flow_list() {
  local file="$1" key="$2"
  local line inner item
  line="$(grep -m1 "^${key}:" "$file" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 0
  inner="${line#"${key}":}"
  inner="$(yaml_unquote "$inner")"
  case "$inner" in
    \[*\]) inner="${inner:1:${#inner}-2}" ;;
    *) return 0 ;;
  esac
  [[ -n "${inner//[[:space:]]/}" ]] || return 0
  local IFS=','
  for item in $inner; do
    item="$(yaml_unquote "$item")"
    [[ -z "$item" ]] || printf '%s\n' "$item"
  done
}

# Task별 수동 검토 예외. 범용 YAML 파서로 넓히지 않고 아래 고정 블록만 읽는다.
#
# policy_override:
#   allow_self_review: true
#   reason: quota_exhaustion
#
# 호출 뒤 TASK_REVIEW_MODE(ai|manual), TASK_REVIEW_REASON, TASK_REVIEW_POLICY_ERROR를
# 확인한다. reviewer=user|human은 별도 Provider가 아니라 사용자 수동 검토를 뜻한다.
# 같은 Provider 예외도 AI self-review가 아니라 manual lifecycle로만 해석한다.
task_review_policy() {
  local file="$1" worker reviewer block_count malformed_line unknown_line
  local allow_count reason_count allow_value reason_value
  TASK_REVIEW_MODE=""
  TASK_REVIEW_REASON=""
  TASK_REVIEW_POLICY_ERROR=""

  [[ -f "$file" ]] || {
    TASK_REVIEW_POLICY_ERROR="Task YAML 파일이 없습니다: $file"
    return 1
  }

  worker="$(yaml_scalar "$file" primary_worker)"
  reviewer="$(yaml_scalar "$file" reviewer)"

  block_count="$(awk '
    { sub(/\r$/, "") }
    /^policy_override:/ { n++ }
    END { print n + 0 }
  ' "$file")"
  if (( block_count > 1 )); then
    TASK_REVIEW_POLICY_ERROR="policy_override 블록이 중복되었습니다"
    return 1
  fi

  if (( block_count == 1 )); then
    malformed_line="$(awk '
      { sub(/\r$/, "") }
      /^policy_override:/ && $0 != "policy_override:" { print NR; exit }
    ' "$file")"
    if [[ -n "$malformed_line" ]]; then
      TASK_REVIEW_POLICY_ERROR="policy_override는 고정 중첩 블록이어야 합니다 (line $malformed_line)"
      return 1
    fi

    unknown_line="$(awk '
      { sub(/\r$/, "") }
      /^policy_override:$/ { inside = 1; next }
      inside && (/^[^[:space:]#]/ || /^#/) { inside = 0 }
      inside && /^[[:space:]]*$/ { next }
      inside && /^  #/ { next }
      inside && /^  (allow_self_review|reason):/ { next }
      inside { print NR; exit }
    ' "$file")"
    if [[ -n "$unknown_line" ]]; then
      TASK_REVIEW_POLICY_ERROR="policy_override에 알 수 없거나 잘못 들여쓴 항목이 있습니다 (line $unknown_line)"
      return 1
    fi

    allow_count="$(awk '
      { sub(/\r$/, "") }
      /^policy_override:$/ { inside = 1; next }
      inside && (/^[^[:space:]#]/ || /^#/) { inside = 0 }
      inside && /^  allow_self_review:/ { n++ }
      END { print n + 0 }
    ' "$file")"
    reason_count="$(awk '
      { sub(/\r$/, "") }
      /^policy_override:$/ { inside = 1; next }
      inside && (/^[^[:space:]#]/ || /^#/) { inside = 0 }
      inside && /^  reason:/ { n++ }
      END { print n + 0 }
    ' "$file")"
    if (( allow_count != 1 || reason_count != 1 )); then
      TASK_REVIEW_POLICY_ERROR="policy_override에는 allow_self_review와 reason이 각각 정확히 하나 필요합니다"
      return 1
    fi

    allow_value="$(awk '
      { sub(/\r$/, "") }
      /^policy_override:$/ { inside = 1; next }
      inside && (/^[^[:space:]#]/ || /^#/) { inside = 0 }
      inside && /^  allow_self_review:/ {
        sub(/^  allow_self_review:[[:space:]]*/, ""); print; exit
      }
    ' "$file")"
    allow_value="$(yaml_unquote "$allow_value")"
    case "$allow_value" in
      true|false) ;;
      *)
        TASK_REVIEW_POLICY_ERROR="policy_override.allow_self_review는 true 또는 false여야 합니다"
        return 1
        ;;
    esac

    reason_value="$(awk '
      { sub(/\r$/, "") }
      /^policy_override:$/ { inside = 1; next }
      inside && (/^[^[:space:]#]/ || /^#/) { inside = 0 }
      inside && /^  reason:/ {
        sub(/^  reason:[[:space:]]*/, ""); print; exit
      }
    ' "$file")"
    reason_value="$(yaml_unquote "$reason_value")"
    if [[ "$allow_value" == true && -z "$reason_value" ]]; then
      TASK_REVIEW_POLICY_ERROR="policy_override.allow_self_review=true에는 비어 있지 않은 reason이 필요합니다"
      return 1
    fi
  else
    allow_value=false
    reason_value=""
  fi

  if ! valid_provider "$worker"; then
    TASK_REVIEW_POLICY_ERROR="알 수 없는 primary_worker=$worker"
    return 1
  fi

  case "$reviewer" in
    user|human)
      TASK_REVIEW_MODE=manual
      TASK_REVIEW_REASON="${reason_value:-manual_reviewer_$reviewer}"
      return 0
      ;;
  esac
  if ! valid_provider "$reviewer"; then
    TASK_REVIEW_POLICY_ERROR="알 수 없는 reviewer=$reviewer"
    return 1
  fi

  if [[ "$worker" == "$reviewer" ]]; then
    if [[ "$allow_value" == true && -n "$reason_value" ]]; then
      TASK_REVIEW_MODE=manual
      TASK_REVIEW_REASON="$reason_value"
      return 0
    fi
    TASK_REVIEW_POLICY_ERROR="Worker와 Reviewer가 같습니다 ($worker). policy_override.allow_self_review=true와 비어 있지 않은 reason이 필요합니다"
    return 1
  fi

  TASK_REVIEW_MODE=ai
  return 0
}

project_field() {
  local root="$1" section="$2" key="$3"
  local file="$root/.harness/project.yaml"
  local count line
  [[ -f "$file" ]] || die "project.yaml이 없습니다: $file"
  count="$(awk -v s="$section:" -v k="  $key:" '
    { sub(/\r$/, "") }
    $0 == s { inside = 1; next }
    /^[^[:space:]#]/ { inside = 0 }
    inside && index($0, k) == 1 { n++ }
    END { print n + 0 }' "$file")"
  [[ "$count" -eq 1 ]] || die "project.yaml에서 $section.$key 를 정확히 한 번 찾지 못했습니다 (발견 $count 회)."
  line="$(awk -v s="$section:" -v k="  $key:" '
    { sub(/\r$/, "") }
    $0 == s { inside = 1; next }
    /^[^[:space:]#]/ { inside = 0 }
    inside && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$file")"
  yaml_unquote "$line"
}

task_file() {
  local root="$1" task_id="$2"
  local path="$root/.harness/tasks/${task_id}.yaml"
  [[ -f "$path" ]] || die "Task 파일이 없습니다: $path"
  printf '%s\n' "$path"
}

task_ids() {
  local root="$1" path base
  for path in "$root"/.harness/tasks/*.yaml; do
    [[ -f "$path" ]] || continue
    base="$(basename "$path" .yaml)"
    [[ "$base" != TEMPLATE ]] || continue
    printf '%s\n' "$base"
  done
}

valid_task_status() {
  case "$1" in
    draft|ready|active|submitted|reviewing|changes_requested|blocked|handover_required|awaiting_approval|completed) return 0 ;;
    *) return 1 ;;
  esac
}

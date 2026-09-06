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

project_field() {
  local root="$1" section="$2" key="$3"
  local file="$root/.harness/project.yaml"
  local count line
  [[ -f "$file" ]] || die "project.yaml이 없습니다: $file"
  count="$(awk -v s="$section:" -v k="  $key:" '
    $0 == s { inside = 1; next }
    /^[^[:space:]#]/ { inside = 0 }
    inside && index($0, k) == 1 { n++ }
    END { print n + 0 }' "$file")"
  [[ "$count" -eq 1 ]] || die "project.yaml에서 $section.$key 를 정확히 한 번 찾지 못했습니다 (발견 $count 회)."
  line="$(awk -v s="$section:" -v k="  $key:" '
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


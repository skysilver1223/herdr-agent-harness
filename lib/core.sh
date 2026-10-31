# herdr-harness: 공통 함수 — 출력·임시 파일·Secret 검사·설정 읽기·경로·Acceptance Criteria.
# harness.sh가 source한다. 단독 실행하지 않는다.

HARNESS_VERSION="2.3.1"
shopt -s inherit_errexit 2>/dev/null || true   # harness.sh를 거치지 않고 source해도 같은 규칙(테스트 등)
ROOT=""
TMP_FILES=()

trap 'rm -f -- ${TMP_FILES[@]+"${TMP_FILES[@]}"}' EXIT
# die는 3으로 끝난다. 그 밖의 예상하지 못한 실패는 어느 줄인지 남겨 조용히 끝나지 않게 한다.
# 주의: set -E라 이 trap은 프로세스 치환 <(…) 안에도 상속된다. 거기 넣는 명령은 실패해도 되면 || true를 붙인다.
on_err() { [[ "$1" -eq 3 ]] || printf 'harness: %s:%s 에서 실패 (exit %s)\n' "${3##*/}" "$2" "$1" >&2; }
trap 'on_err "$?" "$LINENO" "${BASH_SOURCE[0]:-}"' ERR

die()  { printf '오류: %b\n' "$*" >&2; exit 3; }
info() { printf '[harness] %s\n' "$*"; }
warn() { printf '[harness] 경고: %s\n' "$*" >&2; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
nap()  { [[ -n "${HARNESS_NO_SLEEP:-}" ]] || sleep "$1"; }
rel()  { printf '%s' "${1#"$ROOT/"}"; }
need_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "잘못된 ID입니다: $1"; }
yaml_q() { local v="${1//\'/\'\'}"; printf "'%s'" "$v"; }

# 명령의 출력과 종료 코드를 OUT·RC에 담는다. set -e를 건드리지 않고 실패를 다룬다.
hcap() { RC=0; OUT="$("$@" 2>&1)" || RC=$?; }

# 하위 명령을 별도 프로세스로 실행한다. 게이트가 die해도 호출자(run 등)는 살아남는다.
harness_child() { hcap bash "$HARNESS_BIN" -C "$ROOT" "$@"; }

# 같은 디렉터리의 임시 파일에 쓴 뒤 mv한다. 중간 실패가 반쪽 파일을 남기지 않는다.
write_atomic() {
  local dst="$1" tmp
  mkdir -p "$(dirname "$dst")"
  tmp="$(mktemp "$(dirname "$dst")/.harness-tmp.XXXXXX")"
  TMP_FILES+=("$tmp")
  cat >"$tmp"
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$dst"
}

# Prompt·기록으로 나가기 전 마지막 그물. Provider 토큰 접두사는 단어 경계에서만 본다
# (task-sk-... 같은 평범한 ID를 키로 오인하면 dispatch가 영구히 막힌다).
has_secret() {
  # 값으로 보이는 토큰만 잡는다: 따옴표(선택) 뒤 8자 이상, 끝은 공백·따옴표·;·,·줄끝.
  # 첫 글자는 $·괄호·<·{ 로 시작하지 않아야 한다(${VAR}, <placeholder>, os.getenv(…), Optional[str]은 통과).
  # 그래서 "Password: 8자 이상" 같은 문장과 코드는 통과하고, 'hunter2abc', P@ssw0rd!23, Xk9#mP2$vLq8,
  # "password": "…"(JSON), `…`(백틱) 같은 값은 잡는다. 작은따옴표는 $'\x27'로 넣는다
  # (grep ERE는 \047 같은 8진 표기를 해석하지 않는다).
  local q=$'\x27' v='[!#%&*+./0-9:=?@A-Z^_a-z|~-]' w='[!#%&*+./0-9:=?@A-Z^_a-z|~$<>{}\\-]'
  LC_ALL=C grep -Eqi \
    -e 'AKIA[0-9A-Z]{8,}' \
    -e 'BEGIN[[:space:]]+(RSA |EC |DSA |OPENSSH )?PRIVATE KEY' \
    -e "(password|passwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret)[\"$q]?[[:space:]]*[:=][[:space:]]*[\"$q\`]?$v$w{7,}([\"$q\`;,]|[[:space:]]|\$)" \
    -e 'authorization[[:space:]]*:[[:space:]]*(bearer|basic)[[:space:]]' \
    -e '(^|[^A-Za-z0-9_-])(gh[pousr]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9_-]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.)' \
    "$@"
}

# --------------------------------------------------------------------------
# 제한 스키마 YAML — Harness가 만든 고정 형식만 읽는다. 모르는 형식은 조용히
# 넘어가지 않고 거부한다(검사를 건너뛴 것을 통과로 착각하는 게 가장 위험하다).
# --------------------------------------------------------------------------
unquote() {
  local v="${1%$'\r'}"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  if [[ ${#v} -ge 2 && "$v" == \'*\' ]]; then v="${v:1:${#v}-2}"; v="${v//\'\'/\'}"
  elif [[ ${#v} -ge 2 && "$v" == \"*\" ]]; then v="${v:1:${#v}-2}"
  elif [[ "$v" == *[[:space:]]#* ]]; then unquote "${v%%[[:space:]]#*}"; return 0
  fi
  printf '%s' "$v"
}

yget() {  # FILE KEY → 최상위 'KEY: 값'. 없으면 빈 값, 중복이면 실패
  local file="$1" key="$2" n line
  [[ -f "$file" ]] || die "파일이 없습니다: $file"
  n="$(grep -c "^$key:" "$file" || true)"
  (( n <= 1 )) || die "키가 중복됐습니다: $key ($file)"
  line="$(grep -m1 "^$key:" "$file" || true)"
  unquote "${line#"$key:"}"
}

ylist() {  # FILE KEY → 'KEY: [a, b]' 항목을 한 줄씩. 블록 목록(- a)은 거부한다
  local v item
  local -a items=()
  v="$(yget "$1" "$2")"
  if [[ -z "$v" ]] && awk -v k="$2:" 'f && !/^[[:space:]]*(#|$)/ { r = /^[[:space:]]*-/ ? 0 : 1; d = 1; exit } index($0, k) == 1 { f = 1 } END { exit d ? r : 1 }' "$1"; then
    die "$2는 [a, b] 한 줄 형식으로 쓴다 (블록 목록 미지원): $1"
  fi
  [[ -z "$v" || "$v" == \[*\] ]] || die "$2는 [a, b] 형식이어야 합니다: $1"
  [[ -n "$v" ]] || return 0
  IFS=, read -r -a items <<<"${v:1:${#v}-2}"
  for item in ${items[@]+"${items[@]}"}; do
    item="$(unquote "$item")"
    [[ -z "$item" ]] || printf '%s\n' "$item"
  done
}

sget() {  # FILE SECTION KEY [DEFAULT] → 'SECTION:' 아래 '  KEY: 값' (파일·키가 없으면 DEFAULT)
  local v=""
  if [[ -f "$1" ]]; then
    v="$(awk -v s="$2:" -v k="  $3:" '
      { sub(/\r$/, ""); h = $0; sub(/[ \t]+#.*$/, "", h); sub(/[ \t]+$/, "", h) }
      h == s { inside = 1; next }
      /^[^[:space:]#]/ { inside = 0 }
      inside && index($0, k) == 1 { print substr($0, length(k) + 1); exit }
    ' "$1")"
    v="$(unquote "$v")"
  fi
  printf '%s' "${v:-${4:-}}"
}
pget() { sget "$ROOT/.harness/project.yaml" "$@"; }   # SECTION KEY [DEFAULT] → project.yaml

pnum() {  # SECTION KEY DEFAULT → 양의 정수만 (설정 값을 산술식에 그대로 넣지 않는다)
  local v
  v="$(pget "$1" "$2" "$3")"
  [[ "$v" =~ ^[0-9]+$ ]] || die "project.yaml $1.$2는 숫자여야 합니다: $v"
  printf '%s' "$((10#$v))"
}

set_field() {  # TASK_FILE KEY VALUE — 최상위 키 한 줄만 원자적으로 바꾼다
  local tf="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "$(dirname "$tf")/.harness-tmp.XXXXXX")"
  TMP_FILES+=("$tmp")
  awk -v k="$key" -v v="$value" '!d && index($0, k ":") == 1 { print k ": " v; d = 1; next } { print }' "$tf" >"$tmp"
  grep -qxF "$key: $value" "$tmp" || die "$key 갱신 실패: $tf"
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$tf"
}

upsert_field() {  # TASK_FILE KEY VALUE — 있으면 바꾸고 없으면 끝에 덧붙인다
  if grep -q "^$2:" "$1"; then set_field "$1" "$2" "$3"; return 0; fi
  [[ -z "$(tail -c1 "$1")" ]] || printf '\n' >>"$1"
  printf '%s: %s\n' "$2" "$3" >>"$1"
}

pset() {  # SECTION KEY VALUE — project.yaml의 'SECTION:' 아래 '  KEY: VALUE'를 바꾸거나 추가한다
  local f="$ROOT/.harness/project.yaml" tmp
  tmp="$(mktemp "$(dirname "$f")/.harness-tmp.XXXXXX")"
  TMP_FILES+=("$tmp")
  awk -v s="$1:" -v k="$2" -v v="$3" '
    { sub(/\r$/, ""); h = $0; sub(/[ \t]+#.*$/, "", h); sub(/[ \t]+$/, "", h) }
    h == s { print; inside = 1; seen = 1; next }
    inside && /^[^[:space:]#]/ { if (!done) { print "  " k ": " v; done = 1 } inside = 0 }
    inside && index($0, "  " k ":") == 1 { if (!done) { print "  " k ": " v; done = 1 } next }
    { print }
    END { if (inside && !done) print "  " k ": " v; if (!seen) { print ""; print s; print "  " k ": " v } }
  ' "$f" >"$tmp"
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$f"
}

# --------------------------------------------------------------------------
# 검토 수준 — 결과는 Worker와 독립된 Reviewer가 판정한다. 기본은 다른 회사(cross_provider).
# 한 회사만 쓸 수 있는 환경(회사 정책·쿼터 소진)을 위한 예외가 cross_model·same_model이며,
# 기본보다 낮추려면 결정 기록(review-level 명령 또는 review.fallback_level 자동 하향)이 있어야 한다.
# --------------------------------------------------------------------------
level_rank() { case "$1" in cross_provider) echo 3 ;; cross_model) echo 2 ;; same_model) echo 1 ;; *) echo 0 ;; esac; }
valid_level() { case "$1" in cross_provider|cross_model|same_model) return 0 ;; *) return 1 ;; esac; }
level_name() {
  case "$1" in
    cross_provider) echo '다른 회사' ;; cross_model) echo '같은 회사·다른 모델' ;; same_model) echo '같은 모델·별도 세션' ;; *) echo "$1" ;;
  esac
}

actual_level() {  # WORKER_PROVIDER WORKER_MODEL REVIEWER_PROVIDER REVIEWER_MODEL → 실제로 성립한 검토 수준
  local wm="${2:-Provider 기본값}" rm="${4:-Provider 기본값}"
  if [[ "$1" != "$3" ]]; then echo cross_provider
  elif [[ "$wm" != "Provider 기본값" && "$rm" != "Provider 기본값" && "$wm" != "$rm" ]]; then echo cross_model
  else echo same_model; fi
}

latest_level_record() {  # TASK|"" → 최신 검토 수준 결정 기록 (Task 단위 또는 프로젝트 단위)
  local prefix k
  if [[ -n "$1" ]]; then prefix="$1-review-level-"; else prefix="review-level-"; fi
  k="$(last_n "$ROOT/.harness/decisions" "$prefix" .md)"
  (( k == 0 )) || printf '%s/.harness/decisions/%s%s.md' "$ROOT" "$prefix" "$k"
}

# 결정 기록이 기준이다. Task의 review_level 줄은 기록을 비춘 것일 뿐이라, 줄을 지우거나 바꿔도 낮아지지 않는다.
# 또 계획 승인 때 기록한 수준보다 낮아지려면 그 승인 이후의 결정 기록(Task 또는 프로젝트)이 있어야 한다.
required_level() {  # TASK → 이 Task에 필요한 검토 수준
  local tf lv rec field plv
  tf="$(task_file "$1")"
  field="$(yget "$tf" review_level)"
  rec="$(latest_level_record "$1")"
  if [[ -n "$rec" ]]; then
    lv="$(rec_get "$rec" 수준)"
    valid_level "$lv" || die "$(rel "$rec")의 수준 값이 올바르지 않습니다: $lv"
    [[ -z "$field" || "$field" == "$lv" ]] ||
      die "$1의 review_level($field)이 결정 기록($(rel "$rec"): $lv)과 다릅니다. 검토 수준은 review-level 명령으로만 바꾼다."
  elif [[ -n "$field" ]]; then
    die "$1의 검토 수준($field)에 결정 기록이 없습니다. 사용자 결정은 review-level 명령으로 남긴다."
  else
    lv="$(project_level)" || exit 3
  fi
  plv="$(plan_cell "$1" '검토 수준')"
  if valid_level "$plv" && (( $(level_rank "$lv") < $(level_rank "$plv") )); then
    newer_level_record "$1" "$plv" || lv="$plv"
  fi
  valid_level "$lv" || die "$1의 검토 수준을 정할 수 없습니다 (${lv:-빈 값})."
  printf '%s' "$lv"
}

# 계획 승인 이후에 새 검토 수준 결정 기록이 생겼는가. 승인 표의 "수준 근거"(승인 당시 기록 번호)와
# 비교하므로 시계와 무관하다. 그 열이 없는 이전 형식 표는 승인 시각과 비교한다(같은 초는 이후로 보지 않음).
newer_level_record() {  # TASK PLAN_LEVEL
  local cell tn pn t pt r bt bp k
  cell="$(plan_cell "$1" '수준 근거')"
  tn="$(last_n "$ROOT/.harness/decisions" "$1-review-level-" .md)"
  pn="$(last_n "$ROOT/.harness/decisions" "review-level-" .md)"
  if [[ "$cell" =~ ^task:([0-9]+)\ project:([0-9]+)$ ]]; then
    bt=$((10#${BASH_REMATCH[1]})); bp=$((10#${BASH_REMATCH[2]}))
    (( tn <= bt )) || return 0                 # 승인 뒤의 Task 결정
    (( bt == 0 )) || return 1                  # 승인 때 Task 결정이 근거였다면 프로젝트 기록으로는 풀리지 않는다
    for (( k = bp + 1; k <= pn; k++ )); do     # 승인 뒤 프로젝트 수준을 실제로 승인 수준 아래로 낮춘 기록만
      r="$ROOT/.harness/decisions/review-level-$k.md"
      (( $(level_rank "$(rec_get "$r" 수준)") < $(level_rank "${2:-cross_provider}") )) && return 0
    done
    return 1
  fi
  pt="$(sed -n 's/^승인 시각: //p' "$(plan_file "$(yget "$(task_file "$1")" milestone_id)")" 2>/dev/null | head -n 1)"
  for r in "$(latest_level_record "$1")" "$(latest_level_record "")"; do
    [[ -n "$r" ]] || continue
    t="$(rec_get "$r" 시각)"
    [[ -n "$t" && "$t" > "${pt:-}" ]] && return 0
  done
  return 1
}

# 다른 회사가 없을 때 자동으로 낮출 수 있는 최저 수준. none이 아니면 사용자가 남긴 결정 기록이 있어야
# 유효하다(설정 한 줄만 고쳐 자동 하향을 켜는 경로를 막는다). 기록이 없으면 none으로 본다.
recorded_level() {  # TASK|"" → 결정 기록만으로 본 현재 수준 (Task 기록 > 프로젝트 기록 > 다른 회사)
  local r lv
  if [[ -n "$1" ]]; then r="$(latest_level_record "$1")"; [[ -z "$r" ]] || { lv="$(rec_get "$r" 수준)"; valid_level "$lv" && { printf '%s' "$lv"; return 0; }; }; fi
  r="$(latest_level_record "")"
  [[ -z "$r" ]] || { lv="$(rec_get "$r" 수준)"; valid_level "$lv" && { printf '%s' "$lv"; return 0; }; }
  printf cross_provider
}

fallback_level() {
  local fb rec
  fb="$(pget review fallback_level none)"
  if [[ "$fb" != none ]]; then
    rec="$(latest_level_record "")"
    valid_level "$fb" && [[ -n "$rec" && "$(rec_get "$rec" '자동 하향 허용')" == "$fb" ]] || fb=none
  fi
  printf '%s' "$fb"
}

project_level() {  # → 프로젝트 기본 검토 수준 (다른 회사보다 낮으면 결정 기록 필수)
  local lv rec
  lv="$(pget review level cross_provider)"
  valid_level "$lv" || die "project.yaml review.level 값이 올바르지 않습니다: $lv"
  if [[ "$lv" != cross_provider ]]; then
    rec="$(latest_level_record "")"
    [[ -n "$rec" && "$(rec_get "$rec" 수준)" == "$lv" ]] ||
      die "project.yaml review.level($lv)에 결정 기록이 없습니다. review-level 명령으로 사용자 결정을 남긴다."
  fi
  printf '%s' "$lv"
}

# --------------------------------------------------------------------------
# Provider — herdr agent start --kind 이름. 기본 3종 외에는 project.yaml에 추가한다.
# 쿼터 소진 등으로 잠시 못 쓰는 Provider는 runtime/providers.off에 표시한다(provider off|on).
# --------------------------------------------------------------------------
off_file() { printf '%s/.harness/runtime/providers.off' "$ROOT"; }
provider_off() { [[ -f "$(off_file)" ]] && awk -F'\t' -v p="$1" '$1 == p { f = 1 } END { exit !f }' "$(off_file)"; }
provider_off_reason() { [[ -f "$(off_file)" ]] || return 0; awk -F'\t' -v p="$1" '$1 == p { r = $4 } END { print r }' "$(off_file)"; }
provider_off_source() { [[ -f "$(off_file)" ]] || return 0; awk -F'\t' -v p="$1" '$1 == p { r = $3 } END { print r }' "$(off_file)"; }
mark_provider_off() {  # PROVIDER REASON SOURCE(user|auto)
  local src="${3:-user}"
  if provider_off "$1"; then
    # 자동 표시를 사용자가 다시 표시하면 사용자 결정으로 바꾼다(그때부터 교체 규칙을 묻지 않는다).
    [[ "$src" == user && "$(provider_off_source "$1")" != user ]] || return 0
    unmark_provider "$1"
  fi
  mkdir -p "$ROOT/.harness/runtime"
  printf '%s\t%s\t%s\t%s\n' "$1" "$(now)" "$src" "${2//$'\t'/ }" >>"$(off_file)"
}
unmark_provider() {  # PROVIDER
  local tmp
  [[ -f "$(off_file)" ]] || return 0
  tmp="$(mktemp "$ROOT/.harness/runtime/.harness-tmp.XXXXXX")"
  TMP_FILES+=("$tmp")
  awk -F'\t' -v p="$1" '$1 != p' "$(off_file)" >"$tmp"
  mv -f -- "$tmp" "$(off_file)"
}
providers() {
  local list=""
  [[ -z "$ROOT" ]] || list="$(pget providers available)"
  if [[ "$list" == \[*\] ]]; then
    list="${list:1:${#list}-2}"; list="${list//,/ }"
    printf '%s\n' $list
  else
    printf '%s\n' claude codex agy
  fi
}
is_provider() { [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]] && providers | grep -qxF -- "$1"; }

# --------------------------------------------------------------------------
# Task·Milestone·기록 경로
#   tasks/T.yaml                     Task 계약 (status는 harness.sh만 바꾼다)
#   attempts/T-attempt-N.md          Worker 보고서 (Worker가 쓴다)
#   attempts/T-attempt-N.harness.md  dispatch·AC·통합 증빙 (harness.sh만 쓴다)
#   reviews/T-review-R.md            Review (Reviewer가 쓴다)
#   reviews/T-review-R.harness.md    Reviewer dispatch·통합 증빙
#   decisions/M-plan-approval.md     계획 승인 (Task·등급·AC 지문 스냅숏)
#   decisions/M-approval.md          Milestone 완료 승인
#   verifications/T-verify-N.md      재검증 기록 (verify, 보관된 Task는 그 보관함 안)
#   archive/M/                        승인된 Milestone의 위 파일 전부 + SUMMARY.md
#   runtime/ · worktrees/             Pane 추적·로그·Task 작업 공간 (Git 제외)
# --------------------------------------------------------------------------
task_file() {
  need_id "$1"
  local f="$ROOT/.harness/tasks/$1.yaml"
  [[ -f "$f" ]] || die "Task 파일이 없습니다: $(rel "$f")"
  printf '%s' "$f"
}

task_ids() {
  local f b
  for f in "$ROOT"/.harness/tasks/*.yaml; do
    [[ -f "$f" ]] || continue
    b="${f##*/}"; b="${b%.yaml}"
    [[ "$b" == TEMPLATE ]] || printf '%s\n' "$b"
  done
  return 0
}

milestone_tasks() {  # MILESTONE → 그 Milestone의 Task ID
  local id
  while IFS= read -r id; do
    [[ "$(yget "$ROOT/.harness/tasks/$id.yaml" milestone_id)" != "$1" ]] || printf '%s\n' "$id"
  done < <(task_ids)
  return 0
}

# 보관된 Task인가. 정리(prune)한 보관함은 요약(SUMMARY.md) 표에만 남는다. ID 형식이 아니면 아니다(글롭 문자로 보관함을 훑지 않게).
archived_task() {
  local s
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  if compgen -G "$ROOT/.harness/archive/*/tasks/$1.yaml" >/dev/null; then return 0; fi
  for s in "$ROOT"/.harness/archive/*/SUMMARY.md; do
    [[ -f "$s" ]] || continue
    if awk -F'|' -v id="$1" '
         /^\| Task \|/ { t = 1; next }           # Task 표 머리줄부터
         t && !/^\|/ { t = 0 }                    # 표가 끝나면 그만 (지표 표의 첫 칸은 Task가 아니다)
         t { g = $2; gsub(/^[ \t]+|[ \t]+$/, "", g); if (g == id) { f = 1; exit } }
         END { exit !f }' "$s"; then return 0; fi
  done
  return 1
}

spec_approved() {
  [[ "$(awk -F': *' '/^- 상태:/ { print $2; exit }' "$ROOT/.harness/SPEC.md" 2>/dev/null | tr -d '\r[:space:]')" == approved ]]
}

last_n() {  # DIR PREFIX SUFFIX → 가장 큰 N (없으면 0)
  local f n max=0
  for f in "$1/$2"*"$3"; do
    n="${f##*/}"; n="${n#"$2"}"; n="${n%"$3"}"
    if [[ "$n" =~ ^[0-9]+$ ]] && (( 10#$n > max )); then max=$((10#$n)); fi
  done
  printf '%s' "$max"
}

att_report() { printf '%s/.harness/attempts/%s-attempt-%s.md' "$ROOT" "$1" "$2"; }
att_record() { printf '%s/.harness/attempts/%s-attempt-%s.harness.md' "$ROOT" "$1" "$2"; }
rev_file()   { printf '%s/.harness/reviews/%s-review-%s.md' "$ROOT" "$1" "$2"; }
rev_record() { printf '%s/.harness/reviews/%s-review-%s.harness.md' "$ROOT" "$1" "$2"; }
last_attempt() { last_n "$ROOT/.harness/attempts" "$1-attempt-" ".harness.md"; }
last_review()  { last_n "$ROOT/.harness/reviews" "$1-review-" ".harness.md"; }
meta_file()    { printf '%s/.harness/runtime/%s-%s.meta' "$ROOT" "$1" "$2"; }

# 없는 파일은 빈 값이다. pipefail 아래서 sed 실패가 대입을 통째로 죽이지 않게 먼저 거른다.
rec_get()  { [[ -f "$1" ]] || return 0; sed -n "s/^- $2: //p" "$1" | head -n 1; }
rec_last() { [[ -f "$1" ]] || return 0; sed -n "s/^- $2: //p" "$1" | tail -n 1; }
meta_get() { [[ -f "$1" ]] || return 0; sed -n "s/^$2=//p" "$1" | tail -n 1; }

# 줄 시작의 '판정:'만 읽는다(굵게 표시 허용). '- 판정: PASS' 같은 하위 항목은 무시한다.
review_verdict() { [[ -f "$1" ]] || return 0; sed -n 's/^\*\{0,2\}판정:[[:space:]]*\([A-Za-z_]*\).*/\1/p' "$1" | head -n 1; }
review_target()  { [[ -f "$1" ]] || return 0; sed -n 's/^[-*[:space:]]*대상 Attempt:[[:space:]]*\**\([0-9][0-9]*\).*/\1/p' "$1" | head -n 1; }

# 마지막 AC 요약이 PASS인가. submitted 이후 단계가 모두 이 증빙을 전제로 한다.
ac_passed() { [[ -f "$1" && "$(rec_last "$1" 'AC 요약')" == PASS* ]]; }

missing_ids() {  # FILE ID... → 파일에 단어로 나오지 않는 ID들
  local f="$1" id
  shift
  for id in "$@"; do grep -qwF -- "$id" "$f" || printf '%s ' "$id"; done
  return 0
}

norm_scope() {  # write_scope 항목을 비교 가능한 경로로: ./a/ → a, a/** → a
  local p="$1"
  p="${p#./}"; p="${p%/\*\*}"; p="${p%/\*}"; p="${p%/}"
  printf '%s' "${p:-.}"
}
overlap() {  # 두 write_scope 경로가 같거나 한쪽이 다른 쪽 아래인가
  local a b
  a="$(norm_scope "$1")"; b="$(norm_scope "$2")"
  [[ "$a" == . || "$b" == . || "$a" == "$b" || "$a" == "$b"/* || "$b" == "$a"/* ]]
}

# --------------------------------------------------------------------------
# Acceptance Criteria — verified_by 블록 안의 type/command만 읽는다. 항목은
# '- criterion_id:'로 시작해야 한다. 그 밖의 모양은 ERR 줄로 보고해 거부한다.
# --------------------------------------------------------------------------
ac_entries() {  # TASK_FILE → "id<TAB>type<TAB>command" 또는 "ERR<TAB>설명"
  awk '
    function flush() { if (id != "") print id "\t" type "\t" command }
    function indent_of(line) { match(line, /^[[:space:]]*/); return RLENGTH }
    { sub(/\r$/, "") }
    /^acceptance_criteria:[[:space:]]*$/ { inside = 1; next }
    inside && /^[^[:space:]#]/ { inside = 0 }
    !inside || /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*-[[:space:]]/ && item_indent == "" { item_indent = indent_of($0) }
    /^[[:space:]]*-[[:space:]]/ && indent_of($0) == item_indent {
      if ($0 !~ /^[[:space:]]*-[[:space:]]*criterion_id:/) { print "ERR\t항목은 \"- criterion_id:\"로 시작해야 합니다: " $0; next }
      flush(); id = $0; sub(/^[[:space:]]*-[[:space:]]*criterion_id:[[:space:]]*/, "", id)
      type = ""; command = ""; in_v = 0; next
    }
    /^[[:space:]]*verified_by:[[:space:]]*$/ { in_v = 1; v_indent = indent_of($0); next }
    {
      if (in_v && indent_of($0) <= v_indent) in_v = 0
      if (!in_v) next
      if ($0 ~ /^[[:space:]]*type:/) { type = $0; sub(/^[[:space:]]*type:[[:space:]]*/, "", type) }
      else if ($0 ~ /^[[:space:]]*command:/) { command = $0; sub(/^[[:space:]]*command:[[:space:]]*/, "", command) }
    }
    END { flush() }
  ' "$1" | sed -e 's/[[:space:]]*$//'
}

ac_load() {  # TASK_FILE → AC_ID·AC_TYPE·AC_CMD, 형식 문제는 AC_ERR (die하지 않는다)
  AC_ID=(); AC_TYPE=(); AC_CMD=(); AC_ERR=""
  local id type cmd commands=0
  while IFS=$'\t' read -r id type cmd; do
    [[ -n "$id" ]] || continue
    if [[ "$id" == ERR ]]; then AC_ERR="$type"; continue; fi
    id="$(unquote "$id")"; type="$(unquote "$type")"; cmd="$(unquote "$cmd")"
    case "$type" in
      command) commands=$((commands + 1)); [[ -n "$cmd" ]] || AC_ERR="$id: command가 비어 있습니다" ;;
      manual-review) ;;
      *) AC_ERR="$id: verified_by.type을 알 수 없습니다 (${type:-없음}; command | manual-review)" ;;
    esac
    AC_ID+=("$id"); AC_TYPE+=("$type"); AC_CMD+=("$cmd")
  done < <(ac_entries "$1" || true)
  if (( ${#AC_ID[@]} == 0 )); then AC_ERR="${AC_ERR:-acceptance_criteria가 비어 있습니다}"
  elif (( commands == 0 )); then AC_ERR="${AC_ERR:-type: command인 AC가 하나 이상 필요합니다 (증빙 없는 제출 금지)}"
  fi
  return 0
}

ac_hash() { ac_entries "$1" | sha256sum | cut -c1-16; }   # 계획 승인 때의 AC와 같은지 대조한다

# 아무것도 확인하지 않는 명령(true 등). 재검증·v1 증빙 등급에서 증빙으로 세지 않는다.
formal_cmd() { [[ "$1" =~ ^(true|:|/bin/true|/usr/bin/true|exit[[:space:]]+0)$ ]]; }

# --------------------------------------------------------------------------
# JSON — herdr 출력에서 값 하나. jq가 있으면 쓰고, 없으면 문자열·숫자만 읽는다.
# --------------------------------------------------------------------------
jfield() {
  local in="$1" k="$2" v=""
  if [[ "$in" == *"{"*"}"* ]]; then in="{${in#*\{}"; in="${in%\}*}}"; fi
  if command -v jq >/dev/null 2>&1; then
    v="$(jq -r --arg k "$k" 'first(.. | objects | select(has($k)) | .[$k] | select(. != null)) // empty' <<<"$in" 2>/dev/null || true)"
  fi
  if [[ -z "$v" ]]; then
    v="$(tr -d '\n' <<<"$in" | grep -o "\"$k\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|[0-9][0-9]*\)" | head -n 1 |
      sed 's/^[^:]*:[[:space:]]*//; s/^"//; s/"$//' || true)"
  fi
  printf '%s' "$v"
}

# --------------------------------------------------------------------------
# Git·작업 공간
#   code_dir   수정 대상 저장소 (project.yaml workspace.code_dir, 기본은 프로젝트 루트, 원격 모드는 마운트 경로)
#   worktree   Task마다 .harness/worktrees/T (브랜치 hh/T). 병렬 Worker의 변경·검증을 격리한다.
# --------------------------------------------------------------------------
code_dir() {
  local d
  if remote_enabled; then remote_mount_path; return 0; fi
  d="$(pget workspace code_dir .)"
  [[ "$d" == /* ]] || d="$ROOT/$d"
  realpath -m "$d"
}

remote_enabled() {
  [[ -f "$ROOT/.harness/remote.yaml" ]] &&
    awk '$0 == "remote:" { r = 1; next } /^[^[:space:]#]/ { r = 0 } r && /^  enabled:[[:space:]]*["\047]?true["\047]?([[:space:]]|#|$)/ { f = 1 } END { exit !f }' "$ROOT/.harness/remote.yaml"
}

worktree_enabled() {
  [[ "$(pget isolation worktree true)" == true ]] && ! remote_enabled &&
    git -C "$(code_dir)" rev-parse --verify -q HEAD >/dev/null 2>&1
}

is_task_worktree() {  # DIR → 그 폴더 자체가 git worktree인가
  [[ -f "$1/.git" ]] && [[ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" -ef "$1" ]]
}

task_cwd() {  # TASK → Worker·AC가 일하는 디렉터리
  if worktree_enabled; then printf '%s/.harness/worktrees/%s' "$ROOT" "$1"; else code_dir; fi
}

# .harness/ 기록만 commit한다. 사용자가 stage한 다른 변경은 건드리지 않는다.
commit_harness() {
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$ROOT" add -A -- .harness >/dev/null 2>&1 || true
  git -C "$ROOT" diff --cached --quiet -- .harness 2>/dev/null && return 0
  git -C "$ROOT" commit -q -m "harness: $1" -- .harness >/dev/null 2>&1 ||
    warn "기록 commit 실패 ($1) — git user.name/email·hook을 확인한다. 기록 파일은 그대로 남아 있다."
  return 0
}

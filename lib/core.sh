# herdr-harness: 공통 함수 — 출력·임시 파일·Secret 검사·설정 읽기·경로·Acceptance Criteria.
# harness.sh가 source한다. 단독 실행하지 않는다.

HARNESS_VERSION="2.0.0"
ROOT=""
TMP_FILES=()

trap 'rm -f -- ${TMP_FILES[@]+"${TMP_FILES[@]}"}' EXIT
# die는 3으로 끝난다. 그 밖의 예상하지 못한 실패는 어느 줄인지 남겨 조용히 끝나지 않게 한다.
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

pget() {  # SECTION KEY [DEFAULT] → project.yaml의 'SECTION:' 아래 '  KEY: 값'
  local v
  v="$(awk -v s="$1:" -v k="  $2:" '
    { sub(/\r$/, "") }
    $0 == s { inside = 1; next }
    /^[^[:space:]#]/ { inside = 0 }
    inside && index($0, k) == 1 { print substr($0, length(k) + 1); exit }
  ' "$ROOT/.harness/project.yaml")"
  v="$(unquote "$v")"
  printf '%s' "${v:-${3:-}}"
}

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

# --------------------------------------------------------------------------
# Provider — herdr agent start --kind 이름. 기본 3종 외에는 project.yaml에 추가한다.
# --------------------------------------------------------------------------
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

archived_task() { compgen -G "$ROOT/.harness/archive/*/tasks/$1.yaml" >/dev/null; }

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
  done < <(ac_entries "$1")
  if (( ${#AC_ID[@]} == 0 )); then AC_ERR="${AC_ERR:-acceptance_criteria가 비어 있습니다}"
  elif (( commands == 0 )); then AC_ERR="${AC_ERR:-type: command인 AC가 하나 이상 필요합니다 (증빙 없는 제출 금지)}"
  fi
  return 0
}

ac_hash() { ac_entries "$1" | sha256sum | cut -c1-16; }   # 계획 승인 때의 AC와 같은지 대조한다

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

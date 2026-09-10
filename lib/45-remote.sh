# Part of herdr-harness. Sourced by harness.sh — do not run directly.

# ---------------------------------------------------------------------------
# 원격 작업 모드
#
# Agent는 항상 로컬에서 돈다(ARCHITECTURE.md §1). 원격은 "소스는 SSHFS로 로컬에
# 노출하고, 빌드·테스트·VCS만 SSH로 원격에서 실행"하는 실행 환경일 뿐이다.
# 그래서 dispatch/observe에 붙는 플래그가 아니라 프로젝트 속성이며, 설정 정본은
# .harness/policies/remote.yaml 하나다.
#
# 비밀번호는 어떤 파일에도 저장하지 않는다. 최초 1회만 HH_REMOTE_PASSWORD
# 환경변수로 bootstrap-key를 돌려 SSH 키를 등록하고, 이후에는 키 인증만 쓴다.
# ---------------------------------------------------------------------------

REMOTE_CONFIG_REL=".harness/policies/remote.yaml"

_remote_config_path() {
  printf '%s\n' "$1/$REMOTE_CONFIG_REL"
}

# 값 뒤 YAML 주석을 잘라낸다. YAML에서 #는 줄 첫머리이거나 앞이 공백일 때만
# 주석이므로 `path: /srv/a#b`의 #는 값의 일부다. 따옴표 안의 #도 값이며,
# 이중 인용 문자열의 \" 이스케이프는 닫는 따옴표로 세지 않는다.
_remote_strip_comment() {
  local line="$1" out="" quote="" index character previous=""
  for ((index = 0; index < ${#line}; index++)); do
    character="${line:index:1}"
    if [[ -n "$quote" ]]; then
      out+="$character"
      if [[ "$quote" == '"' && "$character" == "\\" ]]; then
        # 이스케이프된 다음 한 글자는 그대로 삼킨다.
        index=$((index + 1))
        out+="${line:index:1}"
        previous="${line:index:1}"
        continue
      fi
      [[ "$character" != "$quote" ]] || quote=""
      previous="$character"
      continue
    fi
    case "$character" in
      "'"|'"') quote="$character"; out+="$character" ;;
      '#')
        if [[ -z "$previous" || "$previous" == [[:space:]] ]]; then
          break
        fi
        out+="$character"
        ;;
      *) out+="$character" ;;
    esac
    previous="$character"
  done
  printf '%s' "$out"
}

# remote.yaml의 `remote:` 블록에서 키 하나를 읽는다. project_field와 같은
# 제한 스키마 규칙을 따르되, 없는 키는 빈 문자열로 돌려준다(기본값 처리는 호출자).
# 사람이 직접 편집하는 파일이므로 값 뒤 주석(`host: build # 사내`)을 잘라내고,
# 같은 키가 두 번 나오면 조용히 첫 값을 쓰지 않고 실패한다.
# 중복 키 검사. _remote_field는 `REMOTE_X="${ENV:-$(_remote_field ...)}"` 형태로
# command substitution 안에서 불리기 때문에, 거기서 die해 봐야 서브셸만 죽고
# 호출자는 빈 값으로 조용히 진행한다. 그래서 검사는 반드시 메인 셸에서 먼저 한다.
_remote_assert_unique_keys() {
  local file="$1" duplicates
  duplicates="$(awk '
    $0 == "remote:" { inside = 1; next }
    /^[^[:space:]#]/ { inside = 0 }
    inside && /^  [A-Za-z_][A-Za-z0-9_]*:/ {
      key = $1
      sub(/:$/, "", key)
      if (seen[key]++ == 1) print key
    }' "$file")"
  [[ -z "$duplicates" ]] ||
    die "remote.yaml에서 키가 중복되었습니다: $(printf '%s' "$duplicates" | tr '\n' ',' | sed 's/,$//') ($file)"
}

_remote_field() {
  local file="$1" key="$2" line count
  count="$(awk -v k="  $key:" '
    $0 == "remote:" { inside = 1; next }
    /^[^[:space:]#]/ { inside = 0 }
    inside && index($0, k) == 1 { n++ }
    END { print n + 0 }' "$file")"
  [[ "$count" -eq 1 ]] || return 0
  line="$(awk -v k="  $key:" '
    $0 == "remote:" { inside = 1; next }
    /^[^[:space:]#]/ { inside = 0 }
    inside && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$file")"
  yaml_unquote "$(_remote_strip_comment "$line")"
}

_remote_expand_tilde() {
  local value="$1"
  case "$value" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s%s' "$HOME" "${value#\~}" ;;
    *) printf '%s' "$value" ;;
  esac
}

# SSH는 목적지 인자가 "-"로 시작하면 옵션으로 해석한다. 즉 user 값이
# `-oProxyCommand=...`이면 인용을 아무리 해도 로컬 명령 실행으로 이어진다.
# 그래서 호스트·사용자는 형태 자체를 제한한다(설정 파일과 환경변수 양쪽 모두).
_remote_validate_endpoint() {
  [[ "$REMOTE_USER" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] ||
    die "원격 사용자명에 허용되지 않는 문자가 있습니다(영문·숫자·. _ -, 첫 글자는 - 불가): $REMOTE_USER"
  # 포트는 호스트 값이 아니라 SSH 옵션이므로 콜론을 허용하지 않는다. IPv6는
  # SSHFS의 host:path 구문과 섞이지 않도록 대괄호 표기만 받는다.
  [[ "$REMOTE_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ || "$REMOTE_HOST" =~ ^\[[0-9A-Fa-f:]+\]$ ]] ||
    die "원격 호스트 형식이 올바르지 않습니다(호스트명·IPv4 또는 [IPv6], 포트는 포함하지 않음): $REMOTE_HOST"
  [[ "$REMOTE_PATH" == /* ]] ||
    die "원격 프로젝트 경로는 절대경로여야 합니다: $REMOTE_PATH"
  # 개행뿐 아니라 모든 제어문자를 막는다. \r 같은 문자는 생성 YAML을 눈에 띄지
  # 않게 오염시키고 원격 셸에서도 예상 밖으로 동작한다.
  local field
  for field in "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PATH" "$REMOTE_MOUNT_PATH" "$REMOTE_SSH_KEY"; do
    [[ "$field" != *[[:cntrl:]]* ]] || die "원격 설정 값에 제어문자(개행·탭 등)가 들어갈 수 없습니다."
  done
}

# 원격 셸에 넘길 값을 POSIX 단일 인용으로 감싼다. 경로에 작은따옴표나 공백이
# 있어도 `cd <path>`가 명령 경계를 넘지 않는다.
_remote_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

# 설정 + 환경변수 override를 읽어 REMOTE_* 전역을 채운다.
# 반환 1 = 설정 파일 없음, 2 = enabled: false. 호출자가 안내 문구를 고른다.
_remote_load() {
  local root="$1" file
  file="$(_remote_config_path "$root")"
  [[ -f "$file" ]] || return 1

  _remote_assert_unique_keys "$file"

  local enabled
  enabled="$(_remote_field "$file" enabled)"
  REMOTE_HOST="${HH_REMOTE_HOST:-$(_remote_field "$file" host)}"
  REMOTE_USER="${HH_REMOTE_USER:-$(_remote_field "$file" user)}"
  REMOTE_PATH="${HH_REMOTE_PATH:-$(_remote_field "$file" path)}"
  REMOTE_MOUNT_PATH="${HH_REMOTE_MOUNT_PATH:-$(_remote_field "$file" mount_path)}"
  REMOTE_SSH_KEY="${HH_REMOTE_SSH_KEY:-$(_remote_field "$file" ssh_key)}"
  # 설정 파일에 적힌 원래 표기(~ 포함)를 그대로 보존한다. setup이 다시 쓸 때
  # 사용자가 적은 형태를 유지하기 위한 것이다.
  REMOTE_SSH_KEY_RAW="$REMOTE_SSH_KEY"
  REMOTE_VCS="${HH_REMOTE_VCS:-$(_remote_field "$file" vcs)}"

  [[ -n "$REMOTE_MOUNT_PATH" ]] || REMOTE_MOUNT_PATH="$root/.harness/remote-mount"
  [[ -n "$REMOTE_SSH_KEY" ]] || REMOTE_SSH_KEY="$HOME/.ssh/herdr_remote_ed25519"
  [[ -n "$REMOTE_VCS" ]] || REMOTE_VCS="git"
  REMOTE_MOUNT_PATH="$(_remote_expand_tilde "$REMOTE_MOUNT_PATH")"
  REMOTE_SSH_KEY="$(_remote_expand_tilde "$REMOTE_SSH_KEY")"

  [[ "$enabled" == true ]] || return 2

  [[ -n "$REMOTE_HOST" ]] || die "remote.yaml에 host가 없습니다: $file"
  [[ -n "$REMOTE_USER" ]] || die "remote.yaml에 user가 없습니다: $file"
  [[ -n "$REMOTE_PATH" ]] || die "remote.yaml에 path(원격 프로젝트 경로)가 없습니다: $file"
  case "$REMOTE_VCS" in
    git|svn|none) ;;
    *) die "지원하지 않는 vcs 값입니다: $REMOTE_VCS (git | svn | none)" ;;
  esac

  _remote_validate_endpoint
  REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
  return 0
}

# remote 하위 명령의 공통 진입: 프로젝트 확인 + 설정 로드 + 비활성 안내.
_remote_require() {
  local root="$1" status=0
  _remote_load "$root" || status=$?
  case "$status" in
    0) return 0 ;;
    1) die "원격 모드 설정이 없습니다: $(_remote_config_path "$root")
   herdr-harness init 시 --remote-host/--remote-path를 주거나, 위 파일을 직접 만들고 enabled: true로 바꾸세요." ;;
    2) die "원격 모드가 꺼져 있습니다: $(_remote_config_path "$root") 의 enabled를 true로 바꾸세요." ;;
  esac
}

_remote_has() {
  command -v "$1" >/dev/null 2>&1
}

_remote_is_mounted() {
  mountpoint -q "$REMOTE_MOUNT_PATH" 2>/dev/null
}

_remote_auth_mode() {
  if [[ -f "$REMOTE_SSH_KEY" ]]; then printf 'key'; else printf 'password'; fi
}

_remote_require_password_tool() {
  [[ "$(_remote_auth_mode)" == password ]] || return 0
  [[ -n "${HH_REMOTE_PASSWORD:-}" ]] ||
    die "SSH 키($REMOTE_SSH_KEY)가 없습니다. HH_REMOTE_PASSWORD를 준 뒤 'remote bootstrap-key'로 키를 등록하세요."
  _remote_has sshpass ||
    die "비밀번호 인증에 sshpass가 필요합니다: sudo apt install -y sshpass"
}

_remote_ssh() {
  local -a options=(
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
  )
  local -a tty_option=()
  if [[ "${1:-}" == --tty ]]; then tty_option=(-t); shift; fi

  if [[ "$(_remote_auth_mode)" == key ]]; then
    ssh "${tty_option[@]}" "${options[@]}" -i "$REMOTE_SSH_KEY" "$REMOTE_TARGET" "$@"
  else
    _remote_require_password_tool
    SSHPASS="$HH_REMOTE_PASSWORD" sshpass -e ssh "${tty_option[@]}" "${options[@]}" "$REMOTE_TARGET" "$@"
  fi
}

# 따옴표·개행이 섞인 스크립트를 원격 셸 인용 규칙과 무관하게 그대로 넘긴다.
_remote_bash() {
  local encoded
  encoded="$(printf '%s' "$1" | base64 -w 0)"
  _remote_ssh "printf '%s' '$encoded' | base64 -d | bash"
}

_remote_check_local_tools() {
  local missing=() item
  for item in ssh base64; do _remote_has "$item" || missing+=("$item"); done
  ((${#missing[@]} == 0)) || die "로컬에 필요한 명령이 없습니다: ${missing[*]}  (sudo apt install -y openssh-client coreutils)"
}

cmd_remote_deps() {
  local failed=0 item
  for item in ssh sshfs mountpoint base64; do
    if _remote_has "$item"; then
      printf '[OK]       %-11s %s\n' "$item" "$(command -v "$item")"
    else
      printf '[MISSING]  %-11s\n' "$item"
      failed=1
    fi
  done
  if _remote_has sshpass; then
    printf '[OK]       %-11s %s\n' sshpass "$(command -v sshpass)"
  elif [[ "$(_remote_auth_mode)" == password ]]; then
    printf '[MISSING]  %-11s (현재 비밀번호 인증에 필요)\n' sshpass
    failed=1
  else
    printf '[OPTIONAL] %-11s (SSH 키 사용 중이라 불필요)\n' sshpass
  fi
  printf '인증 방식: %s (%s)\n' "$(_remote_auth_mode)" "$REMOTE_SSH_KEY"
  ((failed == 0)) ||
    printf 'Ubuntu/WSL 설치 명령: sudo apt update && sudo apt install -y openssh-client sshfs util-linux sshpass\n'
  return "$failed"
}

# 비밀번호는 인자로 받는다(없으면 HH_REMOTE_PASSWORD). 환경으로 export하면
# ssh-keygen·hostname·base64 같은 무관한 자식까지 비밀번호를 상속한다.
cmd_remote_bootstrap_key() {
  local password="${1:-${HH_REMOTE_PASSWORD:-}}"
  _remote_check_local_tools
  _remote_has ssh-keygen || die "ssh-keygen이 필요합니다."
  # 전제 조건을 먼저 확인한다 — 실패할 등록 때문에 키 파일만 남기지 않기 위해서다.
  [[ -n "$password" ]] ||
    die "최초 등록에는 원격 비밀번호가 필요합니다: HH_REMOTE_PASSWORD=... $SCRIPT_NAME remote bootstrap-key"
  _remote_has sshpass || die "sshpass가 필요합니다: sudo apt install -y sshpass"

  if [[ ! -f "$REMOTE_SSH_KEY" ]]; then
    mkdir -p "$(dirname "$REMOTE_SSH_KEY")"
    chmod 700 "$(dirname "$REMOTE_SSH_KEY")"
    ssh-keygen -q -t ed25519 -N '' -f "$REMOTE_SSH_KEY" -C "herdr-harness@$(hostname)"
    info "SSH 키 생성: $REMOTE_SSH_KEY"
  fi

  local encoded_key
  encoded_key="$(base64 -w 0 <"${REMOTE_SSH_KEY}.pub")"
  SSHPASS="$password" sshpass -e ssh -o StrictHostKeyChecking=accept-new "$REMOTE_TARGET" \
    "key=\$(printf '%s' '$encoded_key' | base64 -d); umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF \"\$key\" ~/.ssh/authorized_keys || printf '%s\\n' \"\$key\" >> ~/.ssh/authorized_keys"

  info "SSH 키 등록 완료. 이후에는 HH_REMOTE_PASSWORD 없이 접속합니다 — 환경변수를 지우세요."
}

# ---------------------------------------------------------------------------
# setup: 최초 1회 대화형 설정
#
# remote.yaml을 만들고 SSH 키까지 등록해 "그 다음부터는 비밀번호가 필요 없는"
# 상태로 만든다. 비밀번호는 이 명령이 도는 동안 메모리에만 있고 파일·argv·
# 이력 어디에도 남지 않는다(read -rs + sshpass -e).
# ---------------------------------------------------------------------------

# 비대화형에서는 물어보지 않고 명시적으로 실패한다(10-lib.sh의 prompt_required와 같은 규칙).
_remote_ask() {
  local variable="$1" label="$2" default="${3:-}" value=""
  if [[ ! -t 0 ]]; then
    [[ -n "$default" ]] ||
      die "비대화형 실행에서는 값을 물어볼 수 없습니다. 옵션으로 전달하세요: $label"
    printf -v "$variable" '%s' "$default"
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -e -p "$label [$default]: " value || die "입력을 읽지 못했습니다: $label"
    value="${value:-$default}"
  else
    while [[ -z "$value" ]]; do
      read -r -e -p "$label: " value || die "입력을 읽지 못했습니다: $label"
    done
  fi
  printf -v "$variable" '%s' "$value"
}

# 비밀번호는 화면에 찍지 않고, 셸 이력에도 남지 않도록 여기서만 읽는다.
_remote_ask_password() {
  local variable="$1" value=""
  # 호출자가 뒷정리 안내를 하도록 die 대신 실패를 돌려준다.
  if [[ ! -t 0 ]]; then
    printf '오류: 비대화형 실행에서는 비밀번호를 물어볼 수 없습니다. HH_REMOTE_PASSWORD로 전달하거나 --no-key로 키 등록을 건너뛰세요.\n' >&2
    return 1
  fi
  while [[ -z "$value" ]]; do
    if ! read -r -s -p "원격 비밀번호(키 등록에만 사용, 저장하지 않음): " value; then
      printf '\n오류: 비밀번호를 읽지 못했습니다.\n' >&2
      return 1
    fi
    printf '\n'
  done
  printf -v "$variable" '%s' "$value"
}

# 주의: 이 함수를 `$( ... )` 안에서 부르지 말 것. 안에서 die가 나면 서브셸만
# 죽고 호출자는 실패를 못 본다(이 저장소에서 같은 실수를 이미 한 번 했다).
_remote_write_config() {
  local root="$1" file temporary parent
  file="$(_remote_config_path "$root")"
  parent="$(dirname "$file")"
  mkdir -p "$parent"
  temporary="$(mktemp "$parent/.remote-config.XXXXXX")"
  cat >"$temporary" <<EOF
schema_version: '1.0'
remote:
  # Agent는 항상 로컬에서 실행된다. 원격은 소스를 SSHFS로 로컬에 노출하고
  # 빌드·테스트·VCS만 SSH로 실행하는 실행 환경이다.
  enabled: true
  host: $(yaml_quote "$REMOTE_HOST")
  user: $(yaml_quote "$REMOTE_USER")
  # 원격 호스트에 있는 프로젝트 디렉터리
  path: $(yaml_quote "$REMOTE_PATH")
  # SSHFS로 원격 소스를 붙일 로컬 경로. Agent는 이 경로의 파일을 직접 편집한다.
  mount_path: $(yaml_quote "$REMOTE_MOUNT_PATH")
  # bootstrap-key가 만들고 사용하는 전용 키. 파일이 있으면 항상 키 인증을 쓴다.
  ssh_key: $(yaml_quote "$REMOTE_SSH_KEY_RAW")
  # remote vcs <인수...>가 원격에서 실행할 명령: git | svn | none
  vcs: '$REMOTE_VCS'
EOF
  chmod 0644 "$temporary"
  mv "$temporary" "$file" || { rm -f "$temporary"; die "원격 설정 파일을 쓰지 못했습니다: $file"; }
}

_remote_setup_key_hint() {
  printf '\n' >&2
  info "설정 파일은 저장됐습니다. SSH 키 등록만 다시 실행하세요:"
  info "  $SCRIPT_NAME remote $1 bootstrap-key   (비밀번호는 HH_REMOTE_PASSWORD로 전달)"
}

cmd_remote_setup() {
  local root="$1"; shift
  local host="" user="" path="" mount="" ssh_key="" vcs="" force=0 skip_key=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host) [[ $# -ge 2 ]] || die "--host 값이 필요합니다."; host="$2"; shift 2 ;;
      --user) [[ $# -ge 2 ]] || die "--user 값이 필요합니다."; user="$2"; shift 2 ;;
      --path) [[ $# -ge 2 ]] || die "--path 값이 필요합니다."; path="$2"; shift 2 ;;
      --mount) [[ $# -ge 2 ]] || die "--mount 값이 필요합니다."; mount="$2"; shift 2 ;;
      --ssh-key) [[ $# -ge 2 ]] || die "--ssh-key 값이 필요합니다."; ssh_key="$2"; shift 2 ;;
      --vcs) [[ $# -ge 2 ]] || die "--vcs 값이 필요합니다."; vcs="$2"; shift 2 ;;
      --force) force=1; shift ;;
      --no-key) skip_key=1; shift ;;
      -h|--help) cmd_remote_usage; return 0 ;;
      *) die "알 수 없는 remote setup 옵션: $1" ;;
    esac
  done

  # 기본값은 설정 파일에서 직접 읽는다. _remote_load를 쓰면 HH_REMOTE_* override가
  # 섞여서 "지금 파일에 무엇이 적혀 있나"와 "이번에 무엇을 쓸까"가 뒤엉킨다.
  local config_file existing_enabled=""
  local default_host="" default_user="" default_path="" default_mount="" default_key="" default_vcs=""
  config_file="$(_remote_config_path "$root")"
  if [[ -f "$config_file" ]] && ! ( _remote_assert_unique_keys "$config_file" ) >/dev/null 2>&1; then
    # setup은 깨진 설정을 다시 쓰는 복구 경로이기도 하다. 중복 키가 있으면
    # 기존 값을 기본값으로 믿을 수 없으므로 버리고, 전부 새로 받는다.
    info "기존 remote.yaml에 중복 키가 있어 기존 값을 기본값으로 쓰지 않고 새로 작성합니다: $config_file"
  elif [[ -f "$config_file" ]]; then
    existing_enabled="$(_remote_field "$config_file" enabled)"
    default_host="$(_remote_field "$config_file" host)"
    default_user="$(_remote_field "$config_file" user)"
    default_path="$(_remote_field "$config_file" path)"
    default_mount="$(_remote_field "$config_file" mount_path)"
    default_key="$(_remote_field "$config_file" ssh_key)"
    default_vcs="$(_remote_field "$config_file" vcs)"
  fi

  # 이미 쓸 수 있는 설정이 있으면 덮어쓰기를 명시적으로 요구한다. 기존 값은
  # 프롬프트 기본값으로 다시 보여 주므로, 재실행이 곧 "비밀번호만 다시 넣기"가 된다.
  if [[ "$existing_enabled" == true && -n "$default_host" && -n "$default_user" && -n "$default_path" && "$force" -ne 1 ]]; then
    die "이미 원격 모드가 설정되어 있습니다: $config_file
   값을 다시 쓰려면 --force, 키만 다시 등록하려면 $SCRIPT_NAME remote bootstrap-key 를 쓰세요."
  fi

  [[ -n "$default_user" ]] || default_user="${USER:-$(id -un)}"
  [[ -n "$default_mount" ]] || default_mount="$root/.harness/remote-mount"
  [[ -n "$default_key" ]] || default_key="~/.ssh/herdr_remote_ed25519"
  [[ -n "$default_vcs" ]] || default_vcs="git"

  [[ -n "$host" ]] || _remote_ask host "원격 호스트(SSH)" "$default_host"
  [[ -n "$user" ]] || _remote_ask user "원격 계정" "$default_user"
  [[ -n "$path" ]] || _remote_ask path "원격 프로젝트 경로(절대경로)" "$default_path"
  [[ -n "$mount" ]] || _remote_ask mount "SSHFS 마운트 경로(로컬)" "$default_mount"
  [[ -n "$ssh_key" ]] || _remote_ask ssh_key "전용 SSH 키 경로" "$default_key"
  [[ -n "$vcs" ]] || _remote_ask vcs "원격 VCS (git|svn|none)" "$default_vcs"

  case "$vcs" in
    git|svn|none) ;;
    *) die "지원하지 않는 vcs 값입니다: $vcs (git | svn | none)" ;;
  esac

  REMOTE_HOST="$host" REMOTE_USER="$user" REMOTE_PATH="$path" REMOTE_VCS="$vcs"
  REMOTE_SSH_KEY_RAW="$ssh_key"
  REMOTE_MOUNT_PATH="$(_remote_expand_tilde "$mount")"
  REMOTE_SSH_KEY="$(_remote_expand_tilde "$ssh_key")"
  _remote_validate_endpoint
  REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}"

  _remote_write_config "$root"
  info "원격 설정 기록: $config_file (비밀번호는 저장하지 않습니다)"

  if [[ "$skip_key" -eq 1 ]]; then
    info "키 등록을 건너뜁니다(--no-key). 나중에: $SCRIPT_NAME remote $root bootstrap-key"
    return 0
  fi

  # 키 단계로 들어가면 우리 환경의 비밀번호는 더 이상 필요 없다. 지역 변수로만
  # 들고 가서, 이후 status/ssh 자식 프로세스가 상속하지 않게 한다.
  local inherited_password="${HH_REMOTE_PASSWORD:-}"
  unset HH_REMOTE_PASSWORD

  if [[ -f "$REMOTE_SSH_KEY" ]] && _remote_ssh "true" >/dev/null 2>&1; then
    info "이미 키 인증으로 접속됩니다: $REMOTE_SSH_KEY — 비밀번호를 묻지 않습니다."
  else
    # 여기가 비밀번호를 받는 유일한 지점이다. 등록이 끝나면 변수에서 지운다.
    # 설정 파일은 이미 저장돼 있으므로, 등록만 실패해도 입력한 값은 남는다 —
    # 그 사실을 명시하고 다음 한 단계를 알려 준 뒤 비영으로 끝낸다.
    local password="$inherited_password"
    if [[ -z "$password" ]] && ! _remote_ask_password password; then
      _remote_setup_key_hint "$root"
      return 1
    fi
    if ! ( cmd_remote_bootstrap_key "$password" ); then
      password=""
      _remote_setup_key_hint "$root"
      return 1
    fi
    password=""
  fi

  printf '\n'
  cmd_remote_status || true
  printf '\n다음 단계:\n'
  printf '  %s remote %s doctor\n' "$SCRIPT_NAME" "$root"
  printf '  %s remote %s mount\n' "$SCRIPT_NAME" "$root"
}

cmd_remote_mount() {
  _remote_check_local_tools
  _remote_has sshfs || die "sshfs가 필요합니다: sudo apt install -y sshfs"
  _remote_has mountpoint || die "mountpoint가 필요합니다: sudo apt install -y util-linux"

  if _remote_is_mounted; then
    info "이미 마운트되어 있습니다: $REMOTE_MOUNT_PATH"
    return 0
  fi

  mkdir -p "$REMOTE_MOUNT_PATH"
  local -a options=(
    -o reconnect
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=accept-new
    -o idmap=user
  )

  if [[ "$(_remote_auth_mode)" == key ]]; then
    sshfs "${REMOTE_TARGET}:${REMOTE_PATH}" "$REMOTE_MOUNT_PATH" "${options[@]}" \
      -o "IdentityFile=${REMOTE_SSH_KEY}"
  else
    _remote_require_password_tool
    printf '%s\n' "$HH_REMOTE_PASSWORD" |
      sshfs "${REMOTE_TARGET}:${REMOTE_PATH}" "$REMOTE_MOUNT_PATH" "${options[@]}" -o password_stdin
  fi

  info "마운트 완료: $REMOTE_MOUNT_PATH -> ${REMOTE_TARGET}:${REMOTE_PATH}"
  info "Agent는 로컬에서 이 경로의 파일을 편집하고, 검증 명령만 'remote run'으로 원격 실행합니다."
}

cmd_remote_unmount() {
  if ! _remote_is_mounted; then
    info "마운트되어 있지 않습니다: $REMOTE_MOUNT_PATH"
    return 0
  fi
  if _remote_has fusermount3; then
    fusermount3 -u "$REMOTE_MOUNT_PATH"
  elif _remote_has fusermount; then
    fusermount -u "$REMOTE_MOUNT_PATH"
  else
    die "fusermount3 또는 fusermount가 필요합니다."
  fi
  info "마운트 해제 완료: $REMOTE_MOUNT_PATH"
}

cmd_remote_status() {
  printf '원격 대상:  %s\n' "$REMOTE_TARGET"
  printf '원격 경로:  %s\n' "$REMOTE_PATH"
  printf '마운트 경로: %s\n' "$REMOTE_MOUNT_PATH"
  printf 'VCS:        %s\n' "$REMOTE_VCS"
  printf '인증 방식:  %s\n' "$(_remote_auth_mode)"
  if _remote_is_mounted; then
    printf '마운트:     연결됨\n'
  else
    printf '마운트:     연결 안 됨\n'
  fi
  if _remote_ssh "test -d $(_remote_quote "$REMOTE_PATH")" >/dev/null 2>&1; then
    printf 'SSH/경로:   정상\n'
  else
    printf 'SSH/경로:   확인 실패\n'
    return 1
  fi
}

cmd_remote_doctor() {
  local failed=0
  printf '%s\n' '== 로컬 의존성 =='
  cmd_remote_deps || failed=1

  printf '\n%s\n' '== 원격 환경 =='
  if ! _remote_ssh "printf 'SSH 연결: 정상\\n'"; then
    printf 'SSH 연결: 실패 (%s)\n' "$REMOTE_TARGET" >&2
    return 1
  fi

  local vcs_tools='bash base64'
  [[ "$REMOTE_VCS" == none ]] || vcs_tools="$vcs_tools $REMOTE_VCS"
  local quoted_path
  quoted_path="$(_remote_quote "$REMOTE_PATH")"
  _remote_bash "if test -d $quoted_path; then
    printf '[OK]       프로젝트 경로: %s\\n' $quoted_path
  else
    printf '[MISSING]  프로젝트 경로: %s\\n' $quoted_path
    exit 1
  fi
  status=0
  for tool in $vcs_tools; do
    if command -v \"\$tool\" >/dev/null 2>&1; then
      printf '[OK]       %s: %s\\n' \"\$tool\" \"\$(command -v \"\$tool\")\"
    else
      printf '[MISSING]  %s\\n' \"\$tool\"
      status=1
    fi
  done
  exit \$status" || failed=1

  printf '\n%s\n' '== 마운트 상태 =='
  if _remote_is_mounted; then
    printf '[OK]       연결됨: %s\n' "$REMOTE_MOUNT_PATH"
  else
    printf '[INFO]     연결 안 됨: %s  (%s remote mount)\n' "$REMOTE_MOUNT_PATH" "$SCRIPT_NAME"
  fi
  return "$failed"
}

cmd_remote_shell() {
  _remote_check_local_tools
  _remote_ssh --tty "cd $(_remote_quote "$REMOTE_PATH") && exec bash -l"
}

cmd_remote_run() {
  _remote_check_local_tools
  (($# == 1)) ||
    die "run에는 따옴표로 감싼 명령 하나를 전달하세요. 예: $SCRIPT_NAME remote run 'make -j4 && ctest'"
  _remote_bash "set -Eeuo pipefail
cd $(_remote_quote "$REMOTE_PATH")
$1"
}

cmd_remote_vcs() {
  _remote_check_local_tools
  [[ "$REMOTE_VCS" != none ]] ||
    die "remote.yaml의 vcs가 none입니다. 'remote run'을 쓰거나 vcs를 git|svn으로 바꾸세요."
  (($# > 0)) || die "VCS 하위 명령이 필요합니다. 예: $SCRIPT_NAME remote vcs status"
  local command_text='' quoted argument
  for argument in "$@"; do
    printf -v quoted '%q' "$argument"
    command_text+=" $quoted"
  done
  _remote_bash "set -Eeuo pipefail
cd $(_remote_quote "$REMOTE_PATH")
$REMOTE_VCS$command_text"
}

cmd_remote_usage() {
  cat <<EOF
사용법: $SCRIPT_NAME remote [PATH] <하위 명령> [인수...]

  setup           최초 1회 대화형 설정 — 호스트·계정·경로를 묻고 remote.yaml을
                  만든 뒤, 비밀번호를 한 번만 입력받아 SSH 키를 등록한다.
                  옵션: --host --user --path --mount --ssh-key --vcs --force --no-key
  deps            로컬 의존성(ssh/sshfs/mountpoint/base64/sshpass)과 인증 방식 확인
  doctor          로컬 의존성 + SSH 연결 + 원격 경로·도구 + 마운트 상태 일괄 진단
  bootstrap-key   HH_REMOTE_PASSWORD로 1회 접속해 전용 SSH 키를 원격에 등록
  mount           원격 프로젝트를 mount_path에 SSHFS로 마운트
  unmount         SSHFS 마운트 해제
  status          현재 원격 설정과 연결·마운트 상태 요약
  run '<명령>'    원격 프로젝트 디렉터리에서 명령 실행 (빌드·테스트 검증용)
  vcs <인수...>   remote.yaml의 vcs(git|svn)를 원격에서 실행
  shell           원격 프로젝트 디렉터리에서 대화형 셸 (여기서 Agent를 띄우지 말 것)

설정 정본: $REMOTE_CONFIG_REL   비밀번호는 저장하지 않고 HH_REMOTE_PASSWORD로만 전달합니다.
환경변수 override: HH_REMOTE_HOST, HH_REMOTE_USER, HH_REMOTE_PATH,
  HH_REMOTE_MOUNT_PATH, HH_REMOTE_SSH_KEY, HH_REMOTE_VCS, HH_REMOTE_PASSWORD
EOF
}

cmd_remote() {
  local root_arg="." subcommand=""
  # remote [PATH] <하위 명령> — PATH는 생략 가능하다. 첫 인자가 알려진 하위
  # 명령이면 그것을 쓰고, 아니면 경로로 보되 그 다음 인자는 반드시 알려진 하위
  # 명령이어야 한다(오타를 경로로 삼켜 도움말만 찍고 0으로 끝내지 않기 위해).
  case "${1:-}" in
    ""|-h|--help|help) cmd_remote_usage; return 0 ;;
    setup|deps|doctor|bootstrap-key|mount|unmount|status|run|vcs|shell) subcommand="$1"; shift ;;
    -*) die "알 수 없는 remote 옵션: $1" ;;
    *) root_arg="$1"; shift
       subcommand="${1:-}"
       [[ -n "$subcommand" ]] || die "remote에는 하위 명령이 필요합니다. 도움말: $SCRIPT_NAME remote help"
       case "$subcommand" in
         -h|--help|help) cmd_remote_usage; return 0 ;;
         setup|deps|doctor|bootstrap-key|mount|unmount|status|run|vcs|shell) ;;
         *) die "알 수 없는 remote 하위 명령: $subcommand (도움말: $SCRIPT_NAME remote help)" ;;
       esac
       shift ;;
  esac

  local root
  root="$(project_root "$root_arg")"

  # setup은 설정을 "만드는" 명령이라 설정 존재 검사보다 앞에 온다.
  if [[ "$subcommand" == setup ]]; then
    cmd_remote_setup "$root" "$@"
    return $?
  fi

  _remote_require "$root"

  case "$subcommand" in
    deps)          cmd_remote_deps ;;
    doctor)        cmd_remote_doctor ;;
    bootstrap-key) cmd_remote_bootstrap_key ;;
    mount)         cmd_remote_mount ;;
    unmount)       cmd_remote_unmount ;;
    status)        cmd_remote_status ;;
    shell)         cmd_remote_shell ;;
    run)           cmd_remote_run "$@" ;;
    vcs)           cmd_remote_vcs "$@" ;;
    *)             die "알 수 없는 remote 하위 명령: $subcommand (도움말: $SCRIPT_NAME remote help)" ;;
  esac
}

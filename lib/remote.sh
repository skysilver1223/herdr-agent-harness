# herdr-harness: 원격 실행 모드.
# Agent는 항상 로컬에서 돈다. 원격은 "소스는 SSHFS로 로컬에 노출하고, 빌드·테스트·VCS만
# SSH로 원격에서 실행"하는 실행 환경이다. 설정 정본은 .harness/remote.yaml 하나다.
# 비밀번호는 어떤 파일에도 저장하지 않는다. 최초 1회 HH_REMOTE_PASSWORD로 SSH 키를 등록하고
# 이후에는 키 인증만 쓴다.
# harness.sh가 source한다. 단독 실행하지 않는다.

remote_config() { printf '%s/.harness/remote.yaml' "$ROOT"; }

# 값 뒤 YAML 주석을 잘라낸다. #는 줄 첫머리이거나 앞이 공백일 때만 주석이다
# (`path: /srv/a#b`의 #는 값). 따옴표 안의 #도 값이다.
_remote_strip_comment() {
  local line="$1" out="" quote="" i c prev=""
  for ((i = 0; i < ${#line}; i++)); do
    c="${line:i:1}"
    if [[ -n "$quote" ]]; then
      out+="$c"
      if [[ "$quote" == '"' && "$c" == "\\" ]]; then i=$((i + 1)); out+="${line:i:1}"; prev="${line:i:1}"; continue; fi
      [[ "$c" != "$quote" ]] || quote=""
      prev="$c"; continue
    fi
    case "$c" in
      "'"|'"') quote="$c"; out+="$c" ;;
      '#') if [[ -z "$prev" || "$prev" == [[:space:]] ]]; then break; fi; out+="$c" ;;
      *) out+="$c" ;;
    esac
    prev="$c"
  done
  printf '%s' "$out"
}

# 중복 키 검사는 메인 셸에서 먼저 한다. _remote_field는 $( ) 안에서 불려 die가 삼켜진다.
_remote_assert_unique_keys() {
  local dup
  dup="$(awk '$0 == "remote:" { r = 1; next } /^[^[:space:]#]/ { r = 0 }
    r && /^  [A-Za-z_][A-Za-z0-9_]*:/ { k = $1; sub(/:$/, "", k); if (seen[k]++ == 1) print k }' "$1")"
  [[ -z "$dup" ]] || die "remote.yaml에서 키가 중복되었습니다: $(tr '\n' ',' <<<"$dup" | sed 's/,$//') ($1)"
}

_remote_field() {  # FILE KEY → remote: 아래 값 (없거나 중복이면 빈 값)
  local line
  [[ "$(awk -v k="  $2:" '$0 == "remote:" { r = 1; next } /^[^[:space:]#]/ { r = 0 } r && index($0, k) == 1 { n++ } END { print n + 0 }' "$1")" -eq 1 ]] || return 0
  line="$(awk -v k="  $2:" '$0 == "remote:" { r = 1; next } /^[^[:space:]#]/ { r = 0 } r && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1")"
  unquote "$(_remote_strip_comment "$line")"
}

_remote_expand_tilde() {
  case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s%s' "$HOME" "${1#\~}" ;; *) printf '%s' "$1" ;; esac
}

# SSH는 "-"로 시작하는 목적지를 옵션으로 해석한다(`-oProxyCommand=...`). 형태 자체를 제한한다.
_remote_validate_endpoint() {
  [[ "$REMOTE_USER" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] ||
    die "원격 사용자명에 허용되지 않는 문자가 있습니다(영문·숫자·. _ -, 첫 글자는 - 불가): $REMOTE_USER"
  [[ "$REMOTE_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ || "$REMOTE_HOST" =~ ^\[[0-9A-Fa-f:]+\]$ ]] ||
    die "원격 호스트 형식이 올바르지 않습니다(호스트명·IPv4 또는 [IPv6], 포트 제외): $REMOTE_HOST"
  [[ "$REMOTE_PATH" == /* ]] || die "원격 프로젝트 경로는 절대경로여야 합니다: $REMOTE_PATH"
  local f
  for f in "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_PATH" "$REMOTE_MOUNT_PATH" "$REMOTE_SSH_KEY"; do
    [[ "$f" != *[[:cntrl:]]* ]] || die "원격 설정 값에 제어문자(개행·탭 등)가 들어갈 수 없습니다."
  done
}

# mount_options는 sshfs의 -o 값 하나로 넘긴다(쉼표로 여러 개). 예: 원격의 절대경로 심볼릭 링크가 로컬에서 끊겨
# 보이면 follow_symlinks. 허용 목록의 옵션만 받는다: ssh_command·ProxyCommand·LocalCommand처럼 명령을 실행하거나
# directport·allow_other처럼 보안을 낮추는 옵션이 remote.yaml로 들어오지 않게 한다(_remote_validate_endpoint와 같은 이유).
# 마운트·setup 때만 검사한다(원격 실행은 막지 않는다).
_remote_validate_mount_options() {
  local opt key
  local -a opts=()
  [[ -n "$REMOTE_MOUNT_OPTIONS" ]] || return 0
  [[ "$REMOTE_MOUNT_OPTIONS" =~ ^[A-Za-z0-9_][A-Za-z0-9_=.,:/@+~%-]*$ ]] ||
    die "mount_options는 sshfs -o 옵션을 공백 없이 쉼표로 이은 값입니다(예: follow_symlinks): $REMOTE_MOUNT_OPTIONS"
  [[ "$REMOTE_MOUNT_OPTIONS" != *, ]] || die "mount_options에 빈 항목이 있습니다(끝 쉼표): $REMOTE_MOUNT_OPTIONS"   # read -a는 끝의 빈 필드를 버린다
  IFS=, read -r -a opts <<<"$REMOTE_MOUNT_OPTIONS"
  for opt in "${opts[@]}"; do
    key="${opt%%=*}"
    [[ -n "$key" ]] || die "mount_options에 빈 항목이 있습니다(쉼표가 겹침): $REMOTE_MOUNT_OPTIONS"
    # ssh에 넘어가는 옵션은 ssh처럼 대소문자를 가리지 않는다. sshfs·FUSE 옵션은 대소문자를 가린다.
    case "${key,,}" in port|serveraliveinterval|serveralivecountmax|connecttimeout|tcpkeepalive|compression) continue ;; esac
    case "$key" in
      follow_symlinks|transform_symlinks|idmap|uid|gid|umask|default_permissions|ro|rw|noatime|nonempty) ;;
      reconnect|delay_connect|max_conns|workaround|no_check_root|max_read|max_write|big_writes) ;;
      no_readahead|sync_readdir|sshfs_sync|direct_io|kernel_cache|auto_cache|entry_timeout|attr_timeout|negative_timeout) ;;
      cache|dir_cache|cache_*|dcache_*) ;;
      *) die "mount_options에 쓸 수 없는 옵션입니다: $key — 명령을 실행하거나 보안을 낮출 수 있는 옵션은 받지 않는다(sshfs 옵션은 소문자 그대로). 쓸 수 있는 것: follow_symlinks, transform_symlinks, idmap·uid·gid·umask, cache 계열, compression, reconnect, Port, ServerAlive*, ConnectTimeout 등 (lib/remote.sh)" ;;
    esac
  done
}

_remote_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# 설정 + 환경변수 override → REMOTE_*. 반환 1 = 설정 없음, 2 = enabled: false.
_remote_load() {
  local file enabled
  file="$(remote_config)"
  [[ -f "$file" ]] || return 1
  _remote_assert_unique_keys "$file"
  enabled="$(_remote_field "$file" enabled)"
  REMOTE_HOST="${HH_REMOTE_HOST:-$(_remote_field "$file" host)}"
  REMOTE_USER="${HH_REMOTE_USER:-$(_remote_field "$file" user)}"
  REMOTE_PATH="${HH_REMOTE_PATH:-$(_remote_field "$file" path)}"
  REMOTE_MOUNT_PATH="${HH_REMOTE_MOUNT_PATH:-$(_remote_field "$file" mount_path)}"
  REMOTE_SSH_KEY="${HH_REMOTE_SSH_KEY:-$(_remote_field "$file" ssh_key)}"
  REMOTE_SSH_KEY_RAW="$REMOTE_SSH_KEY"
  REMOTE_VCS="${HH_REMOTE_VCS:-$(_remote_field "$file" vcs)}"
  REMOTE_MOUNT_OPTIONS="${HH_REMOTE_MOUNT_OPTIONS:-$(_remote_field "$file" mount_options)}"
  [[ -n "$REMOTE_MOUNT_PATH" ]] || REMOTE_MOUNT_PATH="$ROOT/.harness/remote-mount"
  [[ -n "$REMOTE_SSH_KEY" ]] || REMOTE_SSH_KEY="$HOME/.ssh/herdr_remote_ed25519"
  [[ -n "$REMOTE_VCS" ]] || REMOTE_VCS=git
  REMOTE_MOUNT_PATH="$(_remote_expand_tilde "$REMOTE_MOUNT_PATH")"
  REMOTE_SSH_KEY="$(_remote_expand_tilde "$REMOTE_SSH_KEY")"
  [[ "$enabled" == true ]] || return 2
  [[ -n "$REMOTE_HOST" && -n "$REMOTE_USER" && -n "$REMOTE_PATH" ]] || die "remote.yaml에 host·user·path가 모두 필요합니다: $file"
  case "$REMOTE_VCS" in git|svn|none) ;; *) die "지원하지 않는 vcs 값입니다: $REMOTE_VCS (git | svn | none)" ;; esac
  _remote_validate_endpoint
  REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
  return 0
}

_remote_require() {
  local status=0
  _remote_load || status=$?
  case "$status" in
    1) die "원격 설정이 없습니다: $(rel "$(remote_config)") — remote setup으로 만든다." ;;
    2) die "원격 모드가 꺼져 있습니다: $(rel "$(remote_config)")의 enabled를 true로 바꾼다." ;;
  esac
  return 0
}

remote_mount_path() {  # 원격 모드의 코드 디렉터리 = SSHFS 마운트 경로
  local m
  m="$(_remote_field "$(remote_config)" mount_path)"
  m="$(_remote_expand_tilde "${m:-$ROOT/.harness/remote-mount}")"
  printf '%s' "$m"
}

_remote_has() { command -v "$1" >/dev/null 2>&1; }
_remote_is_mounted() { mountpoint -q "$REMOTE_MOUNT_PATH" 2>/dev/null; }
_remote_auth_mode() { if [[ -f "$REMOTE_SSH_KEY" ]]; then printf key; else printf password; fi; }

_remote_require_password_tool() {
  [[ "$(_remote_auth_mode)" == password ]] || return 0
  [[ -n "${HH_REMOTE_PASSWORD:-}" ]] || die "SSH 키($REMOTE_SSH_KEY)가 없습니다. HH_REMOTE_PASSWORD를 준 뒤 remote bootstrap-key로 키를 등록한다."
  _remote_has sshpass || die "비밀번호 인증에 sshpass가 필요합니다: sudo apt install -y sshpass"
}

_remote_ssh() {
  # 대화형 셸(--tty)이 아니면 -n: ssh가 호출한 쪽의 표준 입력을 먹지 않게 한다. 반복문 안에서 부르면
  # 남은 입력(다음 AC 등)을 삼켜 첫 명령만 실행되는 결함이 v1에서 실제로 있었다.
  local -a opts=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=3) tty=(-n)
  if [[ "${1:-}" == --tty ]]; then tty=(-t); shift; fi
  if [[ "$(_remote_auth_mode)" == key ]]; then
    ssh ${tty[@]+"${tty[@]}"} "${opts[@]}" -i "$REMOTE_SSH_KEY" "$REMOTE_TARGET" "$@"
  else
    _remote_require_password_tool
    SSHPASS="$HH_REMOTE_PASSWORD" sshpass -e ssh ${tty[@]+"${tty[@]}"} "${opts[@]}" "$REMOTE_TARGET" "$@"
  fi
}

# 따옴표·개행이 섞인 스크립트를 원격 셸 인용 규칙과 무관하게 그대로 넘긴다.
_remote_bash() { _remote_ssh "printf '%s' '$(printf '%s' "$1" | base64 -w 0)' | base64 -d | bash"; }

_remote_check_local_tools() {
  local missing=() t
  for t in ssh base64; do _remote_has "$t" || missing+=("$t"); done
  (( ${#missing[@]} == 0 )) || die "로컬에 필요한 명령이 없습니다: ${missing[*]} (sudo apt install -y openssh-client coreutils)"
}

remote_deps() {
  local failed=0 t
  for t in ssh sshfs mountpoint base64; do
    if _remote_has "$t"; then printf '[OK]       %-11s\n' "$t"; else printf '[MISSING]  %-11s\n' "$t"; failed=1; fi
  done
  if _remote_has sshpass; then printf '[OK]       sshpass\n'
  elif [[ "$(_remote_auth_mode)" == password ]]; then printf '[MISSING]  sshpass (비밀번호 인증에 필요)\n'; failed=1
  else printf '[OPTIONAL] sshpass (키 인증 중)\n'; fi
  printf '인증 방식: %s (%s)\n' "$(_remote_auth_mode)" "$REMOTE_SSH_KEY"
  (( failed == 0 )) || printf '설치: sudo apt update && sudo apt install -y openssh-client sshfs util-linux sshpass\n'
  return "$failed"
}

# 비밀번호는 인자로 받는다(없으면 HH_REMOTE_PASSWORD). export하면 무관한 자식까지 상속한다.
remote_bootstrap_key() {
  local password="${1:-${HH_REMOTE_PASSWORD:-}}" key
  _remote_check_local_tools
  _remote_has ssh-keygen || die "ssh-keygen이 필요합니다."
  [[ -n "$password" ]] || die "최초 등록에는 원격 비밀번호가 필요합니다: HH_REMOTE_PASSWORD=... remote bootstrap-key"
  _remote_has sshpass || die "sshpass가 필요합니다: sudo apt install -y sshpass"
  if [[ ! -f "$REMOTE_SSH_KEY" ]]; then
    mkdir -p "$(dirname "$REMOTE_SSH_KEY")"; chmod 700 "$(dirname "$REMOTE_SSH_KEY")"
    ssh-keygen -q -t ed25519 -N '' -f "$REMOTE_SSH_KEY" -C "herdr-harness@$(hostname)"
    info "SSH 키 생성: $REMOTE_SSH_KEY"
  fi
  key="$(base64 -w 0 <"${REMOTE_SSH_KEY}.pub")"
  SSHPASS="$password" sshpass -e ssh -n -o StrictHostKeyChecking=accept-new "$REMOTE_TARGET" \
    "key=\$(printf '%s' '$key' | base64 -d); umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF \"\$key\" ~/.ssh/authorized_keys || printf '%s\\n' \"\$key\" >> ~/.ssh/authorized_keys"
  info "SSH 키 등록 완료. 이후에는 HH_REMOTE_PASSWORD 없이 접속한다 — 환경변수를 지운다."
}

# 비대화형(stdin이나 stdout이 터미널이 아님)에서는 묻지 않는다: 기본값이 있으면 쓰고, 없으면 실패한다.
_remote_ask() {
  local var="$1" label="$2" default="${3:-}" value=""
  if [[ ! -t 0 || ! -t 1 ]]; then
    [[ -n "$default" ]] || die "비대화형 실행에서는 값을 물어볼 수 없습니다. 옵션으로 전달한다: $label"
    printf -v "$var" '%s' "$default"; return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -e -p "$label [$default]: " value || die "입력을 읽지 못했습니다: $label"
    value="${value:-$default}"
  else
    while [[ -z "$value" ]]; do read -r -e -p "$label: " value || die "입력을 읽지 못했습니다: $label"; done
  fi
  printf -v "$var" '%s' "$value"
}

_remote_ask_password() {
  local var="$1" value=""
  if [[ ! -t 0 ]]; then
    printf '오류: 비대화형에서는 비밀번호를 물어볼 수 없습니다. HH_REMOTE_PASSWORD로 주거나 --no-key를 쓴다.\n' >&2
    return 1
  fi
  while [[ -z "$value" ]]; do
    read -r -s -p "원격 비밀번호(키 등록에만 사용, 저장하지 않음): " value || { printf '\n' >&2; return 1; }
    printf '\n'
  done
  printf -v "$var" '%s' "$value"
}

_remote_write_config() {
  write_atomic "$(remote_config)" <<EOF
schema_version: '1.0'
remote:
  # Agent는 로컬에서 실행된다. 원격은 소스를 SSHFS로 노출하고 빌드·테스트·VCS만 SSH로 실행한다.
  enabled: true
  host: $(yaml_q "$REMOTE_HOST")
  user: $(yaml_q "$REMOTE_USER")
  # 원격 호스트의 프로젝트 디렉터리
  path: $(yaml_q "$REMOTE_PATH")
  # SSHFS 마운트 경로(로컬). 원격 모드에서는 이곳이 코드 디렉터리다.
  mount_path: $(yaml_q "$REMOTE_MOUNT_PATH")
  # sshfs에 더할 -o 옵션(쉼표로 구분, 선택). 원격의 절대경로 심볼릭 링크를 따라가려면 'follow_symlinks'
  mount_options: $(yaml_q "$REMOTE_MOUNT_OPTIONS")
  # bootstrap-key가 만드는 전용 키. 파일이 있으면 항상 키 인증을 쓴다.
  ssh_key: $(yaml_q "$REMOTE_SSH_KEY_RAW")
  # remote vcs가 원격에서 실행할 명령: git | svn | none
  vcs: '$REMOTE_VCS'
EOF
}

remote_setup() {
  local host="" user="" path="" mount="" ssh_key="" vcs="" mopts="" mopts_set=0 force=0 skip_key=0 file
  local d_host="" d_user="" d_path="" d_mount="" d_key="" d_vcs="" d_mopts="" enabled=""
  while (( $# )); do
    case "$1" in
      --host|--user|--path|--mount|--ssh-key|--vcs)
        [[ $# -ge 2 ]] || die "$1 값이 필요합니다."
        case "$1" in --host) host="$2" ;; --user) user="$2" ;; --path) path="$2" ;; --mount) mount="$2" ;; --ssh-key) ssh_key="$2" ;; --vcs) vcs="$2" ;; esac
        shift 2 ;;
      --mount-options) [[ $# -ge 2 ]] || die "$1 값이 필요합니다 (지우려면 '')."; mopts="$2"; mopts_set=1; shift 2 ;;
      --force) force=1; shift ;;
      --no-key) skip_key=1; shift ;;
      *) die "알 수 없는 remote setup 옵션: $1" ;;
    esac
  done
  file="$(remote_config)"
  if [[ -f "$file" ]] && ( _remote_assert_unique_keys "$file" ) >/dev/null 2>&1; then
    enabled="$(_remote_field "$file" enabled)"
    d_host="$(_remote_field "$file" host)"; d_user="$(_remote_field "$file" user)"; d_path="$(_remote_field "$file" path)"
    d_mount="$(_remote_field "$file" mount_path)"; d_key="$(_remote_field "$file" ssh_key)"; d_vcs="$(_remote_field "$file" vcs)"
    d_mopts="$(_remote_field "$file" mount_options)"
  fi
  if [[ "$enabled" == true && -n "$d_host" && -n "$d_user" && -n "$d_path" && $force -ne 1 ]]; then
    die "이미 원격 모드가 설정되어 있습니다: $(rel "$file") — 다시 쓰려면 --force, 키만 다시 등록하려면 remote bootstrap-key."
  fi
  [[ -n "$d_user" ]] || d_user="${USER:-$(id -un)}"
  [[ -n "$d_mount" ]] || d_mount="$ROOT/.harness/remote-mount"
  [[ -n "$d_key" ]] || d_key="~/.ssh/herdr_remote_ed25519"
  [[ -n "$d_vcs" ]] || d_vcs=git
  [[ -n "$host" ]] || _remote_ask host "원격 호스트(SSH)" "$d_host"
  [[ -n "$user" ]] || _remote_ask user "원격 계정" "$d_user"
  [[ -n "$path" ]] || _remote_ask path "원격 프로젝트 경로(절대경로)" "$d_path"
  [[ -n "$mount" ]] || _remote_ask mount "SSHFS 마운트 경로(로컬)" "$d_mount"
  [[ -n "$ssh_key" ]] || _remote_ask ssh_key "전용 SSH 키 경로" "$d_key"
  [[ -n "$vcs" ]] || _remote_ask vcs "원격 VCS (git|svn|none)" "$d_vcs"
  case "$vcs" in git|svn|none) ;; *) die "지원하지 않는 vcs 값입니다: $vcs" ;; esac
  (( mopts_set )) || mopts="$d_mopts"   # 묻지 않는 선택 값: 주지 않으면 기존 값을 지킨다
  REMOTE_HOST="$host" REMOTE_USER="$user" REMOTE_PATH="$path" REMOTE_VCS="$vcs" REMOTE_SSH_KEY_RAW="$ssh_key" REMOTE_MOUNT_OPTIONS="$mopts"
  REMOTE_MOUNT_PATH="$(_remote_expand_tilde "$mount")"; REMOTE_SSH_KEY="$(_remote_expand_tilde "$ssh_key")"
  _remote_validate_endpoint
  _remote_validate_mount_options
  REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
  _remote_write_config
  info "원격 설정 기록: $(rel "$file") (비밀번호는 저장하지 않는다)"
  if (( skip_key )); then info "키 등록을 건너뜁니다. 나중에: remote bootstrap-key"; return 0; fi
  local inherited="${HH_REMOTE_PASSWORD:-}" password
  unset HH_REMOTE_PASSWORD
  if [[ -f "$REMOTE_SSH_KEY" ]] && _remote_ssh true >/dev/null 2>&1; then
    info "이미 키 인증으로 접속됩니다 — 비밀번호를 묻지 않습니다."
  else
    password="$inherited"
    if [[ -z "$password" ]] && ! _remote_ask_password password; then
      info "설정은 저장됐습니다. 키 등록만 다시: HH_REMOTE_PASSWORD=... remote bootstrap-key"; exit 1
    fi
    if ! ( remote_bootstrap_key "$password" ); then
      info "설정은 저장됐습니다. 키 등록만 다시: HH_REMOTE_PASSWORD=... remote bootstrap-key"; exit 1
    fi
    password=""
  fi
  remote_status || true
  printf '\n다음: remote doctor → remote mount\n'
}

remote_mount() {
  _remote_check_local_tools
  _remote_has sshfs || die "sshfs가 필요합니다: sudo apt install -y sshfs"
  _remote_has mountpoint || die "mountpoint가 필요합니다: sudo apt install -y util-linux"
  _remote_validate_mount_options
  if _remote_is_mounted; then info "이미 마운트되어 있습니다: $REMOTE_MOUNT_PATH (mount_options를 바꿨다면 remote unmount 뒤 다시 mount)"; return 0; fi
  mkdir -p "$REMOTE_MOUNT_PATH"
  local -a opts=(-o reconnect -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -o idmap=user)
  [[ -z "$REMOTE_MOUNT_OPTIONS" ]] || opts+=(-o "$REMOTE_MOUNT_OPTIONS")
  if [[ "$(_remote_auth_mode)" == key ]]; then
    sshfs "${REMOTE_TARGET}:${REMOTE_PATH}" "$REMOTE_MOUNT_PATH" "${opts[@]}" -o "IdentityFile=${REMOTE_SSH_KEY}"
  else
    _remote_require_password_tool
    printf '%s\n' "$HH_REMOTE_PASSWORD" | sshfs "${REMOTE_TARGET}:${REMOTE_PATH}" "$REMOTE_MOUNT_PATH" "${opts[@]}" -o password_stdin
  fi
  info "마운트 완료: $REMOTE_MOUNT_PATH -> ${REMOTE_TARGET}:${REMOTE_PATH}"
}

remote_unmount() {
  if ! _remote_is_mounted; then info "마운트되어 있지 않습니다: $REMOTE_MOUNT_PATH"; return 0; fi
  if _remote_has fusermount3; then fusermount3 -u "$REMOTE_MOUNT_PATH"
  elif _remote_has fusermount; then fusermount -u "$REMOTE_MOUNT_PATH"
  else die "fusermount3 또는 fusermount가 필요합니다."; fi
  info "마운트 해제 완료: $REMOTE_MOUNT_PATH"
}

remote_status() {
  printf '원격 대상:   %s\n원격 경로:   %s\n마운트 경로: %s\n마운트 옵션: %s\nVCS:         %s\n인증 방식:   %s\n' \
    "$REMOTE_TARGET" "$REMOTE_PATH" "$REMOTE_MOUNT_PATH" "${REMOTE_MOUNT_OPTIONS:-(기본)}" "$REMOTE_VCS" "$(_remote_auth_mode)"
  if _remote_is_mounted; then printf '마운트:      연결됨\n'; else printf '마운트:      연결 안 됨\n'; fi
  if _remote_ssh "test -d $(_remote_quote "$REMOTE_PATH")" >/dev/null 2>&1; then printf 'SSH/경로:    정상\n'
  else printf 'SSH/경로:    확인 실패\n'; return 1; fi
}

remote_doctor() {
  local failed=0 tools='bash base64' q
  printf '== 로컬 의존성 ==\n'; remote_deps || failed=1
  printf '\n== 원격 환경 ==\n'
  _remote_ssh "printf 'SSH 연결: 정상\\n'" || { printf 'SSH 연결: 실패 (%s)\n' "$REMOTE_TARGET" >&2; return 1; }
  [[ "$REMOTE_VCS" == none ]] || tools="$tools $REMOTE_VCS"
  q="$(_remote_quote "$REMOTE_PATH")"
  _remote_bash "if test -d $q; then printf '[OK]       프로젝트 경로: %s\\n' $q; else printf '[MISSING]  프로젝트 경로: %s\\n' $q; exit 1; fi
status=0
for tool in $tools; do
  if command -v \"\$tool\" >/dev/null 2>&1; then printf '[OK]       %s\\n' \"\$tool\"; else printf '[MISSING]  %s\\n' \"\$tool\"; status=1; fi
done
exit \$status" || failed=1
  printf '\n== 마운트 ==\n'
  if _remote_is_mounted; then printf '[OK]       연결됨: %s\n' "$REMOTE_MOUNT_PATH"; else printf '[INFO]     연결 안 됨: %s (remote mount)\n' "$REMOTE_MOUNT_PATH"; fi
  return "$failed"
}

remote_run() {
  _remote_check_local_tools
  (( $# == 1 )) || die "run에는 따옴표로 감싼 명령 하나를 준다. 예: remote run 'make -j4 && ctest'"
  _remote_bash "set -Eeuo pipefail
cd $(_remote_quote "$REMOTE_PATH")
$1"
}

remote_vcs() {
  _remote_check_local_tools
  [[ "$REMOTE_VCS" != none ]] || die "remote.yaml의 vcs가 none입니다. remote run을 쓰거나 vcs를 git|svn으로 바꾼다."
  (( $# > 0 )) || die "VCS 하위 명령이 필요합니다. 예: remote vcs status"
  local text='' q a
  for a in "$@"; do printf -v q '%q' "$a"; text+=" $q"; done
  _remote_bash "set -Eeuo pipefail
cd $(_remote_quote "$REMOTE_PATH")
$REMOTE_VCS$text"
}

remote_usage() {
  cat <<'EOF'
사용법: harness.sh remote <하위 명령>

  setup           최초 1회 — 호스트·계정·경로를 묻고 remote.yaml을 만든 뒤 SSH 키 등록
                  옵션: --host --user --path --mount --ssh-key --vcs --mount-options --force --no-key
                  (--mount-options는 묻지 않는다. 허용 목록의 sshfs -o 값, 예: follow_symlinks — 주지 않으면 기존 값 유지)
  doctor          로컬 의존성 + SSH 연결 + 원격 경로·도구 + 마운트 일괄 진단
  deps            로컬 의존성과 인증 방식
  bootstrap-key   HH_REMOTE_PASSWORD로 1회 접속해 전용 SSH 키 등록
  mount|unmount   원격 프로젝트를 SSHFS로 마운트/해제 (원격 모드의 코드 디렉터리)
  status          설정과 연결·마운트 상태
  run '<명령>'    원격 프로젝트 디렉터리에서 명령 실행 (빌드·테스트·AC)
  vcs <인수...>   remote.yaml의 vcs(git|svn)를 원격에서 실행
  shell           원격 프로젝트 디렉터리에서 대화형 셸

비밀번호는 저장하지 않고 HH_REMOTE_PASSWORD로만 전달한다.
환경변수 override: HH_REMOTE_HOST, HH_REMOTE_USER, HH_REMOTE_PATH, HH_REMOTE_MOUNT_PATH, HH_REMOTE_SSH_KEY, HH_REMOTE_VCS,
                   HH_REMOTE_MOUNT_OPTIONS
EOF
}

cmd_remote() {
  local sub="${1:-help}"
  (( $# == 0 )) || shift
  case "$sub" in
    help|-h|--help) remote_usage; return 0 ;;
    setup) remote_setup "$@"; return ;;
  esac
  _remote_require
  case "$sub" in
    # 진단·원격 명령의 실패 종료 코드는 그대로 돌려준다(예상한 실패라 오류 위치를 찍지 않는다).
    deps) remote_deps || exit $? ;;
    doctor) remote_doctor || exit $? ;;
    bootstrap-key) remote_bootstrap_key ;;
    mount) remote_mount ;;
    unmount) remote_unmount ;;
    status) remote_status || exit $? ;;
    run) remote_run "$@" || exit $? ;;
    vcs) remote_vcs "$@" || exit $? ;;
    shell) _remote_check_local_tools; _remote_ssh --tty "cd $(_remote_quote "$REMOTE_PATH") && exec bash -l" ;;
    *) die "알 수 없는 remote 하위 명령: $sub (remote help)" ;;
  esac
}

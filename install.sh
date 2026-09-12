#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/harness.sh"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-harness"
BIN_DIR="$HOME/.local/bin"
COMMAND_PATH="$BIN_DIR/herdr-harness"
BASHRC="$HOME/.bashrc"
COMPLETION_BEGIN='# >>> herdr-harness bash completion >>>'
COMPLETION_END='# <<< herdr-harness bash completion <<<'
COMPLETION_LOADER='source <(herdr-harness completion bash)'

# ~/.bashrc에 completion 로더를 마커로 감싼 관리 블록으로 정확히 한 번 등록한다.
# 이미 로더 줄이 있으면(마커 유무 무관) 아무것도 하지 않는다. 기존 내용은
# 재정렬·정규화하지 않고 파일 끝에만 덧붙인다.
# 반환: 0=새로 등록함, 1=이미 있어 건너뜀.
register_bash_completion() {
  local bashrc="$1"
  if [[ -f "$bashrc" ]] && grep -qF -- "$COMPLETION_LOADER" "$bashrc"; then
    return 1
  fi
  if [[ -s "$bashrc" ]] && [[ -n "$(tail -c1 -- "$bashrc")" ]]; then
    printf '\n' >>"$bashrc"
  fi
  {
    printf '%s\n' "$COMPLETION_BEGIN"
    printf '%s\n' "$COMPLETION_LOADER"
    printf '%s\n' "$COMPLETION_END"
  } >>"$bashrc"
  return 0
}

# 등록 시 넣은 관리 블록(마커 두 줄 + 그 사이)만 제거한다. 사용자가 직접 넣은
# 마커 없는 줄이나 다른 ~/.bashrc 내용은 건드리지 않는다.
# 반환: 0=제거함, 1=관리 블록 없음.
deregister_bash_completion() {
  local bashrc="$1" tmp
  [[ -f "$bashrc" ]] || return 1
  grep -qF -- "$COMPLETION_BEGIN" "$bashrc" || return 1
  tmp="$(mktemp -- "$bashrc.herdr.XXXXXX")"
  sed "/^${COMPLETION_BEGIN}$/,/^${COMPLETION_END}$/d" -- "$bashrc" >"$tmp"
  chmod --reference="$bashrc" -- "$tmp" 2>/dev/null || true
  mv -- "$tmp" "$bashrc"
  return 0
}

usage() {
  cat <<'EOF'
Herdr Agent/Skills Harness 설치

사용법:
  ./install.sh
  ./install.sh --with-herdr-skill
  ./install.sh --uninstall

옵션:
  --with-herdr-skill  공식 Herdr Skill도 전역 설치
  --uninstall         설치된 명령 제거
  -h, --help          도움말
EOF
}

WITH_HERDR_SKILL=0
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-herdr-skill) WITH_HERDR_SKILL=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '오류: 알 수 없는 옵션: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

if [[ "$UNINSTALL" -eq 1 ]]; then
  if [[ -L "$COMMAND_PATH" ]] && [[ "$(readlink "$COMMAND_PATH")" == "$INSTALL_DIR/harness.sh" ]]; then
    unlink "$COMMAND_PATH"
  fi
  if [[ -f "$INSTALL_DIR/harness.sh" ]]; then
    unlink "$INSTALL_DIR/harness.sh"
  fi
  rm -rf "$INSTALL_DIR/lib" "$INSTALL_DIR/templates"
  rmdir "$INSTALL_DIR" 2>/dev/null || true
  if deregister_bash_completion "$BASHRC"; then
    printf '탭 완성 로더 관리 블록을 %s에서 제거했습니다.\n' "$BASHRC"
  fi
  printf '제거 완료: %s\n' "$COMMAND_PATH"
  exit 0
fi

[[ -f "$SOURCE" ]] || {
  printf '오류: install.sh와 harness.sh는 같은 디렉터리에 있어야 합니다.\n' >&2
  exit 1
}
for _dir in lib templates; do
  [[ -d "$SCRIPT_DIR/$_dir" ]] || {
    printf '오류: %s/ 디렉터리가 없습니다. 저장소를 온전히 clone했는지 확인하세요.\n' "$_dir" >&2
    exit 1
  }
done

bash -n "$SOURCE"
for _lib in "$SCRIPT_DIR"/lib/*.sh; do bash -n "$_lib"; done
mkdir -p "$INSTALL_DIR" "$BIN_DIR"
install -m 0755 "$SOURCE" "$INSTALL_DIR/harness.sh"
rm -rf "$INSTALL_DIR/lib" "$INSTALL_DIR/templates"
cp -R "$SCRIPT_DIR/lib" "$INSTALL_DIR/lib"
cp -R "$SCRIPT_DIR/templates" "$INSTALL_DIR/templates"
ln -sfn "$INSTALL_DIR/harness.sh" "$COMMAND_PATH"

printf '설치 완료: %s\n' "$COMMAND_PATH"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    printf '\n다음 한 줄을 ~/.bashrc에 추가하세요.\n'
    printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    ;;
esac

printf '\n'
if register_bash_completion "$BASHRC"; then
  printf '탭 완성(Bash) 로더를 %s에 등록했습니다.\n' "$BASHRC"
else
  printf '탭 완성(Bash) 로더가 이미 %s에 있습니다.\n' "$BASHRC"
fi
printf '이 설치기는 자식 프로세스라 지금 실행 중인 셸에는 바로 반영되지 않습니다.\n'
printf '새 터미널을 열거나 다음을 실행하세요.\n'
printf '  source ~/.bashrc\n'

if [[ "$WITH_HERDR_SKILL" -eq 1 ]]; then
  if command -v npx >/dev/null 2>&1; then
    npx --yes skills add herdrdev/herdr --skill herdr -g || {
      printf '경고: Harness는 설치됐지만 Herdr Skill 설치는 실패했습니다.\n' >&2
    }
  else
    printf '경고: npx가 없어 Herdr Skill 설치를 건너뜁니다.\n' >&2
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '\n선택 의존성 jq가 없습니다 — codex 모델 조회(models --refresh)가 안 됩니다.\n'
  printf '설치는 사용자가 직접 합니다(이 설치기는 sudo·패키지 관리자를 호출하지 않습니다).\n'
  printf '  sudo apt install -y jq   # Debian/Ubuntu\n'
  printf '  sudo dnf install -y jq   # Fedora\n'
  printf '  brew install jq          # macOS\n'
fi

printf '\n확인:\n'
printf '  herdr-harness doctor\n'
printf '  herdr-harness test\n'

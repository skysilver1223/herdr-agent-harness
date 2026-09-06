#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/harness.sh"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-harness"
BIN_DIR="$HOME/.local/bin"
COMMAND_PATH="$BIN_DIR/herdr-harness"

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
  rm -rf "$INSTALL_DIR/templates"
  rmdir "$INSTALL_DIR" 2>/dev/null || true
  printf '제거 완료: %s\n' "$COMMAND_PATH"
  exit 0
fi

[[ -f "$SOURCE" ]] || {
  printf '오류: install.sh와 harness.sh는 같은 디렉터리에 있어야 합니다.\n' >&2
  exit 1
}
[[ -d "$SCRIPT_DIR/templates" ]] || {
  printf '오류: templates/ 디렉터리가 없습니다. 저장소를 온전히 clone했는지 확인하세요.\n' >&2
  exit 1
}

bash -n "$SOURCE"
mkdir -p "$INSTALL_DIR" "$BIN_DIR"
install -m 0755 "$SOURCE" "$INSTALL_DIR/harness.sh"
rm -rf "$INSTALL_DIR/templates"
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

printf '\n탭 완성(Bash)을 쓰려면 다음 한 줄을 ~/.bashrc에 추가하세요.\n'
printf 'source <(herdr-harness completion bash)\n'

if [[ "$WITH_HERDR_SKILL" -eq 1 ]]; then
  if command -v npx >/dev/null 2>&1; then
    npx --yes skills add herdrdev/herdr --skill herdr -g || {
      printf '경고: Harness는 설치됐지만 Herdr Skill 설치는 실패했습니다.\n' >&2
    }
  else
    printf '경고: npx가 없어 Herdr Skill 설치를 건너뜁니다.\n' >&2
  fi
fi

printf '\n확인:\n'
printf '  herdr-harness doctor\n'
printf '  herdr-harness test\n'

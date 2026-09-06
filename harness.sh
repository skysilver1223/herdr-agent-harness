#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# 이 파일은 얇은 런처다. 실제 로직은 옆 lib/*.sh 에 기능 단위로 나뉘어 있고,
# 프로젝트 템플릿 정본은 옆 templates/ 에 있다(emit_doc이 @@…@@만 치환해 복사).
# 심볼릭 링크(~/.local/bin/herdr-harness → $INSTALL_DIR/harness.sh)로 실행될 때도
# 실제 위치를 찾아야 하므로 readlink -f로 해석한다. 둘 다 환경변수로 override 가능.
_harness_real_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "$SELF_PATH")"
_harness_root="$(dirname "$_harness_real_path")"
HARNESS_LIB_DIR="${HARNESS_LIB_DIR:-$_harness_root/lib}"
HARNESS_TEMPLATE_DIR="${HARNESS_TEMPLATE_DIR:-$_harness_root/templates}"

[[ -d "$HARNESS_LIB_DIR" ]] ||
  { printf '오류: lib/ 디렉터리가 없습니다: %s  (저장소를 온전히 clone했는지, install.sh를 다시 실행했는지 확인하세요)\n' "$HARNESS_LIB_DIR" >&2; exit 1; }

# 파일명 숫자 접두사(10-, 20-, …) 순서대로 source한다. 각 lib은 함수 정의만
# 하고 실행하지 않으므로 순서는 "정의가 갖춰진 뒤 main 호출"만 지키면 된다.
for _harness_lib in "$HARNESS_LIB_DIR"/*.sh; do
  # shellcheck source=/dev/null
  source "$_harness_lib"
done
unset _harness_lib

main "$@"

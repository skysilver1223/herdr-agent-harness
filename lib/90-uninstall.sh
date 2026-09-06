# Part of herdr-harness. Sourced by harness.sh — do not run directly.


cmd_uninstall() {
  local assume_yes=0 answer=""
  local install_dir="${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-harness"
  local installed_file="$install_dir/harness.sh"
  local command_path="$HOME/.local/bin/herdr-harness"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) assume_yes=1 ;;
      -h|--help)
        cat <<'EOF'
사용법:
  herdr-harness uninstall
  herdr-harness uninstall --yes

제거 대상:
  ~/.local/bin/herdr-harness
  ~/.local/share/herdr-agent-harness/harness.sh
  ~/.local/share/herdr-agent-harness/lib/
  ~/.local/share/herdr-agent-harness/templates/

생성한 프로젝트, Herdr 본체, Integration과 전역 Herdr Skill은 제거하지 않습니다.
EOF
        return 0
        ;;
      *) die "알 수 없는 uninstall 옵션: $1" ;;
    esac
    shift
  done

  if [[ ! -e "$installed_file" && ! -L "$command_path" ]]; then
    info "설치된 Harness를 찾지 못했습니다."
    return 0
  fi

  if [[ "$assume_yes" -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
      die "비대화형 실행에서는 uninstall --yes를 사용하세요."
    fi
    printf '설치된 herdr-harness 명령을 제거할까요? [y/N] '
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) info "제거를 취소했습니다."; return 0 ;; esac
  fi

  if [[ -L "$command_path" ]]; then
    if [[ "$(readlink "$command_path")" == "$installed_file" ]]; then
      unlink "$command_path"
    else
      die "예상하지 않은 Symbolic Link라 제거하지 않습니다: $command_path"
    fi
  elif [[ -e "$command_path" ]]; then
    die "일반 파일이 존재해 제거하지 않습니다: $command_path"
  fi

  if [[ -f "$installed_file" ]]; then
    unlink "$installed_file"
  fi
  rm -rf "$install_dir/lib" "$install_dir/templates"
  rmdir "$install_dir" 2>/dev/null || true

  printf 'Harness 제거 완료.\n'
  printf '생성한 프로젝트와 Herdr 설정은 유지됩니다.\n'
}

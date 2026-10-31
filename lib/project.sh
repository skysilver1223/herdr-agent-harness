# herdr-harness: 프로젝트 생성과 업그레이드 — 템플릿(templates/project)을 복사하고 @@…@@만 치환한다.
# 스크립트는 프로젝트의 .harness/bin/에 통째로 복사되므로 설치 없이 어디서든 동작한다.
# 전역 명령 설치(install)도 여기 있다. 설치본은 저장소의 사본이며, 설치본으로 만든·올린 프로젝트는
# 설치본을 harness_source로 기록한다(저장소를 고친 뒤 install을 다시 해야 프로젝트에 닿는다).
# harness.sh가 source한다. 단독 실행하지 않는다.

profile_focus() {
  case "$1" in
    generic) echo "정확성, 회귀 위험, 보안, 유지보수성" ;;
    python-timeseries) echo "기존 Notebook·코드·데이터·실험 결과를 먼저 확인. 시간 순서 split, 데이터 누수, baseline, backtesting, 재현성, 불확실성" ;;
    network-device) echo "사용자 Dump·MIB·벤더 문서·기존 receiver 설정을 먼저 확인. canonical schema와 vendor adapter 분리, OID 출처, counter reset, 단위, timestamp, unknown OID, 실제 Dump 회귀 테스트" ;;
    *) return 1 ;;
  esac
}

render_file() {  # FILE — R_* 값으로 @@…@@를 치환한다 (치환 문자열은 인용해 &·\ 를 그대로 둔다)
  local content
  content="$(cat "$1"; printf x)"; content="${content%x}"
  content="${content//@@NAME@@/"$R_NAME"}"
  content="${content//@@NAME_YAML@@/"$(yaml_q "$R_NAME")"}"
  content="${content//@@GOAL@@/"$R_GOAL"}"
  content="${content//@@GOAL_YAML@@/"$(yaml_q "$R_GOAL")"}"
  content="${content//@@PROFILE@@/"$R_PROFILE"}"
  content="${content//@@PROFILE_FOCUS@@/"$(profile_focus "$R_PROFILE")"}"
  content="${content//@@ORCHESTRATOR@@/"$R_ORCH"}"
  content="${content//@@WORKER@@/"$R_WORKER"}"
  content="${content//@@REVIEWER@@/"$R_REVIEWER"}"
  content="${content//@@FALLBACK@@/"${R_FALLBACK//,/, }"}"
  content="${content//@@APPROVAL_MODE@@/"$R_MODE"}"
  content="${content//@@SOURCE_YAML@@/"$(yaml_q "$HARNESS_HOME")"}"
  content="${content//@@CODE_DIR_YAML@@/"$(yaml_q "$R_CODE")"}"
  content="${content//@@REVIEW_LEVEL@@/"${R_LEVEL:-cross_provider}"}"
  printf '%s' "$content" >"$1"
}

link_skills() {  # ROOT — .claude/skills/<skill> → ../../.agents/skills/<skill>
  local d
  mkdir -p "$1/.claude/skills"
  for d in "$1"/.agents/skills/*/; do
    d="$(basename "$d")"
    [[ -e "$1/.claude/skills/$d" || -L "$1/.claude/skills/$d" ]] || ln -s "../../.agents/skills/$d" "$1/.claude/skills/$d"
  done
}

install_bin() {  # ROOT — 실행 파일 일체를 .harness/bin/으로 (예전 lib는 지워 남은 파일이 섞이지 않게)
  rm -rf -- "$1/.harness/bin"
  mkdir -p "$1/.harness/bin/lib"
  install -m 0755 "$HARNESS_HOME/harness.sh" "$1/.harness/bin/harness.sh"
  install -m 0644 "$HARNESS_HOME"/lib/*.sh "$1/.harness/bin/lib/"
}

cmd_init() {
  local target="${1:-}" p f
  R_NAME="" R_GOAL="" R_PROFILE=generic R_ORCH=claude R_WORKER=codex R_REVIEWER=agy R_FALLBACK=claude R_MODE=auto R_CODE=. R_LEVEL=cross_provider
  [[ -n "$target" && "$target" != -* ]] || die "사용법: init DIR --goal TEXT [옵션] (help 참고)"
  shift
  while (( $# )); do
    [[ $# -ge 2 ]] || die "$1 값이 필요합니다."
    case "$1" in
      --name) R_NAME="$2" ;; --goal) R_GOAL="$2" ;; --profile) R_PROFILE="$2" ;;
      --orchestrator) R_ORCH="$2" ;; --worker) R_WORKER="$2" ;; --reviewer) R_REVIEWER="$2" ;;
      --fallback) R_FALLBACK="$2" ;; --approval-mode) R_MODE="$2" ;; --code-dir) R_CODE="$2" ;;
      --review-level) R_LEVEL="$2" ;;
      *) die "알 수 없는 init 옵션: $1" ;;
    esac
    shift 2
  done
  [[ -d "$TEMPLATE_DIR/.harness" ]] || die "템플릿이 없습니다: $TEMPLATE_DIR (init은 저장소의 harness.sh로 실행한다)"
  target="$(realpath -m "$target")"
  [[ "$target" != / && "$target" != "$HOME" ]] || die "너무 넓은 경로입니다: $target"
  [[ ! -e "$target" || -z "$(ls -A "$target" 2>/dev/null)" ]] || die "새 프로젝트 전용입니다. 비어 있지 않은 경로: $target"
  [[ -n "$R_NAME" ]] || R_NAME="$(basename "$target")"
  if [[ -z "$R_GOAL" ]]; then
    [[ -t 0 ]] || die "--goal이 필요합니다 (비대화형 실행)."
    read -r -e -p "프로젝트 목표: " R_GOAL
  fi
  [[ "$R_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "프로젝트명은 영문·숫자·. _ -만 쓴다: $R_NAME"
  [[ -n "$R_GOAL" && "$R_GOAL" != *$'\n'* ]] || die "목표는 한 줄이어야 합니다."
  [[ "$R_CODE" != *$'\n'* ]] || die "--code-dir에 개행을 넣을 수 없습니다."
  profile_focus "$R_PROFILE" >/dev/null || die "지원하지 않는 profile: $R_PROFILE"
  for p in "$R_ORCH" "$R_WORKER" "$R_REVIEWER" ${R_FALLBACK//,/ }; do is_provider "$p" || die "지원하지 않는 Provider: $p"; done
  valid_level "$R_LEVEL" || die "--review-level은 cross_provider | cross_model | same_model"
  [[ "$R_WORKER" != "$R_REVIEWER" || "$R_LEVEL" != cross_provider ]] ||
    die "Worker와 Reviewer가 같은 Provider입니다. 다른 회사 검토가 기본이며, 한 회사만 쓰는 환경이면 --review-level cross_model(다른 모델) 또는 same_model을 지정한다."
  case "$R_MODE" in ask|auto|bypass) ;; *) die "--approval-mode는 ask | auto | bypass" ;; esac

  mkdir -p "$target"
  cp -R "$TEMPLATE_DIR/." "$target/"
  while IFS= read -r -d '' f; do render_file "$f"; done < <(grep -rlZ '@@' "$target" || true)
  link_skills "$target"
  install_bin "$target"
  if [[ "$R_LEVEL" != cross_provider ]]; then
    ROOT="$target"
    record_level "" "$R_LEVEL" cross_provider "init 때 사용자가 지정 (--review-level $R_LEVEL, Worker $R_WORKER / Reviewer $R_REVIEWER)" "사용자 (init)"
  fi

  if command -v git >/dev/null 2>&1; then
    git -C "$target" init -q
    git -C "$target" add -A
    if git -C "$target" commit -q -m "chore: harness 기준선" 2>/dev/null; then info "Git 기준 commit을 만들었습니다."
    else warn "기준 commit을 만들지 못했습니다(git user.name/email 확인): git -C '$target' commit -m 'chore: harness 기준선'"; fi
  fi
  info "생성 완료: $target"
  info "다음: cd '$target' && .harness/bin/harness.sh start   (Herdr 첫 Pane에서 $R_ORCH 실행 → AGENTS.md의 '시작' 프롬프트)"
}

ver_before() { [[ -n "$1" && "$1" != "$2" && "$(printf '%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]]; }  # A가 B보다 앞 버전인가

upgrade_one() {  # DIR — 저장소(또는 설치본)의 harness.sh로 실행된다
  local d old dirty src_old
  ROOT="$(realpath -m "$1")"
  [[ -f "$ROOT/.harness/project.yaml" ]] || die "Harness 프로젝트가 아닙니다: $ROOT"
  [[ "$(yget "$ROOT/.harness/project.yaml" schema_version)" == 2 ]] ||
    die "schema 2 프로젝트만 업그레이드한다 (이전 버전 프로젝트는 기존 설치본으로 계속 운영): $ROOT"
  dirty="$(git -C "$ROOT" status --porcelain -- .agents/skills .harness/bin 2>/dev/null || true)"
  [[ -z "$dirty" ]] || die "커밋되지 않은 변경이 있어 덮어쓰지 않습니다 (먼저 commit하거나 저장소에 반영):\n$dirty"
  old="$(sed -n 's/^HARNESS_VERSION="\(.*\)"/\1/p' "$ROOT/.harness/bin/lib/core.sh" 2>/dev/null || true)"
  # 버전을 내리지 않는다. 저장소로 올린 프로젝트에 다시 설치하지 않은 옛 설치본으로 upgrade하면 조용히 내려간다.
  if ver_before "$HARNESS_VERSION" "$old"; then
    die "$ROOT는 이미 $old입니다. 이 harness는 $HARNESS_VERSION($HARNESS_HOME)이라 내리지 않습니다 — 새 버전으로 install을 다시 하거나 새 버전의 harness.sh로 upgrade한다."
  fi
  R_NAME="$(pget project name)" R_GOAL="$(pget project goal)" R_PROFILE="$(pget project profile generic)"
  R_ORCH="$(pget providers orchestrator)" R_WORKER="$(pget providers primary_worker)" R_REVIEWER="$(pget providers reviewer)"
  R_FALLBACK="$(pget providers fallback_chain | tr -d '[] ')" R_MODE="$(pget agents approval_mode auto)" R_CODE="$(pget workspace code_dir .)"
  R_LEVEL="$(pget review level cross_provider)"
  for d in "$TEMPLATE_DIR"/.agents/skills/*/; do
    d="$(basename "$d")"
    mkdir -p "$ROOT/.agents/skills/$d"
    cp "$TEMPLATE_DIR/.agents/skills/$d/SKILL.md" "$ROOT/.agents/skills/$d/SKILL.md"
    render_file "$ROOT/.agents/skills/$d/SKILL.md"
  done
  link_skills "$ROOT"
  install_bin "$ROOT"
  src_old="$(yget "$ROOT/.harness/project.yaml" harness_source)"
  [[ "$src_old" == "$HARNESS_HOME" ]] || set_field "$ROOT/.harness/project.yaml" harness_source "$(yaml_q "$HARNESS_HOME")"
  info "$ROOT: ${old:-?} → $HARNESS_VERSION"
  [[ "$src_old" == "$HARNESS_HOME" ]] || info "harness_source: ${src_old:-(없음)} → $HARNESS_HOME (프로젝트 안의 upgrade가 이곳을 기준으로 한다)"
  # 2.2.1에서 claude의 auto 기본 인수가 바뀌었다. 기본값을 쓰던 프로젝트에는 한 번 알린다.
  if ver_before "$old" 2.2.1 && [[ "$R_MODE" == auto && -z "$(pget agents claude_auto)" ]] && providers | grep -qx claude; then
    info "claude의 auto 모드 기본 인수가 --permission-mode acceptEdits → --permission-mode auto(Claude Code auto 모드)로 바뀌었습니다. 조직 정책 등으로 auto 모드를 못 쓰면 agents.claude_auto를 지정한다 (doctor로 확인)."
  fi
  # 2.3.0부터 원격 마운트에 sshfs 옵션을 더할 수 있다. 원격 모드 프로젝트에 한 번 알린다.
  if ver_before "$old" 2.3.0 && remote_enabled; then
    info "원격 마운트에 sshfs 옵션을 더할 수 있습니다: .harness/remote.yaml의 mount_options (예: 'follow_symlinks' — 원격의 절대경로 심볼릭 링크를 따라간다). 바꾼 뒤 remote unmount → remote mount."
  fi
  git -C "$ROOT" status --short -- .agents .claude .harness/bin .harness/project.yaml 2>/dev/null || true
  info "변경을 확인(git diff)한 뒤 commit한다. AGENTS.md·템플릿은 프로젝트 고유 내용이 있을 수 있어 바꾸지 않는다."
}

cmd_upgrade() {  # [DIR...] — 프로젝트 사본에서 부르면 harness_source의 harness.sh로 넘긴다. DIR이 없으면 지금 위치의 프로젝트
  local d src top
  if [[ ! -d "$TEMPLATE_DIR/.agents/skills" ]]; then
    ROOT="$(resolve_root "")"
    for d in "$@"; do   # 프로젝트 사본은 자기 프로젝트만 올린다 (-C DIR도 여기로 들어온다)
      [[ "$d" -ef "$ROOT" ]] ||
        die "이 프로젝트 사본($ROOT)은 자기 프로젝트만 올립니다: $d — 그 프로젝트의 .harness/bin/harness.sh upgrade 또는 저장소의 harness.sh upgrade DIR"
    done
    src="$(yget "$ROOT/.harness/project.yaml" harness_source)"
    [[ -f "$src/harness.sh" && -d "$src/templates/project" ]] ||
      die "harness_source 저장소를 찾지 못했습니다: ${src:-(없음)} — project.yaml의 harness_source를 저장소 경로로 고친다."
    # 저장소 최상위일 때만 pull한다. 설치본(install)은 저장소가 아니며, 다른 저장소 안의 폴더면 그 저장소가 바뀐다.
    top="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "${HARNESS_NO_PULL:-}" && -n "$top" && "$top" -ef "$src" ]]; then
      info "저장소 최신화: git -C $src pull --ff-only"
      git -C "$src" pull --ff-only -q 2>/dev/null || warn "저장소 pull 실패 — 현재 저장소 내용으로 업그레이드합니다."
    fi
    exec bash "$src/harness.sh" upgrade "$ROOT"
  fi
  if (( $# == 0 )); then
    d="$(resolve_root "" 2>/dev/null)" || die "사용법: upgrade DIR... (프로젝트 안에서는 DIR 없이)"
    set -- "$d"
  fi
  for d in "$@"; do upgrade_one "$d"; done
}

# 설치본 폴더의 정체: none(없음·빈 폴더) | v2(install이 만든 설치본, 표식 INSTALLED) | v1(번호 붙은 lib의 옛 설치본) | other
# 저장소 clone(.git)이나 읽을 수 없는 폴더는 other다. 지우면 안 되는 것을 설치본으로 오인하지 않는다.
install_kind() {
  local items
  if [[ ! -e "$1" && ! -L "$1" ]]; then echo none; return 0; fi
  if [[ -L "$1" || ! -d "$1" || ! -r "$1" || ! -x "$1" || -e "$1/.git" ]]; then echo other; return 0; fi
  if [[ -f "$1/INSTALLED" && -f "$1/bin/herdr-harness" ]]; then echo v2
  elif [[ -f "$1/harness.sh" ]] && compgen -G "$1/lib/[0-9][0-9]-*.sh" >/dev/null; then echo v1
  else
    items="$(ls -A -- "$1" 2>/dev/null || true)"
    if [[ -z "$items" ]]; then echo none; else echo other; fi
  fi
}

install_copy() {  # DIR COMMIT — 설치본에 들어갈 파일과 표식. 조건문 안에서 불리므로 단계마다 실패를 넘긴다
  mkdir -p "$1/lib" "$1/bin" "$1/templates" &&
    install -m 0755 "$HARNESS_HOME/harness.sh" "$1/harness.sh" &&
    install -m 0644 "$HARNESS_HOME"/lib/*.sh "$1/lib/" &&
    install -m 0755 "$HARNESS_HOME/bin/herdr-harness" "$1/bin/herdr-harness" &&
    install -m 0644 "$HARNESS_HOME/bin/completion.bash" "$1/bin/completion.bash" &&
    cp -R -- "$HARNESS_HOME/templates/." "$1/templates/" &&
    printf 'harness.sh install이 만든 설치본 (다시 install하면 통째로 바뀐다)\nversion: %s\nsource: %s\ncommit: %s\ninstalled: %s\ninstall-id: %s\n' \
      "$HARNESS_VERSION" "$HARNESS_HOME" "${2:-}" "$(now)" "$INSTALL_ID" >"$1/INSTALLED"
}

INSTALL_DONE=0 INSTALL_ID="" INSTALL_SHARE="" INSTALL_LINK="" INSTALL_STAGE="" INSTALL_OLD="" INSTALL_LINK_TMP=""

# 설치 도중에 끝나면(실패·중단) 파일 상태를 보고 정리한다. 깃발 대신 파일로 판단하는 이유: mv가 rename을 마친
# 직후에 끊기면 깃발은 아직 서지 않았다.
#   이번 install-id의 새 사본이 제자리에 있고, 임시 링크가 옮겨져 링크가 새 사본을 가리킴 → 설치는 끝났다(옛 사본만 지운다)
#   그 밖 → 새 사본을 치우고 옛 사본·링크를 되돌린다
install_on_exit() {
  local rc="$1" failed placed=0
  set +e; trap - ERR; trap '' INT TERM HUP   # 정리는 끝까지 한다
  rm -f -- ${TMP_FILES[@]+"${TMP_FILES[@]}"}
  (( INSTALL_DONE == 0 )) || return 0
  grep -qxF "install-id: $INSTALL_ID" "$INSTALL_SHARE/INSTALLED" 2>/dev/null && placed=1
  if (( placed )) && [[ -n "$INSTALL_LINK_TMP" && ! -L "$INSTALL_LINK_TMP" && "$(readlink "$INSTALL_LINK")" == "$INSTALL_SHARE/bin/herdr-harness" ]]; then
    [[ -z "$INSTALL_OLD" ]] || rm -rf -- "$INSTALL_OLD" 2>/dev/null
    if [[ -n "$INSTALL_OLD" && -e "$INSTALL_OLD" ]]; then
      printf '[harness] 설치는 끝났습니다(링크까지 바뀜, exit %s). 옛 설치본은 직접 지운다: %s\n' "$rc" "$INSTALL_OLD" >&2
    else
      printf '[harness] 설치는 끝났습니다(링크까지 바뀜, exit %s).\n' "$rc" >&2
    fi
    return 0
  fi
  [[ -z "$INSTALL_LINK_TMP" ]] || rm -f -- "$INSTALL_LINK_TMP"
  if (( placed )); then
    failed="$(mktemp -u "${INSTALL_SHARE%/*}/.herdr-harness-failed.XXXXXX")"
    mv -T -- "$INSTALL_SHARE" "$failed" && rm -rf -- "$failed"
  fi
  [[ -z "$INSTALL_OLD" || -e "$INSTALL_SHARE" || ! -e "$INSTALL_OLD" ]] || mv -T -- "$INSTALL_OLD" "$INSTALL_SHARE"
  [[ -z "$INSTALL_STAGE" ]] || rm -rf -- "$INSTALL_STAGE"
  if [[ -n "$INSTALL_OLD" && -e "$INSTALL_OLD" ]]; then
    printf '[harness] 설치가 끝나지 않았고 옛 설치본을 되돌리지 못했습니다 (exit %s). 옛 설치본: %s, 설치 자리: %s — 직접 확인한다.\n' "$rc" "$INSTALL_OLD" "$INSTALL_SHARE" >&2
  else
    printf '[harness] 설치가 끝나지 않아 원래대로 되돌렸습니다 (exit %s).\n' "$rc" >&2
  fi
}

# 전역 명령: 이 저장소의 사본을 설치본(${XDG_DATA_HOME:-~/.local/share}/herdr-agent-harness, v1과 같은 자리)에 두고
# ~/.local/bin/herdr-harness를 잇는다. 사본을 쓰는 이유: 저장소의 브랜치나 작업 중인 수정이 곧바로 모든 프로젝트의
# 명령에 섞이지 않게 한다. 새 사본을 옆에 만들고 링크까지 바꾼 뒤에야 옛 사본을 지운다. 그 전에 실패하거나 끊기면
# install_on_exit가 원래 설치본과 링크로 되돌린다(링크까지 바뀐 뒤라면 끝난 것으로 본다). ~/.bashrc는 건드리지 않는다.
cmd_install() {  # [--replace-v1]
  local replace=0 share="$HOME/.local/share/herdr-agent-harness" bindir="$HOME/.local/bin" link kind cur commit dirty
  link="$bindir/herdr-harness"
  [[ "${XDG_DATA_HOME:-}" != /* ]] || share="$XDG_DATA_HOME/herdr-agent-harness"   # XDG 명세: 상대 경로는 무시한다
  while (( $# )); do
    case "$1" in --replace-v1) replace=1 ;; *) die "사용법: install [--replace-v1]" ;; esac
    shift
  done
  [[ -f "$HARNESS_HOME/bin/herdr-harness" && -f "$HARNESS_HOME/bin/completion.bash" && -d "$HARNESS_HOME/templates/project/.harness" ]] ||
    die "install은 저장소의 harness.sh로 실행한다 (예: ~/herdr-agent-harness/harness.sh install)."
  [[ "$(realpath -m "$share")" != "$HARNESS_HOME" ]] ||
    die "설치본으로는 다시 설치하지 않습니다. 저장소의 harness.sh로 실행한다 (예: ~/herdr-agent-harness/harness.sh install)."
  kind="$(install_kind "$share")"
  case "$kind" in
    none|v2) ;;
    v1) (( replace )) || die "$share에 v1 설치본이 있습니다. v1 명령으로 운영하는 프로젝트가 없는지 확인한 뒤(v1 프로젝트는 migrate로 옮긴다) --replace-v1을 붙인다. v1 설치본에 직접 고친 내용은 사라진다." ;;
    *) die "$share에 Harness 설치본이 아닌 것이 있어 덮어쓰지 않습니다. 직접 확인해 옮긴 뒤 다시 실행한다." ;;
  esac
  if [[ -L "$link" ]]; then
    cur="$(readlink -m "$link")"
    [[ "$cur" == "$(realpath -m "$share")"/* ]] || die "$link가 다른 곳을 가리킵니다: $cur — 직접 확인해 지운 뒤 다시 실행한다."
  elif [[ -e "$link" ]]; then
    die "$link가 이미 있습니다(링크가 아닌 파일). 직접 확인해 지운 뒤 다시 실행한다."
  fi

  mkdir -p "${share%/*}" "$bindir"
  [[ -w "${share%/*}" && -w "$bindir" ]] || die "쓸 수 없는 폴더가 있어 설치하지 않습니다: ${share%/*} 또는 $bindir"
  commit="$(git -C "$HARNESS_HOME" rev-parse --short HEAD 2>/dev/null || true)"
  dirty="$(git -C "$HARNESS_HOME" status --porcelain -- harness.sh lib bin templates 2>/dev/null || true)"

  # 여기부터는 끝나기 전에 멈추면 install_on_exit가 정리한다. 신호로 끊겨도 그 종료 코드(128+n)가 남게 한다.
  INSTALL_SHARE="$share" INSTALL_LINK="$link" INSTALL_ID="$$-$(date +%s%N)-$RANDOM"
  trap 'install_on_exit "$?"' EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
  INSTALL_STAGE="$(mktemp -d "${share%/*}/.herdr-harness-install.XXXXXX")"
  install_copy "$INSTALL_STAGE" "$commit" || die "설치본을 만들지 못했습니다."
  INSTALL_LINK_TMP="$(mktemp -u "$bindir/.herdr-harness.XXXXXX")"
  ln -s -- "$share/bin/herdr-harness" "$INSTALL_LINK_TMP" || die "링크를 만들지 못했습니다: $bindir"
  if [[ -e "$share" ]]; then
    INSTALL_OLD="$(mktemp -u "${share%/*}/.herdr-harness-old.XXXXXX")"
    mv -T -- "$share" "$INSTALL_OLD" || die "기존 설치본을 옮기지 못했습니다: $share"
  fi
  mv -T -- "$INSTALL_STAGE" "$share" || die "설치본을 제자리에 두지 못했습니다: $share"
  mv -T -- "$INSTALL_LINK_TMP" "$link" || die "링크를 바꾸지 못했습니다: $link"
  INSTALL_DONE=1
  trap - INT TERM HUP
  trap 'rm -f -- ${TMP_FILES[@]+"${TMP_FILES[@]}"}' EXIT
  if [[ -n "$INSTALL_OLD" ]] && ! rm -rf -- "$INSTALL_OLD" 2>/dev/null; then
    warn "옛 설치본을 다 지우지 못했습니다(권한): $INSTALL_OLD — 직접 지운다. 새 설치본은 제자리에 있습니다."
  fi

  info "설치 완료: $HARNESS_VERSION (${commit:-commit 없음}) → $share"
  info "명령: $link → $share/bin/herdr-harness"
  [[ -z "$dirty" ]] || warn "commit하지 않은 수정이 있는 상태로 설치했습니다. 그 수정도 설치본에 들어갔습니다."
  [[ "$kind" != v1 ]] || info "v1 설치본을 바꿨습니다. v1 명령으로 만든 프로젝트는 herdr-harness migrate로 옮긴다."
  case ":$PATH:" in
    *":$bindir:"*) ;;
    *) warn "PATH에 $bindir가 없습니다. ~/.bashrc 등에 추가한다: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
  if grep -qs 'herdr-harness completion bash' "$HOME/.bashrc"; then info "자동완성: ~/.bashrc의 기존 줄이 새 셸부터 이 버전을 불러옵니다."
  else info "자동완성을 쓰려면 ~/.bashrc에 한 줄 추가: source <(herdr-harness completion bash)"; fi
  info "저장소를 고친 뒤에는 install을 다시 실행하고, 프로젝트는 herdr-harness upgrade로 올린다."
}

# Herdr 밖이면 이 프로젝트 이름의 세션을 연다. 이미 Herdr 안이면 중첩 실행이 막혀 있으므로
# 지금 세션에 프로젝트 workspace를 만든다(같은 이름이 있으면 그쪽으로 이동).
cmd_start() {
  local name ws list
  command -v herdr >/dev/null 2>&1 || die "herdr 명령이 없습니다."
  name="$(pget project name)"
  cd "$ROOT"
  if [[ "${HERDR_ENV:-}" != 1 ]]; then
    printf '첫 Pane에서 %s를 실행하고 AGENTS.md의 "시작" 프롬프트를 입력한다.\n' "$(pget providers orchestrator)"
    exec herdr --session "$name"
  fi
  list="$(herdr workspace list 2>/dev/null || true)"
  if command -v jq >/dev/null 2>&1; then
    ws="$(jq -r --arg n "$name" '.result.workspaces[]? | select(.label == $n) | .workspace_id' <<<"$list" 2>/dev/null | head -n 1 || true)"
  else
    ws="$(tr -d '\n' <<<"$list" | grep -o "\"label\":\"$name\"[^}]*\"workspace_id\":\"[^\"]*\"" | head -n 1 | sed 's/.*"workspace_id":"//; s/"$//' || true)"
  fi
  if [[ -n "$ws" ]]; then
    herdr workspace focus "$ws" >/dev/null || die "workspace $ws로 이동하지 못했습니다."
    info "이미 열린 workspace '$name'($ws)로 이동했습니다."
  else
    hcap herdr workspace create --cwd "$ROOT" --label "$name" --focus
    (( RC == 0 )) || die "workspace를 만들지 못했습니다: $OUT"
    info "현재 Herdr 세션에 workspace '$name'을 만들었습니다 (작업 디렉터리: $ROOT)."
  fi
  printf '그 workspace의 Pane에서 %s를 실행하고 AGENTS.md의 "시작" 프롬프트를 입력한다.\n' "$(pget providers orchestrator)"
}

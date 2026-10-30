# herdr-harness: 프로젝트 생성과 업그레이드 — 템플릿(templates/project)을 복사하고 @@…@@만 치환한다.
# 스크립트는 프로젝트의 .harness/bin/에 통째로 복사되므로 설치 없이 어디서든 동작한다.
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
  R_NAME="" R_GOAL="" R_PROFILE=generic R_ORCH=claude R_WORKER=codex R_REVIEWER=agy R_FALLBACK=claude R_MODE=auto R_CODE=.
  [[ -n "$target" && "$target" != -* ]] || die "사용법: init DIR --goal TEXT [옵션] (help 참고)"
  shift
  while (( $# )); do
    [[ $# -ge 2 ]] || die "$1 값이 필요합니다."
    case "$1" in
      --name) R_NAME="$2" ;; --goal) R_GOAL="$2" ;; --profile) R_PROFILE="$2" ;;
      --orchestrator) R_ORCH="$2" ;; --worker) R_WORKER="$2" ;; --reviewer) R_REVIEWER="$2" ;;
      --fallback) R_FALLBACK="$2" ;; --approval-mode) R_MODE="$2" ;; --code-dir) R_CODE="$2" ;;
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
  [[ "$R_WORKER" != "$R_REVIEWER" ]] || die "Worker와 Reviewer는 다른 Provider여야 합니다 (교차 검토)."
  case "$R_MODE" in ask|auto|bypass) ;; *) die "--approval-mode는 ask | auto | bypass" ;; esac

  mkdir -p "$target"
  cp -R "$TEMPLATE_DIR/." "$target/"
  while IFS= read -r -d '' f; do render_file "$f"; done < <(grep -rlZ '@@' "$target")
  link_skills "$target"
  install_bin "$target"

  if command -v git >/dev/null 2>&1; then
    git -C "$target" init -q
    git -C "$target" add -A
    if git -C "$target" commit -q -m "chore: harness 기준선" 2>/dev/null; then info "Git 기준 commit을 만들었습니다."
    else warn "기준 commit을 만들지 못했습니다(git user.name/email 확인): git -C '$target' commit -m 'chore: harness 기준선'"; fi
  fi
  info "생성 완료: $target"
  info "다음: cd '$target' && .harness/bin/harness.sh start   (Herdr 첫 Pane에서 $R_ORCH 실행 → AGENTS.md의 '시작' 프롬프트)"
}

upgrade_one() {  # DIR — 저장소의 harness.sh로 실행된다
  local d old dirty
  ROOT="$(realpath -m "$1")"
  [[ -f "$ROOT/.harness/project.yaml" ]] || die "Harness 프로젝트가 아닙니다: $ROOT"
  [[ "$(yget "$ROOT/.harness/project.yaml" schema_version)" == 2 ]] ||
    die "schema 2 프로젝트만 업그레이드한다 (이전 버전 프로젝트는 기존 설치본으로 계속 운영): $ROOT"
  dirty="$(git -C "$ROOT" status --porcelain -- .agents/skills .harness/bin 2>/dev/null || true)"
  [[ -z "$dirty" ]] || die "커밋되지 않은 변경이 있어 덮어쓰지 않습니다 (먼저 commit하거나 저장소에 반영):\n$dirty"
  old="$(sed -n 's/^HARNESS_VERSION="\(.*\)"/\1/p' "$ROOT/.harness/bin/lib/core.sh" 2>/dev/null || true)"
  R_NAME="$(pget project name)" R_GOAL="$(pget project goal)" R_PROFILE="$(pget project profile generic)"
  R_ORCH="$(pget providers orchestrator)" R_WORKER="$(pget providers primary_worker)" R_REVIEWER="$(pget providers reviewer)"
  R_FALLBACK="$(pget providers fallback_chain | tr -d '[] ')" R_MODE="$(pget agents approval_mode auto)" R_CODE="$(pget workspace code_dir .)"
  for d in "$TEMPLATE_DIR"/.agents/skills/*/; do
    d="$(basename "$d")"
    mkdir -p "$ROOT/.agents/skills/$d"
    cp "$TEMPLATE_DIR/.agents/skills/$d/SKILL.md" "$ROOT/.agents/skills/$d/SKILL.md"
    render_file "$ROOT/.agents/skills/$d/SKILL.md"
  done
  link_skills "$ROOT"
  install_bin "$ROOT"
  if [[ "$(yget "$ROOT/.harness/project.yaml" harness_source)" != "$HARNESS_HOME" ]]; then
    set_field "$ROOT/.harness/project.yaml" harness_source "$(yaml_q "$HARNESS_HOME")"
  fi
  info "$ROOT: ${old:-?} → $HARNESS_VERSION"
  git -C "$ROOT" status --short -- .agents .claude .harness/bin .harness/project.yaml 2>/dev/null || true
  info "변경을 확인(git diff)한 뒤 commit한다. AGENTS.md·템플릿은 프로젝트 고유 내용이 있을 수 있어 바꾸지 않는다."
}

cmd_upgrade() {  # [DIR...] — 프로젝트 사본에서 부르면 harness_source 저장소의 harness.sh로 넘긴다
  local d src
  if [[ ! -d "$TEMPLATE_DIR/.agents/skills" ]]; then
    ROOT="$(resolve_root "")"
    src="$(yget "$ROOT/.harness/project.yaml" harness_source)"
    [[ -f "$src/harness.sh" && -d "$src/templates/project" ]] ||
      die "harness_source 저장소를 찾지 못했습니다: ${src:-(없음)} — project.yaml의 harness_source를 저장소 경로로 고친다."
    if [[ -z "${HARNESS_NO_PULL:-}" ]] && git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      info "저장소 최신화: git -C $src pull --ff-only"
      git -C "$src" pull --ff-only -q 2>/dev/null || warn "저장소 pull 실패 — 현재 저장소 내용으로 업그레이드합니다."
    fi
    exec bash "$src/harness.sh" upgrade "$ROOT"
  fi
  (( $# > 0 )) || die "사용법: upgrade DIR... (저장소의 harness.sh) 또는 프로젝트에서 .harness/bin/harness.sh upgrade"
  for d in "$@"; do upgrade_one "$d"; done
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

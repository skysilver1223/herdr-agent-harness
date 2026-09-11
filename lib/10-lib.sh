# Part of herdr-harness. Sourced by harness.sh — do not run directly.

usage() {
  cat <<EOF
Herdr Agent/Skills Harness

사용법:
  $SCRIPT_NAME help | -h | --help  이 도움말 출력(인자 없이 실행해도 같다)
  $SCRIPT_NAME init PATH [옵션]   새 프로젝트 Harness 생성
  $SCRIPT_NAME sync-templates PATH [--apply]  기존 프로젝트의 skill·role·정책 템플릿을 재동기화(기본은 diff 미리보기)
  $SCRIPT_NAME start [PATH]       Herdr Session 시작
  $SCRIPT_NAME status [PATH]      현재 STATE.md 출력
  $SCRIPT_NAME status --live      문서·Herdr·Git 상태 대조 (DRIFT 표시)
  $SCRIPT_NAME doctor             설치 상태 확인
  $SCRIPT_NAME test               Agent 쿼터 없는 자체 테스트
  $SCRIPT_NAME uninstall [--yes]  설치된 Harness 명령 제거
  $SCRIPT_NAME completion bash    Bash 탭 완성 스크립트 출력(설치: source <(herdr-harness completion bash))

원격 실행 모드 (opt-in, .harness/policies/remote.yaml의 enabled: true일 때만):
  $SCRIPT_NAME remote [PATH] setup           최초 1회 대화형 설정(호스트·계정·경로 입력 → remote.yaml 생성 → 비밀번호 1회로 SSH 키 등록)
  $SCRIPT_NAME remote [PATH] doctor          SSH·원격 경로·도구·마운트 일괄 진단
  $SCRIPT_NAME remote [PATH] bootstrap-key   전용 SSH 키를 원격에 1회 등록
  $SCRIPT_NAME remote [PATH] mount|unmount   원격 소스를 SSHFS로 로컬에 노출/해제
  $SCRIPT_NAME remote [PATH] run '<명령>'    원격에서 빌드·테스트 실행
  $SCRIPT_NAME remote [PATH] vcs <인수...>   원격에서 git|svn 실행
  $SCRIPT_NAME remote [PATH] status|deps|shell

Agent Loop 스텝 명령 (호출 1회 = 1스텝, 상주 루프 없음):
  $SCRIPT_NAME validate [PATH] [--wave ID]        읽기 전용 사전 검증
  $SCRIPT_NAME transition PATH TASK_ID TO_STATE   상태 전이 강제
  $SCRIPT_NAME dispatch PATH TASK_ID ROLE         Task 역할·모델 정책으로 Agent 한 턴 실행
  $SCRIPT_NAME dispatch PATH TASK_ID ROLE --print-only  Pane을 만들지 않고 실행할 명령만 출력(폴백)
  $SCRIPT_NAME observe PATH TASK_ID [ROLE]        기존 Agent 재조회
  $SCRIPT_NAME adopt PATH TASK_ID ROLE --pane ID --agent NAME  사람이 띄운 Agent를 Harness에 등록
  $SCRIPT_NAME close-agent PATH TASK_ID [ROLE]    Harness가 만든 Pane 정리
  $SCRIPT_NAME quota-check PATH TASK_ID ROLE       실행 중인 Agent의 쿼터 확인(claude/codex는 /status, agy는 --print)
  $SCRIPT_NAME quota-check PATH --provider agy    Task 없이 agy 쿼터만 바로 확인
  $SCRIPT_NAME quota-retry PATH TASK_ID ROLE       (opt-in) 연속 저쿼터 확인 시 Provider 교체를 handover_required까지 자동 처리, 재개는 사람 승인 필요
  $SCRIPT_NAME auto-step PATH TASK_ID [--max-turns N]  (opt-in) 유한 턴 동안 dispatch 1회 + observe 반복, settled/blocked/오류에서 즉시 정지

init 옵션:
  --name NAME                     프로젝트명
  --goal TEXT                     프로젝트 목표
  --profile PROFILE               generic | python-timeseries | network-device
  --orchestrator PROVIDER         claude | codex | agy
  --worker PROVIDER               claude | codex | agy
  --reviewer PROVIDER             claude | codex | agy
  --fallback PROVIDERS            쉼표 구분 Provider 목록
  --approval-mode MODE            Agent 도구 실행 승인: ask | auto | bypass (기본 auto)
  --remote-host HOST              원격 실행 모드 활성화(SSH 호스트)
  --remote-user USER              원격 계정 (기본: 현재 사용자)
  --remote-path PATH              원격 프로젝트 경로 (--remote-host 사용 시 필수)
  --remote-mount PATH             SSHFS 마운트 경로 (기본: PROJECT/.harness/remote-mount)
  --remote-vcs VCS                git | svn | none (기본: git)

예시:
  $SCRIPT_NAME init ~/Projects/snmp-normalizer \
    --name snmp-normalizer \
    --goal "멀티벤더 SNMP 데이터를 공통 스키마로 정규화" \
    --profile network-device
EOF
}

die() {
  printf '오류: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[herdr-harness] %s\n' "$*"
}

valid_provider() {
  case "$1" in claude|codex|agy) return 0 ;; *) return 1 ;; esac
}

valid_profile() {
  case "$1" in generic|python-timeseries|network-device) return 0 ;; *) return 1 ;; esac
}

yaml_quote() {
  local value="$1"
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

write_file() {
  local root="$1"
  local relative="$2"
  local destination="$root/$relative"
  local parent temporary
  parent="$(dirname "$destination")"
  mkdir -p "$parent"
  temporary="$(mktemp "$parent/.harness-write.XXXXXX")"
  cat >"$temporary"
  chmod 0644 "$temporary"

  # sync-templates가 켜는 모드. init의 "있으면 거부" 규칙과 달리, 알려진
  # Harness 소유 템플릿 파일만 대상으로 값을 대조해 갱신한다(호출자가
  # 대상 경로를 이미 고정 목록으로 골라 놓았다는 전제). HH_SYNC_DRYRUN이면
  # 아무것도 쓰지 않고 diff만 보여준다.
  if [[ "${HH_SYNC_MODE:-0}" -eq 1 ]]; then
    if [[ -e "$destination" ]] && cmp -s "$temporary" "$destination"; then
      rm -f "$temporary"
      SYNC_UNCHANGED+=("$relative")
      return 0
    fi
    if [[ "${HH_SYNC_DRYRUN:-0}" -eq 1 ]]; then
      if [[ -e "$destination" ]]; then
        printf -- '--- %s (현재)\n+++ %s (최신 템플릿)\n' "$relative" "$relative"
        diff -u "$destination" "$temporary" | tail -n +3 || true
      else
        printf '  (신규 파일) %s\n' "$relative"
      fi
      SYNC_WOULD_CHANGE+=("$relative")
      rm -f "$temporary"
      return 0
    fi
    mv "$temporary" "$destination"
    SYNC_CHANGED+=("$relative")
    return 0
  fi

  [[ ! -e "$destination" ]] || { rm -f "$temporary"; die "기존 파일을 덮어쓰지 않습니다: $destination"; }
  mv "$temporary" "$destination"
}

prompt_required() {
  local variable="$1" label="$2" value=""
  if [[ ! -t 0 ]]; then
    die "비대화형 실행에서는 값을 물어볼 수 없습니다. 해당 값을 옵션으로 전달하세요: $label"
  fi
  while [[ -z "$value" ]]; do
    read -r -e -p "$label: " value || die "입력을 읽지 못했습니다: $label"
  done
  printf -v "$variable" '%s' "$value"
}

prompt_default() {
  local variable="$1" label="$2" default="$3" value=""
  read -r -e -p "$label [$default]: " value
  printf -v "$variable" '%s' "${value:-$default}"
}

emit_doc() {
  local root="$1" relative="$2"
  local source_file="$HARNESS_TEMPLATE_DIR/$relative"
  [[ -f "$source_file" ]] ||
    die "템플릿 파일을 찾을 수 없습니다: $source_file  (HARNESS_TEMPLATE_DIR=$HARNESS_TEMPLATE_DIR)"
  local rendered
  # write_file를 파이프(`| write_file`)로 부르면 오른쪽이 서브셸에서 돌아
  # write_file 안의 전역 배열 갱신(SYNC_* — sync-templates가 씀)이 호출자에게
  # 안 돌아온다. 여기 리다이렉션(<<<)으로 부르면 서브셸이 생기지 않는다.
  rendered="$(sed -e "s|@@WORKER@@|${DOC_WORKER}|g" \
      -e "s|@@REVIEWER@@|${DOC_REVIEWER}|g" \
      -e "s|@@ORCHESTRATOR@@|${DOC_ORCHESTRATOR}|g" \
      -e "s|@@FALLBACK@@|${DOC_FALLBACK}|g" \
      -e "s|@@APPROVAL_MODE@@|${DOC_APPROVAL_MODE:-auto}|g" \
      -e "s|@@CLAUDE_AUTO@@|${DOC_CLAUDE_AUTO:---permission-mode acceptEdits}|g" \
      -e "s|@@CLAUDE_BYPASS@@|${DOC_CLAUDE_BYPASS:---permission-mode bypassPermissions}|g" \
      -e "s|@@CODEX_AUTO@@|${DOC_CODEX_AUTO:---ask-for-approval never --sandbox workspace-write}|g" \
      -e "s|@@CODEX_BYPASS@@|${DOC_CODEX_BYPASS:---dangerously-bypass-approvals-and-sandbox}|g" \
      -e "s|@@AGY_AUTO@@|${DOC_AGY_AUTO:---mode accept-edits}|g" \
      -e "s|@@AGY_BYPASS@@|${DOC_AGY_BYPASS:---dangerously-skip-permissions}|g" \
      -e "s|@@NAME@@|${DOC_NAME}|g" "$source_file")"
  if [[ "$relative" == ".harness/policies/agent-policy.yaml" ]]; then
    rendered="$(printf '%s\n' "$rendered" | awk \
      -v claude_models="${DOC_CLAUDE_MODELS:-}" \
      -v claude_default_model="${DOC_CLAUDE_DEFAULT_MODEL:-}" \
      -v codex_models="${DOC_CODEX_MODELS:-}" \
      -v codex_default_model="${DOC_CODEX_DEFAULT_MODEL:-}" \
      -v agy_models="${DOC_AGY_MODELS:-}" \
      -v agy_default_model="${DOC_AGY_DEFAULT_MODEL:-}" '
        /^  claude_models:/ { print "  claude_models: \047" claude_models "\047"; next }
        /^  claude_default_model:/ { print "  claude_default_model: \047" claude_default_model "\047"; next }
        /^  codex_models:/ { print "  codex_models: \047" codex_models "\047"; next }
        /^  codex_default_model:/ { print "  codex_default_model: \047" codex_default_model "\047"; next }
        /^  agy_models:/ { print "  agy_models: \047" agy_models "\047"; next }
        /^  agy_default_model:/ { print "  agy_default_model: \047" agy_default_model "\047"; next }
        { print }
      ')"
  fi
  write_file "$root" "$relative" <<<"$rendered"
}

# init과 sync-templates가 프로젝트로 복사하는 템플릿 파일 목록. 정본은 이
# 저장소의 templates/ 아래 같은 상대경로에 있고, emit_doc이 @@…@@ 플레이스홀더만
# 치환한다. 새 템플릿을 추가하면 이 배열에도 넣어야 cmd_test가 잡아낸다.
HARNESS_DOC_TEMPLATES=(
  ".agents/skills/harness-spec/SKILL.md"
  ".agents/skills/harness-plan/SKILL.md"
  ".agents/skills/harness-orchestrate/SKILL.md"
  ".agents/skills/harness-work/SKILL.md"
  ".agents/skills/harness-review/SKILL.md"
  ".agents/skills/harness-handover/SKILL.md"
  ".agents/roles/interviewer.agent.md"
  ".agents/roles/planner.agent.md"
  ".agents/roles/orchestrator.agent.md"
  ".agents/roles/worker.agent.md"
  ".agents/roles/advisor.agent.md"
  ".agents/roles/reviewer.agent.md"
  ".harness/attempts/TEMPLATE.md"
  ".harness/reviews/TEMPLATE.md"
  ".harness/handovers/TEMPLATE.md"
  ".harness/waves/TEMPLATE.yaml"
  ".harness/decisions/TEMPLATE.md"
  ".harness/intents/TEMPLATE.md"
  ".harness/intents/README.md"
)

HARNESS_POLICY_TEMPLATES=(
  ".harness/policies/review-policy.yaml"
  ".harness/policies/agent-policy.yaml"
  ".harness/tasks/TEMPLATE.yaml"
)

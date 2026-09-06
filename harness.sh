#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# 프로젝트 템플릿 정본은 harness.sh 옆 templates/ 에 있다. init·sync-templates가
# 여기서 파일을 읽어 @@…@@ 플레이스홀더만 치환해 프로젝트로 복사한다.
# 심볼릭 링크(~/.local/bin/herdr-harness → $INSTALL_DIR/harness.sh)로 실행될 때도
# 실제 위치를 찾아야 하므로 readlink -f로 해석한다.
_harness_real_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "$SELF_PATH")"
HARNESS_TEMPLATE_DIR="${HARNESS_TEMPLATE_DIR:-$(dirname "$_harness_real_path")/templates}"

usage() {
  cat <<EOF
Herdr Agent/Skills Harness

사용법:
  $SCRIPT_NAME help | -h | --help  이 도움말 출력(인자 없이 실행해도 같다)
  $SCRIPT_NAME init PATH [옵션]   새 프로젝트 Harness 생성
  $SCRIPT_NAME sync-templates PATH [--apply]  기존 프로젝트의 skill·role 파일을 지금 버전 템플릿으로 재동기화(기본은 diff 미리보기)
  $SCRIPT_NAME start [PATH]       Herdr Session 시작
  $SCRIPT_NAME status [PATH]      현재 STATE.md 출력
  $SCRIPT_NAME status --live      문서·Herdr·Git 상태 대조 (DRIFT 표시)
  $SCRIPT_NAME doctor             설치 상태 확인
  $SCRIPT_NAME test               Agent 쿼터 없는 자체 테스트
  $SCRIPT_NAME uninstall [--yes]  설치된 Harness 명령 제거
  $SCRIPT_NAME completion bash    Bash 탭 완성 스크립트 출력(설치: source <(herdr-harness completion bash))

Agent Loop 스텝 명령 (호출 1회 = 1스텝, 상주 루프 없음):
  $SCRIPT_NAME validate [PATH] [--wave ID]        읽기 전용 사전 검증
  $SCRIPT_NAME transition PATH TASK_ID TO_STATE   상태 전이 강제
  $SCRIPT_NAME dispatch PATH TASK_ID ROLE         Agent 한 턴 실행
  $SCRIPT_NAME observe PATH TASK_ID [ROLE]        기존 Agent 재조회
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
      -e "s|@@NAME@@|${DOC_NAME}|g" "$source_file")"
  write_file "$root" "$relative" <<<"$rendered"
}

# init과 sync-templates가 프로젝트로 복사하는 템플릿 파일 목록. 정본은 이
# 저장소의 templates/ 아래 같은 상대경로에 있고, emit_doc이 @@…@@ 플레이스홀더만
# 치환한다. 새 템플릿을 추가하면 이 배열에도 넣어야 cmd_test가 잡아낸다.
HARNESS_DOC_TEMPLATES=(
  ".agents/skills/harness-interview/SKILL.md"
  ".agents/skills/harness-reference/SKILL.md"
  ".agents/skills/harness-plan/SKILL.md"
  ".agents/skills/harness-orchestrate/SKILL.md"
  ".agents/skills/harness-work/SKILL.md"
  ".agents/skills/harness-verify/SKILL.md"
  ".agents/skills/harness-review/SKILL.md"
  ".agents/skills/harness-handover/SKILL.md"
  ".agents/skills/harness-status/SKILL.md"
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
  ".harness/tasks/TEMPLATE.yaml"
)

write_project_docs() {
  local root="$1"
  DOC_NAME="$2" DOC_ORCHESTRATOR="$3" DOC_WORKER="$4" DOC_REVIEWER="$5" DOC_FALLBACK="$6"
  local rel
  for rel in "${HARNESS_DOC_TEMPLATES[@]}"; do
    emit_doc "$root" "$rel"
  done
}

write_project_templates() {
  local root="$1"
  DOC_NAME="$2" DOC_ORCHESTRATOR="$3" DOC_WORKER="$4" DOC_REVIEWER="$5" DOC_FALLBACK="$6"
  local rel
  for rel in "${HARNESS_POLICY_TEMPLATES[@]}"; do
    emit_doc "$root" "$rel"
  done
}

# ---------------------------------------------------------------------------
# 프로젝트 루트 진입 문서 (AGENTS.md/CLAUDE.md/GEMINI.md)
# init과 sync-templates의 diff 미리보기가 같은 내용을 봐야 하므로 함수로
# 뽑아 둔다 — 두 곳에 나눠 적으면 시간이 지나며 서로 갈라진다.
# ---------------------------------------------------------------------------

_entry_doc_agents() {
  local name="$1" orchestrator="$2" worker="$3" reviewer="$4" fallback="$5"
  cat <<EOF
# Agent Instructions: $name

이 프로젝트는 Herdr Agent/Skills Harness로 운영한다.

반드시 \`.harness/SPEC.md\`, \`.harness/STATE.md\`, 현재 Task YAML, 현재 역할 문서와 관련 Skill을 읽는다.

- 승인된 SPEC과 Task 없이 구현하지 않는다.
- 하나의 Task는 하나의 목적만 가진다.
- Task당 쓰기 가능한 Primary Worker는 한 명이다.
- 기존 코드·데이터·문서·Dump를 먼저 확인한다.
- Worker는 \`submitted\`까지만 제안하고 사용자가 \`completed\`를 승인한다.
- 실패·쿼터 확인 후 Handover와 사용자 승인을 거쳐 Provider를 교체한다.
- 위험한 명령, 배포, 외부 쓰기는 사용자 승인을 받는다.

기본 배정: Orchestrator=$orchestrator, Worker=$worker, Reviewer=$reviewer, Fallback=$fallback
EOF
}

_entry_doc_claude() {
  cat <<'EOF'
# Claude Code Entry

`AGENTS.md`를 공통 정책으로 사용한다. 현재 역할에 맞는 `.agents/roles/*.agent.md`와 `.claude/skills/`의 Harness Skill을 읽는다. Herdr Pane 제어는 `HERDR_ENV=1`일 때만 수행한다.
EOF
}

_entry_doc_gemini() {
  cat <<'EOF'
# Antigravity Entry

`AGENTS.md`를 공통 정책으로 사용한다. 현재 역할에 맞는 `.agents/roles/*.agent.md`와 `.agents/skills/`의 Harness Skill을 읽는다. Herdr Pane 제어는 `HERDR_ENV=1`일 때만 수행한다.
EOF
}

cmd_init() {
  local target="${1:-}"
  [[ -n "$target" && "$target" != -* ]] || die "init에는 새 프로젝트 경로가 필요합니다."
  shift

  local name="" goal="" profile="generic"
  local orchestrator="claude" worker="codex" reviewer="agy" fallback="claude,agy"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) [[ $# -ge 2 ]] || die "--name 값이 필요합니다."; name="$2"; shift 2 ;;
      --goal) [[ $# -ge 2 ]] || die "--goal 값이 필요합니다."; goal="$2"; shift 2 ;;
      --profile) [[ $# -ge 2 ]] || die "--profile 값이 필요합니다."; profile="$2"; shift 2 ;;
      --orchestrator) [[ $# -ge 2 ]] || die "--orchestrator 값이 필요합니다."; orchestrator="$2"; shift 2 ;;
      --worker) [[ $# -ge 2 ]] || die "--worker 값이 필요합니다."; worker="$2"; shift 2 ;;
      --reviewer) [[ $# -ge 2 ]] || die "--reviewer 값이 필요합니다."; reviewer="$2"; shift 2 ;;
      --fallback) [[ $# -ge 2 ]] || die "--fallback 값이 필요합니다."; fallback="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "알 수 없는 init 옵션: $1" ;;
    esac
  done

  target="$(realpath -m "$target")"
  [[ "$target" != "/" && "$target" != "$HOME" ]] || die "너무 넓은 경로는 사용할 수 없습니다: $target"
  if [[ -d "$target" ]] && find "$target" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    die "신규 프로젝트 전용입니다. 대상 경로가 비어 있지 않습니다: $target"
  fi

  [[ -n "$name" ]] || name="$(basename "$target")"
  if [[ -z "$goal" ]]; then prompt_required goal "프로젝트 목표"; fi
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "프로젝트명은 영문, 숫자, 점, 밑줄, 하이픈만 사용할 수 있습니다."
  valid_profile "$profile" || die "지원하지 않는 Profile입니다: $profile"
  valid_provider "$orchestrator" || die "지원하지 않는 Orchestrator입니다: $orchestrator"
  valid_provider "$worker" || die "지원하지 않는 Worker입니다: $worker"
  valid_provider "$reviewer" || die "지원하지 않는 Reviewer입니다: $reviewer"
  [[ "$worker" != "$reviewer" ]] || die "Worker와 Reviewer는 다른 Provider여야 합니다."

  IFS=',' read -r -a fallback_items <<<"$fallback"
  for provider in "${fallback_items[@]}"; do
    valid_provider "$provider" || die "지원하지 않는 Fallback Provider입니다: $provider"
  done

  mkdir -p "$target"
  local name_yaml goal_yaml
  name_yaml="$(yaml_quote "$name")"
  goal_yaml="$(yaml_quote "$goal")"

  write_file "$target" ".gitignore" <<'EOF'
.env
.env.*
!.env.example
.harness/runtime/
.harness/evidence/raw/
.harness/worktrees/
__pycache__/
.pytest_cache/
.venv/
node_modules/
EOF

  write_file "$target" "AGENTS.md" <<<"$(_entry_doc_agents "$name" "$orchestrator" "$worker" "$reviewer" "$fallback")"
  write_file "$target" "CLAUDE.md" <<<"$(_entry_doc_claude)"
  write_file "$target" "GEMINI.md" <<<"$(_entry_doc_gemini)"

  write_file "$target" ".harness/project.yaml" <<EOF
schema_version: '1.0'
project:
  name: $name_yaml
  goal: $goal_yaml
  profile: '$profile'

mode:
  # 사용자가 Controller와 최종 Gate 역할을 한다.
  type: agent_driven
  unattended_execution: false

providers:
  orchestrator: '$orchestrator'
  primary_worker: '$worker'
  reviewer: '$reviewer'
  fallback_chain: [$fallback]

limits:
  # 전체 Task가 아니라 현재 활성 목록의 상한이다.
  max_active_tasks: 5
  max_parallel_workers: 2
  max_primary_workers_per_task: 1

approval:
  spec: user_required
  milestone_plan: user_required
  provider_failover: user_required
  integration: user_required
  destructive_action: user_required
EOF

  write_file "$target" ".harness/SPEC.md" <<EOF
# Specification: $name

## 1. 핵심 목표

$goal

## 2. 기존 자료와 재사용 판단

- [ ] 기존 코드 또는 저장소
- [ ] 데이터, Sample Dump 또는 Notebook
- [ ] 설계서, API, MIB 또는 운영 문서
- [ ] 라이선스와 재사용 제약

## 3. 기술 스택 및 제약

- 언어/프레임워크: TBD
- 실행 환경: TBD
- 변경 금지 영역: TBD

## 4. 요구사항

- [ ] Interview 후 작성

## 5. Acceptance Criteria

- [ ] Criterion마다 검증 방법 연결

## 6. 제외 범위

- TBD

## 7. 사용자 승인

- 상태: draft
- 승인자:
- 승인 시각:
EOF

  write_file "$target" ".harness/MILESTONES.md" <<'EOF'
# Milestones

| ID | 중간 목표 | 상태 | 완료 기준 |
|---|---|---|---|
| milestone-001 | Interview 후 작성 | draft | 사용자 승인 |
EOF

  write_file "$target" ".harness/STATE.md" <<EOF
# Project State

- Project: $name
- Status: interviewing
- Current milestone: milestone-001
- Active wave: none
- Max active tasks: 5
- Max parallel workers: 2

| Task | 목적 | Worker | Reviewer | 상태 | 검증 |
|---|---|---|---|---|---|
| task-001 | 기존 자료와 요구사항 확인 | $worker | $reviewer | draft | user-review |

## Pending decisions

- SPEC 인터뷰 필요
EOF

  write_file "$target" ".harness/policies/project-policy.yaml" <<'EOF'
execution:
  # 사용자 승인 없이 다음 Wave로 진행하지 않는다.
  unattended_execution: false
  rebase_while_attempt_running: false

security:
  # 운영 지침이며 OS 수준 Sandbox는 아니다.
  allow_destructive_commands: false
  allow_production_deploy: false
  allow_secret_output: false
  allow_network_by_default: false

references:
  require_existing_asset_discovery: true
  require_reference_inventory: true
EOF

  write_file "$target" ".harness/policies/quota-policy.yaml" <<'EOF'
quota_policy:
  # 정상 실행 중에는 다른 Provider를 호출하지 않는다.
  strategy: failure_only
  # true로 켜면 `herdr-harness quota-retry PATH TASK_ID ROLE`이 동작한다.
  # 그래도 자동 실행은 handover_required 전이까지만이다 — Provider 교체 후
  # 재개(ready로 전이)는 항상 사람이 .harness/decisions/TASK-failover-approval.md
  # 에 "승인: yes"를 쓴 뒤 직접 한다. false(기본값)면 quota-retry는 즉시 거부한다.
  automatic_failover: false
  require_handover: true
  require_user_approval: true

  # 능동 확인: `herdr-harness quota-check PATH TASK_ID ROLE`
  # (claude/codex는 실행 중인 Agent에 /status를 보내 읽고, agy는
  # `agy --print "/usage"`로 바로 조회한다 — Task 없이 확인하려면
  # `quota-check PATH --provider agy`). 어느 경우에도 자동으로 Provider를
  # 바꾸지 않는다 — 위 strategy: failure_only 원칙 그대로다.
  #
  # 수동 확인: `agy --print "/usage"` (agy), Agent Pane 안에서 `/status`
  # 입력(claude, codex).
  #
  # 경보 임계값(quota-check가 low로 판정하는 기준). 이 값을 낮추면 더 여유
  # 있을 때부터 low로 뜬다 — 코드가 아니라 여기서 조정한다.
  low_warning_threshold_pct: 25

  # quota-retry가 요구하는 연속 low 판정 횟수와 그 사이 최소 간격(초).
  # 오탐 한 번으로 Provider를 바꾸는 것을 막는다.
  low_confirm_count: 2
  cooldown_seconds: 300

  # quota-retry/auto-step이 쓰는 Task Lock이 소유 프로세스가 죽은 채로
  # 이 시간(초)을 넘기면 stale로 보고 회수한다.
  stale_lock_seconds: 600

  # dispatch/observe는 Agent 출력에서 알려진 쿼터 경고 문구를 지나가는 김에
  # 스캔해 evidence에 "쿼터 신호(자동 감지)" 절로 남긴다(확정 아님, 참고용).
  passive_scan_on_dispatch: true
EOF

  write_file "$target" ".harness/policies/loop-policy.yaml" <<'EOF'
loop_policy:
  # true로 켜면 `herdr-harness auto-step PATH TASK_ID`가 동작한다. 기본은
  # 꺼져 있다 — opt-in. 켜도 상주 루프가 아니다: 호출 1회가 최대
  # max_turns_ceiling턴 안에서 반드시 끝난다.
  enabled: false

  # --max-turns로 이보다 큰 값을 요청해도 이 값이 상한이다.
  max_turns_ceiling: 5

  # Task Lock이 소유 프로세스가 죽은 채로 이 시간(초)을 넘기면 stale로
  # 보고 회수한다.
  stale_lock_seconds: 600
EOF

  write_file "$target" ".harness/profiles/generic.yaml" <<'EOF'
profile_id: generic
task_types: [code, research, data, document, ops]
review_focus: [correctness, regression, security, maintainability]
EOF

  write_file "$target" ".harness/profiles/python-timeseries.yaml" <<'EOF'
profile_id: python-timeseries
reference_inputs: [existing_notebooks, source_code, datasets, data_dictionary, experiment_results]
review_focus: [time_ordered_split, leakage_prevention, baseline, backtesting, reproducibility, uncertainty]
EOF

  write_file "$target" ".harness/profiles/network-device.yaml" <<'EOF'
profile_id: network-device
reference_inputs: [snmp_dumps, mib_files, vendor_docs, receiver_configs, existing_normalizers]
review_focus: [canonical_schema, oid_provenance, counter_reset, units, timestamps, unknown_oid, dump_regression]
EOF

  write_file "$target" ".harness/references/inventory.md" <<'EOF'
# Reference Inventory

| ID | 경로/URL | 유형 | 출처 | 재사용 판단 | 제약 |
|---|---|---|---|---|---|
EOF

  for area in waves attempts evidence reviews handovers decisions archive; do
    write_file "$target" ".harness/$area/README.md" <<EOF
# ${area^}

이 디렉터리에는 Project의 $area 기록을 보존한다. 기존 기록을 덮어쓰지 않고 Task ID와 Attempt 번호를 파일명에 포함한다.
EOF
  done

  write_project_docs "$target" "$name" "$orchestrator" "$worker" "$reviewer" "$fallback"
  write_project_templates "$target" "$name" "$orchestrator" "$worker" "$reviewer" "$fallback"

  mkdir -p "$target/.claude/skills"
  local skill_dir skill_name
  for skill_dir in "$target"/.agents/skills/*; do
    skill_name="$(basename "$skill_dir")"
    ln -s "../../.agents/skills/$skill_name" "$target/.claude/skills/$skill_name"
  done

  write_file "$target" "HARNESS_START.md" <<EOF
# 시작 방법

\`\`\`bash
cd "$target"
herdr-harness start .
\`\`\`

Herdr 첫 Pane에서 \`$orchestrator\`를 실행하고 다음을 요청한다.

\`\`\`text
harness-orchestrate Skill을 사용해 프로젝트를 시작해줘.
기존 코드, 데이터, 문서, Dump가 있는지 먼저 인터뷰하고
SPEC 승인 전에는 구현하지 마.
\`\`\`
EOF

  init_git_baseline "$target"

  info "생성 완료: $target"
  info "다음 단계: cd '$target' && herdr-harness start ."
}

# ---------------------------------------------------------------------------
# sync-templates — 기존 프로젝트를 지금 harness.sh 버전의 skill/role 템플릿과
# 맞춘다. init은 신규 프로젝트 전용(대상이 비어 있지 않으면 die)이라, 그보다
# 먼저 만들어진 프로젝트는 나중에 추가된 Agent Loop 절차(dispatch/observe/
# transition/close-agent)를 skill 파일이 한 줄도 언급하지 않는 채로 영영
# 남는다 — 실사례로 발견됐다(BACKLOG.md 항목 8). 이 명령이 그 gap을 메운다.
#
# Harness 소유 파일만 건드린다: .agents/skills/, .agents/roles/,
# .claude/skills/ 심볼릭 링크. AGENTS.md/CLAUDE.md/GEMINI.md는 프로젝트가
# 손으로 문구를 덧붙였을 수 있어(실제로 한 프로젝트가 그랬다) 자동 갱신하지
# 않고 diff만 보여준다 — 병합은 사람이 판단한다.
# ---------------------------------------------------------------------------

cmd_sync_templates() {
  local root_arg="." apply=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) apply=1; shift ;;
      --dry-run) apply=0; shift ;;
      -h|--help)
        printf '사용법: %s sync-templates [PATH] [--apply]\n' "$SCRIPT_NAME"
        printf '기본은 미리보기(diff)만 한다. 실제로 파일을 갱신하려면 --apply를 준다.\n'
        return 0
        ;;
      -*) die "알 수 없는 sync-templates 옵션: $1" ;;
      *) root_arg="$1"; shift ;;
    esac
  done

  local root
  root="$(project_root "$root_arg")"
  require_git_baseline "$root"

  local name orchestrator worker reviewer fallback
  name="$(project_field "$root" project name)"
  orchestrator="$(project_field "$root" providers orchestrator)"
  worker="$(project_field "$root" providers primary_worker)"
  reviewer="$(project_field "$root" providers reviewer)"
  fallback="$(awk -F'[][]' '/^  fallback_chain:/{print $2; exit}' "$root/.harness/project.yaml")"

  SYNC_CHANGED=()
  SYNC_UNCHANGED=()
  SYNC_WOULD_CHANGE=()
  HH_SYNC_MODE=1
  if [[ "$apply" -eq 1 ]]; then
    HH_SYNC_DRYRUN=0
    info "적용 모드 — .agents/skills/, .agents/roles/, .claude/skills/ 심볼릭 링크를 현재 템플릿으로 갱신합니다."
  else
    HH_SYNC_DRYRUN=1
    info "미리보기 모드(기본값) — 실제로 갱신하려면 --apply. 아래는 바뀌었을 내용이다."
  fi

  write_project_docs "$root" "$name" "$orchestrator" "$worker" "$reviewer" "$fallback"
  write_project_templates "$root" "$name" "$orchestrator" "$worker" "$reviewer" "$fallback"

  # .claude/skills/* 심볼릭 링크 — 없는 것만 만든다. 이미 있으면(정상 링크든,
  # 사용자가 다른 곳을 가리키게 바꿔 놓은 것이든) 손대지 않는다.
  local skill_dir skill_name link_path
  mkdir -p "$root/.claude/skills"
  for skill_dir in "$root"/.agents/skills/*; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "$skill_dir")"
    link_path="$root/.claude/skills/$skill_name"
    [[ -e "$link_path" || -L "$link_path" ]] && continue
    if [[ "$apply" -eq 1 ]]; then
      ln -s "../../.agents/skills/$skill_name" "$link_path"
      SYNC_CHANGED+=(".claude/skills/$skill_name (신규 심볼릭 링크)")
    else
      printf '  (신규 심볼릭 링크) .claude/skills/%s\n' "$skill_name"
      SYNC_WOULD_CHANGE+=(".claude/skills/$skill_name (신규 심볼릭 링크)")
    fi
  done

  # AGENTS.md/CLAUDE.md/GEMINI.md — 참고용 diff만. 자동으로 쓰지 않는다.
  printf '\n[참고용 — 자동 갱신 안 함] AGENTS.md / CLAUDE.md / GEMINI.md\n'
  printf '이 세 파일은 프로젝트가 고유 규칙을 덧붙였을 수 있어 sync-templates가 건드리지 않는다.\n'
  printf '아래에 diff가 보이면 최신 템플릿과 달라졌다는 뜻이니 필요한 부분만 손으로 병합한다.\n'
  local entry_doc entry_generator
  for entry_doc in AGENTS.md CLAUDE.md GEMINI.md; do
    case "$entry_doc" in
      AGENTS.md) entry_generator="_entry_doc_agents \"\$name\" \"\$orchestrator\" \"\$worker\" \"\$reviewer\" \"\$fallback\"" ;;
      CLAUDE.md) entry_generator="_entry_doc_claude" ;;
      GEMINI.md) entry_generator="_entry_doc_gemini" ;;
    esac
    local generated="$root/.harness/runtime/.sync-preview-$entry_doc"
    mkdir -p "$root/.harness/runtime"
    eval "$entry_generator" >"$generated"
    if [[ ! -e "$root/$entry_doc" ]]; then
      printf '  %s: 파일 없음 — sync-templates는 새로 만들지 않는다(직접 만들 것)\n' "$entry_doc"
    elif cmp -s "$generated" "$root/$entry_doc"; then
      printf '  %s: 최신 템플릿과 동일\n' "$entry_doc"
    else
      printf -- '  %s: 최신 템플릿과 다름 —\n' "$entry_doc"
      # diff는 다르면 종료코드 1을 낸다 — set -e 아래서 `|| true` 없이 파이프에
      # 물리면 여기서 스크립트 전체가 조용히 죽는다(요약 줄·이벤트 로그가
      # 통째로 안 나오는 형태로 재현됨). 반드시 이 가드를 유지한다.
      { diff -u "$root/$entry_doc" "$generated" | sed 's/^/    /'; } || true
    fi
    rm -f "$generated"
  done

  # dry-run에서는 SYNC_WOULD_CHANGE에, apply에서는 SYNC_CHANGED에 쌓인다 —
  # 둘 다 아니라 SYNC_CHANGED만 세면 dry-run 요약이 항상 "변경 0"으로
  # 거짓 보고된다(실제로 이 자리에서 그렇게 재현됐다).
  local change_count
  if [[ "$apply" -eq 1 ]]; then
    change_count=${#SYNC_CHANGED[@]}
  else
    change_count=${#SYNC_WOULD_CHANGE[@]}
  fi

  printf '\n요약: 변경 %d · 동일 %d' "$change_count" "${#SYNC_UNCHANGED[@]}"
  if [[ "$apply" -eq 1 ]]; then
    printf '\n'
  else
    printf ' · 미리보기뿐이라 실제로는 안 바뀜(적용하려면 --apply)\n'
  fi

  append_event "$root" sync_templates "-" "" "" \
    "mode=$([[ "$apply" -eq 1 ]] && echo apply || echo dry-run) changed=$change_count unchanged=${#SYNC_UNCHANGED[@]}"
}

# ---------------------------------------------------------------------------
# 제한 스키마 YAML 리더
# 범용 YAML 파서를 흉내 내지 않는다. Harness가 생성한 고정 스키마만 엄격히 읽고,
# 정확히 한 번 매칭되지 않으면 실패한다.
# ---------------------------------------------------------------------------

yaml_unquote() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  case "$value" in
    \'*\') value="${value:1:${#value}-2}"; value="${value//\'\'/\'}" ;;
    \"*\") value="${value:1:${#value}-2}" ;;
  esac
  printf '%s' "$value"
}

yaml_scalar() {
  local file="$1" key="$2" required="${3:-required}"
  local count line
  [[ -f "$file" ]] || die "YAML 파일이 없습니다: $file"
  count="$(grep -c "^${key}:" "$file" 2>/dev/null || true)"
  if [[ "$count" -eq 0 ]]; then
    [[ "$required" == optional ]] || die "필수 키가 없습니다: $key ($file)"
    return 0
  fi
  [[ "$count" -eq 1 ]] || die "키가 중복되었습니다: $key ($file)"
  line="$(grep -m1 "^${key}:" "$file")"
  yaml_unquote "${line#"${key}":}"
}

yaml_flow_list() {
  local file="$1" key="$2"
  local line inner item
  line="$(grep -m1 "^${key}:" "$file" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 0
  inner="${line#"${key}":}"
  inner="$(yaml_unquote "$inner")"
  case "$inner" in
    \[*\]) inner="${inner:1:${#inner}-2}" ;;
    *) return 0 ;;
  esac
  [[ -n "${inner//[[:space:]]/}" ]] || return 0
  local IFS=','
  for item in $inner; do
    item="$(yaml_unquote "$item")"
    [[ -z "$item" ]] || printf '%s\n' "$item"
  done
}

project_field() {
  local root="$1" section="$2" key="$3"
  local file="$root/.harness/project.yaml"
  local count line
  [[ -f "$file" ]] || die "project.yaml이 없습니다: $file"
  count="$(awk -v s="$section:" -v k="  $key:" '
    $0 == s { inside = 1; next }
    /^[^[:space:]#]/ { inside = 0 }
    inside && index($0, k) == 1 { n++ }
    END { print n + 0 }' "$file")"
  [[ "$count" -eq 1 ]] || die "project.yaml에서 $section.$key 를 정확히 한 번 찾지 못했습니다 (발견 $count 회)."
  line="$(awk -v s="$section:" -v k="  $key:" '
    $0 == s { inside = 1; next }
    /^[^[:space:]#]/ { inside = 0 }
    inside && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$file")"
  yaml_unquote "$line"
}

task_file() {
  local root="$1" task_id="$2"
  local path="$root/.harness/tasks/${task_id}.yaml"
  [[ -f "$path" ]] || die "Task 파일이 없습니다: $path"
  printf '%s\n' "$path"
}

task_ids() {
  local root="$1" path base
  for path in "$root"/.harness/tasks/*.yaml; do
    [[ -f "$path" ]] || continue
    base="$(basename "$path" .yaml)"
    [[ "$base" != TEMPLATE ]] || continue
    printf '%s\n' "$base"
  done
}

valid_task_status() {
  case "$1" in
    draft|ready|active|submitted|reviewing|changes_requested|blocked|handover_required|awaiting_approval|completed) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Git 기준선
# ---------------------------------------------------------------------------

git_baseline_status() {
  # 출력: ok | no-git | no-repo | no-commit
  local root="$1"
  command -v git >/dev/null 2>&1 || { printf 'no-git\n'; return 0; }
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf 'no-repo\n'; return 0; }
  git -C "$root" rev-parse HEAD >/dev/null 2>&1 || { printf 'no-commit\n'; return 0; }
  printf 'ok\n'
}

require_git_baseline() {
  local root="$1" state
  state="$(git_baseline_status "$root")"
  case "$state" in
    ok) return 0 ;;
    no-git) die "git 명령을 찾을 수 없습니다. Harness는 Git Diff를 Review와 Handover의 근거로 사용합니다." ;;
    no-repo) die "Git 저장소가 아닙니다: $root  (git init 후 기준 commit을 만드세요)" ;;
    no-commit) die "기준 commit이 없습니다: $root  (git add -A && git commit 으로 기준선을 만드세요)" ;;
  esac
}

init_git_baseline() {
  local root="$1"
  if ! command -v git >/dev/null 2>&1; then
    info "경고: git이 없어 저장소를 초기화하지 못했습니다. Diff 기반 Review와 Handover를 사용할 수 없습니다."
    return 0
  fi
  git -C "$root" init -q
  git -C "$root" add -A
  if git -C "$root" config user.email >/dev/null 2>&1 &&
     git -C "$root" config user.name >/dev/null 2>&1; then
    git -C "$root" -c core.hooksPath=/dev/null commit -q -m "chore: harness 기준선" \
      && info "Git 기준선 commit을 생성했습니다."
  else
    info "경고: git user.name / user.email이 없어 기준 commit을 만들지 못했습니다."
    info "        다음을 실행한 뒤 계속하세요: git -C '$root' commit -m 'chore: harness 기준선'"
  fi
}

# ---------------------------------------------------------------------------
# 이벤트 로그 (append-only)
# ---------------------------------------------------------------------------

append_event() {
  local root="$1"; shift
  local log="$root/.harness/evidence/events.tsv"
  local stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ ! -f "$log" ]]; then
    printf 'timestamp\tevent\ttask\tfrom\tto\tdetail\n' >"$log"
  fi
  printf '%s\t%s\n' "$stamp" "$(printf '%s\t' "$@" | sed 's/\t$//')" >>"$log"
}

# ---------------------------------------------------------------------------
# validate — 읽기 전용 사전 검증. 상태를 바꾸지 않는다.
# ---------------------------------------------------------------------------

cmd_validate() {
  local root_arg="." wave="" strict_git=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wave) [[ $# -ge 2 ]] || die "--wave 값이 필요합니다."; wave="$2"; shift 2 ;;
      --no-git) strict_git=0; shift ;;
      -h|--help) printf '사용법: %s validate [PATH] [--wave ID] [--no-git]\n' "$SCRIPT_NAME"; return 0 ;;
      -*) die "알 수 없는 validate 옵션: $1" ;;
      *) root_arg="$1"; shift ;;
    esac
  done

  local root problems=0
  root="$(project_root "$root_arg")"

  report_problem() { printf '[FAIL] %s\n' "$*"; problems=$((problems + 1)); }
  report_ok() { printf '[OK]   %s\n' "$*"; }

  # 1. Git 기준선
  local git_state
  git_state="$(git_baseline_status "$root")"
  if [[ "$git_state" == ok ]]; then
    report_ok "Git 기준선 존재"
  elif [[ "$strict_git" -eq 1 ]]; then
    report_problem "Git 기준선 없음 ($git_state). Diff 기반 Review·Handover·Context Packet을 만들 수 없습니다."
  else
    report_ok "Git 검사 생략 (--no-git)"
  fi

  # 2. SPEC 승인
  local spec_state
  spec_state="$(awk -F': ' '/^- 상태:/{print $2; exit}' "$root/.harness/SPEC.md" 2>/dev/null || true)"
  spec_state="${spec_state:-unknown}"
  if [[ "$spec_state" == approved ]]; then
    report_ok "SPEC 승인됨"
  else
    report_ok "SPEC 상태=$spec_state (구현 단계 전이는 승인 후에만 가능)"
  fi

  # 3. Provider 배정
  local p_worker p_reviewer
  p_worker="$(project_field "$root" providers primary_worker)"
  p_reviewer="$(project_field "$root" providers reviewer)"
  if [[ "$p_worker" == "$p_reviewer" ]]; then
    report_problem "project.yaml의 primary_worker와 reviewer가 같습니다: $p_worker"
  else
    report_ok "기본 Worker($p_worker) != Reviewer($p_reviewer)"
  fi

  # 4. 상한
  local max_active max_parallel
  max_active="$(awk '/^  max_active_tasks:/{print $2; exit}' "$root/.harness/project.yaml")"
  max_parallel="$(awk '/^  max_parallel_workers:/{print $2; exit}' "$root/.harness/project.yaml")"

  # 5. Task별 검사
  local task_id path status worker reviewer dep
  local active_count=0 open_count=0
  local -A scope_owner=()

  while IFS= read -r task_id; do
    [[ -n "$task_id" ]] || continue
    path="$root/.harness/tasks/${task_id}.yaml"
    local declared_id
    declared_id="$(yaml_scalar "$path" task_id)"
    [[ "$declared_id" == "$task_id" ]] ||
      report_problem "$task_id: 파일명과 task_id가 다릅니다 (task_id=$declared_id)"

    status="$(yaml_scalar "$path" status)"
    valid_task_status "$status" || report_problem "$task_id: 알 수 없는 status=$status"

    worker="$(yaml_scalar "$path" primary_worker)"
    reviewer="$(yaml_scalar "$path" reviewer)"
    valid_provider "$worker" || report_problem "$task_id: 알 수 없는 primary_worker=$worker"
    valid_provider "$reviewer" || report_problem "$task_id: 알 수 없는 reviewer=$reviewer"
    [[ "$worker" != "$reviewer" ]] ||
      report_problem "$task_id: Worker와 Reviewer가 같습니다 ($worker)"

    case "$status" in
      completed) ;;
      *) open_count=$((open_count + 1)) ;;
    esac
    if [[ "$status" == active ]]; then
      active_count=$((active_count + 1))
      fi

    # 의존성: ready 이상으로 열려 있는 Task의 선행 Task는 completed여야 한다
    if [[ "$status" == ready || "$status" == active ]]; then
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        local dep_path dep_status
        dep_path="$root/.harness/tasks/${dep}.yaml"
        if [[ ! -f "$dep_path" ]]; then
          report_problem "$task_id: 의존 Task 파일이 없습니다: $dep"
          continue
        fi
        dep_status="$(yaml_scalar "$dep_path" status)"
        [[ "$dep_status" == completed ]] ||
          report_problem "$task_id: 의존 Task $dep 가 completed가 아닙니다 (현재 $dep_status)"
      done < <(yaml_flow_list "$path" dependencies)
    fi

    # write_scope 충돌: 동시에 active인 Task끼리만 검사
    if [[ "$status" == active ]]; then
      local scope
      while IFS= read -r scope; do
        [[ -n "$scope" ]] || continue
        if [[ -n "${scope_owner[$scope]:-}" ]]; then
          report_problem "write_scope 충돌: '$scope' 를 ${scope_owner[$scope]} 와 $task_id 가 동시에 소유"
        else
          scope_owner[$scope]="$task_id"
        fi
      done < <(yaml_flow_list "$path" write_scope)
    fi
  done < <(task_ids "$root")

  if [[ "$open_count" -le "${max_active:-5}" ]]; then
    report_ok "활성 Task $open_count / 상한 ${max_active:-5}"
  else
    report_problem "활성 Task가 상한을 초과했습니다: $open_count > ${max_active:-5}"
  fi
  if [[ "$active_count" -le "${max_parallel:-2}" ]]; then
    report_ok "동시 Worker $active_count / 상한 ${max_parallel:-2}"
  else
    report_problem "동시 Worker가 상한을 초과했습니다: $active_count > ${max_parallel:-2}"
  fi

  # 6. Wave
  if [[ -n "$wave" ]]; then
    local wave_path wave_status
    wave_path="$root/.harness/waves/${wave}.yaml"
    if [[ ! -f "$wave_path" ]]; then
      report_problem "Wave 파일이 없습니다: $wave_path"
    else
      wave_status="$(yaml_scalar "$wave_path" status)"
      if [[ "$wave_status" == approved ]]; then
        report_ok "Wave $wave 승인됨"
      else
        report_problem "Wave $wave 가 승인되지 않았습니다 (status=$wave_status)"
      fi
    fi
  fi

  printf '\n'
  if [[ "$problems" -eq 0 ]]; then
    printf 'validate: 통과\n'
    return 0
  fi
  printf 'validate: %d개 문제\n' "$problems"
  return 1
}

# ---------------------------------------------------------------------------
# transition — 허용된 상태 전이만 수행한다. 판정을 대행하지 않는다.
# ---------------------------------------------------------------------------

transition_allowed() {
  local from="$1" to="$2"
  case "${from}>${to}" in
    'draft>ready') return 0 ;;
    'ready>active') return 0 ;;
    'active>submitted') return 0 ;;
    'active>blocked') return 0 ;;
    'active>handover_required') return 0 ;;
    'blocked>active') return 0 ;;
    'submitted>reviewing') return 0 ;;
    'reviewing>changes_requested') return 0 ;;
    'reviewing>awaiting_approval') return 0 ;;
    'changes_requested>ready') return 0 ;;
    'handover_required>ready') return 0 ;;
    'awaiting_approval>completed') return 0 ;;
    *) return 1 ;;
  esac
}

cmd_transition() {
  local root_arg="" task_id="" to_state="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) [[ $# -ge 2 ]] || die "--note 값이 필요합니다."; note="$2"; shift 2 ;;
      -h|--help)
        printf '사용법: %s transition PATH TASK_ID TO_STATE [--note TEXT]\n' "$SCRIPT_NAME"
        return 0 ;;
      -*) die "알 수 없는 transition 옵션: $1" ;;
      *)
        if [[ -z "$root_arg" ]]; then root_arg="$1"
        elif [[ -z "$task_id" ]]; then task_id="$1"
        elif [[ -z "$to_state" ]]; then to_state="$1"
        else die "인자가 너무 많습니다: $1"
        fi
        shift ;;
    esac
  done

  [[ -n "$root_arg" && -n "$task_id" && -n "$to_state" ]] ||
    die "사용법: $SCRIPT_NAME transition PATH TASK_ID TO_STATE"

  local root path from_state
  root="$(project_root "$root_arg")"
  path="$(task_file "$root" "$task_id")"
  valid_task_status "$to_state" || die "알 수 없는 목표 상태: $to_state"
  from_state="$(yaml_scalar "$path" status)"

  [[ "$from_state" != "$to_state" ]] || die "$task_id 는 이미 $to_state 입니다."
  transition_allowed "$from_state" "$to_state" ||
    die "허용되지 않은 전이입니다: $from_state -> $to_state ($task_id)"

  # --- 전이별 필수 조건 ---
  case "$to_state" in
    ready)
      local spec_state
      spec_state="$(awk -F': ' '/^- 상태:/{print $2; exit}' "$root/.harness/SPEC.md" 2>/dev/null || true)"
      [[ "$spec_state" == approved ]] ||
        die "SPEC이 승인되지 않았습니다 (현재 ${spec_state:-unknown}). .harness/SPEC.md의 '- 상태:'를 approved로 바꾸고 승인자를 기록하세요."
      ;;
    active)
      require_git_baseline "$root"
      ;;
    handover_required)
      compgen -G "$root/.harness/handovers/${task_id}-handover-*.md" >/dev/null ||
        die "Handover 기록이 없어 handover_required로 전이할 수 없습니다: .harness/handovers/${task_id}-handover-*.md  (harness-handover §3: 인계 문서를 먼저 작성한 뒤 전이한다)"
      ;;
    submitted)
      compgen -G "$root/.harness/attempts/${task_id}-attempt-*.md" >/dev/null ||
        die "Attempt 기록이 없어 submitted로 전이할 수 없습니다: .harness/attempts/${task_id}-attempt-*.md"
      compgen -G "$root/.harness/evidence/${task_id}-*.md" >/dev/null ||
        die "Evidence 기록이 없어 submitted로 전이할 수 없습니다: .harness/evidence/${task_id}-*.md"
      ;;
    reviewing)
      local worker reviewer
      worker="$(yaml_scalar "$path" primary_worker)"
      reviewer="$(yaml_scalar "$path" reviewer)"
      [[ "$worker" != "$reviewer" ]] ||
        die "Reviewer가 Worker와 같습니다 ($worker). 독립 Review가 성립하지 않습니다."
      ;;
    awaiting_approval)
      # 과거의 APPROVED가 남아 있어도 최신 Review가 반려면 통과시키지 않는다.
      local latest_review verdict
      latest_review="$(ls -1t "$root/.harness/reviews/${task_id}"-*.md 2>/dev/null | head -n 1 || true)"
      [[ -n "$latest_review" ]] ||
        die "Review 파일이 없습니다: .harness/reviews/${task_id}-*.md"
      # 줄 시작의 '판정:' 만 읽는다. Markdown 굵은 표시(**판정: X**)는 허용하되
      # focus 항목의 '- 판정: PASS / FAIL / NA' 같은 하위 줄은 매칭하지 않는다.
      verdict="$(sed -n 's/^\*\{0,2\}판정:[[:space:]]*\([A-Za-z_]*\).*/\1/p' "$latest_review" | head -n 1)"
      [[ "$verdict" == APPROVED ]] ||
        die "최신 Review의 판정이 APPROVED가 아닙니다 (${verdict:-없음}): $latest_review"
      ;;
    completed)
      local approval="$root/.harness/decisions/${task_id}-approval.md"
      [[ -f "$approval" ]] ||
        die "사용자 승인 기록이 없습니다: $approval  (Agent는 completed를 만들 수 없습니다)"
      grep -q '^승인:[[:space:]]*yes' "$approval" ||
        die "승인 기록에 '승인: yes' 줄이 없습니다: $approval"
      ;;
  esac

  # --- 원자적 갱신 ---
  local temporary
  temporary="$(mktemp "$(dirname "$path")/.harness-transition.XXXXXX")"
  trap "rm -f -- '$temporary'" RETURN
  awk -v to="$to_state" '
    !done_flag && index($0, "status:") == 1 { print "status: " to; done_flag = 1; next }
    { print }
  ' "$path" >"$temporary"
  grep -q "^status: ${to_state}$" "$temporary" || {
    rm -f "$temporary"
    die "status 갱신에 실패했습니다: $path"
  }
  chmod 0644 "$temporary"
  mv "$temporary" "$path"

  append_event "$root" transition "$task_id" "$from_state" "$to_state" "${note:-}"

  printf '%s: %s -> %s\n' "$task_id" "$from_state" "$to_state"

  # STATE.md 드리프트 안내 (스크립트가 산문을 대신 쓰지 않는다)
  if grep -q "| *${task_id} *|" "$root/.harness/STATE.md" 2>/dev/null; then
    grep -q "| *${task_id} *|.*| *${to_state} *|" "$root/.harness/STATE.md" ||
      info "STATE.md의 $task_id 행이 아직 $to_state 가 아닙니다. Orchestrator가 갱신하세요."
  fi
}

# ---------------------------------------------------------------------------
# 스텝 실행기 — dispatch / observe / close-agent / status --live
# 호출 1회 = 1스텝. 재시도, 상태 전이, failover, blocked 응답을 하지 않는다.
# ---------------------------------------------------------------------------

_runtime_require_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "잘못된 Task ID입니다: $1"
}

_runtime_atomic_copy() {
  local source="$1" destination="$2" parent temporary
  parent="$(dirname "$destination")"
  mkdir -p "$parent"
  temporary="$(mktemp "$parent/.runtime-write.XXXXXX")"
  if ! cp -- "$source" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$destination"
}

_runtime_atomic_text() {
  local destination="$1" value="$2" parent temporary
  parent="$(dirname "$destination")"
  mkdir -p "$parent"
  temporary="$(mktemp "$parent/.runtime-write.XXXXXX")"
  printf '%s\n' "$value" >"$temporary"
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$destination"
}

_runtime_json_field() {
  local input="$1" field="$2" value=""
  # herdr 호출은 전부 2>&1로 캡처한다. 경고 한 줄이 stderr에 섞여도 파싱이
  # 죽지 않도록, 첫 '{'부터 마지막 '}'까지만 남기고 자른다(BACKLOG.md #3).
  if [[ "$input" == *"{"* && "$input" == *"}"* ]]; then
    input="${input#*\{}"
    input="{${input}"
    input="${input%\}*}"
    input="${input}}"
  fi
  if command -v jq >/dev/null 2>&1; then
    value="$(printf '%s' "$input" | jq -r ".. | objects | .$field? // empty" 2>/dev/null | head -n 1 || true)"
  else
    # 앞쪽 탐욕적 .* 는 같은 키가 여러 번 나오면 마지막 값을 뽑는다(BACKLOG.md #2).
    # grep -o 로 겹치지 않는 첫 매치만 취해 jq 경로(첫 값)와 결과를 맞춘다.
    value="$(printf '%s' "$input" | tr -d '\n' \
      | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | head -n 1 \
      | sed -n 's/.*:[[:space:]]*"\([^"]*\)"/\1/p')"
  fi
  printf '%s' "$value"
}

_runtime_yaml_scalar() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      sub("^[[:space:]]*" key ":[[:space:]]*", "")
      gsub(/^['\''"]|['\''"]$/, "")
      print
      exit
    }
  ' "$file"
}

_runtime_yaml_block() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^" key ":[[:space:]]*" { found=1; print; next }
    found && /^[^[:space:]#][^:]*:/ { exit }
    found { print }
  ' "$file"
}

_runtime_has_secret() {
  LC_ALL=C grep -Eqi 'AKIA[0-9A-Z]{8,}|BEGIN[[:space:]]+(RSA |EC |OPENSSH )?PRIVATE KEY|password[[:space:]]*=|token[[:space:]]*=|api[_-]?key[[:space:]]*=' "$1"
}

# 쿼터 경고 신호 스캔. 자동으로 Provider를 바꾸지 않는다 — 확인만 하고 정보로
# 남긴다(ARCHITECTURE.md §8 "Provider 교체는 실패가 확인된 경우에만"). 못 찾으면
# 아무것도 출력하지 않는다: 감지 실패를 "쿼터 여유 있음"으로 착각하면 안 된다.
_runtime_scan_quota_signal() {
  local text="$1" pct
  pct="$(printf '%s' "$text" | grep -Eio '[0-9]+% of your (weekly|daily|five.hour) limit' | grep -Eo '^[0-9]+' | sort -n | head -n 1)"
  if [[ -n "$pct" ]]; then
    printf '남은 한도 %s%% 부근 경고 문구 감지("...%s%% of your ... limit")' "$pct" "$pct"
    return 0
  fi
  if printf '%s' "$text" | grep -Eqi 'usage limit reached|rate.?limit exceeded|quota.?exceeded|429 too many requests'; then
    printf '쿼터·Rate Limit 소진 문구 감지'
    return 0
  fi
  return 1
}

_runtime_next_attempt() {
  local root="$1" task_id="$2" path base number maximum=0
  shopt -s nullglob
  for path in "$root/.harness/attempts/$task_id-attempt-"*.md; do
    base="${path##*/}"
    number="${base#"$task_id-attempt-"}"
    number="${number%.md}"
    [[ "$number" =~ ^[0-9]+$ ]] || continue
    (( number > maximum )) && maximum="$number"
  done
  shopt -u nullglob
  printf '%s\n' "$((maximum + 1))"
}

_runtime_write_result() {
  local root="$1" task_id="$2" role="$3" result="$4"
  _runtime_atomic_text "$root/.harness/runtime/$task_id-$role.result" "$result"
}

_runtime_write_meta() {
  local root="$1" task_id="$2" role="$3" agent_name="$4" pane_id="$5" provider="$6" attempt="$7"
  local destination temporary
  destination="$root/.harness/runtime/$task_id-$role.meta"
  temporary="$(mktemp "$root/.harness/runtime/.meta.XXXXXX")"
  {
    printf 'task_id=%s\n' "$task_id"
    printf 'role=%s\n' "$role"
    printf 'agent_name=%s\n' "$agent_name"
    printf 'pane_id=%s\n' "$pane_id"
    printf 'provider=%s\n' "$provider"
    printf 'attempt=%s\n' "$attempt"
  } >"$temporary"
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$destination"
}

_runtime_meta_value() {
  local file="$1" key="$2"
  sed -n "s/^$key=//p" "$file" | head -n 1
}

# ---------------------------------------------------------------------------
# Task Lock — mkdir 기반 권고적(advisory) 잠금이다. SQLite Lease나 Fencing
# Token이 아니다: quota-retry/auto-step처럼 harness.sh를 거치는 자동화 경로
# 끼리만 같은 Task에 동시에 들어가는 것을 막는다. 사람이 같은 Task에
# 수동으로 dispatch/transition을 실행하는 것까지는 막지 않는다 — 자동
# 명령이 도는 동안은 `status --live`로 확인하고 수동 개입을 삼가야 한다.
# ---------------------------------------------------------------------------

_runtime_lock_dir() {
  printf '%s/.harness/runtime/%s.lock' "$1" "$2"
}

_runtime_lock_acquire() {
  local root="$1" task_id="$2" purpose="$3" stale_seconds="${4:-600}"
  local lock_dir holder pid acquired_at now acquired_epoch token
  lock_dir="$(_runtime_lock_dir "$root" "$task_id")"
  mkdir -p "$root/.harness/runtime"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    holder="$lock_dir/holder"
    if [[ ! -f "$holder" ]]; then
      printf 'Task Lock 디렉터리가 손상되었습니다: %s\n' "$lock_dir" >&2
      return 1
    fi
    pid="$(_runtime_meta_value "$holder" pid)"
    acquired_at="$(_runtime_meta_value "$holder" acquired_at)"
    now="$(date -u +%s)"
    acquired_epoch="$(date -u -d "$acquired_at" +%s 2>/dev/null || printf 0)"
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && (( now - acquired_epoch > stale_seconds )); then
      append_event "$root" lock_reclaim_stale "$task_id" "" "" "purpose=$purpose pid=$pid"
      rm -rf -- "$lock_dir"
      if ! mkdir "$lock_dir" 2>/dev/null; then
        printf 'Task Lock 획득에 실패했습니다(경합): %s\n' "$task_id" >&2
        return 1
      fi
    else
      printf 'Task가 다른 프로세스에 의해 잠겨 있습니다: %s (owner=%s pid=%s since=%s)\n' \
        "$task_id" "$(_runtime_meta_value "$holder" owner)" "$pid" "$acquired_at" >&2
      return 1
    fi
  fi
  token="$$-$(date -u +%s)-$RANDOM"
  local holder_content
  holder_content="$(printf 'owner=%s\npid=%s\nacquired_at=%s\ntoken=%s' \
    "$purpose" "$$" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$token")"
  _runtime_atomic_text "$lock_dir/holder" "$holder_content"
  printf '%s' "$token"
}

_runtime_lock_release() {
  local root="$1" task_id="$2" token="$3" lock_dir current_token
  lock_dir="$(_runtime_lock_dir "$root" "$task_id")"
  [[ -d "$lock_dir" ]] || return 0
  current_token="$(_runtime_meta_value "$lock_dir/holder" token 2>/dev/null || true)"
  [[ "$current_token" == "$token" ]] || return 0
  rm -rf -- "$lock_dir"
}

# 다음 Fallback Provider 계산: Task 자신의 fallback_chain에서 현재 Provider
# 다음 값(끝이면 처음 값으로 순환)을 고른다. dispatch/observe/transition을
# 재구현하지 않는 것과 같은 이유로, Provider를 실제로 갈아끼우는 로직은
# 여기 한 곳에만 둔다.
_runtime_next_fallback_provider() {
  local task_file="$1" current="$2"
  local -a chain=()
  local item
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    chain+=("$item")
  done < <(yaml_flow_list "$task_file" fallback_chain)
  (( ${#chain[@]} > 0 )) || return 1
  local i
  for ((i = 0; i < ${#chain[@]}; i++)); do
    if [[ "${chain[$i]}" == "$current" ]]; then
      if (( i + 1 < ${#chain[@]} )); then
        printf '%s' "${chain[$((i + 1))]}"
      else
        printf '%s' "${chain[0]}"
      fi
      return 0
    fi
  done
  printf '%s' "${chain[0]}"
}

# cmd_transition의 원자적 status 갱신과 같은 관용구(mktemp+awk+grep 검증+mv)
# 를 그대로 따른다. Task YAML의 primary_worker/reviewer 한 필드만 바꾼다.
_runtime_set_task_provider() {
  local task_file="$1" field="$2" new_provider="$3" temporary quote="'"
  temporary="$(mktemp "$(dirname "$task_file")/.harness-provider.XXXXXX")"
  trap "rm -f -- '$temporary'" RETURN
  awk -v key="$field" -v val="$new_provider" -v q="$quote" '
    !done_flag && index($0, key ":") == 1 { print key ": " q val q; done_flag = 1; next }
    { print }
  ' "$task_file" >"$temporary"
  grep -q "^${field}: '${new_provider}'$" "$temporary" || {
    rm -f "$temporary"
    die "Provider 갱신에 실패했습니다: $task_file"
  }
  chmod 0644 "$temporary"
  mv "$temporary" "$task_file"
}

_runtime_append_evidence() {
  local evidence="$1" addition="$2" temporary
  temporary="$(mktemp "$(dirname "$evidence")/.evidence.XXXXXX")"
  trap "rm -f -- '$temporary'" RETURN
  [[ ! -f "$evidence" ]] || cp -- "$evidence" "$temporary"
  cat -- "$addition" >>"$temporary"
  if _runtime_has_secret "$temporary"; then
    : >"$temporary"
    printf '# Evidence withheld\n\n경고: Secret 의심 패턴이 발견되어 원문을 저장하지 않았습니다.\n' >"$temporary"
  fi
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$evidence"
}

_runtime_normalize_state() {
  local get_status="$1" get_output="$2" prompt_status="${3:-0}" prompt_output="${4:-}"
  local state combined
  combined="$prompt_output $get_output"
  # Agent가 실제로 사라졌으면 stalled보다 agent_lost가 더 실행 가능한 정보다.
  if (( get_status != 0 )); then
    printf 'agent_lost'
    return
  fi
  if printf '%s' "$combined" | grep -qi 'agent_prompt_stalled'; then
    printf 'stalled'
    return
  fi
  if (( prompt_status != 0 )) && printf '%s' "$combined" | grep -Eqi 'timed?[ -]?out|timeout'; then
    printf 'timeout'
    return
  fi
  state="$(_runtime_json_field "$get_output" agent_status)"
  case "$state" in
    idle|done) printf 'settled' ;;
    blocked) printf 'blocked' ;;
    *) printf 'error' ;;
  esac
}

_runtime_spec_section() {
  # init이 만드는 SPEC.md는 "## N. 제목" 형식의 고정 섹션 7개로 구성된다.
  # 번호(N)로 매칭해 그 섹션을 다음 "## " 헤더 전까지 그대로 출력한다.
  local file="$1" number="$2"
  awk -v n="$number" '
    $0 ~ "^## " n "\\." { printing=1 }
    printing && /^## / && $0 !~ "^## " n "\\." { exit }
    printing { print }
  ' "$file"
}

_runtime_context_packet() {
  local root="$1" task_id="$2" role="$3" task_file="$4" destination="$5"
  local temporary spec_file
  temporary="$(mktemp "$root/.harness/runtime/.context.XXXXXX")"
  trap "rm -f -- '$temporary'" RETURN
  spec_file="$root/.harness/SPEC.md"
  {
    printf '# Context Packet: %s / %s\n\n' "$task_id" "$role"
    printf '## Specification excerpt\n\n'
    if [[ -f "$spec_file" ]]; then
      # 줄 수로 자르지 않는다(200줄을 넘으면 Acceptance Criteria·제약이 통째로
      # 빠지던 결함 — BACKLOG.md #5). 실행에 필요한 절만 번호로 골라 전부 담는다.
      local section_number
      for section_number in 1 3 4 5 6; do
        _runtime_spec_section "$spec_file" "$section_number"
        printf '\n'
      done
    fi
    printf '\n## Task Contract\n\n'
    cat "$task_file"
    printf '\n## Write scope\n\n'
    _runtime_yaml_block "$task_file" write_scope
    printf '\n## References and inputs\n\n'
    _runtime_yaml_block "$task_file" resources
    _runtime_yaml_block "$task_file" inputs
    printf '\n## Verification commands and criteria\n\n'
    _runtime_yaml_block "$task_file" acceptance_criteria
    printf '\n## Next step\n\n'
    if [[ "$role" == worker ]]; then
      printf '이 Task만 수행하고 검증 결과와 Attempt 산출물을 남긴 뒤 submitted를 제안한다. 상태를 직접 전이하거나 completed로 만들지 않는다.\n'
    else
      printf 'Diff, Task Criteria와 Evidence를 읽기 전용으로 검토하고 Review 산출물에 판정과 근거를 기록한다. 소스와 Task 상태를 수정하지 않는다.\n'
    fi
  } >"$temporary"
  if _runtime_has_secret "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  _runtime_atomic_copy "$temporary" "$destination"
  rm -f -- "$temporary"
}

_runtime_start_agent_when_ready() {
  # 분할 직후 Pane은 Herdr가 "available shell"로 인정하기까지 수 초가 걸린다.
  # 측정 결과 4~7초. 그동안 agent start는 agent_pane_busy로 실패한다.
  # 이 대기는 Pane 준비 조건만 재확인하며, 실패한 Agent 턴을 재시도하지 않는다.
  local agent_name="$1" provider="$2" pane_id="$3" timeout="$4"
  local deadline_s="${5:-30}"
  local waited=0 output status
  while :; do
    set +e
    output="$(herdr agent start "$agent_name" --kind "$provider" --pane "$pane_id" --timeout "$timeout" 2>&1)"
    status=$?
    set -e
    if (( status == 0 )); then
      printf '%s' "$output"
      return 0
    fi
    if ! printf '%s' "$output" | grep -q 'agent_pane_busy'; then
      printf '%s' "$output"
      return "$status"
    fi
    if (( waited >= deadline_s * 2 )); then
      printf '%s' "$output"
      return "$status"
    fi
    sleep 0.5
    waited=$((waited + 1))
  done
}

cmd_dispatch() {
  local path="${1:-}" task_id="${2:-}" role="${3:-}" timeout=120000
  [[ -n "$path" && -n "$task_id" && -n "$role" ]] || die "사용법: dispatch PATH TASK_ID ROLE(worker|reviewer) [--timeout MS]"
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--timeout에는 양의 밀리초가 필요합니다."; timeout="$2"; shift 2 ;;
      *) die "알 수 없는 dispatch 옵션: $1" ;;
    esac
  done
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"

  local root task_file runtime_dir context provider attempt started_at baseline
  local pane_output pane_status pane_id agent_name start_output start_status
  local prompt_output prompt_status get_output get_status read_output read_status result
  local attempt_file evidence_file temporary
  root="$(project_root "$path")"
  task_file="$root/.harness/tasks/$task_id.yaml"
  [[ -f "$task_file" ]] || die "Task YAML을 찾을 수 없습니다: $task_file"
  command -v herdr >/dev/null 2>&1 || die "herdr 명령을 찾을 수 없습니다."
  [[ "${HERDR_ENV:-}" == 1 ]] || die "dispatch는 Herdr Pane 안에서 실행해야 합니다."
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Git 저장소가 아닙니다: $root"

  runtime_dir="$root/.harness/runtime"
  mkdir -p "$runtime_dir" "$root/.harness/attempts" "$root/.harness/evidence"
  context="$runtime_dir/$task_id-context-$role.md"
  if ! _runtime_context_packet "$root" "$task_id" "$role" "$task_file" "$context"; then
    _runtime_write_result "$root" "$task_id" "$role" error
    printf '경고: Context Packet에서 Secret 의심 패턴이 발견되어 저장하거나 전송하지 않았습니다.\n' >&2
    printf 'dispatch_result=error\n'
    return 1
  fi

  if [[ "$role" == worker ]]; then
    provider="$(_runtime_yaml_scalar "$task_file" primary_worker)"
  else
    provider="$(_runtime_yaml_scalar "$task_file" reviewer)"
  fi
  [[ "$provider" =~ ^(claude|codex|agy)$ ]] || die "Task의 Provider가 유효하지 않습니다: $provider"
  attempt="$(_runtime_next_attempt "$root" "$task_id")"
  started_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  baseline="$(git -C "$root" rev-parse HEAD 2>/dev/null || printf 'unborn')"
  local task_slug="${task_id,,}"
  agent_name="hh-${task_slug//[^a-z0-9_-]/-}-${role:0:1}-$attempt"
  agent_name="${agent_name:0:32}"
  [[ "$agent_name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "생성된 Agent 이름이 유효하지 않습니다: $agent_name"

  set +e
  pane_output="$(herdr pane split --current --direction right --cwd "$root" --no-focus 2>&1)"
  pane_status=$?
  set -e
  if (( pane_status != 0 )); then
    _runtime_write_result "$root" "$task_id" "$role" error
    printf '%s\n' "$pane_output" >&2
    printf 'dispatch_result=error\n'
    return 1
  fi
  pane_id="$(_runtime_json_field "$pane_output" pane_id)"
  [[ -n "$pane_id" ]] || die "Herdr Pane ID를 추출하지 못했습니다."

  _runtime_write_meta "$root" "$task_id" "$role" "$agent_name" "$pane_id" "$provider" "$attempt"
  attempt_file="$root/.harness/attempts/$task_id-attempt-$attempt.md"
  temporary="$(mktemp "$root/.harness/attempts/.attempt.XXXXXX")"
  {
    printf '# Attempt %s: %s\n\n' "$attempt" "$task_id"
    printf -- '- Started: %s\n- Role: %s\n- Provider: %s\n- Pane ID: %s\n- Agent name: %s\n- Baseline commit: %s\n' "$started_at" "$role" "$provider" "$pane_id" "$agent_name" "$baseline"
  } >"$temporary"
  _runtime_atomic_copy "$temporary" "$attempt_file"
  rm -f -- "$temporary"

  set +e
  start_output="$(_runtime_start_agent_when_ready "$agent_name" "$provider" "$pane_id" "$timeout")"
  start_status=$?
  set -e
  if (( start_status != 0 )); then
    result=error
    get_output=""
    get_status=1
    prompt_output="$start_output"
    prompt_status="$start_status"
    read_output=""
    read_status=1
  else
    set +e
    prompt_output="$(herdr agent prompt "$agent_name" "$(cat "$context")" --wait --timeout "$timeout" 2>&1)"
    prompt_status=$?
    get_output="$(herdr agent get "$agent_name" 2>&1)"
    get_status=$?
    read_output="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 200 2>&1)"
    read_status=$?
    set -e
    result="$(_runtime_normalize_state "$get_status" "$get_output" "$prompt_status" "$prompt_output")"
  fi

  local quota_signal
  quota_signal="$(_runtime_scan_quota_signal "$prompt_output"$'\n'"$read_output" || true)"

  evidence_file="$root/.harness/evidence/$task_id-$role-attempt-$attempt.md"
  temporary="$(mktemp "$root/.harness/evidence/.capture.XXXXXX")"
  {
    printf '# Evidence: %s / %s / Attempt %s\n\n' "$task_id" "$role" "$attempt"
    printf -- '- Captured: %s\n- Dispatch result: %s\n- Prompt exit: %s\n- Agent get exit: %s\n- Agent read exit: %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$result" "$prompt_status" "$get_status" "$read_status"
    printf '## Git status --short\n\n'
    git -C "$root" status --short 2>&1 || true
    printf '\n## Git diff --stat\n\n'
    git -C "$root" diff --stat 2>&1 || true
    printf '\n## Agent state\n\n%s\n' "$get_output"
    printf '\n## Dispatch 명령 출력\n\n%s\n' "$prompt_output"
    printf '\n## Agent output\n\n%s\n' "$read_output"
    if [[ -n "$quota_signal" ]]; then
      printf '\n## 쿼터 신호(자동 감지 — 확정 아님)\n\n%s\n\n실패로 확정되지 않았으므로 이 신호만으로 Provider를 바꾸지 않는다. `herdr-harness quota-check`로 확인 후 판단한다.\n' "$quota_signal"
    fi
  } >"$temporary"
  if _runtime_has_secret "$temporary"; then
    : >"$temporary"
    printf '# Evidence withheld\n\n경고: Secret 의심 패턴이 발견되어 원문을 저장하지 않았습니다.\n' >"$temporary"
    printf '경고: Agent 출력에서 Secret 의심 패턴이 발견되어 Evidence 원문을 저장하지 않았습니다.\n' >&2
  fi
  _runtime_atomic_copy "$temporary" "$evidence_file"
  rm -f -- "$temporary"
  _runtime_write_result "$root" "$task_id" "$role" "$result"
  printf 'dispatch_result=%s\n' "$result"
  [[ "$result" == settled || "$result" == blocked ]]
}

cmd_observe() {
  local path="${1:-}" task_id="${2:-}" role="${3:-worker}"
  [[ -n "$path" && -n "$task_id" ]] || die "사용법: observe PATH TASK_ID [ROLE]"
  [[ $# -le 3 ]] || die "사용법: observe PATH TASK_ID [ROLE]"
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"
  local root meta agent_name pane_id attempt evidence addition get_output get_status read_output read_status result
  root="$(project_root "$path")"
  meta="$root/.harness/runtime/$task_id-$role.meta"
  [[ -f "$meta" ]] || die "Runtime 기록을 찾을 수 없습니다: $meta"
  agent_name="$(_runtime_meta_value "$meta" agent_name)"
  pane_id="$(_runtime_meta_value "$meta" pane_id)"
  attempt="$(_runtime_meta_value "$meta" attempt)"
  [[ -n "$agent_name" && -n "$pane_id" && "$attempt" =~ ^[0-9]+$ ]] || die "Runtime 기록이 손상되었습니다: $meta"
  set +e
  get_output="$(herdr agent get "$agent_name" 2>&1)"
  get_status=$?
  read_output="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 200 2>&1)"
  read_status=$?
  set -e
  result="$(_runtime_normalize_state "$get_status" "$get_output" 0 "")"
  local quota_signal
  quota_signal="$(_runtime_scan_quota_signal "$read_output" || true)"
  evidence="$root/.harness/evidence/$task_id-$role-attempt-$attempt.md"
  addition="$(mktemp "$root/.harness/evidence/.observe.XXXXXX")"
  {
    printf '\n## Observation %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Result: %s\n- Pane ID: %s\n- Agent get exit: %s\n- Agent read exit: %s\n\n' "$result" "$pane_id" "$get_status" "$read_status"
    printf '### Agent state\n\n%s\n\n### Agent output\n\n%s\n' "$get_output" "$read_output"
    if [[ -n "$quota_signal" ]]; then
      printf '\n### 쿼터 신호(자동 감지 — 확정 아님)\n\n%s\n' "$quota_signal"
    fi
  } >"$addition"
  _runtime_append_evidence "$evidence" "$addition"
  rm -f -- "$addition"
  _runtime_write_result "$root" "$task_id" "$role" "$result"
  printf 'observe_result=%s\n' "$result"
}

cmd_close_agent() {
  local path="${1:-}" task_id="${2:-}" role=worker force=0
  [[ -n "$path" && -n "$task_id" ]] || die "사용법: close-agent PATH TASK_ID [ROLE] [--force]"
  shift 2
  if [[ $# -gt 0 && "$1" != --force ]]; then role="$1"; shift; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in --force) force=1 ;; *) die "알 수 없는 close-agent 옵션: $1" ;; esac
    shift
  done
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"
  local root meta agent_name pane_id get_output get_status state close_output close_status
  root="$(project_root "$path")"
  meta="$root/.harness/runtime/$task_id-$role.meta"
  [[ -f "$meta" ]] || die "Harness Runtime 기록이 없어 Pane 정리를 거부합니다: $meta"
  agent_name="$(_runtime_meta_value "$meta" agent_name)"
  pane_id="$(_runtime_meta_value "$meta" pane_id)"
  [[ -n "$agent_name" && -n "$pane_id" ]] || die "Runtime 기록이 손상되었습니다: $meta"
  set +e
  get_output="$(herdr agent get "$agent_name" 2>&1)"
  get_status=$?
  set -e
  if (( get_status == 0 )); then
    state="$(_runtime_json_field "$get_output" agent_status)"
    [[ "$state" != working || "$force" -eq 1 ]] || die "Agent가 working 상태입니다. --force 없이는 닫지 않습니다: $agent_name"
  fi
  set +e
  close_output="$(herdr pane close "$pane_id" 2>&1)"
  close_status=$?
  set -e
  if (( close_status != 0 )); then
    printf '%s\n' "$close_output" >&2
    die "Harness Pane 정리에 실패했습니다: $pane_id"
  fi
  _runtime_atomic_text "$root/.harness/runtime/$task_id-$role.closed" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  info "Agent Pane 정리 완료: $agent_name ($pane_id)"
}

_runtime_state_tasks() {
  local state_file="$1"
  awk -F'|' '
    /^\|/ && NF >= 6 {
      task=$2; status=$6
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", task)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
      if (task != "Task" && task !~ /^-+$/ && task != "") print task "\t" status
    }
  ' "$state_file"
}

cmd_quota_check() {
  # 능동 쿼터 확인. agy는 --print "/usage"로 바로 조회하지만 claude·codex는
  # 비대화형 조회 수단이 없어 이미 떠 있는 Agent Pane에 "/status"를 보내 읽는다
  # (그래서 claude·codex는 TASK_ID ROLE로 실행 중인 Agent를 지정해야 한다).
  # 자동으로 아무것도 바꾸지 않는다 — 결과를 evidence에 남기고 판단은 사람 몫이다.
  local path="${1:-}" task_id="" role="" provider="" root
  [[ -n "$path" ]] || die "사용법: quota-check PATH TASK_ID ROLE(worker|reviewer) | quota-check PATH --provider PROVIDER"
  shift
  if [[ "${1:-}" == --provider ]]; then
    [[ $# -ge 2 ]] || die "--provider 값이 필요합니다."
    provider="$2"
  else
    task_id="${1:-}"; role="${2:-}"
    [[ -n "$task_id" && -n "$role" ]] || die "사용법: quota-check PATH TASK_ID ROLE(worker|reviewer) | quota-check PATH --provider PROVIDER"
    [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
    _runtime_require_id "$task_id"
  fi
  root="$(project_root "$path")"

  if [[ -z "$provider" ]]; then
    local task_file
    task_file="$root/.harness/tasks/$task_id.yaml"
    [[ -f "$task_file" ]] || die "Task YAML을 찾을 수 없습니다: $task_file"
    if [[ "$role" == worker ]]; then
      provider="$(_runtime_yaml_scalar "$task_file" primary_worker)"
    else
      provider="$(_runtime_yaml_scalar "$task_file" reviewer)"
    fi
  fi
  [[ "$provider" =~ ^(claude|codex|agy)$ ]] || die "Provider가 유효하지 않습니다: $provider"

  # low_warning_threshold_pct는 quota-policy.yaml이 정본이다 — 여기 상수를
  # 못박지 않는다(설정과 코드가 따로 노는 함정을 피한다). 정책 파일이나 키가
  # 없으면 25로 물러난다.
  local low_threshold=25 policy_file
  policy_file="$root/.harness/policies/quota-policy.yaml"
  if [[ -f "$policy_file" ]]; then
    local configured
    configured="$(_runtime_yaml_scalar "$policy_file" low_warning_threshold_pct || true)"
    [[ "$configured" =~ ^[0-9]+$ ]] && low_threshold="$configured"
  fi

  local output status status_word=unknown detail min_pct evidence_file addition
  case "$provider" in
    agy)
      command -v agy >/dev/null 2>&1 || die "agy 명령을 찾을 수 없습니다."
      set +e
      output="$(agy --print "/usage" 2>&1)"
      status=$?
      set -e
      if (( status == 0 )); then
        # 탭 구분 표: <모델군> <지표명> <남은%> <초기화시각>. 세 번째 열의
        # 최솟값을 대표값으로 쓰되, 전체 표는 evidence에 그대로 남긴다.
        min_pct="$(printf '%s\n' "$output" | awk -F'\t' '
          NF>=3 { v=$3; gsub(/%/,"",v); v=v+0; if (seen==0 || v<min) { min=v; seen=1 } }
          END { if (seen==1) print min }
        ')"
        if [[ -n "$min_pct" ]]; then
          detail="최소 남은 한도 ${min_pct}%(임계값 ${low_threshold}%, agy --print /usage 전체 내역은 evidence 참고)"
          if (( min_pct < low_threshold )); then status_word=low; else status_word=ok; fi
        else
          detail="agy --print /usage 출력 형식을 해석하지 못했습니다(원문은 evidence 참고)"
        fi
      else
        detail="agy --print /usage 호출 실패(exit $status)"
      fi
      ;;
    claude|codex)
      [[ -n "$task_id" ]] || die "claude/codex 쿼터 확인은 실행 중인 Task Agent가 필요합니다: quota-check PATH TASK_ID ROLE"
      command -v herdr >/dev/null 2>&1 || die "herdr 명령을 찾을 수 없습니다."
      [[ "${HERDR_ENV:-}" == 1 ]] || die "quota-check(claude/codex)는 Herdr Pane 안에서 실행해야 합니다."
      local meta agent_name
      meta="$root/.harness/runtime/$task_id-$role.meta"
      [[ -f "$meta" ]] || die "Runtime 기록을 찾을 수 없습니다(먼저 dispatch로 Agent를 띄우세요): $meta"
      agent_name="$(_runtime_meta_value "$meta" agent_name)"
      [[ -n "$agent_name" ]] || die "Runtime 기록이 손상되었습니다: $meta"
      set +e
      herdr agent prompt "$agent_name" "/status" --wait --timeout 30000 >/dev/null 2>&1
      output="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 80 2>&1)"
      status=$?
      set -e
      local scan
      scan="$(_runtime_scan_quota_signal "$output" || true)"
      if [[ -n "$scan" ]]; then
        detail="$scan"
        status_word=low
      else
        detail="/status 출력에서 알려진 경고 문구를 못 찾음 — 여유가 있거나 문구 형식이 다른 것일 수 있다(원문은 evidence 참고)"
      fi
      ;;
  esac

  if [[ -n "$task_id" ]]; then
    evidence_file="$root/.harness/evidence/$task_id-$role-quota.md"
    # quota-retry가 참고하는 연속 low 판정 스트릭. low가 아니면 스트릭을
    # 끊는다 — "연속" 판정만 인정한다(오탐 한 번에 반응하지 않기 위함).
    local streak_file="$root/.harness/runtime/$task_id-$role.quota-streak"
    if [[ "$status_word" == low ]]; then
      local prev_count=0 first_low_at="" streak_content
      if [[ -f "$streak_file" ]]; then
        prev_count="$(_runtime_meta_value "$streak_file" count)"
        first_low_at="$(_runtime_meta_value "$streak_file" first_low_at)"
      fi
      [[ "$prev_count" =~ ^[0-9]+$ ]] || prev_count=0
      [[ -n "$first_low_at" ]] || first_low_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
      streak_content="$(printf 'count=%s\nfirst_low_at=%s\nlast_low_at=%s' \
        "$((prev_count + 1))" "$first_low_at" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')")"
      mkdir -p "$root/.harness/runtime"
      _runtime_atomic_text "$streak_file" "$streak_content"
    else
      rm -f -- "$streak_file"
    fi
  else
    evidence_file="$root/.harness/evidence/quota-$provider.md"
  fi
  mkdir -p "$root/.harness/evidence"
  addition="$(mktemp "$root/.harness/evidence/.quota.XXXXXX")"
  {
    printf '## 쿼터 확인 %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Provider: %s\n- 판정: %s\n- 근거: %s\n\n' "$provider" "$status_word" "$detail"
    printf '### 원문\n\n%s\n' "$output"
  } >"$addition"
  _runtime_append_evidence "$evidence_file" "$addition"
  rm -f -- "$addition"

  printf 'quota_check: provider=%s status=%s detail=%s\n' "$provider" "$status_word" "$detail"
}

# ---------------------------------------------------------------------------
# quota-retry — opt-in. 연속 저쿼터가 확인되면 Provider를 fallback_chain의
# 다음 값으로 바꾸고 handover_required까지 자동 전이한다. 거기서 멈춘다:
# ready로 재개하려면 사람이 .harness/decisions/TASK-failover-approval.md에
# "승인: yes"를 쓴 뒤 herdr-harness transition을 직접 실행해야 한다.
# cmd_transition/cmd_close_agent를 그대로 호출하므로 두 함수의 모든
# 전제조건(예: submitted에 필요한 Attempt/Evidence, working Agent 보호)을
# 그대로 물려받는다 — 이 함수는 재구현하지 않는다.
# ---------------------------------------------------------------------------

cmd_quota_retry() {
  local path="${1:-}" task_id="${2:-}" role="${3:-}"
  [[ -n "$path" && -n "$task_id" && -n "$role" && $# -eq 3 ]] ||
    die "사용법: quota-retry PATH TASK_ID ROLE(worker|reviewer)"
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"

  local root task_file policy_file
  root="$(project_root "$path")"
  task_file="$root/.harness/tasks/$task_id.yaml"
  [[ -f "$task_file" ]] || die "Task YAML을 찾을 수 없습니다: $task_file"

  policy_file="$root/.harness/policies/quota-policy.yaml"
  [[ -f "$policy_file" ]] || die "quota-policy.yaml이 없습니다: $policy_file"
  local automatic_failover
  automatic_failover="$(_runtime_yaml_scalar "$policy_file" automatic_failover)"
  [[ "$automatic_failover" == "true" ]] ||
    die "automatic_failover가 꺼져 있습니다(.harness/policies/quota-policy.yaml). quota-retry는 opt-in 기능입니다."

  local task_status
  task_status="$(yaml_scalar "$task_file" status)"
  [[ "$task_status" == active ]] ||
    die "Task 상태가 active가 아닙니다(현재 $task_status). quota-retry는 active Task에만 적용됩니다."

  local used_marker="$root/.harness/runtime/$task_id-$role.auto-retry-used"
  [[ ! -f "$used_marker" ]] ||
    die "이 Task/Role에는 이미 자동 재시도를 1회 사용했습니다(flapping 방지). handover_required로 전이한 뒤 사람이 직접 처리하세요: $used_marker"

  local confirm_needed=2 cooldown=300 stale_seconds=600 configured
  configured="$(_runtime_yaml_scalar "$policy_file" low_confirm_count)"
  [[ "$configured" =~ ^[0-9]+$ ]] && confirm_needed="$configured"
  configured="$(_runtime_yaml_scalar "$policy_file" cooldown_seconds)"
  [[ "$configured" =~ ^[0-9]+$ ]] && cooldown="$configured"
  configured="$(_runtime_yaml_scalar "$policy_file" stale_lock_seconds)"
  [[ "$configured" =~ ^[0-9]+$ ]] && stale_seconds="$configured"

  local streak_file="$root/.harness/runtime/$task_id-$role.quota-streak"
  [[ -f "$streak_file" ]] ||
    die "연속 저쿼터 기록이 없습니다. 먼저 herdr-harness quota-check PATH $task_id $role 을 실행하세요: $streak_file"
  local streak_count last_low_at first_low_at
  streak_count="$(_runtime_meta_value "$streak_file" count)"
  last_low_at="$(_runtime_meta_value "$streak_file" last_low_at)"
  first_low_at="$(_runtime_meta_value "$streak_file" first_low_at)"
  [[ "$streak_count" =~ ^[0-9]+$ ]] || streak_count=0
  (( streak_count >= confirm_needed )) ||
    die "연속 저쿼터 판정이 부족합니다($streak_count/$confirm_needed). quota-check를 다시 실행해 확인하세요."
  if [[ -n "$first_low_at" && -n "$last_low_at" ]]; then
    local first_epoch last_epoch
    first_epoch="$(date -u -d "$first_low_at" +%s 2>/dev/null || printf 0)"
    last_epoch="$(date -u -d "$last_low_at" +%s 2>/dev/null || printf 0)"
    (( last_epoch - first_epoch >= cooldown )) ||
      die "연속 저쿼터 판정 간격이 cooldown(${cooldown}초)보다 짧습니다. 시간을 두고 quota-check를 다시 실행하세요."
  fi

  local token
  token="$(_runtime_lock_acquire "$root" "$task_id" quota-retry "$stale_seconds")" ||
    die "Task Lock 획득에 실패했습니다: $task_id"
  trap "_runtime_lock_release '$root' '$task_id' '$token'" EXIT INT TERM

  append_event "$root" quota_retry_start "$task_id" "$task_status" "" "role=$role"

  cmd_close_agent "$root" "$task_id" "$role" --force

  local role_key current_provider next_provider
  if [[ "$role" == worker ]]; then role_key=primary_worker; else role_key=reviewer; fi
  current_provider="$(_runtime_yaml_scalar "$task_file" "$role_key")"
  next_provider="$(_runtime_next_fallback_provider "$task_file" "$current_provider")" ||
    die "Task의 fallback_chain에서 다음 Provider를 찾지 못했습니다: $task_file"

  _runtime_set_task_provider "$task_file" "$role_key" "$next_provider"

  # handover_required 진입 게이트(cmd_transition)가 Handover 문서를 요구한다.
  # harness-handover §3의 "문서 작성 → 전이" 순서대로, 전이 직전에 stub을 남긴다.
  # (자동 경로가 인계 문맥 없이 원작업자를 종료하던 결함 — BACKLOG 9-3-3)
  local handover_n=1 existing hb_num handover_file
  shopt -s nullglob
  for existing in "$root/.harness/handovers/$task_id-handover-"*.md; do
    hb_num="${existing##*-handover-}"; hb_num="${hb_num%.md}"
    [[ "$hb_num" =~ ^[0-9]+$ ]] && (( hb_num >= handover_n )) && handover_n=$(( hb_num + 1 ))
  done
  shopt -u nullglob
  handover_file="$root/.harness/handovers/$task_id-handover-$handover_n.md"
  {
    printf '# Handover: %s-handover-%s\n\n' "$task_id" "$handover_n"
    printf '## 메타데이터\n'
    printf -- '- Task ID: %s\n- Handover 번호: %s\n- 인계 일시: %s\n' \
      "$task_id" "$handover_n" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- 원작업자 (Source): %s\n- 수신자 (Target): %s\n- 인계 사유: quota_exhausted\n\n' \
      "$current_provider" "$next_provider"
    printf '`quota-retry`가 자동 생성한 stub이다. 연속 저쿼터 확인(count>=%s) 후 %s(%s) Provider를 %s → %s로 교체했다. 세부 내용은 사람이 %s 규격에 맞춰 보완한다.\n\n' \
      "$confirm_needed" "$task_id" "$role" "$current_provider" "$next_provider" ".harness/handovers/TEMPLATE.md"
    printf '## 2. 미완료 작업 및 작업 트리 상태 (Pending Work & Git State)\n\n- `git status --short`:\n```text\n'
    git -C "$root" status --short 2>&1 || true
    printf '```\n- `git diff --stat`:\n```text\n'
    git -C "$root" diff --stat 2>&1 || true
    printf '```\n\n## 5. 다음 담당자를 위한 즉각적 행동 지침 (Next Single Action)\n\n'
    printf '사람이 `.harness/decisions/%s-failover-approval.md`에 "승인: yes"를 기록한 뒤 `herdr-harness transition %s %s ready`를 직접 실행한다. 그 전까지 재개하지 않는다.\n' \
      "$task_id" "$path" "$task_id"
  } >"$handover_file"
  chmod 0644 "$handover_file"

  cmd_transition "$root" "$task_id" handover_required --note "quota-retry: $current_provider -> $next_provider (handover $handover_n)"

  _runtime_atomic_text "$used_marker" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  rm -f -- "$streak_file"

  append_event "$root" quota_retry_done "$task_id" "$task_status" handover_required "provider $current_provider -> $next_provider"

  printf 'quota_retry: %s(%s) provider %s -> %s, 상태 handover_required (handover stub: %s)\n' \
    "$task_id" "$role" "$current_provider" "$next_provider" "${handover_file#"$root/"}"
  printf '다음 단계(사람 몫): handover stub을 확인·보완하고, .harness/decisions/%s-failover-approval.md 에 "승인: yes"를 쓴 뒤 herdr-harness transition %s %s ready 를 직접 실행하세요.\n' \
    "$task_id" "$path" "$task_id"
}

# ---------------------------------------------------------------------------
# auto-step — opt-in. 유한 턴(정책 상한 이하) 동안만 동작하는 스텝 실행기다.
# 상주 루프가 아니다: 호출 1회가 반드시 끝난다. Turn 1에서만 dispatch로
# Pane 하나를 새로 만들고, 이후 턴은 그 같은 Agent를 observe로만 재조회한다
# (dispatch를 반복하면 매번 새 Pane이 생겨 이전 Pane이 고아가 된다 — 그래서
# 반복하지 않는다). settled/blocked/agent_lost/error 중 하나에 도달하면
# 판단을 사람에게 넘기고 즉시 멈춘다. reviewing·awaiting_approval·completed
# 로 이어지는 호출은 이 함수 안에 존재하지 않는다.
# ---------------------------------------------------------------------------

cmd_auto_step() {
  local path="${1:-}" task_id="${2:-}" max_turns=0
  [[ -n "$path" && -n "$task_id" ]] || die "사용법: auto-step PATH TASK_ID [--max-turns N]"
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-turns)
        [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--max-turns에는 양의 정수가 필요합니다."
        max_turns="$2"; shift 2 ;;
      *) die "알 수 없는 auto-step 옵션: $1" ;;
    esac
  done
  _runtime_require_id "$task_id"

  local root task_file policy_file
  root="$(project_root "$path")"
  task_file="$root/.harness/tasks/$task_id.yaml"
  [[ -f "$task_file" ]] || die "Task YAML을 찾을 수 없습니다: $task_file"

  policy_file="$root/.harness/policies/loop-policy.yaml"
  [[ -f "$policy_file" ]] || die "loop-policy.yaml이 없습니다: $policy_file"
  local enabled
  enabled="$(_runtime_yaml_scalar "$policy_file" enabled)"
  [[ "$enabled" == "true" ]] ||
    die "auto-step가 꺼져 있습니다(.harness/policies/loop-policy.yaml). opt-in 기능입니다."

  local ceiling=5 stale_seconds=600 configured
  configured="$(_runtime_yaml_scalar "$policy_file" max_turns_ceiling)"
  [[ "$configured" =~ ^[0-9]+$ ]] && ceiling="$configured"
  configured="$(_runtime_yaml_scalar "$policy_file" stale_lock_seconds)"
  [[ "$configured" =~ ^[0-9]+$ ]] && stale_seconds="$configured"
  [[ "$max_turns" -gt 0 ]] || max_turns="$ceiling"
  (( max_turns <= ceiling )) ||
    die "--max-turns($max_turns)이 정책 상한(max_turns_ceiling=$ceiling)을 넘었습니다."

  local task_status
  task_status="$(yaml_scalar "$task_file" status)"
  case "$task_status" in
    ready|active) ;;
    *) die "Task 상태가 ready/active가 아닙니다(현재 $task_status). auto-step은 이 두 상태에서만 동작합니다." ;;
  esac

  local token
  token="$(_runtime_lock_acquire "$root" "$task_id" auto-step "$stale_seconds")" ||
    die "Task Lock 획득에 실패했습니다: $task_id"
  trap "_runtime_lock_release '$root' '$task_id' '$token'" EXIT INT TERM

  if [[ "$task_status" == ready ]]; then
    cmd_transition "$root" "$task_id" active --note "auto-step"
  fi

  local turn=1 result
  set +e
  result="$(cmd_dispatch "$root" "$task_id" worker)"
  set -e
  result="${result#*dispatch_result=}"
  append_event "$root" auto_step_turn "$task_id" active "$result" "turn=$turn/$max_turns action=dispatch"

  local continue_states=" stalled timeout "
  while :; do
    if [[ "$continue_states" != *" $result "* ]]; then
      printf 'auto_step: turn=%s result=%s — 정지(사람 확인 필요)\n' "$turn" "$result"
      return 0
    fi
    if (( turn >= max_turns )); then
      printf 'auto_step: max_turns(%s) 소진, 마지막 result=%s — 정지\n' "$max_turns" "$result"
      return 0
    fi
    turn=$((turn + 1))
    set +e
    result="$(cmd_observe "$root" "$task_id" worker)"
    set -e
    result="${result#*observe_result=}"
    append_event "$root" auto_step_turn "$task_id" active "$result" "turn=$turn/$max_turns action=observe"
  done
}

_runtime_json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

cmd_status_live() {
  local path="${1:-.}" json=0
  if [[ "$path" == --json ]]; then json=1; path=.; shift; else shift || true; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in --json) json=1 ;; *) die "알 수 없는 status --live 옵션: $1" ;; esac
    shift
  done
  local root agent_list agent_status git_status records_file pending_file meta task role agent_name pane_id
  local task_path document_status herdr_status verdict matched_object approval first
  root="$(project_root "$path")"
  set +e
  agent_list="$(herdr agent list 2>&1)"
  agent_status=$?
  set -e
  git_status="$(git -C "$root" status --short 2>&1 || true)"
  mkdir -p "$root/.harness/runtime"
  records_file="$(mktemp "$root/.harness/runtime/.status-records.XXXXXX")"
  pending_file="$(mktemp "$root/.harness/runtime/.status-pending.XXXXXX")"
  trap "rm -f -- '$records_file' '$pending_file'" RETURN

  shopt -s nullglob
  for meta in "$root"/.harness/runtime/*.meta; do
    task="$(_runtime_meta_value "$meta" task_id)"
    role="$(_runtime_meta_value "$meta" role)"
    agent_name="$(_runtime_meta_value "$meta" agent_name)"
    pane_id="$(_runtime_meta_value "$meta" pane_id)"
    [[ -n "$task" && -n "$role" && -n "$agent_name" && -n "$pane_id" ]] || continue

    task_path="$root/.harness/tasks/$task.yaml"
    if [[ -f "$task_path" ]]; then
      document_status="$(yaml_scalar "$task_path" status)"
    else
      document_status=missing
    fi

    herdr_status=missing
    if (( agent_status == 0 )); then
      if command -v jq >/dev/null 2>&1; then
        herdr_status="$(printf '%s' "$agent_list" | jq -r --arg name "$agent_name" --arg pane "$pane_id" '.result.agents[]? | select(.name == $name and .pane_id == $pane) | .agent_status' 2>/dev/null | head -n 1 || true)"
      else
        matched_object="$(printf '%s' "$agent_list" | sed 's/},{/}\n{/g' | grep -F "\"name\":\"$agent_name\"" | grep -F "\"pane_id\":\"$pane_id\"" | head -n 1 || true)"
        [[ -z "$matched_object" ]] || herdr_status="$(_runtime_json_field "$matched_object" agent_status)"
      fi
      herdr_status="${herdr_status:-missing}"
    else
      herdr_status=unavailable
    fi

    if [[ "$document_status" == active && "$herdr_status" == missing ]]; then
      verdict=DRIFT
    elif [[ "$document_status" == active && "$herdr_status" == unavailable ]]; then
      verdict=DRIFT
    elif [[ "$document_status" != active && "$herdr_status" != missing && "$herdr_status" != unavailable ]]; then
      verdict=ORPHAN
    else
      verdict=OK
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$task" "$role" "$document_status" "$agent_name" "$pane_id" "$herdr_status" "$verdict" >>"$records_file"
  done

  while IFS= read -r task; do
    [[ -n "$task" ]] || continue
    task_path="$root/.harness/tasks/$task.yaml"
    document_status="$(yaml_scalar "$task_path" status)"
    if [[ "$document_status" == active ]] && ! awk -F'\t' -v task="$task" '$1 == task { found=1 } END { exit !found }' "$records_file"; then
      printf '%s\t-\t%s\t-\t-\tmissing\tDRIFT\n' "$task" "$document_status" >>"$records_file"
    fi
    if [[ "$document_status" == awaiting_approval ]]; then
      approval="$root/.harness/decisions/$task-approval.md"
      if [[ ! -f "$approval" ]] || ! grep -q '^승인:[[:space:]]*yes' "$approval"; then
        printf '%s\n' "$task" >>"$pending_file"
      fi
    fi
  done < <(task_ids "$root")
  shopt -u nullglob

  if (( json == 1 )); then
    printf '{"state":"%s","herdr_available":%s,"agents":[' \
      "$(_runtime_json_escape "$(cat "$root/.harness/STATE.md")")" "$([[ "$agent_status" -eq 0 ]] && printf true || printf false)"
    first=1
    while IFS=$'\t' read -r task role document_status agent_name pane_id herdr_status verdict; do
      (( first == 1 )) || printf ','
      first=0
      printf '{"task":"%s","role":"%s","document_status":"%s","agent":"%s","pane":"%s","herdr_status":"%s","verdict":"%s"}' \
        "$(_runtime_json_escape "$task")" "$(_runtime_json_escape "$role")" "$(_runtime_json_escape "$document_status")" \
        "$(_runtime_json_escape "$agent_name")" "$(_runtime_json_escape "$pane_id")" "$(_runtime_json_escape "$herdr_status")" "$(_runtime_json_escape "$verdict")"
    done <"$records_file"
    printf '],"git_status":"%s","pending_decisions":[' "$(_runtime_json_escape "$git_status")"
    first=1
    while IFS= read -r task; do
      [[ -n "$task" ]] || continue
      (( first == 1 )) || printf ','
      first=0
      printf '"%s"' "$(_runtime_json_escape "$task")"
    done <"$pending_file"
    printf ']}\n'
  else
    cat "$root/.harness/STATE.md"
    printf '\n## Live Herdr agents\n\n'
    printf '| Task | Role | 문서상태 | Agent | Pane | Herdr상태 | 판정 |\n'
    printf '|---|---|---|---|---|---|---|\n'
    if [[ -s "$records_file" ]]; then
      while IFS=$'\t' read -r task role document_status agent_name pane_id herdr_status verdict; do
        printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$task" "$role" "$document_status" "$agent_name" "$pane_id" "$herdr_status" "$verdict"
      done <"$records_file"
    else
      printf '| - | - | - | - | - | - | OK |\n'
    fi
    [[ "$agent_status" -eq 0 ]] || printf '\n경고: Herdr Agent 목록을 조회하지 못했습니다.\n'
    printf '\n## Git status --short\n\n%s\n' "${git_status:-clean}"
    printf '\n## 승인 대기 (계산됨)\n\n'
    if [[ -s "$pending_file" ]]; then
      while IFS= read -r task; do printf -- '- %s: completed 사용자 승인 필요\n' "$task"; done <"$pending_file"
    else
      printf -- '- 없음\n'
    fi
  fi
  rm -f -- "$records_file" "$pending_file"
}

cmd_doctor() {
  local failed=0 command_name
  for command_name in herdr git claude codex agy; do
    if command -v "$command_name" >/dev/null 2>&1; then
      printf '[OK]      %-8s %s\n' "$command_name" "$(command -v "$command_name")"
    else
      printf '[MISSING] %-8s\n' "$command_name"
      [[ "$command_name" == herdr || "$command_name" == git ]] && failed=1
    fi
  done
  if command -v herdr >/dev/null 2>&1; then
    printf '\nHerdr version:\n'
    herdr --version || true
    printf '\nHerdr integrations:\n'
    herdr integration status || true
  fi
  return "$failed"
}

project_root() {
  local path="${1:-.}"
  path="$(realpath -m "$path")"
  [[ -f "$path/.harness/project.yaml" ]] || die "Harness 프로젝트가 아닙니다: $path"
  printf '%s\n' "$path"
}

cmd_status() {
  local live=0 json=0 root_arg="."
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --live) live=1; shift ;;
      --json) json=1; shift ;;
      -h|--help) printf '사용법: %s status [PATH] [--live] [--json]\n' "$SCRIPT_NAME"; return 0 ;;
      -*) die "알 수 없는 status 옵션: $1" ;;
      *) root_arg="$1"; shift ;;
    esac
  done
  local root
  root="$(project_root "$root_arg")"
  if [[ "$live" -eq 1 ]]; then
    if [[ "$json" -eq 1 ]]; then
      cmd_status_live "$root" --json
    else
      cmd_status_live "$root"
    fi
    return $?
  fi
  cat "$root/.harness/STATE.md"
}

cmd_start() {
  local root name orchestrator
  root="$(project_root "${1:-.}")"
  command -v herdr >/dev/null 2>&1 || die "herdr 명령을 찾을 수 없습니다. herdr-harness doctor를 실행하세요."
  name="$(awk -F': ' '/^  name:/{gsub(/[\047\042]/,"",$2); print $2; exit}' "$root/.harness/project.yaml")"
  orchestrator="$(awk -F': ' '/^  orchestrator:/{gsub(/[\047\042]/,"",$2); print $2; exit}' "$root/.harness/project.yaml")"
  printf 'Herdr Session: %s\n' "$name"
  printf '첫 Pane에서 %s를 실행한 뒤 HARNESS_START.md의 Prompt를 입력하세요.\n\n' "$orchestrator"
  cd "$root"
  exec herdr --session "$name"
}

cmd_test() {
  bash -n "$SELF_PATH"
  local test_root test_project failure_status
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/herdr-harness-test.XXXXXX")"
  test_project="$test_root/sample-project"
  trap 'case "${test_root:-}" in "${TMPDIR:-/tmp}"/herdr-harness-test.*) rm -rf -- "$test_root" ;; esac' EXIT

  bash "$SELF_PATH" init "$test_project" \
    --name sample-project \
    --goal "SNMP Dump 정규화 테스트" \
    --profile network-device \
    --orchestrator claude \
    --worker codex \
    --reviewer agy \
    --fallback claude,agy >/dev/null

  local required=(
    AGENTS.md CLAUDE.md GEMINI.md HARNESS_START.md
    .harness/project.yaml .harness/SPEC.md .harness/MILESTONES.md .harness/STATE.md
    .harness/tasks/TEMPLATE.yaml .harness/references/inventory.md
    .harness/waves/TEMPLATE.yaml .harness/attempts/TEMPLATE.md
    .harness/reviews/TEMPLATE.md .harness/handovers/TEMPLATE.md
    .harness/decisions/TEMPLATE.md
    .harness/intents/TEMPLATE.md .harness/intents/README.md
    .harness/policies/review-policy.yaml
    .agents/roles/orchestrator.agent.md .agents/roles/worker.agent.md .agents/roles/reviewer.agent.md
    .agents/roles/interviewer.agent.md .agents/roles/planner.agent.md .agents/roles/advisor.agent.md
    .agents/skills/harness-interview/SKILL.md .agents/skills/harness-reference/SKILL.md
    .agents/skills/harness-plan/SKILL.md
    .agents/skills/harness-orchestrate/SKILL.md .agents/skills/harness-work/SKILL.md
    .agents/skills/harness-verify/SKILL.md
    .agents/skills/harness-review/SKILL.md .agents/skills/harness-handover/SKILL.md
    .agents/skills/harness-status/SKILL.md
  )
  local item
  for item in "${required[@]}"; do
    [[ -f "$test_project/$item" ]] || die "자체 테스트 누락 파일: $item"
  done

  # 템플릿 정본이 templates/ 에 파일로 존재하고, 배열과 파일이 서로 어긋나지
  # 않는지 확인한다(heredoc → 파일 추출 후 회귀 방지).
  for item in "${HARNESS_DOC_TEMPLATES[@]}" "${HARNESS_POLICY_TEMPLATES[@]}"; do
    [[ -f "$HARNESS_TEMPLATE_DIR/$item" ]] ||
      die "템플릿 정본 파일 누락: $HARNESS_TEMPLATE_DIR/$item"
  done
  local tpl_file tpl_rel
  while IFS= read -r tpl_file; do
    tpl_rel="${tpl_file#"$HARNESS_TEMPLATE_DIR/"}"
    case " ${HARNESS_DOC_TEMPLATES[*]} ${HARNESS_POLICY_TEMPLATES[*]} " in
      *" $tpl_rel "*) ;;
      *) die "templates/ 에 배열에 없는 파일이 있습니다: $tpl_rel (HARNESS_DOC_TEMPLATES/HARNESS_POLICY_TEMPLATES에 추가하거나 파일을 지우세요)" ;;
    esac
  done < <(find "$HARNESS_TEMPLATE_DIR" -type f | sort)

  for item in "$test_project"/.claude/skills/*/SKILL.md; do
    [[ -f "$item" ]] || die "Claude Skill 연결 실패: $item"
  done

  if grep -rq '@@[A-Z_]*@@' "$test_project" 2>/dev/null; then
    die "치환되지 않은 플레이스홀더가 남아 있습니다."
  fi

  git -C "$test_project" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "init이 Git 저장소를 만들지 않았습니다."
  git -C "$test_project" -c user.name=harness-test -c user.email=test@example.invalid \
    commit -q -m "chore: harness 기준선" >/dev/null 2>&1 || true
  git -C "$test_project" rev-parse HEAD >/dev/null 2>&1 ||
    die "기준 commit을 만들지 못했습니다."

  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "$test_project" <<'HARNESS_YAML_CHECK'
from pathlib import Path
import sys, yaml
root = Path(sys.argv[1])
for path in root.rglob('*.yaml'):
    yaml.safe_load(path.read_text())
HARNESS_YAML_CHECK
  else
    info "PyYAML이 없어 YAML 파싱 테스트는 건너뜁니다."
  fi

  set +e
  bash "$SELF_PATH" init "$test_project" --name duplicate --goal duplicate >/dev/null 2>&1
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || die "비어 있지 않은 디렉터리 거부 테스트 실패"

  set +e
  local goal_message
  goal_message="$(bash "$SELF_PATH" init "$test_root/no-goal" </dev/null 2>&1)"
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || die "비대화형 --goal 누락 거부 테스트 실패"
  printf '%s' "$goal_message" | grep -q '비대화형' ||
    die "비대화형 실패에 설명 메시지가 없습니다."

  local task="$test_project/.harness/tasks/task-001.yaml"
  sed -e 's/^task_id: .*/task_id: task-001/' \
      -e 's/^milestone_id: .*/milestone_id: milestone-001/' \
      "$test_project/.harness/tasks/TEMPLATE.yaml" >"$task"

  expect_fail() {
    local label="$1"; shift
    set +e
    "$@" >/dev/null 2>&1
    local status=$?
    set -e
    [[ "$status" -ne 0 ]] || die "거부되어야 할 동작이 허용됐습니다: $label"
  }
  expect_pass() {
    local label="$1"; shift
    "$@" >/dev/null || die "허용되어야 할 동작이 거부됐습니다: $label"
  }

  expect_fail "draft->active (전이표 위반)" \
    bash "$SELF_PATH" transition "$test_project" task-001 active
  expect_fail "draft->ready (SPEC 미승인)" \
    bash "$SELF_PATH" transition "$test_project" task-001 ready

  sed -i 's/^- 상태: draft$/- 상태: approved/' "$test_project/.harness/SPEC.md"
  expect_pass "draft->ready" \
    bash "$SELF_PATH" transition "$test_project" task-001 ready
  expect_pass "ready->active" \
    bash "$SELF_PATH" transition "$test_project" task-001 active

  expect_fail "active->submitted (Attempt/Evidence 없음)" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted
  printf '# attempt\n' >"$test_project/.harness/attempts/task-001-attempt-1.md"
  expect_fail "active->submitted (Evidence 없음)" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted
  printf '# evidence\n' >"$test_project/.harness/evidence/task-001-worker-attempt-1.md"
  expect_pass "active->submitted" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted

  expect_pass "submitted->reviewing" \
    bash "$SELF_PATH" transition "$test_project" task-001 reviewing
  expect_fail "reviewing->awaiting_approval (APPROVED Review 없음)" \
    bash "$SELF_PATH" transition "$test_project" task-001 awaiting_approval
  printf '판정: CHANGES_REQUESTED\n' >"$test_project/.harness/reviews/task-001-review-1.md"
  expect_fail "reviewing->awaiting_approval (판정 불일치)" \
    bash "$SELF_PATH" transition "$test_project" task-001 awaiting_approval
  printf '판정: APPROVED\n' >"$test_project/.harness/reviews/task-001-review-2.md"
  # 과거 APPROVED가 남아 있어도 최신 Review가 반려면 통과하면 안 된다
  printf '판정: CHANGES_REQUESTED\n' >"$test_project/.harness/reviews/task-001-review-3.md"
  touch -d '+1 minute' "$test_project/.harness/reviews/task-001-review-3.md"
  expect_fail "최신 Review가 반려인데 과거 APPROVED로 우회" \
    bash "$SELF_PATH" transition "$test_project" task-001 awaiting_approval
  rm -f "$test_project/.harness/reviews/task-001-review-3.md"
  touch "$test_project/.harness/reviews/task-001-review-2.md"
  expect_pass "reviewing->awaiting_approval" \
    bash "$SELF_PATH" transition "$test_project" task-001 awaiting_approval

  expect_fail "awaiting_approval->completed (사용자 승인 기록 없음)" \
    bash "$SELF_PATH" transition "$test_project" task-001 completed
  printf 'Task: task-001\n승인: no\n' >"$test_project/.harness/decisions/task-001-approval.md"
  expect_fail "awaiting_approval->completed (승인: no)" \
    bash "$SELF_PATH" transition "$test_project" task-001 completed
  printf 'Task: task-001\n승인: yes\n' >"$test_project/.harness/decisions/task-001-approval.md"
  expect_pass "awaiting_approval->completed" \
    bash "$SELF_PATH" transition "$test_project" task-001 completed

  expect_fail "동일 상태 재전이" \
    bash "$SELF_PATH" transition "$test_project" task-001 completed

  # handover_required 진입 게이트: Handover 인계 문서 필수 (BACKLOG 9-3-3)
  local task3="$test_project/.harness/tasks/task-003.yaml"
  sed -e 's/^task_id: .*/task_id: task-003/' \
      -e 's/^milestone_id: .*/milestone_id: milestone-001/' \
      "$test_project/.harness/tasks/TEMPLATE.yaml" >"$task3"
  bash "$SELF_PATH" transition "$test_project" task-003 ready >/dev/null
  bash "$SELF_PATH" transition "$test_project" task-003 active >/dev/null
  expect_fail "active->handover_required (Handover 문서 없음)" \
    bash "$SELF_PATH" transition "$test_project" task-003 handover_required
  printf '# handover\n' >"$test_project/.harness/handovers/task-003-handover-1.md"
  expect_pass "active->handover_required (Handover 문서 있음)" \
    bash "$SELF_PATH" transition "$test_project" task-003 handover_required

  local events="$test_project/.harness/evidence/events.tsv"
  [[ -f "$events" ]] || die "이벤트 로그가 없습니다: $events"
  [[ "$(grep -c '^' "$events")" -ge 7 ]] || die "이벤트 로그 기록이 부족합니다."

  bash "$SELF_PATH" validate "$test_project" >/dev/null ||
    die "정상 프로젝트에서 validate가 실패했습니다."

  sed -i "s/^reviewer: .*/reviewer: 'codex'/" "$task"
  expect_fail "validate가 Worker==Reviewer를 통과시킴" \
    bash "$SELF_PATH" validate "$test_project"
  sed -i "s/^reviewer: .*/reviewer: 'agy'/" "$task"

  local no_git="$test_root/no-git-project"
  cp -r "$test_project" "$no_git"
  rm -rf "$no_git/.git"
  expect_fail "validate가 Git 기준선 누락을 통과시킴" \
    bash "$SELF_PATH" validate "$no_git"

  expect_fail "dispatch 잘못된 ROLE" \
    bash "$SELF_PATH" dispatch "$test_project" task-001 architect
  expect_fail "observe 인자 부족" \
    bash "$SELF_PATH" observe "$test_project"
  expect_fail "close-agent 기록 없는 Task" \
    bash "$SELF_PATH" close-agent "$test_project" task-999

  # --- Task Lock: 동시 획득 거부, release, stale 회수 -----------------------
  local task2="$test_project/.harness/tasks/task-002.yaml"
  sed -e 's/^task_id: .*/task_id: task-002/' \
      -e 's/^milestone_id: .*/milestone_id: milestone-001/' \
      -e 's/^status: .*/status: active/' \
      "$test_project/.harness/tasks/TEMPLATE.yaml" >"$task2"

  local lock_token1 lock_token2 lock_status
  lock_token1="$(_runtime_lock_acquire "$test_project" task-002 test-a 600)" ||
    die "Task Lock 최초 획득 실패"
  set +e
  lock_token2="$(_runtime_lock_acquire "$test_project" task-002 test-b 600)"
  lock_status=$?
  set -e
  [[ "$lock_status" -ne 0 ]] || die "Task Lock이 동시 획득을 막지 못했습니다."
  _runtime_lock_release "$test_project" task-002 "$lock_token1"
  [[ ! -d "$(_runtime_lock_dir "$test_project" task-002)" ]] ||
    die "Task Lock이 release 후에도 남아 있습니다."

  ( : ) &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  lock_token1="$(_runtime_lock_acquire "$test_project" task-002 test-c 600)" ||
    die "Task Lock 재획득 실패"
  printf 'owner=test-c\npid=%s\nacquired_at=2000-01-01T00:00:00Z\ntoken=stale-token\n' "$dead_pid" \
    >"$(_runtime_lock_dir "$test_project" task-002)/holder"
  lock_token2="$(_runtime_lock_acquire "$test_project" task-002 test-d 1)" ||
    die "Stale Task Lock을 회수하지 못했습니다."
  _runtime_lock_release "$test_project" task-002 "$lock_token2"
  [[ ! -d "$(_runtime_lock_dir "$test_project" task-002)" ]] ||
    die "Task Lock이 release 후에도 남아 있습니다(stale 회수 후)."

  # --- quota-retry / auto-step opt-in 게이트 --------------------------------
  expect_fail "quota-retry 기본값(automatic_failover:false)에서 거부" \
    bash "$SELF_PATH" quota-retry "$test_project" task-002 worker
  expect_fail "auto-step 기본값(loop-policy enabled:false)에서 거부" \
    bash "$SELF_PATH" auto-step "$test_project" task-002

  sed -i 's/^  automatic_failover: false$/  automatic_failover: true/' \
    "$test_project/.harness/policies/quota-policy.yaml"
  expect_fail "quota-retry: 연속 저쿼터 기록 없음" \
    bash "$SELF_PATH" quota-retry "$test_project" task-002 worker

  printf 'count=1\nfirst_low_at=2026-01-01T00:00:00Z\nlast_low_at=2026-01-01T00:00:00Z\n' \
    >"$test_project/.harness/runtime/task-002-worker.quota-streak"
  expect_fail "quota-retry: 연속 확인 횟수 미달" \
    bash "$SELF_PATH" quota-retry "$test_project" task-002 worker

  printf 'count=2\nfirst_low_at=2026-01-01T00:00:00Z\nlast_low_at=2026-01-01T00:00:00Z\n' \
    >"$test_project/.harness/runtime/task-002-worker.quota-streak"
  expect_fail "quota-retry: cooldown 미달" \
    bash "$SELF_PATH" quota-retry "$test_project" task-002 worker

  rm -f "$test_project/.harness/runtime/task-002-worker.quota-streak"
  sed -i 's/^  automatic_failover: true$/  automatic_failover: false/' \
    "$test_project/.harness/policies/quota-policy.yaml"

  sed -i 's/^  enabled: false$/  enabled: true/' "$test_project/.harness/policies/loop-policy.yaml"
  expect_fail "auto-step: --max-turns가 정책 상한을 넘음" \
    bash "$SELF_PATH" auto-step "$test_project" task-002 --max-turns 99
  sed -i 's/^  enabled: true$/  enabled: false/' "$test_project/.harness/policies/loop-policy.yaml"

  # --- 안전 불변식: auto-step/quota-retry 함수 본문에 completed/reviewing/
  #     awaiting_approval/ready 전이 호출이 없어야 한다(구조적 회귀 방지) ----
  local auto_step_body quota_retry_body
  auto_step_body="$(awk '/^cmd_auto_step\(\) \{$/{flag=1} flag{print} flag && /^}$/{exit}' "$SELF_PATH")"
  printf '%s' "$auto_step_body" | grep -qE 'cmd_transition[^\n]*\b(completed|reviewing|awaiting_approval)\b' &&
    die "auto_step 안전 불변식 위반: completed/reviewing/awaiting_approval 전이 호출이 발견됐습니다."
  quota_retry_body="$(awk '/^cmd_quota_retry\(\) \{$/{flag=1} flag{print} flag && /^}$/{exit}' "$SELF_PATH")"
  printf '%s' "$quota_retry_body" | grep -qE 'cmd_transition[^\n]*\b(completed|ready)\b' &&
    die "quota_retry 안전 불변식 위반: completed/ready 전이 호출이 발견됐습니다."
  # quota_retry는 handover_required 게이트를 통과하려면 전이 전에 handover 문서를 만들어야 한다 (BACKLOG 9-3-3)
  printf '%s' "$quota_retry_body" | grep -q 'handovers/\$task_id-handover-' ||
    die "quota_retry 회귀: handover_required 전이 전에 handover stub 생성 코드가 없습니다."
  printf '%s' "$quota_retry_body" | awk '/handovers\/\$task_id-handover-\$handover_n/{h=NR} /cmd_transition .*handover_required/{t=NR} END{exit !(h && t && h < t)}' ||
    die "quota_retry 회귀: handover stub 생성이 handover_required 전이보다 뒤에 있습니다."

  local completion_script
  completion_script="$(bash "$SELF_PATH" completion bash)"
  printf '%s' "$completion_script" | bash -n /dev/stdin ||
    die "completion bash 출력이 유효한 Bash 문법이 아닙니다."
  printf '%s' "$completion_script" | grep -q '^complete -F .* herdr-harness$' ||
    die "completion bash 출력에 complete 등록 줄이 없습니다."

  # --- sync-templates: 기존 프로젝트를 최신 skill/role 템플릿과 재동기화 -----
  local sync_out
  sync_out="$(bash "$SELF_PATH" sync-templates "$test_project")"
  printf '%s' "$sync_out" | grep -q '요약: 변경 0' ||
    die "sync-templates: 방금 init한 프로젝트인데 dry-run이 변경 0이 아닙니다."

  cat >"$test_project/.agents/skills/harness-orchestrate/SKILL.md" <<'EOF'
---
name: harness-orchestrate
description: old stub (자체 테스트용 인위적 구버전)
---
old content
EOF
  printf '\n## 프로젝트 고유 규칙\ncustom rule appended\n' >>"$test_project/AGENTS.md"
  cp "$test_project/.harness/STATE.md" "$test_root/state-before-sync.md"

  sync_out="$(bash "$SELF_PATH" sync-templates "$test_project")"
  printf '%s' "$sync_out" | grep -q '요약: 변경 1' ||
    die "sync-templates: 구버전 skill 하나를 dry-run이 감지하지 못했습니다."
  grep -q "old content" "$test_project/.agents/skills/harness-orchestrate/SKILL.md" ||
    die "sync-templates: dry-run인데 실제로 파일을 갱신했습니다."

  sync_out="$(bash "$SELF_PATH" sync-templates "$test_project" --apply)"
  printf '%s' "$sync_out" | grep -q '요약: 변경 1' ||
    die "sync-templates --apply: 변경 건수가 예상과 다릅니다."
  if grep -q "old content" "$test_project/.agents/skills/harness-orchestrate/SKILL.md"; then
    die "sync-templates --apply: 구버전 skill이 갱신되지 않았습니다."
  fi
  grep -q "herdr-harness dispatch" "$test_project/.agents/skills/harness-orchestrate/SKILL.md" ||
    die "sync-templates --apply: 갱신된 skill에 최신 절차(dispatch)가 없습니다."
  grep -q "custom rule appended" "$test_project/AGENTS.md" ||
    die "sync-templates --apply: AGENTS.md의 프로젝트 고유 규칙이 사라졌습니다(자동 갱신하면 안 되는 파일입니다)."
  cmp -s "$test_root/state-before-sync.md" "$test_project/.harness/STATE.md" ||
    die "sync-templates --apply: 관련 없는 STATE.md가 바뀌었습니다(범위를 벗어났습니다)."

  sync_out="$(bash "$SELF_PATH" sync-templates "$test_project" --apply)"
  printf '%s' "$sync_out" | grep -q '요약: 변경 0' ||
    die "sync-templates --apply: 같은 내용을 다시 적용했는데 멱등이 아닙니다."

  rm -rf -- "$test_root"
  trap - EXIT

  printf 'PASS: Bash 문법\n'
  printf 'PASS: Harness 파일 생성 (21종 템플릿, templates/ 파일 정본)\n'
  printf 'PASS: 템플릿 배열 ↔ templates/ 파일 정합\n'
  printf 'PASS: 공통 Skill과 Claude 연결\n'
  printf 'PASS: 플레이스홀더 치환\n'
  printf 'PASS: Git 기준선 생성\n'
  printf 'PASS: 신규 프로젝트 보호\n'
  printf 'PASS: 비대화형 명시적 실패\n'
  printf 'PASS: 상태 전이표 강제 (16개 케이스, handover_required 인계문서 게이트 포함)\n'
  printf 'PASS: 이벤트 로그 기록\n'
  printf 'PASS: validate 검증 (정상/Worker=Reviewer/Git 누락)\n'
  printf 'PASS: 스텝 명령 인자 검증\n'
  printf 'PASS: Agent 호출 없음\n'
  printf 'PASS: 탭 완성 스크립트 문법\n'
  printf 'PASS: Task Lock (동시 획득 거부/release/stale 회수)\n'
  printf 'PASS: quota-retry/auto-step opt-in 게이트\n'
  printf 'PASS: quota-retry/auto-step 안전 불변식(completed/reviewing/awaiting_approval/ready 미호출, handover stub 선행)\n'
  printf 'PASS: sync-templates (dry-run 무변경 감지·미적용, apply 갱신·멱등, AGENTS.md/STATE.md 비침범)\n'
}

cmd_completion() {
  local shell="${1:-}"
  [[ "$shell" == bash ]] || die "사용법: completion bash  (지원 Shell은 현재 bash뿐입니다)"
  cat <<'HARNESS_BASH_COMPLETION'
# herdr-harness bash completion
# 설치: ~/.bashrc에 다음 한 줄을 추가하세요.
#   source <(herdr-harness completion bash)

_herdr_harness_task_ids() {
  local root="$1" cur="$2" dir f base ids=()
  dir="$root/.harness/tasks"
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.yaml; do
    [[ -f "$f" ]] || continue
    base="${f##*/}"; base="${base%.yaml}"
    [[ "$base" == TEMPLATE ]] && continue
    ids+=("$base")
  done
  COMPREPLY+=($(compgen -W "${ids[*]}" -- "$cur"))
}

_herdr_harness_completions() {
  local cur prev cmd
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local subcommands="init sync-templates start status doctor test uninstall validate transition dispatch observe close-agent quota-check quota-retry auto-step completion"

  if (( COMP_CWORD == 1 )); then
    COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
    return 0
  fi

  cmd="${COMP_WORDS[1]}"
  case "$cmd" in
    init)
      case "$prev" in
        --profile) COMPREPLY=($(compgen -W "generic python-timeseries network-device" -- "$cur")) ;;
        --orchestrator|--worker|--reviewer) COMPREPLY=($(compgen -W "claude codex agy" -- "$cur")) ;;
        --name|--goal|--fallback) ;;
        *)
          if (( COMP_CWORD == 2 )); then
            COMPREPLY=($(compgen -d -- "$cur"))
          else
            COMPREPLY=($(compgen -W "--name --goal --profile --orchestrator --worker --reviewer --fallback" -- "$cur"))
          fi
          ;;
      esac
      ;;
    start|status)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      else
        COMPREPLY=($(compgen -W "--live --json" -- "$cur"))
      fi
      ;;
    validate)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      elif [[ "$prev" == --wave ]]; then
        :
      else
        COMPREPLY=($(compgen -W "--wave --no-git" -- "$cur"))
      fi
      ;;
    sync-templates)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      else
        COMPREPLY=($(compgen -W "--apply --dry-run" -- "$cur"))
      fi
      ;;
    transition)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      elif (( COMP_CWORD == 3 )); then
        _herdr_harness_task_ids "${COMP_WORDS[2]}" "$cur"
      elif (( COMP_CWORD == 4 )); then
        COMPREPLY=($(compgen -W "draft ready active submitted blocked handover_required reviewing changes_requested awaiting_approval completed" -- "$cur"))
      elif [[ "$prev" == --note ]]; then
        :
      else
        COMPREPLY=($(compgen -W "--note" -- "$cur"))
      fi
      ;;
    dispatch|observe|close-agent|quota-check|quota-retry)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      elif (( COMP_CWORD == 3 )) && [[ "$cmd" == quota-check && "$cur" == --* ]]; then
        COMPREPLY=($(compgen -W "--provider" -- "$cur"))
      elif [[ "$prev" == --provider ]]; then
        COMPREPLY=($(compgen -W "claude codex agy" -- "$cur"))
      elif (( COMP_CWORD == 3 )); then
        _herdr_harness_task_ids "${COMP_WORDS[2]}" "$cur"
      elif (( COMP_CWORD == 4 )); then
        COMPREPLY=($(compgen -W "worker reviewer" -- "$cur"))
      elif [[ "$cmd" == dispatch && "$prev" == --timeout ]]; then
        :
      elif [[ "$cmd" == dispatch ]]; then
        COMPREPLY=($(compgen -W "--timeout" -- "$cur"))
      elif [[ "$cmd" == close-agent ]]; then
        COMPREPLY=($(compgen -W "--force" -- "$cur"))
      fi
      ;;
    auto-step)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      elif (( COMP_CWORD == 3 )); then
        _herdr_harness_task_ids "${COMP_WORDS[2]}" "$cur"
      elif [[ "$prev" == --max-turns ]]; then
        :
      else
        COMPREPLY=($(compgen -W "--max-turns" -- "$cur"))
      fi
      ;;
    uninstall)
      COMPREPLY=($(compgen -W "--yes" -- "$cur"))
      ;;
    completion)
      COMPREPLY=($(compgen -W "bash" -- "$cur"))
      ;;
  esac
}

complete -F _herdr_harness_completions herdr-harness
HARNESS_BASH_COMPLETION
}

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
  rm -rf "$install_dir/templates"
  rmdir "$install_dir" 2>/dev/null || true

  printf 'Harness 제거 완료.\n'
  printf '생성한 프로젝트와 Herdr 설정은 유지됩니다.\n'
}

main() {
  local command="${1:-help}"
  [[ $# -eq 0 ]] || shift
  case "$command" in
    init) cmd_init "$@" ;;
    sync-templates) cmd_sync_templates "$@" ;;
    start) cmd_start "$@" ;;
    status) cmd_status "$@" ;;
    validate) cmd_validate "$@" ;;
    transition) cmd_transition "$@" ;;
    dispatch) cmd_dispatch "$@" ;;
    observe) cmd_observe "$@" ;;
    close-agent) cmd_close_agent "$@" ;;
    quota-check) cmd_quota_check "$@" ;;
    quota-retry) cmd_quota_retry "$@" ;;
    auto-step) cmd_auto_step "$@" ;;
    completion) cmd_completion "$@" ;;
    doctor) cmd_doctor "$@" ;;
    test) cmd_test "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    help|-h|--help) usage ;;
    *) die "알 수 없는 명령: $command" ;;
  esac
}

main "$@"

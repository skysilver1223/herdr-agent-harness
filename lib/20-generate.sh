# Part of herdr-harness. Sourced by harness.sh — do not run directly.


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
  DOC_APPROVAL_MODE="${7:-auto}"
  DOC_CLAUDE_AUTO='--permission-mode acceptEdits'
  DOC_CLAUDE_BYPASS='--permission-mode bypassPermissions'
  DOC_CODEX_AUTO='--ask-for-approval never --sandbox workspace-write'
  DOC_CODEX_BYPASS='--dangerously-bypass-approvals-and-sandbox'
  DOC_AGY_AUTO='--mode accept-edits'
  DOC_AGY_BYPASS='--dangerously-skip-permissions'
  DOC_CLAUDE_MODELS='' DOC_CLAUDE_DEFAULT_MODEL=''
  DOC_CODEX_MODELS='' DOC_CODEX_DEFAULT_MODEL=''
  DOC_AGY_MODELS='' DOC_AGY_DEFAULT_MODEL=''
  DOC_WORKER_DEFAULT_TIER='' DOC_REVIEWER_DEFAULT_TIER=''
  DOC_WORKER_DEFAULT_EFFORT='' DOC_REVIEWER_DEFAULT_EFFORT=''
  DOC_CLAUDE_TIER_LIGHT='' DOC_CLAUDE_TIER_STANDARD='' DOC_CLAUDE_TIER_PREMIUM=''
  DOC_CODEX_TIER_LIGHT='' DOC_CODEX_TIER_STANDARD='' DOC_CODEX_TIER_PREMIUM=''
  DOC_AGY_TIER_LIGHT='' DOC_AGY_TIER_STANDARD='' DOC_AGY_TIER_PREMIUM=''
  DOC_CLAUDE_PREMIUM_MODELS=''
  DOC_CODEX_PREMIUM_MODELS=''
  DOC_AGY_PREMIUM_MODELS=''

  # agent-policy.yaml은 사용자가 직접 조정하는 정책 파일이다. sync-templates가
  # 새 모델 키를 전파하되 기존 승인 인수와 모델 목록을 초기값으로 되돌리지
  # 않도록, 이미 존재하는 키의 값은 템플릿에 다시 주입한다.
  local agent_policy="$root/.harness/policies/agent-policy.yaml" key variable value
  if [[ "${HH_SYNC_MODE:-0}" -eq 1 && -f "$agent_policy" ]]; then
    while IFS=':' read -r key variable; do
      value="$(awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
          sub("^[[:space:]]*" key ":[[:space:]]*", "")
          gsub(/^[\047\042]|[\047\042]$/, "")
          print
          exit
        }
      ' "$agent_policy")"
      # 빈 값도 유효하다. 키가 실제로 있을 때만 기존 값을 보존하고, 구버전처럼
      # 키가 없으면 위의 안전한 초기값을 사용한다.
      if grep -Eq "^[[:space:]]*$key:" "$agent_policy"; then
        printf -v "$variable" '%s' "$value"
      fi
    done <<'POLICY_FIELDS'
approval_mode:DOC_APPROVAL_MODE
claude_auto:DOC_CLAUDE_AUTO
claude_bypass:DOC_CLAUDE_BYPASS
codex_auto:DOC_CODEX_AUTO
codex_bypass:DOC_CODEX_BYPASS
agy_auto:DOC_AGY_AUTO
agy_bypass:DOC_AGY_BYPASS
worker_default_tier:DOC_WORKER_DEFAULT_TIER
reviewer_default_tier:DOC_REVIEWER_DEFAULT_TIER
worker_default_effort:DOC_WORKER_DEFAULT_EFFORT
reviewer_default_effort:DOC_REVIEWER_DEFAULT_EFFORT
claude_models:DOC_CLAUDE_MODELS
claude_default_model:DOC_CLAUDE_DEFAULT_MODEL
claude_tier_light:DOC_CLAUDE_TIER_LIGHT
claude_tier_standard:DOC_CLAUDE_TIER_STANDARD
claude_tier_premium:DOC_CLAUDE_TIER_PREMIUM
codex_models:DOC_CODEX_MODELS
codex_default_model:DOC_CODEX_DEFAULT_MODEL
codex_tier_light:DOC_CODEX_TIER_LIGHT
codex_tier_standard:DOC_CODEX_TIER_STANDARD
codex_tier_premium:DOC_CODEX_TIER_PREMIUM
agy_models:DOC_AGY_MODELS
agy_default_model:DOC_AGY_DEFAULT_MODEL
agy_tier_light:DOC_AGY_TIER_LIGHT
agy_tier_standard:DOC_AGY_TIER_STANDARD
agy_tier_premium:DOC_AGY_TIER_PREMIUM
claude_premium_models:DOC_CLAUDE_PREMIUM_MODELS
codex_premium_models:DOC_CODEX_PREMIUM_MODELS
agy_premium_models:DOC_AGY_PREMIUM_MODELS
POLICY_FIELDS
  fi
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
  local remote_host="" remote_user="" remote_path="" remote_mount="" remote_vcs="git"
  local approval_mode="auto"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) [[ $# -ge 2 ]] || die "--name 값이 필요합니다."; name="$2"; shift 2 ;;
      --goal) [[ $# -ge 2 ]] || die "--goal 값이 필요합니다."; goal="$2"; shift 2 ;;
      --profile) [[ $# -ge 2 ]] || die "--profile 값이 필요합니다."; profile="$2"; shift 2 ;;
      --orchestrator) [[ $# -ge 2 ]] || die "--orchestrator 값이 필요합니다."; orchestrator="$2"; shift 2 ;;
      --worker) [[ $# -ge 2 ]] || die "--worker 값이 필요합니다."; worker="$2"; shift 2 ;;
      --reviewer) [[ $# -ge 2 ]] || die "--reviewer 값이 필요합니다."; reviewer="$2"; shift 2 ;;
      --fallback) [[ $# -ge 2 ]] || die "--fallback 값이 필요합니다."; fallback="$2"; shift 2 ;;
      --approval-mode) [[ $# -ge 2 ]] || die "--approval-mode 값이 필요합니다."; approval_mode="$2"; shift 2 ;;
      --remote-host) [[ $# -ge 2 ]] || die "--remote-host 값이 필요합니다."; remote_host="$2"; shift 2 ;;
      --remote-user) [[ $# -ge 2 ]] || die "--remote-user 값이 필요합니다."; remote_user="$2"; shift 2 ;;
      --remote-path) [[ $# -ge 2 ]] || die "--remote-path 값이 필요합니다."; remote_path="$2"; shift 2 ;;
      --remote-mount) [[ $# -ge 2 ]] || die "--remote-mount 값이 필요합니다."; remote_mount="$2"; shift 2 ;;
      --remote-vcs) [[ $# -ge 2 ]] || die "--remote-vcs 값이 필요합니다."; remote_vcs="$2"; shift 2 ;;
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
  case "$approval_mode" in
    ask|auto|bypass) ;;
    *) die "지원하지 않는 --approval-mode입니다: $approval_mode (ask | auto | bypass)" ;;
  esac

  # 원격 실행 모드는 --remote-host가 있을 때만 켜진다. 나머지 프로젝트는
  # remote.yaml이 enabled: false로 생성되고 remote 명령이 즉시 거부한다.
  case "$remote_vcs" in
    git|svn|none) ;;
    *) die "지원하지 않는 --remote-vcs입니다: $remote_vcs (git | svn | none)" ;;
  esac
  # 개행이 든 값은 생성된 YAML과 행 기반 리더를 동시에 깨뜨린다. 원격 모드를
  # 켜지 않아도 mount 경로는 파일에 쓰이므로 둘 다 미리 막는다.
  local remote_value
  for remote_value in "$remote_host" "$remote_user" "$remote_path" "$remote_mount"; do
    [[ "$remote_value" != *$'\n'* ]] || die "--remote-* 값에는 개행을 넣을 수 없습니다."
  done
  local remote_enabled=false
  if [[ -n "$remote_host" ]]; then
    [[ -n "$remote_path" ]] || die "--remote-host를 쓰면 --remote-path(원격 프로젝트 경로)도 필요합니다."
    remote_enabled=true
    [[ -n "$remote_user" ]] || remote_user="${USER:-$(id -un)}"
    # SSH는 "-"로 시작하는 목적지를 옵션으로 해석한다. 잘못된 값이 설정 파일에
    # 적히기 전에 여기서 막는다(45-remote.sh의 _remote_validate_endpoint와 같은 규칙).
    [[ "$remote_user" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] ||
      die "--remote-user에 허용되지 않는 문자가 있습니다(영문·숫자·. _ -, 첫 글자는 - 불가): $remote_user"
    [[ "$remote_host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ || "$remote_host" =~ ^\[[0-9A-Fa-f:]+\]$ ]] ||
      die "--remote-host 형식이 올바르지 않습니다(호스트명·IPv4 또는 [IPv6], 포트는 포함하지 않음): $remote_host"
    [[ "$remote_path" == /* ]] || die "--remote-path는 절대경로여야 합니다: $remote_path"
  fi
  [[ -n "$remote_mount" ]] || remote_mount="$target/.harness/remote-mount"

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
.harness/remote-mount/
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
- Status: spec
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
  # transition submitted가 acceptance_criteria의 verified_by 명령을 직접 실행할 때
  # 명령 하나당 허용하는 최대 시간(초).
  acceptance_check_timeout_seconds: 600

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

  # 원격 실행 모드 설정 정본. 기본은 enabled: false — 이 값이 true가 아니면
  # `herdr-harness remote ...`는 아무 것도 하지 않고 거부한다. 비밀번호는
  # 여기에 절대 적지 않는다(HH_REMOTE_PASSWORD 환경변수 + bootstrap-key 1회).
  write_file "$target" ".harness/policies/remote.yaml" <<EOF
schema_version: '1.0'
remote:
  # Agent는 항상 로컬에서 실행된다. 원격은 소스를 SSHFS로 로컬에 노출하고
  # 빌드·테스트·VCS만 SSH로 실행하는 실행 환경이다.
  enabled: $remote_enabled
  host: $(yaml_quote "$remote_host")
  user: $(yaml_quote "$remote_user")
  # 원격 호스트에 있는 프로젝트 디렉터리
  path: $(yaml_quote "$remote_path")
  # SSHFS로 원격 소스를 붙일 로컬 경로. Agent는 이 경로의 파일을 직접 편집한다.
  mount_path: $(yaml_quote "$remote_mount")
  # bootstrap-key가 만들고 사용하는 전용 키. 파일이 있으면 항상 키 인증을 쓴다.
  ssh_key: '~/.ssh/herdr_remote_ed25519'
  # remote vcs <인수...>가 원격에서 실행할 명령: git | svn | none
  vcs: '$remote_vcs'
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
  write_project_templates "$target" "$name" "$orchestrator" "$worker" "$reviewer" "$fallback" "$approval_mode"

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
harness-spec Skill로 기존 코드·데이터·문서·Dump를 먼저 조사하고
요구사항을 인터뷰해서 SPEC 초안을 만들어줘.
SPEC 승인 전에는 구현하지 마. 이후 harness-plan, harness-orchestrate로 진행해줘.
\`\`\`
EOF

  init_git_baseline "$target"

  info "생성 완료: $target"
  info "다음 단계: cd '$target' && herdr-harness start ."
  if [[ "$remote_enabled" == true ]]; then
    info "원격 모드 설정됨. 키 등록(비밀번호 1회 입력): herdr-harness remote '$target' setup --force"
  fi
}

# ---------------------------------------------------------------------------
# sync-templates — 기존 프로젝트를 지금 harness.sh 버전의 skill/role/정책 템플릿과
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

# 기존 프로젝트의 .gitignore에 Harness가 요구하는 줄이 빠져 있으면 채운다.
# evidence/raw/ 처럼 나중에 생긴 경로는 init 시점에만 쓰이면 기존 프로젝트에
# 영영 반영되지 않아, Agent 출력 덤프가 untracked로 노출된다.
_sync_gitignore() {
  # local은 빌트인이라 인자가 "할당 전에" 한꺼번에 단어 확장된다. 같은 local
  # 안에서 방금 선언한 변수를 참조하면 set -u에서 unbound로 죽는다 — 분리한다.
  local target="$1" apply="$2"
  local file="$target/.gitignore" line
  local missing=()
  local required=(".harness/runtime/" ".harness/evidence/raw/" ".harness/worktrees/" ".harness/remote-mount/")
  [[ -f "$file" ]] || return 0
  for line in "${required[@]}"; do
    grep -qxF "$line" "$file" || missing+=("$line")
  done
  (( ${#missing[@]} > 0 )) || return 0
  if [[ "$apply" == apply ]]; then
    printf '%s\n' "${missing[@]}" >>"$file"
    info ".gitignore에 누락된 줄을 추가했습니다: ${missing[*]}"
  else
    info ".gitignore에 추가될 줄(--apply 필요): ${missing[*]}"
  fi
}

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
    info "적용 모드 — Skill·역할·정책 템플릿과 .claude/skills/ 링크를 현재 버전으로 갱신합니다."
  else
    HH_SYNC_DRYRUN=1
    info "미리보기 모드(기본값) — 실제로 갱신하려면 --apply. 아래는 바뀌었을 내용이다."
  fi

  write_project_docs "$root" "$name" "$orchestrator" "$worker" "$reviewer" "$fallback"
  write_project_templates "$root" "$name" "$orchestrator" "$worker" "$reviewer" "$fallback"

  # 통합·삭제된 스킬 정리 (BACKLOG 9-4). 옛 스킬 디렉터리와 .claude/skills/ 링크를
  # 제거하고, 어디로 갔는지 매핑을 안내한다. Task 산출물은 건드리지 않는다.
  local removed_map=(
    "harness-interview=harness-spec"
    "harness-reference=harness-spec"
    "harness-verify=harness-work §2 (자체 검증 단계)"
    "harness-status=herdr-harness status --live . + orchestrator.agent.md"
  )
  local entry old_skill new_target old_dir old_link
  local printed_removed_header=0
  for entry in "${removed_map[@]}"; do
    old_skill="${entry%%=*}"; new_target="${entry#*=}"
    old_dir="$root/.agents/skills/$old_skill"
    old_link="$root/.claude/skills/$old_skill"
    [[ -e "$old_dir" || -L "$old_link" || -e "$old_link" ]] || continue
    if [[ "$printed_removed_header" -eq 0 ]]; then
      printf '\n[통합·삭제된 스킬] 아래 스킬은 다른 스킬로 흡수됐다:\n'
      printed_removed_header=1
    fi
    printf '  %s → %s\n' "$old_skill" "$new_target"
    if [[ "$apply" -eq 1 ]]; then
      rm -rf -- "$old_dir"
      [[ -L "$old_link" || -e "$old_link" ]] && rm -f -- "$old_link"
      SYNC_CHANGED+=(".agents/skills/$old_skill (제거 — $new_target로 통합)")
    else
      SYNC_WOULD_CHANGE+=(".agents/skills/$old_skill (제거 예정 — $new_target로 통합)")
    fi
  done
  if [[ "$printed_removed_header" -eq 1 ]]; then
    printf '  ※ AGENTS.md가 이 스킬 이름을 언급한다면 손으로 갱신하세요(자동 갱신 안 함).\n'
  fi

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

  _sync_gitignore "$root" "$([[ "$apply" -eq 1 ]] && printf apply || printf dry-run)"

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

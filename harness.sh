#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

usage() {
  cat <<EOF
Herdr Agent/Skills Harness

사용법:
  $SCRIPT_NAME init PATH [옵션]   새 프로젝트 Harness 생성
  $SCRIPT_NAME start [PATH]       Herdr Session 시작
  $SCRIPT_NAME status [PATH]      현재 STATE.md 출력
  $SCRIPT_NAME doctor             설치 상태 확인
  $SCRIPT_NAME test               Agent 쿼터 없는 자체 테스트
  $SCRIPT_NAME uninstall [--yes]  설치된 Harness 명령 제거

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
  [[ ! -e "$destination" ]] || die "기존 파일을 덮어쓰지 않습니다: $destination"
  temporary="$(mktemp "$parent/.harness-write.XXXXXX")"
  cat >"$temporary"
  chmod 0644 "$temporary"
  mv "$temporary" "$destination"
}

prompt_required() {
  local variable="$1" label="$2" value=""
  while [[ -z "$value" ]]; do
    read -r -e -p "$label: " value
  done
  printf -v "$variable" '%s' "$value"
}

prompt_default() {
  local variable="$1" label="$2" default="$3" value=""
  read -r -e -p "$label [$default]: " value
  printf -v "$variable" '%s' "${value:-$default}"
}

create_skill() {
  local root="$1" name="$2" description="$3" role="$4" action="$5"
  write_file "$root" ".agents/skills/$name/SKILL.md" <<EOF
---
name: $name
description: $description
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# $name

다음 파일을 순서대로 읽는다.

1. \`AGENTS.md\`
2. \`.harness/project.yaml\`
3. \`.harness/policies/\`
4. \`$role\`
5. \`.harness/SPEC.md\`와 \`.harness/STATE.md\`

## 절차

$action

사용자 승인이 필요한 단계에서는 진행을 멈추고 판단을 요청한다. 기존 기록을 임의로 삭제하거나 Agent 스스로 Task를 \`completed\`로 만들지 않는다.
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

  write_file "$target" "AGENTS.md" <<EOF
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

  write_file "$target" "CLAUDE.md" <<'EOF'
# Claude Code Entry

`AGENTS.md`를 공통 정책으로 사용한다. 현재 역할에 맞는 `.agents/roles/*.agent.md`와 `.claude/skills/`의 Harness Skill을 읽는다. Herdr Pane 제어는 `HERDR_ENV=1`일 때만 수행한다.
EOF

  write_file "$target" "GEMINI.md" <<'EOF'
# Antigravity Entry

`AGENTS.md`를 공통 정책으로 사용한다. 현재 역할에 맞는 `.agents/roles/*.agent.md`와 `.agents/skills/`의 Harness Skill을 읽는다. Herdr Pane 제어는 `HERDR_ENV=1`일 때만 수행한다.
EOF

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

  write_file "$target" ".harness/policies/review-policy.yaml" <<EOF
review:
  default_provider: '$reviewer'
  provider_must_differ_from_worker: true
  focus:
    - requirement_coverage
    - correctness
    - regression_risk
    - security_and_secrets
    - maintainability
    - verification_quality
    - documentation_and_handover
EOF

  write_file "$target" ".harness/policies/quota-policy.yaml" <<'EOF'
quota_policy:
  # 정상 실행 중에는 다른 Provider를 호출하지 않는다.
  strategy: failure_only
  automatic_failover: false
  require_handover: true
  require_user_approval: true
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

  write_file "$target" ".harness/tasks/TEMPLATE.yaml" <<EOF
schema_version: '1.0'
task_id: task-000
milestone_id: milestone-000
title: Task 제목
objective: 하나의 검증 가능한 목적
status: draft
primary_worker: '$worker'
reviewer: '$reviewer'
fallback_chain: [$fallback]
dependencies: []
target_files: []
write_scope: []
resources: []
inputs:
  references: []
  artifacts: []
acceptance_criteria:
  - criterion_id: AC-001
    statement: 검증 가능한 완료 조건
    verified_by:
      type: manual-review
      instruction: 구체적인 확인 방법
review_focus: [requirement_coverage, correctness, regression_risk]
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

  write_file "$target" ".agents/roles/interviewer.agent.md" <<'EOF'
# Interviewer

기존 코드·데이터·문서·Dump를 먼저 확인하고 한 번에 2~4개의 핵심 질문만 한다. SPEC을 작성하되 사용자 대신 승인하지 않는다.
EOF
  write_file "$target" ".agents/roles/planner.agent.md" <<'EOF'
# Planner

Project를 Milestone으로, Milestone을 하나의 목적을 가진 Task로 나눈다. 전체 Task 수가 아니라 활성 Task와 병렬 Worker를 제한한다.
EOF
  write_file "$target" ".agents/roles/orchestrator.agent.md" <<'EOF'
# Orchestrator

Herdr에서 승인된 Wave만 실행한다. Task당 Primary Worker 한 명을 유지하고 실패 확인 후에만 Handover와 Provider 교체 승인을 요청한다.
EOF
  write_file "$target" ".agents/roles/worker.agent.md" <<'EOF'
# Worker

현재 Task 하나만 수행한다. Reference Inventory를 읽고 자체 검증과 변경 내용을 기록하며 submitted까지만 제안한다.
EOF
  write_file "$target" ".agents/roles/advisor.agent.md" <<'EOF'
# Advisor

특정 쟁점을 읽기 전용으로 분석하고 짧은 Memo를 반환한다. 기본적으로 호출하지 않으며 구현 파일을 수정하지 않는다.
EOF
  write_file "$target" ".agents/roles/reviewer.agent.md" <<'EOF'
# Reviewer

Worker와 다른 Provider로서 Diff, Criteria, Evidence와 전체 품질을 읽기 전용 검토한다. Reviewed Artifacts와 판정 근거를 남긴다.
EOF

  create_skill "$target" harness-interview "모호한 요구를 인터뷰해 SPEC을 작성할 때 사용한다." ".agents/roles/interviewer.agent.md" "기존 자료를 먼저 확인하고 2~4개씩 질문해 SPEC 초안을 작성한다."
  create_skill "$target" harness-reference "기존 코드·데이터·문서·Dump를 목록화하고 재사용을 판단할 때 사용한다." ".agents/roles/interviewer.agent.md" "자료를 Confirmed, Inferred, Unknown으로 구분해 Reference Inventory를 작성한다."
  create_skill "$target" harness-plan "승인된 SPEC을 Milestone과 원자적 Task로 분해할 때 사용한다." ".agents/roles/planner.agent.md" "Milestone과 Task Contract를 작성하고 첫 Wave의 사용자 승인을 요청한다."
  create_skill "$target" harness-orchestrate "Herdr에서 Worker와 Reviewer를 배정하고 상태를 관리할 때 사용한다." ".agents/roles/orchestrator.agent.md" "HERDR_ENV를 확인하고 승인된 Wave만 실행하며 STATE를 갱신한다."
  create_skill "$target" harness-work "승인된 Task 하나를 구현·분석하고 제출할 때 사용한다." ".agents/roles/worker.agent.md" "현재 Task만 수행하고 자체 검증과 Attempt 기록을 남긴 뒤 submitted를 제안한다."
  create_skill "$target" harness-verify "Task Criterion에 연결된 검증을 실행하고 Evidence를 남길 때 사용한다." ".agents/roles/reviewer.agent.md" "실제 명령, 종료 코드, 결과, 미검증 항목을 Evidence에 기록한다."
  create_skill "$target" harness-review "Worker와 독립적으로 전체 품질을 검토할 때 사용한다." ".agents/roles/reviewer.agent.md" "Diff와 Evidence를 읽기 전용 검토하고 Reviewed Artifacts와 판정을 기록한다."
  create_skill "$target" harness-handover "실패·쿼터·교체 전에 최소 Context를 인계할 때 사용한다." ".agents/roles/worker.agent.md" "완료 작업, Diff, 검증, 위험, 다음 한 단계를 Handover에 기록한다."
  create_skill "$target" harness-status "프로젝트 진행 상황과 사용자 결정 항목을 요약할 때 사용한다." ".agents/roles/orchestrator.agent.md" "STATE, 현재 Task, Review, Handover를 읽고 짧은 상태 요약을 제공한다."

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

  info "생성 완료: $target"
  info "다음 단계: cd '$target' && herdr-harness start ."
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
  local root
  root="$(project_root "${1:-.}")"
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

  "$SELF_PATH" init "$test_project" \
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
    .agents/roles/orchestrator.agent.md .agents/roles/worker.agent.md .agents/roles/reviewer.agent.md
    .agents/skills/harness-interview/SKILL.md .agents/skills/harness-plan/SKILL.md
    .agents/skills/harness-orchestrate/SKILL.md .agents/skills/harness-work/SKILL.md
    .agents/skills/harness-review/SKILL.md .agents/skills/harness-handover/SKILL.md
  )
  local item
  for item in "${required[@]}"; do
    [[ -f "$test_project/$item" ]] || die "자체 테스트 누락 파일: $item"
  done

  for item in "$test_project"/.claude/skills/*/SKILL.md; do
    [[ -f "$item" ]] || die "Claude Skill 연결 실패: $item"
  done

  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "$test_project" <<'PY'
from pathlib import Path
import sys, yaml
root = Path(sys.argv[1])
for path in root.rglob('*.yaml'):
    yaml.safe_load(path.read_text())
PY
  else
    info "PyYAML이 없어 YAML 파싱 테스트는 건너뜁니다."
  fi

  set +e
  "$SELF_PATH" init "$test_project" --name duplicate --goal duplicate >/dev/null 2>&1
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || die "비어 있지 않은 디렉터리 거부 테스트 실패"

  rm -rf -- "$test_root"
  trap - EXIT

  printf 'PASS: Bash 문법\n'
  printf 'PASS: Harness 파일 생성\n'
  printf 'PASS: 공통 Skill과 Claude 연결\n'
  printf 'PASS: 신규 프로젝트 보호\n'
  printf 'PASS: Agent 호출 없음\n'
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
  rmdir "$install_dir" 2>/dev/null || true

  printf 'Harness 제거 완료.\n'
  printf '생성한 프로젝트와 Herdr 설정은 유지됩니다.\n'
}

main() {
  local command="${1:-help}"
  [[ $# -eq 0 ]] || shift
  case "$command" in
    init) cmd_init "$@" ;;
    start) cmd_start "$@" ;;
    status) cmd_status "$@" ;;
    doctor) cmd_doctor "$@" ;;
    test) cmd_test "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    help|-h|--help) usage ;;
    *) die "알 수 없는 명령: $command" ;;
  esac
}

main "$@"

# Part of herdr-harness. Sourced by harness.sh — do not run directly.


cmd_test() {
  bash -n "$SELF_PATH"
  local _lib
  for _lib in "$HARNESS_LIB_DIR"/*.sh; do
    bash -n "$_lib" || die "lib 문법 오류: $_lib"
  done
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
    .agents/skills/harness-spec/SKILL.md .agents/skills/harness-plan/SKILL.md
    .agents/skills/harness-orchestrate/SKILL.md .agents/skills/harness-work/SKILL.md
    .agents/skills/harness-review/SKILL.md .agents/skills/harness-handover/SKILL.md
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
  local auto_step_body quota_retry_body automation_lib="$HARNESS_LIB_DIR/60-automation.sh"
  auto_step_body="$(awk '/^cmd_auto_step\(\) \{$/{flag=1} flag{print} flag && /^}$/{exit}' "$automation_lib")"
  printf '%s' "$auto_step_body" | grep -qE 'cmd_transition[^\n]*\b(completed|reviewing|awaiting_approval)\b' &&
    die "auto_step 안전 불변식 위반: completed/reviewing/awaiting_approval 전이 호출이 발견됐습니다."
  quota_retry_body="$(awk '/^cmd_quota_retry\(\) \{$/{flag=1} flag{print} flag && /^}$/{exit}' "$automation_lib")"
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

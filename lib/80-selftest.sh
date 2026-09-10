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
    .harness/policies/review-policy.yaml .harness/policies/remote.yaml
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

  # approve: 명시 승인 확인 뒤 승인 기록 생성 + 기존 completed 전이 재사용.
  make_approval_task() {
    local approval_task_id="$1" declared_id="${2:-$1}" task_state="${3:-awaiting_approval}"
    sed -e "s/^task_id: .*/task_id: $declared_id/" \
        -e 's/^milestone_id: .*/milestone_id: milestone-001/' \
        -e "s/^status: .*/status: $task_state/" \
        "$test_project/.harness/tasks/TEMPLATE.yaml" \
        >"$test_project/.harness/tasks/$approval_task_id.yaml"
  }

  local approve_no_confirm=task-approve-no-confirm
  make_approval_task "$approve_no_confirm"
  printf '판정: APPROVED\n' >"$test_project/.harness/reviews/$approve_no_confirm-review-1.md"
  expect_fail "approve: 명시 확인 플래그 없음" \
    bash "$SELF_PATH" approve "$test_project" "$approve_no_confirm"

  expect_fail "approve: 안전하지 않은 Task ID" \
    bash "$SELF_PATH" approve "$test_project" ../task-escape --confirm-user-approval

  local approve_wrong_state=task-approve-wrong-state
  make_approval_task "$approve_wrong_state" "$approve_wrong_state" active
  printf '판정: APPROVED\n' >"$test_project/.harness/reviews/$approve_wrong_state-review-1.md"
  expect_fail "approve: awaiting_approval 아닌 상태" \
    bash "$SELF_PATH" approve "$test_project" "$approve_wrong_state" --confirm-user-approval

  local approve_id_mismatch=task-approve-id-mismatch
  make_approval_task "$approve_id_mismatch" task-declared-differently
  expect_fail "approve: 파일명과 선언 Task ID 불일치" \
    bash "$SELF_PATH" approve "$test_project" "$approve_id_mismatch" --confirm-user-approval

  local approve_bad_review=task-approve-bad-review
  make_approval_task "$approve_bad_review"
  printf '판정: APPROVED\n' >"$test_project/.harness/reviews/$approve_bad_review-review-1.md"
  printf '판정: CHANGES_REQUESTED\n' >"$test_project/.harness/reviews/$approve_bad_review-review-2.md"
  touch -d '+1 minute' "$test_project/.harness/reviews/$approve_bad_review-review-2.md"
  expect_fail "approve: 최신 Review가 APPROVED 아님" \
    bash "$SELF_PATH" approve "$test_project" "$approve_bad_review" --confirm-user-approval

  local approve_conflict=task-approve-conflict
  make_approval_task "$approve_conflict"
  printf '판정: APPROVED\n' >"$test_project/.harness/reviews/$approve_conflict-review-1.md"
  printf 'Task: %s\n승인: no\n근거 Review: .harness/reviews/%s-review-1.md\n' \
    "$approve_conflict" "$approve_conflict" \
    >"$test_project/.harness/decisions/$approve_conflict-approval.md"
  cp "$test_project/.harness/decisions/$approve_conflict-approval.md" "$test_root/conflict-before.md"
  expect_fail "approve: 기존 승인 파일 충돌" \
    bash "$SELF_PATH" approve "$test_project" "$approve_conflict" --confirm-user-approval
  cmp -s "$test_root/conflict-before.md" "$test_project/.harness/decisions/$approve_conflict-approval.md" ||
    die "approve: 충돌한 기존 승인 파일을 변경했습니다."

  local approve_ok=task-approve-ok approve_record approve_event_count
  make_approval_task "$approve_ok"
  printf '판정: APPROVED\n' >"$test_project/.harness/reviews/$approve_ok-review-1.md"
  expect_pass "approve: 정상 승인" \
    bash "$SELF_PATH" approve "$test_project" "$approve_ok" --confirm-user-approval
  [[ "$(yaml_scalar "$test_project/.harness/tasks/$approve_ok.yaml" status)" == completed ]] ||
    die "approve: 정상 승인 뒤 completed로 전이되지 않았습니다."
  approve_record="$test_project/.harness/decisions/$approve_ok-approval.md"
  approval_record_matches "$approve_record" "$approve_ok" \
    ".harness/reviews/$approve_ok-review-1.md" ||
    die "approve: 생성한 승인 기록의 Task/승인/Review가 올바르지 않습니다."
  grep -q $'\ttransition\ttask-approve-ok\tawaiting_approval\tcompleted\t' \
    "$test_project/.harness/evidence/events.tsv" ||
    die "approve: 기존 transition을 통한 completed 이벤트가 없습니다."
  cp "$approve_record" "$test_root/approve-before-retry.md"
  approve_event_count="$(grep -c $'\ttransition\ttask-approve-ok\t' \
    "$test_project/.harness/evidence/events.tsv")"
  expect_pass "approve: idempotent 재호출" \
    bash "$SELF_PATH" approve "$test_project" "$approve_ok" --confirm-user-approval
  cmp -s "$test_root/approve-before-retry.md" "$approve_record" ||
    die "approve: idempotent 재호출이 승인 기록을 변경했습니다."
  [[ "$(grep -c $'\ttransition\ttask-approve-ok\t' \
      "$test_project/.harness/evidence/events.tsv")" -eq "$approve_event_count" ]] ||
    die "approve: idempotent 재호출이 중복 transition 이벤트를 기록했습니다."

  rm -f \
    "$test_project/.harness/tasks/$approve_no_confirm.yaml" \
    "$test_project/.harness/tasks/$approve_wrong_state.yaml" \
    "$test_project/.harness/tasks/$approve_id_mismatch.yaml" \
    "$test_project/.harness/tasks/$approve_bad_review.yaml" \
    "$test_project/.harness/tasks/$approve_conflict.yaml" \
    "$test_project/.harness/reviews/$approve_no_confirm-review-1.md" \
    "$test_project/.harness/reviews/$approve_wrong_state-review-1.md" \
    "$test_project/.harness/reviews/$approve_bad_review-review-1.md" \
    "$test_project/.harness/reviews/$approve_bad_review-review-2.md" \
    "$test_project/.harness/reviews/$approve_conflict-review-1.md" \
    "$test_project/.harness/decisions/$approve_conflict-approval.md"

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
  printf '%s' "$completion_script" | grep -q 'transition approve dispatch' ||
    die "completion bash 출력에 approve 서브커맨드가 없습니다."

  local help_output approve_help_output
  help_output="$(bash "$SELF_PATH" help)"
  printf '%s' "$help_output" | grep -q 'approve PATH TASK_ID --confirm-user-approval' ||
    die "최상위 도움말에 approve 사용법이 없습니다."
  approve_help_output="$(bash "$SELF_PATH" approve --help)"
  printf '%s' "$approve_help_output" | grep -q 'approve PATH TASK_ID --confirm-user-approval' ||
    die "approve 도움말에 명시 확인 플래그가 없습니다."

  grep -q 'approve .*--confirm-user-approval' \
    "$test_project/.agents/roles/orchestrator.agent.md" ||
    die "생성 Orchestrator 역할 문서에 명시 승인 approve 절차가 없습니다."
  grep -q 'approve .*--confirm-user-approval' \
    "$test_project/.agents/skills/harness-orchestrate/SKILL.md" ||
    die "생성 Orchestrator Skill에 명시 승인 approve 절차가 없습니다."
  grep -q 'approve PATH TASK_ID --confirm-user-approval' \
    "$test_project/.harness/decisions/TEMPLATE.md" ||
    die "생성 Decision 템플릿에 명시 승인 approve 절차가 없습니다."

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

  # --- install.sh: ~/.bashrc completion 로더 멱등 등록·정밀 제거 --------------
  #     설치본(harness.sh만 배포)에는 install.sh가 없으므로 있을 때만 검사한다.
  local install_sh fake_home fake_bashrc
  install_sh="$(dirname "$SELF_PATH")/install.sh"
  if [[ -f "$install_sh" ]]; then
    fake_home="$test_root/fake-home"
    fake_bashrc="$fake_home/.bashrc"
    mkdir -p "$fake_home"
    printf '# user marker line\nexport EXAMPLE=1\n' >"$fake_bashrc"

    run_fake_install() {
      HOME="$fake_home" XDG_DATA_HOME="$fake_home/.local/share" \
        bash "$install_sh" "$@" >/dev/null 2>&1
    }

    run_fake_install || die "install.sh(임시 HOME) 첫 실행 실패"
    run_fake_install || die "install.sh(임시 HOME) 재실행 실패"

    grep -qxF '# user marker line' "$fake_bashrc" ||
      die "install.sh가 기존 .bashrc 사용자 줄(marker)을 보존하지 않았습니다."
    grep -qxF 'export EXAMPLE=1' "$fake_bashrc" ||
      die "install.sh가 기존 .bashrc 사용자 줄을 보존하지 않았습니다."
    [[ "$(grep -cxF 'source <(herdr-harness completion bash)' "$fake_bashrc")" -eq 1 ]] ||
      die "반복 설치 후 completion 로더 줄이 정확히 1개가 아닙니다."
    [[ -L "$fake_home/.local/bin/herdr-harness" ]] ||
      die "install.sh(임시 HOME)가 herdr-harness 명령을 만들지 않았습니다."

    # 경로 1: install.sh --uninstall — 관리 블록만 제거, 사용자 줄 보존
    run_fake_install --uninstall || die "install.sh --uninstall(임시 HOME) 실패"
    grep -q 'herdr-harness completion bash' "$fake_bashrc" &&
      die "install.sh --uninstall이 completion 로더 줄을 제거하지 않았습니다."
    grep -q 'herdr-harness bash completion' "$fake_bashrc" &&
      die "install.sh --uninstall 후 관리 마커가 남아 있습니다."
    grep -qxF '# user marker line' "$fake_bashrc" ||
      die "install.sh --uninstall이 사용자 줄을 훼손했습니다."

    # 경로 2: herdr-harness uninstall — 동일하게 관리 블록만 정리
    run_fake_install || die "install.sh 재설치(임시 HOME) 실패"
    [[ "$(grep -cxF 'source <(herdr-harness completion bash)' "$fake_bashrc")" -eq 1 ]] ||
      die "재설치 후 completion 로더 줄이 1개가 아닙니다."
    HOME="$fake_home" XDG_DATA_HOME="$fake_home/.local/share" \
      bash "$SELF_PATH" uninstall --yes >/dev/null 2>&1 ||
      die "herdr-harness uninstall --yes(임시 HOME) 실패"
    grep -q 'herdr-harness completion bash' "$fake_bashrc" &&
      die "herdr-harness uninstall이 completion 관리 블록을 제거하지 않았습니다."
    grep -qxF '# user marker line' "$fake_bashrc" ||
      die "herdr-harness uninstall이 사용자 줄을 훼손했습니다."

    # 마커 없이 사용자가 직접 넣은 줄은 설치기가 중복 등록하지 않고, 제거도 하지 않는다.
    printf '# user marker line\nsource <(herdr-harness completion bash)\n' >"$fake_bashrc"
    run_fake_install || die "install.sh(수동 줄 존재) 실행 실패"
    [[ "$(grep -cxF 'source <(herdr-harness completion bash)' "$fake_bashrc")" -eq 1 ]] ||
      die "수동 completion 줄이 있는데 설치기가 중복 등록했습니다."
    run_fake_install --uninstall || die "install.sh --uninstall(수동 줄) 실패"
    grep -qxF 'source <(herdr-harness completion bash)' "$fake_bashrc" ||
      die "install.sh --uninstall이 사용자가 직접 넣은 마커 없는 줄을 제거했습니다."

    unset -f run_fake_install
    rm -rf "$fake_home"
  else
    info "install.sh가 없어(설치본) ~/.bashrc 등록 테스트는 건너뜁니다."
  fi

  # ---------------------------------------------------------------------------
  # 원격 실행 모드: 설정이 꺼져 있으면 어떤 remote 하위 명령도 SSH를 시도하지
  # 않고 거부해야 한다. 여기서는 네트워크를 쓰지 않는 게이트만 검증한다.
  # ---------------------------------------------------------------------------
  grep -q '^  enabled: false$' "$test_project/.harness/policies/remote.yaml" ||
    die "init 기본값은 원격 모드 비활성(enabled: false)이어야 합니다."

  local remote_message
  set +e
  remote_message="$(bash "$SELF_PATH" remote "$test_project" status 2>&1)"
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || die "비활성 원격 모드에서 remote status가 실행됐습니다."
  printf '%s' "$remote_message" | grep -q '원격 모드가 꺼져' ||
    die "비활성 원격 모드 거부 메시지가 없습니다: $remote_message"

  expect_fail "remote: Harness 프로젝트 아님" \
    bash "$SELF_PATH" remote "$test_root" status
  bash "$SELF_PATH" remote help >/dev/null || die "remote help 실패"

  # enabled: true로 바꾸면 필수 키 검증과 인자 검증이 살아난다(여기까지도 SSH 없음).
  local remote_project="$test_root/remote-project"
  bash "$SELF_PATH" init "$remote_project" \
    --name remote-project --goal "원격 실행 모드 테스트" \
    --remote-host 203.0.113.9 --remote-user builder \
    --remote-path /srv/remote-project --remote-vcs svn >/dev/null
  grep -q "^  enabled: true$" "$remote_project/.harness/policies/remote.yaml" ||
    die "--remote-host를 줬는데 원격 모드가 켜지지 않았습니다."
  grep -q "^  vcs: 'svn'$" "$remote_project/.harness/policies/remote.yaml" ||
    die "--remote-vcs 값이 반영되지 않았습니다."
  if grep -qi 'password' "$remote_project/.harness/policies/remote.yaml"; then
    die "remote.yaml에 비밀번호 관련 키가 있으면 안 됩니다."
  fi
  grep -qx '\.harness/remote-mount/' "$remote_project/.gitignore" ||
    die ".gitignore에 원격 마운트 경로가 없습니다."

  expect_fail "init: --remote-host만 주고 --remote-path 누락" \
    bash "$SELF_PATH" init "$test_root/remote-no-path" --name r --goal g --remote-host h
  expect_fail "init: 잘못된 --remote-vcs" \
    bash "$SELF_PATH" init "$test_root/remote-bad-vcs" --name r --goal g --remote-vcs hg
  expect_fail "remote run: 명령 인자 없음" \
    bash "$SELF_PATH" remote "$remote_project" run
  expect_fail "remote vcs: 하위 명령 없음" \
    bash "$SELF_PATH" remote "$remote_project" vcs

  # 오타 하위 명령을 경로로 삼켜 도움말만 찍고 0으로 끝내면 안 된다.
  expect_fail "remote: 알 수 없는 하위 명령(단일 인자)" \
    bash "$SELF_PATH" remote teleport
  expect_fail "remote: 알 수 없는 하위 명령(PATH 뒤)" \
    bash "$SELF_PATH" remote "$remote_project" teleport
  bash "$SELF_PATH" remote "$remote_project" help >/dev/null ||
    die "remote PATH help 실패"

  # SSH 목적지 옵션 인젝션(-oProxyCommand=...)과 원격 경로 탈출을 설정·환경변수
  # 양쪽에서 막아야 한다. 여기서도 SSH는 시도하지 않는다(검증 단계에서 종료).
  expect_fail "init: -로 시작하는 --remote-user" \
    bash "$SELF_PATH" init "$test_root/remote-bad-user" --name r --goal g \
      --remote-host h --remote-path /srv/p --remote-user '-oProxyCommand=touch /tmp/pwned'
  expect_fail "init: 상대경로 --remote-path" \
    bash "$SELF_PATH" init "$test_root/remote-rel-path" --name r --goal g \
      --remote-host h --remote-path srv/p
  expect_fail "remote: 환경변수로 주입한 옵션형 user" \
    env HH_REMOTE_USER='-oProxyCommand=touch /tmp/pwned' \
      bash "$SELF_PATH" remote "$remote_project" status
  expect_fail "remote: 환경변수로 주입한 상대 path" \
    env HH_REMOTE_PATH='srv/p' bash "$SELF_PATH" remote "$remote_project" status

  # 값 뒤 주석과 중복 키: 사람이 직접 편집하는 파일이므로 오파싱/조용한 무시 금지.
  local remote_config="$remote_project/.harness/policies/remote.yaml"
  local remote_config_backup="$test_root/remote.yaml.bak"
  cp "$remote_config" "$remote_config_backup"
  sed -i "s|^  host: .*|  host: 'build.internal' # 사내 빌드 서버|" "$remote_config"
  # status는 SSH 확인 실패로 비영 종료할 수 있다(테스트 환경엔 원격이 없다).
  # 여기서 보는 것은 파싱 결과 한 줄뿐이므로 종료 코드는 무시한다.
  local remote_status_output=""
  set +e
  remote_status_output="$(bash "$SELF_PATH" remote "$remote_project" status 2>&1)"
  set -e
  printf '%s' "$remote_status_output" | grep -q "^원격 대상:  builder@build.internal$" ||
    die "값 뒤 주석이 있는 host를 잘못 파싱했습니다: $remote_status_output"
  cp "$remote_config_backup" "$remote_config"
  # 필수 키(host)와 선택 키(mount_path) 모두에서 중복이 잡혀야 한다. 선택 키는
  # 값이 비어도 기본값으로 진행할 수 있어, 검사가 서브셸에서 삼켜지면 조용히
  # 통과하던 자리다.
  local duplicate_key
  for duplicate_key in "  host: 'other.internal'" "  mount_path: '/tmp/other-mount'"; do
    cp "$remote_config_backup" "$remote_config"
    printf '%s\n' "$duplicate_key" >>"$remote_config"
    expect_fail "remote: remote.yaml 중복 키(${duplicate_key%%:*})" \
      bash "$SELF_PATH" remote "$remote_project" status
  done
  cp "$remote_config_backup" "$remote_config"

  # YAML 주석 규칙: #는 줄 첫머리이거나 앞이 공백일 때만 주석이다.
  # `enabled: true#x`를 true로 읽어 원격 모드가 켜지면 안 된다.
  sed -i "s|^  enabled: .*|  enabled: true#disabled|" "$remote_config"
  local enabled_message
  set +e
  enabled_message="$(bash "$SELF_PATH" remote "$remote_project" status 2>&1)"
  set -e
  printf '%s' "$enabled_message" | grep -q '원격 모드가 꺼져' ||
    die "값에 붙은 #를 주석으로 오파싱했습니다: $enabled_message"
  cp "$remote_config_backup" "$remote_config"

  # 포트가 붙은 호스트, 개행이 든 값은 init 단계에서 거부한다.
  expect_fail "init: 포트가 붙은 --remote-host" \
    bash "$SELF_PATH" init "$test_root/remote-host-port" --name r --goal g \
      --remote-host host.example:22 --remote-path /srv/p
  expect_fail "init: 개행이 든 --remote-path" \
    bash "$SELF_PATH" init "$test_root/remote-newline" --name r --goal g \
      --remote-host host.example --remote-path "$(printf '/srv/one\ntwo')"

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
  printf 'PASS: 명시 승인 approve (정상/멱등/무확인/상태/Review/Task ID/충돌 거부)\n'
  printf 'PASS: 이벤트 로그 기록\n'
  printf 'PASS: validate 검증 (정상/Worker=Reviewer/Git 누락)\n'
  printf 'PASS: 스텝 명령 인자 검증\n'
  printf 'PASS: Agent 호출 없음\n'
  printf 'PASS: 탭 완성 스크립트 문법\n'
  printf 'PASS: 원격 실행 모드 (opt-in 게이트/하위 명령 오타 거부/SSH 옵션·경로 인젝션 차단/YAML 주석·중복 키/비밀번호 미저장)\n'
  printf 'PASS: Task Lock (동시 획득 거부/release/stale 회수)\n'
  printf 'PASS: quota-retry/auto-step opt-in 게이트\n'
  printf 'PASS: quota-retry/auto-step 안전 불변식(completed/reviewing/awaiting_approval/ready 미호출, handover stub 선행)\n'
  printf 'PASS: sync-templates (dry-run 무변경 감지·미적용, apply 갱신·멱등, AGENTS.md/STATE.md 비침범)\n'
  printf 'PASS: install.sh ~/.bashrc completion 등록(멱등·사용자 줄 보존·두 제거 경로·수동 줄 비침범)\n'
}

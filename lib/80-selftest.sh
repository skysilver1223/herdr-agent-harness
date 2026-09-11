# Part of herdr-harness. Sourced by harness.sh — do not run directly.


cmd_test() {
  # 이후 띄우는 모든 하위 harness 프로세스에도 전달한다. 신규 models 검사는
  # _models_query_agy를 함수 스텁으로 교체하며, 그 밖의 실제 조회는 125로 막힌다.
  export HH_HARNESS_SELFTEST=1
  bash -n "$SELF_PATH"
  local _lib
  for _lib in "$HARNESS_LIB_DIR"/*.sh; do
    bash -n "$_lib" || die "lib 문법 오류: $_lib"
  done
  local test_root test_project failure_status
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/herdr-harness-test.XXXXXX")"
  test_project="$test_root/sample-project"
  trap 'case "${test_root:-}" in "${TMPDIR:-/tmp}"/herdr-harness-test.*) rm -rf -- "$test_root" ;; esac' EXIT

  # 하위 프로세스가 실수로 _models_query_agy 기본 구현에 도달해도 실제 CLI를
  # 시작하지 않는다. models 동작 검사는 아래에서 이 함수 자체를 시나리오별로
  # 스텁하고, 이 PATH 스텁은 self-test 전체의 마지막 안전망이다.
  local provider_stub_dir="$test_root/provider-stubs"
  local provider_stub_log="$test_root/provider-stub-invocations.log"
  mkdir -p "$provider_stub_dir"
  cat >"$provider_stub_dir/agy" <<'PROVIDER_STUB'
#!/usr/bin/env bash
printf 'agy %s\n' "$*" >>"${HH_PROVIDER_STUB_LOG:?}"
exit 125
PROVIDER_STUB
  chmod +x "$provider_stub_dir/agy"
  export HH_PROVIDER_STUB_LOG="$provider_stub_log"
  export PATH="$provider_stub_dir:$PATH"

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
    .harness/policies/agent-policy.yaml
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
  _ac_set_criteria() {
    python3 - "$1" "$2" <<'AC_PY'
import sys, re
path, block = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
text = re.sub(r'(?ms)^acceptance_criteria:.*?(?=^[^\s#])', block, text)
open(path, 'w', encoding='utf-8').write(text)
AC_PY
  }

  printf "task: 'task-001'\nrole: 'worker'\nattempt: 1\nresult:\n  summary: 'x'\nstatus: 'settled'\n" \
    >"$test_project/.harness/evidence/task-001-worker-attempt-1.yaml"

  # Evidence 게이트는 이름과 필수 필드를 함께 본다 — 글롭만 보면 빈 yaml 하나로
  # 통과한다(checks 파일까지 같은 글롭에 걸린다).
  local stray="$test_project/.harness/evidence/task-001-garbage.yaml"
  local real_evidence="$test_project/.harness/evidence/task-001-worker-attempt-1.yaml"
  local saved_evidence="$test_root/saved-evidence.yaml"
  mv "$real_evidence" "$saved_evidence"
  : >"$stray"
  expect_fail "active->submitted (이름만 맞는 쓰레기 yaml)" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted
  printf "task: 'task-001'\nrole: 'worker'\nattempt: 1\nstatus: 'settled'\n" >"$real_evidence"
  expect_fail "active->submitted (필수 필드 빠진 Evidence)" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted
  rm -f "$stray"
  mv "$saved_evidence" "$real_evidence"

  # verified_by 블록 밖의 type/command를 주우면 검증을 건너뛰고 통과시킨다.
  _ac_set_criteria "$task" "acceptance_criteria:
  - criterion_id: AC-001
    statement: verified_by가 없는 항목
    metadata:
      type: manual-review
"
  expect_fail "active->submitted (verified_by 없이 metadata.type만)" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted

  # --- Acceptance Criteria 게이트 -------------------------------------------
  # 지금까지 "verified_by를 실행하라"는 Skill 문서의 지시였을 뿐이라, Agent가
  # 실행하지 않았거나 실패를 무시해도 submitted로 넘어갔다. 이제 Harness가
  # 직접 실행하고 하나라도 실패하면 거부한다.
  _ac_set_criteria "$task" "acceptance_criteria:
  - criterion_id: AC-001
    statement: 실패하는 검증
    verified_by:
      type: command
      command: 'false'
"
  expect_fail "active->submitted (AC 명령 실패)" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted
  grep -q "result: 'fail'" "$test_project/.harness/evidence/task-001-attempt-1-checks.yaml" ||
    die "AC 실패가 checks 파일에 기록되지 않았습니다."

  _ac_set_criteria "$task" "acceptance_criteria:
  - criterion_id: AC-001
    statement: 알 수 없는 검증 방식
    verified_by:
      type: telepathy
      instruction: 없음
"
  expect_fail "active->submitted (알 수 없는 verified_by.type)" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted

  _ac_set_criteria "$task" "acceptance_criteria: []
"
  expect_fail "active->submitted (acceptance_criteria 비어 있음)" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted

  _ac_set_criteria "$task" "acceptance_criteria:
  - criterion_id: AC-001
    statement: 통과하는 검증
    verified_by:
      type: command
      command: 'true'
  - criterion_id: AC-002
    statement: 사람이 봐야 하는 조건
    verified_by:
      type: manual-review
      instruction: Reviewer 확인
"
  expect_pass "active->submitted" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted
  local checks_file="$test_project/.harness/evidence/task-001-attempt-1-checks.yaml"
  grep -q "  passed: 1$" "$checks_file" || die "AC 통과 수가 기록되지 않았습니다."
  grep -q "  manual: 1$" "$checks_file" || die "manual-review가 기록되지 않았습니다."
  grep -q "  failed: 0$" "$checks_file" || die "AC 실패 수가 0으로 기록되지 않았습니다."

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

  # --- Context Packet에 직전 라운드가 들어가는가 ------------------------------
  # 안 들어가면 changes_requested 재시도에서 Worker가 Reviewer 지적을 못 보고
  # 같은 접근을 반복한다 — Rework 지표가 하네스 결함으로 부풀려진다.
  mkdir -p "$test_project/.harness/runtime"
  local packet="$test_project/.harness/runtime/packet-check.md"
  _runtime_context_packet "$test_project" task-001 worker "$task" "$packet" ||
    die "Context Packet 생성에 실패했습니다."
  grep -q '## 직전 시도' "$packet" ||
    die "Context Packet에 직전 시도 절이 없습니다."
  grep -q '최신 Review 판정: APPROVED' "$packet" ||
    die "Context Packet에 최신 Review 판정이 없습니다."
  grep -q 'Acceptance Criteria 검증 결과' "$packet" ||
    die "Context Packet에 AC 검증 결과가 없습니다."
  grep -q '같은 접근을 그대로 반복하지 않는다' "$packet" ||
    die "Context Packet에 재시도 지시가 없습니다."

  # "가장 큰 attempt 번호"가 아니라 "파일이 실제로 있는 최근 attempt"를 찾아야
  # 한다. 번호만 보면 2번 dispatch가 Evidence를 남기기 전에 죽었을 때 1번의
  # 증적과 AC 결과가 통째로 빠진다 — 이 기능이 막으려던 바로 그 상황이다.
  printf '# a2\n' >"$test_project/.harness/attempts/task-001-attempt-2.md"
  _runtime_context_packet "$test_project" task-001 worker "$task" "$packet" ||
    die "Context Packet 재생성에 실패했습니다."
  grep -q 'Acceptance Criteria 검증 결과' "$packet" ||
    die "Attempt 번호만 올라갔는데 직전 AC 결과가 Packet에서 사라졌습니다."
  grep -q 'Evidence (worker' "$packet" ||
    die "Attempt 번호만 올라갔는데 직전 Evidence가 Packet에서 사라졌습니다."
  rm -f "$test_project/.harness/attempts/task-001-attempt-2.md"

  # 첫 시도(이력 없음)에는 아무것도 붙지 않아야 한다.
  local fresh_task="$test_project/.harness/tasks/task-fresh.yaml"
  sed -e 's/^task_id: .*/task_id: task-fresh/' "$task" >"$fresh_task"
  _runtime_context_packet "$test_project" task-fresh worker "$fresh_task" \
    "$test_project/.harness/runtime/packet-fresh.md" ||
    die "첫 시도 Context Packet 생성에 실패했습니다."
  grep -q '직전 시도' "$test_project/.harness/runtime/packet-fresh.md" &&
    die "이력이 없는데 직전 시도 절이 붙었습니다."
  rm -f "$fresh_task"

  expect_fail "dispatch 잘못된 ROLE" \
    bash "$SELF_PATH" dispatch "$test_project" task-001 architect
  expect_fail "observe 인자 부족" \
    bash "$SELF_PATH" observe "$test_project"
  expect_fail "close-agent 기록 없는 Task" \
    bash "$SELF_PATH" close-agent "$test_project" task-999
  expect_fail "adopt --pane 없음" \
    bash "$SELF_PATH" adopt "$test_project" task-001 worker --agent hh-x-w-1
  expect_fail "adopt --agent 없음" \
    bash "$SELF_PATH" adopt "$test_project" task-001 worker --pane pane-1
  expect_fail "adopt 잘못된 ROLE" \
    bash "$SELF_PATH" adopt "$test_project" task-001 architect --pane pane-1 --agent hh-x-w-1
  expect_fail "adopt Agent 이름 형식" \
    bash "$SELF_PATH" adopt "$test_project" task-001 worker --pane pane-1 --agent "Bad Name"

  # --- dispatch --print-only: Herdr 밖에서도 되고, 아무 상태도 남기지 않는다 ---
  # 기본 경로(dispatch)는 Pane 생성까지 하므로 Herdr 안에서만 동작한다.
  # --print-only는 그 게이트를 지나가되 Agent를 띄우지 않으므로, Attempt·meta가
  # 생기면 안 된다 — 실제로 시작하지 않은 시도를 남기면 전이 게이트가 헐거워진다.
  local print_only_output attempts_before attempts_after
  attempts_before="$(find "$test_project/.harness/attempts" -maxdepth 1 -name 'task-001-attempt-*.md' | wc -l)"
  print_only_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$test_project" task-001 worker --print-only)"
  printf '%s' "$print_only_output" | grep -q '^dispatch_result=print_only$' ||
    die "--print-only가 print_only 결과를 내지 않았습니다."
  printf '%s' "$print_only_output" | grep -q 'herdr agent start ' ||
    die "--print-only 출력에 herdr agent start 명령이 없습니다."
  printf '%s' "$print_only_output" | grep -q ' adopt .* --pane PANE_ID --agent ' ||
    die "--print-only 출력에 adopt 등록 명령이 없습니다."
  [[ ! -e "$test_project/.harness/runtime/task-001-worker.meta" ]] ||
    die "--print-only가 Runtime 기록을 남겼습니다."
  attempts_after="$(find "$test_project/.harness/attempts" -maxdepth 1 -name 'task-001-attempt-*.md' | wc -l)"
  [[ "$attempts_before" -eq "$attempts_after" ]] ||
    die "--print-only가 Attempt를 남겼습니다($attempts_before → $attempts_after)."
  [[ -f "$test_project/.harness/runtime/task-001-context-worker.md" ]] ||
    die "--print-only가 Context Packet을 만들지 않았습니다."

  # --- 호출자 게이트: Harness가 띄운 Agent Pane은 전이·승인을 못 한다 -------
  # 승인 우회 정책 때문에 Agent가 셸 명령을 자유롭게 돌릴 수 있게 됐으므로,
  # "상태 전이·완료 승인은 사람 몫"을 지시가 아니라 코드로 막아야 한다.
  mkdir -p "$test_project/.harness/runtime"
  printf 'task_id=task-001\nrole=worker\nagent_name=hh-task-001-w-8\npane_id=wTEST:p99\nprovider=codex\nattempt=8\nadopted=0\n' \
    >"$test_project/.harness/runtime/task-001-worker.meta"
  set +e
  HERDR_PANE_ID=wTEST:p99 bash "$SELF_PATH" transition "$test_project" task-001 blocked >/dev/null 2>&1
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] ||
    die "Agent Pane에서 transition이 실행됐습니다(호출자 게이트 실패)."
  set +e
  HERDR_PANE_ID=wTEST:p99 bash "$SELF_PATH" approve "$test_project" task-001 --confirm-user-approval >/dev/null 2>&1
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] ||
    die "Agent Pane에서 approve가 실행됐습니다(호출자 게이트 실패)."
  # 사람 Pane(기록에 없는 pane_id)은 게이트에 걸리지 않아야 한다 — 여기서는
  # 게이트가 아니라 전이 규칙 때문에 실패하므로 메시지로 구분한다.
  set +e
  local human_error
  human_error="$(HERDR_PANE_ID=wTEST:p1 bash "$SELF_PATH" transition "$test_project" task-001 completed 2>&1)"
  set -e
  [[ "$human_error" != *"Agent Pane에서 실행할 수 없습니다"* ]] ||
    die "사람 Pane인데 호출자 게이트에 걸렸습니다."
  rm -f "$test_project/.harness/runtime/task-001-worker.meta"

  # --- --print-only 출력은 붙여 넣어도 안전하게 인용돼 있어야 한다 ----------
  local tricky_project="$test_root/tricky dir; touch INJECTED"
  bash "$SELF_PATH" init "$tricky_project" --name tricky --goal "인용 검사" >/dev/null
  cp "$test_project/.harness/tasks/task-001.yaml" "$tricky_project/.harness/tasks/task-001.yaml"
  local tricky_output
  tricky_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$tricky_project" task-001 worker --print-only)"
  # 붙여 넣을 명령 줄(두 칸 들여쓴 줄)만 본다 — 맨 위 'Context Packet:' 안내
  # 줄은 명령이 아니라 경로 표시라 인용하지 않는다.
  local tricky_commands
  tricky_commands="$(printf '%s' "$tricky_output" | grep '^  ' || true)"
  printf '%s' "$tricky_commands" | grep -qF 'tricky\ dir\;\ touch\ INJECTED' ||
    die "--print-only 출력의 경로가 셸 인용되지 않았습니다."
  printf '%s' "$tricky_commands" | grep -qF 'tricky dir; touch INJECTED' &&
    die "--print-only 명령 줄에 인용되지 않은 경로가 남아 있습니다."
  [[ ! -e "$test_root/INJECTED" && ! -e "INJECTED" ]] ||
    die "--print-only 인용 검사 중 인젝션이 실행됐습니다."

  # --- dispatch --cwd: Agent를 띄울 디렉터리와 Sandbox 쓰기 범위 -------------
  # 계획 문서를 담은 워크스페이스와 수정 대상 코드 저장소가 다른 디렉터리인
  # 구성에서, 기본값(워크스페이스)으로 띄우면 Worker는 write_scope에 적힌
  # 코드를 한 줄도 쓸 수 없다 — codex --sandbox workspace-write의 쓰기 범위가
  # 기동 디렉터리 기준이기 때문이다. 실제로 그렇게 막힌 사례가 있었다.
  local cwd_default_output cwd_custom_output cwd_target
  cwd_default_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$test_project" task-001 worker --print-only)"
  printf '%s' "$cwd_default_output" | grep -q "pane split .* --cwd $test_project " ||
    die "--cwd를 주지 않았을 때 pane split이 워크스페이스에서 열리지 않습니다."

  cwd_target="$test_root/code-repo"
  mkdir -p "$cwd_target"
  cwd_custom_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$test_project" task-001 worker --print-only --cwd "$cwd_target")"
  printf '%s' "$cwd_custom_output" | grep -q "pane split .* --cwd $cwd_target " ||
    die "--cwd로 준 디렉터리가 pane split 명령에 반영되지 않았습니다."
  printf '%s' "$cwd_custom_output" | grep -q "^Agent 작업 디렉터리: $cwd_target (--cwd)$" ||
    die "--cwd가 print-only 요약에 보고되지 않았습니다."
  # 워크스페이스 경로가 cwd 자리에 남아 있으면 Sandbox 범위가 안 바뀐다.
  printf '%s' "$cwd_custom_output" | grep -q "pane split .* --cwd $test_project " &&
    die "--cwd를 줬는데도 pane split이 워크스페이스를 가리킵니다."

  expect_fail "--cwd에 없는 디렉터리를 줬는데 통과" \
    env HERDR_ENV= bash "$SELF_PATH" dispatch "$test_project" task-001 worker --print-only --cwd "$test_root/no-such-dir"
  expect_fail "--cwd에 값을 주지 않았는데 통과" \
    env HERDR_ENV= bash "$SELF_PATH" dispatch "$test_project" task-001 worker --print-only --cwd

  # 위험한 이름의 디렉터리도 붙여 넣기 안전하게 인용돼야 한다.
  local cwd_tricky="$test_root/code; touch CWD_INJECTED"
  mkdir -p "$cwd_tricky"
  local cwd_tricky_commands
  cwd_tricky_commands="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$test_project" task-001 worker --print-only --cwd "$cwd_tricky" | grep '^  ' || true)"
  printf '%s' "$cwd_tricky_commands" | grep -qF 'code\;\ touch\ CWD_INJECTED' ||
    die "--cwd 경로가 print-only 명령 줄에서 셸 인용되지 않았습니다."
  [[ ! -e "$test_root/CWD_INJECTED" && ! -e "CWD_INJECTED" ]] ||
    die "--cwd 인용 검사 중 인젝션이 실행됐습니다."

  # 실제 `herdr pane split` 호출은 Herdr 안에서만 돌아 자체 테스트가 실행할 수
  # 없다. 그래서 --print-only 출력만 검사하면, 실제 경로를 $root로 되돌려도
  # 테스트는 녹색으로 남는다(실측 확인함). 두 경로가 같은 변수를 쓰는지 소스에서
  # 직접 확인해 그 구멍을 막는다.
  local dispatch_src pane_split_lines
  dispatch_src="$HARNESS_LIB_DIR/55-dispatch.sh"
  pane_split_lines="$(grep -n 'pane split' "$dispatch_src" || true)"
  [[ -n "$pane_split_lines" ]] ||
    die "dispatch에서 pane split 호출을 찾지 못했습니다(파서 확인 필요)."
  printf '%s' "$pane_split_lines" | grep -q 'herdr pane split --current --direction right --cwd "\$agent_cwd"' ||
    die "실제 pane split 호출이 \$agent_cwd를 쓰지 않습니다 — --cwd가 Sandbox 범위에 반영되지 않습니다($dispatch_src)."
  printf '%s' "$pane_split_lines" | grep -q -- '--cwd "\$root"' &&
    die "pane split이 아직 \$root를 직접 씁니다 — --cwd가 무시됩니다($dispatch_src)."

  # --- 모델 선택: Task 역할별 지정 → 정책 기본값 → Provider 기본값 ---------
  # 승인 인수 allowlist에는 --model을 절대 열지 않는다. 모델은 별도 정책 목록의
  # 토큰과 정확히 일치할 때만 같은 agent_args 배열에 들어가며, print-only와
  # 실제 start 경로가 그 배열을 공유해야 한다.
  local model_project="$test_root/model-project" model_policy model_task
  local model_output model_error model_default_task model_invalid_task model_start_line secret_model
  bash "$SELF_PATH" init "$model_project" --name model-project --goal "모델 선택 검사" \
    --worker codex --reviewer agy >/dev/null
  cp "$test_project/.harness/tasks/task-001.yaml" "$model_project/.harness/tasks/task-001.yaml"
  model_policy="$model_project/.harness/policies/agent-policy.yaml"

  # 미지정 Task와 빈 정책 기본값은 종전처럼 모델 인수가 전혀 없어야 한다.
  model_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$model_project" task-001 worker --print-only)"
  model_start_line="$(printf '%s\n' "$model_output" | grep '^  herdr agent start ')"
  [[ "${model_start_line#* --timeout 120000}" == ' -- --ask-for-approval never --sandbox workspace-write' ]] ||
    die "모델 미지정 Task의 기존 Provider 기동 인수가 바뀌었습니다: $model_start_line"
  printf '%s' "$model_output" | grep -q '출처: Provider 기본값 (미지정)' ||
    die "모델 미지정 출처가 Provider 기본값으로 기록되지 않았습니다."

  sed -i "s|^  codex_models:.*|  codex_models: 'gpt-5.6-sol gpt-5.6-terra'|" "$model_policy"
  sed -i "s|^  codex_default_model:.*|  codex_default_model: 'gpt-5.6-terra'|" "$model_policy"
  sed -i "s|^  agy_models:.*|  agy_models: 'gemini-3.8-flash-high gemini-3.1-pro-high'|" "$model_policy"
  sed -i "s|^  agy_default_model:.*|  agy_default_model: 'gemini-3.8-flash-high'|" "$model_policy"

  model_task="$model_project/.harness/tasks/task-model.yaml"
  awk '
    /^task_id:/ { print "task_id: task-model"; next }
    { print }
    /^reviewer:/ {
      print "worker_model: '\''gpt-5.6-sol'\''"
      print "reviewer_model: '\''gemini-3.1-pro-high'\''"
    }
  ' "$test_project/.harness/tasks/task-001.yaml" >"$model_task"

  # Task 지정이 정책 기본값보다 우선하며, worker/reviewer가 각자 자기 필드를 쓴다.
  model_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$model_project" task-model worker --print-only)"
  printf '%s' "$model_output" | grep -q 'herdr agent start .* --model gpt-5.6-sol' ||
    die "worker_model이 Agent 기동 인수에 전달되지 않았습니다."
  printf '%s' "$model_output" | grep -q '출처: Task 지정 (worker_model)' ||
    die "worker_model의 Task 지정 출처가 기록되지 않았습니다."
  printf '%s' "$model_output" | grep -q -- '--model gpt-5.6-terra' &&
    die "Task 지정이 있는데 codex 정책 기본 모델이 이겼습니다."

  model_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$model_project" task-model reviewer --print-only)"
  printf '%s' "$model_output" | grep -q 'herdr agent start .* --model gemini-3.1-pro-high' ||
    die "reviewer_model이 Agent 기동 인수에 전달되지 않았습니다."
  printf '%s' "$model_output" | grep -q '출처: Task 지정 (reviewer_model)' ||
    die "reviewer_model의 Task 지정 출처가 기록되지 않았습니다."

  # 역할 필드가 비어 있으면 Provider별 정책 기본값을 쓴다.
  model_default_task="$model_project/.harness/tasks/task-model-default.yaml"
  sed 's/^task_id:.*/task_id: task-model-default/' \
    "$test_project/.harness/tasks/task-001.yaml" >"$model_default_task"
  model_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$model_project" task-model-default worker --print-only)"
  printf '%s' "$model_output" | grep -q 'herdr agent start .* --model gpt-5.6-terra' ||
    die "Task 모델 미지정 시 Provider 정책 기본 모델이 적용되지 않았습니다."
  printf '%s' "$model_output" | grep -q '출처: 정책 기본값 (codex_default_model)' ||
    die "정책 기본 모델의 출처가 기록되지 않았습니다."

  # 허용 목록 밖의 Task 값은 정책 기본값으로 재해석하지 않고 Provider 기본값으로
  # 내리며 경고한다. 오타 하나로 Wave 전체를 멈추지는 않는다.
  model_invalid_task="$model_project/.harness/tasks/task-model-invalid.yaml"
  sed -e 's/^task_id:.*/task_id: task-model-invalid/' \
      -e "s/^worker_model:.*/worker_model: 'gpt-not-allowed'/" \
    "$model_task" >"$model_invalid_task"
  model_error="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$model_project" task-model-invalid worker --print-only 2>&1)"
  printf '%s' "$model_error" | grep -q '허용 목록에 없어 Provider 기본값' ||
    die "허용 목록 밖 모델에 경고가 나오지 않았습니다."
  printf '%s' "$model_error" | grep -q 'herdr agent start .* --model ' &&
    die "허용 목록 밖 모델이 Agent 기동 인수에 전달됐습니다."

  # Task 문자열과 정책 목록 양쪽에서 플래그 주입을 시도해도 --model argv가
  # 생기지 않아야 한다. 특히 목록 값에서 꺼내더라도 선행 '-' 토큰은 모델 ID가
  # 아니므로 목록 전체를 거부한다.
  sed -e 's/^task_id:.*/task_id: task-model-inject/' \
      -e "s/^worker_model:.*/worker_model: '--add-dir \/'/" \
    "$model_task" >"$model_project/.harness/tasks/task-model-inject.yaml"
  model_error="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$model_project" task-model-inject worker --print-only 2>&1)"
  printf '%s' "$model_error" | grep -q '안전한 모델 ID 형식이 아니어서' ||
    die "Task 모델 플래그 주입 시도가 경고와 함께 거부되지 않았습니다."
  printf '%s' "$model_error" | grep -q 'herdr agent start .* --model ' &&
    die "Task 모델 플래그 주입 값이 Agent 기동 인수에 전달됐습니다."

  sed -i "s|^  codex_models:.*|  codex_models: 'gpt-5.6-sol --add-dir /'|" "$model_policy"
  model_error="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$model_project" task-model worker --print-only 2>&1)"
  printf '%s' "$model_error" | grep -q '모델 ID가 아닌 토큰' ||
    die "정책 모델 목록의 플래그 주입 토큰이 거부되지 않았습니다."
  printf '%s' "$model_error" | grep -q 'herdr agent start .* --model ' &&
    die "오염된 정책 모델 목록이 Agent 기동 인수에 전달됐습니다."

  # 모델 정책에 Secret을 잘못 붙여 넣어도 argv나 경고에 원문이 나타나면 안 된다.
  secret_model='sk-abcdefghijklmnopqrstuvwx'
  sed -i "s|^  codex_models:.*|  codex_models: '$secret_model'|" "$model_policy"
  model_error="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$model_project" task-model worker --print-only 2>&1)"
  printf '%s' "$model_error" | grep -qF "$secret_model" &&
    die "Secret 형태의 모델 정책 값이 dispatch 출력에 노출됐습니다."
  printf '%s' "$model_error" | grep -q 'herdr agent start .* --model ' &&
    die "Secret 형태의 모델 정책 값이 Agent 기동 인수에 전달됐습니다."

  # 실제 start와 print-only가 같은 agent_args 조립 결과를 사용하고, 정상
  # dispatch가 Attempt·Evidence에 모델과 출처를 기록하는지 소스에서도 고정한다.
  grep -q '_runtime_start_agent_when_ready .*"\${agent_args\[@\]}"' "$dispatch_src" ||
    die "실제 agent start 경로가 검증된 agent_args 배열을 쓰지 않습니다."
  grep -q "printf -- '- Started:.*- Model:.*- Model source:" "$dispatch_src" ||
    die "dispatch Attempt에 Model과 Model source 기록이 없습니다."
  grep -q "printf -- '- Captured:.*- Model:.*- Model source:" "$dispatch_src" ||
    die "dispatch Evidence에 Model과 Model source 기록이 없습니다."

  # --- 프리미엄 모델 승인: 좁은 승인 범위 + Provider 기본값 누출 차단 ------
  local premium_project="$test_root/premium-model-project" premium_policy premium_task
  local premium_output premium_error premium_start_line approval_file other_approval
  local pane_stub_dir="$test_root/premium-pane-stub"
  cp -a "$model_project" "$premium_project"
  premium_policy="$premium_project/.harness/policies/agent-policy.yaml"
  sed -i \
    -e "s|^  codex_models:.*|  codex_models: 'gpt-5.6-sol gpt-6-astra gpt-5.6-terra'|" \
    -e "s|^  codex_default_model:.*|  codex_default_model: 'gpt-5.6-sol'|" \
    -e "s|^  codex_premium_models:.*|  codex_premium_models: 'gpt-6-astra'|" \
    "$premium_policy"
  premium_task="$premium_project/.harness/tasks/task-premium.yaml"
  sed -e 's/^task_id:.*/task_id: task-premium/' \
      -e "s/^worker_model:.*/worker_model: 'gpt-6-astra'/" \
    "$model_task" >"$premium_task"
  approval_file="$premium_project/.harness/decisions/task-premium-model-approval.md"

  # 승인 없음: 프리미엄 token은 argv에 없고 비프리미엄 정책 기본값으로 한 번
  # 강등한다. 경고와 승인 거부 근거도 print-only 결과에 함께 드러난다.
  premium_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-premium worker --print-only 2>&1)"
  premium_start_line="$(printf '%s\n' "$premium_output" | grep '^  herdr agent start ')"
  [[ "$premium_start_line" == *'--model gpt-5.6-sol'* && "$premium_start_line" != *'gpt-6-astra'* ]] ||
    die "승인 없는 프리미엄 모델이 안전한 비프리미엄 모델로 강등되지 않았습니다: $premium_start_line"
  printf '%s' "$premium_output" | grep -q '프리미엄 모델 승인이 없어 요청을 강등' ||
    die "승인 없는 프리미엄 모델 강등 경고가 없습니다."
  printf '%s' "$premium_output" | grep -q '프리미엄 모델 승인: 거부 — 승인 기록 없음' ||
    die "승인 없는 프리미엄 모델의 거부 근거가 기록되지 않았습니다."

  # 정확한 Task+역할+모델+yes만 승인한다. 파일의 모델 값은 비교에만 쓰고,
  # argv에는 계속 허용 목록에서 찾은 token이 들어간다.
  printf '%s\n' \
    '- Task: task-premium' '- 역할: worker' '- 모델: gpt-6-astra' '- 승인: yes' \
    >"$approval_file"
  premium_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-premium worker --print-only 2>&1)"
  printf '%s' "$premium_output" | grep -q 'herdr agent start .* --model gpt-6-astra' ||
    die "정확히 승인된 프리미엄 모델이 argv에 전달되지 않았습니다."
  printf '%s' "$premium_output" | grep -q '프리미엄 모델 승인: 승인됨 (.harness/decisions/task-premium-model-approval.md)' ||
    die "프리미엄 모델 승인 근거 경로가 기록되지 않았습니다."

  printf '%s\n' \
    '- Task: task-premium' '- 역할: reviewer' '- 모델: gpt-6-astra' '- 승인: yes' \
    >"$approval_file"
  premium_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-premium worker --print-only 2>&1)"
  printf '%s' "$premium_output" | grep -q '역할 불일치' ||
    die "승인 파일 역할 불일치 사유가 경고에 없습니다."
  printf '%s' "$premium_output" | grep -q 'herdr agent start .* --model gpt-6-astra' &&
    die "다른 역할의 승인으로 프리미엄 모델이 전달됐습니다."

  printf '%s\n' \
    '- Task: task-other' '- 역할: worker' '- 모델: gpt-6-astra' '- 승인: yes' \
    >"$approval_file"
  premium_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-premium worker --print-only 2>&1)"
  printf '%s' "$premium_output" | grep -q 'Task 불일치' ||
    die "승인 파일 Task 불일치 사유가 경고에 없습니다."
  printf '%s' "$premium_output" | grep -q 'herdr agent start .* --model gpt-6-astra' &&
    die "다른 Task 값의 승인으로 프리미엄 모델이 전달됐습니다."

  printf '%s\n' \
    '- Task: task-premium' '- 역할: worker' '- 모델: gpt-5.6-terra' '- 승인: yes' \
    >"$approval_file"
  premium_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-premium worker --print-only 2>&1)"
  printf '%s' "$premium_output" | grep -q '모델 불일치' ||
    die "승인 파일 모델 불일치 사유가 경고에 없습니다."
  printf '%s' "$premium_output" | grep -q 'herdr agent start .* --model gpt-6-astra' &&
    die "다른 모델의 승인으로 프리미엄 모델이 전달됐습니다."

  rm -f "$approval_file"
  other_approval="$premium_project/.harness/decisions/task-other-model-approval.md"
  printf '%s\n' \
    '- Task: task-other' '- 역할: worker' '- 모델: gpt-6-astra' '- 승인: yes' \
    >"$other_approval"
  premium_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-premium worker --print-only 2>&1)"
  printf '%s' "$premium_output" | grep -q '승인이 없어 요청을 강등' ||
    die "다른 Task 전용 승인 파일이 현재 Task의 승인 없음으로 처리되지 않았습니다."
  printf '%s' "$premium_output" | grep -q 'herdr agent start .* --model gpt-6-astra' &&
    die "다른 Task 전용 승인으로 프리미엄 모델이 전달됐습니다."

  printf '%s\n' \
    '- Task: task-premium' '- 역할: worker' '- 모델: gpt-6-astra' '- 승인: no' \
    >"$approval_file"
  premium_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-premium worker --print-only 2>&1)"
  printf '%s' "$premium_output" | grep -q '승인 값이 yes가 아님' ||
    die "yes가 아닌 승인 값의 거부 사유가 경고에 없습니다."
  printf '%s' "$premium_output" | grep -q 'herdr agent start .* --model gpt-6-astra' &&
    die "yes가 아닌 승인으로 프리미엄 모델이 전달됐습니다."

  # 프리미엄 목록이 비면 같은 모델은 일반 허용 모델로서 종전과 동일하게
  # 승인 파일 없이 전달된다(게이트 opt-in 및 task-006 하위 호환).
  sed -i "s|^  codex_premium_models:.*|  codex_premium_models: ''|" "$premium_policy"
  rm -f "$approval_file"
  premium_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-premium worker --print-only 2>&1)"
  printf '%s' "$premium_output" | grep -q 'herdr agent start .* --model gpt-6-astra' ||
    die "빈 프리미엄 목록이 기존 모델 선택 argv를 바꿨습니다."

  # 게이트가 켜진 모델 미지정 Task는 Provider CLI 기본값을 쓰지 않는다.
  sed -i "s|^  codex_premium_models:.*|  codex_premium_models: 'gpt-6-astra'|" "$premium_policy"
  premium_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-model-default worker --print-only 2>&1)"
  premium_start_line="$(printf '%s\n' "$premium_output" | grep '^  herdr agent start ')"
  [[ "$premium_start_line" == *'--model gpt-5.6-sol'* ]] ||
    die "프리미엄 정책이 있는데 모델 미지정 dispatch가 비프리미엄 모델을 명시하지 않았습니다."

  # 정책 기본값 자체가 프리미엄이면 미승인 고정값으로 쓰지 않고 목록의 첫
  # 비프리미엄 token을 사용하며, 사용자가 고른 값이 아님을 출처에 남긴다.
  sed -i "s|^  codex_default_model:.*|  codex_default_model: 'gpt-6-astra'|" "$premium_policy"
  premium_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-model-default worker --print-only 2>&1)"
  premium_start_line="$(printf '%s\n' "$premium_output" | grep '^  herdr agent start ')"
  [[ "$premium_start_line" == *'--model gpt-5.6-sol'* && "$premium_start_line" != *'gpt-6-astra'* ]] ||
    die "프리미엄 정책 기본값이 승인 없이 고정값으로 사용됐습니다."
  printf '%s' "$premium_output" | grep -q '출처: 정책 목록 첫 비프리미엄 (누출 차단)' ||
    die "목록에서 고른 누출 차단 모델의 출처가 기록되지 않았습니다."

  # 고정할 비프리미엄 모델이 없으면 Provider 기본값으로 fail-open하지 않는다.
  sed -i \
    -e "s|^  codex_models:.*|  codex_models: 'gpt-6-astra'|" \
    -e "s|^  codex_default_model:.*|  codex_default_model: 'gpt-6-astra'|" \
    "$premium_policy"
  set +e
  premium_error="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-premium worker --print-only 2>&1)"
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || die "전부 프리미엄인 정책이 dispatch를 거부하지 않았습니다."
  printf '%s' "$premium_error" | grep -q '고정할 비프리미엄 모델이 없습니다.*codex_default_model' ||
    die "비프리미엄 고정 불가 오류에 default_model 설정 안내가 없습니다."

  # 프리미엄 선언 하나라도 허용 목록과 정확히 맞지 않으면 강등이 아니라
  # 설정 오류로 Pane 생성 전에 거부한다.
  sed -i \
    -e "s|^  codex_models:.*|  codex_models: 'gpt-5.6-sol gpt-6-astra'|" \
    -e "s|^  codex_default_model:.*|  codex_default_model: 'gpt-5.6-sol'|" \
    -e "s|^  codex_premium_models:.*|  codex_premium_models: 'gpt-6-astra gpt-unknown-premium'|" \
    "$premium_policy"
  set +e
  premium_error="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-premium worker --print-only 2>&1)"
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || die "허용 목록과 불일치하는 프리미엄 선언이 fail-open했습니다."
  printf '%s' "$premium_error" | grep -q '정책 오류(fail-open 차단).*허용 목록과 정확히 일치하지 않습니다' ||
    die "프리미엄 선언 불일치가 승인 없음 강등과 구분된 오류를 내지 않았습니다."
  [[ "$premium_error" != *'승인이 없어 요청을 강등'* ]] ||
    die "프리미엄 선언 설정 오류가 승인 없음 강등으로 잘못 보고됐습니다."

  # Agent Pane에서 실행된 dispatch는 내용이 정확한 승인 파일도 인정하지 않는다.
  sed -i "s|^  codex_premium_models:.*|  codex_premium_models: 'gpt-6-astra'|" "$premium_policy"
  printf '%s\n' \
    '- Task: task-premium' '- 역할: worker' '- 모델: gpt-6-astra' '- 승인: yes' \
    >"$approval_file"
  printf '%s\n' 'pane_id=wPREMIUM:p9' \
    >"$premium_project/.harness/runtime/task-existing-worker.meta"
  mkdir -p "$pane_stub_dir"
  cat >"$pane_stub_dir/herdr" <<'PREMIUM_HERDR_STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == pane && "${2:-}" == current ]]; then
  printf '{"pane_id":"wPREMIUM:p9"}\n'
  exit 0
fi
exit 125
PREMIUM_HERDR_STUB
  chmod +x "$pane_stub_dir/herdr"
  premium_output="$(PATH="$pane_stub_dir:$PATH" HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-premium worker --print-only 2>&1)"
  printf '%s' "$premium_output" | grep -q 'Agent Pane에서 실행된 dispatch' ||
    die "Agent Pane dispatch가 프리미엄 승인을 인정하지 않는다는 경고가 없습니다."
  printf '%s' "$premium_output" | grep -q 'herdr agent start .* --model gpt-6-astra' &&
    die "Agent Pane에서 자기 승인한 프리미엄 모델이 argv에 전달됐습니다."

  # 승인 파일의 모델 값은 비교 전용이다. 플래그·셸 메타문자와 중복 필드가
  # 있어도 어느 조각도 argv에 닿지 않고 승인 자체가 거부되어야 한다.
  printf '%s\n' \
    '- Task: task-premium' '- 역할: worker' '- 모델: --add-dir /;touch APPROVAL_INJECTED' \
    '- 모델: gpt-6-astra' '- 승인: yes' >"$approval_file"
  premium_output="$(HERDR_ENV= bash "$SELF_PATH" dispatch "$premium_project" task-premium worker --print-only 2>&1)"
  printf '%s' "$premium_output" | grep -q '모델 필드 누락 또는 중복' ||
    die "중복·오염된 승인 모델 필드가 거부되지 않았습니다."
  printf '%s' "$premium_output" | grep -q -- '--add-dir\|APPROVAL_INJECTED' &&
    die "승인 파일의 모델 문자열이 dispatch argv 또는 출력에 닿았습니다."

  grep -q "printf -- '- Started:.*- Model approval:" "$dispatch_src" ||
    die "dispatch Attempt에 프리미엄 모델 승인 근거 기록이 없습니다."
  grep -q "printf -- '- Captured:.*- Model approval:" "$dispatch_src" ||
    die "dispatch Evidence에 프리미엄 모델 승인 근거 기록이 없습니다."

  # --- models: 실제 Provider 호출 없이 목록 diff·정책 갱신·보존 검증 ------
  local models_project="$test_root/models-command-project" models_policy models_out
  local models_before="$test_root/models-before.yaml" models_once="$test_root/models-once.yaml"
  cp -a "$test_project" "$models_project"
  models_policy="$models_project/.harness/policies/agent-policy.yaml"
  sed -i \
    -e "s|^  claude_models:.*|  claude_models: 'claude-fable-5 claude-opus-4-6'|" \
    -e "s|^  codex_models:.*|  codex_models: 'gpt-5.6-sol gpt-6-astra'|" \
    -e "s|^  agy_models:.*|  agy_models: 'agy-keep agy-remove agy-premium-removed' # 사용자 모델 주석|" \
    -e "s|^  claude_premium_models:.*|  claude_premium_models: 'fable'|" \
    -e "s|^  codex_premium_models:.*|  codex_premium_models: 'gpt-6-astra'|" \
    -e "s|^  agy_premium_models:.*|  agy_premium_models: 'agy-premium-removed'|" \
    "$models_policy"
  sed -i '/^  approval_mode:/i\  # 사용자 정책 주석 — models가 보존해야 함' "$models_policy"

  _models_query_agy() {
    printf '%s\n' \
      'MODEL DISPLAY NAME' \
      'agy-new New model' \
      'agy-keep Kept model'
  }
  _models_now_utc() { printf '2026-09-11T07:00:00Z'; }

  # 기본 표시, --apply만, --refresh dry-run은 모두 정책 파일을 쓰지 않는다.
  cp "$models_policy" "$models_before"
  models_out="$(cmd_models "$models_project")"
  cmp -s "$models_policy" "$models_before" ||
    die "models 기본 표시가 정책 파일을 변경했습니다."
  printf '%s' "$models_out" | grep -q 'claude.*조회 경로 없음 — 수동 관리' ||
    die "models가 조회 불가 Provider를 수동 관리로 안내하지 않았습니다."
  printf '%s' "$models_out" | grep -q 'agy-new (추가)' ||
    die "models 기본 표시에 실제 목록과 정책의 추가 diff가 없습니다."
  printf '%s' "$models_out" | grep -q 'agy-remove (조회 결과에 없음 — 삭제)' ||
    die "models 기본 표시에 실제 목록에서 사라진 모델의 삭제 diff가 없습니다."
  printf '%s' "$models_out" | grep -q 'fable (미적용 — 허용 목록에 정확히 일치하는 값 없음)' ||
    die "models가 약칭 프리미엄을 전체 모델 이름과 부분 일치시켰습니다."
  if printf '%s' "$models_out" | grep -q 'fable (적용)'; then
    die "models가 프리미엄 약칭을 적용 상태로 표시했습니다."
  fi

  cmd_models "$models_project" --apply >/dev/null
  cmp -s "$models_policy" "$models_before" ||
    die "models --apply만으로 정책 파일이 변경됐습니다."
  models_out="$(cmd_models "$models_project" --refresh)"
  cmp -s "$models_policy" "$models_before" ||
    die "models --refresh dry-run이 정책 파일을 변경했습니다."
  printf '%s' "$models_out" | grep -q 'agy-keep (유지)' ||
    die "models --refresh가 유지 모델을 구분하지 않았습니다."
  printf '%s' "$models_out" | LC_ALL=C grep -q 'agy-premium-removed.*프리미엄 선언도 미적용 예정' ||
    die "models --refresh가 삭제될 프리미엄 모델을 특별 표시하지 않았습니다."

  # --refresh --apply는 추가·삭제 전체와 조회 시각을 반영한다.
  cmd_models "$models_project" --refresh --apply >/dev/null
  grep -q "^  agy_models: 'agy-keep agy-new' # 사용자 모델 주석$" "$models_policy" ||
    die "models --refresh --apply가 agy_models를 조회 결과 전체로 교체하지 않았습니다."
  grep -q '^  # 마지막 조회: 2026-09-11T07:00:00Z (agy models)$' "$models_policy" ||
    die "models --refresh --apply가 agy_models 바로 위에 조회 시각을 남기지 않았습니다."
  grep -q '^  # 사용자 정책 주석 — models가 보존해야 함$' "$models_policy" ||
    die "models 갱신이 사용자 주석을 삭제했습니다."
  grep -q "^  approval_mode: 'auto'$" "$models_policy" ||
    die "models 갱신이 approval_mode를 바꿨습니다."
  grep -q "^  codex_auto: '--ask-for-approval never --sandbox workspace-write'$" "$models_policy" ||
    die "models 갱신이 *_auto 정책을 바꿨습니다."

  # 비정상 종료와 성공+빈 출력은 둘 다 조회 실패다. 기존 목록·시각에 손대거나
  # 삭제 diff를 만들면 안 된다.
  cp "$models_policy" "$models_before"
  _models_query_agy() { return 17; }
  models_out="$(cmd_models "$models_project" --refresh --apply)"
  cmp -s "$models_policy" "$models_before" ||
    die "agy models 비정상 종료가 기존 모델 정책을 변경했습니다."
  printf '%s' "$models_out" | grep -q '삭제를 계산하지 않고 기존 정책을 보존' ||
    die "agy models 비정상 종료 시 보존 경고가 없습니다."
  _models_query_agy() { :; }
  models_out="$(cmd_models "$models_project" --refresh --apply)"
  cmp -s "$models_policy" "$models_before" ||
    die "agy models 빈 출력이 기존 모델 정책을 변경했습니다."
  printf '%s' "$models_out" | grep -q '삭제를 계산하지 않고 기존 정책을 보존' ||
    die "agy models 빈 출력 시 보존 경고가 없습니다."

  # --premium은 Provider별 set 의미이며, 같은 Provider의 반복은 누적하고 다른
  # Provider는 보존한다. 빈 값은 그 Provider의 집합을 비운다.
  _models_query_agy() { printf '%s\n' 'agy-keep Kept' 'agy-new New'; }
  models_out="$(cmd_models "$models_project" \
    --premium claude=claude-fable-5 \
    --premium claude=claude-opus-4-6 --apply)"
  grep -q "^  claude_premium_models: 'claude-fable-5 claude-opus-4-6'$" "$models_policy" ||
    die "models --premium 반복 지정이 Provider 프리미엄 집합으로 누적되지 않았습니다."
  grep -q "^  codex_premium_models: 'gpt-6-astra'$" "$models_policy" ||
    die "models --premium이 언급하지 않은 Provider를 변경했습니다."
  printf '%s' "$models_out" | grep -q 'claude-fable-5 (적용)' ||
    die "models --premium 전체 이름이 적용 상태로 표시되지 않았습니다."
  cmd_models "$models_project" --premium claude= --apply >/dev/null
  grep -q "^  claude_premium_models: ''$" "$models_policy" ||
    die "models --premium PROVIDER=가 프리미엄 집합을 비우지 않았습니다."

  # 허용 목록 밖 선언은 허용 목록을 넓히지 않고 미적용으로 분명히 보인다.
  models_out="$(cmd_models "$models_project" --premium claude=claude-unknown-9 --apply)"
  grep -q "^  claude_models: 'claude-fable-5 claude-opus-4-6'$" "$models_policy" ||
    die "models --premium이 Provider 허용 목록을 넓혔습니다."
  printf '%s' "$models_out" | grep -q 'claude-unknown-9 (미적용 — 허용 목록에 정확히 일치하는 값 없음)' ||
    die "허용 목록 밖 프리미엄 선언이 미적용으로 표시되지 않았습니다."

  # 같은 조회 결과의 연속 적용은 파일 전체가 같아야 한다(주석 시각 포함).
  cmd_models "$models_project" --refresh --apply >/dev/null
  cp "$models_policy" "$models_once"
  cmd_models "$models_project" --refresh --apply >/dev/null
  cmp -s "$models_policy" "$models_once" ||
    die "models --refresh --apply가 연속 실행에서 멱등이 아닙니다."

  # 구버전 정책처럼 프리미엄 키가 하나도 없어도 조회가 되고, 명시한 Provider
  # 키만 추가된다. 나머지 Provider의 논리적 빈 값은 그대로다.
  sed -i '/^  \(claude\|codex\|agy\)_premium_models:/d' "$models_policy"
  models_out="$(cmd_models "$models_project")"
  printf '%s' "$models_out" | grep -q '현재 codex_premium_models: (비어 있음)' ||
    die "models가 *_premium_models 없는 구버전 정책을 읽지 못했습니다."
  cmd_models "$models_project" --premium agy= --apply >/dev/null
  grep -q "^  agy_premium_models: ''$" "$models_policy" ||
    die "models가 구버전 정책에 명시한 프리미엄 키를 추가하지 않았습니다."
  if grep -q '^  codex_premium_models:' "$models_policy"; then
    die "models가 언급하지 않은 구버전 Provider 프리미엄 키를 추가했습니다."
  fi
  if grep -q 'herdr agent' "$HARNESS_LIB_DIR/52-models.sh"; then
    die "models 구현에 Agent 기동 경로가 들어갔습니다."
  fi
  models_out="$(bash "$SELF_PATH" help models)"
  printf '%s' "$models_out" | grep -q '`agy models`' ||
    die "help models에 agy 조회 경로 설명이 없습니다."

  # --- dispatch 옵션 정합: 인수 파싱 ↔ help 상세 ↔ 탭 완성 설명 -------------
  # 명령 이름은 기존 "도움말 정합성"이 검사하지만 옵션은 아무도 보지 않았다.
  # 실제로 --extra-prompt가 탭 완성 목록에서 빠진 채(줄바꿈 누락으로) 통과했다.
  local dispatch_options=() dispatch_help_text dispatch_completion_text option
  mapfile -t dispatch_options < <(
    awk '/^cmd_dispatch\(\)/ {inside=1}
         inside && /^}/ {exit}
         inside && /^      --[a-z-]+\)/ {
           label = $1; sub(/\).*$/, "", label); print label
         }' "$HARNESS_LIB_DIR/55-dispatch.sh" | sort -u)
  [[ "${#dispatch_options[@]}" -ge 4 ]] ||
    die "dispatch 옵션 정합 검사가 인수 파싱 목록을 읽지 못했습니다(파서 확인 필요)."
  dispatch_help_text="$(bash "$SELF_PATH" help dispatch)"
  dispatch_completion_text="$(bash "$SELF_PATH" completion bash)"
  for option in "${dispatch_options[@]}"; do
    printf '%s' "$dispatch_help_text" | grep -qF -- "$option" ||
      die "help dispatch에 설명이 없는 옵션: $option (lib/15-help.sh)"
    printf '%s' "$dispatch_completion_text" | grep -qF -- "\"$option::" ||
      die "탭 완성 설명에 없는 dispatch 옵션: $option (lib/85-completion.sh)"
  done

  # --- close-agent는 adopt로 등록한(사람이 만든) Pane을 --force 없이 닫지 않는다 ---
  mkdir -p "$test_project/.harness/runtime"
  printf 'task_id=task-001\nrole=worker\nagent_name=hh-task-001-w-9\npane_id=pane-9\nprovider=codex\nattempt=9\nadopted=1\n' \
    >"$test_project/.harness/runtime/task-001-worker.meta"
  expect_fail "close-agent가 adopt한 Pane을 --force 없이 닫음" \
    bash "$SELF_PATH" close-agent "$test_project" task-001 worker
  rm -f "$test_project/.harness/runtime/task-001-worker.meta"

  # --- Task Lock: 동시 획득 거부, release, stale 회수 -----------------------
  local task2="$test_project/.harness/tasks/task-002.yaml"
  sed -e 's/^task_id: .*/task_id: task-002/' \
      -e 's/^milestone_id: .*/milestone_id: milestone-001/' \
      -e 's/^status: .*/status: active/' \
      "$test_project/.harness/tasks/TEMPLATE.yaml" >"$task2"

  local lock_token1 lock_token2 lock_status lock_error
  lock_token1="$(_runtime_lock_acquire "$test_project" task-002 test-a 600)" ||
    die "Task Lock 최초 획득 실패"
  set +e
  lock_error="$(_runtime_lock_acquire "$test_project" task-002 test-b 600 2>&1)"
  lock_status=$?
  set -e
  [[ "$lock_status" -ne 0 ]] || die "Task Lock이 동시 획득을 막지 못했습니다."
  printf '%s' "$lock_error" | grep -qF 'Task가 다른 프로세스에 의해 잠겨 있습니다' ||
    die "Task Lock 동시 획득 거부 사유가 없습니다: $lock_error"
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

  # agent-policy는 사용자가 직접 편집하는 정책이라 통째로 초기화하면 안 된다.
  # 구버전 파일에 모델 키만 보충하면서 기존 승인 인수는 보존해야 한다.
  sed -i '/^  \(claude\|codex\|agy\)_\(models\|default_model\|premium_models\):/d' \
    "$test_project/.harness/policies/agent-policy.yaml"
  sed -i "s|^  codex_auto:.*|  codex_auto: '--ask-for-approval on-request --sandbox workspace-write'|" \
    "$test_project/.harness/policies/agent-policy.yaml"
  sync_out="$(bash "$SELF_PATH" sync-templates "$test_project")"
  printf '%s' "$sync_out" | grep -q '요약: 변경 1' ||
    die "sync-templates: 구버전 agent-policy의 모델 키 누락을 감지하지 못했습니다."
  grep -q '^  codex_models:' "$test_project/.harness/policies/agent-policy.yaml" &&
    die "sync-templates dry-run이 agent-policy 모델 키를 실제로 추가했습니다."
  sync_out="$(bash "$SELF_PATH" sync-templates "$test_project" --apply)"
  printf '%s' "$sync_out" | grep -q '요약: 변경 1' ||
    die "sync-templates --apply: agent-policy 모델 키 전파 건수가 예상과 다릅니다."
  grep -q "^  codex_models: ''$" "$test_project/.harness/policies/agent-policy.yaml" ||
    die "sync-templates --apply가 빈 초기 모델 허용 목록을 전파하지 않았습니다."
  grep -q "^  codex_premium_models: ''$" "$test_project/.harness/policies/agent-policy.yaml" ||
    die "sync-templates --apply가 빈 초기 프리미엄 모델 목록을 전파하지 않았습니다."
  grep -q "^  codex_auto: '--ask-for-approval on-request --sandbox workspace-write'$" \
    "$test_project/.harness/policies/agent-policy.yaml" ||
    die "sync-templates가 사용자가 고친 승인 정책 값을 초기화했습니다."
  sed -i "s|^  codex_models:.*|  codex_models: 'gpt-project-model gpt-review-model'|" \
    "$test_project/.harness/policies/agent-policy.yaml"
  sed -i "s|^  codex_default_model:.*|  codex_default_model: 'gpt-project-model'|" \
    "$test_project/.harness/policies/agent-policy.yaml"
  sed -i "s|^  codex_premium_models:.*|  codex_premium_models: 'gpt-project-premium'|" \
    "$test_project/.harness/policies/agent-policy.yaml"
  sync_out="$(bash "$SELF_PATH" sync-templates "$test_project" --apply)"
  printf '%s' "$sync_out" | grep -q '요약: 변경 0' ||
    die "sync-templates: agent-policy 모델 키 전파가 멱등이 아닙니다."
  grep -q "^  codex_models: 'gpt-project-model gpt-review-model'$" \
    "$test_project/.harness/policies/agent-policy.yaml" ||
    die "sync-templates가 사용자가 고친 모델 허용 목록을 초기화했습니다."
  grep -q "^  codex_default_model: 'gpt-project-model'$" \
    "$test_project/.harness/policies/agent-policy.yaml" ||
    die "sync-templates가 사용자가 고친 정책 기본 모델을 초기화했습니다."
  grep -q "^  codex_premium_models: 'gpt-project-premium'$" \
    "$test_project/.harness/policies/agent-policy.yaml" ||
    die "sync-templates가 사용자가 고친 프리미엄 모델 선언을 초기화했습니다."

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
  # ---------------------------------------------------------------------------
  # remote setup: 설정이 없는 기존 프로젝트를 옵션만으로 구성한다. --no-key라
  # 네트워크는 쓰지 않는다. 비밀번호가 파일에 남지 않는지도 여기서 본다.
  # ---------------------------------------------------------------------------
  local setup_project="$test_root/setup-project"
  bash "$SELF_PATH" init "$setup_project" --name setup-project --goal "setup 테스트" >/dev/null
  local setup_config="$setup_project/.harness/policies/remote.yaml"
  grep -q '^  enabled: false$' "$setup_config" ||
    die "setup 테스트 전제 위반: 새 프로젝트가 이미 원격 모드입니다."

  HH_REMOTE_PASSWORD='절대저장되면안됨' bash "$SELF_PATH" remote "$setup_project" setup \
    --host build.example --user builder --path /srv/setup --vcs svn --no-key >/dev/null ||
    die "remote setup(비대화형, --no-key) 실패"
  grep -q "^  enabled: true$" "$setup_config" || die "setup이 원격 모드를 켜지 않았습니다."
  grep -q "^  host: 'build.example'$" "$setup_config" || die "setup이 host를 쓰지 않았습니다."
  grep -q "^  vcs: 'svn'$" "$setup_config" || die "setup이 vcs를 쓰지 않았습니다."
  if grep -q '절대저장되면안됨' "$setup_config"; then
    die "setup이 비밀번호를 설정 파일에 기록했습니다."
  fi
  # setup 직후 설정만으로 다른 하위 명령이 로드에 성공해야 한다(SSH는 실패해도 됨).
  local setup_status_output
  set +e
  setup_status_output="$(bash "$SELF_PATH" remote "$setup_project" status 2>&1)"
  set -e
  printf '%s' "$setup_status_output" | grep -q '^원격 대상:  builder@build.example$' ||
    die "setup이 만든 설정을 다시 읽지 못했습니다: $setup_status_output"

  expect_fail "remote setup: 기존 설정 덮어쓰기에 --force 필요" \
    bash "$SELF_PATH" remote "$setup_project" setup --host other.example --user u --path /srv/x --no-key
  bash "$SELF_PATH" remote "$setup_project" setup --force \
    --host other.example --user builder --path /srv/x --vcs git --no-key >/dev/null ||
    die "remote setup --force 실패"
  grep -q "^  host: 'other.example'$" "$setup_config" || die "--force가 값을 갱신하지 않았습니다."
  expect_fail "remote setup: 옵션형 user 거부" \
    bash "$SELF_PATH" remote "$setup_project" setup --force \
      --host h.example --user '-oProxyCommand=touch /tmp/pwned' --path /srv/x --no-key
  # 기본값으로 채울 수 없는 값이 남으면 비대화형에서는 물어보지 않고 실패한다.
  # (--force 재실행은 기존 값이 기본값이 되므로 이 경우에 해당하지 않는다.)
  local setup_bare="$test_root/setup-bare"
  bash "$SELF_PATH" init "$setup_bare" --name setup-bare --goal "setup 비대화형" >/dev/null
  expect_fail "remote setup: 비대화형에서 host 누락" \
    bash "$SELF_PATH" remote "$setup_bare" setup --user builder --path /srv/x --no-key

  # 제어문자(개행·캐리지리턴)는 생성 YAML을 조용히 오염시키므로 거부한다.
  expect_fail "remote setup: 경로에 캐리지리턴" \
    bash "$SELF_PATH" remote "$setup_bare" setup --host build.example --user builder \
      --path "$(printf '/srv/a\rb')" --no-key

  # 중복 키로 깨진 설정은 setup --force로 복구할 수 있어야 한다(복구 경로).
  local setup_repair="$test_root/setup-repair"
  bash "$SELF_PATH" init "$setup_repair" --name setup-repair --goal "복구" >/dev/null
  printf "  mount_path: '/tmp/duplicate'\n" >>"$setup_repair/.harness/policies/remote.yaml"
  bash "$SELF_PATH" remote "$setup_repair" setup --force \
    --host build.example --user builder --path /srv/p --vcs git --no-key >/dev/null ||
    die "중복 키가 있는 설정을 setup --force로 복구하지 못했습니다."
  [[ "$(grep -c '^  mount_path:' "$setup_repair/.harness/policies/remote.yaml")" -eq 1 ]] ||
    die "복구 후에도 중복 키가 남아 있습니다."

  # 비밀번호는 sshpass 호출에만 전달돼야 한다. ssh-keygen 같은 무관한 자식이
  # HH_REMOTE_PASSWORD를 상속하면 /proc/<pid>/environ으로 노출된다.
  local stub_dir="$test_root/stub-bin"
  mkdir -p "$stub_dir"
  cat >"$stub_dir/ssh-keygen" <<'STUB'
#!/usr/bin/env bash
if env | grep -q '^HH_REMOTE_PASSWORD='; then printf 'LEAK-keygen\n'; fi
exit 1
STUB
  cat >"$stub_dir/sshpass" <<'STUB'
#!/usr/bin/env bash
if env | grep -q '^HH_REMOTE_PASSWORD='; then printf 'LEAK-sshpass\n'; fi
exit 1
STUB
  chmod +x "$stub_dir/ssh-keygen" "$stub_dir/sshpass"

  local setup_leak="$test_root/setup-leak" leak_output
  bash "$SELF_PATH" init "$setup_leak" --name setup-leak --goal "비밀번호 상속" >/dev/null
  set +e
  leak_output="$(PATH="$stub_dir:$PATH" HH_REMOTE_PASSWORD='절대상속되면안됨' \
    bash "$SELF_PATH" remote "$setup_leak" setup \
    --host build.example --user builder --path /srv/x 2>&1)"
  set -e
  if printf '%s' "$leak_output" | grep -q 'LEAK-'; then
    die "비밀번호가 무관한 자식 프로세스로 상속됐습니다: $leak_output"
  fi

  # 키 등록 단계에서 실패해도 입력한 설정은 남고, 다음 한 단계를 안내해야 한다.
  local setup_keyfail="$test_root/setup-keyfail"
  bash "$SELF_PATH" init "$setup_keyfail" --name setup-keyfail --goal "키 등록 실패" >/dev/null
  local keyfail_output
  set +e
  keyfail_output="$(bash "$SELF_PATH" remote "$setup_keyfail" setup \
    --host build.example --user builder --path /srv/x </dev/null 2>&1)"
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || die "비대화형 키 등록이 성공으로 보고됐습니다."
  printf '%s' "$keyfail_output" | grep -q 'bootstrap-key' ||
    die "키 등록 실패 안내에 다음 단계가 없습니다: $keyfail_output"
  grep -q "^  host: 'build.example'$" "$setup_keyfail/.harness/policies/remote.yaml" ||
    die "키 등록 실패 시 입력한 설정이 남지 않았습니다."

  expect_fail "init: 포트가 붙은 --remote-host" \
    bash "$SELF_PATH" init "$test_root/remote-host-port" --name r --goal g \
      --remote-host host.example:22 --remote-path /srv/p
  expect_fail "init: 개행이 든 --remote-path" \
    bash "$SELF_PATH" init "$test_root/remote-newline" --name r --goal g \
      --remote-host host.example --remote-path "$(printf '/srv/one\ntwo')"

  # ---------------------------------------------------------------------------
  # Agent 승인 정책(agent-policy.yaml)
  # 도구 실행 승인만 건너뛰고, 작업 방향성 결정(전이·승인)은 건드리지 않는다.
  # 정책 파일을 이리저리 고쳐 보므로 다른 검사와 섞이지 않게 별도 프로젝트를 쓴다.
  local approval_project="$test_root/approval-project"
  bash "$SELF_PATH" init "$approval_project" --name approval-project --goal "승인 정책 검사" >/dev/null
  local agent_policy="$approval_project/.harness/policies/agent-policy.yaml"
  grep -q "^  approval_mode: 'auto'$" "$agent_policy" ||
    die "init 기본 approval_mode가 auto가 아닙니다: $agent_policy"

  # 표에 적힌 인수가 mode·Provider 조합대로 나와야 한다.
  [[ "$(_runtime_agent_args "$approval_project" claude)" == "--permission-mode acceptEdits" ]] ||
    die "approval_mode=auto에서 claude 인수가 표와 다릅니다."
  [[ "$(_runtime_agent_args "$approval_project" codex)" == "--ask-for-approval never --sandbox workspace-write" ]] ||
    die "approval_mode=auto에서 codex 인수가 표와 다릅니다."
  sed -i "s/^  approval_mode: 'auto'$/  approval_mode: 'bypass'/" "$agent_policy"
  [[ "$(_runtime_agent_args "$approval_project" agy)" == "--dangerously-skip-permissions" ]] ||
    die "approval_mode=bypass에서 agy 인수가 표와 다릅니다."
  sed -i "s/^  approval_mode: 'bypass'$/  approval_mode: 'ask'/" "$agent_policy"
  [[ -z "$(_runtime_agent_args "$approval_project" claude)" ]] ||
    die "approval_mode=ask에서 인수가 붙었습니다."

  # 설정 파일 값이 그대로 argv가 되므로 허용 문자를 벗어나면 거부해야 한다.
  # 명령 치환 문자와 glob 문자 둘 다 — glob은 분리 뒤에 검사하면 경로 확장에
  # 먼저 걸려 빠져나가므로 회귀 방지로 함께 확인한다.
  sed -i "s/^  approval_mode: 'ask'$/  approval_mode: 'auto'/" "$agent_policy"
  local rejected_value
  for rejected_value in '--permission-mode \$(id)' '--permission-mode *' '--permission-mode "x"'; do
    sed -i "s|^  claude_auto: .*$|  claude_auto: '$rejected_value'|" "$agent_policy"
    set +e
    ( _runtime_agent_args "$approval_project" claude ) >/dev/null 2>&1
    failure_status=$?
    set -e
    [[ "$failure_status" -ne 0 ]] ||
      die "agent-policy.yaml의 인수에 허용되지 않는 문자가 있는데 통과했습니다: $rejected_value"
  done

  # 문자 집합만으로는 부족하다 — 승인과 무관한 Provider 옵션이 통과하면
  # 정책 파일 한 줄로 auto가 사실상 full-access가 된다(기록은 계속 auto).
  # 그래서 Provider별 허용 플래그·허용 값 목록으로 막는다.
  local rejected_arg
  for rejected_arg in '--add-dir /' '--permission-mode acceptEdits --add-dir /' '--model opus'; do
    sed -i "s|^  claude_auto: .*$|  claude_auto: '$rejected_arg'|" "$agent_policy"
    set +e
    ( _runtime_agent_args "$approval_project" claude ) >/dev/null 2>&1
    failure_status=$?
    set -e
    [[ "$failure_status" -ne 0 ]] ||
      die "승인과 무관한 Provider 인수가 정책을 통과했습니다: $rejected_arg"
  done
  # auto가 bypass 수준 플래그를 받아들이면 기록은 auto인데 실제 권한만
  # full-access가 된다 — mode별로 허용 목록이 갈려야 한다.
  local escalation
  for escalation in '--permission-mode bypassPermissions' '--dangerously-skip-permissions'; do
    sed -i "s|^  claude_auto: .*$|  claude_auto: '$escalation'|" "$agent_policy"
    set +e
    ( _runtime_agent_args "$approval_project" claude ) >/dev/null 2>&1
    failure_status=$?
    set -e
    [[ "$failure_status" -ne 0 ]] ||
      die "auto 모드가 bypass 수준 인수를 통과시켰습니다: $escalation"
  done
  # 같은 인수라도 bypass 모드에서는 허용돼야 한다.
  sed -i "s/^  approval_mode: 'auto'$/  approval_mode: 'bypass'/" "$agent_policy"
  sed -i "s|^  claude_bypass: .*$|  claude_bypass: '--permission-mode bypassPermissions'|" "$agent_policy"
  [[ "$(_runtime_agent_args "$approval_project" claude)" == "--permission-mode bypassPermissions" ]] ||
    die "bypass 모드에서 bypassPermissions가 거부됐습니다."
  sed -i "s/^  approval_mode: 'bypass'$/  approval_mode: 'auto'/" "$agent_policy"

  # 허용 플래그라도 허용 값이 아니면 거부한다.
  sed -i "s|^  claude_auto: .*$|  claude_auto: '--permission-mode wideOpen'|" "$agent_policy"
  set +e
  ( _runtime_agent_args "$approval_project" claude ) >/dev/null 2>&1
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || die "허용되지 않는 --permission-mode 값이 통과했습니다."
  # 실패는 die가 아니라 반환값이어야 한다 — auto-step처럼 커맨드 치환 안에서
  # 불릴 때 안쪽 die는 삼켜져 "인수 없음"으로 조용히 진행되기 때문이다.
  set +e
  ( _runtime_agent_args "$approval_project" claude >/dev/null 2>&1; printf 'reached=%s' "$?" ) | grep -q 'reached=1' ||
    die "_runtime_agent_args가 반환값으로 실패를 알리지 않았습니다."
  set -e
  sed -i "s|^  claude_auto: .*$|  claude_auto: '--permission-mode acceptEdits'|" "$agent_policy"

  # 정책 파일이 없는 기존 프로젝트는 종전대로 인수 없이 동작해야 한다.
  rm -f "$agent_policy"
  [[ -z "$(_runtime_agent_args "$approval_project" claude)" ]] ||
    die "agent-policy.yaml이 없는데 인수가 붙었습니다."

  # init의 --approval-mode 값 검증.
  set +e
  bash "$SELF_PATH" init "$test_root/bad-approval" --name bad --goal g --approval-mode nonsense >/dev/null 2>&1
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || die "잘못된 --approval-mode 값이 통과했습니다."

  # 도움말 정합성: 명령 목록이 세 곳(99-main.sh의 case, 15-help.sh의 요약표와
  # topic 분기, 85-completion.sh의 설명 목록)에 흩어져 있어 쉽게 갈라진다.
  # 하나라도 빠지면 사용자는 "탭에는 있는데 help는 없는" 명령을 만난다.
  # ---------------------------------------------------------------------------
  local dispatch_commands=() summary_commands=() completion_commands=()
  # case 라벨만 본다 — 본문이 같은 줄에 있든 다음 줄에 있든 잡히도록.
  # `help|-h|--help)` 처럼 별칭이 붙은 라벨은 첫 이름만 쓴다.
  mapfile -t dispatch_commands < <(
    awk '/^    [a-z][a-z-]*(\|[-a-z]+)*\)/ {
           label = $1
           sub(/\).*$/, "", label)
           split(label, parts, "|")
           print parts[1]
         }' "$HARNESS_LIB_DIR/99-main.sh" | sort -u)
  mapfile -t summary_commands < <(harness_command_names | sort -u)
  mapfile -t completion_commands < <(
    bash "$SELF_PATH" completion bash |
      awk -F'"' '/^    "[a-z-]+::/ { split($2, parts, "::"); print parts[1] }' | sort -u)

  [[ "${#dispatch_commands[@]}" -gt 10 ]] ||
    die "도움말 정합성 검사가 명령 목록을 읽지 못했습니다(파서 확인 필요)."
  # 디스패처가 실제로 아는 이름이 파서에 잡히는지 표본으로 확인한다.
  local sentinel
  for sentinel in init remote help; do
    case " ${dispatch_commands[*]} " in
      *" $sentinel "*) ;;
      *) die "도움말 정합성 검사의 디스패처 파서가 $sentinel 를 놓쳤습니다(lib/80-selftest.sh)." ;;
    esac
  done

  # 세 목록은 정확히 같아야 한다 — 어느 쪽에만 있어도 실패다.
  # (한쪽만 검사하면 탭에만 있는 가짜 명령이나 실행할 수 없는 help 항목이 남는다.)
  local expected_command
  for expected_command in "${dispatch_commands[@]}"; do
    case " ${summary_commands[*]} " in
      *" $expected_command "*) ;;
      *) die "HARNESS_COMMAND_SUMMARIES에 설명이 없는 명령: $expected_command (lib/15-help.sh)" ;;
    esac
    case " ${completion_commands[*]} " in
      *" $expected_command "*) ;;
      *) die "탭 완성 설명 목록에 없는 명령: $expected_command (lib/85-completion.sh)" ;;
    esac
    bash "$SELF_PATH" help "$expected_command" >/dev/null ||
      die "help 상세 항목이 없는 명령: $expected_command (lib/15-help.sh의 cmd_help_topic)"
  done

  for expected_command in "${summary_commands[@]}"; do
    case " ${dispatch_commands[*]} " in
      *" $expected_command "*) ;;
      *) die "실행할 수 없는 명령이 도움말 요약표에 있습니다: $expected_command (lib/15-help.sh)" ;;
    esac
  done

  for expected_command in "${completion_commands[@]}"; do
    case " ${dispatch_commands[*]} " in
      *" $expected_command "*) ;;
      *) die "실행할 수 없는 명령이 탭 완성 설명 목록에 있습니다: $expected_command (lib/85-completion.sh)" ;;
    esac
  done

  # 설명 표시 가드: TAB이 "후보를 그대로 넣는" readline 명령에 묶여 있거나
  # 사용자가 껐으면, 후보가 여럿이어도 설명 없이 명령만 돌려줘야 한다.
  # (그러지 않으면 설명 문자열이 그대로 명령줄에 삽입된다.)
  local describe_probe
  describe_probe='
    source <(bash "$0" completion bash)
    COMP_WORDS=(herdr-harness ""); COMP_CWORD=1; COMPREPLY=()
    compopt() { :; }
    _herdr_harness_completions
    printf "%s\n" "${COMPREPLY[0]}"
  '
  # 삽입형 readline 명령 각각에 대해 bind 스텁이 "그 명령만" TAB에 묶였다고
  # 보고하게 한다 — 하나라도 검사에서 빠지면 여기서 걸린다.
  local guarded_case guarded_first bind_stub
  for guarded_case in env menu-complete menu-complete-backward insert-completions; do
    if [[ "$guarded_case" == env ]]; then
      guarded_first="$(bash -c "HERDR_HARNESS_COMPLETION_DESCRIPTIONS=0; $describe_probe" "$SELF_PATH")"
    else
      bind_stub="bind() { [[ \"\$2\" == $guarded_case ]] || return 0; printf '%s can be invoked via \"\\\\C-i\".\n' \"\$2\"; }; "
      guarded_first="$(bash -c "$bind_stub$describe_probe" "$SELF_PATH")"
    fi
    [[ "$guarded_first" != *" : "* ]] ||
      die "설명 표시를 꺼야 하는 상황($guarded_case)에서 설명이 후보에 들어갔습니다: $guarded_first"
  done

  local described_first
  described_first="$(bash -c "bind() { return 1; }; $describe_probe" "$SELF_PATH")"
  [[ "$described_first" == *" : "* ]] ||
    die "기본 상황에서 탭 완성 설명이 붙지 않았습니다: $described_first"

  set +e
  bash "$SELF_PATH" help no-such-command >/dev/null 2>&1
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || die "없는 명령에 대한 help가 성공으로 끝났습니다."

  # --- --extra-prompt: 추가 지시가 Packet에 붙고 Secret 검사도 받는다 -------
  #
  # 이 옵션이 없으면 Task별 커스텀 지시를 담으려고 사람이 Agent를 직접 띄우게
  # 되고, 그 순간 Attempt·Evidence·추적이 통째로 빠진다.
  local extra_file packet_probe
  extra_file="$(mktemp)"
  printf '리뷰 시 빈 카드는 승인된 비용이다. 회귀로 오판하지 말 것.\n' >"$extra_file"
  packet_probe="$test_project/.harness/runtime/task-001-context-reviewer.md"
  rm -f -- "$packet_probe"
  _runtime_context_packet "$test_project" task-001 reviewer \
    "$test_project/.harness/tasks/task-001.yaml" "$packet_probe" "$extra_file" ||
    die "--extra-prompt가 붙은 Context Packet 생성에 실패했습니다."
  grep -q '## 이 Task 추가 지시' "$packet_probe" ||
    die "Context Packet에 추가 지시 절이 없습니다."
  grep -q '승인된 비용' "$packet_probe" ||
    die "추가 지시 본문이 Context Packet에 들어가지 않았습니다."
  # 추가 지시가 Next step보다 앞에 와야 "다음 한 단계"가 마지막에 남는다.
  [[ "$(grep -n '## 이 Task 추가 지시' "$packet_probe" | cut -d: -f1)" -lt \
     "$(grep -n '## Next step' "$packet_probe" | cut -d: -f1)" ]] ||
    die "추가 지시가 Next step 뒤에 붙었습니다."
  printf 'OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx\n' >"$extra_file"
  if _runtime_context_packet "$test_project" task-001 reviewer \
       "$test_project/.harness/tasks/task-001.yaml" "$packet_probe" "$extra_file"; then
    rm -f -- "$extra_file"
    die "추가 지시의 Secret 패턴이 걸러지지 않았습니다."
  fi
  rm -f -- "$extra_file"

  # --- 프롬프트 전달 재시도 판정 --------------------------------------------
  #
  # 출력에 Packet 헤더가 있는지는 Provider UI·스크롤백에 좌우되므로 신호가
  # 아니다. Herdr가 lifecycle을 못 봤다(agent_prompt_stalled) + Agent가 아직
  # idle일 때만 한 번 재시도해야 정상 턴을 중복 실행하지 않는다.
  _runtime_prompt_needs_retry 0 '{"agent_status":"idle"}' 1 'agent_prompt_stalled' ||
    die "idle 상태의 유실된 프롬프트를 재시도 대상으로 판정하지 못했습니다."
  ! _runtime_prompt_needs_retry 0 '{"agent_status":"done"}' 0 'agent_prompt_stalled' ||
    die "정상 종료된 프롬프트를 재시도 대상으로 판정했습니다."
  ! _runtime_prompt_needs_retry 0 '{"agent_status":"blocked"}' 1 'agent_prompt_stalled' ||
    die "확인/승인 UI가 막힌 프롬프트를 자동 재시도 대상으로 판정했습니다."
  ! _runtime_prompt_needs_retry 0 '{"agent_status":"idle"}' 1 'other failure' ||
    die "원인을 모르는 프롬프트 실패를 재시도 대상으로 판정했습니다."

  # --- Herdr Agent 상태 정규화 ---------------------------------------------
  # 실제 CLI가 반환하는 다섯 상태와 프롬프트 전후 활동 지표를 JSON 표본으로만
  # 검사한다. 여기서 herdr를 부르면 자체 테스트가 Agent 쿼터를 소모한다.
  local activity_before activity_changed idle_unchanged done_unchanged
  local normalized unknown_warning
  activity_before='{"agent_status":"idle","revision":1,"state_change_seq":7}'
  activity_changed='{"agent_status":"idle","revision":2,"state_change_seq":8}'
  idle_unchanged='{"agent_status":"idle","revision":1,"state_change_seq":7}'
  done_unchanged='{"agent_status":"done","revision":1,"state_change_seq":7}'

  [[ "$(_runtime_normalize_state 0 '{"agent_status":"working","revision":2,"state_change_seq":8}' 0 '' "$activity_before")" == running ]] ||
    die "working을 running으로 정규화하지 못했습니다(정상 작업 회귀)."
  [[ "$(_runtime_normalize_state 0 "$activity_changed" 0 '' "$activity_before")" == settled ]] ||
    die "활동 지표가 변한 idle을 settled로 정규화하지 못했습니다."
  [[ "$(_runtime_normalize_state 0 '{"agent_status":"done","revision":2,"state_change_seq":8}' 0 '' "$activity_before")" == settled ]] ||
    die "활동 지표가 변한 done을 settled로 정규화하지 못했습니다."
  [[ "$(_runtime_normalize_state 0 '{"agent_status":"done","revision":2,"state_change_seq":8}' 0 'agent_prompt_stalled' "$activity_before")" == settled ]] ||
    die "재전송 성공 뒤 남은 이전 stalled 문구를 현재 실패로 오판했습니다."
  [[ "$(_runtime_normalize_state 0 '{"agent_status":"blocked","revision":1,"state_change_seq":7}' 0 '' "$activity_before")" == blocked ]] ||
    die "blocked 정규화가 기존 결과를 보존하지 못했습니다."
  [[ "$(_runtime_normalize_state 0 '{"agent_status":"unknown","revision":1,"state_change_seq":7}' 0 '' "$activity_before")" == unknown ]] ||
    die "unknown을 error와 분리하지 못했습니다."

  normalized="$(_runtime_normalize_state 0 "$idle_unchanged" 0 '' "$activity_before")"
  [[ "$normalized" == prompt_not_delivered ]] ||
    die "활동 지표가 불변인 idle을 prompt_not_delivered로 판정하지 못했습니다: $normalized"
  normalized="$(_runtime_normalize_state 0 "$done_unchanged" 0 '' "$activity_before")"
  [[ "$normalized" == prompt_not_delivered && "$normalized" != settled ]] ||
    die "활동 지표가 불변인 done을 거짓 settled로 판정했습니다: $normalized"
  [[ "$(_runtime_normalize_state 1 '' 0 '' "$activity_before")" == agent_lost ]] ||
    die "agent get 실패의 agent_lost 결과를 보존하지 못했습니다."

  unknown_warning="$(mktemp)"
  normalized="$(_runtime_normalize_state 0 '{"agent_status":"rebooting","revision":2,"state_change_seq":8}' 0 '' "$activity_before" 2>"$unknown_warning")"
  [[ "$normalized" == unknown ]] || {
    rm -f -- "$unknown_warning"
    die "미지의 agent_status를 unknown으로 정규화하지 못했습니다: $normalized"
  }
  grep -q 'rebooting' "$unknown_warning" || {
    rm -f -- "$unknown_warning"
    die "미지의 agent_status 경고에 원래 값이 없습니다."
  }
  rm -f -- "$unknown_warning"

  _runtime_prompt_needs_retry 0 "$idle_unchanged" 0 '' "$activity_before" ||
    die "지표 불변으로 확인된 prompt_not_delivered를 1회 재시도 대상으로 판정하지 못했습니다."
  ! _runtime_prompt_needs_retry 0 "$activity_changed" 0 '' "$activity_before" ||
    die "지표가 변한 정상 idle을 재시도 대상으로 판정했습니다."

  # --- Secret 스캐너: 낱말 가운데 접두사는 오탐이 아니어야 한다 -------------
  #
  # ta"sk-..." 처럼 평범한 Task ID가 OpenAI 키 패턴에 걸리면 Context Packet
  # 생성이 거부되고 그 프로젝트의 dispatch가 Provider와 무관하게 영구히 막힌다.
  # 반대로 진짜 접두사는 계속 걸려야 하므로 양방향으로 본다.
  local secret_probe
  secret_probe="$(mktemp)"
  local benign_sample malicious_sample
  for benign_sample in \
    'task-political-lri-trend' \
    'task-overview-today-summary-attempt-1' \
    '.harness/reviews/task-cross-domain-news-counts-review-1.md'; do
    printf '%s\n' "$benign_sample" >"$secret_probe"
    if _runtime_has_secret "$secret_probe"; then
      rm -f -- "$secret_probe"
      die "Secret 스캐너가 평범한 식별자를 Secret으로 오탐했습니다: $benign_sample"
    fi
  done
  for malicious_sample in \
    'OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx' \
    'token: ghp_abcdefghijklmnopqrstuv' \
    'Authorization: Bearer abcdef'; do
    printf '%s\n' "$malicious_sample" >"$secret_probe"
    if ! _runtime_has_secret "$secret_probe"; then
      rm -f -- "$secret_probe"
      die "Secret 스캐너가 실제 Secret 패턴을 놓쳤습니다: $malicious_sample"
    fi
  done
  rm -f -- "$secret_probe"

  # 나중에 생긴 .gitignore 줄(evidence/raw/)이 기존 프로젝트에도 반영돼야 한다 —
  # 안 그러면 Agent 출력 덤프가 untracked로 노출된다.
  local gi_project="$test_root/gitignore-project"
  bash "$SELF_PATH" init "$gi_project" --name gi --goal "gitignore 검사" >/dev/null
  grep -v '^\.harness/evidence/raw/$' "$gi_project/.gitignore" >"$gi_project/.gitignore.tmp"
  mv "$gi_project/.gitignore.tmp" "$gi_project/.gitignore"
  bash "$SELF_PATH" sync-templates "$gi_project" >/dev/null
  grep -qxF '.harness/evidence/raw/' "$gi_project/.gitignore" &&
    die "dry-run인데 .gitignore가 바뀌었습니다."
  bash "$SELF_PATH" sync-templates "$gi_project" --apply >/dev/null
  grep -qxF '.harness/evidence/raw/' "$gi_project/.gitignore" ||
    die "sync-templates --apply가 .gitignore의 누락된 줄을 채우지 않았습니다."
  bash "$SELF_PATH" sync-templates "$gi_project" --apply >/dev/null
  [[ "$(grep -cxF '.harness/evidence/raw/' "$gi_project/.gitignore")" -eq 1 ]] ||
    die "sync-templates --apply가 .gitignore 줄을 중복 추가했습니다."

  # 출력 목록 자체를 한 곳에서 정의하고 README의 기대 출력 블록과 비교한다.
  # cmd_test를 다시 실행하지 않으므로 Agent 호출·네트워크 접근·재귀 실행이 없다.
  local pass_lines=(
    'PASS: Bash 문법'
    'PASS: Harness 파일 생성 (22종 템플릿, templates/ 파일 정본)'
    'PASS: 템플릿 배열 ↔ templates/ 파일 정합'
    'PASS: 공통 Skill과 Claude 연결'
    'PASS: 플레이스홀더 치환'
    'PASS: Git 기준선 생성'
    'PASS: 신규 프로젝트 보호'
    'PASS: 비대화형 명시적 실패'
    'PASS: 상태 전이표 강제 (16개 케이스, handover_required 인계문서 게이트 포함)'
    'PASS: Context Packet 직전 라운드 주입 (Evidence·AC 결과·Review 판정, 첫 시도엔 미주입)'
    'PASS: dispatch 추가 지시(--extra-prompt 주입·순서·Secret 차단)와 안전한 프롬프트 재시도 판정'
    'PASS: Agent 상태 정규화'
    'PASS: Secret 스캐너 경계 (task-* 식별자 오탐 없음, 실제 키 접두사·Authorization 탐지)'
    'PASS: Acceptance Criteria 게이트 (명령 직접 실행/실패 거부/알 수 없는 type·빈 목록 거부/manual-review 기록)'
    'PASS: 명시 승인 approve (정상/멱등/무확인/상태/Review/Task ID/충돌 거부)'
    'PASS: 이벤트 로그 기록'
    'PASS: validate 검증 (정상/Worker=Reviewer/Git 누락)'
    'PASS: 스텝 명령 인자 검증 (adopt 인자, --print-only 무상태·셸 인용, adopt Pane close 보호)'
    'PASS: dispatch --cwd (기본 워크스페이스/지정 반영/없는 경로·무값 거부/셸 인용, 옵션↔help↔탭완성 정합)'
    'PASS: 모델 선택 (역할별 Task 지정/정책·Provider 기본값/허용 목록·플래그 주입 거부/Secret 비노출/기록)'
    'PASS: 프리미엄 모델 승인 (정확 범위/불일치·재사용·Agent Pane 거부/강등·누출 차단/fail-open·argv 주입 차단/기록)'
    'PASS: models 명령 (dry-run/apply·전체 refresh·실패 보존·프리미엄 set/비우기/정확 일치·멱등·구버전 정책·사용자 값 보존)'
    'PASS: 호출자 게이트 (Agent Pane의 transition·approve 거부, 사람 Pane 비침범)'
    'PASS: Agent 호출 없음'
    'PASS: 탭 완성 스크립트 문법'
    'PASS: Agent 승인 정책 (기본 auto/인수표/ask 무인수/문자·플래그·값·모드별 권한상승 거부/반환값 실패/정책 없음/init 값)'
    'PASS: 도움말 정합성 (dispatch↔help 요약·상세↔탭 완성 설명, 없는 명령 거부)'
    'PASS: 원격 실행 모드 (opt-in 게이트/setup 생성·--force·비밀번호 미저장/하위 명령 오타 거부/SSH 옵션·경로 인젝션 차단/YAML 주석·중복 키)'
    'PASS: Task Lock (동시 획득 거부/release/stale 회수)'
    'PASS: quota-retry/auto-step opt-in 게이트'
    'PASS: quota-retry/auto-step 안전 불변식(completed/reviewing/awaiting_approval/ready 미호출, handover stub 선행)'
    'PASS: sync-templates (dry-run/apply·멱등, agent-policy 모델·프리미엄 키 전파·사용자 값 보존, AGENTS.md/STATE.md 비침범, .gitignore 보충)'
    'PASS: README 기대 출력 ↔ 실제 test 출력 정합'
    'PASS: install.sh ~/.bashrc completion 등록(멱등·사용자 줄 보존·두 제거 경로·수동 줄 비침범)'
  )
  local harness_root readme_path readme_passes readme_check_ran pass_line
  harness_root="$(dirname "$(readlink -f "$SELF_PATH")")"
  readme_path="$harness_root/README.md"
  readme_passes="$test_root/readme-expected-output.txt"
  readme_check_ran=0
  if [[ -r "$readme_path" ]]; then
    if ! awk '
      $0 == "### 10. 쿼터 없는 자체 테스트" { in_section = 1; next }
      in_section && /^### / { exit }
      in_section && $0 == "기대 결과:" { expect_block = 1; next }
      expect_block && $0 == "```text" { in_block = 1; expect_block = 0; next }
      in_block && $0 == "```" { found = 1; exit }
      in_block { print }
      END { if (!found) exit 1 }
    ' "$readme_path" >"$readme_passes"; then
      die "README 기대 출력 블록을 읽을 수 없습니다: $readme_path"
    fi
    if ! diff -u <(printf '%s\n' "${pass_lines[@]}") "$readme_passes" >/dev/null; then
      die "README 기대 출력 블록이 실제 test PASS 목록과 다릅니다: $readme_path"
    fi
    readme_check_ran=1
  else
    info "README.md가 없어(설치본) 기대 출력 정합성 검사는 건너뜁니다."
  fi

  if [[ -s "$provider_stub_log" ]]; then
    die "self-test가 함수 스텁 밖에서 Provider CLI를 호출했습니다: $(tr '\n' ' ' <"$provider_stub_log")"
  fi

  rm -rf -- "$test_root"
  trap - EXIT

  for pass_line in "${pass_lines[@]}"; do
    if (( ! readme_check_ran )) && [[ "$pass_line" == 'PASS: README 기대 출력 ↔ 실제 test 출력 정합' ]]; then
      continue
    fi
    printf '%s\n' "$pass_line"
  done
}

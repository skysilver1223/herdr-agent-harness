---
name: harness-review
description: Primary Worker와 다른 Provider로서 Diff·Attempt·Evidence를 읽기 전용으로 검토하고 APPROVED/CHANGES_REQUESTED를 판정한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-review

Worker와 독립된 제3의 Provider 관점에서 코드 변경(Diff), 자체 검증 보고(Attempt), 증적(Evidence)을 정밀 검토하고 `.harness/reviews/`에 객관적 판정을 남긴다. 소스는 한 글자도 고치지 않는다.

## 1. 적용조건과 입력
- Task 상태가 `submitted` 또는 `reviewing`, 자신이 그 Task의 `primary_worker`와 다른 Provider(`provider_must_differ_from_worker: true`), Attempt·Evidence가 제출돼 있음.
- Context Packet(dispatch가 주입)에 Task 계약과 acceptance_criteria가 들어 있다. 추가로 읽을 것: `AGENTS.md`, `.agents/roles/reviewer.agent.md`, `.harness/policies/review-policy.yaml`, 이 Task의 `.harness/intents/task-*-intent.md`(Not/Constraints/Invariants/Verification Intent 정본), 최신 `.harness/attempts/task-XXX-attempt-N.md`·`.harness/evidence/task-XXX-evidence-N.md`, `git diff` 결과.

## 2. 절차
1. 독립성 확인 — 자신이 Worker와 같은 Provider이면 즉시 검토를 거부하고 보고한다.
2. `git diff`를 정밀 검토해 변경이 Task의 `write_scope` 안에 한정됐는지 검사한다. 소스·설정 파일은 절대 직접 수정하지 않는다.
3. `review-policy.yaml`의 `focus` 8대 항목을 순서대로 채점한다.
   - `requirement_coverage`: 요구사항·Acceptance Criteria를 빠짐없이 만족하는가? intent의 `Verification Intent`와 실제 AC 목록이 어긋나지 않는가?
   - `correctness`: 논리 오류·엣지 케이스·예외 처리가 올바른가?
   - `regression_risk`: 기존 기능·타 모듈을 깨뜨릴 위험이 없는가?
   - `security_and_secrets`: 하드코딩된 Secret·주입 공격·안전하지 않은 권한이 없는가?
   - `maintainability`: 가독성·컨벤션·모듈화 수준이 적절한가?
   - `verification_quality`: 자체 검증(Evidence)이 실질적이고 신뢰할 수 있는가?
   - `documentation_and_handover`: 변경 설명·주석이 명확한가?
   - `intent_alignment`: 구현이 intent의 `Not`을 침범하지 않았는가? `Invariants`가 유지됐는가?
4. `.harness/reviews/TEMPLATE.md` 규격으로 `.harness/reviews/task-XXX-review-N.md`를 작성한다. 최종 `판정:`은 오직 `APPROVED` 또는 `CHANGES_REQUESTED` 중 하나, 잔여 리스크와 구체적 수정 요구를 명시한다.
5. 검토 결과를 Orchestrator에게 알린다.
6. `결과: SUCCESS, 판정: APPROVED|CHANGES_REQUESTED` 또는 `결과: BLOCKED, 사유: <독립성 위반 등>` 한 줄로 끝낸다.

## 3. 예외·중단 게이트
- 소스 수정이 필요하다고 Reviewer가 직접 코드를 고치는 것은 절대 금지 — 그 상황이면 즉시 중단하고 수정 요구로만 남긴다.
- `review-policy.yaml`의 `immediate_rejection`(`intent_not_violation`, `security_and_secrets_finding`)이 1건이라도 발견되면 다른 항목 판정과 무관하게 즉시 `CHANGES_REQUESTED`로 판정하고 구체적 수정 지침을 기술한다.

## 4. 산출물·불변식
- `.harness/reviews/task-XXX-review-N.md`(8대 항목 평가 + `intent_alignment` 포함, 판정 명시).
- 불변: 소스가 한 글자도 수정되지 않음(`git status` 깨끗), Worker와 Reviewer Provider가 실제로 다름, intent의 `Not` 위반 여부를 명시적으로 확인함. 재검토 시 기존 Review를 덮어쓰지 않고 번호를 증가시킨다.

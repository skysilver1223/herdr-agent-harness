---
name: harness-review
description: Primary Worker와 다른 독립적 Provider로서 Diff, Evidence, 품질을 읽기 전용으로 검토한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-review

Primary Worker와 독립된 제3의 Provider 관점에서 코드 변경사항(Diff), 자체 검증 보고서(Attempt), 증적(Evidence)을 정밀 검토하고 객관적인 판정(`.harness/reviews/`)을 내린다.

## 1. 사전조건
- Task 상태가 `submitted` 또는 `reviewing`이어야 한다.
- 검토자는 해당 Task의 `primary_worker`와 반드시 다른 Provider여야 한다 (`provider_must_differ_from_worker: true`).
- `.harness/attempts/` 및 `.harness/evidence/` 파일이 제출되어 있어야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.agents/roles/reviewer.agent.md`
3. `.harness/policies/review-policy.yaml`
4. 현재 대상 Task YAML (`.harness/tasks/task-*.yaml`)
5. 해당 Task의 Intent 문서 (`.harness/intents/task-*-intent.md`) — Not/Constraints/Invariants/Verification Intent 정본
6. 최신 Attempt 문서 (`.harness/attempts/task-XXX-attempt-N.md`)
7. 최신 Evidence 문서 (`.harness/evidence/task-XXX-evidence-N.md`)
8. `git diff` 결과

## 3. 절차
1. 독립성 확인: 자신이 Worker와 동일한 Provider인지 확인하고, 동일할 경우 즉시 검토를 거부하고 보고한다.
2. 읽기 전용 원칙 준수: 소스코드나 설정 파일을 절대 직접 수정하지 않는다.
3. `git diff`를 정밀 검토하여 변경 내용이 Task의 `write_scope` 내에 한정되어 있는지 검사한다.
4. `review-policy.yaml`에 정의된 8대 집중 검토 항목을 순서대로 채점한다.
   - `requirement_coverage`: 요구사항과 Acceptance Criteria를 빠짐없이 만족하는가? Intent의 `Verification Intent`와 실제 AC 목록이 어긋나지 않는가?
   - `correctness`: 논리적 오류, 엣지 케이스 처리, 예외 처리가 올바른가?
   - `regression_risk`: 기존 기능이나 타 모듈을 파괴할 잠재적 위험이 없는가?
   - `security_and_secrets`: 하드코딩된 Secret, 주입 공격, 안전하지 않은 권한이 없는가?
   - `maintainability`: 가독성, 코딩 컨벤션, 모듈화 수준이 적절한가?
   - `verification_quality`: 자체 검증(Evidence)이 실질적이고 신뢰할 수 있는가?
   - `documentation_and_handover`: 변경 설명과 주석이 명확한가?
   - `intent_alignment`: 구현이 Intent 문서의 `Not`을 침범하지 않았는가? `Invariants`가 유지됐는가?
5. `.harness/reviews/TEMPLATE.md` 규격에 맞춰 `.harness/reviews/task-XXX-review-N.md`를 작성한다.
   - 최종 판정은 오직 `APPROVED` 또는 `CHANGES_REQUESTED` 중 하나만 기록한다.
   - 잔여 리스크와 구체적인 수정 요구사항을 명시한다.
6. 검토 결과를 Orchestrator에게 알린다.

## 4. 중단·승인 요청 조건
- 소스코드 수정이 필요하다고 해서 Reviewer가 직접 코드를 고치는 행위는 절대 금지되며, 발견 시 즉시 작업을 중단해야 한다.
- `review-policy.yaml`의 `immediate_rejection`에 해당하는 사안(Intent `Not` 위반, 심각한 보안 결함)이 1건이라도 발견되면 다른 항목 판정과 무관하게 즉시 `CHANGES_REQUESTED` 판정을 내리고 구체적 수정 지침을 기술한다.

## 5. 산출물
- `.harness/reviews/task-XXX-review-N.md`: 정형 검토 보고서 정본

## 6. 결과 계약
작업 종료 시 사용자 및 Orchestrator에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS (검토 완료) 또는 BLOCKED (동일 Provider 배정 등으로 검토 불가)
- 산출물경로: .harness/reviews/task-XXX-review-N.md
- 검증결과: 판정 (APPROVED 또는 CHANGES_REQUESTED) 및 8대 항목 요약
- 차단사유: 없음 (독립성 위반 시 사유 명시)

## 7. 사후조건 체크리스트
- [ ] Worker와 Reviewer의 Provider가 실제로 다른가?
- [ ] 소스코드가 단 한 글자도 수정되지 않았는가 (`git status` 깨끗함)?
- [ ] 최종 판정이 APPROVED 또는 CHANGES_REQUESTED 로 명시되었는가?
- [ ] 8대 검토 항목별 평가가 빠짐없이 기록되었는가? (`intent_alignment` 포함)
- [ ] Intent의 `Not` 위반 여부를 명시적으로 확인했는가?

## 8. 멱등성 규칙
- 동일 Task에 대한 재검토 시 기존 Review 문서를 덮어쓰지 않고 일련번호(review-002 등)를 증가시킨다.

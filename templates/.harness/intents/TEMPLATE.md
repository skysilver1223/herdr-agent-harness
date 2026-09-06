# Intent: {{TASK_ID}}

## 메타데이터
- Task ID: {{TASK_ID}}
- 작성 시각: {{TIMESTAMP}}
- 작성자: {{AUTHOR}}
- 연결 Task Contract: `.harness/tasks/{{TASK_ID}}.yaml`

## Why
[이 Task가 지금 필요한 이유 — 사업/운영 동기. SPEC.md·BOARD.md·사용자 결정 등 근거를 인용한다]

## What
[산출물 요약 — Task YAML의 target_files/write_scope와 1:1 대응하는 산문 설명]

## Not
[명시적 제외 — 이 Task가 절대 건드리지 않는 것. "안 정해서 못 함"이 아니라 "정해서 안 함"을 적는다]

## Constraints
[이 Task에 실제로 적용되는 정책 포인터 — AGENTS.md·CLAUDE.md·REVIEW_RULES.md의 해당 조항을 인용/링크한다. 전문을 복사하지 않는다]

## Invariants
[구현 전후로 절대 깨지면 안 되는 성질 — 예: "판별력이 리팩터링 전보다 떨어지면 안 된다", "결측을 0으로 채우지 않는다"]

## Open Questions / Decision Gates
[착수를 막는 미결정 사항 목록. 각 항목은 해소 시 `.harness/decisions/{{TASK_ID}}-decisions-NN.md`로 연결한다]

- [ ] {{질문 1}} — 해소 시 참조: `.harness/decisions/...`
- [ ] {{질문 2}} — 해소 시 참조: `.harness/decisions/...`

> 이 목록이 모두 체크되기 전에는 Task 상태를 `ready`로 전환하지 않는다.
> Acceptance Criteria에 착수 게이트를 다시 적지 않는다 — 게이트는 여기서만 관리한다.

## Verification Intent
[Task YAML의 acceptance_criteria가 왜 충분한지에 대한 근거. Reviewer는 실제 AC 목록이 이 의도와 어긋나지 않는지 대조한다]

## 이 문서의 역할
이 Task의 Why/What/Not/Constraints/Invariants/착수 게이트 정본은 이 파일이다.
Task YAML의 `objective`·`acceptance_criteria`는 검증 가능한 목적과 기준만 담고,
착수 조건·제외 범위·불변식 판단은 이 문서를 참조한다.

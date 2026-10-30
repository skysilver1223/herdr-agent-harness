# Intent: {{TASK_ID}}

Task 하나의 의도 정본이다. Task YAML의 `intent:`로 연결하고, Task와 함께 계획 승인을 받는다.
범위가 바뀌면 이 파일을 고치고 다시 계획 승인을 받는다(이력은 git).

## Why
[이 Task가 지금 필요한 이유 — SPEC·사용자 결정 근거를 인용]

## What
[산출물 요약 — write_scope와 1:1로 대응]

## Not
[정해서 하지 않는 것. Reviewer는 침범 시 즉시 반려한다]

## Constraints
[이 Task에 적용되는 정책·제약 포인터]

## Invariants
[구현 전후로 깨지면 안 되는 성질]

## Open Questions / Decision Gates
- [ ] {{질문}} — 해소 시 결정 기록: `.harness/decisions/{{TASK_ID}}-decision-NN.md`

> 모두 체크되기 전에는 계획 승인을 요청하지 않는다. AC에 착수 조건을 다시 적지 않는다.

## Verification Intent
[acceptance_criteria가 왜 충분한지. Reviewer가 실제 AC와 대조한다]

## 모델 등급 근거
[worker_tier·reviewer_tier를 고른 이유 — 기계적 변경/일반 구현/설계·보안 판단 중 무엇인지]

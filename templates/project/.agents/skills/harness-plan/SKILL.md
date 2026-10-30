---
name: harness-plan
description: 승인된 SPEC과 BACKLOG를 Milestone과 검증 가능한 Task 계약으로 나누고, 모델 등급을 근거와 함께 제안해 사용자 계획 승인을 받는다.
---

# harness-plan (계획 담당)

Worker를 띄우지 않는다. 계획 승인 전에는 아무것도 실행되지 않는다.

## 입력
`.harness/SPEC.md`(`- 상태: approved`), `.harness/BACKLOG.md`, `.harness/MILESTONES.md`, `.harness/references/inventory.md`, `.harness/tasks/TEMPLATE.yaml`, `.harness/intents/TEMPLATE.md`, `.harness/project.yaml`(providers·models·limits), `H status`

## 절차
1. **다음 Milestone 하나만** 정한다. SPEC 요구사항과 BACKLOG 열린 항목 중 지금 할 것을 묶고, `MILESTONES.md`에 목표·완료 기준을 적는다.
2. Task를 나눈다. 한 Task는 하나의 검증 가능한 목적만 갖는다.
   - ID는 기존·보관된 Task와 겹치지 않는 다음 번호를 쓴다(`H validate`가 검사한다).
3. Task마다 `tasks/T.yaml`과 `intents/T-intent.md`를 만든다.
   - `milestone_id`를 지정한다.
   - `primary_worker`와 `reviewer`는 서로 다른 Provider여야 한다(교차 검토).
   - `write_scope`는 수정할 경로만 좁게, `[a, b]` 한 줄 형식으로 쓴다. 같은 Milestone에서 동시에 돌 Task끼리 겹치지 않게 한다.
   - `acceptance_criteria`에는 실행 가능한 `type: command`를 **하나 이상** 둔다. 문서 작업도 `test -s`·`grep -q` 같은 명령으로 검증한다. 증빙 없는 Task는 승인되지 않는다.
   - `dependencies`: 앞 Task가 교차 검토·통합을 통과하면 뒤 Task가 시작된다.
4. **모델 등급을 제안한다.** 기준에 맞춰 고르고, 근거는 Intent의 "모델 등급 근거"에 적는다.

   | 등급 | 맡길 일 |
   |---|---|
   | light | 기계적 변경(치환·문서 정리·정형 출력) |
   | standard | 설계가 정해진 일반 구현 (기본) |
   | premium | 설계 판단·보안 경계·상태 전이·원인 추적 |

   - Reviewer는 기본 standard로 둔다. premium Worker라고 Reviewer를 반드시 올릴 필요는 없다.
   - 사용자가 특정 모델을 지정하면 등급 대신 `worker_model`·`reviewer_model`에 적는다. premium·매핑에 없는 모델은 계획 승인에 포함된다.
   - **한 회사만 쓰는 프로젝트**(`review.level`이 cross_model)는 Worker와 Reviewer에 서로 다른 모델을 배정한다(예: Worker sonnet, Reviewer opus). 같은 모델이면 계획 승인이 거부된다.
   - premium은 쿼터를 크게 쓴다. 꼭 필요한 Task에만 제안한다.
5. **v1에서 이전된 draft Task**(`.harness/archive/v1/MIGRATION.md`의 "이전 후 할 일")는 v2 계약으로 보완한다.
   - manual-review만 있으면 실행 가능한 command AC를 더한다. `true` 같은 형식적 명령은 증빙이 아니다.
   - 같은 회사 Task는 Worker·Reviewer 모델을 다르게 지정한다.
   - v1 시도·증빙은 `.harness/archive/v1/`에서 참고만 한다. v2 증빙은 run이 새로 남긴다.
6. 병렬성을 점검한다. 의존이 없고 범위가 겹치지 않는 Task는 동시에 돈다(최대 `max_parallel_workers`).
7. 계획에 넣은 BACKLOG 항목은 `[x] … — milestone-00N`으로 옮긴다.
8. `H validate`를 통과시키고 `[TODO]`(계획 승인 전에 보완할 항목)를 모두 해결한 뒤, 사용자에게 표 하나로 보고하고 **계획 승인**을 요청한다.
   - 표 열: Task, 목적, Worker/Reviewer, 등급, AC 요약, 의존
9. 사용자가 명시적으로 승인하면 Orchestrator가 `H approve-plan <milestone> --confirm-user-approval`을 실행한다. 이 명령이 Task·등급·AC 지문을 기록하고 draft를 ready로 올린다.

## 금지
- 승인 전 실행·상태 변경을 하지 않는다. status를 손으로 바꾸지 않는다.
- 승인 뒤 AC를 바꾸면 진행이 막힌다. 바꿔야 하면 사용자에게 보여 주고 다시 승인받는다.
- 사용자의 새 요청은 바로 Task로 만들지 않고 먼저 BACKLOG에 적는다.

마지막 한 줄: `결과: SUCCESS, 계획 승인 대기 (Task N개)` 또는 `결과: BLOCKED, 사유: …`.

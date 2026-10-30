---
name: harness-handover
description: 실패·쿼터 소진·장애·교체 지시 때 다음 작업자가 바로 이어받을 수 있는 인계 문서를 남긴다(예외 절차).
---

# harness-handover (예외 절차)

자동 교체 규칙(project.yaml `failover: auto`)이 있으면 run이 인계 문서를 자동으로 쓴다. 이 Skill은 사람이 승인하는 교체와 그 밖의 중단에 쓴다.

## 절차
1. 사유를 분류한다: `quota_exhausted` / `agent_error` / `repeated_failure` / `blocker` / `user_directed`.
2. 작업 디렉터리의 변경을 그대로 보존한다(되돌리지 않는다). `git status --short`·`git diff --stat`을 뽑는다.
3. `.harness/handovers/<TASK>-handover-<N>.md`를 쓴다. 기존 번호에 1을 더하고, 덮어쓰지 않는다.
   - 일시, 원작업자 → 대상 Provider, 사유
   - 끝낸 것 / 못 끝낸 것과 작업 공간 상태
   - 마지막 검증 결과와 실패 요약(Harness 증빙 경로)
   - 막힌 점·결정이 필요한 점
   - 다음 작업자가 할 **정확한 다음 한 단계**
4. 상태 전이는 Orchestrator가 한다. 사용자가 교체를 승인하면 다음 순서로 진행한다.
   1. `H transition T handover_required`
   2. Task의 `primary_worker` 변경 (Reviewer와 달라야 한다)
   3. `H transition T ready`

## 금지
- 인계 문서 없이 작업을 버리거나 Provider를 바꾸지 않는다(`handover_required`는 문서가 있어야 통과한다).
- 교체 규칙이 `ask`이면 사용자 승인 없이 다른 Provider를 부르지 않는다.

마지막 한 줄: `결과: SUCCESS, 인계 완료 (사유: <분류>)`.

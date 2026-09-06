---
name: harness-handover
description: 실패·쿼터·교체 발생 시 최소 컨텍스트를 인계 문서로 남기고 프로세스를 안전하게 멈춘다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-handover

에러 반복·Quota 소진·세션 중단·외부 블로커·Provider 교체 지시가 발생했을 때, 진행 내용을 다음 작업자에게 최소·정밀하게 인계한다. 정상 작업 경로가 아니라 예외 프로토콜이다.

## 1. 적용조건과 입력
- Task 상태가 `active`, `blocked` 또는 `handover_required`이고 중단 사유(할당량 초과·반복 실패·프로세스 종료 등)가 실제로 발생한 상태.
- 읽을 것: 이 Task의 `.harness/tasks/task-*.yaml`, 최근 Attempt·Evidence, `git status`·`git diff`. 사유 분류 기준은 `.harness/policies/quota-policy.yaml`.

## 2. 절차
1. 중단 사유를 분류한다: `quota_exhausted` / `blocker` / `repeated_failure` / `user_directed`.
2. 작업 트리의 현재 수정 내용을 보존하고 `git status --short`·`git diff --stat`을 추출한다.
3. `.harness/handovers/TEMPLATE.md` 규격으로 `.harness/handovers/task-XXX-handover-N.md`를 작성한다 — 인계 일시·원작업자/대상 Provider, 완료된 작업, 미완료 작업과 작업 트리 상태, 실행한 검증 결과·실패 로그 요약, 직면한 블로커·리스크, 다음 작업자가 즉시 수행할 **정확한 다음 한 단계**.
4. 상태 전이는 Orchestrator에게 요청한다 — `active`이고 사용자 입력 대기면 `blocked`, 장애·쿼터·교체면 `handover_required`. 이미 `blocked`/`handover_required`이면 추가 전이 없이 인계 기록만 남긴다.
5. 인계 문서 작성 후 현재 작업 프로세스를 안전하게 대기 상태로 둔다.
6. `결과: SUCCESS, 인계 완료 (사유: <분류>)` 한 줄로 끝낸다.

## 3. 예외·중단 게이트
- 인계 문서(`handovers/`) 없이 프로세스를 일방적으로 종료·방치하는 것을 엄격히 금지한다. `herdr-harness transition ... handover_required`는 이 문서가 있어야 통과한다.
- 사용자 승인 없이 대체 Provider를 임의로 호출하지 않는다.

## 4. 산출물·불변식
- `.harness/handovers/task-XXX-handover-N.md`.
- 불변: 수정 중이던 코드가 작업 트리에 유실 없이 보존됨, '다음 한 단계'가 구체적임. 추가 핸드오버 시 기존 파일을 덮어쓰지 않고 번호를 증가시킨다.

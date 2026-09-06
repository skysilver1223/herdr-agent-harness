---
name: harness-handover
description: 실패·쿼터·교체 전에 최소 정밀 Context를 인계하고 핸드오버 문서를 작성한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-handover

작업 도중 에러 반복, Quota 소진, 세션 중단, 외부 블로커 또는 Provider 교체 지시가 발생했을 때, 현재 상태와 진행 내용을 다음 작업자에게 안전하고 최소화된 컨텍스트로 인계한다.

## 1. 사전조건
- Task 상태가 `active`, `blocked` 또는 `handover_required`여야 한다.
- 진행 중단 사유(할당량 초과, 반복 실패, 프로세스 종료 등)가 발생한 상태여야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.agents/roles/worker.agent.md`
3. `.harness/policies/quota-policy.yaml`
4. 현재 Task YAML (`.harness/tasks/task-*.yaml`)
5. 최근 Attempt 및 Evidence 파일
6. `git status` 및 `git diff`

## 3. 절차
1. 중단 사유를 명확히 분류한다: `quota_exhausted` / `blocker` / `repeated_failure` / `user_directed`.
2. 작업 트리의 현재 수정 내용을 보존하고 `git status --short` 및 `git diff --stat`을 추출한다.
3. `.harness/handovers/TEMPLATE.md` 규격에 맞춰 `.harness/handovers/task-XXX-handover-N.md`를 작성한다.
   - 인계 일시, 원작업자 Provider, 대상 Provider
   - 완료된 작업(What was done)
   - 미완료 작업 및 작업 트리 상태(Pending changes & Git Diff)
   - 실행했던 검증 결과 및 실패 로그 요약
   - 직면한 장애 요인 및 리스크(Blockers & Risks)
   - 다음 작업자가 즉시 수행해야 할 정확한 다음 한 단계(Next Single Action)
4. 현재 Task 상태에 따라 전이 요청을 구분한다.
   - 현재 상태가 `active`이면 원인이 사용자 입력 대기일 때 `blocked`, 장애·쿼터·교체 필요일 때 `handover_required`로 전이하도록 Orchestrator에게 요청한다.
   - 현재 상태가 이미 `blocked` 또는 `handover_required`이면 추가 상태 전이를 요청하지 않고 Handover 기록만 남긴다.
   - `blocked -> handover_required`, `handover_required -> blocked` 또는 동일 상태 재전이를 시도하지 않는다.
5. 인계 문서 작성 완료 후 현재 작업 프로세스를 안전하게 대기 상태로 전환한다.

## 4. 중단·승인 요청 조건
- 인계 문서(`handovers/`)를 작성하지 않은 채 일방적으로 프로세스를 종료하거나 방치하는 것을 엄격히 금지한다.
- 사용자 승인 없이 대체 Provider를 즉시 임의 호출하지 않는다.

## 5. 산출물
- `.harness/handovers/task-XXX-handover-N.md`: 정합성 있는 인계 패킷 문서

## 6. 결과 계약
작업 종료 시 사용자 및 Orchestrator에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS (인계 완료)
- 산출물경로: .harness/handovers/task-XXX-handover-N.md
- 검증결과: 중단 사유, 보존된 Diff 크기, 다음 한 단계 명시 여부
- 차단사유: 직면했던 차단 사유 요약

## 7. 사후조건 체크리스트
- [ ] 수정 중이던 코드가 유실되지 않고 작업 트리에 보존되었는가?
- [ ] 다음 작업자를 위한 '다음 한 단계(Next Single Action)'가 모호하지 않고 구체적인가?
- [ ] handover 파일이 올바른 경로에 생성되었는가?

## 8. 멱등성 규칙
- 추가 핸드오버 발생 시 기존 파일을 덮어쓰지 않고 일련번호를 증가시켜 저장한다.

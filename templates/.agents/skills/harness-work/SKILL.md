---
name: harness-work
description: 승인된 Task 하나를 수행하여 코드를 구현하거나 분석하고 자체 검증 및 Attempt를 작성한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-work

승인된 단 하나의 Task Contract를 엄격히 준수하여 구현, 분석, 수정을 수행하고, 자체 검증과 Attempt 문서를 작성하여 `submitted` 상태를 제안한다.

## 1. 사전조건
- Task 상태가 `active`여야 한다.
- 자신이 해당 Task의 `primary_worker`로 지정되어 있어야 한다.
- 작업 브랜치 또는 작업 트리가 깨끗하고 Git 추적 중이어야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.agents/roles/worker.agent.md`
3. 현재 대상 Task 계약 파일 (`.harness/tasks/task-*.yaml`)
4. 해당 Task의 Intent 문서 (`.harness/intents/task-*-intent.md`) — Why/What/Not/Constraints/Invariants/Open Questions 정본
5. `.harness/SPEC.md`
6. `.harness/references/inventory.md`
7. 이전 Attempt가 있을 경우 최신 Attempt 및 Review 파일

## 3. 절차
1. Task YAML의 `objective`, `target_files`, `write_scope`, `acceptance_criteria`를 정독한다.
2. Intent 문서의 `Not`·`Constraints`·`Invariants`를 정독한다. `Open Questions / Decision Gates`에 미해소 항목이 있으면 구현을 시작하지 않고 즉시 Orchestrator에게 알린다.
3. 구현 전 `git status`로 현재 기준선을 확인한다.
4. `write_scope`에 지정된 파일 및 경로 내에서만 코드를 작성하거나 수정한다. 허용되지 않은 파일(설정, 다른 모듈, 정책 문서)은 절대 수정하지 않는다. `write_scope`에 포함되어 있어도 Intent의 `Not`에 명시된 범위는 침범하지 않는다.
5. `acceptance_criteria`의 각 항목에 연결된 검증 명령(`verified_by`)을 실행하여 자가 검증을 수행한다 (`harness-verify` 참조).
6. 기존 테스트 및 회귀 테스트를 실행하여 부작용이 없음을 확인한다.
7. `.harness/attempts/task-XXX-attempt-N.md` 파일을 작성한다 (N은 001부터 순차 증가).
   - 작업 변경 요약
   - 수정한 파일 목록 및 `git diff --stat`
   - 자체 검증 명령, 실행 결과, 종료 코드
   - Reviewer를 위한 중점 검토 포인트 (Intent의 Not/Invariants 대비 확인 포인트 포함)
8. 구현 및 문서 작성이 완료되면 `submitted` 상태로의 전이를 요청한다.

## 4. 중단·승인 요청 조건
- Intent 문서의 `Not`·`Constraints`가 Task YAML의 지시와 상충하거나, `Open Questions / Decision Gates`가 미해소 상태이면 구현을 시작하지 않고 즉시 중단한다.
- `write_scope` 외부 파일 수정이 불가피한 경우 작업을 중단하고 Orchestrator에게 계약 수정을 요청한다.
- 외부 API 키, 인증 정보 등 시크릿이 필요하거나 모호한 정책 판단이 필요한 경우 즉시 작업을 멈추고 `blocked` 상태를 알린다.
- 동일 원인으로 검증이 3회 이상 실패하거나 쿼터 소진 징후가 보이면 `harness-handover`를 호출하고 작업을 중단한다.
- Worker는 어떠한 경우에도 스스로 `completed`를 선언하거나 승인하지 않는다.

## 5. 산출물
- `write_scope` 내 구현 및 수정 소스코드
- `.harness/attempts/task-XXX-attempt-N.md`: 정형화된 시도 보고서
- `.harness/evidence/task-XXX-evidence-N.md`: 자체 검증 로그 증적

## 6. 결과 계약
작업 종료 시 사용자 및 Orchestrator에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS 또는 BLOCKED
- 산출물경로: .harness/attempts/task-XXX-attempt-N.md
- 검증결과: acceptance_criteria 검증 통과 여부 및 diff 요약
- 차단사유: 없음 (차단 시 blocked 사유 및 필요 자원 명시)

## 7. 사후조건 체크리스트
- [ ] Intent 문서의 `Not`에 명시된 범위를 침범하지 않았는가?
- [ ] write_scope 외부의 파일이 수정되지 않았는가 (`git status` 확인)?
- [ ] acceptance_criteria의 모든 검증 명령이 성공(exit code 0)하였는가?
- [ ] Attempt 문서에 diff stat과 검증 결과가 충실히 기록되었는가?
- [ ] 완료 보고 시 completed가 아닌 submitted를 제안하였는가?

## 8. 멱등성 규칙
- 재작업 시 기존 Attempt 파일을 덮어쓰지 않고 새로운 번호(attempt-002 등)의 파일을 생성한다.
- 이전 작업물의 유효한 부분은 Git 히스토리를 통해 안전하게 계승한다.

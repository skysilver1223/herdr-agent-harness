---
name: harness-orchestrate
description: Herdr에서 승인된 Wave의 Task를 1스텝씩 디스패치하고 상태 전이를 강제하며 진행을 보고한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-orchestrate

Herdr Multiplexer 환경에서 승인된 Wave를 실행한다. 1스텝 CLI(`herdr-harness`)로 Worker와 Reviewer를 디스패치하고 라이프사이클·상태 전이를 안전하게 제어한다. 자율 무한 루프를 돌리지 않는다 — 한 스텝씩 디스패치하고 결과를 검증한 뒤 다음 단계를 정한다.

## 1. 적용조건과 입력
- `test "${HERDR_ENV:-}" = 1` 통과, `.harness/SPEC.md`와 실행 대상 Wave가 사용자 승인됨, `herdr-harness validate .`가 PASS.
- 읽을 것: `AGENTS.md`, `.agents/roles/orchestrator.agent.md`, `.harness/project.yaml`, `.harness/policies/`, `.harness/STATE.md`, 현재 `.harness/waves/wave-*.yaml`, 실행 대상 `.harness/tasks/task-*.yaml`.

## 2. 절차
1. **사전 검증·관측.** `herdr-harness validate .`(Git·스키마·권한·정책, 실패 시 즉시 중단) → `herdr-harness status --live .`(Herdr agent/pane과 STATE.md의 Drift·orphan 확인). ORPHAN 등록 Agent는 `herdr-harness close-agent . <task_id> worker|reviewer`로 정리한다. (진행 상황 요약이 필요할 때도 `status --live .` 결과를 사용자에게 정리해 보고한다.)
2. **Task 선택·전이 (ready → active).** 승인된 Wave에서 의존성이 충족된 `ready` Task를 골라 `herdr-harness transition . <task_id> active`.
3. **Worker 디스패치 (active).** `herdr-harness dispatch . <task_id> worker` — 내부적으로 pane split·agent start·Context Packet 주입·`agent prompt --wait`를 수행하고 결과를 정규화한다. 반환 코드별 분기:
   - `settled`: 4로 진행.
   - `blocked`: `herdr-harness observe . <task_id>`로 원인 수집 → `herdr-harness transition . <task_id> blocked` → 사용자에게 즉시 질문하고 루프를 일시 중지.
   - `timeout`/`stalled`: `observe`로 출력 확인 후 재대기할지 중단할지 판단.
   - `agent_lost`/`error`: `herdr-harness transition . <task_id> handover_required`(인계 문서 필요) 후 사용자에게 보고.
   - `agent read` 출력이 비었거나 잘리면(Alternate Screen 등) Worker에게 `.harness/attempts/<task_id>-attempt-N.md` 파일 산출을 요청하고 존재·내용을 확인한다.
4. **제출 검증·전이 (active → submitted).** `.harness/attempts/<task_id>-attempt-*.md`와 Evidence 파일 생성 확인 → `git status --short`·`git diff --stat`으로 write_scope 준수 확인 → `herdr-harness transition . <task_id> submitted` → `herdr-harness close-agent . <task_id> worker`.
5. **Reviewer 디스패치 (submitted → reviewing).** `herdr-harness transition . <task_id> reviewing`(Worker≠Reviewer 강제) → `herdr-harness dispatch . <task_id> reviewer`(읽기 전용, `review-policy.yaml`의 8대 `focus`로 `.harness/reviews/<task_id>-review-N.md` 작성). `timeout`/`stalled`이면 `herdr-harness observe . <task_id> reviewer`. 끝나면 `herdr-harness close-agent . <task_id> reviewer`.
6. **판정 처리.** Review의 `판정:`을 읽는다. `CHANGES_REQUESTED`이면 `herdr-harness transition . <task_id> changes_requested` → `herdr-harness transition . <task_id> ready` 후 2로 복귀. `APPROVED`이면 `herdr-harness transition . <task_id> awaiting_approval`.
7. **완료 승인 Gate (awaiting_approval → completed).** Wave의 모든 Task가 `awaiting_approval`에 도달하면 `herdr-harness status --live .`를 종합해 사용자에게 보고한다. 사용자가 채팅에서 현재 Task의 완료를 명시적으로 승인한 경우에만 `herdr-harness approve . <task_id> --confirm-user-approval`을 호출한다. 이 명령이 Task ID·상태·최신 APPROVED Review를 재검증하고 승인 파일을 원자적으로 기록한 뒤 기존 transition Gate를 호출한다. 승인 파일을 직접 편집하거나 사용자 발화에서 승인 권한을 추론하지 않는다.
8. `결과: SUCCESS, <실행한 Task·전이·판정 요약>` 또는 `결과: BLOCKED, 사유: <승인 대기·Agent 블록·장애 등>` 한 줄로 끝낸다.

## 3. 예외·중단 게이트
- `HERDR_ENV != 1`, `herdr-harness validate .` 실패, Worker가 `blocked`이거나 시크릿 요구, Provider Failover가 필요한 장애, Wave 완료 후 `completed` 승인 대기 — 이 중 하나면 멈추고 사용자 판단을 받는다.
- 일반 상태 변경은 `herdr-harness transition`으로, 사용자 완료 승인의 기록·전이는 명시적 승인 뒤 `herdr-harness approve ... --confirm-user-approval`로만 한다(Task YAML·승인 파일 직접 편집 금지). 실패 원인 분석·핸드오버 문서 없이 타 Provider를 연쇄 호출(failover)하지 않는다.

## 4. 산출물·불변식
- `.harness/STATE.md`, `.harness/waves/`, `.harness/runtime/`, 사용자 명시 승인 때 `approve`가 생성한 `.harness/decisions/<task-id>-approval.md`.
- 불변: 모든 상태 전이가 `herdr-harness transition` 경유(`approve`도 내부 재사용), Worker와 Reviewer가 서로 다른 Provider로 실행됨, 사용 끝난 Herdr 패널이 `close-agent`로 정리됨, `completed`는 사용자 명시 승인 하에서만. 세션이 끊기면 새 세션에서 `herdr-harness status --live .`로 현재 상태부터 재개한다.

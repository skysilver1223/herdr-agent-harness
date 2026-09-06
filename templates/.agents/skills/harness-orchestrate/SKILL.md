---
name: harness-orchestrate
description: Herdr 환경에서 승인된 Wave의 Task들을 단계별로 실행하고 상태를 관리한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-orchestrate

Herdr Multiplexer 환경에서 승인된 Wave를 실행한다. 스크립트 기반 1스텝 도구(`herdr-harness`)를 호출하여 Worker와 Reviewer를 디스패치하고, 라이프사이클과 상태 전이를 안전하게 제어한다.

## 1. 사전조건
- `test "${HERDR_ENV:-}" = 1` 환경 검증을 통과해야 한다.
- `.harness/SPEC.md`와 실행 대상 Wave가 사용자 승인을 받은 상태여야 한다.
- `herdr-harness validate .` 검증이 PASS 상태여야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.harness/project.yaml`
3. `.agents/roles/orchestrator.agent.md`
4. `.harness/policies/`
5. `.harness/STATE.md`
6. 현재 활성 Wave 파일 (`.harness/waves/wave-*.yaml`)
7. 실행 대상 Task YAML (`.harness/tasks/task-*.yaml`)

## 3. 절차

### 1단계: 사전 검증 및 런타임 관측
1. `herdr-harness validate .` 를 실행하여 Git 상태, 스키마, 권한, 정책을 검사한다. 실패 시 즉시 중단한다.
2. `herdr-harness status --live .` 를 실행하여 실제 Herdr agent/pane 상태와 STATE.md 간의 Drift나 고아(orphan) 패널 유무를 확인한다.
3. ORPHAN으로 판정된 등록 Agent는 `herdr-harness close-agent . <task_id> worker|reviewer` 로 정리한다.

### 2단계: Task 선택 및 상태 전이 (ready -> active)
1. 현재 승인된 Wave에서 의존성이 충족된 `ready` 상태의 Task를 선택한다.
2. `herdr-harness transition . <task_id> active` 명령을 실행하여 상태를 원자적으로 전이한다.

### 3단계: Worker 디스패치 및 1스텝 실행
1. `herdr-harness dispatch . <task_id> worker` 명령을 호출한다.
   - 내부적으로 Herdr 패널 분할(`pane split --no-focus`), Worker 기동(`agent start`), Context Packet 주입, 프롬프트 대기(`agent prompt --wait`)를 수행하고 결과를 정규화하여 반환한다.
2. 반환 결과 코드에 따라 분기한다.
   - `settled`: 정상 완료. 4단계로 진행한다.
   - `blocked`: Worker가 사용자 입력이나 시크릿을 요구함. `herdr-harness observe . <task_id>`로 원인을 수집하고, `herdr-harness transition . <task_id> blocked` 실행 후 사용자에게 즉시 질문하고 루프를 일시 중지한다.
   - `timeout` 또는 `stalled`: 응답 지연. `herdr-harness observe . <task_id>`로 출력 확인 후 재대기할지 중단할지 판단한다.
   - `agent_lost` 또는 `error`: 에이전트 비정상 종료. `herdr-harness transition . <task_id> handover_required` 실행 후 사용자에게 보고한다.
3. Fallback 처리: 만약 Herdr 터미널 Alternate Screen 등의 사유로 `agent read` 출력이 비어 있거나 잘린 경우, Worker에게 파일 산출(`.harness/attempts/<task_id>-attempt-N.md`)을 요청하고 해당 파일의 존재와 내용을 확인한다.

### 4단계: 제출 검증 및 상태 전이 (active -> submitted)
1. `.harness/attempts/<task_id>-attempt-*.md` 파일과 Evidence 파일이 생성되었는지 확인한다.
2. `git status --short` 및 `git diff --stat`으로 write_scope 준수 여부를 확인한다.
3. `herdr-harness transition . <task_id> submitted` 명령을 실행한다.
4. 사용이 완료된 Worker 패널은 `herdr-harness close-agent . <task_id> worker` 로 안전하게 정리한다.

### 5단계: Reviewer 디스패치 및 독립 검토 (submitted -> reviewing)
1. `herdr-harness transition . <task_id> reviewing` 명령을 실행한다 (Worker != Reviewer 강제 검증).
2. `herdr-harness dispatch . <task_id> reviewer` 명령을 호출한다.
   - Reviewer는 읽기 전용으로 Diff, Attempt, Evidence를 `review-policy.yaml`의 8대 정책 기준(`focus`)에 맞춰 검토하고 `.harness/reviews/<task_id>-review-N.md`를 작성한다.
   - Reviewer 응답이 `timeout` 또는 `stalled`이면 `herdr-harness observe . <task_id> reviewer`로 재조회한다.
3. 검토 완료 후 `herdr-harness close-agent . <task_id> reviewer` 로 패널을 닫는다.

### 6단계: 판정 처리 및 순환
1. 생성된 Review 파일의 최종 `판정:`을 읽는다.
2. 판정이 `CHANGES_REQUESTED`인 경우:
   - `herdr-harness transition . <task_id> changes_requested` 실행.
   - 피드백 반영을 위해 `herdr-harness transition . <task_id> ready` 실행 후 2단계로 되돌린다.
3. 판정이 `APPROVED`인 경우:
   - `herdr-harness transition . <task_id> awaiting_approval` 실행.

### 7단계: 사용자 완료 승인 Gate (awaiting_approval -> completed)
1. Wave 내 모든 Task가 `awaiting_approval` 상태에 도달하면 `herdr-harness status --live .` 결과를 종합하여 사용자에게 보고한다.
2. 사용자가 `.harness/decisions/`에 승인 결정을 남기고 지시한 경우에만 `herdr-harness transition . <task_id> completed` 를 호출한다.
3. Orchestrator는 절대 사용자를 대신하여 `completed`를 승인하지 않는다.

## 4. 중단·승인 요청 조건
- HERDR_ENV != 1 환경인 경우.
- `herdr-harness validate .` 실패 시.
- Worker가 `blocked` 상태이거나 시크릿 입력을 요구할 때.
- Provider Failover가 필요한 장애 발생 시.
- Wave 완료 후 `completed` 승인 대기 시점.

## 5. 산출물
- `.harness/STATE.md`: 실시간 갱신된 프로젝트 상태
- `.harness/waves/`: 갱신된 Wave 상태
- `.harness/runtime/`: 실행 로그 및 임시 메타데이터

## 6. 결과 계약
작업 종료 시 사용자에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS 또는 BLOCKED
- 산출물경로: .harness/STATE.md
- 검증결과: 실행된 Task ID, 전환된 상태, 검토 판정 결과
- 차단사유: 없음 (사용자 승인 대기, 에이전트 블록, 장애 발생 시 상세 원인 기재)

## 7. 사후조건 체크리스트
- [ ] Task 상태 전이가 오직 herdr-harness transition 명령으로만 수행되었는가?
- [ ] Worker와 Reviewer가 서로 다른 Provider로 실행되었는가?
- [ ] 작업 완료 후 불필요한 Herdr 패널이 close-agent로 정리되었는가?
- [ ] completed 상태가 오직 사용자의 명시적 승인 하에서만 반영되었는가?

## 8. 멱등성 규칙
- 세션이 중간에 끊기더라도 새 세션에서 `herdr-harness status --live .`를 실행해 현재 STATE.md에 기록된 상태부터 안전하게 재개한다.
- 이미 완료된 Task를 재실행하지 않으며, 실패한 Task는 새 Attempt 번호로 재진입한다.

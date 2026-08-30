# Herdr Agent/Skills Harness Architecture

## 1. 목적

Herdr에서 Claude, Codex, AGY를 함께 사용하되 프로젝트마다 Controller 프로그램을 개발하지 않고 역할 문서, Agent Skills, Git, 사용자 승인으로 전체 작업 흐름을 운영합니다.

이 문서에서 Full Harness는 다음 흐름을 모두 다룬다는 의미입니다.

```text
Interview → SPEC → Reference → Plan → Work → Verify → Review → User Approval → Handover
```

무인 실행, 트랜잭션, 물리적 Sandbox를 의미하지는 않습니다.

## 2. 구성요소

| 구성요소 | 책임 |
|---|---|
| Herdr | Workspace, Pane, Agent 프로세스와 상태 표시 |
| `AGENTS.md` | Provider 공통 운영 정책 |
| `CLAUDE.md`, `GEMINI.md` | Provider별 짧은 진입 지침 |
| `.agents/roles/` | 역할·책임·금지사항 정본 |
| `.agents/skills/` | 재사용 가능한 실행 절차 |
| `.claude/skills/` | Claude가 공통 Skill을 읽기 위한 연결 |
| `.harness/` | SPEC, 계획, 상태, Task, Evidence, Review, Handover |
| 사용자 | SPEC, Wave, Failover, Integration, 완료 승인 |

## 3. 역할

| 역할 | 쓰기 | 책임 |
|---|---:|---|
| Interviewer | Harness 문서 | 요구사항과 기존 자료 확인 |
| Planner | Harness 문서 | Milestone과 Task 분할 |
| Orchestrator | Harness 상태 | Herdr Pane과 Wave 운영 |
| Primary Worker | Task 범위 | 구현·조사·분석 |
| Advisor | 없음 | 특정 쟁점의 읽기 전용 조언 |
| Reviewer | 없음 | 전체 품질과 Evidence 검토 |
| 사용자 | 승인 | 최종 상태와 Provider 교체 결정 |

하나의 Task에 여러 Provider가 참여할 수 있지만 동시에 쓰기 가능한 Primary Worker는 한 명뿐입니다.

## 4. Project, Milestone, Task

```mermaid
flowchart TD
    P[Project] --> M[Milestone]
    M --> T1[Task]
    M --> T2[Task]
    T1 --> W[Worker Attempt]
    T1 --> R[Review]
```

- Project는 전체 최종 목표입니다.
- Milestone은 Project 완성에 필요한 중간 목표입니다.
- Task는 Milestone을 만드는 하나의 검증 가능한 목적입니다.
- 프로젝트 전체 Task 수는 제한하지 않습니다.
- 현재 활성 Task는 기본 5개, 병렬 Worker는 2개로 제한합니다.
- 완료 Milestone은 Archive해 기본 Context에서 제외합니다.

## 5. Task 상태

```mermaid
stateDiagram-v2
    [*] --> draft
    draft --> ready: 사용자 계획 승인
    ready --> active: Worker 시작
    active --> submitted: 결과 제출
    active --> blocked: 입력 필요
    active --> handover_required: 실패·쿼터
    submitted --> reviewing: 독립 Review
    reviewing --> changes_requested: 수정 필요
    reviewing --> awaiting_approval: Review 통과
    changes_requested --> ready: 재시도 승인
    handover_required --> ready: 교체 승인
    awaiting_approval --> completed: 사용자 승인
```

Worker는 `completed`를 선언하지 않습니다. Reviewer는 품질 판정을 기록하고 사용자가 완료를 승인합니다.

## 6. Skills

| Skill | 역할 |
|---|---|
| `harness-interview` | 요구사항 인터뷰 |
| `harness-reference` | 기존 코드·데이터·문서 Inventory |
| `harness-plan` | Milestone과 Task 분할 |
| `harness-orchestrate` | Herdr 실행과 상태 관리 |
| `harness-work` | Task 단위 구현·분석 |
| `harness-verify` | 검증과 Evidence 기록 |
| `harness-review` | 독립 품질 Review |
| `harness-handover` | 실패·쿼터 시 Context 인계 |
| `harness-status` | 현재 진행 상황 요약 |

각 Skill은 현재 역할 문서, SPEC, STATE, Task Contract를 명시적으로 읽습니다. Skill은 운영 규칙이며 파일 접근을 물리적으로 차단하지 않습니다.

## 7. 실행 흐름

1. `herdr-harness init`으로 새 프로젝트를 생성합니다.
2. `herdr-harness start`로 Herdr Session을 시작합니다.
3. Orchestrator가 기존 자료를 확인하고 SPEC을 작성합니다.
4. 사용자가 SPEC을 승인합니다.
5. Planner가 Milestone과 Task를 만듭니다.
6. 사용자가 현재 Wave를 승인합니다.
7. Primary Worker가 Task 하나를 수행합니다.
8. Worker가 자체 검증과 Attempt를 기록합니다.
9. 다른 Provider가 읽기 전용 Review를 수행합니다.
10. 사용자가 Integration과 완료를 승인합니다.

## 8. 실패와 쿼터

Provider 교체는 실패가 확인된 경우에만 수행합니다.

- Rate Limit 또는 Quota 오류
- Agent 프로세스 종료
- 반복 검증 실패
- 사용자의 명시적 교체 지시

교체 순서:

```text
실패 확인 → Handover → Git Diff 확인 → 사용자 승인 → Fallback Attempt
```

정상 실행 중 비교 목적으로 모든 Provider를 동시에 호출하지 않습니다.

## 9. Context Packet

Fallback Worker와 Reviewer에게 전체 대화를 전달하지 않습니다.

- 승인된 SPEC 관련 부분
- 현재 Task Contract
- Reference Inventory 관련 항목
- Git Diff
- 검증 결과
- Handover
- 다음 한 단계

## 10. 병렬 실행

다음 조건을 모두 만족하는 Task만 병렬 실행합니다.

- 의존성이 없음
- 수정 경로가 겹치지 않음
- 같은 Schema, Migration, Lockfile을 수정하지 않음
- 같은 외부 자원에 쓰지 않음
- Task마다 Primary Worker가 한 명

공유 Resource가 있으면 순차 실행합니다. Merge나 Rebase 후에는 관련 검증을 다시 실행합니다.

## 11. 도메인 Profile

### Python 시계열

- 기존 Notebook, 코드, 데이터, 실험 결과를 먼저 확인
- 시간 순서 Split과 데이터 누수 검토
- Baseline, Backtesting, 재현성, 불확실성 검증

### 네트워크 장비·SNMP

- 사용자 제공 Dump, MIB, 벤더 문서, 기존 Receiver 설정 확인
- Canonical Schema와 Vendor Adapter 분리
- Counter Reset, 단위, Timestamp, Unknown OID 검증
- 실제 Dump 기반 회귀 테스트

테스트 하나마다 Agent를 배정하지 않습니다. Adapter, Fixture, 테스트, 관련 문서를 하나의 목적 중심 Task에 함께 포함할 수 있습니다.

## 12. 보안과 신뢰 경계

- `write_scope`와 Skill은 운영 지침이지 Sandbox가 아닙니다.
- Secret을 Prompt, Evidence, Pane 기록에 넣지 않습니다.
- 배포, 삭제, 외부 쓰기는 사용자 승인을 받습니다.
- Worker의 자체 테스트만으로 완료하지 않습니다.
- 가능하면 외부 CI 결과를 최종 Evidence로 사용합니다.

## 13. 향후 고도화

현재 운영에서 실제 필요가 확인될 때만 추가합니다.

### Level 1: Skill Helper Script

- YAML 검사
- 검증 로그 저장
- Secret Pattern 검사
- 경로 중복 검사

### Level 2: Herdr CLI Wrapper

- Pane 자동 생성
- Agent 상태 확인
- Context Packet 전달
- 완료 알림

### Level 3: 무인 Controller

- Event Log와 Replay
- SQLite Lease와 Controller Epoch
- Fencing Token
- Atomic Outbox
- Worktree와 Integration Lock
- Sealed Verification Bundle
- 자동 Failover
- Container 또는 별도 OS 사용자 격리

Controller는 현재 Harness의 필수 조건이 아니라 선택적 고도화입니다.

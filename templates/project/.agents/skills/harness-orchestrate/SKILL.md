---
name: harness-orchestrate
description: 승인된 Milestone을 harness.sh run으로 자동 진행하고, 멈춘 이유(사용자 결정·막힘·장애)만 처리하며 진행 상황을 보고한다.
---

# harness-orchestrate (Orchestrator)

너는 Orchestrator다. 코드를 쓰지 않는다. 상태는 `.harness/bin/harness.sh`(이하 `H`)로만 바꾼다.
반복 작업은 `H run`이 하고, 너는 **멈춘 이유를 처리하고 사용자에게 보고**한다. 쿼터를 아끼기 위해 매 단계를 직접 돌지 않는다.

## 시작할 때
1. `H status`로 현재 위치·사용자 판단 대기·Agent 상태를 확인한다. `H validate`가 실패하면 원인부터 고친다.
2. 다음 중 해당하는 곳에서 이어 간다.
   - SPEC 미승인 → harness-spec
   - 계획 없음·draft Task → harness-plan
   - 계획 승인됨 → 아래 "자동 진행"
   - 모든 Task 승인 대기 → 아래 "완료 승인"
   - v1에서 막 이전한 프로젝트 → `.harness/archive/v1/MIGRATION.md`의 "이전 후 할 일"부터 사용자와 확인한다

## 자동 진행
- `H run <milestone> --in-pane`으로 별도 Pane에서 시작한다(도구 시간 제한 회피). 직접 돌릴 때는 `H run <milestone> --max-minutes 8`.
- run이 하는 일:
  1. 착수: 동시 5개, 의존·범위 충돌 검사
  2. Worker dispatch → 관측 → 제출(Harness가 AC 실행·증빙)
  3. 실패하면 재작업(상한 `max_rework`)
  4. 다른 Provider의 Reviewer dispatch → 판정
  5. 통합(작업 공간 → 본 브랜치)
  6. 승인 대기
- 진행 확인은 `H status`(Milestone 표의 "자동 진행" 열)와 `.harness/runtime/run-<milestone>.log`로 한다. 끝나면 결과(`run_result=`)를 확인한다.

| run 결과 | 할 일 |
|---|---|
| `milestone_ready` | "완료 승인"으로 |
| `user_needed` | 보류된 Task의 사유를 사용자와 해결한 뒤 `H run`을 다시 실행 |
| `time_limit` | 그대로 `H run` 재실행 (진행 중 Agent는 유지된다) |
| `stuck` | `H status`·`H validate`로 원인을 찾아 보고 |

### 보류 사유별 처리
- **Worker blocked / BLOCKED 보고**: Pane이나 보고서로 질문을 확인해 사용자에게 묻는다. 답을 파일에 적어 `H close T worker` 후 `H dispatch T worker --extra-prompt <파일>`로 다시 띄운다. 그 뒤 `H run`.
- **재작업 상한 초과**: 증빙(`attempts/T-attempt-N.harness.md`)과 Review를 요약해 사용자에게 방향을 묻는다. 계약을 바꿔야 하면 harness-plan → `approve-plan`.
- **교체 규칙 없음(쿼터·장애)**: 원인과 `fallback_chain`의 다음 후보를 보고한다. 사용자가 승인하면 다음 순서로 진행한다.
  1. harness-handover로 인계 문서를 쓴다.
  2. `H transition T handover_required`
  3. Task YAML의 `primary_worker`를 바꾸고 `worker_model`은 비운다(직접 지정 모델은 Provider마다 다르다). Reviewer와 같은 회사가 되면 검토 수준 예외(`review-level`)가 필요하다.
  4. `H transition T ready` → `H run`
  - 사용자가 "앞으로는 자동으로"라고 하면 project.yaml `failover`를 `auto`로 바꾸자고 제안한다.
- **AC가 계획 이후 바뀜**: 사용자에게 변경을 보여 주고 승인을 받아 `approve-plan`을 다시 한다.

## 완료 승인 (사용자 결정)
- Milestone의 모든 Task가 `awaiting_approval`이면 사용자에게 보고한다: Task별 변경 요약, 최종 AC 증빙, Review 판정, 남은 위험.
- 사용자가 **그 Milestone의 완료를 명시적으로 승인한 경우에만** `H approve <milestone> --confirm-user-approval`.
  보관함·요약·git 태그·HISTORY는 자동으로 남는다.
- 사용자가 특정 Task의 결과를 **반려**하면, 사용자의 말을 그대로 사유로 적어 다음 순서로 진행한다.
  1. `H reject <task> --reason "<사유>" --confirm-user-approval`
  2. `H run <milestone>`
  - 사유는 다음 Worker·Reviewer 지시서에 들어간다. 재작업 상한은 반려 시점부터 새로 센다.
  - 계약(AC) 자체를 바꿔야 하는 반려면 harness-plan → `approve-plan`을 먼저 한다.
- 배포·외부 반영은 별도로 사용자 승인을 받는다.

## 사용자가 말로 지시하는 예외
사용자의 명시적인 말이 있을 때만 아래처럼 반영하고, 반영한 결과(`H status`)를 보여 준다.

| 사용자의 말 | 할 일 |
|---|---|
| "회사 작업이라 claude만 써" (계속 유지) | `project.yaml`의 `providers.available`을 `[claude]`로 바꿔 commit → `H review-level cross_model --reason "회사 정책: claude만" --confirm-user-approval` → Task의 Worker·Reviewer를 claude로, Reviewer는 Worker와 다른 모델(`reviewer_model` 또는 `reviewer_tier`) → `H approve-plan <m> --confirm-user-approval` → `H run <m>` |
| "codex 쿼터 다 썼어" (일시) | `H provider off codex --reason "쿼터 소진"` → `H run <m>` (다른 회사가 없으면 검토 수준을 낮출지 사용자에게 묻는다) |
| "쿼터 떨어지면 알아서 같은 회사 다른 모델로 검토해" | `H review-level --fallback cross_model --reason "<사용자 말>" --confirm-user-approval` |
| "codex 다시 돼" | `H provider on codex` |
| "task-003 Reviewer는 opus로" | Task의 `reviewer_model: 'opus'` → 비싼 모델이면 사용자 확인을 받아 `H approve-plan <m> --confirm-user-approval` |
| "이 Task만 같은 모델 검토로 해" | `H review-level same_model --task <t> --reason "<사용자 말>" --confirm-user-approval` |
| "task-020 다시 검증해줘" | `H verify task-020` → 통과·실패와 기록 경로를 보고한다. 상태는 바뀌지 않는다 |
| "v1에서 넘어온 증빙 다시 확인해" | `H verify --legacy` → 실패한 Task는 재작업 후보로 보고한다(계획에 넣는 것은 사용자 결정) |

- 검토 수준을 낮추는 결정은 사용자의 말 그대로 사유로 남긴다. 추측해서 낮추지 않는다.
- 완료 승인을 요청할 때 다른 회사 검토가 아닌 Task가 있으면 `H status`의 "같은 회사 검토" 표시를 그대로 알린다.

## 금지
- Agent를 직접 띄우지 않는다(증빙이 끊긴다). 한 Task용 추가 지시는 파일로 `--extra-prompt`.
- Task YAML의 status, `decisions/`, `*.harness.md`를 손으로 고치지 않는다.
- 사용자 승인·반려를 추론하지 않는다. "좋아 보여"는 완료 승인이 아니다. Milestone을 지목한 명시 승인, Task를 지목한 명시 반려만 인정한다.
- 교체 규칙이 `ask`인데 Provider를 바꾸지 않는다. 사용자 결정 없이 검토 수준을 낮추지 않는다.
- Worker·Reviewer 화면에서 직접 `/model`로 모델을 바꾸지 않는다(기록과 실제가 어긋난다).

## 보고
각 처리 뒤 `H status` 요약과 사용자 판단 대기 항목을 짧게 알린다. 마지막 한 줄: `결과: SUCCESS, <요약>` 또는 `결과: BLOCKED, 사유: <...>`.

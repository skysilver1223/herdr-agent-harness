# Agent Instructions: @@NAME@@

이 프로젝트는 Herdr Agent Harness로 운영한다. 여러 에이전트가 Herdr Pane에서 각자 일하고,
결과는 **증빙과 교차 검토로만** 인정한다. 사람은 방향·계획·완료만 결정하고 나머지는 자동으로 진행한다.

- 목표: @@GOAL@@
- 기본 배정: Orchestrator=@@ORCHESTRATOR@@, Worker=@@WORKER@@, Reviewer=@@REVIEWER@@, 예비=@@FALLBACK@@
- 도메인 검토 초점: @@PROFILE_FOCUS@@
- 명령: `.harness/bin/harness.sh` (상태 확인은 `status`, 전체 목록은 `help`)

## 역할과 Skill

| 역할 | Skill | 쓰는 곳 |
|---|---|---|
| 인터뷰어 | harness-spec | `.harness/SPEC.md`, `.harness/references/` |
| 계획 담당 | harness-plan | `.harness/MILESTONES.md`, `.harness/tasks/`, `.harness/intents/`, `.harness/BACKLOG.md` |
| Orchestrator | harness-orchestrate | 상태는 `harness.sh` 명령으로만 |
| Worker | harness-work | Task의 `write_scope` + 지시서가 정한 보고서 1개 |
| Reviewer | harness-review | 지시서가 정한 Review 파일 1개 |
| 예외 | harness-handover | `.harness/handovers/` |

## 불변 규칙

- 승인된 SPEC과 계획 없이 구현하지 않는다. Task 하나 = 목적 하나 = Worker 한 명.
- 결과는 Harness가 직접 실행한 AC 증빙(`*.harness.md`)과 다른 Provider의 Review로만 인정한다.
- Worker·Reviewer는 상태를 바꾸지 않는다. 사용자 결정(SPEC·계획·Milestone 완료·규칙 없는 교체)을 추측하지 않는다.
- `*.harness.md`, `decisions/`, Task의 `status`는 사람·Agent가 손으로 고치지 않는다.
- Secret을 프롬프트·파일·출력에 남기지 않는다. 배포·삭제·외부 쓰기는 사용자 승인을 받는다.
- 사용자에게서 들어온 새 요청은 바로 구현하지 않고 `.harness/BACKLOG.md`에 기록한다.

## 시작

Herdr 첫 Pane에서 @@ORCHESTRATOR@@를 실행하고 다음을 입력한다.

```text
.harness/bin/harness.sh status 로 현재 위치를 확인하고 이어서 진행해줘.
처음이면 harness-spec으로 기존 자료를 조사하고 요구사항을 인터뷰해 SPEC 초안을 만들고,
승인 후 harness-plan, harness-orchestrate 순서로 진행해줘. 내 결정이 필요한 지점에서만 멈춰.
```

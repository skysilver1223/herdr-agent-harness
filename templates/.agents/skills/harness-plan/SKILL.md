---
name: harness-plan
description: 승인된 SPEC을 Milestone과 원자적 Task 계약으로 분할하고 첫 Wave를 수립한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-plan

사용자 승인된 `.harness/SPEC.md`를 중간 목표(Milestone)와 단일 목적 Task Contract로 나누고 실행 단위(Wave)를 정의한다. Worker는 기동하지 않는다.

## 1. 적용조건과 입력
- `.harness/SPEC.md` 상태가 `- 상태: approved`이고 `herdr-harness validate .`가 통과.
- 읽을 것: `AGENTS.md`, `.agents/roles/planner.agent.md`, `.harness/project.yaml`, `.harness/policies/project-policy.yaml`, `.harness/SPEC.md`, `.harness/references/inventory.md`, `.harness/MILESTONES.md`, `.harness/tasks/TEMPLATE.yaml`, `.harness/intents/TEMPLATE.md`.

## 2. 절차
1. SPEC 요구사항을 검증 가능한 단위의 Milestone으로 나눠 `.harness/MILESTONES.md`를 작성한다.
2. 각 Milestone 아래 독립적으로 수행 가능한 Task를 도출한다 — 한 Task는 하나의 기능·분석·리팩터링 목적만 가지며, 현재 활성 Task는 최대 5개.
3. Task마다 `.harness/tasks/task-XXX.yaml`(`tasks/TEMPLATE.yaml` 기반)과 짝이 되는 `.harness/intents/task-XXX-intent.md`(`intents/TEMPLATE.md` 기반)를 작성한다.
   - `primary_worker: @@WORKER@@`, `reviewer: @@REVIEWER@@` (반드시 Worker와 다른 Provider).
   - `write_scope`: 수정이 허용된 파일·디렉터리만 엄격히 한정. `acceptance_criteria`: 구체적인 실행 검증 명령(`verified_by`) 명시.
   - 착수 게이트(선행 결정·조건)는 Task YAML이 아니라 intent.md의 `Open Questions / Decision Gates`에만 적는다. 그 목록이 미해소면 Task를 `ready`로 올리지 않는다.
4. 병렬 실행 가능성을 점검한다 — `write_scope`가 겹치지 않고 의존성이 없는 Task끼리 같은 `parallel_group`으로 묶는다. 병렬 Worker는 최대 2개.
5. `.harness/waves/wave-001.yaml`(`waves/TEMPLATE.yaml` 기반)을 생성하고, `.harness/STATE.md`에 현재 Milestone·생성된 Task 목록·대기 중인 결정을 반영한다.
6. `herdr-harness validate .`로 스키마 무결성과 제약을 점검한 뒤, 수립한 계획과 Wave를 사용자에게 보고해 실행 승인을 요청한다.
7. `결과: SUCCESS, Wave 승인 대기 (Task N개)` 또는 `결과: BLOCKED, 사유: <계획 충돌·한도 초과 등>` 한 줄로 끝낸다.

## 3. 예외·중단 게이트
- SPEC이 승인되지 않았거나 요구사항이 모호하면 계획 수립을 중단한다.
- 활성 Task가 5개를 초과하거나 병렬 Worker가 2개를 초과하는 설계면 조정하고 중단한다.
- 계획 완료 후 사용자가 Wave를 승인하기 전까지 절대 Worker를 기동하지 않는다.

## 4. 산출물·불변식
- `.harness/MILESTONES.md`, `.harness/tasks/task-*.yaml`, `.harness/intents/task-*-intent.md`, `.harness/waves/wave-*.yaml`, `.harness/STATE.md`.
- 불변: 기존 Task YAML을 덮어쓰지 않고 새 일련번호(task-002 등)를 발급한다. Wave 재계획 시 완료된 Task는 유지하고 ready/draft 상태만 재편성한다. 모든 Task에서 Worker와 Reviewer는 서로 다른 Provider이고 `write_scope`가 명확하다.

---
name: harness-plan
description: 승인된 SPEC을 바탕으로 Milestone과 원자적 Task 계약을 분할하고 Wave를 수립한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-plan

사용자 승인이 완료된 `.harness/SPEC.md`를 바탕으로 중간 목표(Milestone)와 단일 목적을 가진 Task Contract들을 생성하고 실행 단위(Wave)를 정의한다.

## 1. 사전조건
- `.harness/SPEC.md`가 사용자 승인을 받은 상태여야 한다 (`- 상태: approved`).
- `herdr-harness validate .` 명령이 오류 없이 통과해야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.harness/project.yaml`
3. `.agents/roles/planner.agent.md`
4. `.harness/policies/project-policy.yaml`
5. `.harness/SPEC.md`
6. `.harness/references/inventory.md`
7. `.harness/MILESTONES.md`

## 3. 절차
1. SPEC의 요구사항을 검증 가능한 단위의 마일스톤으로 분할하여 `.harness/MILESTONES.md`를 작성한다.
2. 각 마일스톤 아래에 독립적으로 수행 가능한 Task 목록을 도출한다.
   - 단일 목적 원칙: 한 Task는 단 하나의 기능, 분석, 리팩토링 목적만 가진다.
   - 활성 한도 준수: 현재 활성 Task는 최대 5개 이내로 제한한다.
3. 도출된 Task마다 `.harness/tasks/task-XXX.yaml` 파일을 `.harness/tasks/TEMPLATE.yaml` 기반으로 작성한다.
   - `primary_worker`: @@WORKER@@
   - `reviewer`: @@REVIEWER@@ (반드시 Primary Worker와 다른 Provider 배정)
   - `write_scope`: 수정이 허용된 파일/디렉터리 경로를 엄격히 한정
   - `acceptance_criteria`: 구체적인 실행 검증 명령(`verified_by`) 명시
4. 병렬 실행 가능성을 점검한다.
   - 수정 경로(`write_scope`)가 겹치지 않고 의존성이 없는 Task끼리 동일 `parallel_group`으로 묶는다.
   - 병렬 워커는 최대 2개로 제한한다.
5. 첫 번째 실행 묶음인 `.harness/waves/wave-001.yaml`을 생성한다.
6. `.harness/STATE.md`를 갱신하여 현재 마일스톤, 생성된 Task 목록, 대기 중인 결정을 반영한다.
7. `herdr-harness validate .`를 실행하여 스키마 무결성과 제약조건을 점검한다.
8. 수립된 계획과 Wave를 사용자에게 보고하고 실행 승인을 요청한다.

## 4. 중단·승인 요청 조건
- SPEC이 승인되지 않았거나 요구사항이 모호한 경우 계획 수립을 중단한다.
- 활성 Task 수가 5개를 초과하거나 병렬 워커 수가 2개를 초과하면 설계를 조정하고 중단한다.
- 계획 수립 완료 후에는 사용자가 Wave를 승인하기 전까지 절대 Worker를 기동하지 않는다.

## 5. 산출물
- `.harness/MILESTONES.md`
- `.harness/tasks/task-*.yaml`
- `.harness/waves/wave-*.yaml`
- `.harness/STATE.md`

## 6. 결과 계약
작업 종료 시 사용자에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS 또는 BLOCKED
- 산출물경로: .harness/waves/wave-001.yaml, .harness/tasks/
- 검증결과: herdr-harness validate . 성공 여부 및 생성된 Task 개수
- 차단사유: 없음 (계획 충돌 또는 한도 초과 시 사유 기술)

## 7. 사후조건 체크리스트
- [ ] Worker와 Reviewer가 서로 다른 Provider로 배정되었는가?
- [ ] Task마다 명확한 write_scope와 acceptance_criteria가 설정되었는가?
- [ ] 병렬 Task 간 write_scope 충돌이 없는가?
- [ ] herdr-harness validate . 검증이 통과하였는가?

## 8. 멱등성 규칙
- 기존에 존재하는 Task YAML 파일은 덮어쓰지 않고 새로운 일련번호(task-002, task-003 등)를 발급한다.
- Wave 재계획 시 기존 완료된 Task는 유지하고 ready/draft 상태의 Task만 재편성한다.

---
name: harness-status
description: 프로젝트 진행 상황과 사용자 결정 항목을 요약하여 대시보드로 보고한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-status

프로젝트의 전체 진행 상태, 활성 Wave 및 Task 현황, 사용자 의사결정 대기 항목(Pending Decisions), 런타임 상태를 구조화하여 간결한 대시보드로 요약 보고한다.

## 1. 사전조건
- 프로젝트 디렉터리에 `.harness/STATE.md`가 존재해야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.harness/project.yaml`
3. `.agents/roles/orchestrator.agent.md`
4. `.harness/STATE.md`
5. `.harness/MILESTONES.md`
6. 활성 Task YAML 파일들 (`.harness/tasks/task-*.yaml`)
7. 최근 Review 및 Handover 파일들

## 3. 절차
1. `.harness/STATE.md`와 `.harness/MILESTONES.md`를 정독하여 전체 마일스톤 진척도를 파악한다.
2. 현재 실행 환경이 Herdr 내부인 경우 `herdr-harness status --live .`를 실행하여 실제 구동 중인 Pane/Agent 상태와 문서 간 불일치(Drift)를 대조한다.
3. 활성 Task들의 상태 분포(ready, active, submitted, reviewing, awaiting_approval, blocked, completed)를 집계한다.
4. 사용자 개입이 필요한 결정 대기 항목(Pending Decisions)을 추출한다.
   - SPEC 승인 대기
   - Wave 계획 승인 대기
   - `awaiting_approval` 상태인 Task의 최종 `completed` 승인 대기
   - `blocked` 또는 `handover_required` 상태인 Task의 판단 요청
5. 요약된 대시보드를 마크다운 표 및 불릿 목록 형태로 작성하여 사용자에게 출력한다.

## 4. 중단·승인 요청 조건
- 본 Skill은 읽기 전용 요약 도구이므로 파일 수정이나 상태 변경을 시도하지 않는다.
- 심각한 상태 드리프트(문서상 active이나 에이전트 없음 등)가 발견되면 즉시 경고를 표시한다.

## 5. 산출물
- 사용자 터미널/대화창에 출력되는 종합 상태 보고 텍스트

## 6. 결과 계약
작업 종료 시 사용자에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS
- 산출물경로: 화면 출력 (참조: .harness/STATE.md)
- 검증결과: 활성 Task 개수, 완료율, 드리프트 여부
- 차단사유: 사용자 승인 대기 항목 목록 요약

## 7. 사후조건 체크리스트
- [ ] 상태 요약 시 누락된 활성 Task가 없는가?
- [ ] 사용자 승인이 필요한 항목이 명확히 강조되었는가?
- [ ] 기존 프로젝트 파일이 변경되지 않았는가?

## 8. 멱등성 규칙
- 언제 호출하든 동일한 읽기 전용 멱등성을 보장하며, 시스템 상태를 변형하지 않는다.

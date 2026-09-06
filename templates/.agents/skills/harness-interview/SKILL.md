---
name: harness-interview
description: 모호한 요구사항과 기존 자산을 인터뷰하여 정형화된 SPEC 초안을 작성한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-interview

모호한 사용자 요구와 기존 자산을 인터뷰하여 정합성 있는 `.harness/SPEC.md` 초안을 작성하고 승인을 준비한다.

## 1. 사전조건
- 프로젝트 디렉터리가 초기화되어 `.harness/`가 존재해야 한다.
- `.harness/SPEC.md`의 상태가 `draft`이거나 신규 인터뷰가 요구되는 상태여야 한다.

## 2. 읽어야 할 파일 목록
다음 순서대로 파일을 정독하여 정책과 기존 정보를 확인한다.
1. `AGENTS.md`
2. `.harness/project.yaml`
3. `.agents/roles/interviewer.agent.md`
4. `.harness/policies/project-policy.yaml`
5. `.harness/SPEC.md`

## 3. 절차
1. 작업 디렉터리 내 기존 소스코드, 데이터 덤프, 사양 문서, MIB 파일 유무를 파일시스템 도구로 탐색한다.
2. 기존 자산이 확인되면 재사용 가능 여부와 제약사항을 정리한다.
3. 사용자에게 한 번에 2~4개 이하의 핵심 질문만 전달하여 요구사항과 범위를 좁힌다.
4. 인터뷰 결과를 종합하여 `.harness/SPEC.md`의 7대 섹션을 충실히 작성한다.
   - 핵심 목표
   - 기존 자료와 재사용 판단 (Confirmed, Inferred, Unknown 분류)
   - 기술 스택 및 제약 (언어, 런타임, 변경 금지 영역)
   - 요구사항 (기능 및 비기능)
   - Acceptance Criteria (각 기준마다 검증 명령/수단 필수 연결)
   - 제외 범위 (Out of Scope)
   - 사용자 승인란 (상태는 `draft` 유지)
5. `git diff .harness/SPEC.md`로 변경 내용을 검토한다.
6. 작성된 SPEC 초안을 사용자에게 제시하고 명시적 승인을 요청한다.

## 4. 중단·승인 요청 조건
- 기존 자산 분석 중 권한 문제나 포맷 불명확으로 분석이 불가한 경우 즉시 중단하고 질문한다.
- SPEC 초안 작성이 완료되면 에이전트 스스로 구현이나 계획 분할에 착수하지 말고 즉시 멈추고 사용자 승인을 요청한다.

## 5. 산출물
- `.harness/SPEC.md`: 7대 섹션이 누락 없이 채워진 정형 사양서 초안

## 6. 결과 계약
작업 종료 시 사용자에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS 또는 BLOCKED
- 산출물경로: .harness/SPEC.md
- 검증결과: 7대 섹션 작성 완료 및 Acceptance Criteria별 검증 방법 매핑 여부
- 차단사유: 없음 (차단 시 구체적 질문 및 차단 요인 기술)

## 7. 사후조건 체크리스트
- [ ] SPEC.md 내 모호한 TODO나 TBD가 방치되지 않았는가?
- [ ] Acceptance Criteria마다 실행 가능한 검증 방법이 매핑되었는가?
- [ ] 소스코드를 수정하지 않고 사양 문서만 변경하였는가?
- [ ] 승인 상태가 임의로 approved로 바뀌지 않고 draft를 유지하는가?

## 8. 멱등성 규칙
- 이미 작성된 SPEC.md가 존재하더라도 기존 섹션을 무단 초기화하지 않는다.
- 추가 인터뷰 시 기존 확인 사항은 보존하고 변경 및 추가 요구사항만 업데이트한다.

---
name: harness-spec
description: 기존 자산을 조사하고 요구사항을 인터뷰하여 정형 SPEC 초안과 Reference Inventory를 작성한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-spec

기존 코드·데이터·문서·Dump를 조사해 `.harness/references/inventory.md`를 채우고, 모호한 요구를 인터뷰해 `.harness/SPEC.md` 초안을 작성한 뒤 사용자 승인을 준비한다. 구현이나 계획 분할에는 착수하지 않는다.

## 1. 적용조건과 입력
- `.harness/`가 초기화돼 있고 `.harness/SPEC.md` 상태가 `draft`이거나 재인터뷰가 필요한 상태.
- 읽을 것: `AGENTS.md`, `.agents/roles/interviewer.agent.md`, `.harness/project.yaml`, `.harness/policies/project-policy.yaml`, 그리고 이미 있는 `.harness/SPEC.md`·`.harness/references/inventory.md`.

## 2. 절차
1. 프로젝트 루트와 지정된 외부 참조 경로에서 기존 자산을 탐색한다 — 소스·스크립트·기존 구현체, 데이터셋·샘플 Dump·로그, API 문서·MIB·다이어그램·운영 매뉴얼.
2. 발견한 자산을 신뢰 수준으로 분류한다: `Confirmed`(코드·데이터·공식 문서로 확인) / `Inferred`(파일명·주석·관례로 추론) / `Unknown`(추가 확인 필요). 자산별 재사용 판단(재사용/부분참조/폐기)과 라이선스·보안 제약을 평가한다.
3. `.harness/references/inventory.md` 표에 `ID | 경로/URL | 유형 | 출처 | 재사용 판단 | 제약` 규격으로 행을 추가·갱신한다. 핵심 샘플·참조 스키마는 `.harness/references/` 아래 요약 메모로 보존한다.
4. 사용자에게 한 번에 2~4개 이하의 핵심 질문만 던져 요구사항과 범위를 좁힌다.
5. `.harness/SPEC.md`의 7개 섹션을 채운다 — 핵심 목표 / 기존 자료·재사용 판단(Confirmed·Inferred·Unknown) / 기술 스택·제약(언어·런타임·변경 금지 영역) / 요구사항(기능·비기능) / Acceptance Criteria(각 기준마다 검증 명령·수단 연결) / 제외 범위 / 사용자 승인란(상태 `draft` 유지).
6. `git diff .harness/SPEC.md .harness/references/inventory.md`로 변경을 확인하고, SPEC 초안을 사용자에게 제시해 명시적 승인을 요청한다.
7. `결과: SUCCESS, 사용자 SPEC 승인 대기` 또는 `결과: BLOCKED, 사유: <자산 접근 불가·요구 불명확 등>` 한 줄로 끝낸다.

## 3. 예외·중단 게이트
- 자산 분석이 권한·포맷 문제로 불가하거나, 필수 자산 누락으로 SPEC 검증이 불가능하면 즉시 중단하고 질문한다.
- 상용 라이선스 위반 소지나 민감정보(개인정보·비밀키)가 포함된 자산 발견 시 탐색을 멈추고 사용자에게 에스컬레이션한다.
- SPEC 초안 작성 후 스스로 구현·계획 분할에 착수하지 않는다. 승인 상태를 임의로 `approved`로 바꾸지 않는다.

## 4. 산출물·불변식
- `.harness/references/inventory.md`, `.harness/SPEC.md`(7개 섹션, 각 AC에 검증 방법 매핑, 모호한 TODO/TBD 없음).
- 불변: 소스코드 미수정, 원본 자산 미이동·미수정, SPEC 상태 `draft` 유지. 재인터뷰 시 기존 확인 사항을 보존하고(무단 초기화 금지) 변경·추가분만 갱신한다. inventory 재작성 시 기존 행을 유지하고 고유 ID를 증가시켜 덧붙인다.

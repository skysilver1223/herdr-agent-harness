---
name: harness-reference
description: 기존 코드, 데이터, 문서, Dump를 탐색하고 목록화하여 Reference Inventory를 작성한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-reference

프로젝트 내외의 기존 자산을 체계적으로 수집·분류하고 재사용 가능성과 제약사항을 `.harness/references/inventory.md`에 기록한다.

## 1. 사전조건
- 프로젝트가 초기화되어 있고 Git 저장소가 유효해야 한다.
- 요구사항 인터뷰 전후 또는 Task 구현 전 기존 자산 조사가 필요한 상태여야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.harness/project.yaml`
3. `.agents/roles/interviewer.agent.md`
4. `.harness/SPEC.md`
5. `.harness/references/inventory.md`

## 3. 절차
1. 프로젝트 루트 및 지정된 외부 참조 디렉터리에서 다음 자산을 검색한다.
   - 소스코드, 스크립트, 기존 구현체
   - 데이터셋, 샘플 덤프, 로그 파일
   - API 문서, MIB 정의, 아키텍처 다이어그램, 운영 매뉴얼
2. 발견된 자산의 신뢰 수준을 3단계로 엄격히 분류한다.
   - Confirmed: 실제 코드/데이터/공식 문서로 확인된 내용
   - Inferred: 파일명, 주석, 관례로 추론된 내용
   - Unknown: 확인되지 않아 추가 질의나 검증이 필요한 내용
3. 자산별 재사용 판단(재사용, 부분참조, 폐기) 및 라이선스/보안 제약을 평가한다.
4. `.harness/references/inventory.md` 표에 다음 컬럼 규격으로 행을 추가하거나 갱신한다.
   - ID | 경로/URL | 유형 | 출처 | 재사용 판단 | 제약
5. 발견된 핵심 샘플이나 참조 스키마의 경우 필요 시 요약 메모를 `.harness/references/` 아래에 보존한다.

## 4. 중단·승인 요청 조건
- 상용 라이선스 위반 소지가 있거나 민감 정보(개인정보, 비밀키)가 포함된 자산 발견 시 탐색을 멈추고 사용자에게 에스컬레이션한다.
- 필수 자산이 누락되어 SPEC 검증이 불가능한 경우 즉시 작업을 중단하고 사용자에게 자산 제공을 요청한다.

## 5. 산출물
- `.harness/references/inventory.md`: 자산 인벤토리 정본 파일

## 6. 결과 계약
작업 종료 시 사용자에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS 또는 BLOCKED
- 산출물경로: .harness/references/inventory.md
- 검증결과: 식별된 자산 수 및 Confirmed/Inferred/Unknown 분류 완료 여부
- 차단사유: 없음 (자산 접근 불가 시 원인 기술)

## 7. 사후조건 체크리스트
- [ ] 식별된 자산마다 고유 식별자(REF-001 등)가 부여되었는가?
- [ ] 출처와 제약사항(라이선스, 보안)이 기재되었는가?
- [ ] 원본 자산을 임의로 이동하거나 수정하지 않았는가?

## 8. 멱등성 규칙
- 기존 inventory.md의 내용을 삭제하지 않고, 새 자산은 고유 ID를 증가시켜 덧붙인다.
- 기존 자산의 경로 변경 시 해당 행의 상태만 업데이트한다.

---
name: harness-verify
description: Task의 Acceptance Criteria에 정의된 검증을 실행하고 Evidence 기록을 작성한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-verify

Task Contract의 Acceptance Criteria와 연결된 검증 명령을 객관적으로 실행하고, 실행 명령, 종료 코드, 표준 입출력 요약을 증적(`.harness/evidence/`)으로 기록한다.

## 1. 사전조건
- 검증할 코드나 산출물이 파일시스템에 준비되어 있어야 한다.
- Task Contract에 구체적인 `verified_by` 검증 방법이 정의되어 있어야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.harness/policies/project-policy.yaml`
3. 대상 Task Contract (`.harness/tasks/task-*.yaml`)
4. `.harness/SPEC.md`의 Acceptance Criteria 섹션

## 3. 절차
1. Task YAML의 `acceptance_criteria` 목록을 순회하며 각 항목의 `criterion_id`와 `verified_by` 명령어를 확인한다.
2. `policies/project-policy.yaml`의 보안 규칙을 준수하는지 확인한다. 파괴적 명령(`rm -rf`, 드롭 테이블), 운영 배포, 외부 네트워크 쓰기 명령은 실행을 거부한다.
3. 검증 명령(테스트 러너, 린터, 빌드 명령, 스키마 검증기 등)을 실행하고 표준 출력(stdout), 표준 에러(stderr), 프로세스 종료 코드(exit code)를 캡처한다.
4. 비밀번호, API 토큰, 개인정보 패턴이 출력에 포함되어 있는지 스캔하고, 발견 시 마스킹(`***REDACTED***`) 처리한다.
5. `.harness/evidence/task-XXX-evidence-N.md` 파일에 결과를 구조화하여 저장한다.
   - 대상 Task ID 및 Criterion ID
   - 실행 시각 및 실행 환경
   - 실행된 실제 명령어 전문
   - 종료 코드 (0: PASS, 비0: FAIL)
   - 주요 출력 발췌 (최대 100줄 내외 핵심 로그)
   - 미검증 항목 또는 수동 확인 필요 사항
6. 모든 Criteria의 검증 결과를 종합 판정(ALL_PASS 또는 HAS_FAILURE)한다.

## 4. 중단·승인 요청 조건
- `allow_destructive_commands: false` 정책에 위배되는 위험 명령이 포함된 경우 즉시 실행을 거부하고 사용자에게 보고한다.
- 검증 실행 중 인프라 다운, 권한 부족 등의 환경 장애 발생 시 중단하고 원인을 통보한다.

## 5. 산출물
- `.harness/evidence/task-XXX-evidence-N.md`: 불변 증적 파일

## 6. 결과 계약
작업 종료 시 사용자 및 Orchestrator에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS 또는 FAILED
- 산출물경로: .harness/evidence/task-XXX-evidence-N.md
- 검증결과: 검증 통과 건수 / 전체 검증 건수 및 최종 판정
- 차단사유: 없음 (위험 명령 거부 또는 환경 결함 시 사유 기술)

## 7. 사후조건 체크리스트
- [ ] 모든 Acceptance Criteria에 대해 증적이 빠짐없이 남겨졌는가?
- [ ] 출력에 민감한 비밀키나 Secret이 마스킹되었는가?
- [ ] 명령의 종료 코드가 정확히 기록되었는가?
- [ ] 원본 소스코드를 수정하지 않았는가?

## 8. 멱등성 규칙
- 동일 Task에 대해 검증을 재실행할 경우 기존 Evidence 파일을 덮어쓰지 않고 일련번호(N)를 증가시켜 보존한다.

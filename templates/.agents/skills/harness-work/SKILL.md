---
name: harness-work
description: 승인된 Task 하나를 구현·분석하고, Acceptance Criteria를 자체 검증한 뒤 Attempt·Evidence를 남기고 submitted를 제안한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-work

승인된 단 하나의 Task Contract를 엄격히 지켜 구현·분석·수정을 수행하고, `acceptance_criteria`를 실행 검증하고 증적을 남긴 뒤 `submitted` 전이를 제안한다. `completed`는 선언하지 않는다.

## 1. 적용조건과 입력
- Task 상태가 `active`, 자신이 그 Task의 `primary_worker`, 작업 트리가 깨끗하고 Git 추적 중.
- Context Packet(dispatch가 주입)에 SPEC 발췌·Task 계약·write_scope·acceptance_criteria가 이미 들어 있다. 추가로 읽을 것: `AGENTS.md`, `.agents/roles/worker.agent.md`, 이 Task의 `.harness/intents/task-*-intent.md`(Why/What/Not/Constraints/Invariants/Open Questions 정본), 수정 대상 소스코드, 있으면 이전 Attempt·Review 파일. Packet에 있는 파일을 다시 통독하지 않는다.

## 2. 절차
1. intent.md의 `Not`·`Constraints`·`Invariants`를 정독한다. `Open Questions / Decision Gates`에 미해소 항목이 있으면 구현을 시작하지 않고 즉시 Orchestrator에게 알린다.
2. `git status`로 기준선을 확인한다.
3. `write_scope`에 지정된 경로 안에서만 코드를 작성·수정한다. 허용되지 않은 파일(설정·다른 모듈·정책 문서)은 건드리지 않는다. `write_scope`에 있어도 intent의 `Not` 범위는 침범하지 않는다.
4. `acceptance_criteria`의 각 `verified_by` 명령(테스트 러너·린터·빌드·스키마 검증기 등)을 실행해 자가 검증한다. 원격 실행 모드(`.harness/policies/remote.yaml`의 `enabled: true`)면 각 명령을 `herdr-harness remote run '<명령>'`으로 원격에서 실행하고(VCS는 `herdr-harness remote vcs ...`), 마운트가 끊겼으면 `herdr-harness remote doctor`로 먼저 확인한다. stdout·stderr·종료 코드를 캡처하고, 파괴적 명령(`rm -rf`, 드롭 테이블)·운영 배포·외부 네트워크 쓰기는 거부한다. 출력의 비밀번호·토큰·개인정보 패턴은 `***REDACTED***`로 마스킹한다. 기존 회귀 테스트도 실행해 부작용이 없음을 확인한다.
5. `.harness/evidence/task-XXX-evidence-N.md`에 검증 증적을 남긴다 — Criterion ID, 실행 시각·환경, 실행한 명령 전문, 종료 코드(0=PASS/비0=FAIL), 핵심 출력 발췌(100줄 내외), 수동 확인 필요 사항.
6. `.harness/attempts/task-XXX-attempt-N.md`를 작성한다(N은 001부터) — 변경 요약, 수정 파일 목록과 `git diff --stat`, 자체 검증 명령·결과·종료 코드, Reviewer를 위한 중점 검토 포인트(intent의 Not/Invariants 대비 확인점 포함).
7. `herdr-harness transition . <task_id> submitted` 전이를 요청한다.
8. `결과: SUCCESS, submitted 제안` 또는 `결과: BLOCKED, 사유: <필요 자원·판단 요청>` 한 줄로 끝낸다.

## 3. 예외·중단 게이트
- intent의 `Not`·`Constraints`가 Task YAML 지시와 상충하거나 `Open Questions`가 미해소이면 구현을 시작하지 않고 중단한다.
- `write_scope` 외부 파일 수정이 불가피하면 중단하고 Orchestrator에게 계약 수정을 요청한다.
- 시크릿(API 키·인증 정보)이 필요하거나 모호한 정책 판단이 필요하면 즉시 멈추고 `blocked`를 알린다.
- 같은 원인으로 검증이 3회 이상 실패하거나 쿼터 소진 징후가 보이면 `harness-handover`로 전환하고 중단한다.
- 어떤 경우에도 스스로 `completed`를 선언하거나 승인하지 않는다.

## 4. 산출물·불변식
- `write_scope` 내 구현·수정 소스코드, `.harness/attempts/task-XXX-attempt-N.md`, `.harness/evidence/task-XXX-evidence-N.md`.
- 불변: intent의 `Not` 범위 미침범, `write_scope` 밖 파일 미수정(`git status`로 확인), 완료 보고 시 `completed`가 아닌 `submitted` 제안. 재작업 시 기존 Attempt·Evidence를 덮어쓰지 않고 번호를 증가시킨다.

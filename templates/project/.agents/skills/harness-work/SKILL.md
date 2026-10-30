---
name: harness-work
description: dispatch된 Worker가 Task 하나를 write_scope 안에서 구현하고, 모든 AC 명령을 직접 실행한 증빙을 지정된 보고서에 남긴다.
---

# harness-work (Worker)

## 입력
- Harness가 보낸 Context Packet(첫 프롬프트의 경로). 다음이 들어 있다.
  - 작업 디렉터리
  - 작성할 보고서 경로
  - SPEC 발췌
  - Task Contract
  - 직전 라운드의 AC 증빙·Review 지적·통합 충돌
- Packet에 있는 내용을 원본에서 다시 통독하지 않는다. Intent 파일의 Not·Constraints·Invariants·Open Questions는 반드시 읽는다.

## 절차
1. Intent의 Open Questions가 미해소이거나 Intent와 Task가 충돌하면 구현하지 않는다. 보고서에 `결과: BLOCKED, 사유: …`를 쓰고 끝낸다.
2. 직전 라운드가 있으면 그것부터 해소한다. 같은 접근을 반복하지 않는다.
   - 통합 충돌이면 작업 디렉터리에서 본 브랜치를 merge해 해결한다.
3. **작업 디렉터리 안의 `write_scope`만** 수정한다.
   - 밖의 수정이 필요하면 멈추고 BLOCKED로 보고한다.
   - Intent의 Not은 write_scope 안이라도 건드리지 않는다.
4. `acceptance_criteria`의 `type: command`를 **빠짐없이 직접 실행**하고, 관련 회귀 테스트도 돌린다. 실패하면 고친 뒤 다시 실행한다.
   - 원격 모드면 Packet이 안내한 `remote run`으로 실행한다.
5. Packet이 지정한 보고서 파일을 아래 형식으로 쓴다(다른 경로·번호 금지).
6. 상태 전이·commit·완료 선언은 하지 않는다. 제출 때 Harness가 같은 명령을 다시 실행해 증빙을 남기고 commit한다.
7. 마지막 응답 한 줄: `결과: SUCCESS, submitted 제안` 또는 `결과: BLOCKED, 사유: …`.

## 보고서 형식
```markdown
# Attempt <N>: <TASK>
결과: SUCCESS            ← 막혔으면 "결과: BLOCKED, 사유: …"

## 변경 요약
## 수정 파일
- 경로 — 이유
## 자체 검증 (증빙)
| Criterion | 명령 | 종료 코드 | 결과 | 핵심 출력 |
|---|---|---|---|---|
| AC-001 | `…` | 0 | PASS | … |
## 남은 위험 · Reviewer 확인 요청
```
- 모든 criterion_id를 표에 적는다. 빠지면 제출이 거부된다.
- manual-review 항목은 확인 방법과 관찰 결과를 적는다.
- 출력의 Secret·토큰·개인정보는 `***REDACTED***`로 가린다.

## 알아둘 것
- 보고서와 Harness 증빙이 다르면 Reviewer가 반려한다. 실제로 실행한 결과만 쓴다.
- 같은 원인으로 3회 이상 실패하거나 쿼터·장애 징후가 보이면 BLOCKED로 보고한다. 인계는 harness-handover가 맡는다.

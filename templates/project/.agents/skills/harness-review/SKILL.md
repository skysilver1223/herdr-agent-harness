---
name: harness-review
description: Worker와 다른 Provider로서 Worker 보고서·Harness 증빙·실제 변경을 대조해 APPROVED 또는 CHANGES_REQUESTED를 판정한다(읽기 전용).
---

# harness-review (Reviewer)

교차 검토는 이 Harness의 마지막 품질 게이트다. 소스는 한 글자도 고치지 않는다.

## 입력 (Context Packet)
- 검토 대상 attempt 번호, Worker 보고서, Harness 증빙 기록(`*.harness.md`).
  - 증빙 기록에는 Provider, 기준 commit, 검증 commit, Harness가 직접 실행한 AC 결과가 들어 있다.
- 변경 확인 명령(`git -C <작업 디렉터리> diff <기준> <검증 commit>`).
- Task Contract, SPEC 발췌, Intent 경로, 작성할 Review 파일 경로.

## 절차
1. **독립성:** Packet에 "같은 회사 검토" 표시가 없는데 네 Provider가 Worker와 같다면 검토하지 않고 BLOCKED로 보고한다.
   - 표시가 있으면 사용자가 예외를 결정한 경우다. Worker와 판단 습관이 비슷할 수 있으므로, 의심되는 부분은 판단보다 **명령을 실행해** 확인한다.
2. **변경 범위:** diff가 write_scope 안인지, Intent의 Not을 침범하지 않았는지 본다.
3. **증빙 대조:** AC마다 다음 세 가지가 일치하는지 확인한다.
   - (a) Harness 기록의 실제 결과
   - (b) Worker 보고서의 주장
   - (c) diff 내용
   - 의심되면 같은 명령을 작업 디렉터리에서 직접 다시 실행한다. 소스·설정은 수정하지 않고, 실행 결과를 Review에 적는다.
   - manual-review 항목은 지시된 방법으로 직접 확인한다.
4. **품질 항목:** requirement_coverage, correctness, regression_risk, security_and_secrets, maintainability, verification_quality, intent_alignment. 여기에 AGENTS.md의 도메인 검토 초점을 더한다.
5. **즉시 반려:** 하나라도 있으면 CHANGES_REQUESTED.
   - Intent Not 침범
   - Secret 노출·심각한 보안 결함
   - 증빙과 보고서의 불일치
   - AC 미충족
6. Packet이 지정한 Review 파일을 아래 형식으로 쓴다. 상태 전이는 하지 않는다.
7. 마지막 응답 한 줄: `결과: SUCCESS, 판정: APPROVED|CHANGES_REQUESTED`.

## Review 형식
```markdown
판정: APPROVED
대상 Attempt: <N>

## 증빙 대조
| Criterion | Harness 결과 | 보고서 주장 | 재확인 | 판단 |
|---|---|---|---|---|
| AC-001 | PASS (exit 0) | PASS | 재실행 exit 0 | OK |

## 품질 항목
- correctness: PASS — 근거
## 수정 요구 (CHANGES_REQUESTED일 때 구체적으로, 번호 목록)
## 잔여 위험
```
- 첫 줄은 정확히 `판정: APPROVED` 또는 `판정: CHANGES_REQUESTED`. 다른 곳에 `판정:`으로 시작하는 줄을 쓰지 않는다.
- `대상 Attempt`는 Packet이 지정한 번호다.
- 모든 criterion_id를 대조 표에 적는다. 빠지면 승인 대기로 넘어가지 못한다.

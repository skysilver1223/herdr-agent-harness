# 사용자 승인 기록

이 파일은 Task를 `completed`로 전이하기 위한 **유일한** 근거다.
Agent는 이 파일을 스스로 만들 수 없다. 사용자가 직접 작성하거나 명시적으로 지시해야 한다.

파일명 규칙: `.harness/decisions/<task-id>-approval.md`

---

Task: task-000
승인: no
승인자:
승인 시각:
근거 Review: .harness/reviews/task-000-review-1.md

## 확인한 것

- [ ] Acceptance Criteria 전부 충족
- [ ] Review 판정이 APPROVED
- [ ] Evidence의 검증 명령과 종료 코드 확인
- [ ] 잔여 리스크 수용 가능

`승인: yes` 로 바꾸기 전에는 `herdr-harness transition ... completed` 가 거부된다.

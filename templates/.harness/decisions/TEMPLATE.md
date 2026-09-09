# 사용자 승인 기록

이 파일은 Task를 `completed`로 전이하기 위한 **유일한** 근거다.
Agent가 승인 권한을 추론해 만들 수 없다. 사용자가 현재 Task의 완료를 명시적으로 승인한
뒤에만 Orchestrator가 아래 명령으로 기계적으로 기록할 수 있다.

`herdr-harness approve PATH TASK_ID --confirm-user-approval`

직접 작성하는 기존 방식도 유효하지만, 기존 파일은 `approve`가 조용히 덮어쓰지 않는다.

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
`approve`는 `awaiting_approval` 상태와 최신 `APPROVED` Review를 다시 확인한 뒤 이 기록을
원자적으로 만들고 같은 transition Gate를 호출한다.

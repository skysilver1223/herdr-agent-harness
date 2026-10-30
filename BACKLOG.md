# Backlog — 열린 항목

현재 확인된 미처리 항목만 기록한다. 과거 기록은
[2026-09 아카이브](docs/BACKLOG_ARCHIVE_2026-09.md)에서 확인한다.

## 열린 항목

> **2026-10-30 갱신**: v2 개편으로 2·3·4·5·6·8번이 종결되어
> [2026-10 아카이브](docs/BACKLOG_ARCHIVE_2026-10.md)로 옮겼다.

1. **agy 승인 UI 대기가 `settled`로 보고됨** — *auto 모드에서만 발동*
   Provider의 도구 실행 승인 화면을 `_runtime_scan_approval_signal` 같은 별도 스캔
   계층에서 감지한다. `_runtime_scan_quota_signal`이 선례다.
   ([task-007 Review 근거](../harness-dev/.harness/reviews/task-007-review-1.md#쟁점-1-최우선-실측3승인-ui-대기-판정))
   v2 참고: 잘못 settled로 보고돼도 제출 게이트에서 Harness가 AC를 직접 실행하고 보고서·Review를 요구하므로 잘못된 결과가 다음 단계로 넘어가지는 않는다. run은 보고서 없이 끝난 Worker를 보류로 돌린다.

7. **프롬프트가 전달됐는데 Agent가 오류를 낸 경우도 `settled`로 보고됨**
   2026-09-12 실측. 잘못된 모델로 기동했을 때 codex는 400 오류, claude는 안내
   메시지를 냈는데 `dispatch_result`는 셋 다 `settled`였다. task-007이 "프롬프트
   미수신"은 잡게 만들었지만 "전달 후 Agent 오류"는 여전히 성공으로 보고된다.
   1번과 같은 출력 스캔 계층의 문제다 — 함께 다루는 것이 자연스럽다.
   (근거: v1 ARCHITECTURE.md §13 — v2에서 README로 통합, 원문은 git 이력)
   v2 참고: 1번과 같이 제출·교차 검토 게이트가 막는다. 남은 것은 조기 감지(쿼터 문구 외의 오류 패턴)다.

## 기재 규칙

- 사용자에게서 들어온 개선 제보, 기능 제안, 문서화 요청만 추가한다. Harness가 새 작업을
  스스로 발굴하지 않는다.
- 항목 하나에는 목적 하나만 두고, 근거와 상세 설계는 Intent·Task·Review 등 원문에
  링크한다.
- 종결된 항목은 현재 목록에 누적하지 않고 해당 월의 `docs/BACKLOG_ARCHIVE_<YYYY-MM>.md`로
  원문을 옮긴다.
- 설계 원칙을 바꾸는 제안은 SPEC 재승인 전까지 열린 구현 항목으로 추가하지 않는다.

# Backlog — 열린 항목

현재 확인된 미처리 항목만 기록한다. 과거 기록은
[2026-09 아카이브](docs/BACKLOG_ARCHIVE_2026-09.md)에서 확인한다.

## 열린 항목

1. **agy 승인 UI 대기가 `settled`로 보고됨**
   Provider의 도구 실행 승인 화면을 `_runtime_scan_approval_signal` 같은 별도 스캔
   계층에서 감지한다. `_runtime_scan_quota_signal`이 선례다.
   ([task-007 Review 근거](../harness-dev/.harness/reviews/task-007-review-1.md#쟁점-1-최우선-실측3승인-ui-대기-판정))

2. **`--cwd` 사용 시 Harness 워크스페이스에 보고할 수 없음**
   코드 저장소에서 Worker를 기동하면 Harness 워크스페이스가 Sandbox 밖이 되어
   `.harness/attempts/`에 결과를 쓸 수 없다.
   ([wave-002 근거](../harness-dev/.harness/MILESTONES.md#wave-002-후보-활성-상한-5-때문에-미기안))

3. **재dispatch가 고아 Pane을 만들고 `status --live`가 감지하지 못함**
   meta를 덮어쓰기 전에 기존 Agent를 정리하거나 재dispatch를 거부하고, 등록되지 않은
   `hh-*` Agent도 탐지할 수 있어야 한다.
   ([wave-002 근거](../harness-dev/.harness/MILESTONES.md#wave-002-후보-활성-상한-5-때문에-미기안))

4. **`dispatch` 대기 만료 판정과 `--timeout` 상한 처리**
   `agent prompt --wait` 만료만으로 timeout을 판정하며 `herdr agent wait`를 사용하지
   않는다. Herdr의 300000ms 상한을 넘는 값도 Pane과 Attempt를 만든 뒤에야 실패한다.
   ([wave-002 근거](../harness-dev/.harness/MILESTONES.md#wave-002-후보-활성-상한-5-때문에-미기안))

5. **`write_scope` Sandbox 사전 검사 부재**
   쓰기 범위가 Worker의 Sandbox 밖이어도 Agent를 먼저 띄워, 실제 쓰기 단계에서 실패한다.
   ([wave-002 근거](../harness-dev/.harness/MILESTONES.md#wave-002-후보-활성-상한-5-때문에-미기안))

6. **Event Log 미기록 경로와 Replay 도구 부재**
   `dispatch`·`observe`·`quota-check` 이벤트는 기록하지 않으며 Replay 도구도 없다.
   ([ARCHITECTURE §13](ARCHITECTURE.md#13-향후-고도화))

## 기재 규칙

- 사용자에게서 들어온 개선 제보, 기능 제안, 문서화 요청만 추가한다. Harness가 새 작업을
  스스로 발굴하지 않는다.
- 항목 하나에는 목적 하나만 두고, 근거와 상세 설계는 Intent·Task·Review 등 원문에
  링크한다.
- 종결된 항목은 현재 목록에 누적하지 않고 해당 월의 `docs/BACKLOG_ARCHIVE_<YYYY-MM>.md`로
  원문을 옮긴다.
- 설계 원칙을 바꾸는 제안은 SPEC 재승인 전까지 열린 구현 항목으로 추가하지 않는다.

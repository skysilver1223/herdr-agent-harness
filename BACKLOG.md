# Backlog — 열린 항목

현재 확인된 미처리 항목만 기록한다. 과거 기록은
[2026-09 아카이브](docs/BACKLOG_ARCHIVE_2026-09.md)에서 확인한다.

## 열린 항목

> **2026-09-12 갱신**: 이 목록은 `approval_mode: auto` 기준이다. 프로젝트를
> `bypass`로 운영하면 1·2·5는 **발동하지 않지만 해결된 것은 아니다** — `auto`로
> 돌아가면 그대로 재발한다. 각 항목에 조건을 적었다.

1. **agy 승인 UI 대기가 `settled`로 보고됨** — *auto 모드에서만 발동*
   Provider의 도구 실행 승인 화면을 `_runtime_scan_approval_signal` 같은 별도 스캔
   계층에서 감지한다. `_runtime_scan_quota_signal`이 선례다.
   ([task-007 Review 근거](../harness-dev/.harness/reviews/task-007-review-1.md#쟁점-1-최우선-실측3승인-ui-대기-판정))

2. **`--cwd` 사용 시 Harness 워크스페이스에 보고할 수 없음** — *auto 모드에서만 발동*
   코드 저장소에서 Worker를 기동하면 Harness 워크스페이스가 Sandbox 밖이 되어
   `.harness/attempts/`에 결과를 쓸 수 없다.
   `bypass`에서는 Sandbox가 없어 Worker가 직접 쓴다(2026-09-12 task-011·012에서 확인).
   근본 해결은 Provider별로 쓰기 가능 루트를 둘 다 주거나 Attempt 경로만 예외 허용하는 것이다.
   ([wave-002 근거](../harness-dev/.harness/MILESTONES.md#wave-002-후보-활성-상한-5-때문에-미기안))

3. **재dispatch가 고아 Pane을 만들고 `status --live`가 감지하지 못함**
   meta를 덮어쓰기 전에 기존 Agent를 정리하거나 재dispatch를 거부하고, 등록되지 않은
   `hh-*` Agent도 탐지할 수 있어야 한다.
   ([wave-002 근거](../harness-dev/.harness/MILESTONES.md#wave-002-후보-활성-상한-5-때문에-미기안))

4. **`dispatch` 대기 만료 판정과 `--timeout` 상한 처리**
   `agent prompt --wait` 만료만으로 timeout을 판정하며 `herdr agent wait`(전용 명령)를
   사용하지 않는다. Herdr의 300000ms 상한을 넘는 값도 Pane과 Attempt를 만든 뒤에야 실패한다.
   2026-09-12 task-007이 `working -> running` 정규화를 넣어 **정상 작업을 timeout으로
   오판하는 부분은 해소**됐다. 남은 것은 `herdr agent wait` 미사용과 상한 미검증이다.
   ([wave-002 근거](../harness-dev/.harness/MILESTONES.md#wave-002-후보-활성-상한-5-때문에-미기안))

5. **`write_scope` Sandbox 사전 검사 부재** — *auto 모드에서만 발동*
   쓰기 범위가 Worker의 Sandbox 밖이어도 Agent를 먼저 띄워, 실제 쓰기 단계에서 실패한다.
   `bypass`에서는 Sandbox가 없어 발생하지 않지만, 동시에 `write_scope`가 강제력을 잃고
   문서상 지침이 된다 — 우회이지 해결이 아니다.
   ([wave-002 근거](../harness-dev/.harness/MILESTONES.md#wave-002-후보-활성-상한-5-때문에-미기안))

6. **Event Log 미기록 경로와 Replay 도구 부재**
   `dispatch`·`observe`·`quota-check` 이벤트는 기록하지 않으며 Replay 도구도 없다.

7. **프롬프트가 전달됐는데 Agent가 오류를 낸 경우도 `settled`로 보고됨**
   2026-09-12 실측. 잘못된 모델로 기동했을 때 codex는 400 오류, claude는 안내
   메시지를 냈는데 `dispatch_result`는 셋 다 `settled`였다. task-007이 "프롬프트
   미수신"은 잡게 만들었지만 "전달 후 Agent 오류"는 여전히 성공으로 보고된다.
   1번과 같은 출력 스캔 계층의 문제다 — 함께 다루는 것이 자연스럽다.
   ([ARCHITECTURE §13](ARCHITECTURE.md#13-향후-고도화))

## 기재 규칙

- 사용자에게서 들어온 개선 제보, 기능 제안, 문서화 요청만 추가한다. Harness가 새 작업을
  스스로 발굴하지 않는다.
- 항목 하나에는 목적 하나만 두고, 근거와 상세 설계는 Intent·Task·Review 등 원문에
  링크한다.
- 종결된 항목은 현재 목록에 누적하지 않고 해당 월의 `docs/BACKLOG_ARCHIVE_<YYYY-MM>.md`로
  원문을 옮긴다.
- 설계 원칙을 바꾸는 제안은 SPEC 재승인 전까지 열린 구현 항목으로 추가하지 않는다.

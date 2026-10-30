# Backlog Archive — 2026-10

Harness v2 개편(2026-10-30)에서 종결된 항목의 원문과 종결 사유다.

## 항목 2 — 종결

종결 사유: v2: Task 작업 디렉터리가 Harness 워크스페이스와 다르면 dispatch가 모든 Provider에 `--add-dir <워크스페이스>`를 붙인다(claude·codex·agy 모두 `--add-dir` 지원 확인). Worker가 보고서를 워크스페이스에 쓸 수 있다.

원문:

2. **`--cwd` 사용 시 Harness 워크스페이스에 보고할 수 없음** — *auto 모드에서만 발동*
   코드 저장소에서 Worker를 기동하면 Harness 워크스페이스가 Sandbox 밖이 되어
   `.harness/attempts/`에 결과를 쓸 수 없다.
   `bypass`에서는 Sandbox가 없어 Worker가 직접 쓴다(2026-09-12 task-011·012에서 확인).
   근본 해결은 Provider별로 쓰기 가능 루트를 둘 다 주거나 Attempt 경로만 예외 허용하는 것이다.
   ([wave-002 근거](../harness-dev/.harness/MILESTONES.md#wave-002-후보-활성-상한-5-때문에-미기안))

## 항목 3 — 종결

종결 사유: task-016에서 재dispatch 거부가 들어갔고, v2는 Pane을 닫는 데 실패하면 정리로 기록하지 않아 살아 있는 Pane이 추적에서 사라지지 않는다.

원문:

3. **재dispatch가 고아 Pane을 만들고 `status --live`가 감지하지 못함**
   meta를 덮어쓰기 전에 기존 Agent를 정리하거나 재dispatch를 거부하고, 등록되지 않은
   `hh-*` Agent도 탐지할 수 있어야 한다.
   ([wave-002 근거](../harness-dev/.harness/MILESTONES.md#wave-002-후보-활성-상한-5-때문에-미기안))

## 항목 4 — 종결

종결 사유: v2: `--timeout`은 Pane을 만들기 전에 300000ms 상한을 검사하고, dispatch는 전달 확인까지만 기다린다. 작업 완료 대기는 `observe --wait`가 `herdr agent wait`로 한다.

원문:

4. **`dispatch` 대기 만료 판정과 `--timeout` 상한 처리**
   `agent prompt --wait` 만료만으로 timeout을 판정하며 `herdr agent wait`(전용 명령)를
   사용하지 않는다. Herdr의 300000ms 상한을 넘는 값도 Pane과 Attempt를 만든 뒤에야 실패한다.
   2026-09-12 task-007이 `working -> running` 정규화를 넣어 **정상 작업을 timeout으로
   오판하는 부분은 해소**됐다. 남은 것은 `herdr agent wait` 미사용과 상한 미검증이다.
   ([wave-002 근거](../harness-dev/.harness/MILESTONES.md#wave-002-후보-활성-상한-5-때문에-미기안))

## 항목 5 — 종결

종결 사유: v2: Task마다 git worktree를 작업 디렉터리로 쓰므로 Sandbox 쓰기 범위(기동 디렉터리)가 곧 그 Task의 작업 공간이다. write_scope 파일은 그 안에 있다.

원문:

5. **`write_scope` Sandbox 사전 검사 부재** — *auto 모드에서만 발동*
   쓰기 범위가 Worker의 Sandbox 밖이어도 Agent를 먼저 띄워, 실제 쓰기 단계에서 실패한다.
   `bypass`에서는 Sandbox가 없어 발생하지 않지만, 동시에 `write_scope`가 강제력을 잃고
   문서상 지침이 된다 — 우회이지 해결이 아니다.
   ([wave-002 근거](../harness-dev/.harness/MILESTONES.md#wave-002-후보-활성-상한-5-때문에-미기안))

## 항목 6 — 종결

종결 사유: v2 설계 변경: events.tsv를 없애고 Git에 남는 Harness 증빙 기록(`*.harness.md`)과 commit·태그 이력이 같은 역할을 한다.

원문:

6. **Event Log 미기록 경로와 Replay 도구 부재**
   `dispatch`·`observe`·`quota-check` 이벤트는 기록하지 않으며 Replay 도구도 없다.

## 항목 8 — 종결

종결 사유: v2: test.sh는 모든 명령을 `</dev/null`로 실행하고, remote setup은 stdin·stdout이 모두 터미널일 때만 묻는다. 비대화형 remote setup을 테스트로 고정했다.

원문:

8. **`harness.sh test`가 TTY 환경에서 사람 입력을 기다린다** — *2026-09-12 사용자 제보*
   원격 모드 `setup` 검사가 `_remote_ask`(`lib/45-remote.sh:291`)를 호출하는데,
   그 가드는 `[[ ! -t 0 ]]`로 **stdin이 TTY인지만** 본다. 비-TTY면 기본값으로
   조용히 통과하지만, 사용자가 터미널에서 돌리면 실제로 프롬프트가 뜬다.

   ```
   SSHFS 마운트 경로(로컬) [/tmp/herdr-harness-test.XXXX/setup-project/.harness/remote-mount]:
   ```

   자체 테스트는 어떤 환경에서도 사람 입력을 요구해선 안 된다.

   발견이 늦은 이유가 문제의 성격을 보여준다 — Agent와 스크립트의 stdin은 TTY가
   아니어서 이 경로를 **한 번도 타지 않는다.** README가 안내하는 방식(사람이
   터미널에서 `herdr-harness test`)에서만 나타난다.

   기존 `PASS: 비대화형 명시적 실패`는 "비대화형에서 die하는지"를 보고,
   **"대화형에서 멈추는지"는 아무도 검사하지 않는다.**

   조치 방향: 자체 테스트가 원격 setup을 호출할 때 stdin을 끊거나
   (`< /dev/null`), 필요한 값을 모두 옵션으로 넘기거나, 테스트 전용
   비대화형 플래그를 둔다. 그리고 **"대화형 환경에서도 test가 멈추지 않는다"를
   검사로 고정**해야 같은 부류가 재발하지 않는다.

   우회: `bash harness.sh test < /dev/null`

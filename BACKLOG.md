# Backlog — Agent Loop 도입 후 남은 작업

브랜치 `feat/agent-loop-harness` 작업에서 확인됐으나 처리하지 않은 항목이다.
Claude(통합·상태머신), Codex(런타임), AGY(Skill·문서 → 독립 리뷰) 세 Pane으로 진행했고,
아래 1~5는 AGY의 독립 리뷰에서 나온 것이다.

**2026-09-05 — 1~6 전부 처리 완료.** 아래 각 항목에 처리 내역을 남겼다.
`bash harness.sh test` 12개 PASS 재확인, 재현된 결함은 원래 재현 조건으로 다시
돌려 수정을 확인했다(uppercase Task ID, jq 없는 환경의 첫 값 추출, 200줄 초과
SPEC.md).

진행 상황 요약 페이지: https://claude.ai/code/artifact/d705d3c2-0186-4083-aa13-c1b327511b76

**재현 여부를 구분해 적었다. "재현됨"은 실제로 실행해 확인한 것이고, "미재현"은 리뷰 지적이지만
현재 환경에서 조건이 성립하지 않아 확인하지 못한 것이다.**

---

## 1. [MED · 재현됨] 대문자 Task ID면 dispatch가 즉시 중단

`_runtime_require_id`는 `^[A-Za-z0-9][A-Za-z0-9._-]*$`로 대문자 Task ID를 유효하게 받는다.
그러나 Agent 이름을 만들 때 소문자로 낮추지 않아, Herdr의 이름 규칙
`^[a-z][a-z0-9_-]{0,31}$` 검사에서 걸려 die 한다.

재현:

```
$ bash harness.sh dispatch . TASK-UP worker
오류: 생성된 Agent 이름이 유효하지 않습니다: hh-TASK-UP-w-1
```

수정 위치: `harness.sh` · `cmd_dispatch`의 `agent_name="hh-${task_id//...}"` 줄

```bash
local task_slug="${task_id,,}"
agent_name="hh-${task_slug//[^a-z0-9_-]/-}-${role:0:1}-$attempt"
```

**처리 완료.** 위 코드 그대로 반영. `task_id=TASK-UP`으로 재현 조건을 다시 돌려
`agent_name=hh-task-up-w-1`이 herdr 이름 규칙(`^[a-z][a-z0-9_-]{0,31}$`)을
통과하는 것을 확인했다.

---

## 2. [MED · 재현됨] jq 없는 환경에서 greedy 정규식이 마지막 값을 뽑음

`_runtime_json_field`의 sed fallback은 앞쪽 `.*`가 탐욕적이라, 같은 키가 여러 번 나오면
첫 값이 아니라 **마지막 값**을 추출한다. jq 경로의 `head -n 1`과 결과가 어긋난다.

재현:

```
$ printf '%s' '{"pane":{"pane_id":"w1:p2"},"other":{"pane_id":"w1:p99"}}' \
    | sed -n 's/.*"pane_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
w1:p99          # jq 경로는 w1:p2
```

`pane split` 응답처럼 중첩 객체에 같은 키가 반복되면 잘못된 Pane을 잡을 수 있다.

수정 위치: `harness.sh` · `_runtime_json_field`의 sed 분기.
앞쪽 `.*`를 `[^{]*` 등으로 제한하고 첫 줄만 취한다.

**처리 완료.** `.*` greedy 매치 대신 `grep -o`로 겹치지 않는 첫 매치만 취하고
그 조각에서만 값을 뽑도록 바꿨다(jq 경로와 동일하게 첫 값을 취한다). 재현
입력(`{"pane":{"pane_id":"w1:p2"},"other":{"pane_id":"w1:p99"}}`)으로 다시
돌려 `w1:p2`가 나오는 것을 확인했다.

---

## 3. [MED · 미재현] stderr 혼입 시 JSON 파싱 전면 실패

herdr 호출을 전부 `2>&1`로 캡처한다. CLI나 터미널 환경이 경고 한 줄이라도 stderr에 쓰면
입력이 순수 JSON이 아니게 되어 `pane_id` 추출이 빈 값이 되고,
`[[ -n "$pane_id" ]] || die` 에서 dispatch가 중단된다.

현재 환경에서는 herdr가 stderr를 쓰지 않아 재현되지 않았다. 다만 방어는 값싸다.

수정 위치: `harness.sh` · `_runtime_json_field` 및 herdr 호출부.
파서에 넘기기 전 첫 `{`부터 마지막 `}`까지만 잘라낸다.

**처리 완료.** 호출부 6곳을 각각 고치는 대신 `_runtime_json_field` 진입
지점 한 곳에서 첫 `{`~마지막 `}`로 잘라내 모든 호출부가 자동으로 방어를
받도록 했다. 여전히 미재현이라 회귀 재현은 못 했지만, 임의로 만든 stderr
혼입 입력으로 트리밍 로직 자체는 확인했다.

---

## 4. [LOW] mktemp 임시 파일 trap cleanup 부재

`set -e` 중간 실패나 SIGINT 시 임시 파일이 삭제되지 않고 누적된다.
`.harness/runtime/`과 `.harness/evidence/`에 `.tasks.XXXXXX`, `.anomalies.XXXXXX`,
`.harness-transition.XXXXXX`, `.capture.XXXXXX` 등이 남는다.

수정 위치: `cmd_transition`, `cmd_status_live`, `_runtime_append_evidence`,
`_runtime_context_packet`. 함수 진입 시 `trap 'rm -f ...' RETURN` 등록.

**처리 완료(변형 적용).** `trap 'rm -f -- "$temporary"' RETURN`처럼 변수를
홑따옴표로 지연 평가하면 함수가 실제로 반환하는 시점에 `local` 변수가 이미
스코프를 벗어나 `set -u`가 `unbound variable`로 죽는다(자체 테스트로 실제
재현됨). `trap "rm -f -- '$temporary'" RETURN`처럼 겹따옴표로 등록 시점에
경로를 즉시 전개해 문제를 피했다. 4곳 전부 적용 후 `bash harness.sh test`
12개 PASS(전이 14케이스 포함) 재확인.

---

## 5. [LOW] Context Packet의 SPEC 200줄 하드코딩 잘림

`_runtime_context_packet`이 `sed -n '1,200p' .harness/SPEC.md` 로 자른다.
SPEC이 200줄을 넘으면 Acceptance Criteria나 제약이 Worker·Reviewer에게 전달되지 않는다.

줄 수 자르기 대신 섹션 헤더 기반 발췌가 맞다.

**처리 완료.** `_runtime_spec_section`을 추가해 `## N.` 헤더로 섹션을 찾아
다음 헤더 전까지 통째로 뽑는다. Context Packet에는 실행에 필요한 절(1 핵심
목표·3 기술 스택 및 제약·4 요구사항·5 Acceptance Criteria·6 제외 범위)을
번호로 모두 담고, 체크리스트성 절(2 기존 자료 판단)과 승인 메타(7)는 뺐다.
272줄짜리 SPEC.md로 재현해, 옛 방식(`1,200p`)이면 5·6번 섹션이 통째로
잘려 나가던 것을 확인하고 새 방식이 둘 다 담는 것을 확인했다.

---

## 6. README.md · ARCHITECTURE.md 갱신

이번 작업으로 다음이 문서에 반영되지 않은 채 남았다.

- 신규 명령 6개: `validate` / `transition` / `dispatch` / `observe` / `close-agent` / `status --live`
- 실행 원칙: **Bash는 한 스텝의 실행·검증·기록, Orchestrator Agent가 다음 단계 선택**
- `init`의 `git init` + 기준 commit 자동화
- 자체 테스트 출력이 5줄 → 12줄 PASS로 확장
- 기존 "생성되는 프로젝트 구조" 트리가 실제 생성물과 다름
  (`waves/`, `attempts/`, `decisions/`, `archive/` 누락)
- 생성물이 5종 → 20종 템플릿, 파일 116개

섹션별 교체 계획은 아래 부록에 있다.

**처리 완료.** 아래 부록 계획 그대로 README.md·ARCHITECTURE.md에 반영했다.

---

## 7. 2026-09-05 후속 — quota-retry/auto-step opt-in 예외 추가

아래 "참고: 이번 작업에서 확정한 설계 원칙"의 "절대 만들지 않는 것"(자율 반복 루프,
자동 Provider failover 연쇄 호출)에 대해 사용자 요청으로 위험을 먼저 검토했고,
원칙 자체를 뒤집지 않는 범위에서 **opt-in·유한·되돌릴 수 있는 예외**만 추가했다.

- 두 명령 모두 정책 파일(`quota-policy.yaml`의 `automatic_failover`,
  `loop-policy.yaml`의 `enabled`)에서 명시적으로 켜야만 동작한다(기본 false).
- `quota-retry`는 연속 저쿼터 확인(`low_confirm_count` + `cooldown_seconds`) 후
  Provider를 fallback_chain의 다음 값으로 바꾸고 `handover_required`까지만
  자동 전이한다. `ready` 재개는 여전히 사람이
  `.harness/decisions/TASK_ID-failover-approval.md`에 `승인: yes`를 쓰고
  직접 한다. Task당 1회 한정(flapping 방지).
- `auto-step`은 정책 상한(`max_turns_ceiling`) 안에서만 도는 유한 배치다.
  1턴째만 dispatch로 Pane을 만들고 이후 턴은 같은 Agent를 observe로만
  재조회한다(반복 dispatch가 Pane을 고아로 만드는 문제를 피하기 위함).
  `completed`·`reviewing`·`awaiting_approval`로 이어지는 코드 경로는 아예
  없다 — 자체 테스트가 이걸 구조적으로 검증한다.
- 두 명령 다 mkdir 기반 Task Lock(`.harness/runtime/TASK_ID.lock`)을 잡는다.
  다만 이건 quota-retry/auto-step 두 자동화 경로끼리만 충돌을 막는 권고적
  잠금이지, 사람이 수동으로 dispatch/transition을 실행하는 것까지 막는
  SQLite Lease/Fencing Token(§13 선택적 고도화)은 아니다 — 남은 한계로
  README.md·ARCHITECTURE.md §8.1·§8.2에 명시했다.

검토·설계 세션: https://claude.ai/code/session_012SdWRBBfDUadCsZYbAPhNh
커밋: `4386afb feat: quota-retry/auto-step opt-in 제약된 자동화 + Task Lock 추가`

---

## 8. [MED · 재현됨] 기존 프로젝트가 harness.sh 갱신을 따라가지 못한다 — 실사례로 발견됨

`init`은 신규 프로젝트 전용이다(대상 경로가 비어 있지 않으면 die). 그런데 기존
프로젝트의 `.agents/skills/*/SKILL.md`·`.claude/skills/*/SKILL.md`·
`.agents/roles/*.agent.md`·`AGENTS.md`를 **최신 템플릿으로 재동기화하는 명령이
없다.** Agent Loop(`dispatch`/`observe`/`transition`/`close-agent`/`validate`
/`status --live`)가 나중에 추가되면서 `cmd_init`이 쓰는 `harness-orchestrate`
SKILL.md 템플릿은 크게 두꺼워졌지만(사전조건→7단계 절차→결과계약→사후조건
체크리스트), **그보다 먼저 만들어진 프로젝트는 그 내용을 영영 못 받는다.**

재현(실사례): `tube-index-refactor` 프로젝트(Agent Loop 기능 이전 버전의
`init`으로 생성)의 `.agents/skills/harness-orchestrate/SKILL.md`와
`.claude/skills/harness-orchestrate/SKILL.md`를 지금 이 저장소의 `harness.sh`가
`cmd_init`에서 쓰는 heredoc과 대조하면 완전히 다르다 — 그 프로젝트의 두 파일은
"HERDR_ENV를 확인하고 승인된 Wave만 실행하며 STATE를 갱신한다"는 8줄짜리 stub뿐이고
(둘이 서로 byte-identical이라 애초에 상세 절차가 반영된 적이 없다는 뜻이다),
`dispatch`·`observe`·`transition`·`close-agent`라는 단어 자체가 그 프로젝트의
`AGENTS.md`·어떤 skill 파일에도 없다(`quota-check`만 `AGENTS.md`에 언급됨).

실제로 벌어진 일: 그 프로젝트에서 작업한 Claude Orchestrator 세션이
`herdr-harness dispatch`류의 존재를 전혀 모른 채, raw `herdr pane split` +
`herdr agent start`/`agent prompt`로 Worker·Reviewer를 직접 우회 배정했다.
Task Lock 미획득, `.harness/evidence/events.tsv` 이벤트 로그 없음,
`.harness/attempts/*.md`·`.harness/reviews/*.md` 정식 기록 없음(Reviewer의
전체 재현검증 내용은 Herdr pane을 닫는 순간 원본이 사라졌다) — 이 프로젝트가
갖추려던 안전장치·감사 트레일이 통째로 빠진 채 한 Task 라운드가 완료·검수까지
갔다. 대조군: Agent Loop 이후 `init`으로 만든 `harness-ui-audit` 프로젝트는
`.harness/runtime/*.meta`·`.result`·`.closed`, `evidence/events.tsv`,
`attempts/*.md`, `reviews/*.md`가 정상적으로 남아 있다 — 같은 `harness.sh`를
쓰는 두 프로젝트가 생성 시점 버전 차이만으로 완전히 다르게 동작한 것이다.

수정 위치 제안: `harness.sh`에 `sync-templates PATH`(가칭) 명령 추가.
- Harness가 소유한 파일만 재생성한다: `.agents/skills/`, `.claude/skills/`,
  `.agents/roles/`, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`. 사용자 데이터
  (`.harness/SPEC.md`·`STATE.md`·`tasks/`·`decisions/`·`waves/` 등)는 건드리지
  않는다 — `cmd_init`의 write 목록과 사용자 데이터 목록을 코드 레벨에서
  분리해 두면 이 구분이 유지보수 중 갈라지지 않는다.
- `--dry-run`으로 diff 미리보기를 기본 동작으로 하고, 실제 적용은 `cmd_init`과
  같은 Git 기준선 확인(작업 트리 unclean이면 die)을 공유한다.
- 최소한 `herdr-harness doctor`나 `status --live`가 "이 프로젝트의 skill
  템플릿이 현재 harness.sh보다 오래됐다"는 경고만이라도 내면(diff 유무만 검사),
  `sync-templates` 구현 전에도 이번 것과 같은 무인지 상태(agent가 구버전
  skill을 읽고도 그런 줄 모르는 것)는 막을 수 있다.

발견 세션: https://claude.ai/code/session_01BH9fokbznniajMF4nZDozY

**처리 완료.** `sync-templates PATH [--apply]` 명령을 추가했다 — 기본은 diff
미리보기, `--apply`로 `.agents/skills/`·`.agents/roles/`·`.harness/*/TEMPLATE.*`·
`.claude/skills/` 심볼릭 링크만 최신 템플릿으로 갱신한다. `AGENTS.md`·
`CLAUDE.md`·`GEMINI.md`는 프로젝트가 손으로 고쳤을 수 있어 자동 갱신하지
않고 diff만 보여준다(실제로 이 gap을 겪은 프로젝트의 AGENTS.md가 그런
경우였다). 구현 중 실제로 버그 2건이 나왔다 — `emit_doc`이 `| write_file`로
서브셸에서 돌아 sync 모드의 카운트 배열이 호출자에게 안 돌아오던 것,
`diff`(차이 있으면 exit 1)가 가드 없이 파이프에 물려 `set -e` 아래서
AGENTS.md에 실제 차이가 있을 때만 스크립트 전체가 조용히 죽던 것. 둘 다
고쳤고 `cmd_test`에 회귀 테스트를 추가했다(PASS 16→17). `tube-index-refactor`
프로젝트에 실제로 적용해 20개 파일(skill 9·role 6·TEMPLATE 5) 전부 갱신을
확인했다.
커밋: `harness.sh`(+286/-34), `BACKLOG.md`

---

## 참고: 이번 작업에서 확정한 설계 원칙

Codex는 처음 `run-wave` 자율 루프를 제안했고 AGY는 설계 철학(`unattended_execution: false`) 위반이라
반박했다. 3라운드 토론 끝에 Codex가 *"Bash는 예외를 정규화하고 기록하되 복구 정책을 판단하면 안 된다"* 로
입장을 수정하며 `run-wave` · `resume-wave` · `reconcile`을 철회했다.

> Bash는 "한 단계의 실행·검증·기록"을 책임지고,
> Orchestrator Agent는 "다음 단계의 선택"을 책임진다.
> 상주 루프를 두지 않는다. 호출 1회 = 1스텝.

절대 만들지 않는 것: 자율 반복 루프, `completed` 자동 승인,
자동 Provider failover 연쇄 호출, 상주 데몬·파일 감시 프로세스.

---

# 부록: README / ARCHITECTURE 갱신 초안

아래는 Codex가 작성한 섹션별 교체 계획이다.


아래는 전체 파일 재작성 대신 섹션 단위 교체·삽입안이다.

## README.md

### 1. `### 10. 쿼터 없는 자체 테스트`의 기대 결과 블록 교체

```diff
-PASS: Bash 문법
-PASS: Harness 파일 생성
-PASS: 공통 Skill과 Claude 연결
-PASS: 신규 프로젝트 보호
-PASS: Agent 호출 없음
+PASS: Bash 문법
+PASS: Harness 파일 생성 (20종 템플릿)
+PASS: 공통 Skill과 Claude 연결
+PASS: 플레이스홀더 치환
+PASS: Git 기준선 생성
+PASS: 신규 프로젝트 보호
+PASS: 비대화형 명시적 실패
+PASS: 상태 전이표 강제 (13개 케이스)
+PASS: 이벤트 로그 기록
+PASS: validate 검증 (정상/Worker=Reviewer/Git 누락)
+PASS: 스텝 명령 인자 검증
+PASS: Agent 호출 없음
```

기존 “Agent 쿼터를 사용하지 않는다” 설명은 유지한다.

### 2. `## 프로젝트 생성`의 기본값 표 다음 설명 교체

```diff
-스크립트는 신규·빈 디렉터리에서만 작동하며 기존 파일을 덮어쓰지 않습니다.
+스크립트는 신규·빈 디렉터리에서만 작동하며 기존 파일을 덮어쓰지 않습니다. 생성 후 `git init`과 Harness 파일 staging을 자동 수행합니다. Git 사용자 이름과 이메일이 설정되어 있으면 기준 commit도 생성합니다. 설정이 없어 commit을 만들지 못한 경우 안내된 `git commit`을 완료해야 Task를 `active`로 전이할 수 있습니다.
```

### 3. `## 상태 확인` 섹션 전체 교체

```diff
 ## 상태 확인
 
 ```bash
 herdr-harness status ~/Projects/snmp-normalizer
+herdr-harness status ~/Projects/snmp-normalizer --live
+herdr-harness status ~/Projects/snmp-normalizer --live --json
 ```
+
+기본 상태 명령은 `STATE.md`를 출력합니다. `--live`는 문서 상태와 Herdr Agent, Git 상태를 함께 대조하여 `DRIFT`와 `ORPHAN`을 표시합니다. 상태를 자동 수정하지는 않습니다.
```

### 4. `## 상태 확인` 뒤에 신규 섹션 삽입

```diff
+## Agent Loop 스텝 명령
+
+Harness는 상주 Controller나 자율 반복 루프를 실행하지 않습니다. Bash 명령은 호출 한 번에 한 단계의 검증·실행·기록만 담당하고, Orchestrator Agent가 결과를 읽어 다음 단계를 선택합니다.
+
+| 명령 | 책임 |
+|---|---|
+| `herdr-harness validate [PATH] [--wave ID] [--no-git]` | Git 기준선, Task/Wave, Provider, 의존성, 실행 상한과 write scope를 읽기 전용 검증 |
+| `herdr-harness transition PATH TASK_ID TO_STATE [--note TEXT]` | 허용된 상태 전이와 필수 Attempt/Evidence/Review/승인 기록 강제 |
+| `herdr-harness dispatch PATH TASK_ID worker\|reviewer [--timeout MS]` | Pane 생성, Agent 시작, Context Packet 1회 전송, 대기와 증적 기록 |
+| `herdr-harness observe PATH TASK_ID [worker\|reviewer]` | 기존 Agent를 재조회하고 Evidence에 추가 |
+| `herdr-harness close-agent PATH TASK_ID [worker\|reviewer] [--force]` | Harness runtime에 등록된 Pane만 정리 |
+| `herdr-harness status [PATH] --live [--json]` | 문서·Herdr·Git 실시간 상태 대조 |
+
+`dispatch`는 재시도, 상태 전이, blocked 응답 또는 Provider failover를 수행하지 않습니다. Orchestrator는 반환된 `dispatch_result`를 확인한 뒤 사용자 승인 경계를 지키며 다음 스텝을 호출합니다.
```

### 5. `## 생성되는 프로젝트 구조`의 트리 교체

```diff
 project/
 ├── AGENTS.md
 ├── CLAUDE.md
 ├── GEMINI.md
 ├── HARNESS_START.md
 ├── .agents/
 │   ├── roles/
 │   └── skills/
 ├── .claude/skills/
 └── .harness/
     ├── project.yaml
     ├── SPEC.md
     ├── MILESTONES.md
     ├── STATE.md
     ├── policies/
     ├── profiles/
     ├── tasks/
+    ├── waves/
     ├── references/
+    ├── attempts/
     ├── evidence/
     ├── reviews/
-    └── handovers/
+    ├── handovers/
+    ├── decisions/
+    └── archive/
```

`dispatch` 실행 시 Git 제외 영역인 `.harness/runtime/`이 추가로 생성된다는 문장을 트리 다음에 덧붙인다.

### 6. `## 운영 원칙` 첫머리에 두 항목 삽입

```diff
 ## 운영 원칙
 
+- Bash는 한 스텝의 실행·검증·기록만 담당하고 Orchestrator Agent가 다음 스텝을 선택합니다.
+- 상태는 Task YAML을 직접 편집하지 않고 `herdr-harness transition`으로 전이합니다.
 - 하나의 Task는 하나의 목적만 가집니다.
```

## ARCHITECTURE.md

### 1. `## 1. 목적`의 마지막 문단 뒤에 실행 원칙 삽입

```diff
 무인 실행, 트랜잭션, 물리적 Sandbox를 의미하지는 않습니다.
+
+핵심 실행 원칙은 “Bash는 한 스텝, Agent가 루프”입니다. `harness.sh`는 호출 한 번에 검증, 상태 전이 또는 Agent 한 턴만 수행합니다. Orchestrator Agent가 그 결과와 사용자 응답을 해석해 다음 명령을 선택하며, 상주 루프·자동 failover·자동 완료 승인은 수행하지 않습니다.
```

### 2. `## 2. 구성요소` 표에 행 추가·수정

```diff
 | Herdr | Workspace, Pane, Agent 프로세스와 상태 표시 |
+| `harness.sh` 스텝 명령 | 정적 검증, 상태 전이 강제, Agent 한 턴 실행, Evidence와 런타임 관측 |
 | `AGENTS.md` | Provider 공통 운영 정책 |
@@
-| `.harness/` | SPEC, 계획, 상태, Task, Evidence, Review, Handover |
+| `.harness/` | SPEC, Wave, Task, Attempt, Evidence, Review, Handover, Decision, Runtime 상태 |
```

### 3. `## 5. Task 상태`의 상태도 다음 설명 교체

```diff
 Worker는 `completed`를 선언하지 않습니다. Reviewer는 품질 판정을 기록하고 사용자가 완료를 승인합니다.
+상태 변경은 `herdr-harness transition PATH TASK_ID TO_STATE`만 사용합니다. `submitted`에는 Attempt와 Evidence, `awaiting_approval`에는 `판정: APPROVED`인 Review, `completed`에는 `.harness/decisions/TASK-approval.md`의 `승인: yes`가 필요합니다.
```

### 4. `## 7. 실행 흐름` 전체 교체

```diff
 ## 7. 실행 흐름
 
-1. `herdr-harness init`으로 새 프로젝트를 생성합니다.
-2. `herdr-harness start`로 Herdr Session을 시작합니다.
-3. Orchestrator가 기존 자료를 확인하고 SPEC을 작성합니다.
-4. 사용자가 SPEC을 승인합니다.
-5. Planner가 Milestone과 Task를 만듭니다.
-6. 사용자가 현재 Wave를 승인합니다.
-7. Primary Worker가 Task 하나를 수행합니다.
-8. Worker가 자체 검증과 Attempt를 기록합니다.
-9. 다른 Provider가 읽기 전용 Review를 수행합니다.
-10. 사용자가 Integration과 완료를 승인합니다.
+1. `init`이 프로젝트 파일과 Git 저장소를 만들고 가능한 경우 기준 commit을 생성합니다.
+2. Interview와 Plan 후 사용자가 SPEC과 Wave를 승인합니다.
+3. Orchestrator가 `validate [PATH] --wave ID`로 실행 전제를 검사합니다.
+4. `transition ... active` 후 `dispatch ... worker`로 Worker 한 턴만 실행합니다.
+5. `blocked`, `timeout`, `stalled`이면 `observe`로 상태를 재조회하고 Orchestrator가 사용자 질문, 대기 또는 중단을 결정합니다.
+6. Attempt와 Evidence가 준비되면 `transition ... submitted`, 이어서 `transition ... reviewing`을 수행합니다.
+7. `dispatch ... reviewer`로 다른 Provider의 읽기 전용 Review 한 턴을 실행합니다.
+8. Review 판정에 따라 `changes_requested` 또는 `awaiting_approval`로 전이합니다.
+9. 사용자가 승인 파일에 `승인: yes`를 기록한 뒤에만 `completed`로 전이합니다.
+10. 등록된 Agent는 `close-agent`, 전체 상태는 `status --live`로 정리·관측합니다.
```

### 5. `## 9. Context Packet` 첫 문장과 목록 교체

```diff
-Fallback Worker와 Reviewer에게 전체 대화를 전달하지 않습니다.
+`dispatch`는 Worker와 Reviewer에게 전체 대화 대신 `.harness/runtime/TASK-context-ROLE.md` Context Packet을 한 번 전달합니다.
 
 - 승인된 SPEC 관련 부분
 - 현재 Task Contract
- Reference Inventory 관련 항목
- Git Diff
- 검증 결과
- Handover
+- write scope, 참조와 입력
+- Acceptance Criteria와 검증 방법
 - 다음 한 단계
```

Secret 의심 패턴이 발견되면 Context 원문을 저장·전송하지 않고 해당 dispatch를 실패시킨다는 문장을 목록 뒤에 추가한다.

### 6. `## 13. 향후 고도화` 전체 교체

```diff
 ## 13. 향후 고도화
 
-현재 운영에서 실제 필요가 확인될 때만 추가합니다.
-
-### Level 1: Skill Helper Script
-
-- YAML 검사
-- 검증 로그 저장
-- Secret Pattern 검사
-- 경로 중복 검사
-
-### Level 2: Herdr CLI Wrapper
-
-- Pane 자동 생성
-- Agent 상태 확인
-- Context Packet 전달
-- 완료 알림
-
-### Level 3: 무인 Controller
+현재 Harness는 이미 YAML/상태 검증, Evidence 기록, Secret 패턴 차단, 경로 충돌 검사와 Herdr Pane·Agent 스텝 실행을 제공합니다. 다음 기능은 실제 필요가 확인될 때만 별도 고도화합니다.
+
+### 선택적 고도화
 
 - Event Log와 Replay
 - SQLite Lease와 Controller Epoch
 - Fencing Token
 - Atomic Outbox
 - Worktree와 Integration Lock
 - Sealed Verification Bundle
 - 자동 Failover
 - Container 또는 별도 OS 사용자 격리
 
-Controller는 현재 Harness의 필수 조건이 아니라 선택적 고도화입니다.
+상주 Controller와 자동 Failover는 현재 Harness의 범위가 아닙니다.
```

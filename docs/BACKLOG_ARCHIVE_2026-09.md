# Backlog Archive — 2026-09

이 문서는 2026-09-11에 열린 항목만 남기는 현재 `BACKLOG.md`와 완료 기록을 분리하면서
만든 아카이브다. 이관 직전 원본은 `feat/dispatch-cwd` 브랜치의
`eb5036bc5b610227b1a99afc8022a1089913d9eb` 시점이며, 아래 「이관 전 원문」에는 당시
`BACKLOG.md` 800줄을 수정 없이 그대로 보존했다.

이 파일명은 Evidence 슬롯의 `<주제>_<YYYY-MM-DD>.md` 규칙과 무관한 월별 Backlog
아카이브 규칙 `BACKLOG_ARCHIVE_<YYYY-MM>.md`를 따른다.

## 2026-09-11 후속 기록

이관 전 원문 이후 같은 세션에서 다음 작업이 끝났다. 현재 Backlog의 열린 항목은 아니다.

- `dispatch --cwd` 신설 (`58df790`)
- README 기대 출력 단일 출처화 (`d2f146d`, task-002)
- Task별 모델 선택 (`c484ffc`, task-006)
- test stderr 정리 (`24174c9`, task-003)
- Agent 상태 정규화 수정 (`eb5036b`, task-007)

---

## 이관 전 원문

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
갔다. 대조군: `harness-ui-audit` 프로젝트는 `.harness/runtime/*.meta`·`.result`
·`.closed`, `evidence/events.tsv`, `attempts/*.md`, `reviews/*.md`가 정상적으로
남아 있다 — 그 프로젝트의 세션은 `dispatch`류를 실제로 썼다는 뜻이다.

**정정(구현 뒤 재확인):** 위 "생성 시점 버전 차이" 설명은 확인 안 하고 쓴
추정이었다 — 실측하니 틀렸다. `sync-templates`로 `harness-ui-audit`를 직접
대조해보니 그 프로젝트의 skill 파일도 `harness-refactor`와 **똑같이** 20개
전부 outdated였다(`harness-orchestrate/SKILL.md` 21줄짜리 구버전, 둘 다
"migrate: ... 이관" 커밋으로 생성됨 — `init`을 직접 쓴 적이 없다). 즉 그
프로젝트가 `dispatch`류를 쓴 건 skill 파일이 최신이라서가 아니라, 그 세션이
`herdr-harness --help`를 스스로 찾아봤거나 사용자가 직접 알려줬기 때문일
가능성이 높다 — 확인 안 된 채 남는다. **결론은 안 바뀐다**: skill 파일에
`dispatch`가 안 적혀 있으면 몰라도 되는 게 아니라 몰라도 이상하지 않다는
뜻이고, 그래서 `sync-templates`가 필요하다는 진단 자체는 유효하다. 다만
"버전 차이가 원인"이라는 인과관계는 근거 없이 쓴 것이었으므로 정정한다.

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

## 9. [완료] 구성 과잉 검토 — 3자 리뷰 결과와 감량

**2026-09-06.** "스킬·명령을 너무 많이 넣으면 모델 성능이 저하된다"는 우려로
Claude·AGY·Codex 3자가 저장소를 교차 검토했다. Codex는 `bash harness.sh test`와
`init` 샘플 생성을 실제로 돌려 확인했다.

검토 세션: https://claude.ai/code/session_01RJKTEvVpFVde4RKM9qXLaX

---

### 9-★ 최종 완료 상태 (2026-09-06)

전체 감량이 **PR #2로 `main`에 머지 완료**(`d18acf9`). 브랜치 `fix/drift-9-3`
삭제. 커밋 4개, 아래 세부 절(9-9~9-12)에 각각 처리 내역.

| # | 항목 | 결과 | 커밋 |
|---|---|---|---|
| 9-3 | 드리프트 3건 (quota-retry handover 누락 / 검토항목 7↔8 / 템플릿 종수) | `cmd_transition`에 `handover_required` 게이트 + quota-retry stub 자동생성, "8대"로 정합, "21종/16개"로 정합 | `47e55f5` |
| 9-5 A | 템플릿 heredoc → `templates/**` 실제 파일 | `emit_doc`이 파일 읽어 `@@…@@` 치환. 회귀: 산출물 byte-identical | `dd841f7` |
| 9-4 | 스킬 **9 → 6**, 8섹션 → 4섹션 | interview+reference→`harness-spec`, verify→`harness-work`, status 삭제. 스킬 595줄→201줄 | `8501993` |
| 9-2 | Context Packet 내부 중복 제거 | Task YAML 재추출 3블록 삭제, 미사용 `_runtime_yaml_block` 제거 | `8501993` |
| 9-12 | `harness.sh` 로직부 → `lib/*.sh` 13개 분할 (런타임 source) | `harness.sh` 2,789줄 → 27줄 런처. 회귀: 이어붙이면 분할 전과 byte-identical | `6ee5f40` |
| 마이그레이션 | `sync-templates`에 통합·삭제 스킬 정리(제거 + 매핑 안내) | `--apply` 시 옛 스킬 dir·링크 제거하고 매핑표 출력 | `8501993` |

**최종 형태**
- `harness.sh` 27줄 런처 + `lib/` 13개(평균 ~200줄) + `templates/` 21개 파일
- 생성 프로젝트: 스킬 6개(spec/plan/orchestrate/work/review/handover), 각 4섹션
- `bash harness.sh test` 18 PASS, 샌드박스 install→실행→validate→test→uninstall 통과

**기존 프로젝트 적용 완료**
- `002.tube_index/harness-refactor` → 커밋 `ad2fee3` (9스킬 → 6스킬, validate 통과)
- `002.tube_index/harness-ui-audit` → 커밋 `62cd9ad` (동일). 진행 중이던
  `task-overview-cross-domain`(CHANGES_REQUESTED)은 불변
- `lib/` 분할은 `templates/`를 안 건드리므로 두 프로젝트 재sync 불필요(dry-run 변경 0)

**안 한 것 (결정에 따름)**
- 9-5 B안(`src/*.sh` concat 빌드) — 런타임 source로 대체(9-12). `install.sh`가 이미
  `templates/`를 복사하므로 `lib/` 추가는 대칭이라 빌드 스텝 불필요
- `curl .../harness.sh` 단일 파일 배포 여지는 포기(README는 git clone)

아래 9-0 ~ 9-12는 검토 당시 원본 기록이며 진단 근거로 보존한다.

---

### 9-0. 결론

문제는 "도구 개수"가 아니다 — 이 repo는 **MCP 서버를 0개 추가**하고, 생성되는
스킬은 역할별 lazy-load라 한 턴에 다 열리지 않는다. 실제 병목은 **생성 스킬
문서의 의례적 비대함 + 같은 내용의 중복 컨텍스트 적재 + 동일 사실의 문서 간
드리프트**다. 3자 모두 이 진단에 동의했다.

### 9-1. [재현됨] 스킬 8섹션 템플릿의 자기 반복

생성 스킬은 총 586줄(`init` 샘플 실측), 9개가 전부 동일한
`사전조건 / 읽을파일 목록 / 절차 / 중단조건 / 산출물 / 결과계약 / 사후조건
체크리스트 / 멱등성` 8섹션 구조다. `harness-work` 한 파일에서
"submitted 제안"이 절차 8단계·6장 결과계약·7장 체크리스트에 3회,
"diff stat"도 3회 등장한다(`harness.sh:446` 이하). 저장소 전체에서
`결과 계약`·`사후조건 체크리스트`·`멱등성 규칙`·`읽어야 할 파일 목록`
헤더가 36회 반복된다.

### 9-2. [재현됨] Context Packet ↔ 스킬 정독목록 2중 적재 + Packet 내부 중복

`_runtime_context_packet`(`harness.sh:2484`)이 dispatch 시 주입하는 내용:

- SPEC 1·3·4·5·6절 발췌 → `harness-work` "읽을 파일" 5번이 `SPEC.md` 원본을 **재독** 지시
- task YAML **전문** 삽입 → 같은 YAML에서 `write_scope`·`resources/inputs`·
  `acceptance_criteria`를 **다시 추출**해 덧붙임(`harness.sh:2502~2510`) →
  그 뒤 `harness-work` "읽을 파일" 3번이 task YAML 원본을 **또** 정독 지시

즉 SPEC은 2회, task는 3회 컨텍스트에 적재된다.

### 9-3. [재현됨] 동일 사실의 문서 간 드리프트 — 3건

같은 숫자·목록이 역할문서·스킬·정책 YAML·README·test 문자열에 복붙돼 있어
한쪽만 갱신되면 갈라진다:

1. **검토 항목 7 vs 8.** `review-policy.yaml`은 8개(`intent_alignment` 포함,
   `harness.sh:1253~1261`), `harness-review` 스킬도 "8대"인데
   `reviewer.agent.md`는 "7대 핵심 항목"(`harness.sh:919, 924`),
   `harness-orchestrate`도 "7대 정책 기준"(`harness.sh:399`).
2. **템플릿 종수 20 vs 21.** `README.md:268` "20종 템플릿",
   `cmd_test`는 "21종" 출력(`harness.sh:3565`).
3. **quota-retry의 handover 누락.** `quota-policy.yaml`에 `require_handover: true`
   (`harness.sh:1531`)이고 `harness-handover` 스킬은 handover 문서 작성을
   요구하지만, `cmd_quota_retry`는 `cmd_close_agent --force` 직후
   `--note`만 달아 `handover_required`로 전이한다(`harness.sh:2967, 2978`).
   `cmd_transition`에 `handover_required` 진입 게이트가 없어(`harness.sh:2124~2166`)
   **다음 작업자에게 넘길 문맥 없이 원작업자가 종료될 수 있다.**
   → 스킬 정리보다 **먼저** 고칠 것(Codex 권고).

### 9-4. 감량안 (합의)

| 항목 | 결론 |
|---|---|
| 스킬 개수 | **9 → 6.** `interview`+`reference`→`harness-spec`, `work`+`verify`→`harness-work`, `status` 삭제(→`orchestrator.agent.md` 한 줄로 흡수). `plan`·`orchestrate`·`review` 유지. **`handover`는 유지** — AGY는 5개안(work에 흡수)을 냈으나 Codex 반대를 채택: handover는 쿼터소진·프로세스종료·반복실패 때만 쓰는 예외 프로토콜이라, work에 합치면 모든 Worker가 매번 장애분류·Provider교체 규칙까지 읽는다. 20~30줄짜리 예외 스킬로 축약하고, 상세 필드는 `.harness/handovers/TEMPLATE.md`에 둔다. `harness-work`에는 "이 조건이면 멈추고 handover로 전환"이라는 짧은 라우팅 표만 남긴다. |
| 스킬 템플릿 | **8섹션 → 4섹션**: ① 적용조건·입력 ② 정상 절차(+호출할 `herdr-harness` CLI) ③ 예외·중단 게이트 ④ 산출물·불변식. `결과계약`·`사후조건 체크리스트`·`멱등성 규칙` 삭제, 필요한 한 줄만 절차 안으로. 파일당 분량 60%+ 감소 예상. |
| 정독 목록 | Context Packet에 실린 SPEC 발췌·task YAML은 목록에서 제거. **남길 것**: Task Intent 문서, 이전 Attempt/Review, 역할문서의 권한·금지, (Reviewer 한정) 최신 Evidence·Diff. |
| Context Packet | task 전문 1회만. 뒤의 필드 재추출 3블록 제거. 장기적으로 Worker용/Reviewer용 Packet 분리. |
| 문서 정본화 | 각 사실은 **정본 1곳 + 나머지는 참조**. 역할문서는 권한·금지만, 스킬은 절차만, 정책 YAML은 기계적 설정값만. |
| 목표 지표 | "스킬 개수"가 아니라 **한 번의 dispatch에서 실제로 읽히는 지침량과 중복률**. 대형 스킬 5개가 소형 9개보다 반드시 가볍지는 않다(Codex). |

### 9-5. harness.sh(3798줄) 분할

- **1순위 (단독 -1,200줄):** `write_project_docs` 한 함수가 1,099줄(`harness.sh:146`),
  대부분 SKILL/role/policy heredoc이다. 파일이 안 읽히는 건 로직이 아니라 이
  덩어리 때문. → `templates/skills/harness-work/SKILL.md` 같은 **실제 파일**로
  옮기고 `emit_doc`이 읽어서 `@@WORKER@@` 치환만. 템플릿이 마크다운
  하이라이팅·정상 diff·정상 blame 대상이 되고, `sync-templates`가
  heredoc 대조 → 파일 복사로 단순해진다. `install.sh`가 이미 `$INSTALL_DIR`로
  복사하므로 `templates/` 동봉은 작은 변경.
- **2순위 (나머지 ~2,600줄):** 런타임 `source lib/*.sh`는 **하지 않는다** —
  `install.sh:58`이 파일 1개만 복사·심링크하는데 다중 파일로 바꾸면
  설치·업데이트·제거가 다중 파일 트랜잭션이 되고 launcher↔lib 버전 불일치
  실패 모드가 생긴다. 대신 `src/*.sh` 모듈 → **결정적 concat** → 루트
  `harness.sh`를 생성물로 커밋. CI에서 `재빌드 후 git diff --exit-code -- harness.sh`.
  경계안(Codex): `10-core` / `20-generator` / `30-state` /
  `40-runtime-core` / `41-runtime-agent` / `42-runtime-policy` / `50-cli` /
  `90-selftest`. 잃는 것은 생성 파일의 git blame 유용성과 src↔배포본 줄번호
  대응뿐이며, 모듈 경계 주석 + 결정적 빌드로 완화.

### 9-6. 착수 전 확인할 사항 (미해소)

1. **제거되는 스킬의 마이그레이션.** 기존 생성 프로젝트(`tube-index-refactor`,
   `harness-ui-audit` 등)는 `harness-verify`·`harness-reference`·`harness-status`
   심볼릭 링크와 문서를 갖고 있다. `sync-templates`가 삭제된 스킬을 어떻게
   처리할지(제거 + AGENTS.md 안내, 또는 alias) 정해야 한다.
2. **Context Packet 재추출 블록 소비자 확인.** `dispatch`/`observe`/생성
   Agent 지침 중 `## Write scope` 등 개별 블록을 파싱하는 곳이 없는지 확인
   후 제거.
3. **역할 모델 유지 여부.** `interview`+`reference` 병합 시, 대형 기존
   코드베이스에서 "레퍼런스 인벤토리"를 Worker Task로 돌리던 경로가 있으면
   재검토.
4. **`cmd_test` 동반 수정.** 현재 "21종 템플릿"·스킬 개수·"플레이스홀더
   치환"·"공통 Skill과 Claude 연결" 검사가 구조 변경과 함께 깨진다. 감량과
   같은 커밋에서 회귀 테스트를 다시 써야 한다.
5. **드리프트 전수 스윕.** 9-3의 3건 외에 AGENTS.md·profiles·README에 같은
   패턴이 더 있는지 "정본 1곳" 원칙으로 훑는다.

### 9-7. 착수 가능 여부

- **바로 가능:** 9-3의 드리프트 3건은 독립적인 소규모 수정이다. 특히
  9-3-3(quota-retry handover 누락)을 먼저 처리한다 — `cmd_transition`에
  `handover_required` 진입 게이트(handover 파일 존재 확인) 추가 또는
  `cmd_quota_retry`가 최소 handover stub을 생성하도록.
- **설계 결정 후 가능:** 9-4·9-5의 구조 감량은 위 9-6의 5개 항목을 정하고
  `cmd_test`를 동반 수정해야 하는 설계 변경이다. "바로" 착수할 수는 없고
  SPEC 한 바퀴가 필요하다. 템플릿 파일 추출(9-5 1순위)을 첫 Task로,
  스킬 병합(9-4)을 두 번째 Task로 쪼개는 것을 권한다.

### 9-8. 결정 (2026-09-06)

사용자가 9-6의 열린 항목을 결정했다. 9-6-2는 검토로 해소(패킷은
`herdr agent prompt "$agent" "$(cat "$context")"`로 통째 전달되는 산문이고
`## Write scope` 등 개별 블록을 파싱하는 코드는 없음 — `harness.sh:2657` 확인.
재추출 3블록 제거는 안전).

| # | 결정 | 내용 |
|---|---|---|
| 스킬 개수 | **9 → 6** (Codex안) | `verify` → `work` 흡수, `reference` → `interview`(→`harness-spec`) 흡수, `status` 삭제(→`orchestrator.agent.md` 한 줄). `plan`·`orchestrate`·`review` 유지. **`handover`는 20~30줄 예외 스킬로 축약해 유지** — 상세 필드는 `.harness/handovers/TEMPLATE.md`, `harness-work`에는 "이 조건이면 handover로 전환" 라우팅 표만. |
| 마이그레이션 | **제거 + 매핑 안내** | `sync-templates --apply`가 삭제 스킬 디렉터리·`.claude/skills/` 링크를 제거하고, 출력과 `AGENTS.md`에 `harness-verify → harness-work` 식 매핑표를 남긴다. |
| harness.sh 분할 | **템플릿 파일 추출만** (9-5 A안) | heredoc → `templates/**` 실제 파일 + `emit_doc` 읽어서 `@@…@@` 치환. `src/*.sh` concat 빌드(9-5 B안)는 하지 않는다. |
| 순서 | **드리프트 먼저, 감량 별도** | 9-3 3건을 독립 커밋(9-3-3 우선). 9-4·9-5는 별도 SPEC/Task. |

미결(감량 SPEC에서 다룸): 8섹션 → 4섹션 축소는 AGY·Codex가 수렴했고 9→6
방향에 포함되나, 최종 4섹션 규격과 "완료/차단 1줄 상태 신호 유지"(Codex
caveat) 여부는 감량 SPEC에서 확정. 9-6-1(제거 스킬 마이그레이션 세부),
9-6-3(interview+reference 역할 모델), 9-6-4(`cmd_test` 재작성),
9-6-5(드리프트 전수 스윕)도 그 SPEC 범위.

### 9-9. 드리프트 3건 수정 계획 (9-3 · 독립 커밋)

1. **9-3-3 quota-retry handover 누락** — `cmd_transition`의 전이별 필수조건
   `case`(`harness.sh:2124`)에 `handover_required)` 분기를 추가해
   `.harness/handovers/${task_id}-handover-*.md` 존재를 요구한다(harness-handover
   §3이 이미 "문서 작성 후 전이"를 규정하므로 문서 순서를 어기지 않고 강제하는
   것). 이어 `cmd_quota_retry`(`harness.sh:2978` 직전)가 `cmd_transition …
   handover_required` 호출 전에 handover stub을 생성하도록 한다 — 사유
   `quota_exhausted`, `current → next` provider, `git diff --stat`,
   다음 한 단계("사람이 `${task_id}-failover-approval.md` 승인 후
   `transition … ready`"). `cmd_test`에 회귀(handover 파일 없이
   `→ handover_required` 거부, quota-retry 후 stub 존재) 추가.
2. **9-3-1 검토 항목 7 ↔ 8** — `reviewer.agent.md`(`harness.sh:919, 924`)와
   `harness-orchestrate`(`harness.sh:399`)의 "7대"를 "8대"로 고치고
   `intent_alignment`를 목록에 추가. 정본은 `review-policy.yaml`의 `focus`
   (8개)임을 주석으로 명시.
3. **9-3-2 템플릿 종수 20 ↔ 21** — `README.md:268`을 "21종"으로. `init` 샘플
   실측치(생성 파일 47개)와 함께 확인.

**처리 완료 (2026-09-06, 브랜치 `fix/drift-9-3`).**

- **9-3-3**: `cmd_transition`에 `handover_required)` 게이트 추가 —
  `.harness/handovers/${task_id}-handover-*.md` 존재를 요구(harness-handover
  §3의 "문서 작성 → 전이" 순서를 강제). `cmd_quota_retry`가 `_runtime_set_task_provider`
  직후·`transition` 직전에 handover stub(메타데이터 + `git status`/`diff --stat`
  + Next Single Action)을 생성하도록 추가. `cmd_test`에 전이 게이트 2케이스
  (문서 없음 거부 / 문서 있음 통과)와 구조 불변식(stub 생성이 전이보다
  선행) 추가. `ARCHITECTURE.md §5·§8.1·§13`, `README.md` quota-retry 항목
  갱신.
- **9-3-1**: `reviewer.agent.md`·`harness-orchestrate`의 "7대" → "8대"
  (`review-policy.yaml`의 `focus` 8개가 정본임을 명시, `immediate_rejection`
  2개도 역할문서에 추가).
- **9-3-2**: `README.md`·`harness.sh` test 문자열 "20종"·"14개 케이스" →
  "21종"·"16개 케이스"로 정합.
- `bash harness.sh test` 17개 PASS 재확인.

9-4(스킬 9→6, 8→4 섹션)는 별도 SPEC로 미착수 유지.

### 9-10. Task A — 템플릿 파일 추출 완료 (2026-09-06, 브랜치 `fix/drift-9-3`)

9-5 A안을 실행했다. `harness.sh`의 `emit_doc`가 heredoc 대신 `templates/`
디렉터리의 실제 파일을 읽어 `@@…@@`만 치환하도록 바꿨다.

- `templates/` 신설 — `write_project_docs`·`write_project_templates`의 heredoc
  24개(skill 9·role 6·`.harness/**/TEMPLATE.*` 8·`review-policy.yaml`)를
  같은 상대경로의 파일로 추출. 두 함수는 `HARNESS_DOC_TEMPLATES`/
  `HARNESS_POLICY_TEMPLATES` 배열을 도는 루프로 축소.
- `HARNESS_TEMPLATE_DIR` 해석: `readlink -f "${BASH_SOURCE[0]}"`로 심볼릭 링크
  (`~/.local/bin/herdr-harness` → `$INSTALL_DIR/harness.sh`)를 풀어 그 옆
  `templates/`를 가리킨다. `HARNESS_TEMPLATE_DIR` 환경변수로 override 가능.
- `install.sh`: `cp -R templates/ $INSTALL_DIR/templates/` 추가,
  `--uninstall`·`cmd_uninstall`도 `templates/` 제거.
- `cmd_test`: 배열 ↔ `templates/` 파일 양방향 정합 검사 추가(누락·orphan 모두
  die). PASS 18개.
- **회귀 검증:** 추출 전 `HEAD:harness.sh`와 추출 후로 각각 프로젝트를 생성해
  `diff -r` — `HARNESS_START.md`의 프로젝트 자기 경로(`cd "..."`) 한 줄 외
  전부 byte-identical. 심볼릭 링크 실행·`install.sh` 전체 설치/제거도
  샌드박스에서 확인.
- `harness.sh` 3862줄 → 2760줄 (-1102, -29%).

`src/*.sh` concat 빌드(9-5 B안)는 결정대로 안 함.

### 9-11. Task B·C — 스킬 9→6, 8→4 섹션, Context Packet 중복 제거 완료 (2026-09-06, 브랜치 `fix/drift-9-3`)

결정(9-8): 스킬 9→6, 8섹션→4섹션, 상태 신호 1줄 유지, `harness-spec` 신설,
마이그레이션 "제거 + 매핑 안내".

**스킬 9 → 6** (`templates/.agents/skills/`)
- `harness-interview` + `harness-reference` → **`harness-spec`** (자산 조사 +
  인터뷰). 역할은 `interviewer.agent.md` 유지.
- `harness-verify` → **`harness-work`** §2 (AC 검증·Evidence를 정상 절차에 흡수).
- `harness-status` → 삭제. `herdr-harness status --live .` +
  `orchestrator.agent.md`에 진행 보고 지침 추가.
- `harness-plan`·`harness-orchestrate`·`harness-review` 유지, `harness-handover`는
  예외 프로토콜로 축약 유지.

**8섹션 → 4섹션**: `적용조건·입력 / 절차 / 예외·중단 게이트 / 산출물·불변식`.
`결과계약`·`사후조건 체크리스트`·`멱등성 규칙` 삭제, 절차 마지막에
`결과: SUCCESS|BLOCKED, ...` 한 줄만. 절차 안에 호출할 `herdr-harness` 명령
직접 명시. 스킬 총 595줄 → 201줄.

**Task C — Context Packet 중복 제거** (`_runtime_context_packet`)
- Task Contract 전문 뒤에 있던 `## Write scope`·`## References and inputs`·
  `## Verification commands and criteria` 재추출 3블록 삭제(전부 Task YAML 안에
  이미 있음 — 소비자 없음 확인). intent.md 경로 한 줄로 대체. 미사용이 된
  `_runtime_yaml_block` 함수 제거.
- 새 스킬의 "읽을 것"은 Context Packet에 없는 것만 — intent.md, 수정 대상
  소스, 이전 Attempt/Review.

**마이그레이션**: `cmd_sync_templates`에 통합·삭제 스킬 처리 추가 —
`--apply` 시 옛 `.agents/skills/<old>/`와 `.claude/skills/<old>` 링크를 제거하고
매핑표(`harness-verify → harness-work §2` 등)를 출력. `AGENTS.md`는 자동 갱신
안 하고 안내만. f3c3866(9스킬) 생성 프로젝트에 실제 적용해 6스킬로 정리 확인.

**harness.sh·docs**: `HARNESS_DOC_TEMPLATES`·`cmd_test` required 목록·
`HARNESS_START.md`·`ARCHITECTURE.md §1·§6·§7`·`README.md` 갱신. `bash harness.sh
test` 18 PASS, `init` 샘플 생성·`validate` 통과 확인.

### 9-12. harness.sh 로직부 lib/ 분할 (2026-09-06, 브랜치 `fix/drift-9-3`)

9-5에서 A안(템플릿 추출만)을 골랐지만 이후 사용자가 로직부도 기능 단위로
쪼개길 원해 **런타임 source 방식**으로 진행했다(9-5 B안의 concat 빌드는 아님).
`install.sh`가 이미 `templates/`를 복사하므로 `lib/` 추가 복사는 대칭이라
"설치가 다중 파일이 된다"는 원래 반대 근거가 약해졌다.

- `harness.sh` 2,789줄 → **27줄 런처**. `readlink -f`로 실제 위치를 풀어
  `$HARNESS_LIB_DIR/*.sh`(파일명 숫자 접두사 순)를 source하고 `main "$@"` 호출.
  `HARNESS_LIB_DIR`·`HARNESS_TEMPLATE_DIR` 환경변수로 override 가능.
- `lib/` 13개 (평균 ~200줄): `10-lib` / `20-generate` / `30-yaml` / `35-git` /
  `40-transition` / `50-runtime` / `55-dispatch` / `60-automation` / `70-status` /
  `80-selftest` / `85-completion` / `90-uninstall` / `99-main`.
- **회귀 검증**: `header(1-13) + lib/*.sh(주석 헤더 제거) + 'main "$@"'`를 이어붙이면
  분할 전 `harness.sh`와 byte-identical(diff 0). 분할 전/후 `init` 산출물도
  자기 경로 한 줄 외 동일.
- `install.sh`: `lib/` 존재 확인 + 각 `lib/*.sh` `bash -n` + `cp -R lib/`.
  uninstall 두 경로 모두 `lib/` 제거.
- `cmd_test`: 모든 `lib/*.sh` `bash -n` 추가, auto-step/quota-retry 안전 불변식
  스캔 대상을 `$SELF_PATH` → `$HARNESS_LIB_DIR/60-automation.sh`로 변경.
- 샌드박스 install → 심볼릭 링크 실행 → `validate` → `test`(18 PASS) → uninstall 통과.

빌드 스텝·CI diff 검사·생성물 커밋 없음. 잃는 것: `curl .../harness.sh` 단일 파일
배포 여지(README는 git clone이라 무관).

---

## 10. 2026-09-09~10 후속 — 문서 반영 완료 항목

9-★(2026-09-06) 이후 추가된 기능과, 그것이 반영된 문서 위치를 남긴다.
BACKLOG의 미결 항목은 아니며 기록용이다.

| 기능 | 커밋 | 문서 |
|---|---|---|
| 원격 실행 모드(`remote`, `remote setup`) | `902eb5a`·`f9a15a5` | README `## 원격 실행 모드`, ARCHITECTURE §11.1 |
| Bash 탭 완성(설명 포함) + `help <명령>` | `a9bfecb`·`9590926`·`c6ee9c6`·`799482e` | README `### 8-1`, `## 명령 사용법 찾기` |
| Agent 승인 정책(`agent-policy.yaml`, `init --approval-mode`) | `aa99b21` | README `### Agent 승인 정책`, ARCHITECTURE §7.1·§12 |
| dispatch 폴백(`--print-only` + `adopt`) | `aa99b21` | README `### Agent를 어떻게 띄우는가`, ARCHITECTURE §7.1 |
| 호출자 게이트(Agent Pane의 `transition`/`approve` 거부) | `aa99b21` | README `## 운영 원칙`, ARCHITECTURE §12 |
| Acceptance Criteria 게이트(Harness 직접 실행) | `4bfb871` | README `### Acceptance Criteria 게이트`, ARCHITECTURE §5.1 |
| Evidence 정본 YAML ↔ `raw/` 분리 | `4bfb871` | README `### Evidence 구조`, ARCHITECTURE §5.2 |
| Context Packet 직전 라운드 주입 | `4bfb871` | README `### Context Packet에 직전 라운드가 들어간다`, ARCHITECTURE §9 |

`bash harness.sh test` 26 PASS 기준이다(항목 6의 "12개 PASS", 9-12의 "18 PASS"는
그 시점 기록이다).

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

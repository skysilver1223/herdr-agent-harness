# Backlog — Agent Loop 도입 후 남은 작업

브랜치 `feat/agent-loop-harness` 작업에서 확인됐으나 처리하지 않은 항목이다.
Claude(통합·상태머신), Codex(런타임), AGY(Skill·문서 → 독립 리뷰) 세 Pane으로 진행했고,
아래 1~5는 AGY의 독립 리뷰에서 나온 것이다.

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

---

## 3. [MED · 미재현] stderr 혼입 시 JSON 파싱 전면 실패

herdr 호출을 전부 `2>&1`로 캡처한다. CLI나 터미널 환경이 경고 한 줄이라도 stderr에 쓰면
입력이 순수 JSON이 아니게 되어 `pane_id` 추출이 빈 값이 되고,
`[[ -n "$pane_id" ]] || die` 에서 dispatch가 중단된다.

현재 환경에서는 herdr가 stderr를 쓰지 않아 재현되지 않았다. 다만 방어는 값싸다.

수정 위치: `harness.sh` · `_runtime_json_field` 및 herdr 호출부.
파서에 넘기기 전 첫 `{`부터 마지막 `}`까지만 잘라낸다.

---

## 4. [LOW] mktemp 임시 파일 trap cleanup 부재

`set -e` 중간 실패나 SIGINT 시 임시 파일이 삭제되지 않고 누적된다.
`.harness/runtime/`과 `.harness/evidence/`에 `.tasks.XXXXXX`, `.anomalies.XXXXXX`,
`.harness-transition.XXXXXX`, `.capture.XXXXXX` 등이 남는다.

수정 위치: `cmd_transition`, `cmd_status_live`, `_runtime_append_evidence`,
`_runtime_context_packet`. 함수 진입 시 `trap 'rm -f ...' RETURN` 등록.

---

## 5. [LOW] Context Packet의 SPEC 200줄 하드코딩 잘림

`_runtime_context_packet`이 `sed -n '1,200p' .harness/SPEC.md` 로 자른다.
SPEC이 200줄을 넘으면 Acceptance Criteria나 제약이 Worker·Reviewer에게 전달되지 않는다.

줄 수 자르기 대신 섹션 헤더 기반 발췌가 맞다.

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

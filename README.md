# Herdr Agent Harness

Claude, Codex, AGY를 Herdr에서 역할과 Skill 기반으로 운영하기 위한 Ubuntu·WSL용 프로젝트 생성 도구입니다.

저장소 구성:

```text
install.sh       # 최초 설치
harness.sh       # 얇은 런처 — lib/*.sh 를 source하고 main 호출
lib/             # 기능 단위로 나뉜 실제 로직 (10-lib, 20-generate, 40-transition, 50-runtime, …)
templates/       # init·sync-templates가 프로젝트로 복사하는 skill·role·정책 템플릿 정본
README.md        # 사용법
ARCHITECTURE.md  # 운영 구조
```

`harness.sh`는 자기 옆 `lib/*.sh`(파일명 숫자 접두사 순서)를 source하고, 프로젝트 생성 시 `templates/`에서 파일을 읽어 `@@…@@` 플레이스홀더만 치환해 복사합니다. `install.sh`가 `harness.sh`와 함께 `lib/`·`templates/`를 `~/.local/share/herdr-agent-harness/`로 복사합니다. 로직을 고칠 때는 해당 `lib/*.sh`를 편집하면 되고(빌드 스텝 없음), `HARNESS_LIB_DIR`·`HARNESS_TEMPLATE_DIR` 환경변수로 위치를 덮어쓸 수 있습니다.

`LICENSE`는 공개 배포를 위한 기존 MIT 라이선스입니다.

## 지원 환경

- Ubuntu 22.04 이상
- Windows 11의 WSL2 Ubuntu
- Bash 4 이상
- Git
- Herdr
- Claude Code, Codex CLI, Antigravity CLI 중 하나 이상

WSL2에서는 프로젝트와 Harness 저장소를 `/mnt/c`보다 Ubuntu Home 아래에 두는 것을 권장합니다.

```text
~/herdr-agent-harness
~/Projects/my-project
```

파일 권한, Git, Symbolic Link와 실행 성능 문제를 줄일 수 있습니다.

## 전체 설치 과정

### 1. Ubuntu 기본 패키지 설치

```bash
sudo apt update
sudo apt install -y \
  git curl jq \
  python3 python3-pip \
  nodejs npm
```

확인:

```bash
git --version
python3 --version
node --version
npm --version
```

### 2. Agent CLI 확인

사용할 Agent CLI가 설치되어 있는지 확인합니다.

```bash
claude --version
codex --version
agy --version
```

세 개를 모두 사용할 필요는 없지만, 기본 구성은 다음 역할을 사용합니다.

| Provider | 기본 역할 |
|---|---|
| Claude | Orchestrator |
| Codex | Primary Worker |
| AGY | Reviewer |

설치되지 않은 Agent를 사용하려면 해당 제품의 공식 설치 절차로 먼저 CLI를 설치하고 로그인해야 합니다. API Key나 로그인 정보는 이 저장소에 기록하지 않습니다.

### 3. Herdr 설치 또는 업데이트

신규 설치:

```bash
curl -fsSL https://herdr.dev/install.sh | sh
exec "$SHELL" -l
```

확인:

```bash
herdr --version
```

인스톨러로 설치한 기존 Herdr를 업데이트하려면:

```bash
herdr update
herdr --version
```

공식 문서: [Herdr Installation](https://herdr.dev/docs/install/)

### 4. Herdr Integration 설치

각 Provider의 상태와 재개 가능한 Session을 Herdr가 인식하도록 Integration을 설치합니다.

```bash
mkdir -p ~/.claude ~/.codex ~/.gemini/config

herdr integration install claude
herdr integration install codex
herdr integration install antigravity-cli
```

확인:

```bash
herdr integration status
```

사용하지 않는 Provider의 Integration은 생략할 수 있습니다. AGY의 Integration 설치 이름은 `agy`가 아니라 `antigravity-cli`입니다.

공식 문서: [Herdr Integrations](https://herdr.dev/docs/integrations/)

### 5. Harness 저장소 내려받기

```bash
cd ~

git clone \
  https://github.com/skysilver1223/herdr-agent-harness.git \
  ~/herdr-agent-harness

cd ~/herdr-agent-harness
```

이미 내려받았다면:

```bash
cd ~/herdr-agent-harness
git pull --ff-only
```

### 6. 실행 권한 부여

GitHub 웹에서 Shell Script를 업로드하면 실행 권한이 보존되지 않을 수 있습니다.

```bash
chmod +x install.sh harness.sh
```

확인:

```bash
stat -c '%A %a %n' install.sh harness.sh
```

기대값:

```text
-rwxr-xr-x 755 install.sh
-rwxr-xr-x 755 harness.sh
```

### 7. Harness와 공식 Herdr Skill 설치

```bash
./install.sh --with-herdr-skill
```

다음 위치에 명령이 설치됩니다.

```text
~/.local/bin/herdr-harness
```

Harness만 설치하고 Herdr Skill은 나중에 설치하려면:

```bash
./install.sh
```

공식 Herdr Skill을 별도로 설치하는 명령:

```bash
npx skills add herdrdev/herdr --skill herdr -g
```

설치된 Herdr 버전에 포함된 Skill 내용을 확인하려면:

```bash
herdr --skill
```

공식 문서: [Herdr Agent Skill](https://herdr.dev/docs/agent-skill/)

### 8. PATH 설정

다음 명령이 바로 실행되면 별도 설정이 필요 없습니다.

```bash
herdr-harness --help
```

`command not found`가 발생하면 `~/.local/bin`을 PATH에 추가합니다.

```bash
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc ||
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

source ~/.bashrc
```

확인:

```bash
command -v herdr-harness
```

기대 경로:

```text
/home/<사용자명>/.local/bin/herdr-harness
```

### 8-1. 탭 완성 (Bash)

`./install.sh`는 다음 관리 블록을 `~/.bashrc`에 한 번만 자동 등록합니다. 반복
설치해도 중복되지 않고, 기존 `~/.bashrc` 내용은 재정렬·정규화하지 않습니다.

```bash
# >>> herdr-harness bash completion >>>
source <(herdr-harness completion bash)
# <<< herdr-harness bash completion <<<
```

설치기는 자식 프로세스라서 이미 실행 중인 셸에는 즉시 반영할 수 없습니다. 새
터미널을 열거나 다음을 실행해야 이번 세션에도 적용됩니다.

```bash
source ~/.bashrc
```

확인:

```bash
herdr-harness <TAB><TAB>
```

```text
init             : 새 프로젝트에 Harness 문서·정책·역할 파일 생성
sync-templates   : Skill·역할·정책 템플릿을 지금 버전으로 재동기화
models           : 적용 가능 모델과 허용·프리미엄 정책 조회·갱신
start            : 프로젝트 디렉터리에서 Herdr Session 열기
status           : STATE.md 출력 (--live로 문서·Herdr·Git 대조)
validate         : 상태를 바꾸지 않고 정합성만 검사
transition       : Task 상태를 전이표에 따라 전이
...
remote           : 원격 서버에서 빌드·테스트·VCS 실행 (opt-in)
help             : 명령 목록 또는 특정 명령 상세 사용법
```

후보가 여럿일 때는 `명령 : 설명` 형태로 함께 나오고, 후보가 하나로 좁혀지면 설명 없이
명령만 입력됩니다. TAB을 `menu-complete`에 바인딩해 두었다면(그 경우 후보 문자열이 그대로
입력되므로) 설명을 자동으로 끄고 명령만 돌려줍니다. 항상 끄고 싶으면
`export HERDR_HARNESS_COMPLETION_DESCRIPTIONS=0`. `herdr-harness remote <TAB><TAB>`도 하위 명령마다 설명을 보여 줍니다.

```text
$ herdr-harness remote <TAB><TAB>
setup            : 최초 1회 설정 — 호스트·계정 입력 + SSH 키 등록
doctor           : 의존성·SSH·원격 경로·도구·마운트 일괄 진단
status           : 현재 원격 설정과 연결·마운트 상태 요약
mount            : 원격 소스를 로컬 경로에 SSHFS로 붙임
run              : 원격 프로젝트 디렉터리에서 명령 실행 (빌드·테스트)
...
```

서브커맨드뿐 아니라 `init --profile`·`--orchestrator` 등의 옵션 값, `transition`의
Task ID·상태, `approve`의 Task ID·확인 플래그, `dispatch`·`quota-check`의 Task
ID·`worker`/`reviewer`, `remote setup`의 옵션도 완성됩니다.
Bash만 지원합니다.

자동 등록을 원하지 않으면 위 3줄을 지우면 되고, 직접 관리하고 싶으면 마커 없이
`source <(herdr-harness completion bash)` 한 줄만 두어도 설치기가 중복 등록하지
않습니다. 다만 마커 없는 줄은 제거 시 그대로 남습니다(사용자 설정으로 취급).

### 9. 설치 진단

```bash
herdr-harness doctor
```

`doctor`는 다음을 확인합니다.

- Herdr
- Git
- Claude Code
- Codex CLI
- Antigravity CLI
- Herdr Integration 상태

Herdr와 Git은 필수입니다. 설치하지 않은 선택 Provider는 `MISSING`으로 표시될 수 있습니다.

### 10. 쿼터 없는 자체 테스트

```bash
herdr-harness test
```

기대 결과:

```text
PASS: Bash 문법
PASS: Harness 파일 생성 (22종 템플릿, templates/ 파일 정본)
PASS: 템플릿 배열 ↔ templates/ 파일 정합
PASS: 공통 Skill과 Claude 연결
PASS: 플레이스홀더 치환
PASS: Git 기준선 생성
PASS: 신규 프로젝트 보호
PASS: 비대화형 명시적 실패
PASS: 상태 전이표 강제 (16개 케이스, handover_required 인계문서 게이트 포함)
PASS: Context Packet 직전 라운드 주입 (Evidence·AC 결과·Review 판정, 첫 시도엔 미주입)
PASS: dispatch 추가 지시(--extra-prompt 주입·순서·Secret 차단)와 안전한 프롬프트 재시도 판정
PASS: Agent 상태 정규화
PASS: Secret 스캐너 경계 (task-* 식별자 오탐 없음, 실제 키 접두사·Authorization 탐지)
PASS: Acceptance Criteria 게이트 (명령 직접 실행/실패 거부/알 수 없는 type·빈 목록 거부/manual-review 기록)
PASS: 명시 승인 approve (정상/멱등/무확인/상태/Review/Task ID/충돌 거부)
PASS: 이벤트 로그 기록
PASS: validate 검증 (정상/Worker=Reviewer/Git 누락)
PASS: 스텝 명령 인자 검증 (adopt 인자, --print-only 무상태·셸 인용, adopt Pane close 보호)
PASS: dispatch --cwd (기본 워크스페이스/지정 반영/없는 경로·무값 거부/셸 인용, 옵션↔help↔탭완성 정합)
PASS: 모델 선택 (역할별 Task 지정/정책·Provider 기본값/허용 목록·플래그 주입 거부/Secret 비노출/기록)
PASS: 프리미엄 모델 승인 (정확 범위/불일치·재사용·Agent Pane 거부/강등·누출 차단/fail-open·argv 주입 차단/기록)
PASS: models 명령 (dry-run/apply·전체 refresh·실패 보존·프리미엄 set/비우기/정확 일치·멱등·구버전 정책·사용자 값 보존)
PASS: 호출자 게이트 (Agent Pane의 transition·approve 거부, 사람 Pane 비침범)
PASS: Agent 호출 없음
PASS: 탭 완성 스크립트 문법
PASS: Agent 승인 정책 (기본 auto/인수표/ask 무인수/문자·플래그·값·모드별 권한상승 거부/반환값 실패/정책 없음/init 값)
PASS: 도움말 정합성 (dispatch↔help 요약·상세↔탭 완성 설명, 없는 명령 거부)
PASS: 원격 실행 모드 (opt-in 게이트/setup 생성·--force·비밀번호 미저장/하위 명령 오타 거부/SSH 옵션·경로 인젝션 차단/YAML 주석·중복 키)
PASS: Task Lock (동시 획득 거부/release/stale 회수)
PASS: quota-retry/auto-step opt-in 게이트
PASS: quota-retry/auto-step 안전 불변식(completed/reviewing/awaiting_approval/ready 미호출, handover stub 선행)
PASS: sync-templates (dry-run/apply·멱등, agent-policy 모델·프리미엄 키 전파·사용자 값 보존, AGENTS.md/STATE.md 비침범, .gitignore 보충)
PASS: README 기대 출력 ↔ 실제 test 출력 정합
PASS: install.sh ~/.bashrc completion 등록(멱등·사용자 줄 보존·두 제거 경로·수동 줄 비침범)
```

이 테스트는 실제 Claude, Codex, AGY를 호출하지 않으므로 Agent 쿼터를 사용하지 않습니다.

## 빠른 설치 요약

이미 Herdr와 Agent CLI가 설치되어 있다면 다음 명령만 실행하면 됩니다.

```bash
git clone \
  https://github.com/skysilver1223/herdr-agent-harness.git \
  ~/herdr-agent-harness

cd ~/herdr-agent-harness
chmod +x install.sh harness.sh
./install.sh --with-herdr-skill

herdr-harness doctor
herdr-harness test
```

## 프로젝트 생성

### SNMP 정규화

```bash
herdr-harness init ~/Projects/snmp-normalizer \
  --name snmp-normalizer \
  --goal "멀티벤더 SNMP 데이터를 공통 스키마로 정규화" \
  --profile network-device \
  --orchestrator claude \
  --worker codex \
  --reviewer agy
```

### Python 시계열 분석

```bash
herdr-harness init ~/Projects/timeseries-inference \
  --name timeseries-inference \
  --goal "시계열 데이터를 분석하고 재현 가능한 추론기를 개발" \
  --profile python-timeseries
```

옵션을 생략하면 다음 기본값을 사용합니다.

| 항목 | 기본값 |
|---|---|
| Profile | `generic` |
| Orchestrator | `claude` |
| Worker | `codex` |
| Reviewer | `agy` |
| Fallback | `claude,agy` |
| Agent 승인 모드 | `auto` (`--approval-mode ask\|auto\|bypass`) |
| 활성 Task | 최대 5개 |
| 병렬 Worker | 최대 2개 |

스크립트는 신규·빈 디렉터리에서만 작동하며 기존 파일을 덮어쓰지 않습니다. 생성 후 `git init`과 Harness 파일 staging을 자동 수행합니다. Git 사용자 이름과 이메일이 설정되어 있으면 기준 commit도 생성합니다. 설정이 없어 commit을 만들지 못한 경우 안내된 `git commit`을 완료해야 Task를 `active`로 전이할 수 있습니다.

## 운영 시작

```bash
cd ~/Projects/snmp-normalizer
herdr-harness start .
```

Herdr 첫 Pane에서 설정된 Orchestrator를 실행합니다.

```bash
claude
```

다음 요청을 입력합니다.

```text
harness-spec Skill로 기존 코드·데이터·문서·Dump를 먼저 조사하고
요구사항을 인터뷰해서 SPEC 초안을 만들어줘.
SPEC 승인 전에는 구현하지 마. 이후 harness-plan, harness-orchestrate로 진행해줘.
```

## 상태 확인

```bash
herdr-harness status ~/Projects/snmp-normalizer
herdr-harness status ~/Projects/snmp-normalizer --live
herdr-harness status ~/Projects/snmp-normalizer --live --json
```

기본 상태 명령은 `STATE.md`를 출력합니다. `--live`는 문서 상태와 Herdr Agent, Git 상태를 함께 대조하여 `DRIFT`와 `ORPHAN`을 표시합니다. 상태를 자동 수정하지는 않습니다.

## 명령 사용법 찾기

명령이 많으므로 세 가지 경로로 안내를 제공합니다.

```bash
herdr-harness help                 # 전체 명령 목록 한 줄 설명
herdr-harness help remote          # 특정 명령의 목적·구문·예시·주의
herdr-harness <TAB><TAB>           # 설명이 붙은 후보 목록
herdr-harness remote help          # 원격 모드 하위 명령 목록
```

`help <명령>`은 그 명령이 무엇을 하는지, 어떤 인자를 받는지, 실제로 어떻게 치는지를
예시와 함께 보여 줍니다.

```text
$ herdr-harness help dispatch
dispatch — Task의 역할·모델 정책에 맞는 Agent를 Pane에서 한 턴 실행한다

구문:
  herdr-harness dispatch PATH TASK_ID ROLE [--timeout MS] [--print-only]
                        [--extra-prompt FILE] [--cwd DIR]

무엇을 하나:
  Task 계약·SPEC 발췌·intent를 Context Packet으로 묶어 Herdr Pane에서 Agent를
  한 턴 실행하고, 결과를 Evidence로 남긴다. 호출 1회 = 1턴이며 상주 루프가 아니다.

승인 정책:
  .harness/policies/agent-policy.yaml의 approval_mode(ask|auto|bypass)에 따라
  Provider CLI에 승인 우회 인수를 붙인다. 도구 실행 승인만 건너뛴다 — 상태
  전이와 완료 승인은 이 설정과 무관하게 transition/approve로만 가능하다.
  ...

모델 선택:
  Task의 worker_model/reviewer_model → agent-policy.yaml의 Provider 기본 모델 →
  Provider CLI 기본값 순서로 고른다. 프리미엄 목록이 있으면 Provider 기본값을
  쓰지 않고 비프리미엄 모델을 명시하며, 프리미엄 모델은 Task·역할·모델별
  사용자 승인 파일이 있어야 쓴다. 실제 모델·출처·승인 근거는 Attempt·Evidence에
  남긴다.

역할(ROLE): worker | reviewer

예시:
  herdr-harness dispatch . task-001 worker
  herdr-harness dispatch . task-001 reviewer --timeout 600000

--print-only:
  Pane을 만들지도 Agent를 띄우지도 않고, Context Packet 경로와 직접 실행할
  herdr 명령만 출력한다. ...
```

## Agent Loop 스텝 명령

Harness는 상주 Controller나 자율 반복 루프를 실행하지 않습니다. Bash 명령은 호출 한 번에 한 단계의 검증·실행·기록만 담당하고, Orchestrator Agent가 결과를 읽어 다음 단계를 선택합니다.

| 명령 | 책임 |
|---|---|
| `herdr-harness validate [PATH] [--wave ID] [--no-git]` | Git 기준선, Task/Wave, Provider, 의존성, 실행 상한과 write scope를 읽기 전용 검증 |
| `herdr-harness transition PATH TASK_ID TO_STATE [--note TEXT]` | 허용된 상태 전이와 필수 Attempt/Evidence/Review/승인 기록 강제. `submitted`로 갈 때는 Acceptance Criteria의 `verified_by` 명령을 직접 실행하고 하나라도 실패하면 거부 |
| `herdr-harness approve PATH TASK_ID --confirm-user-approval` | 사용자 명시 승인 확인 후 승인 증거를 원자적으로 기록하고 기존 `transition` 게이트로 `completed` 전이 |
| `herdr-harness dispatch PATH TASK_ID worker\|reviewer [--timeout MS] [--print-only] [--extra-prompt FILE] [--cwd DIR]` | 역할별 모델을 선택하고 프리미엄 승인·Provider 기본값 누출 차단을 적용한 뒤 Pane 생성, Agent 시작, Context Packet 1회 전송, 대기와 증적 기록. `--print-only`는 아무것도 띄우지 않고 실행할 `herdr` 명령만 출력 |
| `herdr-harness observe PATH TASK_ID [worker\|reviewer]` | 기존 Agent를 재조회하고 Evidence에 추가 |
| `herdr-harness adopt PATH TASK_ID worker\|reviewer --pane PANE --agent NAME [--provider P]` | 사람이 직접 띄운 Agent를 Harness 추적에 등록(`--print-only` 폴백의 마지막 단계) |
| `herdr-harness close-agent PATH TASK_ID [worker\|reviewer] [--force]` | Harness runtime에 등록된 Pane만 정리 |
| `herdr-harness status [PATH] --live [--json]` | 문서·Herdr·Git 실시간 상태 대조 |
| `herdr-harness quota-check PATH TASK_ID worker\|reviewer` | 실행 중인 Agent의 쿼터 확인(claude·codex는 `/status` 전송, agy는 `--print "/usage"`) |
| `herdr-harness quota-check PATH --provider agy` | Task 없이 agy 쿼터만 바로 확인 |
| `herdr-harness quota-retry PATH TASK_ID worker\|reviewer` | (opt-in) 연속 저쿼터 확인 시 Provider 교체를 `handover_required`까지 자동 처리 |
| `herdr-harness auto-step PATH TASK_ID [--max-turns N]` | (opt-in) 유한 턴 동안 dispatch 1회 + observe 반복 |

`dispatch`는 프롬프트 미전달로 확인된 경우의 1회 재전송 외에는 Task 재시도, 상태 전이, blocked 응답 또는 Provider failover를 수행하지 않습니다. Orchestrator는 반환된 `dispatch_result`를 확인한 뒤 사용자 승인 경계를 지키며 다음 스텝을 호출합니다.

`dispatch`가 `herdr agent get`의 상태를 정규화하는 표는 다음과 같습니다. `idle`과
`done`은 상태 이름만으로 성공 처리하지 않고, 프롬프트 직전과 이후의 `revision`·
`state_change_seq`가 하나라도 변했는지를 함께 확인합니다.

| Herdr `agent_status` | Harness 결과 | 의미 |
| --- | --- | --- |
| `working` | `running` | 정상 작업 중이며 장애가 아님 |
| `idle`, `done` + 활동 지표 변화 | `settled` | 프롬프트 처리 뒤 터미널 상태에 도달 |
| `idle`, `done` + 두 활동 지표 불변 | `prompt_not_delivered` | 프롬프트가 실제 처리되지 않은 것으로 판정 |
| `blocked` | `blocked` | 사용자 입력·승인 등으로 중단 |
| `unknown` | `unknown` | Herdr가 상태를 관측하지 못함 |
| 그 밖의 상태값 | `unknown` + 경고 | 새 값을 장애로 단정하지 않고 원래 값을 경고에 표시 |
| `agent get` 실패 | `agent_lost` | Agent 조회 자체가 실패 |

프롬프트 명령 자체의 기존 `stalled`·`timeout` 판정도 유지됩니다. Pane 생성이나 Agent
기동처럼 상태 조회 전 단계에서 실패한 경우에는 `error`가 반환될 수 있습니다.

`approve`는 사용자가 채팅에서 **현재 Task의 완료를 명시적으로 승인한 뒤** Orchestrator가
호출하는 기록 대행 명령입니다. `--confirm-user-approval`이 없거나 Task가
`awaiting_approval`이 아니거나 최신 Review가 `APPROVED`가 아니면 거부합니다. 기존 승인
파일과 Task/Review가 다르면 덮어쓰지 않으며, 성공한 명령을 같은 인자로 다시 호출하면
승인 파일을 바꾸지 않고 성공합니다. 사용자 발화나 승인 의도를 CLI가 추론하지는 않습니다.

```bash
herdr-harness approve ~/Projects/snmp-normalizer task-001 --confirm-user-approval
```

`quota-check`도 자동으로 아무것도 바꾸지 않습니다. claude·codex는 비대화형 조회 수단이 없어 실행 중인 Agent Pane에 `/status`를 보내고 그 출력에서 알려진 경고 문구("... N% of your weekly limit ..." 등)를 스캔합니다. agy는 `agy --print "/usage"`로 정확한 잔여 퍼센트를 바로 얻습니다. 판정 기준(`low`로 볼 임계값)은 `.harness/policies/quota-policy.yaml`의 `low_warning_threshold_pct`로 조정하며, `dispatch`·`observe`도 Agent 출력을 지나가는 김에 스캔해 Evidence에 참고용 경고를 남깁니다(`passive_scan_on_dispatch`).

### Agent를 어떻게 띄우는가 — `dispatch` 기본, `--print-only` + `adopt` 폴백

Agent 생성 방식은 두 가지가 가능합니다: Harness가 Pane 분할·Agent 실행·프롬프트까지 한 번에 하는 방식(A)과, 실행할 명령만 받아 사람이 직접 띄우는 방식(B).

**기본은 A(`dispatch`)입니다.** 취향 문제가 아니라 구조 때문입니다 — `transition`의 게이트가 Attempt·Evidence의 존재를 요구하도록 설계돼 있어서, Agent 생성을 사람 손에 넘기면 그 게이트가 통째로 헐거워집니다(문서는 `submitted`인데 실제로는 아무 근거도 남지 않는 상태). A에서만 다음이 성립합니다.

- `pane_id`·`agent_name`·baseline commit·승인 모드·실제 모델과 출처가 자동으로 Attempt/Evidence에 기록됨
- Context Packet(SPEC 발췌 + Task 계약 + intent)이 복붙 없이 그대로 전달됨
- `observe`·`close-agent`·`quota-check`·`auto-step`이 그 Agent를 찾을 수 있음
- `close-agent`가 "Harness가 만든 Pane"만 정리한다는 불변식이 유지됨

대신 A는 Herdr·Provider CLI에 강하게 결합되고 `HERDR_ENV=1` 안에서만 동작합니다. 그래서 B는 버리지 않고 **명시적인 폴백 경로**로 둡니다.

```bash
# 1) Pane을 만들지 않고, 실행할 herdr 명령과 Context Packet 경로만 출력 (Herdr 밖에서도 동작)
herdr-harness dispatch . task-001 worker --print-only

# 2) 출력된 herdr 명령을 직접 실행한 뒤, Harness 추적에 되돌려 등록
herdr-harness adopt . task-001 worker --pane pane-3 --agent hh-task-001-w-1

# 3) 이후는 평소와 같다
herdr-harness observe . task-001 worker
```

- `--print-only`는 **아무 상태도 남기지 않습니다**(Context Packet만 씁니다). 시작하지 않은 시도를 Attempt로 남기면 전이 게이트가 헐거워지기 때문입니다.
- `adopt`는 등록 전에 `herdr agent get`으로 그 Agent가 실제로 살아 있는지 확인하고, 없으면 거부합니다.

#### Agent를 어디서 띄우는가 — `--cwd`

`dispatch`는 기본적으로 **Harness 워크스페이스**(`.harness/`가 있는 디렉터리)에서 Agent를 띄웁니다. Provider Sandbox의 쓰기 범위가 그 디렉터리를 기준으로 정해집니다 — `codex --sandbox workspace-write`는 기동 디렉터리 **아래만** 쓸 수 있습니다.

계획·상태 문서를 담은 워크스페이스와 수정 대상 코드 저장소를 **따로 두는 구성**이라면 기본값으로는 아무것도 고칠 수 없습니다.

```text
projects/slot/
├── harness-dev/      ← 기본값: Agent가 여기서 기동, 쓰기 가능
│   └── .harness/
└── code-repo/        ← write_scope는 여기인데 쓰기 거부됨
```

Worker는 Task를 분석하고 재현까지 마친 뒤 **쓰기 시점에** 막힙니다. 그때까지 쓴 시간과 토큰은 그대로 버려집니다. `--cwd`로 기동 디렉터리를 옮기면 Sandbox 범위가 그쪽으로 갑니다.

```bash
herdr-harness dispatch . task-002 worker --cwd ../code-repo
```

- 그 디렉터리가 별도 Git 저장소면 **baseline commit과 `git status`·`git diff`가 양쪽 모두** Attempt·Evidence에 남습니다. 리뷰가 대조할 기준은 워크스페이스가 아니라 실제 수정 대상 저장소이기 때문입니다.
- `--print-only` 출력에도 같은 `--cwd`가 반영되고, 경로는 셸 인용됩니다.
- 없는 디렉터리를 주면 Agent를 띄우기 전에 거부합니다.
- 워크스페이스를 코드 저장소 안에 두는 구성(`code-repo/.harness/`)이라면 기본값으로 충분하며 `--cwd`는 필요 없습니다.
- `adopt`로 등록한 Pane은 사람이 만든 것이므로 `close-agent`가 `--force` 없이는 닫지 않습니다.

### 커스텀 프롬프트도 `dispatch`로 — `--extra-prompt`

Task마다 리뷰 중점이나 오판 방지 경고를 따로 붙이고 싶을 때가 있습니다. 그걸 담으려고 Agent를 사람이 직접 띄우면 Attempt·Evidence·Pane 추적이 통째로 빠집니다. 추가 지시는 파일로 적어 Packet에 붙입니다.

```bash
herdr-harness dispatch . task-001 reviewer --extra-prompt .harness/runtime/task-001-review-notes.md
```

- 내용은 Context Packet의 `## 이 Task 추가 지시` 절로 들어가며, `## Next step` **앞**에 놓입니다 — 마지막 줄이 "다음 한 단계"로 끝나야 Agent가 무엇을 할 차례인지 헷갈리지 않습니다.
- 파일 내용도 Packet 전체와 함께 Secret 검사를 받습니다.

### 첫 프롬프트가 확인 화면에 먹히는 문제

`herdr agent start`는 Provider가 떴다는 것까지만 보장합니다. 그 뒤에도 agy는 REPL 부팅·폴더 신뢰·로그인 화면을, claude는 `bypassPermissions` 첫 확인 화면을 띄울 수 있고, 그 화면에 Context Packet을 보내면 텍스트가 화면에 먹힌 채 Agent는 아무 일도 하지 않고 `idle`로 남을 수 있습니다. `done`도 항상 완료를 뜻하지 않습니다. 실제로 명령 승인 프롬프트를 기다리는 동안 `done`이 관측된 사례가 있습니다.

`dispatch`는 이를 두 단계로 막습니다.

1. 프롬프트 전에 Provider REPL이 안정적으로 입력을 받을 수 있을 때까지 기다린 뒤(agy는 부팅이 느려 더 기다립니다), `herdr agent get`으로 `revision`과 `state_change_seq` 기준값을 기록합니다.
2. 전송 뒤 `idle`/`done`인데 두 지표가 모두 그대로면 `prompt_not_delivered`로 판정해 **1회만** 다시 보냅니다. `herdr agent prompt`가 성공을 반환했더라도 같은 규칙을 적용합니다. 기존 `agent_prompt_stalled` 신호도 같은 1회 재전송 경로에 남습니다.
3. 두 지표 중 하나라도 변한 `idle`/`done`만 `settled`로 봅니다. 화면 출력에 Packet 헤더나 Provider별 부팅 문구가 보이는지는 전달 판정에 쓰지 않습니다.

재전송 여부는 Evidence의 `Prompt 재전송` 항목에 남습니다.

### Agent 승인 정책 — `.harness/policies/agent-policy.yaml`

Agent를 띄울 때마다 "이 명령을 실행할까요? (y/n)"을 반복해서 물으면 진행만 막힙니다. `dispatch`는 `agent_policy.approval_mode`에 따라 Provider CLI에 승인 우회 인수를 붙여 **도구 실행 승인만** 건너뜁니다.

| 모드 | 의미 | claude | codex | agy |
| --- | --- | --- | --- | --- |
| `ask` | Provider 기본값, 매번 물어봄 | (인수 없음) | (인수 없음) | (인수 없음) |
| `auto` (기본값) | 파일 편집·작업 트리 안 명령은 자동 승인 | `--permission-mode acceptEdits` | `--ask-for-approval never --sandbox workspace-write` | `--mode accept-edits` |
| `bypass` | 도구 실행 승인을 전부 건너뜀 | `--permission-mode bypassPermissions` | `--dangerously-bypass-approvals-and-sandbox` | `--dangerously-skip-permissions` |

여기서 사라지는 것은 리눅스 명령 실행 같은 **도구 단위 승인**뿐입니다. 작업 방향성에 대한 결정 — Task 상태 전이, 완료 승인 — 은 그대로 사람 몫으로 남습니다.

승인을 건너뛰게 되면 Agent는 셸 명령을 자유롭게 돌릴 수 있으므로, "직접 전이하지 마라"는 프롬프트 지시만으로는 Agent가 스스로 `approve --confirm-user-approval`을 실행하거나 프리미엄 모델 승인 파일을 만드는 것을 막을 수 없습니다. 그래서 `transition`과 `approve`는 **호출한 Pane이 Harness가 추적 중인 Agent Pane이면 거부**하고, 같은 Pane에서 실행한 `dispatch`는 프리미엄 승인 파일을 인정하지 않습니다(`dispatch`가 띄운 Pane뿐 아니라 `adopt`로 등록한 Pane도 포함) — `herdr pane current`로 현재 pane을 확인해 `.harness/runtime/*.meta`에 기록된 `pane_id`와 대조합니다(환경변수보다 `herdr pane current`를 우선하므로 `HERDR_PANE_ID`를 `env -u`로 지우는 것만으로는 통하지 않습니다. `herdr` 조회 자체가 실패하면 그 환경변수로 떨어지고, 그것도 비어 있으면 Pane을 특정할 수 없어 통과시킵니다 — 아래 단서대로 가드레일이지 경계가 아닙니다). `.meta`에 기록이 없는 사람 Pane과 Orchestrator Pane은 영향을 받지 않습니다.

> **이것은 가드레일이지 보안 경계가 아닙니다.** Agent는 사용자와 같은 권한으로 돌기 때문에 `.meta`, 승인 파일이나 Harness 스크립트 자체를 고칠 수 있습니다. 완료 승인과 프리미엄 모델 승인을 지시를 따라 스스로 통과시키는 기본 동작을 막을 뿐, 적대적 Agent를 막지는 못합니다. 진짜 경계를 원하면 OS 수준 분리(별도 계정·컨테이너)가 필요하고 그건 아직 Deferred 항목입니다.

- 프로젝트를 만들 때 `herdr-harness init PATH --approval-mode ask|auto|bypass`로 정하고, 이후에는 `agent-policy.yaml`을 직접 고칩니다.
- 표의 값은 공백으로 나뉘어 `herdr agent start ... -- <인수>`로 전달됩니다. **임의의 Provider 옵션을 넣는 통로가 아닙니다** — Provider별로, 그리고 **모드별로** 허용 플래그와 허용 값이 갈립니다. `--add-dir /`, `--model opus` 같은 승인과 무관한 인수는 거부되고, `auto` 칸에 `--permission-mode bypassPermissions`나 `--dangerously-*`를 넣는 것도 거부됩니다(같은 값이 `bypass` 칸에서는 통과). 그러지 않으면 정책 파일 한 줄로 `auto`가 사실상 full-access가 되면서 기록에는 계속 `auto`로 남습니다.
- claude의 `bypassPermissions`는 디렉터리마다 처음 한 번 확인 화면을 띄울 수 있고, 그러면 `herdr agent start`가 그 화면에서 멈춥니다. 기본값 `auto`(`acceptEdits`)는 그 화면이 없습니다.
- 실제로 쓰인 모드와 인수는 Attempt·Evidence 문서에 기록됩니다.
- 이 파일이 없는 예전 프로젝트에서는 인수를 붙이지 않습니다(= `ask`와 같음).

### Task별 모델 선택 — 승인 인수와 분리된 정책 경로

모델은 Task를 기안하는 사람이 난이도와 역할에 맞춰 선택합니다. Harness가 난이도를
추측하지 않습니다. Task YAML의 선택 필드는 역할별로 나뉩니다.

```yaml
primary_worker: 'codex'
reviewer: 'agy'
worker_model: 'gpt-5.6-sol'
reviewer_model: 'gemini-3.1-pro-high'
```

선택 우선순위는 `worker_model`/`reviewer_model` → 선택된 Provider의 정책 기본값 →
Provider CLI 기본값입니다. 정책은 `.harness/policies/agent-policy.yaml`에서 관리합니다.

```yaml
agent_policy:
  codex_models: 'gpt-5.6-sol gpt-5.6-terra'
  codex_default_model: 'gpt-5.6-terra'
  codex_premium_models: 'gpt-5.6-terra'
  agy_models: 'gemini-3.8-flash-high gemini-3.1-pro-high'
  agy_default_model: 'gemini-3.8-flash-high'
  agy_premium_models: ''
```

- `*_models`는 공백 구분 허용 목록입니다. Task 값과 `*_default_model`은 목록의
  토큰과 정확히 일치해야 하며, CLI에는 Task 문자열이 아니라 목록에서 찾은 값만
  `--model <MODEL>`로 전달됩니다.
- 프리미엄 목록이 비어 있으면 Task 값이 목록 밖이거나 목록이 비어 있을 때 경고 후
  모델 인수를 붙이지 않는 기존 동작을 유지합니다. 모델 미지정 Task와 빈 초기
  정책도 기존과 똑같이 Provider CLI 기본값을 씁니다.
- `*_premium_models`는 프리미엄(최상위) 등급의 선언입니다. `*_models`를 넓히지
  않으며, 전체 모델 ID가 허용 목록 토큰과 정확히 일치해야 합니다. 하나라도
  일치하지 않으면 런타임은 fail-open 대신 Pane 생성 전 dispatch를 거부합니다.
- 프리미엄 목록이 있으면 모델 미지정 Task도 Provider CLI의 보이지 않는 기본값에
  맡기지 않습니다. 비프리미엄 `*_default_model`, 없으면 `*_models`의 첫
  비프리미엄 token을 `--model`로 명시합니다. 둘 다 없으면 `*_default_model`
  설정 안내와 함께 dispatch를 거부합니다.
- 프리미엄 모델은 `.harness/decisions/TASK_ID-model-approval.md`의 `Task`, `역할`,
  `모델`, `승인: yes`가 현재 dispatch와 모두 일치할 때만 사용합니다. 없거나
  불일치하면 경고 후 위 규칙의 비프리미엄 모델로 강등합니다. 승인은 Attempt가
  아니라 Task+역할+모델 범위라 같은 Task의 재시도에서는 유지됩니다.
- 목록 조회와 갱신은 `herdr-harness models PATH`를 사용합니다. `agy`는 실제
  `agy models` 결과와 정책의 추가·삭제·유지를 보여 주지만, 비대화형 조회 경로가
  없는 `codex`·`claude`는 `조회 경로 없음 — 수동 관리`로 표시하고 값을 추측하지
  않습니다.
- 승인용 `*_auto`/`*_bypass` 표는 모델 통로가 아닙니다. 그 표의 `--model opus`는
  계속 거부되며, 모델 선택은 별도의 허용 목록 검사를 거칩니다.
- `dispatch`는 Attempt와 Evidence에 모델·출처와 프리미엄 승인 근거 또는 구체적인
  거부 사유를 기록합니다. 승인 파일의 모델 값은 비교에만 쓰고 argv에는 허용
  목록에서 꺼낸 token만 전달합니다.

모델 정책 명령은 `sync-templates`와 같은 안전 규약을 사용합니다.

```bash
# 정책·실제 조회 결과와 프리미엄 적용 여부 표시(파일 변경 없음)
herdr-harness models .

# agy 전체 목록 갱신의 추가·삭제·유지 diff만 미리보기
herdr-harness models . --refresh

# 조회가 성공한 경우에만 agy_models와 조회 시각 주석을 실제 반영
herdr-harness models . --refresh --apply

# 언급한 Provider의 프리미엄 집합 전체를 대체(반복 지정은 누적, 빈 값은 비우기)
herdr-harness models . \
  --premium claude=claude-fable-5 \
  --premium claude=claude-opus-4-6 --apply
herdr-harness models . --premium agy= --apply
```

`--apply`가 없으면 정책 파일을 쓰지 않습니다. 조회가 비정상 종료하거나 빈 목록을
돌려주면 삭제를 계산하지 않고 기존 값과 조회 시각을 보존합니다. 프리미엄 선언은
그 호출에서 언급한 Provider에만 set 의미로 적용되며, 다른 Provider의 선언과
`approval_mode`·`*_auto`·`*_bypass`·사용자 주석은 그대로 남습니다.

### Acceptance Criteria 게이트 — `transition ... submitted`가 직접 검증한다

`submitted` 전이는 Attempt·Evidence의 존재만 보지 않습니다. Harness가 Task YAML의 `acceptance_criteria[].verified_by`를 **직접 실행**하고, 하나라도 실패하면 전이를 거부합니다. "됐다"는 Agent의 보고와 실제 저장소 상태가 갈라지는 경우를 여기서 잡습니다.

```yaml
acceptance_criteria:
  - criterion_id: AC-001
    statement: 벤더 A Dump가 공통 스키마로 정규화된다
    verified_by:
      type: command
      command: pytest tests/test_vendor_a.py -q
  - criterion_id: AC-002
    statement: 스키마 문서가 실제 필드와 일치한다
    verified_by:
      type: manual-review
      instruction: 구체적인 확인 방법
```

- `type: command` — 프로젝트 루트에서 실행하고 종료 코드로 판정합니다. 명령 하나당 제한 시간은 `.harness/policies/project-policy.yaml`의 `acceptance_check_timeout_seconds`(기본 600초)이며, 시간을 넘기면 강제 종료됩니다.
- `type: manual-review` — 자동 검증이 불가능한 기준입니다. `manual`로 기록만 하고 전이를 막지 않습니다. 판단은 Reviewer가 합니다.
- `verified_by`의 `type`은 `command` 또는 `manual-review`입니다. 값 뒤에 인라인 주석(`type: command  # ...`)을 붙이면 주석까지 값으로 읽혀 전이가 거부되므로, 설명은 항목 위 줄 주석으로 답니다.
- 항목 키는 `criterion_id`입니다(`.harness/tasks/TEMPLATE.yaml`과 같음). 파서는 `- criterion_id:`로 시작하는 항목만 인식하므로 다른 키를 쓰면 기준이 0개로 읽혀 전이가 거부됩니다.
- `acceptance_criteria`가 비어 있으면 `submitted`로 전이할 수 없습니다.
- 원격 실행 모드(`remote.yaml`의 `enabled: true`)에서는 같은 명령을 원격에서 실행합니다.
- 결과는 `.harness/evidence/TASK-attempt-N-checks.yaml`에 남고, Reviewer의 Context Packet에 그대로 주입됩니다.

### Evidence 구조 — 정본 YAML과 `raw/` 분리

Evidence는 "Worker가 말한 것과 실제 저장소 상태가 일치하는가"를 판단하는 데 쓰입니다. 그 판단에 쓰이는 필드만 정본 YAML에 두고, Agent 출력 원문 같은 긴 덤프는 디버깅용으로 분리합니다. Agent에게 보낸 Context Packet 전문은 Evidence가 아니라 `.harness/runtime/TASK-context-ROLE.md`에 있습니다.

| 파일 | 내용 | Git |
|---|---|---|
| `.harness/evidence/TASK-<worker\|reviewer>-attempt-N.yaml` | 정본 — `task`·`role`·`attempt`·`result`·`changes`(`git status --short`)·`status`·`raw` | 추적 |
| `.harness/evidence/TASK-attempt-N-checks.yaml` | AC 검증 결과 — 기준별 `command`·`exit_code`·`result`·`output_tail`과 `summary` | 추적 |
| `.harness/evidence/raw/TASK-<role>-attempt-N.md` | 원문 덤프 — `git status --short`/`diff --stat`, Agent 상태·출력, `observe` 관측 기록 | `.gitignore` 제외 |

`submitted` 게이트는 글롭이 아니라 파일 이름과 필수 필드를 함께 확인합니다. 빈 YAML을 하나 놓아 두는 것으로는 통과하지 못하며, 정본은 `dispatch`/`observe`만 만듭니다. Secret 의심 패턴이 발견되면 원문 대신 요약만 남깁니다.

### Context Packet에 직전 라운드가 들어간다

`dispatch`가 만드는 `.harness/runtime/TASK-context-ROLE.md`에는 SPEC 발췌·Task 계약·intent 안내에 더해 **직전 라운드**가 함께 들어갑니다.

- 최신 Worker·Reviewer Evidence 정본
- 최신 AC 검증 결과(`checks.yaml`)
- 최신 Review 판정과 본문 발췌

`changes_requested` 후 재시도에서 Worker가 Reviewer의 지적을 못 본 채 같은 접근을 반복하는 것을 막기 위한 것입니다. "가장 큰 attempt 번호"가 아니라 파일이 실제로 존재하는 최근 attempt를 찾고, 길이가 예측 불가능한 Review·checks는 줄 수와 줄 길이를 함께 잘라 넣습니다.

### `quota-retry`, `auto-step` — opt-in 제약된 자동화

두 명령 모두 기본은 꺼져 있고(opt-in), 완전 자율 실행이 아니라 **유한하고 되돌릴 수 있는 범위**만 자동화합니다. 둘 다 실행 전에 같은 Task에 대한 mkdir 기반 Task Lock(`.harness/runtime/TASK_ID.lock`)을 잡아, `quota-retry`/`auto-step` 두 자동화 경로끼리 같은 Task에 동시에 들어가는 것을 막습니다 — SQLite Lease나 Fencing Token 같은 완전한 락은 아니며, 사람이 그 사이에 수동으로 `dispatch`/`transition`을 실행하는 것까지 막지는 않으므로 자동 명령이 도는 동안은 `status --live`로 확인하고 수동 개입을 삼가세요.

- **`quota-retry`**: `.harness/policies/quota-policy.yaml`의 `automatic_failover: true`로 켜야 동작합니다. `quota-check`가 남긴 연속 `low` 판정이 `low_confirm_count`회 이상, 그 간격이 `cooldown_seconds` 이상일 때만 진행하며, Task당 1회만 허용합니다(flapping 방지). 진행 시 기존 `close-agent`/`transition`을 그대로 호출해 Provider를 `fallback_chain`의 다음 값으로 바꾸고, `handover_required` 전이 전에 `.harness/handovers/TASK_ID-handover-N.md` stub(사유·Provider 교체·`git diff --stat`·다음 한 단계)을 자동 생성한 뒤 `handover_required`까지 전이하고 **거기서 멈춥니다**(`transition`이 인계 문서를 요구하므로 자동 경로도 인계 문맥을 남깁니다). `ready`로 재개하려면 사람이 `.harness/decisions/TASK_ID-failover-approval.md`에 `승인: yes`를 쓰고 `transition ... ready`를 직접 실행해야 합니다 — `completed`는 물론 이 재개 단계도 자동화하지 않습니다.
- **`auto-step`**: `.harness/policies/loop-policy.yaml`의 `enabled: true`로 켜야 동작하고, `--max-turns`는 `max_turns_ceiling`(기본 5)을 넘을 수 없습니다. 상주 루프가 아니라 호출 1회가 반드시 끝납니다: 1턴째만 `dispatch`로 Pane을 새로 만들고, 이후 턴은 같은 Agent를 `observe`로만 재조회합니다(반복 dispatch는 Pane을 고아로 만들기 때문에 하지 않습니다). `stalled`·`timeout`만 정책 상한 안에서 다시 관측하고, `settled`·`blocked`·`running`·`prompt_not_delivered`·`unknown`·`agent_lost`·`error`에 닿으면 즉시 멈추고 판단을 사람에게 넘깁니다 — `reviewing`·`awaiting_approval`·`completed`로 이어지는 코드 경로 자체가 없습니다.

## 원격 실행 모드 (opt-in)

소스가 원격 서버에만 있고 빌드·테스트·SVN도 그 서버에서만 되는 환경을 위한 모드입니다. **Agent는 언제나 로컬에서 실행됩니다** — 원격은 소스를 SSHFS로 로컬에 노출하고, 검증 명령만 SSH로 실행하는 실행 환경일 뿐입니다.

```bash
herdr-harness init ~/Projects/normalize-telemetry \
  --name normalize-telemetry \
  --goal "원격 빌드 서버의 텔레메트리 정규화 모듈 개선" \
  --remote-host 192.168.2.77 \
  --remote-user nsotdb \
  --remote-path /home/nsotdb/Normalize_Telemetry \
  --remote-mount ~/workspace/Normalize_Telemetry \
  --remote-vcs svn
```

설정 정본은 `.harness/policies/remote.yaml`이고, `enabled: true`가 아니면 모든 `remote` 하위 명령이 즉시 거부합니다(기존 프로젝트는 영향 없음).

### 최초 1회: `remote setup`

기존 프로젝트든 새 프로젝트든, 설정 파일 작성과 SSH 키 등록을 한 번에 끝냅니다. **ID와 비밀번호는 이때 한 번만 입력**하고, 그 뒤로는 키 인증이라 다시 묻지 않습니다.

```bash
cd ~/Projects/내프로젝트
herdr-harness remote . setup
```

```text
원격 호스트(SSH): 192.168.2.77
원격 계정 [esk1223]: nsotdb
원격 프로젝트 경로(절대경로): /home/nsotdb/Normalize_Telemetry
SSHFS 마운트 경로(로컬) [~/Projects/내프로젝트/.harness/remote-mount]: ~/workspace/Normalize_Telemetry
전용 SSH 키 경로 [~/.ssh/herdr_remote_ed25519]:
원격 VCS (git|svn|none) [git]: svn
원격 비밀번호(키 등록에만 사용, 저장하지 않음):        ← 화면에 표시되지 않음
[herdr-harness] 원격 설정 기록: .harness/policies/remote.yaml (비밀번호는 저장하지 않습니다)
[herdr-harness] SSH 키 등록 완료. 이후에는 HH_REMOTE_PASSWORD 없이 접속합니다.
```

비밀번호는 이 명령이 도는 동안 메모리에만 있고 설정 파일·명령줄 인자·셸 이력 어디에도 남지 않습니다. `sshpass` 호출 하나에만 전달되며 `ssh-keygen` 같은 다른 자식 프로세스는 상속하지 않습니다. 이미 키로 접속되는 상태라면 비밀번호를 아예 묻지 않습니다.

- 다시 실행하면 기존 값이 기본값으로 채워집니다. 값을 바꾸려면 `--force`가 필요합니다(설정 파일이 중복 키 등으로 깨져 있으면 `--force`로 새로 작성할 수 있습니다).
- 키 등록 단계에서 실패해도 입력한 설정은 저장돼 있습니다. `herdr-harness remote . bootstrap-key`로 키만 다시 등록하면 됩니다.
- 스크립트·CI용 비대화형 실행: `herdr-harness remote . setup --host H --user U --path /srv/p --vcs svn --no-key` (`--no-key`는 키 등록을 건너뜁니다. 등록까지 하려면 `HH_REMOTE_PASSWORD`를 함께 넘기세요.)
- 키만 다시 등록하려면 `herdr-harness remote . bootstrap-key`.

### 이후 사용

```bash
herdr-harness remote . doctor            # 의존성·SSH·원격 경로·도구·마운트 진단
herdr-harness remote . mount             # 원격 소스를 로컬 경로에 노출
herdr-harness remote . run 'make -j4 && ctest'   # 빌드·테스트를 원격에서 실행
herdr-harness remote . vcs status        # remote.yaml의 vcs(git|svn)를 원격에서 실행
herdr-harness remote . status            # 설정·연결·마운트 요약
herdr-harness remote . unmount
```

Worker/Reviewer는 Task의 `verified_by` 명령을 로컬에서 직접 돌리지 않고 `remote run`으로 실행합니다(역할 문서와 `harness-work` Skill에 명시되어 있습니다). Evidence에는 평소처럼 명령 전문과 종료 코드를 남깁니다.

**비밀번호는 어떤 파일에도 저장하지 않습니다.** `remote.yaml`에는 비밀번호 키 자체가 없고, 코드가 비밀번호를 파일이나 명령줄 인자(argv)에 쓰지도 않습니다(`sshpass -e`로 환경변수 경유).

다만 다음 두 가지는 한계로 알고 쓰세요.

- `ssh_key` 파일이 아직 없으면 `bootstrap-key`뿐 아니라 `run`·`status`·`mount` 등 **모든 원격 명령이 비밀번호 인증으로 떨어집니다**. 키를 등록하고 나면 그 뒤로는 키 인증만 씁니다 — 그래서 설치 직후 `bootstrap-key`를 먼저 돌리는 것을 권합니다.
- 환경변수에 담긴 비밀번호는 같은 사용자나 root가 `/proc/<pid>/environ`으로 볼 수 있습니다. 키 등록이 끝나면 `unset HH_REMOTE_PASSWORD`로 지우세요.

로컬에 `openssh-client`, `sshfs`, `util-linux`가 필요하고, 키 등록 전까지만 `sshpass`가 필요합니다.

호스트·사용자명은 `-oProxyCommand=...` 같은 SSH 옵션으로 해석될 수 있는 형태를 거부하고, 원격 경로는 절대경로만 허용하며 원격 셸에 넘길 때 인용합니다 — 설정 파일과 환경변수 override 양쪽 모두에 적용됩니다.

환경변수 override: `HH_REMOTE_HOST`, `HH_REMOTE_USER`, `HH_REMOTE_PATH`, `HH_REMOTE_MOUNT_PATH`, `HH_REMOTE_SSH_KEY`, `HH_REMOTE_VCS`, `HH_REMOTE_PASSWORD`.

## 생성되는 프로젝트 구조

```text
project/
├── AGENTS.md
├── CLAUDE.md
├── GEMINI.md
├── HARNESS_START.md
├── .gitignore
├── .agents/
│   ├── roles/
│   └── skills/           # harness-spec/plan/orchestrate/work/review/handover
├── .claude/skills/        # 위 6개 스킬로 향하는 심볼릭 링크
└── .harness/
    ├── project.yaml
    ├── SPEC.md
    ├── MILESTONES.md
    ├── STATE.md
    ├── policies/          # project·quota·agent·loop·review·remote.yaml
    ├── profiles/
    ├── tasks/
    ├── waves/
    ├── intents/           # Task별 intent.md (착수 게이트·제외 범위·불변식)
    ├── references/
    ├── attempts/
    ├── evidence/           # 정본 YAML + AC checks (원문 덤프는 evidence/raw/, Git 제외)
    ├── reviews/
    ├── handovers/
    ├── decisions/
    └── archive/
```

`dispatch` 실행 시 Git 제외 영역인 `.harness/runtime/`이 추가로 생성됩니다.

## 운영 원칙

- Bash는 한 스텝의 실행·검증·기록만 담당하고 Orchestrator Agent가 다음 스텝을 선택합니다.
- 상태는 Task YAML을 직접 편집하지 않고 `herdr-harness transition`으로 전이합니다.
  완료 승인은 사용자 명시 승인 뒤 `herdr-harness approve ... --confirm-user-approval`로
  기록·전이합니다.
- 하나의 Task는 하나의 목적만 가집니다.
- Task당 쓰기 가능한 Primary Worker는 한 명입니다.
- 기존 코드·데이터·문서·Dump를 먼저 조사합니다.
- Worker와 다른 Provider가 Review합니다.
- 실패나 쿼터 소진이 확인된 경우에만 Provider를 교체합니다.
- `submitted` 전이 시 Harness가 Acceptance Criteria의 `verified_by` 명령을 직접 실행합니다. Agent의 자기 보고만으로는 통과하지 못합니다.
- Agent는 `submitted`까지만 제안하고 사용자가 `completed`를 승인합니다. `transition`·`approve`는 Harness가 추적 중인 Agent Pane(`dispatch`·`adopt` 모두)에서 호출하면 거부됩니다.
- Skill과 정책은 운영 지침이며 OS 수준의 보안 격리는 아닙니다.

자세한 내용은 [ARCHITECTURE.md](ARCHITECTURE.md)를 참고하세요.

## 업데이트

```bash
cd ~/herdr-agent-harness
git pull --ff-only
chmod +x install.sh harness.sh
./install.sh
herdr-harness test
```

## 제거

Clone 디렉터리를 이미 지웠더라도 설치된 명령 자체로 제거할 수 있습니다.

```bash
herdr-harness uninstall
```

확인 질문 없이 제거하려면:

```bash
herdr-harness uninstall --yes
```

Clone 디렉터리가 남아 있다면 기존 설치 스크립트도 사용할 수 있습니다.

```bash
cd ~/herdr-agent-harness
./install.sh --uninstall
```

제거되는 항목:

```text
~/.local/bin/herdr-harness
~/.local/share/herdr-agent-harness/harness.sh
~/.local/share/herdr-agent-harness/lib/
~/.local/share/herdr-agent-harness/templates/
~/.bashrc 의 탭 완성 로더 관리 블록(위 8-1의 마커 포함 3줄)
```

`herdr-harness uninstall`과 `./install.sh --uninstall` 모두 자동 등록한 관리
블록만 지우고, `~/.bashrc`의 다른 내용과 사용자가 마커 없이 직접 넣은 completion
줄은 건드리지 않습니다.

다음 항목은 제거하지 않습니다.

- 생성한 프로젝트
- Herdr 본체
- Herdr Integration
- 전역으로 설치한 Herdr Skill
- Claude, Codex, AGY CLI

## 설치 문제 해결

### `./install.sh: Permission denied`

GitHub 웹 업로드 과정에서 실행 권한이 빠진 경우입니다.

```bash
cd ~/herdr-agent-harness
chmod +x install.sh harness.sh
./install.sh
```

또는 실행 권한을 부여하기 전 다음처럼 실행할 수도 있습니다.

```bash
bash install.sh
```

### `herdr-harness: command not found`

설치 파일과 PATH를 확인합니다.

```bash
ls -l ~/.local/bin/herdr-harness
printf '%s\n' "$PATH" | tr ':' '\n' | grep "$HOME/.local/bin"
```

PATH에 없다면:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### `herdr: command not found`

Herdr를 설치하고 Shell을 다시 불러옵니다.

```bash
curl -fsSL https://herdr.dev/install.sh | sh
exec "$SHELL" -l
herdr --version
```

### Integration 설치 오류

Provider 설정 디렉터리가 없는 경우 먼저 생성합니다.

```bash
mkdir -p ~/.claude ~/.codex ~/.gemini/config

herdr integration install claude
herdr integration install codex
herdr integration install antigravity-cli
herdr integration status
```

### Agent가 Herdr Skill을 사용하지 못함

Agent는 일반 Ubuntu Terminal이 아니라 Herdr Pane 안에서 실행해야 합니다.

```bash
herdr --session harness-check
```

Herdr Pane에서 다음을 확인합니다.

```bash
printf '%s\n' "$HERDR_ENV"
```

기대값:

```text
1
```

공식 Skill을 다시 설치하려면:

```bash
npx skills add herdrdev/herdr --skill herdr -g
```

### `doctor`에서 특정 Agent가 `MISSING`

해당 Agent를 사용하지 않는다면 무시할 수 있습니다. 사용하려면 CLI 설치와 로그인을 완료한 뒤 새 Terminal에서 다시 확인합니다.

```bash
claude --version
codex --version
agy --version
herdr-harness doctor
```

### `dispatch`가 `stalled`로 끝나고 Agent가 확인 화면에 멈춰 있음

Provider CLI가 **디렉터리마다 최초 1회** 띄우는 확인 화면이 있습니다. 이 화면은 승인 정책(`agent-policy.yaml`)으로 건너뛸 수 없고, `dispatch`가 보낸 Context Packet이 그 화면에 입력돼 사라집니다.

- agy: `Do you trust the contents of this project?`
- claude: `--permission-mode bypassPermissions`의 첫 확인 화면

```bash
herdr-harness observe . TASK_ID reviewer          # 지금 어느 화면인지 확인
herdr agent read hh-...-r-1 --source visible      # 화면 직접 확인
herdr agent send-keys hh-...-r-1 enter            # 확인 화면 응답(내용을 보고 사람이 판단)
herdr agent prompt hh-...-r-1 "$(cat .harness/runtime/TASK_ID-context-ROLE.md)" --wait --timeout 240000
herdr-harness observe . TASK_ID reviewer          # Evidence 갱신
```

같은 디렉터리에서 한 번 응답하면 이후 `dispatch`는 그대로 통과합니다. claude에서 이 화면을 피하려면 `approval_mode: auto`(`acceptEdits`)를 씁니다.

### 자체 테스트에서 YAML 검사를 건너뜀

PyYAML은 선택 사항입니다. YAML 파싱까지 검사하려면:

```bash
python3 -m pip install --user PyYAML
herdr-harness test
```

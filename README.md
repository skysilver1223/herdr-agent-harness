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

서브커맨드뿐 아니라 `init --profile`·`--orchestrator` 등의 옵션 값, `transition`의
Task ID·상태, `approve`의 Task ID·확인 플래그, `dispatch`·`quota-check`의 Task
ID·`worker`/`reviewer`도 완성됩니다.
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
PASS: Harness 파일 생성 (21종 템플릿, templates/ 파일 정본)
PASS: 템플릿 배열 ↔ templates/ 파일 정합
PASS: 공통 Skill과 Claude 연결
PASS: 플레이스홀더 치환
PASS: Git 기준선 생성
PASS: 신규 프로젝트 보호
PASS: 비대화형 명시적 실패
PASS: 상태 전이표 강제 (16개 케이스, handover_required 인계문서 게이트 포함)
PASS: 명시 승인 approve (정상/멱등/무확인/상태/Review/Task ID/충돌 거부)
PASS: 이벤트 로그 기록
PASS: validate 검증 (정상/Worker=Reviewer/Git 누락)
PASS: 스텝 명령 인자 검증
PASS: Agent 호출 없음
PASS: 탭 완성 스크립트 문법
PASS: Task Lock (동시 획득 거부/release/stale 회수)
PASS: quota-retry/auto-step opt-in 게이트
PASS: quota-retry/auto-step 안전 불변식(completed/reviewing/awaiting_approval/ready 미호출, handover stub 선행)
PASS: sync-templates (dry-run 무변경 감지·미적용, apply 갱신·멱등, AGENTS.md/STATE.md 비침범)
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

## Agent Loop 스텝 명령

Harness는 상주 Controller나 자율 반복 루프를 실행하지 않습니다. Bash 명령은 호출 한 번에 한 단계의 검증·실행·기록만 담당하고, Orchestrator Agent가 결과를 읽어 다음 단계를 선택합니다.

| 명령 | 책임 |
|---|---|
| `herdr-harness validate [PATH] [--wave ID] [--no-git]` | Git 기준선, Task/Wave, Provider, 의존성, 실행 상한과 write scope를 읽기 전용 검증 |
| `herdr-harness transition PATH TASK_ID TO_STATE [--note TEXT]` | 허용된 상태 전이와 필수 Attempt/Evidence/Review/승인 기록 강제 |
| `herdr-harness approve PATH TASK_ID --confirm-user-approval` | 사용자 명시 승인 확인 후 승인 증거를 원자적으로 기록하고 기존 `transition` 게이트로 `completed` 전이 |
| `herdr-harness dispatch PATH TASK_ID worker\|reviewer [--timeout MS]` | Pane 생성, Agent 시작, Context Packet 1회 전송, 대기와 증적 기록 |
| `herdr-harness observe PATH TASK_ID [worker\|reviewer]` | 기존 Agent를 재조회하고 Evidence에 추가 |
| `herdr-harness close-agent PATH TASK_ID [worker\|reviewer] [--force]` | Harness runtime에 등록된 Pane만 정리 |
| `herdr-harness status [PATH] --live [--json]` | 문서·Herdr·Git 실시간 상태 대조 |
| `herdr-harness quota-check PATH TASK_ID worker\|reviewer` | 실행 중인 Agent의 쿼터 확인(claude·codex는 `/status` 전송, agy는 `--print "/usage"`) |
| `herdr-harness quota-check PATH --provider agy` | Task 없이 agy 쿼터만 바로 확인 |
| `herdr-harness quota-retry PATH TASK_ID worker\|reviewer` | (opt-in) 연속 저쿼터 확인 시 Provider 교체를 `handover_required`까지 자동 처리 |
| `herdr-harness auto-step PATH TASK_ID [--max-turns N]` | (opt-in) 유한 턴 동안 dispatch 1회 + observe 반복 |

`dispatch`는 재시도, 상태 전이, blocked 응답 또는 Provider failover를 수행하지 않습니다. Orchestrator는 반환된 `dispatch_result`를 확인한 뒤 사용자 승인 경계를 지키며 다음 스텝을 호출합니다.

`approve`는 사용자가 채팅에서 **현재 Task의 완료를 명시적으로 승인한 뒤** Orchestrator가
호출하는 기록 대행 명령입니다. `--confirm-user-approval`이 없거나 Task가
`awaiting_approval`이 아니거나 최신 Review가 `APPROVED`가 아니면 거부합니다. 기존 승인
파일과 Task/Review가 다르면 덮어쓰지 않으며, 성공한 명령을 같은 인자로 다시 호출하면
승인 파일을 바꾸지 않고 성공합니다. 사용자 발화나 승인 의도를 CLI가 추론하지는 않습니다.

```bash
herdr-harness approve ~/Projects/snmp-normalizer task-001 --confirm-user-approval
```

`quota-check`도 자동으로 아무것도 바꾸지 않습니다. claude·codex는 비대화형 조회 수단이 없어 실행 중인 Agent Pane에 `/status`를 보내고 그 출력에서 알려진 경고 문구("... N% of your weekly limit ..." 등)를 스캔합니다. agy는 `agy --print "/usage"`로 정확한 잔여 퍼센트를 바로 얻습니다. 판정 기준(`low`로 볼 임계값)은 `.harness/policies/quota-policy.yaml`의 `low_warning_threshold_pct`로 조정하며, `dispatch`·`observe`도 Agent 출력을 지나가는 김에 스캔해 Evidence에 참고용 경고를 남깁니다(`passive_scan_on_dispatch`).

### `quota-retry`, `auto-step` — opt-in 제약된 자동화

두 명령 모두 기본은 꺼져 있고(opt-in), 완전 자율 실행이 아니라 **유한하고 되돌릴 수 있는 범위**만 자동화합니다. 둘 다 실행 전에 같은 Task에 대한 mkdir 기반 Task Lock(`.harness/runtime/TASK_ID.lock`)을 잡아, `quota-retry`/`auto-step` 두 자동화 경로끼리 같은 Task에 동시에 들어가는 것을 막습니다 — SQLite Lease나 Fencing Token 같은 완전한 락은 아니며, 사람이 그 사이에 수동으로 `dispatch`/`transition`을 실행하는 것까지 막지는 않으므로 자동 명령이 도는 동안은 `status --live`로 확인하고 수동 개입을 삼가세요.

- **`quota-retry`**: `.harness/policies/quota-policy.yaml`의 `automatic_failover: true`로 켜야 동작합니다. `quota-check`가 남긴 연속 `low` 판정이 `low_confirm_count`회 이상, 그 간격이 `cooldown_seconds` 이상일 때만 진행하며, Task당 1회만 허용합니다(flapping 방지). 진행 시 기존 `close-agent`/`transition`을 그대로 호출해 Provider를 `fallback_chain`의 다음 값으로 바꾸고, `handover_required` 전이 전에 `.harness/handovers/TASK_ID-handover-N.md` stub(사유·Provider 교체·`git diff --stat`·다음 한 단계)을 자동 생성한 뒤 `handover_required`까지 전이하고 **거기서 멈춥니다**(`transition`이 인계 문서를 요구하므로 자동 경로도 인계 문맥을 남깁니다). `ready`로 재개하려면 사람이 `.harness/decisions/TASK_ID-failover-approval.md`에 `승인: yes`를 쓰고 `transition ... ready`를 직접 실행해야 합니다 — `completed`는 물론 이 재개 단계도 자동화하지 않습니다.
- **`auto-step`**: `.harness/policies/loop-policy.yaml`의 `enabled: true`로 켜야 동작하고, `--max-turns`는 `max_turns_ceiling`(기본 5)을 넘을 수 없습니다. 상주 루프가 아니라 호출 1회가 반드시 끝납니다: 1턴째만 `dispatch`로 Pane을 새로 만들고, 이후 턴은 같은 Agent를 `observe`로만 재조회합니다(반복 dispatch는 Pane을 고아로 만들기 때문에 하지 않습니다). `settled`/`blocked`/오류에 도달하면 즉시 멈추고 판단을 사람에게 넘깁니다 — `reviewing`·`awaiting_approval`·`completed`로 이어지는 코드 경로 자체가 없습니다.

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
    ├── policies/          # project·quota·loop·review-policy.yaml
    ├── profiles/
    ├── tasks/
    ├── waves/
    ├── intents/           # Task별 intent.md (착수 게이트·제외 범위·불변식)
    ├── references/
    ├── attempts/
    ├── evidence/
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
- Agent는 `submitted`까지만 제안하고 사용자가 `completed`를 승인합니다.
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

### 자체 테스트에서 YAML 검사를 건너뜀

PyYAML은 선택 사항입니다. YAML 파싱까지 검사하려면:

```bash
python3 -m pip install --user PyYAML
herdr-harness test
```

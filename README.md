# Herdr Agent Harness

Claude, Codex, AGY를 Herdr에서 역할과 Skill 기반으로 운영하기 위한 Ubuntu·WSL용 프로젝트 생성 도구입니다.

저장소에서 사용자가 다룰 파일은 네 개입니다.

```text
install.sh       # 최초 설치
harness.sh       # 생성·실행·상태·진단·테스트
README.md        # 사용법
ARCHITECTURE.md  # 운영 구조
```

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
PASS: Harness 파일 생성
PASS: 공통 Skill과 Claude 연결
PASS: 신규 프로젝트 보호
PASS: Agent 호출 없음
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

스크립트는 신규·빈 디렉터리에서만 작동하며 기존 파일을 덮어쓰지 않습니다.

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
harness-orchestrate Skill을 사용해 프로젝트를 시작해줘.
기존 코드, 데이터, 문서, Dump가 있는지 먼저 인터뷰하고
SPEC 승인 전에는 구현하지 마.
```

## 상태 확인

```bash
herdr-harness status ~/Projects/snmp-normalizer
```

## 생성되는 프로젝트 구조

```text
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
    ├── references/
    ├── evidence/
    ├── reviews/
    └── handovers/
```

## 운영 원칙

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
```

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

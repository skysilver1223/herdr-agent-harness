# Herdr Agent Harness

WSL·Linux에서 Claude Code, Codex CLI, Antigravity(agy) 등 여러 에이전트를 Herdr
Pane에서 병렬로 운영하는 하네스입니다.

- **신뢰성**: 결과는 증빙과 교차 검토로만 인정합니다. 하네스가 검증 명령을 직접 실행해 기록하고, 다른 회사의 에이전트가 검토합니다.
- **자동화**: 사람은 방향·계획·완료만 결정하고, 나머지는 자동으로 진행합니다.
- **원격 자원**: SSH·SSHFS로 원격 서버의 빌드·테스트 환경을 씁니다.
- **비용**: 모델 등급(가벼운·보통·고급)과 쿼터 감시로 비싼 모델의 낭비를 줄입니다.

설치가 필요 없습니다. 프로젝트를 만들면 스크립트가 프로젝트 안(`.harness/bin/`)에 복사되므로,
bash·git·herdr만 있으면 그 프로젝트는 어디서든 동작합니다.
어디서나 짧게 부르고 탭 자동완성을 쓰려면 전역 명령 `herdr-harness`를 설치합니다(선택, [아래](#전역-명령과-자동완성-선택)).

## 요구 사항

- Ubuntu 22.04+ 또는 Windows 11 WSL2 (프로젝트는 `/mnt/c`보다 리눅스 홈 아래 권장)
- bash 4.4+, git(**전역 user.name/email 필요** — 하네스가 증빙을 commit합니다), herdr, coreutils(`timeout`, `sha256sum`)
- 에이전트 CLI 하나 이상: `claude`, `codex`, `agy`, 또는 herdr가 지원하는 다른 에이전트
- 선택: `jq`(codex 모델 목록 조회), `ssh`·`sshfs`·`sshpass`(원격 모드)

```bash
git config --global user.name  "이름"
git config --global user.email "메일"
```

## 빠른 시작

```bash
git clone <이 저장소> ~/herdr-agent-harness
~/herdr-agent-harness/harness.sh init ~/Projects/my-app --goal "멀티벤더 SNMP 데이터를 공통 스키마로 정규화" \
  --profile network-device            # generic | python-timeseries | network-device
cd ~/Projects/my-app
.harness/bin/harness.sh doctor        # 의존성 확인
.harness/bin/harness.sh start         # Herdr 밖: 프로젝트 세션 시작 / Herdr 안: 현재 세션에 프로젝트 workspace
```

Herdr 첫 Pane에서 Orchestrator 에이전트(기본 claude)를 실행하고 `AGENTS.md`의 "시작" 프롬프트를 입력합니다.
이후는 에이전트가 Skill을 따라 진행하고, 사람의 결정이 필요할 때만 묻습니다.
전역 명령을 설치했다면 `~/herdr-agent-harness/harness.sh`·`.harness/bin/harness.sh` 대신 `herdr-harness`라고 써도 됩니다.

`init` 주요 옵션:
- `--worker`·`--reviewer`·`--orchestrator`: 서로 다른 에이전트를 배정합니다. Worker와 Reviewer는 반드시 달라야 합니다.
- `--fallback claude,agy`: 교체 순서
- `--approval-mode ask|auto|bypass`: 도구 실행 승인 방식. auto의 claude 기본 인수는 `--permission-mode auto`(Claude Code auto 모드)입니다. `acceptEdits`는 편집만 자동 승인해 AC 실행 같은 명령마다 확인창에서 멈춥니다. 오래된 claude CLI가 이 모드를 모르면 `doctor`가 알립니다. 조직 정책·요금제 등으로 auto 모드가 꺼져 있으면 Claude가 확인창으로 돌아가 Worker가 멈출 수 있습니다. 그때는 `agents.claude_auto`에 다른 인수를 지정하거나, 작업 공간이 격리돼 있으면 bypass를 씁니다
- `--code-dir DIR`: 수정할 코드 저장소가 따로 있을 때

## 흐름

```text
요청 → BACKLOG → [사용자] SPEC 승인 → 계획(Milestone·Task·등급) → [사용자] 계획 승인
     → run: 착수 → 구현 → 증빙 → 교차 검토 → 통합 (실패 시 재작업, 최대 3회)
     → [사용자] Milestone 완료 승인 → 보관·태그·이력 → 다음 Milestone
       (반려하면 사유와 함께 재작업 → 다시 승인 대기)
```

| 사용자 결정 | 명령 (Orchestrator가 사용자의 명시 승인 뒤 실행) |
|---|---|
| 구현 방향 | `.harness/SPEC.md`의 `- 상태: approved` |
| 계획 | `approve-plan <milestone> --confirm-user-approval` — Task·등급·AC 지문을 기록하고 착수 허가 |
| 완료·배포 | `approve <milestone> --confirm-user-approval` — 완료 처리, 보관, git 태그 |
| 반려 | `reject <task> --reason "사유" --confirm-user-approval` — 사유를 기록하고 수정 요청으로. 다음 Worker·Reviewer가 사유를 받고, 재작업 상한은 새로 센다 |
| 에이전트 교체 | 기본은 사용자 승인. `project.yaml`의 `failover`에 규칙(`auto`)이 있으면 그대로 자동 교체 |
| 검토 수준 낮추기 | `review-level <수준> --reason "사유" --confirm-user-approval` — 한 회사만 쓸 수 있는 예외 (아래) |

## 신뢰성 — 스크립트가 강제하는 것

| 단계 | 통과 조건 |
|---|---|
| 착수 | 계획 승인 이후 AC가 바뀌지 않았고, 선행 Task가 통합됐고, 동시 Worker가 상한(기본 5) 이하이며, 통합 전 Task와 `write_scope`가 겹치지 않음 |
| 제출 | 아래를 모두 충족하면 하네스가 AC 명령을 Task 작업 공간에서 직접 실행하고 결과표를 Git 기록에 남긴 뒤 commit합니다 (하나라도 실패하면 거부):<br>· 정상 실행 기록이 있음<br>· Worker가 작업을 마침<br>· 보고서가 이번 실행 이후 작성됐고 모든 AC를 다룸 |
| 검토 | 같은 Provider 배정이면 검토 수준 예외(결정 기록)가 있어야 하고, 최신 시도에 AC 통과 증빙이 있음. 실제 독립성(Provider·모델)은 Reviewer dispatch와 승인 대기에서 판정 |
| 승인 대기 | dispatch된 최신 Review가 아래를 모두 충족한 뒤, 통합 상태에서 AC를 다시 돌려 본 브랜치에 반영합니다:<br>· APPROVED<br>· 최신 시도 대상<br>· 실제 Provider·모델 기록으로 판정한 검토 수준이 필요 수준 이상<br>· 모든 AC 대조 |
| 완료 | Milestone 승인 기록이 그 Task와 최신 Review를 가리킴 |

- 하네스가 띄운 에이전트 Pane에는 표식이 심깁니다. 그 Pane에서 상태 변경이나 승인을 시도하면 거부합니다.
- 끝난 결과도 `verify`로 다시 확인할 수 있습니다. 통합을 마친 Task나 보관된 Task의 AC 명령을 지금 코드에서 모두 다시 실행해 `verifications/`에 기록하고, 상태는 바꾸지 않습니다. 원격에 닿지 못하면 거짓 실패를 남기지 않도록 기록 없이 멈춥니다. 오래 걸리거나 부수효과가 있을 수 있어 사용자가 지시할 때만 돕니다.
- 지시서에 Secret 의심 패턴이 있으면 보내지 않습니다.
- 이 장치들은 가드레일이지 보안 경계가 아닙니다. 에이전트는 사용자와 같은 권한으로 돕니다.

## 한 회사만 쓸 수 있을 때 (예외)

기본은 다른 회사 에이전트의 교차 검토입니다. 회사 정책상 claude만 쓰거나, 다른 에이전트의 쿼터를 다 쓴 경우를 위해 검토 수준을 3단계로 둡니다.

| 수준 | 의미 |
|---|---|
| `cross_provider` (기본) | 다른 회사 에이전트가 검토 |
| `cross_model` | 같은 회사, **다른 모델**이 별도 세션으로 검토 (예: Worker sonnet, Reviewer opus) |
| `same_model` | 같은 모델, 별도 세션으로만 검토 |

**회사 정책 (상시):**
```bash
harness.sh init DIR --goal "..." --worker claude --reviewer claude --review-level cross_model --fallback claude
```
- 계속 유지할 제한은 `providers.available: [claude]`처럼 `project.yaml`(커밋됨)에 둡니다. `provider off`는 이 PC의 런타임에만 남는 일시 표시입니다.
- `project.yaml`에 `models.claude_standard: 'sonnet'`, `models.claude_premium: 'opus'`처럼 모델을 매핑하고, Reviewer 등급(또는 `reviewer_model`)을 Worker와 다르게 둡니다.
- 같은 모델이면 계획 승인이 거부됩니다.

**쿼터 소진 (일시):**
- 쿼터 소진이 감지되면 그 에이전트를 사용 불가로 자동 표시합니다. `provider off|on`으로 직접 표시하거나 해제할 수도 있습니다.
- 다른 회사 검토자를 구할 수 없을 때 `review.fallback_level`(기본 `none` = 멈추고 묻기)에 정한 수준까지만 자동으로 낮추고, 결정 기록을 남깁니다.
- 자동 하향을 켜는 것도 사용자 결정입니다: `review-level --fallback cross_model --reason "..." --confirm-user-approval`. 설정 줄만 고치면 무시됩니다.

**프롬프트 창에서 말로:** Orchestrator에게 "회사 작업이라 claude만 써", "codex 쿼터 다 썼어", "task-003 Reviewer는 opus로"라고 말하면, Orchestrator가 위 명령으로 반영합니다(harness-orchestrate Skill의 표).

**지켜지는 원칙**
- 기본보다 낮추는 것은 사용자 결정이나 미리 정한 규칙만 가능하고, 결정 기록(`decisions/review-level-*.md`)이 없으면 진행이 막힙니다.
- Task의 `review_level` 줄을 지우거나 고쳐도 낮아지지 않습니다. 결정 기록이 기준이고, 계획 승인 때의 수준보다 낮아지려면 그 뒤의 결정 기록이 있어야 합니다.
- 낮아진 검토 수준은 Review 기록, `status`의 승인 대기 표시, Milestone 요약에 그대로 드러납니다.
- 하네스의 AC 실행 증빙, 통합 후 재검증, 사용자 완료 승인은 어떤 수준에서도 그대로입니다.

## 병렬 작업과 작업 공간

- Task마다 git worktree(`.harness/worktrees/<task>`, 브랜치 `hh/<task>`)에서 작업합니다. 동시에 도는 Worker의 변경과 검증이 섞이지 않습니다.
- 교차 검토를 통과하면 본 브랜치를 Task 브랜치에 합치고, 검증을 다시 돌린 뒤 본 브랜치를 fast-forward합니다.
- 본 브랜치에는 **검증된 commit만** 들어갑니다. 검증 뒤 작업 공간에 생긴 변경(리뷰 중 테스트 산출물 등)은 버리고 기록합니다. 검증 뒤 생긴 commit이 있으면 통합하지 않습니다.
- 충돌하거나 통합 후 검증이 실패하면 수정 요청으로 돌아가 Worker가 해결합니다.
- 본 저장소에 커밋되지 않은 변경이 있으면 **통합 보류**로 멈춥니다. 사람이 정리한 뒤 다시 진행합니다.
- 원격 모드나 `isolation.worktree: false`처럼 한 폴더를 함께 쓰는 모드에서는 Task를 하나씩 통합까지 진행합니다.
- 원격 모드에서 SSHFS 마운트가 풀려 있으면(WSL 재시작 등) dispatch를 거부합니다.
- 상태 전이마다 `.harness/` 기록을 commit합니다. git 이력이 곧 전이 감사 기록입니다.

## 명령

프로젝트 안에서는 `.harness/bin/harness.sh <명령>`(전역 명령을 설치했으면 `herdr-harness <명령>`)을 씁니다. 다른 위치에서는 `-C DIR`을 붙입니다.

| 명령 | 설명 |
|---|---|
| `status` | Milestone 진행, Task 표, 에이전트 대조(DRIFT/ORPHAN), 사용자 판단 대기, BACKLOG 상위, 최근 완료, 지표 |
| `metrics` | 에이전트·등급별 시도·AC 통과·첫 시도 통과, Reviewer별 승인·반려 (진행 중 / 전체) |
| `validate` | 읽기 전용 일괄 검사 |
| `run <m> [--in-pane] [--max-minutes N]` | 사람 결정이 필요할 때까지 자동 진행. 한 Task가 막혀도 나머지는 계속 진행합니다 |
| `approve-plan <m>` / `approve <m>` / `reject <task> --reason ...` | 사용자 결정 기록 (`--confirm-user-approval` 필수) |
| `prune <m>` | 보관함을 요약만 남기고 정리 (원본은 git 태그 `<m>-approved`) |
| `verify <task>` / `verify --milestone <m>` / `verify --legacy` | AC 명령을 지금 코드에서 다시 실행해 기록 (상태는 바꾸지 않음). 통과 0, 실패 1, 재검증할 수 없음(진행 중·command AC 없음) 2 |
| `models [--refresh]` | 등급별 모델 매핑. `--refresh`는 agy·codex의 실제 모델 목록과 대조 |
| `review-level [수준] [--task T] [--fallback 수준] --reason ...` | 검토 수준 예외·자동 하향 허용. 낮추기·허용은 `--confirm-user-approval` 필수 |
| `provider list` / `provider off <p> --reason ...` / `provider on <p>` | 쿼터 소진·정책 등으로 못 쓰는 에이전트 표시 |
| `quota-check TASK [ROLE]` / `quota-check --provider agy` | 쿼터 확인 |
| `transition` `dispatch` `observe` `close` | 한 단계씩 진행 (run이 내부에서 사용) |
| `remote <하위 명령>` | 원격 모드 (아래) |
| `upgrade` | 최신 스크립트·Skill로 갱신 (아래) |
| `migrate` | v1 프로젝트를 v2로 이전 (저장소의 harness.sh, 아래) |
| `install [--replace-v1]` | 전역 명령 `herdr-harness` 설치 (저장소의 harness.sh, 아래). 탭 자동완성은 `~/.bashrc` 한 줄 |
| `doctor` `start` `help` | 점검, Herdr 세션 시작, 도움말 |

## 전역 명령과 자동완성 (선택)

```bash
~/herdr-agent-harness/harness.sh install                 # ~/.local/bin/herdr-harness
~/herdr-agent-harness/harness.sh install --replace-v1    # v1 설치본이 있던 자리면
grep -q 'herdr-harness completion bash' ~/.bashrc || echo 'source <(herdr-harness completion bash)' >> ~/.bashrc   # 탭 자동완성
```

- 저장소의 사본을 설치본(`~/.local/share/herdr-agent-harness/`, `XDG_DATA_HOME`이 있으면 그 아래 — v1과 같은 자리)에 두고 `~/.local/bin/herdr-harness`를 잇습니다. `~/.bashrc`는 건드리지 않습니다.
- 프로젝트 안(하위 폴더 포함)이나 `-C DIR`에서는 그 프로젝트의 `.harness/bin/harness.sh`로 넘깁니다.
  - 에이전트와 같은 버전으로 실행됩니다. 버전은 `upgrade`로만 바뀝니다.
  - Task 작업 공간(`.harness/worktrees/T`) 안에서는 바깥 프로젝트로 넘깁니다. 작업 공간의 `.harness`는 브랜치 시점 사본이라 상태가 옛것입니다.
  - v1 프로젝트면 `migrate`를, `.harness/bin/`이 없으면 `upgrade`를 안내하고 멈춥니다. 설치본·저장소의 `harness.sh`를 직접 불러도 v1 프로젝트는 다루지 않습니다.
- `init`·`upgrade`·`migrate`·`help`는 설치본이 실행합니다. 설치본으로 만들거나 올린 프로젝트는 설치본을 `harness_source`로 기록하고, 바뀔 때 알립니다.
- 사본을 쓰므로 저장소의 브랜치나 작업 중인 수정이 곧바로 모든 프로젝트의 명령에 섞이지 않습니다. 저장소를 고친 뒤에는 `install`을 다시 실행합니다.
- `upgrade`는 버전을 내리지 않습니다. 프로젝트가 설치본보다 새 버전이면(저장소로 올린 경우) 멈추고, `install`을 다시 하라고 안내합니다.
- 자동완성 후보:
  - 명령·하위 명령·옵션
  - 현재 프로젝트의 Task(상태·제목 표시)·Milestone·Provider
  - `transition`에서는 지금 상태에서 갈 수 있는 상태만
- 후보가 여럿이면 설명을 한 줄씩 보여 줍니다. 그 밖의 경우:
  - 후보를 명령줄에 바로 넣는 완성(menu-complete, M-\*)이나 후보가 40개를 넘으면 설명 없이 냅니다.
  - `HERDR_HARNESS_COMPLETION_DESCRIPTIONS=0`이면 늘 끕니다.
  - `.harness/bin/harness.sh`를 칠 때도 동작합니다.
- 다음 경우에는 바꾸지 않고 멈춥니다.
  - v1 설치본 자리: `--replace-v1`이 필요합니다(v1에 직접 고친 내용은 사라짐)
  - Harness 설치본이 아닌 폴더: 저장소 clone, 표식(`INSTALLED`) 없는 사본, 읽을 수 없는 폴더
  - 다른 프로그램을 가리키는 `herdr-harness` 링크
  - 쓸 수 없는 `~/.local/bin`
- 새 사본을 옆에 만들고 링크까지 바꾼 뒤에야 옛 사본을 지웁니다. 도중에 실패하거나 끊기면 원래 설치본과 링크로 되돌립니다.

## 모델 등급과 쿼터

`.harness/project.yaml`에서 에이전트별로 등급별 모델과 생각 깊이를 정합니다.

```yaml
models:
  default_tier: 'standard'
  default_effort: ''          # low | medium | high
  claude_light: ''            # 비우면 Provider 기본 모델
  claude_standard: ''
  claude_premium: ''
  codex_premium: ''
```

**등급 기준**

| 등급 | 맡길 일 |
|---|---|
| light | 기계적 변경 |
| standard | 정해진 설계의 일반 구현 |
| premium | 설계 판단·보안·상태 전이·원인 추적 |

- 계획 담당 에이전트가 Task마다 등급을 근거와 함께 제안합니다.
- 특정 모델이 필요하면 Task에 `worker_model`·`reviewer_model`을 직접 적습니다(등급보다 우선). premium 매핑 모델이나 매핑에 없는 모델은 계획 승인 표에 적힌 경우에만 쓰입니다.
- Worker·Reviewer 화면에서 직접 `/model`로 바꾸지 마세요. 증빙 기록과 실제 모델이 어긋납니다.
- premium은 계획 승인 때 사용자가 함께 승인한 Task만 실행됩니다.
- 에이전트가 비정상으로 멈췄을 때(막힘·사라짐·보고서 없음) 화면에 한도 소진 문구가 있으면 쿼터 소진으로 봅니다. 교체 규칙이 있으면 예비 에이전트로 넘기고, 없으면 그 Task를 멈춥니다.
- 정상으로 끝난 작업 화면의 `429`·rate limit 문구(테스트 출력 등)는 무시합니다.
- "N% of your weekly limit"는 사용량 경고로 기록만 합니다.

다른 에이전트를 추가하려면 `providers.available`에 herdr kind 이름을 넣고, 필요하면 아래를 설정합니다.
- `agents.<kind>_auto` / `<kind>_bypass`: 승인 모드 인수
- `agents.<kind>_effort_flag`: 생각 깊이 플래그
- `models.<kind>_<등급>`: 등급별 모델

## 원격 모드

에이전트는 로컬에서 돌고, 원격 서버는 소스(SSHFS 마운트)와 빌드·테스트·VCS 실행만 맡습니다.

```bash
.harness/bin/harness.sh remote setup      # 최초 1회: 호스트·계정·경로 입력, 비밀번호 1회로 SSH 키 등록
.harness/bin/harness.sh remote doctor     # 연결·도구·마운트 진단
.harness/bin/harness.sh remote mount      # 원격 소스를 로컬에 마운트 (이 경로가 코드 디렉터리가 된다)
.harness/bin/harness.sh remote run 'make -j4 && ctest'
```

- 원격 모드가 켜지면 AC 검증도 원격에서 실행됩니다.
- 원격 명령(ssh)은 호출한 쪽의 표준 입력을 읽지 않습니다(`-n`). 반복문 안에서 불러도 다음 입력을 먹지 않습니다. v1은 이 결함 때문에 원격 모드에서 첫 번째 AC만 실행됐습니다.
- 비밀번호는 파일에 저장하지 않습니다. 키 등록 때 한 번만 `HH_REMOTE_PASSWORD`로 넘깁니다.
- 설정 정본은 `.harness/remote.yaml`입니다.
- `mount_options`로 sshfs에 `-o` 옵션을 더합니다(쉼표로 구분, `remote setup --mount-options`로도 지정).
  - 예: 원격의 절대경로 심볼릭 링크가 로컬에서 끊겨 보이면 `mount_options: 'follow_symlinks'`
  - 허용 목록의 옵션만 받습니다: 심볼릭 링크(`follow_symlinks`·`transform_symlinks`), `idmap`·`uid`·`gid`·`umask`, cache 계열, `compression`, `reconnect`, `Port`, `ServerAlive*`, `ConnectTimeout` 등.
  - `ssh_command`·`ProxyCommand`처럼 명령을 실행하거나 `directport`·`allow_other`처럼 보안을 낮추는 옵션은 거부합니다.
  - 바꾼 뒤에는 `remote unmount` → `remote mount`로 다시 마운트합니다.

## 장기 운영

| 단계 | 파일 |
|---|---|
| 아이디어·요청 | `.harness/BACKLOG.md` |
| 확정된 계획 | `.harness/MILESTONES.md` |
| 진행 중 | `.harness/tasks/` 등 |
| 완료 | `.harness/archive/<m>/` + `HISTORY.md` |

- Milestone을 승인하면 관련 파일을 보관함으로 옮기고, 요약(`SUMMARY.md`, 지표 포함)·git 태그·이력 한 줄을 남깁니다. 원문 로그(`.harness/runtime/`, Git 제외)는 지웁니다.
- 지시서에는 현재 Task와 직전 라운드만 들어가므로, 작업 기간이 길어져도 에이전트 토큰 사용량이 늘지 않습니다.
- 오래된 보관함은 `prune`으로 요약만 남깁니다. 원본은 `git show <m>-approved:<경로>`로 복원합니다.

## 업데이트·패치

```bash
.harness/bin/harness.sh upgrade                     # 프로젝트 안에서: harness_source(저장소면 pull) 기준으로 bin·Skill 갱신
~/herdr-agent-harness/harness.sh upgrade ~/Projects/a ~/Projects/b   # 여러 프로젝트를 한 번에
herdr-harness upgrade                               # 전역 명령: 설치본 버전으로 (프로젝트 안, DIR 없이)
```

- 전역 명령을 쓰면 순서는 저장소 갱신 → `~/herdr-agent-harness/harness.sh install` → 프로젝트마다 `herdr-harness upgrade`입니다.
- 버전 변화(`2.0.0 → 2.x`)와 바뀐 파일을 보여 줍니다. `git diff`로 확인한 뒤 commit합니다.
- 프로젝트에서 bin이나 Skill을 직접 고쳤고 아직 commit하지 않았다면 덮어쓰지 않습니다. 그런 수정은 저장소에 반영합니다.
- 갱신하지 않는 파일: `AGENTS.md`, SPEC, 템플릿처럼 프로젝트 고유 내용이 있는 파일
- 패치는 저장소의 해당 `lib/*.sh` 하나만 고치면 됩니다. 빌드 단계는 없습니다.

## 저장소 구성

```text
harness.sh          진입점 (명령 분기)
lib/core.sh         공통 함수, 설정 읽기, 경로, AC 파서, git 작업 공간
lib/gates.sh        상태 전이·증빙·교차 검토·통합·계획/Milestone 승인·보관
lib/agents.sh       dispatch · observe · close (herdr)
lib/packet.sh       에이전트에게 주는 지시서
lib/models.sh       모델 등급·생각 깊이, 쿼터 확인
lib/auto.sh         자동 진행(run), 교체 규칙
lib/remote.sh       원격 모드
lib/status.sh       status · metrics · validate · doctor
lib/project.sh      init · upgrade · start · install
lib/verify.sh       재검증 (verify)
lib/migrate.sh      v1 프로젝트 이전 (migrate)
bin/herdr-harness   전역 명령 (install이 설치, 프로젝트 안에서는 그 프로젝트의 사본으로 넘김)
bin/completion.bash Bash 탭 자동완성 (herdr-harness completion bash)
templates/project/  프로젝트 골격: AGENTS.md, Skill 6개, project.yaml, SPEC·MILESTONES·BACKLOG, Task·Intent 템플릿
test.sh             자체 테스트 (가짜 herdr·ssh, 임시 폴더에서 실행 후 삭제)
```

## 자체 테스트

```bash
./test.sh       # 실제 에이전트·네트워크·쿼터를 쓰지 않습니다. 입력을 기다리지 않습니다.
```

다음을 가짜 herdr와 ssh로 끝까지 검사합니다.
- 생성 → 계획 승인·계약 고정 → 작업 공간 분리
- 증빙·교차 검토·통합
- 자동 진행(기동 실패 → 자동 교체 포함)
- Milestone 승인·보관·정리
- 병렬 상한·범위 충돌·premium 승인·재작업 상한
- 원격 모드(마운트 옵션·허용 목록 포함, 가짜 sshfs)
- 업그레이드(버전을 내리지 않음, 링크로 가리킨 저장소의 pull 포함)
- 전역 명령 (아래 항목을 모두 확인):
  - 설치·갱신·거부 조건, 실패 시 되돌리기
  - 프로젝트 사본으로 넘기기(작업 공간 안 포함)
  - 자동완성 후보, 그리고 자동완성 목록(명령·옵션·상태)이 harness.sh와 맞는지 대조
- 재검증, v1 이전 (아래 항목을 모두 확인):
  - 사전 점검이 아무것도 바꾸지 않음
  - 차단 조건
  - 실패 시 자동 원상복구 (Git 밖 파일 포함, 다른 파일의 진행 중 수정은 남김)
  - 강제 종료 뒤 `--rollback`, 병합 전 `--undo`
  - 중단: Ctrl-C(종료 코드 130), 출력 파이프 끊김(141), 맨 위 셸만 강제 종료된 뒤 남은 `mv`가 끝나기 전의 `--rollback` 거부(잠금), 줄바꿈 없이 끝난 기록 줄
  - 여러 묶음으로 나눠 옮기기, 깊은 빈 폴더 정리와 되돌릴 때 다시 만들기, Git 밖 항목 목록(없거나 바뀌면 `--undo` 거부)
  - runtime의 v1 파일과 사용자 파일 구분, 참조 검사가 실패하면 차단, 저장소 상태로 막히면 계획을 건너뜀
  - 경고: AC의 상위 폴더 상대경로, 프로젝트 밖 write_scope, 링크가 아닌 Skill 폴더, 프로젝트 폴더에서 도는 프로세스·Claude 예약 작업
  - 내용을 바꾸는 commit hook, `.gitignore` 규칙, 링크인 진입 문서, 사용자 git 설정
  - 옮긴 파일의 해시 대조와 목록 독립 재대조
  - 마운트·작업 공간 폴더에 들어가지 않음

## 이전 버전(v1)에서

v1(`~/.local/share/herdr-agent-harness`, `herdr-harness` 명령)으로 만든 프로젝트는 `migrate`로 v2로 옮깁니다. Task와 Task 사이처럼 에이전트가 돌지 않을 때 실행합니다.

```bash
~/herdr-agent-harness/harness.sh migrate ~/workspace/AI_SW          # 사전 점검 보고서만 (아무것도 바꾸지 않음)
~/herdr-agent-harness/harness.sh migrate ~/workspace/AI_SW --apply --confirm-user-approval \
  --review-level cross_model --reason "회사 정책: claude만" \
  --complete task-020,task-021 --complete-reason "D-9: 사용자 완료 인정"   # 사용자 결정은 인수로
```

| v1 | v2 |
|---|---|
| 완료 Task | `.harness/archive/v1-<milestone>/`로 보관합니다. 요약에 증빙 등급을 남깁니다: 마지막 AC 실행이 command AC를 모두 통과했는지, 일부만 실행됐는지 |
| 제출·검토 중·승인 대기 Task | `--complete`로 사용자가 지정한 것만 완료로 보관합니다. 나머지는 draft로 돌아가 v2에서 다시 증빙합니다(v2 승인 대기로 옮기지 않음) |
| 그 밖의 열린 Task | draft로 돌아갑니다. v1 시도 기록은 보관합니다. 계약을 보완하고 `approve-plan`부터 다시 밟습니다 |
| `project.yaml` + `policies/` | v2 `project.yaml` 하나로 합칩니다. 다음 값은 그대로 옮깁니다:<br>· 동시 Worker 상한·AC 제한 시간·승인 모드<br>· 모델(기본 모델 → 등급 매핑)<br>· 바꾼 Provider 인수 |
| `STATE.md`·`waves/`·`evidence/`·`.agents/roles/`·v1 Skill 등 | `.harness/archive/v1/` (원래 경로 그대로) |
| `AGENTS.md`·`CLAUDE.md`·`GEMINI.md`·`HARNESS_START.md` | 덮어쓰지 않고 끝에 v2 운영 규칙(또는 안내) 절만 덧붙입니다. AGENTS.md가 다른 진입 문서를 가리키는 링크면 그 문서에 규칙 절을 넣습니다 |

안전장치는 다음과 같습니다.
- **차단 조건**: 다음 중 하나라도 있으면 적용하지 않습니다.
  - 커밋되지 않은 변경, Harness 경로의 커밋되지 않은 새 파일
  - Git이 강제로 추적하는 v1 원문 로그(`evidence/raw`) — `git rm --cached`로 추적을 풀면 됩니다(파일은 남습니다)
  - Herdr에 남은 v1 에이전트
  - 읽을 수 없는 폴더
  - 같은 회사 Task가 있는데 검토 수준 결정이 없음
  - 참조 검사를 끝내지 못함(메모리 부족 등) — 참조가 없다고 보고 넘어가지 않습니다
  - 저장소 상태로 막히는 조건은 계획(파일 분류·참조 검사) 전에 몇 초 만에 알립니다.
- **규모**: `evidence/raw` 원문 로그처럼 파일이 수십만 개여도 됩니다. 분류는 해시 조회, 참조 검사는 GNU `grep -F`, 옮기기·되돌리기는 작업 기록을 먼저 쓰고 `xargs`로 묶어서 합니다. 진행 상황을 표시합니다. 파일 49만 개 프로젝트 실측: 사전 점검 약 6분, 이전 약 15분, 되돌리기 약 6분, 메모리 약 1GB.
- **참고(경고)**: 보고서에 다음을 알립니다.
  - AC에 상위 폴더 상대경로(`cd ../repo`)가 있는 열린 Task — v2는 AC를 Task 작업 공간(`.harness/worktrees/T`)에서 실행하므로 가리키는 곳이 달라집니다. 절대경로로 바꾸거나 `isolation.worktree: false`로 둡니다.
  - 프로젝트 밖을 가리키는 write_scope — v2의 작업 공간 격리·통합은 이 저장소에만 적용됩니다.
  - 링크가 아닌 `.claude/skills/<harness-*>` 폴더 — v2 Skill 대신 옛 Skill이 읽힙니다.
  - 프로젝트 폴더에서 도는 다른 프로세스와 Claude 예약 작업(`.claude/scheduled_tasks.lock`) — 적용 중에 파일을 바꿀 수 있습니다.
  - runtime의 v1 시절 스크립트(`herdr-harness`를 부르는 것) — v2에서는 명령 형식이 달라 실패합니다.
- **되돌리기**: 시작 commit에 태그 `harness-v1-final`을 달고, 새 브랜치 `harness-v2-migration`에 commit 하나로 남깁니다.
  - 도중에 실패하면 작업 기록을 거꾸로 되짚어 시작 상태로 되돌립니다. 이때 이전이 손댄 경로만 되돌리므로, 저장소의 다른 파일에서 진행 중이던 수정은 그대로 남습니다.
  - 강제 종료 등으로 끊겼다면 `migrate DIR --rollback`으로 기록대로 되돌립니다.
    - 여러 번 실행해도 안전합니다.
    - 강제 종료 뒤 남은 `mv`가 아직 돌고 있으면 끝날 때까지 거부합니다(`.git/harness-migrate.lock`). 보관 폴더는 통째로 지우지 않고, 파일이 남아 있으면 멈춥니다.
    - Ctrl-C·터미널 닫힘·출력 파이프 끊김으로 끝나도 원상복구하고, 원상복구 중에는 이것들로 멈추지 않습니다.
    - 끊긴 뒤 이전 브랜치에 commit이 쌓였으면 그 작업을 지우지 않도록 거부합니다.
    - 끊긴 기록이 남아 있으면 v2 `validate`가 알려 줍니다.
  - 성공한 이전을 본 브랜치에 병합하기 전에 되돌리려면 `migrate DIR --undo --confirm-user-approval`을 씁니다. Git 밖으로 옮긴 파일과 지운 빈 폴더까지 제자리로 돌아옵니다.
- **무손실 확인**:
  - 옮기기 전후 모든 파일의 해시를 대조합니다. Git이 추적하는 파일의 목록은 `.harness/archive/v1/MANIFEST.txt`로 commit합니다.
  - Git 밖 항목(원문 로그·런타임·지운 빈 폴더)의 목록은 `.harness/archive/v1/MANIFEST-untracked.txt`에 둡니다. 이 파일은 Git에 올리지 않고(`.gitignore`), `--undo`가 읽습니다. 수십만 줄일 수 있어 Git에 넣지 않습니다.
  - Git 추적 여부도 바뀌지 않습니다. 바뀔 것 같으면(`.gitignore` 규칙) 사전 점검에서 막습니다.
  - Git이 추적하지 않는 파일은 제자리에서 고치지 않습니다(실패 때 되돌릴 수 없으므로 막습니다).
  - commit hook이 내용을 바꾸면(포맷터 등) 대조한 내용과 달라지므로 되돌립니다.
  - 이전 직후 `validate`·`status`가 통과해야 commit합니다.
- **참조 보존**: 열린 Task·Intent·결정·사용자 문서가 경로로 가리키는 v1 기록은 원래 자리에 둡니다. v1 운영 파일이거나 v2와 이름이 겹쳐 둘 수 없는 것은 옮기고, 끊기는 참조를 보고서에 새 위치와 함께 적습니다.
- **건드리지 않는 곳**: 원격 마운트와 `.harness/worktrees/`. 응답 없는 마운트(끊긴 SSHFS)가 있으면 멈추는 대신 막습니다. 런타임 폴더는 최상위의 v1 Agent 추적·지시문·로그(`T-worker.meta`, `T-reviewer.md` 등)만 `runtime/v1/`로 옮깁니다(Git 밖). 사용자가 둔 런타임 파일(접속 정보 `.env`, 스크립트 등)은 문서가 그 경로를 가리킬 수 있어 그대로 둡니다. v1이 만든 것만 옮기고, 사용자가 둔 파일과 Skill, 링크인 진입 문서는 그대로 둡니다.
- **이전 뒤 할 일**은 `.harness/archive/v1/MIGRATION.md`에 정리됩니다. 주로 다음 두 가지입니다.
  - `verify --legacy`: 증빙이 불완전한 v1 완료 Task를 다시 검증합니다.
  - Milestone별 `approve-plan`
- v1의 `herdr-harness` 명령은 `install --replace-v1`이 v2 전역 명령으로 바꿉니다. `~/.bashrc`의 `source <(herdr-harness completion bash)` 줄은 그대로 두면 v2 자동완성을 불러옵니다.
- 전역 명령 없이 쓰려면:
  - `rm -rf ~/.local/share/herdr-agent-harness ~/.local/bin/herdr-harness` (`XDG_DATA_HOME`을 쓰면 `$XDG_DATA_HOME/herdr-agent-harness`)
  - `~/.bashrc`에서 `source <(herdr-harness completion bash)` 줄(v1 install이 넣었다면 `herdr-harness bash completion` 표시가 붙은 블록)을 삭제
  - 설치본으로 만들거나 올린 프로젝트는 `harness_source`가 설치본입니다. 지운 뒤에는 저장소의 harness.sh로 한 번 `upgrade`해 `harness_source`를 저장소로 되돌립니다. 그래야 프로젝트 안의 `upgrade`가 멈추지 않습니다.

## 라이선스

[MIT](LICENSE)

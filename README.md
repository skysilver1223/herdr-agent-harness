# Herdr Agent Harness

WSL·Linux에서 Claude Code, Codex CLI, Antigravity(agy) 등 여러 에이전트를 Herdr
Pane에서 병렬로 운영하는 하네스입니다.

- **신뢰성**: 결과는 증빙과 교차 검토로만 인정합니다. 하네스가 검증 명령을 직접 실행해 기록하고, 다른 회사의 에이전트가 검토합니다.
- **자동화**: 사람은 방향·계획·완료만 결정하고, 나머지는 자동으로 진행합니다.
- **원격 자원**: SSH·SSHFS로 원격 서버의 빌드·테스트 환경을 씁니다.
- **비용**: 모델 등급(가벼운·보통·고급)과 쿼터 감시로 비싼 모델의 낭비를 줄입니다.

설치가 필요 없습니다. 프로젝트를 만들면 스크립트가 프로젝트 안(`.harness/bin/`)에 복사되므로,
bash·git·herdr만 있으면 그 프로젝트는 어디서든 동작합니다.

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
.harness/bin/harness.sh start         # 이 프로젝트로 Herdr 세션 시작
```

Herdr 첫 Pane에서 Orchestrator 에이전트(기본 claude)를 실행하고 `AGENTS.md`의 "시작" 프롬프트를 입력합니다.
이후는 에이전트가 Skill을 따라 진행하고, 사람의 결정이 필요할 때만 묻습니다.

`init` 주요 옵션:
- `--worker`·`--reviewer`·`--orchestrator`: 서로 다른 에이전트를 배정합니다. Worker와 Reviewer는 반드시 달라야 합니다.
- `--fallback claude,agy`: 교체 순서
- `--approval-mode ask|auto|bypass`: 도구 실행 승인 방식
- `--code-dir DIR`: 수정할 코드 저장소가 따로 있을 때

## 흐름

```text
요청 → BACKLOG → [사용자] SPEC 승인 → 계획(Milestone·Task·등급) → [사용자] 계획 승인
     → run: 착수 → 구현 → 증빙 → 교차 검토 → 통합 (실패 시 재작업, 최대 3회)
     → [사용자] Milestone 완료 승인 → 보관·태그·이력 → 다음 Milestone
```

| 사용자 결정 | 명령 (Orchestrator가 사용자의 명시 승인 뒤 실행) |
|---|---|
| 구현 방향 | `.harness/SPEC.md`의 `- 상태: approved` |
| 계획 | `approve-plan <milestone> --confirm-user-approval` — Task·등급·AC 지문을 기록하고 착수 허가 |
| 완료·배포 | `approve <milestone> --confirm-user-approval` — 완료 처리, 보관, git 태그 |
| 에이전트 교체 | 기본은 사용자 승인. `project.yaml`의 `failover`에 규칙(`auto`)이 있으면 그대로 자동 교체 |

## 신뢰성 — 스크립트가 강제하는 것

| 단계 | 통과 조건 |
|---|---|
| 착수 | 계획 승인 이후 AC가 바뀌지 않았고, 선행 Task가 통합됐고, 동시 Worker가 상한(기본 5) 이하이며, 통합 전 Task와 `write_scope`가 겹치지 않음 |
| 제출 | 아래를 모두 충족하면 하네스가 AC 명령을 Task 작업 공간에서 직접 실행하고 결과표를 Git 기록에 남긴 뒤 commit합니다 (하나라도 실패하면 거부):<br>· 정상 실행 기록이 있음<br>· Worker가 작업을 마침<br>· 보고서가 이번 실행 이후 작성됐고 모든 AC를 다룸 |
| 검토 | Reviewer가 Worker와 다른 Provider이고, 최신 시도에 AC 통과 증빙이 있음 |
| 승인 대기 | dispatch된 최신 Review가 아래를 모두 충족한 뒤, 통합 상태에서 AC를 다시 돌려 본 브랜치에 반영합니다:<br>· APPROVED<br>· 최신 시도 대상<br>· 다른 Provider<br>· 모든 AC 대조 |
| 완료 | Milestone 승인 기록이 그 Task와 최신 Review를 가리킴 |

- 하네스가 띄운 에이전트 Pane에는 표식이 심깁니다. 그 Pane에서 상태 변경이나 승인을 시도하면 거부합니다.
- 지시서에 Secret 의심 패턴이 있으면 보내지 않습니다.
- 이 장치들은 가드레일이지 보안 경계가 아닙니다. 에이전트는 사용자와 같은 권한으로 돕니다.

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

프로젝트 안에서는 `.harness/bin/harness.sh <명령>`을 씁니다. 다른 위치에서는 `-C DIR`을 붙입니다.

| 명령 | 설명 |
|---|---|
| `status` | Milestone 진행, Task 표, 에이전트 대조(DRIFT/ORPHAN), 사용자 판단 대기, BACKLOG 상위, 최근 완료, 지표 |
| `metrics` | 에이전트·등급별 시도·AC 통과·첫 시도 통과, Reviewer별 승인·반려 (진행 중 / 전체) |
| `validate` | 읽기 전용 일괄 검사 |
| `run <m> [--in-pane] [--max-minutes N]` | 사람 결정이 필요할 때까지 자동 진행. 한 Task가 막혀도 나머지는 계속 진행합니다 |
| `approve-plan <m>` / `approve <m>` | 사용자 결정 기록 (`--confirm-user-approval` 필수) |
| `prune <m>` | 보관함을 요약만 남기고 정리 (원본은 git 태그 `<m>-approved`) |
| `models [--refresh]` | 등급별 모델 매핑. `--refresh`는 agy·codex의 실제 모델 목록과 대조 |
| `quota-check TASK [ROLE]` / `quota-check --provider agy` | 쿼터 확인 |
| `transition` `dispatch` `observe` `close` | 한 단계씩 진행 (run이 내부에서 사용) |
| `remote <하위 명령>` | 원격 모드 (아래) |
| `upgrade` | 최신 스크립트·Skill로 갱신 (아래) |
| `doctor` `start` `help` | 점검, Herdr 세션 시작, 도움말 |

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
- 비밀번호는 파일에 저장하지 않습니다. 키 등록 때 한 번만 `HH_REMOTE_PASSWORD`로 넘깁니다.
- 설정 정본은 `.harness/remote.yaml`입니다.

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
.harness/bin/harness.sh upgrade                     # 프로젝트 안에서: 저장소 pull 후 bin·Skill 갱신
~/herdr-agent-harness/harness.sh upgrade ~/Projects/a ~/Projects/b   # 여러 프로젝트를 한 번에
```

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
lib/project.sh      init · upgrade · start
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
- 원격 모드
- 업그레이드

## 이전 버전(v1)에서

- v1(`~/.local/share/herdr-agent-harness`, `herdr-harness` 명령)으로 만든 프로젝트는 그 설치본으로 계속 운영할 수 있습니다. v2는 v1 프로젝트 구조(`policies/`, `evidence/`, `STATE.md`)를 읽지 않습니다.
- v1을 지우려면:
  - `rm -rf ~/.local/share/herdr-agent-harness ~/.local/bin/herdr-harness`
  - `~/.bashrc`에서 `herdr-harness bash completion` 블록을 삭제

## 라이선스

[MIT](LICENSE)

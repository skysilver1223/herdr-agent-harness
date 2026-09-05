#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

usage() {
  cat <<EOF
Herdr Agent/Skills Harness

사용법:
  $SCRIPT_NAME init PATH [옵션]   새 프로젝트 Harness 생성
  $SCRIPT_NAME start [PATH]       Herdr Session 시작
  $SCRIPT_NAME status [PATH]      현재 STATE.md 출력
  $SCRIPT_NAME status --live      문서·Herdr·Git 상태 대조 (DRIFT 표시)
  $SCRIPT_NAME doctor             설치 상태 확인
  $SCRIPT_NAME test               Agent 쿼터 없는 자체 테스트
  $SCRIPT_NAME uninstall [--yes]  설치된 Harness 명령 제거

Agent Loop 스텝 명령 (호출 1회 = 1스텝, 상주 루프 없음):
  $SCRIPT_NAME validate [PATH] [--wave ID]        읽기 전용 사전 검증
  $SCRIPT_NAME transition PATH TASK_ID TO_STATE   상태 전이 강제
  $SCRIPT_NAME dispatch PATH TASK_ID ROLE         Agent 한 턴 실행
  $SCRIPT_NAME observe PATH TASK_ID [ROLE]        기존 Agent 재조회
  $SCRIPT_NAME close-agent PATH TASK_ID [ROLE]    Harness가 만든 Pane 정리
  $SCRIPT_NAME quota-check PATH TASK_ID ROLE       실행 중인 Agent의 쿼터 확인(claude/codex는 /status, agy는 --print)
  $SCRIPT_NAME quota-check PATH --provider agy    Task 없이 agy 쿼터만 바로 확인

init 옵션:
  --name NAME                     프로젝트명
  --goal TEXT                     프로젝트 목표
  --profile PROFILE               generic | python-timeseries | network-device
  --orchestrator PROVIDER         claude | codex | agy
  --worker PROVIDER               claude | codex | agy
  --reviewer PROVIDER             claude | codex | agy
  --fallback PROVIDERS            쉼표 구분 Provider 목록

예시:
  $SCRIPT_NAME init ~/Projects/snmp-normalizer \
    --name snmp-normalizer \
    --goal "멀티벤더 SNMP 데이터를 공통 스키마로 정규화" \
    --profile network-device
EOF
}

die() {
  printf '오류: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[herdr-harness] %s\n' "$*"
}

valid_provider() {
  case "$1" in claude|codex|agy) return 0 ;; *) return 1 ;; esac
}

valid_profile() {
  case "$1" in generic|python-timeseries|network-device) return 0 ;; *) return 1 ;; esac
}

yaml_quote() {
  local value="$1"
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

write_file() {
  local root="$1"
  local relative="$2"
  local destination="$root/$relative"
  local parent temporary
  parent="$(dirname "$destination")"
  mkdir -p "$parent"
  [[ ! -e "$destination" ]] || die "기존 파일을 덮어쓰지 않습니다: $destination"
  temporary="$(mktemp "$parent/.harness-write.XXXXXX")"
  cat >"$temporary"
  chmod 0644 "$temporary"
  mv "$temporary" "$destination"
}

prompt_required() {
  local variable="$1" label="$2" value=""
  if [[ ! -t 0 ]]; then
    die "비대화형 실행에서는 값을 물어볼 수 없습니다. 해당 값을 옵션으로 전달하세요: $label"
  fi
  while [[ -z "$value" ]]; do
    read -r -e -p "$label: " value || die "입력을 읽지 못했습니다: $label"
  done
  printf -v "$variable" '%s' "$value"
}

prompt_default() {
  local variable="$1" label="$2" default="$3" value=""
  read -r -e -p "$label [$default]: " value
  printf -v "$variable" '%s' "${value:-$default}"
}

emit_doc() {
  local root="$1" relative="$2"
  sed -e "s|@@WORKER@@|${DOC_WORKER}|g" \
      -e "s|@@REVIEWER@@|${DOC_REVIEWER}|g" \
      -e "s|@@ORCHESTRATOR@@|${DOC_ORCHESTRATOR}|g" \
      -e "s|@@FALLBACK@@|${DOC_FALLBACK}|g" \
      -e "s|@@NAME@@|${DOC_NAME}|g" \
    | write_file "$root" "$relative"
}

write_project_docs() {
  local root="$1"
  DOC_NAME="$2" DOC_ORCHESTRATOR="$3" DOC_WORKER="$4" DOC_REVIEWER="$5" DOC_FALLBACK="$6"

  emit_doc "$root" ".agents/skills/harness-interview/SKILL.md" <<'HARNESS_DOC_EOF'
---
name: harness-interview
description: 모호한 요구사항과 기존 자산을 인터뷰하여 정형화된 SPEC 초안을 작성한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-interview

모호한 사용자 요구와 기존 자산을 인터뷰하여 정합성 있는 `.harness/SPEC.md` 초안을 작성하고 승인을 준비한다.

## 1. 사전조건
- 프로젝트 디렉터리가 초기화되어 `.harness/`가 존재해야 한다.
- `.harness/SPEC.md`의 상태가 `draft`이거나 신규 인터뷰가 요구되는 상태여야 한다.

## 2. 읽어야 할 파일 목록
다음 순서대로 파일을 정독하여 정책과 기존 정보를 확인한다.
1. `AGENTS.md`
2. `.harness/project.yaml`
3. `.agents/roles/interviewer.agent.md`
4. `.harness/policies/project-policy.yaml`
5. `.harness/SPEC.md`

## 3. 절차
1. 작업 디렉터리 내 기존 소스코드, 데이터 덤프, 사양 문서, MIB 파일 유무를 파일시스템 도구로 탐색한다.
2. 기존 자산이 확인되면 재사용 가능 여부와 제약사항을 정리한다.
3. 사용자에게 한 번에 2~4개 이하의 핵심 질문만 전달하여 요구사항과 범위를 좁힌다.
4. 인터뷰 결과를 종합하여 `.harness/SPEC.md`의 7대 섹션을 충실히 작성한다.
   - 핵심 목표
   - 기존 자료와 재사용 판단 (Confirmed, Inferred, Unknown 분류)
   - 기술 스택 및 제약 (언어, 런타임, 변경 금지 영역)
   - 요구사항 (기능 및 비기능)
   - Acceptance Criteria (각 기준마다 검증 명령/수단 필수 연결)
   - 제외 범위 (Out of Scope)
   - 사용자 승인란 (상태는 `draft` 유지)
5. `git diff .harness/SPEC.md`로 변경 내용을 검토한다.
6. 작성된 SPEC 초안을 사용자에게 제시하고 명시적 승인을 요청한다.

## 4. 중단·승인 요청 조건
- 기존 자산 분석 중 권한 문제나 포맷 불명확으로 분석이 불가한 경우 즉시 중단하고 질문한다.
- SPEC 초안 작성이 완료되면 에이전트 스스로 구현이나 계획 분할에 착수하지 말고 즉시 멈추고 사용자 승인을 요청한다.

## 5. 산출물
- `.harness/SPEC.md`: 7대 섹션이 누락 없이 채워진 정형 사양서 초안

## 6. 결과 계약
작업 종료 시 사용자에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS 또는 BLOCKED
- 산출물경로: .harness/SPEC.md
- 검증결과: 7대 섹션 작성 완료 및 Acceptance Criteria별 검증 방법 매핑 여부
- 차단사유: 없음 (차단 시 구체적 질문 및 차단 요인 기술)

## 7. 사후조건 체크리스트
- [ ] SPEC.md 내 모호한 TODO나 TBD가 방치되지 않았는가?
- [ ] Acceptance Criteria마다 실행 가능한 검증 방법이 매핑되었는가?
- [ ] 소스코드를 수정하지 않고 사양 문서만 변경하였는가?
- [ ] 승인 상태가 임의로 approved로 바뀌지 않고 draft를 유지하는가?

## 8. 멱등성 규칙
- 이미 작성된 SPEC.md가 존재하더라도 기존 섹션을 무단 초기화하지 않는다.
- 추가 인터뷰 시 기존 확인 사항은 보존하고 변경 및 추가 요구사항만 업데이트한다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/skills/harness-reference/SKILL.md" <<'HARNESS_DOC_EOF'
---
name: harness-reference
description: 기존 코드, 데이터, 문서, Dump를 탐색하고 목록화하여 Reference Inventory를 작성한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-reference

프로젝트 내외의 기존 자산을 체계적으로 수집·분류하고 재사용 가능성과 제약사항을 `.harness/references/inventory.md`에 기록한다.

## 1. 사전조건
- 프로젝트가 초기화되어 있고 Git 저장소가 유효해야 한다.
- 요구사항 인터뷰 전후 또는 Task 구현 전 기존 자산 조사가 필요한 상태여야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.harness/project.yaml`
3. `.agents/roles/interviewer.agent.md`
4. `.harness/SPEC.md`
5. `.harness/references/inventory.md`

## 3. 절차
1. 프로젝트 루트 및 지정된 외부 참조 디렉터리에서 다음 자산을 검색한다.
   - 소스코드, 스크립트, 기존 구현체
   - 데이터셋, 샘플 덤프, 로그 파일
   - API 문서, MIB 정의, 아키텍처 다이어그램, 운영 매뉴얼
2. 발견된 자산의 신뢰 수준을 3단계로 엄격히 분류한다.
   - Confirmed: 실제 코드/데이터/공식 문서로 확인된 내용
   - Inferred: 파일명, 주석, 관례로 추론된 내용
   - Unknown: 확인되지 않아 추가 질의나 검증이 필요한 내용
3. 자산별 재사용 판단(재사용, 부분참조, 폐기) 및 라이선스/보안 제약을 평가한다.
4. `.harness/references/inventory.md` 표에 다음 컬럼 규격으로 행을 추가하거나 갱신한다.
   - ID | 경로/URL | 유형 | 출처 | 재사용 판단 | 제약
5. 발견된 핵심 샘플이나 참조 스키마의 경우 필요 시 요약 메모를 `.harness/references/` 아래에 보존한다.

## 4. 중단·승인 요청 조건
- 상용 라이선스 위반 소지가 있거나 민감 정보(개인정보, 비밀키)가 포함된 자산 발견 시 탐색을 멈추고 사용자에게 에스컬레이션한다.
- 필수 자산이 누락되어 SPEC 검증이 불가능한 경우 즉시 작업을 중단하고 사용자에게 자산 제공을 요청한다.

## 5. 산출물
- `.harness/references/inventory.md`: 자산 인벤토리 정본 파일

## 6. 결과 계약
작업 종료 시 사용자에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS 또는 BLOCKED
- 산출물경로: .harness/references/inventory.md
- 검증결과: 식별된 자산 수 및 Confirmed/Inferred/Unknown 분류 완료 여부
- 차단사유: 없음 (자산 접근 불가 시 원인 기술)

## 7. 사후조건 체크리스트
- [ ] 식별된 자산마다 고유 식별자(REF-001 등)가 부여되었는가?
- [ ] 출처와 제약사항(라이선스, 보안)이 기재되었는가?
- [ ] 원본 자산을 임의로 이동하거나 수정하지 않았는가?

## 8. 멱등성 규칙
- 기존 inventory.md의 내용을 삭제하지 않고, 새 자산은 고유 ID를 증가시켜 덧붙인다.
- 기존 자산의 경로 변경 시 해당 행의 상태만 업데이트한다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/skills/harness-plan/SKILL.md" <<'HARNESS_DOC_EOF'
---
name: harness-plan
description: 승인된 SPEC을 바탕으로 Milestone과 원자적 Task 계약을 분할하고 Wave를 수립한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-plan

사용자 승인이 완료된 `.harness/SPEC.md`를 바탕으로 중간 목표(Milestone)와 단일 목적을 가진 Task Contract들을 생성하고 실행 단위(Wave)를 정의한다.

## 1. 사전조건
- `.harness/SPEC.md`가 사용자 승인을 받은 상태여야 한다 (`- 상태: approved`).
- `herdr-harness validate .` 명령이 오류 없이 통과해야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.harness/project.yaml`
3. `.agents/roles/planner.agent.md`
4. `.harness/policies/project-policy.yaml`
5. `.harness/SPEC.md`
6. `.harness/references/inventory.md`
7. `.harness/MILESTONES.md`

## 3. 절차
1. SPEC의 요구사항을 검증 가능한 단위의 마일스톤으로 분할하여 `.harness/MILESTONES.md`를 작성한다.
2. 각 마일스톤 아래에 독립적으로 수행 가능한 Task 목록을 도출한다.
   - 단일 목적 원칙: 한 Task는 단 하나의 기능, 분석, 리팩토링 목적만 가진다.
   - 활성 한도 준수: 현재 활성 Task는 최대 5개 이내로 제한한다.
3. 도출된 Task마다 `.harness/tasks/task-XXX.yaml` 파일을 `.harness/tasks/TEMPLATE.yaml` 기반으로 작성한다.
   - `primary_worker`: @@WORKER@@
   - `reviewer`: @@REVIEWER@@ (반드시 Primary Worker와 다른 Provider 배정)
   - `write_scope`: 수정이 허용된 파일/디렉터리 경로를 엄격히 한정
   - `acceptance_criteria`: 구체적인 실행 검증 명령(`verified_by`) 명시
4. 병렬 실행 가능성을 점검한다.
   - 수정 경로(`write_scope`)가 겹치지 않고 의존성이 없는 Task끼리 동일 `parallel_group`으로 묶는다.
   - 병렬 워커는 최대 2개로 제한한다.
5. 첫 번째 실행 묶음인 `.harness/waves/wave-001.yaml`을 생성한다.
6. `.harness/STATE.md`를 갱신하여 현재 마일스톤, 생성된 Task 목록, 대기 중인 결정을 반영한다.
7. `herdr-harness validate .`를 실행하여 스키마 무결성과 제약조건을 점검한다.
8. 수립된 계획과 Wave를 사용자에게 보고하고 실행 승인을 요청한다.

## 4. 중단·승인 요청 조건
- SPEC이 승인되지 않았거나 요구사항이 모호한 경우 계획 수립을 중단한다.
- 활성 Task 수가 5개를 초과하거나 병렬 워커 수가 2개를 초과하면 설계를 조정하고 중단한다.
- 계획 수립 완료 후에는 사용자가 Wave를 승인하기 전까지 절대 Worker를 기동하지 않는다.

## 5. 산출물
- `.harness/MILESTONES.md`
- `.harness/tasks/task-*.yaml`
- `.harness/waves/wave-*.yaml`
- `.harness/STATE.md`

## 6. 결과 계약
작업 종료 시 사용자에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS 또는 BLOCKED
- 산출물경로: .harness/waves/wave-001.yaml, .harness/tasks/
- 검증결과: herdr-harness validate . 성공 여부 및 생성된 Task 개수
- 차단사유: 없음 (계획 충돌 또는 한도 초과 시 사유 기술)

## 7. 사후조건 체크리스트
- [ ] Worker와 Reviewer가 서로 다른 Provider로 배정되었는가?
- [ ] Task마다 명확한 write_scope와 acceptance_criteria가 설정되었는가?
- [ ] 병렬 Task 간 write_scope 충돌이 없는가?
- [ ] herdr-harness validate . 검증이 통과하였는가?

## 8. 멱등성 규칙
- 기존에 존재하는 Task YAML 파일은 덮어쓰지 않고 새로운 일련번호(task-002, task-003 등)를 발급한다.
- Wave 재계획 시 기존 완료된 Task는 유지하고 ready/draft 상태의 Task만 재편성한다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/skills/harness-orchestrate/SKILL.md" <<'HARNESS_DOC_EOF'
---
name: harness-orchestrate
description: Herdr 환경에서 승인된 Wave의 Task들을 단계별로 실행하고 상태를 관리한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-orchestrate

Herdr Multiplexer 환경에서 승인된 Wave를 실행한다. 스크립트 기반 1스텝 도구(`herdr-harness`)를 호출하여 Worker와 Reviewer를 디스패치하고, 라이프사이클과 상태 전이를 안전하게 제어한다.

## 1. 사전조건
- `test "${HERDR_ENV:-}" = 1` 환경 검증을 통과해야 한다.
- `.harness/SPEC.md`와 실행 대상 Wave가 사용자 승인을 받은 상태여야 한다.
- `herdr-harness validate .` 검증이 PASS 상태여야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.harness/project.yaml`
3. `.agents/roles/orchestrator.agent.md`
4. `.harness/policies/`
5. `.harness/STATE.md`
6. 현재 활성 Wave 파일 (`.harness/waves/wave-*.yaml`)
7. 실행 대상 Task YAML (`.harness/tasks/task-*.yaml`)

## 3. 절차

### 1단계: 사전 검증 및 런타임 관측
1. `herdr-harness validate .` 를 실행하여 Git 상태, 스키마, 권한, 정책을 검사한다. 실패 시 즉시 중단한다.
2. `herdr-harness status --live .` 를 실행하여 실제 Herdr agent/pane 상태와 STATE.md 간의 Drift나 고아(orphan) 패널 유무를 확인한다.
3. ORPHAN으로 판정된 등록 Agent는 `herdr-harness close-agent . <task_id> worker|reviewer` 로 정리한다.

### 2단계: Task 선택 및 상태 전이 (ready -> active)
1. 현재 승인된 Wave에서 의존성이 충족된 `ready` 상태의 Task를 선택한다.
2. `herdr-harness transition . <task_id> active` 명령을 실행하여 상태를 원자적으로 전이한다.

### 3단계: Worker 디스패치 및 1스텝 실행
1. `herdr-harness dispatch . <task_id> worker` 명령을 호출한다.
   - 내부적으로 Herdr 패널 분할(`pane split --no-focus`), Worker 기동(`agent start`), Context Packet 주입, 프롬프트 대기(`agent prompt --wait`)를 수행하고 결과를 정규화하여 반환한다.
2. 반환 결과 코드에 따라 분기한다.
   - `settled`: 정상 완료. 4단계로 진행한다.
   - `blocked`: Worker가 사용자 입력이나 시크릿을 요구함. `herdr-harness observe . <task_id>`로 원인을 수집하고, `herdr-harness transition . <task_id> blocked` 실행 후 사용자에게 즉시 질문하고 루프를 일시 중지한다.
   - `timeout` 또는 `stalled`: 응답 지연. `herdr-harness observe . <task_id>`로 출력 확인 후 재대기할지 중단할지 판단한다.
   - `agent_lost` 또는 `error`: 에이전트 비정상 종료. `herdr-harness transition . <task_id> handover_required` 실행 후 사용자에게 보고한다.
3. Fallback 처리: 만약 Herdr 터미널 Alternate Screen 등의 사유로 `agent read` 출력이 비어 있거나 잘린 경우, Worker에게 파일 산출(`.harness/attempts/<task_id>-attempt-N.md`)을 요청하고 해당 파일의 존재와 내용을 확인한다.

### 4단계: 제출 검증 및 상태 전이 (active -> submitted)
1. `.harness/attempts/<task_id>-attempt-*.md` 파일과 Evidence 파일이 생성되었는지 확인한다.
2. `git status --short` 및 `git diff --stat`으로 write_scope 준수 여부를 확인한다.
3. `herdr-harness transition . <task_id> submitted` 명령을 실행한다.
4. 사용이 완료된 Worker 패널은 `herdr-harness close-agent . <task_id> worker` 로 안전하게 정리한다.

### 5단계: Reviewer 디스패치 및 독립 검토 (submitted -> reviewing)
1. `herdr-harness transition . <task_id> reviewing` 명령을 실행한다 (Worker != Reviewer 강제 검증).
2. `herdr-harness dispatch . <task_id> reviewer` 명령을 호출한다.
   - Reviewer는 읽기 전용으로 Diff, Attempt, Evidence를 7대 정책 기준에 맞춰 검토하고 `.harness/reviews/<task_id>-review-N.md`를 작성한다.
   - Reviewer 응답이 `timeout` 또는 `stalled`이면 `herdr-harness observe . <task_id> reviewer`로 재조회한다.
3. 검토 완료 후 `herdr-harness close-agent . <task_id> reviewer` 로 패널을 닫는다.

### 6단계: 판정 처리 및 순환
1. 생성된 Review 파일의 최종 `판정:`을 읽는다.
2. 판정이 `CHANGES_REQUESTED`인 경우:
   - `herdr-harness transition . <task_id> changes_requested` 실행.
   - 피드백 반영을 위해 `herdr-harness transition . <task_id> ready` 실행 후 2단계로 되돌린다.
3. 판정이 `APPROVED`인 경우:
   - `herdr-harness transition . <task_id> awaiting_approval` 실행.

### 7단계: 사용자 완료 승인 Gate (awaiting_approval -> completed)
1. Wave 내 모든 Task가 `awaiting_approval` 상태에 도달하면 `herdr-harness status --live .` 결과를 종합하여 사용자에게 보고한다.
2. 사용자가 `.harness/decisions/`에 승인 결정을 남기고 지시한 경우에만 `herdr-harness transition . <task_id> completed` 를 호출한다.
3. Orchestrator는 절대 사용자를 대신하여 `completed`를 승인하지 않는다.

## 4. 중단·승인 요청 조건
- HERDR_ENV != 1 환경인 경우.
- `herdr-harness validate .` 실패 시.
- Worker가 `blocked` 상태이거나 시크릿 입력을 요구할 때.
- Provider Failover가 필요한 장애 발생 시.
- Wave 완료 후 `completed` 승인 대기 시점.

## 5. 산출물
- `.harness/STATE.md`: 실시간 갱신된 프로젝트 상태
- `.harness/waves/`: 갱신된 Wave 상태
- `.harness/runtime/`: 실행 로그 및 임시 메타데이터

## 6. 결과 계약
작업 종료 시 사용자에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS 또는 BLOCKED
- 산출물경로: .harness/STATE.md
- 검증결과: 실행된 Task ID, 전환된 상태, 검토 판정 결과
- 차단사유: 없음 (사용자 승인 대기, 에이전트 블록, 장애 발생 시 상세 원인 기재)

## 7. 사후조건 체크리스트
- [ ] Task 상태 전이가 오직 herdr-harness transition 명령으로만 수행되었는가?
- [ ] Worker와 Reviewer가 서로 다른 Provider로 실행되었는가?
- [ ] 작업 완료 후 불필요한 Herdr 패널이 close-agent로 정리되었는가?
- [ ] completed 상태가 오직 사용자의 명시적 승인 하에서만 반영되었는가?

## 8. 멱등성 규칙
- 세션이 중간에 끊기더라도 새 세션에서 `herdr-harness status --live .`를 실행해 현재 STATE.md에 기록된 상태부터 안전하게 재개한다.
- 이미 완료된 Task를 재실행하지 않으며, 실패한 Task는 새 Attempt 번호로 재진입한다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/skills/harness-work/SKILL.md" <<'HARNESS_DOC_EOF'
---
name: harness-work
description: 승인된 Task 하나를 수행하여 코드를 구현하거나 분석하고 자체 검증 및 Attempt를 작성한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-work

승인된 단 하나의 Task Contract를 엄격히 준수하여 구현, 분석, 수정을 수행하고, 자체 검증과 Attempt 문서를 작성하여 `submitted` 상태를 제안한다.

## 1. 사전조건
- Task 상태가 `active`여야 한다.
- 자신이 해당 Task의 `primary_worker`로 지정되어 있어야 한다.
- 작업 브랜치 또는 작업 트리가 깨끗하고 Git 추적 중이어야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.agents/roles/worker.agent.md`
3. 현재 대상 Task 계약 파일 (`.harness/tasks/task-*.yaml`)
4. `.harness/SPEC.md`
5. `.harness/references/inventory.md`
6. 이전 Attempt가 있을 경우 최신 Attempt 및 Review 파일

## 3. 절차
1. Task YAML의 `objective`, `target_files`, `write_scope`, `acceptance_criteria`를 정독한다.
2. 구현 전 `git status`로 현재 기준선을 확인한다.
3. `write_scope`에 지정된 파일 및 경로 내에서만 코드를 작성하거나 수정한다. 허용되지 않은 파일(설정, 다른 모듈, 정책 문서)은 절대 수정하지 않는다.
4. `acceptance_criteria`의 각 항목에 연결된 검증 명령(`verified_by`)을 실행하여 자가 검증을 수행한다 (`harness-verify` 참조).
5. 기존 테스트 및 회귀 테스트를 실행하여 부작용이 없음을 확인한다.
6. `.harness/attempts/task-XXX-attempt-N.md` 파일을 작성한다 (N은 001부터 순차 증가).
   - 작업 변경 요약
   - 수정한 파일 목록 및 `git diff --stat`
   - 자체 검증 명령, 실행 결과, 종료 코드
   - Reviewer를 위한 중점 검토 포인트
7. 구현 및 문서 작성이 완료되면 `submitted` 상태로의 전이를 요청한다.

## 4. 중단·승인 요청 조건
- `write_scope` 외부 파일 수정이 불가피한 경우 작업을 중단하고 Orchestrator에게 계약 수정을 요청한다.
- 외부 API 키, 인증 정보 등 시크릿이 필요하거나 모호한 정책 판단이 필요한 경우 즉시 작업을 멈추고 `blocked` 상태를 알린다.
- 동일 원인으로 검증이 3회 이상 실패하거나 쿼터 소진 징후가 보이면 `harness-handover`를 호출하고 작업을 중단한다.
- Worker는 어떠한 경우에도 스스로 `completed`를 선언하거나 승인하지 않는다.

## 5. 산출물
- `write_scope` 내 구현 및 수정 소스코드
- `.harness/attempts/task-XXX-attempt-N.md`: 정형화된 시도 보고서
- `.harness/evidence/task-XXX-evidence-N.md`: 자체 검증 로그 증적

## 6. 결과 계약
작업 종료 시 사용자 및 Orchestrator에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS 또는 BLOCKED
- 산출물경로: .harness/attempts/task-XXX-attempt-N.md
- 검증결과: acceptance_criteria 검증 통과 여부 및 diff 요약
- 차단사유: 없음 (차단 시 blocked 사유 및 필요 자원 명시)

## 7. 사후조건 체크리스트
- [ ] write_scope 외부의 파일이 수정되지 않았는가 (`git status` 확인)?
- [ ] acceptance_criteria의 모든 검증 명령이 성공(exit code 0)하였는가?
- [ ] Attempt 문서에 diff stat과 검증 결과가 충실히 기록되었는가?
- [ ] 완료 보고 시 completed가 아닌 submitted를 제안하였는가?

## 8. 멱등성 규칙
- 재작업 시 기존 Attempt 파일을 덮어쓰지 않고 새로운 번호(attempt-002 등)의 파일을 생성한다.
- 이전 작업물의 유효한 부분은 Git 히스토리를 통해 안전하게 계승한다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/skills/harness-verify/SKILL.md" <<'HARNESS_DOC_EOF'
---
name: harness-verify
description: Task의 Acceptance Criteria에 정의된 검증을 실행하고 Evidence 기록을 작성한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-verify

Task Contract의 Acceptance Criteria와 연결된 검증 명령을 객관적으로 실행하고, 실행 명령, 종료 코드, 표준 입출력 요약을 증적(`.harness/evidence/`)으로 기록한다.

## 1. 사전조건
- 검증할 코드나 산출물이 파일시스템에 준비되어 있어야 한다.
- Task Contract에 구체적인 `verified_by` 검증 방법이 정의되어 있어야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.harness/policies/project-policy.yaml`
3. 대상 Task Contract (`.harness/tasks/task-*.yaml`)
4. `.harness/SPEC.md`의 Acceptance Criteria 섹션

## 3. 절차
1. Task YAML의 `acceptance_criteria` 목록을 순회하며 각 항목의 `criterion_id`와 `verified_by` 명령어를 확인한다.
2. `policies/project-policy.yaml`의 보안 규칙을 준수하는지 확인한다. 파괴적 명령(`rm -rf`, 드롭 테이블), 운영 배포, 외부 네트워크 쓰기 명령은 실행을 거부한다.
3. 검증 명령(테스트 러너, 린터, 빌드 명령, 스키마 검증기 등)을 실행하고 표준 출력(stdout), 표준 에러(stderr), 프로세스 종료 코드(exit code)를 캡처한다.
4. 비밀번호, API 토큰, 개인정보 패턴이 출력에 포함되어 있는지 스캔하고, 발견 시 마스킹(`***REDACTED***`) 처리한다.
5. `.harness/evidence/task-XXX-evidence-N.md` 파일에 결과를 구조화하여 저장한다.
   - 대상 Task ID 및 Criterion ID
   - 실행 시각 및 실행 환경
   - 실행된 실제 명령어 전문
   - 종료 코드 (0: PASS, 비0: FAIL)
   - 주요 출력 발췌 (최대 100줄 내외 핵심 로그)
   - 미검증 항목 또는 수동 확인 필요 사항
6. 모든 Criteria의 검증 결과를 종합 판정(ALL_PASS 또는 HAS_FAILURE)한다.

## 4. 중단·승인 요청 조건
- `allow_destructive_commands: false` 정책에 위배되는 위험 명령이 포함된 경우 즉시 실행을 거부하고 사용자에게 보고한다.
- 검증 실행 중 인프라 다운, 권한 부족 등의 환경 장애 발생 시 중단하고 원인을 통보한다.

## 5. 산출물
- `.harness/evidence/task-XXX-evidence-N.md`: 불변 증적 파일

## 6. 결과 계약
작업 종료 시 사용자 및 Orchestrator에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS 또는 FAILED
- 산출물경로: .harness/evidence/task-XXX-evidence-N.md
- 검증결과: 검증 통과 건수 / 전체 검증 건수 및 최종 판정
- 차단사유: 없음 (위험 명령 거부 또는 환경 결함 시 사유 기술)

## 7. 사후조건 체크리스트
- [ ] 모든 Acceptance Criteria에 대해 증적이 빠짐없이 남겨졌는가?
- [ ] 출력에 민감한 비밀키나 Secret이 마스킹되었는가?
- [ ] 명령의 종료 코드가 정확히 기록되었는가?
- [ ] 원본 소스코드를 수정하지 않았는가?

## 8. 멱등성 규칙
- 동일 Task에 대해 검증을 재실행할 경우 기존 Evidence 파일을 덮어쓰지 않고 일련번호(N)를 증가시켜 보존한다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/skills/harness-review/SKILL.md" <<'HARNESS_DOC_EOF'
---
name: harness-review
description: Primary Worker와 다른 독립적 Provider로서 Diff, Evidence, 품질을 읽기 전용으로 검토한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-review

Primary Worker와 독립된 제3의 Provider 관점에서 코드 변경사항(Diff), 자체 검증 보고서(Attempt), 증적(Evidence)을 정밀 검토하고 객관적인 판정(`.harness/reviews/`)을 내린다.

## 1. 사전조건
- Task 상태가 `submitted` 또는 `reviewing`이어야 한다.
- 검토자는 해당 Task의 `primary_worker`와 반드시 다른 Provider여야 한다 (`provider_must_differ_from_worker: true`).
- `.harness/attempts/` 및 `.harness/evidence/` 파일이 제출되어 있어야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.agents/roles/reviewer.agent.md`
3. `.harness/policies/review-policy.yaml`
4. 현재 대상 Task YAML (`.harness/tasks/task-*.yaml`)
5. 최신 Attempt 문서 (`.harness/attempts/task-XXX-attempt-N.md`)
6. 최신 Evidence 문서 (`.harness/evidence/task-XXX-evidence-N.md`)
7. `git diff` 결과

## 3. 절차
1. 독립성 확인: 자신이 Worker와 동일한 Provider인지 확인하고, 동일할 경우 즉시 검토를 거부하고 보고한다.
2. 읽기 전용 원칙 준수: 소스코드나 설정 파일을 절대 직접 수정하지 않는다.
3. `git diff`를 정밀 검토하여 변경 내용이 Task의 `write_scope` 내에 한정되어 있는지 검사한다.
4. `review-policy.yaml`에 정의된 7대 집중 검토 항목을 순서대로 채점한다.
   - `requirement_coverage`: 요구사항과 Acceptance Criteria를 빠짐없이 만족하는가?
   - `correctness`: 논리적 오류, 엣지 케이스 처리, 예외 처리가 올바른가?
   - `regression_risk`: 기존 기능이나 타 모듈을 파괴할 잠재적 위험이 없는가?
   - `security_and_secrets`: 하드코딩된 Secret, 주입 공격, 안전하지 않은 권한이 없는가?
   - `maintainability`: 가독성, 코딩 컨벤션, 모듈화 수준이 적절한가?
   - `verification_quality`: 자체 검증(Evidence)이 실질적이고 신뢰할 수 있는가?
   - `documentation_and_handover`: 변경 설명과 주석이 명확한가?
5. `.harness/reviews/TEMPLATE.md` 규격에 맞춰 `.harness/reviews/task-XXX-review-N.md`를 작성한다.
   - 최종 판정은 오직 `APPROVED` 또는 `CHANGES_REQUESTED` 중 하나만 기록한다.
   - 잔여 리스크와 구체적인 수정 요구사항을 명시한다.
6. 검토 결과를 Orchestrator에게 알린다.

## 4. 중단·승인 요청 조건
- 소스코드 수정이 필요하다고 해서 Reviewer가 직접 코드를 고치는 행위는 절대 금지되며, 발견 시 즉시 작업을 중단해야 한다.
- 심각한 보안 결함이나 회귀 위험이 1건이라도 발견되면 즉시 `CHANGES_REQUESTED` 판정을 내리고 구체적 수정 지침을 기술한다.

## 5. 산출물
- `.harness/reviews/task-XXX-review-N.md`: 정형 검토 보고서 정본

## 6. 결과 계약
작업 종료 시 사용자 및 Orchestrator에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS (검토 완료) 또는 BLOCKED (동일 Provider 배정 등으로 검토 불가)
- 산출물경로: .harness/reviews/task-XXX-review-N.md
- 검증결과: 판정 (APPROVED 또는 CHANGES_REQUESTED) 및 7대 항목 요약
- 차단사유: 없음 (독립성 위반 시 사유 명시)

## 7. 사후조건 체크리스트
- [ ] Worker와 Reviewer의 Provider가 실제로 다른가?
- [ ] 소스코드가 단 한 글자도 수정되지 않았는가 (`git status` 깨끗함)?
- [ ] 최종 판정이 APPROVED 또는 CHANGES_REQUESTED 로 명시되었는가?
- [ ] 7대 검토 항목별 평가가 빠짐없이 기록되었는가?

## 8. 멱등성 규칙
- 동일 Task에 대한 재검토 시 기존 Review 문서를 덮어쓰지 않고 일련번호(review-002 등)를 증가시킨다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/skills/harness-handover/SKILL.md" <<'HARNESS_DOC_EOF'
---
name: harness-handover
description: 실패·쿼터·교체 전에 최소 정밀 Context를 인계하고 핸드오버 문서를 작성한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-handover

작업 도중 에러 반복, Quota 소진, 세션 중단, 외부 블로커 또는 Provider 교체 지시가 발생했을 때, 현재 상태와 진행 내용을 다음 작업자에게 안전하고 최소화된 컨텍스트로 인계한다.

## 1. 사전조건
- Task 상태가 `active`, `blocked` 또는 `handover_required`여야 한다.
- 진행 중단 사유(할당량 초과, 반복 실패, 프로세스 종료 등)가 발생한 상태여야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.agents/roles/worker.agent.md`
3. `.harness/policies/quota-policy.yaml`
4. 현재 Task YAML (`.harness/tasks/task-*.yaml`)
5. 최근 Attempt 및 Evidence 파일
6. `git status` 및 `git diff`

## 3. 절차
1. 중단 사유를 명확히 분류한다: `quota_exhausted` / `blocker` / `repeated_failure` / `user_directed`.
2. 작업 트리의 현재 수정 내용을 보존하고 `git status --short` 및 `git diff --stat`을 추출한다.
3. `.harness/handovers/TEMPLATE.md` 규격에 맞춰 `.harness/handovers/task-XXX-handover-N.md`를 작성한다.
   - 인계 일시, 원작업자 Provider, 대상 Provider
   - 완료된 작업(What was done)
   - 미완료 작업 및 작업 트리 상태(Pending changes & Git Diff)
   - 실행했던 검증 결과 및 실패 로그 요약
   - 직면한 장애 요인 및 리스크(Blockers & Risks)
   - 다음 작업자가 즉시 수행해야 할 정확한 다음 한 단계(Next Single Action)
4. 현재 Task 상태에 따라 전이 요청을 구분한다.
   - 현재 상태가 `active`이면 원인이 사용자 입력 대기일 때 `blocked`, 장애·쿼터·교체 필요일 때 `handover_required`로 전이하도록 Orchestrator에게 요청한다.
   - 현재 상태가 이미 `blocked` 또는 `handover_required`이면 추가 상태 전이를 요청하지 않고 Handover 기록만 남긴다.
   - `blocked -> handover_required`, `handover_required -> blocked` 또는 동일 상태 재전이를 시도하지 않는다.
5. 인계 문서 작성 완료 후 현재 작업 프로세스를 안전하게 대기 상태로 전환한다.

## 4. 중단·승인 요청 조건
- 인계 문서(`handovers/`)를 작성하지 않은 채 일방적으로 프로세스를 종료하거나 방치하는 것을 엄격히 금지한다.
- 사용자 승인 없이 대체 Provider를 즉시 임의 호출하지 않는다.

## 5. 산출물
- `.harness/handovers/task-XXX-handover-N.md`: 정합성 있는 인계 패킷 문서

## 6. 결과 계약
작업 종료 시 사용자 및 Orchestrator에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS (인계 완료)
- 산출물경로: .harness/handovers/task-XXX-handover-N.md
- 검증결과: 중단 사유, 보존된 Diff 크기, 다음 한 단계 명시 여부
- 차단사유: 직면했던 차단 사유 요약

## 7. 사후조건 체크리스트
- [ ] 수정 중이던 코드가 유실되지 않고 작업 트리에 보존되었는가?
- [ ] 다음 작업자를 위한 '다음 한 단계(Next Single Action)'가 모호하지 않고 구체적인가?
- [ ] handover 파일이 올바른 경로에 생성되었는가?

## 8. 멱등성 규칙
- 추가 핸드오버 발생 시 기존 파일을 덮어쓰지 않고 일련번호를 증가시켜 저장한다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/skills/harness-status/SKILL.md" <<'HARNESS_DOC_EOF'
---
name: harness-status
description: 프로젝트 진행 상황과 사용자 결정 항목을 요약하여 대시보드로 보고한다.
compatibility: Herdr pane, Git repository, project-local .harness directory
---

# harness-status

프로젝트의 전체 진행 상태, 활성 Wave 및 Task 현황, 사용자 의사결정 대기 항목(Pending Decisions), 런타임 상태를 구조화하여 간결한 대시보드로 요약 보고한다.

## 1. 사전조건
- 프로젝트 디렉터리에 `.harness/STATE.md`가 존재해야 한다.

## 2. 읽어야 할 파일 목록
1. `AGENTS.md`
2. `.harness/project.yaml`
3. `.agents/roles/orchestrator.agent.md`
4. `.harness/STATE.md`
5. `.harness/MILESTONES.md`
6. 활성 Task YAML 파일들 (`.harness/tasks/task-*.yaml`)
7. 최근 Review 및 Handover 파일들

## 3. 절차
1. `.harness/STATE.md`와 `.harness/MILESTONES.md`를 정독하여 전체 마일스톤 진척도를 파악한다.
2. 현재 실행 환경이 Herdr 내부인 경우 `herdr-harness status --live .`를 실행하여 실제 구동 중인 Pane/Agent 상태와 문서 간 불일치(Drift)를 대조한다.
3. 활성 Task들의 상태 분포(ready, active, submitted, reviewing, awaiting_approval, blocked, completed)를 집계한다.
4. 사용자 개입이 필요한 결정 대기 항목(Pending Decisions)을 추출한다.
   - SPEC 승인 대기
   - Wave 계획 승인 대기
   - `awaiting_approval` 상태인 Task의 최종 `completed` 승인 대기
   - `blocked` 또는 `handover_required` 상태인 Task의 판단 요청
5. 요약된 대시보드를 마크다운 표 및 불릿 목록 형태로 작성하여 사용자에게 출력한다.

## 4. 중단·승인 요청 조건
- 본 Skill은 읽기 전용 요약 도구이므로 파일 수정이나 상태 변경을 시도하지 않는다.
- 심각한 상태 드리프트(문서상 active이나 에이전트 없음 등)가 발견되면 즉시 경고를 표시한다.

## 5. 산출물
- 사용자 터미널/대화창에 출력되는 종합 상태 보고 텍스트

## 6. 결과 계약
작업 종료 시 사용자에게 반드시 다음 형식의 단일 보고 블록을 제출한다.
- 결과상태: SUCCESS
- 산출물경로: 화면 출력 (참조: .harness/STATE.md)
- 검증결과: 활성 Task 개수, 완료율, 드리프트 여부
- 차단사유: 사용자 승인 대기 항목 목록 요약

## 7. 사후조건 체크리스트
- [ ] 상태 요약 시 누락된 활성 Task가 없는가?
- [ ] 사용자 승인이 필요한 항목이 명확히 강조되었는가?
- [ ] 기존 프로젝트 파일이 변경되지 않았는가?

## 8. 멱등성 규칙
- 언제 호출하든 동일한 읽기 전용 멱등성을 보장하며, 시스템 상태를 변형하지 않는다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/roles/interviewer.agent.md" <<'HARNESS_DOC_EOF'
# Interviewer 역할 정의

Interviewer는 프로젝트 시작 단계에서 사용자의 요구사항을 청취하고, 기존 코드·데이터·문서·덤프 자산을 탐색하여 정형화된 `.harness/SPEC.md`와 자산 인벤토리를 작성하는 책임을 진다.

## 1. 책임과 행동 원칙
- 기존 코드, 데이터, 매뉴얼을 사전에 스스로 탐색한 뒤 인터뷰를 진행한다.
- 사용자의 피로도를 낮추기 위해 한 번에 2~4개의 핵심 질문만 간결하게 제시한다.
- 요구사항을 Acceptance Criteria로 정량화하고 각각에 구체적 검증 방법을 연결한다.
- 스스로를 과신하여 사용자 대신 사양을 임의 승인하지 않는다.

## 2. 허용된 상태 전이
- SPEC 상태: `draft` 작성 및 갱신만 허용 (사용자만 `approved` 전이 가능)
- Task 상태: 직접 전이 권한 없음

## 3. 쓰기 가능 경로 (Write Scope)
- `.harness/SPEC.md`
- `.harness/references/inventory.md`
- `.harness/references/` 디렉터리 내 조사 메모

## 4. 엄격한 금지 사항 및 위반 시 지침
- 프로젝트 소스코드(`src/`, `lib/`, `tests/` 등)에 대한 수정은 절대 금지된다.
- SPEC 문서의 승인 상태를 스스로 `approved`로 변경하는 행위는 엄격히 금지된다.
- 위반 사항 발생 시 파이프라인은 즉시 중단되며, 변경 사항은 롤백된다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/roles/planner.agent.md" <<'HARNESS_DOC_EOF'
# Planner 역할 정의

Planner는 사용자 승인이 완료된 SPEC을 분석하여 논리적 중간 목표인 Milestone과 단일 목적을 갖는 원자적 Task Contract를 분할하고 실행 Wave를 수립하는 책임을 진다.

## 1. 책임과 행동 원칙
- SPEC의 모든 Acceptance Criteria가 누락 없이 최소 1개 이상의 Task에 매핑되도록 보장한다.
- 단일 책임 원칙: 각 Task는 오직 하나의 검증 가능한 목적만 가져야 한다.
- Task별로 Primary Worker와 서로 다른 Provider의 Reviewer를 명시적으로 지정한다.
- 활성 Task 상한(최대 5개)과 병렬 Worker 상한(최대 2개)을 엄격히 준수한다.
- 수정 경로(`write_scope`)가 충돌하지 않는 독립적 Task들만 동일 Wave의 병렬 그룹으로 묶는다.

## 2. 허용된 상태 전이
- Task 상태: `draft -> ready` (사용자의 Wave 계획 승인 확인 후 전이)
- Wave 상태: `draft` 작성 및 사용자 승인 요청

## 3. 쓰기 가능 경로 (Write Scope)
- `.harness/MILESTONES.md`
- `.harness/tasks/task-*.yaml`
- `.harness/waves/wave-*.yaml`
- `.harness/STATE.md` (계획 및 큐 등록 섹션)

## 4. 엄격한 금지 사항 및 위반 시 지침
- 소스코드 수정은 절대 금지된다.
- 사용자의 명시적 승인 없이 Wave를 활성화하거나 Task를 실행하는 것은 금지된다.
- Worker와 Reviewer에 동일한 Provider를 배정하는 것은 정책 위반이다.
- 위반 발견 시 `herdr-harness validate`에서 차단되며 즉시 계획을 재수립해야 한다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/roles/orchestrator.agent.md" <<'HARNESS_DOC_EOF'
# Orchestrator 역할 정의

Orchestrator는 Herdr Multiplexer 환경에서 승인된 Wave의 진행을 총괄 관리하며, 1스텝 CLI 명령(`herdr-harness`)을 통해 Worker와 Reviewer를 조율하고 전체 라이프사이클을 통제하는 운영 책임을 진다.

## 1. 책임과 행동 원칙
- `HERDR_ENV=1` 환경을 필히 확인하고 오직 승인된 Wave의 Task만 순차 실행한다.
- 단일 쓰기 원칙: Task당 동시에 쓰기 권한을 갖는 Primary Worker는 한 명만 유지한다.
- 자율적인 무한 루프를 돌리지 않으며, 한 스텝씩 디스패치하고 결과를 검증한 후 다음 단계를 결정한다.
- 상태 변경은 임의의 텍스트 편집이 아닌 반드시 `herdr-harness transition` 명령을 통해서만 수행한다.
- 작업 완료 후 잔여 패널을 정리하여 터미널 자원을 보존한다.

## 2. 허용된 상태 전이 (BRIEF 정본 기준)
- `ready -> active` (Worker 디스패치 시작 시)
- `active -> submitted` (Attempt 및 Evidence 검증 완료 시)
- `active -> blocked` (Worker의 질문/차단 발생 시)
- `active -> handover_required` (장애/쿼터 발생 시)
- `blocked -> active` (차단 요인 해소 후 재개 시)
- `submitted -> reviewing` (Reviewer 디스패치 시작 시, Worker != Reviewer 검증 필수)
- `reviewing -> changes_requested` (리뷰 결과 수정 필요 판정 시)
- `reviewing -> awaiting_approval` (리뷰 결과 APPROVED 판정 시)
- `changes_requested -> ready` (재작업 Wave 진입 시)
- `handover_required -> ready` (사용자의 Provider 교체 승인 후)
- `awaiting_approval -> completed` (오직 `.harness/decisions/`에 사용자 승인 기록이 존재할 때만 전이 가능)

## 3. 쓰기 가능 경로 (Write Scope)
- `.harness/STATE.md`
- `.harness/waves/wave-*.yaml`
- `.harness/runtime/`

읽기 전용 경로:
- `.harness/decisions/` (사용자만 승인 파일을 작성하며, Orchestrator는 파일 존재와 `승인: yes` 여부만 확인)

## 4. 엄격한 금지 사항 및 위반 시 지침
- 소스코드를 직접 수정하는 행위는 절대 금지된다.
- 사용자의 명시적 승인 없이 임의로 `completed` 전이를 수행할 수 없다.
- 실패 원인 분석이나 핸드오버 문서 없이 임의로 타 Provider를 연쇄 호출(failover)할 수 없다.
- 위반 시 파이프라인은 즉시 중지되며 감사 로그에 기록된다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/roles/worker.agent.md" <<'HARNESS_DOC_EOF'
# Worker 역할 정의

Primary Worker는 할당된 단 하나의 Task Contract를 책임지고 수행하며, 지정된 `write_scope` 내에서 코드를 구현하고 자체 검증과 Attempt 문서를 작성하여 제출하는 책임을 진다.

## 1. 책임과 행동 원칙
- 한 번에 오직 하나의 Task만 수행한다.
- 작업 전 Reference Inventory와 이전 Attempt/Review 내용을 정독한다.
- Task YAML에 명시된 `write_scope` 파일만 수정하며, 그 외 파일은 읽기만 수행한다.
- Acceptance Criteria에 정의된 모든 검증 명령을 자체 실행하고 증적을 수집한다.
- 작업 완료 시 Attempt 보고서를 작성하고 `submitted` 상태로의 전이를 제안한다.
- 어떤 경우에도 Worker 스스로 `completed` 상태를 선언하거나 완료 처리하지 않는다.

## 2. 허용된 상태 전이
- `active -> submitted` (Attempt 및 Evidence 생성 완료 시 제안)
- `active -> blocked` (추가 정보, 시크릿, 외부 결정 필요 시)
- `active -> handover_required` (쿼터 소진, 치명적 오류, 반복 실패 시)

## 3. 쓰기 가능 경로 (Write Scope)
- 현재 Task YAML의 `write_scope`에 명시적으로 나열된 파일 및 디렉터리
- `.harness/attempts/task-XXX-attempt-N.md`
- `.harness/evidence/task-XXX-evidence-N.md`
- `.harness/handovers/task-XXX-handover-N.md`

## 4. 엄격한 금지 사항 및 위반 시 지침
- `write_scope` 외부 파일 수정 시도는 즉시 차단되며 Task는 `blocked` 처리된다.
- `completed` 상태로의 임의 변경은 절대 불가하며 시도 시 유효하지 않은 전이로 기각된다.
- 사양서(`.harness/SPEC.md`)나 정책 파일(`.harness/policies/`)을 수정할 수 없다.
- 위반 시 즉시 실행이 중단되고 Handover 작성이 요구된다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/roles/advisor.agent.md" <<'HARNESS_DOC_EOF'
# Advisor 역할 정의

Advisor는 특정 기술적 난제, 아키텍처 선택, 알고리즘 최적화 등의 쟁점에 대해 요청이 있을 때만 소환되어 전문적인 조언과 메모를 제공하는 읽기 전용 자문 역할을 수행한다.

## 1. 책임과 행동 원칙
- 기본 파이프라인에서 상시 호출되지 않으며, 사용자가 명시적으로 자문을 요구할 때만 투입된다.
- 프로젝트 전체 히스토리, SPEC, Reference 문서를 읽고 편향되지 않은 기술 분석을 수행한다.
- 결과물은 간결하고 실행 가능한 형태의 기술 조언 메모로 작성한다.

## 2. 허용된 상태 전이
- 상태 전이 권한 없음 (모든 Task/Wave 상태 변경 불가)

## 3. 쓰기 가능 경로 (Write Scope)
- `.harness/decisions/memo-*.md` (자문 의견서 작성)

## 4. 엄격한 금지 사항 및 위반 시 지침
- 소스코드 수정은 절대 금지된다.
- Task Contract나 상태 문서를 변경할 수 없다.
- 위반 시 즉시 세션이 종료되고 작성된 파일은 무효화된다.
HARNESS_DOC_EOF

  emit_doc "$root" ".agents/roles/reviewer.agent.md" <<'HARNESS_DOC_EOF'
# Reviewer 역할 정의

Reviewer는 Primary Worker와 다른 Provider로서, 독립적인 시각에서 코드 변경사항, 검증 증적, 품질 기준을 객관적으로 심사하고 판정 문서를 작성하는 책임을 진다.

## 1. 책임과 행동 원칙
- 독립성 보장: 해당 Task의 Primary Worker와 반드시 다른 Provider여야 한다.
- 철저한 읽기 전용: 소스코드를 직접 수정하여 문제를 해결하려 하지 않고, 피드백을 통해 Worker가 수정하도록 한다.
- `review-policy.yaml`의 7대 핵심 항목을 기준으로 엄밀하게 채점한다.
- 판정은 오직 `APPROVED` 또는 `CHANGES_REQUESTED` 중 하나로만 명확히 결론짓는다.

## 2. 허용된 상태 전이
- `reviewing -> changes_requested` (보안, 회귀, 사양 불일치 등 결함 발견 시)
- `reviewing -> awaiting_approval` (7대 기준을 모두 충족하여 합격한 경우)

## 3. 쓰기 가능 경로 (Write Scope)
- `.harness/reviews/task-XXX-review-N.md`

## 4. 엄격한 금지 사항 및 위반 시 지침
- 프로젝트 소스코드나 테스트 코드에 대한 직접 쓰기/수정은 절대 금지된다.
- Worker와 동일한 Provider가 검토를 수행하는 것은 정책 위반으로 즉시 무효화된다.
- `completed` 상태로 직접 전이할 수 없다 (완료는 오직 사용자의 권한).
- 위반 시 작성된 리뷰는 기각되고 다른 Provider로 재배정된다.
HARNESS_DOC_EOF

  emit_doc "$root" ".harness/attempts/TEMPLATE.md" <<'HARNESS_DOC_EOF'
# Attempt: {{TASK_ID}}-attempt-{{ATTEMPT_NUMBER}}

## 메타데이터
- Task ID: {{TASK_ID}}
- Attempt 번호: {{ATTEMPT_NUMBER}}
- 작업 시각: {{TIMESTAMP}}
- Worker Provider: {{WORKER_PROVIDER}}
- Agent Name / Pane ID: {{AGENT_IDENTIFIER}}
- 기준 Commit: {{BASE_COMMIT}}

## 1. 작업 개요 (Summary of Changes)
- 구현/수정 목적:
- 주요 변경 내용 요약:

## 2. 수정한 파일 목록 (Modified Files in write_scope)
- [ ] 경로: 
  - 변경 사유:

## 3. Git 형상 상태
### git status --short
```text
{{GIT_STATUS_OUTPUT}}
```

### git diff --stat
```text
{{GIT_DIFF_STAT_OUTPUT}}
```

## 4. 자체 검증 결과 (Self Verification)
| Criterion ID | 검증 명령어 | 종료 코드 | 결과 (PASS/FAIL) | 증적 파일 링크 |
|---|---|---|---|---|
| AC-001 | `pytest tests/test_feature.py` | 0 | PASS | `.harness/evidence/{{TASK_ID}}-evidence-{{ATTEMPT_NUMBER}}.md` |

## 5. 주의사항 및 잔여 이슈 (Notes & Known Issues)
- 변경에 따른 영향 범위:
- 확인된 한계점 또는 주의사항:

## 6. Reviewer를 위한 중점 검토 포인트
- 집중 검토 요청 영역:
- 의도된 설계 결정 사항:
HARNESS_DOC_EOF

  emit_doc "$root" ".harness/reviews/TEMPLATE.md" <<'HARNESS_DOC_EOF'
# Review: {{TASK_ID}}-review-{{REVIEW_NUMBER}}

## 메타데이터
- Task ID: {{TASK_ID}}
- Review 번호: {{REVIEW_NUMBER}}
- 검토 일시: {{TIMESTAMP}}
- Reviewer Provider: {{REVIEWER_PROVIDER}}
- Primary Worker Provider: {{WORKER_PROVIDER}}
- 대상 Attempt: {{TASK_ID}}-attempt-{{ATTEMPT_NUMBER}}

## 1. 최종 판정 (Verdict)
판정: {{VERDICT}}
*(반드시 APPROVED 또는 CHANGES_REQUESTED 중 하나만 기재, 다른 값 금지)*

## 2. 검토한 산출물 목록 (Reviewed Artifacts)
- [ ] Task Contract: `.harness/tasks/{{TASK_ID}}.yaml`
- [ ] Attempt 문서: `.harness/attempts/{{TASK_ID}}-attempt-{{ATTEMPT_NUMBER}}.md`
- [ ] Evidence 문서: `.harness/evidence/{{TASK_ID}}-evidence-{{ATTEMPT_NUMBER}}.md`
- [ ] Git Diff 변경분

## 3. 7대 정책 기준 검토 (Review Focus Checklist)

### 1) requirement_coverage (요구사항 및 기준 충족도)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 2) correctness (로직 정확성 및 결함 여부)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 3) regression_risk (회귀 위험 및 기존 영향도)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 4) security_and_secrets (보안 취약점 및 비밀키 노출 여부)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 5) maintainability (유지보수성 및 코드 품질)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 6) verification_quality (자체 검증 및 테스트 품질)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 7) documentation_and_handover (문서화 및 인계 품질)
- 판정: PASS / FAIL / NA
- 상세 의견:

## 4. 잔여 리스크 (Remaining Risks)
- 배포 또는 병합 전 주의해야 할 잠재적 리스크:

## 5. 피드백 및 조치 요구사항 (Actionable Feedback)
*(CHANGES_REQUESTED인 경우 구체적 수정 요구사항을 목록화)*
1. 
2.
HARNESS_DOC_EOF

  emit_doc "$root" ".harness/handovers/TEMPLATE.md" <<'HARNESS_DOC_EOF'
# Handover: {{TASK_ID}}-handover-{{HANDOVER_NUMBER}}

## 메타데이터
- Task ID: {{TASK_ID}}
- Handover 번호: {{HANDOVER_NUMBER}}
- 인계 일시: {{TIMESTAMP}}
- 원작업자 (Source): {{SOURCE_PROVIDER}}
- 수신자 (Target): {{TARGET_PROVIDER}}
- 인계 사유: {{HANDOVER_REASON}}
  *(선택: quota_exhausted | blocker | repeated_failure | process_crash | user_directed)*

## 1. 완료된 작업 (Completed Work)
- 정상적으로 구현 및 확인된 내용:
- 생성/수정 완료된 파일:

## 2. 미완료 작업 및 작업 트리 상태 (Pending Work & Git State)
- 작업 중단 시점의 미해결 항목:
- 변경된 파일 현황 (`git status --short`):
```text
{{GIT_STATUS_OUTPUT}}
```
- Diff 통계 (`git diff --stat`):
```text
{{GIT_DIFF_STAT_OUTPUT}}
```

## 3. 마지막 검증 결과 및 실패 로그 (Last Verification & Error Logs)
- 마지막 실행 명령: `{{LAST_COMMAND}}`
- 종료 코드: {{EXIT_CODE}}
- 실패 원인 분석 및 핵심 로그 발췌:
```text
{{ERROR_LOG_EXCERPT}}
```

## 4. 직면한 차단 요인 및 미해결 의문 (Blockers & Open Questions)
- 의사결정 또는 외부 입력이 필요한 사항:
- 확인된 제약사항:

## 5. 다음 담당자를 위한 즉각적 행동 지침 (Next Single Action)
*(다음 담당 에이전트가 인계받아 즉시 실행해야 할 단 하나의 명확한 작업)*
> **다음 단계**: {{NEXT_SINGLE_ACTION}}
HARNESS_DOC_EOF

  emit_doc "$root" ".harness/waves/TEMPLATE.yaml" <<'HARNESS_DOC_EOF'
schema_version: '1.0'
wave_id: wave-000
milestone_id: milestone-000
title: Wave 제목
description: Wave 실행 목적 및 개요
status: draft # draft | approved | active | completed

# 병렬 실행 한도 및 제약
limits:
  max_parallel_workers: 2

# 소속 Task 목록 (동일 parallel_group은 경로 충돌이 없는 병렬 가능 Task)
tasks:
  - task_id: task-001
    parallel_group: 1
    primary_worker: '@@WORKER@@'
    reviewer: '@@REVIEWER@@'
  - task_id: task-002
    parallel_group: 1
    primary_worker: '@@WORKER@@'
    reviewer: '@@REVIEWER@@'

# 선행 완료 필수 Wave
dependencies: []

# 사용자 승인 메타데이터 (미승인 시 실행 불가)
approval:
  user_approved: false
  approved_by: ''
  approved_at: ''
HARNESS_DOC_EOF

  emit_doc "$root" ".harness/decisions/TEMPLATE.md" <<'HARNESS_DOC_EOF'
# 사용자 승인 기록

이 파일은 Task를 `completed`로 전이하기 위한 **유일한** 근거다.
Agent는 이 파일을 스스로 만들 수 없다. 사용자가 직접 작성하거나 명시적으로 지시해야 한다.

파일명 규칙: `.harness/decisions/<task-id>-approval.md`

---

Task: task-000
승인: no
승인자:
승인 시각:
근거 Review: .harness/reviews/task-000-review-1.md

## 확인한 것

- [ ] Acceptance Criteria 전부 충족
- [ ] Review 판정이 APPROVED
- [ ] Evidence의 검증 명령과 종료 코드 확인
- [ ] 잔여 리스크 수용 가능

`승인: yes` 로 바꾸기 전에는 `herdr-harness transition ... completed` 가 거부된다.
HARNESS_DOC_EOF

}

cmd_init() {
  local target="${1:-}"
  [[ -n "$target" && "$target" != -* ]] || die "init에는 새 프로젝트 경로가 필요합니다."
  shift

  local name="" goal="" profile="generic"
  local orchestrator="claude" worker="codex" reviewer="agy" fallback="claude,agy"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) [[ $# -ge 2 ]] || die "--name 값이 필요합니다."; name="$2"; shift 2 ;;
      --goal) [[ $# -ge 2 ]] || die "--goal 값이 필요합니다."; goal="$2"; shift 2 ;;
      --profile) [[ $# -ge 2 ]] || die "--profile 값이 필요합니다."; profile="$2"; shift 2 ;;
      --orchestrator) [[ $# -ge 2 ]] || die "--orchestrator 값이 필요합니다."; orchestrator="$2"; shift 2 ;;
      --worker) [[ $# -ge 2 ]] || die "--worker 값이 필요합니다."; worker="$2"; shift 2 ;;
      --reviewer) [[ $# -ge 2 ]] || die "--reviewer 값이 필요합니다."; reviewer="$2"; shift 2 ;;
      --fallback) [[ $# -ge 2 ]] || die "--fallback 값이 필요합니다."; fallback="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "알 수 없는 init 옵션: $1" ;;
    esac
  done

  target="$(realpath -m "$target")"
  [[ "$target" != "/" && "$target" != "$HOME" ]] || die "너무 넓은 경로는 사용할 수 없습니다: $target"
  if [[ -d "$target" ]] && find "$target" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    die "신규 프로젝트 전용입니다. 대상 경로가 비어 있지 않습니다: $target"
  fi

  [[ -n "$name" ]] || name="$(basename "$target")"
  if [[ -z "$goal" ]]; then prompt_required goal "프로젝트 목표"; fi
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "프로젝트명은 영문, 숫자, 점, 밑줄, 하이픈만 사용할 수 있습니다."
  valid_profile "$profile" || die "지원하지 않는 Profile입니다: $profile"
  valid_provider "$orchestrator" || die "지원하지 않는 Orchestrator입니다: $orchestrator"
  valid_provider "$worker" || die "지원하지 않는 Worker입니다: $worker"
  valid_provider "$reviewer" || die "지원하지 않는 Reviewer입니다: $reviewer"
  [[ "$worker" != "$reviewer" ]] || die "Worker와 Reviewer는 다른 Provider여야 합니다."

  IFS=',' read -r -a fallback_items <<<"$fallback"
  for provider in "${fallback_items[@]}"; do
    valid_provider "$provider" || die "지원하지 않는 Fallback Provider입니다: $provider"
  done

  mkdir -p "$target"
  local name_yaml goal_yaml
  name_yaml="$(yaml_quote "$name")"
  goal_yaml="$(yaml_quote "$goal")"

  write_file "$target" ".gitignore" <<'EOF'
.env
.env.*
!.env.example
.harness/runtime/
.harness/evidence/raw/
.harness/worktrees/
__pycache__/
.pytest_cache/
.venv/
node_modules/
EOF

  write_file "$target" "AGENTS.md" <<EOF
# Agent Instructions: $name

이 프로젝트는 Herdr Agent/Skills Harness로 운영한다.

반드시 \`.harness/SPEC.md\`, \`.harness/STATE.md\`, 현재 Task YAML, 현재 역할 문서와 관련 Skill을 읽는다.

- 승인된 SPEC과 Task 없이 구현하지 않는다.
- 하나의 Task는 하나의 목적만 가진다.
- Task당 쓰기 가능한 Primary Worker는 한 명이다.
- 기존 코드·데이터·문서·Dump를 먼저 확인한다.
- Worker는 \`submitted\`까지만 제안하고 사용자가 \`completed\`를 승인한다.
- 실패·쿼터 확인 후 Handover와 사용자 승인을 거쳐 Provider를 교체한다.
- 위험한 명령, 배포, 외부 쓰기는 사용자 승인을 받는다.

기본 배정: Orchestrator=$orchestrator, Worker=$worker, Reviewer=$reviewer, Fallback=$fallback
EOF

  write_file "$target" "CLAUDE.md" <<'EOF'
# Claude Code Entry

`AGENTS.md`를 공통 정책으로 사용한다. 현재 역할에 맞는 `.agents/roles/*.agent.md`와 `.claude/skills/`의 Harness Skill을 읽는다. Herdr Pane 제어는 `HERDR_ENV=1`일 때만 수행한다.
EOF

  write_file "$target" "GEMINI.md" <<'EOF'
# Antigravity Entry

`AGENTS.md`를 공통 정책으로 사용한다. 현재 역할에 맞는 `.agents/roles/*.agent.md`와 `.agents/skills/`의 Harness Skill을 읽는다. Herdr Pane 제어는 `HERDR_ENV=1`일 때만 수행한다.
EOF

  write_file "$target" ".harness/project.yaml" <<EOF
schema_version: '1.0'
project:
  name: $name_yaml
  goal: $goal_yaml
  profile: '$profile'

mode:
  # 사용자가 Controller와 최종 Gate 역할을 한다.
  type: agent_driven
  unattended_execution: false

providers:
  orchestrator: '$orchestrator'
  primary_worker: '$worker'
  reviewer: '$reviewer'
  fallback_chain: [$fallback]

limits:
  # 전체 Task가 아니라 현재 활성 목록의 상한이다.
  max_active_tasks: 5
  max_parallel_workers: 2
  max_primary_workers_per_task: 1

approval:
  spec: user_required
  milestone_plan: user_required
  provider_failover: user_required
  integration: user_required
  destructive_action: user_required
EOF

  write_file "$target" ".harness/SPEC.md" <<EOF
# Specification: $name

## 1. 핵심 목표

$goal

## 2. 기존 자료와 재사용 판단

- [ ] 기존 코드 또는 저장소
- [ ] 데이터, Sample Dump 또는 Notebook
- [ ] 설계서, API, MIB 또는 운영 문서
- [ ] 라이선스와 재사용 제약

## 3. 기술 스택 및 제약

- 언어/프레임워크: TBD
- 실행 환경: TBD
- 변경 금지 영역: TBD

## 4. 요구사항

- [ ] Interview 후 작성

## 5. Acceptance Criteria

- [ ] Criterion마다 검증 방법 연결

## 6. 제외 범위

- TBD

## 7. 사용자 승인

- 상태: draft
- 승인자:
- 승인 시각:
EOF

  write_file "$target" ".harness/MILESTONES.md" <<'EOF'
# Milestones

| ID | 중간 목표 | 상태 | 완료 기준 |
|---|---|---|---|
| milestone-001 | Interview 후 작성 | draft | 사용자 승인 |
EOF

  write_file "$target" ".harness/STATE.md" <<EOF
# Project State

- Project: $name
- Status: interviewing
- Current milestone: milestone-001
- Active wave: none
- Max active tasks: 5
- Max parallel workers: 2

| Task | 목적 | Worker | Reviewer | 상태 | 검증 |
|---|---|---|---|---|---|
| task-001 | 기존 자료와 요구사항 확인 | $worker | $reviewer | draft | user-review |

## Pending decisions

- SPEC 인터뷰 필요
EOF

  write_file "$target" ".harness/policies/project-policy.yaml" <<'EOF'
execution:
  # 사용자 승인 없이 다음 Wave로 진행하지 않는다.
  unattended_execution: false
  rebase_while_attempt_running: false

security:
  # 운영 지침이며 OS 수준 Sandbox는 아니다.
  allow_destructive_commands: false
  allow_production_deploy: false
  allow_secret_output: false
  allow_network_by_default: false

references:
  require_existing_asset_discovery: true
  require_reference_inventory: true
EOF

  write_file "$target" ".harness/policies/review-policy.yaml" <<EOF
review:
  default_provider: '$reviewer'
  provider_must_differ_from_worker: true
  focus:
    - requirement_coverage
    - correctness
    - regression_risk
    - security_and_secrets
    - maintainability
    - verification_quality
    - documentation_and_handover
EOF

  write_file "$target" ".harness/policies/quota-policy.yaml" <<'EOF'
quota_policy:
  # 정상 실행 중에는 다른 Provider를 호출하지 않는다.
  strategy: failure_only
  automatic_failover: false
  require_handover: true
  require_user_approval: true

  # 능동 확인: `herdr-harness quota-check PATH TASK_ID ROLE`
  # (claude/codex는 실행 중인 Agent에 /status를 보내 읽고, agy는
  # `agy --print "/usage"`로 바로 조회한다 — Task 없이 확인하려면
  # `quota-check PATH --provider agy`). 어느 경우에도 자동으로 Provider를
  # 바꾸지 않는다 — 위 strategy: failure_only 원칙 그대로다.
  #
  # 수동 확인: `agy --print "/usage"` (agy), Agent Pane 안에서 `/status`
  # 입력(claude, codex).
  #
  # 경보 임계값(quota-check가 low로 판정하는 기준). 이 값을 낮추면 더 여유
  # 있을 때부터 low로 뜬다 — 코드가 아니라 여기서 조정한다.
  low_warning_threshold_pct: 25

  # dispatch/observe는 Agent 출력에서 알려진 쿼터 경고 문구를 지나가는 김에
  # 스캔해 evidence에 "쿼터 신호(자동 감지)" 절로 남긴다(확정 아님, 참고용).
  passive_scan_on_dispatch: true
EOF

  write_file "$target" ".harness/profiles/generic.yaml" <<'EOF'
profile_id: generic
task_types: [code, research, data, document, ops]
review_focus: [correctness, regression, security, maintainability]
EOF

  write_file "$target" ".harness/profiles/python-timeseries.yaml" <<'EOF'
profile_id: python-timeseries
reference_inputs: [existing_notebooks, source_code, datasets, data_dictionary, experiment_results]
review_focus: [time_ordered_split, leakage_prevention, baseline, backtesting, reproducibility, uncertainty]
EOF

  write_file "$target" ".harness/profiles/network-device.yaml" <<'EOF'
profile_id: network-device
reference_inputs: [snmp_dumps, mib_files, vendor_docs, receiver_configs, existing_normalizers]
review_focus: [canonical_schema, oid_provenance, counter_reset, units, timestamps, unknown_oid, dump_regression]
EOF

  write_file "$target" ".harness/tasks/TEMPLATE.yaml" <<EOF
schema_version: '1.0'
task_id: task-000
milestone_id: milestone-000
title: Task 제목
objective: 하나의 검증 가능한 목적
status: draft
primary_worker: '$worker'
reviewer: '$reviewer'
fallback_chain: [$fallback]
dependencies: []
target_files: []
write_scope: []
resources: []
inputs:
  references: []
  artifacts: []
acceptance_criteria:
  - criterion_id: AC-001
    statement: 검증 가능한 완료 조건
    verified_by:
      type: manual-review
      instruction: 구체적인 확인 방법
review_focus: [requirement_coverage, correctness, regression_risk]
EOF

  write_file "$target" ".harness/references/inventory.md" <<'EOF'
# Reference Inventory

| ID | 경로/URL | 유형 | 출처 | 재사용 판단 | 제약 |
|---|---|---|---|---|---|
EOF

  for area in waves attempts evidence reviews handovers decisions archive; do
    write_file "$target" ".harness/$area/README.md" <<EOF
# ${area^}

이 디렉터리에는 Project의 $area 기록을 보존한다. 기존 기록을 덮어쓰지 않고 Task ID와 Attempt 번호를 파일명에 포함한다.
EOF
  done

  write_project_docs "$target" "$name" "$orchestrator" "$worker" "$reviewer" "$fallback"

  mkdir -p "$target/.claude/skills"
  local skill_dir skill_name
  for skill_dir in "$target"/.agents/skills/*; do
    skill_name="$(basename "$skill_dir")"
    ln -s "../../.agents/skills/$skill_name" "$target/.claude/skills/$skill_name"
  done

  write_file "$target" "HARNESS_START.md" <<EOF
# 시작 방법

\`\`\`bash
cd "$target"
herdr-harness start .
\`\`\`

Herdr 첫 Pane에서 \`$orchestrator\`를 실행하고 다음을 요청한다.

\`\`\`text
harness-orchestrate Skill을 사용해 프로젝트를 시작해줘.
기존 코드, 데이터, 문서, Dump가 있는지 먼저 인터뷰하고
SPEC 승인 전에는 구현하지 마.
\`\`\`
EOF

  init_git_baseline "$target"

  info "생성 완료: $target"
  info "다음 단계: cd '$target' && herdr-harness start ."
}

# ---------------------------------------------------------------------------
# 제한 스키마 YAML 리더
# 범용 YAML 파서를 흉내 내지 않는다. Harness가 생성한 고정 스키마만 엄격히 읽고,
# 정확히 한 번 매칭되지 않으면 실패한다.
# ---------------------------------------------------------------------------

yaml_unquote() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  case "$value" in
    \'*\') value="${value:1:${#value}-2}"; value="${value//\'\'/\'}" ;;
    \"*\") value="${value:1:${#value}-2}" ;;
  esac
  printf '%s' "$value"
}

yaml_scalar() {
  local file="$1" key="$2" required="${3:-required}"
  local count line
  [[ -f "$file" ]] || die "YAML 파일이 없습니다: $file"
  count="$(grep -c "^${key}:" "$file" 2>/dev/null || true)"
  if [[ "$count" -eq 0 ]]; then
    [[ "$required" == optional ]] || die "필수 키가 없습니다: $key ($file)"
    return 0
  fi
  [[ "$count" -eq 1 ]] || die "키가 중복되었습니다: $key ($file)"
  line="$(grep -m1 "^${key}:" "$file")"
  yaml_unquote "${line#"${key}":}"
}

yaml_flow_list() {
  local file="$1" key="$2"
  local line inner item
  line="$(grep -m1 "^${key}:" "$file" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 0
  inner="${line#"${key}":}"
  inner="$(yaml_unquote "$inner")"
  case "$inner" in
    \[*\]) inner="${inner:1:${#inner}-2}" ;;
    *) return 0 ;;
  esac
  [[ -n "${inner//[[:space:]]/}" ]] || return 0
  local IFS=','
  for item in $inner; do
    item="$(yaml_unquote "$item")"
    [[ -z "$item" ]] || printf '%s\n' "$item"
  done
}

project_field() {
  local root="$1" section="$2" key="$3"
  local file="$root/.harness/project.yaml"
  local count line
  [[ -f "$file" ]] || die "project.yaml이 없습니다: $file"
  count="$(awk -v s="$section:" -v k="  $key:" '
    $0 == s { inside = 1; next }
    /^[^[:space:]#]/ { inside = 0 }
    inside && index($0, k) == 1 { n++ }
    END { print n + 0 }' "$file")"
  [[ "$count" -eq 1 ]] || die "project.yaml에서 $section.$key 를 정확히 한 번 찾지 못했습니다 (발견 $count 회)."
  line="$(awk -v s="$section:" -v k="  $key:" '
    $0 == s { inside = 1; next }
    /^[^[:space:]#]/ { inside = 0 }
    inside && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$file")"
  yaml_unquote "$line"
}

task_file() {
  local root="$1" task_id="$2"
  local path="$root/.harness/tasks/${task_id}.yaml"
  [[ -f "$path" ]] || die "Task 파일이 없습니다: $path"
  printf '%s\n' "$path"
}

task_ids() {
  local root="$1" path base
  for path in "$root"/.harness/tasks/*.yaml; do
    [[ -f "$path" ]] || continue
    base="$(basename "$path" .yaml)"
    [[ "$base" != TEMPLATE ]] || continue
    printf '%s\n' "$base"
  done
}

valid_task_status() {
  case "$1" in
    draft|ready|active|submitted|reviewing|changes_requested|blocked|handover_required|awaiting_approval|completed) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Git 기준선
# ---------------------------------------------------------------------------

git_baseline_status() {
  # 출력: ok | no-git | no-repo | no-commit
  local root="$1"
  command -v git >/dev/null 2>&1 || { printf 'no-git\n'; return 0; }
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf 'no-repo\n'; return 0; }
  git -C "$root" rev-parse HEAD >/dev/null 2>&1 || { printf 'no-commit\n'; return 0; }
  printf 'ok\n'
}

require_git_baseline() {
  local root="$1" state
  state="$(git_baseline_status "$root")"
  case "$state" in
    ok) return 0 ;;
    no-git) die "git 명령을 찾을 수 없습니다. Harness는 Git Diff를 Review와 Handover의 근거로 사용합니다." ;;
    no-repo) die "Git 저장소가 아닙니다: $root  (git init 후 기준 commit을 만드세요)" ;;
    no-commit) die "기준 commit이 없습니다: $root  (git add -A && git commit 으로 기준선을 만드세요)" ;;
  esac
}

init_git_baseline() {
  local root="$1"
  if ! command -v git >/dev/null 2>&1; then
    info "경고: git이 없어 저장소를 초기화하지 못했습니다. Diff 기반 Review와 Handover를 사용할 수 없습니다."
    return 0
  fi
  git -C "$root" init -q
  git -C "$root" add -A
  if git -C "$root" config user.email >/dev/null 2>&1 &&
     git -C "$root" config user.name >/dev/null 2>&1; then
    git -C "$root" -c core.hooksPath=/dev/null commit -q -m "chore: harness 기준선" \
      && info "Git 기준선 commit을 생성했습니다."
  else
    info "경고: git user.name / user.email이 없어 기준 commit을 만들지 못했습니다."
    info "        다음을 실행한 뒤 계속하세요: git -C '$root' commit -m 'chore: harness 기준선'"
  fi
}

# ---------------------------------------------------------------------------
# 이벤트 로그 (append-only)
# ---------------------------------------------------------------------------

append_event() {
  local root="$1"; shift
  local log="$root/.harness/evidence/events.tsv"
  local stamp
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ ! -f "$log" ]]; then
    printf 'timestamp\tevent\ttask\tfrom\tto\tdetail\n' >"$log"
  fi
  printf '%s\t%s\n' "$stamp" "$(printf '%s\t' "$@" | sed 's/\t$//')" >>"$log"
}

# ---------------------------------------------------------------------------
# validate — 읽기 전용 사전 검증. 상태를 바꾸지 않는다.
# ---------------------------------------------------------------------------

cmd_validate() {
  local root_arg="." wave="" strict_git=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wave) [[ $# -ge 2 ]] || die "--wave 값이 필요합니다."; wave="$2"; shift 2 ;;
      --no-git) strict_git=0; shift ;;
      -h|--help) printf '사용법: %s validate [PATH] [--wave ID] [--no-git]\n' "$SCRIPT_NAME"; return 0 ;;
      -*) die "알 수 없는 validate 옵션: $1" ;;
      *) root_arg="$1"; shift ;;
    esac
  done

  local root problems=0
  root="$(project_root "$root_arg")"

  report_problem() { printf '[FAIL] %s\n' "$*"; problems=$((problems + 1)); }
  report_ok() { printf '[OK]   %s\n' "$*"; }

  # 1. Git 기준선
  local git_state
  git_state="$(git_baseline_status "$root")"
  if [[ "$git_state" == ok ]]; then
    report_ok "Git 기준선 존재"
  elif [[ "$strict_git" -eq 1 ]]; then
    report_problem "Git 기준선 없음 ($git_state). Diff 기반 Review·Handover·Context Packet을 만들 수 없습니다."
  else
    report_ok "Git 검사 생략 (--no-git)"
  fi

  # 2. SPEC 승인
  local spec_state
  spec_state="$(awk -F': ' '/^- 상태:/{print $2; exit}' "$root/.harness/SPEC.md" 2>/dev/null || true)"
  spec_state="${spec_state:-unknown}"
  if [[ "$spec_state" == approved ]]; then
    report_ok "SPEC 승인됨"
  else
    report_ok "SPEC 상태=$spec_state (구현 단계 전이는 승인 후에만 가능)"
  fi

  # 3. Provider 배정
  local p_worker p_reviewer
  p_worker="$(project_field "$root" providers primary_worker)"
  p_reviewer="$(project_field "$root" providers reviewer)"
  if [[ "$p_worker" == "$p_reviewer" ]]; then
    report_problem "project.yaml의 primary_worker와 reviewer가 같습니다: $p_worker"
  else
    report_ok "기본 Worker($p_worker) != Reviewer($p_reviewer)"
  fi

  # 4. 상한
  local max_active max_parallel
  max_active="$(awk '/^  max_active_tasks:/{print $2; exit}' "$root/.harness/project.yaml")"
  max_parallel="$(awk '/^  max_parallel_workers:/{print $2; exit}' "$root/.harness/project.yaml")"

  # 5. Task별 검사
  local task_id path status worker reviewer dep
  local active_count=0 open_count=0
  local -A scope_owner=()

  while IFS= read -r task_id; do
    [[ -n "$task_id" ]] || continue
    path="$root/.harness/tasks/${task_id}.yaml"
    local declared_id
    declared_id="$(yaml_scalar "$path" task_id)"
    [[ "$declared_id" == "$task_id" ]] ||
      report_problem "$task_id: 파일명과 task_id가 다릅니다 (task_id=$declared_id)"

    status="$(yaml_scalar "$path" status)"
    valid_task_status "$status" || report_problem "$task_id: 알 수 없는 status=$status"

    worker="$(yaml_scalar "$path" primary_worker)"
    reviewer="$(yaml_scalar "$path" reviewer)"
    valid_provider "$worker" || report_problem "$task_id: 알 수 없는 primary_worker=$worker"
    valid_provider "$reviewer" || report_problem "$task_id: 알 수 없는 reviewer=$reviewer"
    [[ "$worker" != "$reviewer" ]] ||
      report_problem "$task_id: Worker와 Reviewer가 같습니다 ($worker)"

    case "$status" in
      completed) ;;
      *) open_count=$((open_count + 1)) ;;
    esac
    if [[ "$status" == active ]]; then
      active_count=$((active_count + 1))
      fi

    # 의존성: ready 이상으로 열려 있는 Task의 선행 Task는 completed여야 한다
    if [[ "$status" == ready || "$status" == active ]]; then
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        local dep_path dep_status
        dep_path="$root/.harness/tasks/${dep}.yaml"
        if [[ ! -f "$dep_path" ]]; then
          report_problem "$task_id: 의존 Task 파일이 없습니다: $dep"
          continue
        fi
        dep_status="$(yaml_scalar "$dep_path" status)"
        [[ "$dep_status" == completed ]] ||
          report_problem "$task_id: 의존 Task $dep 가 completed가 아닙니다 (현재 $dep_status)"
      done < <(yaml_flow_list "$path" dependencies)
    fi

    # write_scope 충돌: 동시에 active인 Task끼리만 검사
    if [[ "$status" == active ]]; then
      local scope
      while IFS= read -r scope; do
        [[ -n "$scope" ]] || continue
        if [[ -n "${scope_owner[$scope]:-}" ]]; then
          report_problem "write_scope 충돌: '$scope' 를 ${scope_owner[$scope]} 와 $task_id 가 동시에 소유"
        else
          scope_owner[$scope]="$task_id"
        fi
      done < <(yaml_flow_list "$path" write_scope)
    fi
  done < <(task_ids "$root")

  if [[ "$open_count" -le "${max_active:-5}" ]]; then
    report_ok "활성 Task $open_count / 상한 ${max_active:-5}"
  else
    report_problem "활성 Task가 상한을 초과했습니다: $open_count > ${max_active:-5}"
  fi
  if [[ "$active_count" -le "${max_parallel:-2}" ]]; then
    report_ok "동시 Worker $active_count / 상한 ${max_parallel:-2}"
  else
    report_problem "동시 Worker가 상한을 초과했습니다: $active_count > ${max_parallel:-2}"
  fi

  # 6. Wave
  if [[ -n "$wave" ]]; then
    local wave_path wave_status
    wave_path="$root/.harness/waves/${wave}.yaml"
    if [[ ! -f "$wave_path" ]]; then
      report_problem "Wave 파일이 없습니다: $wave_path"
    else
      wave_status="$(yaml_scalar "$wave_path" status)"
      if [[ "$wave_status" == approved ]]; then
        report_ok "Wave $wave 승인됨"
      else
        report_problem "Wave $wave 가 승인되지 않았습니다 (status=$wave_status)"
      fi
    fi
  fi

  printf '\n'
  if [[ "$problems" -eq 0 ]]; then
    printf 'validate: 통과\n'
    return 0
  fi
  printf 'validate: %d개 문제\n' "$problems"
  return 1
}

# ---------------------------------------------------------------------------
# transition — 허용된 상태 전이만 수행한다. 판정을 대행하지 않는다.
# ---------------------------------------------------------------------------

transition_allowed() {
  local from="$1" to="$2"
  case "${from}>${to}" in
    'draft>ready') return 0 ;;
    'ready>active') return 0 ;;
    'active>submitted') return 0 ;;
    'active>blocked') return 0 ;;
    'active>handover_required') return 0 ;;
    'blocked>active') return 0 ;;
    'submitted>reviewing') return 0 ;;
    'reviewing>changes_requested') return 0 ;;
    'reviewing>awaiting_approval') return 0 ;;
    'changes_requested>ready') return 0 ;;
    'handover_required>ready') return 0 ;;
    'awaiting_approval>completed') return 0 ;;
    *) return 1 ;;
  esac
}

cmd_transition() {
  local root_arg="" task_id="" to_state="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) [[ $# -ge 2 ]] || die "--note 값이 필요합니다."; note="$2"; shift 2 ;;
      -h|--help)
        printf '사용법: %s transition PATH TASK_ID TO_STATE [--note TEXT]\n' "$SCRIPT_NAME"
        return 0 ;;
      -*) die "알 수 없는 transition 옵션: $1" ;;
      *)
        if [[ -z "$root_arg" ]]; then root_arg="$1"
        elif [[ -z "$task_id" ]]; then task_id="$1"
        elif [[ -z "$to_state" ]]; then to_state="$1"
        else die "인자가 너무 많습니다: $1"
        fi
        shift ;;
    esac
  done

  [[ -n "$root_arg" && -n "$task_id" && -n "$to_state" ]] ||
    die "사용법: $SCRIPT_NAME transition PATH TASK_ID TO_STATE"

  local root path from_state
  root="$(project_root "$root_arg")"
  path="$(task_file "$root" "$task_id")"
  valid_task_status "$to_state" || die "알 수 없는 목표 상태: $to_state"
  from_state="$(yaml_scalar "$path" status)"

  [[ "$from_state" != "$to_state" ]] || die "$task_id 는 이미 $to_state 입니다."
  transition_allowed "$from_state" "$to_state" ||
    die "허용되지 않은 전이입니다: $from_state -> $to_state ($task_id)"

  # --- 전이별 필수 조건 ---
  case "$to_state" in
    ready)
      local spec_state
      spec_state="$(awk -F': ' '/^- 상태:/{print $2; exit}' "$root/.harness/SPEC.md" 2>/dev/null || true)"
      [[ "$spec_state" == approved ]] ||
        die "SPEC이 승인되지 않았습니다 (현재 ${spec_state:-unknown}). .harness/SPEC.md의 '- 상태:'를 approved로 바꾸고 승인자를 기록하세요."
      ;;
    active)
      require_git_baseline "$root"
      ;;
    submitted)
      compgen -G "$root/.harness/attempts/${task_id}-attempt-*.md" >/dev/null ||
        die "Attempt 기록이 없어 submitted로 전이할 수 없습니다: .harness/attempts/${task_id}-attempt-*.md"
      compgen -G "$root/.harness/evidence/${task_id}-*.md" >/dev/null ||
        die "Evidence 기록이 없어 submitted로 전이할 수 없습니다: .harness/evidence/${task_id}-*.md"
      ;;
    reviewing)
      local worker reviewer
      worker="$(yaml_scalar "$path" primary_worker)"
      reviewer="$(yaml_scalar "$path" reviewer)"
      [[ "$worker" != "$reviewer" ]] ||
        die "Reviewer가 Worker와 같습니다 ($worker). 독립 Review가 성립하지 않습니다."
      ;;
    awaiting_approval)
      # 과거의 APPROVED가 남아 있어도 최신 Review가 반려면 통과시키지 않는다.
      local latest_review verdict
      latest_review="$(ls -1t "$root/.harness/reviews/${task_id}"-*.md 2>/dev/null | head -n 1 || true)"
      [[ -n "$latest_review" ]] ||
        die "Review 파일이 없습니다: .harness/reviews/${task_id}-*.md"
      # 줄 시작의 '판정:' 만 읽는다. Markdown 굵은 표시(**판정: X**)는 허용하되
      # focus 항목의 '- 판정: PASS / FAIL / NA' 같은 하위 줄은 매칭하지 않는다.
      verdict="$(sed -n 's/^\*\{0,2\}판정:[[:space:]]*\([A-Za-z_]*\).*/\1/p' "$latest_review" | head -n 1)"
      [[ "$verdict" == APPROVED ]] ||
        die "최신 Review의 판정이 APPROVED가 아닙니다 (${verdict:-없음}): $latest_review"
      ;;
    completed)
      local approval="$root/.harness/decisions/${task_id}-approval.md"
      [[ -f "$approval" ]] ||
        die "사용자 승인 기록이 없습니다: $approval  (Agent는 completed를 만들 수 없습니다)"
      grep -q '^승인:[[:space:]]*yes' "$approval" ||
        die "승인 기록에 '승인: yes' 줄이 없습니다: $approval"
      ;;
  esac

  # --- 원자적 갱신 ---
  local temporary
  temporary="$(mktemp "$(dirname "$path")/.harness-transition.XXXXXX")"
  trap "rm -f -- '$temporary'" RETURN
  awk -v to="$to_state" '
    !done_flag && index($0, "status:") == 1 { print "status: " to; done_flag = 1; next }
    { print }
  ' "$path" >"$temporary"
  grep -q "^status: ${to_state}$" "$temporary" || {
    rm -f "$temporary"
    die "status 갱신에 실패했습니다: $path"
  }
  chmod 0644 "$temporary"
  mv "$temporary" "$path"

  append_event "$root" transition "$task_id" "$from_state" "$to_state" "${note:-}"

  printf '%s: %s -> %s\n' "$task_id" "$from_state" "$to_state"

  # STATE.md 드리프트 안내 (스크립트가 산문을 대신 쓰지 않는다)
  if grep -q "| *${task_id} *|" "$root/.harness/STATE.md" 2>/dev/null; then
    grep -q "| *${task_id} *|.*| *${to_state} *|" "$root/.harness/STATE.md" ||
      info "STATE.md의 $task_id 행이 아직 $to_state 가 아닙니다. Orchestrator가 갱신하세요."
  fi
}

# ---------------------------------------------------------------------------
# 스텝 실행기 — dispatch / observe / close-agent / status --live
# 호출 1회 = 1스텝. 재시도, 상태 전이, failover, blocked 응답을 하지 않는다.
# ---------------------------------------------------------------------------

_runtime_require_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "잘못된 Task ID입니다: $1"
}

_runtime_atomic_copy() {
  local source="$1" destination="$2" parent temporary
  parent="$(dirname "$destination")"
  mkdir -p "$parent"
  temporary="$(mktemp "$parent/.runtime-write.XXXXXX")"
  if ! cp -- "$source" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$destination"
}

_runtime_atomic_text() {
  local destination="$1" value="$2" parent temporary
  parent="$(dirname "$destination")"
  mkdir -p "$parent"
  temporary="$(mktemp "$parent/.runtime-write.XXXXXX")"
  printf '%s\n' "$value" >"$temporary"
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$destination"
}

_runtime_json_field() {
  local input="$1" field="$2" value=""
  # herdr 호출은 전부 2>&1로 캡처한다. 경고 한 줄이 stderr에 섞여도 파싱이
  # 죽지 않도록, 첫 '{'부터 마지막 '}'까지만 남기고 자른다(BACKLOG.md #3).
  if [[ "$input" == *"{"* && "$input" == *"}"* ]]; then
    input="${input#*\{}"
    input="{${input}"
    input="${input%\}*}"
    input="${input}}"
  fi
  if command -v jq >/dev/null 2>&1; then
    value="$(printf '%s' "$input" | jq -r ".. | objects | .$field? // empty" 2>/dev/null | head -n 1 || true)"
  else
    # 앞쪽 탐욕적 .* 는 같은 키가 여러 번 나오면 마지막 값을 뽑는다(BACKLOG.md #2).
    # grep -o 로 겹치지 않는 첫 매치만 취해 jq 경로(첫 값)와 결과를 맞춘다.
    value="$(printf '%s' "$input" | tr -d '\n' \
      | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | head -n 1 \
      | sed -n 's/.*:[[:space:]]*"\([^"]*\)"/\1/p')"
  fi
  printf '%s' "$value"
}

_runtime_yaml_scalar() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      sub("^[[:space:]]*" key ":[[:space:]]*", "")
      gsub(/^['\''"]|['\''"]$/, "")
      print
      exit
    }
  ' "$file"
}

_runtime_yaml_block() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^" key ":[[:space:]]*" { found=1; print; next }
    found && /^[^[:space:]#][^:]*:/ { exit }
    found { print }
  ' "$file"
}

_runtime_has_secret() {
  LC_ALL=C grep -Eqi 'AKIA[0-9A-Z]{8,}|BEGIN[[:space:]]+(RSA |EC |OPENSSH )?PRIVATE KEY|password[[:space:]]*=|token[[:space:]]*=|api[_-]?key[[:space:]]*=' "$1"
}

# 쿼터 경고 신호 스캔. 자동으로 Provider를 바꾸지 않는다 — 확인만 하고 정보로
# 남긴다(ARCHITECTURE.md §8 "Provider 교체는 실패가 확인된 경우에만"). 못 찾으면
# 아무것도 출력하지 않는다: 감지 실패를 "쿼터 여유 있음"으로 착각하면 안 된다.
_runtime_scan_quota_signal() {
  local text="$1" pct
  pct="$(printf '%s' "$text" | grep -Eio '[0-9]+% of your (weekly|daily|five.hour) limit' | grep -Eo '^[0-9]+' | sort -n | head -n 1)"
  if [[ -n "$pct" ]]; then
    printf '남은 한도 %s%% 부근 경고 문구 감지("...%s%% of your ... limit")' "$pct" "$pct"
    return 0
  fi
  if printf '%s' "$text" | grep -Eqi 'usage limit reached|rate.?limit exceeded|quota.?exceeded|429 too many requests'; then
    printf '쿼터·Rate Limit 소진 문구 감지'
    return 0
  fi
  return 1
}

_runtime_next_attempt() {
  local root="$1" task_id="$2" path base number maximum=0
  shopt -s nullglob
  for path in "$root/.harness/attempts/$task_id-attempt-"*.md; do
    base="${path##*/}"
    number="${base#"$task_id-attempt-"}"
    number="${number%.md}"
    [[ "$number" =~ ^[0-9]+$ ]] || continue
    (( number > maximum )) && maximum="$number"
  done
  shopt -u nullglob
  printf '%s\n' "$((maximum + 1))"
}

_runtime_write_result() {
  local root="$1" task_id="$2" role="$3" result="$4"
  _runtime_atomic_text "$root/.harness/runtime/$task_id-$role.result" "$result"
}

_runtime_write_meta() {
  local root="$1" task_id="$2" role="$3" agent_name="$4" pane_id="$5" provider="$6" attempt="$7"
  local destination temporary
  destination="$root/.harness/runtime/$task_id-$role.meta"
  temporary="$(mktemp "$root/.harness/runtime/.meta.XXXXXX")"
  {
    printf 'task_id=%s\n' "$task_id"
    printf 'role=%s\n' "$role"
    printf 'agent_name=%s\n' "$agent_name"
    printf 'pane_id=%s\n' "$pane_id"
    printf 'provider=%s\n' "$provider"
    printf 'attempt=%s\n' "$attempt"
  } >"$temporary"
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$destination"
}

_runtime_meta_value() {
  local file="$1" key="$2"
  sed -n "s/^$key=//p" "$file" | head -n 1
}

_runtime_append_evidence() {
  local evidence="$1" addition="$2" temporary
  temporary="$(mktemp "$(dirname "$evidence")/.evidence.XXXXXX")"
  trap "rm -f -- '$temporary'" RETURN
  [[ ! -f "$evidence" ]] || cp -- "$evidence" "$temporary"
  cat -- "$addition" >>"$temporary"
  if _runtime_has_secret "$temporary"; then
    : >"$temporary"
    printf '# Evidence withheld\n\n경고: Secret 의심 패턴이 발견되어 원문을 저장하지 않았습니다.\n' >"$temporary"
  fi
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$evidence"
}

_runtime_normalize_state() {
  local get_status="$1" get_output="$2" prompt_status="${3:-0}" prompt_output="${4:-}"
  local state combined
  combined="$prompt_output $get_output"
  # Agent가 실제로 사라졌으면 stalled보다 agent_lost가 더 실행 가능한 정보다.
  if (( get_status != 0 )); then
    printf 'agent_lost'
    return
  fi
  if printf '%s' "$combined" | grep -qi 'agent_prompt_stalled'; then
    printf 'stalled'
    return
  fi
  if (( prompt_status != 0 )) && printf '%s' "$combined" | grep -Eqi 'timed?[ -]?out|timeout'; then
    printf 'timeout'
    return
  fi
  state="$(_runtime_json_field "$get_output" agent_status)"
  case "$state" in
    idle|done) printf 'settled' ;;
    blocked) printf 'blocked' ;;
    *) printf 'error' ;;
  esac
}

_runtime_spec_section() {
  # init이 만드는 SPEC.md는 "## N. 제목" 형식의 고정 섹션 7개로 구성된다.
  # 번호(N)로 매칭해 그 섹션을 다음 "## " 헤더 전까지 그대로 출력한다.
  local file="$1" number="$2"
  awk -v n="$number" '
    $0 ~ "^## " n "\\." { printing=1 }
    printing && /^## / && $0 !~ "^## " n "\\." { exit }
    printing { print }
  ' "$file"
}

_runtime_context_packet() {
  local root="$1" task_id="$2" role="$3" task_file="$4" destination="$5"
  local temporary spec_file
  temporary="$(mktemp "$root/.harness/runtime/.context.XXXXXX")"
  trap "rm -f -- '$temporary'" RETURN
  spec_file="$root/.harness/SPEC.md"
  {
    printf '# Context Packet: %s / %s\n\n' "$task_id" "$role"
    printf '## Specification excerpt\n\n'
    if [[ -f "$spec_file" ]]; then
      # 줄 수로 자르지 않는다(200줄을 넘으면 Acceptance Criteria·제약이 통째로
      # 빠지던 결함 — BACKLOG.md #5). 실행에 필요한 절만 번호로 골라 전부 담는다.
      local section_number
      for section_number in 1 3 4 5 6; do
        _runtime_spec_section "$spec_file" "$section_number"
        printf '\n'
      done
    fi
    printf '\n## Task Contract\n\n'
    cat "$task_file"
    printf '\n## Write scope\n\n'
    _runtime_yaml_block "$task_file" write_scope
    printf '\n## References and inputs\n\n'
    _runtime_yaml_block "$task_file" resources
    _runtime_yaml_block "$task_file" inputs
    printf '\n## Verification commands and criteria\n\n'
    _runtime_yaml_block "$task_file" acceptance_criteria
    printf '\n## Next step\n\n'
    if [[ "$role" == worker ]]; then
      printf '이 Task만 수행하고 검증 결과와 Attempt 산출물을 남긴 뒤 submitted를 제안한다. 상태를 직접 전이하거나 completed로 만들지 않는다.\n'
    else
      printf 'Diff, Task Criteria와 Evidence를 읽기 전용으로 검토하고 Review 산출물에 판정과 근거를 기록한다. 소스와 Task 상태를 수정하지 않는다.\n'
    fi
  } >"$temporary"
  if _runtime_has_secret "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  _runtime_atomic_copy "$temporary" "$destination"
  rm -f -- "$temporary"
}

_runtime_start_agent_when_ready() {
  # 분할 직후 Pane은 Herdr가 "available shell"로 인정하기까지 수 초가 걸린다.
  # 측정 결과 4~7초. 그동안 agent start는 agent_pane_busy로 실패한다.
  # 이 대기는 Pane 준비 조건만 재확인하며, 실패한 Agent 턴을 재시도하지 않는다.
  local agent_name="$1" provider="$2" pane_id="$3" timeout="$4"
  local deadline_s="${5:-30}"
  local waited=0 output status
  while :; do
    set +e
    output="$(herdr agent start "$agent_name" --kind "$provider" --pane "$pane_id" --timeout "$timeout" 2>&1)"
    status=$?
    set -e
    if (( status == 0 )); then
      printf '%s' "$output"
      return 0
    fi
    if ! printf '%s' "$output" | grep -q 'agent_pane_busy'; then
      printf '%s' "$output"
      return "$status"
    fi
    if (( waited >= deadline_s * 2 )); then
      printf '%s' "$output"
      return "$status"
    fi
    sleep 0.5
    waited=$((waited + 1))
  done
}

cmd_dispatch() {
  local path="${1:-}" task_id="${2:-}" role="${3:-}" timeout=120000
  [[ -n "$path" && -n "$task_id" && -n "$role" ]] || die "사용법: dispatch PATH TASK_ID ROLE(worker|reviewer) [--timeout MS]"
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--timeout에는 양의 밀리초가 필요합니다."; timeout="$2"; shift 2 ;;
      *) die "알 수 없는 dispatch 옵션: $1" ;;
    esac
  done
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"

  local root task_file runtime_dir context provider attempt started_at baseline
  local pane_output pane_status pane_id agent_name start_output start_status
  local prompt_output prompt_status get_output get_status read_output read_status result
  local attempt_file evidence_file temporary
  root="$(project_root "$path")"
  task_file="$root/.harness/tasks/$task_id.yaml"
  [[ -f "$task_file" ]] || die "Task YAML을 찾을 수 없습니다: $task_file"
  command -v herdr >/dev/null 2>&1 || die "herdr 명령을 찾을 수 없습니다."
  [[ "${HERDR_ENV:-}" == 1 ]] || die "dispatch는 Herdr Pane 안에서 실행해야 합니다."
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Git 저장소가 아닙니다: $root"

  runtime_dir="$root/.harness/runtime"
  mkdir -p "$runtime_dir" "$root/.harness/attempts" "$root/.harness/evidence"
  context="$runtime_dir/$task_id-context-$role.md"
  if ! _runtime_context_packet "$root" "$task_id" "$role" "$task_file" "$context"; then
    _runtime_write_result "$root" "$task_id" "$role" error
    printf '경고: Context Packet에서 Secret 의심 패턴이 발견되어 저장하거나 전송하지 않았습니다.\n' >&2
    printf 'dispatch_result=error\n'
    return 1
  fi

  if [[ "$role" == worker ]]; then
    provider="$(_runtime_yaml_scalar "$task_file" primary_worker)"
  else
    provider="$(_runtime_yaml_scalar "$task_file" reviewer)"
  fi
  [[ "$provider" =~ ^(claude|codex|agy)$ ]] || die "Task의 Provider가 유효하지 않습니다: $provider"
  attempt="$(_runtime_next_attempt "$root" "$task_id")"
  started_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  baseline="$(git -C "$root" rev-parse HEAD 2>/dev/null || printf 'unborn')"
  local task_slug="${task_id,,}"
  agent_name="hh-${task_slug//[^a-z0-9_-]/-}-${role:0:1}-$attempt"
  agent_name="${agent_name:0:32}"
  [[ "$agent_name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die "생성된 Agent 이름이 유효하지 않습니다: $agent_name"

  set +e
  pane_output="$(herdr pane split --current --direction right --cwd "$root" --no-focus 2>&1)"
  pane_status=$?
  set -e
  if (( pane_status != 0 )); then
    _runtime_write_result "$root" "$task_id" "$role" error
    printf '%s\n' "$pane_output" >&2
    printf 'dispatch_result=error\n'
    return 1
  fi
  pane_id="$(_runtime_json_field "$pane_output" pane_id)"
  [[ -n "$pane_id" ]] || die "Herdr Pane ID를 추출하지 못했습니다."

  _runtime_write_meta "$root" "$task_id" "$role" "$agent_name" "$pane_id" "$provider" "$attempt"
  attempt_file="$root/.harness/attempts/$task_id-attempt-$attempt.md"
  temporary="$(mktemp "$root/.harness/attempts/.attempt.XXXXXX")"
  {
    printf '# Attempt %s: %s\n\n' "$attempt" "$task_id"
    printf -- '- Started: %s\n- Role: %s\n- Provider: %s\n- Pane ID: %s\n- Agent name: %s\n- Baseline commit: %s\n' "$started_at" "$role" "$provider" "$pane_id" "$agent_name" "$baseline"
  } >"$temporary"
  _runtime_atomic_copy "$temporary" "$attempt_file"
  rm -f -- "$temporary"

  set +e
  start_output="$(_runtime_start_agent_when_ready "$agent_name" "$provider" "$pane_id" "$timeout")"
  start_status=$?
  set -e
  if (( start_status != 0 )); then
    result=error
    get_output=""
    get_status=1
    prompt_output="$start_output"
    prompt_status="$start_status"
    read_output=""
    read_status=1
  else
    set +e
    prompt_output="$(herdr agent prompt "$agent_name" "$(cat "$context")" --wait --timeout "$timeout" 2>&1)"
    prompt_status=$?
    get_output="$(herdr agent get "$agent_name" 2>&1)"
    get_status=$?
    read_output="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 200 2>&1)"
    read_status=$?
    set -e
    result="$(_runtime_normalize_state "$get_status" "$get_output" "$prompt_status" "$prompt_output")"
  fi

  local quota_signal
  quota_signal="$(_runtime_scan_quota_signal "$prompt_output"$'\n'"$read_output" || true)"

  evidence_file="$root/.harness/evidence/$task_id-$role-attempt-$attempt.md"
  temporary="$(mktemp "$root/.harness/evidence/.capture.XXXXXX")"
  {
    printf '# Evidence: %s / %s / Attempt %s\n\n' "$task_id" "$role" "$attempt"
    printf -- '- Captured: %s\n- Dispatch result: %s\n- Prompt exit: %s\n- Agent get exit: %s\n- Agent read exit: %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$result" "$prompt_status" "$get_status" "$read_status"
    printf '## Git status --short\n\n'
    git -C "$root" status --short 2>&1 || true
    printf '\n## Git diff --stat\n\n'
    git -C "$root" diff --stat 2>&1 || true
    printf '\n## Agent state\n\n%s\n' "$get_output"
    printf '\n## Dispatch 명령 출력\n\n%s\n' "$prompt_output"
    printf '\n## Agent output\n\n%s\n' "$read_output"
    if [[ -n "$quota_signal" ]]; then
      printf '\n## 쿼터 신호(자동 감지 — 확정 아님)\n\n%s\n\n실패로 확정되지 않았으므로 이 신호만으로 Provider를 바꾸지 않는다. `herdr-harness quota-check`로 확인 후 판단한다.\n' "$quota_signal"
    fi
  } >"$temporary"
  if _runtime_has_secret "$temporary"; then
    : >"$temporary"
    printf '# Evidence withheld\n\n경고: Secret 의심 패턴이 발견되어 원문을 저장하지 않았습니다.\n' >"$temporary"
    printf '경고: Agent 출력에서 Secret 의심 패턴이 발견되어 Evidence 원문을 저장하지 않았습니다.\n' >&2
  fi
  _runtime_atomic_copy "$temporary" "$evidence_file"
  rm -f -- "$temporary"
  _runtime_write_result "$root" "$task_id" "$role" "$result"
  printf 'dispatch_result=%s\n' "$result"
  [[ "$result" == settled || "$result" == blocked ]]
}

cmd_observe() {
  local path="${1:-}" task_id="${2:-}" role="${3:-worker}"
  [[ -n "$path" && -n "$task_id" ]] || die "사용법: observe PATH TASK_ID [ROLE]"
  [[ $# -le 3 ]] || die "사용법: observe PATH TASK_ID [ROLE]"
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"
  local root meta agent_name pane_id attempt evidence addition get_output get_status read_output read_status result
  root="$(project_root "$path")"
  meta="$root/.harness/runtime/$task_id-$role.meta"
  [[ -f "$meta" ]] || die "Runtime 기록을 찾을 수 없습니다: $meta"
  agent_name="$(_runtime_meta_value "$meta" agent_name)"
  pane_id="$(_runtime_meta_value "$meta" pane_id)"
  attempt="$(_runtime_meta_value "$meta" attempt)"
  [[ -n "$agent_name" && -n "$pane_id" && "$attempt" =~ ^[0-9]+$ ]] || die "Runtime 기록이 손상되었습니다: $meta"
  set +e
  get_output="$(herdr agent get "$agent_name" 2>&1)"
  get_status=$?
  read_output="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 200 2>&1)"
  read_status=$?
  set -e
  result="$(_runtime_normalize_state "$get_status" "$get_output" 0 "")"
  local quota_signal
  quota_signal="$(_runtime_scan_quota_signal "$read_output" || true)"
  evidence="$root/.harness/evidence/$task_id-$role-attempt-$attempt.md"
  addition="$(mktemp "$root/.harness/evidence/.observe.XXXXXX")"
  {
    printf '\n## Observation %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Result: %s\n- Pane ID: %s\n- Agent get exit: %s\n- Agent read exit: %s\n\n' "$result" "$pane_id" "$get_status" "$read_status"
    printf '### Agent state\n\n%s\n\n### Agent output\n\n%s\n' "$get_output" "$read_output"
    if [[ -n "$quota_signal" ]]; then
      printf '\n### 쿼터 신호(자동 감지 — 확정 아님)\n\n%s\n' "$quota_signal"
    fi
  } >"$addition"
  _runtime_append_evidence "$evidence" "$addition"
  rm -f -- "$addition"
  _runtime_write_result "$root" "$task_id" "$role" "$result"
  printf 'observe_result=%s\n' "$result"
}

cmd_close_agent() {
  local path="${1:-}" task_id="${2:-}" role=worker force=0
  [[ -n "$path" && -n "$task_id" ]] || die "사용법: close-agent PATH TASK_ID [ROLE] [--force]"
  shift 2
  if [[ $# -gt 0 && "$1" != --force ]]; then role="$1"; shift; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in --force) force=1 ;; *) die "알 수 없는 close-agent 옵션: $1" ;; esac
    shift
  done
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
  _runtime_require_id "$task_id"
  local root meta agent_name pane_id get_output get_status state close_output close_status
  root="$(project_root "$path")"
  meta="$root/.harness/runtime/$task_id-$role.meta"
  [[ -f "$meta" ]] || die "Harness Runtime 기록이 없어 Pane 정리를 거부합니다: $meta"
  agent_name="$(_runtime_meta_value "$meta" agent_name)"
  pane_id="$(_runtime_meta_value "$meta" pane_id)"
  [[ -n "$agent_name" && -n "$pane_id" ]] || die "Runtime 기록이 손상되었습니다: $meta"
  set +e
  get_output="$(herdr agent get "$agent_name" 2>&1)"
  get_status=$?
  set -e
  if (( get_status == 0 )); then
    state="$(_runtime_json_field "$get_output" agent_status)"
    [[ "$state" != working || "$force" -eq 1 ]] || die "Agent가 working 상태입니다. --force 없이는 닫지 않습니다: $agent_name"
  fi
  set +e
  close_output="$(herdr pane close "$pane_id" 2>&1)"
  close_status=$?
  set -e
  if (( close_status != 0 )); then
    printf '%s\n' "$close_output" >&2
    die "Harness Pane 정리에 실패했습니다: $pane_id"
  fi
  _runtime_atomic_text "$root/.harness/runtime/$task_id-$role.closed" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  info "Agent Pane 정리 완료: $agent_name ($pane_id)"
}

_runtime_state_tasks() {
  local state_file="$1"
  awk -F'|' '
    /^\|/ && NF >= 6 {
      task=$2; status=$6
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", task)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
      if (task != "Task" && task !~ /^-+$/ && task != "") print task "\t" status
    }
  ' "$state_file"
}

cmd_quota_check() {
  # 능동 쿼터 확인. agy는 --print "/usage"로 바로 조회하지만 claude·codex는
  # 비대화형 조회 수단이 없어 이미 떠 있는 Agent Pane에 "/status"를 보내 읽는다
  # (그래서 claude·codex는 TASK_ID ROLE로 실행 중인 Agent를 지정해야 한다).
  # 자동으로 아무것도 바꾸지 않는다 — 결과를 evidence에 남기고 판단은 사람 몫이다.
  local path="${1:-}" task_id="" role="" provider="" root
  [[ -n "$path" ]] || die "사용법: quota-check PATH TASK_ID ROLE(worker|reviewer) | quota-check PATH --provider PROVIDER"
  shift
  if [[ "${1:-}" == --provider ]]; then
    [[ $# -ge 2 ]] || die "--provider 값이 필요합니다."
    provider="$2"
  else
    task_id="${1:-}"; role="${2:-}"
    [[ -n "$task_id" && -n "$role" ]] || die "사용법: quota-check PATH TASK_ID ROLE(worker|reviewer) | quota-check PATH --provider PROVIDER"
    [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer여야 합니다."
    _runtime_require_id "$task_id"
  fi
  root="$(project_root "$path")"

  if [[ -z "$provider" ]]; then
    local task_file
    task_file="$root/.harness/tasks/$task_id.yaml"
    [[ -f "$task_file" ]] || die "Task YAML을 찾을 수 없습니다: $task_file"
    if [[ "$role" == worker ]]; then
      provider="$(_runtime_yaml_scalar "$task_file" primary_worker)"
    else
      provider="$(_runtime_yaml_scalar "$task_file" reviewer)"
    fi
  fi
  [[ "$provider" =~ ^(claude|codex|agy)$ ]] || die "Provider가 유효하지 않습니다: $provider"

  # low_warning_threshold_pct는 quota-policy.yaml이 정본이다 — 여기 상수를
  # 못박지 않는다(설정과 코드가 따로 노는 함정을 피한다). 정책 파일이나 키가
  # 없으면 25로 물러난다.
  local low_threshold=25 policy_file
  policy_file="$root/.harness/policies/quota-policy.yaml"
  if [[ -f "$policy_file" ]]; then
    local configured
    configured="$(_runtime_yaml_scalar "$policy_file" low_warning_threshold_pct || true)"
    [[ "$configured" =~ ^[0-9]+$ ]] && low_threshold="$configured"
  fi

  local output status status_word=unknown detail min_pct evidence_file addition
  case "$provider" in
    agy)
      command -v agy >/dev/null 2>&1 || die "agy 명령을 찾을 수 없습니다."
      set +e
      output="$(agy --print "/usage" 2>&1)"
      status=$?
      set -e
      if (( status == 0 )); then
        # 탭 구분 표: <모델군> <지표명> <남은%> <초기화시각>. 세 번째 열의
        # 최솟값을 대표값으로 쓰되, 전체 표는 evidence에 그대로 남긴다.
        min_pct="$(printf '%s\n' "$output" | awk -F'\t' '
          NF>=3 { v=$3; gsub(/%/,"",v); v=v+0; if (seen==0 || v<min) { min=v; seen=1 } }
          END { if (seen==1) print min }
        ')"
        if [[ -n "$min_pct" ]]; then
          detail="최소 남은 한도 ${min_pct}%(임계값 ${low_threshold}%, agy --print /usage 전체 내역은 evidence 참고)"
          if (( min_pct < low_threshold )); then status_word=low; else status_word=ok; fi
        else
          detail="agy --print /usage 출력 형식을 해석하지 못했습니다(원문은 evidence 참고)"
        fi
      else
        detail="agy --print /usage 호출 실패(exit $status)"
      fi
      ;;
    claude|codex)
      [[ -n "$task_id" ]] || die "claude/codex 쿼터 확인은 실행 중인 Task Agent가 필요합니다: quota-check PATH TASK_ID ROLE"
      command -v herdr >/dev/null 2>&1 || die "herdr 명령을 찾을 수 없습니다."
      [[ "${HERDR_ENV:-}" == 1 ]] || die "quota-check(claude/codex)는 Herdr Pane 안에서 실행해야 합니다."
      local meta agent_name
      meta="$root/.harness/runtime/$task_id-$role.meta"
      [[ -f "$meta" ]] || die "Runtime 기록을 찾을 수 없습니다(먼저 dispatch로 Agent를 띄우세요): $meta"
      agent_name="$(_runtime_meta_value "$meta" agent_name)"
      [[ -n "$agent_name" ]] || die "Runtime 기록이 손상되었습니다: $meta"
      set +e
      herdr agent prompt "$agent_name" "/status" --wait --timeout 30000 >/dev/null 2>&1
      output="$(herdr agent read "$agent_name" --source recent-unwrapped --lines 80 2>&1)"
      status=$?
      set -e
      local scan
      scan="$(_runtime_scan_quota_signal "$output" || true)"
      if [[ -n "$scan" ]]; then
        detail="$scan"
        status_word=low
      else
        detail="/status 출력에서 알려진 경고 문구를 못 찾음 — 여유가 있거나 문구 형식이 다른 것일 수 있다(원문은 evidence 참고)"
      fi
      ;;
  esac

  if [[ -n "$task_id" ]]; then
    evidence_file="$root/.harness/evidence/$task_id-$role-quota.md"
  else
    evidence_file="$root/.harness/evidence/quota-$provider.md"
  fi
  mkdir -p "$root/.harness/evidence"
  addition="$(mktemp "$root/.harness/evidence/.quota.XXXXXX")"
  {
    printf '## 쿼터 확인 %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Provider: %s\n- 판정: %s\n- 근거: %s\n\n' "$provider" "$status_word" "$detail"
    printf '### 원문\n\n%s\n' "$output"
  } >"$addition"
  _runtime_append_evidence "$evidence_file" "$addition"
  rm -f -- "$addition"

  printf 'quota_check: provider=%s status=%s detail=%s\n' "$provider" "$status_word" "$detail"
}

_runtime_json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

cmd_status_live() {
  local path="${1:-.}" json=0
  if [[ "$path" == --json ]]; then json=1; path=.; shift; else shift || true; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in --json) json=1 ;; *) die "알 수 없는 status --live 옵션: $1" ;; esac
    shift
  done
  local root agent_list agent_status git_status records_file pending_file meta task role agent_name pane_id
  local task_path document_status herdr_status verdict matched_object approval first
  root="$(project_root "$path")"
  set +e
  agent_list="$(herdr agent list 2>&1)"
  agent_status=$?
  set -e
  git_status="$(git -C "$root" status --short 2>&1 || true)"
  mkdir -p "$root/.harness/runtime"
  records_file="$(mktemp "$root/.harness/runtime/.status-records.XXXXXX")"
  pending_file="$(mktemp "$root/.harness/runtime/.status-pending.XXXXXX")"
  trap "rm -f -- '$records_file' '$pending_file'" RETURN

  shopt -s nullglob
  for meta in "$root"/.harness/runtime/*.meta; do
    task="$(_runtime_meta_value "$meta" task_id)"
    role="$(_runtime_meta_value "$meta" role)"
    agent_name="$(_runtime_meta_value "$meta" agent_name)"
    pane_id="$(_runtime_meta_value "$meta" pane_id)"
    [[ -n "$task" && -n "$role" && -n "$agent_name" && -n "$pane_id" ]] || continue

    task_path="$root/.harness/tasks/$task.yaml"
    if [[ -f "$task_path" ]]; then
      document_status="$(yaml_scalar "$task_path" status)"
    else
      document_status=missing
    fi

    herdr_status=missing
    if (( agent_status == 0 )); then
      if command -v jq >/dev/null 2>&1; then
        herdr_status="$(printf '%s' "$agent_list" | jq -r --arg name "$agent_name" --arg pane "$pane_id" '.result.agents[]? | select(.name == $name and .pane_id == $pane) | .agent_status' 2>/dev/null | head -n 1 || true)"
      else
        matched_object="$(printf '%s' "$agent_list" | sed 's/},{/}\n{/g' | grep -F "\"name\":\"$agent_name\"" | grep -F "\"pane_id\":\"$pane_id\"" | head -n 1 || true)"
        [[ -z "$matched_object" ]] || herdr_status="$(_runtime_json_field "$matched_object" agent_status)"
      fi
      herdr_status="${herdr_status:-missing}"
    else
      herdr_status=unavailable
    fi

    if [[ "$document_status" == active && "$herdr_status" == missing ]]; then
      verdict=DRIFT
    elif [[ "$document_status" == active && "$herdr_status" == unavailable ]]; then
      verdict=DRIFT
    elif [[ "$document_status" != active && "$herdr_status" != missing && "$herdr_status" != unavailable ]]; then
      verdict=ORPHAN
    else
      verdict=OK
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$task" "$role" "$document_status" "$agent_name" "$pane_id" "$herdr_status" "$verdict" >>"$records_file"
  done

  while IFS= read -r task; do
    [[ -n "$task" ]] || continue
    task_path="$root/.harness/tasks/$task.yaml"
    document_status="$(yaml_scalar "$task_path" status)"
    if [[ "$document_status" == active ]] && ! awk -F'\t' -v task="$task" '$1 == task { found=1 } END { exit !found }' "$records_file"; then
      printf '%s\t-\t%s\t-\t-\tmissing\tDRIFT\n' "$task" "$document_status" >>"$records_file"
    fi
    if [[ "$document_status" == awaiting_approval ]]; then
      approval="$root/.harness/decisions/$task-approval.md"
      if [[ ! -f "$approval" ]] || ! grep -q '^승인:[[:space:]]*yes' "$approval"; then
        printf '%s\n' "$task" >>"$pending_file"
      fi
    fi
  done < <(task_ids "$root")
  shopt -u nullglob

  if (( json == 1 )); then
    printf '{"state":"%s","herdr_available":%s,"agents":[' \
      "$(_runtime_json_escape "$(cat "$root/.harness/STATE.md")")" "$([[ "$agent_status" -eq 0 ]] && printf true || printf false)"
    first=1
    while IFS=$'\t' read -r task role document_status agent_name pane_id herdr_status verdict; do
      (( first == 1 )) || printf ','
      first=0
      printf '{"task":"%s","role":"%s","document_status":"%s","agent":"%s","pane":"%s","herdr_status":"%s","verdict":"%s"}' \
        "$(_runtime_json_escape "$task")" "$(_runtime_json_escape "$role")" "$(_runtime_json_escape "$document_status")" \
        "$(_runtime_json_escape "$agent_name")" "$(_runtime_json_escape "$pane_id")" "$(_runtime_json_escape "$herdr_status")" "$(_runtime_json_escape "$verdict")"
    done <"$records_file"
    printf '],"git_status":"%s","pending_decisions":[' "$(_runtime_json_escape "$git_status")"
    first=1
    while IFS= read -r task; do
      [[ -n "$task" ]] || continue
      (( first == 1 )) || printf ','
      first=0
      printf '"%s"' "$(_runtime_json_escape "$task")"
    done <"$pending_file"
    printf ']}\n'
  else
    cat "$root/.harness/STATE.md"
    printf '\n## Live Herdr agents\n\n'
    printf '| Task | Role | 문서상태 | Agent | Pane | Herdr상태 | 판정 |\n'
    printf '|---|---|---|---|---|---|---|\n'
    if [[ -s "$records_file" ]]; then
      while IFS=$'\t' read -r task role document_status agent_name pane_id herdr_status verdict; do
        printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$task" "$role" "$document_status" "$agent_name" "$pane_id" "$herdr_status" "$verdict"
      done <"$records_file"
    else
      printf '| - | - | - | - | - | - | OK |\n'
    fi
    [[ "$agent_status" -eq 0 ]] || printf '\n경고: Herdr Agent 목록을 조회하지 못했습니다.\n'
    printf '\n## Git status --short\n\n%s\n' "${git_status:-clean}"
    printf '\n## 승인 대기 (계산됨)\n\n'
    if [[ -s "$pending_file" ]]; then
      while IFS= read -r task; do printf -- '- %s: completed 사용자 승인 필요\n' "$task"; done <"$pending_file"
    else
      printf -- '- 없음\n'
    fi
  fi
  rm -f -- "$records_file" "$pending_file"
}

cmd_doctor() {
  local failed=0 command_name
  for command_name in herdr git claude codex agy; do
    if command -v "$command_name" >/dev/null 2>&1; then
      printf '[OK]      %-8s %s\n' "$command_name" "$(command -v "$command_name")"
    else
      printf '[MISSING] %-8s\n' "$command_name"
      [[ "$command_name" == herdr || "$command_name" == git ]] && failed=1
    fi
  done
  if command -v herdr >/dev/null 2>&1; then
    printf '\nHerdr version:\n'
    herdr --version || true
    printf '\nHerdr integrations:\n'
    herdr integration status || true
  fi
  return "$failed"
}

project_root() {
  local path="${1:-.}"
  path="$(realpath -m "$path")"
  [[ -f "$path/.harness/project.yaml" ]] || die "Harness 프로젝트가 아닙니다: $path"
  printf '%s\n' "$path"
}

cmd_status() {
  local live=0 json=0 root_arg="."
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --live) live=1; shift ;;
      --json) json=1; shift ;;
      -h|--help) printf '사용법: %s status [PATH] [--live] [--json]\n' "$SCRIPT_NAME"; return 0 ;;
      -*) die "알 수 없는 status 옵션: $1" ;;
      *) root_arg="$1"; shift ;;
    esac
  done
  local root
  root="$(project_root "$root_arg")"
  if [[ "$live" -eq 1 ]]; then
    if [[ "$json" -eq 1 ]]; then
      cmd_status_live "$root" --json
    else
      cmd_status_live "$root"
    fi
    return $?
  fi
  cat "$root/.harness/STATE.md"
}

cmd_start() {
  local root name orchestrator
  root="$(project_root "${1:-.}")"
  command -v herdr >/dev/null 2>&1 || die "herdr 명령을 찾을 수 없습니다. herdr-harness doctor를 실행하세요."
  name="$(awk -F': ' '/^  name:/{gsub(/[\047\042]/,"",$2); print $2; exit}' "$root/.harness/project.yaml")"
  orchestrator="$(awk -F': ' '/^  orchestrator:/{gsub(/[\047\042]/,"",$2); print $2; exit}' "$root/.harness/project.yaml")"
  printf 'Herdr Session: %s\n' "$name"
  printf '첫 Pane에서 %s를 실행한 뒤 HARNESS_START.md의 Prompt를 입력하세요.\n\n' "$orchestrator"
  cd "$root"
  exec herdr --session "$name"
}

cmd_test() {
  bash -n "$SELF_PATH"
  local test_root test_project failure_status
  test_root="$(mktemp -d "${TMPDIR:-/tmp}/herdr-harness-test.XXXXXX")"
  test_project="$test_root/sample-project"
  trap 'case "${test_root:-}" in "${TMPDIR:-/tmp}"/herdr-harness-test.*) rm -rf -- "$test_root" ;; esac' EXIT

  bash "$SELF_PATH" init "$test_project" \
    --name sample-project \
    --goal "SNMP Dump 정규화 테스트" \
    --profile network-device \
    --orchestrator claude \
    --worker codex \
    --reviewer agy \
    --fallback claude,agy >/dev/null

  local required=(
    AGENTS.md CLAUDE.md GEMINI.md HARNESS_START.md
    .harness/project.yaml .harness/SPEC.md .harness/MILESTONES.md .harness/STATE.md
    .harness/tasks/TEMPLATE.yaml .harness/references/inventory.md
    .harness/waves/TEMPLATE.yaml .harness/attempts/TEMPLATE.md
    .harness/reviews/TEMPLATE.md .harness/handovers/TEMPLATE.md
    .harness/decisions/TEMPLATE.md
    .agents/roles/orchestrator.agent.md .agents/roles/worker.agent.md .agents/roles/reviewer.agent.md
    .agents/roles/interviewer.agent.md .agents/roles/planner.agent.md .agents/roles/advisor.agent.md
    .agents/skills/harness-interview/SKILL.md .agents/skills/harness-reference/SKILL.md
    .agents/skills/harness-plan/SKILL.md
    .agents/skills/harness-orchestrate/SKILL.md .agents/skills/harness-work/SKILL.md
    .agents/skills/harness-verify/SKILL.md
    .agents/skills/harness-review/SKILL.md .agents/skills/harness-handover/SKILL.md
    .agents/skills/harness-status/SKILL.md
  )
  local item
  for item in "${required[@]}"; do
    [[ -f "$test_project/$item" ]] || die "자체 테스트 누락 파일: $item"
  done

  for item in "$test_project"/.claude/skills/*/SKILL.md; do
    [[ -f "$item" ]] || die "Claude Skill 연결 실패: $item"
  done

  if grep -rq '@@[A-Z_]*@@' "$test_project" 2>/dev/null; then
    die "치환되지 않은 플레이스홀더가 남아 있습니다."
  fi

  git -C "$test_project" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "init이 Git 저장소를 만들지 않았습니다."
  git -C "$test_project" -c user.name=harness-test -c user.email=test@example.invalid \
    commit -q -m "chore: harness 기준선" >/dev/null 2>&1 || true
  git -C "$test_project" rev-parse HEAD >/dev/null 2>&1 ||
    die "기준 commit을 만들지 못했습니다."

  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "$test_project" <<'HARNESS_YAML_CHECK'
from pathlib import Path
import sys, yaml
root = Path(sys.argv[1])
for path in root.rglob('*.yaml'):
    yaml.safe_load(path.read_text())
HARNESS_YAML_CHECK
  else
    info "PyYAML이 없어 YAML 파싱 테스트는 건너뜁니다."
  fi

  set +e
  bash "$SELF_PATH" init "$test_project" --name duplicate --goal duplicate >/dev/null 2>&1
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || die "비어 있지 않은 디렉터리 거부 테스트 실패"

  set +e
  local goal_message
  goal_message="$(bash "$SELF_PATH" init "$test_root/no-goal" </dev/null 2>&1)"
  failure_status=$?
  set -e
  [[ "$failure_status" -ne 0 ]] || die "비대화형 --goal 누락 거부 테스트 실패"
  printf '%s' "$goal_message" | grep -q '비대화형' ||
    die "비대화형 실패에 설명 메시지가 없습니다."

  local task="$test_project/.harness/tasks/task-001.yaml"
  sed -e 's/^task_id: .*/task_id: task-001/' \
      -e 's/^milestone_id: .*/milestone_id: milestone-001/' \
      "$test_project/.harness/tasks/TEMPLATE.yaml" >"$task"

  expect_fail() {
    local label="$1"; shift
    set +e
    "$@" >/dev/null 2>&1
    local status=$?
    set -e
    [[ "$status" -ne 0 ]] || die "거부되어야 할 동작이 허용됐습니다: $label"
  }
  expect_pass() {
    local label="$1"; shift
    "$@" >/dev/null || die "허용되어야 할 동작이 거부됐습니다: $label"
  }

  expect_fail "draft->active (전이표 위반)" \
    bash "$SELF_PATH" transition "$test_project" task-001 active
  expect_fail "draft->ready (SPEC 미승인)" \
    bash "$SELF_PATH" transition "$test_project" task-001 ready

  sed -i 's/^- 상태: draft$/- 상태: approved/' "$test_project/.harness/SPEC.md"
  expect_pass "draft->ready" \
    bash "$SELF_PATH" transition "$test_project" task-001 ready
  expect_pass "ready->active" \
    bash "$SELF_PATH" transition "$test_project" task-001 active

  expect_fail "active->submitted (Attempt/Evidence 없음)" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted
  printf '# attempt\n' >"$test_project/.harness/attempts/task-001-attempt-1.md"
  expect_fail "active->submitted (Evidence 없음)" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted
  printf '# evidence\n' >"$test_project/.harness/evidence/task-001-worker-attempt-1.md"
  expect_pass "active->submitted" \
    bash "$SELF_PATH" transition "$test_project" task-001 submitted

  expect_pass "submitted->reviewing" \
    bash "$SELF_PATH" transition "$test_project" task-001 reviewing
  expect_fail "reviewing->awaiting_approval (APPROVED Review 없음)" \
    bash "$SELF_PATH" transition "$test_project" task-001 awaiting_approval
  printf '판정: CHANGES_REQUESTED\n' >"$test_project/.harness/reviews/task-001-review-1.md"
  expect_fail "reviewing->awaiting_approval (판정 불일치)" \
    bash "$SELF_PATH" transition "$test_project" task-001 awaiting_approval
  printf '판정: APPROVED\n' >"$test_project/.harness/reviews/task-001-review-2.md"
  # 과거 APPROVED가 남아 있어도 최신 Review가 반려면 통과하면 안 된다
  printf '판정: CHANGES_REQUESTED\n' >"$test_project/.harness/reviews/task-001-review-3.md"
  touch -d '+1 minute' "$test_project/.harness/reviews/task-001-review-3.md"
  expect_fail "최신 Review가 반려인데 과거 APPROVED로 우회" \
    bash "$SELF_PATH" transition "$test_project" task-001 awaiting_approval
  rm -f "$test_project/.harness/reviews/task-001-review-3.md"
  touch "$test_project/.harness/reviews/task-001-review-2.md"
  expect_pass "reviewing->awaiting_approval" \
    bash "$SELF_PATH" transition "$test_project" task-001 awaiting_approval

  expect_fail "awaiting_approval->completed (사용자 승인 기록 없음)" \
    bash "$SELF_PATH" transition "$test_project" task-001 completed
  printf 'Task: task-001\n승인: no\n' >"$test_project/.harness/decisions/task-001-approval.md"
  expect_fail "awaiting_approval->completed (승인: no)" \
    bash "$SELF_PATH" transition "$test_project" task-001 completed
  printf 'Task: task-001\n승인: yes\n' >"$test_project/.harness/decisions/task-001-approval.md"
  expect_pass "awaiting_approval->completed" \
    bash "$SELF_PATH" transition "$test_project" task-001 completed

  expect_fail "동일 상태 재전이" \
    bash "$SELF_PATH" transition "$test_project" task-001 completed

  local events="$test_project/.harness/evidence/events.tsv"
  [[ -f "$events" ]] || die "이벤트 로그가 없습니다: $events"
  [[ "$(grep -c '^' "$events")" -ge 7 ]] || die "이벤트 로그 기록이 부족합니다."

  bash "$SELF_PATH" validate "$test_project" >/dev/null ||
    die "정상 프로젝트에서 validate가 실패했습니다."

  sed -i "s/^reviewer: .*/reviewer: 'codex'/" "$task"
  expect_fail "validate가 Worker==Reviewer를 통과시킴" \
    bash "$SELF_PATH" validate "$test_project"
  sed -i "s/^reviewer: .*/reviewer: 'agy'/" "$task"

  local no_git="$test_root/no-git-project"
  cp -r "$test_project" "$no_git"
  rm -rf "$no_git/.git"
  expect_fail "validate가 Git 기준선 누락을 통과시킴" \
    bash "$SELF_PATH" validate "$no_git"

  expect_fail "dispatch 잘못된 ROLE" \
    bash "$SELF_PATH" dispatch "$test_project" task-001 architect
  expect_fail "observe 인자 부족" \
    bash "$SELF_PATH" observe "$test_project"
  expect_fail "close-agent 기록 없는 Task" \
    bash "$SELF_PATH" close-agent "$test_project" task-999

  rm -rf -- "$test_root"
  trap - EXIT

  printf 'PASS: Bash 문법\n'
  printf 'PASS: Harness 파일 생성 (20종 템플릿)\n'
  printf 'PASS: 공통 Skill과 Claude 연결\n'
  printf 'PASS: 플레이스홀더 치환\n'
  printf 'PASS: Git 기준선 생성\n'
  printf 'PASS: 신규 프로젝트 보호\n'
  printf 'PASS: 비대화형 명시적 실패\n'
  printf 'PASS: 상태 전이표 강제 (14개 케이스)\n'
  printf 'PASS: 이벤트 로그 기록\n'
  printf 'PASS: validate 검증 (정상/Worker=Reviewer/Git 누락)\n'
  printf 'PASS: 스텝 명령 인자 검증\n'
  printf 'PASS: Agent 호출 없음\n'
}

cmd_uninstall() {
  local assume_yes=0 answer=""
  local install_dir="${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-harness"
  local installed_file="$install_dir/harness.sh"
  local command_path="$HOME/.local/bin/herdr-harness"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) assume_yes=1 ;;
      -h|--help)
        cat <<'EOF'
사용법:
  herdr-harness uninstall
  herdr-harness uninstall --yes

제거 대상:
  ~/.local/bin/herdr-harness
  ~/.local/share/herdr-agent-harness/harness.sh

생성한 프로젝트, Herdr 본체, Integration과 전역 Herdr Skill은 제거하지 않습니다.
EOF
        return 0
        ;;
      *) die "알 수 없는 uninstall 옵션: $1" ;;
    esac
    shift
  done

  if [[ ! -e "$installed_file" && ! -L "$command_path" ]]; then
    info "설치된 Harness를 찾지 못했습니다."
    return 0
  fi

  if [[ "$assume_yes" -ne 1 ]]; then
    if [[ ! -t 0 ]]; then
      die "비대화형 실행에서는 uninstall --yes를 사용하세요."
    fi
    printf '설치된 herdr-harness 명령을 제거할까요? [y/N] '
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) info "제거를 취소했습니다."; return 0 ;; esac
  fi

  if [[ -L "$command_path" ]]; then
    if [[ "$(readlink "$command_path")" == "$installed_file" ]]; then
      unlink "$command_path"
    else
      die "예상하지 않은 Symbolic Link라 제거하지 않습니다: $command_path"
    fi
  elif [[ -e "$command_path" ]]; then
    die "일반 파일이 존재해 제거하지 않습니다: $command_path"
  fi

  if [[ -f "$installed_file" ]]; then
    unlink "$installed_file"
  fi
  rmdir "$install_dir" 2>/dev/null || true

  printf 'Harness 제거 완료.\n'
  printf '생성한 프로젝트와 Herdr 설정은 유지됩니다.\n'
}

main() {
  local command="${1:-help}"
  [[ $# -eq 0 ]] || shift
  case "$command" in
    init) cmd_init "$@" ;;
    start) cmd_start "$@" ;;
    status) cmd_status "$@" ;;
    validate) cmd_validate "$@" ;;
    transition) cmd_transition "$@" ;;
    dispatch) cmd_dispatch "$@" ;;
    observe) cmd_observe "$@" ;;
    close-agent) cmd_close_agent "$@" ;;
    quota-check) cmd_quota_check "$@" ;;
    doctor) cmd_doctor "$@" ;;
    test) cmd_test "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    help|-h|--help) usage ;;
    *) die "알 수 없는 명령: $command" ;;
  esac
}

main "$@"

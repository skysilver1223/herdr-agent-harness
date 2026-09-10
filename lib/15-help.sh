# Part of herdr-harness. Sourced by harness.sh — do not run directly.

# ---------------------------------------------------------------------------
# 명령별 상세 도움말
#
# usage()는 "무엇이 있는지"만 한 줄로 보여 준다. 여기 있는 topic은 "어떻게
# 쓰는지"를 목적·구문·예시·주의로 나눠 설명한다. 탭 완성에 붙는 한 줄 설명도
# 같은 표(HARNESS_COMMAND_SUMMARIES)에서 나오므로 설명이 갈라지지 않는다.
#
# 새 명령을 추가하면 (1) 99-main.sh의 case, (2) 이 표, (3) cmd_help_topic의
# 분기, (4) 85-completion.sh의 목록 네 곳을 함께 갱신해야 한다 — 빠뜨리면
# cmd_test가 잡는다.
# ---------------------------------------------------------------------------

HARNESS_COMMAND_SUMMARIES=(
  "init:새 프로젝트에 Harness 문서·정책·역할 파일을 생성한다"
  "sync-templates:기존 프로젝트의 Skill·역할 파일을 지금 버전 템플릿으로 재동기화한다"
  "start:프로젝트 디렉터리에서 Herdr Session을 연다"
  "status:STATE.md를 출력한다 (--live로 문서·Herdr·Git 대조)"
  "validate:상태를 바꾸지 않고 문서·정책·Git 정합성만 검사한다"
  "transition:Task 상태를 전이표와 게이트에 따라 강제 전이한다"
  "approve:사용자 승인을 기록하고 awaiting_approval을 completed로 만든다"
  "dispatch:Task와 역할에 맞는 Agent를 Pane에서 한 턴 실행한다"
  "observe:이미 실행 중인 Agent의 출력을 다시 읽어 Evidence를 갱신한다"
  "close-agent:Harness가 만든 Agent Pane을 정리한다"
  "quota-check:실행 중인 Agent의 남은 쿼터를 확인한다"
  "quota-retry:연속 저쿼터 확인 시 Provider 교체를 handover_required까지 처리한다 (opt-in)"
  "auto-step:유한 턴 동안 dispatch 1회 + observe 반복을 돌린다 (opt-in)"
  "remote:원격 서버에서 빌드·테스트·VCS를 실행하는 원격 모드 (opt-in)"
  "doctor:herdr·git·Agent CLI 등 설치 상태를 확인한다"
  "test:Agent 쿼터를 쓰지 않는 자체 테스트를 실행한다"
  "completion:Bash 탭 완성 스크립트를 출력한다"
  "uninstall:설치된 Harness 명령과 파일을 제거한다"
  "help:명령 목록 또는 특정 명령의 상세 사용법을 보여 준다"
)

harness_command_names() {
  local entry
  for entry in "${HARNESS_COMMAND_SUMMARIES[@]}"; do
    printf '%s\n' "${entry%%:*}"
  done
}

harness_command_summary() {
  local name="$1" entry
  for entry in "${HARNESS_COMMAND_SUMMARIES[@]}"; do
    [[ "${entry%%:*}" == "$name" ]] || continue
    printf '%s\n' "${entry#*:}"
    return 0
  done
  return 1
}

cmd_help() {
  local topic="${1:-}"
  if [[ -z "$topic" ]]; then
    usage
    printf '\n특정 명령의 상세 사용법과 예시:\n  %s help <명령>   (예: %s help dispatch)\n' \
      "$SCRIPT_NAME" "$SCRIPT_NAME"
    printf '\n완료 승인 기록:\n  %s approve PATH TASK_ID --confirm-user-approval\n' "$SCRIPT_NAME"
    return 0
  fi
  harness_command_summary "$topic" >/dev/null ||
    die "그런 명령이 없습니다: $topic  (목록: $SCRIPT_NAME help)"
  printf '%s — %s\n\n' "$topic" "$(harness_command_summary "$topic")"
  cmd_help_topic "$topic"
}

cmd_help_topic() {
  case "$1" in
    init) cat <<EOF
구문:
  $SCRIPT_NAME init PATH [--name NAME] [--goal TEXT] [--profile PROFILE]
                    [--orchestrator P] [--worker P] [--reviewer P] [--fallback P,P]
                    [--remote-host H] [--remote-user U] [--remote-path /경로]
                    [--remote-mount /경로] [--remote-vcs git|svn|none]

무엇을 하나:
  비어 있는 디렉터리에 AGENTS.md·SPEC.md·STATE.md·정책·역할·Skill 파일과 Git
  기준선을 만든다. 기존 디렉터리가 비어 있지 않으면 거부한다.

예시:
  $SCRIPT_NAME init ~/Projects/snmp-normalizer \\
    --name snmp-normalizer --goal "멀티벤더 SNMP 데이터를 공통 스키마로 정규화" \\
    --profile network-device

  # 원격 서버에서 빌드·테스트하는 프로젝트
  $SCRIPT_NAME init ~/Projects/telemetry \\
    --name telemetry --goal "정규화 모듈 개선" \\
    --remote-host 192.168.2.77 --remote-user nsotdb \\
    --remote-path /home/nsotdb/Normalize_Telemetry --remote-vcs svn

다음 단계:
  cd PATH && $SCRIPT_NAME start .
EOF
      ;;
    sync-templates) cat <<EOF
구문:
  $SCRIPT_NAME sync-templates PATH [--apply]

무엇을 하나:
  Harness가 소유한 Skill·역할·템플릿 파일만 지금 버전으로 맞춘다. 기본은
  diff 미리보기이며 --apply를 줘야 실제로 쓴다. SPEC.md·STATE.md·Task 파일
  같은 프로젝트 산출물은 건드리지 않는다.

예시:
  $SCRIPT_NAME sync-templates ~/Projects/telemetry          # 무엇이 바뀔지만 확인
  $SCRIPT_NAME sync-templates ~/Projects/telemetry --apply  # 실제 적용
EOF
      ;;
    start) cat <<EOF
구문:
  $SCRIPT_NAME start [PATH]

무엇을 하나:
  프로젝트 이름으로 Herdr Session을 열고 그 디렉터리로 이동한다. 첫 Pane에서
  Orchestrator Provider를 실행한 뒤 HARNESS_START.md의 Prompt를 붙여 넣는다.

예시:
  $SCRIPT_NAME start ~/Projects/telemetry
EOF
      ;;
    status) cat <<EOF
구문:
  $SCRIPT_NAME status [PATH] [--live] [--json]

무엇을 하나:
  기본은 STATE.md를 그대로 출력한다. --live는 문서 상태와 실제 Herdr Pane·Git
  상태를 대조해 어긋난 항목을 DRIFT로 표시한다.

예시:
  $SCRIPT_NAME status .
  $SCRIPT_NAME status . --live
  $SCRIPT_NAME status . --live --json | jq .
EOF
      ;;
    validate) cat <<EOF
구문:
  $SCRIPT_NAME validate [PATH] [--wave ID] [--no-git]

무엇을 하나:
  아무것도 바꾸지 않고 검사만 한다 — Task YAML 스키마, Worker/Reviewer 중복,
  write_scope 충돌, Git 상태. Wave를 시작하기 전이나 dispatch 전에 쓴다.

예시:
  $SCRIPT_NAME validate .
  $SCRIPT_NAME validate . --wave wave-001
EOF
      ;;
    transition) cat <<EOF
구문:
  $SCRIPT_NAME transition PATH TASK_ID TO_STATE [--note TEXT]

무엇을 하나:
  전이표에 있는 경로만 허용하고, 상태마다 요구하는 증거를 확인한 뒤 Task
  YAML과 STATE.md를 갱신한다. 예를 들어 submitted는 Attempt·Evidence가,
  awaiting_approval은 최신 Review의 APPROVED 판정이 있어야 한다.

상태:
  draft ready active submitted blocked handover_required
  reviewing changes_requested awaiting_approval completed

예시:
  $SCRIPT_NAME transition . task-001 ready
  $SCRIPT_NAME transition . task-001 blocked --note "샘플 Dump 필요"
EOF
      ;;
    approve) cat <<EOF
구문:
  $SCRIPT_NAME approve PATH TASK_ID --confirm-user-approval

무엇을 하나:
  사용자 승인 기록(.harness/decisions/TASK_ID-approval.md)을 만들고
  awaiting_approval → completed 전이를 실행한다. --confirm-user-approval이
  없으면 거부한다 — Agent가 스스로 완료를 선언하지 못하게 하는 장치다.

예시:
  $SCRIPT_NAME approve . task-001 --confirm-user-approval
EOF
      ;;
    dispatch) cat <<EOF
구문:
  $SCRIPT_NAME dispatch PATH TASK_ID ROLE [--timeout MS]

무엇을 하나:
  Task 계약·SPEC 발췌·intent를 Context Packet으로 묶어 Herdr Pane에서 Agent를
  한 턴 실행하고, 결과를 Evidence로 남긴다. 호출 1회 = 1턴이며 상주 루프가 아니다.

역할(ROLE): worker | reviewer

예시:
  $SCRIPT_NAME dispatch . task-001 worker
  $SCRIPT_NAME dispatch . task-001 reviewer --timeout 600000
EOF
      ;;
    observe) cat <<EOF
구문:
  $SCRIPT_NAME observe PATH TASK_ID [ROLE]

무엇을 하나:
  dispatch로 이미 띄운 Agent의 Pane을 다시 읽어 현재 상태와 출력을 Evidence에
  갱신한다. 새 Agent를 만들지 않는다.

예시:
  $SCRIPT_NAME observe . task-001
  $SCRIPT_NAME observe . task-001 reviewer
EOF
      ;;
    close-agent) cat <<EOF
구문:
  $SCRIPT_NAME close-agent PATH TASK_ID [ROLE] [--force]

무엇을 하나:
  Harness가 만든 Pane만 정리한다. 사용자가 직접 만든 Pane은 건드리지 않는다.

예시:
  $SCRIPT_NAME close-agent . task-001 worker
EOF
      ;;
    quota-check) cat <<EOF
구문:
  $SCRIPT_NAME quota-check PATH TASK_ID ROLE
  $SCRIPT_NAME quota-check PATH --provider claude|codex|agy

무엇을 하나:
  실행 중인 Agent에 상태를 물어 남은 쿼터를 읽고 결과를 기록한다(claude·codex는
  /status, agy는 --print). 확인만 하며 Provider를 자동으로 바꾸지 않는다.

예시:
  $SCRIPT_NAME quota-check . task-001 worker
  $SCRIPT_NAME quota-check . --provider agy
EOF
      ;;
    quota-retry) cat <<EOF
구문:
  $SCRIPT_NAME quota-retry PATH TASK_ID ROLE

무엇을 하나 (opt-in):
  .harness/policies/quota-policy.yaml의 automatic_failover: true일 때만 동작한다.
  연속 low 판정이 기준을 넘으면 Pane을 정리하고 Provider를 fallback_chain의 다음
  값으로 바꾼 뒤 handover stub을 만들고 handover_required까지 전이하고 멈춘다.
  재개(ready 전이)는 사람이 승인 기록을 쓴 뒤 직접 해야 한다.

예시:
  $SCRIPT_NAME quota-retry . task-001 worker
EOF
      ;;
    auto-step) cat <<EOF
구문:
  $SCRIPT_NAME auto-step PATH TASK_ID [--max-turns N]

무엇을 하나 (opt-in):
  .harness/policies/loop-policy.yaml의 enabled: true일 때만 동작한다. 1턴째만
  dispatch하고 이후에는 observe만 반복하며, settled·blocked·오류에서 즉시 멈춘다.
  --max-turns는 정책의 max_turns_ceiling을 넘을 수 없고, 호출 1회는 반드시 끝난다.

예시:
  $SCRIPT_NAME auto-step . task-001 --max-turns 3
EOF
      ;;
    remote) cat <<EOF
구문:
  $SCRIPT_NAME remote [PATH] <하위 명령> [인수...]

무엇을 하나 (opt-in):
  소스와 빌드 환경이 원격 서버에만 있을 때 쓴다. Agent는 그대로 로컬에서 돌고,
  소스는 SSHFS로 로컬에 노출되며 빌드·테스트·VCS만 SSH로 원격에서 실행된다.
  .harness/policies/remote.yaml의 enabled: true일 때만 동작한다.

처음 한 번:
  $SCRIPT_NAME remote . setup
      호스트·계정·경로를 묻고 remote.yaml을 만든 뒤, 비밀번호를 한 번만 입력받아
      SSH 키를 등록한다. 이후로는 비밀번호를 다시 묻지 않는다.

그다음:
  $SCRIPT_NAME remote . doctor                     연결·경로·도구·마운트 진단
  $SCRIPT_NAME remote . mount                      원격 소스를 로컬 경로에 붙임
  $SCRIPT_NAME remote . run 'make -j4 && ctest'    빌드·테스트를 원격에서 실행
  $SCRIPT_NAME remote . vcs status                 git/svn을 원격에서 실행
  $SCRIPT_NAME remote . status                     설정·연결·마운트 요약
  $SCRIPT_NAME remote . unmount

하위 명령 전체 목록: $SCRIPT_NAME remote help
EOF
      ;;
    doctor) cat <<EOF
구문:
  $SCRIPT_NAME doctor

무엇을 하나:
  herdr·git·claude·codex·agy가 PATH에 있는지 확인한다. herdr·git이 없으면
  실패로 끝난다. ssh·sshfs·sshpass는 원격 모드에서만 필요해 [OPTION]으로만 표시한다.
  프로젝트별 원격 연결 진단은 $SCRIPT_NAME remote PATH doctor 쪽이다.
EOF
      ;;
    test) cat <<EOF
구문:
  $SCRIPT_NAME test

무엇을 하나:
  임시 디렉터리에 프로젝트를 만들어 문법·파일 생성·상태 전이 게이트·잠금·
  원격 모드 게이트 등을 검사한다. Agent를 호출하지 않으므로 쿼터를 쓰지 않는다.
EOF
      ;;
    completion) cat <<EOF
구문:
  $SCRIPT_NAME completion bash

무엇을 하나:
  Bash 탭 완성 스크립트를 출력한다. install.sh가 ~/.bashrc에 로더를 자동
  등록하므로 보통 직접 쓸 일은 없다.

수동 설치:
  source <($SCRIPT_NAME completion bash)
EOF
      ;;
    uninstall) cat <<EOF
구문:
  $SCRIPT_NAME uninstall [--yes]

무엇을 하나:
  설치된 명령·라이브러리·템플릿과 ~/.bashrc의 완성 로더 블록을 제거한다.
  프로젝트 디렉터리는 건드리지 않는다.
EOF
      ;;
    help) cat <<EOF
구문:
  $SCRIPT_NAME help [명령]

예시:
  $SCRIPT_NAME help              전체 명령 목록
  $SCRIPT_NAME help remote       원격 모드 사용법과 예시
  $SCRIPT_NAME help transition   상태 전이 규칙과 예시
EOF
      ;;
    *) die "그런 명령이 없습니다: $1" ;;
  esac
}

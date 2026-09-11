# Part of herdr-harness. Sourced by harness.sh — do not run directly.


cmd_completion() {
  local shell="${1:-}"
  [[ "$shell" == bash ]] || die "사용법: completion bash  (지원 Shell은 현재 bash뿐입니다)"
  cat <<'HARNESS_BASH_COMPLETION'
# herdr-harness bash completion
# 설치: ~/.bashrc에 다음 한 줄을 추가하세요.
#   source <(herdr-harness completion bash)

_herdr_harness_task_ids() {
  local root="$1" cur="$2" dir f base ids=()
  dir="$root/.harness/tasks"
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.yaml; do
    [[ -f "$f" ]] || continue
    base="${f##*/}"; base="${base%.yaml}"
    [[ "$base" == TEMPLATE ]] && continue
    ids+=("$base")
  done
  COMPREPLY+=($(compgen -W "${ids[*]}" -- "$cur"))
}

# 화면에서 차지하는 칸 수를 센다. 한글·CJK는 1글자가 2칸이라 ${#s}(글자 수)와
# 다르다. printf '%d' "'문자" 가 코드 포인트를 주므로, 그것을 wcwidth와 같은
# 기준(East Asian Wide/Fullwidth 구간)으로 분류한다. '—'·'·'·'→' 같은 기호는
# 3바이트여도 1칸이라 "바이트 수로 추정"하면 어긋난다.
#
# 한계: 완전한 wcwidth 구현이 아니다. 결합 문자와 ZWJ(U+200D)는 0으로 세지만
# ZWJ로 이어 붙인 이모지(👩‍💻)는 여전히 실제보다 넓게 계산된다. 설명 문자열은
# 우리가 쓰는 것이고 거기에 그런 문자를 넣지 않으므로 실제 배치는 어긋나지
# 않는다 — 사용자 입력을 여기에 넣게 되면 그때 wcwidth를 제대로 구현해야 한다.
_herdr_harness_display_width() {
  local text="$1" i ch code width=0
  for (( i = 0; i < ${#text}; i++ )); do
    ch="${text:i:1}"
    printf -v code '%d' "'$ch"
    # 결합 문자(악센트, 이체자 선택자, 결합용 반쪽 문자)는 앞 글자에 겹쳐
    # 찍히므로 폭이 0이다. 1로 세면 그만큼 덜 채워져 배치가 어긋난다.
    if (( (code >= 768   && code <= 879)    ||
          (code >= 1155  && code <= 1161)   ||
          (code >= 6832  && code <= 6911)   ||
          (code >= 7616  && code <= 7679)   ||
          (code >= 8203  && code <= 8207)   ||
          (code >= 8400  && code <= 8447)   ||
          (code >= 65024 && code <= 65039)  ||
          (code >= 65056 && code <= 65071) )); then
      continue
    fi
    if (( (code >= 4352  && code <= 4447)   ||
          (code >= 8986  && code <= 8987)   ||
          (code >= 9001  && code <= 9002)   ||
          (code >= 9193  && code <= 9203)   ||
          (code >= 9725  && code <= 9726)   ||
          (code >= 9748  && code <= 9749)   ||
          (code >= 9800  && code <= 9811)   ||
          (code >= 9855  && code <= 9855)   ||
          (code >= 9875  && code <= 9875)   ||
          (code >= 9889  && code <= 9889)   ||
          (code >= 9898  && code <= 9899)   ||
          (code >= 9917  && code <= 9918)   ||
          (code >= 9924  && code <= 9925)   ||
          (code >= 9934  && code <= 9934)   ||
          (code >= 9940  && code <= 9940)   ||
          (code >= 9962  && code <= 9962)   ||
          (code >= 9970  && code <= 9971)   ||
          (code >= 9973  && code <= 9973)   ||
          (code >= 9978  && code <= 9978)   ||
          (code >= 9981  && code <= 9981)   ||
          (code >= 9989  && code <= 9989)   ||
          (code >= 9994  && code <= 9995)   ||
          (code >= 10024 && code <= 10024)  ||
          (code >= 10060 && code <= 10060)  ||
          (code >= 10062 && code <= 10062)  ||
          (code >= 10067 && code <= 10069)  ||
          (code >= 10071 && code <= 10071)  ||
          (code >= 10133 && code <= 10135)  ||
          (code >= 10160 && code <= 10160)  ||
          (code >= 10175 && code <= 10175)  ||
          (code >= 11035 && code <= 11036)  ||
          (code >= 11088 && code <= 11088)  ||
          (code >= 11093 && code <= 11093)  ||
          (code >= 11904 && code <= 12350)  ||
          (code >= 12353 && code <= 19903)  ||
          (code >= 19968 && code <= 42191)  ||
          (code >= 44032 && code <= 55203)  ||
          (code >= 63744 && code <= 64255)  ||
          (code >= 65040 && code <= 65135)  ||
          (code >= 65280 && code <= 65376)  ||
          (code >= 65504 && code <= 65510)  ||
          (code >= 127744 && code <= 129791) )); then
      width=$((width + 2))
    else
      width=$((width + 1))
    fi
  done
  printf '%s' "$width"
}

# 화면 폭 기준으로 오른쪽을 공백으로 채운다. 넘치면 자르지 않는다 —
# --confirm-user-approval 처럼 라벨이 길어도 설명이 잘리면 안 되기 때문이다.
_herdr_harness_pad_min() {
  local text="$1" width="$2" w
  w="$(_herdr_harness_display_width "$text")"
  if (( w < width )); then
    printf '%s%*s' "$text" "$((width - w))" ''
  else
    printf '%s' "$text"
  fi
}

# 후보 하나를 터미널 폭에 가깝게 늘린다.
#
# Bash는 후보 목록을 "가장 긴 후보 + 2"를 열 너비로 삼아 COLUMNS 안에
# 몇 열이 들어가는지 계산해 배치한다. 설명이 붙은 후보를 그냥 넣으면 한 줄에
# 서너 개가 붙어 읽기 어려우므로, 모든 후보를 폭 가까이 채워 열이 하나만
# 들어가게 만든다 — 즉 한 줄에 하나씩 나온다.
_herdr_harness_pad_line() {
  local text="$1" width="$2" w
  w="$(_herdr_harness_display_width "$text")"
  while (( w > width )) && (( ${#text} > 0 )); do
    text="${text:0:${#text}-1}"
    w="$(_herdr_harness_display_width "$text")"
  done
  _herdr_harness_pad_min "$text" "$width"
}

_herdr_harness_line_width() {
  local width="${COLUMNS:-0}"
  [[ "$width" =~ ^[0-9]+$ ]] || width=0
  (( width >= 40 )) || width=80
  printf '%s' "$((width - 4))"
}

# 설명을 붙여도 안전한 상황인지 완성 때마다 다시 판정한다.
#
# Bash에는 "표시 전용" 완성 항목이 없어서 설명은 후보 문자열 자체에 들어간다.
# 기본 complete 동작에서는 후보가 여럿일 때 목록만 표시하므로 문제가 없지만,
# 사용자가 TAB을 menu-complete에 바인딩해 두었다면 후보 문자열이 그대로
# 입력된다. 그런 설정이면 설명을 끄고 명령만 반환한다.
# HERDR_HARNESS_COMPLETION_DESCRIPTIONS=0으로 언제든 끌 수 있다.
#
# 알려진 한계: insert-completions는 Bash 기본값에서 M-*(\e*)에도 묶여 있다.
# 그 키를 직접 누르면 설명 줄까지 명령줄에 들어간다. \e*까지 막으면 설명
# 기능 자체가 항상 꺼지므로(기본 바인딩이라 모든 셸에서 걸린다) 여기서는
# TAB(\C-i)만 검사한다. M-*를 쓰는 사람은 위 환경변수로 끄면 된다.
_herdr_harness_describe_enabled() {
  [[ "${HERDR_HARNESS_COMPLETION_DESCRIPTIONS:-1}" != 0 ]] || return 1
  # TAB이 "후보를 그대로 넣는" readline 명령에 묶여 있으면 설명이 명령줄에
  # 삽입된다. 그런 바인딩이 하나라도 있으면 설명을 끈다.
  #
  # 판정을 캐시하지 않는다 — 캐시하면 세션 도중 TAB을 menu-complete로
  # 다시 묶어도 계속 설명이 붙는다. bind는 내장 명령이고 아래 비교도
  # 외부 프로세스를 쓰지 않으므로 매 완성마다 확인해도 부담이 없다.
  local readline_command bound
  for readline_command in menu-complete menu-complete-backward insert-completions; do
    bound="$(bind -q "$readline_command" 2>/dev/null || true)"
    [[ "$bound" != *'\C-i'* ]] || return 1
  done
  return 0
}

# 후보가 여럿일 때만 "명령 : 설명" 형태로 보여 준다. 후보가 하나로 좁혀지면
# 설명 없이 명령만 넣어야 실제 입력이 망가지지 않는다.
# 반환: 0=후보를 넣었다, 1=일치하는 후보가 없다(호출자가 다른 완성을 시도).
_herdr_harness_describe() {
  local cur="$1"; shift
  local pair name matched=() width
  for pair in "$@"; do
    name="${pair%%::*}"
    [[ "$name" == "$cur"* ]] || continue
    matched+=("$pair")
  done
  if (( ${#matched[@]} == 0 )); then
    return 1
  fi
  if (( ${#matched[@]} == 1 )) || ! _herdr_harness_describe_enabled; then
    for pair in "${matched[@]}"; do
      COMPREPLY+=("${pair%%::*}")
    done
    return 0
  fi
  width="$(_herdr_harness_line_width)"
  for pair in "${matched[@]}"; do
    COMPREPLY+=("$(_herdr_harness_pad_line "$(_herdr_harness_pad_min "${pair%%::*}" 16) : ${pair#*::}" "$width")")
  done
  compopt -o nosort 2>/dev/null
  return 0
}

# 위치 인자(PATH·TASK_ID처럼 완성 후보에 설명을 붙일 수 없는 자리)에서
# "여기에 무엇을 넣어야 하는지"를 보여 준다.
#
# Bash 완성에는 표시 전용 줄이 없으므로 이 안내도 후보로 들어간다. 그래서
#   - cur가 비어 있을 때만 붙이고(무언가 타이핑하면 실제 완성만 남는다),
#   - 항상 2줄 이상 넣어 첫 글자가 서로 달라지게 해서 공통 접두사가 비게 한다.
#     (bash는 모든 후보의 공통 접두사만 명령줄에 넣는다 — 비면 아무것도 안 들어간다.)
# menu-complete 사용자처럼 후보가 그대로 삽입되는 환경에서는 아예 붙이지 않는다.
_herdr_harness_note() {
  local cur="$1"; shift
  [[ -z "$cur" ]] || return 0
  (( $# >= 2 )) || return 0
  _herdr_harness_describe_enabled || return 0
  local width pair
  width="$(_herdr_harness_line_width)"
  for pair in "$@"; do
    COMPREPLY+=("$(_herdr_harness_pad_line "$(_herdr_harness_pad_min "${pair%%::*}" 16) : ${pair#*::}" "$width")")
  done
  compopt -o nosort 2>/dev/null
}

_herdr_harness_subcommand_help() {
  printf '%s\n' \
    "init::새 프로젝트에 Harness 문서·정책·역할 파일 생성" \
    "sync-templates::Skill·역할·정책 템플릿을 지금 버전으로 재동기화" \
    "models::모델 허용 목록·등급 해석·프리미엄 정책 조회·갱신" \
    "start::프로젝트 디렉터리에서 Herdr Session 열기" \
    "status::STATE.md 출력 (--live로 문서·Herdr·Git 대조)" \
    "validate::상태를 바꾸지 않고 정합성만 검사" \
    "transition::Task 상태를 전이표에 따라 전이" \
    "approve::사용자 승인 기록 후 completed로 전이" \
    "dispatch::Task 역할+모델 등급·속도 정책으로 Agent를 한 턴 실행" \
    "observe::실행 중인 Agent 출력을 다시 읽어 갱신" \
    "adopt::사람이 직접 띄운 Agent를 Harness에 등록" \
    "close-agent::Harness가 만든 Agent Pane 정리" \
    "quota-check::실행 중인 Agent의 남은 쿼터 확인" \
    "quota-retry::저쿼터 시 Provider 교체(handover까지, opt-in)" \
    "auto-step::유한 턴 dispatch+observe 반복 (opt-in)" \
    "remote::원격 서버에서 빌드·테스트·VCS 실행 (opt-in)" \
    "doctor::herdr·git·Agent CLI 설치 상태 확인" \
    "test::쿼터를 쓰지 않는 자체 테스트" \
    "completion::Bash 탭 완성 스크립트 출력" \
    "uninstall::설치된 Harness 명령·파일 제거" \
    "help::명령 목록 또는 특정 명령 상세 사용법"
}

_HERDR_HARNESS_PROVIDERS=(
  "claude::Claude Code CLI"
  "codex::Codex CLI"
  "agy::agy CLI"
)

_HERDR_HARNESS_ROLES=(
  "worker::Task를 구현하고 Attempt·Evidence를 남기는 Agent"
  "reviewer::Diff와 Evidence를 읽기 전용으로 검토하는 Agent"
)

_HERDR_HARNESS_STATES=(
  "draft::초안 — 아직 착수 조건을 못 갖춘 Task"
  "ready::착수 가능 — dispatch 대상"
  "active::Agent가 작업 중"
  "submitted::Worker가 결과를 제출함 (Attempt·Evidence 필요)"
  "reviewing::Reviewer가 검토 중"
  "changes_requested::Reviewer가 수정 요청함"
  "blocked::외부 입력·결정 대기로 진행 불가"
  "handover_required::Provider 교체 등으로 인계 문서가 필요"
  "awaiting_approval::사용자 승인 대기 (approve로만 completed)"
  "completed::승인 완료 — approve 명령으로만 도달"
)

_herdr_harness_completions() {
  local cur prev cmd
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local subcommands="init sync-templates models start status doctor test uninstall validate transition approve dispatch observe adopt close-agent quota-check quota-retry auto-step remote completion help"

  if (( COMP_CWORD == 1 )); then
    local described=()
    mapfile -t described < <(_herdr_harness_subcommand_help)
    _herdr_harness_describe "$cur" "${described[@]}"
    return 0
  fi

  cmd="${COMP_WORDS[1]}"
  case "$cmd" in
    init)
      local init_options=(
        "--name::프로젝트명 (기본: 디렉터리 이름)"
        "--goal::한 줄 목표 — SPEC.md와 STATE.md에 들어간다"
        "--profile::generic | python-timeseries | network-device"
        "--orchestrator::오케스트레이터 Provider (claude|codex|agy)"
        "--worker::Worker 기본 Provider (claude|codex|agy)"
        "--reviewer::Reviewer 기본 Provider (claude|codex|agy)"
        "--fallback::쿼터 소진 시 교체 후보, 쉼표 구분"
        "--approval-mode::Agent 승인 정책 (ask|auto|bypass, 기본 auto)"
        "--remote-host::원격 실행 모드 활성화 — SSH 호스트"
        "--remote-user::원격 계정 (기본: 현재 사용자)"
        "--remote-path::원격 프로젝트 경로 (--remote-host와 함께 필수)"
        "--remote-mount::SSHFS 마운트 경로 (기본: PROJECT/.harness/remote-mount)"
        "--remote-vcs::원격 VCS (git|svn|none)"
      )
      case "$prev" in
        --profile)
          _herdr_harness_describe "$cur" \
            "generic::범용 — 언어·도메인 가정 없음" \
            "python-timeseries::Python 시계열 데이터 처리" \
            "network-device::네트워크 장비 수집·정규화"
          ;;
        --orchestrator|--worker|--reviewer)
          _herdr_harness_describe "$cur" "${_HERDR_HARNESS_PROVIDERS[@]}"
          ;;
        --approval-mode)
          _herdr_harness_describe "$cur" \
            "ask::Provider 기본값 — 도구 실행마다 사용자에게 묻는다" \
            "auto::파일 편집은 자동 승인, 위험한 작업만 묻는다 (권장)" \
            "bypass::도구 실행 승인을 전부 건너뛴다 (신뢰 가능한 트리에서만)"
          ;;
        --name|--goal|--fallback|--remote-host|--remote-user|--remote-path) ;;
        --remote-vcs)
          _herdr_harness_describe "$cur" \
            "git::원격에서 git 실행" \
            "svn::원격에서 svn 실행" \
            "none::원격 VCS 사용 안 함"
          ;;
        --remote-mount) COMPREPLY=($(compgen -d -- "$cur")) ;;
        *)
          if (( COMP_CWORD == 2 )); then
            COMPREPLY=($(compgen -d -- "$cur"))
            _herdr_harness_note "$cur" \
              "구문::herdr-harness init PATH [옵션...]" \
              "PATH::새로 만들 프로젝트 디렉터리 — 비어 있거나 없어야 한다" \
              "help::herdr-harness help init  (전체 구문과 예시)"
          else
            _herdr_harness_describe "$cur" "${init_options[@]}"
          fi
          ;;
      esac
      ;;
    start)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
        _herdr_harness_note "$cur" \
          "구문::herdr-harness start [PATH]" \
          "PATH::Harness 프로젝트 디렉터리 (생략하면 현재 디렉터리)" \
          "help::herdr-harness help start"
      fi
      ;;
    status)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
        _herdr_harness_note "$cur" \
          "구문::herdr-harness status [PATH] [--live] [--json]" \
          "PATH::Harness 프로젝트 디렉터리 (생략하면 현재 디렉터리)" \
          "help::herdr-harness help status"
      else
        _herdr_harness_describe "$cur" \
          "--live::문서 상태를 실제 Herdr Pane·Git과 대조해 DRIFT 표시" \
          "--json::결과를 JSON으로 출력 (jq로 파이프)"
      fi
      ;;
    validate)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
        _herdr_harness_note "$cur" \
          "구문::herdr-harness validate [PATH] [--wave ID] [--no-git]" \
          "PATH::Harness 프로젝트 디렉터리 (생략하면 현재 디렉터리)" \
          "help::herdr-harness help validate"
      elif [[ "$prev" == --wave ]]; then
        :
      else
        _herdr_harness_describe "$cur" \
          "--wave::검사 범위를 한 Wave로 좁힌다 (.harness/waves/ID.yaml)" \
          "--no-git::Git 상태 검사를 건너뛴다"
      fi
      ;;
    sync-templates)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
        _herdr_harness_note "$cur" \
          "구문::herdr-harness sync-templates [PATH] [--apply|--dry-run]" \
          "PATH::Harness 프로젝트 디렉터리 (생략하면 현재 디렉터리)" \
          "help::herdr-harness help sync-templates"
      else
        _herdr_harness_describe "$cur" \
          "--dry-run::무엇이 바뀔지 diff로만 보여 준다 (기본값)" \
          "--apply::Skill·역할·정책 템플릿을 실제로 갱신한다"
      fi
      ;;
    models)
      if [[ "$prev" == --premium ]]; then
        _herdr_harness_describe "$cur" \
          "claude=::Claude 전체 모델 ID (반복 지정 가능)" \
          "codex=::Codex 전체 모델 ID (반복 지정 가능)" \
          "agy=::agy 전체 모델 ID (빈 값은 프리미엄 비우기)"
      elif (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
        _herdr_harness_note "$cur" \
          "구문::herdr-harness models PATH [--refresh] [--premium PROVIDER=MODEL]... [--apply]" \
          "PATH::Harness 프로젝트 디렉터리 (필수)" \
          "help::herdr-harness help models"
      else
        _herdr_harness_describe "$cur" \
          "--refresh::조회 가능한 Provider의 허용 목록 전체 갱신을 미리보기" \
          "--premium::Provider의 프리미엄 집합을 선언적으로 대체" \
          "--apply::미리 본 모델 정책 변경을 실제로 적용"
      fi
      ;;
    transition)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
        _herdr_harness_note "$cur" \
          "구문::herdr-harness transition PATH TASK_ID TO_STATE [--note TEXT]" \
          "PATH::Harness 프로젝트 디렉터리" \
          "help::herdr-harness help transition  (전이표와 게이트)"
      elif (( COMP_CWORD == 3 )); then
        _herdr_harness_task_ids "${COMP_WORDS[2]}" "$cur"
        _herdr_harness_note "$cur" \
          "구문::herdr-harness transition PATH TASK_ID TO_STATE" \
          "TASK_ID::.harness/tasks/<ID>.yaml 의 ID" \
          "help::herdr-harness help transition"
      elif (( COMP_CWORD == 4 )); then
        _herdr_harness_describe "$cur" "${_HERDR_HARNESS_STATES[@]}"
      elif [[ "$prev" == --note ]]; then
        :
      else
        _herdr_harness_describe "$cur" \
          "--note::전이 사유를 STATE.md와 이벤트 로그에 남긴다"
      fi
      ;;
    approve)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
        _herdr_harness_note "$cur" \
          "구문::herdr-harness approve PATH TASK_ID --confirm-user-approval" \
          "PATH::Harness 프로젝트 디렉터리" \
          "help::herdr-harness help approve"
      elif (( COMP_CWORD == 3 )); then
        _herdr_harness_task_ids "${COMP_WORDS[2]}" "$cur"
        _herdr_harness_note "$cur" \
          "구문::herdr-harness approve PATH TASK_ID --confirm-user-approval" \
          "TASK_ID::awaiting_approval 상태인 Task의 ID" \
          "help::herdr-harness help approve"
      else
        _herdr_harness_describe "$cur" \
          "--confirm-user-approval::사람이 승인했다는 명시 확인 — 없으면 거부한다"
      fi
      ;;
    dispatch|observe|adopt|close-agent|quota-check|quota-retry)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
        _herdr_harness_note "$cur" \
          "구문::herdr-harness $cmd PATH TASK_ID [ROLE]" \
          "PATH::Harness 프로젝트 디렉터리" \
          "help::herdr-harness help $cmd"
      elif (( COMP_CWORD == 3 )) && [[ "$cmd" == quota-check && "$cur" == --* ]]; then
        _herdr_harness_describe "$cur" \
          "--provider::Task 없이 Provider만 지정해 쿼터 조회 (agy만 가능)"
      elif [[ "$prev" == --provider ]]; then
        _herdr_harness_describe "$cur" "${_HERDR_HARNESS_PROVIDERS[@]}"
      elif (( COMP_CWORD == 3 )); then
        _herdr_harness_task_ids "${COMP_WORDS[2]}" "$cur"
        _herdr_harness_note "$cur" \
          "구문::herdr-harness $cmd PATH TASK_ID [ROLE]" \
          "TASK_ID::.harness/tasks/<ID>.yaml 의 ID" \
          "help::herdr-harness help $cmd"
      elif (( COMP_CWORD == 4 )); then
        _herdr_harness_describe "$cur" "${_HERDR_HARNESS_ROLES[@]}"
      elif [[ "$cmd" == dispatch && "$prev" == --timeout ]]; then
        :
      elif [[ "$cmd" == dispatch && "$prev" == --cwd ]]; then
        COMPREPLY=($(compgen -d -- "$cur"))
      elif [[ "$cmd" == dispatch ]]; then
        _herdr_harness_describe "$cur" \
          "--timeout::Agent 한 턴의 대기 한도(밀리초, 기본 120000)" \
          "--print-only::Pane을 만들지 않고 실행할 herdr 명령만 출력 (폴백)" \
          "--extra-prompt::이 Task에만 필요한 추가 지시 파일을 Context Packet에 덧붙인다" \
          "--cwd::Agent를 띄울 디렉터리 — Sandbox 쓰기 범위의 기준 (기본: 워크스페이스)"
        _herdr_harness_note "$cur" \
          "모델::Task 모델 → Task 등급 → 역할 기본 등급 → 레거시 기본값 → CLI 기본값" \
          "등급::light|standard|premium; 해석 모델도 <provider>_models와 정확히 일치" \
          "속도::low|medium|high; agy는 모델 ID에 흡수되어 별도 인수 없음"
      elif [[ "$cmd" == adopt && ( "$prev" == --pane || "$prev" == --agent ) ]]; then
        :
      elif [[ "$cmd" == adopt && "$prev" == --provider ]]; then
        _herdr_harness_describe "$cur" "${_HERDR_HARNESS_PROVIDERS[@]}"
      elif [[ "$cmd" == adopt ]]; then
        _herdr_harness_describe "$cur" \
          "--pane::herdr pane split이 출력한 pane_id (필수)" \
          "--agent::herdr agent start에 쓴 Agent 이름 (필수)" \
          "--provider::Task YAML 대신 쓸 Provider (claude|codex|agy)"
      elif [[ "$cmd" == close-agent ]]; then
        _herdr_harness_describe "$cur" \
          "--force::Agent가 살아 있어도 Pane을 정리한다"
      fi
      ;;
    auto-step)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
        _herdr_harness_note "$cur" \
          "구문::herdr-harness auto-step PATH TASK_ID [--max-turns N]" \
          "PATH::Harness 프로젝트 디렉터리 (loop-policy.yaml enabled: true 필요)" \
          "help::herdr-harness help auto-step"
      elif (( COMP_CWORD == 3 )); then
        _herdr_harness_task_ids "${COMP_WORDS[2]}" "$cur"
        _herdr_harness_note "$cur" \
          "구문::herdr-harness auto-step PATH TASK_ID [--max-turns N]" \
          "TASK_ID::.harness/tasks/<ID>.yaml 의 ID" \
          "help::herdr-harness help auto-step"
      elif [[ "$prev" == --max-turns ]]; then
        :
      else
        _herdr_harness_describe "$cur" \
          "--max-turns::반복 상한 — loop-policy.yaml의 max_turns_ceiling을 넘을 수 없다"
      fi
      ;;
    remote)
      local remote_subs="setup deps doctor bootstrap-key mount unmount status run vcs shell help"
      local remote_described=(
        "setup::최초 1회 설정 — 호스트·계정 입력 + SSH 키 등록"
        "doctor::의존성·SSH·원격 경로·도구·마운트 일괄 진단"
        "status::현재 원격 설정과 연결·마운트 상태 요약"
        "mount::원격 소스를 로컬 경로에 SSHFS로 붙임"
        "unmount::SSHFS 마운트 해제"
        "run::원격 프로젝트 디렉터리에서 명령 실행 (빌드·테스트)"
        "vcs::remote.yaml의 vcs(git|svn)를 원격에서 실행"
        "shell::원격 프로젝트 디렉터리에서 대화형 셸"
        "bootstrap-key::전용 SSH 키를 원격에 등록 (setup이 자동 수행)"
        "deps::로컬 의존성과 현재 인증 방식 확인"
        "help::원격 모드 하위 명령 목록"
      )
      if (( COMP_CWORD == 2 )); then
        # 경로처럼 보일 때만 디렉터리를 섞는다. 그러지 않으면 하위 명령 목록에
        # 프로젝트 디렉터리 이름이 끼어들어 설명이 읽기 어려워진다.
        # 경로처럼 보이면 디렉터리만, 아니면 하위 명령 설명을 먼저 보여 주고
        # 일치하는 하위 명령이 없을 때만 디렉터리로 되돌아간다(remote li<TAB> → lib).
        case "$cur" in
          */*|.*|~*) COMPREPLY=($(compgen -d -- "$cur")) ;;
          *) _herdr_harness_describe "$cur" "${remote_described[@]}" ||
               COMPREPLY=($(compgen -d -- "$cur")) ;;
        esac
      elif (( COMP_CWORD == 3 )) && [[ " $remote_subs " != *" ${COMP_WORDS[2]} "* ]]; then
        _herdr_harness_describe "$cur" "${remote_described[@]}"
      elif [[ " ${COMP_WORDS[*]} " == *" setup "* ]]; then
        case "$prev" in
          --vcs)
            _herdr_harness_describe "$cur" \
              "git::원격에서 git 실행" \
              "svn::원격에서 svn 실행" \
              "none::원격 VCS 사용 안 함"
            ;;
          --path|--mount|--ssh-key) COMPREPLY=($(compgen -d -- "$cur")) ;;
          --host|--user) ;;
          *)
            _herdr_harness_describe "$cur" \
              "--host::원격 SSH 호스트 이름 또는 IP" \
              "--user::원격 계정" \
              "--path::원격 프로젝트 경로" \
              "--mount::SSHFS 마운트로 쓸 로컬 경로" \
              "--ssh-key::쓸 SSH 개인키 경로" \
              "--vcs::원격 VCS (git|svn|none)" \
              "--force::기존 remote.yaml을 덮어쓴다" \
              "--no-key::SSH 키 등록 단계를 건너뛴다"
            ;;
        esac
      fi
      ;;
    uninstall)
      _herdr_harness_describe "$cur" \
        "--yes::확인 없이 바로 제거한다"
      ;;
    completion)
      _herdr_harness_describe "$cur" \
        "bash::Bash 탭 완성 스크립트를 표준출력으로 낸다"
      ;;
    help)
      if (( COMP_CWORD == 2 )); then
        local help_topics=()
        mapfile -t help_topics < <(_herdr_harness_subcommand_help)
        _herdr_harness_describe "$cur" "${help_topics[@]}"
      fi
      ;;
  esac
}

complete -F _herdr_harness_completions herdr-harness
HARNESS_BASH_COMPLETION
}

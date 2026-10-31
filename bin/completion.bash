# herdr-harness Bash 탭 완성 — `herdr-harness completion bash`가 이 파일을 그대로 출력한다.
#   설치: ~/.bashrc에 한 줄  source <(herdr-harness completion bash)
# herdr-harness와 harness.sh(.harness/bin/harness.sh, 저장소의 harness.sh)에 등록한다.
# 후보가 여럿이면 "후보 : 설명"을 한 줄에 하나씩 보여 주고, 하나로 좁혀지면 후보만 넣는다.
# Task·Milestone·Provider 후보는 -C DIR 또는 현재 위치부터 위로 찾은 프로젝트의 파일에서 읽는다.
# 사용자의 대화형 셸 안에서 돌므로 셸 옵션을 바꾸지 않고(글롭 대신 compgen -G) 변수는 모두 local로 둔다.
# 명령·옵션·상태 목록이 harness.sh와 어긋나지 않는지 test.sh가 대조한다.

_HERDR_HARNESS_COMMANDS=(
  "status::진행 상황 · Task 표 · 사용자 판단 대기"
  "start::Herdr에 프로젝트 세션·workspace 열기"
  "run::사람 결정이 필요할 때까지 자동 진행"
  "approve-plan::계획(Task·등급·AC) 승인 — draft → ready"
  "approve::Milestone 완료 승인 → 보관·태그"
  "reject::승인 대기 결과 반려 → 재작업"
  "validate::상태를 바꾸지 않고 일괄 검사"
  "verify::AC 명령을 지금 코드에서 다시 실행해 기록"
  "metrics::에이전트·등급별 시도·통과 지표"
  "models::등급별 모델 매핑"
  "review-level::검토 수준 예외 · 자동 하향 허용"
  "provider::못 쓰는 에이전트 표시 (list · off · on)"
  "quota-check::남은 쿼터 확인"
  "prune::보관함을 요약만 남기고 정리"
  "remote::원격 모드 (setup · mount · run …)"
  "doctor::herdr · git · 에이전트 CLI · 설정 점검"
  "transition::Task 상태 한 단계 전이"
  "dispatch::Worker·Reviewer 한 턴 실행"
  "observe::실행 중인 에이전트 출력 확인"
  "close::에이전트 Pane 정리"
  "init::새 프로젝트 만들기"
  "upgrade::프로젝트의 bin·Skill을 이 버전으로"
  "migrate::v1 프로젝트를 v2로 이전"
  "install::전역 herdr-harness 명령 설치 (저장소에서)"
  "completion::Bash 탭 완성 스크립트 출력"
  "help::명령 목록"
)

_HERDR_HARNESS_ROLES=(
  "worker::Task를 구현하고 보고서를 쓰는 에이전트"
  "reviewer::결과를 읽기 전용으로 검토하는 에이전트"
)

_HERDR_HARNESS_STATES=(
  "draft::초안 — 계획 승인 전"
  "ready::착수 가능"
  "active::Worker 작업 중"
  "submitted::제출됨 — 하네스가 AC 실행·기록"
  "reviewing::Reviewer 검토 중"
  "changes_requested::수정 요청"
  "blocked::외부 입력·결정 대기"
  "handover_required::인계 문서 필요 (Provider 교체 등)"
  "awaiting_approval::통합됨 — 사용자 승인 대기"
  "completed::Milestone 승인으로 완료"
)

# lib/gates.sh의 TRANSITIONS와 같다.
_HERDR_HARNESS_TRANSITIONS=" draft>ready ready>active active>submitted active>blocked active>handover_required blocked>active submitted>reviewing reviewing>changes_requested reviewing>awaiting_approval changes_requested>ready handover_required>ready awaiting_approval>completed awaiting_approval>changes_requested "

_HERDR_HARNESS_LEVELS=(
  "cross_provider::다른 회사 에이전트가 검토 (기본)"
  "cross_model::같은 회사 · 다른 모델"
  "same_model::같은 모델 · 별도 세션"
)

_HERDR_HARNESS_REMOTE=(
  "setup::최초 1회 — 설정 작성 · SSH 키 등록"
  "doctor::의존성 · SSH · 원격 경로 · 마운트 진단"
  "mount::원격 소스를 SSHFS로 마운트"
  "unmount::마운트 해제"
  "status::설정과 연결 · 마운트 상태"
  "run::원격 프로젝트에서 명령 실행"
  "vcs::remote.yaml의 vcs를 원격에서 실행"
  "shell::원격 프로젝트에서 대화형 셸"
  "bootstrap-key::HH_REMOTE_PASSWORD로 전용 키 등록"
  "deps::로컬 의존성과 인증 방식"
  "help::remote 사용법"
)

# 한 글자의 화면 폭: 결합 문자 0, East Asian Wide·Fullwidth 2, 그 밖 1.
# 완전한 wcwidth는 아니다(ZWJ로 이은 이모지는 넓게 센다). 설명 정렬에만 쓴다.
_herdr_harness_cw() {  # VAR 코드포인트
  local c="$2"
  if (( (c >= 768 && c <= 879) || (c >= 1155 && c <= 1161) || (c >= 6832 && c <= 6911) || (c >= 7616 && c <= 7679) ||
        (c >= 8203 && c <= 8207) || (c >= 8400 && c <= 8447) || (c >= 65024 && c <= 65039) || (c >= 65056 && c <= 65071) )); then
    printf -v "$1" 0
  elif (( (c >= 4352 && c <= 4447) || (c >= 8986 && c <= 8987) || (c >= 9001 && c <= 9002) || (c >= 9193 && c <= 9203) ||
          (c >= 9725 && c <= 9726) || (c >= 9748 && c <= 9749) || (c >= 9800 && c <= 9811) || c == 9855 || c == 9875 ||
          c == 9889 || (c >= 9898 && c <= 9899) || (c >= 9917 && c <= 9918) || (c >= 9924 && c <= 9925) || c == 9934 ||
          c == 9940 || c == 9962 || (c >= 9970 && c <= 9971) || c == 9973 || c == 9978 || c == 9981 || c == 9989 ||
          (c >= 9994 && c <= 9995) || c == 10024 || c == 10060 || c == 10062 || (c >= 10067 && c <= 10069) || c == 10071 ||
          (c >= 10133 && c <= 10135) || c == 10160 || c == 10175 || (c >= 11035 && c <= 11036) || c == 11088 || c == 11093 ||
          (c >= 11904 && c <= 12350) || (c >= 12353 && c <= 19903) || (c >= 19968 && c <= 42191) || (c >= 44032 && c <= 55203) ||
          (c >= 63744 && c <= 64255) || (c >= 65040 && c <= 65135) || (c >= 65280 && c <= 65376) || (c >= 65504 && c <= 65510) ||
          (c >= 127744 && c <= 129791) )); then
    printf -v "$1" 2
  else
    printf -v "$1" 1
  fi
}

_herdr_harness_fit() {  # VAR TEXT MIN [MAX] — MIN칸까지 공백으로 채우고 MAX칸을 넘는 뒷부분은 자른다
  local __t="$2" __min="$3" __max="${4:-0}" __i __code __cw __w=0 __out=""
  if [[ "$__t" != *[![:ascii:]]* ]]; then   # ASCII만이면 글자 수가 곧 폭이다
    __out="$__t"; (( __max == 0 || ${#__out} <= __max )) || __out="${__out:0:__max}"; __w=${#__out}
  else
    for (( __i = 0; __i < ${#__t}; __i++ )); do
      printf -v __code '%d' "'${__t:__i:1}"
      if (( __code < 768 )); then __cw=1
      elif (( __code >= 44032 && __code <= 55203 )); then __cw=2   # 한글 음절은 표를 보지 않는다
      else _herdr_harness_cw __cw "$__code"; fi
      (( __max == 0 || __w + __cw <= __max )) || break
      __out+="${__t:__i:1}"; __w=$(( __w + __cw ))
    done
  fi
  (( __w >= __min )) || printf -v __out '%s%*s' "$__out" $(( __min - __w )) ''
  printf -v "$1" '%s' "$__out"
}

# 설명은 후보 문자열 자체에 들어간다(Bash에는 표시 전용 후보가 없다). 후보를 명령줄에 그대로 넣는 완성에서는
# 설명이 명령줄에 들어가므로 끈다: menu-complete(COMP_TYPE 37 '%', 어느 키에 묶였든)와 insert-completions(42 '*', M-*).
# 목록을 보여 주는 TAB(9·63 등)에서만 붙인다. HERDR_HARNESS_COMPLETION_DESCRIPTIONS=0이면 늘 끈다.
_herdr_harness_describe_enabled() {
  [[ "${HERDR_HARNESS_COMPLETION_DESCRIPTIONS:-1}" != 0 ]] || return 1
  case "${COMP_TYPE:-9}" in 37|42) return 1 ;; esac
  return 0
}

_HERDR_HARNESS_DESCRIBE_MAX=40   # 후보가 이보다 많으면 설명 없이 낸다 (어차피 긴 목록이고 폭 계산이 느려진다)

# 후보가 여럿이면 "후보 : 설명"을 화면 폭 가까이 채운다. Bash는 가장 긴 후보 폭으로 열을 나누므로 모두
# 폭만큼 채우면 한 줄에 하나씩 보인다. 하나로 좁혀지면 후보만 넣어야 명령줄이 맞다.
# 같은 이름이 두 번 들어가면 공통 접두사에 설명까지 들어가 명령줄이 망가지므로 이름은 한 번만 쓴다.
_herdr_harness_describe() {  # CUR "후보::설명"... — 반환 1 = 맞는 후보 없음
  local cur="$1" pair name line width seen=" "
  local -a matched=()
  shift
  for pair in "$@"; do
    name="${pair%%::*}"
    [[ "$name" == "$cur"* && "$seen" != *" $name "* ]] || continue
    seen+="$name "; matched+=("$pair")
  done
  (( ${#matched[@]} > 0 )) || return 1
  if (( ${#matched[@]} == 1 || ${#matched[@]} > _HERDR_HARNESS_DESCRIBE_MAX )) || ! _herdr_harness_describe_enabled; then
    for pair in "${matched[@]}"; do COMPREPLY+=("${pair%%::*}"); done
    return 0
  fi
  width="${COLUMNS:-80}"
  [[ "$width" =~ ^[0-9]+$ ]] && (( width >= 40 )) || width=80
  width=$(( width - 4 ))
  for pair in "${matched[@]}"; do
    _herdr_harness_fit name "${pair%%::*}" 16
    _herdr_harness_fit line "$name : ${pair#*::}" "$width" "$width"
    COMPREPLY+=("$line")
  done
  compopt -o nosort 2>/dev/null || true
  return 0
}

_herdr_harness_words() {  # CUR 후보... — 설명 없는 후보
  local cur="$1" w
  shift
  for w in "$@"; do [[ "$w" != "$cur"* ]] || COMPREPLY+=("$w"); done
  return 0
}

_herdr_harness_paths() {  # CUR -d|-f — 폴더·파일 후보 (공백이 든 이름도 한 후보로)
  local p
  while IFS= read -r p; do COMPREPLY+=("$p"); done < <(compgen "$2" -- "$1")
  compopt -o filenames 2>/dev/null || true
}

# 명령줄에 적힌 경로를 셸처럼 푼다: 감싼 따옴표, 백슬래시, 앞의 ~, $NAME·${NAME}. 명령 치환은 하지 않는다
# (TAB이 코드를 실행하면 안 된다). 한계: 경로에 = 나 : 가 있으면 Bash가 단어를 쪼개(COMP_WORDBREAKS) 찾지 못한다.
_herdr_harness_dequote() {  # VAR WORD
  local __w="$2" __n __i
  case "$__w" in
    \'*\') printf -v "$1" '%s' "${__w:1:${#__w}-2}"; return 0 ;;
    \"*\") __w="${__w:1:${#__w}-2}" ;;
    *) __w="${__w//\\/}"; case "$__w" in "~") __w="$HOME" ;; "~/"*) __w="$HOME/${__w#\~/}" ;; esac ;;
  esac
  for (( __i = 0; __i < 10; __i++ )); do
    [[ "$__w" =~ \$\{?([A-Za-z_][A-Za-z0-9_]*)\}? ]] || break
    __n="${BASH_REMATCH[1]}"
    __w="${__w/"${BASH_REMATCH[0]}"/"${!__n:-}"}"
  done
  printf -v "$1" '%s' "$__w"
}

# 프로젝트 루트: -C DIR(그 폴더만) 또는 현재 위치부터 위로. Task 작업 공간(.harness/worktrees/T) 안이면 바깥
# 프로젝트에서 찾는다(작업 공간의 .harness는 브랜치 시점 사본이다). 없으면 빈 값.
_herdr_harness_root() {  # VAR
  local d=""
  if [[ "${COMP_WORDS[1]:-}" == -C ]]; then
    _herdr_harness_dequote d "${COMP_WORDS[2]:-}"
  else
    d="${PWD%%/.harness/worktrees/*}"
    while [[ "$d" != / && ! -f "$d/.harness/project.yaml" ]]; do d="${d%/*}"; d="${d:-/}"; done
  fi
  [[ -n "$d" && -f "$d/.harness/project.yaml" ]] || d=""
  printf -v "$1" '%s' "$d"
}

_herdr_harness_scalar() {  # VAR RAW — YAML 값 하나: 따옴표 안의 #은 값, 따옴표 밖의 " #"부터는 주석
  local __v="$2"
  __v="${__v#"${__v%%[![:space:]]*}"}"
  case "$__v" in
    \'*) __v="${__v:1}"; __v="${__v//\'\'/$'\001'}"; __v="${__v%%\'*}"; __v="${__v//$'\001'/\'}" ;;
    \"*) __v="${__v:1}"; __v="${__v%%\"*}" ;;
    *) __v="${__v%%[[:space:]]#*}"; __v="${__v%"${__v##*[![:space:]]}"}" ;;
  esac
  printf -v "$1" '%s' "$__v"
}

_herdr_harness_value() {  # VAR FILE KEY — 최상위 KEY의 값
  local __line
  printf -v "$1" '%s' ""
  [[ -f "$2" ]] || return 0
  while IFS= read -r __line || [[ -n "$__line" ]]; do
    [[ "$__line" == "$3:"* ]] || continue
    _herdr_harness_scalar "$1" "${__line#"$3:"}"
    return 0
  done <"$2"
}

_herdr_harness_task_files() {  # ROOT [archived] — 진행 중 Task 파일 (archived면 보관된 것도)
  [[ -n "$1" ]] || return 0
  compgen -G "$1/.harness/tasks/*.yaml" || true
  [[ -z "${2:-}" ]] || compgen -G "$1/.harness/archive/*/tasks/*.yaml" || true
}

_herdr_harness_tasks() {  # CUR ROOT [archived] — "Task : 상태 · 제목" 후보
  local f id st title line show=0
  local -a files=() pairs=()
  while IFS= read -r f; do   # ID 접두사로 먼저 거른다 (파일은 설명을 보일 때만 읽는다)
    id="${f##*/}"; id="${id%.yaml}"
    [[ "$id" == TEMPLATE || "$id" != "$1"* ]] || files+=("$f")
  done < <(_herdr_harness_task_files "$2" "${3:-}")
  (( ${#files[@]} > 0 )) || return 0
  if (( ${#files[@]} > 1 && ${#files[@]} <= _HERDR_HARNESS_DESCRIBE_MAX )) && _herdr_harness_describe_enabled; then show=1; fi
  for f in "${files[@]}"; do
    id="${f##*/}"; id="${id%.yaml}"; st="" title=""
    if (( show )); then
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in status:*) _herdr_harness_scalar st "${line#status:}" ;; title:*) _herdr_harness_scalar title "${line#title:}" ;; esac
        [[ -z "$st" || -z "$title" ]] || break
      done <"$f"
      [[ "$f" != "$2/.harness/archive/"* ]] || st="보관됨"
    fi
    pairs+=("$id::${st:-?} · $title")
  done
  _herdr_harness_describe "$1" "${pairs[@]}"
  return 0
}

_herdr_harness_milestones() {  # CUR ROOT [archived] — Task들의 milestone_id (중복 없이)
  local f m seen=" "
  local -a ids=()
  while IFS= read -r f; do
    [[ "${f##*/}" != TEMPLATE.yaml ]] || continue
    _herdr_harness_value m "$f" milestone_id
    [[ -n "$m" && "$seen" != *" $m "* ]] || continue
    seen+="$m "; ids+=("$m")
  done < <(_herdr_harness_task_files "$2" "${3:-}")
  _herdr_harness_words "$1" "${ids[@]}"
}

_herdr_harness_archives() {  # CUR ROOT — 보관된 Milestone (archive/<m>/SUMMARY.md)
  local f
  local -a ids=()
  [[ -n "$2" ]] || return 0
  while IFS= read -r f; do f="${f%/SUMMARY.md}"; ids+=("${f##*/}"); done < <(compgen -G "$2/.harness/archive/*/SUMMARY.md" || true)
  _herdr_harness_words "$1" "${ids[@]}"
}

_herdr_harness_providers() {  # CUR ROOT — project.yaml providers.available (없으면 claude codex agy)
  local line inside=0 list=""
  local -a names=()
  if [[ -n "$2" && -f "$2/.harness/project.yaml" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == providers:* ]]; then inside=1; continue; fi
      [[ "$line" != [![:space:]#]* ]] || inside=0
      if (( inside )) && [[ "$line" =~ ^[[:space:]]+available:[[:space:]]*\[([^]]*)\] ]]; then list="${BASH_REMATCH[1]}"; break; fi
    done <"$2/.harness/project.yaml"
  fi
  list="${list//[\'\",]/ }"
  [[ -n "${list//[[:space:]]/}" ]] || list="claude codex agy"
  read -r -a names <<<"$list"
  _herdr_harness_words "$1" "${names[@]}"
}

_herdr_harness_next_states() {  # CUR 현재상태 — 전이할 수 있는 상태 (현재 상태를 모를 때만 전부, 끝난 상태면 없음)
  local pair
  local -a out=()
  for pair in "${_HERDR_HARNESS_STATES[@]}"; do
    [[ -n "$2" && "$_HERDR_HARNESS_TRANSITIONS" != *" $2>${pair%%::*} "* ]] || out+=("$pair")
  done
  (( ${#out[@]} == 0 )) || _herdr_harness_describe "$1" "${out[@]}"
  return 0
}

_herdr_harness_completions() {
  local cur prev root sub st pair base=1 n
  local -a cmds=()
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]:-}"
  if [[ "${COMP_WORDS[1]:-}" == -C ]] && (( COMP_CWORD >= 2 )); then
    if (( COMP_CWORD == 2 )); then _herdr_harness_paths "$cur" -d; return 0; fi
    base=3
  fi
  if (( COMP_CWORD == base )); then
    if (( base == 1 )) && [[ "$cur" == -* ]]; then _herdr_harness_describe "$cur" "-C::다른 위치의 프로젝트 (-C DIR 명령)"; return 0; fi
    for pair in "${_HERDR_HARNESS_COMMANDS[@]}"; do   # completion은 전역 명령만 안다
      [[ "${pair%%::*}" == completion && "${COMP_WORDS[0]##*/}" != herdr-harness ]] || cmds+=("$pair")
    done
    _herdr_harness_describe "$cur" "${cmds[@]}"
    return 0
  fi
  n=$(( COMP_CWORD - base ))     # 명령 뒤 몇 번째 자리인가 (1부터)
  sub="${COMP_WORDS[base+1]:-}"  # 명령 바로 뒤 첫 인수
  _herdr_harness_root root
  case "${COMP_WORDS[base]}" in
    init)
      case "$prev" in
        --profile) _herdr_harness_describe "$cur" "generic::일반" "python-timeseries::Python 시계열·실험" "network-device::네트워크 장비 데이터 정규화" ;;
        --orchestrator|--worker|--reviewer) _herdr_harness_providers "$cur" "" ;;
        --approval-mode)
          _herdr_harness_describe "$cur" "ask::도구를 실행할 때마다 확인" "auto::에이전트의 자동 승인 모드 (기본)" \
            "bypass::확인 없이 실행 — 격리된 작업 공간에서만" ;;
        --review-level) _herdr_harness_describe "$cur" "${_HERDR_HARNESS_LEVELS[@]}" ;;
        --code-dir) _herdr_harness_paths "$cur" -d ;;
        --goal|--name|--fallback) ;;
        *)
          if (( n == 1 )); then _herdr_harness_paths "$cur" -d
          else
            _herdr_harness_describe "$cur" \
              "--goal::프로젝트 목표 한 줄 (필수)" "--name::프로젝트 이름 (기본: 폴더 이름)" \
              "--profile::generic | python-timeseries | network-device" \
              "--orchestrator::Orchestrator 에이전트" "--worker::Worker 에이전트" "--reviewer::Reviewer 에이전트" \
              "--fallback::교체 순서 (예: claude,agy)" "--approval-mode::ask | auto | bypass" \
              "--code-dir::수정할 코드 저장소가 따로 있을 때" "--review-level::cross_provider | cross_model | same_model"
          fi ;;
      esac ;;
    upgrade) _herdr_harness_paths "$cur" -d ;;
    migrate)
      case "$prev" in
        --review-level) _herdr_harness_describe "$cur" "${_HERDR_HARNESS_LEVELS[@]}" ;;
        --reason|--complete|--complete-reason) ;;
        *)
          if (( n == 1 )); then _herdr_harness_paths "$cur" -d
          else
            _herdr_harness_describe "$cur" \
              "--apply::실제로 이전한다 (없으면 사전 점검 보고서만)" "--confirm-user-approval::사용자 승인 확인" \
              "--review-level::같은 회사 Task의 검토 수준" "--reason::검토 수준을 정한 사유" \
              "--complete::완료로 인정할 Task (T,T)" "--complete-reason::완료 인정 사유" \
              "--undo::병합 전 이전 되돌리기" "--rollback::끊긴 이전을 기록대로 되돌리기"
          fi ;;
      esac ;;
    install) _herdr_harness_describe "$cur" "--replace-v1::그 자리의 v1 설치본을 바꾼다 (v1에 직접 고친 내용은 사라짐)" ;;
    models) (( n > 1 )) || _herdr_harness_describe "$cur" "--refresh::실제 모델 목록과 대조" ;;
    approve-plan|approve)
      if (( n == 1 )); then _herdr_harness_milestones "$cur" "$root"
      else _herdr_harness_describe "$cur" "--confirm-user-approval::사용자 승인 확인 (필수)"; fi ;;
    run)
      if (( n == 1 )); then _herdr_harness_milestones "$cur" "$root"
      elif [[ "$prev" != --max-minutes && "$prev" != --poll ]]; then
        _herdr_harness_describe "$cur" "--in-pane::별도 Pane에서 실행 (Orchestrator 도구 시간 제한 회피)" \
          "--max-minutes::최대 실행 시간(분)" "--poll::상태 확인 간격(초)"
      fi ;;
    reject)
      if (( n == 1 )); then _herdr_harness_tasks "$cur" "$root"
      elif [[ "$prev" != --reason ]]; then
        _herdr_harness_describe "$cur" "--reason::반려 사유 (필수)" "--confirm-user-approval::사용자 승인 확인 (필수)"
      fi ;;
    review-level)
      case "$prev" in
        --task) _herdr_harness_tasks "$cur" "$root" ;;
        --fallback) _herdr_harness_describe "$cur" "none::자동 하향 안 함" "cross_model::같은 회사 다른 모델까지 허용" "same_model::같은 모델 별도 세션까지 허용" ;;
        --reason) ;;
        *)
          if (( n == 1 )) && [[ "$cur" != -* ]]; then _herdr_harness_describe "$cur" "${_HERDR_HARNESS_LEVELS[@]}"
          else
            _herdr_harness_describe "$cur" "--task::이 Task에만 적용" "--fallback::Provider를 못 쓸 때 자동 하향 허용 범위" \
              "--reason::사유 (필수)" "--confirm-user-approval::낮추기·허용은 사용자 승인 필수"
          fi ;;
      esac ;;
    provider)
      if (( n == 1 )); then _herdr_harness_describe "$cur" "list::에이전트별 사용 가능 여부" "off::사용 불가로 표시 (--reason)" "on::다시 사용 가능으로"
      elif [[ "$sub" == off || "$sub" == on ]]; then
        if (( n == 2 )); then _herdr_harness_providers "$cur" "$root"
        elif [[ "$prev" != --reason ]]; then _herdr_harness_describe "$cur" "--reason::사유"; fi
      fi ;;
    prune) (( n > 1 )) || _herdr_harness_archives "$cur" "$root" ;;
    verify)
      if [[ "$prev" == --milestone ]]; then _herdr_harness_milestones "$cur" "$root" archived
      elif (( n == 1 )); then
        if [[ "$cur" == -* ]]; then
          _herdr_harness_describe "$cur" "--milestone::Milestone의 모든 Task (보관된 것 포함)" "--legacy::v1에서 이전된 Task 중 증빙이 불완전한 것"
        else _herdr_harness_tasks "$cur" "$root" archived; fi
      fi ;;
    transition)
      if (( n == 1 )); then _herdr_harness_tasks "$cur" "$root"
      elif (( n == 2 )); then
        st=""; [[ -z "$root" ]] || _herdr_harness_value st "$root/.harness/tasks/$sub.yaml" status
        _herdr_harness_next_states "$cur" "$st"
      fi ;;
    dispatch)
      if (( n == 1 )); then _herdr_harness_tasks "$cur" "$root"
      elif (( n == 2 )); then _herdr_harness_describe "$cur" "${_HERDR_HARNESS_ROLES[@]}"
      elif [[ "$prev" == --extra-prompt ]]; then _herdr_harness_paths "$cur" -f
      elif [[ "$prev" != --timeout ]]; then
        _herdr_harness_describe "$cur" "--timeout::한 턴 대기 한도(밀리초)" "--extra-prompt::이 Task에만 줄 추가 지시 파일"
      fi ;;
    observe|close)
      if (( n == 1 )); then _herdr_harness_tasks "$cur" "$root"
      elif [[ "$prev" == --wait ]]; then :
      elif (( n == 2 )) && [[ "$cur" != -* ]]; then _herdr_harness_describe "$cur" "${_HERDR_HARNESS_ROLES[@]}"
      elif [[ "${COMP_WORDS[base]}" == observe ]]; then _herdr_harness_describe "$cur" "--wait::새 출력을 기다릴 시간(밀리초)"
      else _herdr_harness_describe "$cur" "--force::에이전트가 살아 있어도 Pane을 닫는다"
      fi ;;
    quota-check)
      if [[ "$prev" == --provider ]]; then _herdr_harness_providers "$cur" "$root"
      elif (( n == 1 )); then
        if [[ "$cur" == -* ]]; then _herdr_harness_describe "$cur" "--provider::Task 없이 Provider 쿼터 조회 (agy)"
        else _herdr_harness_tasks "$cur" "$root"; fi
      elif (( n == 2 )) && [[ "$sub" != --provider ]]; then _herdr_harness_describe "$cur" "${_HERDR_HARNESS_ROLES[@]}"
      fi ;;
    remote)
      if (( n == 1 )); then _herdr_harness_describe "$cur" "${_HERDR_HARNESS_REMOTE[@]}"
      elif [[ "$sub" == setup ]]; then
        case "$prev" in
          --host|--user|--path|--mount-options) ;;
          --mount) _herdr_harness_paths "$cur" -d ;;
          --ssh-key) _herdr_harness_paths "$cur" -f ;;
          --vcs) _herdr_harness_describe "$cur" "git::git" "svn::svn" "none::VCS 없음 (remote run만)" ;;
          *)
            _herdr_harness_describe "$cur" "--host::원격 호스트" "--user::원격 계정" "--path::원격 프로젝트 경로 (절대경로)" \
              "--mount::SSHFS 마운트 경로 (로컬)" "--ssh-key::전용 SSH 키 경로" "--vcs::git | svn | none" \
              "--mount-options::sshfs에 더할 -o 옵션 (예: follow_symlinks)" \
              "--force::기존 설정을 다시 쓴다" "--no-key::SSH 키 등록을 건너뛴다" ;;
        esac
      fi ;;
    completion) (( n > 1 )) || _herdr_harness_describe "$cur" "bash::Bash 탭 완성 스크립트" ;;
  esac
  return 0
}

complete -F _herdr_harness_completions herdr-harness harness.sh

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


# 후보가 여럿일 때만 "명령  설명" 형태로 보여 준다. 후보가 하나로 좁혀지면
# 설명 없이 명령만 넣어야 실제 입력이 망가지지 않는다(Bash에는 설명 전용
# 표시 기능이 없어 이 방식이 유일하게 안전하다).
_herdr_harness_describe() {
  local cur="$1"; shift
  local pair name matched=()
  for pair in "$@"; do
    name="${pair%%::*}"
    [[ "$name" == "$cur"* ]] || continue
    matched+=("$pair")
  done
  if (( ${#matched[@]} == 0 )); then
    return 0
  fi
  if (( ${#matched[@]} == 1 )); then
    COMPREPLY+=("${matched[0]%%::*}")
    return 0
  fi
  for pair in "${matched[@]}"; do
    COMPREPLY+=("$(printf '%-16s : %s' "${pair%%::*}" "${pair#*::}")")
  done
  compopt -o nosort 2>/dev/null
  return 0
}

_herdr_harness_subcommand_help() {
  printf '%s\n' \
    "init::새 프로젝트에 Harness 문서·정책·역할 파일 생성" \
    "sync-templates::Skill·역할 파일을 지금 버전 템플릿으로 재동기화" \
    "start::프로젝트 디렉터리에서 Herdr Session 열기" \
    "status::STATE.md 출력 (--live로 문서·Herdr·Git 대조)" \
    "validate::상태를 바꾸지 않고 정합성만 검사" \
    "transition::Task 상태를 전이표에 따라 전이" \
    "approve::사용자 승인 기록 후 completed로 전이" \
    "dispatch::Task+역할로 Agent를 한 턴 실행" \
    "observe::실행 중인 Agent 출력을 다시 읽어 갱신" \
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

_herdr_harness_completions() {
  local cur prev cmd
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local subcommands="init sync-templates start status doctor test uninstall validate transition approve dispatch observe close-agent quota-check quota-retry auto-step remote completion help"

  if (( COMP_CWORD == 1 )); then
    local described=()
    mapfile -t described < <(_herdr_harness_subcommand_help)
    _herdr_harness_describe "$cur" "${described[@]}"
    return 0
  fi

  cmd="${COMP_WORDS[1]}"
  case "$cmd" in
    init)
      case "$prev" in
        --profile) COMPREPLY=($(compgen -W "generic python-timeseries network-device" -- "$cur")) ;;
        --orchestrator|--worker|--reviewer) COMPREPLY=($(compgen -W "claude codex agy" -- "$cur")) ;;
        --name|--goal|--fallback|--remote-host|--remote-user|--remote-path) ;;
        --remote-vcs) COMPREPLY=($(compgen -W "git svn none" -- "$cur")) ;;
        --remote-mount) COMPREPLY=($(compgen -d -- "$cur")) ;;
        *)
          if (( COMP_CWORD == 2 )); then
            COMPREPLY=($(compgen -d -- "$cur"))
          else
            COMPREPLY=($(compgen -W "--name --goal --profile --orchestrator --worker --reviewer --fallback --remote-host --remote-user --remote-path --remote-mount --remote-vcs" -- "$cur"))
          fi
          ;;
      esac
      ;;
    start|status)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      else
        COMPREPLY=($(compgen -W "--live --json" -- "$cur"))
      fi
      ;;
    validate)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      elif [[ "$prev" == --wave ]]; then
        :
      else
        COMPREPLY=($(compgen -W "--wave --no-git" -- "$cur"))
      fi
      ;;
    sync-templates)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      else
        COMPREPLY=($(compgen -W "--apply --dry-run" -- "$cur"))
      fi
      ;;
    transition)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      elif (( COMP_CWORD == 3 )); then
        _herdr_harness_task_ids "${COMP_WORDS[2]}" "$cur"
      elif (( COMP_CWORD == 4 )); then
        COMPREPLY=($(compgen -W "draft ready active submitted blocked handover_required reviewing changes_requested awaiting_approval completed" -- "$cur"))
      elif [[ "$prev" == --note ]]; then
        :
      else
        COMPREPLY=($(compgen -W "--note" -- "$cur"))
      fi
      ;;
    approve)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      elif (( COMP_CWORD == 3 )); then
        _herdr_harness_task_ids "${COMP_WORDS[2]}" "$cur"
      else
        COMPREPLY=($(compgen -W "--confirm-user-approval" -- "$cur"))
      fi
      ;;
    dispatch|observe|close-agent|quota-check|quota-retry)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      elif (( COMP_CWORD == 3 )) && [[ "$cmd" == quota-check && "$cur" == --* ]]; then
        COMPREPLY=($(compgen -W "--provider" -- "$cur"))
      elif [[ "$prev" == --provider ]]; then
        COMPREPLY=($(compgen -W "claude codex agy" -- "$cur"))
      elif (( COMP_CWORD == 3 )); then
        _herdr_harness_task_ids "${COMP_WORDS[2]}" "$cur"
      elif (( COMP_CWORD == 4 )); then
        COMPREPLY=($(compgen -W "worker reviewer" -- "$cur"))
      elif [[ "$cmd" == dispatch && "$prev" == --timeout ]]; then
        :
      elif [[ "$cmd" == dispatch ]]; then
        COMPREPLY=($(compgen -W "--timeout" -- "$cur"))
      elif [[ "$cmd" == close-agent ]]; then
        COMPREPLY=($(compgen -W "--force" -- "$cur"))
      fi
      ;;
    auto-step)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -d -- "$cur"))
      elif (( COMP_CWORD == 3 )); then
        _herdr_harness_task_ids "${COMP_WORDS[2]}" "$cur"
      elif [[ "$prev" == --max-turns ]]; then
        :
      else
        COMPREPLY=($(compgen -W "--max-turns" -- "$cur"))
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
        case "$cur" in
          */*|.*|~*) COMPREPLY=($(compgen -d -- "$cur")) ;;
          *) _herdr_harness_describe "$cur" "${remote_described[@]}" ;;
        esac
      elif (( COMP_CWORD == 3 )) && [[ " $remote_subs " != *" ${COMP_WORDS[2]} "* ]]; then
        _herdr_harness_describe "$cur" "${remote_described[@]}"
      elif [[ " ${COMP_WORDS[*]} " == *" setup "* ]]; then
        case "$prev" in
          --vcs) COMPREPLY=($(compgen -W "git svn none" -- "$cur")) ;;
          --path|--mount|--ssh-key) COMPREPLY=($(compgen -d -- "$cur")) ;;
          --host|--user) ;;
          *) COMPREPLY=($(compgen -W "--host --user --path --mount --ssh-key --vcs --force --no-key" -- "$cur")) ;;
        esac
      fi
      ;;
    uninstall)
      COMPREPLY=($(compgen -W "--yes" -- "$cur"))
      ;;
    completion)
      COMPREPLY=($(compgen -W "bash" -- "$cur"))
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

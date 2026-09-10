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

_herdr_harness_completions() {
  local cur prev cmd
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local subcommands="init sync-templates start status doctor test uninstall validate transition approve dispatch observe close-agent quota-check quota-retry auto-step remote completion"

  if (( COMP_CWORD == 1 )); then
    COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
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
      local remote_subs="deps doctor bootstrap-key mount unmount status run vcs shell help"
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=($(compgen -W "$remote_subs" -- "$cur"))
        COMPREPLY+=($(compgen -d -- "$cur"))
      elif (( COMP_CWORD == 3 )) && [[ " $remote_subs " != *" ${COMP_WORDS[2]} "* ]]; then
        COMPREPLY=($(compgen -W "$remote_subs" -- "$cur"))
      fi
      ;;
    uninstall)
      COMPREPLY=($(compgen -W "--yes" -- "$cur"))
      ;;
    completion)
      COMPREPLY=($(compgen -W "bash" -- "$cur"))
      ;;
  esac
}

complete -F _herdr_harness_completions herdr-harness
HARNESS_BASH_COMPLETION
}

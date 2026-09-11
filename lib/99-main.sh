# Part of herdr-harness. Sourced by harness.sh — do not run directly.


main() {
  local command="${1:-help}"
  [[ $# -eq 0 ]] || shift
  case "$command" in
    init) cmd_init "$@" ;;
    sync-templates) cmd_sync_templates "$@" ;;
    models) cmd_models "$@" ;;
    start) cmd_start "$@" ;;
    status) cmd_status "$@" ;;
    validate) cmd_validate "$@" ;;
    transition) cmd_transition "$@" ;;
    approve) cmd_approve "$@" ;;
    dispatch) cmd_dispatch "$@" ;;
    observe) cmd_observe "$@" ;;
    adopt) cmd_adopt "$@" ;;
    close-agent) cmd_close_agent "$@" ;;
    quota-check) cmd_quota_check "$@" ;;
    quota-retry) cmd_quota_retry "$@" ;;
    auto-step) cmd_auto_step "$@" ;;
    remote) cmd_remote "$@" ;;
    completion) cmd_completion "$@" ;;
    doctor) cmd_doctor "$@" ;;
    test) cmd_test "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    help|-h|--help) cmd_help "$@" ;;
    *) die "알 수 없는 명령: $command" ;;
  esac
}

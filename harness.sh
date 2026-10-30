#!/usr/bin/env bash
# herdr-harness — Herdr 위에서 Claude·Codex·AGY(그 밖의 에이전트 포함)를 역할(Skill)과 Git 증빙으로 운영한다.
#
# 원칙: Bash는 한 스텝(검증·전이·Agent 한 턴)을, 판단은 .agents/skills/의 프롬프트를 따르는
# Orchestrator Agent가 맡는다. run은 그 스텝들을 사람 결정이 필요한 지점까지 자동으로 이어 준다.
# 프롬프트로 대신할 수 없는 게이트만 코드에 둔다:
#   증빙(Harness가 AC를 직접 실행·기록) · 교차 검토(다른 Provider) · 사용자 결정(계획·Milestone 승인)
#
# 이 파일은 진입점이다. 기능은 옆 lib/*.sh에 나뉘어 있다. init이 이 파일과 lib/를 프로젝트의
# .harness/bin/으로 복사하므로, 프로젝트는 bash·git·herdr만 있으면 설치 없이 동작한다.
set -Eeuo pipefail
# $( ) 안에서도 set -e를 유지한다. 없으면 $( ) 속 함수가 다시 $( )를 부를 때 안쪽의 거부(die)가
# 빈 값으로 바뀌어 게이트가 통과해 버린다(2.1.0 검토에서 실제로 재현됨). bash 4.4 이상.
shopt -s inherit_errexit

HARNESS_BIN="$(readlink -f "${BASH_SOURCE[0]}")"
HARNESS_HOME="$(dirname "$HARNESS_BIN")"
TEMPLATE_DIR="${HARNESS_TEMPLATE_DIR:-$HARNESS_HOME/templates/project}"

for _lib in core gates agents packet models auto remote status project verify migrate; do
  [[ -f "$HARNESS_HOME/lib/$_lib.sh" ]] || { printf '오류: %s/lib/%s.sh가 없습니다.\n' "$HARNESS_HOME" "$_lib" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$HARNESS_HOME/lib/$_lib.sh"
done
unset _lib

usage() {
  cat <<'EOF'
herdr-harness — Herdr에서 여러 에이전트를 증빙·교차 검토로 운영

프로젝트 (저장소의 harness.sh로):
  init DIR --goal TEXT [--name N] [--profile generic|python-timeseries|network-device]
           [--orchestrator P] [--worker P] [--reviewer P] [--fallback P,P]
           [--approval-mode ask|auto|bypass] [--code-dir DIR] [--review-level cross_provider|cross_model|same_model]
  upgrade DIR...                    프로젝트의 bin·Skill을 이 버전으로 (프로젝트 안에서는 인수 없이)
  migrate DIR [--apply --confirm-user-approval] [--review-level L --reason "사유"]
              [--complete T,T --complete-reason "사유"]
                                    v1 프로젝트를 v2로 이전 (기본은 사전 점검 보고서만, 바꾸지 않음)
  migrate DIR --undo --confirm-user-approval    병합 전 이전 되돌리기 (Git 밖으로 옮긴 파일 포함)
  migrate DIR --rollback                        끊긴 이전(강제 종료 등)을 기록대로 되돌리기

프로젝트 안에서 (.harness/bin/harness.sh, 다른 위치면 -C DIR):
  status | metrics | validate | models [--refresh] | doctor | start
  approve-plan MILESTONE --confirm-user-approval   계획(Task·등급·AC) 승인, draft → ready
  run MILESTONE [--in-pane] [--max-minutes N]      사람 결정이 필요할 때까지 자동 진행
  approve MILESTONE --confirm-user-approval        Milestone 완료 승인 → 보관·태그
  reject TASK --reason "사유" --confirm-user-approval  승인 대기 결과 반려 → 사유를 받아 재작업
  review-level [LEVEL] [--task TASK] [--fallback none|cross_model|same_model] --reason "사유" [--confirm-user-approval]
                                                 검토 수준 예외·자동 하향 허용(낮추기·허용은 사용자 결정)
  provider list | off PROVIDER --reason "사유" | on PROVIDER          쿼터 소진·정책 등으로 못 쓰는 에이전트 표시
  prune MILESTONE                                  보관함을 요약만 남기고 정리 (원본은 git 태그)
  verify TASK | --milestone M | --legacy           AC 명령을 지금 코드에서 다시 실행해 기록 (상태는 바꾸지 않음)

한 단계씩 (run이 내부에서 쓰는 명령):
  transition TASK STATE
  dispatch TASK worker|reviewer [--timeout MS] [--extra-prompt FILE]
  observe TASK [worker|reviewer] [--wait MS]
  close TASK [worker|reviewer] [--force]
  quota-check TASK [ROLE] | quota-check --provider agy
  remote <setup|doctor|mount|unmount|status|run|vcs|shell|bootstrap-key|deps>

P = project.yaml providers.available의 에이전트 (기본 claude | codex | agy)
EOF
}

resolve_root() {  # -C DIR > 이 스크립트가 <root>/.harness/bin/harness.sh면 그 root > 현재 디렉터리부터 위로
  local d
  if [[ -n "$1" ]]; then d="$(realpath -m "$1")"
  elif [[ "$HARNESS_BIN" == */.harness/bin/harness.sh ]]; then d="${HARNESS_BIN%/.harness/bin/harness.sh}"
  else
    d="$PWD"
    while [[ "$d" != / && ! -f "$d/.harness/project.yaml" ]]; do d="$(dirname "$d")"; done
  fi
  [[ -f "$d/.harness/project.yaml" ]] || die "Harness 프로젝트를 찾지 못했습니다 (-C DIR로 지정): $d"
  printf '%s' "$d"
}

main() {
  local dir=""
  if [[ "${1:-}" == -C ]]; then
    [[ -n "${2:-}" ]] || die "-C 뒤에 디렉터리가 필요합니다."
    dir="$2"; shift 2
  fi
  local cmd="${1:-help}"
  (( $# == 0 )) || shift
  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
    init) cmd_init "$@"; return 0 ;;
    upgrade) cmd_upgrade "$@"; return 0 ;;
    migrate) cmd_migrate "$@"; return 0 ;;
    doctor) ROOT="$(resolve_root "$dir" 2>/dev/null)" || ROOT=""; cmd_doctor; return 0 ;;
  esac
  ROOT="$(resolve_root "$dir")"
  case "$cmd" in
    status) cmd_status ;;
    metrics) cmd_metrics ;;
    validate) cmd_validate ;;
    models) cmd_models "$@" ;;
    approve-plan) cmd_approve_plan "$@" ;;
    run) cmd_run "$@" ;;
    approve) cmd_approve "$@" ;;
    reject) cmd_reject "$@" ;;
    review-level) cmd_review_level "$@" ;;
    provider) cmd_provider "$@" ;;
    prune) cmd_prune "$@" ;;
    verify) cmd_verify "$@" ;;
    transition) cmd_transition "$@" ;;
    dispatch) cmd_dispatch "$@" ;;
    observe) cmd_observe "$@" ;;
    close) cmd_close "$@" ;;
    quota-check) cmd_quota_check "$@" ;;
    remote) cmd_remote "$@" ;;
    start) cmd_start ;;
    *) die "알 수 없는 명령: $cmd (help 참고)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi

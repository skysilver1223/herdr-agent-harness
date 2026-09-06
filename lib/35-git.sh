# Part of herdr-harness. Sourced by harness.sh — do not run directly.

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


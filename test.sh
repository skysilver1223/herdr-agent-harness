#!/usr/bin/env bash
# harness 자체 테스트 — 실제 에이전트·네트워크·쿼터를 쓰지 않는다.
# 가짜 herdr(에이전트 대신 각본대로 보고서·리뷰를 쓴다)와 가짜 ssh(원격 명령을 로컬에서 실행)로
# init부터 Milestone 승인·보관, 원격 모드, 업그레이드까지 전체 흐름을 검사한다.
# 모든 파일은 임시 디렉터리에만 만들고 끝나면 지운다. 사용자 입력을 기다리지 않는다.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/harness-test.XXXXXX")"
trap 'chmod -R u+rwx -- "$WORK" 2>/dev/null; rm -rf -- "$WORK"' EXIT   # 권한을 막아 둔 폴더(migrate 검사)도 지운다
PASS=0 FAIL=0 LAST=""

ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
ng() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | tail -n 8 | sed 's/^/      /'; }
NOISE='에서 실패 (exit'   # ERR trap 잡음: 예상한 결과(성공·거부)에서는 절대 나오면 안 된다
expect_ok() {
  local name="$1"; shift
  if LAST="$("$@" 2>&1 </dev/null)"; then
    if [[ "$LAST" == *"$NOISE"* ]]; then ng "$name (오류 위치 잡음)" "$LAST"; else ok "$name"; fi
  else ng "$name" "$LAST"; fi
}
expect_fail() {
  local name="$1" pat="$2"; shift 2
  if LAST="$("$@" 2>&1 </dev/null)"; then ng "$name (성공하면 안 됨)" "$LAST"
  elif [[ -n "$pat" && "$LAST" != *"$pat"* ]]; then ng "$name (메시지에 '$pat' 없음)" "$LAST"
  elif [[ "$LAST" == *"$NOISE"* ]]; then ng "$name (오류 위치 잡음)" "$LAST"
  else ok "$name"; fi
}
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else ng "$name"; fi; }
has() { [[ "$LAST" == *"$1"* ]]; }

# --- 가짜 herdr ---------------------------------------------------------------
FAKE="$WORK/fake"; mkdir -p "$FAKE/bin" "$FAKE/panes" "$FAKE/agents"; echo 0 >"$FAKE/count"
cat >"$FAKE/bin/herdr" <<'EOF'
#!/usr/bin/env bash
F="$FAKE_DIR"
json_agent() { . "$F/agents/$1"; printf '{"result":{"agent":{"name":"%s","pane_id":"%s","agent_status":"%s","revision":%s,"state_change_seq":%s}}}\n' "$1" "$pane" "$status" "$rev" "$seq"; }
case "$1 $2" in
  "pane split")
    n=$(( $(cat "$F/count") + 1 )); echo "$n" >"$F/count"; env=""
    while (( $# )); do [[ "$1" != --env ]] || env="$2"; shift; done
    echo "env=$env" >"$F/panes/p_$n"; printf '{"result":{"pane":{"pane_id":"p_%s"}}}\n' "$n" ;;
  "pane close") [[ -f "$F/panes/$3" ]] && rm -f "$F/panes/$3" ;;
  "pane get") [[ -f "$F/panes/$3" ]] && printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3" ;;
  "pane current") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${FAKE_CURRENT_PANE:-p_0}" ;;
  "pane run") echo "$4" >"$F/pane-run" ;;
  "pane read") echo "${FAKE_SCREEN:-}" ;;
  "agent start")
    name="$3"; shift 3; pane="" kind=""
    while (( $# )); do case "$1" in --pane) pane="$2"; shift ;; --kind) kind="$2"; shift ;; --) shift; break ;; esac; shift; done
    if [[ -n "${FAKE_START_FAIL_ONCE:-}" && ! -f "$F/start-failed" ]]; then touch "$F/start-failed"; echo '{"error":{"code":"invalid_agent_timeout"}}'; exit 1; fi
    printf 'status=idle\nrev=1\nseq=1\npane=%s\nkind=%s\n' "$pane" "$kind" >"$F/agents/$name"; echo "$*" >"$F/agents/$name.args" ;;
  "agent get") [[ -f "$F/agents/$3" ]] || { echo '{"error":"agent_not_found"}'; exit 1; }; json_agent "$3" ;;
  "agent prompt")
    name="$3" text="$4"; [[ -f "$F/agents/$name" ]] || exit 1
    if [[ -n "${FAKE_DROP_FIRST:-}" && ! -f "$F/dropped-$name" ]]; then touch "$F/dropped-$name"; echo agent_prompt_stalled; exit 1; fi
    if [[ -n "${FAKE_VANISH:-}" ]]; then rm -f "$F/agents/$name"; echo '{"result":{"status":"ok"}}'; exit 0; fi   # 에이전트가 곧바로 종료
    [[ "$text" == /status ]] || bash "$FAKE_HOOK" "$text"
    . "$F/agents/$name"; printf 'status=%s\nrev=%s\nseq=%s\npane=%s\nkind=%s\n' "${FAKE_AFTER:-idle}" $((rev + 1)) $((seq + 1)) "$pane" "$kind" >"$F/agents/$name"
    echo '{"result":{"status":"ok"}}' ;;
  "agent read") echo "${FAKE_READ:-작업 완료}" ;;
  "agent wait"|"agent list") echo '{"result":{"agents":[]}}' ;;
  "workspace list") if [[ -f "$F/ws" ]]; then printf '{"result":{"workspaces":[{"label":"%s","workspace_id":"w1"}]}}\n' "$(cat "$F/ws")"; else echo '{"result":{"workspaces":[]}}'; fi ;;
  "workspace create") while (( $# )); do [[ "$1" != --label ]] || echo "$2" >"$F/ws"; shift; done; echo '{"result":{"workspace":{"workspace_id":"w1"}}}' ;;
  "workspace focus") echo "$3" >"$F/ws-focused" ;;
  *) echo "fake herdr: 모르는 호출 $*" >&2; exit 2 ;;
esac
EOF
# 에이전트 대역: Context Packet을 읽고 write_scope 파일을 만들고 보고서·리뷰를 쓴다.
cat >"$FAKE/hook.sh" <<'EOF'
packet="${1##*: }"
field() { sed -n "s/^- $1: //p" "$packet" | head -n 1; }
out="$(field '작성할 파일')"; cwd="$(field '작업 디렉터리')"; ids="$(field '다뤄야 할 AC')"
mkdir -p "$(dirname "$out")"
if grep -q '^# Context Packet — .* / worker' "$packet"; then
  if [[ "${FAKE_WORKER:-good}" == good ]]; then
    for f in $(sed -n 's/^write_scope: \[\(.*\)\]/\1/p' "$packet" | tr -d "',"); do
      [[ "${f##*/}" == *.* ]] || f="$f/from-agent.txt"   # 확장자 없는 항목은 디렉터리로 본다
      mkdir -p "$cwd/$(dirname "$f")"; echo ok >"$cwd/$f"
    done
  fi
  { echo "# Attempt"; echo "결과: SUCCESS"; for i in $ids; do echo "| $i | cmd | 0 | PASS | ok |"; done; } >"$out"
else
  { echo "판정: ${FAKE_VERDICT:-APPROVED}"; echo "대상 Attempt: $(field '검토 대상 Attempt')"; for i in $ids; do echo "| $i | PASS | PASS | OK | OK |"; done; } >"$out"
fi
EOF
# 가짜 ssh: 마지막 인수(원격 명령)를 로컬에서 실행한다.
cat >"$FAKE/bin/ssh" <<'EOF'
#!/usr/bin/env bash
n=0; for a in "$@"; do [[ "$a" != -n ]] || n=1; done
(( n )) || cat >/dev/null   # 실제 ssh처럼 -n이 없으면 호출한 쪽의 표준 입력을 먹는다
cmd="${!#}"; bash -c "$cmd"
EOF
# 가짜 claude: doctor가 보는 --help의 권한 모드 목록만 흉내 낸다 (FAKE_CLAUDE_OLD면 auto를 모르는 옛 CLI)
cat >"$FAKE/bin/claude" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --help ]] || exit 0
if [[ -n "${FAKE_CLAUDE_OLD:-}" ]]; then printf '  --permission-mode <mode>  Permission mode (choices: "acceptEdits",\n      "bypassPermissions", "default", "plan")\n\nCommands:\n  config  "auto" 설정과 무관한 다른 절\n'
else printf '  --permission-mode <mode>  Permission mode (choices: "acceptEdits", "auto",\n      "bypassPermissions", "manual", "plan")\n'; fi
EOF
chmod +x "$FAKE/bin/herdr" "$FAKE/bin/ssh" "$FAKE/bin/claude"

export FAKE_DIR="$FAKE" FAKE_HOOK="$FAKE/hook.sh" PATH="$FAKE/bin:$PATH" HERDR_ENV=1 HARNESS_NO_SLEEP=1 HARNESS_NO_PULL=1 HARNESS_SKIP_MOUNT_CHECK=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"   # 임시 파일은 테스트 폴더 안에만 (남으면 누수 검사가 잡는다)
unset HARNESS_AGENT HERDR_PANE_ID FAKE_CURRENT_PANE
git config --file "$GIT_CONFIG_GLOBAL" user.name tester
git config --file "$GIT_CONFIG_GLOBAL" user.email tester@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

P="$WORK/proj"
R() { bash "$REPO/harness.sh" "$@"; }
H() { bash "$P/.harness/bin/harness.sh" "$@"; }
st() { sed -n 's/^status: //p' "$P/.harness/tasks/$1.yaml"; }
pane_of() { sed -n 's/^pane=//p' "$P/.harness/runtime/$1-$2.meta"; }

write_task() {  # ID MILESTONE SCOPE AC_COMMAND [추가 줄...]
  local id="$1" m="$2" scope="$3" cmd="$4"; shift 4
  cat >"$P/.harness/tasks/$id.yaml" <<EOT
schema_version: '2'
task_id: $id
milestone_id: $m
title: $id 제목
objective: 테스트 목적
intent: .harness/intents/$id-intent.md
status: draft
primary_worker: 'codex'
reviewer: 'agy'
worker_tier: ''
reviewer_tier: ''
dependencies: []
write_scope: [$scope]
acceptance_criteria:
  - criterion_id: AC-001
    statement: 파일 생성
    verified_by:
      type: command
      command: $cmd
  - criterion_id: AC-002
    statement: 사람 확인
    verified_by:
      type: manual-review
      instruction: 눈으로 확인
EOT
  local line; for line in "$@"; do sed -i "s|^${line%%:*}:.*|$line|" "$P/.harness/tasks/$id.yaml"; done
  printf '# Intent %s\n\n## Not\n- 없음\n' "$id" >"$P/.harness/intents/$id-intent.md"
}
commit_all() { git -C "$P" add -A && git -C "$P" commit -qm "$1"; }
setp() { sed -i "s|^  $1:.*|  $1: $2|" "$P/.harness/project.yaml"; }

echo "== 1. 생성 =="
expect_fail "init: 비대화형에서 --goal 없으면 거부" "--goal" R init "$P"
expect_fail "init: Worker=Reviewer 거부 (검토 수준 예외 없이)" "--review-level" R init "$WORK/x" --goal g --worker codex --reviewer codex
expect_ok   "init" R init "$P" --goal "테스트 & 목표 | 특수문자"
check "프로젝트에 bin·lib 복사" test -x "$P/.harness/bin/harness.sh" -a -f "$P/.harness/bin/lib/gates.sh"
check "치환되지 않은 @@ 없음" bash -c "! grep -rl '@@' '$P' --exclude-dir=bin --exclude-dir=.git"
check "목표 특수문자 보존" grep -qF "테스트 & 목표 | 특수문자" "$P/AGENTS.md"
check "Claude Skill 링크" test -L "$P/.claude/skills/harness-work"
check "기준 commit" git -C "$P" rev-parse --verify -q HEAD
expect_fail "init: 비어 있지 않은 경로 거부" "비어 있지 않은" R init "$P" --goal g
expect_ok   "validate (초기)" H validate
expect_ok   "status (기록이 하나도 없는 새 프로젝트)" H status
expect_ok   "metrics (기록 없음)" H metrics
expect_ok   "start (Herdr 안: 중첩 대신 현재 세션에 workspace 생성)" H start
check "프로젝트 이름의 workspace" grep -qx proj "$FAKE/ws"
expect_ok   "start 재실행 (있는 workspace로 이동)" H start
check "기존 workspace로 이동" grep -qx w1 "$FAKE/ws-focused"
expect_ok   "doctor" H doctor
has "[OK]      claude --permission-mode auto" && ok "doctor: claude CLI가 auto 권한 모드를 지원" || ng "doctor claude 확인" "$LAST"
FAKE_CLAUDE_OLD=1 expect_fail "doctor: auto 모드 프로젝트인데 claude CLI가 auto를 모르면 실패" "permission-mode auto를 모릅니다" H doctor
FAKE_CLAUDE_OLD=1 expect_ok "doctor (프로젝트 밖): 옛 claude CLI는 경고만" bash -c "cd '$WORK' && bash '$REPO/harness.sh' doctor"
has "[WARN]    claude CLI가 --permission-mode auto를 모릅니다" && ok "프로젝트 밖 경고" || ng "프로젝트 밖 경고" "$LAST"
setp claude_auto "'--permission-mode acceptEdits'"
FAKE_CLAUDE_OLD=1 expect_ok "doctor: auto 권한 모드를 쓰지 않는 인수면 옛 CLI도 통과" H doctor
setp claude_auto "''"
H provider off claude --reason "시험" >/dev/null
FAKE_CLAUDE_OLD=1 expect_ok "doctor: 사용 불가로 표시한 claude는 따지지 않음" H doctor
H provider on claude >/dev/null

echo "== 2. 계획 승인과 계약 고정 =="
write_task task-001 milestone-001 out.txt "test -f out.txt && grep -q ok out.txt"
write_task task-002 milestone-001 two.txt "test -f two.txt" "dependencies: [task-001]"
commit_all "tasks"
expect_fail "SPEC 미승인이면 계획 승인 거부" "SPEC" H approve-plan milestone-001 --confirm-user-approval
sed -i 's/^- 상태: draft/- 상태: approved/' "$P/.harness/SPEC.md"; commit_all "spec"
expect_fail "확인 플래그 없는 계획 승인 거부" "confirm-user-approval" H approve-plan milestone-001
expect_ok   "계획 승인" H approve-plan milestone-001 --confirm-user-approval
check "draft → ready" test "$(st task-001)" = ready
expect_ok "선행 Task를 기다리는 ready Task는 정상 대기 (validate 통과)" H validate
! has "선행 Task" && ok "선행 대기를 문제로 표시하지 않음" || ng "선행 대기 표시" "$LAST"
write_task task-090 milestone-090 n.txt "true" "dependencies: [task-nope]"
expect_ok "없는 선행 Task: draft면 TODO" H validate
has "[TODO] task-090: 선행 Task가 없습니다 — task-nope" && ok "없는 선행 Task 안내 (draft)" || ng "없는 선행 TODO" "$LAST"
sed -i 's/^status: draft/status: ready/' "$P/.harness/tasks/task-090.yaml"
expect_fail "없는 선행 Task: 계획 뒤면 실패" "선행 Task가 없습니다 — task-nope" H validate
rm -f "$P/.harness/tasks/task-090.yaml" "$P/.harness/intents/task-090-intent.md"
cp "$P/.harness/tasks/task-001.yaml" "$WORK/t1a.bak"
sed -i 's|command: test -f out.txt.*|command: true|' "$P/.harness/tasks/task-001.yaml"
expect_fail "승인 뒤 AC를 바꾸면 착수 거부" "바뀌었습니다" H transition task-001 active
cp "$WORK/t1a.bak" "$P/.harness/tasks/task-001.yaml"
printf 'write_scope:\n  - a\n' >"$WORK/block.yaml"
expect_fail "블록 목록 형식 거부" "블록 목록" bash -c "source '$REPO/lib/core.sh'; ylist '$WORK/block.yaml' write_scope"
printf 'dependencies:\n  # 주석\n\n  - task-001\n' >"$WORK/block2.yaml"
expect_fail "주석 뒤 블록 목록도 거부 (의존성 누락 방지)" "블록 목록" bash -c "source '$REPO/lib/core.sh'; ylist '$WORK/block2.yaml' dependencies"
printf 'dependencies:\n  # 주석만\n\n' >"$WORK/block3.yaml"
expect_ok "키 뒤에 주석만 있으면 빈 목록" bash -c "source '$REPO/lib/core.sh'; ylist '$WORK/block3.yaml' dependencies"
expect_fail "선행 Task 미완료면 착수 거부" "선행" H transition task-002 active
expect_fail "ready에서 worker dispatch 거부" "active" H dispatch task-001 worker

# 선행 Task 검사는 따로 만든 프로젝트에서 (본 흐름의 Task·결정 기록을 건드리지 않게)
P_SAVE="$P"; P="$WORK/projd"
R init "$P" --goal deps >/dev/null; sed -i 's/^- 상태: draft/- 상태: approved/' "$P/.harness/SPEC.md"
write_task task-a milestone-a a.txt "test -f a.txt"
write_task task-b milestone-a b.txt "test -f b.txt" "dependencies: [task-a]"
write_task task-c milestone-c c.txt "true" "dependencies: [task-d]"
write_task task-d milestone-c d.txt "true" "dependencies: [task-c]"
write_task task-e milestone-e e.txt "true" "dependencies: [task-e]"
write_task task-f milestone-f f.txt "true" "dependencies: [TEMPLATE]"
write_task task-g milestone-g g.txt "true" "dependencies: [task-a]"
commit_all "deps"
expect_ok "validate: 계획 전(draft)의 선행 문제는 TODO" H validate
has "[TODO] task-c: 선행 Task가 순환합니다" && has "[TODO] task-e: 자기 자신을 선행 Task로 둠" && has "[TODO] task-f: 선행 Task가 없습니다 — TEMPLATE" && ok "순환·자기 자신·TEMPLATE 선행 안내" || ng "선행 문제 안내" "$LAST"
[[ "$(grep -c 'task-e:' <<<"$LAST")" == 1 ]] && ok "자기 자신 선행은 한 번만 알림" || ng "자기 자신 선행 중복" "$LAST"
expect_fail "순환하는 선행 관계는 계획 승인 거부" "선행 Task가 순환합니다" H approve-plan milestone-c --confirm-user-approval
expect_fail "자기 자신을 선행으로 두면 계획 승인 거부" "자기 자신을 선행 Task로 둠" H approve-plan milestone-e --confirm-user-approval
expect_fail "없는 선행(TEMPLATE)은 계획 승인 거부" "선행 Task가 없습니다 — TEMPLATE" H approve-plan milestone-f --confirm-user-approval
expect_ok "다른 Milestone의 draft를 기다리는 Task도 계획 승인은 된다" H approve-plan milestone-g --confirm-user-approval
expect_ok "validate: 선행이 아직 계획 전(draft)이면 TODO" H validate
has "[TODO] task-g: 선행 Task가 아직 계획 승인 전(draft)입니다 — task-a" && ok "계획 전 선행을 기다림 안내" || ng "draft 선행 안내" "$LAST"
expect_ok "선행 Milestone 계획 승인" H approve-plan milestone-a --confirm-user-approval
expect_ok "validate: 선행을 기다리는 ready는 정상" H validate
sed -i 's/^status: ready/status: active/' "$P/.harness/tasks/task-b.yaml"
expect_fail "선행이 통합 상태가 아닌 active는 실패 (착수 뒤 반려 등)" "선행 Task가 통합 상태가 아닙니다 (착수 뒤 반려 등) — task-a" H validate
git -C "$P" checkout -q -- .harness/tasks/task-b.yaml
P="$P_SAVE"

echo "== 3. 작업 공간 · 증빙 · 교차 검토 · 통합 =="
expect_ok "착수 (worktree 생성)" H transition task-001 active
check "Task 작업 공간과 브랜치" test -d "$P/.harness/worktrees/task-001" -a -n "$(git -C "$P" branch --list hh/task-001)"
cp "$P/.harness/tasks/task-001.yaml" "$WORK/t1.bak"
sed -i 's|^objective:.*|objective: "password: hunter22"|' "$P/.harness/tasks/task-001.yaml"
expect_fail "Secret이 든 지시서는 보내지 않음" "Secret" H dispatch task-001 worker
cp "$WORK/t1.bak" "$P/.harness/tasks/task-001.yaml"
FAKE_WORKER=bad expect_ok "Worker dispatch" H dispatch task-001 worker
has "dispatch_result=settled" && ok "결과 settled" || ng "결과 settled" "$LAST"
args="$(cat "$FAKE"/agents/hh-task-001-*-w1.args)"
[[ "$args" == *"--sandbox workspace-write"* && "$args" == *"--add-dir $P"* ]] && ok "승인 모드 인수 + 워크스페이스 쓰기 허용" || ng "Provider 인수" "$args"
grep -q "env=HARNESS_AGENT=task-001-worker" "$FAKE/panes/$(pane_of task-001 worker)" && ok "Agent Pane에 표식" || ng "Agent Pane 표식"
expect_fail "살아 있는 Agent 재dispatch 거부" "살아 있습니다" H dispatch task-001 worker
expect_fail "AC 실패면 제출 거부" "AC 검증 실패" H transition task-001 submitted
check "실패 증빙 기록" grep -q '^- AC 요약: FAIL' "$P/.harness/attempts/task-001-attempt-1.harness.md"
FAKE_CURRENT_PANE="$(pane_of task-001 worker)" expect_fail "Agent Pane에서 전이 거부" "Agent Pane" H transition task-001 blocked
HARNESS_AGENT=task-001-worker expect_fail "Agent 환경에서 전이 거부" "Agent(task-001-worker)" H transition task-001 blocked
expect_ok "Worker 정리" H close task-001 worker
FAKE_WORKER=good FAKE_DROP_FIRST=1 expect_ok "재작업 dispatch (첫 프롬프트 유실 → 1회 재전송)" H dispatch task-001 worker
check "재전송 기록" grep -q '프롬프트 재전송: yes' "$P/.harness/attempts/task-001-attempt-2.harness.md"
check "지시서에 직전 실패 증빙" grep -q '직전 attempt 1의 Harness AC 증빙' "$P/.harness/runtime/task-001-worker.context.md"
printf '#!/bin/sh\n[ -z "$FAKE_HOOK_FAIL" ] || { echo "hook says no"; exit 1; }\n' >"$P/.git/hooks/pre-commit"; chmod +x "$P/.git/hooks/pre-commit"
FAKE_HOOK_FAIL=1 expect_fail "commit hook 실패면 제출 거부" "commit" H transition task-001 submitted
check "hook 실패는 PASS로 남지 않음" grep -q '^- AC 요약: FAIL (AC는 통과했지만 commit 실패' "$P/.harness/attempts/task-001-attempt-2.harness.md"
expect_ok "제출 (Harness가 AC 실행 → PASS → commit)" H transition task-001 submitted
check "통과 증빙과 검증 commit" grep -q '^- 검증 commit:' "$P/.harness/attempts/task-001-attempt-2.harness.md"
H close task-001 worker >/dev/null
expect_ok "검토 착수" H transition task-001 reviewing
FAKE_VERDICT=CHANGES_REQUESTED expect_ok "Reviewer dispatch (다른 Provider)" H dispatch task-001 reviewer
[[ "$(cat "$FAKE"/agents/hh-task-001-*-r1.args)" == *"--mode accept-edits"* ]] && ok "Reviewer(agy) 인수" || ng "Reviewer 인수"
expect_fail "반려 Review로는 승인 대기 불가" "APPROVED" H transition task-001 awaiting_approval
expect_ok "수정 요청 반영" H transition task-001 changes_requested
H close task-001 reviewer >/dev/null
expect_ok "재착수" bash -c "bash '$P/.harness/bin/harness.sh' transition task-001 ready && bash '$P/.harness/bin/harness.sh' transition task-001 active"
expect_ok "attempt 3 dispatch" H dispatch task-001 worker
check "지시서에 Review 지적" grep -q '최신 Review 1 (판정: CHANGES_REQUESTED)' "$P/.harness/runtime/task-001-worker.context.md"
H transition task-001 submitted >/dev/null; H close task-001 worker >/dev/null; H transition task-001 reviewing >/dev/null
cp "$P/.harness/reviews/task-001-review-1.md" "$WORK/r1.bak"
printf '판정: APPROVED\n대상 Attempt: 3\nAC-001 AC-002\n' >"$P/.harness/reviews/task-001-review-1.md"
expect_fail "다른 attempt용 Review를 고쳐 써도 거부" "dispatch되지 않았습니다" H transition task-001 awaiting_approval
cp "$WORK/r1.bak" "$P/.harness/reviews/task-001-review-1.md"
expect_ok "Reviewer 재검토" H dispatch task-001 reviewer
cp "$P/.harness/tasks/task-001.yaml" "$WORK/t1r.bak"
sed -i 's|command: test -f out.txt.*|command: true|' "$P/.harness/tasks/task-001.yaml"
expect_fail "검토 중 AC를 바꾸면 승인 대기 거부" "바뀌었습니다" H transition task-001 awaiting_approval
cp "$WORK/t1r.bak" "$P/.harness/tasks/task-001.yaml"
cp "$P/.harness/reviews/task-001-review-2.md" "$WORK/r2.bak"; sed -i '/AC-002/d' "$P/.harness/reviews/task-001-review-2.md"
expect_fail "AC 대조가 빠진 Review 거부" "AC-002" H transition task-001 awaiting_approval
cp "$WORK/r2.bak" "$P/.harness/reviews/task-001-review-2.md"
WT="$P/.harness/worktrees/task-001"
git -C "$WT" commit -q --allow-empty -m "검증 뒤 몰래 넣은 commit"
echo bad >"$WT/out.txt"; for i in $(seq 400); do echo junk >"$WT/junk$i.txt"; done; echo dirty >>"$P/AGENTS.md"
expect_fail "본 저장소에 커밋 안 된 변경이면 통합 보류" "통합 보류" H transition task-001 awaiting_approval
expect_fail "통합 보류는 수정 요청 사유가 아님" "" H transition task-001 changes_requested
git -C "$P" checkout -q -- AGENTS.md
expect_ok "승인 대기 (통합 AC → 본 브랜치 fast-forward)" H transition task-001 awaiting_approval
check "검증 뒤 commit·변경(400건)은 버리고 기록" bash -c "grep -q '검증 commit 이후 commit 버림' '$P/.harness/reviews/task-001-review-2.harness.md' && grep -q '검증 commit 이후 변경 버림 (401건)' '$P/.harness/reviews/task-001-review-2.harness.md'"
check "본 브랜치에는 검증된 내용만" bash -c "grep -qx ok '$P/out.txt' && test ! -e '$P/junk1.txt' && ! git -C '$P' log --format=%s | grep -q '몰래'"
check "본 브랜치에 결과 반영" test -f "$P/out.txt"
check "통합 기록 + 작업 공간 정리" bash -c "grep -q '^- 통합: OK' '$P/.harness/reviews/task-001-review-2.harness.md' && test ! -d '$P/.harness/worktrees/task-001'"
check "worktree가 아닌 폴더는 작업 공간으로 인정하지 않음" bash -c "mkdir -p '$WORK/fakewt' && source '$REPO/lib/core.sh' && ! is_task_worktree '$WORK/fakewt' && ! is_task_worktree '$P'"
H close task-001 reviewer >/dev/null

echo "== 4. 자동 진행 · Milestone 승인 · 보관 =="
FAKE_READ="pytest: 429 Too Many Requests 테스트 통과" expect_ok "run (task-002: 착수→구현→증빙→검토→통합, 화면의 429 문구는 무시)" H run milestone-001 --max-minutes 2 --poll 1
has "run_result=milestone_ready" && ok "Milestone 승인 대기 도달" || ng "run 결과" "$LAST"
expect_fail "반려 기록 없이 승인 대기를 되돌릴 수 없음" "반려 기록" H transition task-002 changes_requested
expect_fail "확인 플래그 없는 반려 거부" "confirm-user-approval" H reject task-002 --reason "two.txt 형식을 다시 확인"
expect_ok "사용자 반려" H reject task-002 --reason "two.txt 형식을 다시 확인" --confirm-user-approval
check "반려 → 수정 요청" test "$(st task-002)" = changes_requested
expect_ok "반려 후 자동 재작업 (작업 공간을 본 브랜치 기준으로 다시 만듦)" H run milestone-001 --max-minutes 2 --poll 1
has "run_result=milestone_ready" && ok "재작업 뒤 다시 승인 대기" || ng "반려 후 run" "$LAST"
check "Worker 지시서에 반려 사유" grep -q 'two.txt 형식을 다시 확인' "$P/.harness/runtime/task-002-worker.context.md"
check "Reviewer 지시서에 반려 사유 확인 지시" grep -q '사용자 반려 사유 — 해소됐는지' "$P/.harness/runtime/task-002-reviewer.context.md"
expect_fail "확인 플래그 없는 Milestone 승인 거부" "confirm-user-approval" H approve milestone-001
expect_ok "Milestone 승인" H approve milestone-001 --confirm-user-approval
check "보관함 요약" test -f "$P/.harness/archive/milestone-001/SUMMARY.md"
check "Task 파일 이동" test ! -e "$P/.harness/tasks/task-001.yaml" -a -f "$P/.harness/archive/milestone-001/tasks/task-001.yaml"
check "이력 한 줄" grep -q 'milestone-001' "$P/.harness/HISTORY.md"
check "git 태그" git -C "$P" rev-parse --verify -q refs/tags/milestone-001-approved
check "반려 기록도 보관" test -f "$P/.harness/archive/milestone-001/decisions/task-002-rejection-1.md"
expect_ok "status" H status
has "최근 완료" && has "milestone-001" && ok "status에 이력" || ng "status 이력" "$LAST"
expect_ok "metrics" H metrics
has "Worker" && ok "지표 표" || ng "지표 표" "$LAST"
expect_ok "prune (요약만 남김)" H prune milestone-001
check "원본은 태그로 복원 가능" git -C "$P" cat-file -e "milestone-001-approved:.harness/archive/milestone-001/tasks/task-001.yaml"
check "정리한 보관함의 Task도 보관된 Task로 안다 (글롭 문자는 ID가 아님)" bash -c "source '$REPO/lib/core.sh'; ROOT='$P'; archived_task task-001 && ! archived_task 'task-00?' && ! archived_task codex && ! archived_task Worker && ! archived_task Task"
write_task task-091 milestone-091 q.txt "true" "dependencies: [task-001]"
expect_ok "정리한 보관함의 Task를 선행으로 둔 Task (validate)" H validate
! has "task-091: 선행 Task가 없습니다" && ok "정리된 선행 Task를 오타로 보지 않음" || ng "정리된 선행 Task" "$LAST"
rm -f "$P/.harness/tasks/task-091.yaml" "$P/.harness/intents/task-091-intent.md"

echo "== 5. 병렬 상한 · 범위 충돌 · 등급 · 재작업 상한 · 자동 교체 =="
setp codex_premium "'gpt-test-premium'"
write_task task-003 milestone-002 lib/a.txt "test -f lib/a.txt"
write_task task-004 milestone-002 lib "true"
write_task task-005 milestone-002 c.txt "test -f c.txt" "worker_tier: premium"
commit_all "m2"
expect_ok "milestone-002 계획 승인" H approve-plan milestone-002 --confirm-user-approval
check "계획 승인에 premium 기록" grep -q '^| task-005 | codex | agy | premium |' "$P/.harness/decisions/milestone-002-plan-approval.md"
expect_ok "task-003 착수" H transition task-003 active
expect_fail "write_scope 충돌 거부" "충돌" H transition task-004 active
setp max_parallel_workers 1
expect_fail "동시 Worker 상한 거부" "상한" H transition task-005 active
setp max_parallel_workers 5
sed -i "s|^worker_tier:.*|worker_tier: premium|" "$P/.harness/tasks/task-003.yaml"
expect_fail "승인 안 된 premium 거부" "premium" H dispatch task-003 worker
sed -i "s|^worker_tier:.*|worker_tier: ''|" "$P/.harness/tasks/task-003.yaml"
setp max_rework 0
FAKE_WORKER=bad expect_ok "task-003 attempt 1" H dispatch task-003 worker
H close task-003 worker >/dev/null
expect_fail "재작업 상한 거부" "재작업 상한" H dispatch task-003 worker
setp max_rework 3
setp agent_error "'auto'"
commit_all "settings"
FAKE_START_FAIL_ONCE=1 expect_ok "run (기동 실패 → 규칙대로 자동 교체 → 끝까지)" H run milestone-002 --max-minutes 2 --poll 1
has "run_result=milestone_ready" && ok "milestone-002 승인 대기 도달" || ng "run 결과" "$LAST"
check "자동 인계 문서" grep -q '^- 자동 교체: yes' "$P/.harness/handovers/task-003-handover-1.md"
check "Worker가 예비 Provider로 교체" grep -q "^primary_worker: claude" "$P/.harness/tasks/task-003.yaml"
[[ "$(cat "$FAKE"/agents/hh-task-005-*-w1.args)" == *"--model gpt-test-premium"* ]] && ok "승인된 premium 모델 사용" || ng "premium 모델 인수"
check "task-004는 충돌 해소 뒤 진행" test "$(st task-004)" = awaiting_approval
expect_ok "run --in-pane" H run milestone-002 --in-pane
check "별도 Pane은 Milestone 승인 대기에서만 스스로 닫힘" grep -q "milestone_ready.*herdr pane close" "$FAKE/pane-run"
check "임시 파일이 남지 않음" bash -c "test -z \"\$(find '$P' -name '.harness-tmp.*')\""

echo "== 6. 상태 판정 단위 검사 =="
N() { bash -c 'source "$1/lib/core.sh"; source "$1/lib/agents.sh"; shift; normalize "$@"' _ "$REPO" "$@" 2>/dev/null; }
A='{"agent_status":"idle","revision":3,"state_change_seq":5}'
[[ "$(N 1 x)" == agent_lost ]] && ok "조회 실패 → agent_lost" || ng "agent_lost"
[[ "$(N 0 '{"agent_status":"working"}')" == running ]] && ok "working → running" || ng "running"
[[ "$(N 0 "$A" 0 "" "$A")" == prompt_not_delivered ]] && ok "활동 지표 불변 → prompt_not_delivered" || ng "prompt_not_delivered"
[[ "$(N 0 '{"agent_status":"idle","revision":4,"state_change_seq":6}' 0 "" "$A")" == settled ]] && ok "활동 지표 변화 → settled" || ng "settled"
[[ "$(N 0 '{"agent_status":"idle"}' 1 agent_prompt_stalled)" == stalled ]] && ok "stalled" || ng "stalled"
[[ "$(N 0 '{"agent_status":"weird"}')" == unknown ]] && ok "모르는 상태 → unknown" || ng "unknown"
OLD="$WORK/oldplan"; mkdir -p "$OLD/.harness/tasks" "$OLD/.harness/decisions"
printf 'schema_version: 2\nmodels:\n  codex_premium: x\n' >"$OLD/.harness/project.yaml"
printf 'task_id: task-x\nmilestone_id: m1\nstatus: ready\n' >"$OLD/.harness/tasks/task-x.yaml"
printf '승인: yes\n\n| Task | Worker | Reviewer | Worker 등급 | Reviewer 등급 | AC 지문 |\n|---|---|---|---|---|---|\n| task-x | codex | agy | premium | standard | abc |\n' >"$OLD/.harness/decisions/m1-plan-approval.md"
MA() { bash -c 'for f in core gates models; do source "$1/lib/$f.sh"; done; ROOT="$2"; shift 2; model_approved "$@"' _ "$REPO" "$OLD" "$@" 2>/dev/null; }
MA task-x worker codex premium x && ok "2.0 형식 표: 승인된 premium 등급은 그대로 인정" || ng "2.0 형식 premium"
! MA task-x worker codex direct custom && ok "2.0 형식 표: 직접 지정 모델은 재승인 필요" || ng "2.0 형식 직접 지정"
check "Task ID의 sk- 는 Secret 아님" bash -c "source '$REPO/lib/core.sh'; ! has_secret <<<'task-sk-political-lri-trend'"
check "SPEC 문장 'Password: 8자 이상'은 Secret 아님" bash -c "source '$REPO/lib/core.sh'; ! has_secret <<<'- Password: 8자 이상'"
check "코드 'api_key = os.getenv(...)'는 Secret 아님" bash -c "source '$REPO/lib/core.sh'; ! has_secret <<<'api_key = os.getenv(\"KEY\")'"
for ok_text in 'password: ${DB_PASSWORD}' 'password: <your-password>' 'api_key: Optional[str]' 'token = os.environ["TOKEN"]'; do
  check "Secret 아님: $ok_text" bash -c 'source "$1/lib/core.sh"; ! has_secret <<<"$2"' _ "$REPO" "$ok_text"
done
for sec in "password: hunter22" "password: 'hunter2abc'" "api_key='sk_live_abcdefgh'" 'DB_PASSWORD=P@ssw0rd!23' 'token=abcdefghij;' \
           'DB_PASSWORD=Xk9#mP2$vLq8' '"password": "hunter2abc"' '{"api_key":"sk_live_abcdefghij"}' 'password=`hunter2abcde`'; do
  check "Secret으로 잡음: $sec" bash -c 'source "$1/lib/core.sh"; has_secret <<<"$2"' _ "$REPO" "$sec"
done

echo "== 7. 원격 모드 (가짜 ssh) =="
P2="$WORK/proj2"; RSRC="$WORK/remote-src"; mkdir -p "$RSRC"; touch "$WORK/key"
expect_ok "원격 프로젝트 init" R init "$P2" --goal remote
expect_ok "remote setup (비대화형, 입력 대기 없음)" bash "$P2/.harness/bin/harness.sh" remote setup \
  --host buildhost --user dev --path "$RSRC" --mount "$RSRC" --ssh-key "$WORK/key" --vcs none --no-key
expect_ok "remote run" bash "$P2/.harness/bin/harness.sh" remote run 'echo remote-ok'
has remote-ok && ok "원격 명령 출력" || ng "원격 명령 출력" "$LAST"
LAST="$(printf 'a\nb\nc\n' | while read -r x; do bash "$P2/.harness/bin/harness.sh" remote run "echo got-$x" 2>&1; done)"
has got-a && has got-b && has got-c && ok "반복문 안의 원격 명령이 남은 입력을 먹지 않음 (ssh -n)" || ng "원격 명령 표준 입력" "$LAST"
P_SAVE="$P"; P="$P2"
write_task task-001 milestone-001 r.txt "test -f r.txt"
cat >>"$P/.harness/tasks/task-001.yaml" <<'EOT'
  - criterion_id: AC-003
    statement: 두 번째 명령도 원격에서 실행된다
    verified_by:
      type: command
      command: test -f r.txt && echo second-ac-ran
EOT
sed -i 's/^- 상태: draft/- 상태: approved/' "$P/.harness/SPEC.md"; commit_all "remote tasks"
H approve-plan milestone-001 --confirm-user-approval >/dev/null
expect_ok "원격 모드 착수 (작업 공간 분리 없이 순서대로)" H transition task-001 active
env -u HARNESS_SKIP_MOUNT_CHECK bash "$P/.harness/bin/harness.sh" dispatch task-001 worker >"$WORK/m.out" 2>&1 </dev/null
grep -q '마운트되어 있지 않습니다' "$WORK/m.out" && ok "마운트가 풀린 원격은 dispatch 거부" || ng "마운트 확인" "$(cat "$WORK/m.out")"
expect_ok "원격 모드 dispatch (코드 = 마운트 경로)" H dispatch task-001 worker
expect_ok "원격 모드 제출 (AC를 원격에서 실행)" H transition task-001 submitted
check "AC 실행 위치가 원격" grep -q '실행 위치: 원격' "$P/.harness/attempts/task-001-attempt-1.harness.md"
check "원격에서 검증 명령 여러 개가 모두 실행됨" bash -c "grep -q '^| AC-001 | command | 0 | PASS' '$P/.harness/attempts/task-001-attempt-1.harness.md' && grep -q '^| AC-003 | command | 0 | PASS' '$P/.harness/attempts/task-001-attempt-1.harness.md'"
write_task task-002 milestone-001 r2.txt "test -f r2.txt"
commit_all "remote task-002"
H approve-plan milestone-001 --confirm-user-approval >/dev/null
expect_fail "원격 모드는 통합 전 Task가 있으면 다음 Task 착수 거부" "하나씩" H transition task-002 active
H transition task-001 reviewing >/dev/null; FAKE_VERDICT=CHANGES_REQUESTED H dispatch task-001 reviewer >/dev/null
H transition task-001 changes_requested >/dev/null; H transition task-001 ready >/dev/null
expect_fail "재작업 대기(ready) Task도 자리를 차지" "하나씩" H transition task-002 active
P="$P_SAVE"

echo "== 9. 한 회사만 쓰는 환경 (회사 정책 예외) =="
P3="$WORK/proj3"
expect_ok "claude 단독 init (--review-level cross_model)" R init "$P3" --goal "claude only" --worker claude --reviewer claude --review-level cross_model --fallback claude
check "init의 검토 수준 결정 기록" grep -q '^- 수준: cross_model' "$P3/.harness/decisions/review-level-1.md"
P_SAVE="$P"; P="$P3"
write_task task-001 milestone-001 a.txt "test -f a.txt" "primary_worker: claude" "reviewer: claude"
sed -i 's/^- 상태: draft/- 상태: approved/' "$P/.harness/SPEC.md"; commit_all "p3 tasks"
expect_fail "같은 모델이면 계획 승인 거부 (cross_model)" "검토 수준" H approve-plan milestone-001 --confirm-user-approval
setp claude_standard "'sonnet'"; setp claude_premium "'opus'"
sed -i "s|^reviewer_tier:.*|reviewer_tier: premium|" "$P/.harness/tasks/task-001.yaml"; commit_all "p3 models"
expect_ok "계획 승인 (Worker sonnet / Reviewer opus)" H approve-plan milestone-001 --confirm-user-approval
check "계획 표에 모델·검토 수준" grep -q '| sonnet | opus | cross_model |' "$P/.harness/decisions/milestone-001-plan-approval.md"
expect_ok "착수" H transition task-001 active
FAKE_VANISH=1 FAKE_SCREEN="claude: 로그인이 필요합니다" expect_fail "에이전트가 곧바로 사라짐 → agent_lost" "dispatch_result=agent_lost" H dispatch task-001 worker
has "agent_screen=claude: 로그인이 필요합니다" && ok "사라진 에이전트의 마지막 화면을 보여 줌" || ng "마지막 화면" "$LAST"
check "증빙에 마지막 화면 기록" grep -q '^- 마지막 화면: claude: 로그인이 필요합니다' "$P/.harness/attempts/task-001-attempt-1.harness.md"
expect_ok "사라진 에이전트 정리" H close task-001 worker
FAKE_VANISH=1 expect_fail "Pane 화면이 비어 있어도 agent_lost를 보고 (명령이 죽지 않음)" "dispatch_result=agent_lost" H dispatch task-001 worker
check "빈 화면에서도 dispatch 기록이 남음" grep -q '^- 결과: agent_lost' "$P/.harness/attempts/task-001-attempt-2.harness.md"
expect_ok "다시 정리" H close task-001 worker
expect_ok "run (같은 회사·다른 모델 검토로 끝까지)" H run milestone-001 --max-minutes 2 --poll 1
has "run_result=milestone_ready" && ok "승인 대기 도달" || ng "run 결과" "$LAST"
check "검토 기록에 실제 검토 수준" grep -q '^- 검토 수준: cross_model (필요: cross_model)' "$P/.harness/reviews/task-001-review-1.harness.md"
[[ "$(cat "$FAKE"/agents/hh-task-001-*-r1.args)" == *"--model opus"* && "$(cat "$FAKE"/agents/hh-task-001-*-w3.args)" == *"--model sonnet"* ]] && ok "Worker sonnet / Reviewer opus로 실행" || ng "모델 인수"
[[ "$(cat "$FAKE"/agents/hh-task-001-*-w3.args)" == *"--permission-mode auto"* ]] && ok "claude auto 모드 기본 인수는 --permission-mode auto" || ng "claude auto 인수" "$(cat "$FAKE"/agents/hh-task-001-*-w3.args)"
expect_ok "status" H status
has "같은 회사 검토: task-001" && ok "승인 요청에 같은 회사 검토 표시" || ng "같은 회사 검토 표시" "$LAST"
sed -i "s|^  level:.*|  level: 'same_model'|" "$P/.harness/project.yaml"
expect_fail "결정 기록 없이 손으로 낮춘 검토 수준은 거부" "결정 기록" H validate
sed -i "s|^  level:.*|  level: 'cross_model'|" "$P/.harness/project.yaml"
expect_fail "검토 수준 낮추기는 확인 플래그 필요" "confirm-user-approval" H review-level same_model --reason "모델 하나뿐"
expect_ok "사용자 결정으로 낮추기" H review-level same_model --reason "모델 하나뿐" --confirm-user-approval
check "결정 기록과 설정 반영" bash -c "grep -q '^- 수준: same_model' '$P/.harness/decisions/review-level-2.md' && grep -q \"^  level: 'same_model'\" '$P/.harness/project.yaml'"
expect_ok "높이기는 확인 없이" H review-level cross_model --reason "원복"
HARNESS_AGENT=task-001-worker expect_fail "에이전트는 검토 수준을 못 바꿈" "Agent" H review-level same_model --reason x --confirm-user-approval
sed -i 's/^review:$/review:   # 검토 설정/' "$P/.harness/project.yaml"
expect_ok "섹션 머리에 주석이 있어도 설정을 읽고 씀" H review-level cross_model --reason "주석 섹션 확인"
check "주석 달린 섹션이 중복되지 않음" test "$(grep -c '^review:' "$P/.harness/project.yaml")" = 1
write_task task-002 milestone-002 b.txt "test -f b.txt" "primary_worker: claude" "reviewer: codex"
commit_all "p3 task-002"
expect_ok "Task 단위로 검토 수준 올리기 (확인 불필요)" H review-level cross_provider --task task-002 --reason "중요 Task는 다른 회사 검토"
expect_ok "milestone-002 계획 승인 (claude → codex)" H approve-plan milestone-002 --confirm-user-approval
sed -i '/^review_level:/d; s/^reviewer:.*/reviewer: claude/' "$P/.harness/tasks/task-002.yaml"
expect_fail "review_level 줄을 지워도 결정 기록의 수준이 유지됨" "같은 Provider" H validate
rm -f "$P/.harness/decisions/task-002-review-level-1.md"
expect_fail "결정 기록까지 지워도 계획 승인 때 수준이 유지됨" "같은 Provider" H validate
expect_ok "자동 하향 설정만 바꾸는 프로젝트 기록" H review-level --fallback same_model --reason "설정 변경" --confirm-user-approval
expect_fail "자동 하향 설정 기록으로는 계획 승인 수준이 풀리지 않음" "같은 Provider" H validate
P="$P_SAVE"

echo "== 10. 쿼터 소진: 사용 불가 표시 · 자동 하향 · 모델 직접 지정 =="
setp codex_standard "'gpt-a'"; setp codex_light "'gpt-b'"; setp fallback_level "'cross_model'"
expect_fail "설정 줄만 고친 자동 하향 허용은 무효" "자동 하향 허용" H validate
setp fallback_level "'none'"
expect_fail "자동 하향 허용은 확인 플래그 필요" "confirm-user-approval" H review-level --fallback cross_model --reason "쿼터 소진 대비"
expect_ok "사용자 결정으로 자동 하향 허용" H review-level --fallback cross_model --reason "쿼터 소진 대비" --confirm-user-approval
write_task task-006 milestone-003 six.txt "test -f six.txt"
write_task task-007 milestone-003 seven.txt "test -f seven.txt"
commit_all "m3"
expect_ok "milestone-003 계획 승인" H approve-plan milestone-003 --confirm-user-approval
echo "worker_model: 'gpt-x-custom'" >>"$P/.harness/tasks/task-007.yaml"
expect_ok "task-007 착수" H transition task-007 active
expect_fail "매핑에 없는 모델은 계획 승인 필요" "계획 승인" H dispatch task-007 worker
commit_all "task-007 model"
expect_ok "지정 모델을 포함해 재승인" H approve-plan milestone-003 --confirm-user-approval
expect_ok "지정 모델로 dispatch" H dispatch task-007 worker
[[ "$(cat "$FAKE"/agents/hh-task-007-*-w1.args)" == *"--model gpt-x-custom"* ]] && ok "직접 지정 모델 사용" || ng "직접 지정 모델"
H close task-007 worker >/dev/null
expect_fail "--reason 값이 없으면 거부 (잡음 없이)" "사유" H provider off codex --reason
expect_ok "codex 사용 불가 표시" H provider off codex --reason "쿼터 소진"
expect_ok "task-006 착수" H transition task-006 active
expect_fail "사용 불가 Provider는 dispatch 거부" "사용 불가" H dispatch task-006 worker
expect_ok "codex 다시 사용" H provider on codex
expect_ok "agy·claude 사용 불가 표시" bash -c "bash '$P/.harness/bin/harness.sh' provider off agy --reason '쿼터 소진' && bash '$P/.harness/bin/harness.sh' provider off claude --reason '쿼터 소진'"
expect_ok "provider list" H provider list
has "사용 불가 — 쿼터 소진" && ok "사용 불가 목록" || ng "사용 불가 목록" "$LAST"
expect_ok "run (Reviewer 회사가 없음 → 같은 회사·다른 모델로 자동 하향)" H run milestone-003 --max-minutes 2 --poll 1
has "run_result=milestone_ready" && ok "milestone-003 승인 대기 도달" || ng "run 결과" "$LAST"
check "자동 하향 결정 기록" grep -q '^- 결정: 자동 (review.fallback_level)' "$P/.harness/decisions/task-006-review-level-1.md"
check "Reviewer를 같은 회사·다른 모델 등급으로" bash -c "grep -q '^reviewer: codex' '$P/.harness/tasks/task-006.yaml' && grep -q '^reviewer_tier: light' '$P/.harness/tasks/task-006.yaml'"
check "검토 기록에 실제 수준" grep -q '^- 검토 수준: cross_model (필요: cross_model)' "$P/.harness/reviews/task-006-review-1.harness.md"
expect_ok "agy·claude 다시 사용" bash -c "bash '$P/.harness/bin/harness.sh' provider on agy && bash '$P/.harness/bin/harness.sh' provider on claude"
bash -c 'cd "$1" && source "$2/lib/core.sh" && ROOT="$1" && mark_provider_off agy "쿼터 소진 감지" auto' _ "$P" "$REPO"
expect_ok "자동 표시된 Provider를 사용자가 다시 표시" H provider off agy --reason "쿼터 소진 확인"
check "자동 표시가 사용자 표시로 바뀜" grep -qP '^agy\t[^\t]*\tuser\t' "$P/.harness/runtime/providers.off"
expect_ok "agy 다시 사용" H provider on agy
setp codex_standard "''"
write_task task-008 milestone-004 eight.txt "test -f eight.txt"
commit_all "m4"
expect_ok "milestone-004 계획 승인" H approve-plan milestone-004 --confirm-user-approval
expect_ok "agy·claude 사용 불가" bash -c "bash '$P/.harness/bin/harness.sh' provider off agy --reason x && bash '$P/.harness/bin/harness.sh' provider off claude --reason x"
expect_ok "run (Worker 모델을 모르면 다른 모델 검토를 증명 못 함 → 하향하지 않고 멈춤)" H run milestone-004 --max-minutes 2 --poll 1
has "run_result=user_needed" && ok "사용자 판단 대기로 멈춤" || ng "run 결과" "$LAST"
check "증명 못 하는 하향은 기록도 배정 변경도 하지 않음" bash -c "test ! -e '$P/.harness/decisions/task-008-review-level-1.md' && grep -q '^reviewer: .agy.' '$P/.harness/tasks/task-008.yaml'"
expect_ok "원상 복구" bash -c "bash '$P/.harness/bin/harness.sh' provider on agy && bash '$P/.harness/bin/harness.sh' provider on claude"
setp codex_standard "'gpt-a'"
write_task task-009 milestone-005 nine.txt "test -f nine.txt" "reviewer: codex"
commit_all "m5"
setp level "'same_model'"
expect_fail "손으로 낮춘 프로젝트 수준으로는 같은 회사 계획을 승인할 수 없음 (안쪽 거부도 전파)" "결정 기록" H approve-plan milestone-005 --confirm-user-approval
check "실패한 계획 승인은 표를 남기지 않음" test ! -e "$P/.harness/decisions/milestone-005-plan-approval.md"
expect_fail "손으로 낮춘 상태에서도 Task 수준은 확인 없이 못 낮춤" "confirm-user-approval" H review-level same_model --task task-009 --reason x
expect_ok "review-level로 손으로 고친 줄 바로잡기 (결정 기록 기준)" H review-level cross_provider --reason "손으로 고친 줄 원복"
check "설정 줄이 결정 기록대로 돌아옴" grep -q "^  level: 'cross_provider'" "$P/.harness/project.yaml"
rm -f "$P/.harness/tasks/task-009.yaml" "$P/.harness/intents/task-009-intent.md"; commit_all "m5 정리"
write_task task-003-1 milestone-009 z.txt "true"
printf 'note\n' >"$P/.harness/decisions/task-003-1-note.md"; commit_all "task-003-1"
expect_ok "승인 대기 Task 재검증 (본 저장소에서, 상태는 그대로)" H verify task-003
check "재검증 기록과 상태 유지" bash -c "grep -q '^- 재검증 요약: PASS' '$P/.harness/verifications/task-003-verify-1.md' && grep -q '^status: awaiting_approval' '$P/.harness/tasks/task-003.yaml'"
expect_fail "형식적 명령(true)뿐인 Task는 재검증하지 않음" "실행해 확인하는 command AC가 없습니다" H verify task-004
sed -i '/^- 검토 수준:/d' "$P/.harness/reviews/task-004-review-1.harness.md"
expect_ok "2.0 리뷰(검토 수준 줄 없음)도 기록으로 계산해 Milestone 승인" H approve milestone-002 --confirm-user-approval
check "요약에 계산된 검토 수준" grep -q '^| task-004 |.*| cross_provider |$' "$P/.harness/archive/milestone-002/SUMMARY.md"
check "재검증 기록도 Milestone과 함께 보관" bash -c "test -f '$P/.harness/archive/milestone-002/verifications/task-003-verify-1.md' && test ! -e '$P/.harness/verifications/task-003-verify-1.md'"
check "ID가 더 긴 다른 Task(task-003-1)의 기록은 함께 보관하지 않음" bash -c "test -f '$P/.harness/intents/task-003-1-intent.md' && test -f '$P/.harness/decisions/task-003-1-note.md' && test -f '$P/.harness/archive/milestone-002/intents/task-003-intent.md'"
rm -f "$P/.harness/tasks/task-003-1.yaml" "$P/.harness/intents/task-003-1-intent.md" "$P/.harness/decisions/task-003-1-note.md"; commit_all "task-003-1 정리"

echo "== 8. 업그레이드 =="
V="$(sed -n 's/^HARNESS_VERSION="\(.*\)"/\1/p' "$REPO/lib/core.sh")"
sed -i 's/^HARNESS_VERSION=.*/HARNESS_VERSION="2.2.0"/' "$P/.harness/bin/lib/core.sh"; commit_all "옛 bin 흉내"
expect_ok "저장소에서 업그레이드" R upgrade "$P"
has "2.2.0 → $V" && ok "버전 표시" || ng "버전 표시" "$LAST"
has "--permission-mode auto(Claude Code auto 모드)로 바뀌었습니다" && ok "업그레이드: claude auto 기본 인수 변경 안내" || ng "업그레이드 안내" "$LAST"
commit_all "upgrade" 2>/dev/null || true
echo "# local edit" >>"$P/.agents/skills/harness-work/SKILL.md"
expect_fail "로컬 수정이 있으면 덮어쓰지 않음" "커밋되지 않은 변경" H upgrade
git -C "$P" checkout -q -- .agents/skills/harness-work/SKILL.md
expect_ok "프로젝트 안에서 업그레이드 (harness_source)" H upgrade

echo "== 11. v1 이전(migrate) · 재검증(verify) =="
# 실제 v1 생성기 형식(policies/·evidence/·STATE.md·waves/·.agents/roles/)을 따른 견본 프로젝트.
V1="$WORK/v1proj"; RS1="$WORK/v1-remote-src"
mkdir -p "$V1" "$RS1"
w() { mkdir -p "$(dirname "$V1/$1")"; cat >"$V1/$1"; }
v1_task() {  # ID STATUS MILESTONE WORKER REVIEWER — 나머지 필드(목록·AC)는 표준 입력
  { printf "schema_version: '1.0'\ntask_id: %s\nmilestone_id: %s\ntitle: \"%s 제목\"\nobjective: 목적\n" "$1" "$3" "$1"
    printf "intent: .harness/intents/%s-intent.md\nstatus: %s\nprimary_worker: %s\nreviewer: %s\nfallback_chain: [claude, agy]\n" "$1" "$2" "$4" "$5"
    cat; } | w ".harness/tasks/$1.yaml"
  printf '# Intent %s\n' "$1" | w ".harness/intents/$1-intent.md"
}
ac() {  # ID command|manual-review 값
  if [[ "$2" == command ]]; then printf '  - criterion_id: %s\n    statement: s\n    verified_by:\n      type: command\n      command: %s\n' "$1" "$3"
  else printf '  - criterion_id: %s\n    statement: s\n    verified_by:\n      type: manual-review\n      instruction: %s\n' "$1" "$3"; fi
}
v1_checks() {  # ID ATTEMPT AC:result...
  local id="$1" n="$2" c; shift 2
  { printf "task: '%s'\nattempt: %s\nrunner: 'remote'\nchecks:\n" "$id" "$n"
    for c in "$@"; do printf "  - criterion_id: '%s'\n    command: 'x'\n    exit_code: 0\n    result: '%s'\n    output_tail: ''\n" "${c%%:*}" "${c#*:}"; done
    printf 'summary:\n  total: %s\n' "$#"; } | w ".harness/evidence/$id-attempt-$n-checks.yaml"
}
w .harness/project.yaml <<'EOT'
schema_version: '1.0'
project:
  name: 'legacy'
  goal: 'v1 견본 프로젝트'
  profile: 'network-device'

mode:
  type: agent_driven
  unattended_execution: false

providers:
  orchestrator: 'claude'
  primary_worker: 'codex'
  reviewer: 'agy'
  fallback_chain: [claude,agy]

limits:
  max_active_tasks: 5
  max_parallel_workers: 2
  max_primary_workers_per_task: 1
EOT
w .harness/policies/agent-policy.yaml <<'EOT'
schema_version: '1.0'
agent_policy:
  approval_mode: 'bypass'
  claude_auto: '--permission-mode acceptEdits'
  claude_bypass: '--permission-mode bypassPermissions'
  codex_auto: '--ask-for-approval never --sandbox workspace-write --config sandbox_workspace_write.network_access=true'
  codex_bypass: '--dangerously-bypass-approvals-and-sandbox'
  agy_auto: '--mode accept-edits'
  agy_bypass: '--dangerously-skip-permissions'
  worker_default_tier: ''
  claude_models: 'sonnet opus fable'
  claude_default_model: 'sonnet'
  claude_premium_models: 'opus fable'
EOT
printf 'execution:\n  acceptance_check_timeout_seconds: 300\n' | w .harness/policies/project-policy.yaml
printf 'quota_policy:\n  automatic_failover: false\n  low_warning_threshold_pct: 30\n' | w .harness/policies/quota-policy.yaml
printf 'loop_policy:\n  enabled: false\n' | w .harness/policies/loop-policy.yaml
printf 'review:\n  provider_must_differ_from_worker: true\n' | w .harness/policies/review-policy.yaml
w .harness/policies/remote.yaml <<EOT
schema_version: '1.0'
remote:
  enabled: true
  host: 'buildhost'
  user: 'dev'
  path: '$RS1'
  mount_path: '$V1/remote'
  ssh_key: '$WORK/key'
  # 사용자 메모: 이 주석은 이전 뒤에도 그대로 남아야 한다
  vcs: 'none'
EOT
printf '# Project State\n' | w .harness/STATE.md
printf "wave_id: wave-001\n" | w .harness/waves/wave-001.yaml
printf "profile_id: generic\n" | w .harness/profiles/generic.yaml
printf '# Archive\n' | w .harness/archive/README.md
printf '# Evidence\n' | w .harness/evidence/README.md
printf 'ts\tevent\n' | w .harness/evidence/events.tsv
printf '# Specification\n\n## 1. 핵심 목표\n\n견본\n\n## 7. 사용자 승인\n\n- 상태: approved\n' | w .harness/SPEC.md
printf '# Milestones\n\n| ID | 목표 |\n|---|---|\n| milestone-001 | 첫 |\n' | w .harness/MILESTONES.md
printf '# Reference Inventory\n' | w .harness/references/inventory.md
printf "schema_version: '1.0'\ntask_id: task-000\n" | w .harness/tasks/TEMPLATE.yaml
{ printf 'write_scope:\n  - "a.txt"\n  - later.txt\ndependencies: []\nacceptance_criteria:\n'
  ac AC-001 command "test -f a.txt"; ac AC-002 command "grep -q ok a.txt"; ac AC-003 command "test -f later.txt"; } | v1_task task-001 completed milestone-001 codex agy
sed -i 's/^title: .*/title: "task-001 제목 | 파이프"/' "$V1/.harness/tasks/task-001.yaml"   # 요약 표에서 칸이 밀리지 않아야 한다
{ printf 'write_scope: [b.txt]\nacceptance_criteria:\n'; ac AC-001 command "test -f b.txt"; } | v1_task task-002 completed milestone-001 codex agy
{ printf 'write_scope: [c.txt]\nacceptance_criteria:\n'; ac AC-001 manual-review "눈으로"; ac AC-002 command true; } | v1_task task-003 completed milestone-001 claude agy
{ printf 'write_scope: [d.txt]\nacceptance_criteria:\n'; ac AC-001 command "test -f d.txt"; ac AC-002 command "test -f d2.txt"; } | v1_task task-004 submitted milestone-001 claude claude
{ printf 'write_scope:\n  - "e.txt"\ndependencies:\n  - task-004\ninputs:\n  references:\n    - ".harness/decisions/task-001-approval.md"\nacceptance_criteria:\n'; ac AC-001 command "test -f e.txt"; } | v1_task task-005 submitted milestone-002 claude claude
{ printf "write_scope:\n  - \"it's.txt\"   # 따옴표 든 항목\n  - 'f.txt'\ndependencies: [task-099]\nacceptance_criteria:\n"; ac AC-001 command true; } | v1_task task-006 changes_requested milestone-002 claude codex
{ printf 'write_scope: [g.txt]\nacceptance_criteria:\n'; ac AC-001 manual-review "눈으로"; } | v1_task task-007 draft milestone-002 claude agy
printf "task_id: task-008\nstatus: draft\n" | w .harness/superseded/task-008.yaml
mkdir -p "$V1/.harness/planned"
v1_checks task-001 1 AC-001:pass AC-002:pass AC-003:pass
v1_checks task-001 2 AC-001:pass          # v1 원격 결함: 첫 AC만 실행된 기록
v1_checks task-002 1 AC-001:pass
v1_checks task-004 1 AC-001:pass
for f in attempts/README.md attempts/TEMPLATE.md attempts/task-001-attempt-1.md attempts/task-001-attempt-2.md attempts/task-004-attempt-1.md \
         attempts/task-005-attempt-1.md attempts/task-006-attempt-1.md attempts/task-008-attempt-1.md reviews/README.md \
         reviews/task-001-review-1.md reviews/task-006-review-1.md evidence/raw/task-001-worker-attempt-2.md evidence/raw/task-005-worker-attempt-1.md \
         handovers/README.md handovers/task-006-handover-1.md handovers/task-099-handover-1.md decisions/README.md decisions/TEMPLATE.md \
         decisions/task-001-approval.md decisions/task-006-decisions-01.md decisions/task-008-recontract-01.md decisions/provider-claude-only-01.md \
         intents/README.md intents/TEMPLATE.md intents/task-004-extra-prompt.md intents/task-008-intent.md intents/notes.md user-notes.md \
         "decisions/task-001-메모 공백.md" decisions/milestone-001-approval.md reviews/old-review-1.md; do
  printf '%s 원문\n' "$f" | w ".harness/$f"
done
printf 'worker role\n' | w .agents/roles/worker.agent.md
printf -- '---\nname: harness-work\n---\nv1 work skill\n' | w .agents/skills/harness-work/SKILL.md
printf -- '---\nname: harness-plan\n---\nv1 plan skill\n' | w .agents/skills/harness-plan/SKILL.md
printf -- '---\nname: my-skill\n---\n사용자 Skill\n' | w .agents/skills/my-skill/SKILL.md
mkdir -p "$V1/.claude/skills"; ln -s ../../.agents/skills/harness-work "$V1/.claude/skills/harness-work"; ln -s ../../.agents/skills/my-skill "$V1/.claude/skills/my-skill"
printf '{}\n' | w .claude/settings.local.json
printf '# 메모\n\n- 검토: .harness/reviews/task-001-review-1.md\n- 시도: .harness/attempts/task-005-attempt-1.md\n- 상태: .harness/STATE.md\n- 대체: .harness/attempts/task-008-attempt-1.md\n- 메모: .harness/decisions/task-001-메모 공백.md\n- 옛 리뷰: .harness/reviews/old-review-1.md\n' | w docs/notes.md
printf '# 시작 방법\n\nherdr-harness start .\n' | w HARNESS_START.md
printf '# Agent Instructions: legacy\n\n반드시 .harness/STATE.md와 역할 문서를 읽는다.\n' | w AGENTS.md
ln -s AGENTS.md "$V1/CLAUDE.md"   # 흔한 관례: CLAUDE.md → AGENTS.md (링크는 따라가 고치지 않는다)
printf '# Antigravity Entry\n\n`.agents/roles/*.agent.md`를 읽는다.' | w GEMINI.md   # 마지막 줄바꿈 없음
printf '.env\n.harness/runtime/\n.harness/evidence/raw/\n.harness/worktrees/\n.harness/remote-mount/\n.claude/settings.local.json\n\n/remote/\n' | w .gitignore
printf 'task_id=task-004\nrole=worker\nagent_name=hh-task-004-w-1\npane_id=p_900\n' | w .harness/runtime/task-004-worker.meta
printf 'closed\n' | w .harness/runtime/task-004-worker.closed
printf 'task_id=task-005\nrole=worker\nagent_name=hh-task-005-w-1\npane_id=p_901\n' | w .harness/runtime/task-005-worker.meta
printf 'packet\n' | w .harness/runtime/task-005-context-worker.md
for d in remote .harness/remote-mount .harness/worktrees/wt1 .harness/runtime/locked; do printf 'sentinel %s\n' "$d" | w "$d/sentinel"; done
printf 'ok\n' >"$RS1/a.txt"; touch "$RS1/b.txt" "$RS1/d.txt" "$RS1/d2.txt"
git -C "$V1" init -q && git -C "$V1" add -A && git -C "$V1" commit -qm "v1 기준선"
git -C "$V1" config grep.lineNumber true; git -C "$V1" config core.quotePath true   # 출력 형식을 바꾸는 사용자 설정
touch "$V1/scratch.txt"   # 이전과 무관한 미추적 파일: 그대로 남고 commit에 들어가지 않아야 한다
PROT=(remote .harness/remote-mount .harness/worktrees/wt1 .harness/runtime/locked)
lock()   { local d; for d in "${PROT[@]}"; do chmod 000 "$V1/$d"; done; }   # 들어가려 하면 실패하도록 막는다
unlock() { local d; for d in "${PROT[@]}"; do chmod 755 "$V1/$d"; done; }
snap() {  # 파일 내용·링크·폴더·Git 상태 (.git과 막아 둔 폴더 안은 제외)
  ( cd "$V1" || exit 1
    local -a pr=(-path ./.git -o -path ./remote -o -path ./.harness/remote-mount -o -path ./.harness/worktrees/wt1 -o -path ./.harness/runtime/locked)
    find . \( "${pr[@]}" \) -prune -o -type f -print0 | sort -z | xargs -0 sha256sum
    find . \( "${pr[@]}" \) -prune -o -type l -printf '%p -> %l\n' | sort
    find . \( "${pr[@]}" \) -prune -o -type d -print | sort
    git rev-parse HEAD; git branch --format='%(refname:short)'; git tag; git status --porcelain --ignored )
}
lock
snap >"$WORK/s0"
MIG=(--review-level cross_model --reason "회사 정책: claude만")

expect_fail "사전 점검: 같은 회사 Task가 있으면 검토 수준 결정을 요구" "--review-level cross_model" R migrate "$V1"
has "task-001 | milestone-001 | completed | 보관 → archive/v1-milestone-001/" && ok "보고서: 완료 Task는 보관" || ng "보고서: 완료 Task" "$LAST"
expect_ok "사전 점검 (검토 수준 결정 포함)" R migrate "$V1" "${MIG[@]}"
has "적용할 수 있습니다" && has "| 부분 | 마지막 실행(attempt 2): command 3개 중 1개 통과, 미실행 AC-002 AC-003" && ok "보고서: v1 원격 결함 기록은 부분 증빙" || ng "보고서: 증빙 등급" "$LAST"
has "| task-002 |" && has "| 완전 |" && has "| 사람 확인만 | 실행해 확인하는 command AC 없음 (형식적 명령 AC-002은 증빙이 아님)" && ok "보고서: 완전·사람 확인 등급" || ng "보고서: 등급" "$LAST"
has "draft — v2에서 다시 증빙 (완료 인정 안 함)" && has "이전과 무관한 미추적" && has "codex_auto" && ok "보고서: 제출 Task는 draft, 미추적 파일 안내, v1 인수 유지" || ng "보고서: 처리" "$LAST"
snap >"$WORK/s1"
cmp -s "$WORK/s0" "$WORK/s1" && ok "사전 점검은 아무것도 바꾸지 않음" || ng "사전 점검이 무언가를 바꿈" "$(diff "$WORK/s0" "$WORK/s1" | head)"
echo x >>"$V1/AGENTS.md"
expect_fail "커밋되지 않은 추적 파일 변경이 있으면 차단" "커밋되지 않은 변경 1개" R migrate "$V1" "${MIG[@]}"
git -C "$V1" checkout -q -- AGENTS.md
touch "$V1/.harness/intents/new.md"
expect_fail "Harness 경로의 미추적 파일은 차단" "Harness 경로에 커밋되지 않은 새 파일" R migrate "$V1" "${MIG[@]}"
rm -f "$V1/.harness/intents/new.md"
printf 'status=idle\nrev=1\nseq=1\npane=p_901\nkind=claude\n' >"$FAKE/agents/hh-task-005-w-1"
expect_fail "v1 Agent가 Herdr에 남아 있으면 차단" "hh-task-005-w-1" R migrate "$V1" "${MIG[@]}"
rm -f "$FAKE/agents/hh-task-005-w-1"
expect_fail "완료 인정은 제출·검토 중 Task만" "완료 인정(--complete)은" R migrate "$V1" "${MIG[@]}" --complete task-006 --complete-reason x
expect_fail "완료 인정에는 사유가 필요" "--complete-reason" R migrate "$V1" "${MIG[@]}" --complete task-004
expect_fail "적용은 사용자 확인 필요" "confirm-user-approval" R migrate "$V1" "${MIG[@]}" --apply
chmod 000 "$V1/.harness/waves"
expect_fail "읽을 수 없는 폴더가 있으면 차단 (빠짐없이 옮길 수 없음)" "읽을 수 없는" R migrate "$V1" "${MIG[@]}"
chmod 755 "$V1/.harness/waves"
expect_fail "v2 프로젝트는 이전하지 않음" "이미 v2" R migrate "$P"
{ printf 'write_scope: [z.txt]\nacceptance_criteria:\n'; ac AC-001 command "test -f z.txt"; } | v1_task task-010 draft milestone-002 claude agy
printf '.harness/tasks/task-010.yaml\n.harness/intents/task-010-intent.md\n' >>"$V1/.git/info/exclude"
expect_fail "Git이 추적하지 않는 열린 Task는 제자리에서 바꾸지 않음 (실패 때 되돌릴 수 없다)" "Git이 추적하지 않는 파일은 제자리에서" R migrate "$V1" "${MIG[@]}"
rm -f "$V1/.harness/tasks/task-010.yaml" "$V1/.harness/intents/task-010-intent.md"; sed -i '/task-010/d' "$V1/.git/info/exclude"
sed -i "s/^  approval_mode: 'bypass'/  approval_mode: 'auto'/; /^  agy_auto: /d" "$V1/.harness/policies/agent-policy.yaml"   # agy 인수 키가 없는 v1
expect_fail "사전 점검: 실제로 바뀌는 Provider 인수를 보고서에 밝힘 (수정 중이라 차단)" "커밋되지 않은 변경" R migrate "$V1" "${MIG[@]}"
has "claude: v1 기본값 --permission-mode acceptEdits → v2 기본값 --permission-mode auto" && has "agy: v1에서 인수 없음(확인창) → v2 내장 기본값 --mode accept-edits" && has "agy_auto: v1에서 인수 없이 확인창으로" && ok "auto 모드 인수 변화·인수 없던 Provider 안내" || ng "인수 변화 보고" "$LAST"
sed -i "/^  approval_mode: /d" "$V1/.harness/policies/agent-policy.yaml"
expect_fail "사전 점검: v1에 승인 모드가 없으면 ask로 (v1 동작 그대로)" "커밋되지 않은 변경" R migrate "$V1" "${MIG[@]}"
has "| 도구 승인 모드 | ask | ask |" && ok "승인 모드 없음 → ask" || ng "승인 모드 기본값" "$LAST"
git -C "$V1" checkout -q -- .harness/policies/agent-policy.yaml
git -C "$V1" add -f .harness/evidence/raw/task-005-worker-attempt-1.md && git -C "$V1" commit -qm "원문 로그 하나를 강제로 추적"
expect_fail "Git이 추적하는 v1 원문 로그는 미리 차단 (보관 위치는 Git 밖)" "Git이 추적하는 v1 원문 로그" R migrate "$V1" "${MIG[@]}"
git -C "$V1" reset -q HEAD~1   # --mixed: 추적만 풀고 파일은 남긴다 (다시 무시 목록 대상)
: >"$V1/.git/harness-migrate.journal"
expect_ok "빈 복구 기록은 --rollback이 정리" R migrate "$V1" --rollback
check "빈 기록 정리" test ! -e "$V1/.git/harness-migrate.journal"
echo 'archive/' >>"$V1/.git/info/exclude"
expect_fail ".gitignore 규칙에 걸려 Git에서 빠질 기록은 미리 차단" "규칙에 걸려 Git에서 빠집니다" R migrate "$V1" "${MIG[@]}"
sed -i '/^archive\/$/d' "$V1/.git/info/exclude"
HOOK="$V1/.git/hooks/pre-commit"
printf '#!/bin/sh\necho hook-edit >>docs/notes.md\nexit 1\n' >"$HOOK"; chmod +x "$HOOK"
expect_fail "마지막 commit 실패 → 자동 원상복구" "commit 실패" R migrate "$V1" "${MIG[@]}" --complete task-004 --complete-reason "D-9" --apply --confirm-user-approval
has "원상복구 완료" && ok "원상복구 메시지" || ng "원상복구 메시지" "$LAST"
check "되돌리기는 이전이 손댄 경로만 (저장소의 다른 파일 수정은 남김)" grep -q hook-edit "$V1/docs/notes.md"
git -C "$V1" checkout -q -- docs/notes.md
snap >"$WORK/s2"
cmp -s "$WORK/s0" "$WORK/s2" && ok "원상복구 뒤 파일·폴더·링크·Git 상태가 시작과 같음 (Git 밖 파일 포함)" || ng "원상복구가 불완전" "$(diff "$WORK/s0" "$WORK/s2" | head -n 20)"
check "복구 기록 정리" test ! -e "$V1/.git/harness-migrate.journal"
printf '#!/bin/sh\nf=.harness/archive/v1/waves/wave-001.yaml\n[ -f "$f" ] && echo "# reformatted" >>"$f" && git add "$f"\nexit 0\n' >"$HOOK"
MSGHOOK="$V1/.git/hooks/prepare-commit-msg"   # commit 제목 앞에 일감 번호를 붙이는 흔한 hook
printf '#!/bin/sh\nsed -i "1s/^/[PROJ-1] /" "$1"\n' >"$MSGHOOK"; chmod +x "$MSGHOOK"
expect_fail "commit hook이 내용을 바꾸면 원상복구 (해시 대조와 달라진다)" "commit hook이 commit 내용을 바꿨습니다" R migrate "$V1" "${MIG[@]}" --complete task-004 --complete-reason "D-9" --apply --confirm-user-approval
snap >"$WORK/s3"
cmp -s "$WORK/s0" "$WORK/s3" && ok "hook이 바꾼 내용까지 되돌림 (commit 제목이 바뀌어도 이전 commit을 알아봄)" || ng "hook 뒤 원상복구" "$(diff "$WORK/s0" "$WORK/s3" | head -n 20)"
rm -f "$MSGHOOK"
# 강제 종료: hook에서 맨 위 migrate 프로세스만 SIGKILL (그 프로세스는 commit을 기다리는 중이라 trap을 돌릴 틈이 없다)
cat >"$HOOK" <<'EOT'
#!/bin/sh
# 조상 프로세스를 /proc로 따라 올라가, 바로 위의 migrate 프로세스 묶음 중 가장 바깥 것만 죽인다.
# 묶음 위에서 멈춘다: 바깥 셸의 명령 줄에 같은 글자가 있어도 건드리지 않는다. 찾은 경로는 진단용으로 남긴다.
p=$PPID; top=""; walk=""
while [ -n "$p" ] && [ "$p" -gt 1 ]; do
  c=$(tr '\000' ' ' <"/proc/$p/cmdline" 2>/dev/null)
  walk="$walk $p[$(printf '%s' "$c" | cut -c1-50)]"
  case "$c" in
    *"/harness.sh migrate "*) top=$p ;;
    *) [ -z "$top" ] || break ;;
  esac
  p=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$p/status" 2>/dev/null)
done
echo "top=$top walk=$walk" >>"$HOOKLOG"
[ -z "$top" ] || kill -9 "$top"
exit 1
EOT
cp "$HOOK" "$HOOK.kill"
export HOOKLOG="$WORK/hook.log"
rc=0; R migrate "$V1" "${MIG[@]}" --complete task-004 --complete-reason "D-9" --apply --confirm-user-approval >"$WORK/crash.out" 2>&1 </dev/null || rc=$?
(( rc == 137 )) && ok "이전 도중 강제 종료 (되돌릴 기회 없이 끊김)" || ng "강제 종료 재현 (rc=$rc)" "$(tail -n 3 "$WORK/crash.out"; tail -n 1 "$HOOKLOG" 2>/dev/null)"
check "끊긴 이전: 복구 기록과 이전 브랜치가 남음" bash -c "test -f '$V1/.git/harness-migrate.journal' && [[ \$(git -C '$V1' branch --show-current) == harness-v2-migration ]]"
expect_fail "끊긴 기록이 있으면 다른 실행은 되돌리기를 안내" "--rollback" R migrate "$V1" "${MIG[@]}"
rm -f "$HOOK"
check "v2 validate도 끊긴 이전을 알림" bash -c "! bash '$V1/.harness/bin/harness.sh' validate >/dev/null 2>&1; bash '$V1/.harness/bin/harness.sh' validate 2>&1 | grep -q '끝나지 않은 v1 이전'"
touch "$V1/.git/index.lock" "$V1/.harness/tasks/.harness-tmp.left"   # 다른 git 작업이 잠금을 쥔 상태, 끊긴 실행이 남긴 임시 파일
expect_fail "잠금 때문에 Git 되돌리기가 끝나지 않으면 기록을 남기고 안내" "잠금이 풀린 뒤 다시" R migrate "$V1" --rollback
check "실패한 되돌리기는 기록을 남김" test -f "$V1/.git/harness-migrate.journal"
rm -f "$V1/.git/index.lock"
expect_ok "다시 --rollback (여러 번 실행해도 원본을 지우지 않음)" R migrate "$V1" --rollback
snap >"$WORK/s4"
cmp -s "$WORK/s0" "$WORK/s4" && ok "--rollback 뒤 시작 상태와 같음 (끊긴 실행의 임시 파일도 정리)" || ng "--rollback 불완전" "$(diff "$WORK/s0" "$WORK/s4" | head -n 20)"
# B: commit 뒤 끊겨 기록이 남은 채 이전 브랜치에 사용자 작업이 쌓인 경우
sed 's/^exit 1$/exit 0/' "$HOOK.kill" >"$V1/.git/hooks/post-commit"; chmod +x "$V1/.git/hooks/post-commit"
rc=0; R migrate "$V1" "${MIG[@]}" --complete task-004 --complete-reason "D-9" --apply --confirm-user-approval >"$WORK/crash.out" 2>&1 </dev/null || rc=$?
rm -f "$V1/.git/hooks/post-commit"
(( rc == 137 )) || ng "commit 직후 강제 종료 재현 (rc=$rc)" "$(tail -n 3 "$WORK/crash.out"; tail -n 1 "$HOOKLOG" 2>/dev/null)"
check "commit 직후 강제 종료: 기록과 이전 commit이 남음" bash -c "(( $rc == 137 )) && test -f '$V1/.git/harness-migrate.journal' && [[ \$(git -C '$V1' log -1 --format=%s) == 'harness: v1 → v2 이전'* ]]"
git -C "$V1" commit --allow-empty -qm "사용자 작업 (끊긴 기록을 모른 채)"
expect_fail "이전 브랜치에 사용자 commit이 쌓였으면 --rollback은 거부" "이전 뒤의 commit이 있어" R migrate "$V1" --rollback
check "거부할 때는 아무것도 바꾸지 않음" bash -c "[[ \$(git -C '$V1' log -1 --format=%s) == '사용자 작업 (끊긴 기록을 모른 채)' ]] && test -f '$V1/.harness/archive/v1/MANIFEST.txt' && test -f '$V1/.git/harness-migrate.journal'"
git -C "$V1" reset -q --hard HEAD~1
expect_ok "사용자 작업을 정리한 뒤 --rollback (commit 뒤 끊긴 이전)" R migrate "$V1" --rollback
snap >"$WORK/s4b"
cmp -s "$WORK/s0" "$WORK/s4b" && ok "commit 뒤 끊긴 이전도 시작 상태로" || ng "commit 뒤 --rollback 불완전" "$(diff "$WORK/s0" "$WORK/s4b" | head -n 20)"
rm -f "$TMPDIR"/harness-migrate.* "$HOOK.kill"   # 강제 종료로 정리할 기회가 없었던 임시 파일
printf '#!/bin/sh\nsed -i "1s/^/[PROJ-1] /" "$1"\n' >"$MSGHOOK"; chmod +x "$MSGHOOK"   # 아래 적용·--undo는 제목이 바뀐 commit으로
expect_ok "이전 적용 (검토 수준 예외 + 완료 인정)" R migrate "$V1" "${MIG[@]}" --complete task-004 --complete-reason "D-9: 사용자 완료 인정" --apply --confirm-user-approval
has "대조: " && has "손실 없음" && ok "옮긴 파일 대조 통과" || ng "대조" "$LAST"
check "새 브랜치에 commit 하나, 시작점 태그" bash -c "[[ \$(git -C '$V1' branch --show-current) == harness-v2-migration && \$(git -C '$V1' rev-list --count harness-v1-final..HEAD) == 1 ]]"
check "남은 변경은 무관한 미추적 파일뿐" bash -c "[[ \"\$(git -C '$V1' status --porcelain)\" == '?? scratch.txt' ]]"
Y="$V1/.harness/project.yaml"
check "project.yaml: schema 2·검토 수준·v1 제한값·승인 모드" bash -c "grep -q \"^schema_version: '2'\" '$Y' && grep -q \"^  level: 'cross_model'\" '$Y' && grep -q '^  max_parallel_workers: 2   #' '$Y' && grep -q '^  ac_timeout_seconds: 300 ' '$Y' && grep -q '^  quota_low_pct: 30 ' '$Y' && grep -q \"^  approval_mode: 'bypass'\" '$Y'"
check "project.yaml: 에이전트·모델 매핑·바꾼 인수" bash -c "grep -q '^  available: \[claude, codex, agy\]' '$Y' && grep -q \"^  claude_standard: 'sonnet'\" '$Y' && grep -q \"^  claude_light: 'sonnet'\" '$Y' && grep -q \"^  claude_premium: 'opus'\" '$Y' && grep -q 'network_access=true' '$Y'"
check "v1이 넣던 기본 인수(claude acceptEdits)는 옮기지 않음 → v2 기본값" grep -q "^  claude_auto: ''" "$Y"
check "검토 수준 결정 기록 (사용자 사유)" grep -q '^회사 정책: claude만$' "$V1/.harness/decisions/review-level-1.md"
B="$V1/.harness/archive/v1-milestone-001"
check "완료·완료 인정 Task 보관" bash -c "ls '$B/tasks' | tr '\n' ' ' | grep -qx 'task-001.yaml task-002.yaml task-003.yaml task-004.yaml '"
check "보관 요약에 증빙 등급·완료 인정" bash -c "grep -q '^| task-001 |.*| v1 완료 |.*| partial |' '$B/SUMMARY.md' && grep -q '^| task-004 |.*| 사용자 완료 인정 (이전 때) |.*| partial |' '$B/SUMMARY.md' && grep -q 'D-9: 사용자 완료 인정' '$B/SUMMARY.md'"
check "완료 Task 기록 묶음 (시도·추가 지시·증빙)" bash -c "test -f '$B/attempts/task-001-attempt-2.md' && test -f '$B/intents/task-004-extra-prompt.md' && test -f '$B/evidence/task-001-attempt-2-checks.yaml'"
check "남는 파일이 가리키는 완료 Task 기록은 원래 자리에 (참조 유지)" bash -c "test -f '$V1/.harness/decisions/task-001-approval.md' && test -f '$V1/.harness/reviews/task-001-review-1.md' && test ! -e '$B/reviews/task-001-review-1.md' && grep -q '원래 자리에 둔 기록 (다른 파일이 가리킴): .harness/reviews/task-001-review-1.md' '$B/SUMMARY.md'"
check "v2와 부딪히는 기록은 옮기고 끊기는 참조로 보고" bash -c "test -f '$V1/.harness/archive/v1/attempts/task-005-attempt-1.md' && grep -q '^- .harness/attempts/task-005-attempt-1.md → .harness/archive/v1/attempts/task-005-attempt-1.md (가리키는 파일: docs/notes.md)' '$V1/.harness/archive/v1/MIGRATION.md' && grep -q '^- .harness/STATE.md → .harness/archive/v1/STATE.md' '$V1/.harness/archive/v1/MIGRATION.md'"
check "Git 밖 원문 로그는 옮긴 뒤에도 Git 밖" bash -c "cd '$V1' && git check-ignore -q .harness/archive/v1-milestone-001/evidence/raw/task-001-worker-attempt-2.md && git check-ignore -q .harness/archive/v1/evidence/raw/task-005-worker-attempt-1.md"
T5="$V1/.harness/tasks/task-005.yaml"
check "열린 Task: draft·schema 2·한 줄 목록" bash -c "grep -qx 'status: draft' '$T5' && grep -qx \"schema_version: '2'\" '$T5' && grep -qxF \"write_scope: ['e.txt']\" '$T5' && grep -qxF \"dependencies: ['task-004']\" '$T5'"
check "따옴표 든 목록 항목 변환" grep -qxF "write_scope: ['it''s.txt', 'f.txt']" "$V1/.harness/tasks/task-006.yaml"
check "열린 Task 원본 사본" bash -c "grep -qx 'status: submitted' '$V1/.harness/archive/v1/tasks-v1/task-005.yaml' && cmp -s '$V1/.harness/archive/v1/tasks-v1/task-005.yaml' <(git -C '$V1' show harness-v1-final:.harness/tasks/task-005.yaml)"
check "열린 Task의 시도·인계는 보관, Intent·결정은 그대로" bash -c "test -f '$V1/.harness/archive/v1/attempts/task-005-attempt-1.md' && test -f '$V1/.harness/archive/v1/handovers/task-006-handover-1.md' && test -f '$V1/.harness/intents/task-005-intent.md' && test -f '$V1/.harness/decisions/task-006-decisions-01.md' && test ! -e '$V1/.harness/attempts'"
check "대체·삭제된 Task 기록과 v1 운영 파일은 archive/v1" bash -c "cd '$V1/.harness/archive/v1' && test -f superseded/task-008.yaml && test -f intents/task-008-intent.md && test -f decisions/task-008-recontract-01.md && test -f handovers/task-099-handover-1.md && test -f STATE.md && test -f waves/wave-001.yaml && test -f policies/agent-policy.yaml && test -f project.yaml && test ! -e '$V1/.harness/planned'"
check "프로젝트 결정·사용자 파일은 그대로" bash -c "test -f '$V1/.harness/decisions/provider-claude-only-01.md' && test -f '$V1/.harness/intents/notes.md' && test -f '$V1/.harness/user-notes.md'"
check "원격 설정은 내용 그대로 새 자리로" cmp -s "$V1/.harness/remote.yaml" <(git -C "$V1" show harness-v1-final:.harness/policies/remote.yaml)
check "v1 Skill·역할은 보관, v2 Skill 설치, 사용자 Skill 유지" bash -c "grep -q 'v1 work skill' '$V1/.harness/archive/v1/agents/skills/harness-work/SKILL.md' && test -f '$V1/.harness/archive/v1/agents/roles/worker.agent.md' && grep -q '^name: harness-work' '$V1/.agents/skills/harness-work/SKILL.md' && ! grep -q 'v1 work' '$V1/.agents/skills/harness-work/SKILL.md' && grep -q '사용자 Skill' '$V1/.agents/skills/my-skill/SKILL.md' && test -L '$V1/.claude/skills/harness-review' && test ! -e '$V1/.agents/roles'"
check "v1 런타임 파일은 runtime/v1로 (Git 밖)" bash -c "test -f '$V1/.harness/runtime/v1/task-005-worker.meta' && test ! -e '$V1/.harness/runtime/task-005-worker.meta' && test -d '$V1/.harness/runtime/locked'"
check "진입 문서는 덧붙이기만" bash -c "head -c \$(git -C '$V1' show harness-v1-final:AGENTS.md | wc -c) '$V1/AGENTS.md' | cmp -s - <(git -C '$V1' show harness-v1-final:AGENTS.md) && grep -qx '## Harness v2 운영 규칙' '$V1/AGENTS.md' && grep -qx '### 불변 규칙' '$V1/AGENTS.md' && grep -qx '## Harness v2' '$V1/GEMINI.md' && grep -q '^# Antigravity Entry' '$V1/GEMINI.md'"
check ".gitignore 보강·이력" bash -c "grep -qxF '.harness/archive/*/evidence/raw/' '$V1/.gitignore' && grep -q '| v1-milestone-001 (v1에서 이전) | 4개 |' '$V1/.harness/HISTORY.md'"
check "링크인 진입 문서는 고치지 않음 (CLAUDE.md → AGENTS.md, 절은 한 번)" bash -c "test -L '$V1/CLAUDE.md' && [[ \$(grep -cx '## Harness v2 운영 규칙' '$V1/AGENTS.md') == 1 ]]"
check "v1 시작 안내(HARNESS_START.md)에 v2 안내만 덧붙임" bash -c "grep -q '^herdr-harness start .' '$V1/HARNESS_START.md' && grep -qx '## Harness v2' '$V1/HARNESS_START.md'"
check "이름에 공백이 든 참조 기록도 원래 자리에 (사용자 git 설정과 무관)" bash -c "test -f '$V1/.harness/decisions/task-001-메모 공백.md' && grep -qF '원래 자리에 둔 기록 (다른 파일이 가리킴): .harness/decisions/task-001-메모 공백.md' '$B/SUMMARY.md'"
check "대체된 Task의 시도 기록은 옮기고 끊기는 참조로 (ID가 다시 쓰일 수 있다)" bash -c "test -f '$V1/.harness/archive/v1/attempts/task-008-attempt-1.md' && grep -q '^- .harness/attempts/task-008-attempt-1.md → ' '$V1/.harness/archive/v1/MIGRATION.md'"
check "v2 기록과 이름이 겹치는 v1 결정은 보관" bash -c "test -f '$V1/.harness/archive/v1/decisions/milestone-001-approval.md' && test ! -e '$V1/.harness/decisions/milestone-001-approval.md'"
check "주인 없는 v2 기록 이름(X-review-N.md)은 참조돼도 옮김" bash -c "test -f '$V1/.harness/archive/v1/reviews/old-review-1.md' && grep -q '^- .harness/reviews/old-review-1.md → ' '$V1/.harness/archive/v1/MIGRATION.md'"
check "임시 파일을 남기지 않음" bash -c "! ls -A '$TMPDIR' | grep -q harness-migrate"
f_hash() { if [[ -L "$1" ]]; then printf 'symlink:%s' "$(readlink "$1")" | sha256sum | cut -c1-64; else sha256sum <"$1" | cut -c1-64; fi; }
manifest_check() {  # MANIFEST의 모든 줄을 테스트가 직접 다시 대조하고, 이전 전 파일이 빠짐없이 올라 있는지 본다
  local op sha size gt src dst got bad=0 exp act
  while IFS=$'\t' read -r op sha size gt src dst; do
    [[ "$op" != \#* ]] || continue
    case "$op" in
      move|convert) got="$(f_hash "$V1/$dst")" ;;
      keep) got="$(f_hash "$V1/$src")" ;;
      append) got="$(head -c "$size" "$V1/$src" | sha256sum | cut -c1-64)" ;;
      rmdir) got="$sha" ;;   # 비어서 지운 폴더 (내용 없음)
      *) got=x ;;
    esac
    [[ "$got" == "$sha" ]] || { echo "불일치: $op $src → $dst"; bad=1; }
  done <"$V1/.harness/archive/v1/MANIFEST.txt"
  exp="$(sed -n 's|^[0-9a-f]\{64\}  \./||p' "$WORK/s0" | grep -E '^\.(harness|agents)/' | grep -vE '^\.harness/(worktrees|remote-mount)/|^\.harness/runtime/[^/]+/' | sort)"
  act="$(awk -F'\t' '!/^#/ && $1 != "rmdir" && $5 ~ /^\.(harness|agents)\// { print $5 }' "$V1/.harness/archive/v1/MANIFEST.txt" | sort)"
  [[ "$exp" == "$act" ]] || { echo "목록 누락·초과:"; diff <(echo "$exp") <(echo "$act") | head; bad=1; }
  return "$bad"
}
LAST="$(manifest_check 2>&1)" && ok "MANIFEST 독립 재대조: 해시 일치·누락 없음" || ng "MANIFEST 재대조" "$LAST"
unlock
check "막아 둔 보호 폴더(마운트·작업 공간·런타임 하위)는 그대로" bash -c "for d in ${PROT[*]}; do grep -qx \"sentinel \$d\" '$V1/'\$d/sentinel && [[ \$(ls -A '$V1/'\$d) == sentinel ]] || exit 1; done"
lock
VH() { bash "$V1/.harness/bin/harness.sh" "$@"; }
expect_ok "이전 뒤 validate (draft 계약 보완은 TODO)" VH validate
has "[TODO] task-007: 계획 승인 전에 보완" && ok "manual-review만 있는 draft는 TODO로 안내" || ng "TODO 안내" "$LAST"
expect_ok "이전 뒤 status" VH status
! has "hh-task-005-w-1" && has "v1-milestone-001 (v1에서 이전)" && ok "status: v1 Agent 추적 파일을 읽지 않음, 이력 표시" || ng "status 내용" "$LAST"
check "MIGRATION.md에 이전 직후 검사 결과" grep -q '^validate: 통과' "$V1/.harness/archive/v1/MIGRATION.md"
expect_fail "이전된 프로젝트는 다시 이전하지 않음" "이미 v2" R migrate "$V1"
expect_fail "되돌리기(--undo)는 사용자 확인 필요" "confirm-user-approval" R migrate "$V1" --undo
expect_ok "병합 전 되돌리기 (--undo)" R migrate "$V1" --undo --confirm-user-approval
snap >"$WORK/s5"
cmp -s "$WORK/s0" "$WORK/s5" && ok "--undo 뒤 시작 상태와 같음 (Git 밖으로 옮긴 파일·지운 빈 폴더 포함, 제목이 바뀐 commit)" || ng "--undo 불완전" "$(diff "$WORK/s0" "$WORK/s5" | head -n 20)"
rm -f "$MSGHOOK"
# AGENTS.md가 CLAUDE.md를 가리키는 프로젝트(Codex 호환 관례) + 사용자가 .claude/를 무시하는 경우
rm "$V1/CLAUDE.md"; mv "$V1/AGENTS.md" "$V1/CLAUDE.md"; ln -s CLAUDE.md "$V1/AGENTS.md"
git -C "$V1" add -A AGENTS.md CLAUDE.md && git -C "$V1" commit -qm "AGENTS.md → CLAUDE.md"
printf '.claude/\n' >>"$V1/.git/info/exclude"
snap >"$WORK/s6"
expect_ok "다시 이전 (AGENTS.md가 링크, .claude/ 무시)" R migrate "$V1" "${MIG[@]}" --complete task-004 --complete-reason "D-9: 사용자 완료 인정" --apply --confirm-user-approval
check "v2 운영 규칙 절은 AGENTS.md가 가리키는 문서에 한 번" bash -c "test -L '$V1/AGENTS.md' && [[ \$(grep -cx '## Harness v2 운영 규칙' '$V1/CLAUDE.md') == 1 ]] && grep -qx '## Harness v2' '$V1/GEMINI.md'"
check "무시하는 경로의 새 Skill 링크는 로컬에만 (추적 파일 변경만 commit)" bash -c "test -L '$V1/.claude/skills/harness-review' && [[ -z \$(git -C '$V1' ls-files -- .claude/skills/harness-review) && \"\$(git -C '$V1' status --porcelain)\" == '?? scratch.txt' ]]"
expect_ok "그 상태에서도 --undo" R migrate "$V1" --undo --confirm-user-approval
snap >"$WORK/s7"
cmp -s "$WORK/s6" "$WORK/s7" && ok "--undo가 Git 밖에 새로 만든 링크까지 지움" || ng "--undo 뒤 남은 것" "$(diff "$WORK/s6" "$WORK/s7" | head -n 20)"
expect_ok "다시 이전 (재검증 시험용)" R migrate "$V1" "${MIG[@]}" --complete task-004 --complete-reason "D-9: 사용자 완료 인정" --apply --confirm-user-approval

expect_fail "v1 증빙 재검증: 지금 코드에서 실패하는 AC는 실패로 남김" "실패 1" VH verify --legacy
has "제외: task-002 — v1 증빙 완전" && has "제외: task-003 — command AC 없음" && ok "재검증 대상 선별 (불완전한 증빙만)" || ng "재검증 대상" "$LAST"
check "원격에서 AC 여러 개가 모두 실행되고 실패가 기록됨" bash -c "grep -q '^| AC-002 | command | 0 | PASS' '$B/verifications/task-001-verify-1.md' && grep -q '^| AC-003 | command | 1 | FAIL' '$B/verifications/task-001-verify-1.md' && grep -q '^- 재검증 요약: FAIL' '$B/verifications/task-001-verify-1.md'"
check "통과한 Task 기록" grep -q '^- 재검증 요약: PASS' "$B/verifications/task-004-verify-1.md"
check "재검증 기록 commit" bash -c "git -C '$V1' log --format=%s | grep -q '^harness: 재검증 task-001 #1: FAIL'"
touch "$RS1/later.txt"
expect_ok "고친 뒤 재검증 (통과한 Task는 다시 돌리지 않음)" VH verify --legacy
has "제외: task-004 — 재검증 통과 기록 있음" && check "다시 실행해 통과" grep -q '^- 재검증 요약: PASS' "$B/verifications/task-001-verify-2.md" || ng "재검증 재실행" "$LAST"
expect_ok "보관된 Task 하나 재검증" VH verify task-002
n_rec="$(ls "$B/verifications" | wc -l)"; mv "$WORK/key" "$WORK/key.off"
expect_fail "원격에 닿지 못하면 거짓 실패 기록을 남기지 않음" "원격에 연결하지 못해" VH verify task-002
check "연결 실패 때는 기록 없음" bash -c "[[ \$(ls '$B/verifications' | wc -l) == $n_rec ]]"
mv "$WORK/key.off" "$WORK/key"
expect_fail "command AC가 없으면 재검증 불가" "command AC가 없습니다" VH verify task-003
VH verify task-003 >/dev/null 2>&1; [[ $? == 2 ]] && ok "재검증할 수 없음은 종료 코드 2 (실패 1과 구분)" || ng "재검증 불가 종료 코드"
expect_fail "진행 전 Task는 재검증하지 않음 (run이 증빙)" "draft 상태" VH verify task-005
expect_fail "Harness가 띄운 Agent 안에서는 거부" "Agent" env HARNESS_AGENT=task-005-worker bash "$V1/.harness/bin/harness.sh" verify task-002
expect_ok "Milestone 단위 재검증 (보관된 v1 Task 포함)" VH verify --milestone milestone-001
has "통과 3 · 실패 0 · 제외 1" && ok "Milestone 재검증 요약" || ng "Milestone 재검증 요약" "$LAST"
check "재검증은 상태를 바꾸지 않음" bash -c "grep -qx 'status: draft' '$T5' && test -f '$B/tasks/task-001.yaml' && grep -qx 'status: completed' '$B/tasks/task-001.yaml'"
unlock

printf '\n결과: PASS %s / FAIL %s\n' "$PASS" "$FAIL"
(( FAIL == 0 ))

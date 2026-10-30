#!/usr/bin/env bash
# harness 자체 테스트 — 실제 에이전트·네트워크·쿼터를 쓰지 않는다.
# 가짜 herdr(에이전트 대신 각본대로 보고서·리뷰를 쓴다)와 가짜 ssh(원격 명령을 로컬에서 실행)로
# init부터 Milestone 승인·보관, 원격 모드, 업그레이드까지 전체 흐름을 검사한다.
# 모든 파일은 임시 디렉터리에만 만들고 끝나면 지운다. 사용자 입력을 기다리지 않는다.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/harness-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
PASS=0 FAIL=0 LAST=""

ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
ng() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | tail -n 8 | sed 's/^/      /'; }
expect_ok() { local name="$1"; shift; if LAST="$("$@" 2>&1 </dev/null)"; then ok "$name"; else ng "$name" "$LAST"; fi; }
expect_fail() {
  local name="$1" pat="$2"; shift 2
  if LAST="$("$@" 2>&1 </dev/null)"; then ng "$name (성공하면 안 됨)" "$LAST"
  elif [[ -n "$pat" && "$LAST" != *"$pat"* ]]; then ng "$name (메시지에 '$pat' 없음)" "$LAST"
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
  "agent start")
    name="$3"; shift 3; pane="" kind=""
    while (( $# )); do case "$1" in --pane) pane="$2"; shift ;; --kind) kind="$2"; shift ;; --) shift; break ;; esac; shift; done
    if [[ -n "${FAKE_START_FAIL_ONCE:-}" && ! -f "$F/start-failed" ]]; then touch "$F/start-failed"; echo '{"error":{"code":"invalid_agent_timeout"}}'; exit 1; fi
    printf 'status=idle\nrev=1\nseq=1\npane=%s\nkind=%s\n' "$pane" "$kind" >"$F/agents/$name"; echo "$*" >"$F/agents/$name.args" ;;
  "agent get") [[ -f "$F/agents/$3" ]] || { echo '{"error":"agent_not_found"}'; exit 1; }; json_agent "$3" ;;
  "agent prompt")
    name="$3" text="$4"; [[ -f "$F/agents/$name" ]] || exit 1
    if [[ -n "${FAKE_DROP_FIRST:-}" && ! -f "$F/dropped-$name" ]]; then touch "$F/dropped-$name"; echo agent_prompt_stalled; exit 1; fi
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
cmd="${!#}"; bash -c "$cmd"
EOF
chmod +x "$FAKE/bin/herdr" "$FAKE/bin/ssh"

export FAKE_DIR="$FAKE" FAKE_HOOK="$FAKE/hook.sh" PATH="$FAKE/bin:$PATH" HERDR_ENV=1 HARNESS_NO_SLEEP=1 HARNESS_NO_PULL=1 HARNESS_SKIP_MOUNT_CHECK=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
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
expect_fail "init: Worker=Reviewer 거부" "다른 Provider" R init "$WORK/x" --goal g --worker codex --reviewer codex
expect_ok   "init" R init "$P" --goal "테스트 & 목표 | 특수문자"
check "프로젝트에 bin·lib 복사" test -x "$P/.harness/bin/harness.sh" -a -f "$P/.harness/bin/lib/gates.sh"
check "치환되지 않은 @@ 없음" bash -c "! grep -rl '@@' '$P' --exclude-dir=bin --exclude-dir=.git"
check "목표 특수문자 보존" grep -qF "테스트 & 목표 | 특수문자" "$P/AGENTS.md"
check "Claude Skill 링크" test -L "$P/.claude/skills/harness-work"
check "기준 commit" git -C "$P" rev-parse --verify -q HEAD
expect_fail "init: 비어 있지 않은 경로 거부" "비어 있지 않은" R init "$P" --goal g
expect_ok   "validate (초기)" H validate
expect_ok   "start (Herdr 안: 중첩 대신 현재 세션에 workspace 생성)" H start
check "프로젝트 이름의 workspace" grep -qx proj "$FAKE/ws"
expect_ok   "start 재실행 (있는 workspace로 이동)" H start
check "기존 workspace로 이동" grep -qx w1 "$FAKE/ws-focused"
expect_ok   "doctor" H doctor

echo "== 2. 계획 승인과 계약 고정 =="
write_task task-001 milestone-001 out.txt "test -f out.txt && grep -q ok out.txt"
write_task task-002 milestone-001 two.txt "test -f two.txt" "dependencies: [task-001]"
commit_all "tasks"
expect_fail "SPEC 미승인이면 계획 승인 거부" "SPEC" H approve-plan milestone-001 --confirm-user-approval
sed -i 's/^- 상태: draft/- 상태: approved/' "$P/.harness/SPEC.md"; commit_all "spec"
expect_fail "확인 플래그 없는 계획 승인 거부" "confirm-user-approval" H approve-plan milestone-001
expect_ok   "계획 승인" H approve-plan milestone-001 --confirm-user-approval
check "draft → ready" test "$(st task-001)" = ready
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
P_SAVE="$P"; P="$P2"
write_task task-001 milestone-001 r.txt "test -f r.txt"
sed -i 's/^- 상태: draft/- 상태: approved/' "$P/.harness/SPEC.md"; commit_all "remote tasks"
H approve-plan milestone-001 --confirm-user-approval >/dev/null
expect_ok "원격 모드 착수 (작업 공간 분리 없이 순서대로)" H transition task-001 active
env -u HARNESS_SKIP_MOUNT_CHECK bash "$P/.harness/bin/harness.sh" dispatch task-001 worker >"$WORK/m.out" 2>&1 </dev/null
grep -q '마운트되어 있지 않습니다' "$WORK/m.out" && ok "마운트가 풀린 원격은 dispatch 거부" || ng "마운트 확인" "$(cat "$WORK/m.out")"
expect_ok "원격 모드 dispatch (코드 = 마운트 경로)" H dispatch task-001 worker
expect_ok "원격 모드 제출 (AC를 원격에서 실행)" H transition task-001 submitted
check "AC 실행 위치가 원격" grep -q '실행 위치: 원격' "$P/.harness/attempts/task-001-attempt-1.harness.md"
write_task task-002 milestone-001 r2.txt "test -f r2.txt"; commit_all "remote task-002"
H approve-plan milestone-001 --confirm-user-approval >/dev/null
expect_fail "원격 모드는 통합 전 Task가 있으면 다음 Task 착수 거부" "하나씩" H transition task-002 active
H transition task-001 reviewing >/dev/null; FAKE_VERDICT=CHANGES_REQUESTED H dispatch task-001 reviewer >/dev/null
H transition task-001 changes_requested >/dev/null; H transition task-001 ready >/dev/null
expect_fail "재작업 대기(ready) Task도 자리를 차지" "하나씩" H transition task-002 active
P="$P_SAVE"

echo "== 8. 업그레이드 =="
expect_ok "저장소에서 업그레이드" R upgrade "$P"
has "2.0.0 → 2.0.0" && ok "버전 표시" || ng "버전 표시" "$LAST"
commit_all "upgrade" 2>/dev/null || true
echo "# local edit" >>"$P/.agents/skills/harness-work/SKILL.md"
expect_fail "로컬 수정이 있으면 덮어쓰지 않음" "커밋되지 않은 변경" H upgrade
git -C "$P" checkout -q -- .agents/skills/harness-work/SKILL.md
expect_ok "프로젝트 안에서 업그레이드 (harness_source)" H upgrade

printf '\n결과: PASS %s / FAIL %s\n' "$PASS" "$FAIL"
(( FAIL == 0 ))

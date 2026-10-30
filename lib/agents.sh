# herdr-harness: 에이전트 실행 — dispatch / observe / close. Herdr 호출은 실측으로 확정된 형식만 쓴다.
# harness.sh가 source한다. 단독 실행하지 않는다.

DISPATCH_TIMEOUT_MAX=300000   # herdr agent start·prompt 상한. 넘기면 Pane만 만들고 실패한다.

# 승인 모드별 Provider 인수. project.yaml agents.<provider>_<mode>가 있으면 그 값을,
# 없으면 기본 3종의 내장 값을 쓴다. 메인 셸에서 부른다(서브셸의 die는 삼켜진다).
approval_args_raw() {  # PROVIDER MODE → 공백 구분 인수
  local p="$1" mode="$2" v
  [[ "$mode" != ask ]] || return 0
  v="$(pget agents "${p}_${mode}")"
  if [[ -z "$v" ]]; then
    case "$p:$mode" in
      claude:auto)   v="--permission-mode acceptEdits" ;;
      claude:bypass) v="--permission-mode bypassPermissions" ;;
      codex:auto)    v="--ask-for-approval never --sandbox workspace-write" ;;
      codex:bypass)  v="--dangerously-bypass-approvals-and-sandbox" ;;
      agy:auto)      v="--mode accept-edits" ;;
      agy:bypass)    v="--dangerously-skip-permissions" ;;
    esac
  fi
  [[ "$v" =~ ^[-A-Za-z0-9=_./\ ]*$ ]] || die "agents.${p}_${mode}에 허용되지 않는 문자가 있습니다: $v"
  # 기록에는 auto로 남는데 실제 권한은 전부 열리는 상황을 막는다.
  if [[ "$mode" == auto ]] && grep -Eqi 'dangerous|bypass|danger-full-access' <<<"$v"; then
    die "auto 모드 인수에 승인 우회 플래그가 있습니다: agents.${p}_auto = $v (bypass 모드를 쓴다)"
  fi
  printf '%s' "$v"
}

activity_unchanged() {  # 프롬프트 전후 revision·state_change_seq가 모두 그대로인가
  local a b c d
  a="$(jfield "$1" revision)"; b="$(jfield "$1" state_change_seq)"
  c="$(jfield "$2" revision)"; d="$(jfield "$2" state_change_seq)"
  [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && "$a" == "$c" && "$b" == "$d" ]]
}

# Herdr agent_status → Harness 결과. BASELINE(프롬프트 직전 get)이 있으면 활동 지표로
# 전달 여부를 판정한다. Provider 출력 문자열은 성공 근거로 쓰지 않는다.
normalize() {  # GET_RC GET_OUT [PROMPT_RC PROMPT_OUT BASELINE]
  local gs="$1" gout="$2" ps="${3:-0}" pout="${4:-}" base="${5:-}" st
  if (( gs != 0 )); then echo agent_lost; return 0; fi
  st="$(jfield "$gout" agent_status)"
  case "$st" in
    working) echo running ;;
    blocked) echo blocked ;;
    unknown) echo unknown ;;
    idle|done)
      if [[ -n "$base" ]] && activity_unchanged "$base" "$gout"; then echo prompt_not_delivered
      elif [[ -n "$base" ]] && (( ps == 0 )); then echo settled
      elif grep -qi agent_prompt_stalled <<<"$pout"; then echo stalled
      elif (( ps != 0 )) && grep -Eqi 'timed?[ -]?out' <<<"$pout"; then echo timeout
      else echo settled
      fi ;;
    *) printf '경고: 알 수 없는 agent_status=%s — unknown으로 보고\n' "${st:-빈 값}" >&2; echo unknown ;;
  esac
}

# 분할 직후 Pane은 수 초간 agent_pane_busy다. 준비 대기만 재시도하고 Agent 턴은 재시도하지 않는다.
start_agent() {  # NAME KIND PANE TIMEOUT [ARGS...] → OUT·RC
  local -a cmd=(herdr agent start "$1" --kind "$2" --pane "$3" --timeout "$4")
  local tries=0
  shift 4
  (( $# == 0 )) || cmd+=(-- "$@")
  while :; do
    hcap "${cmd[@]}"
    if (( RC == 0 )) || ! grep -q agent_pane_busy <<<"$OUT" || (( tries >= 60 )); then return "$RC"; fi
    tries=$((tries + 1))
    nap 0.5
  done
}

# Provider REPL이 입력을 받을 때까지 기다린다(부팅·신뢰 확인 화면이 프롬프트를 먹는다).
# 연속 2회 idle이면 준비로 보고, 직후 get을 BASELINE으로 잡는다.
wait_ready() {  # NAME BOOT_SECONDS
  local waited="$2" stable=0
  nap "$2"
  while (( waited < 40 )); do
    case "$(jfield "$(herdr agent get "$1" 2>/dev/null || true)" agent_status)" in
      idle|done) stable=$((stable + 1)) ;;
      *) stable=0 ;;
    esac
    (( stable < 2 )) || break
    nap 2
    waited=$((waited + 2))
  done
  BASELINE="$(herdr agent get "$1" 2>/dev/null || true)"
}

# 프롬프트는 상태 변화가 처음 관측되면 돌아온다(전달 확인). 작업 완료 대기는 observe --wait 몫이다.
turn() {  # NAME MESSAGE TIMEOUT → T_PS T_POUT T_GS T_GOUT T_ROUT
  hcap herdr agent prompt "$1" "$2" --wait --timeout "$3" --until working --until idle --until done --until blocked
  T_PS=$RC; T_POUT="$OUT"
  hcap herdr agent get "$1"; T_GS=$RC; T_GOUT="$OUT"
  hcap herdr agent read "$1" --source recent-unwrapped --lines 200; T_ROUT="$OUT"
}

append_log() {  # FILE TITLE TEXT — Secret 의심이면 원문 대신 경고만 남긴다 (Git 제외 영역)
  local text="$3"
  if has_secret <<<"$text"; then text="(Secret 의심 패턴 — 원문 저장 안 함)"; fi
  printf '\n# %s %s\n\n%s\n' "$2" "$(now)" "$text" >>"$1"
}

record_changes() {  # DIR → 기록용 git status 목록
  printf -- '- 변경 파일 (%s):\n' "$1"
  git -C "$1" status --short 2>/dev/null | sed 's/^/    /' || true
}

agent_name() {  # TASK ROLE N → hh-<task>-<해시>-<w|r><N> (32자 이내, 긴 ID도 충돌하지 않게)
  local suffix="-${2:0:1}$3" h slug
  h="$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; h="${h: -4}"
  slug="${1,,}"; slug="${slug//[^a-z0-9-]/-}"
  printf 'hh-%s-%s%s' "${slug:0:$((24 - ${#suffix}))}" "$h" "$suffix"
}

cmd_dispatch() {
  local task="${1:-}" role="${2:-}" tmo=120000 extra=""
  [[ -n "$task" && -n "$role" ]] || die "사용법: dispatch TASK worker|reviewer [--timeout MS] [--extra-prompt FILE]"
  shift 2
  while (( $# )); do
    case "$1" in
      --timeout)
        [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] && (( $2 <= DISPATCH_TIMEOUT_MAX )) ||
          die "--timeout은 1~${DISPATCH_TIMEOUT_MAX}ms입니다 (기동·전달 대기 상한). 작업 완료는 observe --wait로 기다린다."
        tmo="$2"; shift 2 ;;
      --extra-prompt) [[ -f "${2:-}" ]] || die "--extra-prompt 파일이 없습니다: ${2:-}"; extra="$(realpath "$2")"; shift 2 ;;
      *) die "알 수 없는 dispatch 옵션: $1" ;;
    esac
  done
  [[ "$role" == worker || "$role" == reviewer ]] || die "ROLE은 worker 또는 reviewer입니다."
  require_human dispatch

  local tf status provider n att=0 worker_provider="" cwd meta old max_rework
  tf="$(task_file "$task")"
  status="$(yget "$tf" status)"
  if [[ "$role" == worker ]]; then
    [[ "$status" == active ]] || die "worker dispatch는 active Task만 가능합니다 ($task: $status)."
    provider="$(yget "$tf" primary_worker)"
    plan_check "$task"
    n=$(( $(last_attempt "$task") + 1 ))
    max_rework="$(pnum limits max_rework 3)"
    (( n <= max_rework + 1 )) || die "$task의 재작업 상한(${max_rework}회)을 넘었습니다. 사용자 판단이 필요합니다."
  else
    [[ "$status" == reviewing ]] || die "reviewer dispatch는 reviewing Task만 가능합니다 ($task: $status)."
    provider="$(yget "$tf" reviewer)"
    att="$(last_attempt "$task")"
    ac_passed "$(att_record "$task" "$att")" || die "attempt $att에 AC 통과 증빙이 없습니다."
    worker_provider="$(rec_get "$(att_record "$task" "$att")" Provider)"
    [[ "$provider" != "$worker_provider" ]] ||
      die "Reviewer($provider)가 attempt $att의 Worker와 같은 Provider입니다. 교차 검토가 성립하지 않습니다."
    n=$(( $(last_review "$task") + 1 ))
  fi
  is_provider "$provider" || die "Task의 Provider가 project.yaml providers.available에 없습니다: ${provider:-없음}"
  command -v herdr >/dev/null 2>&1 || die "herdr 명령이 없습니다."
  [[ "${HERDR_ENV:-}" == 1 ]] || die "dispatch는 Herdr Pane 안(HERDR_ENV=1)에서 실행한다."
  cwd="$(task_cwd "$task")"
  [[ -d "$cwd" ]] || die "작업 디렉터리가 없습니다: $cwd (worktree는 transition active가 만든다)"
  # WSL 재시작 뒤에는 SSHFS 마운트가 풀리고 빈 폴더만 남는다. 거기서 일하면 결과가 로컬에만 생긴다.
  if remote_enabled && [[ -z "${HARNESS_SKIP_MOUNT_CHECK:-}" ]] && ! mountpoint -q "$cwd" 2>/dev/null; then
    die "원격 소스가 마운트되어 있지 않습니다: $cwd (remote mount 후 다시 실행)"
  fi

  # 살아 있는 이전 Agent의 추적 정보를 덮어쓰면 그 Pane은 고아가 된다.
  meta="$(meta_file "$task" "$role")"
  old="$(meta_get "$meta" agent)"
  if [[ -n "$old" ]] && ! grep -q '^closed=' "$meta" && herdr agent get "$old" >/dev/null 2>&1; then
    die "같은 Task·역할의 Agent가 살아 있습니다 ($old). 먼저 close $task $role [--force]."
  fi

  # Provider 인수 = 승인 모드 + 모델 등급·생각 깊이 + (작업 공간이 따로면) 워크스페이스 쓰기 허용.
  local mode raw name packet record log base
  local -a args=()
  mode="$(pget agents approval_mode ask)"
  case "$mode" in ask|auto|bypass) ;; *) die "project.yaml agents.approval_mode가 올바르지 않습니다: $mode" ;; esac
  raw="$(approval_args_raw "$provider" "$mode")"
  [[ -z "$raw" ]] || read -r -a args <<<"$raw"
  select_model "$task" "$role" "$provider"
  args+=(${SEL_ARGS[@]+"${SEL_ARGS[@]}"})
  [[ "$cwd" == "$ROOT" ]] || args+=(--add-dir "$ROOT")

  name="$(agent_name "$task" "$role" "$n")"
  base="$(git -C "$cwd" rev-parse HEAD 2>/dev/null || echo -)"
  mkdir -p "$ROOT/.harness/runtime"
  packet="$ROOT/.harness/runtime/$task-$role.context.md"
  log="$ROOT/.harness/runtime/$task-$role-$n.log"
  write_packet "$task" "$role" "$n" "$att" "$cwd" "$base" "$packet" "$extra" ||
    die "Context Packet에 Secret 의심 패턴이 있어 보내지 않습니다. Task·SPEC·Review에서 값을 지운 뒤 다시 dispatch한다."
  if [[ "$role" == worker ]]; then record="$(att_record "$task" "$n")"; else record="$(rev_record "$task" "$n")"; fi

  hcap herdr pane split --current --direction right --cwd "$cwd" --no-focus --env "HARNESS_AGENT=$task-$role"
  (( RC == 0 )) || die "herdr pane split 실패: $OUT"
  local pane
  pane="$(jfield "$OUT" pane_id)"
  [[ -n "$pane" ]] || die "pane_id를 읽지 못했습니다: $OUT"

  mkdir -p "$(dirname "$record")"
  {
    printf '# Harness 기록: %s %s #%s\n\n이 파일은 harness.sh만 쓴다(증빙). 사람·Agent는 수정하지 않는다.\n\n' "$task" "$role" "$n"
    printf -- '- 시작: %s\n- 시작(epoch): %s\n- Provider: %s\n- 등급: %s\n- 모델: %s\n- 생각 깊이: %s\n' \
      "$(now)" "$(date +%s)" "$provider" "$SEL_TIER" "${SEL_MODEL:-Provider 기본값}" "${SEL_EFFORT:-Provider 기본값}"
    printf -- '- 인수: %s\n- Agent: %s\n- Pane: %s\n- 작업 디렉터리: %s\n- 기준 commit: %s\n' \
      "${args[*]:-(없음)}" "$name" "$pane" "$cwd" "$base"
    [[ "$role" == worker ]] || printf -- '- 검토 대상: attempt %s (Worker %s)\n' "$att" "$worker_provider"
  } >"$record"
  write_atomic "$meta" <<EOF
agent=$name
pane=$pane
provider=$provider
n=$n
record=$record
cwd=$cwd
log=$log
EOF

  local result resent=no msg cleanup signal warning
  msg="Harness Context Packet을 읽고 그 지시대로 이 Task만 수행하라: $packet"
  : >"$log"
  if ! start_agent "$name" "$provider" "$pane" "$tmo" ${args[@]+"${args[@]}"}; then
    result=error
    append_log "$log" "agent start" "$OUT"
    if grep -qi invalid_agent_timeout <<<"$OUT"; then OUT=invalid_agent_timeout
    elif grep -qi agent_pane_busy <<<"$OUT"; then OUT=agent_pane_busy
    else OUT="unknown (원문: $(rel "$log"))"; fi
    if herdr pane close "$pane" >/dev/null 2>&1; then
      cleanup="회수됨"; printf 'closed=%s\n' "$(now)" >>"$meta"
    else
      cleanup="회수 실패 — herdr pane close $pane"
    fi
    printf '기동 실패: %s · Pane %s\n' "$OUT" "$cleanup" >&2
    printf -- '- 기동 실패: %s\n- Pane 정리: %s\n' "$OUT" "$cleanup" >>"$record"
  else
    wait_ready "$name" "$( [[ "$provider" == agy ]] && echo 12 || echo 3 )"
    turn "$name" "$msg" "$(( tmo < 30000 ? tmo : 30000 ))"
    result="$(normalize "$T_GS" "$T_GOUT" "$T_PS" "$T_POUT" "$BASELINE")"
    # 활동 지표가 그대로인 idle, 또는 stalled + idle일 때만 1회 재전송한다.
    if [[ "$result" == prompt_not_delivered ]] ||
       { [[ "$result" == stalled ]] && [[ "$(jfield "$T_GOUT" agent_status)" =~ ^(idle|done)$ ]]; }; then
      info "첫 프롬프트가 전달되지 않았습니다 — 1회 재전송합니다."
      resent=yes
      append_log "$log" "prompt (재전송 전)" "$T_POUT"
      wait_ready "$name" 3
      turn "$name" "$msg" "$(( tmo < 30000 ? tmo : 30000 ))"
      result="$(normalize "$T_GS" "$T_GOUT" "$T_PS" "$T_POUT" "$BASELINE")"
    fi
    append_log "$log" "prompt" "$T_POUT"
    append_log "$log" "agent get" "$T_GOUT"
    append_log "$log" "agent read" "$T_ROUT"
  fi
  signal="$(quota_exhausted "${T_POUT:-}"$'\n'"${T_ROUT:-}" || true)"
  warning="$(quota_warning "${T_ROUT:-}" || true)"
  {
    printf '\n## dispatch %s\n\n- 결과: %s\n- 프롬프트 재전송: %s\n- 원문 로그(Git 제외): %s\n' \
      "$(now)" "$result" "$resent" "$(rel "$log")"
    [[ -z "$signal" ]] || printf -- '- 쿼터 신호: %s\n' "$signal"
    [[ -z "$warning" ]] || printf -- '- 쿼터 경고: %s\n' "$warning"
    [[ "$result" != settled ]] || record_changes "$cwd"
  } >>"$record"
  printf '%s|%s\n' "$result" "$signal" >"$ROOT/.harness/runtime/$task-$role.last"
  printf 'dispatch_result=%s\n' "$result"
  [[ -z "$signal" ]] || printf 'quota_signal=%s\n' "$signal"
  [[ -z "$warning" ]] || printf 'quota_warning=%s\n' "$warning"
  printf '증빙: %s\n' "$(rel "$record")"
  case "$result" in running|settled|blocked) return 0 ;; esac
  exit 1   # 예상한 실패 결과 — 오류 위치를 찍지 않고 종료 코드만 돌려준다
}

cmd_observe() {
  local task="${1:-}" role=worker wait_ms="" meta name record cwd log result last signal warning
  [[ -n "$task" ]] || die "사용법: observe TASK [worker|reviewer] [--wait MS]"
  shift
  if [[ "${1:-}" == worker || "${1:-}" == reviewer ]]; then role="$1"; shift; fi
  while (( $# )); do
    case "$1" in
      --wait) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "--wait에는 밀리초가 필요합니다."; wait_ms="$2"; shift 2 ;;
      *) die "알 수 없는 observe 옵션: $1" ;;
    esac
  done
  need_id "$task"
  meta="$(meta_file "$task" "$role")"
  [[ -f "$meta" ]] || die "dispatch 기록이 없습니다: $(rel "$meta")"
  command -v herdr >/dev/null 2>&1 || die "herdr 명령이 없습니다."
  name="$(meta_get "$meta" agent)"; record="$(meta_get "$meta" record)"
  cwd="$(meta_get "$meta" cwd)"; log="$(meta_get "$meta" log)"
  [[ -z "$wait_ms" ]] || herdr agent wait "$name" --timeout "$wait_ms" >/dev/null 2>&1 || true
  hcap herdr agent get "$name"; local gs=$RC gout="$OUT"
  hcap herdr agent read "$name" --source recent-unwrapped --lines 200
  result="$(normalize "$gs" "$gout")"
  signal="$(quota_exhausted "$OUT" || true)"
  warning="$(quota_warning "$OUT" || true)"
  last="$(cat "$ROOT/.harness/runtime/$task-$role.last" 2>/dev/null || true)"
  # 반복 관측이 Git 기록을 부풀리지 않게, 결과가 바뀌었을 때만 남긴다.
  if [[ "$result|$signal" != "$last" ]]; then
    append_log "$log" "observe ($result)" "$gout"$'\n\n'"$OUT"
    {
      printf '\n## observe %s\n\n- 결과: %s\n' "$(now)" "$result"
      [[ -z "$signal" ]] || printf -- '- 쿼터 신호: %s\n' "$signal"
      [[ -z "$warning" ]] || printf -- '- 쿼터 경고: %s\n' "$warning"
      [[ "$result" != settled ]] || record_changes "$cwd"
    } >>"$record"
    printf '%s|%s\n' "$result" "$signal" >"$ROOT/.harness/runtime/$task-$role.last"
  fi
  printf 'observe_result=%s\n' "$result"
  [[ -z "$signal" ]] || printf 'quota_signal=%s\n' "$signal"
  [[ -z "$warning" ]] || printf 'quota_warning=%s\n' "$warning"
}

cmd_close() {
  local task="${1:-}" role=worker force=0 meta name pane
  [[ -n "$task" ]] || die "사용법: close TASK [worker|reviewer] [--force]"
  shift
  if [[ "${1:-}" == worker || "${1:-}" == reviewer ]]; then role="$1"; shift; fi
  while (( $# )); do
    case "$1" in --force) force=1 ;; *) die "알 수 없는 close 옵션: $1" ;; esac
    shift
  done
  need_id "$task"
  require_human close
  meta="$(meta_file "$task" "$role")"
  [[ -f "$meta" ]] || die "Harness가 띄운 Agent 기록이 없어 정리하지 않습니다: $(rel "$meta")"
  grep -q '^closed=' "$meta" && { info "이미 정리됨: $(meta_get "$meta" agent)"; return 0; }
  name="$(meta_get "$meta" agent)"; pane="$(meta_get "$meta" pane)"
  hcap herdr agent get "$name"
  if (( RC == 0 )); then
    [[ "$(jfield "$OUT" agent_status)" != working || $force -eq 1 ]] ||
      die "$name이(가) working 상태입니다. 결과를 버려도 되면 --force."
  fi
  # Pane이 실제로 남아 있으면 닫혀야만 정리로 기록한다. 실패를 숨기면 살아 있는 Pane이 추적에서 사라진다.
  if herdr pane get "$pane" >/dev/null 2>&1; then
    hcap herdr pane close "$pane"
    (( RC == 0 )) || die "Pane 정리 실패($pane): $OUT"
  fi
  printf 'closed=%s\n' "$(now)" >>"$meta"
  info "정리 완료: $name ($pane)"
}

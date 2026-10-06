# Part of herdr-harness. Sourced by harness.sh — do not run directly.


_runtime_json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# status 요약 — "지금 무엇을 해야 하나"를 Task YAML 기준으로 보여 준다.
#
# STATE.md를 그대로 cat하면, 상태표 아래에 Wave마다 쌓인 서술 섹션(`다음 작업`,
# `이관 메모` 등)이 파일 끝에 남는다. `status | tail -30`이 몇 주 전의 할 일을
# 보여 주고, 실제 최신 Task(awaiting_approval 등)는 파일 중간 표 안에 묻힌다
# (2026-09-25 실사용 제보). 그래서 기본 출력은 정본(Task YAML의 status:)에서
# 계산한 요약이고, STATE.md에서는 헤더 bullet과 상태표만 읽어 대조한다.
# 서술 섹션은 출력하지 않는다 — 원문은 --full로 본다. STATE.md는 읽기만 한다.
# ---------------------------------------------------------------------------

# 정렬 우선순위: 사람 판단이 필요한 상태가 위로 온다.
_status_rank() {
  case "$1" in
    awaiting_approval) printf 1 ;;
    blocked) printf 2 ;;
    handover_required) printf 3 ;;
    changes_requested) printf 4 ;;
    active) printf 5 ;;
    reviewing) printf 6 ;;
    submitted) printf 7 ;;
    ready) printf 8 ;;
    draft) printf 9 ;;
    *) printf 10 ;;
  esac
}

# STATE.md 상태표에서 "task<TAB>상태" 행을 뽑는다. 열 순서는 프로젝트마다 다를
# 수 있어 헤더의 "상태"/"status" 열 위치를 찾는다. 헤더가 없으면 init 형식
# (5번째 칸)을 쓴다.
_status_state_table() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0
  awk -F'|' '
    function trim(v) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); gsub(/`/, "", v); return v }
    /^[[:space:]]*\|/ {
      first = trim($2)
      if (first ~ /^(Task|task|ID)$/) {
        col = 0
        for (i = 2; i <= NF; i++) {
          cell = trim($i)
          if (cell == "상태" || tolower(cell) == "status") { col = i; break }
        }
        next
      }
      if (first ~ /^task-[A-Za-z0-9._-]+$/) {
        c = col ? col : 6
        print first "\t" trim($c)
      }
    }
  ' "$state_file"
}

# STATE.md 맨 앞(첫 "## " 이전)의 "- 키: 값" bullet — 프로젝트 헤더.
_status_state_header() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0
  awk '/^## / { exit } /^- [^:]+: / { print }' "$state_file"
}

# 결과: STATUS_TASKS(정렬된 "rank task status worker reviewer title state_md", \x1f 구분)
#       STATUS_PENDING(사용자 승인·판단 항목), STATUS_MISMATCH, STATUS_DONE_COUNT,
#       STATUS_SPEC, STATUS_WAVES("wave\tstatus"), STATUS_STATE_ONLY
_status_collect() {
  local root="$1" task_id path status worker reviewer title state_status rank approval
  local spec_state wave_path wave_id wave_status
  local -A state_rows=() seen=()
  local -a rows=()

  STATUS_TASKS=() STATUS_PENDING=() STATUS_MISMATCH=() STATUS_WAVES=() STATUS_STATE_ONLY=()
  STATUS_DONE_COUNT=0

  while IFS=$'\t' read -r task_id state_status; do
    [[ -n "$task_id" ]] || continue
    state_rows[$task_id]="$state_status"
  done < <(_status_state_table "$root/.harness/STATE.md")

  spec_state="$(awk -F': ' '/^- 상태:/{print $2; exit}' "$root/.harness/SPEC.md" 2>/dev/null || true)"
  STATUS_SPEC="${spec_state:-unknown}"
  [[ "$STATUS_SPEC" == approved ]] ||
    STATUS_PENDING+=("SPEC: 상태=$STATUS_SPEC — 사용자 승인 필요 (.harness/SPEC.md §7)")

  shopt -s nullglob
  for wave_path in "$root"/.harness/waves/*.yaml; do
    wave_id="$(basename "$wave_path" .yaml)"
    [[ "$wave_id" != TEMPLATE ]] || continue
    wave_status="$(_runtime_yaml_scalar "$wave_path" status)"
    wave_status="${wave_status%%#*}"; wave_status="${wave_status%"${wave_status##*[![:space:]]}"}"
    [[ "$wave_status" != completed ]] || continue
    STATUS_WAVES+=("$wave_id"$'\t'"${wave_status:-unknown}")
    [[ "$wave_status" != draft ]] ||
      STATUS_PENDING+=("$wave_id: Wave 계획 승인 필요 (status=draft)")
  done
  shopt -u nullglob

  while IFS= read -r task_id; do
    [[ -n "$task_id" ]] || continue
    path="$root/.harness/tasks/$task_id.yaml"
    seen[$task_id]=1
    status="$(_runtime_yaml_scalar "$path" status)"
    state_status="${state_rows[$task_id]:-}"
    if [[ -n "$state_status" && "$state_status" != "$status" ]]; then
      STATUS_MISMATCH+=("$task_id: STATE.md 상태표=$state_status, Task YAML=$status (정본은 Task YAML)")
    fi
    if [[ "$status" == completed ]]; then
      STATUS_DONE_COUNT=$((STATUS_DONE_COUNT + 1))
      continue
    fi
    worker="$(_runtime_yaml_scalar "$path" primary_worker)"
    reviewer="$(_runtime_yaml_scalar "$path" reviewer)"
    title="$(_runtime_yaml_scalar "$path" title)"
    rank="$(_status_rank "$status")"
    # 빈 칸(제목 없음 등)이 있어도 열이 밀리지 않도록 공백류가 아닌 구분자를 쓴다.
    rows+=("$rank"$'\x1f'"$task_id"$'\x1f'"$status"$'\x1f'"$worker"$'\x1f'"$reviewer"$'\x1f'"$title"$'\x1f'"$state_status")
    case "$status" in
      awaiting_approval)
        approval="$root/.harness/decisions/$task_id-approval.md"
        if [[ ! -f "$approval" ]] || ! grep -q '^승인:[[:space:]]*yes' "$approval"; then
          STATUS_PENDING+=("$task_id: awaiting_approval — completed 사용자 승인 필요 (승인 후: $SCRIPT_NAME approve PATH $task_id --confirm-user-approval)")
        fi
        ;;
      blocked) STATUS_PENDING+=("$task_id: blocked — 입력·결정 필요") ;;
      handover_required) STATUS_PENDING+=("$task_id: handover_required — Provider 교체 승인 필요") ;;
    esac
  done < <(task_ids "$root")

  # Task YAML 없이 STATE.md 표에만 남은 행(아카이브된 Task 등). 진행 중 상태로 남아
  # 있을 때만 알린다 — completed와, init이 만드는 draft 자리표시 행은 할 일이 아니다.
  for task_id in "${!state_rows[@]}"; do
    [[ -z "${seen[$task_id]:-}" ]] || continue
    case "${state_rows[$task_id]}" in completed|draft) continue ;; esac
    STATUS_STATE_ONLY+=("$task_id: STATE.md 상태표에만 있음 (상태=${state_rows[$task_id]}, Task YAML 없음)")
  done

  if (( ${#rows[@]} > 0 )); then
    mapfile -t STATUS_TASKS < <(printf '%s\n' "${rows[@]}" | LC_ALL=C sort -t$'\x1f' -k1,1n -k2,2)
  fi
}

_status_md_cell() {
  local value="$1"
  value="${value//|/\\|}"
  printf '%s' "${value:--}"
}

_status_print_summary() {
  local root="$1" state_file name line rank task status worker reviewer title state_status
  local total_lines narrative=""
  state_file="$root/.harness/STATE.md"
  name="$(project_field "$root" project name)"
  _status_collect "$root"

  printf '# 현재 상태: %s\n\n' "$name"
  printf '정본: Task YAML의 status. STATE.md에서는 헤더와 상태표만 대조한다.\n\n'
  _status_state_header "$state_file"
  printf -- '- SPEC: %s\n' "$STATUS_SPEC"
  if (( ${#STATUS_WAVES[@]} > 0 )); then
    printf -- '- 열린 Wave:'
    for line in "${STATUS_WAVES[@]}"; do
      printf ' %s(%s)' "${line%%$'\t'*}" "${line#*$'\t'}"
    done
    printf '\n'
  fi

  printf '\n## 사용자 승인·판단 대기\n\n'
  if (( ${#STATUS_PENDING[@]} > 0 )); then
    printf -- '- %s\n' "${STATUS_PENDING[@]}"
  else
    printf -- '- 없음\n'
  fi

  printf '\n## 진행 중 Task (completed 제외 %d개, 사람 판단이 필요한 순)\n\n' "${#STATUS_TASKS[@]}"
  if (( ${#STATUS_TASKS[@]} > 0 )); then
    printf '| Task | 상태 | Worker | Reviewer | 제목 |\n|---|---|---|---|---|\n'
    for line in "${STATUS_TASKS[@]}"; do
      IFS=$'\x1f' read -r rank task status worker reviewer title state_status <<<"$line"
      printf '| %s | %s | %s | %s | %s |\n' "$task" "$status" "$(_status_md_cell "$worker")" \
        "$(_status_md_cell "$reviewer")" "$(_status_md_cell "$title")"
    done
  else
    printf -- '- 없음\n'
  fi

  if (( ${#STATUS_MISMATCH[@]} + ${#STATUS_STATE_ONLY[@]} > 0 )); then
    printf '\n## STATE.md 갱신 필요\n\n'
    (( ${#STATUS_MISMATCH[@]} == 0 )) || printf -- '- %s\n' "${STATUS_MISMATCH[@]}"
    (( ${#STATUS_STATE_ONLY[@]} == 0 )) || printf -- '- %s\n' "${STATUS_STATE_ONLY[@]}"
  fi

  printf '\n완료 Task %d개는 생략했다.' "$STATUS_DONE_COUNT"
  if [[ -f "$state_file" ]]; then
    total_lines="$(wc -l <"$state_file")"
    narrative="$(awk '/^## / { sub(/^## /, ""); printf "%s%s", sep, $0; sep = ", " }' "$state_file")"
    printf ' STATE.md는 %s줄이다' "$total_lines"
    [[ -z "$narrative" ]] || printf ' — 서술 섹션(%s)은 작성 시점의 기록이며 현재 할 일이 아니다' "$narrative"
    printf '.\n원문 전체: %s status %s --full\n' "$SCRIPT_NAME" "$root"
  else
    printf ' STATE.md가 없다.\n'
  fi
}

# status --json과 status --live --json이 함께 쓰는 요약 필드(앞에 쉼표 없음).
_status_json_summary_fields() {
  local root="$1" line rank task status worker reviewer title state_status first=1
  _status_collect "$root"
  printf '"spec_status":"%s","tasks":[' "$(_runtime_json_escape "$STATUS_SPEC")"
  for line in "${STATUS_TASKS[@]}"; do
    IFS=$'\x1f' read -r rank task status worker reviewer title state_status <<<"$line"
    (( first == 1 )) || printf ','
    first=0
    printf '{"task":"%s","status":"%s","worker":"%s","reviewer":"%s","title":"%s","state_md_status":"%s"}' \
      "$(_runtime_json_escape "$task")" "$(_runtime_json_escape "$status")" \
      "$(_runtime_json_escape "$worker")" "$(_runtime_json_escape "$reviewer")" \
      "$(_runtime_json_escape "$title")" "$(_runtime_json_escape "$state_status")"
  done
  printf '],"completed_count":%d,"attention":[' "$STATUS_DONE_COUNT"
  first=1
  for line in "${STATUS_PENDING[@]}" "${STATUS_MISMATCH[@]}" "${STATUS_STATE_ONLY[@]}"; do
    (( first == 1 )) || printf ','
    first=0
    printf '"%s"' "$(_runtime_json_escape "$line")"
  done
  printf ']'
}

_status_pending_approval_tasks() {
  local root="$1" task path approval
  while IFS= read -r task; do
    [[ -n "$task" ]] || continue
    path="$root/.harness/tasks/$task.yaml"
    [[ "$(_runtime_yaml_scalar "$path" status)" == awaiting_approval ]] || continue
    approval="$root/.harness/decisions/$task-approval.md"
    if [[ ! -f "$approval" ]] || ! grep -q '^승인:[[:space:]]*yes' "$approval"; then
      printf '%s\n' "$task"
    fi
  done < <(task_ids "$root")
}

cmd_status_live() {
  local path="${1:-.}" json=0 full=0
  if [[ "$path" == --json ]]; then json=1; path=.; shift; else shift || true; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1 ;;
      --full) full=1 ;;
      *) die "알 수 없는 status --live 옵션: $1" ;;
    esac
    shift
  done
  local root agent_list agent_status git_status records_file pending_file meta task role agent_name pane_id
  local task_path document_status herdr_status verdict matched_object approval first
  root="$(project_root "$path")"
  set +e
  agent_list="$(herdr agent list 2>&1)"
  agent_status=$?
  set -e
  git_status="$(git -C "$root" status --short 2>&1 || true)"
  mkdir -p "$root/.harness/runtime"
  records_file="$(mktemp "$root/.harness/runtime/.status-records.XXXXXX")"
  pending_file="$(mktemp "$root/.harness/runtime/.status-pending.XXXXXX")"
  trap "rm -f -- '$records_file' '$pending_file'" RETURN

  shopt -s nullglob
  for meta in "$root"/.harness/runtime/*.meta; do
    task="$(_runtime_meta_value "$meta" task_id)"
    role="$(_runtime_meta_value "$meta" role)"
    agent_name="$(_runtime_meta_value "$meta" agent_name)"
    pane_id="$(_runtime_meta_value "$meta" pane_id)"
    [[ -n "$task" && -n "$role" && -n "$agent_name" && -n "$pane_id" ]] || continue

    task_path="$root/.harness/tasks/$task.yaml"
    if [[ -f "$task_path" ]]; then
      document_status="$(yaml_scalar "$task_path" status)"
    else
      document_status=missing
    fi

    herdr_status=missing
    if (( agent_status == 0 )); then
      if command -v jq >/dev/null 2>&1; then
        herdr_status="$(printf '%s' "$agent_list" | jq -r --arg name "$agent_name" --arg pane "$pane_id" '.result.agents[]? | select(.name == $name and .pane_id == $pane) | .agent_status' 2>/dev/null | head -n 1 || true)"
      else
        matched_object="$(printf '%s' "$agent_list" | sed 's/},{/}\n{/g' | grep -F "\"name\":\"$agent_name\"" | grep -F "\"pane_id\":\"$pane_id\"" | head -n 1 || true)"
        [[ -z "$matched_object" ]] || herdr_status="$(_runtime_json_field "$matched_object" agent_status)"
      fi
      herdr_status="${herdr_status:-missing}"
    else
      herdr_status=unavailable
    fi

    if [[ "$document_status" == active && "$herdr_status" == missing ]]; then
      verdict=DRIFT
    elif [[ "$document_status" == active && "$herdr_status" == unavailable ]]; then
      verdict=DRIFT
    elif [[ "$document_status" != active && "$herdr_status" != missing && "$herdr_status" != unavailable ]]; then
      verdict=ORPHAN
    else
      verdict=OK
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$task" "$role" "$document_status" "$agent_name" "$pane_id" "$herdr_status" "$verdict" >>"$records_file"
  done

  while IFS= read -r task; do
    [[ -n "$task" ]] || continue
    task_path="$root/.harness/tasks/$task.yaml"
    document_status="$(yaml_scalar "$task_path" status)"
    if [[ "$document_status" == active ]] && ! awk -F'\t' -v task="$task" '$1 == task { found=1 } END { exit !found }' "$records_file"; then
      printf '%s\t-\t%s\t-\t-\tmissing\tDRIFT\n' "$task" "$document_status" >>"$records_file"
    fi
    if [[ "$document_status" == awaiting_approval ]]; then
      approval="$root/.harness/decisions/$task-approval.md"
      if [[ ! -f "$approval" ]] || ! grep -q '^승인:[[:space:]]*yes' "$approval"; then
        printf '%s\n' "$task" >>"$pending_file"
      fi
    fi
  done < <(task_ids "$root")
  shopt -u nullglob

  if (( json == 1 )); then
    # "state"(STATE.md 원문)는 기존 소비자와의 계약이라 그대로 둔다. 현재 상태
    # 판단에는 뒤에 붙는 요약 필드(tasks·attention)를 쓴다.
    printf '{"state":"%s","herdr_available":%s,' \
      "$(_runtime_json_escape "$(cat "$root/.harness/STATE.md")")" "$([[ "$agent_status" -eq 0 ]] && printf true || printf false)"
    _status_json_summary_fields "$root"
    printf ',"agents":[' 
    first=1
    while IFS=$'\t' read -r task role document_status agent_name pane_id herdr_status verdict; do
      (( first == 1 )) || printf ','
      first=0
      printf '{"task":"%s","role":"%s","document_status":"%s","agent":"%s","pane":"%s","herdr_status":"%s","verdict":"%s"}' \
        "$(_runtime_json_escape "$task")" "$(_runtime_json_escape "$role")" "$(_runtime_json_escape "$document_status")" \
        "$(_runtime_json_escape "$agent_name")" "$(_runtime_json_escape "$pane_id")" "$(_runtime_json_escape "$herdr_status")" "$(_runtime_json_escape "$verdict")"
    done <"$records_file"
    printf '],"git_status":"%s","pending_decisions":[' "$(_runtime_json_escape "$git_status")"
    first=1
    while IFS= read -r task; do
      [[ -n "$task" ]] || continue
      (( first == 1 )) || printf ','
      first=0
      printf '"%s"' "$(_runtime_json_escape "$task")"
    done <"$pending_file"
    printf ']}\n'
  else
    if (( full == 1 )); then
      cat "$root/.harness/STATE.md"
    else
      _status_print_summary "$root"
    fi
    printf '\n## Live Herdr agents\n\n'
    printf '| Task | Role | 문서상태 | Agent | Pane | Herdr상태 | 판정 |\n'
    printf '|---|---|---|---|---|---|---|\n'
    if [[ -s "$records_file" ]]; then
      while IFS=$'\t' read -r task role document_status agent_name pane_id herdr_status verdict; do
        printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$task" "$role" "$document_status" "$agent_name" "$pane_id" "$herdr_status" "$verdict"
      done <"$records_file"
    else
      printf '| - | - | - | - | - | - | OK |\n'
    fi
    [[ "$agent_status" -eq 0 ]] || printf '\n경고: Herdr Agent 목록을 조회하지 못했습니다.\n'
    printf '\n## Git status --short\n\n%s\n' "${git_status:-clean}"
    printf '\n## 승인 대기 (계산됨)\n\n'
    if [[ -s "$pending_file" ]]; then
      while IFS= read -r task; do printf -- '- %s: completed 사용자 승인 필요\n' "$task"; done <"$pending_file"
    else
      printf -- '- 없음\n'
    fi
  fi
  rm -f -- "$records_file" "$pending_file"
}

cmd_doctor() {
  local failed=0 command_name harness_dir
  harness_dir="$(dirname "$(readlink -f "$SELF_PATH")")"
  printf '[OK]      %-8s %s (지문 %s)\n' harness "$harness_dir" "$(_harness_fingerprint "$harness_dir")"
  for command_name in herdr git claude codex agy; do
    if command -v "$command_name" >/dev/null 2>&1; then
      printf '[OK]      %-8s %s\n' "$command_name" "$(command -v "$command_name")"
    else
      printf '[MISSING] %-8s\n' "$command_name"
      [[ "$command_name" == herdr || "$command_name" == git ]] && failed=1
    fi
  done

  # 원격 실행 모드용 도구는 옵션이다 — 없다고 doctor를 실패시키지 않는다.
  # 프로젝트별 연결 진단은 `herdr-harness remote [PATH] doctor`가 한다.
  for command_name in ssh sshfs sshpass; do
    if command -v "$command_name" >/dev/null 2>&1; then
      printf '[OK]      %-8s %s\n' "$command_name" "$(command -v "$command_name")"
    else
      printf '[OPTION]  %-8s (원격 실행 모드에서만 필요)\n' "$command_name"
    fi
  done
  if command -v herdr >/dev/null 2>&1; then
    printf '\nHerdr version:\n'
    herdr --version || true
    printf '\nHerdr integrations:\n'
    herdr integration status || true
  fi
  return "$failed"
}

project_root() {
  local path="${1:-.}"
  path="$(realpath -m "$path")"
  [[ -f "$path/.harness/project.yaml" ]] || die "Harness 프로젝트가 아닙니다: $path"
  printf '%s\n' "$path"
}

cmd_status() {
  local live=0 json=0 full=0 root_arg="."
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --live) live=1; shift ;;
      --json) json=1; shift ;;
      --full) full=1; shift ;;
      -h|--help) printf '사용법: %s status [PATH] [--live] [--json] [--full]\n' "$SCRIPT_NAME"; return 0 ;;
      -*) die "알 수 없는 status 옵션: $1" ;;
      *) root_arg="$1"; shift ;;
    esac
  done
  local root
  root="$(project_root "$root_arg")"
  if [[ "$live" -eq 1 ]]; then
    local -a live_args=()
    (( json == 0 )) || live_args+=(--json)
    (( full == 0 )) || live_args+=(--full)
    cmd_status_live "$root" "${live_args[@]}"
    return $?
  fi
  if (( json == 1 )); then
    local task first=1
    printf '{'
    _status_json_summary_fields "$root"
    printf ',"pending_decisions":['
    while IFS= read -r task; do
      [[ -n "$task" ]] || continue
      (( first == 1 )) || printf ','
      first=0
      printf '"%s"' "$(_runtime_json_escape "$task")"
    done < <(_status_pending_approval_tasks "$root")
    printf ']}\n'
    return 0
  fi
  if (( full == 1 )); then
    cat "$root/.harness/STATE.md"
    return 0
  fi
  _status_print_summary "$root"
}

cmd_start() {
  local root name orchestrator
  root="$(project_root "${1:-.}")"
  command -v herdr >/dev/null 2>&1 || die "herdr 명령을 찾을 수 없습니다. herdr-harness doctor를 실행하세요."
  name="$(awk -F': ' '/^  name:/{gsub(/[\047\042]/,"",$2); print $2; exit}' "$root/.harness/project.yaml")"
  orchestrator="$(awk -F': ' '/^  orchestrator:/{gsub(/[\047\042]/,"",$2); print $2; exit}' "$root/.harness/project.yaml")"
  printf 'Herdr Session: %s\n' "$name"
  printf '첫 Pane에서 %s를 실행한 뒤 HARNESS_START.md의 Prompt를 입력하세요.\n\n' "$orchestrator"
  cd "$root"
  exec herdr --session "$name"
}

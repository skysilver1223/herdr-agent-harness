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

# herdr agent list의 최상위 Agent 객체를 한 줄씩 낸다. jq는 선택 의존성이므로
# 없을 때도 문자열 escape와 객체·배열 깊이를 세어 agents 배열의 객체 경계를
# 복원한다. 이 방식은 result/type의 필드 순서나 agents 뒤의 wrapper suffix에
# 의존하지 않고, 빈 배열과 agent_session 같은 중첩 객체도 안전하게 처리한다.
_status_agent_objects() {
  local input="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -c '.result.agents[]?' 2>/dev/null || true
    return
  fi
  printf '%s' "$input" | awk '
    { json = json $0 }
    END {
      if (!match(json, /"agents"[[:space:]]*:[[:space:]]*\[/)) exit
      array_depth = 1
      object_depth = 0
      object_start = 0
      in_string = 0
      escaped = 0
      start = RSTART + RLENGTH
      for (i = start; i <= length(json); i++) {
        char = substr(json, i, 1)
        if (in_string) {
          if (escaped) escaped = 0
          else if (char == "\\") escaped = 1
          else if (char == "\"") in_string = 0
          continue
        }
        if (char == "\"") { in_string = 1; continue }
        if (char == "[") { array_depth++; continue }
        if (char == "]") {
          if (array_depth == 1) break
          array_depth--
          continue
        }
        if (char == "{") {
          if (array_depth == 1 && object_depth == 0) object_start = i
          object_depth++
          continue
        }
        if (char == "}") {
          object_depth--
          if (array_depth == 1 && object_depth == 0 && object_start > 0) {
            print substr(json, object_start, i - object_start + 1)
            object_start = 0
          }
        }
      }
    }
  '
}

cmd_status_live() {
  local path="${1:-.}" json=0
  if [[ "$path" == --json ]]; then json=1; path=.; shift; else shift || true; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in --json) json=1 ;; *) die "알 수 없는 status --live 옵션: $1" ;; esac
    shift
  done
  local root agent_list agent_status git_status records_file pending_file agents_file meta task role agent_name pane_id
  local task_path document_status herdr_status verdict matched_object approval first agent_object agent_cwd foreground_cwd
  root="$(project_root "$path")"
  set +e
  agent_list="$(herdr agent list 2>&1)"
  agent_status=$?
  set -e
  git_status="$(git -C "$root" status --short 2>&1 || true)"
  mkdir -p "$root/.harness/runtime"
  records_file="$(mktemp "$root/.harness/runtime/.status-records.XXXXXX")"
  pending_file="$(mktemp "$root/.harness/runtime/.status-pending.XXXXXX")"
  agents_file="$(mktemp "$root/.harness/runtime/.status-agents.XXXXXX")"
  trap "rm -f -- '$records_file' '$pending_file' '$agents_file'" RETURN
  if (( agent_status == 0 )); then
    _status_agent_objects "$agent_list" >"$agents_file"
  fi

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
      matched_object="$(grep -F "\"name\":\"$agent_name\"" "$agents_file" | grep -F "\"pane_id\":\"$pane_id\"" | head -n 1 || true)"
      [[ -z "$matched_object" ]] || herdr_status="$(_runtime_json_field "$matched_object" agent_status)"
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

  # meta에서 시작하면 덮어쓰기로 추적을 잃은 이전 Agent는 순회 대상 자체가
  # 되지 않는다. Herdr 목록도 반대 방향으로 대조하되, 이 프로젝트 cwd에
  # 속하고 Harness 명명 규칙(hh-*)을 쓰는 Agent만 ORPHAN 사실로 표시한다.
  if (( agent_status == 0 )); then
    while IFS= read -r agent_object; do
      [[ -n "$agent_object" ]] || continue
      agent_name="$(_runtime_json_field "$agent_object" name)"
      [[ "$agent_name" == hh-* ]] || continue
      pane_id="$(_runtime_json_field "$agent_object" pane_id)"
      [[ -n "$pane_id" ]] || continue
      agent_cwd="$(_runtime_json_field "$agent_object" cwd)"
      foreground_cwd="$(_runtime_json_field "$agent_object" foreground_cwd)"
      [[ "$agent_cwd" == "$root" || "$foreground_cwd" == "$root" ]] || continue
      if awk -F'\t' -v name="$agent_name" -v pane="$pane_id" \
          '$4 == name && $5 == pane { found=1 } END { exit !found }' "$records_file"; then
        continue
      fi
      herdr_status="$(_runtime_json_field "$agent_object" agent_status)"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        - - untracked "$agent_name" "$pane_id" "${herdr_status:-unknown}" ORPHAN >>"$records_file"
    done <"$agents_file"
  fi

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
    printf '{"state":"%s","herdr_available":%s,"agents":[' \
      "$(_runtime_json_escape "$(cat "$root/.harness/STATE.md")")" "$([[ "$agent_status" -eq 0 ]] && printf true || printf false)"
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
    cat "$root/.harness/STATE.md"
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
  rm -f -- "$records_file" "$pending_file" "$agents_file"
}

cmd_doctor() {
  local failed=0 command_name
  for command_name in herdr git claude codex agy; do
    if command -v "$command_name" >/dev/null 2>&1; then
      printf '[OK]      %-8s %s\n' "$command_name" "$(command -v "$command_name")"
    else
      printf '[MISSING] %-8s\n' "$command_name"
      [[ "$command_name" == herdr || "$command_name" == git ]] && failed=1
    fi
  done

  # jq는 이미 lib/50-runtime.sh·lib/70-status.sh 자기 자신·lib/52-models.sh가
  # 쓰는 선택 의존성이다. 없어도 doctor는 실패시키지 않되, 없을 때 안 되는
  # 동작(codex 모델 조회)을 구체적으로 알린다 — 조용히 빈 목록만 나오는 것이
  # 가장 나쁜 결과다.
  if command -v jq >/dev/null 2>&1; then
    printf '[OK]      %-8s %s\n' jq "$(command -v jq)"
  else
    printf '[OPTION]  %-8s (없으면 codex 모델 조회(models --refresh)가 안 됨)\n' jq
  fi

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
  local live=0 json=0 root_arg="."
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --live) live=1; shift ;;
      --json) json=1; shift ;;
      -h|--help) printf '사용법: %s status [PATH] [--live] [--json]\n' "$SCRIPT_NAME"; return 0 ;;
      -*) die "알 수 없는 status 옵션: $1" ;;
      *) root_arg="$1"; shift ;;
    esac
  done
  local root
  root="$(project_root "$root_arg")"
  if [[ "$live" -eq 1 ]]; then
    if [[ "$json" -eq 1 ]]; then
      cmd_status_live "$root" --json
    else
      cmd_status_live "$root"
    fi
    return $?
  fi
  cat "$root/.harness/STATE.md"
}

# ---------------------------------------------------------------------------
# report — Task YAML을 정본으로 한 완료 요약·진척율. 기본 경로는 읽기 전용이며
# Herdr를 호출하지 않는다. 실시간 Pane 대조는 명시적인 --live에서만 한다.
# ---------------------------------------------------------------------------

_report_statuses() {
  # 모든 유효 상태를 고정 순서로 낸다. 드문 blocked/handover_required도 빼면
  # 상태별 합계가 전체 Task 수와 달라져 진척율 정본이라는 약속을 어기게 된다.
  printf '%s\n' completed reviewing awaiting_approval active submitted ready queued draft \
    changes_requested blocked handover_required
}

_report_current_wave() {
  # 현재 Wave는 Wave 문서 상태가 아니라 실제 Task 진행으로 고른다. 끝난 옛
  # approved Wave가 정리되지 않아도 그것을 현재 작업으로 잘못 보이지 않게,
  # 미완료 Task를 하나라도 가진 Wave 중 파일명상 가장 최신 것을 택한다.
  # 그런 Wave가 없을 때만 가장 최신 Wave를 안전한 표시용 fallback으로 쓴다.
  local root="$1" path task_id task_path status latest_wave="" latest_incomplete=""
  local -a wave_paths=()
  mapfile -t wave_paths < <(compgen -G "$root/.harness/waves/*.yaml" | LC_ALL=C sort)
  for path in "${wave_paths[@]}"; do
    [[ "${path##*/}" != TEMPLATE.yaml ]] || continue
    latest_wave="$(basename "$path" .yaml)"
    while IFS= read -r task_id; do
      [[ -n "$task_id" ]] || continue
      task_path="$root/.harness/tasks/$task_id.yaml"
      [[ -f "$task_path" ]] || continue
      status="$(yaml_scalar "$task_path" status)"
      if [[ "$status" != completed ]]; then
        latest_incomplete="$latest_wave"
        break
      fi
    done < <(_report_wave_task_ids "$path")
  done
  printf '%s\n' "${latest_incomplete:-$latest_wave}"
}

_report_wave_task_ids() {
  # Wave의 고정 tasks: 목록만 읽는다. 범용 YAML 파서가 아니라 Harness 템플릿의
  # "- task_id:" 항목만 허용하므로, 산문에 task_id:가 있어도 Task로 세지 않는다.
  local wave_path="$1"
  [[ -f "$wave_path" ]] || return 0
  awk '
    /^tasks:[[:space:]]*$/ { inside = 1; next }
    inside && /^[^[:space:]#]/ { exit }
    inside && /^[[:space:]]*-[[:space:]]*task_id:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*task_id:[[:space:]]*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line ~ /^\047.*\047$/ || line ~ /^".*"$/) line = substr(line, 2, length(line) - 2)
      print line
    }
  ' "$wave_path"
}

_report_attempt_count() {
  local root="$1" task_id="$2" path count=0
  shopt -s nullglob
  for path in "$root/.harness/attempts/$task_id-attempt-"*.md; do
    [[ "${path##*/}" =~ ^"$task_id"-attempt-[0-9]+\.md$ ]] || continue
    count=$((count + 1))
  done
  shopt -u nullglob
  printf '%s' "$count"
}

_report_latest_completed_task() {
  # events.tsv는 append-only이므로 마지막 completed 전이의 Task가 수동 report의
  # "가장 최근 완료"다. 과거 Harness 또는 사람이 만든 fixture처럼 이력이 없으면
  # Task ID 정렬의 마지막 completed Task로 결정적으로 fallback한다.
  local root="$1" events="$root/.harness/evidence/events.tsv"
  local stamp event task_id from_state to_state detail path latest=""
  if [[ -f "$events" ]]; then
    while IFS=$'\t' read -r stamp event task_id from_state to_state detail; do
      [[ "$event" == transition && "$to_state" == completed ]] || continue
      path="$root/.harness/tasks/$task_id.yaml"
      [[ -f "$path" ]] || continue
      [[ "$(yaml_scalar "$path" status)" == completed ]] || continue
      latest="$task_id"
    done < "$events"
  fi
  if [[ -z "$latest" ]]; then
    while IFS= read -r task_id; do
      path="$root/.harness/tasks/$task_id.yaml"
      [[ "$(yaml_scalar "$path" status)" == completed ]] || continue
      latest="$task_id"
    done < <(task_ids "$root" | LC_ALL=C sort)
  fi
  printf '%s\n' "$latest"
}

_report_latest_checks_summary() {
  local root="$1" task_id="$2" attempt path total passed failed manual
  attempt="$(_runtime_latest_existing "$root" "$task_id-attempt-" "-checks.yaml")"
  [[ -n "$attempt" ]] || { printf '%s' '없음'; return 0; }
  path="$root/.harness/evidence/$task_id-attempt-$attempt-checks.yaml"
  [[ -f "$path" ]] || { printf '%s' '없음'; return 0; }
  total="$(awk '/^  total:/{print $2; exit}' "$path")"
  passed="$(awk '/^  passed:/{print $2; exit}' "$path")"
  failed="$(awk '/^  failed:/{print $2; exit}' "$path")"
  manual="$(awk '/^  manual:/{print $2; exit}' "$path")"
  printf 'Attempt %s: pass %s / manual %s / fail %s (전체 %s)' "$attempt" \
    "${passed:-0}" "${manual:-0}" "${failed:-0}" "${total:-0}"
}

_report_progress_line() {
  local label="$1" completed="$2" total="$3" width=20 filled=0 empty percent=0 bar
  if (( total > 0 )); then
    percent=$((completed * 100 / total))
    filled=$((completed * width / total))
  fi
  empty=$((width - filled))
  printf -v bar '%*s' "$filled" ''
  bar="${bar// /#}"
  printf -v empty '%*s' "$empty" ''
  empty="${empty// /-}"
  printf '%s [%s%s] %s/%s (%s%%)\n' "$label" "$bar" "$empty" "$completed" "$total" "$percent"
}

_report_state_row_status() {
  # STATE.md의 첫 Task 열만 대조한다. 표가 없거나 사람이 상태 열을 빼면 빈
  # 값으로 두어 "드리프트 없음"이라고 거짓말하지 않고 호출자가 경고를 낸다.
  local state_file="$1" task_id="$2"
  [[ -f "$state_file" ]] || return 0
  awk -F'|' -v wanted="$task_id" '
    function trim(value) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); return value }
    /^[[:space:]]*\|/ {
      if (trim($2) != wanted) next
      found = 1
      for (i = 3; i < NF; i++) {
        value = trim($i)
        if (value == "draft" || value == "queued" || value == "ready" || value == "active" ||
            value == "submitted" || value == "reviewing" || value == "changes_requested" ||
            value == "blocked" || value == "handover_required" || value == "awaiting_approval" ||
            value == "completed") {
          print value
          exit
        }
      }
    }
    END { if (found && !printed) exit 0 }
  ' "$state_file"
}

_report_live_summary() {
  local root="$1" agent_list status meta agent_name pane_id agent_object found tracked=0 missing=0
  set +e
  agent_list="$(herdr agent list 2>/dev/null)"
  status=$?
  set -e
  if (( status != 0 )); then
    printf 'Herdr 대조: 조회 불가 (--live는 선택 사항이며 상태를 바꾸지 않습니다)'
    return 0
  fi

  shopt -s nullglob
  for meta in "$root"/.harness/runtime/*.meta; do
    agent_name="$(_runtime_meta_value "$meta" agent_name)"
    pane_id="$(_runtime_meta_value "$meta" pane_id)"
    [[ -n "$agent_name" && -n "$pane_id" ]] || continue
    tracked=$((tracked + 1))
    found=0
    while IFS= read -r agent_object; do
      grep -Fq "\"name\":\"$agent_name\"" <<<"$agent_object" || continue
      grep -Fq "\"pane_id\":\"$pane_id\"" <<<"$agent_object" || continue
      found=1
      break
    done < <(_status_agent_objects "$agent_list")
    if (( found == 0 )); then
      missing=$((missing + 1))
    fi
  done
  shopt -u nullglob
  printf 'Herdr 대조: 추적 Agent %s, 목록에서 누락 %s' "$tracked" "$missing"
}

cmd_report() {
  local root_arg="." live=0 json=0 all=0 requested_task=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --live) live=1 ;;
      --json) json=1 ;;
      --all) all=1 ;;
      --task)
        [[ $# -ge 2 ]] || die "--task 값이 필요합니다."
        [[ -z "$requested_task" ]] || die "--task 옵션이 중복됐습니다."
        requested_task="$2"
        shift ;;
      -h|--help)
        printf '사용법: %s report [PATH] [--task TASK_ID|--all] [--live] [--json]\n' "$SCRIPT_NAME"
        return 0 ;;
      -*) die "알 수 없는 report 옵션: $1" ;;
      *) root_arg="$1" ;;
    esac
    shift
  done

  [[ "$all" -eq 0 || -z "$requested_task" ]] ||
    die "--task 와 --all 은 함께 쓸 수 없습니다."

  local root wave wave_path task_id path status title worker reviewer worker_model reviewer_model
  local total=0 wave_total=0 active_slots=0 max_active=0 current_state state_row
  local -A counts=() wave_counts=() wave_members=()
  local -a completed_tasks=() ready_tasks=() queued_tasks=() approval_tasks=() promotable_tasks=() drifts=()
  root="$(project_root "$root_arg")"
  wave="$(_report_current_wave "$root")"
  if [[ -n "$wave" ]]; then
    wave_path="$root/.harness/waves/$wave.yaml"
    while IFS= read -r task_id; do
      [[ -n "$task_id" ]] && wave_members["$task_id"]=1
    done < <(_report_wave_task_ids "$wave_path")
  fi
  while IFS= read -r status; do
    counts["$status"]=0
    wave_counts["$status"]=0
  done < <(_report_statuses)

  while IFS= read -r task_id; do
    [[ -n "$task_id" ]] || continue
    path="$root/.harness/tasks/$task_id.yaml"
    status="$(yaml_scalar "$path" status)"
    counts["$status"]=$(( ${counts[$status]:-0} + 1 ))
    total=$((total + 1))
    task_uses_active_slot "$status" && active_slots=$((active_slots + 1))
    if [[ -n "${wave_members[$task_id]:-}" ]]; then
      wave_counts["$status"]=$(( ${wave_counts[$status]:-0} + 1 ))
      wave_total=$((wave_total + 1))
    fi
    [[ "$status" == completed ]] && completed_tasks+=("$task_id")
    [[ "$status" == ready ]] && ready_tasks+=("$task_id")
    [[ "$status" == queued ]] && queued_tasks+=("$task_id")
    [[ "$status" == awaiting_approval ]] && approval_tasks+=("$task_id")
    state_row="$(_report_state_row_status "$root/.harness/STATE.md" "$task_id")"
    if [[ -n "$state_row" && "$state_row" != "$status" ]]; then
      drifts+=("$task_id: STATE.md=$state_row, YAML=$status")
    fi
  done < <(task_ids "$root" | LC_ALL=C sort)

  # 완료 요약은 평소 한 건만 보여 준다. 자동 completed 경로는 --task로 방금
  # 끝난 Task를 명시하고, 수동 기본은 event log의 최신 completed 전이를 따른다.
  if [[ -n "$requested_task" ]]; then
    path="$root/.harness/tasks/$requested_task.yaml"
    [[ -f "$path" ]] || die "Task 파일이 없습니다: $path"
    [[ "$(yaml_scalar "$path" status)" == completed ]] ||
      die "완료된 Task만 요약할 수 있습니다: $requested_task"
    completed_tasks=("$requested_task")
  elif (( all == 0 )); then
    task_id="$(_report_latest_completed_task "$root")"
    if [[ -n "$task_id" ]]; then
      completed_tasks=("$task_id")
    else
      completed_tasks=()
    fi
  fi

  max_active="$(project_max_active_tasks "$root")"
  local available=$((max_active - active_slots))
  if (( available > 0 )); then
    for task_id in "${queued_tasks[@]}"; do
      path="$root/.harness/tasks/$task_id.yaml"
      _transition_dependencies_complete "$root" "$path" || continue
      promotable_tasks+=("$task_id")
      available=$((available - 1))
      (( available > 0 )) || break
    done
  fi

  if (( json == 1 )); then
    local first=1
    printf '{"completed":['
    for task_id in "${completed_tasks[@]}"; do
      path="$root/.harness/tasks/$task_id.yaml"
      title="$(yaml_scalar "$path" title optional)"
      worker="$(yaml_scalar "$path" primary_worker optional)"; reviewer="$(yaml_scalar "$path" reviewer optional)"
      worker_model="$(yaml_scalar "$path" worker_model optional)"; reviewer_model="$(yaml_scalar "$path" reviewer_model optional)"
      (( first == 1 )) || printf ','; first=0
      printf '{"task":"%s","title":"%s","worker":{"provider":"%s","model":"%s"},"reviewer":{"provider":"%s","model":"%s"},"review":"%s","acceptance":"%s","attempts":%s}' \
        "$(_runtime_json_escape "$task_id")" "$(_runtime_json_escape "$title")" \
        "$(_runtime_json_escape "$worker")" "$(_runtime_json_escape "${worker_model:-default}")" \
        "$(_runtime_json_escape "$reviewer")" "$(_runtime_json_escape "${reviewer_model:-default}")" \
        "$(_runtime_json_escape "$(latest_task_review "$root" "$task_id" | xargs -r basename 2>/dev/null || true)")" \
        "$(_runtime_json_escape "$(_report_latest_checks_summary "$root" "$task_id")")" \
        "$(_report_attempt_count "$root" "$task_id")"
    done
    printf '],"progress":{"wave":{"id":"%s","total":%s,"completed":%s},"overall":{"total":%s,"completed":%s},"states":{' \
      "$(_runtime_json_escape "${wave:-none}")" "$wave_total" "${wave_counts[completed]:-0}" "$total" "${counts[completed]:-0}"
    first=1
    while IFS= read -r status; do
      (( first == 1 )) || printf ','; first=0
      printf '"%s":%s' "$status" "${counts[$status]:-0}"
    done < <(_report_statuses)
    printf '},"wave_states":{'
    first=1
    while IFS= read -r status; do
      (( first == 1 )) || printf ','; first=0
      printf '"%s":%s' "$status" "${wave_counts[$status]:-0}"
    done < <(_report_statuses)
    printf '}},"next":{"ready":['
    first=1; for task_id in "${ready_tasks[@]}"; do (( first == 1 )) || printf ','; first=0; printf '"%s"' "$(_runtime_json_escape "$task_id")"; done
    printf '],"promotable_queued":['
    first=1; for task_id in "${promotable_tasks[@]}"; do (( first == 1 )) || printf ','; first=0; printf '"%s"' "$(_runtime_json_escape "$task_id")"; done
    printf '],"awaiting_approval":['
    first=1; for task_id in "${approval_tasks[@]}"; do (( first == 1 )) || printf ','; first=0; printf '"%s"' "$(_runtime_json_escape "$task_id")"; done
    printf ']},"warnings":{"state_drift":['
    first=1; for current_state in "${drifts[@]}"; do (( first == 1 )) || printf ','; first=0; printf '"%s"' "$(_runtime_json_escape "$current_state")"; done
    printf '],"active_slots":%s,"max_active_tasks":%s,"over_limit":%s' "$active_slots" "$max_active" "$([[ "$active_slots" -gt "$max_active" ]] && printf true || printf false)"
    if (( live == 1 )); then printf ',"live":"%s"' "$(_runtime_json_escape "$(_report_live_summary "$root")")"; fi
    printf '}}\n'
    return 0
  fi

  printf '## 완료된 Task 요약\n\n'
  if (( ${#completed_tasks[@]} == 0 )); then
    printf -- '- 없음\n'
  else
    for task_id in "${completed_tasks[@]}"; do
      path="$root/.harness/tasks/$task_id.yaml"
      title="$(yaml_scalar "$path" title optional)"
      worker="$(yaml_scalar "$path" primary_worker optional)"; reviewer="$(yaml_scalar "$path" reviewer optional)"
      worker_model="$(yaml_scalar "$path" worker_model optional)"; reviewer_model="$(yaml_scalar "$path" reviewer_model optional)"
      local review="$(latest_task_review "$root" "$task_id")" verdict="없음"
      [[ -n "$review" ]] && verdict="$(review_verdict "$review")"
      printf -- '- %s — %s\n  Worker: %s (%s), Reviewer: %s (%s)\n  최신 Review: %s, AC: %s, Attempt: %s\n' \
        "$task_id" "${title:-제목 없음}" "${worker:-미지정}" "${worker_model:-default}" \
        "${reviewer:-미지정}" "${reviewer_model:-default}" "${verdict:-불명}" \
        "$(_report_latest_checks_summary "$root" "$task_id")" "$(_report_attempt_count "$root" "$task_id")"
    done
  fi

  printf '\n## 진척율 (Task YAML 정본)\n\n'
  if [[ -n "$wave" ]]; then
    _report_progress_line "Wave $wave" "${wave_counts[completed]:-0}" "$wave_total"
    printf '  상태: '
    while IFS= read -r status; do printf '%s=%s ' "$status" "${wave_counts[$status]:-0}"; done < <(_report_statuses)
    printf '\n'
  else
    printf 'Wave: 선택 가능한 Wave가 없습니다 (0/0, 0%%)\n'
  fi
  _report_progress_line '전체' "${counts[completed]:-0}" "$total"
  printf '  상태: '
  while IFS= read -r status; do printf '%s=%s ' "$status" "${counts[$status]:-0}"; done < <(_report_statuses)
  printf '\n'

  printf '\n## 다음 할 일\n\n'
  if (( ${#ready_tasks[@]} )); then printf -- '- ready: %s\n' "${ready_tasks[*]}"; else printf -- '- ready: 없음\n'; fi
  if (( ${#promotable_tasks[@]} )); then printf -- '- 승격 가능한 queued: %s\n' "${promotable_tasks[*]}"; else printf -- '- 승격 가능한 queued: 없음\n'; fi
  if (( ${#approval_tasks[@]} )); then printf -- '- 사용자 승인 대기: %s\n' "${approval_tasks[*]}"; else printf -- '- 사용자 승인 대기: 없음\n'; fi

  printf '\n## 경고·드리프트\n\n'
  if (( ${#drifts[@]} )); then
    for current_state in "${drifts[@]}"; do printf -- '- %s\n' "$current_state"; done
  else
    printf -- '- STATE.md ↔ Task YAML 드리프트 없음\n'
  fi
  if (( active_slots > max_active )); then
    printf -- '- 활성 슬롯 상한 초과: %s > %s\n' "$active_slots" "$max_active"
  else
    printf -- '- 활성 슬롯: %s / %s\n' "$active_slots" "$max_active"
  fi
  (( live == 0 )) || printf -- '- %s\n' "$(_report_live_summary "$root")"
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

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

cmd_status_live() {
  local path="${1:-.}" json=0
  if [[ "$path" == --json ]]; then json=1; path=.; shift; else shift || true; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in --json) json=1 ;; *) die "알 수 없는 status --live 옵션: $1" ;; esac
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
  rm -f -- "$records_file" "$pending_file"
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

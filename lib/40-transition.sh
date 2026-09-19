# Part of herdr-harness. Sourced by harness.sh — do not run directly.

# ---------------------------------------------------------------------------
# validate — 읽기 전용 사전 검증. 상태를 바꾸지 않는다.
# ---------------------------------------------------------------------------

cmd_validate() {
  local root_arg="." wave="" strict_git=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wave) [[ $# -ge 2 ]] || die "--wave 값이 필요합니다."; wave="$2"; shift 2 ;;
      --no-git) strict_git=0; shift ;;
      -h|--help) printf '사용법: %s validate [PATH] [--wave ID] [--no-git]\n' "$SCRIPT_NAME"; return 0 ;;
      -*) die "알 수 없는 validate 옵션: $1" ;;
      *) root_arg="$1"; shift ;;
    esac
  done

  local root problems=0
  root="$(project_root "$root_arg")"

  report_problem() { printf '[FAIL] %s\n' "$*"; problems=$((problems + 1)); }
  report_ok() { printf '[OK]   %s\n' "$*"; }
  report_warn() { printf '[WARN] %s\n' "$*"; }

  # 1. Git 기준선
  local git_state
  git_state="$(git_baseline_status "$root")"
  if [[ "$git_state" == ok ]]; then
    report_ok "Git 기준선 존재"
  elif [[ "$strict_git" -eq 1 ]]; then
    report_problem "Git 기준선 없음 ($git_state). Diff 기반 Review·Handover·Context Packet을 만들 수 없습니다."
  else
    report_ok "Git 검사 생략 (--no-git)"
  fi

  # 2. SPEC 승인
  local spec_state
  spec_state="$(awk -F': ' '/^- 상태:/{print $2; exit}' "$root/.harness/SPEC.md" 2>/dev/null || true)"
  spec_state="${spec_state:-unknown}"
  if [[ "$spec_state" == approved ]]; then
    report_ok "SPEC 승인됨"
  else
    report_ok "SPEC 상태=$spec_state (구현 단계 전이는 승인 후에만 가능)"
  fi

  # 3. Provider 배정
  local p_worker p_reviewer
  p_worker="$(project_field "$root" providers primary_worker)"
  p_reviewer="$(project_field "$root" providers reviewer)"
  if [[ "$p_worker" == "$p_reviewer" ]]; then
    report_problem "project.yaml의 primary_worker와 reviewer가 같습니다: $p_worker"
  else
    report_ok "기본 Worker($p_worker) != Reviewer($p_reviewer)"
  fi

  # 4. 상한
  local max_active max_parallel
  max_active="$(project_max_active_tasks "$root")"
  max_parallel="$(awk '/^  max_parallel_workers:/{print $2; exit}' "$root/.harness/project.yaml")"

  # 5. Task별 검사
  local task_id path status worker reviewer dep
  local active_count=0 slot_count=0
  local -A scope_owner=()

  while IFS= read -r task_id; do
    [[ -n "$task_id" ]] || continue
    path="$root/.harness/tasks/${task_id}.yaml"
    local declared_id
    declared_id="$(yaml_scalar "$path" task_id)"
    [[ "$declared_id" == "$task_id" ]] ||
      report_problem "$task_id: 파일명과 task_id가 다릅니다 (task_id=$declared_id)"

    status="$(yaml_scalar "$path" status)"
    valid_task_status "$status" || report_problem "$task_id: 알 수 없는 status=$status"

    worker="$(yaml_scalar "$path" primary_worker)"
    reviewer="$(yaml_scalar "$path" reviewer)"
    if task_review_policy "$path"; then
      if [[ "$TASK_REVIEW_MODE" == manual ]]; then
        report_warn "$task_id: 독립 AI Review 생략, 수동 검토 후 사용자 승인 필요 (reason=$TASK_REVIEW_REASON)"
      fi
    else
      report_problem "$task_id: $TASK_REVIEW_POLICY_ERROR"
    fi

    if task_uses_active_slot "$status"; then
      slot_count=$((slot_count + 1))
    fi
    if [[ "$status" == active ]]; then
      active_count=$((active_count + 1))
      fi

    # 의존성: ready 이상으로 열려 있는 Task의 선행 Task는 completed여야 한다
    if [[ "$status" == ready || "$status" == active ]]; then
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        local dep_path dep_status
        dep_path="$root/.harness/tasks/${dep}.yaml"
        if [[ ! -f "$dep_path" ]]; then
          report_problem "$task_id: 의존 Task 파일이 없습니다: $dep"
          continue
        fi
        dep_status="$(yaml_scalar "$dep_path" status)"
        [[ "$dep_status" == completed ]] ||
          report_problem "$task_id: 의존 Task $dep 가 completed가 아닙니다 (현재 $dep_status)"
      done < <(yaml_flow_list "$path" dependencies)
    fi

    # write_scope 충돌: 동시에 active인 Task끼리만 검사
    if [[ "$status" == active ]]; then
      local scope
      while IFS= read -r scope; do
        [[ -n "$scope" ]] || continue
        if [[ -n "${scope_owner[$scope]:-}" ]]; then
          report_problem "write_scope 충돌: '$scope' 를 ${scope_owner[$scope]} 와 $task_id 가 동시에 소유"
        else
          scope_owner[$scope]="$task_id"
        fi
      done < <(yaml_flow_list "$path" write_scope)
    fi
  done < <(task_ids "$root")

  if [[ "$slot_count" -le "$max_active" ]]; then
    report_ok "활성 Task $slot_count / 상한 $max_active"
  else
    # 이미 진행 중인 레거시 Task를 validate가 임의로 되돌리거나 프로젝트
    # 전체를 막지는 않는다. 새 슬롯 진입은 transition의 queue lock이 막는다.
    report_warn "활성 Task가 상한을 초과했습니다: $slot_count > $max_active (기존 상태 유지, 신규 Task는 queued)"
  fi
  if [[ "$active_count" -le "${max_parallel:-2}" ]]; then
    report_ok "동시 Worker $active_count / 상한 ${max_parallel:-2}"
  else
    report_problem "동시 Worker가 상한을 초과했습니다: $active_count > ${max_parallel:-2}"
  fi

  # 6. Wave
  if [[ -n "$wave" ]]; then
    local wave_path wave_status
    wave_path="$root/.harness/waves/${wave}.yaml"
    if [[ ! -f "$wave_path" ]]; then
      report_problem "Wave 파일이 없습니다: $wave_path"
    else
      wave_status="$(yaml_scalar "$wave_path" status)"
      if [[ "$wave_status" == approved ]]; then
        report_ok "Wave $wave 승인됨"
      else
        report_problem "Wave $wave 가 승인되지 않았습니다 (status=$wave_status)"
      fi
    fi
  fi

  printf '\n'
  if [[ "$problems" -eq 0 ]]; then
    printf 'validate: 통과\n'
    return 0
  fi
  printf 'validate: %d개 문제\n' "$problems"
  return 1
}

# ---------------------------------------------------------------------------
# transition — 허용된 상태 전이만 수행한다. 판정을 대행하지 않는다.
# ---------------------------------------------------------------------------

transition_allowed() {
  local from="$1" to="$2"
  case "${from}>${to}" in
    'draft>ready') return 0 ;;
    'queued>ready') return 0 ;;
    'ready>active') return 0 ;;
    'active>submitted') return 0 ;;
    'active>blocked') return 0 ;;
    'active>handover_required') return 0 ;;
    'blocked>active') return 0 ;;
    'submitted>reviewing') return 0 ;;
    'submitted>awaiting_approval') return 0 ;;
    'reviewing>changes_requested') return 0 ;;
    'reviewing>awaiting_approval') return 0 ;;
    'changes_requested>ready') return 0 ;;
    'handover_required>ready') return 0 ;;
    'awaiting_approval>completed') return 0 ;;
    *) return 1 ;;
  esac
}

latest_task_review() {
  local root="$1" task_id="$2"
  ls -1t "$root/.harness/reviews/${task_id}"-*.md 2>/dev/null | head -n 1 || true
}

review_verdict() {
  local review="$1"
  sed -n 's/^\*\{0,2\}판정:[[:space:]]*\([A-Za-z_]*\).*/\1/p' "$review" | head -n 1
}

valid_approval_task_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

approval_record_matches() {
  local approval="$1" task_id="$2" review_relative="$3" policy_reason="${4:-}"
  [[ -f "$approval" ]] || return 1
  [[ "$(grep -c '^Task:' "$approval" 2>/dev/null || true)" -eq 1 ]] || return 1
  [[ "$(grep -c '^승인:' "$approval" 2>/dev/null || true)" -eq 1 ]] || return 1
  [[ "$(grep -c '^근거 Review:' "$approval" 2>/dev/null || true)" -eq 1 ]] || return 1
  grep -qxF "Task: $task_id" "$approval" || return 1
  grep -qxF '승인: yes' "$approval" || return 1
  grep -qxF "근거 Review: $review_relative" "$approval" || return 1
  if [[ -n "$policy_reason" ]]; then
    [[ "$(grep -c '^정책 예외 사유:' "$approval" 2>/dev/null || true)" -eq 1 ]] || return 1
    grep -qxF "정책 예외 사유: $policy_reason" "$approval"
  else
    [[ "$(grep -c '^정책 예외 사유:' "$approval" 2>/dev/null || true)" -eq 0 ]]
  fi
}

# ---------------------------------------------------------------------------
# Acceptance Criteria 게이트 — submitted 전이 시 Harness가 직접 검증한다.
#
# 지금까지 "verified_by 명령을 실행하라"는 것은 Skill 문서의 지시였을 뿐이라,
# Agent가 실행하지 않았거나 실패를 무시해도 submitted로 넘어갔다. 그래서
# "됐다고 했는데 실제로는 안 된"(wrong completion) 경우를 아무도 못 잡았다.
# 여기서 Harness가 직접 실행하고, 하나라도 실패하면 전이를 거부한다.
#
# verified_by.type:
#   command       — command 필드의 명령을 실행한다. 종료코드 0이어야 통과.
#   manual-review — 자동 검증이 불가능하다. 실행하지 않고 manual로 기록만 하며
#                   전이를 막지 않는다. 판단은 Reviewer 몫이다.
#
# 파서는 init이 만드는 고정 스키마만 읽는다(lib/30-yaml.sh와 같은 원칙).
# 모양이 다르면 조용히 넘어가지 않고 실패한다 — 검증을 건너뛴 것을 통과로
# 착각하는 것이 이 게이트에서 가장 위험하기 때문이다.
# ---------------------------------------------------------------------------
_ac_entries() {
  # 출력 한 줄 = "criterion_id<TAB>type<TAB>command"
  #
  # verified_by 블록 안의 type/command만 읽는다. 블록을 구분하지 않고 acceptance
  # 영역의 모든 type:/command:를 주우면 두 방향으로 틀린다 — metadata.type 같은
  # 엉뚱한 키가 검증 방식으로 인식돼 검증을 건너뛰고 통과시키거나, 다른 중첩
  # 객체의 command가 실행돼 버린다. 여기서는 들여쓰기 깊이로 블록을 닫는다.
  local task_file="$1"
  awk '
    function flush() { if (id != "") print id "\t" type "\t" command }
    function indent_of(line,   n) { match(line, /^[[:space:]]*/); return RLENGTH }
    /^acceptance_criteria:[[:space:]]*$/ { inside = 1; next }
    inside && /^[^[:space:]#]/ { inside = 0 }
    !inside { next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*-[[:space:]]*criterion_id:[[:space:]]*/ {
      flush()
      id = $0; sub(/^[[:space:]]*-[[:space:]]*criterion_id:[[:space:]]*/, "", id)
      type = ""; command = ""; in_verified = 0; verified_indent = -1
      next
    }
    /^[[:space:]]*verified_by:[[:space:]]*$/ {
      in_verified = 1; verified_indent = indent_of($0); next
    }
    {
      if (in_verified && indent_of($0) <= verified_indent) { in_verified = 0 }
      if (!in_verified) next
      if ($0 ~ /^[[:space:]]*type:[[:space:]]*/) {
        type = $0; sub(/^[[:space:]]*type:[[:space:]]*/, "", type); next
      }
      if ($0 ~ /^[[:space:]]*command:[[:space:]]*/) {
        command = $0; sub(/^[[:space:]]*command:[[:space:]]*/, "", command); next
      }
    }
    END { flush() }
  ' "$task_file" |
  sed -e "s/\r$//" -e "s/[[:space:]]*$//"
}

_ac_unquote() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  case "$value" in
    \'*\') value="${value:1:${#value}-2}"; value="${value//\'\'/\'}" ;;
    \"*\") value="${value:1:${#value}-2}" ;;
  esac
  printf '%s' "$value"
}

_ac_latest_attempt() {
  local root="$1" task_id="$2" path base number maximum=0
  shopt -s nullglob
  for path in "$root/.harness/attempts/$task_id-attempt-"*.md; do
    base="${path##*/}"; number="${base#"$task_id-attempt-"}"; number="${number%.md}"
    [[ "$number" =~ ^[0-9]+$ ]] || continue
    (( number > maximum )) && maximum="$number"
  done
  shopt -u nullglob
  printf '%s' "$maximum"
}

_ac_remote_enabled() {
  local root="$1"
  local config="$root/.harness/policies/remote.yaml"
  [[ -f "$config" ]] || return 1
  awk '/^  enabled:[[:space:]]*true[[:space:]]*$/ { found = 1 } END { exit found ? 0 : 1 }' "$config"
}

# Evidence 정본 검사 — 이름과 필수 필드를 함께 본다.
#
# 글롭으로 "<task>-*.yaml이 하나라도 있으면 통과"시키면 빈 task-001-garbage.yaml
# 하나로도 게이트를 지나간다. checks 파일까지 같은 글롭에 걸린다. 정본은
# dispatch/observe가 만든 <task>-<role>-attempt-<N>.yaml 뿐이고, 그 안에
# 판단에 필요한 필드가 실제로 들어 있어야 한다.
_transition_require_evidence() {
  local root="$1" task_id="$2" path base key found=""
  shopt -s nullglob
  for path in "$root/.harness/evidence/$task_id-worker-attempt-"*.yaml \
              "$root/.harness/evidence/$task_id-reviewer-attempt-"*.yaml; do
    base="${path##*/}"
    [[ "$base" =~ ^"$task_id"-(worker|reviewer)-attempt-[0-9]+\.yaml$ ]] || continue
    local complete=1
    for key in task role attempt result status; do
      grep -q "^${key}:" "$path" || { complete=0; break; }
    done
    (( complete == 1 )) || continue
    found="$path"
    break
  done
  shopt -u nullglob
  [[ -n "$found" ]] ||
    die "Evidence 정본이 없어 submitted로 전이할 수 없습니다.
   필요한 것: .harness/evidence/${task_id}-<worker|reviewer>-attempt-<N>.yaml
   (task·role·attempt·result·status 필드를 모두 갖춰야 하며, dispatch/observe가 만듭니다)"
}

_transition_require_acceptance_criteria() {
  local root="$1" task_id="$2" task_file="$3"
  local line id type command output status attempt checks_file temporary
  local total=0 passed=0 failed=0 manual=0 timeout_s
  local -a cached_commands=()
  local -a cached_statuses=()
  local -a cached_outputs=()

  timeout_s="$(awk '/^  acceptance_check_timeout_seconds:/{print $2; exit}' \
    "$root/.harness/policies/project-policy.yaml" 2>/dev/null || true)"
  [[ "$timeout_s" =~ ^[1-9][0-9]*$ ]] || timeout_s=600

  attempt="$(_ac_latest_attempt "$root" "$task_id")"
  [[ "$attempt" != 0 ]] || attempt=1
  checks_file="$root/.harness/evidence/$task_id-attempt-$attempt-checks.yaml"
  mkdir -p "$root/.harness/evidence"
  temporary="$(mktemp "$root/.harness/evidence/.checks.XXXXXX")"

  {
    printf 'task: %s\n' "$(yaml_quote "$task_id")"
    printf 'attempt: %s\n' "$attempt"
    printf 'ran_at: %s\n' "$(yaml_quote "$(date -u +'%Y-%m-%dT%H:%M:%SZ')")"
    printf 'runner: %s\n' "$(yaml_quote "$(_ac_remote_enabled "$root" && printf 'remote' || printf 'local')")"
    printf 'checks:\n'
  } >"$temporary"

  while IFS=$'\t' read -r id type command; do
    [[ -n "$id" ]] || continue
    id="$(_ac_unquote "$id")"
    type="$(_ac_unquote "$type")"
    command="$(_ac_unquote "$command")"
    total=$((total + 1))
    case "$type" in
      command)
        [[ -n "$command" ]] || {
          rm -f -- "$temporary"
          die "$id 의 verified_by.type이 command인데 command 필드가 없습니다: $task_file"
        }

        local cache_idx=-1
        local i
        for (( i=0; i<${#cached_commands[@]}; i++ )); do
          if [[ "${cached_commands[i]}" == "$command" ]]; then
            cache_idx=$i
            break
          fi
        done

        if (( cache_idx >= 0 )); then
          info "AC 검증 결과 재사용: $id"
          status="${cached_statuses[cache_idx]}"
          output="${cached_outputs[cache_idx]}"
        else
          info "AC 검증 실행: $id — $command"
          set +e
          if _ac_remote_enabled "$root"; then
            # cmd_remote_run은 인자 1개만 받고, 설정이 미리 로드돼 있어야 한다.
            # 원격에서도 무한 루프가 전이를 영원히 붙잡지 않도록 timeout을 건다.
            output="$( _remote_require "$root" &&
                       cmd_remote_run "timeout -k 10 $timeout_s bash -c $(printf '%q' "$command")" 2>&1 )"
          else
            # -k 없이는 TERM을 무시하는 명령이 계속 돌아 전이가 끝나지 않는다.
            output="$(cd "$root" && timeout -k 10 "$timeout_s" bash -c "$command" 2>&1)"
          fi
          status=$?
          set -e
          cached_commands+=("$command")
          cached_statuses+=("$status")
          cached_outputs+=("$output")
        fi

        if (( status == 0 )); then
          passed=$((passed + 1))
        else
          failed=$((failed + 1))
        fi
        {
          printf '  - criterion_id: %s\n' "$(yaml_quote "$id")"
          printf '    command: %s\n' "$(yaml_quote "$command")"
          printf '    exit_code: %s\n' "$status"
          printf '    result: %s\n' "$( ((status == 0)) && printf "'pass'" || printf "'fail'" )"
          printf '    output_tail: %s\n' "$(yaml_quote "$(printf '%s' "$output" | tail -n 5 | tr '\n' ' ')")"
        } >>"$temporary"
        ;;
      manual-review)
        manual=$((manual + 1))
        {
          printf '  - criterion_id: %s\n' "$(yaml_quote "$id")"
          printf "    result: 'manual'\n"
          printf "    note: 'Harness가 자동 검증할 수 없다 — Reviewer가 판단한다'\n"
        } >>"$temporary"
        ;;
      *)
        rm -f -- "$temporary"
        die "$id 의 verified_by.type을 알 수 없습니다: ${type:-없음} (command | manual-review): $task_file"
        ;;
    esac
  done < <(_ac_entries "$task_file")

  {
    printf 'summary:\n'
    printf '  total: %s\n  passed: %s\n  failed: %s\n  manual: %s\n' "$total" "$passed" "$failed" "$manual"
  } >>"$temporary"

  if _runtime_has_secret "$temporary"; then
    : >"$temporary"
    printf '# checks withheld\n' >"$temporary"
    printf "note: 'Secret 의심 패턴이 발견되어 원문을 저장하지 않았습니다'\n" >>"$temporary"
    printf 'summary:\n  total: %s\n  passed: %s\n  failed: %s\n  manual: %s\n' \
      "$total" "$passed" "$failed" "$manual" >>"$temporary"
  fi
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$checks_file"

  (( total > 0 )) ||
    die "acceptance_criteria가 비어 있어 submitted로 전이할 수 없습니다: $task_file"
  (( failed == 0 )) ||
    die "Acceptance Criteria 검증에 실패했습니다 ($failed/$total). 결과: ${checks_file#"$root/"}"
  info "AC 검증 통과: pass $passed / manual $manual / 전체 $total → ${checks_file#"$root/"}"
}

_transition_active_slot_count() {
  local root="$1" task_id path status count=0
  while IFS= read -r task_id; do
    [[ -n "$task_id" ]] || continue
    path="$root/.harness/tasks/$task_id.yaml"
    status="$(yaml_scalar "$path" status)"
    task_uses_active_slot "$status" && count=$((count + 1))
  done < <(task_ids "$root")
  printf '%s\n' "$count"
}

# 의존성 미충족에는 성질이 다른 두 경우가 섞여 있다. 선언한 Task 파일이 아예
# 없는 것은 계획 오류이므로 어떤 슬롯 상황에서도 큰 소리로 실패해야 한다. 반면
# "의존 Task가 아직 completed가 아니다"는 Wave의 정상 진행 상태이며, 그 Task는
# queued에서 기다리다가 completed 전이가 승격한다. 호출자가 둘을 구분할 수
# 있도록 TRANSITION_DEPENDENCY_MISSING으로 나눠 알린다.
_transition_dependencies_complete() {
  local root="$1" path="$2" dep dep_path dep_status
  TRANSITION_DEPENDENCY_ERROR=""
  TRANSITION_DEPENDENCY_MISSING=0
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    dep_path="$root/.harness/tasks/$dep.yaml"
    if [[ ! -f "$dep_path" ]]; then
      TRANSITION_DEPENDENCY_ERROR="의존 Task 파일이 없습니다: $dep"
      TRANSITION_DEPENDENCY_MISSING=1
      return 1
    fi
    dep_status="$(yaml_scalar "$dep_path" status)"
    if [[ "$dep_status" != completed ]]; then
      TRANSITION_DEPENDENCY_ERROR="의존 Task $dep 가 completed가 아닙니다 (현재 $dep_status)"
      return 1
    fi
  done < <(yaml_flow_list "$path" dependencies)
  return 0
}

_transition_write_status() {
  local root="$1" task_id="$2" path="$3" from_state="$4" to_state="$5" note="${6:-}"
  local temporary
  temporary="$(mktemp "$(dirname "$path")/.harness-transition.XXXXXX")"
  if ! awk -v to="$to_state" '
    !done_flag && index($0, "status:") == 1 { print "status: " to; done_flag = 1; next }
    { print }
  ' "$path" >"$temporary"; then
    rm -f -- "$temporary"
    die "status 갱신용 임시 파일 생성에 실패했습니다: $path"
  fi
  grep -q "^status: ${to_state}$" "$temporary" || {
    rm -f -- "$temporary"
    die "status 갱신에 실패했습니다: $path"
  }
  chmod 0644 "$temporary"
  if ! mv -f -- "$temporary" "$path"; then
    rm -f -- "$temporary"
    die "status 파일 교체에 실패했습니다: $path"
  fi

  append_event "$root" transition "$task_id" "$from_state" "$to_state" "$note"
  printf '%s: %s -> %s\n' "$task_id" "$from_state" "$to_state"

  # STATE.md 드리프트 안내 (스크립트가 산문을 대신 쓰지 않는다)
  if grep -q "| *${task_id} *|" "$root/.harness/STATE.md" 2>/dev/null; then
    grep -q "| *${task_id} *|.*| *${to_state} *|" "$root/.harness/STATE.md" ||
      info "STATE.md의 $task_id 행이 아직 $to_state 가 아닙니다. Orchestrator가 갱신하세요."
  fi
}

# completed가 만든 빈 슬롯만 채운다. 호출자는 프로젝트 queue lock을 보유한다.
# 자동 범위는 queued -> ready 상태 기록까지이며 dispatch나 승인 경로는 호출하지
# 않는다. 정렬은 locale과 무관한 Task ID 문자열 오름차순으로 고정한다.
_transition_promote_queued() {
  local root="$1" max_active="$2" active_count available task_id path status
  active_count="$(_transition_active_slot_count "$root")"
  available=$((max_active - active_count))
  (( available > 0 )) || return 0

  while IFS= read -r task_id; do
    (( available > 0 )) || break
    [[ -n "$task_id" ]] || continue
    path="$root/.harness/tasks/$task_id.yaml"
    status="$(yaml_scalar "$path" status)"
    [[ "$status" == queued ]] || continue
    _transition_dependencies_complete "$root" "$path" || continue
    _transition_write_status "$root" "$task_id" "$path" queued ready \
      "queue promotion: dependency satisfied; max_active_tasks=$max_active"
    available=$((available - 1))
  done < <(task_ids "$root" | LC_ALL=C sort)
}

# 완료 보고는 상태 전이가 끝난 뒤의 부가 출력일 뿐이다. 기본 호출에는 --live를
# 붙이지 않아 Herdr 가용성과 지연이 전이 경로에 들어오지 않게 한다.
_transition_emit_completion_report() {
  local root="$1" task_id="$2"
  if ! cmd_report "$root" --task "$task_id"; then
    info "완료 보고를 생성하지 못했습니다. 상태 전이는 이미 반영됐습니다. report를 다시 실행해 확인하세요."
  fi
  return 0
}

cmd_transition() {
  local root_arg="" task_id="" to_state="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) [[ $# -ge 2 ]] || die "--note 값이 필요합니다."; note="$2"; shift 2 ;;
      -h|--help)
        printf '사용법: %s transition PATH TASK_ID TO_STATE [--note TEXT]\n' "$SCRIPT_NAME"
        return 0 ;;
      -*) die "알 수 없는 transition 옵션: $1" ;;
      *)
        if [[ -z "$root_arg" ]]; then root_arg="$1"
        elif [[ -z "$task_id" ]]; then task_id="$1"
        elif [[ -z "$to_state" ]]; then to_state="$1"
        else die "인자가 너무 많습니다: $1"
        fi
        shift ;;
    esac
  done

  [[ -n "$root_arg" && -n "$task_id" && -n "$to_state" ]] ||
    die "사용법: $SCRIPT_NAME transition PATH TASK_ID TO_STATE"

  local root path from_state max_active="" queue_token="" lock_error_file="" lock_error=""
  root="$(project_root "$root_arg")"
  _runtime_require_human_caller "$root" transition
  path="$(task_file "$root" "$task_id")"
  valid_task_status "$to_state" || die "알 수 없는 목표 상태: $to_state"

  # 슬롯 수를 바꾸는 경로는 상태 확인 전부터 같은 프로젝트 전역 lock 아래 둔다.
  # lock 획득 실패 시 어떤 Task YAML도 건드리지 않는다.
  case "$to_state" in
    ready|completed)
      max_active="$(project_max_active_tasks "$root")"
      lock_error_file="$(mktemp "${TMPDIR:-/tmp}/herdr-queue-lock.XXXXXX")"
      if ! queue_token="$(_runtime_lock_acquire "$root" __project_queue__ queue-transition 600 2>"$lock_error_file")"; then
        lock_error="$(tr '\n' ' ' <"$lock_error_file")"
        rm -f -- "$lock_error_file"
        die "프로젝트 queue lock 획득에 실패했습니다. 상태는 변경되지 않았습니다: ${lock_error:-알 수 없는 잠금 오류}"
      fi
      rm -f -- "$lock_error_file"
      trap "_runtime_lock_release '$root' __project_queue__ '$queue_token'" EXIT INT TERM
      ;;
  esac

  from_state="$(yaml_scalar "$path" status)"

  [[ "$from_state" != "$to_state" ]] || die "$task_id 는 이미 $to_state 입니다."
  transition_allowed "$from_state" "$to_state" ||
    die "허용되지 않은 전이입니다: $from_state -> $to_state ($task_id)"

  local write_state="$to_state" write_note="$note" active_slots

  # draft/queued만 ready 진입 때 새 슬롯을 소비한다. changes_requested와
  # handover_required는 이미 활성 슬롯을 쓰므로 ready로 이름만 바뀐다.
  #
  # 의존성과 슬롯은 서로 독립인 두 조건이다. 하나의 if/elif로 묶으면 같은 요청이
  # 큐가 붐빌 때만 다르게 처리돼 계획 오류가 가장 발견하기 어려운 시점에 숨는다.
  # 그래서 둘을 각각 판정하고, 해당하는 사유를 모두 남긴다.
  if [[ "$to_state" == ready && ( "$from_state" == draft || "$from_state" == queued ) ]]; then
    local dependency_ok=1 dependency_reason="" slot_full=0

    if ! _transition_dependencies_complete "$root" "$path"; then
      # 선언한 의존 Task 파일이 아예 없다 = 계획 오류. 슬롯 상황과 무관하게,
      # 또 어느 from_state에서든 실패한다. queued에 묻어두면 Wave가 끝날 때까지
      # 아무도 모른다.
      (( TRANSITION_DEPENDENCY_MISSING == 0 )) ||
        die "$task_id: ready 전이 조건 불충족 — $TRANSITION_DEPENDENCY_ERROR"
      dependency_ok=0
      dependency_reason="$TRANSITION_DEPENDENCY_ERROR"
    fi

    active_slots="$(_transition_active_slot_count "$root")"
    (( active_slots < max_active )) || slot_full=1

    if (( dependency_ok == 0 || slot_full == 1 )); then
      if [[ "$from_state" == draft ]]; then
        # 아직 ready가 될 수 없는 승인된 Task는 실패시키지도 과할당하지도 않고
        # queued에 보존한다. 해당하는 사유를 모두 note와 WARN에 남긴다.
        write_state=queued
        if (( dependency_ok == 0 )); then
          write_note="${write_note:+$write_note; }queue: ready requested; $dependency_reason"
          printf '[WARN] 의존성이 아직 충족되지 않아 %s 를 queued로 기록합니다: %s\n' \
            "$task_id" "$dependency_reason" >&2
        fi
        if (( slot_full == 1 )); then
          write_note="${write_note:+$write_note; }queue: ready requested; active=$active_slots; max_active_tasks=$max_active"
          printf '[WARN] 활성 Task 슬롯이 가득 차 %s 를 queued로 기록합니다: %s / %s\n' \
            "$task_id" "$active_slots" "$max_active" >&2
        fi
      elif (( dependency_ok == 0 )); then
        # 이미 queued인 Task에 대한 명시적 ready 요청은 지금 이행할 수 없으므로
        # 상태를 바꾸지 않고 사유와 함께 실패한다.
        die "$task_id: ready 전이 조건 불충족 — $dependency_reason"
      else
        printf '[WARN] 활성 Task 슬롯이 가득 차 %s 는 queued에 남습니다: %s / %s\n' \
          "$task_id" "$active_slots" "$max_active" >&2
        _runtime_lock_release "$root" __project_queue__ "$queue_token"
        trap - EXIT INT TERM
        return 0
      fi
    fi
  fi

  # --- 전이별 필수 조건 ---
  case "$to_state" in
    ready)
      local spec_state
      spec_state="$(awk -F': ' '/^- 상태:/{print $2; exit}' "$root/.harness/SPEC.md" 2>/dev/null || true)"
      [[ "$spec_state" == approved ]] ||
        die "SPEC이 승인되지 않았습니다 (현재 ${spec_state:-unknown}). .harness/SPEC.md의 '- 상태:'를 approved로 바꾸고 승인자를 기록하세요."
      ;;
    active)
      require_git_baseline "$root"
      ;;
    handover_required)
      compgen -G "$root/.harness/handovers/${task_id}-handover-*.md" >/dev/null ||
        die "Handover 기록이 없어 handover_required로 전이할 수 없습니다: .harness/handovers/${task_id}-handover-*.md  (harness-handover §3: 인계 문서를 먼저 작성한 뒤 전이한다)"
      ;;
    submitted)
      compgen -G "$root/.harness/attempts/${task_id}-attempt-*.md" >/dev/null ||
        die "Attempt 기록이 없어 submitted로 전이할 수 없습니다: .harness/attempts/${task_id}-attempt-*.md"
      _transition_require_evidence "$root" "$task_id"
      _transition_require_acceptance_criteria "$root" "$task_id" "$path"
      ;;
    reviewing)
      task_review_policy "$path" || die "$task_id: $TASK_REVIEW_POLICY_ERROR"
      [[ "$TASK_REVIEW_MODE" == ai ]] ||
        die "$task_id 는 수동 검토 Task입니다. Reviewer를 dispatch하지 말고 submitted -> awaiting_approval로 전이하세요 (reason=$TASK_REVIEW_REASON)."
      ;;
    awaiting_approval)
      task_review_policy "$path" || die "$task_id: $TASK_REVIEW_POLICY_ERROR"
      if [[ "$from_state" == submitted ]]; then
        [[ "$TASK_REVIEW_MODE" == manual ]] ||
          die "$task_id 는 독립 AI Review Task입니다. submitted -> reviewing을 먼저 수행하세요."
        info "수동 검토 예외: AI Review 없이 사용자 승인 대기로 전이합니다 (reason=$TASK_REVIEW_REASON)"
      else
        [[ "$TASK_REVIEW_MODE" == ai ]] ||
          die "$task_id 는 수동 검토 Task이므로 reviewing 상태에서 awaiting_approval로 전이할 수 없습니다."
        # 과거의 APPROVED가 남아 있어도 최신 Review가 반려면 통과시키지 않는다.
        local latest_review verdict
        latest_review="$(latest_task_review "$root" "$task_id")"
        [[ -n "$latest_review" ]] ||
          die "Review 파일이 없습니다: .harness/reviews/${task_id}-*.md"
        # 줄 시작의 '판정:' 만 읽는다. Markdown 굵은 표시(**판정: X**)는 허용하되
        # focus 항목의 '- 판정: PASS / FAIL / NA' 같은 하위 줄은 매칭하지 않는다.
        verdict="$(review_verdict "$latest_review")"
        [[ "$verdict" == APPROVED ]] ||
          die "최신 Review의 판정이 APPROVED가 아닙니다 (${verdict:-없음}): $latest_review"
      fi
      ;;
    completed)
      local approval="$root/.harness/decisions/${task_id}-approval.md"
      [[ -f "$approval" ]] ||
        die "사용자 승인 기록이 없습니다: $approval  (Agent는 completed를 만들 수 없습니다)"
      grep -q '^승인:[[:space:]]*yes' "$approval" ||
        die "승인 기록에 '승인: yes' 줄이 없습니다: $approval"
      ;;
  esac

  # --- queue lock 아래 원자적 파일 교체와 유한 승격 ---
  _transition_write_status "$root" "$task_id" "$path" "$from_state" "$write_state" "$write_note"
  if [[ "$to_state" == completed ]]; then
    _transition_promote_queued "$root" "$max_active"
  fi

  if [[ -n "$queue_token" ]]; then
    _runtime_lock_release "$root" __project_queue__ "$queue_token"
    trap - EXIT INT TERM
  fi

  # queue lock을 푼 뒤 읽기 전용 보고를 덧붙인다. 보고 실패가 전이 종료코드를
  # 바꾸지 않도록 래퍼가 언제나 성공으로 돌아온다.
  [[ "$to_state" != completed ]] || _transition_emit_completion_report "$root" "$task_id"
}

# ---------------------------------------------------------------------------
# approve — 사용자의 명시적 완료 승인을 기계적으로 기록하고 completed로 전이.
# 승인 판단은 하지 않으며, --confirm-user-approval 없이는 절대 실행하지 않는다.
# ---------------------------------------------------------------------------

cmd_approve() {
  local root_arg="" task_id="" confirm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --confirm-user-approval)
        [[ "$confirm" -eq 0 ]] || die "--confirm-user-approval 플래그가 중복됐습니다."
        confirm=1
        shift
        ;;
      -h|--help)
        printf '사용법: %s approve PATH TASK_ID --confirm-user-approval\n' "$SCRIPT_NAME"
        printf '사용자가 현재 Task의 완료를 명시적으로 승인한 뒤에만 Orchestrator가 호출합니다.\n'
        return 0
        ;;
      -*) die "알 수 없는 approve 옵션: $1" ;;
      *)
        if [[ -z "$root_arg" ]]; then root_arg="$1"
        elif [[ -z "$task_id" ]]; then task_id="$1"
        else die "인자가 너무 많습니다: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$root_arg" && -n "$task_id" ]] ||
    die "사용법: $SCRIPT_NAME approve PATH TASK_ID --confirm-user-approval"
  [[ "$confirm" -eq 1 ]] ||
    die "사용자의 명시적 승인을 확인했다는 --confirm-user-approval 플래그가 필요합니다."
  valid_approval_task_id "$task_id" ||
    die "안전하지 않은 Task ID입니다: $task_id"

  local root path declared_id task_status latest_review verdict review_relative approval
  local review_mode policy_reason=""
  root="$(project_root "$root_arg")"
  _runtime_require_human_caller "$root" approve
  path="$(task_file "$root" "$task_id")"
  declared_id="$(yaml_scalar "$path" task_id)"
  [[ "$declared_id" == "$task_id" ]] ||
    die "Task ID가 파일명과 일치하지 않습니다: 요청=$task_id, 선언=$declared_id"

  task_status="$(yaml_scalar "$path" status)"
  [[ "$task_status" == awaiting_approval || "$task_status" == completed ]] ||
    die "$task_id 는 awaiting_approval 상태가 아닙니다 (현재 $task_status)."

  task_review_policy "$path" || die "$task_id: $TASK_REVIEW_POLICY_ERROR"
  review_mode="$TASK_REVIEW_MODE"
  if [[ "$review_mode" == manual ]]; then
    review_relative="(생략 — 수동 검토 정책 예외)"
    policy_reason="$TASK_REVIEW_REASON"
  else
    latest_review="$(latest_task_review "$root" "$task_id")"
    [[ -n "$latest_review" ]] ||
      die "Review 파일이 없습니다: .harness/reviews/${task_id}-*.md"
    verdict="$(review_verdict "$latest_review")"
    [[ "$verdict" == APPROVED ]] ||
      die "최신 Review의 판정이 APPROVED가 아닙니다 (${verdict:-없음}): $latest_review"
    review_relative=".harness/reviews/${latest_review##*/}"
  fi
  approval="$root/.harness/decisions/${task_id}-approval.md"

  if [[ -e "$approval" ]]; then
    approval_record_matches "$approval" "$task_id" "$review_relative" "$policy_reason" ||
      die "기존 승인 파일이 현재 Task/Review와 충돌합니다. 덮어쓰지 않습니다: $approval"
  elif [[ "$task_status" == completed ]]; then
    die "completed Task의 승인 파일이 없습니다: $approval"
  else
    local temporary approved_at
    approved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    temporary="$(mktemp "$(dirname "$approval")/.harness-approval.XXXXXX")"
    trap "rm -f -- '$temporary'" RETURN
    {
      printf '# 사용자 승인 기록\n\n'
      printf 'Task: %s\n' "$task_id"
      printf '승인: yes\n'
      printf '승인자: 사용자 (채팅 명시 승인)\n'
      printf '승인 시각: %s\n' "$approved_at"
      printf '근거 Review: %s\n' "$review_relative"
      [[ -z "$policy_reason" ]] || printf '정책 예외 사유: %s\n' "$policy_reason"
      printf '명시 확인: --confirm-user-approval\n'
    } >"$temporary"
    chmod 0644 "$temporary"

    # 같은 Task에 대한 approve 호출이 겹쳐도 기존 파일을 덮어쓰지 않는다.
    # GNU mv -n은 같은 디렉터리 안에서 원자적으로 이름을 붙이되 충돌 시 보존한다.
    mv -n "$temporary" "$approval"
    if [[ -e "$temporary" ]]; then
      rm -f "$temporary"
      approval_record_matches "$approval" "$task_id" "$review_relative" "$policy_reason" ||
        die "승인 파일 생성 중 충돌이 발생했습니다. 기존 파일을 보존합니다: $approval"
    fi
  fi

  if [[ "$task_status" == completed ]]; then
    printf '%s: 이미 completed입니다 (승인 기록 일치, 변경 없음)\n' "$task_id"
    return 0
  fi

  local approval_note="approve: explicit user confirmation; review=$review_relative"
  [[ -z "$policy_reason" ]] || approval_note="$approval_note; policy_exception=$policy_reason"
  cmd_transition "$root" "$task_id" completed --note "$approval_note"
}

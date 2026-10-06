# Part of herdr-harness. Sourced by harness.sh — do not run directly.

# ---------------------------------------------------------------------------
# preflight — 첫 dispatch 전 읽기 전용 점검
#
# validate가 "문서끼리 맞는가"를 본다면 preflight는 "이 환경에서 실제로 기동될
# 수 있는가"를 본다: Provider CLI, 설치본과 소스의 일치, Git 기준선, 승인 모드가
# 역할별로 실제 붙일 인수, Worker≠Reviewer, 등급→모델 매핑, write_scope의 쓰기
# 가능 여부. 문제는 Agent를 띄운 뒤(쿼터를 쓴 뒤)가 아니라 여기서 드러나야 한다.
#
# 모델 ID는 자주 바뀌므로 여기에 어떤 기본 모델도 적지 않는다. 정책 값과 설치된
# Provider가 돌려주는 목록(조회 경로가 있는 agy만)을 대조할 뿐이며, 조회가 안 되면
# 추측하지 않고 사람에게 명시적 설정을 요청한다. 파일은 아무것도 바꾸지 않는다.
# ---------------------------------------------------------------------------

# lib/·templates/ 내용으로 만든 짧은 지문. 설치본과 소스가 같은 코드인지 본다.
_harness_fingerprint() {
  local dir="$1"
  [[ -d "$dir/lib" ]] || { printf 'unknown'; return 0; }
  (
    cd "$dir" &&
      find lib templates -type f -print0 2>/dev/null | LC_ALL=C sort -z |
      xargs -0 sha256sum 2>/dev/null
  ) | sha256sum | cut -c1-12
}

# Provider CLI 버전 한 줄. self-test 하위 프로세스에서는 실제 CLI를 띄우지 않는다
# (_models_query_agy와 같은 안전망 — 테스트가 Provider 호출 0회를 검사한다).
_preflight_provider_version() {
  local provider="$1"
  [[ "${HH_HARNESS_SELFTEST:-0}" != 1 ]] || return 125
  timeout 10 "$provider" --version 2>/dev/null | head -n 1
}

# Task YAML·write_scope 항목을 절대경로(또는 절대 glob)로 바꾼다.
_preflight_abs_scope() {
  local root="$1" entry="$2"
  entry="${entry%/}"
  [[ "$entry" == /* ]] || entry="$root/$entry"
  # glob이 없으면 ..·. 을 정규화한다. glob은 문자열 그대로 비교에 쓴다.
  if [[ "$entry" != *[\*\?\[]* ]]; then
    entry="$(realpath -m "$entry")"
  fi
  printf '%s' "$entry"
}

# 경로가 write_scope 항목(파일·디렉터리·glob) 중 하나에 들어가는가.
_scope_matches() {
  local file="$1" pattern
  shift
  for pattern in "$@"; do
    [[ -n "$pattern" ]] || continue
    # shellcheck disable=SC2053 — pattern은 의도적으로 glob이다.
    [[ "$file" == $pattern || "$file" == $pattern/* ]] && return 0
  done
  return 1
}

cmd_preflight() {
  local root_arg="."
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        printf '사용법: %s preflight [PATH]\n' "$SCRIPT_NAME"
        printf '첫 dispatch 전 읽기 전용 점검. [FAIL]이 하나라도 있으면 종료 코드 1.\n'
        return 0
        ;;
      -*) die "알 수 없는 preflight 옵션: $1" ;;
      *) root_arg="$1"; shift ;;
    esac
  done

  local root policy fails=0 warns=0
  root="$(project_root "$root_arg")"
  policy="$root/.harness/policies/agent-policy.yaml"

  pf_ok() { printf '[OK]   %s\n' "$1"; }
  pf_info() { printf '[INFO] %s\n' "$1"; }
  pf_warn() {
    printf '[WARN] %s\n' "$1"
    [[ -z "${2:-}" ]] || printf '       수정: %s\n' "$2"
    warns=$((warns + 1))
  }
  pf_fail() {
    printf '[FAIL] %s\n' "$1"
    [[ -z "${2:-}" ]] || printf '       수정: %s\n' "$2"
    fails=$((fails + 1))
  }

  local orchestrator p_worker p_reviewer preset approval_mode
  orchestrator="$(project_field "$root" providers orchestrator)"
  p_worker="$(project_field "$root" providers primary_worker)"
  p_reviewer="$(project_field "$root" providers reviewer)"
  preset="$(project_preset "$root")"
  approval_mode="$(_runtime_approval_mode "$root")"
  printf '# preflight: %s\n\n' "$root"
  printf '프리셋=%s · Orchestrator=%s · Worker=%s · Reviewer=%s · 승인 모드=%s\n' \
    "$preset" "$orchestrator" "$p_worker" "$p_reviewer" "$approval_mode"

  # 열린(completed가 아닌) Task 목록 — 이후 여러 절에서 쓴다.
  local task_id path status
  local -a open_tasks=()
  while IFS= read -r task_id; do
    [[ -n "$task_id" ]] || continue
    status="$(_runtime_yaml_scalar "$root/.harness/tasks/$task_id.yaml" status)"
    [[ "$status" == completed ]] || open_tasks+=("$task_id")
  done < <(task_ids "$root")

  # --- 1. 설치본 ------------------------------------------------------------
  printf '\n## 1. Harness 설치본\n\n'
  local running_dir installed_cmd installed_dir running_fp installed_fp
  running_dir="$(dirname "$(readlink -f "$SELF_PATH")")"
  running_fp="$(_harness_fingerprint "$running_dir")"
  pf_ok "실행 중: $running_dir (지문 $running_fp)"
  installed_cmd="$(command -v herdr-harness 2>/dev/null || true)"
  if [[ -z "$installed_cmd" ]]; then
    pf_warn "PATH에 herdr-harness가 없습니다 — Agent·Skill 문서의 herdr-harness 명령이 실패합니다." \
      "소스 저장소에서 ./install.sh 실행 후 ~/.local/bin을 PATH에 추가 (README §7·§8)"
  else
    installed_dir="$(dirname "$(readlink -f "$installed_cmd")")"
    if [[ "$installed_dir" == "$running_dir" ]]; then
      pf_ok "PATH의 herdr-harness가 이 사본을 가리킵니다."
    else
      installed_fp="$(_harness_fingerprint "$installed_dir")"
      if [[ "$installed_fp" == "$running_fp" ]]; then
        pf_ok "설치본($installed_dir)과 실행 중인 사본의 lib·templates가 같습니다 (지문 $installed_fp)."
      else
        pf_warn "설치본($installed_dir, 지문 $installed_fp)과 실행 중인 사본(지문 $running_fp)이 다릅니다 — Agent는 설치본을 실행합니다." \
          "최신 소스에서 ./install.sh를 다시 실행하거나, 의도한 버전인지 확인"
      fi
    fi
  fi

  # --- 2. Provider CLI ------------------------------------------------------
  printf '\n## 2. Provider CLI\n\n'
  local provider version
  # needed: CLI가 있어야 하는 Provider와 그 용도. agent_providers: Worker·Reviewer로
  # 기동될 Provider(모델 정책 대조 대상 — Orchestrator는 dispatch로 띄우지 않는다).
  local -A needed=() agent_providers=()
  needed[$orchestrator]="orchestrator"
  needed[$p_worker]="${needed[$p_worker]:+${needed[$p_worker]},}worker"
  needed[$p_reviewer]="${needed[$p_reviewer]:+${needed[$p_reviewer]},}reviewer"
  agent_providers[$p_worker]=1
  agent_providers[$p_reviewer]=1
  for task_id in "${open_tasks[@]}"; do
    path="$root/.harness/tasks/$task_id.yaml"
    for provider in "$(_runtime_yaml_scalar "$path" primary_worker)" "$(_runtime_yaml_scalar "$path" reviewer)"; do
      valid_provider "$provider" || continue
      agent_providers[$provider]=1
      [[ -n "${needed[$provider]:-}" ]] || needed[$provider]="Task"
    done
  done
  if command -v herdr >/dev/null 2>&1; then
    pf_ok "herdr: $(command -v herdr)"
  else
    pf_fail "herdr 명령이 없습니다 — dispatch가 Pane을 만들 수 없습니다." \
      "Herdr 설치(README §3). 임시로는 dispatch --print-only + adopt 폴백"
  fi
  for provider in claude codex agy; do
    [[ -n "${needed[$provider]:-}" ]] || continue
    if command -v "$provider" >/dev/null 2>&1; then
      version="$(_preflight_provider_version "$provider" || true)"
      pf_ok "$provider (${needed[$provider]}): $(command -v "$provider")${version:+ — $version}"
    else
      pf_fail "$provider (${needed[$provider]}) CLI가 PATH에 없습니다." \
        "$provider CLI를 설치하거나 project.yaml providers / Task YAML의 Provider를 바꾼다"
    fi
  done

  # --- 3. Git 기준선 --------------------------------------------------------
  printf '\n## 3. Git 기준선\n\n'
  local git_state dirty
  git_state="$(git_baseline_status "$root")"
  if [[ "$git_state" == ok ]]; then
    pf_ok "기준 commit $(git -C "$root" rev-parse --short HEAD)"
    dirty="$(git -C "$root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    if (( dirty > 0 )); then
      pf_warn "커밋되지 않은 변경 ${dirty}개 — dispatch의 기준 commit에 포함되지 않아 write_scope 대조에 섞입니다." \
        "dispatch 전에 commit하거나 정리"
    fi
  else
    pf_fail "Git 기준선 없음 ($git_state) — Diff Review·write_scope 대조를 할 수 없습니다." \
      "git -C '$root' add -A && git -C '$root' commit -m 'chore: harness 기준선'"
  fi

  # --- 4. 승인 모드와 Gate --------------------------------------------------
  printf '\n## 4. 도구 승인 모드\n\n'
  local role role_provider args
  case "$approval_mode" in
    ask|auto|bypass) pf_ok "approval_mode=$approval_mode (agent-policy.yaml)" ;;
    *) pf_fail "approval_mode 값이 유효하지 않습니다: $approval_mode" \
         "$policy의 approval_mode를 ask|auto|bypass 중 하나로" ;;
  esac
  for role in worker reviewer; do
    [[ "$role" == worker ]] && role_provider="$p_worker" || role_provider="$p_reviewer"
    if args="$(_runtime_agent_args "$root" "$role_provider" 2>&1)"; then
      pf_ok "$role($role_provider) 실제 Provider 인수: ${args:-(없음 — Provider 기본 승인 동작)}"
    else
      pf_fail "$role($role_provider) 승인 인수가 정책 검사를 통과하지 못했습니다: $args" \
        "$policy의 ${role_provider}_${approval_mode} 값을 확인"
    fi
  done
  local gate gate_value
  for gate in spec milestone_plan provider_failover integration destructive_action; do
    gate_value="$(awk -v k="  $gate:" '
      $0 == "approval:" { inside = 1; next }
      /^[^[:space:]#]/ { inside = 0 }
      inside && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$root/.harness/project.yaml")"
    gate_value="$(yaml_unquote "$gate_value")"
    if [[ "$gate_value" != user_required ]]; then
      pf_fail "사용자 Gate가 꺼져 있습니다: project.yaml approval.$gate=${gate_value:-(없음)}" \
        ".harness/project.yaml의 approval.$gate를 user_required로 (승인 모드와 무관하게 유지해야 한다)"
    fi
  done
  if [[ "$approval_mode" == bypass ]]; then
    pf_info "bypass는 Provider의 도구 실행 승인에만 적용된다. SPEC/Wave 승인·Provider 교체·위험 명령·외부 쓰기/배포·completed는 사용자 Gate(project.yaml approval)와 transition/approve로 그대로 막힌다."
    pf_info "Sandbox가 없으므로 write_scope가 쓰기 경계다 — submitted 전이가 Attempt 기준 commit 이후 변경 파일을 대조해 범위 밖 변경을 거부한다."
  fi

  # --- 5. Worker ≠ Reviewer -------------------------------------------------
  printf '\n## 5. Worker ≠ Reviewer\n\n'
  if [[ "$p_worker" == "$p_reviewer" ]]; then
    pf_fail "project.yaml의 primary_worker와 reviewer가 같습니다: $p_worker" "providers.reviewer를 다른 Provider로"
  else
    pf_ok "기본 배정 Worker=$p_worker, Reviewer=$p_reviewer"
  fi
  local t_worker t_reviewer
  for task_id in "${open_tasks[@]}"; do
    path="$root/.harness/tasks/$task_id.yaml"
    t_worker="$(_runtime_yaml_scalar "$path" primary_worker)"
    t_reviewer="$(_runtime_yaml_scalar "$path" reviewer)"
    if [[ "$t_worker" == "$t_reviewer" ]]; then
      pf_fail "$task_id: Worker와 Reviewer가 같습니다 ($t_worker)" "$path의 reviewer를 다른 Provider로"
    elif [[ "$t_worker" != "$p_worker" || "$t_reviewer" != "$p_reviewer" ]]; then
      pf_info "$task_id: Task 지정 Worker=$t_worker, Reviewer=$t_reviewer (프로젝트 기본값보다 우선)"
    fi
  done

  # --- 6. 모델·등급·속도 ----------------------------------------------------
  printf '\n## 6. 모델·등급·속도\n\n'
  local probe_task model model_source effort effort_source fix
  mkdir -p "$root/.harness/runtime"
  # 프로젝트 기본값만 보려고 Task 지정 키가 없는 빈 Task를 쓴다(.harness/runtime은 Git 제외).
  probe_task="$(mktemp "$root/.harness/runtime/.preflight-task.XXXXXX")"
  printf "task_id: 'preflight'\n" >"$probe_task"

  # 역할 하나의 실제 선택 결과를 dispatch와 같은 함수로 계산한다. 서브셸에서
  # 돌려 전역 RUNTIME_* 값과 경고 출력을 붙잡는다.
  _preflight_role_model() {
    local label="$1" task_file="$2" role="$3" provider="$4" task_name="$5"
    local raw
    raw="$(
      exec 3>&1
      {
        if _runtime_select_model "$root" "$task_file" "$role" "$provider" "$task_name"; then
          printf '\037model\037%s\037%s\n' "$RUNTIME_MODEL" "$RUNTIME_MODEL_SOURCE" >&3
        else
          printf '\037model-fail\n' >&3
        fi
        if _runtime_select_effort "$root" "$task_file" "$role" "$provider"; then
          printf '\037effort\037%s\037%s\n' "$RUNTIME_EFFORT" "$RUNTIME_EFFORT_SOURCE" >&3
        else
          printf '\037effort-fail\n' >&3
        fi
      } 2>&1 >/dev/null
    )"
    local messages model_line effort_line
    messages="$(printf '%s\n' "$raw" | grep -v $'^\037' || true)"
    model_line="$(printf '%s\n' "$raw" | grep $'^\037model' | head -n 1)"
    effort_line="$(printf '%s\n' "$raw" | grep $'^\037effort' | head -n 1)"
    case "$provider" in
      agy) fix="herdr-harness models $root --refresh --apply 로 agy_models를 채우고, agy_tier_<등급>을 그 목록의 모델 ID로 설정 ($policy)" ;;
      *) fix="$policy의 ${provider}_models(공백 구분 허용 목록)와 ${provider}_tier_<등급>을 직접 채운다 — $provider는 목록 조회 경로가 없다. 확인: herdr-harness models $root" ;;
    esac
    if [[ "$model_line" == $'\037model-fail' || "$effort_line" == $'\037effort-fail' ]]; then
      pf_fail "$label: 모델/속도를 해석할 수 없어 dispatch가 중단됩니다 — ${messages//$'\n'/ }" "$fix"
      return 0
    fi
    IFS=$'\037' read -r _ _ model model_source <<<"$model_line"
    IFS=$'\037' read -r _ _ effort effort_source <<<"$effort_line"
    if [[ -n "$messages" ]]; then
      pf_warn "$label: 모델=${model:-Provider 기본값} [$model_source] — ${messages//$'\n'/ }" "$fix"
    else
      pf_ok "$label: 모델=${model:-Provider 기본값} [$model_source] · 속도=${effort:-Provider 기본값} [$effort_source]"
    fi
  }

  _preflight_role_model "worker($p_worker) 기본" "$probe_task" worker "$p_worker" preflight
  _preflight_role_model "reviewer($p_reviewer) 기본" "$probe_task" reviewer "$p_reviewer" preflight
  for task_id in "${open_tasks[@]}"; do
    path="$root/.harness/tasks/$task_id.yaml"
    t_worker="$(_runtime_yaml_scalar "$path" primary_worker)"
    t_reviewer="$(_runtime_yaml_scalar "$path" reviewer)"
    # Task가 Provider·모델·등급·속도를 바꾸지 않았다면 위 기본 결과와 같으므로
    # 같은 줄을 Task마다 반복하지 않는다.
    for role in worker reviewer; do
      [[ "$role" == worker ]] && role_provider="$t_worker" || role_provider="$t_reviewer"
      valid_provider "$role_provider" || continue
      if [[ "$role_provider" == "$([[ "$role" == worker ]] && printf '%s' "$p_worker" || printf '%s' "$p_reviewer")" &&
            -z "$(_runtime_yaml_scalar "$path" "${role}_model")$(_runtime_yaml_scalar "$path" "${role}_tier")$(_runtime_yaml_scalar "$path" "${role}_effort")" ]]; then
        continue
      fi
      _preflight_role_model "$task_id $role($role_provider)" "$path" "$role" "$role_provider" "$task_id"
    done
  done

  # 등급·프리미엄 충돌과 설치된 목록 대조 — 쓰이는 Provider만.
  local tier tier_value premium_set query_output item key
  local -a live=() premium_items=()
  for provider in claude codex agy; do
    [[ -n "${agent_providers[$provider]:-}" && -f "$policy" ]] || continue
    premium_set="$(_runtime_yaml_scalar "$policy" "${provider}_premium_models") $(_runtime_yaml_scalar "$policy" "${provider}_tier_premium")"
    read -r -a premium_items <<<"$premium_set"
    for tier in light standard; do
      tier_value="$(_runtime_yaml_scalar "$policy" "${provider}_tier_${tier}")"
      [[ -n "$tier_value" ]] || continue
      if _runtime_model_list_contains "$tier_value" "${premium_items[@]}"; then
        pf_fail "$provider: ${provider}_tier_${tier}가 프리미엄으로 선언된 모델($tier_value)을 가리킵니다 — 등급과 비용·승인 분류가 충돌합니다." \
          "$policy에서 ${provider}_tier_${tier}를 비프리미엄 모델로 바꾸거나 프리미엄 선언(${provider}_premium_models/${provider}_tier_premium)을 조정"
      fi
    done
    [[ "$provider" == agy ]] || continue
    if query_output="$(_models_query_agy 2>/dev/null)"; then
      mapfile -t live < <(_models_parse_agy_output <<<"$query_output")
    else
      live=()
    fi
    if (( ${#live[@]} == 0 )); then
      pf_warn "agy 모델 목록을 조회하지 못했습니다 — 정책 값이 설치된 agy와 맞는지 확인할 수 없습니다." \
        "agy CLI 로그인·설치를 확인한 뒤 herdr-harness models $root --refresh, 또는 agy_models·agy_tier_*를 명시적으로 확인"
      continue
    fi
    for key in agy_default_model agy_tier_light agy_tier_standard agy_tier_premium; do
      item="$(_runtime_yaml_scalar "$policy" "$key")"
      [[ -n "$item" ]] || continue
      _runtime_model_list_contains "$item" "${live[@]}" ||
        pf_fail "agy: $key=$item 이(가) 설치된 agy 모델 목록에 없습니다 (오래된 모델 ID)." \
          "herdr-harness models $root --refresh --apply 후 $policy의 $key를 현재 목록의 모델로"
    done
    pf_ok "agy: 설치된 목록 ${#live[@]}개와 정책 매핑 대조 완료"
  done
  unset -f _preflight_role_model
  rm -f -- "$probe_task"

  # --- 7. write_scope -------------------------------------------------------
  printf '\n## 7. write_scope·외부 저장소\n\n'
  local entry abs probe scope_count repo_top
  for task_id in "${open_tasks[@]}"; do
    path="$root/.harness/tasks/$task_id.yaml"
    status="$(_runtime_yaml_scalar "$path" status)"
    t_worker="$(_runtime_yaml_scalar "$path" primary_worker)"
    scope_count=0
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      scope_count=$((scope_count + 1))
      abs="$(_preflight_abs_scope "$root" "$entry")"
      # glob 앞부분까지를 실제 경로로 보고 가장 가까운 존재하는 조상을 찾는다.
      probe="${abs%%[\*\?\[]*}"
      while [[ -n "$probe" && ! -e "$probe" ]]; do probe="$(dirname "$probe")"; done
      [[ -d "$probe" ]] || probe="$(dirname "$probe")"
      if [[ ! -w "$probe" ]]; then
        pf_fail "$task_id: write_scope '$entry' — 실행 환경에서 쓸 수 없습니다 ($probe)." \
          "경로 권한을 고치거나 Task의 write_scope를 쓰기 가능한 경로로 (dispatch 전에)"
        continue
      fi
      case "$abs/" in
        "$root"/*) pf_ok "$task_id: write_scope '$entry' (프로젝트 안, 쓰기 가능)" ;;
        *)
          repo_top="$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null || true)"
          if [[ -n "$repo_top" ]] && git -C "$repo_top" rev-parse HEAD >/dev/null 2>&1; then
            pf_ok "$task_id: write_scope '$entry' — 외부 저장소 $repo_top (HEAD $(git -C "$repo_top" rev-parse --short HEAD), 쓰기 가능)"
            pf_info "$task_id: 외부 저장소의 변경을 기록·대조하려면 dispatch에 --cwd '$repo_top'를 준다."
          else
            pf_warn "$task_id: write_scope '$entry' — 프로젝트 밖이며 Git 기준선이 없습니다. 변경 대조·Diff Review를 할 수 없습니다." \
              "대상 디렉터리에서 git init + 기준 commit, 또는 inventory.md에 사유 기록"
          fi
          if [[ "$approval_mode" != bypass ]]; then
            pf_warn "$task_id: approval_mode=$approval_mode의 Sandbox는 기동 디렉터리 밖 쓰기를 막을 수 있습니다 (Worker=$t_worker)." \
              "dispatch --cwd <대상 저장소>로 기동하거나 bypass 사용 여부를 사용자와 결정"
          fi
          ;;
      esac
    done < <(yaml_flow_list "$path" write_scope)
    if (( scope_count == 0 )) && [[ "$status" != draft ]]; then
      pf_warn "$task_id: write_scope가 비어 있습니다 — submitted 전이의 변경 파일 대조가 생략됩니다." \
        "$path의 write_scope에 수정 허용 경로를 적는다"
    fi
  done
  (( ${#open_tasks[@]} > 0 )) || pf_info "열린 Task가 없습니다 — Planner가 Task를 만든 뒤 다시 실행하면 write_scope도 점검합니다."

  # --- 8. 참고 자산 ---------------------------------------------------------
  printf '\n## 8. 기존 자산 인벤토리\n\n'
  local inventory="$root/.harness/references/inventory.md" rows=0
  if [[ -f "$inventory" ]]; then
    # 표 머리 행과 구분선을 뺀 데이터 행 수.
    rows="$(awk '/^\|/ && !/^\|[-| :]+\|$/ { n++ } END { print (n > 1 ? n - 1 : 0) }' "$inventory")"
    if (( rows == 0 )); then
      pf_info "references/inventory.md가 비어 있습니다 — harness-spec 단계에서 기존 코드·문서·Dump·외부 저장소 경로를 기록한다."
    else
      pf_info "references/inventory.md 항목 ${rows}개"
    fi
  else
    pf_warn "references/inventory.md가 없습니다." "init 템플릿과 같은 표 머리를 가진 파일을 만든다"
  fi

  printf '\n'
  if (( fails > 0 )); then
    printf 'preflight: 실패 %d · 경고 %d — [FAIL]을 고친 뒤 다시 실행한다.\n' "$fails" "$warns"
    return 1
  fi
  printf 'preflight: 통과 (경고 %d)\n' "$warns"
}

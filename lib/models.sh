# herdr-harness: 모델 등급·생각 깊이 선택과 쿼터 관리 — 비싼 모델의 불필요한 사용과 쿼터 소진을 줄인다.
# harness.sh가 source한다. 단독 실행하지 않는다.

task_tier() {  # TASK_FILE ROLE → light|standard|premium (Task 지정 > models.default_tier > standard)
  local t
  t="$(yget "$1" "${2}_tier")"
  [[ -n "$t" ]] || t="$(pget models default_tier standard)"
  case "$t" in light|standard|premium) printf '%s' "$t" ;; *) die "등급은 light | standard | premium입니다: ${2}_tier=$t ($1)" ;; esac
}

task_effort() {  # TASK_FILE ROLE → low|medium|high|빈 값
  local e
  e="$(yget "$1" "${2}_effort")"
  [[ -n "$e" ]] || e="$(pget models default_effort)"
  case "$e" in ""|low|medium|high) printf '%s' "$e" ;; *) die "생각 깊이는 low | medium | high입니다: ${2}_effort=$e ($1)" ;; esac
}

# 등급 → project.yaml models.<provider>_<tier> 모델. 비어 있으면 Provider 기본 모델(인수 없음).
# premium은 계획 승인 표에 premium으로 승인된 Task·역할만 쓴다. 메인 셸에서 부른다.
select_model() {  # TASK ROLE PROVIDER → SEL_TIER SEL_MODEL SEL_EFFORT SEL_ARGS
  local tf flag
  tf="$(task_file "$1")"
  SEL_TIER="$(task_tier "$tf" "$2")"
  SEL_EFFORT="$(task_effort "$tf" "$2")"
  SEL_MODEL="$(pget models "${3}_${SEL_TIER}")"
  SEL_ARGS=()
  if [[ "$SEL_TIER" == premium && "$(plan_tier "$1" "$2")" != premium ]]; then
    die "$1 $2의 premium 등급은 계획 승인 때 승인되지 않았습니다. approve-plan으로 다시 승인받는다."
  fi
  if [[ -n "$SEL_MODEL" ]]; then
    [[ "$SEL_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]] || die "models.${3}_${SEL_TIER} 형식이 올바르지 않습니다: $SEL_MODEL"
    SEL_ARGS+=(--model "$SEL_MODEL")
  fi
  if [[ -n "$SEL_EFFORT" ]]; then
    case "$3" in
      claude) SEL_ARGS+=(--effort "$SEL_EFFORT") ;;
      codex)  SEL_ARGS+=(-c "model_reasoning_effort=\"$SEL_EFFORT\"") ;;
      *)      # agy는 모델 ID에 속도가 들어 있다. 그 밖의 에이전트는 플래그를 정해 둔 경우만.
        flag="$(pget agents "${3}_effort_flag")"
        if [[ -n "$flag" ]]; then
          [[ "$flag" =~ ^--?[A-Za-z0-9-]+$ ]] || die "agents.${3}_effort_flag 형식 오류: $flag"
          SEL_ARGS+=("$flag" "$SEL_EFFORT")
        fi ;;
    esac
  fi
}

# 실제 모델 목록 조회(읽기 전용). 정책은 바꾸지 않고 매핑이 실제로 있는지만 보여 준다.
models_query() {  # PROVIDER → 모델 ID 한 줄씩 (조회 불가면 실패)
  case "$1" in
    agy) agy models 2>/dev/null | awk 'NF { print $1 }' | grep -E '^[A-Za-z0-9][A-Za-z0-9._:/@-]*$' ;;
    codex) command -v jq >/dev/null 2>&1 && codex debug models 2>/dev/null | jq -r '.. | objects | (.slug? // .id? // empty)' 2>/dev/null | sort -u ;;
    *) return 1 ;;
  esac
}

cmd_models() {
  local refresh=0 p t m list
  [[ "${1:-}" != --refresh ]] || refresh=1
  printf '기본 등급: %s · 기본 생각 깊이: %s\n\n' "$(pget models default_tier standard)" "$(pget models default_effort)"
  printf '| Provider | light | standard | premium |%s\n|---|---|---|---|%s\n' \
    "$( ((refresh)) && echo ' 실제 목록 대조 |')" "$( ((refresh)) && echo '---|')"
  while IFS= read -r p; do
    printf '| %s ' "$p"
    for t in light standard premium; do m="$(pget models "${p}_${t}")"; printf '| %s ' "${m:-(기본)}"; done
    if (( refresh )); then
      if list="$(models_query "$p")" && [[ -n "$list" ]]; then
        local bad=""
        for t in light standard premium; do
          m="$(pget models "${p}_${t}")"
          [[ -z "$m" ]] || grep -qxF -- "$m" <<<"$list" || bad+="$t=$m "
        done
        printf '| %s ' "$([[ -z "$bad" ]] && echo '일치' || echo "목록에 없음: $bad")"
      else
        printf '| 조회 불가 '
      fi
    fi
    printf '|\n'
  done < <(providers)
  printf '\n등급 기준: light=기계적 변경(치환·문서 정리·정형 출력) · standard=설계가 정해진 일반 구현 · premium=설계 판단·보안 경계·상태 전이·원인 추적\n'
  printf '변경: .harness/project.yaml의 models.<provider>_<등급>. premium Task는 approve-plan 때 함께 승인된다.\n'
  if (( refresh )); then
    printf '\n실제 모델 목록:\n'
    for p in agy codex; do
      list="$(models_query "$p" || true)"
      printf '  %s: %s\n' "$p" "$(tr '\n' ' ' <<<"${list:-(조회 불가)}")"
    done
  fi
}

# 출력에서 알려진 한도 문구만 찾는다. 화면에는 테스트 출력·배너도 섞이므로 이것만으로 판단하지 않는다
# (run은 Agent가 비정상으로 멈췄을 때만 소진으로 본다). 못 찾았다고 여유가 있다는 뜻도 아니다.
quota_exhausted() {
  grep -Eqi 'usage limit reached|rate.?limit (exceeded|reached)|quota.?exceeded|429 too many requests|out of credits' <<<"$1" || return 1
  printf '한도 소진 문구'
}
quota_warning() {  # "N% of your weekly limit"는 사용량이다 → 남은 비율로 바꿔 알린다(정보용)
  local used
  used="$(grep -Eio '[0-9]+% of your (weekly|daily|five.hour|5.hour) limit' <<<"$1" | grep -Eo '^[0-9]+' | sort -n | tail -n 1 || true)"
  [[ -n "$used" ]] || return 1
  printf '한도 경고 (사용 %s%% · 남은 약 %s%%)' "$used" "$(( used > 100 ? 0 : 100 - used ))"
}

# 능동 확인. agy는 --print로 바로, claude·codex는 떠 있는 Agent에 /status를 보내 읽는다.
cmd_quota_check() {
  local provider="" task="" role="" out low pct name status=unknown detail
  if [[ "${1:-}" == --provider ]]; then provider="${2:-}"
  else
    task="${1:-}"; role="${2:-worker}"
    [[ -n "$task" ]] || die "사용법: quota-check TASK [worker|reviewer] | quota-check --provider agy"
    provider="$(yget "$(task_file "$task")" "$([[ "$role" == worker ]] && echo primary_worker || echo reviewer)")"
  fi
  is_provider "$provider" || die "알 수 없는 Provider: $provider"
  low="$(pnum limits quota_low_pct 25)"
  case "$provider" in
    agy)
      command -v agy >/dev/null 2>&1 || die "agy 명령이 없습니다."
      hcap agy --print "/usage"; out="$OUT"
      pct="$(awk -F'\t' 'NF >= 3 { v = $3; gsub(/%/, "", v); v += 0; if (!s || v < m) { m = v; s = 1 } } END { if (s) print m }' <<<"$out")"
      if [[ -n "$pct" ]]; then
        detail="최소 남은 한도 ${pct}% (기준 ${low}%)"
        if (( pct < low )); then status=low; else status=ok; fi
      else detail="출력 형식을 해석하지 못했습니다"; fi ;;
    *)
      [[ -n "$task" ]] || die "$provider는 떠 있는 Task Agent가 필요합니다: quota-check TASK ROLE"
      name="$(meta_get "$(meta_file "$task" "$role")" agent)"
      [[ -n "$name" ]] || die "dispatch 기록이 없습니다: $task $role"
      herdr agent prompt "$name" "/status" --wait --timeout 30000 >/dev/null 2>&1 || true
      hcap herdr agent read "$name" --source recent-unwrapped --lines 80; out="$OUT"
      if detail="$(quota_exhausted "$out")"; then status=low
      elif detail="$(quota_warning "$out")"; then
        pct="$(grep -Eo '남은 약 [0-9]+' <<<"$detail" | grep -Eo '[0-9]+')"
        if (( pct < low )); then status=low; else status=ok; fi
      else detail="알려진 경고 문구 없음 (형식이 다를 수 있음)"; fi ;;
  esac
  printf 'quota_check: provider=%s status=%s detail=%s\n' "$provider" "$status" "$detail"
  [[ "$status" != low ]] || exit 1
}

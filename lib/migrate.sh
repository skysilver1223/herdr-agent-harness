# herdr-harness: v1 프로젝트를 v2로 이전한다 (migrate). 저장소의 harness.sh로 실행한다.
#
#   무손실   지우지 않고 옮긴다. 옮기기 전 해시를 재고 옮긴 뒤 하나하나 대조하며, 목록을 archive/v1/MANIFEST.txt로
#            커밋한다. Git 추적 여부도 그대로 둔다(추적하던 파일은 계속 추적, Git 밖 파일은 계속 Git 밖).
#   되돌림   시작 commit에 태그(harness-v1-final)를 달고 새 브랜치(harness-v2-migration)에 commit 하나로 남긴다.
#            도중에 실패하면 작업 기록(.git/harness-migrate.journal)을 거꾸로 되짚어 시작 상태로 되돌린다.
#   사용자 결정은 인수로   검토 수준 예외(--review-level --reason), 완료 인정(--complete --complete-reason).
#            v1 제출 건을 v2의 승인 대기로 옮기지 않는다(v2의 증빙·교차 검토를 거치지 않았다). 열린 Task는 draft로
#            돌아가 v2 계획 승인(approve-plan)부터 다시 밟는다(v2는 계획 승인 없이 ready가 될 수 없다).
#   손대지 않는 곳   원격 마운트, .harness/worktrees, 프로젝트 안의 다른 파일시스템. 런타임은 최상위 v1 파일만
#            runtime/v1/로 옮긴다(Git 밖 그대로 — v2가 v1 Agent 추적 파일을 자기 것으로 읽어 status·dispatch가 어긋나지 않게).
#   v1 Harness가 만든 것만 옮긴다. 사용자가 .harness 안에 둔 다른 파일·폴더와 사용자 Skill은 그대로 둔다.
# --apply 없이 실행하면 사전 점검 보고서만 출력하고 아무것도 바꾸지 않는다.
# harness.sh가 source한다. 단독 실행하지 않는다.

MG_TAG=harness-v1-final
MG_BRANCH=harness-v2-migration
MG_MARK='## Harness v2 운영 규칙'
MG_SEP=$'\x1f'   # 빈 칸이 있어도 합쳐지지 않는 구분자 (탭은 IFS에서 공백처럼 합쳐진다)
MG_DOCS=(AGENTS.md CLAUDE.md GEMINI.md HARNESS_START.md)   # 덮어쓰지 않고 v2 절만 덧붙이는 진입 문서 (HARNESS_START.md는 v1이 만든 시작 안내)

mg_block() { MG_BLOCK+=("$*"); }
mg_warn()  { MG_WARN+=("$*"); }
mg_todo()  { MG_TODO+=("$*"); }
mg_cell()  { local v="${1//|/\\|}"; v="${v//$'\n'/ }"; printf '%s' "$v"; }
mg_list()  { local v="${1#\[}"; v="${v%\]}"; v="${v// /}"; printf '%s' "$v"; }   # '[a, b]' → 'a,b'

mg_grade_label() {
  case "$1" in
    full) echo '완전' ;; partial) echo '부분' ;; fail) echo '실패 기록' ;; none) echo '없음' ;; manual) echo '사람 확인만' ;; *) echo '-' ;;
  esac
}

# --------------------------------------------------------------------------
# 조사 — v1 파일을 읽기만 한다.
# --------------------------------------------------------------------------
mg_task_fields() {  # FILE → task_id·status·milestone_id·primary_worker·reviewer·title (MG_SEP 구분). 형식 오류면 실패
  local a b c d e g
  a="$(yget "$1" task_id)" || return 1
  b="$(yget "$1" status)" || return 1
  c="$(yget "$1" milestone_id)" || return 1
  d="$(yget "$1" primary_worker)" || return 1
  e="$(yget "$1" reviewer)" || return 1
  g="$(yget "$1" title)" || return 1
  printf '%s\n' "$a$MG_SEP$b$MG_SEP$c$MG_SEP$d$MG_SEP$e$MG_SEP$g"
}

mg_mounts() {  # → 프로젝트 안의 마운트 지점 (상대 경로). 들어가지도 옮기지도 않는다
  local dev mp rest
  [[ -r /proc/self/mounts ]] || return 0
  while read -r dev mp rest; do
    mp="$(printf '%b' "$mp")"   # /proc/mounts는 공백 등을 \040처럼 적는다
    [[ "$mp" == "$MG_DIR"/* ]] && printf '%s\n' "${mp#"$MG_DIR/"}"
  done </proc/self/mounts
  return 0
}

mg_find() {  # → .harness·.agents 아래 파일(일반·링크), 프로젝트 기준 상대 경로, NUL 구분
  local p
  local -a starts=() pr=(-path .harness/runtime -o -path .harness/worktrees -o -path .harness/remote-mount -o -path .harness/bin)
  [[ ! -d "$MG_DIR/.harness" ]] || starts+=(.harness)
  [[ ! -d "$MG_DIR/.agents" ]] || starts+=(.agents)
  for p in ${MG_PROTECT[@]+"${MG_PROTECT[@]}"}; do pr+=(-o -path "$p"); done
  (( ${#starts[@]} )) || return 0
  # 보호 경로는 들어가지 않는다(-prune). 다른 파일시스템(마운트)도 넘지 않는다(-xdev).
  (cd "$MG_DIR" && find "${starts[@]}" -xdev \( "${pr[@]}" \) -prune -o \( -type f -o -type l \) -print0)
}

mg_mount_alive() {  # DIR → 5초 안에 응답하는가. 끊긴 SSHFS에서 멈추지 않게 뒤에서 확인한다
  local pid i
  ( stat -- "$1" >/dev/null 2>&1 ) & pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; return; fi
    sleep 0.5
  done
  disown "$pid" 2>/dev/null || true
  return 1
}

mg_owner() {  # BASENAME → MG_OWNER (아는 Task ID 중 가장 긴 접두사, 없으면 빈 값)
  local id
  MG_OWNER=""
  for id in "${!MG_KNOWN[@]}"; do
    if [[ "$1" == "$id"-* || "$1" == "$id".* ]] && (( ${#id} > ${#MG_OWNER} )); then MG_OWNER="$id"; fi
  done
}

mg_reserved() {  # decisions/의 파일 이름이 v2 기록과 겹치는가 (남기면 v2가 자기 기록으로 읽거나 덮어쓴다)
  local m
  [[ ! "$1" =~ ^(review-level-[0-9]+|.+-review-level-[0-9]+|.+-rejection-[0-9]+|.+-plan-approval)\.md$ ]] || return 0
  [[ "$1" == *-approval.md ]] || return 1
  m="${1%-approval.md}"
  [[ -n "$m" ]] || return 1
  [[ "$m" == milestone-* || -n "${MG_MSET[$m]:-}" ]]
}

# 파일 하나의 처리. v1 Harness가 만든 것만 옮기고, 열린 Task의 Intent·결정과 사용자 파일은 그대로 둔다.
mg_classify() {  # REL → MG_C_OP(move|keep|convert|append) MG_C_DST
  local p="$1" rest d b s id cls=""
  MG_C_OP=move MG_C_DST=""
  case "$p" in
    .agents/roles/*) MG_C_DST=".harness/archive/v1/agents/${p#.agents/}"; return 0 ;;   # 점 없는 이름: 도구가 옛 Skill을 찾지 않게
    .agents/skills/*/*)
      s="${p#.agents/skills/}"; s="${s%%/*}"
      if [[ -d "$TEMPLATE_DIR/.agents/skills/$s" ]]; then MG_C_DST=".harness/archive/v1/agents/${p#.agents/}"
      else MG_C_OP=keep MG_C_DST="$p"; fi
      return 0 ;;
    .agents/*) MG_C_OP=keep MG_C_DST="$p"; return 0 ;;
    .harness/project.yaml) MG_C_DST=.harness/archive/v1/project.yaml; return 0 ;;
    .harness/policies/remote.yaml) MG_C_DST=.harness/remote.yaml; return 0 ;;
    .harness/HISTORY.md) MG_C_OP=append MG_C_DST="$p"; return 0 ;;
  esac
  rest="${p#.harness/}"; d="${rest%%/*}"; b="${p##*/}"
  case "$d" in
    tasks)
      if [[ "$rest" == tasks/*.yaml && "$rest" != tasks/*/* ]]; then
        id="${b%.yaml}"
        case "${MG_CLASS[$id]:-}" in
          done) MG_C_DST=".harness/archive/${MG_BDIR[$id]}/tasks/$b"; return 0 ;;
          open) MG_C_OP=convert MG_C_DST=".harness/archive/v1/tasks-v1/$b"; return 0 ;;   # archive/*/tasks/ 아님: 보관 Task로 오인되지 않게
        esac
      fi
      MG_C_DST=".harness/archive/v1/tasks-v1/${rest#tasks/}"; return 0 ;;
    intents|decisions|attempts|reviews|evidence|handovers)
      mg_owner "$b"
      [[ -z "$MG_OWNER" ]] || cls="${MG_KNOWN[$MG_OWNER]:-}"
      if [[ -z "$MG_OWNER" && "$b" =~ ^task-[0-9]+[-.] ]]; then cls=orphan; fi   # v1에서 지워진 Task의 기록
      # v2 기록과 이름이 겹치는 결정(M-approval.md 등)은 남기지 않는다: v2가 자기 기록으로 읽거나 덮어쓴다
      if [[ "$d" == decisions ]] && mg_reserved "$b"; then MG_C_DST=".harness/archive/v1/$rest"; return 0; fi
      case "$cls" in
        done) MG_C_DST=".harness/archive/${MG_BDIR[$MG_OWNER]}/$rest"; return 0 ;;
        open) if [[ "$d" == intents || "$d" == decisions ]]; then MG_C_OP=keep MG_C_DST="$p"; return 0; fi ;;
        "") if [[ ( "$d" == intents || "$d" == decisions ) && "$b" != README.md && "$b" != TEMPLATE.md && "$rest" != */*/* ]]; then
              MG_C_OP=keep MG_C_DST="$p"; return 0   # 프로젝트 결정·메모
            fi ;;
      esac
      MG_C_DST=".harness/archive/v1/$rest"; return 0 ;;
    STATE.md|policies|profiles|waves|archive|superseded|planned) MG_C_DST=".harness/archive/v1/$rest"; return 0 ;;
  esac
  MG_C_OP=keep MG_C_DST="$p"   # SPEC·MILESTONES·references와 사용자가 둔 파일
}

# 열린 Task를 v2 형식으로: status draft, schema '2', write_scope·dependencies 블록 목록 → [a, b] 한 줄.
# 다른 필드는 그대로 둔다(v2가 쓰지 않는 v1 필드도 보존).
mg_convert() {  # SRC DST
  awk -v q="'" '
    function trim(v) { sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); return v }
    function unq(v) {
      v = trim(v)
      if (length(v) >= 2 && v ~ /^".*"$/) return substr(v, 2, length(v) - 2)
      if (length(v) >= 2 && substr(v, 1, 1) == q && substr(v, length(v), 1) == q) { v = substr(v, 2, length(v) - 2); gsub(q q, q, v); return v }
      if (match(v, /[ \t]#/)) return unq(substr(v, 1, RSTART - 1))
      return v
    }
    function qq(v) { gsub(q, q q, v); return q v q }
    function flush() { if (key != "") { print key ": [" items "]"; key = ""; items = "" } }
    { sub(/\r$/, "") }
    key != "" {
      if ($0 ~ /^[ \t]*-([ \t]|$)/) {
        it = $0; sub(/^[ \t]*-[ \t]*/, "", it); it = unq(it)
        if (index(it, ",")) bad = bad " " key
        if (it != "") items = items (items == "" ? "" : ", ") qq(it)
        next
      }
      if ($0 ~ /^[ \t]*(#.*)?$/) { held = held $0 "\n"; next }
      flush(); printf "%s", held; held = ""
    }
    /^(write_scope|dependencies):[ \t]*(#.*)?$/ { key = $0; sub(/:.*/, "", key); next }
    /^status:/ { print "status: draft"; next }
    /^schema_version:/ { print "schema_version: " q "2" q; next }
    { print }
    END {
      flush(); printf "%s", held
      if (bad != "") { print "쉼표가 들어간 항목은 v2의 한 줄 목록으로 바꿀 수 없습니다:" bad > "/dev/stderr"; exit 2 }
    }
  ' "$1" >"$2"
}

# 열린 Task를 변환해 v2 규칙으로 검사한다. 이전을 막는 문제는 MG_BLOCK, 계획 때 고칠 것은 MG_TODO.
mg_check_open() {  # FILE ID
  local f="$1" id="$2" tmp k v out dep
  local -a notes=()
  tmp="$(mktemp "${TMPDIR:-/tmp}/harness-migrate.XXXXXX")"; TMP_FILES+=("$tmp")
  if ! out="$(mg_convert "$f" "$tmp" 2>&1)"; then mg_block "$id: $out"; return 0; fi
  if grep -qE '^(write_scope|dependencies):[[:space:]]*(#.*)?$' "$f"; then notes+=("목록 형식 변환"); fi
  [[ -n "${MG_MS[$id]}" ]] || mg_block "$id: milestone_id가 없습니다 (v2 Task는 Milestone에 속해야 한다)"
  for k in worker_tier reviewer_tier worker_effort reviewer_effort worker_model reviewer_model write_scope dependencies intent; do
    if ! v="$(yget "$tmp" "$k" 2>&1)"; then mg_block "$id: $k — ${v##*오류: }"; continue; fi
    case "$k" in
      *_tier) case "$v" in ""|light|standard|premium) ;; *) mg_block "$id: $k 값을 v2가 모릅니다 ($v — light | standard | premium)" ;; esac ;;
      *_effort) case "$v" in ""|low|medium|high) ;; *) mg_block "$id: $k 값을 v2가 모릅니다 ($v — low | medium | high)" ;; esac ;;
      *_model) [[ -z "$v" || "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]] || mg_block "$id: $k 이름 형식을 v2가 받지 않습니다 ($v)" ;;
      intent) if [[ -z "$v" || ! -f "$MG_DIR/$v" ]]; then mg_todo "$id: intent 파일이 없습니다 (${v:-미지정}) — 계획 승인 전에 작성"; fi ;;
    esac
  done
  for k in write_scope dependencies; do
    if ! out="$( (ylist "$tmp" "$k") 2>&1 )"; then mg_block "$id: $k — ${out##*오류: }"; fi
  done
  out="$( (ylist "$tmp" write_scope) 2>/dev/null )" || out=""
  [[ -n "$out" ]] || mg_todo "$id: write_scope가 비어 있습니다 — 계획 때 수정 경로를 적는다"
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    case "${MG_KNOWN[$dep]:-}" in
      open|done) ;;
      *) mg_todo "$id: 선행 Task 없음 — $dep (v1에서 대체·삭제됨). 계획 때 dependencies를 고친다" ;;
    esac
  done < <( (ylist "$tmp" dependencies) 2>/dev/null || true)
  ac_load "$tmp"
  if [[ -n "$AC_ERR" ]]; then mg_todo "$id: $AC_ERR — 계획 승인 전에 보완"; notes+=("AC 보완 필요"); fi
  for v in "${MG_W[$id]}" "${MG_R[$id]}"; do
    [[ "$v" =~ ^[a-z][a-z0-9-]*$ ]] || mg_block "$id: Provider 이름 형식 오류 (${v:-빈 값})"
  done
  if [[ "${MG_W[$id]}" == "${MG_R[$id]}" ]]; then MG_SAME+=("$id"); notes+=("같은 회사 검토"); fi
  MG_NOTE[$id]="$(IFS=,; printf '%s' "${notes[*]:-}")"
  MG_NOTE[$id]="${MG_NOTE[$id]//,/ · }"
}

mg_checks_results() {  # v1 checks.yaml → "criterion<TAB>result" 줄
  awk -v q="'" '
    function clean(v) { sub(/^[^:]*:[ \t]*/, "", v); gsub("[\"" q "]", "", v); sub(/[ \t]+$/, "", v); return v }
    { sub(/\r$/, "") }
    /^[ \t]*-[ \t]*criterion_id:/ { id = clean($0); next }
    /^[ \t]+result:/ && id != "" { print id "\t" clean($0); id = "" }
  ' "$1"
}

# v1 완료 Task의 증빙 등급: 마지막 AC 실행 기록(evidence/T-attempt-N-checks.yaml)이 command AC를 모두 통과했는가.
# v1 원격 모드에는 반복문 안의 ssh가 남은 입력을 먹어 첫 AC만 실행되던 결함이 있었다 — 그런 기록은 partial로 드러난다.
mg_grade() {  # TASK_FILE ID → MG_G(full|partial|fail|none|manual) MG_GN(근거)
  local tf="$1" id="$2" f n max=0 latest="" aid typ cmd res base
  local -a cmds=() formal=() missing=() failed=()
  local -A got=()
  while IFS=$'\t' read -r aid typ cmd; do
    [[ -n "$aid" && "$aid" != ERR ]] || continue
    aid="$(unquote "$aid")"; typ="$(unquote "$typ")"; cmd="$(unquote "$cmd")"
    [[ "$typ" == command ]] || continue
    if formal_cmd "$cmd"; then formal+=("$aid"); else cmds+=("$aid"); fi
  done < <(ac_entries "$tf" || true)
  if (( ${#cmds[@]} == 0 )); then
    MG_G=manual; MG_GN="실행해 확인하는 command AC 없음"
    (( ${#formal[@]} == 0 )) || MG_GN+=" (형식적 명령 ${formal[*]}은 증빙이 아님)"
    return 0
  fi
  for f in "$MG_DIR/.harness/evidence/$id-attempt-"*-checks.yaml; do
    [[ -f "$f" ]] || continue
    n="${f##*-attempt-}"; n="${n%-checks.yaml}"
    if [[ "$n" =~ ^[0-9]+$ ]] && (( 10#$n > max )); then max=$((10#$n)); latest="$f"; fi
  done
  if [[ -z "$latest" ]]; then MG_G=none; MG_GN="v1 AC 실행 기록(evidence/$id-attempt-N-checks.yaml) 없음"; return 0; fi
  while IFS=$'\t' read -r aid res; do [[ -z "$aid" ]] || got[$aid]="$res"; done < <(mg_checks_results "$latest" || true)
  for aid in "${cmds[@]}"; do
    case "${got[$aid]:-}" in pass) ;; fail) failed+=("$aid") ;; *) missing+=("$aid") ;; esac
  done
  base="마지막 실행(attempt $max): command ${#cmds[@]}개 중 $(( ${#cmds[@]} - ${#missing[@]} - ${#failed[@]} ))개 통과"
  if (( ${#failed[@]} )); then MG_G=fail; MG_GN="$base, 실패 ${failed[*]}"
  elif (( ${#missing[@]} || ${#formal[@]} )); then MG_G=partial; MG_GN="$base"
    (( ${#missing[@]} == 0 )) || MG_GN+=", 미실행 ${missing[*]}"
  else MG_G=full; MG_GN="$base"; fi
  (( ${#formal[@]} == 0 )) || MG_GN+=", 형식적 명령 ${formal[*]}은 증빙이 아님"
  return 0
}

mg_live_agents() {  # → Herdr에 아직 있는 v1 Agent (이름과 Pane이 v1 추적 파일과 같은 것)
  local m name pane out=""
  command -v herdr >/dev/null 2>&1 || return 0
  for m in "$MG_DIR"/.harness/runtime/*.meta; do
    [[ -f "$m" ]] || continue
    name="$(sed -n 's/^agent_name=//p' "$m" | tail -n 1)"; pane="$(sed -n 's/^pane_id=//p' "$m" | tail -n 1)"
    [[ -n "$name" ]] || continue
    hcap herdr agent get "$name"
    (( RC == 0 )) || continue
    [[ -z "$pane" || "$(jfield "$OUT" pane_id)" == "$pane" ]] || continue
    out+="$name "
  done
  printf '%s' "${out% }"
}

mg_models() {  # v1 agent-policy의 모델 설정 → v2 models (MG_MODEL, MG_DTIER, MG_DEFFORT)
  local ap="$MG_DIR/.harness/policies/agent-policy.yaml" p t v def prem rt
  for p in $MG_AVAIL; do
    def="$(sget "$ap" agent_policy "${p}_default_model")"
    prem="$(sget "$ap" agent_policy "${p}_premium_models")"; prem="${prem%% *}"
    for t in light standard premium; do
      v="$(sget "$ap" agent_policy "${p}_tier_$t")"
      # v1은 등급 매핑이 비면 기본 모델을 썼다. v2는 등급 매핑만 보므로 그 뜻을 매핑에 옮긴다.
      if [[ -z "$v" && "$t" != premium ]]; then v="$def"; fi
      if [[ -z "$v" && "$t" == premium ]]; then v="$prem"; fi
      [[ -n "$v" ]] || continue
      if [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ ]]; then MG_MODEL[${p}_$t]="$v"
      else mg_warn "모델 이름 형식이 맞지 않아 옮기지 않음: ${p}_$t = $v"; fi
    done
  done
  MG_DTIER="$(sget "$ap" agent_policy worker_default_tier)"
  case "$MG_DTIER" in ""|light|standard|premium) ;; *) mg_warn "worker_default_tier($MG_DTIER)를 v2가 몰라 standard로 둔다"; MG_DTIER="" ;; esac
  rt="$(sget "$ap" agent_policy reviewer_default_tier)"
  [[ -z "$rt" || "$rt" == "$MG_DTIER" ]] || mg_warn "v2의 기본 등급은 하나(models.default_tier)다 — Worker 기본값(${MG_DTIER:-standard})을 쓰고, Reviewer 기본 등급($rt)은 Task의 reviewer_tier로 지정한다"
  MG_DEFFORT="$(sget "$ap" agent_policy worker_default_effort)"
  case "$MG_DEFFORT" in ""|low|medium|high) ;; *) mg_warn "worker_default_effort($MG_DEFFORT)를 v2가 몰라 비워 둔다"; MG_DEFFORT="" ;; esac
}

mg_args() {  # v1 Provider 인수가 v2 내장 기본값과 다를 때만 옮긴다 (MG_ARGS)
  local ap="$MG_DIR/.harness/policies/agent-policy.yaml" p mode v builtin
  for p in $MG_AVAIL; do
    for mode in auto bypass; do
      v="$(sget "$ap" agent_policy "${p}_${mode}")"
      [[ -n "$v" ]] || continue
      builtin="$(approval_args_raw "$p" "$mode")"
      [[ "$v" != "$builtin" ]] || continue
      if [[ "$v" =~ ^[-A-Za-z0-9=_./\ ]*$ ]] && { [[ "$mode" != auto ]] || ! grep -Eqi 'dangerous|bypass|danger-full-access' <<<"$v"; }; then
        MG_ARGS[${p}_$mode]="$v"
      else
        mg_warn "v1 Provider 인수를 v2가 받지 않아 옮기지 않음: ${p}_$mode = $v"
      fi
    done
  done
}

mg_survey() {
  local h="$MG_DIR/.harness" pj ap pp qp rp f id info tid st m w r title act s p
  local -a carr=() cand=()
  local -A seen=()
  pj="$h/project.yaml"; ap="$h/policies/agent-policy.yaml"; pp="$h/policies/project-policy.yaml"
  qp="$h/policies/quota-policy.yaml"; rp="$h/policies/remote.yaml"
  MG_NAME="$(sget "$pj" project name "$(basename "$MG_DIR")")"
  MG_GOAL="$(sget "$pj" project goal)"
  MG_PROFILE="$(sget "$pj" project profile generic)"
  if ! profile_focus "$MG_PROFILE" >/dev/null; then mg_warn "v2에 없는 profile이라 generic으로 둔다: $MG_PROFILE"; MG_PROFILE=generic; fi
  MG_ORCH="$(sget "$pj" providers orchestrator claude)"
  MG_WORKER="$(sget "$pj" providers primary_worker codex)"
  MG_REVIEWER="$(sget "$pj" providers reviewer agy)"
  MG_FALLBACK="$(mg_list "$(sget "$pj" providers fallback_chain claude)")"
  MG_MODE="$(sget "$ap" agent_policy approval_mode auto)"
  case "$MG_MODE" in ask|auto|bypass) ;; *) mg_warn "v2가 모르는 approval_mode라 auto로 둔다: $MG_MODE"; MG_MODE=auto ;; esac
  MG_PAR="$(sget "$pj" limits max_parallel_workers 2)"
  MG_ACTIVE="$(sget "$pj" limits max_active_tasks 5)"
  MG_TIMEOUT="$(sget "$pp" execution acceptance_check_timeout_seconds 600)"
  MG_QLOW="$(sget "$qp" quota_policy low_warning_threshold_pct 25)"
  MG_AUTOFAIL="$(sget "$qp" quota_policy automatic_failover false)"
  for s in "max_parallel_workers=$MG_PAR" "acceptance_check_timeout_seconds=$MG_TIMEOUT" "low_warning_threshold_pct=$MG_QLOW"; do
    [[ "${s#*=}" =~ ^[0-9]+$ ]] || mg_block "v1 설정 값이 숫자가 아닙니다: $s"
  done
  [[ -n "$MG_GOAL" && "$MG_GOAL" != *$'\n'* ]] || mg_warn "project.goal이 비었거나 여러 줄입니다"

  MG_REMOTE=0 MG_MOUNT="" MG_MOUNT_REL=""
  if [[ -f "$rp" ]]; then
    if awk '$0 == "remote:" { r = 1; next } /^[^[:space:]#]/ { r = 0 } r && /^  enabled:[[:space:]]*["\047]?true["\047]?([[:space:]]|#|$)/ { f = 1 } END { exit !f }' "$rp"; then MG_REMOTE=1; fi
    MG_MOUNT="$(_remote_expand_tilde "$(_remote_field "$rp" mount_path)")"
    if [[ -n "$MG_MOUNT" ]]; then
      [[ "$MG_MOUNT" == /* ]] || MG_MOUNT="$MG_DIR/$MG_MOUNT"
      MG_MOUNT="$(realpath -ms "$MG_MOUNT")"   # -s: 경로만 정리한다(마운트 지점을 stat하지 않는다)
      if [[ "$MG_MOUNT" == "$MG_DIR"/* ]]; then MG_MOUNT_REL="${MG_MOUNT#"$MG_DIR/"}"; fi
    fi
  fi
  MG_PROTECT=(); MG_MOUNTED=()
  [[ -z "$MG_MOUNT_REL" ]] || MG_PROTECT+=("$MG_MOUNT_REL")
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    MG_MOUNTED[$s]=1
    if [[ " ${MG_PROTECT[*]:-} " != *" $s "* ]]; then MG_PROTECT+=("$s"); fi
    # 응답 없는 마운트(끊긴 SSHFS)는 아래 find·git이 멈출 수 있다. 먼저 확인해 멈추는 대신 막는다.
    mg_mount_alive "$MG_DIR/$s" || mg_block "프로젝트 안의 마운트가 응답하지 않습니다: $s — remote unmount 등으로 정리한 뒤 이전한다"
  done < <(mg_mounts)
  MG_RAW_IGNORED=0
  # --no-index: 안에 강제로 추적한 파일이 있어도 규칙으로 판단한다 (그 파일은 사전 점검이 따로 막는다)
  if [[ -d "$h/evidence/raw" ]] && git -C "$MG_DIR" check-ignore -q --no-index -- .harness/evidence/raw/ 2>/dev/null; then MG_RAW_IGNORED=1; fi

  # Task: 대체된(superseded) ID → 진행 중 Task 분류 → 열린 Task 검사(모든 ID를 안 뒤에 의존을 본다)
  for f in "$h"/superseded/*.yaml; do
    [[ -f "$f" ]] || continue
    id="${f##*/}"; MG_KNOWN[${id%.yaml}]=superseded
  done
  if [[ -n "$MG_COMPLETE" ]]; then
    IFS=, read -r -a carr <<<"$MG_COMPLETE"
    for id in "${carr[@]}"; do id="${id// /}"; [[ -z "$id" ]] || MG_WANT[$id]=1; done
  fi
  for f in "$h"/tasks/*.yaml; do
    [[ -f "$f" ]] || continue
    id="${f##*/}"; id="${id%.yaml}"
    [[ "$id" != TEMPLATE ]] || continue
    if [[ ! "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then mg_block "Task 파일 이름을 v2가 쓸 수 없습니다: tasks/$id.yaml"; continue; fi
    if ! info="$(mg_task_fields "$f" 2>&1)"; then mg_block "$id: Task 파일을 읽지 못했습니다 — $(tail -n 1 <<<"$info")"; continue; fi
    IFS="$MG_SEP" read -r tid st m w r title <<<"$info"
    MG_IDS+=("$id"); MG_ST[$id]="$st"; MG_MS[$id]="$m"; MG_TITLE[$id]="$title"; MG_W[$id]="$w"; MG_R[$id]="$r"
    [[ -z "$m" ]] || MG_MSET[$m]=1
    case "$st" in
      completed) act=archive ;;
      submitted|reviewing|awaiting_approval) if [[ -n "${MG_WANT[$id]:-}" ]]; then act=complete; else act=draft; fi ;;
      draft|ready|active|blocked|handover_required|changes_requested) act=draft ;;
      *) mg_block "$id: 알 수 없는 v1 상태입니다 (${st:-빈 값})"; act=draft ;;
    esac
    if [[ -n "${MG_WANT[$id]:-}" && "$act" != complete ]]; then
      mg_block "$id: 완료 인정(--complete)은 제출·검토 중·승인 대기 Task만 할 수 있습니다 (현재 ${st:-빈 값})"
    fi
    MG_ACT[$id]="$act"
    if [[ "$act" == draft ]]; then
      MG_CLASS[$id]=open
      [[ "$tid" == "$id" ]] || mg_block "$id: task_id(${tid:-빈 값})가 파일 이름과 다릅니다"
    else
      MG_CLASS[$id]=done
      if [[ -n "$m" && ! "$m" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then mg_block "$id: milestone_id를 보관 폴더 이름으로 쓸 수 없습니다 ($m)"; fi
      MG_BDIR[$id]="v1-${m:-unassigned}"
      MG_BCOUNT[${MG_BDIR[$id]}]=$(( ${MG_BCOUNT[${MG_BDIR[$id]}]:-0} + 1 ))
      mg_grade "$f" "$id"; MG_GRADE[$id]="$MG_G"; MG_GNOTE[$id]="$MG_GN"
    fi
    MG_KNOWN[$id]="${MG_CLASS[$id]}"
  done
  for id in "${!MG_WANT[@]}"; do [[ -n "${MG_ACT[$id]:-}" ]] || mg_block "--complete에 적은 Task가 없습니다: $id"; done
  [[ -z "$MG_COMPLETE" || -n "$MG_CREASON" ]] || mg_block "--complete에는 --complete-reason \"사유\"가 필요합니다 (결정 기록에 남는다)"
  MG_OPEN=0
  for id in ${MG_IDS[@]+"${MG_IDS[@]}"}; do
    [[ "${MG_CLASS[$id]}" == open ]] || continue
    MG_OPEN=$((MG_OPEN + 1))
    mg_check_open "$h/tasks/$id.yaml" "$id"
  done
  MG_OPENMAX=$(( MG_OPEN > 10 ? MG_OPEN : 10 ))

  # 쓸 수 있는 에이전트 = 기본 배정·예비·열린 Task가 쓰는 것 (v2 validate가 모두 요구한다)
  cand=("$MG_ORCH" "$MG_WORKER" "$MG_REVIEWER" ${MG_FALLBACK//,/ })
  for id in ${MG_IDS[@]+"${MG_IDS[@]}"}; do [[ "${MG_CLASS[$id]}" != open ]] || cand+=("${MG_W[$id]}" "${MG_R[$id]}"); done
  for p in "${cand[@]}"; do
    [[ -n "$p" ]] || continue
    [[ "$p" =~ ^[a-z][a-z0-9-]*$ ]] || { mg_block "Provider 이름 형식 오류: $p"; continue; }
    seen[$p]=1
  done
  MG_AVAIL=""
  for p in claude codex agy; do [[ -z "${seen[$p]:-}" ]] || MG_AVAIL+="$p "; done
  for p in $(printf '%s\n' "${!seen[@]}" | sort); do
    case "$p" in claude|codex|agy) ;; *) MG_AVAIL+="$p " ;; esac
  done
  MG_AVAIL="${MG_AVAIL% }"
  mg_models
  mg_args

  # 검토 수준: 같은 회사 Task가 있으면 사용자 결정(예외)이 필요하다
  if [[ "$MG_LEVEL" == cross_provider ]] && { (( ${#MG_SAME[@]} )) || [[ "$MG_WORKER" == "$MG_REVIEWER" ]]; }; then
    mg_block "같은 회사(Worker = Reviewer) 배정이 있어 검토 수준 예외가 필요합니다 ($( (( ${#MG_SAME[@]} )) && printf 'Task: %s' "${MG_SAME[*]}" || printf '기본 배정: %s' "$MG_WORKER")) — --review-level cross_model --reason \"사유\" (사용자 결정)"
  fi
  [[ "$MG_LEVEL" == cross_provider || -n "$MG_REASON" ]] || mg_block "--review-level $MG_LEVEL에는 --reason \"사유\"가 필요합니다 (결정 기록에 남는다)"
  if [[ "$MG_LEVEL" == cross_model ]]; then
    for id in ${MG_SAME[@]+"${MG_SAME[@]}"}; do
      w="$(yget "$h/tasks/$id.yaml" worker_model 2>/dev/null)" || w=""
      r="$(yget "$h/tasks/$id.yaml" reviewer_model 2>/dev/null)" || r=""
      [[ -n "$w" ]] || w="${MG_MODEL[${MG_W[$id]}_${MG_DTIER:-standard}]:-}"
      [[ -n "$r" ]] || r="${MG_MODEL[${MG_R[$id]}_${MG_DTIER:-standard}]:-}"
      if [[ -z "$w" || -z "$r" || "$w" == "$r" ]]; then
        mg_todo "$id: 같은 회사·다른 모델 검토에는 Worker·Reviewer 모델이 달라야 합니다 (지금 ${w:-Provider 기본값} / ${r:-Provider 기본값}) — 계획 때 worker_model·reviewer_model 또는 등급으로 나눈다"
      fi
    done
  fi
}

# --------------------------------------------------------------------------
# 계획 — 파일마다 처리(옮김·그대로·변환·덧붙임)를 정한다.
# --------------------------------------------------------------------------
mg_gitignore_lines() {  # → .gitignore에 없는 v2 줄
  local l
  while IFS= read -r l; do
    [[ -n "$l" && "$l" != \#* ]] || continue
    grep -qxF -- "$l" "$MG_DIR/.gitignore" 2>/dev/null || printf '%s\n' "$l"
  done <"$TEMPLATE_DIR/.gitignore"
  if (( MG_RAW_IGNORED )) && ! grep -qxF -- '.harness/archive/*/evidence/raw/' "$MG_DIR/.gitignore" 2>/dev/null; then
    printf '%s\n' '.harness/archive/*/evidence/raw/'   # Git 밖이던 v1 원문 로그는 옮긴 뒤에도 Git 밖
  fi
  return 0
}

# 옮길 v1 기록이 원래 자리에 남아도 v2와 부딪히지 않는가.
#   v1 운영 파일·템플릿·Skill은 남기면 옛 지시가 살아난다.
#   v2 기록과 이름이 겹치는 결정은 v2가 자기 기록으로 읽거나 덮어쓴다.
#   시도·리뷰·인계는 v2가 같은 이름으로 쓰거나 인계 문서로 오인한다. ID가 다시 쓰이지 않는 보관된(done) Task 것만 남길 수 있다.
#   대체·삭제된 Task의 ID는 새 v2 Task가 다시 쓸 수 있어, v2가 쓰지 않는 evidence/만 남긴다.
mg_can_stay() {  # SRC
  local rest="${1#.harness/}" d b cls=""
  [[ "$1" == .harness/* ]] || return 1
  d="${rest%%/*}"; b="${1##*/}"
  case "$d" in intents|decisions|evidence|attempts|reviews|handovers) ;; *) return 1 ;; esac
  case "$b" in README.md|TEMPLATE.md|TEMPLATE.yaml) return 1 ;; esac
  if [[ "$d" == decisions ]] && mg_reserved "$b"; then return 1; fi
  mg_owner "$b"
  [[ -z "$MG_OWNER" ]] || cls="${MG_KNOWN[$MG_OWNER]:-}"
  if [[ -z "$MG_OWNER" && "$b" =~ ^task-[0-9]+[-.] ]]; then cls=orphan; fi
  case "$cls" in
    done) return 0 ;;
    open) [[ "$d" == intents || "$d" == decisions || "$d" == evidence ]] ;;
    "")   # 어느 Task에도 속하지 않는 메모. 단 v2 기록 이름(X-attempt-N.md 등)을 닮았으면 새 Task X와 부딪힌다
      [[ "$d" == intents || "$d" == decisions || "$d" == evidence || ! "$b" =~ -(attempt|review|handover)-[0-9]+(\.harness)?\.md$ ]] ;;
    *) [[ "$d" == evidence ]] ;;
  esac
}

# 앞으로도 쓰이는 파일(열린 Task·그 Intent·결정, 프로젝트 결정, SPEC, 사용자 문서 등 Git이 추적하는 남는 파일)이
# 경로로 가리키는 v1 기록은 옮기지 않는다 — 참조가 끊기지 않게. 이렇게 남긴 기록이 다시 가리키는 것은 따라가지 않는다
# (v1 기록끼리는 자동으로 서로를 많이 가리켜, 따라가면 보관할 것이 거의 남지 않는다). 남길 수 없는 것은 MG_BROKEN.
# git grep 출력 형식은 사용자 설정(줄 번호·경로 인용·색)과 무관하게 고정한다.
mg_refs() {
  local pf i src rel line f m
  local -A pat=() moving=() hits=()
  git -C "$MG_DIR" rev-parse -q --verify HEAD >/dev/null 2>&1 || return 0
  pf="$(mktemp "${TMPDIR:-/tmp}/harness-migrate.XXXXXX")"; TMP_FILES+=("$pf")
  for i in "${!MG_P_OP[@]}"; do
    [[ "${MG_P_OP[$i]}" == move ]] || continue
    src="${MG_P_SRC[$i]}"; moving[$src]=1
    rel="${src#.harness/}"; pat[$rel]=$i
    printf '%s\n' "$rel" >>"$pf"
  done
  [[ -s "$pf" ]] || return 0
  while IFS= read -r line; do
    f="${line%%"$MG_SEP"*}"; m="${line#*"$MG_SEP"}"
    [[ -z "${moving[$f]:-}" && -n "${pat[$m]:-}" ]] || continue   # 함께 옮겨지는 파일끼리의 참조는 보관함 안에서 그대로 이어진다
    [[ "$MG_SEP${hits[$m]:-}" == *"$MG_SEP$f$MG_SEP"* ]] || hits[$m]+="$f$MG_SEP"
  done < <(git -C "$MG_DIR" -c grep.lineNumber=false -c grep.column=false -c core.quotePath=false \
             grep --no-color -z -I -F -o -f "$pf" -- . ':(exclude).harness/runtime' 2>/dev/null | tr '\0' "$MG_SEP" || true)
  for m in "${!hits[@]}"; do
    i="${pat[$m]}"; src="${MG_P_SRC[$i]}"
    f="${hits[$m]%"$MG_SEP"}"; f="${f//"$MG_SEP"/, }"
    if mg_can_stay "$src"; then MG_P_OP[$i]=keep; MG_P_DST[$i]="$src"; MG_KEPTREF[$src]="$f"
    else MG_BROKEN[$src]="$f"; fi
  done
  return 0
}

mg_q() {  # 셸에 그대로 붙여 넣을 수 있게 인용 (가능하면 큰따옴표)
  if [[ "$1" =~ ^[A-Za-z0-9_./:,@+=-]+$ ]]; then printf '%s' "$1"
  elif [[ "$1" != *[\"\$\`\\!]* ]]; then printf '"%s"' "$1"
  else printf '%q' "$1"; fi
}

# v2 운영 규칙 절을 넣을 문서: AGENTS.md, 또는 AGENTS.md가 링크로 가리키는 저장소 안의 진입 문서(AGENTS.md → CLAUDE.md 등).
# AGENTS.md가 저장소 밖을 가리키면 그 파일은 고치지 않고 CLAUDE.md·GEMINI.md에 절을 넣는다(MG_AGENTS_DOC 빈 값).
mg_agents_doc() {
  local t d
  MG_AGENTS_DOC=AGENTS.md
  [[ -L "$MG_DIR/AGENTS.md" ]] || return 0
  MG_AGENTS_DOC=""
  t="$(realpath -m -- "$MG_DIR/AGENTS.md" 2>/dev/null)" || t=""
  for d in CLAUDE.md GEMINI.md HARNESS_START.md; do
    if [[ -n "$t" && "$t" == "$MG_DIR/$d" && -f "$MG_DIR/$d" && ! -L "$MG_DIR/$d" ]]; then MG_AGENTS_DOC="$d"; fi
  done
  if [[ -z "$MG_AGENTS_DOC" ]]; then
    local where="저장소 밖" got=""
    [[ -z "$t" || "$t" != "$MG_DIR"/* ]] || where="저장소 안의 다른 파일"
    for d in CLAUDE.md GEMINI.md; do if [[ -f "$MG_DIR/$d" && ! -L "$MG_DIR/$d" ]]; then got+="$d·"; fi; done
    if [[ -n "$got" ]]; then
      mg_warn "AGENTS.md가 $where(→ $(readlink -- "$MG_DIR/AGENTS.md"))을 가리켜 고치지 않는다. v2 운영 규칙 절은 ${got%·}에 넣는다 — AGENTS.md만 읽는 에이전트(codex 등)를 위해 링크 대상에도 직접 더한다"
    else
      mg_warn "AGENTS.md가 $where(→ $(readlink -- "$MG_DIR/AGENTS.md"))을 가리키고 CLAUDE.md·GEMINI.md도 일반 파일이 아니라 v2 운영 규칙 절을 넣을 곳이 없다 — 링크 대상에 직접 더한다"
    fi
  fi
  return 0
}

mg_doc_kind() {  # 진입 문서 → rules(v2 운영 규칙 절) | note(짧은 안내) | skip(링크는 고치지 않는다)
  if [[ -L "$MG_DIR/$1" ]]; then echo skip; return 0; fi
  if [[ -n "$MG_AGENTS_DOC" ]]; then
    if [[ "$1" == "$MG_AGENTS_DOC" ]]; then echo rules; else echo note; fi
    return 0
  fi
  case "$1" in
    CLAUDE.md|GEMINI.md) if [[ -f "$MG_DIR/$1" ]]; then echo rules; else echo note; fi ;;   # 없으면 v2 템플릿으로 만든다
    *) echo note ;;
  esac
}

mg_mark_for() { if [[ "$(mg_doc_kind "$1")" == rules ]]; then printf '%s' "$MG_MARK"; else printf '## Harness v2'; fi; }

mg_plan() {
  local listf errf rel frc=0 f d i t
  local -A dsts=()
  MG_P_OP=(); MG_P_SRC=(); MG_P_DST=(); MG_RTN=0
  while IFS= read -r -d '' f; do MG_TRACKED[$f]=1; done \
    < <(git -C "$MG_DIR" ls-files -z -- .harness .agents "${MG_DOCS[@]}" .gitignore 2>/dev/null || true)
  listf="$(mktemp "${TMPDIR:-/tmp}/harness-migrate.XXXXXX")"; errf="$(mktemp "${TMPDIR:-/tmp}/harness-migrate.XXXXXX")"
  TMP_FILES+=("$listf" "$errf")
  mg_find >"$listf" 2>"$errf" || frc=$?
  (( frc == 0 )) || mg_block "읽을 수 없는 폴더·파일이 있어 빠짐없이 옮길 수 없습니다: $(head -n 3 "$errf" | tr '\n' ' ')"
  while IFS= read -r -d '' rel; do
    if [[ "$rel" == *$'\t'* || "$rel" == *$'\n'* || "$rel" == *"$MG_SEP"* ]]; then mg_block "파일 이름에 탭·줄바꿈이 있어 옮길 수 없습니다: $rel"; continue; fi
    mg_classify "$rel"
    MG_P_OP+=("$MG_C_OP"); MG_P_SRC+=("$rel"); MG_P_DST+=("$MG_C_DST")
  done < <(sort -z <"$listf")
  mg_refs
  # 런타임은 최상위 파일만 (하위 폴더는 들어가지 않는다)
  for f in "$MG_DIR"/.harness/runtime/* "$MG_DIR"/.harness/runtime/.[!.]*; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    rel="${f#"$MG_DIR/"}"
    MG_P_OP+=(move); MG_P_SRC+=("$rel"); MG_P_DST+=(".harness/runtime/v1/${rel#.harness/runtime/}")
    MG_RTN=$((MG_RTN + 1))
  done
  # 진입 문서는 덮어쓰지 않고 v2 절만 덧붙인다. 링크는 따라가 고치지 않는다(저장소 밖 공용 파일일 수 있다).
  mg_agents_doc
  for rel in "${MG_DOCS[@]}"; do
    [[ -f "$MG_DIR/$rel" || -L "$MG_DIR/$rel" ]] || continue
    if [[ -L "$MG_DIR/$rel" ]]; then
      MG_P_OP+=(keep)
      t="$(realpath -m -- "$MG_DIR/$rel")"
      case "$t" in
        "$MG_DIR/AGENTS.md"|"$MG_DIR/CLAUDE.md"|"$MG_DIR/GEMINI.md"|"$MG_DIR/HARNESS_START.md") ;;   # 다른 진입 문서를 가리키면 그쪽에 덧붙는다
        *) mg_warn "$rel: 링크(→ $(readlink -- "$MG_DIR/$rel"))라 덧붙이지 않는다. 필요하면 링크 대상에 v2 운영 규칙을 직접 더한다" ;;
      esac
    elif grep -qxF -- "$(mg_mark_for "$rel")" "$MG_DIR/$rel"; then MG_P_OP+=(keep)
    else MG_P_OP+=(append); fi
    MG_P_SRC+=("$rel"); MG_P_DST+=("$rel")
  done
  if [[ -L "$MG_DIR/.gitignore" ]]; then
    [[ -z "$(mg_gitignore_lines)" ]] || mg_block ".gitignore가 링크라 v2 줄을 덧붙이지 않습니다 — 링크를 풀거나 다음 줄을 직접 더해 commit한 뒤 이전한다: $(mg_gitignore_lines | tr '\n' ' ')"
    MG_P_OP+=(keep); MG_P_SRC+=(.gitignore); MG_P_DST+=(.gitignore)
  elif [[ -f "$MG_DIR/.gitignore" ]]; then
    if [[ -n "$(mg_gitignore_lines)" ]]; then MG_P_OP+=(append); else MG_P_OP+=(keep); fi
    MG_P_SRC+=(.gitignore); MG_P_DST+=(.gitignore)
  fi
  # 옮길 자리가 비어 있어야 한다 (덮어쓰지 않는다)
  for i in "${!MG_P_OP[@]}"; do
    [[ "${MG_P_OP[$i]}" == move || "${MG_P_OP[$i]}" == convert ]] || continue
    d="${MG_P_DST[$i]}"
    [[ -z "${dsts[$d]:-}" ]] || mg_block "옮길 자리가 겹칩니다: $d"
    dsts[$d]=1
    if [[ -e "$MG_DIR/$d" || -L "$MG_DIR/$d" ]]; then mg_block "옮길 자리에 이미 파일이 있습니다: $d"; fi
  done
  for d in .harness/archive/v1 .harness/runtime/v1 .harness/bin; do
    [[ ! -e "$MG_DIR/$d" ]] || mg_block "이전이 새로 만들 폴더가 이미 있습니다: $d"
  done
  for d in "${!MG_BCOUNT[@]}"; do
    [[ ! -e "$MG_DIR/.harness/archive/$d" ]] || mg_block "이전이 새로 만들 폴더가 이미 있습니다: .harness/archive/$d"
  done
}

mg_preflight() {
  local top line n live gd p ign=0 i d gv gmaj gmin
  local -a tr_dst=() ig_dst=() ig_src=()
  gv="$(git --version 2>/dev/null | awk '{print $3}')"
  IFS=. read -r gmaj gmin _ <<<"$gv"
  if ! [[ "$gmaj" =~ ^[0-9]+$ && "$gmin" =~ ^[0-9]+$ ]] || (( gmaj < 2 || (gmaj == 2 && gmin < 23) )); then
    mg_block "Git 2.23 이상이 필요합니다 (되돌리기에 git restore를 쓴다): ${gv:-알 수 없음}"
  fi
  top="$(git -C "$MG_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$top" ]]; then mg_block "Git 저장소가 아닙니다 (이전은 태그·브랜치로 되돌림을 보장하므로 Git이 필요하다)"; return 0; fi
  [[ "$top" -ef "$MG_DIR" ]] || mg_block "프로젝트 폴더가 Git 저장소의 최상위가 아닙니다 (최상위: $top)"
  git -C "$MG_DIR" rev-parse -q --verify HEAD >/dev/null || { mg_block "Git commit이 없습니다"; return 0; }
  git -C "$MG_DIR" symbolic-ref -q HEAD >/dev/null || mg_block "브랜치에 있지 않습니다 (detached HEAD)"
  if [[ -z "$(git -C "$MG_DIR" config user.name || true)" || -z "$(git -C "$MG_DIR" config user.email || true)" ]]; then
    mg_block "git user.name/email이 없습니다 (이전 결과를 commit한다)"
  fi
  if git -C "$MG_DIR" rev-parse -q --verify "refs/tags/$MG_TAG" >/dev/null; then
    [[ "$(git -C "$MG_DIR" rev-parse "$MG_TAG^{commit}")" == "$(git -C "$MG_DIR" rev-parse HEAD)" ]] ||
      mg_block "태그가 이미 다른 commit에 있습니다: $MG_TAG"
  fi
  ! git -C "$MG_DIR" rev-parse -q --verify "refs/heads/$MG_BRANCH" >/dev/null || mg_block "브랜치가 이미 있습니다: $MG_BRANCH (지난 이전 결과를 확인한 뒤 지운다)"
  if [[ -n "$(git -C "$MG_DIR" for-each-ref --count=1 --format='%(refname)' "refs/heads/$MG_BRANCH/" "refs/tags/$MG_TAG/")" ]]; then
    mg_block "같은 이름 아래에 브랜치·태그가 있어 $MG_BRANCH·$MG_TAG를 만들 수 없습니다 (git for-each-ref refs/heads/$MG_BRANCH/ refs/tags/$MG_TAG/)"
  fi
  gd="$(git -C "$MG_DIR" rev-parse --absolute-git-dir)"
  [[ ! -e "$gd/harness-migrate.journal" ]] || mg_block "지난 이전이 끝나지 않은 기록이 있습니다: $gd/harness-migrate.journal — 되돌리기: harness.sh migrate $(mg_q "$MG_DIR") --rollback"
  # 보호 경로(마운트)가 Git 무시 목록에 없으면 git status가 그 안을 훑는다(원격 전체). 그 전에 멈춘다.
  # 마운트된 곳은 stat하지 않는다(/proc/self/mounts로 안다). 마운트되지 않은 폴더만 있는지 본다.
  for p in ${MG_PROTECT[@]+"${MG_PROTECT[@]}"}; do
    if [[ -z "${MG_MOUNTED[$p]:-}" && ! -e "$MG_DIR/$p" ]]; then continue; fi
    if ! git -C "$MG_DIR" check-ignore -q -- "$p/"; then mg_block "마운트 경로가 .gitignore에 없습니다: $p — 추가해 commit한 뒤 이전한다"; ign=1; fi
  done
  (( ign == 0 )) || return 0
  line="$(git -C "$MG_DIR" status --porcelain --untracked-files=no 2>/dev/null || true)"
  n="$(grep -c . <<<"$line" || true)"
  (( n == 0 )) || mg_block "커밋되지 않은 변경 ${n}개 (추적 파일) — 먼저 commit한다: $(head -n 3 <<<"$line" | cut -c4- | tr '\n' ' ')"
  line="$(git -C "$MG_DIR" status --porcelain --untracked-files=all -- .harness .agents .claude/skills "${MG_DOCS[@]}" .gitignore 2>/dev/null | grep '^??' || true)"
  n="$(grep -c . <<<"$line" || true)"
  (( n == 0 )) || mg_block "Harness 경로에 커밋되지 않은 새 파일 ${n}개 — 먼저 commit한다: $(head -n 3 <<<"$line" | cut -c4- | tr '\n' ' ')"
  line="$(git -C "$MG_DIR" status --porcelain 2>/dev/null | grep '^??' | grep -vE '^\?\? "?(\.harness/|\.agents/|\.claude/|AGENTS\.md|CLAUDE\.md|GEMINI\.md|HARNESS_START\.md|\.gitignore)' || true)"
  n="$(grep -c . <<<"$line" || true)"
  (( n == 0 )) || mg_warn "이전과 무관한 미추적 파일·폴더 ${n}개는 그대로 둔다 (commit에 넣지 않는다)"
  # 제자리에서 바꾸는 파일(열린 Task·진입 문서·.gitignore)은 Git이 추적해야 실패 때 git으로 되돌린다.
  for i in "${!MG_P_OP[@]}"; do
    case "${MG_P_OP[$i]}" in convert|append) ;; *) continue ;; esac
    [[ -n "${MG_TRACKED[${MG_P_SRC[$i]}]:-}" ]] ||
      mg_block "Git이 추적하지 않는 파일은 제자리에서 바꾸지 않습니다(실패 때 되돌릴 수 없다): ${MG_P_SRC[$i]} — commit하거나 무시 목록에서 뺀 뒤 이전한다"
  done
  # .gitignore 예측: 추적하던 파일·새 기록은 옮긴 뒤에도 추적되고, Git 밖 파일은 계속 Git 밖이어야 한다.
  for i in "${!MG_P_OP[@]}"; do
    d="${MG_P_DST[$i]}"
    case "${MG_P_OP[$i]}" in
      convert) tr_dst+=("$d") ;;
      move)
        [[ "$d" != .harness/runtime/v1/* ]] || continue   # 런타임 안에서만 옮긴다 (Git 밖 그대로)
        if [[ -n "${MG_TRACKED[${MG_P_SRC[$i]}]:-}" ]]; then
          tr_dst+=("$d")
          if (( MG_RAW_IGNORED )) && [[ "$d" == .harness/archive/*/evidence/raw/* ]]; then
            mg_block "Git이 추적하는 v1 원문 로그가 있습니다: ${MG_P_SRC[$i]} — 보관 위치(evidence/raw)는 Git 밖으로 두므로 먼저 git rm --cached로 추적을 푼 뒤 이전한다"
          fi
        elif (( MG_RAW_IGNORED )) && [[ "$d" == .harness/archive/*/evidence/raw/* ]]; then :   # 덧붙일 규칙이 Git 밖으로 둔다
        else ig_dst+=("$d"); ig_src+=("${MG_P_SRC[$i]}"); fi ;;
    esac
  done
  tr_dst+=(.harness/project.yaml .harness/HISTORY.md .harness/archive/v1/MANIFEST.txt .harness/archive/v1/MIGRATION.md)
  for d in "${!MG_BCOUNT[@]}"; do tr_dst+=(".harness/archive/$d/SUMMARY.md"); done
  line="$(printf '%s\n' "${tr_dst[@]}" | git -C "$MG_DIR" check-ignore --no-index --stdin 2>/dev/null || true)"
  [[ -z "$line" ]] || mg_block "옮기거나 새로 만들 기록이 .gitignore 규칙에 걸려 Git에서 빠집니다: $(head -n 3 <<<"$line" | paste -sd' ') — 규칙을 고쳐 commit한 뒤 이전한다"
  if (( ${#ig_dst[@]} )); then
    line="$(printf '%s\n' "${ig_dst[@]}" | git -C "$MG_DIR" check-ignore --no-index --stdin 2>/dev/null || true)"
    for i in "${!ig_dst[@]}"; do
      if ! grep -qxF -- "${ig_dst[$i]}" <<<"$line"; then
        mg_block "Git 밖이던 파일이 옮긴 자리에서는 추적됩니다: ${ig_src[$i]} → ${ig_dst[$i]} — .gitignore에 규칙을 더해 commit한 뒤 이전한다"
        break
      fi
    done
  fi
  live="$(mg_live_agents)"
  [[ -z "$live" ]] || mg_block "v1이 띄운 Agent가 아직 Herdr에 있습니다: $live — 작업을 마치고 Pane을 닫은 뒤 이전한다"
  return 0
}

mg_cfg() { MG_CFG+=("| $(mg_cell "$1") | $(mg_cell "$2") | $(mg_cell "$3") |"); }

mg_config_rows() {
  local ap="$MG_DIR/.harness/policies/agent-policy.yaml" k v v1m="" v2m="" args
  MG_CFG=()
  mg_cfg "프로젝트" "$MG_NAME · $MG_PROFILE" "그대로"
  mg_cfg "기본 배정 (Orchestrator / Worker / Reviewer / 예비)" "$MG_ORCH / $MG_WORKER / $MG_REVIEWER / $MG_FALLBACK" "그대로"
  mg_cfg "쓸 수 있는 에이전트" "(지정 없음)" "[${MG_AVAIL// /, }] — 기본 배정·예비·열린 Task가 쓰는 것"
  mg_cfg "도구 승인 모드" "$MG_MODE" "$MG_MODE"
  args="v2 내장 기본값 (v1 값과 같음)"
  (( ${#MG_ARGS[@]} == 0 )) || args="v1 값 유지: $(printf '%s ' "${!MG_ARGS[@]}")"
  mg_cfg "Provider 인수" "policies/agent-policy.yaml" "$args"
  mg_cfg "동시 Worker" "$MG_PAR" "$MG_PAR (v1 값 유지 — v2 기본값은 5, 필요하면 limits.max_parallel_workers)"
  mg_cfg "열린 Task 상한" "max_active_tasks $MG_ACTIVE" "max_open_tasks $MG_OPENMAX (열린 Task $MG_OPEN개)"
  mg_cfg "AC 제한 시간" "${MG_TIMEOUT}초" "${MG_TIMEOUT}초"
  mg_cfg "쿼터 경고" "${MG_QLOW}%" "${MG_QLOW}%"
  for k in $MG_AVAIL; do
    for v in default_model tier_light tier_standard tier_premium premium_models models; do
      [[ -z "$(sget "$ap" agent_policy "${k}_$v")" ]] || v1m+="${k}_$v=$(sget "$ap" agent_policy "${k}_$v" | cut -c1-40) "
    done
  done
  for k in $(printf '%s\n' "${!MG_MODEL[@]}" | sort); do v2m+="$k=${MG_MODEL[$k]} "; done
  mg_cfg "모델" "${v1m:-(지정 없음)}" "${v2m:-(지정 없음 — Provider 기본값)}$( [[ "$v1m" != *_models=* ]] || printf ' · 허용 목록은 없다(premium·매핑에 없는 모델은 계획 승인 표로 통제)')"
  mg_cfg "교체 규칙" "automatic_failover: $MG_AUTOFAIL" "failover: ask (자동 교체는 사용자가 정하면 켠다)"
  mg_cfg "검토 수준" "Reviewer는 Worker와 다른 Provider" "$(level_name "$MG_LEVEL")$( [[ "$MG_LEVEL" == cross_provider ]] || printf ' — 결정 기록 decisions/review-level-N.md')"
  if [[ -f "$MG_DIR/.harness/policies/remote.yaml" ]]; then
    mg_cfg "원격 모드" "policies/remote.yaml ($( ((MG_REMOTE)) && echo enabled || echo disabled), 마운트 ${MG_MOUNT:-없음})" ".harness/remote.yaml (내용 그대로)"
  else
    mg_cfg "원격 모드" "없음" ".harness/remote.yaml (꺼짐)"
  fi
}

# --------------------------------------------------------------------------
# 보고서 — 사전 점검(dry-run)은 화면에, 적용하면 archive/v1/MIGRATION.md로 남긴다.
# --------------------------------------------------------------------------
mg_report() {  # MODE(dry-run|apply)
  local mode="$1" id i act line d n=0 keep=0 conv=0 app=0 rt=0 p s cmd ms
  local -A ar=() drafts=()
  local -a legacy=() sup=()
  if [[ "$mode" == apply ]]; then
    printf '# Harness v1 → v2 이전 기록: %s\n\n' "$MG_NAME"
    printf -- '- 프로젝트: %s\n- 시작 commit: %s (브랜치 %s, 태그 %s)\n- 이전 브랜치: %s\n' "$MG_DIR" "$MG_START" "$MG_ORIG" "$MG_TAG" "$MG_BRANCH"
  else
    printf '# Harness v1 → v2 이전 사전 점검: %s\n\n' "$MG_NAME"
    printf -- '- 프로젝트: %s\n- 현재 commit: %s (%s)\n' "$MG_DIR" "$(git -C "$MG_DIR" rev-parse --short HEAD 2>/dev/null || echo -)" \
      "$(git -C "$MG_DIR" symbolic-ref --short HEAD 2>/dev/null || echo '브랜치 없음')"
  fi
  printf -- '- Harness: %s (%s)\n- 시각: %s\n' "$HARNESS_VERSION" "$HARNESS_HOME" "$(now)"

  printf '\n## 적용 조건\n\n'
  if (( ${#MG_BLOCK[@]} )); then for line in "${MG_BLOCK[@]}"; do printf -- '- [차단] %s\n' "$line"; done
  elif [[ "$mode" == apply ]]; then printf -- '- 차단 조건 없음\n'
  else printf -- '- 차단 조건 없음 — 적용할 수 있습니다\n'; fi

  printf '\n## 사용자 결정\n\n'
  if [[ "$MG_LEVEL" == cross_provider ]]; then printf -- '- 검토 수준: %s (기본)\n' "$(level_name "$MG_LEVEL")"
  else printf -- '- 검토 수준: %s — 사유: %s\n' "$(level_name "$MG_LEVEL")" "${MG_REASON:-(없음)}"; fi
  if [[ -n "$MG_COMPLETE" ]]; then printf -- '- 완료 인정: %s — 사유: %s\n' "$MG_COMPLETE" "${MG_CREASON:-(없음)}"
  else printf -- '- 완료 인정: 없음 (제출·검토 중 Task는 v2에서 다시 증빙)\n'; fi

  printf '\n## 설정 변환\n\n| 항목 | v1 | v2 |\n|---|---|---|\n'
  for line in ${MG_CFG[@]+"${MG_CFG[@]}"}; do printf '%s\n' "$line"; done

  printf '\n## Task 처리 (%s개)\n\n| Task | Milestone | v1 상태 | 처리 | Worker / Reviewer | 증빙 등급 | 비고 |\n|---|---|---|---|---|---|---|\n' "${#MG_IDS[@]}"
  for id in ${MG_IDS[@]+"${MG_IDS[@]}"}; do
    case "${MG_ACT[$id]}" in
      archive) act="보관 → archive/${MG_BDIR[$id]}/ (v1 완료)" ;;
      complete) act="보관 → archive/${MG_BDIR[$id]}/ (사용자 완료 인정)" ;;
      *) case "${MG_ST[$id]}" in
           draft|ready) act="draft — v2 계획 승인 후 진행" ;;
           submitted|reviewing|awaiting_approval) act="draft — v2에서 다시 증빙 (완료 인정 안 함)" ;;
           *) act="draft — v2에서 다시 시도 (v1 시도 기록은 보관)" ;;
         esac
         ms="${MG_MS[$id]:-(없음)}"; drafts[$ms]+="$id " ;;
    esac
    case "${MG_GRADE[$id]:-}" in partial|fail|none) legacy+=("$id") ;; esac
    printf '| %s | %s | %s | %s | %s / %s | %s | %s |\n' "$id" "${MG_MS[$id]:--}" "${MG_ST[$id]}" "$act" "${MG_W[$id]}" "${MG_R[$id]}" \
      "$(mg_grade_label "${MG_GRADE[$id]:-}")" "$(mg_cell "${MG_GNOTE[$id]:-${MG_NOTE[$id]:-}}")"
  done
  for id in "${!MG_KNOWN[@]}"; do [[ "${MG_KNOWN[$id]}" != superseded ]] || sup+=("$id"); done
  (( ${#sup[@]} == 0 )) || printf '\nv1에서 대체(superseded)된 Task %s개(%s)는 archive/v1/superseded/로 옮긴다.\n' "${#sup[@]}" "$(printf '%s\n' "${sup[@]}" | sort | paste -sd' ')"

  printf '\n## 파일\n\n'
  for i in "${!MG_P_OP[@]}"; do
    case "${MG_P_OP[$i]}" in
      keep) keep=$((keep + 1)) ;;
      convert) conv=$((conv + 1)) ;;
      append) app=$((app + 1)) ;;
      move)
        d="${MG_P_DST[$i]}"
        if [[ "$d" == .harness/runtime/v1/* ]]; then rt=$((rt + 1))
        elif [[ "$d" == .harness/archive/* ]]; then d="${d#.harness/archive/}"; d="${d%%/*}"; ar[$d]=$(( ${ar[$d]:-0} + 1 ))
        else n=$((n + 1)); fi ;;
    esac
  done
  printf -- '- 그대로 두는 파일: %s개 — SPEC·MILESTONES·references, 열린 Task의 Intent·결정, 프로젝트 결정 기록, 사용자 파일\n' "$keep"
  printf -- '- v2 형식으로 바꾸는 열린 Task: %s개 — status draft, schema 2, write_scope·dependencies 한 줄 목록 (원본 사본: archive/v1/tasks-v1/)\n' "$conv"
  s=""; for d in $(printf '%s\n' "${!ar[@]}" | sort); do s+="archive/$d/ ${ar[$d]}개 · "; done
  printf -- '- 보관함으로 옮기는 파일 (내용 그대로): %s\n' "${s:-없음}"
  (( n == 0 )) || printf -- '- 자리를 옮기는 설정: %s개 (policies/remote.yaml → .harness/remote.yaml)\n' "$n"
  if (( ${#MG_KEPTREF[@]} )); then
    printf -- '- 다른 파일이 가리키고 있어 원래 자리에 두는 v1 기록: %s개 (참조가 끊기지 않게):\n' "${#MG_KEPTREF[@]}"
    while IFS= read -r p; do printf '  - %s ← %s\n' "$p" "$(mg_cell "${MG_KEPTREF[$p]:-}" | cut -c1-160)"; done \
      < <(printf '%s\n' "${!MG_KEPTREF[@]}" | LC_ALL=C sort | head -n 12 || true)
    (( ${#MG_KEPTREF[@]} <= 12 )) || printf '  - … 외 %s개\n' "$(( ${#MG_KEPTREF[@]} - 12 ))"
  fi
  printf -- '- Git 밖 런타임 파일: %s개 → .harness/runtime/v1/ (v2가 v1 Agent 추적 파일을 자기 것으로 읽지 않게)\n' "$rt"
  s=""
  for i in "${!MG_P_OP[@]}"; do
    [[ "${MG_P_OP[$i]}" == append ]] || continue
    case "${MG_P_SRC[$i]}" in
      .gitignore) s+=".gitignore(빠진 줄) · " ;;
      .harness/HISTORY.md) s+="HISTORY.md(이력 줄) · " ;;
      *) s+="${MG_P_SRC[$i]}($( [[ "$(mg_doc_kind "${MG_P_SRC[$i]}")" == rules ]] && echo 'v2 운영 규칙 절' || echo '안내 한 절')) · " ;;
    esac
  done
  printf -- '- 덧붙이는 파일: %s개 — %s\n' "$app" "${s% · }"
  printf -- '- 새로 만드는 파일: v2 project.yaml(v1 원본은 archive/v1/project.yaml), .harness/bin/, Skill 6개(v1 Skill은 archive/v1/agents/skills/), Task·Intent 템플릿'
  [[ -f "$MG_DIR/.harness/BACKLOG.md" ]] || printf ', BACKLOG.md'
  [[ -f "$MG_DIR/.harness/HISTORY.md" ]] || printf ', HISTORY.md'
  [[ -f "$MG_DIR/.harness/policies/remote.yaml" ]] || printf ', remote.yaml(꺼짐)'
  [[ "$MG_LEVEL" == cross_provider ]] || printf ', 검토 수준 결정 기록'
  printf ', 보관 묶음 요약(SUMMARY.md), archive/v1/MIGRATION.md·MANIFEST.txt\n'
  s=""
  for p in .harness/worktrees .harness/remote-mount ${MG_PROTECT[@]+"${MG_PROTECT[@]}"}; do
    [[ " · $s" != *" · $p · "* ]] || continue
    if [[ -n "${MG_MOUNTED[$p]:-}" || -e "$MG_DIR/$p" ]]; then s+="$p · "; fi   # 마운트된 곳은 stat하지 않는다
  done
  printf -- '- 손대지 않는 경로: %s.harness/runtime/의 하위 폴더\n' "$s"

  if (( ${#MG_BROKEN[@]} )); then
    printf '\n## 이전 뒤 끊기는 참조 (%s개)\n\nv1 운영 파일이거나 v2와 이름이 겹쳐 원래 자리에 둘 수 없는 기록을 가리키는 참조입니다. 새 위치는 MANIFEST.txt에도 있습니다.\n\n' "${#MG_BROKEN[@]}"
    while IFS= read -r p; do
      for i in "${!MG_P_SRC[@]}"; do [[ "${MG_P_SRC[$i]}" != "$p" ]] || break; done
      printf -- '- %s → %s (가리키는 파일: %s)\n' "$p" "${MG_P_DST[$i]}" "$(mg_cell "${MG_BROKEN[$p]:-}" | cut -c1-160)"
    done < <(printf '%s\n' "${!MG_BROKEN[@]}" | LC_ALL=C sort | head -n 15 || true)
    (( ${#MG_BROKEN[@]} <= 15 )) || printf -- '- … 외 %s개\n' "$(( ${#MG_BROKEN[@]} - 15 ))"
  fi

  printf '\n## 이전 후 할 일\n\n'
  n=0
  if (( ${#legacy[@]} )); then n=$((n + 1)); printf '%s. v1 증빙 재검증: `.harness/bin/harness.sh verify --legacy` (대상: %s) — 상태는 바꾸지 않는다\n' "$n" "${legacy[*]}"; fi
  while IFS= read -r ms; do
    [[ -n "$ms" ]] || continue
    n=$((n + 1)); printf '%s. %s: harness-plan으로 v2 계약을 보완하고 사용자 계획 승인 → `approve-plan %s --confirm-user-approval` (draft: %s)\n' "$n" "$ms" "$ms" "${drafts[$ms]% }"
  done < <(printf '%s\n' "${!drafts[@]}" | LC_ALL=C sort)
  for line in ${MG_TODO[@]+"${MG_TODO[@]}"}; do n=$((n + 1)); printf '%s. %s\n' "$n" "$line"; done
  n=$((n + 1)); printf '%s. 이후 v1 명령(herdr-harness)은 이 프로젝트에 쓰지 않는다. 명령은 `.harness/bin/harness.sh`\n' "$n"
  if (( ${#MG_WARN[@]} )); then
    printf '\n## 참고\n\n'
    for line in "${MG_WARN[@]}"; do printf -- '- %s\n' "$line"; done
  fi
  if [[ "$mode" == apply ]]; then
    printf '\n## 이전 직후 검사\n\n```text\n%s\n```\n' "$(grep -E '^\[(OK|TODO|FAIL)\]|^validate:' <<<"${MG_VALIDATE:-}" || true)"
    printf '\n파일별 처리와 해시: `.harness/archive/v1/MANIFEST.txt`\n'
  else
    cmd="harness.sh migrate $(mg_q "$MG_DIR") --apply --confirm-user-approval"
    if [[ "$MG_LEVEL" != cross_provider ]]; then cmd+=" --review-level $MG_LEVEL --reason $(mg_q "${MG_REASON:-사유}")"
    elif (( ${#MG_SAME[@]} )) || [[ "$MG_WORKER" == "$MG_REVIEWER" ]]; then cmd+=' --review-level cross_model --reason "사유"'; fi
    [[ -z "$MG_COMPLETE" ]] || cmd+=" --complete $MG_COMPLETE --complete-reason $(mg_q "${MG_CREASON:-사유}")"
    printf '\n## 적용 명령 (사용자 결정 후)\n\n```bash\n%s\n```\n' "$cmd"
    printf '\n- 시작 commit에 태그 %s, 새 브랜치 %s에 commit 하나로 남는다. 실패하면 자동으로 되돌린다.\n' "$MG_TAG" "$MG_BRANCH"
    printf -- '- 제출·검토 중 Task를 완료로 인정하려면 --complete T,T --complete-reason "사유"를 더한다(사용자 결정).\n'
  fi
}

mg_bundle_summary() {  # 보관 묶음 이름 → SUMMARY.md
  local d="$1" id c=0
  printf '# Milestone 요약: %s (v1에서 이전)\n\n' "$d"
  printf -- '- 이전: %s (harness %s migrate) · v1 원본: 태그 %s (%s)\n' "$(now)" "$HARNESS_VERSION" "$MG_TAG" "$MG_START"
  printf -- '- v1 Harness가 완료로 기록한 Task와, 이전 때 사용자가 완료로 인정한 Task다. v2의 증빙(*.harness.md)·교차 검토 기록은 없다.\n'
  printf -- '- 증빙 등급(v1 마지막 AC 실행 기록 기준): full=command AC 모두 통과 · partial=일부 미실행 또는 형식적 명령 · fail=실패 기록 · none=실행 기록 없음 · manual=command AC 없음(사람 확인만)\n'
  printf -- '- 재검증: `.harness/bin/harness.sh verify --legacy` (partial·fail·none 대상, 기록은 이 폴더의 verifications/)\n'
  for id in "${MG_IDS[@]}"; do [[ "${MG_BDIR[$id]:-}" != "$d" || "${MG_ACT[$id]}" != complete ]] || c=$((c + 1)); done
  (( c == 0 )) || printf -- '- 완료 인정 사유(사용자, migrate --complete): %s\n' "$MG_CREASON"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    mg_owner "${id##*/}"
    [[ -n "$MG_OWNER" && "${MG_BDIR[$MG_OWNER]:-}" == "$d" ]] || continue
    printf -- '- 원래 자리에 둔 기록 (다른 파일이 가리킴): %s\n' "$id"
  done < <(printf '%s\n' "${!MG_KEPTREF[@]}" | LC_ALL=C sort)
  printf '\n| Task | 제목 | 처리 | Worker | Reviewer | 증빙 등급 | 근거 |\n|---|---|---|---|---|---|---|\n'
  for id in "${MG_IDS[@]}"; do
    [[ "${MG_BDIR[$id]:-}" == "$d" ]] || continue
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$id" "$(mg_cell "${MG_TITLE[$id]}")" \
      "$( [[ "${MG_ACT[$id]}" == complete ]] && echo '사용자 완료 인정 (이전 때)' || echo 'v1 완료')" \
      "${MG_W[$id]}" "${MG_R[$id]}" "${MG_GRADE[$id]}" "$(mg_cell "${MG_GNOTE[$id]}")"
  done
}

mg_agents_section() {  # TMP → AGENTS.md 끝에 덧붙일 v2 절 (템플릿의 역할 표·불변 규칙을 그대로 가져온다)
  local tmp="$1"   # 호출한 셸이 만들고 지운다 ($( ) 안에서 만든 임시 파일은 정리 목록에 남지 않는다)
  cp "$TEMPLATE_DIR/AGENTS.md" "$tmp"
  render_file "$tmp"
  printf '%s\n\n' "$MG_MARK"
  printf '> %s `harness.sh migrate`로 Harness v1에서 v2(%s)로 이전했다. 위 내용과 다르면 이 절을 따른다.\n' "$(date +%F)" "$HARNESS_VERSION"
  printf '> v1 운영 기록(STATE.md·waves·evidence·역할 문서 `.agents/roles/`)은 `.harness/archive/v1/`, v1에서 완료된 Task는 `.harness/archive/v1-<milestone>/`에 있다 (`.harness/archive/v1/MIGRATION.md`).\n\n'
  printf -- '- 명령: `.harness/bin/harness.sh` (상태 확인은 `status`, 전체 목록은 `help`). 상태는 이 명령으로만 바꾼다.\n'
  printf -- '- 검토 수준: %s (결정 기록: `.harness/decisions/review-level-*.md`).\n' "$(level_name "$MG_LEVEL")"
  printf -- '- v1에서 넘어온 열린 Task는 draft다. harness-plan으로 v2 계약(실행 가능한 command AC, Worker·Reviewer 모델)을 보완하고 사용자 계획 승인(`approve-plan`)을 받은 뒤 진행한다.\n'
  printf -- '- v1 완료 Task 중 증빙이 불완전한 것은 `.harness/bin/harness.sh verify --legacy`로 다시 검증한다(상태는 바꾸지 않는다).\n'
  awk '/^## 역할과 Skill/ { p = 1 } /^## 시작/ { p = 0 } p { if (/^## /) sub(/^## /, "### "); print }' "$tmp"
}

mg_entry_note() {  # 진입 문서 이름 → 끝에 덧붙일 안내
  local dir='.claude/skills/'
  if [[ "$1" == HARNESS_START.md ]]; then
    printf '## Harness v2\n\nHarness v2로 이전했다. 위의 `herdr-harness start .` 대신 `.harness/bin/harness.sh start`를 쓰고, 첫 Pane에서 할 말은 AGENTS.md의 "시작" 절을 따른다.\n'
    return 0
  fi
  [[ "$1" != GEMINI.md ]] || dir='.agents/skills/'
  printf '## Harness v2\n\nHarness v2로 이전했다. 역할 문서(`.agents/roles/`)와 `.harness/STATE.md`는 보관함으로 옮겨져 더 이상 읽지 않는다. AGENTS.md의 "Harness v2 운영 규칙"과 `%s`의 Harness Skill을 따른다.\n' "$dir"
}

# --------------------------------------------------------------------------
# 적용 — 모든 변경을 작업 기록(journal)에 먼저 적는다. 실패·중단하면 거꾸로 되짚는다.
#   mv SRC DST · new PATH(새 파일) · dir PATH(새 폴더) · tree PATH(새 폴더 전체) · rmdir PATH(지운 빈 폴더)
#   tag NAME(만든 태그) · branch ORIG(만든 브랜치와 원래 브랜치)
# 추적 파일의 제자리 수정(열린 Task 변환, 진입 문서·.gitignore 덧붙이기)은 git reset --hard로 되돌린다.
# --------------------------------------------------------------------------
mg_j() { printf '%s\n' "$1$MG_SEP${2:-}$MG_SEP${3:-}" >>"$MG_JOURNAL"; }

mg_mkdir() {  # DIR(상대 경로) — 새로 만든 폴더만 기록한다
  local cur="$1" i
  local -a stack=()
  while [[ -n "$cur" && "$cur" != . && ! -d "$MG_DIR/$cur" ]]; do stack+=("$cur"); cur="$(dirname -- "$cur")"; done
  for (( i = ${#stack[@]} - 1; i >= 0; i-- )); do mg_j dir "${stack[$i]}"; mkdir -- "$MG_DIR/${stack[$i]}"; done
}

mg_tree() {  # DIR — 없던 폴더 전체 (되돌릴 때 옮긴 파일을 모두 꺼낸 뒤 통째로 지운다)
  [[ ! -e "$MG_DIR/$1" ]] || die "이전이 새로 만들 폴더가 이미 있습니다: $1"
  mg_mkdir "$(dirname -- "$1")"
  mg_j tree "$1"
  mkdir -- "$MG_DIR/$1"
}

mg_mv() {  # SRC DST
  [[ ! -e "$MG_DIR/$2" && ! -L "$MG_DIR/$2" ]] || die "옮길 자리에 이미 파일이 있습니다: $2"
  mg_mkdir "$(dirname -- "$2")"
  mg_j mv "$1" "$2"
  mv -- "$MG_DIR/$1" "$MG_DIR/$2"
}

mg_new() {  # PATH — 이전이 새로 만드는 파일 (되돌릴 때 지운다)
  [[ ! -e "$MG_DIR/$1" && ! -L "$MG_DIR/$1" ]] || die "새로 만들 파일이 이미 있습니다: $1"
  mg_mkdir "$(dirname -- "$1")"
  mg_j new "$1"
}

mg_pset() {  # SECTION KEY VALUE — project.yaml 값만 바꾸고 줄 끝 주석은 남긴다 (키가 없으면 pset이 덧붙인다)
  local f="$MG_DIR/.harness/project.yaml" tmp
  if ! awk -v s="$1:" -v k="  $2:" '$0 == s { i = 1; next } /^[^[:space:]#]/ { i = 0 } i && index($0, k) == 1 { f = 1 } END { exit !f }' "$f"; then
    pset "$1" "$2" "$3"; return 0
  fi
  tmp="$(mktemp "$MG_DIR/.harness/.harness-tmp.XXXXXX")"; TMP_FILES+=("$tmp")
  awk -v s="$1:" -v k="  $2:" -v v="$3" -v q="'" '
    $0 == s { i = 1; print; next }
    /^[^[:space:]#]/ { i = 0 }
    i && !d && index($0, k) == 1 {
      c = ""; rest = substr($0, length(k) + 1)
      if (match(rest, "[ \t]+#[^" q "\"]*$")) c = substr(rest, RSTART)
      print k " " v c; d = 1; next
    }
    { print }' "$f" >"$tmp"
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$f"
}

mg_hash_plan() {  # 계획의 원래 파일마다 MG_P_SHA·MG_P_SIZE·MG_P_GIT (옮기기 전)
  local i p
  local -a reg=() regi=() shas=() sizes=()
  MG_P_SHA=(); MG_P_SIZE=(); MG_P_GIT=()
  for i in "${!MG_P_SRC[@]}"; do
    p="${MG_P_SRC[$i]}"
    if [[ -L "$MG_DIR/$p" ]]; then MG_P_SHA[$i]="$(printf 'symlink:%s' "$(readlink -- "$MG_DIR/$p")" | sha256sum | cut -c1-64)"
    else reg+=("$p"); regi+=("$i"); fi
    if [[ -n "${MG_TRACKED[$p]:-}" ]]; then MG_P_GIT[$i]=t; else MG_P_GIT[$i]=-; fi
  done
  if (( ${#reg[@]} )); then
    mapfile -t shas < <(cd "$MG_DIR" && printf '%s\0' "${reg[@]}" | xargs -0 sha256sum -- | sed 's/^\\//' | cut -c1-64)
    (( ${#shas[@]} == ${#reg[@]} )) || die "해시를 계산하지 못한 파일이 있습니다 (읽기 권한 확인)."
    for i in "${!regi[@]}"; do MG_P_SHA[${regi[$i]}]="${shas[$i]}"; done
  fi
  mapfile -t sizes < <(cd "$MG_DIR" && printf '%s\0' "${MG_P_SRC[@]}" | xargs -0 stat -c %s --)
  (( ${#sizes[@]} == ${#MG_P_SRC[@]} )) || die "파일 크기를 읽지 못한 파일이 있습니다."
  for i in "${!sizes[@]}"; do MG_P_SIZE[$i]="${sizes[$i]}"; done
}

mg_verify_manifest() {  # 옮긴 뒤 하나하나 대조한다 — 손실 0이 아니면 commit하지 않는다
  local i op f got bad=0 list=""
  local -a chk=() chki=() shas=()
  for i in "${!MG_P_OP[@]}"; do
    op="${MG_P_OP[$i]}"
    if [[ "$op" == append ]]; then f="${MG_P_SRC[$i]}"; else f="${MG_P_DST[$i]}"; fi   # convert: 보관한 원본 사본
    if [[ "$op" == convert && ! -f "$MG_DIR/${MG_P_SRC[$i]}" ]]; then bad=$((bad + 1)); list+="  없음: ${MG_P_SRC[$i]}"$'\n'; continue; fi
    if [[ ! -e "$MG_DIR/$f" && ! -L "$MG_DIR/$f" ]]; then bad=$((bad + 1)); list+="  없음: $f"$'\n'; continue; fi
    if [[ "$op" == append ]]; then got="$(head -c "${MG_P_SIZE[$i]}" -- "$MG_DIR/$f" | sha256sum | cut -c1-64)"
    elif [[ -L "$MG_DIR/$f" ]]; then got="$(printf 'symlink:%s' "$(readlink -- "$MG_DIR/$f")" | sha256sum | cut -c1-64)"
    else chk+=("$f"); chki+=("$i"); continue; fi
    [[ "$got" == "${MG_P_SHA[$i]}" ]] || { bad=$((bad + 1)); list+="  내용 다름: $f"$'\n'; }
  done
  if (( ${#chk[@]} )); then
    mapfile -t shas < <(cd "$MG_DIR" && printf '%s\0' "${chk[@]}" | xargs -0 sha256sum -- | sed 's/^\\//' | cut -c1-64)
    (( ${#shas[@]} == ${#chk[@]} )) || die "옮긴 파일의 해시를 계산하지 못했습니다."
    for i in "${!chk[@]}"; do
      [[ "${shas[$i]}" == "${MG_P_SHA[${chki[$i]}]}" ]] || { bad=$((bad + 1)); list+="  내용 다름: ${chk[$i]}"$'\n'; }
    done
  fi
  (( bad == 0 )) || die "옮긴 파일 대조 실패 ${bad}건:\n$list"
  info "대조: ${#MG_P_OP[@]}개 파일 손실 없음 (옮기기 전 해시와 일치)"
}

mg_write_v2() {
  local s f k rec t
  mg_new .harness/project.yaml   # v1 원본은 이미 archive/v1/project.yaml로 옮겼다
  cp "$TEMPLATE_DIR/.harness/project.yaml" "$MG_DIR/.harness/project.yaml"
  render_file "$MG_DIR/.harness/project.yaml"
  mg_pset providers available "[${MG_AVAIL// /, }]"
  mg_pset limits max_parallel_workers "$MG_PAR"
  mg_pset limits max_open_tasks "$MG_OPENMAX"
  mg_pset limits ac_timeout_seconds "$MG_TIMEOUT"
  mg_pset limits quota_low_pct "$MG_QLOW"
  [[ -z "$MG_DTIER" ]] || mg_pset models default_tier "'$MG_DTIER'"
  [[ -z "$MG_DEFFORT" ]] || mg_pset models default_effort "'$MG_DEFFORT'"
  for k in "${!MG_MODEL[@]}"; do mg_pset models "$k" "$(yaml_q "${MG_MODEL[$k]}")"; done
  for k in "${!MG_ARGS[@]}"; do mg_pset agents "$k" "$(yaml_q "${MG_ARGS[$k]}")"; done
  if [[ "$MG_LEVEL" != cross_provider ]]; then
    rec=".harness/decisions/review-level-$(( $(last_n "$MG_DIR/.harness/decisions" review-level- .md) + 1 )).md"
    mg_new "$rec"
    record_level "" "$MG_LEVEL" cross_provider "$MG_REASON" "사용자 (migrate --confirm-user-approval)" none
    [[ -f "$MG_DIR/$rec" ]] || die "검토 수준 결정 기록을 만들지 못했습니다: $rec"
  fi
  if [[ ! -e "$MG_DIR/.harness/remote.yaml" ]]; then
    mg_new .harness/remote.yaml; cp "$TEMPLATE_DIR/.harness/remote.yaml" "$MG_DIR/.harness/remote.yaml"
  fi
  for f in .harness/tasks/TEMPLATE.yaml .harness/intents/TEMPLATE.md .harness/BACKLOG.md .harness/SPEC.md .harness/MILESTONES.md .harness/references/inventory.md; do
    [[ ! -e "$MG_DIR/$f" ]] || continue
    mg_new "$f"; cp "$TEMPLATE_DIR/$f" "$MG_DIR/$f"; render_file "$MG_DIR/$f"
  done
  for s in "$TEMPLATE_DIR"/.agents/skills/*/; do
    s="$(basename "$s")"
    mg_new ".agents/skills/$s/SKILL.md"
    cp "$TEMPLATE_DIR/.agents/skills/$s/SKILL.md" "$MG_DIR/.agents/skills/$s/SKILL.md"
    render_file "$MG_DIR/.agents/skills/$s/SKILL.md"
    if [[ ! -e "$MG_DIR/.claude/skills/$s" && ! -L "$MG_DIR/.claude/skills/$s" ]]; then
      mg_new ".claude/skills/$s"; ln -s "../../.agents/skills/$s" "$MG_DIR/.claude/skills/$s"
    fi
  done
  mg_tree .harness/bin
  install_bin "$MG_DIR"
  t="$(mktemp "${TMPDIR:-/tmp}/harness-migrate.XXXXXX")"; TMP_FILES+=("$t")
  for f in "${MG_DOCS[@]}"; do
    case "$(mg_doc_kind "$f")" in
      rules) s="$(mg_agents_section "$t")"; mg_append_doc "$f" "$s" ;;
      note) s="$(mg_entry_note "$f")"; mg_append_doc "$f" "$s" ;;
    esac
  done
  s="$(mg_gitignore_lines)"
  if [[ -n "$s" && ! -L "$MG_DIR/.gitignore" ]]; then
    if [[ ! -e "$MG_DIR/.gitignore" ]]; then mg_new .gitignore; : >"$MG_DIR/.gitignore"; fi
    [[ ! -s "$MG_DIR/.gitignore" || -z "$(tail -c1 "$MG_DIR/.gitignore")" ]] || printf '\n' >>"$MG_DIR/.gitignore"
    printf '\n# Harness v2 (migrate): 런타임·작업 공간·마운트와 보관된 v1 원문 로그(evidence/raw)는 커밋하지 않는다.\n%s\n' "$s" >>"$MG_DIR/.gitignore"
  fi
  for s in "${!MG_BCOUNT[@]}"; do
    mg_new ".harness/archive/$s/SUMMARY.md"
    mg_bundle_summary "$s" >"$MG_DIR/.harness/archive/$s/SUMMARY.md"
  done
  if [[ ! -e "$MG_DIR/.harness/HISTORY.md" ]]; then
    mg_new .harness/HISTORY.md
    printf '# 완료 이력\n\n| 날짜 | Milestone | Task | 시도 합계 | 태그 |\n|---|---|---|---|---|\n' >"$MG_DIR/.harness/HISTORY.md"
  fi
  for s in $(printf '%s\n' "${!MG_BCOUNT[@]}" | sort); do
    printf '| %s | %s (v1에서 이전) | %s개 | - | %s |\n' "$(date +%F)" "$s" "${MG_BCOUNT[$s]}" "$MG_TAG" >>"$MG_DIR/.harness/HISTORY.md"
  done
}

mg_append_doc() {  # FILE TEXT — 이미 덧붙였으면 그대로, 파일이 없으면 v2 템플릿으로 만든다 (링크는 고치지 않는다)
  local f="$MG_DIR/$1"
  [[ ! -L "$f" ]] || return 0
  if [[ ! -e "$f" ]]; then
    [[ -f "$TEMPLATE_DIR/$1" ]] || return 0   # v2 템플릿에 없는 문서(HARNESS_START.md)는 만들지 않는다
    mg_new "$1"; cp "$TEMPLATE_DIR/$1" "$f"; render_file "$f"; return 0
  fi
  ! grep -qxF -- "$(mg_mark_for "$1")" "$f" || return 0
  [[ ! -s "$f" || -z "$(tail -c1 "$f")" ]] || printf '\n' >>"$f"
  printf '\n%s\n' "$2" >>"$f"
}

mg_prune_empty() {  # 옮기고 비어 버린 v1 폴더를 지운다 (되돌릴 때 다시 만든다)
  local d n round p
  local -a starts=() pr=(-path .harness/runtime -o -path .harness/worktrees -o -path .harness/remote-mount -o -path .harness/bin -o -path .harness/archive)
  [[ ! -d "$MG_DIR/.harness" ]] || starts+=(.harness)
  [[ ! -d "$MG_DIR/.agents" ]] || starts+=(.agents)
  for p in ${MG_PROTECT[@]+"${MG_PROTECT[@]}"}; do pr+=(-o -path "$p"); done
  for round in 1 2 3 4 5 6; do
    n=0
    while IFS= read -r -d '' d; do mg_j rmdir "$d"; rmdir -- "$MG_DIR/$d"; MG_RMDIRS+=("$d"); n=$((n + 1)); done \
      < <(cd "$MG_DIR" && find "${starts[@]}" -xdev -mindepth 1 \( "${pr[@]}" \) -prune -o -type d -empty -print0 2>/dev/null || true)
    (( n > 0 )) || break
  done
}

mg_selfcheck() {  # 새 bin으로 validate·status를 별도 프로세스에서 — 통과해야 commit한다
  local h="$MG_DIR/.harness/bin/harness.sh"
  hcap env HARNESS_MIGRATING=1 bash "$h" -C "$MG_DIR" validate   # 이전 중이라 남아 있는 자기 기록(journal)은 문제로 보지 않는다
  MG_VALIDATE="$OUT"
  (( RC == 0 )) || die "이전 직후 validate 실패:\n$(grep -E '^\[FAIL\]' <<<"$OUT" | head -n 20)"
  hcap bash "$h" -C "$MG_DIR" status
  (( RC == 0 )) && [[ "$OUT" != *'에서 실패 (exit'* ]] || die "이전 직후 status 실패:\n$(tail -n 5 <<<"$OUT")"
  info "이전 직후 검사: $(tail -n 1 <<<"$MG_VALIDATE") · status 정상"
}

mg_write_records() {
  local i op a b
  mg_new .harness/archive/v1/MANIFEST.txt
  {
    printf '# Harness v1 → v2 이전 목록 (harness %s migrate, %s)\n' "$HARNESS_VERSION" "$(now)"
    printf '# 시작 commit %s (태그 %s). 열: 처리, sha256(옮기기 전), 크기, Git, 원래 경로, 현재 경로\n' "$MG_START" "$MG_TAG"
    printf '# 시작 브랜치: %s\n' "$MG_ORIG"
    printf '# 처리: move=옮김(내용 동일) keep=그대로 convert=원래 경로는 v2 형식으로 바꾸고 원본 사본을 현재 경로에 둠 append=원래 내용 뒤에 v2 절만 덧붙임 rmdir=비어서 지운 폴더 new=새로 만든 Git 밖 파일\n'
    printf '# Git: t=추적, -=Git 밖(무시 목록·런타임). 이전 뒤에도 같다.\n'
    {
      for i in "${!MG_P_OP[@]}"; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${MG_P_OP[$i]}" "${MG_P_SHA[$i]}" "${MG_P_SIZE[$i]}" "${MG_P_GIT[$i]}" "${MG_P_SRC[$i]}" "${MG_P_DST[$i]}"
      done
      for i in ${MG_RMDIRS[@]+"${!MG_RMDIRS[@]}"}; do printf 'rmdir\t-\t0\t-\t%s\t-\n' "${MG_RMDIRS[$i]}"; done   # 비어서 지운 v1 폴더 (되돌릴 때 다시 만든다)
      # 이전이 새로 만들었지만 Git 밖에 남을 파일(사용자가 무시하는 .claude/의 Skill 링크 등) — 되돌릴 때 지운다
      while IFS="$MG_SEP" read -r op a b; do
        [[ "$op" == new ]] && mg_safe_rel "$a" || continue
        if [[ -e "$MG_DIR/$a" || -L "$MG_DIR/$a" ]] && git -C "$MG_DIR" check-ignore -q --no-index -- "$a"; then printf 'new\t-\t0\t-\t-\t%s\n' "$a"; fi
      done <"$MG_JOURNAL"
    } | LC_ALL=C sort -t $'\t' -k5,5
  } >"$MG_DIR/.harness/archive/v1/MANIFEST.txt"
  mg_new .harness/archive/v1/MIGRATION.md
  mg_report apply >"$MG_DIR/.harness/archive/v1/MIGRATION.md"
}

mg_commit() {
  local p i dst tree
  local -a paths=()
  local -A idx=()
  for p in .harness .agents .claude/skills "${MG_DOCS[@]}" .gitignore; do
    if [[ -e "$MG_DIR/$p" || -L "$MG_DIR/$p" || -n "$(git -C "$MG_DIR" ls-files -- "$p")" ]]; then paths+=("$p"); fi
  done
  for p in "${paths[@]}"; do
    if git -C "$MG_DIR" check-ignore -q --no-index -- "$p"; then
      # 사용자가 무시하는 경로(.claude/ 등): 이미 추적 중인 파일의 변경만 담는다 (--no-index: 추적 파일이 있어도 규칙으로 판단)
      if [[ -n "$(git -C "$MG_DIR" ls-files -- "$p")" ]]; then git -C "$MG_DIR" add -u -- "$p"; fi
    else
      git -C "$MG_DIR" add -A -- "$p"
    fi
  done
  # Git 추적 여부 보존: 추적하던 파일은 새 자리에서도 추적, Git 밖이던 파일은 계속 Git 밖
  while IFS= read -r -d '' p; do idx[$p]=1; done < <(git -C "$MG_DIR" ls-files -z -- .harness .agents "${MG_DOCS[@]}" .gitignore || true)
  for i in "${!MG_P_OP[@]}"; do
    if [[ "${MG_P_OP[$i]}" == move ]]; then dst="${MG_P_DST[$i]}"; else dst="${MG_P_SRC[$i]}"; fi
    if [[ "${MG_P_GIT[$i]}" == t ]]; then
      [[ -n "${idx[$dst]:-}" ]] || die "추적하던 파일이 이전 뒤 Git에서 빠집니다: ${MG_P_SRC[$i]} → $dst (.gitignore 확인)"
      [[ "${MG_P_OP[$i]}" != convert || -n "${idx[${MG_P_DST[$i]}]:-}" ]] || die "열린 Task 원본 사본이 Git에 들어가지 않습니다: ${MG_P_DST[$i]}"
    else
      [[ -z "${idx[$dst]:-}" ]] || die "Git 밖이던 파일이 이전 뒤 추적됩니다: ${MG_P_SRC[$i]} → $dst (.gitignore 확인)"
    fi
  done
  tree="$(git -C "$MG_DIR" write-tree)"   # 해시를 대조한 그대로 commit되는지 (hook이 내용을 고치면 무손실이 깨진다)
  mg_j index "$tree"
  hcap git -C "$MG_DIR" commit -q -m "harness: v1 → v2 이전 (migrate, harness $HARNESS_VERSION)" -m "$(mg_commit_body)"
  (( RC == 0 )) || die "commit 실패(hook 등): $(tail -n 3 <<<"$OUT")"
  mg_j commit "$(git -C "$MG_DIR" rev-parse HEAD)"   # 되돌릴 때 이 commit을 제목이 아니라 SHA로 알아본다
  [[ "$(git -C "$MG_DIR" rev-parse 'HEAD^{tree}')" == "$tree" ]] ||
    die "commit hook이 commit 내용을 바꿨습니다(포맷터 등) — 대조한 내용과 달라 되돌립니다. 그 hook을 확인한 뒤 다시 이전한다."
  [[ -z "$(git -C "$MG_DIR" status --porcelain -- "${paths[@]}")" ]] || die "commit 뒤에도 커밋되지 않은 변경이 남았습니다(hook이 파일을 고쳤을 수 있다)."
}

mg_commit_body() {
  local d s="" c=0 o=0 id
  for d in $(printf '%s\n' "${!MG_BCOUNT[@]}" | sort); do s+="archive/$d/ ${MG_BCOUNT[$d]}개 "; done
  for id in "${MG_IDS[@]}"; do case "${MG_ACT[$id]}" in complete) c=$((c + 1)) ;; draft) o=$((o + 1)) ;; esac; done
  printf -- '- 완료 Task 보관: %s(완료 인정 %s개 포함)\n' "${s:-없음 }" "$c"
  printf -- '- 열린 Task %s개 → draft (v2 계획 승인 필요)\n' "$o"
  printf -- '- 검토 수준: %s\n' "$(level_name "$MG_LEVEL")"
  printf -- '- 시작점: 태그 %s (%s)\n' "$MG_TAG" "$MG_START"
  printf -- '- 기록: .harness/archive/v1/MIGRATION.md · 목록: .harness/archive/v1/MANIFEST.txt'
}

mg_safe_rel() {  # 기록의 경로가 프로젝트 안 상대 경로인가 (잘린 줄·빈 값으로 넓게 지우지 않게)
  [[ -n "$1" && "$1" != /* && "$1" != . && "$1" != .. && "/$1/" != */../* && "/$1/" != */./* ]]
}

mg_tree_ok() {  # 통째로 지워도 되는, 이전이 만드는 폴더인가
  case "$1" in
    .harness/archive/v1|.harness/runtime/v1|.harness/bin) return 0 ;;
    .harness/archive/v1-*) [[ "$1" != */*/*/* && "${1#.harness/archive/v1-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ;;
    *) return 1 ;;
  esac
}

mg_git_retry() {  # git 명령 — 다른 프로그램(IDE 등)이 index.lock을 잠시 잡고 있으면 몇 번 다시 시도한다
  local i gd
  gd="$(git -C "$MG_DIR" rev-parse --absolute-git-dir 2>/dev/null)" || gd="$MG_DIR/.git"
  for i in 1 2 3 4 5 6; do
    git -C "$MG_DIR" "$@" && return 0
    [[ -e "$gd/index.lock" ]] || return 1
    nap 1
  done
  return 1
}

# REV → 시작 commit이거나 이전이 만든 commit인가 (그 뒤에 쌓인 사용자 작업이 없는가).
# commit 제목은 hook(prepare-commit-msg)이 바꿀 수 있어 보지 않는다. commit 직후 기록한 SHA, 그 기록 전에
# 끊겼다면 commit 전에 기록한 트리(시작 commit 바로 위이면서 대조한 그 내용 그대로)로 알아본다.
mg_is_mig_tip() {
  local t
  t="$(git -C "$MG_DIR" rev-parse -q --verify "$1^{commit}" 2>/dev/null)" || return 1
  if [[ "$t" == "$MG_START" || ( -n "${MG_COMMIT_SHA:-}" && "$t" == "$MG_COMMIT_SHA" ) ]]; then return 0; fi
  [[ -n "${MG_INDEX_TREE:-}" && "$(git -C "$MG_DIR" rev-parse -q --verify "$t^" 2>/dev/null)" == "$MG_START" &&
     "$(git -C "$MG_DIR" rev-parse "$t^{tree}")" == "$MG_INDEX_TREE" ]]
}

# 기록(journal)을 거꾸로 되짚는다. 이전 중 실패(EXIT trap)와 --rollback(끊긴 이전 복구)이 함께 쓴다.
# 여러 번 실행해도 같은 결과다: 이미 제자리로 돌아온 원본은 다시 건드리지 않는다.
mg_rollback() {
  local -
  local -a lines=() paths=()
  local i op a b fail=0 tag="" cur tip p
  local -A mvsrc=()
  set +e; trap - ERR   # 되돌리는 중에는 하나가 실패해도 끝까지 가고 결과를 보고한다
  mapfile -t lines <"$MG_JOURNAL"
  if (( ${#lines[@]} == 0 )); then   # 기록을 만든 직후 끊긴 경우: 아직 아무것도 바꾸지 않았다
    rm -f -- "$MG_JOURNAL"; printf '[harness] 빈 기록이라 되돌릴 것이 없습니다 (기록을 정리했다).\n' >&2; return 0
  fi
  IFS="$MG_SEP" read -r op a b <<<"${lines[0]}"
  if [[ "$op" != start ]] || ! git -C "$MG_DIR" rev-parse -q --verify "$a^{commit}" >/dev/null 2>&1 || [[ -z "$b" ]]; then
    printf '[harness] 복구 기록의 머리줄(시작 commit·브랜치)이 올바르지 않아 되돌리지 않습니다: %s\n' "$MG_JOURNAL" >&2; return 1
  fi
  MG_START="${MG_START:-$a}"; MG_ORIG="${MG_ORIG:-$b}"; MG_COMMIT_SHA=""; MG_INDEX_TREE=""
  for i in "${!lines[@]}"; do   # 이전 commit의 SHA(commit 직후)와 트리(commit 직전)
    IFS="$MG_SEP" read -r op a b <<<"${lines[$i]}"
    case "$op" in commit) MG_COMMIT_SHA="$a" ;; index) MG_INDEX_TREE="$a" ;; esac
  done
  # 0) 이전 브랜치 위에 사용자 작업이 쌓였으면(끊긴 기록을 모른 채 계속 쓴 경우) 아무것도 건드리지 않는다
  tip="$(git -C "$MG_DIR" rev-parse -q --verify "refs/heads/$MG_BRANCH" 2>/dev/null)"
  if [[ -n "$tip" ]] && ! mg_is_mig_tip "$tip"; then
    printf '[harness] 이전 브랜치(%s)에 이전 뒤의 commit이 있어 자동으로 되돌리지 않습니다 (git log %s..%s).\n  그 작업을 옮기거나 정리한 뒤 다시: harness.sh migrate %s --rollback\n' \
      "$MG_BRANCH" "$MG_START" "$MG_BRANCH" "$(mg_q "$MG_DIR")" >&2
    return 1
  fi
  cur="$(git -C "$MG_DIR" symbolic-ref --short -q HEAD)"
  if [[ "$cur" != "$MG_BRANCH" && ! ( "$cur" == "$MG_ORIG" && "$(git -C "$MG_DIR" rev-parse HEAD)" == "$MG_START" ) ]]; then
    printf '[harness] 지금 브랜치(%s)가 이전 브랜치(%s)도, 시작점의 원래 브랜치(%s)도 아니라 되돌리지 않습니다.\n  이전 브랜치로 돌아간 뒤 다시: harness.sh migrate %s --rollback\n' \
      "${cur:-없음}" "$MG_BRANCH" "$MG_ORIG" "$(mg_q "$MG_DIR")" >&2
    return 1
  fi
  for i in "${!lines[@]}"; do
    IFS="$MG_SEP" read -r op a b <<<"${lines[$i]}"
    [[ "$op" != mv ]] || mvsrc[$a]="$b"
  done
  # 1) 파일 — 옮긴 것을 모두 제자리로 꺼낸 다음에만 새로 만든 것을 지운다. 하나라도 못 꺼내면 아무것도 지우지 않는다.
  for (( i = ${#lines[@]} - 1; i >= 0; i-- )); do
    IFS="$MG_SEP" read -r op a b <<<"${lines[$i]}"
    case "$op" in
      mv)
        if ! mg_safe_rel "$a" || ! mg_safe_rel "$b"; then fail=1; printf '  형식이 잘못된 기록 줄: %s\n' "${lines[$i]//"$MG_SEP"/ | }" >&2; continue; fi
        if [[ -e "$MG_DIR/$b" || -L "$MG_DIR/$b" ]]; then
          if [[ -e "$MG_DIR/$a" || -L "$MG_DIR/$a" ]]; then fail=1; printf '  되돌릴 자리에 다른 파일이 있음: %s\n' "$a" >&2; continue; fi
          { mkdir -p -- "$(dirname -- "$MG_DIR/$a")" && mv -- "$MG_DIR/$b" "$MG_DIR/$a"; } ||
            { fail=1; printf '  되돌리지 못함: %s → %s\n' "$b" "$a" >&2; }
        elif [[ ! -e "$MG_DIR/$a" && ! -L "$MG_DIR/$a" ]]; then
          fail=1; printf '  찾지 못함: %s (원래 %s)\n' "$b" "$a" >&2
        fi ;;
      new)
        # 원본을 옮긴 자리에 새로 만든 파일(project.yaml 등)은 원본이 아직 보관 자리에 있을 때만 지운다 — 다시 실행해도 원본을 지우지 않는다
        if (( ! fail )) && mg_safe_rel "$a"; then
          if [[ -z "${mvsrc[$a]:-}" ]] || [[ -e "$MG_DIR/${mvsrc[$a]}" || -L "$MG_DIR/${mvsrc[$a]}" ]]; then rm -f -- "$MG_DIR/$a"; fi
        fi ;;
      dir) if (( ! fail )) && mg_safe_rel "$a"; then rmdir -- "$MG_DIR/$a" 2>/dev/null; fi ;;
      rmdir) if mg_safe_rel "$a"; then mkdir -p -- "$MG_DIR/$a"; fi ;;
      tree)
        if ! mg_tree_ok "$a"; then printf '  이전이 만드는 폴더가 아니라 지우지 않음: %s\n' "$a" >&2
        elif (( ! fail )); then rm -rf -- "${MG_DIR:?}/$a"; fi ;;
      tag) tag="$a" ;;
      start|branch|commit|index|"") ;;
      *) printf '  알 수 없는 기록 줄(건너뜀): %s\n' "${lines[$i]//"$MG_SEP"/ | }" >&2 ;;
    esac
  done
  if (( fail )); then
    printf '[harness] 일부 파일을 제자리로 되돌리지 못해, 새로 만든 파일도 지우지 않고 멈춥니다.\n  기록: %s\n  원인을 정리한 뒤: harness.sh migrate %s --rollback\n' "$MG_JOURNAL" "$(mg_q "$MG_DIR")" >&2
    return 1
  fi
  # 끊긴 실행이 남긴 임시 파일 (이전은 깨끗한 작업 트리에서만 시작하므로 이 이름의 파일은 이전이 만든 것이다)
  rm -f -- "$MG_DIR"/.harness/.harness-tmp.* "$MG_DIR"/.harness/tasks/.harness-tmp.* "$MG_DIR"/.harness/decisions/.harness-tmp.* 2>/dev/null
  # 2) Git — 이전이 손댄 경로만 시작 commit으로 되돌린다. 저장소의 다른 파일(진행 중인 수정)은 건드리지 않는다.
  for p in .harness .agents .claude/skills "${MG_DOCS[@]}" .gitignore; do
    if git -C "$MG_DIR" cat-file -e "$MG_START:$p" 2>/dev/null || [[ -n "$(git -C "$MG_DIR" ls-files -- "$p" 2>/dev/null)" ]]; then paths+=("$p"); fi
  done
  if (( ${#paths[@]} )) && ! mg_git_retry restore --source="$MG_START" --staged --worktree -- "${paths[@]}"; then fail=1
  elif [[ "$cur" != "$MG_ORIG" ]] && ! mg_git_retry checkout -q "$MG_ORIG"; then fail=1; fi
  # 이전 브랜치는 이전이 만든 것이다(사전 점검이 같은 이름을 막는다). 위 0)에서 사용자 작업이 없음을 확인했다.
  if (( ! fail )) && git -C "$MG_DIR" rev-parse -q --verify "refs/heads/$MG_BRANCH" >/dev/null; then
    mg_git_retry branch -q -D "$MG_BRANCH" || fail=1
  fi
  if (( ! fail )) && [[ -n "$tag" && "$(git -C "$MG_DIR" rev-parse -q --verify "refs/tags/$tag^{commit}")" == "$MG_START" ]]; then
    git -C "$MG_DIR" tag -d "$tag" >/dev/null || fail=1
  fi
  if (( fail )); then
    printf '[harness] Git 되돌리기가 끝나지 않았습니다(다른 git 작업이 잠금을 잡고 있을 수 있다). 기록과 태그 %s는 남겨 둡니다.\n' "$MG_TAG" >&2
    printf '  잠금이 풀린 뒤 다시: harness.sh migrate %s --rollback  (여러 번 실행해도 안전하다)\n' "$(mg_q "$MG_DIR")" >&2
    return 1
  fi
  rm -f -- "$MG_JOURNAL"
  printf '[harness] 원상복구 완료: 브랜치 %s, commit %s, 파일 위치 원래대로\n' "$MG_ORIG" "$MG_START" >&2
  return 0
}

mg_on_exit() {  # 이전 도중에 끝나면(실패·중단) 원상복구한다
  local rc="$1"
  set +e
  rm -f -- ${TMP_FILES[@]+"${TMP_FILES[@]}"}
  if [[ "${MG_DONE:-0}" != 1 && -n "${MG_JOURNAL:-}" && -f "$MG_JOURNAL" ]]; then
    printf '\n[harness] 이전이 끝나지 않았습니다 (exit %s) — 원상복구합니다.\n' "$rc" >&2
    mg_rollback
  fi
}

# 성공한 이전을 본 브랜치에 병합하기 전에 되돌린다: Git 밖으로 옮긴 파일(무시 목록·런타임)을 MANIFEST대로 제자리에
# → 원래 브랜치로 → 이전 브랜치·태그 삭제. 추적 파일은 checkout이 되돌린다.
mg_undo() {
  local cur man orig base n=0 op sha size gt src dst
  cur="$(git -C "$MG_DIR" symbolic-ref --short -q HEAD || true)"
  [[ "$cur" == "$MG_BRANCH" ]] || die "되돌리기는 이전 브랜치($MG_BRANCH)에서, 본 브랜치에 병합하기 전에 한다 (지금: ${cur:-브랜치 없음})."
  git -C "$MG_DIR" rev-parse -q --verify "refs/tags/$MG_TAG" >/dev/null || die "시작점 태그가 없습니다: $MG_TAG"
  # 이전 commit은 제목(hook이 바꿀 수 있다)이 아니라 내용으로 알아본다: 시작점 태그 바로 위 + 그 commit의 MANIFEST가 같은 시작 commit
  man="$(git -C "$MG_DIR" show HEAD:.harness/archive/v1/MANIFEST.txt 2>/dev/null)" ||
    die "HEAD에 이전 목록(.harness/archive/v1/MANIFEST.txt)이 없습니다 — 이전 commit에서만 되돌린다 (git log $MG_TAG..HEAD)."
  base="$(git -C "$MG_DIR" rev-parse "$MG_TAG^{commit}")"
  [[ "$(git -C "$MG_DIR" rev-parse -q --verify 'HEAD^')" == "$base" ]] && grep -q "^# 시작 commit $base " <<<"$man" ||
    die "HEAD가 시작점 태그 바로 위의 이전 commit이 아닙니다 (git log $MG_TAG..HEAD). 이전 뒤의 commit을 정리한 뒤 되돌린다."
  [[ -z "$(git -C "$MG_DIR" status --porcelain --untracked-files=no)" ]] || die "커밋되지 않은 변경이 있습니다 — 정리한 뒤 되돌린다."
  [[ -z "$(git -C "$MG_DIR" status --porcelain --untracked-files=all -- .harness .agents .claude/skills "${MG_DOCS[@]}" .gitignore | grep '^??')" ]] ||
    die "Harness 경로에 커밋되지 않은 새 파일이 있습니다 — 정리한 뒤 되돌린다."
  orig="$(sed -n 's/^# 시작 브랜치: //p' <<<"$man" | head -n 1)"
  [[ -n "$orig" ]] && git -C "$MG_DIR" rev-parse -q --verify "refs/heads/$orig" >/dev/null || die "원래 브랜치를 알 수 없습니다 (MANIFEST의 '시작 브랜치')."
  [[ "$(git -C "$MG_DIR" rev-parse "refs/heads/$orig")" == "$(git -C "$MG_DIR" rev-parse "$MG_TAG^{commit}")" ]] ||
    die "원래 브랜치($orig)가 시작점에서 움직였습니다 — 이미 병합했다면 git revert로 되돌린다."
  while IFS=$'\t' read -r op sha size gt src dst; do
    if [[ "$op" == rmdir ]] && mg_safe_rel "$src"; then mkdir -p -- "$MG_DIR/$src"; continue; fi
    if [[ "$op" == new ]] && mg_safe_rel "$dst"; then   # 이전이 만든 Git 밖 파일 (추적 파일은 checkout이 지운다)
      if [[ -z "$(git -C "$MG_DIR" ls-files -- "$dst")" ]]; then rm -f -- "$MG_DIR/$dst"; fi
      continue
    fi
    [[ "$op" == move && "$gt" == - ]] || continue
    if ! mg_safe_rel "$src" || ! mg_safe_rel "$dst"; then continue; fi
    if [[ ( -e "$MG_DIR/$dst" || -L "$MG_DIR/$dst" ) && ! -e "$MG_DIR/$src" && ! -L "$MG_DIR/$src" ]]; then
      mkdir -p -- "$(dirname -- "$MG_DIR/$src")"
      mv -- "$MG_DIR/$dst" "$MG_DIR/$src"
      n=$((n + 1))
    fi
  done < <(grep -v '^#' <<<"$man" || true)
  hcap git -C "$MG_DIR" checkout -q "$orig"
  (( RC == 0 )) || die "원래 브랜치로 돌아가지 못했습니다: $OUT"
  git -C "$MG_DIR" branch -q -D "$MG_BRANCH"
  git -C "$MG_DIR" tag -d "$MG_TAG" >/dev/null
  # 옮겨 낸 뒤 남은 빈 폴더 (Git 밖 파일이 있던 보관 폴더, runtime/v1)
  find "$MG_DIR/.harness/archive" "$MG_DIR/.harness/runtime/v1" -mindepth 0 -depth -type d -empty -delete 2>/dev/null || true
  info "되돌림 완료: 브랜치 $orig (commit $(git -C "$MG_DIR" rev-parse --short HEAD)), Git 밖 파일 ${n}개 제자리, 브랜치 $MG_BRANCH·태그 $MG_TAG 삭제"
}

mg_apply() {
  local i src dst t
  [[ -z "${HARNESS_AGENT:-}" ]] || die "migrate는 Harness가 띄운 Agent($HARNESS_AGENT) 안에서 실행할 수 없습니다."
  MG_START="$(git -C "$MG_DIR" rev-parse HEAD)"
  MG_ORIG="$(git -C "$MG_DIR" symbolic-ref --short HEAD)"
  MG_JOURNAL="$(git -C "$MG_DIR" rev-parse --absolute-git-dir)/harness-migrate.journal"
  [[ ! -e "$MG_JOURNAL" ]] || die "지난 이전이 끝나지 않은 기록이 있습니다: $MG_JOURNAL — harness.sh migrate $(mg_q "$MG_DIR") --rollback"
  info "이전 시작: $MG_DIR (시작 commit $MG_START, 파일 ${#MG_P_OP[@]}개)"
  mg_hash_plan
  MG_DONE=0
  printf '%s\n' "start$MG_SEP$MG_START$MG_SEP$MG_ORIG" >"$MG_JOURNAL"   # 머리줄과 함께 만든다: 끊겨도 --rollback이 시작 상태를 안다
  trap 'mg_on_exit "$?"' EXIT
  if ! git -C "$MG_DIR" rev-parse -q --verify "refs/tags/$MG_TAG" >/dev/null; then
    mg_j tag "$MG_TAG"; git -C "$MG_DIR" tag "$MG_TAG" "$MG_START"
  fi
  git -C "$MG_DIR" checkout -q -b "$MG_BRANCH"
  mg_j branch "$MG_ORIG"   # 만든 뒤에 적는다: 만들지 못한 브랜치를 되돌릴 때 지우려 하지 않게
  mg_tree .harness/archive/v1
  for t in "${!MG_BCOUNT[@]}"; do mg_tree ".harness/archive/$t"; done
  (( MG_RTN == 0 )) || mg_tree .harness/runtime/v1
  # 열린 Task: 원본 사본을 보관하고 제자리에서 v2 형식으로
  for i in "${!MG_P_OP[@]}"; do
    [[ "${MG_P_OP[$i]}" == convert ]] || continue
    src="${MG_P_SRC[$i]}"; dst="${MG_P_DST[$i]}"
    mg_new "$dst"; cp -p -- "$MG_DIR/$src" "$MG_DIR/$dst"
    t="$(mktemp "$MG_DIR/.harness/tasks/.harness-tmp.XXXXXX")"; TMP_FILES+=("$t")
    mg_convert "$MG_DIR/$src" "$t"
    chmod --reference="$MG_DIR/$src" -- "$t"
    mv -f -- "$t" "$MG_DIR/$src"
  done
  for i in "${!MG_P_OP[@]}"; do
    [[ "${MG_P_OP[$i]}" != move ]] || mg_mv "${MG_P_SRC[$i]}" "${MG_P_DST[$i]}"
  done
  mg_write_v2
  mg_prune_empty
  mg_verify_manifest
  mg_selfcheck
  mg_write_records
  mg_commit
  MG_DONE=1
  rm -f -- "$MG_JOURNAL"
  info "이전 완료: $(git -C "$MG_DIR" log --oneline -1) (브랜치 $MG_BRANCH)"
  printf '\n다음 (기록: .harness/archive/v1/MIGRATION.md)\n'
  printf '  1. 확인:          git -C %q show --stat HEAD   ·   %q status\n' "$MG_DIR" "$MG_DIR/.harness/bin/harness.sh"
  printf '  2. 본 브랜치 반영: git -C %q checkout %q && git -C %q merge --ff-only %s\n' "$MG_DIR" "$MG_ORIG" "$MG_DIR" "$MG_BRANCH"
  printf '  3. 병합 전 되돌리기: harness.sh migrate %s --undo --confirm-user-approval  (Git 밖으로 옮긴 파일까지 제자리로)\n' "$(mg_q "$MG_DIR")"
  printf '  4. 이전 후 할 일: MIGRATION.md의 "이전 후 할 일" (v1 증빙 재검증 verify --legacy, 열린 Task 계획 승인)\n'
}

cmd_migrate() {
  local dir="" apply=0 confirm=0 rollback=0 undo=0 sv
  MG_LEVEL=cross_provider MG_REASON="" MG_COMPLETE="" MG_CREASON="" MG_DONE=0 MG_JOURNAL="" MG_VALIDATE=""
  MG_BLOCK=(); MG_WARN=(); MG_TODO=(); MG_IDS=(); MG_SAME=(); MG_CFG=(); MG_PROTECT=(); MG_RMDIRS=(); MG_AGENTS_DOC=AGENTS.md
  declare -gA MG_ST=() MG_MS=() MG_TITLE=() MG_W=() MG_R=() MG_ACT=() MG_CLASS=() MG_BDIR=() MG_GRADE=() MG_GNOTE=() \
    MG_NOTE=() MG_KNOWN=() MG_BCOUNT=() MG_MODEL=() MG_ARGS=() MG_WANT=() MG_KEPTREF=() MG_BROKEN=() MG_MSET=() \
    MG_TRACKED=() MG_MOUNTED=()
  while (( $# )); do
    case "$1" in
      --apply) apply=1; shift ;;
      --rollback) rollback=1; shift ;;
      --undo) undo=1; shift ;;
      --confirm-user-approval) confirm=1; shift ;;
      --review-level) valid_level "${2:-}" || die "--review-level은 cross_provider | cross_model | same_model"; MG_LEVEL="$2"; shift 2 ;;
      --reason) [[ -n "${2:-}" ]] || die "--reason에 사유가 필요합니다."; MG_REASON="$2"; shift 2 ;;
      --complete) [[ -n "${2:-}" && "$2" != -* ]] || die "--complete에 Task ID 목록(쉼표 구분)이 필요합니다."; MG_COMPLETE="$2"; shift 2 ;;
      --complete-reason) [[ -n "${2:-}" ]] || die "--complete-reason에 사유가 필요합니다."; MG_CREASON="$2"; shift 2 ;;
      -*) die "알 수 없는 migrate 옵션: $1" ;;
      *) [[ -z "$dir" ]] || die "프로젝트 경로는 하나만 줍니다."; dir="$1"; shift ;;
    esac
  done
  [[ -n "$dir" ]] || die "사용법: migrate DIR [--apply --confirm-user-approval] [--review-level L --reason \"사유\"] [--complete T,T --complete-reason \"사유\"] | migrate DIR --rollback | migrate DIR --undo --confirm-user-approval"
  (( apply + rollback + undo <= 1 )) || die "--apply·--rollback·--undo는 하나만 쓴다."
  [[ -d "$TEMPLATE_DIR/.agents/skills" ]] || die "템플릿이 없습니다: $TEMPLATE_DIR (migrate는 저장소의 harness.sh로 실행한다)"
  [[ -z "$MG_CREASON" || -n "$MG_COMPLETE" ]] || die "--complete-reason은 --complete와 함께 쓴다."
  [[ -z "$MG_REASON" || "$MG_LEVEL" != cross_provider ]] || die "--reason은 --review-level(cross_model·same_model)과 함께 쓴다."
  ! has_secret <<<"$MG_REASON"$'\n'"$MG_CREASON" || die "사유에 Secret 의심 패턴이 있습니다."
  MG_DIR="$(realpath -m "$dir")"
  if (( rollback || undo )); then
    git -C "$MG_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "Git 저장소가 아닙니다: $MG_DIR"
    [[ -z "${HARNESS_AGENT:-}" ]] || die "migrate는 Harness가 띄운 Agent($HARNESS_AGENT) 안에서 실행할 수 없습니다."
    if (( rollback )); then   # 끊긴 이전(강제 종료 등)을 기록대로 되돌린다
      MG_JOURNAL="$(git -C "$MG_DIR" rev-parse --absolute-git-dir)/harness-migrate.journal"
      [[ -f "$MG_JOURNAL" ]] || die "끝나지 않은 이전 기록이 없습니다 (되돌릴 것이 없다): $MG_JOURNAL"
      MG_START="" MG_ORIG=""
      mg_rollback || exit 1
    else
      (( confirm )) || die "되돌리기는 사용자 결정입니다. 사용자가 승인했을 때만 --undo --confirm-user-approval로 실행한다."
      mg_undo
    fi
    return 0
  fi
  # 끊긴 이전(강제 종료 등)이 남긴 기록이 있으면 그 상태(project.yaml이 이미 v2일 수 있다)에서 다른 일을 하지 않는다.
  if git -C "$MG_DIR" rev-parse --git-dir >/dev/null 2>&1 &&
     [[ -e "$(git -C "$MG_DIR" rev-parse --absolute-git-dir)/harness-migrate.journal" ]]; then
    die "끝나지 않은 이전 기록이 있습니다 — 먼저 되돌린다: harness.sh migrate $(mg_q "$MG_DIR") --rollback"
  fi
  [[ -f "$MG_DIR/.harness/project.yaml" ]] || die "Harness 프로젝트가 아닙니다: $MG_DIR"
  sv="$(yget "$MG_DIR/.harness/project.yaml" schema_version)"
  [[ "$sv" != 2 ]] || die "이미 v2 프로젝트입니다: $MG_DIR (최신화는 harness.sh upgrade DIR)"
  [[ -d "$MG_DIR/.harness/policies" || -f "$MG_DIR/.harness/STATE.md" ]] ||
    die "v1 Harness 프로젝트로 보이지 않습니다 (.harness/policies·STATE.md 없음): $MG_DIR"
  ROOT="$MG_DIR"
  R_NAME="" R_GOAL="" R_PROFILE="" R_ORCH="" R_WORKER="" R_REVIEWER="" R_FALLBACK="" R_MODE="" R_CODE=. R_LEVEL=""
  mg_survey
  mg_plan
  mg_preflight
  mg_config_rows
  R_NAME="$MG_NAME" R_GOAL="$MG_GOAL" R_PROFILE="$MG_PROFILE" R_ORCH="$MG_ORCH" R_WORKER="$MG_WORKER" R_REVIEWER="$MG_REVIEWER"
  R_FALLBACK="$MG_FALLBACK" R_MODE="$MG_MODE" R_CODE=. R_LEVEL="$MG_LEVEL"
  if (( ! apply )); then
    mg_report dry-run
    (( ${#MG_BLOCK[@]} == 0 )) || exit 1
    return 0
  fi
  (( confirm )) || die "이전은 사용자 결정입니다. 사용자가 승인했을 때만 --apply --confirm-user-approval로 실행한다."
  if (( ${#MG_BLOCK[@]} )); then
    mg_report dry-run
    die "차단 조건이 있어 이전하지 않습니다 (위 '적용 조건')."
  fi
  mg_apply
}

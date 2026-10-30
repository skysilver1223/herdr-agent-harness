# herdr-harness: 재검증(verify) — 사용자 지시로 Task의 command AC 전부를 지금 코드(본 저장소, 원격 모드면 원격)에서
# 다시 실행하고 기록한다. 상태는 바꾸지 않는다. 진행 중 Task의 증빙은 run(제출·통합 게이트)이 남기므로 다루지 않는다.
#   verifications/T-verify-N.md   재검증 기록 (보관된 Task는 그 보관함의 verifications/)
# 결과: 통과 0, 실패 1, 재검증할 수 없음(진행 중·command AC 없음) 2, 오류 3. 여러 Task(--milestone·--legacy)는
# 실패나 오류가 하나라도 있으면 1. v1에서 이전된 Task는 --legacy로 증빙이 불완전한 것만 고른다.
# 빌드·원격 실행처럼 오래 걸리거나 부수효과가 있을 수 있어 자동으로 돌리지 않는다.
# harness.sh가 source한다. 단독 실행하지 않는다.

verify_task_file() {  # TASK → Task 파일 (진행 중이면 tasks/, 보관됐으면 archive/*/tasks/)
  local f
  f="$ROOT/.harness/tasks/$1.yaml"
  if [[ -f "$f" ]]; then printf '%s' "$f"; return 0; fi
  for f in "$ROOT"/.harness/archive/*/tasks/"$1".yaml; do
    if [[ -f "$f" ]]; then printf '%s' "$f"; return 0; fi
  done
  die "Task를 찾지 못했습니다: $1 (.harness/tasks/ 또는 .harness/archive/*/tasks/)"
}

# 같은 폴더를 함께 쓰는 모드(원격·worktree 꺼짐)에서 진행 중인 Task. 그 미완성 변경이 결과에 섞일 수 있다.
verify_busy() {
  local id out=""
  if worktree_enabled; then return 0; fi
  while IFS= read -r id; do
    case "$(yget "$ROOT/.harness/tasks/$id.yaml" status)" in
      active|submitted|reviewing|changes_requested|blocked|handover_required) out+="$id " ;;
    esac
  done < <(task_ids)
  printf '%s' "${out% }"
}

verify_skip() { printf '제외: %s\n' "$*" >&2; exit 2; }   # 재검증할 수 없음 (오류와 구분한다)

# 결과는 VERIFY_RESULT(PASS|FAIL)로 돌려준다. 조건문 안에서 부르면 안쪽 실패가 삼켜지므로 반환값을 쓰지 않는다.
verify_one() {  # TASK — 기록을 쓰고 commit한다
  local task="$1" tf st dir n rec i cmds=0 busy code sha
  tf="$(verify_task_file "$task")"
  st="$(yget "$tf" status)"
  if [[ "$tf" == "$ROOT/.harness/tasks/"* ]]; then
    case "$st" in
      awaiting_approval|completed) ;;
      *) verify_skip "진행 중 Task는 재검증하지 않습니다 ($task: $st 상태). 그 증빙은 run(제출·통합 게이트)이 남긴다. 재검증은 통합을 마친 Task(awaiting_approval·completed)와 보관된 Task만 한다." ;;
    esac
    dir="$ROOT/.harness/verifications"
  else
    dir="${tf%/tasks/*}/verifications"
  fi
  ac_load "$tf"
  for i in "${!AC_TYPE[@]}"; do [[ "${AC_TYPE[$i]}" != command ]] || formal_cmd "${AC_CMD[$i]}" || cmds=$((cmds + 1)); done
  (( cmds > 0 )) || verify_skip "$task에는 실행해 확인하는 command AC가 없습니다(manual-review·true 같은 형식적 명령만) — 재검증할 수 없습니다. Reviewer·사용자가 직접 확인한다."
  [[ -z "$AC_ERR" ]] || die "$task의 AC 형식 오류: $AC_ERR ($(rel "$tf"))"
  busy="$(verify_busy)"
  code="$(code_dir)"
  if remote_enabled; then
    # 원격에 닿지 못하면(키·네트워크) 모든 AC가 실패로 기록된다. 그런 거짓 실패 기록은 남기지 않는다.
    hcap bash "$HARNESS_BIN" -C "$ROOT" remote run true
    (( RC == 0 )) || die "원격에 연결하지 못해 재검증하지 않습니다(기록을 남기지 않음): $(tail -n 2 <<<"$OUT" | tr '\n' ' ')"
  fi
  if remote_enabled; then sha="원격 모드 — 코드 버전은 아래 명령 출력으로 확인"
  else sha="$(git -C "$code" rev-parse HEAD 2>/dev/null || echo -)"; fi
  n=$(( $(last_n "$dir" "$task-verify-" .md) + 1 ))
  rec="$dir/$task-verify-$n.md"
  write_atomic "$rec" <<EOF
# 재검증: $task #$n

- 대상: $(rel "$tf") (상태 ${st:-?} — 재검증은 상태를 바꾸지 않는다)
- 실행: 사용자 지시 (verify)
- 프로젝트 commit: $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo -)
- 코드 commit: $sha
- 시각: $(now)
EOF
  [[ -z "$busy" ]] || printf -- '- 주의: 진행 중 Task(%s)가 같은 작업 공간을 쓴다 — 미완성 변경이 결과에 섞일 수 있다\n' "$busy" >>"$rec"
  run_checks "$task" "$rec" "재검증" "$code"
  VERIFY_RESULT="$AC_RESULT"
  commit_harness "재검증 $task #$n: $VERIFY_RESULT"
  info "재검증 $task: $VERIFY_RESULT — 기록: $(rel "$rec")"
}

summary_grades() {  # SUMMARY.md → "Task<TAB>증빙 등급" (열은 머리줄 이름으로 찾는다)
  awk -F'|' '
    { gsub(/\\\|/, "\001") }   # 칸 안의 \| (제목 등)는 칸 구분이 아니다
    /^\| Task \|/ { for (i = 2; i < NF; i++) { h = $i; gsub(/^[ \t]+|[ \t]+$/, "", h); idx[h] = i } next }
    ("증빙 등급" in idx) && /^\| [^-]/ {
      id = $2; g = $(idx["증빙 등급"]); gsub(/^[ \t]+|[ \t]+$/, "", id); gsub(/^[ \t]+|[ \t]+$/, "", g); print id "\t" g
    }
  ' "$1"
}

verify_legacy_ids() {  # → "Task<TAB>제외 사유(대상이면 빈 값)" — v1에서 이전된 보관 Task
  local s d id g last
  for s in "$ROOT"/.harness/archive/v1-*/SUMMARY.md; do
    [[ -f "$s" ]] || continue
    d="${s%/SUMMARY.md}"
    while IFS=$'\t' read -r id g; do
      case "$g" in
        partial|fail|none) ;;
        full) printf '%s\tv1 증빙 완전\n' "$id"; continue ;;
        manual) printf '%s\tcommand AC 없음 — 재검증 불가 (사람 확인)\n' "$id"; continue ;;
        *) printf '%s\t증빙 등급을 알 수 없음 (%s)\n' "$id" "$g"; continue ;;
      esac
      last="$(last_n "$d/verifications" "$id-verify-" .md)"
      if (( last > 0 )) && [[ "$(rec_last "$d/verifications/$id-verify-$last.md" '재검증 요약')" == PASS* ]]; then
        printf '%s\t재검증 통과 기록 있음 (%s)\n' "$id" "$(rel "$d/verifications/$id-verify-$last.md")"
        continue
      fi
      printf '%s\t\n' "$id"
    done < <(summary_grades "$s")
  done
}

verify_milestone_ids() {  # MILESTONE → "Task<TAB>제외 사유" — 진행 중 Task와 보관된 Task 모두
  local id f st
  while IFS= read -r id; do
    st="$(yget "$ROOT/.harness/tasks/$id.yaml" status)"
    case "$st" in
      awaiting_approval|completed) printf '%s\t\n' "$id" ;;
      *) printf '%s\t%s — 아직 통합 전\n' "$id" "$st" ;;
    esac
  done < <(milestone_tasks "$1")
  for f in "$ROOT"/.harness/archive/*/tasks/*.yaml; do
    [[ -f "$f" ]] || continue
    [[ "$(yget "$f" milestone_id)" == "$1" ]] || continue
    id="${f##*/}"; printf '%s\t\n' "${id%.yaml}"
  done
}

cmd_verify() {
  local id why rc row pass=0 fail=0 skip=0 err=0
  local -a rows=()
  case "${1:-}" in
    --legacy) (( $# == 1 )) || die "사용법: verify --legacy" ;;
    --milestone) [[ $# -eq 2 && -n "$2" ]] || die "사용법: verify --milestone MILESTONE"; need_id "$2" ;;
    ""|-*) die "사용법: verify TASK | --milestone MILESTONE | --legacy  (AC 명령을 지금 코드에서 다시 실행해 기록, 상태는 바꾸지 않음)" ;;
    *)
      (( $# == 1 )) || die "사용법: verify TASK"
      need_id "$1"; require_human verify
      verify_one "$1"
      [[ "$VERIFY_RESULT" == PASS ]] || exit 1
      return 0 ;;
  esac
  require_human verify
  if [[ "$1" == --legacy ]]; then
    compgen -G "$ROOT/.harness/archive/v1-*/SUMMARY.md" >/dev/null ||
      die "v1에서 이전한 보관함(.harness/archive/v1-*/SUMMARY.md)이 없습니다."
    mapfile -t rows < <(verify_legacy_ids)
  else
    mapfile -t rows < <(verify_milestone_ids "$2")
  fi
  (( ${#rows[@]} > 0 )) || die "재검증할 Task가 없습니다."
  # Task마다 별도 프로세스로 실행한다: 한 Task의 거부(die)가 나머지를 멈추지 않는다.
  for row in "${rows[@]}"; do
    id="${row%%$'\t'*}"; why="${row#*$'\t'}"
    if [[ -n "$why" ]]; then info "제외: $id — $why"; skip=$((skip + 1)); continue; fi
    rc=0
    bash "$HARNESS_BIN" -C "$ROOT" verify "$id" </dev/null || rc=$?
    case "$rc" in 0) pass=$((pass + 1)) ;; 1) fail=$((fail + 1)) ;; 2) skip=$((skip + 1)) ;; *) err=$((err + 1)) ;; esac
  done
  info "재검증 요약: 통과 $pass · 실패 $fail · 제외 $skip$( ((err == 0)) || echo " · 오류 $err")"
  (( pass + fail + err > 0 )) || info "재검증한 Task가 없습니다 (모두 제외)."
  (( fail == 0 && err == 0 )) || exit 1
}

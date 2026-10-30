# herdr-harness: Context Packet — dispatch가 Agent에게 주는 단일 지시서.
# 프롬프트에는 이 파일 경로 한 줄만 보낸다(긴 본문을 TUI에 붙여 넣으면 줄바꿈·길이 문제로 유실된다).
# harness.sh가 source한다. 단독 실행하지 않는다.

spec_section() { awk -v n="$2" '$0 ~ "^## " n "\\." { p = 1; print; next } p && /^## / { exit } p' "$1"; }
last_section() { awk -v h="$2" 'index($0, h) == 1 { b = ""; on = 1 } on && /^## / && index($0, h) != 1 { on = 0 } on { b = b $0 "\n" } END { printf "%s", b }' "$1"; }

excerpt() {  # FILE [LINES] — 줄 수와 줄 길이를 함께 자른다
  local max="${2:-60}" total
  [[ -f "$1" ]] || return 0
  total="$(wc -l <"$1")"
  head -n "$max" "$1" | cut -c1-400
  (( total <= max )) || printf '… (%s줄 중 %s줄 — 전문: %s)\n' "$total" "$max" "$(rel "$1")"
  return 0
}

# 아직 해소되지 않은(그 뒤에 APPROVED Review가 없는) 최신 사용자 반려 사유.
rejection_note() {  # TASK ROLE
  local f e r s
  f="$(latest_rejection "$1")"
  [[ -n "$f" ]] || return 0
  e="$(rec_get "$f" '시각(epoch)')"
  for (( r = $(last_review "$1"); r > 0; r-- )); do
    s="$(rec_get "$(rev_record "$1" "$r")" '시작(epoch)')"
    (( ${s:-0} > ${e:-0} )) || break
    [[ "$(review_verdict "$(rev_file "$1" "$r")")" != APPROVED ]] || return 0
  done
  if [[ "$2" == worker ]]; then printf '\n## 사용자 반려 사유 — 가장 먼저 해결한다 (%s)\n\n' "$(rel "$f")"
  else printf '\n## 사용자 반려 사유 — 해소됐는지 반드시 확인한다 (%s)\n\n' "$(rel "$f")"; fi
  sed -n '/^## 사유/,$p' "$f" | sed 1d | head -n 40 | cut -c1-400
  return 0
}

write_packet() {  # TASK ROLE N ATTEMPT CWD BASE OUT EXTRA → Secret 의심이면 1
  local task="$1" role="$2" n="$3" att="$4" cwd="$5" base="$6" out="$7" extra="$8"
  local tf intent tmp s p r ids conflict="" att_rec verified
  tf="$(task_file "$task")"
  intent="$(yget "$tf" intent)"
  ac_load "$tf"
  ids="${AC_ID[*]:-}"
  tmp="$(mktemp "$(dirname "$out")/.harness-tmp.XXXXXX")"
  TMP_FILES+=("$tmp")
  r="$(last_review "$task")"
  conflict="$(rec_last "$(rev_record "$task" "$r")" '통합')"
  [[ "$conflict" == CONFLICT* || "$conflict" == FAIL* ]] || conflict=""
  {
    printf '# Context Packet — %s / %s #%s\n\n' "$task" "$role" "$n"
    printf 'Harness가 dispatch로 보낸 단일 지시서다. 이 Task만 수행하고 아래 경로를 그대로 쓴다.\n\n'
    printf -- '- 프로젝트 루트: %s\n- 작업 디렉터리: %s\n' "$ROOT" "$cwd"
    if [[ "$role" == worker ]]; then
      printf -- '- 기준 commit: %s\n' "$base"
      printf -- '- 따를 Skill: harness-work (%s/.agents/skills/harness-work/SKILL.md)\n' "$ROOT"
      printf -- '- 작성할 파일: %s\n' "$(att_report "$task" "$n")"
      printf -- '- Harness 증빙 기록(읽기 전용): %s\n' "$(att_record "$task" "$n")"
    else
      att_rec="$(att_record "$task" "$att")"
      verified="$(rec_last "$att_rec" '검증 commit' | cut -d' ' -f1)"
      printf -- '- 따를 Skill: harness-review (%s/.agents/skills/harness-review/SKILL.md)\n' "$ROOT"
      printf -- '- 작성할 파일: %s\n' "$(rev_file "$task" "$n")"
      printf -- '- 검토 대상 Attempt: %s\n' "$att"
      printf -- '- Worker 보고서: %s\n' "$(att_report "$task" "$att")"
      printf -- '- Harness 증빙 기록: %s\n' "$att_rec"
      printf -- '- 변경 확인: git -C %s diff %s %s\n' "$cwd" "$(rec_get "$att_rec" '기준 commit')" "${verified:-}"
    fi
    printf -- '- 다뤄야 할 AC: %s\n' "${ids:-(없음)}"
    [[ -z "$intent" ]] || printf -- '- Intent (Not·Invariants·Open Questions 정본): %s/%s\n' "$ROOT" "$intent"
    ! remote_enabled || printf -- '- 원격 모드: 빌드·테스트·VCS는 %s remote run|vcs로 원격에서 실행한다\n' "$ROOT/.harness/bin/harness.sh"
    printf '\n## SPEC 발췌\n\n'
    if [[ -f "$ROOT/.harness/SPEC.md" ]]; then
      for s in 1 3 4 5 6; do spec_section "$ROOT/.harness/SPEC.md" "$s"; printf '\n'; done
    fi
    printf '## Task Contract (%s)\n\n```yaml\n' "$(rel "$tf")"
    cat "$tf"
    printf '\n```\n'
    # 직전 라운드의 증빙·판정만 넣는다. 없으면 재시도가 같은 실수를 반복한다.
    if [[ "$role" == worker ]]; then
      for (( p = n - 1; p > 0; p-- )); do
        grep -q '^## AC 검증' "$(att_record "$task" "$p")" 2>/dev/null || continue
        printf '\n## 직전 attempt %s의 Harness AC 증빙\n\n' "$p"
        last_section "$(att_record "$task" "$p")" '## AC 검증' | head -n 40 | cut -c1-400
        break
      done
      if [[ -n "$conflict" ]]; then
        printf '\n## 통합 실패 — 먼저 해결한다\n\n%s\n작업 디렉터리에서 본 브랜치를 merge해 충돌을 해결한다. commit은 하지 않는다(제출 때 Harness가 한다).\n' "$conflict"
      fi
    else
      r=$((n - 1))
    fi
    if (( r > 0 )) && [[ -f "$(rev_file "$task" "$r")" ]]; then
      printf '\n## 최신 Review %s (판정: %s) — 지적이 해소됐는지부터 본다\n\n' "$r" "$(review_verdict "$(rev_file "$task" "$r")")"
      excerpt "$(rev_file "$task" "$r")" 80
    fi
    rejection_note "$task" "$role"
    if [[ -n "$extra" ]]; then printf '\n## 이 Task 추가 지시\n\n'; cat "$extra"; printf '\n'; fi
    printf '\n## 다음 한 단계\n\n'
    if [[ "$role" == worker ]]; then
      printf 'harness-work 절차대로 이 Task만 수행한다. write_scope 밖은 수정하지 않는다. 모든 `type: command` AC를 직접 실행하고, 위 "작성할 파일"에 보고서를 쓴다(AC ID 전부 포함). 상태 전이·commit·완료 선언은 하지 않는다. 마지막 응답: `결과: SUCCESS, submitted 제안` 또는 `결과: BLOCKED, 사유: …`\n'
    else
      printf 'harness-review 절차대로 읽기 전용으로 검토한다. Harness 증빙 기록·Worker 보고서·위 "변경 확인" diff를 대조하고 필요하면 AC 명령을 직접 재실행한다. 위 "작성할 파일"에 Review를 쓴다 — 첫 줄 `판정: APPROVED` 또는 `판정: CHANGES_REQUESTED`, 다음 줄 `대상 Attempt: %s`, AC ID 전부 포함. 소스·상태는 수정하지 않는다. 마지막 응답: `결과: SUCCESS, 판정: …`\n' "$att"
    fi
  } >"$tmp"
  if has_secret "$tmp"; then rm -f -- "$tmp"; return 1; fi
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$out"
}

#!/usr/bin/env bash
# Context Packet 축약 전후 실측 (docs/context-packet-measurement-2026-10.md의 근거).
#
# 사용법: docs/tools/measure-context-packet.sh [OLD_REF] [OUT_DIR]
#   OLD_REF  축약 전 lib/50-runtime.sh를 꺼낼 Git ref (기본 c0769bf — 축약 직전 commit)
#   OUT_DIR  fixture·Packet을 만들 빈 디렉터리 (기본: mktemp -d)
# 같은 fixture(대표 SPEC·Task·직전 라운드)에 두 구현을 돌려 bytes·줄 수를 비교한다.
# Agent·Provider를 호출하지 않는다.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
old_ref="${1:-c0769bf}"
out="${2:-$(mktemp -d "${TMPDIR:-/tmp}/packet-measure.XXXXXX")}"
mkdir -p "$out"
old_runtime="$out/old-50-runtime.sh"
git -C "$repo" show "$old_ref:lib/50-runtime.sh" >"$old_runtime"
rm -rf "$out/project"
proj="$out/project"
bash "$repo/harness.sh" init "$proj" --name measure --goal '부동산 탭 UI 감사 결과를 정규화된 보고서로 만든다' --preset agy-primary >/dev/null
git -C "$proj" -c user.name=m -c user.email=m@x commit -qm base >/dev/null 2>&1 || true

# 대표 SPEC — 각 절이 실제 프로젝트처럼 몇 줄씩 있다.
python3 - "$proj/.harness/SPEC.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = s.replace("- [ ] 기존 코드 또는 저장소\n", "- [x] 기존 코드: ui-audit 저장소의 src/realestate/ (React), 감사 스크립트 scripts/audit/\n- [x] 2026-08 수동 감사 결과 엑셀 3종\n")
s = s.replace("- 언어/프레임워크: TBD\n- 실행 환경: TBD\n- 변경 금지 영역: TBD\n",
  "- 언어/프레임워크: TypeScript 5, React 18, Playwright\n- 실행 환경: Node 22, Ubuntu 24.04, 사내 스테이징\n- 변경 금지 영역: legacy/ 디렉터리, 운영 DB 스키마, 결제 모듈\n- 외부 쓰기: 스테이징 외 배포 금지\n")
s = s.replace("- [ ] Interview 후 작성\n", "".join(f"- [ ] R-{i:02d}: 탭 {i}의 표·필터·정렬이 디자인 가이드와 일치하는지 감사하고 차이를 보고서에 기록한다\n" for i in range(1, 13)))
s = s.replace("- [ ] Criterion마다 검증 방법 연결\n", "".join(f"- [ ] AC-{i:02d}: R-{i:02d}의 모든 차이가 화면 경로·재현 절차·기대값과 함께 보고서에 있다 (검증: scripts/audit/check.sh {i})\n" for i in range(1, 13)))
s = s.replace("## 6. 제외 범위\n\n- TBD\n", "## 6. 제외 범위\n\n- 결제·청약 탭\n- 모바일 앱\n- 성능 측정\n")
open(p, 'w', encoding='utf-8').write(s)
PY

mktask() {
  sed -e "s/^task_id: .*/task_id: $1/" -e "s/^status: .*/status: active/" \
      -e "s/^title: .*/title: 부동산 탭 감사/" -e "s/^objective: .*/objective: 부동산 탭 표·필터의 디자인 가이드 차이를 재현 가능한 보고서로 남긴다/" \
      -e "s|^intent: .*|intent: .harness/intents/$1-intent.md|" \
      -e "s|^write_scope: .*|write_scope: [docs/audit/realestate.md, scripts/audit/realestate/]|" \
      -e "s|^target_files: .*|target_files: [docs/audit/realestate.md]|" \
      "$proj/.harness/tasks/TEMPLATE.yaml" >"$proj/.harness/tasks/$1.yaml"
}
mkdir -p "$proj/.harness/runtime"
mktask task-normal
mktask task-longac
python3 - "$proj/.harness/tasks/task-longac.yaml" <<'PY'
import sys, re
p = sys.argv[1]
t = open(p, encoding='utf-8').read()
items = []
for i in range(1, 7):
    items.append(f"""  - criterion_id: AC-{i:03d}
    statement: |
      부동산 탭 {i}번 표에서 금액 단위(만원·억원)가 원 단위로 정규화되고, 음수·빈 값·하이픈('-')은 각각 오류·결측·0으로
      구분해 기록되어야 한다. 정규화 전후 행 수가 같아야 하며 중복 행을 만들지 않는다. 필터 조합(지역×유형×기간)마다
      정렬 기준이 디자인 가이드 4.{i}절과 일치해야 하고, 차이는 화면 경로·재현 절차·기대값과 함께 보고서에 남긴다.
    verified_by:
      type: command
      command: 'bash scripts/audit/check.sh {i}'""")
t = re.sub(r'(?ms)^acceptance_criteria:.*?(?=^[^\s#])', "acceptance_criteria:\n" + "\n".join(items) + "\n", t)
open(p, 'w', encoding='utf-8').write(t)
PY

retry_fixture() {
  local task="$1"
  mkdir -p "$proj/.harness/evidence" "$proj/.harness/reviews" "$proj/.harness/attempts"
  printf -- '# Attempt 1\n- Role: worker\n' >"$proj/.harness/attempts/$task-attempt-1.md"
  {
    printf "task: '%s'\nrole: 'worker'\nattempt: 1\nresult:\n  summary: 'dispatch 결과 settled (Provider agy, 모델 agy-x, 출처 역할 기본값, 속도 medium, 승인 모드 bypass). 원문은 raw 참조.'\nchanges:\n" "$task"
    printf "  - ' M docs/audit/realestate.md'\n  - '?? scripts/audit/realestate/check_units.py'\n"
    printf "checks:\n  # acceptance_criteria 실행 결과는 transition submitted 시점에 Harness가\n  # 직접 실행해 %s-attempt-1-checks.yaml 로 기록한다.\nnotes:\n  - '관측 횟수: 2'\nstatus: 'settled'\nraw: '.harness/evidence/raw/%s-worker-attempt-1.md'\n" "$task" "$task"
  } >"$proj/.harness/evidence/$task-worker-attempt-1.yaml"
  {
    printf "task: '%s'\nattempt: 1\nran_at: '2026-10-06T00:00:00Z'\nrunner: 'local'\nchecks:\n" "$task"
    for i in 1 2 3 4 5 6; do
      if [[ $i -eq 3 ]]; then r=fail; e=1; tail_="AssertionError: 억원 단위 미변환 (row 17)"; else r=pass; e=0; tail_="ok"; fi
      printf "  - criterion_id: 'AC-%03d'\n    command: 'bash scripts/audit/check.sh %s'\n    exit_code: %s\n    result: '%s'\n    output_tail: '%s'\n" "$i" "$i" "$e" "$r" "$tail_"
    done
    printf "summary:\n  total: 6\n  passed: 5\n  failed: 1\n  manual: 0\n"
  } >"$proj/.harness/evidence/$task-attempt-1-checks.yaml"
  {
    printf '# Review: %s / Attempt 1\n\n- Reviewer Provider: codex\n- Primary Worker Provider: agy\n\n판정: CHANGES_REQUESTED\n\n## 지적\n\n' "$task"
    printf -- '- [필수] AC-003: 하이픈 값을 0이 아니라 결측으로 처리함 — scripts/audit/realestate/check_units.py:42\n'
    printf -- '- [필수] 보고서 3절에 재현 절차가 빠진 항목 2건\n- [권고] 표 제목 표기 통일\n\n## focus\n\n'
    for f in requirement_coverage correctness regression_risk security maintainability evidence scope tests; do
      printf -- '- %s: 판정 PASS — 근거 한 줄\n' "$f"
    done
  } >"$proj/.harness/reviews/$task-review-1.md"
}

run_packet() {
  # $1=runtime lib file, $2=task, $3=role, $4=output
  bash -c '
    set -Eeuo pipefail
    SCRIPT_NAME=herdr-harness SELF_PATH="$1/harness.sh"
    HARNESS_LIB_DIR="$1/lib" HARNESS_TEMPLATE_DIR="$1/templates"
    for lib in "$1"/lib/*.sh; do
      [[ "$(basename "$lib")" == 50-runtime.sh ]] && lib="$2"
      source "$lib"
    done
    _runtime_context_packet "$3" "$4" "$5" "$3/.harness/tasks/$4.yaml" "$6"
  ' _ "$repo" "$1" "$proj" "$2" "$3" "$4"
}

printf '| 케이스 | 축약 전 bytes | 축약 후 bytes | 감소 | 축약 전 줄 | 축약 후 줄 |\n|---|---:|---:|---:|---:|---:|\n'
measure() {
  local label="$1" task="$2" role="$3" before after b a bl al
  before="$out/$label-before.md" after="$out/$label-after.md"
  run_packet "$old_runtime" "$task" "$role" "$before"
  run_packet "$repo/lib/50-runtime.sh" "$task" "$role" "$after"
  b=$(wc -c <"$before"); a=$(wc -c <"$after"); bl=$(wc -l <"$before"); al=$(wc -l <"$after")
  python3 -c 'import sys; [open(p, encoding="utf-8", errors="strict").read() for p in sys.argv[1:]]' "$before" "$after"
  printf '| %s | %s | %s | %s%% | %s | %s |\n' "$label" "$b" "$a" "$(( (b - a) * 100 / b ))" "$bl" "$al"
}
measure "최초 시도 (worker)" task-normal worker
measure "최초 시도 (reviewer)" task-normal reviewer
measure "긴 한글 AC 6개 (worker)" task-longac worker
retry_fixture task-normal
measure "재시도: 직전 CHANGES_REQUESTED + AC 1건 실패 (worker)" task-normal worker
retry_fixture task-longac
measure "재시도 + 긴 한글 AC (worker)" task-longac worker

# Context Packet 축약 실측 (2026-10)

`dispatch`가 Worker·Reviewer에게 보내는 Context Packet(`.harness/runtime/TASK-context-ROLE.md`)을
줄이기 전후를 같은 fixture로 비교한 기록이다. 목표는 **필수 정보 무손실**과 대표 Task에서의
크기 감소다. 고정 글자 수 제한이나 앞부분 자르기는 쓰지 않았다.

재현: `docs/tools/measure-context-packet.sh c0769bf` (c0769bf = 축약 직전 commit). Agent·Provider를
호출하지 않는다.

## Fixture

- `init --preset agy-primary`로 만든 프로젝트, SPEC 각 절을 실제 규모로 채움
  (§3 제약 4줄, §4 요구사항 12개, §5 프로젝트 AC 12개, §6 제외 범위 3개)
- `task-normal`: 템플릿 기본 AC 2개 + `write_scope` 2개
- `task-longac`: 여러 줄 한글 AC 6개(블록 스칼라)
- 재시도: Worker Evidence 정본, AC 6개 중 1개 실패한 checks, `CHANGES_REQUESTED` Review(지적 3개 + focus 8줄)

## 결과

| 케이스 | 축약 전 bytes | 축약 후 bytes | 감소 | 축약 전 줄 | 축약 후 줄 |
|---|---:|---:|---:|---:|---:|
| 최초 시도 (worker) | 6439 | 4370 | 32% | 110 | 74 |
| 최초 시도 (reviewer) | 6444 | 4076 | 36% | 110 | 73 |
| 긴 한글 AC 6개 (worker) | 9677 | 7608 | 21% | 148 | 112 |
| 재시도: 직전 CHANGES_REQUESTED + AC 1건 실패 (worker) | 9021 | 6115 | 32% | 207 | 127 |
| 재시도 + 긴 한글 AC (worker) | 12259 | 9353 | 23% | 245 | 165 |

bytes에는 절대 경로가 포함되므로 fixture 위치에 따라 수십 bytes 차이가 난다. 모든 Packet은
유효한 UTF-8이다(스크립트가 strict 디코딩으로 확인).

토큰 수는 Provider 토크나이저마다 달라 측정하지 않았다. 한글 비중이 높은 Packet은
bytes 대비 토큰이 영문보다 많으므로, bytes 감소율을 토큰 감소의 근사로 본다.

## 무엇을 뺐고 무엇을 남겼나

| 구분 | 축약 전 | 축약 후 |
|---|---|---|
| SPEC | §1·§3·§4·§5·§6 원문 | §1 목표·§3 제약·§6 제외 범위 원문. §4·§5는 정본 절대 경로 + "Task 목적·AC가 모호하거나 SPEC과 어긋나 보일 때만 읽는다" |
| Task Contract | YAML 전문(템플릿 주석 포함) | 주석·빈 줄과 Harness가 이미 적용했거나 변하는 키(`schema_version`, `status`, `fallback_chain`, `*_model`/`*_tier`/`*_effort`)만 제거. 목적·경로·`write_scope`·`inputs`·`acceptance_criteria`는 원문 그대로. 블록 스칼라(`\|`, `>`) 본문은 빈 줄·`#` 줄까지 보존 |
| 역할·정책 | 마지막 한 문장 | 짧은 실행 규칙 + 역할·Skill·AGENTS.md 절대 경로(열람 조건 명시). 안전 Gate(위험 명령·배포·외부 쓰기·Provider 교체·completed)는 문장으로 유지 |
| 산출물 경로 | 없음(Worker가 Attempt 번호를 추측) | Attempt/Review 기록 **절대 경로**, Intent 절대 경로 |
| 직전 Evidence | YAML 전문(checks 안내 주석·관측 횟수 포함) | 결과·요약·변경 파일·원문 경로 |
| 직전 AC 결과 | checks YAML 전문 | 요약 한 줄 + **실패한 기준만** |
| 직전 Review | 판정 + 본문 80줄 | 판정 + 출처는 항상, 본문은 `APPROVED`가 아닐 때(미해결 지적이 있을 때)만 |
| 최초 시도 | 직전 라운드 없음 | 동일(없음) |

무손실 검사는 자체 테스트 `PASS: Context Packet 축약 (...)`가 고정한다: 긴 한글 AC의 모든 줄,
`write_scope`, SPEC 제약·제외 범위, 산출물 절대 경로, 안전 Gate 문장, 미해결 Review 지적,
실패 AC의 출력 꼬리가 Packet에 있어야 하고, 통과한 AC 결과·APPROVED 본문·템플릿 주석은
없어야 한다.

## 측정하지 못한 것

- **Provider가 추가로 읽는 파일 수와 재시도 횟수.** 이 환경에서는 실제 Provider를 기동하지
  않았다. 축약으로 정본 경로 열람이 늘어 실제 비용이 상쇄되는지는 운영에서 봐야 한다.
  이를 위해 `dispatch`가 Attempt 머리말에 `- Context Packet: 경로 (N bytes, M줄)`을 남기고,
  `--print-only`도 같은 크기를 출력한다. 재시도 횟수는 기존처럼 Attempt 번호와 Evidence의
  `Prompt 재전송` 항목으로 확인한다.

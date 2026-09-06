# Intents

이 디렉터리는 Task 단위 사전 의도(Intent) 문서를 보존한다. Anthropic의
AI-Native SDLC 개념에서 "코드를 쓰기 전에 Why/What/Not/Constraints를
정의"하는 관행을 이 하네스의 Task 레벨에 도입한 것이다.

## 역할

`SPEC.md`가 프로젝트 레벨의 Why/What/Not/Constraints라면, `intents/`는
**Task 레벨**에서 같은 역할을 한다. Task YAML의 `objective` 문단·인라인
주석·`acceptance_criteria` 문장에 착수 게이트와 제외 범위 판단을 섞어 두면
Worker와 Reviewer가 매번 산문을 재해석해야 한다. Intent 문서는 이를
필드별로 분리해 바로 대조할 수 있게 한다.

## 명명 규칙

```
.harness/intents/task-<task_id>-intent.md
```

- Task 1개당 Intent 1개. `attempts/`·`reviews/`와 달리 버전 번호(-N)를
  붙이지 않는다 — 착수 전 합의된 단일 계약이며, 개정은 git 히스토리로
  추적한다.
- 범위가 실제로 바뀌면(Task 재정의 수준) 이 파일을 갱신하고 `STATE.md`에
  개정 사실을 남긴다.

## 필수 필드

`TEMPLATE.md` 참고: Why · What · Not · Constraints · Invariants ·
Open Questions / Decision Gates · Verification Intent.

핵심은 뒤 두 필드다:
- **Open Questions / Decision Gates**: 착수를 막는 미결정 사항. 해소되면
  `.harness/decisions/`의 결정 기록으로 연결한다. 이 목록이 이 Task의
  착수 게이트 정본이며, Task YAML의 `acceptance_criteria`에는 착수 게이트를
  다시 적지 않는다.
- **Verification Intent**: acceptance_criteria가 왜 충분한지에 대한 근거.
  Reviewer가 실제 AC 목록과 이 의도가 어긋났는지 대조하는 기준이 된다.

## 연결 규칙

- Task YAML에 `intent: .harness/intents/task-<id>-intent.md` 필드로 연결한다.
- Task 상태를 `draft` → `ready`로 전환하려면 Intent의 Open Questions가 모두
  해소되어 있어야 한다.
- `harness-work`는 착수 전 Intent의 Not/Constraints/Invariants를 정독하고
  Task YAML과 상충하면 중단한다.
- `harness-review`는 `review-policy.yaml`의 `intent_alignment` 항목으로
  Not 위반 여부를 검수하며, 위반이 1건이라도 있으면 다른 항목과 무관하게
  즉시 `CHANGES_REQUESTED`를 판정한다.

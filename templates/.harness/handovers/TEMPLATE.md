# Handover: {{TASK_ID}}-handover-{{HANDOVER_NUMBER}}

## 메타데이터
- Task ID: {{TASK_ID}}
- Handover 번호: {{HANDOVER_NUMBER}}
- 인계 일시: {{TIMESTAMP}}
- 원작업자 (Source): {{SOURCE_PROVIDER}}
- 수신자 (Target): {{TARGET_PROVIDER}}
- 인계 사유: {{HANDOVER_REASON}}
  *(선택: quota_exhausted | blocker | repeated_failure | process_crash | user_directed)*

## 1. 완료된 작업 (Completed Work)
- 정상적으로 구현 및 확인된 내용:
- 생성/수정 완료된 파일:

## 2. 미완료 작업 및 작업 트리 상태 (Pending Work & Git State)
- 작업 중단 시점의 미해결 항목:
- 변경된 파일 현황 (`git status --short`):
```text
{{GIT_STATUS_OUTPUT}}
```
- Diff 통계 (`git diff --stat`):
```text
{{GIT_DIFF_STAT_OUTPUT}}
```

## 3. 마지막 검증 결과 및 실패 로그 (Last Verification & Error Logs)
- 마지막 실행 명령: `{{LAST_COMMAND}}`
- 종료 코드: {{EXIT_CODE}}
- 실패 원인 분석 및 핵심 로그 발췌:
```text
{{ERROR_LOG_EXCERPT}}
```

## 4. 직면한 차단 요인 및 미해결 의문 (Blockers & Open Questions)
- 의사결정 또는 외부 입력이 필요한 사항:
- 확인된 제약사항:

## 5. 다음 담당자를 위한 즉각적 행동 지침 (Next Single Action)
*(다음 담당 에이전트가 인계받아 즉시 실행해야 할 단 하나의 명확한 작업)*
> **다음 단계**: {{NEXT_SINGLE_ACTION}}

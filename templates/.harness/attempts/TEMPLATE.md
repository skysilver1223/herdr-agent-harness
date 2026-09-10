# Attempt: {{TASK_ID}}-attempt-{{ATTEMPT_NUMBER}}

## 메타데이터
- Task ID: {{TASK_ID}}
- Attempt 번호: {{ATTEMPT_NUMBER}}
- 작업 시각: {{TIMESTAMP}}
- Worker Provider: {{WORKER_PROVIDER}}
- Agent Name / Pane ID: {{AGENT_IDENTIFIER}}
- 기준 Commit: {{BASE_COMMIT}}

## 1. 작업 개요 (Summary of Changes)
- 구현/수정 목적:
- 주요 변경 내용 요약:

## 2. 수정한 파일 목록 (Modified Files in write_scope)
- [ ] 경로: 
  - 변경 사유:

## 3. Git 형상 상태
### git status --short
```text
{{GIT_STATUS_OUTPUT}}
```

### git diff --stat
```text
{{GIT_DIFF_STAT_OUTPUT}}
```

## 4. 자체 검증 결과 (Self Verification)
| Criterion ID | 검증 명령어 | 종료 코드 | 결과 (PASS/FAIL) | 증적 파일 링크 |
|---|---|---|---|---|
| AC-001 | `pytest tests/test_feature.py` | 0 | PASS | `.harness/evidence/raw/{{TASK_ID}}-worker-attempt-{{ATTEMPT_NUMBER}}.md` |

## 5. 주의사항 및 잔여 이슈 (Notes & Known Issues)
- 변경에 따른 영향 범위:
- 확인된 한계점 또는 주의사항:

## 6. Reviewer를 위한 중점 검토 포인트
- 집중 검토 요청 영역:
- 의도된 설계 결정 사항:

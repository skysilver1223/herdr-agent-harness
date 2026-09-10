# Review: {{TASK_ID}}-review-{{REVIEW_NUMBER}}

## 메타데이터
- Task ID: {{TASK_ID}}
- Review 번호: {{REVIEW_NUMBER}}
- 검토 일시: {{TIMESTAMP}}
- Reviewer Provider: {{REVIEWER_PROVIDER}}
- Primary Worker Provider: {{WORKER_PROVIDER}}
- 대상 Attempt: {{TASK_ID}}-attempt-{{ATTEMPT_NUMBER}}

## 1. 최종 판정 (Verdict)
판정: {{VERDICT}}
*(반드시 APPROVED 또는 CHANGES_REQUESTED 중 하나만 기재, 다른 값 금지)*

## 2. 검토한 산출물 목록 (Reviewed Artifacts)
- [ ] Task Contract: `.harness/tasks/{{TASK_ID}}.yaml`
- [ ] Intent 문서: `.harness/intents/{{TASK_ID}}-intent.md`
- [ ] Attempt 문서: `.harness/attempts/{{TASK_ID}}-attempt-{{ATTEMPT_NUMBER}}.md`
- [ ] Evidence 정본: `.harness/evidence/{{TASK_ID}}-worker-attempt-{{ATTEMPT_NUMBER}}.yaml`
- [ ] AC 검증 결과: `.harness/evidence/{{TASK_ID}}-attempt-{{ATTEMPT_NUMBER}}-checks.yaml`
- [ ] Git Diff 변경분

## 3. 8대 정책 기준 검토 (Review Focus Checklist)

### 1) requirement_coverage (요구사항 및 기준 충족도)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 2) correctness (로직 정확성 및 결함 여부)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 3) regression_risk (회귀 위험 및 기존 영향도)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 4) security_and_secrets (보안 취약점 및 비밀키 노출 여부)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 5) maintainability (유지보수성 및 코드 품질)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 6) verification_quality (자체 검증 및 테스트 품질)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 7) documentation_and_handover (문서화 및 인계 품질)
- 판정: PASS / FAIL / NA
- 상세 의견:

### 8) intent_alignment (Intent 문서 Not/Invariants 대조)
- 판정: PASS / FAIL / NA
- 상세 의견:
- Not 위반 발견 시 다른 항목 판정과 무관하게 최종 판정은 CHANGES_REQUESTED (`review-policy.yaml` immediate_rejection)

## 4. 잔여 리스크 (Remaining Risks)
- 배포 또는 병합 전 주의해야 할 잠재적 리스크:

## 5. 피드백 및 조치 요구사항 (Actionable Feedback)
*(CHANGES_REQUESTED인 경우 구체적 수정 요구사항을 목록화)*
1. 
2.

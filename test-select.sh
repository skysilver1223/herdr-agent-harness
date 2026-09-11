#!/bin/bash
source ../herdr-harness/lib/10-lib.sh
source ../herdr-harness/lib/50-runtime.sh

test_select() {
  local provider="$1"
  RUNTIME_MODEL=""
  RUNTIME_MODEL_SOURCE=""
  RUNTIME_MODEL_APPROVAL=""
  RUNTIME_MODEL_DEGRADATION=""
  
  if _runtime_select_model "../dummy-test-proj" "../dummy-test-proj/.harness/tasks/task-001.yaml" "worker" "$provider" "task-001" 2>&1; then
    echo "SUCCESS | MODEL: $RUNTIME_MODEL | SOURCE: $RUNTIME_MODEL_SOURCE"
  else
    echo "FAILED"
  fi
}
echo "--- Legacy Path (Empty Tier) ---"
test_select "claude"

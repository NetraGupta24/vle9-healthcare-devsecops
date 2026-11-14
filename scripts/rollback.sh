#!/usr/bin/env bash
# Roll the patient-api Deployment back to its previous revision.
# Called by the Jenkinsfile when the DAST stage fails after a deploy.
# Usage: scripts/rollback.sh [reason]
set -euo pipefail
NS=healthcare
REASON=${1:-manual rollback}

echo "==> ROLLBACK: $REASON"
kubectl -n "$NS" rollout history deployment/patient-api | tail -5 || true
if kubectl -n "$NS" rollout undo deployment/patient-api; then
  kubectl -n "$NS" rollout status deployment/patient-api --timeout=120s
  kubectl -n "$NS" get deploy patient-api -o jsonpath='{"now running: "}{.spec.template.spec.containers[0].image}{"\n"}'
else
  echo "No previous revision to roll back to." >&2
fi

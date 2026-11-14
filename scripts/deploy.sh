#!/usr/bin/env bash
# Deploy one exact image to the "healthcare" namespace (Jenkins "Deploy" stage,
# Step 7). Works with the least-privilege jenkins-deployer kubeconfig.
#
# Usage: scripts/deploy.sh <image:tag> [change-cause]
# Env:
#   KUBECONFIG        kubeconfig to use (Jenkins: jenkins-deployer credential)
#   APP_SECRETS_FILE  optional env-file; (re)creates Secret patient-api-secrets
#                     from it. Without it, the existing Secret is reused.
#
# If the rollout does not become healthy, it is rolled back automatically.
set -euo pipefail

IMAGE=${1:?usage: deploy.sh <image:tag> [change-cause]}
CAUSE=${2:-"deploy $IMAGE"}
NS=healthcare
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "==> Target: $(kubectl config current-context 2>/dev/null || echo '?') / namespace $NS"

if [[ -n "${APP_SECRETS_FILE:-}" ]]; then
  echo "==> Syncing Secret patient-api-secrets from Jenkins credentials (values are never printed)"
  # Server-side apply: no "last-applied-configuration" annotation, so the
  # secret values are not duplicated into object metadata.
  kubectl -n "$NS" create secret generic patient-api-secrets \
    --from-env-file="$APP_SECRETS_FILE" --dry-run=client -o yaml \
    | kubectl apply --server-side --field-manager=jenkins-deployer --force-conflicts -f - >/dev/null
fi
if ! kubectl -n "$NS" get secret patient-api-secrets >/dev/null 2>&1; then
  echo "ERROR: Secret $NS/patient-api-secrets does not exist. Create the values with" >&2
  echo "       scripts/generate-app-secrets.sh and pass the file as APP_SECRETS_FILE." >&2
  exit 1
fi

checksum=$( { cat "$ROOT/k8s/app/configmap.yaml"; [[ -n "${APP_SECRETS_FILE:-}" ]] && cat "$APP_SECRETS_FILE"; } | sha256sum | cut -c1-16)
cp "$ROOT"/k8s/app/{configmap,pdb}.yaml "$OUT/"
sed -e "s#__IMAGE__#${IMAGE}#g" -e "s#__CONFIG_CHECKSUM__#${checksum}#g" \
  "$ROOT/k8s/app/deployment.yaml" > "$OUT/deployment.yaml"

echo "==> kubectl apply (image $IMAGE)"
kubectl apply -f "$OUT"
kubectl -n "$NS" annotate deployment/patient-api kubernetes.io/change-cause="$CAUSE" --overwrite >/dev/null

echo "==> Waiting for rollout"
if ! kubectl -n "$NS" rollout status deployment/patient-api --timeout=180s; then
  echo "ERROR: rollout did not become healthy - rolling back" >&2
  kubectl -n "$NS" get pods -o wide || true
  kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -15 || true
  kubectl -n "$NS" rollout undo deployment/patient-api || true
  kubectl -n "$NS" rollout status deployment/patient-api --timeout=120s || true
  exit 1
fi

kubectl -n "$NS" get deploy,pods,svc -o wide
echo "==> Deployed $IMAGE"

#!/usr/bin/env bash
# Build a kubeconfig for the least-privilege "jenkins-deployer" ServiceAccount
# (k8s/base/01-rbac.yaml) and prove what it can and cannot do.
# Run as the cluster admin (the user that owns minikube), AFTER applying k8s/base.
#
# Usage: scripts/make-jenkins-kubeconfig.sh [output-file]
#   default output: ~/.medsecure/jenkins-deployer.kubeconfig  (mode 600)
set -euo pipefail

OUT=${1:-$HOME/.medsecure/jenkins-deployer.kubeconfig}
NS=healthcare
SA=jenkins-deployer

echo "==> Waiting for the ServiceAccount token to be issued"
for _ in $(seq 1 30); do
  TOKEN_B64=$(kubectl -n "$NS" get secret "$SA-token" -o jsonpath='{.data.token}' 2>/dev/null || true)
  [[ -n "$TOKEN_B64" ]] && break
  sleep 2
done
[[ -n "$TOKEN_B64" ]] || { echo "token secret $NS/$SA-token not populated" >&2; exit 1; }

SERVER=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl -n "$NS" get secret "$SA-token" -o jsonpath='{.data.ca\.crt}')
TOKEN=$(printf '%s' "$TOKEN_B64" | base64 -d)

umask 077
mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: medsecure
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
users:
  - name: ${SA}
    user:
      token: ${TOKEN}
contexts:
  - name: ${SA}@medsecure
    context:
      cluster: medsecure
      user: ${SA}
      namespace: ${NS}
current-context: ${SA}@medsecure
EOF
chmod 600 "$OUT"
echo "==> Wrote $OUT"

echo "==> RBAC proof (expected: yes, yes, yes, no, no, no, no, no)"
check() { printf '  %-55s %s\n' "$*" "$(kubectl --kubeconfig "$OUT" auth can-i "$@" 2>/dev/null || true)"; }
check create deployments -n "$NS"
check patch deployments -n "$NS"
check get secret/patient-api-secrets -n "$NS"
check delete deployments -n "$NS"
check create pods/exec -n "$NS"
check get secret/jenkins-deployer-token -n "$NS"
check list secrets -n kube-system
check create rolebindings -n "$NS"

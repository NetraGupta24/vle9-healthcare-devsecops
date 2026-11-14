#!/usr/bin/env bash
# Step 9 - Install Prometheus, Alertmanager and Grafana (kube-prometheus-stack)
# plus the MedSecure ServiceMonitor, alert rules, dashboard and Mailpit inbox.
# Usage (as the ubuntu user, from the repo): scripts/ec2/04-install-monitoring.sh
# Env: HELM_EXTRA_ARGS - extra helm flags, e.g. "-f my-alert-receivers.yaml"
set -euo pipefail
source "$(dirname "$0")/common.sh"
cd "$REPO_ROOT"
secrets_dir

CHART_VERSION=${CHART_VERSION:-93.3.0}

info "Helm repository"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

info "Grafana admin password (random, stored in a Kubernetes Secret, no trailing newline)"
random_secret "$SECRETS_DIR/grafana-admin-password" sh -c 'openssl rand -base64 24 | tr -dc A-Za-z0-9 | cut -c1-20'
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-file=admin-password=<(printf '%s' "$(cat "$SECRETS_DIR/grafana-admin-password")") \
  --dry-run=client -o yaml | kubectl apply --server-side --field-manager=medsecure-setup -f - >/dev/null

info "kube-prometheus-stack $CHART_VERSION (this takes a few minutes)"
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --version "$CHART_VERSION" \
  -f monitoring/kube-prometheus-stack-values.yaml ${HELM_EXTRA_ARGS:-} \
  --wait --timeout 15m

info "MedSecure ServiceMonitor, alert rules, Grafana dashboard, Mailpit"
kubectl apply -k monitoring/
kubectl -n monitoring rollout status deploy/mailpit --timeout=180s
kubectl -n monitoring get pods

echo
echo "Monitoring ready. Grafana user: admin  password: cat $SECRETS_DIR/grafana-admin-password"
echo "NEXT: sudo scripts/ec2/05-configure-jenkins.sh <your GitHub repo URL>"

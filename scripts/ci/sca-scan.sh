#!/usr/bin/env bash
# Pipeline stage "Dependency & IaC Scan":
#   1. npm audit       - known CVEs in the production dependency tree (SCA)
#   2. trivy fs        - CVEs in package-lock.json, leaked secrets in files, and
#                        misconfigurations in the Dockerfile, Kubernetes
#                        manifests and Terraform (Infrastructure-as-Code scan)
# Fails on HIGH or CRITICAL findings.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

info "npm audit (production dependencies)"
docker run --rm -u "$(id -u):$(id -g)" \
  -e HOME=/tmp -e npm_config_cache=/tmp/.npm -e npm_config_update_notifier=false \
  -v "$REPO_ROOT/app:/app" -v "$REPORTS:/reports" -w /app \
  "$NODE_IMAGE" sh -c 'npm audit --omit=dev --json > /reports/npm-audit.json; npm audit --omit=dev --audit-level=high' \
  && ok "npm audit: no HIGH/CRITICAL advisories" \
  || { fail "npm audit found HIGH/CRITICAL advisories (see reports/npm-audit.json)"; exit 1; }

info "Trivy filesystem scan: dependencies + secrets + IaC misconfigurations"
trivy_run fs --quiet --scanners vuln,secret,misconfig \
  --skip-dirs app/node_modules --skip-dirs infra/terraform/.terraform --ignorefile .trivyignore.yaml \
  --format json --output reports/trivy-fs.json .
trivy_run fs --quiet --scanners vuln,secret,misconfig \
  --skip-dirs app/node_modules --skip-dirs infra/terraform/.terraform --ignorefile .trivyignore.yaml \
  --severity "$TRIVY_SEVERITY" --exit-code 1 . \
  && ok "Trivy fs: no $TRIVY_SEVERITY findings" \
  || { fail "Trivy found $TRIVY_SEVERITY issues in dependencies/IaC (see reports/trivy-fs.json)"; exit 1; }

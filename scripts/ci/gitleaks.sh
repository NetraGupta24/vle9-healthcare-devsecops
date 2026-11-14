#!/usr/bin/env bash
# Pipeline stage "Secrets Scan": fail the build if any secret (API key, token,
# private key, password...) was ever committed to this branch's Git history.
# Findings are redacted in the log and in reports/gitleaks.json.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

info "Gitleaks: scanning Git history for hardcoded secrets"
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$REPO_ROOT:/repo" -w /repo \
  "$GITLEAKS_IMAGE" git /repo \
  --config /repo/.gitleaks.toml \
  --redact --no-banner --verbose \
  --report-format json --report-path /repo/reports/gitleaks.json \
  --exit-code 1 \
  && ok "no secrets found" \
  || { fail "Gitleaks found secrets. Remove them, ROTATE them, and rewrite history. See reports/gitleaks.json"; exit 1; }

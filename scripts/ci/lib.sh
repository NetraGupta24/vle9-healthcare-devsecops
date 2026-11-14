#!/usr/bin/env bash
# Shared helpers for the CI scripts. Sourced, not executed.

# Tool images, pinned so every build uses the same scanner versions.
# (The Jenkinsfile exports the same values; these are fallbacks for local runs.)
: "${NODE_IMAGE:=node:24-alpine@sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5}"
: "${GITLEAKS_IMAGE:=zricethezav/gitleaks:v8.30.1}"
: "${SONAR_SCANNER_IMAGE:=sonarsource/sonar-scanner-cli:12.4.0.4321_8.4.0}"
: "${ZAP_IMAGE:=ghcr.io/zaproxy/zaproxy:2.17.0}"
: "${TRIVY_IMAGE:=aquasec/trivy:0.76.2}"
: "${TRIVY_SEVERITY:=HIGH,CRITICAL}"

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REPORTS="$REPO_ROOT/reports"
mkdir -p "$REPORTS"

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32mOK:\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; }

# Run Trivy: the native binary if installed (EC2 / Jenkins host), otherwise
# the official container image (laptop). Reports land in $REPORTS either way.
trivy_run() {
  if command -v trivy >/dev/null 2>&1; then
    trivy "$@"
  else
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "${HOME}/.cache/trivy:/root/.cache/trivy" \
      -v "$REPO_ROOT:$REPO_ROOT" -w "$REPO_ROOT" \
      "$TRIVY_IMAGE" "$@"
  fi
}

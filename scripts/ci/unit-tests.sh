#!/usr/bin/env bash
# Pipeline stage "Unit Tests": install dependencies from the lockfile and run
# the test suite with coverage inside a throwaway Node container (the Jenkins
# host needs no Node.js). Produces app/coverage/lcov.info for SonarQube and
# reports/junit.xml for Jenkins.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

info "Unit tests (node:24-alpine container)"
docker run --rm -u "$(id -u):$(id -g)" \
  -e HOME=/tmp -e npm_config_cache=/tmp/.npm -e npm_config_update_notifier=false \
  -v "$REPO_ROOT/app:/app" -w /app \
  "$NODE_IMAGE" sh -c 'npm ci --ignore-scripts --no-audit --no-fund && npm run -s test:coverage'

cp app/coverage/junit.xml "$REPORTS/junit.xml"
cp app/coverage/lcov.info "$REPORTS/lcov.info"
ok "tests passed (coverage in app/coverage/lcov.info)"

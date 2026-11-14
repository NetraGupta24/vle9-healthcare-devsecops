#!/usr/bin/env bash
# Pipeline stage "SAST + Quality Gate (SonarQube)" - Step 4 of the lab.
# sonar.qualitygate.wait=true makes the scanner wait for SonarQube's verdict
# and exit non-zero when the Quality Gate fails, which fails the stage.
# Runs inside withSonarQubeEnv('sonarqube') in the Jenkinsfile, which injects
# SONAR_HOST_URL and SONAR_AUTH_TOKEN (the token is masked in the log).
# Project settings live in sonar-project.properties.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

: "${SONAR_HOST_URL:?run inside withSonarQubeEnv or export SONAR_HOST_URL}"
: "${SONAR_AUTH_TOKEN:=${SONAR_TOKEN:-}}"
[[ -n "$SONAR_AUTH_TOKEN" ]] || { fail "SONAR_AUTH_TOKEN/SONAR_TOKEN not set"; exit 1; }

info "sonar-scanner -> $SONAR_HOST_URL"
# --network host: the scanner container reaches SonarQube on localhost:9000.
docker run --rm --network host -u "$(id -u):$(id -g)" \
  -e SONAR_HOST_URL -e SONAR_TOKEN="$SONAR_AUTH_TOKEN" -e SONAR_USER_HOME=/tmp/.sonar \
  -v "$REPO_ROOT:/usr/src" -w /usr/src \
  "$SONAR_SCANNER_IMAGE" \
  -Dsonar.working.directory=/usr/src/.scannerwork \
  -Dsonar.qualitygate.wait=true -Dsonar.qualitygate.timeout=300 \
  -Dsonar.projectVersion="$(jq -r .version app/package.json 2>/dev/null || echo 1.0.0)" \
  ${BUILD_NUMBER:+-Dsonar.analysis.buildNumber="$BUILD_NUMBER"}
ok "SonarQube analysis done and the Quality Gate PASSED"

#!/usr/bin/env bash
# Pipeline stage "DAST (OWASP ZAP)" - Step 8.
# Runs zap-baseline.py (spider + passive scan) against the RUNNING app.
# security/zap/rules.tsv decides which findings FAIL the build.
#
# zap-baseline.py exit codes: 0 = clean, 1 = at least one FAIL,
#                             2 = only WARNs, 3 = scan error.
# Usage: zap-baseline.sh [target-url]
#   default target = the app's NodePort on the minikube node.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

PROFILE=${MINIKUBE_PROFILE:-minikube}
NETWORK=${ZAP_NETWORK:-$PROFILE}
if [[ -n "${1:-}" ]]; then
  TARGET=$1
else
  NODE_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$PROFILE\").IPAddress}}" "$PROFILE")
  TARGET="http://${NODE_IP}:30080"
fi

WRK="$REPORTS/zap"
mkdir -p "$WRK"
cp security/zap/rules.tsv "$WRK/rules.tsv"
chmod 777 "$WRK" # the ZAP container runs as its own "zap" user

info "OWASP ZAP baseline scan -> $TARGET"
set +e
docker run --rm --network "$NETWORK" -v "$WRK:/zap/wrk:rw" "$ZAP_IMAGE" \
  zap-baseline.py -t "$TARGET" -c rules.tsv -m 2 \
  -r zap-report.html -J zap-report.json -w zap-report.md
rc=$?
set -e

case $rc in
  0) ok "ZAP: no findings" ;;
  2) ok "ZAP: warnings only (see reports/zap/zap-report.html), no FAIL-level findings" ;;
  1) fail "ZAP: FAIL-level findings - see reports/zap/zap-report.html"; exit 1 ;;
  *) fail "ZAP scan error (exit $rc)"; exit 1 ;;
esac

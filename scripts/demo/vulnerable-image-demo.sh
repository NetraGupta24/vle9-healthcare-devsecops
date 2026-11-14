#!/usr/bin/env bash
# "Vulnerabilities detected early" demo (Step 6): build the same app twice
#   1. with the handout's Dockerfile (node:18-alpine, npm left in the image)
#   2. with this project's hardened Dockerfile
# and run the pipeline's container gate (scripts/ci/trivy-image.sh) on both.
# Jenkins equivalent: Build with Parameters -> BASE_IMAGE=node:18-alpine.
set -uo pipefail
source "$(dirname "$0")/../ci/lib.sh"
cd "$REPO_ROOT" || exit 1

summary() {
  trivy_run image --quiet --scanners vuln --format json "$1" 2>/dev/null \
    | jq -r '([.Results[]?.Vulnerabilities[]?.Severity] | group_by(.) | map("\(.[0])=\(length)") | join("  ")) as $v
             | (if $v == "" then "no vulnerabilities" else $v end) + "   (OS: \(.Metadata.OS.Family) \(.Metadata.OS.Name)\(if .Metadata.OS.EOSL then ", END-OF-LIFE" else "" end))"'
}

info "Building the handout image (scripts/demo/Dockerfile.handout)"
docker build -q -f scripts/demo/Dockerfile.handout -t medsecure-demo:handout . >/dev/null || exit 1
info "Building the hardened image (Dockerfile)"
docker build -q -t medsecure-demo:hardened . >/dev/null || exit 1

echo
printf '%-22s %s\n' "handout Dockerfile:" "$(summary medsecure-demo:handout)"
printf '%-22s %s\n' "hardened Dockerfile:" "$(summary medsecure-demo:hardened)"

for img in medsecure-demo:handout medsecure-demo:hardened; do
  info "Pipeline container gate on $img"
  if scripts/ci/trivy-image.sh "$img" > "$REPORTS/demo-gate-${img#*:}.log" 2>&1; then
    ok "$img PASSES the gate"
  else
    grep -E 'FAIL|Total:' "$REPORTS/demo-gate-${img#*:}.log" | head -5
    fail "$img is BLOCKED - it would never reach Kubernetes"
  fi
done

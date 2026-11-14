#!/usr/bin/env bash
# Pipeline stage "Container Scan (Trivy)" - Step 6.
# 1. Full report of every vulnerability (all severities) -> reports/
# 2. SBOM (CycloneDX) of everything inside the image   -> reports/sbom.cdx.json
# 3. Gates - the image is NOT deployed if any of these fail:
#    a. HIGH/CRITICAL vulnerabilities that have a fix available, or secrets
#    b. the base OS is end-of-life (no more security patches)
#    c. the Node.js runtime is older than the oldest supported LTS line
#       (Trivy cannot see CVEs in the node binary itself, so check the version)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

IMAGE=${1:?usage: trivy-image.sh <image:tag>}
MIN_NODE_MAJOR=${MIN_NODE_MAJOR:-22} # Node 22 = oldest LTS still receiving security fixes
status=0

info "Trivy: full vulnerability report for $IMAGE"
trivy_run image --quiet --scanners vuln,secret --format json --output reports/trivy-image.json "$IMAGE"
trivy_run image --quiet --scanners vuln,secret --format table --output reports/trivy-image.txt "$IMAGE"

info "Trivy: SBOM (CycloneDX)"
trivy_run image --quiet --format cyclonedx --output reports/sbom.cdx.json "$IMAGE"

info "Gate a: $TRIVY_SEVERITY vulnerabilities with a fix must be zero"
if trivy_run image --quiet --scanners vuln,secret --severity "$TRIVY_SEVERITY" --ignore-unfixed \
     --exit-code 1 "$IMAGE"; then
  ok "no fixable $TRIVY_SEVERITY vulnerabilities"
else
  fail "fixable $TRIVY_SEVERITY vulnerabilities found"; status=1
fi

info "Gate b: base OS must still be supported"
os=$(jq -r '.Metadata.OS | "\(.Family) \(.Name)"' reports/trivy-image.json)
if [[ "$(jq -r '.Metadata.OS.EOSL // false' reports/trivy-image.json)" == "true" ]]; then
  fail "base OS $os is END-OF-LIFE"; status=1
else
  ok "base OS $os is supported"
fi

info "Gate c: Node.js runtime must be >= $MIN_NODE_MAJOR (supported LTS)"
node_version=$(docker run --rm --entrypoint node "$IMAGE" -p 'process.versions.node' 2>/dev/null || echo unknown)
if [[ "$node_version" != unknown && "${node_version%%.*}" -ge "$MIN_NODE_MAJOR" ]]; then
  ok "Node.js $node_version"
else
  fail "Node.js $node_version is end-of-life (minimum $MIN_NODE_MAJOR)"; status=1
fi

if [[ $status -eq 0 ]]; then
  ok "image $IMAGE passed the container security gate"
else
  fail "image $IMAGE will NOT be deployed (see reports/trivy-image.txt)"
fi
exit $status

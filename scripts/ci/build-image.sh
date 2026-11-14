#!/usr/bin/env bash
# Pipeline stage "Build Image" - Step 5.
# Usage: build-image.sh <image:tag> [base-image-override]
# The optional override exists for the demo: build with node:18-alpine
# (end-of-life) and watch the Trivy gate in the next stage block it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

IMAGE=${1:?usage: build-image.sh <image:tag> [base-image]}
BASE=${2:-}

args=(--pull --tag "$IMAGE"
  --label "org.opencontainers.image.revision=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)")
if [[ -n "$BASE" ]]; then
  info "DEMO: overriding base image with $BASE"
  args+=(--build-arg "NODE_IMAGE=$BASE")
fi

info "docker build $IMAGE"
docker build "${args[@]}" .
docker image inspect "$IMAGE" --format 'Built {{.RepoTags}}  user={{.Config.User}}  size={{.Size}} bytes'

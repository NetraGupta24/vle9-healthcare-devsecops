#!/usr/bin/env bash
# Keep the disk from filling up: every build adds a ~270 MB app image on the
# host and (when deployed) a copy inside the minikube node. Keep only the
# newest KEEP images (by build number) in each place.
#
# Safe for rollback: only images that passed every gate reach the node, so
# the live and the previous revision are always among the newest ones; and
# the container runtime refuses to delete an image a running pod uses.
# Usage: prune-images.sh [keep]   (default 3)
set -uo pipefail
KEEP=${1:-3}
REPO=medsecure-patient-api
PROFILE=${MINIKUBE_PROFILE:-minikube}

# Tags look like <build>-<sha>; sort newest first by build number.
old_tags() { sort -t- -k1,1nr | tail -n +$((KEEP + 1)); }

echo "==> Pruning $REPO images, keeping the newest $KEEP"
docker images "$REPO" --format '{{.Tag}}' | grep -E '^[0-9]+-' | old_tags | while read -r tag; do
  docker rmi "$REPO:$tag" >/dev/null 2>&1 && echo "  host: removed $tag"
done

if docker inspect "$PROFILE" >/dev/null 2>&1; then
  docker exec "$PROFILE" crictl images -o json 2>/dev/null \
    | jq -r --arg r "docker.io/library/$REPO:" '.images[].repoTags[]? | select(startswith($r)) | ltrimstr($r)' \
    | grep -E '^[0-9]+-' | old_tags | while read -r tag; do
        docker exec "$PROFILE" crictl rmi "docker.io/library/$REPO:$tag" >/dev/null 2>&1 \
          && echo "  node: removed $tag" || echo "  node: kept $tag (in use)"
      done
fi
docker image prune -f >/dev/null 2>&1
df -h / | awk 'NR==2 {print "==> disk: " $5 " used, " $4 " free"}'

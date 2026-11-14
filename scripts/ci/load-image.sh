#!/usr/bin/env bash
# Copy a locally built image into the minikube node so pods can start it
# without any registry (imagePullPolicy: IfNotPresent).
#
# * If this user owns the minikube profile: `minikube image load`.
# * Otherwise (the jenkins user, which only has Docker access): stream the
#   image into the node's container runtime. minikube >= 1.39 uses containerd
#   by default, so `ctr import` is used; older Docker-runtime nodes use
#   `docker load`.
set -euo pipefail
IMAGE=${1:?usage: load-image.sh <image:tag>}
PROFILE=${MINIKUBE_PROFILE:-minikube}

echo "==> Loading $IMAGE into minikube node '$PROFILE'"
if command -v minikube >/dev/null 2>&1 && minikube -p "$PROFILE" status >/dev/null 2>&1; then
  minikube -p "$PROFILE" image load "$IMAGE"
elif docker exec "$PROFILE" sh -c 'command -v ctr' >/dev/null 2>&1 \
     && docker exec "$PROFILE" sh -c 'crictl info 2>/dev/null | grep -q containerd'; then
  docker save "$IMAGE" | docker exec -i "$PROFILE" ctr -n k8s.io images import -
else
  docker save "$IMAGE" | docker exec -i "$PROFILE" docker load
fi

ref="docker.io/library/${IMAGE}"
[[ "$IMAGE" == */* ]] && ref="$IMAGE"
if docker exec "$PROFILE" crictl inspecti "$ref" >/dev/null 2>&1; then
  echo "==> Image present in the node runtime: $ref"
else
  echo "ERROR: $ref not found in the minikube node after loading" >&2
  exit 1
fi

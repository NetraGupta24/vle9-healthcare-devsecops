#!/usr/bin/env bash
# Step 7 (cluster) - Start a hardened single-node minikube cluster:
#   * Calico CNI           -> NetworkPolicies are actually enforced
#   * etcd encryption      -> Secrets are encrypted at rest (secretbox), not
#                             just base64 encoded
#   * API audit logging    -> who read/changed what in the cluster
#   * k8s/base applied     -> namespace (Pod Security "restricted"), RBAC,
#                             NetworkPolicies, quotas
#   * kubeconfig for the least-privilege jenkins-deployer ServiceAccount
#
# Usage (as the ubuntu user, from the repo): scripts/ec2/03-start-minikube.sh
# Re-run after an EC2 reboot to start the existing cluster again.
# Env: MINIKUBE_PROFILE (minikube) MINIKUBE_CPUS (2) MINIKUBE_MEMORY (3584mb)
#      MINIKUBE_START_ARGS (extra flags, e.g. --base-image=... behind a proxy)
set -euo pipefail
source "$(dirname "$0")/common.sh"
cd "$REPO_ROOT"
secrets_dir

CPUS=${MINIKUBE_CPUS:-2}
MEMORY=${MINIKUBE_MEMORY:-3584mb}
K8S_VERSION=${K8S_VERSION:-v1.37.0}
MK_FILES="${MINIKUBE_HOME:-$HOME/.minikube}/files/etc/ssl/certs"

# Files under ~/.minikube/files/ are copied into the node before Kubernetes
# starts; /etc/ssl/certs is already mounted into the kube-apiserver pod.
info "Writing API-server encryption + audit configuration"
mkdir -p "$MK_FILES"
random_secret "$SECRETS_DIR/etcd-encryption-key" sh -c 'head -c 32 /dev/urandom | base64'
(umask 077; cat > "$MK_FILES/medsecure-encryption.yaml" <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - secretbox:
          keys:
            - name: key1
              secret: $(cat "$SECRETS_DIR/etcd-encryption-key")
      - identity: {} # still able to read anything stored before encryption was on
EOF
)
cat > "$MK_FILES/medsecure-audit-policy.yaml" <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:
  # Never log Secret contents - only who touched which Secret.
  - level: Metadata
    resources: [{ group: "", resources: ["secrets", "configmaps"] }]
  # Every change in the PHI namespace, with the request body.
  - level: Request
    namespaces: ["healthcare"]
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
  # exec / port-forward into PHI pods.
  - level: Metadata
    namespaces: ["healthcare"]
    resources: [{ group: "", resources: ["pods/exec", "pods/portforward", "pods/attach"] }]
  # RBAC changes anywhere.
  - level: Metadata
    resources: [{ group: "rbac.authorization.k8s.io" }]
  - level: None
EOF

if minikube -p "$PROFILE" status >/dev/null 2>&1; then
  ok "minikube profile '$PROFILE' is already running"
else
  info "Starting minikube ($PROFILE): Kubernetes $K8S_VERSION, Calico, $CPUS CPU, $MEMORY"
  minikube start -p "$PROFILE" --driver=docker --container-runtime=containerd \
    --kubernetes-version="$K8S_VERSION" --cni=calico \
    --cpus="$CPUS" --memory="$MEMORY" --disk-size=20g \
    --extra-config=apiserver.encryption-provider-config=/etc/ssl/certs/medsecure-encryption.yaml \
    --extra-config=apiserver.audit-policy-file=/etc/ssl/certs/medsecure-audit-policy.yaml \
    --extra-config=apiserver.audit-log-path=- \
    --extra-config=apiserver.audit-log-maxage=7 \
    ${MINIKUBE_START_ARGS:-}
fi
kubectl config use-context "$PROFILE" >/dev/null
wait_for 300 "node Ready" kubectl wait --for=condition=Ready node --all --timeout=10s
wait_for 300 "Calico running" kubectl -n kube-system rollout status ds/calico-node --timeout=10s

info "Applying k8s/base (namespace, RBAC, NetworkPolicies, quotas) as cluster admin"
kubectl apply -f k8s/base/

info "Building the jenkins-deployer kubeconfig"
scripts/make-jenkins-kubeconfig.sh "$SECRETS_DIR/jenkins-deployer.kubeconfig"

info "Proving Secrets are encrypted in etcd"
raw=$(kubectl -n kube-system exec "etcd-$PROFILE" -- etcdctl \
  --endpoints=https://127.0.0.1:2379 --cacert=/var/lib/minikube/certs/etcd/ca.crt \
  --cert=/var/lib/minikube/certs/etcd/server.crt --key=/var/lib/minikube/certs/etcd/server.key \
  get /registry/secrets/healthcare/jenkins-deployer-token --print-value-only 2>/dev/null | head -c 40 | tr -c '[:print:]' '.')
echo "  first bytes in etcd: $raw"
if [[ "$raw" == k8s:enc:secretbox:v1:key1* ]]; then
  ok "Secrets are encrypted at rest (secretbox)"
else
  warn "Secret is NOT encrypted in etcd - check the --extra-config flags (cluster may predate this script: minikube delete && re-run)"
fi

echo
echo "Cluster ready. NEXT: scripts/ec2/04-install-monitoring.sh"

#!/usr/bin/env bash
# Evidence for the report/viva: proves each runtime security control works.
# Run on the EC2 host as the cluster admin, after the pipeline deployed the app.
#   scripts/demo/security-checks.sh
# Never prints secret values.
set -uo pipefail
NS=healthcare
PROFILE=${MINIKUBE_PROFILE:-minikube}
pass=0; failn=0
check() { # check "<description>" <expected: ok|fail> <command...>
  local desc=$1 want=$2; shift 2
  if "$@" >/dev/null 2>&1; then got=ok; else got=fail; fi
  if [[ "$got" == "$want" ]]; then printf '  \033[32mPASS\033[0m %s\n' "$desc"; pass=$((pass+1))
  else printf '  \033[31mFAIL\033[0m %s\n' "$desc"; failn=$((failn+1)); fi
}
pod=$(kubectl -n $NS get pods -l app.kubernetes.io/name=patient-api -o jsonpath='{.items[0].metadata.name}')
DEPLOYER=${DEPLOYER_KUBECONFIG:-$HOME/.medsecure/jenkins-deployer.kubeconfig}

echo "== 1. Pod Security Admission (namespace enforces 'restricted')"
check "a root/privileged pod is REJECTED in $NS" fail \
  kubectl -n $NS run psa-test --image=busybox:1.37 --restart=Never --privileged=true -- id
check "the app pod runs as uid 10001 (non-root)" ok \
  sh -c "kubectl -n $NS exec $pod -- node -e 'process.exit(process.getuid()===10001?0:1)'"
check "the container root filesystem is read-only" fail \
  kubectl -n $NS exec "$pod" -- node -e 'require("fs").writeFileSync("/app/pwned","x")'

echo "== 2. RBAC least privilege (jenkins-deployer)"
k() { kubectl --kubeconfig "$DEPLOYER" "$@"; }
check "deployer CAN update the deployment" ok k -n $NS auth can-i patch deployments --quiet
check "deployer can NOT delete deployments" fail k -n $NS auth can-i delete deployments --quiet
check "deployer can NOT exec into pods" fail k -n $NS auth can-i create pods/exec --quiet
check "deployer can NOT read other secrets" fail k -n $NS auth can-i get secret/jenkins-deployer-token --quiet
check "deployer can NOT touch kube-system" fail k -n kube-system auth can-i list secrets --quiet
check "deployer can NOT change NetworkPolicies" fail k -n $NS auth can-i patch networkpolicies --quiet
check "app ServiceAccount has no API token mounted" fail \
  kubectl -n $NS exec "$pod" -- node -e 'require("fs").statSync("/var/run/secrets/kubernetes.io/serviceaccount/token")'

echo "== 3. NetworkPolicies (Calico)"
kubectl run np-probe --image=busybox:1.37 --restart=Never -n default --command -- sleep 120 >/dev/null 2>&1
kubectl -n default wait --for=condition=Ready pod/np-probe --timeout=90s >/dev/null 2>&1
check "other namespace CAN reach the API port" ok \
  kubectl -n default exec np-probe -- wget -T 4 -qO /dev/null http://patient-api.$NS.svc/healthz
check "other namespace can NOT scrape metrics (only 'monitoring' may)" fail \
  kubectl -n default exec np-probe -- wget -T 4 -qO /dev/null http://patient-api-metrics.$NS.svc:9464/metrics
check "app pods can NOT call the internet (no exfiltration path)" fail \
  kubectl -n $NS exec "$pod" -- node -e 'fetch("https://example.com",{signal:AbortSignal.timeout(4000)}).then(()=>process.exit(0),()=>process.exit(1))'
kubectl -n default delete pod np-probe --now >/dev/null 2>&1 &

echo "== 4. Secrets"
check "Secret patient-api-secrets exists with the 5 expected keys" ok \
  sh -c "[ \"\$(kubectl -n $NS get secret patient-api-secrets -o json | jq -r '.data|keys|length')\" = 5 ]"
check "Secret is encrypted at rest in etcd (k8s:enc:secretbox)" ok sh -c "
  kubectl -n kube-system exec etcd-$PROFILE -- etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/var/lib/minikube/certs/etcd/ca.crt --cert=/var/lib/minikube/certs/etcd/server.crt \
    --key=/var/lib/minikube/certs/etcd/server.key get /registry/secrets/$NS/patient-api-secrets \
    --print-value-only | head -c 26 | grep -q 'k8s:enc:secretbox:v1:key1'"
check "no last-applied annotation duplicates the secret" fail sh -c \
  "kubectl -n $NS get secret patient-api-secrets -o json | jq -e '.metadata.annotations[\"kubectl.kubernetes.io/last-applied-configuration\"]'"

echo "== 5. Application"
api=http://127.0.0.1:8081
check "API rejects requests without a token (401)" ok \
  sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $api/api/patients)\" = 401 ]"
check "security headers present (CSP, nosniff, no-store)" ok sh -c \
  "curl -sI $api/ | grep -qi 'content-security-policy' && curl -sI $api/ | grep -qi 'x-content-type-options: nosniff' && curl -sI $api/ | grep -qi 'cache-control: no-store'"
check "metrics port is NOT exposed by the public service" fail \
  sh -c "kubectl -n $NS get svc patient-api -o json | jq -e '.spec.ports[] | select(.port==9464)'"

echo
echo "Result: $pass passed, $failn failed"
[[ $failn -eq 0 ]]

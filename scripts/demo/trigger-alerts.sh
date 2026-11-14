#!/usr/bin/env bash
# Step 9 demo - generate attack-like traffic so each security alert fires.
# Run on the EC2 host (uses the app port-forward on 127.0.0.1:8081 and the
# admin kubeconfig for the CPU test).
#
# Usage: scripts/demo/trigger-alerts.sh [all|failed-logins|unauthorized|forbidden|bulk-phi|cpu]
#
# Expected alerts (Prometheus -> Alerts, Grafana dashboard, Mailpit inbox):
#   failed-logins  -> FailedLoginBurst, AccountLockedOut
#   unauthorized   -> UnauthorizedAccessSpike
#   forbidden      -> PrivilegeEscalationAttempt
#   bulk-phi       -> PHIBulkAccess
#   cpu            -> PatientAPIHighCPU (after ~3-4 minutes)
set -euo pipefail
API=${API:-http://127.0.0.1:8081}
SECRETS_FILE=${APP_SECRETS_FILE:-$HOME/.medsecure/app-secrets.env}
WHAT=${1:-all}

pw() { grep "^$1=" "$SECRETS_FILE" | cut -d= -f2-; }
login() { # login <user> <password> -> token
  curl -fsS -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg u "$1" --arg p "$2" '{username:$u,password:$p}')" "$API/api/auth/login" | jq -r .token
}
codes() { sort | uniq -c | awk '{printf "  HTTP %s x %s\n", $2, $1}'; }

curl -fsS -o /dev/null "$API/healthz" || { echo "App not reachable at $API (run scripts/ec2/06-port-forwards.sh start)" >&2; exit 1; }

# Log in BEFORE the brute-force test: the per-IP login rate limit will then
# block further logins from this host for 15 minutes.
DOCTOR=$(login dr.mehta "$(pw DOCTOR_PASSWORD)")
NURSE=$(login nurse.priya "$(pw NURSE_PASSWORD)")

failed_logins() {
  echo "==> Brute force: 30 wrong passwords for desk.ravi"
  for i in $(seq 1 30); do
    curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' \
      -d "{\"username\":\"desk.ravi\",\"password\":\"guess-$i-Password\"}" "$API/api/auth/login"
  done | codes
  echo "   (401 = rejected, 429 = per-IP rate limit kicked in; account locked after 5 failures)"
}

unauthorized() {
  echo "==> 45 requests to PHI endpoints without a valid token"
  # A token claiming to be the doctor, signed with a key the attacker made up.
  b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
  garbage="not-a-jwt"
  forged="$(printf '{"alg":"HS256"}' | b64url).$(printf '{"sub":"dr.mehta","role":"doctor"}' | b64url).$(head -c 32 /dev/urandom | b64url)"
  { for _ in $(seq 1 15); do curl -s -o /dev/null -w '%{http_code}\n' "$API/api/patients"; done
    for _ in $(seq 1 15); do curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $forged" "$API/api/patients"; done
    for _ in $(seq 1 15); do curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $garbage" "$API/api/patients"; done
  } | codes
}

forbidden() {
  echo "==> Nurse tries doctor-only actions 8 times"
  id=$(curl -fsS -H "Authorization: Bearer $DOCTOR" "$API/api/patients" | jq -r '.patients[0].id')
  for _ in $(seq 1 8); do
    curl -s -o /dev/null -w '%{http_code}\n' -X PATCH -H "Authorization: Bearer $NURSE" \
      -H 'Content-Type: application/json' -d '{"diagnosis":"changed by nurse"}' "$API/api/patients/$id/clinical"
  done | codes
}

bulk_phi() {
  echo "==> Doctor account reads 80 full patient records in a burst (exfiltration pattern)"
  mapfile -t ids < <(curl -fsS -H "Authorization: Bearer $DOCTOR" "$API/api/patients" | jq -r '.patients[].id')
  for i in $(seq 1 80); do
    curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $DOCTOR" "$API/api/patients/${ids[$((i % ${#ids[@]}))]}"
  done | codes
}

cpu() {
  echo "==> Simulating a crypto-miner inside one pod (busy loop for 5 minutes)"
  pod=$(kubectl -n healthcare get pods -l app.kubernetes.io/name=patient-api -o jsonpath='{.items[0].metadata.name}')
  kubectl -n healthcare exec "$pod" -- node -e 'const end=Date.now()+300000; while (Date.now()<end) {}' >/dev/null 2>&1 &
  echo "   burning CPU in $pod (pid $!). PatientAPIHighCPU fires after ~3-4 min: kubectl -n healthcare top pod"
}

case "$WHAT" in
  failed-logins) failed_logins ;;
  unauthorized) unauthorized ;;
  forbidden) forbidden ;;
  bulk-phi) bulk_phi ;;
  cpu) cpu ;;
  all) unauthorized; forbidden; bulk_phi; failed_logins; cpu ;;
  *) echo "usage: $0 [all|failed-logins|unauthorized|forbidden|bulk-phi|cpu]" >&2; exit 2 ;;
esac

cat <<'EOF'

Watch the alerts (through the SSH tunnel):
  Prometheus  http://localhost:19090/alerts    (pending -> firing within ~1 min)
  Grafana     http://localhost:13000           dashboard "MedSecure - Healthcare Security Monitoring"
  Mailpit     http://localhost:18025           security-team@ / oncall@ emails (~1 min later)
EOF

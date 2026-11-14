#!/usr/bin/env bash
# Expose the in-cluster UIs on the EC2 host's LOCALHOST only. Nothing is
# opened to the internet: you reach them from your laptop through the
# encrypted SSH tunnel printed at the end (terraform output tunnel_command).
#
# Usage (as the ubuntu user): scripts/ec2/06-port-forwards.sh start|stop|status
set -euo pipefail
source "$(dirname "$0")/common.sh"
secrets_dir
RUN="$SECRETS_DIR/port-forwards"
mkdir -p "$RUN"

# name namespace service host-port service-port
FORWARDS=(
  "app        healthcare patient-api                              8081 80"
  "grafana    monitoring monitoring-grafana                       3000 80"
  "prometheus monitoring monitoring-kube-prometheus-prometheus    9090 9090"
  "alertmgr   monitoring monitoring-kube-prometheus-alertmanager  9093 9093"
  "mailpit    monitoring mailpit                                  8025 8025"
)

start() {
  for f in "${FORWARDS[@]}"; do
    read -r name ns svc lport rport <<<"$f"
    if [[ -f "$RUN/$name.pid" ]] && kill -0 "$(cat "$RUN/$name.pid")" 2>/dev/null; then
      ok "$name already forwarded on 127.0.0.1:$lport"; continue
    fi
    # Loop: a port-forward dies when its pod is replaced (e.g. after a deploy).
    nohup bash -c "while true; do kubectl -n $ns port-forward --address 127.0.0.1 svc/$svc $lport:$rport; sleep 2; done" \
      >"$RUN/$name.log" 2>&1 &
    echo $! > "$RUN/$name.pid"
    ok "$name -> 127.0.0.1:$lport (svc/$svc in $ns)"
  done
}

stop() {
  for f in "$RUN"/*.pid; do
    [[ -e "$f" ]] || continue
    pid=$(cat "$f"); pkill -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true; rm -f "$f"
  done
  ok "port-forwards stopped"
}

status() {
  for f in "${FORWARDS[@]}"; do
    read -r name _ _ lport _ <<<"$f"
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$lport/" || true)
    printf '  %-11s 127.0.0.1:%-5s HTTP %s\n' "$name" "$lport" "$code"
  done
}

case "${1:-start}" in
  start) start; sleep 3; status ;;
  stop) stop ;;
  status) status ;;
  *) die "usage: $0 start|stop|status" ;;
esac

cat <<'EOF'

From your LAPTOP, open the tunnel (keep it running):
  ssh -i ~/.ssh/vle9-key -N \
    -L 18080:localhost:8080 -L 19000:localhost:9000 -L 18081:localhost:8081 \
    -L 13000:localhost:3000 -L 19090:localhost:9090 -L 19093:localhost:9093 \
    -L 18025:localhost:8025 ubuntu@<EC2_PUBLIC_IP>
Then browse:
  Jenkins      http://localhost:18080      SonarQube    http://localhost:19000
  MedSecure    http://localhost:18081      Grafana      http://localhost:13000
  Prometheus   http://localhost:19090      Alertmanager http://localhost:19093
  Alert inbox  http://localhost:18025
EOF

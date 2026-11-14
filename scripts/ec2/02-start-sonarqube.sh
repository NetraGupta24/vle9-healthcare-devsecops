#!/usr/bin/env bash
# Step 2/4 - Start SonarQube (+PostgreSQL) and prepare it for Jenkins:
#   * replaces the default admin/admin password with a random one
#   * creates a NON-admin "jenkins" user that may only run analyses, and a token
# Secrets are written to ~/.medsecure/ (mode 600), never printed.
# Usage (as the ubuntu user, from the repo): scripts/ec2/02-start-sonarqube.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"
cd "$REPO_ROOT"
secrets_dir

URL=${SONAR_URL:-http://localhost:9000}
ENV_FILE=security/sonarqube/.env

info "Starting SonarQube + PostgreSQL (docker compose)"
random_secret "$SECRETS_DIR/sonarqube-db-password" openssl rand -hex 24
(umask 077; echo "SONAR_DB_PASSWORD=$(cat "$SECRETS_DIR/sonarqube-db-password")" > "$ENV_FILE")
docker compose -f security/sonarqube/docker-compose.yml --env-file "$ENV_FILE" up -d

sonar_up() { curl -fsS "$URL/api/system/status" | grep -q '"status":"UP"'; }
wait_for 900 "SonarQube is UP at $URL" sonar_up

# 1. Default credentials are the #1 finding in every audit: rotate them.
random_secret "$SECRETS_DIR/sonarqube-admin-password" sh -c 'printf "%sAa1!" "$(openssl rand -hex 10)"'
ADMIN_PW=$(cat "$SECRETS_DIR/sonarqube-admin-password")
FACTORY_DEFAULT="admin:admin" # gitleaks:allow - SonarQube's public factory default, rotated right here
if curl -fsS -u "$FACTORY_DEFAULT" "$URL/api/authentication/validate" | grep -q '"valid":true'; then
  info "Replacing the default SonarQube admin password"
  curl -fsS -u "$FACTORY_DEFAULT" -X POST "$URL/api/users/change_password" \
    --data-urlencode login=admin --data-urlencode previousPassword=admin \
    --data-urlencode "password=$ADMIN_PW"
fi
curl -fsS -u "admin:$ADMIN_PW" "$URL/api/authentication/validate" | grep -q '"valid":true' \
  || die "cannot log in to SonarQube as admin with the stored password"
ok "admin password is not the default (stored in $SECRETS_DIR/sonarqube-admin-password)"
api() { curl -fsS -u "admin:$ADMIN_PW" "$@"; }

# 2. Least privilege for CI: a normal user with only "Execute Analysis" and
#    "Create Projects", instead of using the admin account in Jenkins.
if ! api "$URL/api/users/search?q=jenkins" | jq -e '.users[] | select(.login=="jenkins")' >/dev/null; then
  info "Creating SonarQube user 'jenkins' (non-admin)"
  api -X POST "$URL/api/users/create" --data-urlencode login=jenkins \
    --data-urlencode "name=Jenkins CI" --data-urlencode local=true \
    --data-urlencode "password=$(openssl rand -hex 12)Aa1!" >/dev/null
fi
for perm in scan provisioning; do
  api -X POST "$URL/api/permissions/add_user" -d login=jenkins -d "permission=$perm"
done
token_valid() {
  [[ -s "$SECRETS_DIR/sonarqube-token" ]] \
    && curl -fsS -u "$(cat "$SECRETS_DIR/sonarqube-token"):" "$URL/api/authentication/validate" | grep -q '"valid":true'
}
# (Re)generate when missing or stale, e.g. after the SonarQube volumes were reset.
if ! token_valid; then
  api -X POST "$URL/api/user_tokens/revoke" -d login=jenkins -d name=jenkins-ci >/dev/null 2>&1 || true
  (umask 077; api -X POST "$URL/api/user_tokens/generate" -d login=jenkins -d name=jenkins-ci -d type=USER_TOKEN \
    | jq -r .token > "$SECRETS_DIR/sonarqube-token")
fi
ok "analysis token for user 'jenkins' stored in $SECRETS_DIR/sonarqube-token"

# No webhook to Jenkins: SonarQube (rightly) refuses webhook URLs on private
# addresses as SSRF protection. Instead the scanner itself waits for the
# Quality Gate (sonar.qualitygate.wait=true in scripts/ci/sonar-scan.sh) and
# fails the Jenkins stage when the gate fails.

echo
echo "SonarQube ready. UI (through the SSH tunnel): http://localhost:19000  user: admin"
echo "Password: cat $SECRETS_DIR/sonarqube-admin-password"
echo "NEXT: scripts/ec2/03-start-minikube.sh"

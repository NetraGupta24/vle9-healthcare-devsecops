#!/usr/bin/env bash
# Step 2/10 - Configure Jenkins as code (no clicking through the setup wizard):
#   * installs the pipeline plugins (SonarQube, Git, JCasC, Job DSL, ...)
#   * creates the admin user with a random password
#   * loads the credentials the pipeline needs from ~/.medsecure/ into the
#     Jenkins credential store (encrypted on disk by Jenkins, masked in logs)
#   * registers the SonarQube server and creates the pipeline job
#
# Usage (from the repo, with sudo):
#   sudo scripts/ec2/05-configure-jenkins.sh https://github.com/<you>/<repo>.git [branch]
# Prerequisites: 02-start-sonarqube.sh and 03-start-minikube.sh have run.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
REPO_URL=${1:?usage: sudo $0 <git-repo-url> [branch]}
BRANCH=${2:-main}

APP_USER=${SUDO_USER:-ubuntu}
APP_HOME=$(getent passwd "$APP_USER" | cut -d: -f6)
export HOME=$APP_HOME SECRETS_DIR=$APP_HOME/.medsecure
source "$(dirname "$0")/common.sh"
cd "$REPO_ROOT"

JENKINS_HOME=/var/lib/jenkins
CASC_SECRETS=$JENKINS_HOME/casc_secrets
PM_VERSION=2.16.0
PM_JAR=/opt/jenkins-plugin-manager-$PM_VERSION.jar

for f in sonarqube-token jenkins-deployer.kubeconfig; do
  [[ -s "$SECRETS_DIR/$f" ]] || die "$SECRETS_DIR/$f missing - run 02-start-sonarqube.sh and 03-start-minikube.sh first"
done
if [[ ! -s "$SECRETS_DIR/app-secrets.env" ]]; then
  info "Generating application secrets"
  sudo -u "$APP_USER" scripts/generate-app-secrets.sh "$SECRETS_DIR/app-secrets.env"
fi
random_secret "$SECRETS_DIR/jenkins-admin-password" sh -c 'openssl rand -base64 24 | tr -dc A-Za-z0-9 | cut -c1-20'
chown -R "$APP_USER:$APP_USER" "$SECRETS_DIR"

systemctl stop jenkins || true

info "Installing plugins (plugin-installation-manager $PM_VERSION)"
if [[ ! -f "$PM_JAR" ]]; then
  base=https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/$PM_VERSION
  curl -fsSL -o "$PM_JAR" "$base/jenkins-plugin-manager-$PM_VERSION.jar"
  echo "$(curl -fsSL "$base/jenkins-plugin-manager-$PM_VERSION.jar.sha256" | awk '{print $1}')  $PM_JAR" | sha256sum -c -
fi
install -d -o jenkins -g jenkins "$JENKINS_HOME/plugins"
plugin_list=$(mktemp)
grep -vE '^\s*(#|$)' jenkins/plugins.txt > "$plugin_list"
chmod 644 "$plugin_list"
sudo -u jenkins java -jar "$PM_JAR" --war /usr/share/java/jenkins.war \
  --plugin-download-directory "$JENKINS_HOME/plugins" --plugin-file "$plugin_list"
rm -f "$plugin_list"

info "Credentials for JCasC (copied to $CASC_SECRETS, owner jenkins, mode 600)"
install -d -o jenkins -g jenkins -m 700 "$CASC_SECRETS"
install -o jenkins -g jenkins -m 600 "$SECRETS_DIR/jenkins-admin-password" "$CASC_SECRETS/jenkinsAdminPassword"
install -o jenkins -g jenkins -m 600 "$SECRETS_DIR/sonarqube-token" "$CASC_SECRETS/sonarToken"
install -o jenkins -g jenkins -m 600 "$SECRETS_DIR/app-secrets.env" "$CASC_SECRETS/app-secrets.env"
install -o jenkins -g jenkins -m 600 "$SECRETS_DIR/jenkins-deployer.kubeconfig" "$CASC_SECRETS/jenkins-deployer.kubeconfig"

info "Rendering JCasC configuration"
install -d -o jenkins -g jenkins -m 700 "$JENKINS_HOME/casc_configs"
sed -e "s#__REPO_URL__#${REPO_URL}#g" -e "s#__BRANCH__#${BRANCH}#g" jenkins/casc.yaml \
  > "$JENKINS_HOME/casc_configs/jenkins.yaml"
chown jenkins:jenkins "$JENKINS_HOME/casc_configs/jenkins.yaml"
chmod 600 "$JENKINS_HOME/casc_configs/jenkins.yaml"

install -d /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf <<'EOF'
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false -Xmx1g"
Environment="CASC_JENKINS_CONFIG=/var/lib/jenkins/casc_configs/jenkins.yaml"
Environment="SECRETS=/var/lib/jenkins/casc_secrets"
EOF
systemctl daemon-reload
systemctl start jenkins

jenkins_up() { [[ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/login)" == 200 ]]; }
wait_for 600 "Jenkins answers on :8080" jenkins_up
AUTH="admin:$(cat "$SECRETS_DIR/jenkins-admin-password")"
job_ok() { curl -fsS -u "$AUTH" http://localhost:8080/job/medsecure-devsecops/api/json; }
wait_for 300 "job medsecure-devsecops exists" job_ok
curl -fsS -u "$AUTH" "http://localhost:8080/credentials/store/system/domain/_/api/json?depth=1" \
  | jq -r '"credentials: " + ([.credentials[].id] | join(", "))'

if [[ "${TRIGGER_BUILD:-true}" == "true" ]]; then
  info "Triggering the first pipeline run"
  cookie=$(mktemp)
  crumb=$(curl -fsS -c "$cookie" -u "$AUTH" 'http://localhost:8080/crumbIssuer/api/json' | jq -r '.crumbRequestField + ":" + .crumb')
  curl -fsS -b "$cookie" -u "$AUTH" -H "$crumb" -X POST http://localhost:8080/job/medsecure-devsecops/build
  rm -f "$cookie"
  ok "build queued"
fi

echo
echo "Jenkins ready. UI (through the SSH tunnel): http://localhost:18080  user: admin"
echo "Password: cat $SECRETS_DIR/jenkins-admin-password"
echo "NEXT: scripts/ec2/06-port-forwards.sh start"

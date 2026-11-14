#!/usr/bin/env bash
# Step 1-2 - Bootstrap the EC2 host. Runs automatically as root on first boot
# (Terraform passes it as EC2 user data); safe to re-run: sudo ./00-bootstrap.sh
#
# Installs: Docker + compose, Git, Java 21, Jenkins LTS, kubectl, minikube,
# Helm, Trivy. OWASP ZAP, SonarQube scanner and Gitleaks run as pinned
# containers, so they are only pre-pulled here.
#
# Every binary downloaded outside apt is verified against its published
# SHA-256 checksum before it is installed.
# Log: /var/log/medsecure-bootstrap.log
set -euo pipefail
exec > >(tee -a /var/log/medsecure-bootstrap.log) 2>&1
echo "=== bootstrap start $(date -u +%FT%TZ)"

KUBECTL_VERSION=v1.37.2
MINIKUBE_VERSION=v1.39.0
HELM_VERSION=v4.3.2
APP_USER=${APP_USER:-ubuntu}
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- OS basics
apt-get update -y
apt-get -o Dpkg::Options::=--force-confold upgrade -y
apt-get install -y ca-certificates curl gnupg jq git unzip conntrack \
  openssl fontconfig openjdk-21-jre-headless unattended-upgrades \
  docker.io docker-compose-v2
systemctl enable --now unattended-upgrades docker

# 4 GiB swap: Jenkins + SonarQube + minikube share 8 GiB of RAM.
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# Kernel settings: SonarQube's Elasticsearch needs a high mmap count.
cat > /etc/sysctl.d/99-medsecure.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
vm.swappiness=10
EOF
sysctl --system >/dev/null

# SSH hardening: keys only, no root login.
cat > /etc/ssh/sshd_config.d/99-medsecure.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X11Forwarding no
MaxAuthTries 3
EOF
systemctl reload ssh || systemctl reload sshd || true

# ---------------------------------------------------------------- Jenkins LTS
# Jenkins rotated its apt signing key in 2026 (jenkins.io-2026.key).
install -d -m 0755 /etc/apt/keyrings
curl -fsSL -o /etc/apt/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list

# ---------------------------------------------------------------- Trivy
curl -fsSL https://get.trivy.dev/deb/public.key | gpg --dearmor --yes -o /etc/apt/keyrings/trivy.gpg
echo "deb [signed-by=/etc/apt/keyrings/trivy.gpg] https://get.trivy.dev/deb generic main" \
  > /etc/apt/sources.list.d/trivy.list

apt-get update -y
apt-get install -y jenkins trivy
usermod -aG docker jenkins
usermod -aG docker "$APP_USER"
# Jenkins is configured (plugins, admin user, credentials, job) by
# scripts/ec2/05-configure-jenkins.sh. Until then it stays behind its
# setup wizard, which requires the one-time initialAdminPassword.
systemctl enable jenkins

# ---------------------------------------------------------------- kubectl / minikube / helm
TMP=$(mktemp -d)
cd "$TMP"
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -
install -m 0755 kubectl /usr/local/bin/kubectl

curl -fsSLO "https://github.com/kubernetes/minikube/releases/download/${MINIKUBE_VERSION}/minikube-linux-amd64"
curl -fsSLO "https://github.com/kubernetes/minikube/releases/download/${MINIKUBE_VERSION}/minikube-linux-amd64.sha256"
echo "$(cat minikube-linux-amd64.sha256)  minikube-linux-amd64" | sha256sum -c -
install -m 0755 minikube-linux-amd64 /usr/local/bin/minikube

curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
sha256sum -c "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
tar -xzf "helm-${HELM_VERSION}-linux-amd64.tar.gz"
install -m 0755 linux-amd64/helm /usr/local/bin/helm
cd / && rm -rf "$TMP"

# ---------------------------------------------------------------- pre-pull scanner images
for img in \
  node:24-alpine@sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5 \
  zricethezav/gitleaks:v8.30.1 \
  sonarsource/sonar-scanner-cli:12.4.0.4321_8.4.0 \
  ghcr.io/zaproxy/zaproxy:2.17.0 \
  sonarqube:26.11.0.134175-community \
  postgres:17-alpine; do
  docker pull -q "$img" || echo "WARN: could not pre-pull $img (will be pulled on first use)"
done

echo "=== versions"
docker --version; docker compose version; java -version 2>&1 | head -1
kubectl version --client | head -1; minikube version --short; helm version --short; trivy --version | head -1
dpkg -s jenkins | grep '^Version'
touch /var/lib/medsecure-bootstrap.done
echo "=== bootstrap done $(date -u +%FT%TZ)"

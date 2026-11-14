#!/usr/bin/env bash
# One-shot setup of the whole lab on the EC2 host, after Terraform created it
# and the user-data bootstrap finished. Runs steps 02-06 in order.
#
# Usage (as the ubuntu user, from the repo):
#   scripts/ec2/setup-all.sh https://github.com/<you>/<repo>.git [branch]
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO_URL=${1:?usage: $0 <git-repo-url> [branch]}
BRANCH=${2:-main}

[[ -f /var/lib/medsecure-bootstrap.done ]] || {
  echo "Bootstrap not finished yet: tail -f /var/log/medsecure-bootstrap.log" >&2; exit 1; }
# Group membership from the bootstrap only applies to new logins:
id -nG | grep -qw docker || exec sg docker -c "$0 $*"

scripts/ec2/02-start-sonarqube.sh
scripts/ec2/03-start-minikube.sh
scripts/ec2/04-install-monitoring.sh
sudo scripts/ec2/05-configure-jenkins.sh "$REPO_URL" "$BRANCH"
scripts/ec2/06-port-forwards.sh start

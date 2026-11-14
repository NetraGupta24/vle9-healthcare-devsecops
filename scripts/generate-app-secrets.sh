#!/usr/bin/env bash
# Generate strong random application secrets into an env-file OUTSIDE the
# repository (mode 600). Nothing here is ever committed.
#
# Usage: scripts/generate-app-secrets.sh [output-file] [--force]
#   default output: ~/.medsecure/app-secrets.env
#
# Next: store the file in Jenkins as a "Secret file" credential with
# id "medsecure-app-secrets" (scripts/ec2/06-configure-jenkins.sh does this).
set -euo pipefail

OUT=${1:-$HOME/.medsecure/app-secrets.env}
FORCE=${2:-}
if [[ -e "$OUT" && "$FORCE" != "--force" ]]; then
  echo "$OUT already exists. Pass --force to rotate (pods will restart with new secrets)." >&2
  exit 1
fi

umask 077
mkdir -p "$(dirname "$OUT")"
pw() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20; }

cat > "$OUT" <<EOF
JWT_SECRET=$(openssl rand -hex 32)
PHI_ENCRYPTION_KEY=$(openssl rand -base64 32)
DOCTOR_PASSWORD=$(pw)
NURSE_PASSWORD=$(pw)
RECEPTIONIST_PASSWORD=$(pw)
EOF
chmod 600 "$OUT"

echo "Wrote $OUT (mode 600) with: $(cut -d= -f1 "$OUT" | paste -sd' ')"
echo "Staff logins for the UI:  grep PASSWORD $OUT"
echo
echo "WARNING: PHI_ENCRYPTION_KEY encrypts patient data. Rotating it makes"
echo "existing records unreadable (fine for this in-memory demo; a real system"
echo "re-encrypts with a key-management service such as AWS KMS)."

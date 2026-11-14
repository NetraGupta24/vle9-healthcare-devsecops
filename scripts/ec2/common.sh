#!/usr/bin/env bash
# Shared helpers for scripts/ec2/*. Sourced, not executed.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# Generated secrets live here, outside the Git checkout, readable only by you.
SECRETS_DIR=${SECRETS_DIR:-$HOME/.medsecure}
PROFILE=${MINIKUBE_PROFILE:-minikube}

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32mOK:\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

secrets_dir() { (umask 077; mkdir -p "$SECRETS_DIR"); chmod 700 "$SECRETS_DIR"; }

# random_secret <file> <command...>: create the file once (mode 600) with the
# command's output; later runs keep the existing value.
random_secret() {
  local file=$1; shift
  if [[ ! -s "$file" ]]; then
    (umask 077; "$@" > "$file")
  fi
  chmod 600 "$file"
}

wait_for() { # wait_for <seconds> <description> <command...>
  local timeout=$1 what=$2; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start > timeout )) && die "timed out after ${timeout}s waiting for $what"
    sleep 5
  done
  ok "$what"
}

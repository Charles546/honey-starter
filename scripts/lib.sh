# shellcheck shell=bash
# Library of helper functions for honey-starter scripts.

set -euo pipefail

# Paths
HONEY_STARTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_DIR="${HONEY_STARTER_DIR}/bootstrap"
DEPLOY_DIR="${HONEY_STARTER_DIR}/deploy"

# Load environment variables from .env if present
if [ -f "${HONEY_STARTER_DIR}/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "${HONEY_STARTER_DIR}/.env"
  set +a
fi

# Docker image tag for the daemon (must match the HEAD of the v4 branch you
# intend to use). When running configcheck outside docker, the binary at
# /tmp/honeydipper is used.
HONEYDIPPER_IMAGE="${HONEYDIPPER_IMAGE:-honeydipper/honeydipper:4.0.0-alpha4-53-g897242b}"

# Default values
: "${VALKEY_ADDR:=127.0.0.1:6379}"
: "${HD_JWT_SIGNING_KEY:=}"

# Print a message and exit with an error.
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Hard requirement: exit if the command is missing.
require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    die "required command not found: $1"
  fi
}

# Soft preflight: print [ok]/[missing] without failing. Used for tools that
# this phase of the project can operate without (docker, shellcheck, ...).
check_cmd() {
  if command -v "$1" &>/dev/null; then
    echo "  [ok]      $1"
  else
    echo "  [missing] $1"
  fi
}

# shellcheck shell=bash
# Library of helper functions for honey-starter scripts.

set -euo pipefail

# Paths
HONEY_STARTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_DIR="${HONEY_STARTER_DIR}/bootstrap"
DEPLOY_DIR="${HONEY_STARTER_DIR}/deploy"
# Exported: variables are consumed by scripts that source this library
# (e.g. start.sh, and the Phase 2 deployment helpers).
export BOOTSTRAP_DIR DEPLOY_DIR

# Load environment variables from .env if present. Test scripts (smoke, ...)
# set HONEY_STARTER_NO_ENV=1 before sourcing to keep their environment hermetic
# and avoid picking up a host .env.
if [ -z "${HONEY_STARTER_NO_ENV:-}" ] && [ -f "${HONEY_STARTER_DIR}/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "${HONEY_STARTER_DIR}/.env"
  set +a
fi

# Docker image tag for the daemon. This is the published image on Docker Hub.
# Override with HONEYDIPPER_IMAGE env var if needed.
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
  if ! command -v "$1" >/dev/null 2>&1; then
    die "required command not found: $1"
  fi
}

# Soft preflight: print [ok]/[missing] without failing. Used for tools that
# this phase of the project can operate without (shellcheck, ...).
check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "  [ok]      $1"
  else
    echo "  [missing] $1"
  fi
}

# Compose file used by the compose helpers below. Override COMPOSE_FILE before
# sourcing to point at a different compose project/file (a throwaway smoke
# project still uses the same file; the project is selected through the
# COMPOSE_PROJECT_NAME environment variable).
: "${COMPOSE_FILE:=${DEPLOY_DIR}/docker-compose.yaml}"

# Run `vault <args>` inside the vault service container as the vault user.
#
# Vault is unreachable from the host by network design (internal network, no
# published host port). `docker compose exec` reaches the container through the
# docker API, not the container network, so this is the ONLY supported way to
# run init/unseal/policy/seeding operations against the vault service — no host
# vault binary is ever needed. Compose exec syntax is
#   exec [OPTIONS] SERVICE COMMAND [ARGS...]
# and it bypasses the image entrypoint (which normally drops root -> vault and
# chowns /vault). Passing --user vault keeps init/unseal writes owned
# consistently with the running server, which also runs as the vault user.
# Note the service name ("vault") and the CLI binary ("vault") are distinct
# positional tokens.
vault_exec() {
  local svc="vault"
  docker compose -f "${COMPOSE_FILE}" exec -i -T --user "${svc}" "${svc}" vault "$@"
}

# Same as vault_exec but with an explicit VAULT_TOKEN in the container env.
vault_exec_token() {
  local token="$1"
  shift
  local svc="vault"
  docker compose -f "${COMPOSE_FILE}" exec -i -T --user "${svc}" \
    -e "VAULT_TOKEN=${token}" "${svc}" vault "$@"
}

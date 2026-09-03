#!/usr/bin/env bash
# start.sh — single-command entry point for honey-starter.
#
# Phase 1: this script validates the environment and the bootstrap config.
# Phase 2 will generate docker-compose and bring up valkey/vault/daemon/ui.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

echo "=== honey-starter: environment check ==="
# htpasswd is REQUIRED: used for bcrypt token generation (Vault seeding) and
# the B1 validation contract.
require_cmd htpasswd
# docker is required for Phase 2 and for configcheck; check-config.sh skips
# gracefully if docker is absent, so we report it here without failing.
check_cmd docker
check_cmd bash
check_cmd openssl
check_cmd shellcheck

echo ""
echo "=== honey-starter: validating bootstrap config ==="
"${HONEY_STARTER_DIR}/test/check-config.sh"

echo ""
echo "=== honey-starter: validating bcrypt token contract ==="
"${HONEY_STARTER_DIR}/test/check-bcrypt.sh"

echo ""
echo "Environment and config are valid."
echo "The docker-compose deployment (valkey, vault, daemon, ui) ships in Phase 2."

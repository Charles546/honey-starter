#!/usr/bin/env bash
# start.sh — single-command entry point for honey-starter.
#
# Phase 1: this script validates the environment and the bootstrap config.
# Phase 2 ships the docker-compose deployment in deploy/ (valkey/vault/daemon/ui)
# and the smoke gate; Phase 3 will add the Vault seeding + compose orchestration
# to this script.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

echo "=== honey-starter: environment check ==="
# htpasswd is REQUIRED: used for bcrypt token generation (Vault seeding) and
# the B1 validation contract.
require_cmd htpasswd
# The shellcheck tool is REQUIRED for the lint gate (contract: shellcheck, no docker).
require_cmd shellcheck
# docker is required for configcheck and for Phase 2; check-config.sh skips
# gracefully if docker is absent, so we report it here without failing.
check_cmd docker
check_cmd bash
check_cmd openssl

echo ""
echo "=== honey-starter: linting scripts (shellcheck) ==="
(cd "${HONEY_STARTER_DIR}" && shellcheck -x -P SCRIPTDIR scripts/*.sh test/*.sh)

echo ""
echo "=== honey-starter: validating bootstrap config ==="
"${HONEY_STARTER_DIR}/test/check-config.sh"

echo ""
echo "=== honey-starter: validating bcrypt token contract ==="
"${HONEY_STARTER_DIR}/test/check-bcrypt.sh"

echo ""
echo "Environment and config are valid."
echo "The docker-compose deployment lives in deploy/ (see deploy/README.md)."

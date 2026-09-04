#!/usr/bin/env bash
# stop.sh — gracefully stop the honey-starter stack (valkey, vault, daemon, ui).
#
# This is a "stop" (docker compose stop): containers are stopped but NOT
# removed, and the named volumes (vault-file, valkey-data, daemon-driver-cache)
# plus .honey-starter/ state are preserved, so `make start` afterwards resumes
# the same deployment quickly (vault stays initialized; start.sh re-establishes
# the unsealed state).
#
# Run: bash scripts/stop.sh   (or: make stop)
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not found"
  exit 0
fi

echo "=== honey-starter: stop ==="
# compose v2 `ps` only lists running containers by default; --all covers
# stopped ones too so we can detect "nothing to stop" either way.
if [ -z "$(compose ps --all -q 2>/dev/null)" ]; then
  echo "nothing to stop (no containers for project ${COMPOSE_PROJECT_NAME})"
  exit 0
fi
compose stop
echo "=== honey-starter stopped (volumes and .honey-starter/ state preserved) ==="

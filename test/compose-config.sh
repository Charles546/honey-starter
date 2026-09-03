#!/usr/bin/env bash
# compose-config.sh — validate deploy/docker-compose.yaml with `docker compose
# config` (compose v2). This catches schema/interpolation errors without
# pulling images or starting containers.
#
# Requires: docker with compose v2.
# Skips gracefully (exit 0) when docker/compose is unavailable.
#
# Run: bash test/compose-config.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${HERE}/deploy/docker-compose.yaml"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not found"
  exit 0
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "SKIP: docker compose v2 not found"
  exit 0
fi

echo "=== Compose config validation ==="
echo "File: ${COMPOSE_FILE}"
docker compose -f "${COMPOSE_FILE}" config >/dev/null
echo "=== Compose config is valid ==="

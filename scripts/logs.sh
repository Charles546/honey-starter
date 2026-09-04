#!/usr/bin/env bash
# logs.sh — follow the honeydipper daemon logs.
#
# By default tails + follows the daemon service. Pass extra args through to
# `docker compose logs` to select another service or different options, e.g.:
#   bash scripts/logs.sh ui
#   bash scripts/logs.sh --tail=200 daemon
#   bash scripts/logs.sh -f daemon ui
# Run: bash scripts/logs.sh [compose-logs-args...]   (or: make logs)
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not found"
  exit 0
fi

if [ "$#" -eq 0 ]; then
  compose logs -f --tail=100 daemon
else
  compose logs "$@"
fi

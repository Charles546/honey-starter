#!/usr/bin/env bash
# down.sh — full teardown of the honey-starter stack.
#
# `docker compose down` removes the containers and the default (non-named)
# networks but keeps the named volumes (vault-file, valkey-data,
# daemon-driver-cache) and .honey-starter/ state. `make down` therefore tears
# the stack down while preserving your Vault data and rendered config, so a
# later `make start` brings it back without re-initializing Vault.
#
# To ALSO delete the named volumes (irrecoverably wiping Vault's file backend
# and valkey data), pass -v/--volumes through: `make down-volumes`. The
# .honey-starter/ directory (root token/unseal key, admin token, identity
# files, rendered config) is NEVER removed by this script — remove it by hand
# only after you have backed up anything you need.
#
# Usage:
#   bash scripts/down.sh            # containers + networks down, data kept
#   bash scripts/down.sh --volumes  # also delete the named volumes
#   bash scripts/down.sh -v
# Run (typical): bash scripts/down.sh   (or: make down)
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not found"
  exit 0
fi

EXTRA=()
case "${1:-}" in
  "" ) ;;
  -v|--volumes) EXTRA+=(--volumes) ;;
  *)
    echo "usage: $0 [-v|--volumes]" >&2
    exit 1
    ;;
esac

echo "=== honey-starter: down ==="
compose down "${EXTRA[@]}"
if [ "${#EXTRA[@]}" -gt 0 ]; then
  echo "=== honey-starter down; named volumes deleted (vault-file / valkey-data / daemon-driver-cache) ==="
  echo "=== .honey-starter/ state preserved (remove by hand to fully reset) ==="
else
  echo "=== honey-starter down; named volumes and .honey-starter/ state preserved ==="
fi

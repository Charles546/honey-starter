#!/usr/bin/env bash
# render-config.sh — render bootstrap/ into ${HD_STATE_DIR}/config (no restart).
#
# This is the shared render (single source of truth) used by BOTH the
# reload-watch watcher and `make render-config`. It ONLY renders config/ from
# bootstrap/ — it does NOT start/stop the stack, does not touch Vault, and does
# not restart the daemon.
#
# IMPORTANT (fallback guidance): a running daemon keeps its in-memory config
# until it reloads. If reload-watch is NOT running, `make render-config` alone
# does NOT apply the change to a running daemon — the daemon keeps its stale
# in-memory config until the next HD_CONFIG_CHECK_INTERVAL tick. To apply
# without a watcher, use `make start` INSTEAD (it renders AND restarts in one
# step when the config changed) or restart the daemon explicitly with
# `docker compose restart daemon`. With reload-watch running, the render below
# is picked up and applied live (no restart).
#
# Run: bash scripts/render-config.sh   (or: make render-config)
set -euo pipefail

# bash >= 4 required (same guard as the other scripts).
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  printf '%s\n' "ERROR: bash 4 or newer is required (found ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

render_config

if [ "${CONFIG_CHANGED:-0}" -eq 1 ]; then
  msg_ok "rendered ${BOOTSTRAP_DIR} -> ${CONFIG_DIR} (ns=${HONEY_NS} user=${HONEY_USER})"
  msg_info "config changed; with reload-watch running it applies live. Without a watcher, use 'make start' (renders + restarts if changed) or 'docker compose restart daemon' to apply to a running daemon."
else
  msg_info "rendered ${BOOTSTRAP_DIR} -> ${CONFIG_DIR}: config unchanged (ns=${HONEY_NS} user=${HONEY_USER})"
fi

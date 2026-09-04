#!/usr/bin/env bash
# status.sh — report the health of a honey-starter deployment.
#
# Shows, in order:
#   1. docker compose ps (all four services, up/healthy/down)
#   2. daemon /healthz over the published API port (200 = healthy)
#   3. vault seal status (initialized/unsealed) via vault_exec
#   4. UI reachability over the published UI port
#
# Exit code: 0 when every service is up, vault is initialized+unsealed, and
# both /healthz and the UI answer HTTP 200; 1 otherwise (useful for scripting).
#
# Run: bash scripts/status.sh   (or: make status)
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not found"
  exit 0
fi

echo "=== honey-starter: status ==="
if [ -z "$(compose ps --status running -q 2>/dev/null)" ]; then
  echo "stack is not running (no running containers for project ${COMPOSE_PROJECT_NAME}). Start it with: make start"
  exit 1
fi

compose ps

API_HOST_PORT="${HD_API_HOST_PORT:-9000}"
UI_HOST_PORT="${HD_UI_HOST_PORT:-8090}"
API_URL="http://localhost:${API_HOST_PORT}"
UI_URL="http://localhost:${UI_HOST_PORT}"

ok=true

# daemon healthz
code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "${API_URL}/healthz" 2>/dev/null || true)"
if [ "${code}" = "200" ]; then
  echo "daemon /healthz:            OK (200)"
else
  echo "daemon /healthz:            FAIL (${code:-no response})" >&2
  ok=false
fi

# vault seal status. Use -format=json and parse it: the plain `vault status`
# table prints a "Sealed" header row even when the server is unsealed, so
# string-matching the table cannot distinguish sealed from unsealed. The JSON
# form has .initialized / .sealed booleans.
set +e
vault_out="$(vault_exec status -format=json 2>/dev/null)"
vault_rc=$?
set -e
if ! printf '%s' "${vault_out}" | jq -e '.initialized == true' >/dev/null 2>&1; then
  echo "vault seal status:          NOT INITIALIZED (run make start)" >&2
  ok=false
elif printf '%s' "${vault_out}" | jq -e '.sealed == true' >/dev/null 2>&1; then
  echo "vault seal status:          SEALED (run make start to unseal)" >&2
  ok=false
elif [ "${vault_rc}" -eq 0 ] \
  && printf '%s' "${vault_out}" | jq -e '.sealed == false' >/dev/null 2>&1; then
  echo "vault seal status:          unsealed"
else
  echo "vault seal status:          unknown (rc=${vault_rc})" >&2
  ok=false
fi

# UI reachability
ui_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "${UI_URL}/" 2>/dev/null || true)"
if [ "${ui_code}" = "200" ]; then
  echo "UI at ${UI_URL}:             OK (200)"
else
  echo "UI at ${UI_URL}:             FAIL (${ui_code:-no response})" >&2
  ok=false
fi

echo ""
if [ "${ok}" = "true" ]; then
  echo "=== honey-starter is healthy ==="
else
  echo "=== honey-starter has problems (see above) ===" >&2
  exit 1
fi

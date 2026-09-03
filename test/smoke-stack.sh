#!/usr/bin/env bash
# smoke-stack.sh — boot the full honey-starter compose stack (valkey, vault,
# daemon, ui) in a throwaway compose project and verify the trust chain end to
# end:
#
#   1. vault is initialized + unsealed, KV v2 mounted at secrets/, AppRole
#      enabled with a read-only policy scoped EXACTLY to
#      secrets/data/<ns>/daemon.
#   2. identity files (role_id, secret_id) are written and mounted into the
#      daemon; the daemon boots with AppRole credentials only — the root token
#      is never mounted or passed to it.
#   3. the daemon resolves LOOKUP[vault,/secrets/data/<ns>/daemon#...] values
#      (admin token hash + AI keys) through the vault driver.
#   4. API /healthz returns 200 and an admin bearer token (bcrypt hash stored
#      in Vault) authenticates against the api service.
#   5. the AppRole policy denies writes and reads outside the scoped path.
#   6. the UI serves HTTP 200 through the published port.
#
# Vault init/unseal/policy/seeding all happen through `docker compose exec
# vault` (the vault_exec helpers in scripts/lib.sh): Vault publishes no host
# port and is unreachable from the host by network design.
#
# Requires: docker (compose v2), network, curl, jq, openssl, htpasswd.
# Skips gracefully (exit 0) when docker is unavailable.
#
# Run: bash test/smoke-stack.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Namespace/user used for both the config placeholders and Vault seeding.
: "${SMOKE_NS:=smoke}"
: "${SMOKE_USER:=alice}"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not found"
  exit 0
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "SKIP: docker compose v2 not found"
  exit 0
fi
for cmd in curl jq openssl htpasswd; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
done

# Unique project + throwaway state dir. Host ports default to high ports to
# avoid clashing with a running instance; override via HD_API_HOST_PORT /
# HD_UI_HOST_PORT.
PROJECT="honey-starter-smoke-$$"
export COMPOSE_PROJECT_NAME="${PROJECT}"
STATE="$(mktemp -d)"
export HD_STATE_DIR="${STATE}"
export HD_API_HOST_PORT="${HD_API_HOST_PORT:-19000}"
export HD_UI_HOST_PORT="${HD_UI_HOST_PORT:-19080}"
export HD_UI_URL="http://localhost:${HD_UI_HOST_PORT}"
# Long interval: a local-dir init repo (REPO=/etc/honeydipper/config, no
# BRANCH) is treated as "uncommitted" and reloads unconditionally every
# tick, so keep the interval longer than the whole smoke run.
export HD_CONFIG_CHECK_INTERVAL="${HD_CONFIG_CHECK_INTERVAL:-30m}"
HD_JWT_SIGNING_KEY="$(openssl rand -hex 32)"
export HD_JWT_SIGNING_KEY

# --port-preflight (best-effort): abort if a requested host port is already
# serving HTTP on this host. Uses curl against 127.0.0.1 so both 127.0.0.1- and
# 0.0.0.0-bound HTTP listeners are caught without needing root for an ss/bind
# probe. This is best-effort: it cannot catch non-HTTP services on the port,
# IPv6-only binds, or a firewall that drops the probe. The default smoke ports
# (19000/19080) are high and normally free; if a port is occupied, override
# HD_API_HOST_PORT/HD_UI_HOST_PORT.
port_preflight() {
  local port="$1"
  local what="$2"
  if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${port}/" 2>/dev/null; then
    echo "ERROR: ${what} host port ${port} is already in use; set" >&2
    echo "       HD_API_HOST_PORT/HD_UI_HOST_PORT to free ports" >&2
    exit 1
  fi
  echo "  [ok] host port ${port} free (${what})"
}
echo "--- host port preflight"
port_preflight "${HD_API_HOST_PORT}" "daemon API"
port_preflight "${HD_UI_HOST_PORT}" "UI"

# Source the shared library AFTER setting smoke exports so it does not read a
# host .env (HONEY_STARTER_NO_ENV=1) and picks up COMPOSE_FILE/COMPOSE_PROJECT_NAME.
export HONEY_STARTER_NO_ENV=1
# shellcheck source=../scripts/lib.sh
source "${HERE}/scripts/lib.sh"

COMPOSE=(docker compose -f "${COMPOSE_FILE}")

cleanup() {
  set +e
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1
  rm -rf "${STATE}"
}
trap cleanup EXIT

echo "=== honey-starter smoke: compose project ${PROJECT} ==="

# --- render config with placeholders substituted ---------------------------
mkdir -p "${STATE}/config" "${STATE}/identity"
cp -r "${HERE}/bootstrap/." "${STATE}/config/"
sed -i "s/<ns>/${SMOKE_NS}/g" "${STATE}/config/init.yaml" \
  "${STATE}/config/auth.yaml" "${STATE}/config/engines.yaml" \
  "${STATE}/config/contexts.yaml"
sed -i "s/<user>/${SMOKE_USER}/g" "${STATE}/config/init.yaml" \
  "${STATE}/config/auth.yaml" "${STATE}/config/contexts.yaml" \
  "${STATE}/config/tests/api_auth_tests.yaml"
echo "--- rendered config with ns=${SMOKE_NS} user=${SMOKE_USER}"

# --- admin token + bcrypt hash (seeded into Vault) --------------------------
ADMIN_TOKEN="smoke-admin-$(openssl rand -hex 12)"
ADMIN_TOKEN_HASH="$(htpasswd -bnBC 12 "" "${ADMIN_TOKEN}" | cut -d: -f2 | tr -d '\n')"
echo "--- admin token generated (bcrypt hash stored in Vault only)"

# --- start infrastructure ---------------------------------------------------
echo "--- starting valkey + vault"
"${COMPOSE[@]}" up -d valkey vault

echo "--- waiting for vault API"
vault_out=""
for ((i = 0; i < 90; i++)); do
  set +e
  vault_out="$(vault_exec status 2>&1)"
  rc=$?
  set -e
  # A fresh (uninitialized) server answers with exit 1 + "not initialized";
  # an initialized-but-sealed server answers with exit 2 + "sealed". Both mean
  # the API is up. Anything else (connection refused, etc.) = still booting.
  case "${vault_out}" in
    *"not initialized"* | *Sealed* | *sealed*)
      break
      ;;
  esac
  sleep 2
done
case "${vault_out}" in
  *"not initialized"* | *Sealed* | *sealed*)
    ;;
  *)
    echo "FAIL: vault did not become reachable" >&2
    echo "${vault_out}" >&2
    exit 1
    ;;
esac

# --- initialize + unseal -----------------------------------------------------
echo "--- initializing vault (1 unseal key, dev-style smoke only)"
INIT_JSON="$(vault_exec operator init \
  -key-shares=1 -key-threshold=1 -format=json)"
ROOT_TOKEN="$(printf '%s' "${INIT_JSON}" | jq -r .root_token)"
UNSEAL_KEY="$(printf '%s' "${INIT_JSON}" | jq -r '.unseal_keys_b64[0]')"
vault_exec operator unseal "${UNSEAL_KEY}"
echo "--- vault unsealed"

# --- enable KV v2 + AppRole (idempotent on fresh volumes only) --------------
if ! vault_exec_token "${ROOT_TOKEN}" secrets list -format=json \
  | jq -e 'has("secrets/")' >/dev/null 2>&1; then
  vault_exec_token "${ROOT_TOKEN}" secrets enable -path=secrets kv-v2
  echo "--- KV v2 enabled at secrets/"
fi
if ! vault_exec_token "${ROOT_TOKEN}" auth list -format=json \
  | jq -e 'has("approle/")' >/dev/null 2>&1; then
  vault_exec_token "${ROOT_TOKEN}" auth enable approle
  echo "--- AppRole auth enabled"
fi

# --- AppRole role with read-only, path-scoped policy --------------------------
printf 'path "secrets/data/%s/daemon" {\n  capabilities = ["read"]\n}\n' \
  "${SMOKE_NS}" | vault_exec_token "${ROOT_TOKEN}" policy write daemon-read -
echo "--- policy daemon-read written (scoped to secrets/data/${SMOKE_NS}/daemon)"

vault_exec_token "${ROOT_TOKEN}" write auth/approle/role/daemon \
  token_policies=daemon-read \
  secret_id_ttl=0 \
  token_ttl=1h \
  token_max_ttl=24h \
  >/dev/null
ROLE_ID="$(vault_exec_token "${ROOT_TOKEN}" read -field=role_id \
  auth/approle/role/daemon/role-id)"
SECRET_ID="$(vault_exec_token "${ROOT_TOKEN}" write -field=secret_id \
  auth/approle/role/daemon/secret-id)"

# identity files are mounted read-only into the daemon at /var/hd-secrets/identity
# (printf '%s' -> no trailing newline; chmod 600 keeps them host-user-only).
printf '%s' "${ROLE_ID}" > "${STATE}/identity/role_id"
printf '%s' "${SECRET_ID}" > "${STATE}/identity/secret_id"
chmod 600 "${STATE}/identity/role_id" "${STATE}/identity/secret_id"
echo "--- AppRole identity files written (chmod 600, no trailing newline)"

# --- seed namespace secrets ---------------------------------------------------
vault_exec_token "${ROOT_TOKEN}" kv put "secrets/${SMOKE_NS}/daemon" \
  "admin_token_hash=${ADMIN_TOKEN_HASH}" \
  openai_api_key=sk-smoke-openai \
  openrouter_api_key=sk-smoke-openrouter \
  >/dev/null
echo "--- seeded secrets/data/${SMOKE_NS}/daemon"

# --- seed a decoy secret OUTSIDE the AppRole scope ----------------------------
# M1: the "read outside scope denied" assertion below must distinguish a real
# permission denial (403) from a vacuous 404 (path never existed). Seeding a
# decoy first means the path exists, so a wide-open policy would succeed and
# the test would catch it.
vault_exec_token "${ROOT_TOKEN}" kv put secrets/other/secret \
  decoy=value \
  >/dev/null
echo "--- seeded decoy secrets/data/other/secret (outside AppRole scope)"

# --- start daemon + ui ---------------------------------------------------------
echo "--- starting daemon + ui (daemon waits for vault healthy == unsealed)"
"${COMPOSE[@]}" up -d daemon ui

API_URL="http://localhost:${HD_API_HOST_PORT}"
echo "--- waiting for daemon /healthz at ${API_URL}"
http_code=""
for ((i = 0; i < 180; i++)); do
  set +e
  http_code="$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}/healthz" 2>/dev/null)"
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ] && [ "${http_code}" = "200" ]; then
    break
  fi
  sleep 2
done
if [ "${http_code}" != "200" ]; then
  echo "FAIL: daemon /healthz did not become 200 (last=${http_code})" >&2
  "${COMPOSE[@]}" logs daemon >&2 || true
  exit 1
fi
echo "--- daemon healthy"

# --- API auth round trip: bearer token -> bcrypt hash in Vault -> subject ----
# /api/user/profile is a local api-service handler (no dependency on remote
# drivers); 200 proves the bearer token authenticated to the seeded subject.
auth_code="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" "${API_URL}/api/user/profile")"
if [ "${auth_code}" != "200" ]; then
  echo "FAIL: authenticated GET /api/user/profile returned ${auth_code} (expected 200)" >&2
  exit 1
fi
echo "--- authenticated API call succeeded (vault LOOKUP + bcrypt verified)"

anon_code="$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}/api/user/profile")"
if [ "${anon_code}" = "200" ]; then
  echo "FAIL: anonymous GET /api/user/profile returned 200 (expected 401/403)" >&2
  exit 1
fi
echo "--- anonymous API call denied (${anon_code})"

# --- assert the AppRole policy is exactly read-only + path-scoped --------------
DAEMON_TOKEN="$(vault_exec_token "${ROOT_TOKEN}" write -field=client_token \
  auth/approle/login role_id="${ROLE_ID}" secret_id="${SECRET_ID}")"
if ! vault_exec_token "${DAEMON_TOKEN}" read \
  "secrets/data/${SMOKE_NS}/daemon" >/dev/null 2>&1; then
  echo "FAIL: daemon AppRole cannot read its own scoped secret" >&2
  exit 1
fi
echo "--- AppRole can read secrets/data/${SMOKE_NS}/daemon"

if vault_exec_token "${DAEMON_TOKEN}" kv put \
  "secrets/${SMOKE_NS}/daemon" admin_token_hash=denied >/dev/null 2>&1; then
  echo "FAIL: AppRole policy allowed a write to its scoped path" >&2
  exit 1
fi
echo "--- AppRole write denied"

# The decoy secret at secrets/data/other/secret EXISTS (seeded above), so a
# denied read here must be a genuine permission-denied (HTTP 403), not a
# vacuous 404. Vault's CLI prints the error to stderr and exits non-zero;
# grep for the "permission denied" marker.
set +e
denied_out="$(vault_exec_token "${DAEMON_TOKEN}" read \
  "secrets/data/other/secret" 2>&1)"
denied_rc=$?
set -e
if [ "${denied_rc}" -eq 0 ]; then
  echo "FAIL: AppRole policy allowed reading outside the scoped path" >&2
  exit 1
fi
if ! printf '%s' "${denied_out}" | grep -qi "permission denied"; then
  echo "FAIL: expected 'permission denied' reading outside scope, got:" >&2
  echo "${denied_out}" >&2
  exit 1
fi
echo "--- AppRole read outside scope denied (permission denied, 403)"

# --- UI check -------------------------------------------------------------------
UI_URL="http://localhost:${HD_UI_HOST_PORT}"
ui_code="$(curl -s -o /dev/null -w '%{http_code}' "${UI_URL}/")"
if [ "${ui_code}" != "200" ]; then
  echo "FAIL: UI at ${UI_URL} returned ${ui_code} (expected 200)" >&2
  exit 1
fi
echo "--- UI serving at ${UI_URL}"

echo ""
echo "=== honey-starter smoke passed ==="

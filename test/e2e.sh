#!/usr/bin/env bash
# e2e.sh — end-to-end test of the honey-starter SINGLE-COMMAND bring-up.
#
# This is the end-to-end E2E gate. Unlike the smoke test (which re-implements
# the provisioning sequence inline to test the *deployment*), the E2E test
# boots the stack through the real `scripts/start.sh` path into a throwaway
# compose project (COMPOSE_PROJECT_NAME=honey-starter-e2e-$$, HD_STATE_DIR in
# a mktemp dir, high host ports), then verifies the full trust chain:
#
#   1. vault is initialized + unsealed (start.sh only returns success once the
#      daemon /healthz answers 200, which itself proves the AppRole identity
#      files were readable and every Vault LOOKUP resolved at StageDiscovering).
#   2. KV v2 at secrets/ + AppRole auth are enabled.
#   3. the daemon-read policy + AppRole role are scoped EXACTLY to
#      secrets/data/<ns>/daemon (role token_policies=daemon-read).
#   4. identity files are present and non-empty in HD_STATE_DIR/identity/.
#   5. /healthz is 200 (all services healthy, all Vault LOOKUPs resolved).
#   6. an admin bearer token (read back from HD_STATE_DIR/admin_token, bcrypt
#      hash stored in Vault) authenticates (GET /api/user/profile -> 200).
#   7. anonymous access is denied.
#   8. AppRole can read its scoped path; a write to it is denied; reading a
#      DECOY secret outside the scope is a genuine permission-denied (403),
#      not a vacuous 404.
#   9. the UI serves HTTP 200 through the published port.
#
# Requires: docker (compose v2), network, curl, jq, openssl, htpasswd.
# Skips gracefully (exit 0) when docker is unavailable.
#
# Run: bash test/e2e.sh   (or: make e2e)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Throwaway namespace/user for the E2E project.
: "${E2E_NS:=e2e}"
: "${E2E_USER:=e2eadmin}"

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

# Read a state file, falling back to sudo when it is root-owned: start.sh
# chowns the AppRole identity files to root:0 with chmod 600 whenever it can
# act as root (see deploy/README.md "Identity-file hygiene"), so a non-root
# test user must read them through sudo.
e2e_read() {
  local f="$1"
  if [ -r "$f" ]; then
    cat "$f"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo -n cat "$f" 2>/dev/null && return 0
    sudo cat "$f" 2>/dev/null && return 0
  fi
  return 1
}

# Unique throwaway compose project + state dir + high host ports (distinct
# from the smoke's 19000/19080). Everything below is exported so the start.sh
# subprocess (which sources scripts/lib.sh itself) sees the same hermetic,
# throwaway configuration.
PROJECT="honey-starter-e2e-$$"
export COMPOSE_PROJECT_NAME="${PROJECT}"
export HONEY_STARTER_NO_ENV=1
export HONEY_NS="${E2E_NS}"
export HONEY_USER="${E2E_USER}"
STATE="$(mktemp -d)"
export HD_STATE_DIR="${STATE}"
export HD_API_HOST_PORT="${HD_API_HOST_PORT:-19500}"
export HD_UI_HOST_PORT="${HD_UI_HOST_PORT:-19580}"
export HD_UI_URL="http://localhost:${HD_UI_HOST_PORT}"
# Keep the daemon's config-check interval longer than the whole E2E run (a
# local-dir init repo reloads unconditionally every tick; 30m bounds the
# AppRole churn — see deploy/README.md "Config reload behavior").
export HD_CONFIG_CHECK_INTERVAL="${HD_CONFIG_CHECK_INTERVAL:-30m}"
# Real-looking AI keys so the daemon's LOOKUPs resolve to non-empty strings
# (the engine api_key fields are Vault LOOKUPs; any non-empty value resolves).
export OPENAI_API_KEY="sk-e2e-openai"
export OPENROUTER_API_KEY="sk-e2e-openrouter"

# shellcheck source=../scripts/lib.sh
source "${HERE}/scripts/lib.sh"

COMPOSE=(docker compose -f "${COMPOSE_FILE}")

cleanup() {
  set +e
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1
  rm -rf "${STATE}"
}
trap cleanup EXIT

echo "=== honey-starter e2e: compose project ${PROJECT} ==="

# --- single-command bring-up through the REAL start.sh path ------------------
echo "--- running scripts/start.sh (single-command bring-up)"
START_LOG="${STATE}/start.log"
if ! bash "${HERE}/scripts/start.sh" >"${START_LOG}" 2>&1; then
  echo "FAIL: scripts/start.sh exited non-zero" >&2
  echo "--- start.sh log (tail) ---" >&2
  tail -n 120 "${START_LOG}" >&2 || true
  exit 1
fi
echo "--- start.sh completed successfully"

# --- idempotent re-run: start.sh must converge without regenerating secrets --
# Core single-command requirement: re-runs must not re-init Vault, and must not
# regenerate/overwrite the admin token or API keys. Capture the state files,
# re-run start.sh, and assert nothing that must stay stable changed. (Vault's
# init/unseal state is asserted separately below.)
ADMIN_TOKEN_BEFORE="$(e2e_read "${STATE}/admin_token")"
ROLE_ID_FILE_BEFORE="$(e2e_read "${STATE}/identity/role_id")"
SECRET_ID_FILE_BEFORE="$(e2e_read "${STATE}/identity/secret_id")"
if ! bash "${HERE}/scripts/start.sh" >"${START_LOG}" 2>&1; then
  echo "FAIL: scripts/start.sh re-run exited non-zero (must be idempotent)" >&2
  echo "--- start.sh re-run log (tail) ---" >&2
  tail -n 120 "${START_LOG}" >&2 || true
  exit 1
fi
ADMIN_TOKEN_AFTER="$(e2e_read "${STATE}/admin_token")"
if [ "${ADMIN_TOKEN_BEFORE}" != "${ADMIN_TOKEN_AFTER}" ]; then
  echo "FAIL: start.sh re-run regenerated the admin token (idempotency broken)" >&2
  exit 1
fi
if [ "$(e2e_read "${STATE}/identity/role_id")" != "${ROLE_ID_FILE_BEFORE}" ] \
  || [ "$(e2e_read "${STATE}/identity/secret_id")" != "${SECRET_ID_FILE_BEFORE}" ]; then
  echo "FAIL: start.sh re-run regenerated the AppRole identity pair (idempotency broken)" >&2
  exit 1
fi
echo "--- start.sh idempotent re-run converged (admin token + identity pair unchanged)"

# --- root token + admin token from the state dir (host-only, chmod 600) ------
# start.sh ran in a subprocess as the same user, so these are readable.
ROOT_TOKEN="$(e2e_read "${STATE}/root_token")"
[ -n "${ROOT_TOKEN}" ] || { echo "FAIL: empty root_token in ${STATE}" >&2; exit 1; }
ADMIN_TOKEN="$(e2e_read "${STATE}/admin_token")"
[ -n "${ADMIN_TOKEN}" ] || { echo "FAIL: empty admin_token in ${STATE}" >&2; exit 1; }

echo "--- state files present: root_token, unseal_key, admin_token, identity/*"

# --- 1. vault initialized + unsealed ------------------------------------------
if ! vault_exec status -format=json | jq -e '.initialized == true and .sealed == false' >/dev/null; then
  echo "FAIL: vault not initialized+unsealed after start.sh" >&2
  exit 1
fi
echo "--- vault initialized and unsealed"

# --- 2. KV v2 + AppRole enabled ------------------------------------------------
if ! vault_exec_token "${ROOT_TOKEN}" secrets list -format=json \
  | jq -e 'has("secrets/")' >/dev/null 2>&1; then
  echo "FAIL: KV v2 not enabled at secrets/" >&2
  exit 1
fi
if ! vault_exec_token "${ROOT_TOKEN}" auth list -format=json \
  | jq -e 'has("approle/")' >/dev/null 2>&1; then
  echo "FAIL: AppRole auth not enabled" >&2
  exit 1
fi
echo "--- KV v2 at secrets/ + AppRole auth enabled"

# --- 3. policy + role scoped exactly -------------------------------------------
policy_text="$(vault_exec_token "${ROOT_TOKEN}" policy read daemon-read)"
expected_line="path \"secrets/data/${E2E_NS}/daemon\" {"
if ! printf '%s' "${policy_text}" | grep -Fq "${expected_line}"; then
  echo "FAIL: daemon-read policy does not scope to ${expected_line}" >&2
  echo "${policy_text}" >&2
  exit 1
fi
role_json="$(vault_exec_token "${ROOT_TOKEN}" read -format=json auth/approle/role/daemon)"
if ! printf '%s' "${role_json}" | jq -e --arg p daemon-read \
  '.data.token_policies | index($p) != null' >/dev/null; then
  echo "FAIL: AppRole role daemon does not carry token_policies=daemon-read" >&2
  printf '%s' "${role_json}" >&2
  exit 1
fi
echo "--- daemon-read policy scoped to secrets/data/${E2E_NS}/daemon; role token_policies=daemon-read"

# --- 4. identity files present + non-empty -------------------------------------
if [ ! -s "${STATE}/identity/role_id" ] || [ ! -s "${STATE}/identity/secret_id" ]; then
  echo "FAIL: identity files missing or empty in ${STATE}/identity" >&2
  ls -la "${STATE}/identity" >&2 || true
  exit 1
fi
echo "--- AppRole identity files present and non-empty"

# --- 5. daemon /healthz 200 (start.sh waited for it; re-verify cheaply) --------
API_URL="http://localhost:${HD_API_HOST_PORT}"
http_code="$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}/healthz")"
if [ "${http_code}" != "200" ]; then
  echo "FAIL: daemon /healthz returned ${http_code} (expected 200)" >&2
  exit 1
fi
echo "--- daemon /healthz 200 (all Vault LOOKUPs resolved via AppRole identity files)"

# --- 6/7. admin bearer auth + anonymous denial ---------------------------------
auth_code="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" "${API_URL}/api/user/profile")"
if [ "${auth_code}" != "200" ]; then
  echo "FAIL: authenticated GET /api/user/profile returned ${auth_code} (expected 200)" >&2
  exit 1
fi
echo "--- admin bearer token authenticates (bcrypt hash in Vault verified)"

anon_code="$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}/api/user/profile")"
if [ "${anon_code}" = "200" ]; then
  echo "FAIL: anonymous GET /api/user/profile returned 200 (expected 401/403)" >&2
  exit 1
fi
echo "--- anonymous API call denied (${anon_code})"

# --- 8. AppRole policy behavior (read-ok / write-denied / out-of-scope 403) -----
# Use a fresh secret-id generated from the role (secret_id_ttl=0, so generated
# secret ids never expire — the same role the daemon's identity pair belongs
# to). role_id is not a secret; read it from Vault.
ROLE_ID="$(vault_exec_token "${ROOT_TOKEN}" read -field=role_id \
  auth/approle/role/daemon/role-id)"
# AppRole secret-id write takes no data: -force is required (see smoke).
SECRET_ID="$(vault_exec_token "${ROOT_TOKEN}" write -force -field=secret_id \
  auth/approle/role/daemon/secret-id)"
# AppRole login returns an auth response; -field is "token" (see smoke).
DAEMON_TOKEN="$(vault_exec_token "${ROOT_TOKEN}" write -field=token \
  auth/approle/login role_id="${ROLE_ID}" secret_id="${SECRET_ID}")"

if ! vault_exec_token "${DAEMON_TOKEN}" read "secrets/data/${E2E_NS}/daemon" >/dev/null 2>&1; then
  echo "FAIL: AppRole cannot read its own scoped secret" >&2
  exit 1
fi
echo "--- AppRole can read secrets/data/${E2E_NS}/daemon"

if vault_exec_token "${DAEMON_TOKEN}" kv put "secrets/${E2E_NS}/daemon" \
  admin_token_hash=denied >/dev/null 2>&1; then
  echo "FAIL: AppRole policy allowed a write to its scoped path" >&2
  exit 1
fi
echo "--- AppRole write denied"

# Decoy secret OUTSIDE the AppRole scope. The path must exist so a denied read
# is a genuine permission-denied (403), not a vacuous 404.
vault_exec_token "${ROOT_TOKEN}" kv put secrets/other/secret decoy=value >/dev/null
set +e
denied_out="$(vault_exec_token "${DAEMON_TOKEN}" read "secrets/data/other/secret" 2>&1)"
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
echo "--- AppRole read outside scope denied (permission denied, 403; decoy path exists)"

# --- 9. UI 200 -------------------------------------------------------------------
UI_URL="http://localhost:${HD_UI_HOST_PORT}"
ui_code="$(curl -s -o /dev/null -w '%{http_code}' "${UI_URL}/")"
if [ "${ui_code}" != "200" ]; then
  echo "FAIL: UI at ${UI_URL} returned ${ui_code} (expected 200)" >&2
  exit 1
fi
echo "--- UI serving at ${UI_URL}"

echo ""
echo "=== honey-starter e2e passed ==="

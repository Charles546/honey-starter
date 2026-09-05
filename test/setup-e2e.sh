#!/usr/bin/env bash
# setup-e2e.sh — end-to-end test of the GUIDED INSTALLER path (scripts/setup.sh).
#
# This is the docker-gated E2E gate for Phase 4. Unlike test/e2e.sh (which
# boots the stack through scripts/start.sh directly), this gate drives the
# real single-command *installer*: it copies the tree under test into a
# throwaway mktemp dir, then runs THAT copy's scripts/setup.sh
# (HONEY_STARTER_NONINTERACTIVE=1 + HONEY_STARTER_ASSUME_YES=1, answers via
# the environment) into a throwaway compose project
# (COMPOSE_PROJECT_NAME=honey-starter-setup-e2e-$$), a second mktemp
# HD_STATE_DIR, and high host ports. setup.sh writes the repo-root .env
# (chmod 600) and delegates to scripts/start.sh — so the whole
# write-.env -> start.sh -> Vault init/unseal/seed -> daemon+ui bring-up chain
# is exercised end to end.
#
# Assertions:
#   1. .env is written into the copied tree with chmod 600.
#   2. Vault is initialized + unsealed; KV v2 at secrets/ + AppRole enabled.
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
#  10. a SECOND setup.sh run converges: the .env rewrite is idempotent, and
#      the admin token + AppRole identity pair + the seeded KV `.data`
#      (canonical object incl. metadata.version) are unchanged — re-running
#      the installer never regenerates secrets (start.sh's guarantee, reused
#      via the canonical-`.data` comparison from e2e.sh). The second run uses
#      the Phase 5 positional in-place form (`cd "${COPY}" && bash
#      scripts/setup.sh .`), proving manage-existing end to end.
#
# Requires: docker (compose v2), network, curl, jq, openssl, htpasswd.
# Skips gracefully (exit 0) when docker is unavailable.
#
# Run: bash test/setup-e2e.sh   (or: make setup-e2e)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Throwaway namespace/user for the setup-e2e project.
: "${SETUPE2E_NS:=se2e}"
: "${SETUPE2E_USER:=seadmin}"

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

# Unique throwaway compose project + state dir + tree copy + high host ports
# (distinct from smoke's 19000/19080 and e2e's 19500/19580). Everything below
# is exported so the setup.sh subprocess (which delegates to scripts/start.sh,
# which sources scripts/lib.sh itself) sees the same hermetic throwaway
# configuration.
PROJECT="honey-starter-setup-e2e-$$"
export COMPOSE_PROJECT_NAME="${PROJECT}"
export HONEY_STARTER_NO_ENV=1
export HONEY_NS="${SETUPE2E_NS}"
export HONEY_USER="${SETUPE2E_USER}"
export HONEY_STARTER_NONINTERACTIVE=1
export HONEY_STARTER_ASSUME_YES=1
export HONEY_AI_PROVIDER=openai
STATE="$(mktemp -d)"
export HD_STATE_DIR="${STATE}"
export HD_API_HOST_PORT="${HD_API_HOST_PORT:-19600}"
export HD_UI_HOST_PORT="${HD_UI_HOST_PORT:-19680}"
export HD_UI_URL="http://localhost:${HD_UI_HOST_PORT}"
# Keep the daemon's config-check interval longer than the whole run (a
# local-dir init repo reloads unconditionally every tick; 30m bounds the
# AppRole churn — see deploy/README.md "Config reload behavior").
export HD_CONFIG_CHECK_INTERVAL="${HD_CONFIG_CHECK_INTERVAL:-30m}"
# Real-looking AI keys so the daemon's LOOKUPs resolve to non-empty strings
# (the engine api_key fields are Vault LOOKUPs; any non-empty value resolves).
export OPENAI_API_KEY="sk-setup-e2e-openai"
export OPENROUTER_API_KEY="sk-setup-e2e-openrouter"

# Throwaway copy of the tree under test. setup.sh is executed from THIS copy
# (never the dev checkout), so the .env it writes cannot touch the repo.
WORK="$(mktemp -d)"
COPY="${WORK}/tree"
mkdir -p "${COPY}"
cp -a "${HERE}/." "${COPY}/"
rm -rf "${COPY}/.git" "${COPY}/.honey-starter" "${COPY}/.env"
# Phase 5: HONEY_STARTER_INSTALL_DIR is branch-3-only (standalone/piped). An
# on-disk run never consults it — the invoked copy detects the instance it is
# inside via detect_mode/SCRIPT_TREE, so both the first run and the positional
# re-run below land on the COPY tree without any install-dir env.
SETUP="${COPY}/scripts/setup.sh"

# Source lib.sh from the COPY (the tree under test), not the dev checkout, so
# the harness's COMPOSE_FILE / COMPOSE_PROJECT_NAME and vault_exec helpers use
# the exact lib.sh + compose file setup.sh delegates to — full end-to-end.
export COMPOSE_FILE="${COPY}/deploy/docker-compose.yaml"
# shellcheck source=../scripts/lib.sh
source "${COPY}/scripts/lib.sh"

COMPOSE=(docker compose -f "${COMPOSE_FILE}")

cleanup() {
  set +e
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1
  rm -rf "${STATE}" "${WORK}"
}
trap cleanup EXIT

echo "=== honey-starter setup-e2e: compose project ${PROJECT} ==="

# --- single-command installer run (setup.sh -> writes .env -> delegates to
# --- scripts/start.sh -> full bring-up) -------------------------------------
echo "--- running scripts/setup.sh (guided installer, non-interactive)"
START_LOG="${STATE}/setup.log"
if ! bash "${SETUP}" >"${START_LOG}" 2>&1; then
  echo "FAIL: scripts/setup.sh exited non-zero" >&2
  echo "--- setup.sh log (tail) ---" >&2
  tail -n 120 "${START_LOG}" >&2 || true
  exit 1
fi
echo "--- setup.sh completed successfully"

# --- 0. .env written into the copied tree, chmod 600 ------------------------
if [ ! -f "${COPY}/.env" ]; then
  echo "FAIL: setup.sh did not write ${COPY}/.env" >&2
  exit 1
fi
MODE="$(stat -c '%a' "${COPY}/.env")"
if [ "${MODE}" != "600" ]; then
  echo "FAIL: .env mode ${MODE} (expected 600)" >&2
  exit 1
fi
echo "--- .env written (chmod 600) into the copied tree"
if grep -q "^HONEY_NS=${SETUPE2E_NS}$" "${COPY}/.env" \
  && grep -q "^HONEY_USER=${SETUPE2E_USER}$" "${COPY}/.env" \
  && grep -q "^HD_API_HOST_PORT=${HD_API_HOST_PORT}$" "${COPY}/.env" \
  && grep -q "^HD_UI_HOST_PORT=${HD_UI_HOST_PORT}$" "${COPY}/.env"; then
  echo "--- .env managed values match the requested configuration"
else
  echo "FAIL: .env managed values mismatch:" >&2
  sed 's/^/    | /' "${COPY}/.env" >&2
  exit 1
fi

# --- root token + admin token from the state dir (host-only, chmod 600) ------
ROOT_TOKEN="$(e2e_read "${STATE}/root_token")"
[ -n "${ROOT_TOKEN}" ] || { echo "FAIL: empty root_token in ${STATE}" >&2; exit 1; }
ADMIN_TOKEN="$(e2e_read "${STATE}/admin_token")"
[ -n "${ADMIN_TOKEN}" ] || { echo "FAIL: empty admin_token in ${STATE}" >&2; exit 1; }
echo "--- state files present: root_token, unseal_key, admin_token, identity/*"

# --- idempotent re-run: a SECOND setup.sh run must converge without churn ----
# Core single-command requirement: re-running the installer must not re-init
# Vault and must not regenerate/overwrite the admin token, the AppRole pair or
# the seeded KV payload. Capture state + the canonical `.data` object, re-run
# setup.sh (which rewrites .env + delegates to start.sh again), and assert
# everything that must stay stable is unchanged. (The canonical `.data`
# comparison — field values + KV metadata incl. metadata.version, not the
# per-request response envelope — is the same idempotency check e2e.sh uses.)
SEED_PATH="secrets/${SETUPE2E_NS}/daemon"
ADMIN_TOKEN_BEFORE="$(e2e_read "${STATE}/admin_token")"
ROLE_ID_FILE_BEFORE="$(e2e_read "${STATE}/identity/role_id")"
SECRET_ID_FILE_BEFORE="$(e2e_read "${STATE}/identity/secret_id")"
SEED_KV_BEFORE="$(vault_exec_token "${ROOT_TOKEN}" kv get -format=json "${SEED_PATH}" 2>/dev/null | jq -cS '.data' 2>/dev/null || true)"
# Phase 5: the idempotent second run exercises the positional in-place path —
# `cd "${COPY}" && bash scripts/setup.sh .` (branch 1 positional resolving to
# the tree itself -> pure in-place manage: .env rewrite + delegate to start.sh
# + no secret/seed churn). Proves the full-stack manage-existing path E2E.
if ! ( cd "${COPY}" && bash scripts/setup.sh . ) >"${START_LOG}" 2>&1; then
  echo "FAIL: scripts/setup.sh re-run exited non-zero (must be idempotent)" >&2
  echo "--- setup.sh re-run log (tail) ---" >&2
  tail -n 120 "${START_LOG}" >&2 || true
  exit 1
fi
ADMIN_TOKEN_AFTER="$(e2e_read "${STATE}/admin_token")"
if [ "${ADMIN_TOKEN_BEFORE}" != "${ADMIN_TOKEN_AFTER}" ]; then
  echo "FAIL: setup.sh re-run regenerated the admin token (idempotency broken)" >&2
  exit 1
fi
if [ "$(e2e_read "${STATE}/identity/role_id")" != "${ROLE_ID_FILE_BEFORE}" ] \
  || [ "$(e2e_read "${STATE}/identity/secret_id")" != "${SECRET_ID_FILE_BEFORE}" ]; then
  echo "FAIL: setup.sh re-run regenerated the AppRole identity pair (idempotency broken)" >&2
  exit 1
fi
SEED_KV_AFTER="$(vault_exec_token "${ROOT_TOKEN}" kv get -format=json "${SEED_PATH}" 2>/dev/null | jq -cS '.data' 2>/dev/null || true)"
if [ -n "${SEED_KV_BEFORE}" ] && [ "${SEED_KV_BEFORE}" != "${SEED_KV_AFTER}" ]; then
  echo "FAIL: setup.sh re-run rewrote the seeded KV payload at ${SEED_PATH} (idempotency broken)" >&2
  exit 1
fi
echo "--- setup.sh idempotent re-run converged (admin token + identity pair + seeded KV data/metadata unchanged)"

# --- 1. vault initialized + unsealed ------------------------------------------
if ! vault_exec status -format=json | jq -e '.initialized == true and .sealed == false' >/dev/null; then
  echo "FAIL: vault not initialized+unsealed after setup.sh" >&2
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
expected_line="path \"secrets/data/${SETUPE2E_NS}/daemon\" {"
if ! printf '%s' "${policy_text}" | grep -Fq "${expected_line}"; then
  echo "FAIL: daemon-read policy does not scope to ${expected_line}" >&2
  printf '%s\n' "${policy_text}" >&2
  exit 1
fi
role_json="$(vault_exec_token "${ROOT_TOKEN}" read -format=json auth/approle/role/daemon)"
if ! printf '%s' "${role_json}" | jq -e --arg p daemon-read \
  '.data.token_policies | index($p) != null' >/dev/null; then
  echo "FAIL: AppRole role daemon does not carry token_policies=daemon-read" >&2
  printf '%s' "${role_json}" >&2
  exit 1
fi
echo "--- daemon-read policy scoped to secrets/data/${SETUPE2E_NS}/daemon; role token_policies=daemon-read"

# --- 4. identity files present + non-empty --------------------------------------
if [ ! -s "${STATE}/identity/role_id" ] || [ ! -s "${STATE}/identity/secret_id" ]; then
  echo "FAIL: identity files missing or empty in ${STATE}/identity" >&2
  ls -la "${STATE}/identity" >&2 || true
  exit 1
fi
echo "--- AppRole identity files present and non-empty"

# --- 5. daemon /healthz 200 (setup.sh/start.sh waited for it; re-verify) -------
API_URL="http://localhost:${HD_API_HOST_PORT}"
http_code="$(curl -s -o /dev/null -w '%{http_code}' "${API_URL}/healthz")"
if [ "${http_code}" != "200" ]; then
  echo "FAIL: daemon /healthz returned ${http_code} (expected 200)" >&2
  exit 1
fi
echo "--- daemon /healthz 200 (all Vault LOOKUPs resolved via AppRole identity files)"

# --- 6/7. admin bearer auth + anonymous denial -----------------------------------
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
ROLE_ID="$(vault_exec_token "${ROOT_TOKEN}" read -field=role_id \
  auth/approle/role/daemon/role-id)"
# AppRole secret-id write takes no data: -force is required (see smoke).
SECRET_ID="$(vault_exec_token "${ROOT_TOKEN}" write -force -field=secret_id \
  auth/approle/role/daemon/secret-id)"
# AppRole login returns an auth response; -field is "token" (see smoke).
DAEMON_TOKEN="$(vault_exec_token "${ROOT_TOKEN}" write -field=token \
  auth/approle/login role_id="${ROLE_ID}" secret_id="${SECRET_ID}")"

if ! vault_exec_token "${DAEMON_TOKEN}" read "secrets/data/${SETUPE2E_NS}/daemon" >/dev/null 2>&1; then
  echo "FAIL: AppRole cannot read its own scoped secret" >&2
  exit 1
fi
echo "--- AppRole can read secrets/data/${SETUPE2E_NS}/daemon"

if vault_exec_token "${DAEMON_TOKEN}" kv put "secrets/${SETUPE2E_NS}/daemon" \
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
  printf '%s\n' "${denied_out}" >&2
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
echo "=== honey-starter setup-e2e passed ==="

#!/usr/bin/env bash
# start.sh — single-command bring-up for a honey-starter deployment.
#
# Brings up the full stack on a Linux docker host with one command:
#
#   valkey  (Redis-compatible event bus)
#   vault   (file-backed, non-dev; initialized + unsealed + seeded by this script)
#   daemon  (honeydipper; AppRole credentials via identity bind-mount)
#   ui      (honeydipper hd-ui)
#
# The script is idempotent and safe to re-run:
#   * vault is initialized and unsealed ONLY when needed (state is detected
#     from the vault server itself, and root token + unseal key(s) are
#     persisted to ${HD_STATE_DIR} with chmod 600).
#   * KV v2 / AppRole / the daemon-read policy / the AppRole role are enabled
#     or created only when missing (policy + role are idempotent writes).
#   * the admin token and AI API keys are generated/seeded once and never
#     clobbered on re-run (admin token is persisted plaintext at
#     ${HD_STATE_DIR}/admin_token with chmod 600 and printed once; AI keys are
#     only (re)written when you explicitly set OPENAI_API_KEY /
#     OPENROUTER_API_KEY and re-run).
#
# Secret lifecycle (see README.md / deploy/README.md "Vault"):
#   * ALL operational secrets live in Vault at secrets/data/<ns>/daemon
#     (admin_token_hash, openai_api_key, openrouter_api_key).
#   * The ONLY secret material outside Vault is:
#       (a) root token + unseal key(s) in ${HD_STATE_DIR} (chmod 600, host
#           only, never mounted into any container), and
#       (b) the AppRole identity pair (role_id/secret_id) in
#           ${HD_STATE_DIR}/identity/, mounted read-only into the daemon.
#   * VAULT_TOKEN is NEVER set in the daemon container; no AI keys appear in
#     env/config/compose.
#
# All vault administration runs through `docker compose exec vault vault ...`
# (vault_exec / vault_exec_token in scripts/lib.sh): vault publishes no host
# port and is unreachable from the host by network design. No local vault or
# honeydipper binary is required.
#
# Run: bash scripts/start.sh   (or: make start)
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

echo "=== honey-starter: start ==="

# --- Linux-only guard -------------------------------------------------------
# The cap_drop/CAP_DAC_OVERRIDE file-permission model and the bind-mount
# layout below are Linux-specific (see deploy/README.md "Hardening notes").
if [ "$(uname -s)" != "Linux" ]; then
  die "honey-starter runs on Linux only (docker bind mounts + the root-without-caps file-permission model). Detected: $(uname -s)"
fi

# --- required tools ---------------------------------------------------------
require_cmd docker
if ! docker compose version >/dev/null 2>&1; then
  die "docker compose v2 is required (docker compose version failed)"
fi
for cmd in curl jq openssl htpasswd; do
  require_cmd "${cmd}"
done
if ! docker info >/dev/null 2>&1; then
  die "docker daemon is not reachable (docker info failed). Start docker and re-run."
fi

echo "  [ok] Linux $(uname -r)"
echo "  [ok] docker compose v2"
for cmd in docker curl jq openssl htpasswd; do
  echo "  [ok] ${cmd}"
done

# --- tunables with defaults ------------------------------------------------
# <ns>: Vault KV namespace prefix. MUST be a single Vault path segment and MUST
# stay constant for the life of a deployment (changing it after first run would
# point the daemon's LOOKUP paths at an unseeded path).
# <user>: the admin subject (casbin editor binding).
: "${HONEY_NS:=starter}"
: "${HONEY_USER:=admin}"
: "${HONEY_VAULT_KEY_SHARES:=1}"
: "${HONEY_VAULT_KEY_THRESHOLD:=1}"

case "${HONEY_NS}" in
  ''|*/*|*[!A-Za-z0-9._-]*)
    die "HONEY_NS must be a single Vault path segment ([A-Za-z0-9._-]+), got: ${HONEY_NS}"
    ;;
esac
case "${HONEY_USER}" in
  ''|*/*|*[!A-Za-z0-9@._-]*)
    die "HONEY_USER must be a plain subject token ([A-Za-z0-9@._-]+), got: ${HONEY_USER}"
    ;;
esac
if ! [ "${HONEY_VAULT_KEY_THRESHOLD:-1}" -ge 1 ] 2>/dev/null \
  || ! [ "${HONEY_VAULT_KEY_SHARES:-1}" -ge "${HONEY_VAULT_KEY_THRESHOLD:-1}" ] 2>/dev/null; then
  die "HONEY_VAULT_KEY_SHARES must be >= HONEY_VAULT_KEY_THRESHOLD >= 1"
fi
export HONEY_NS HONEY_USER

# --- state directory --------------------------------------------------------
# HD_STATE_DIR defaults to <repo>/.honey-starter. Compose anchors relative
# host paths at deploy/, so we always resolve it to an absolute path before
# exporting it: that guarantees the script and the compose bind mounts address
# the same directory. A relative HD_STATE_DIR is anchored at the repo root
# (HONEY_STARTER_DIR) so `make start` produces the same state dir regardless
# of the caller's cwd. (An ABSOLUTE path is recommended — see .env.example.)
if [ -z "${HD_STATE_DIR:-}" ]; then
  HD_STATE_DIR="${HONEY_STARTER_DIR}/.honey-starter"
else
  case "${HD_STATE_DIR}" in
    /*) ;;
    *) HD_STATE_DIR="${HONEY_STARTER_DIR}/${HD_STATE_DIR}" ;;
  esac
fi
export HD_STATE_DIR

STATE_DIR="${HD_STATE_DIR}"
CONFIG_DIR="${STATE_DIR}/config"
IDENTITY_DIR="${STATE_DIR}/identity"
ADMIN_TOKEN_FILE="${STATE_DIR}/admin_token"
ROOT_TOKEN_FILE="${STATE_DIR}/root_token"
UNSEAL_KEY_FILE="${STATE_DIR}/unseal_key"
PROVISION_FILE="${STATE_DIR}/provision.env"

mkdir -p "${CONFIG_DIR}" "${IDENTITY_DIR}"
# ".honey-starter/" is "the kingdom": it holds the rendered config, the
# AppRole identity pair and (during bring-up) the root token + unseal key.
chmod 700 "${STATE_DIR}" 2>/dev/null || true
# The daemon container runs root-without-caps (cap_drop: [ALL]) and cannot
# bypass file permissions, so the bind-mounted config/identity dirs must be
# traversable/readable by it regardless of host umask (see guard in
# deploy/README.md "Hardening notes"): dirs 755, config files world-readable.
chmod 755 "${CONFIG_DIR}" "${IDENTITY_DIR}" 2>/dev/null || true

echo "--- state dir: ${STATE_DIR}"

# --- root/sudo capability for identity-file hygiene --------------------------
# Identity files must be readable by the daemon's root-without-caps process:
#   0600 + chown 0:0 when we can act as root (root, or sudo), else 0644.
CAN_ROOT=0
if [ "$(id -u)" -eq 0 ]; then
  CAN_ROOT=1
elif command -v sudo >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    CAN_ROOT=1
  elif [ -t 1 ]; then
    # interactive terminal: allow a password prompt for sudo
    if sudo true >/dev/null 2>&1; then
      CAN_ROOT=1
    fi
  fi
fi

# Read a state file, falling back to sudo when the file is root-owned and we
# are not root.
file_read() {
  local f="$1"
  if [ -r "$f" ]; then
    cat "$f"
    return 0
  fi
  if [ "$CAN_ROOT" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    sudo -n cat "$f" 2>/dev/null && return 0
    sudo cat "$f" 2>/dev/null && return 0
  fi
  return 1
}

# Write an AppRole identity file. Prefer 0600 + root-owned (readable by the
# daemon's root-without-caps and by nobody else); fall back to 0644 when we
# cannot act as root (see deploy/README.md "Identity-file hygiene").
write_identity_file() {
  local file="$1"
  local value="$2"
  if [ "$CAN_ROOT" -eq 1 ]; then
    if [ "$(id -u)" -eq 0 ]; then
      printf '%s' "${value}" > "${file}"
      chown 0:0 "${file}" 2>/dev/null || true
      chmod 600 "${file}"
    else
      printf '%s' "${value}" | sudo tee "${file}" >/dev/null
      sudo chown 0:0 "${file}" >/dev/null 2>&1 || true
      sudo chmod 600 "${file}"
    fi
  else
    printf '%s' "${value}" > "${file}"
    chmod 644 "${file}"
    echo "NOTE: cannot act as root (no root/sudo); ${file} is 0644. The AppRole pair is scoped to read one Vault path only (never the root token)."
  fi
}

# --- namespace/user persistence ---------------------------------------------
# <ns>/<user> are baked into both the rendered config and the Vault seeding.
# Changing them after the first run would desync the daemon's LOOKUP paths from
# the seeded secrets, so we persist the values used on first run and refuse to
# proceed on a mismatch.
# Read the persisted <ns>/<user> values if the deployment was already
# provisioned. They are only written AFTER a successful first provisioning
# (see below), so a failed first run does not strand the namespace.
if [ -f "${PROVISION_FILE}" ]; then
  PROVISION_CONTENT="$(file_read "${PROVISION_FILE}")" \
    || die "cannot read ${PROVISION_FILE}; re-run start.sh as its owner or with sudo (or reset the deployment)"
  PROVISION_NS="$(printf '%s\n' "${PROVISION_CONTENT}" | sed -n 's/^PROVISION_NS=//p')"
  PROVISION_USER="$(printf '%s\n' "${PROVISION_CONTENT}" | sed -n 's/^PROVISION_USER=//p')"
  if [ "${HONEY_NS}" != "${PROVISION_NS}" ] || [ "${HONEY_USER}" != "${PROVISION_USER}" ]; then
    die "HONEY_NS/HONEY_USER changed since first run (was ns=${PROVISION_NS} user=${PROVISION_USER}, now ns=${HONEY_NS} user=${HONEY_USER}). This would desync the daemon's Vault LOOKUP paths from the seeded secrets. Reset the deployment (rm -rf ${STATE_DIR} and, if you want to also wipe Vault data, 'make down-volumes') to start over."
  fi
fi

# --- render bootstrap config ------------------------------------------------
# Re-render from bootstrap/ on every run so bootstrap/ stays the single source
# of truth (edit bootstrap/, not the rendered copy). Compare against the
# existing rendered config; when unchanged we leave the mount untouched.
render_config() {
  local staging
  staging="${STATE_DIR}/.config.staging.$$"
  rm -rf "${staging}"
  mkdir -p "${staging}"
  cp -r "${BOOTSTRAP_DIR}/." "${staging}/"

  local f
  while IFS= read -r f; do
    sed -i "s/<ns>/${HONEY_NS}/g" "${f}"
  done < <(grep -rl '<ns>' "${staging}" 2>/dev/null || true)
  while IFS= read -r f; do
    sed -i "s/<user>/${HONEY_USER}/g" "${f}"
  done < <(grep -rl '<user>' "${staging}" 2>/dev/null || true)

  # normalize perms so the daemon's root-without-caps can read the mount
  chmod -R a+rX "${staging}"

  if [ -d "${CONFIG_DIR}" ] && diff -rq "${staging}" "${CONFIG_DIR}" >/dev/null 2>&1; then
    rm -rf "${staging}"
    CONFIG_CHANGED=0
    echo "--- rendered config unchanged (ns=${HONEY_NS} user=${HONEY_USER})"
  else
    # refresh in place (keep the CONFIG_DIR inode so a running daemon's bind
    # mount keeps working); a running daemon picks the change up on its next
    # config check tick or after `docker compose restart daemon`.
    find "${CONFIG_DIR}" -mindepth 1 -delete 2>/dev/null || true
    cp -r "${staging}/." "${CONFIG_DIR}/"
    rm -rf "${staging}"
    chmod -R a+rX "${CONFIG_DIR}"
    CONFIG_CHANGED=1
    echo "--- rendered config refreshed (ns=${HONEY_NS} user=${HONEY_USER})"
  fi

  # sanity: no placeholders may remain in the rendered config
  if grep -rEq '<ns>|<user>' "${CONFIG_DIR}" 2>/dev/null; then
    die "rendered config still contains <ns>/<user> placeholders"
  fi
}
CONFIG_CHANGED=0
render_config

# --- host port preflight (best-effort) ---------------------------------------
# Skip when our own daemon OR ui is already running: the published ports then
# belong (at least in part) to this stack, so probing them would raise a false
# conflict on a partially-running stack (e.g. only the ui survived a crash).
# Best-effort by design: uses curl against 127.0.0.1 so 127.0.0.1- and
# 0.0.0.0-bound HTTP listeners are caught without root; cannot catch
# non-HTTP listeners, IPv6-only binds or a firewall that drops the probe.
API_HOST_PORT="${HD_API_HOST_PORT:-9000}"
UI_HOST_PORT="${HD_UI_HOST_PORT:-8090}"
# Export the HD_* host-port vars so the `compose` subprocess (which reads
# ${HD_API_HOST_PORT}/${HD_UI_HOST_PORT} from its environment) always binds
# exactly what the preflight below checked. .env values are already exported
# by lib.sh (set -a); this guarantees an unexported shell var and a .env value
# agree too. (These are not secrets.)
export HD_API_HOST_PORT HD_UI_HOST_PORT

stack_running=false
daemon_was_running=false
# compose v2 `ps` lists stopped containers too, so filter to --status running.
if [ -n "$(compose ps --status running -q daemon ui 2>/dev/null)" ]; then
  stack_running=true
fi
if [ -n "$(compose ps --status running -q daemon 2>/dev/null)" ]; then
  daemon_was_running=true
fi

if [ "${stack_running}" = "false" ]; then
  port_preflight() {
    local port="$1"
    local what="$2"
    if curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:${port}/" 2>/dev/null; then
      die "${what} host port ${port} is already in use; set HD_API_HOST_PORT/HD_UI_HOST_PORT to free ports"
    fi
    echo "  [ok] host port ${port} free (${what})"
  }
  echo "--- host port preflight"
  port_preflight "${API_HOST_PORT}" "daemon API"
  port_preflight "${UI_HOST_PORT}" "UI"
else
  echo "--- a daemon/ui container is already running; skipping host port preflight"
fi

# --- start infrastructure -----------------------------------------------------
echo "--- starting valkey + vault"
compose up -d valkey vault

echo "--- waiting for vault API"
vault_out=""
for ((i = 0; i < 90; i++)); do
  set +e
  vault_out="$(vault_exec status 2>&1)"
  rc=$?
  set -e
  # A fresh (uninitialized) server answers exit 1 + "not initialized"; an
  # initialized-but-sealed server answers exit 2 + a "Sealed" table; an
  # unsealed server answers exit 0 + a "Sealed" table. Any of those means the
  # API is up. Anything else = still booting.
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
    die "vault API unreachable"
    ;;
esac

# --- determine vault state ---------------------------------------------------
# vault status -format=json exits 0 when unsealed, 2 when sealed, 1 when
# uninitialized (the same exit-code contract as the plain `vault status` the
# reachability loop above probes). All three answer with valid JSON.
vault_is_initialized() {
  local out rc
  set +e
  out="$(vault_exec status -format=json 2>/dev/null)"
  rc=$?
  set -e
  [ "${rc}" -eq 0 ] || [ "${rc}" -eq 1 ] || [ "${rc}" -eq 2 ] || return 1
  printf '%s' "${out}" | jq -e '.initialized == true' >/dev/null 2>&1
}

vault_is_unsealed() {
  local out rc
  set +e
  out="$(vault_exec status -format=json 2>/dev/null)"
  rc=$?
  set -e
  [ "${rc}" -eq 0 ] || return 1
  printf '%s' "${out}" | jq -e '.sealed == false' >/dev/null 2>&1
}

if vault_is_initialized; then
  vault_initialized=true
else
  vault_initialized=false
fi
if [ "${vault_initialized}" = "true" ] && vault_is_unsealed; then
  vault_sealed=false
else
  vault_sealed=true
fi
# --- initialize + unseal (first run only) ------------------------------------
if [ "${vault_initialized}" = "false" ]; then
  if [ -s "${ROOT_TOKEN_FILE}" ]; then
    die "vault reports uninitialized but ${ROOT_TOKEN_FILE} exists. The vault-file volume is out of sync with ${STATE_DIR} (e.g. the volume was removed but the state kept, or vice versa). To start fresh: 'make down-volumes' then remove ${STATE_DIR}."
  fi
  echo "--- vault not initialized; initializing (key-shares=${HONEY_VAULT_KEY_SHARES}, key-threshold=${HONEY_VAULT_KEY_THRESHOLD})"
  INIT_JSON="$(vault_exec operator init \
    -key-shares="${HONEY_VAULT_KEY_SHARES}" \
    -key-threshold="${HONEY_VAULT_KEY_THRESHOLD}" \
    -format=json)"
  ROOT_TOKEN="$(printf '%s' "${INIT_JSON}" | jq -r '.root_token')"
  [ -n "${ROOT_TOKEN}" ] || die "vault operator init returned no root token"
  mapfile -t UNSEAL_KEYS < <(printf '%s' "${INIT_JSON}" | jq -r '.unseal_keys_b64[]')
  [ "${#UNSEAL_KEYS[@]}" -ge "${HONEY_VAULT_KEY_THRESHOLD}" ] || die "vault operator init returned fewer unseal keys than threshold"

  # persist root token + unseal key(s): host-only, chmod 600, NEVER mounted.
  ( umask 077; printf '%s\n' "${ROOT_TOKEN}" > "${ROOT_TOKEN_FILE}" )
  chmod 600 "${ROOT_TOKEN_FILE}"
  ( umask 077; printf '%s\n' "${UNSEAL_KEYS[@]}" > "${UNSEAL_KEY_FILE}" )
  chmod 600 "${UNSEAL_KEY_FILE}"
  echo "--- root token + unseal key(s) persisted to ${STATE_DIR} (chmod 600, host-only)"

  echo "--- unsealing vault"
  for k in "${UNSEAL_KEYS[@]}"; do
    vault_exec operator unseal "${k}" >/dev/null
    vault_is_unsealed && break
  done
  vault_is_unsealed || die "vault failed to unseal"
  echo "--- vault unsealed"
elif [ "${vault_sealed}" = "true" ]; then
  # re-run after a restart / host reboot: vault comes back sealed; unseal with
  # the persisted key(s)
  [ -s "${UNSEAL_KEY_FILE}" ] || die "vault is sealed but ${UNSEAL_KEY_FILE} is missing/empty. The unseal key is not recoverable from Vault; restore it from a backup or reset the deployment."
  UNSEAL_KEYS_FROM_FILE="$(file_read "${UNSEAL_KEY_FILE}")" || die "cannot read ${UNSEAL_KEY_FILE}; re-run start.sh as its owner or with sudo (or reset the deployment)"
  echo "--- vault sealed on re-run; unsealing with persisted key(s)"
  while IFS= read -r k; do
    [ -n "${k}" ] || continue
    vault_exec operator unseal "${k}" >/dev/null
    vault_is_unsealed && break
  done <<< "${UNSEAL_KEYS_FROM_FILE}"
  vault_is_unsealed || die "vault failed to unseal with persisted key(s)"
  echo "--- vault unsealed"
else
  echo "--- vault already initialized and unsealed"
fi

# Load the root token for administrative operations. On a fresh init ROOT_TOKEN
# is already set from the init response; otherwise read the persisted file.
if [ -z "${ROOT_TOKEN:-}" ]; then
  ROOT_TOKEN="$(file_read "${ROOT_TOKEN_FILE}")" || die "cannot read ${ROOT_TOKEN_FILE}; re-run start.sh as its owner or with sudo (or reset the deployment)"
  [ -n "${ROOT_TOKEN}" ] || die "${ROOT_TOKEN_FILE} is empty"
fi

# --- enable KV v2 + AppRole (idempotent) -------------------------------------
if ! vault_exec_token "${ROOT_TOKEN}" secrets list -format=json \
  | jq -e 'has("secrets/")' >/dev/null 2>&1; then
  vault_exec_token "${ROOT_TOKEN}" secrets enable -path=secrets kv-v2
  echo "--- KV v2 enabled at secrets/"
else
  echo "--- KV v2 already enabled at secrets/"
fi
if ! vault_exec_token "${ROOT_TOKEN}" auth list -format=json \
  | jq -e 'has("approle/")' >/dev/null 2>&1; then
  vault_exec_token "${ROOT_TOKEN}" auth enable approle
  echo "--- AppRole auth enabled"
else
  echo "--- AppRole auth already enabled"
fi

# --- AppRole role with read-only, path-scoped policy --------------------------
printf 'path "secrets/data/%s/daemon" {\n  capabilities = ["read"]\n}\n' \
  "${HONEY_NS}" | vault_exec_token "${ROOT_TOKEN}" policy write daemon-read -
echo "--- policy daemon-read ensured (read-only, scoped to secrets/data/${HONEY_NS}/daemon)"

vault_exec_token "${ROOT_TOKEN}" write auth/approle/role/daemon \
  token_policies=daemon-read \
  secret_id_ttl=0 \
  token_ttl=1h \
  token_max_ttl=24h \
  >/dev/null
echo "--- AppRole role daemon ensured"

# --- identity files (role_id / secret_id) -------------------------------------
# Vault keeps a role's role_id stable across role-data writes, so on re-run we
# reuse the existing identity pair when it still matches the role (no secret-id
# churn: secret_id_ttl=0 means generated secret ids never expire). We only
# regenerate when the role_id changed (role was deleted/recreated) or a file is
# missing.
VAULT_ROLE_ID="$(vault_exec_token "${ROOT_TOKEN}" read -field=role_id \
  auth/approle/role/daemon/role-id)"
[ -n "${VAULT_ROLE_ID}" ] || die "could not read role_id for role daemon"

existing_role_id=""
if [ -f "${IDENTITY_DIR}/role_id" ] && [ -f "${IDENTITY_DIR}/secret_id" ]; then
  existing_role_id="$(file_read "${IDENTITY_DIR}/role_id" || true)"
fi
if [ -n "${existing_role_id}" ] && [ "${existing_role_id}" = "${VAULT_ROLE_ID}" ] \
  && [ -n "$(file_read "${IDENTITY_DIR}/secret_id" || true)" ]; then
  echo "--- AppRole identity files already present and matching; reusing"
else
  if { [ -f "${IDENTITY_DIR}/role_id" ] || [ -f "${IDENTITY_DIR}/secret_id" ]; } \
    && [ -z "$(file_read "${IDENTITY_DIR}/role_id" 2>/dev/null || true)" ]; then
    die "existing identity files in ${IDENTITY_DIR} are not readable; re-run start.sh as their owner or with sudo (or remove them to regenerate)"
  fi
  # secret-id endpoint takes no data; -force is required (see smoke regression)
  VAULT_SECRET_ID="$(vault_exec_token "${ROOT_TOKEN}" write -force -field=secret_id \
    auth/approle/role/daemon/secret-id)"
  [ -n "${VAULT_SECRET_ID}" ] || die "could not generate a secret_id for role daemon"
  write_identity_file "${IDENTITY_DIR}/role_id" "${VAULT_ROLE_ID}"
  write_identity_file "${IDENTITY_DIR}/secret_id" "${VAULT_SECRET_ID}"
  echo "--- AppRole identity files written (no trailing newline; readable by daemon root-without-caps)"
fi

# --- admin token (generate once, persist, print once) -------------------------
# The admin token is an operational secret whose bcrypt hash lives in Vault.
# The plaintext is persisted at ${STATE_DIR}/admin_token (chmod 600, host-only,
# never mounted) so re-runs reuse it and the operator can recover it.
admin_token_generated=false
if [ -s "${ADMIN_TOKEN_FILE}" ]; then
  ADMIN_TOKEN="$(file_read "${ADMIN_TOKEN_FILE}")" || die "cannot read ${ADMIN_TOKEN_FILE}; re-run start.sh as its owner or with sudo (or remove it to generate a new admin token)"
  echo "--- admin token reused from ${ADMIN_TOKEN_FILE}"
else
  ADMIN_TOKEN="$(openssl rand -hex 24)"
  ( umask 077; printf '%s\n' "${ADMIN_TOKEN}" > "${ADMIN_TOKEN_FILE}" )
  chmod 600 "${ADMIN_TOKEN_FILE}"
  admin_token_generated=true
  echo "--- admin token generated and persisted (chmod 600)"
fi

# --- AI provider keys ---------------------------------------------------------
# AI API keys are seeded into Vault from the environment when provided. When
# absent, a clearly-marked placeholder is stored instead so the daemon still
# boots (a placeholder resolves like any string; model calls simply fail until
# a real key is set). Existing non-placeholder values are NEVER clobbered on a
# plain re-run; export OPENAI_API_KEY / OPENROUTER_API_KEY and re-run start.sh
# to replace them.
: "${OPENAI_API_KEY:=sk-placeholder-set-your-openai-key}"
: "${OPENROUTER_API_KEY:=sk-placeholder-set-your-openrouter-key}"
# an explicitly exported empty string is treated the same as unset
[ -n "${OPENAI_API_KEY}" ] || OPENAI_API_KEY=sk-placeholder-set-your-openai-key
[ -n "${OPENROUTER_API_KEY}" ] || OPENROUTER_API_KEY=sk-placeholder-set-your-openrouter-key

SEED_PATH="secrets/${HONEY_NS}/daemon"

# Current value of a KV field under SEED_PATH (empty when absent/unreadable).
kv_get_field() {
  local key="$1"
  local val
  set +e
  val="$(vault_exec_token "${ROOT_TOKEN}" kv get -format=json "${SEED_PATH}" 2>/dev/null \
    | jq -r --arg k "${key}" '.data.data[$k] // empty' 2>/dev/null)"
  set -e
  printf '%s' "${val}"
}

is_placeholder() {
  case "$1" in
    sk-placeholder-*) return 0 ;;
    *) return 1 ;;
  esac
}

# seed_one KEY VALUE MODE
#   MODE=hash : the admin_token_hash field. The bcrypt hash is authoritative
#               for ADMIN_TOKEN but is re-salted by htpasswd on every run, so
#               we only rewrite it when it is missing or the token itself was
#               regenerated this run (avoids gratuitous writes every start).
#   MODE=env  : an AI API key. Seed when missing; replace only when an explicit
#               non-placeholder env value is provided. Never downgrade an
#               existing value to a placeholder.
seed_one() {
  local key="$1" value="$2" mode="$3"
  local cur
  cur="$(kv_get_field "${key}")"
  case "${mode}" in
    hash)
      if [ -n "${cur}" ] && [ "${admin_token_generated}" = "false" ]; then
        echo "--- ${key} already present; left unchanged (token unchanged)"
        return 0
      fi
      if [ "${cur}" = "${value}" ]; then
        return 0
      fi
      vault_exec_token "${ROOT_TOKEN}" kv patch "${SEED_PATH}" "${key}=${value}" >/dev/null
      echo "--- seeded ${key}"
      ;;
    env)
      if [ -z "${cur}" ]; then
        vault_exec_token "${ROOT_TOKEN}" kv patch "${SEED_PATH}" "${key}=${value}" >/dev/null
        echo "--- seeded ${key}"
      elif is_placeholder "${value}"; then
        echo "--- ${key} already present; left unchanged (export the real key to replace)"
      elif [ "${cur}" != "${value}" ]; then
        vault_exec_token "${ROOT_TOKEN}" kv patch "${SEED_PATH}" "${key}=${value}" >/dev/null
        echo "--- updated ${key} from explicit env value"
      else
        echo "--- ${key} already up to date"
      fi
      ;;
  esac
}

echo "--- seeding ${SEED_PATH}"
# The bcrypt hash is only computed when it will actually be written.
ADMIN_TOKEN_HASH=""
if [ "${admin_token_generated}" = "true" ] \
  || [ -z "$(kv_get_field admin_token_hash)" ]; then
  ADMIN_TOKEN_HASH="$(htpasswd -bnBC 12 "" "${ADMIN_TOKEN}" | cut -d: -f2 | tr -d '\n')"
  [ -n "${ADMIN_TOKEN_HASH}" ] || die "htpasswd produced an empty bcrypt hash"
fi

if vault_exec_token "${ROOT_TOKEN}" kv get -format=json "${SEED_PATH}" >/dev/null 2>&1 \
  && [ "$(vault_exec_token "${ROOT_TOKEN}" kv get -format=json "${SEED_PATH}" 2>/dev/null \
        | jq -r '.data.data != null')" = "true" ]; then
  if [ -n "${ADMIN_TOKEN_HASH}" ]; then
    seed_one admin_token_hash "${ADMIN_TOKEN_HASH}" hash
  else
    seed_one admin_token_hash "" hash
  fi
  seed_one openai_api_key "${OPENAI_API_KEY}" env
  seed_one openrouter_api_key "${OPENROUTER_API_KEY}" env
else
  # path missing or empty: create it with all three fields at once
  if [ -z "${ADMIN_TOKEN_HASH}" ]; then
    ADMIN_TOKEN_HASH="$(htpasswd -bnBC 12 "" "${ADMIN_TOKEN}" | cut -d: -f2 | tr -d '\n')"
  fi
  vault_exec_token "${ROOT_TOKEN}" kv put "${SEED_PATH}" \
    "admin_token_hash=${ADMIN_TOKEN_HASH}" \
    "openai_api_key=${OPENAI_API_KEY}" \
    "openrouter_api_key=${OPENROUTER_API_KEY}" \
    >/dev/null
  echo "--- seeded secrets/data/${HONEY_NS}/daemon (created)"
fi
if is_placeholder "${OPENAI_API_KEY}"; then
  echo "NOTE: OPENAI_API_KEY not set; a placeholder was stored in Vault. To enable AI, add OPENAI_API_KEY=<your key> to .env and re-run start.sh (the key is stored in Vault only, never in compose/env)."
fi

# --- start application --------------------------------------------------------
echo "--- starting daemon + ui (daemon waits for vault healthy == unsealed)"
compose up -d daemon ui

# If the rendered config changed while the daemon was already running, the
# `up -d` above does not recreate it (compose sees no env/image change); apply
# the refreshed config by restarting the daemon so the change takes effect now
# instead of waiting up to HD_CONFIG_CHECK_INTERVAL. (A daemon that was down is
# started fresh by `up -d` above and already reads the new config.)
if [ "${CONFIG_CHANGED}" -eq 1 ] && [ "${daemon_was_running}" = "true" ]; then
  echo "--- rendered config changed; restarting daemon to apply"
  compose restart daemon
fi

API_URL="http://localhost:${API_HOST_PORT}"
echo "--- waiting for daemon /healthz at ${API_URL}"
http_code=""
for ((i = 0; i < 240; i++)); do
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
  # Surface the daemon's own view immediately: the most common cause of a
  # never-200 /healthz is the daemon crash-looping (unreadable identity files,
  # a missing/mis-seeded Vault LOOKUP key, vault sealed at boot), so dump
  # status + logs instead of making the operator wait.
  compose ps daemon >&2 || true
  echo "--- daemon logs (tail) ---" >&2
  compose logs --tail=100 daemon >&2 || true
  die "daemon /healthz did not become 200"
fi
echo "--- daemon healthy"

# --- persist namespace/user after successful provisioning --------------------
# Written only now, so a failed first run does not strand the <ns>/<user>
# values (a re-run with corrected values or a fresh state dir still works).
if [ ! -f "${PROVISION_FILE}" ]; then
  ( umask 077; printf 'PROVISION_NS=%s\nPROVISION_USER=%s\n' "${HONEY_NS}" "${HONEY_USER}" > "${PROVISION_FILE}" )
  chmod 600 "${PROVISION_FILE}"
fi

# --- success summary -----------------------------------------------------------
echo ""
echo "=== honey-starter is up ==="
echo "UI:        http://localhost:${UI_HOST_PORT}"
echo "API:       ${API_URL}/healthz"
if [ "${admin_token_generated}" = "true" ]; then
  echo "Admin token (generated now, printed once): ${ADMIN_TOKEN}"
else
  echo "Admin token: stored at ${ADMIN_TOKEN_FILE} (chmod 600). It was printed on first run; cat the file to view it."
fi
echo ""
echo "Namespace (Vault KV prefix): ${HONEY_NS}"
echo "Admin subject:               ${HONEY_USER}"
echo "Secrets live in Vault at:    secrets/data/${HONEY_NS}/daemon"
echo "Root token/unseal key:       ${STATE_DIR} (chmod 600, host-only, never mounted)"
echo ""
echo "Lifecycle:  make stop | make down | make down-volumes | make status | make logs"
echo "To unseal after a host reboot / 'docker compose restart': re-run make start"

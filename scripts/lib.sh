# shellcheck shell=bash
# Library of helper functions for honey-starter scripts.

set -euo pipefail

# Paths
HONEY_STARTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_DIR="${HONEY_STARTER_DIR}/bootstrap"
DEPLOY_DIR="${HONEY_STARTER_DIR}/deploy"
# Exported: variables are consumed by scripts that source this library
# (e.g. start.sh and the lifecycle/test helpers).
export BOOTSTRAP_DIR DEPLOY_DIR

# Load environment variables from .env if present. Test scripts (smoke, e2e, ...)
# set HONEY_STARTER_NO_ENV=1 before sourcing to keep their environment hermetic
# and avoid picking up a host .env.
if [ -z "${HONEY_STARTER_NO_ENV:-}" ] && [ -f "${HONEY_STARTER_DIR}/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "${HONEY_STARTER_DIR}/.env"
  set +a
fi

# Docker image tag for the daemon. This is the published image on Docker Hub.
# Override with HONEYDIPPER_IMAGE env var if needed.
HONEYDIPPER_IMAGE="${HONEYDIPPER_IMAGE:-honeydipper/honeydipper:4.0.0-alpha4-53-g897242b}"

# Default values
: "${VALKEY_ADDR:=127.0.0.1:6379}"
: "${HD_JWT_SIGNING_KEY:=}"

# KEEP-IN-SYNC with scripts/setup.sh: the rich-output block below (the marker
# comment through usage_die) is a byte-for-byte copy of setup.sh's Phase A
# rich-output foundations — setup.sh is the ORIGINAL; the guided installer
# stays self-contained, this copy is shared by every other script. Edit BOTH,
# or the D8 sync-guard check in test/setup-dryrun.sh fails.
# --- output helpers (Phase A rich-output foundation) --------------------------
# Rich-output detection: enabled ONLY when fd 1 is a real terminal AND no
# color-disable env var is PRESENT (no-color.org convention: any value,
# INCLUDING EMPTY, disables — checked with `[ -z "${VAR+x}" ]`, never
# `[ -z "$VAR" ]` which treats an empty value as unset) AND TERM is set and
# not "dumb". Computed ONCE and cached in RICH_OUTPUT; every msg_* helper
# re-invokes rich_output_enabled(). The gate is on STDOUT only — INTENTIONAL
# and conservative: prompts/die messages go to stderr, so when stdout is a
# redirected file but stderr is a tty, detection says OFF and prompts render
# UNSTYLED. That is the SAFE direction (styled output appears only when fd 1
# is a tty — consistent with `make setup-dryrun` captures being plain because
# non-pty tests redirect fd 1). Do NOT "fix" this to also probe stdin/stderr.
RICH_OUTPUT=0
RICH_OUTPUT_UNCACHED=1
rich_output_enabled() {
  if [ "${RICH_OUTPUT_UNCACHED}" -eq 1 ]; then
    RICH_OUTPUT_UNCACHED=0
    if [ -t 1 ] \
      && [ -z "${NO_COLOR+x}" ] \
      && [ -z "${HONEY_STARTER_NO_COLOR+x}" ] \
      && [ -n "${TERM:-}" ] && [ "${TERM}" != "dumb" ]; then
      RICH_OUTPUT=1
    else
      RICH_OUTPUT=0
    fi
  fi
  [ "${RICH_OUTPUT}" -eq 1 ]
}

# ANSI SGR codes + status glyphs. Emitted as literal bytes (bash passes UTF-8
# through unchanged even under LC_ALL=C; the only garble risk is the terminal
# consumer, which is exactly what the fallback excludes). The msg_* helpers
# render the ORIGINAL line text byte-for-byte in both modes: rich mode only
# PREPENDS the style+glyph and appends ONE trailing reset — it NEVER
# interleaves ESC / glyph with the message tokens ([ok], ERROR:, WARNING:,
# NOTE:, === … ===, prompt labels) and NEVER rewrites message text (the strict
# prefix-only rule).
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_UNDERLINE=$'\033[4m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_CYAN=$'\033[36m'
E_OK="✅"
E_FAIL="❌"
E_WARN="⚠"
E_INFO="ℹ"
E_SECTION="🚀"
E_KEY="🔑"

msg_ok() {
  if rich_output_enabled; then
    printf '%s%s %s%s\n' "${C_GREEN}" "${E_OK}" "$*" "${C_RESET}"
  else
    printf '%s\n' "$*"
  fi
}
msg_fail() {
  if rich_output_enabled; then
    printf '%s%s %s%s\n' "${C_RED}" "${E_FAIL}" "$*" "${C_RESET}" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}
msg_warn() {
  if rich_output_enabled; then
    printf '%s%s %s%s\n' "${C_YELLOW}" "${E_WARN}" "$*" "${C_RESET}" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}
msg_info() {
  if [ -z "$*" ]; then
    printf '\n'
    return 0
  fi
  if rich_output_enabled; then
    printf '%s%s %s%s\n' "${C_CYAN}" "${E_INFO}" "$*" "${C_RESET}"
  else
    printf '%s\n' "$*"
  fi
}
msg_note() { msg_info "$*"; }
msg_section() {
  if rich_output_enabled; then
    printf '%s%s%s %s%s\n' "${C_BOLD}" "${C_CYAN}" "${E_SECTION}" "$*" "${C_RESET}"
  else
    printf '%s\n' "$*"
  fi
}
# msg_input: prompt labels (bold; the label/default text stays byte-contiguous —
# a single bold prefix + one trailing reset, NEVER between label tokens).
msg_input() {
  if rich_output_enabled; then
    printf '%s%s%s' "${C_BOLD}" "$*" "${C_RESET}"
  else
    printf '%s' "$*"
  fi
}
# msg_key: key/secret prompt label — 🔑 + bold on the label line; the label
# text stays byte-contiguous (one bold prefix + one trailing reset, never
# between label tokens).
msg_key() {
  if rich_output_enabled; then
    printf '%s%s %s%s' "${C_BOLD}" "${E_KEY}" "$*" "${C_RESET}"
  else
    printf '%s' "$*"
  fi
}
# msg_highlight: bold+underline for install dir / state dir / project paths.
msg_highlight() {
  if rich_output_enabled; then
    printf '%s%s%s%s\n' "${C_BOLD}" "${C_UNDERLINE}" "$*" "${C_RESET}"
  else
    printf '%s\n' "$*"
  fi
}

info() { msg_info "$*"; }
note() { msg_note "NOTE: $*"; }
warn() { msg_warn "WARNING: $*"; }
die() { msg_fail "ERROR: $*"; exit 1; }
usage_die() { msg_fail "ERROR: $*"; printf 'Try --help for usage.\n' >&2; exit 2; }

# Hard requirement: exit if the command is missing.
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "required command not found: $1"
  fi
}

# Soft preflight: print [ok]/[missing] without failing. Used for tools that
# this phase of the project can operate without (shellcheck, ...). Styled with
# msg_ok/msg_fail (Phase D) so no message in this library is left unstyled.
check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    msg_ok "  [ok]      $1"
  else
    msg_fail "  [missing] $1"
  fi
}

# Compose file used by the compose helpers below. Override COMPOSE_FILE before
# sourcing to point at a different compose project/file (a throwaway smoke /
# e2e project still uses the same file; the project is selected through the
# COMPOSE_PROJECT_NAME environment variable).
: "${COMPOSE_FILE:=${DEPLOY_DIR}/docker-compose.yaml}"

# Compose project name. Real deployments (start.sh and the lifecycle scripts)
# default to "honey-starter" so `stop`/`down`/`status`/`logs` always address
# the same stack start.sh brought up. Throwaway test projects (smoke, e2e)
# override COMPOSE_PROJECT_NAME before sourcing this library.
: "${COMPOSE_PROJECT_NAME:=honey-starter}"
export COMPOSE_PROJECT_NAME

# Run `docker compose -f "$COMPOSE_FILE" "$@"`. Every script goes through this
# wrapper (plus vault_exec below) so the compose file and project cannot diverge
# between start.sh, the lifecycle scripts and the tests.
compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

# Run `vault <args>` inside the vault service container as the vault user.
#
# Vault is unreachable from the host by network design (internal network, no
# published host port). `docker compose exec` reaches the container through the
# docker API, not the container network, so this is the ONLY supported way to
# run init/unseal/policy/seeding operations against the vault service — no host
# vault binary is ever needed. Compose exec syntax is
#   exec [OPTIONS] SERVICE COMMAND [ARGS...]
# and it bypasses the image entrypoint (which normally drops root -> vault and
# chowns /vault). Passing --user vault keeps init/unseal writes owned
# consistently with the running server, which also runs as the vault user.
# Note the service name ("vault") and the CLI binary ("vault") are distinct
# positional tokens.
vault_exec() {
  local svc="vault"
  docker compose -f "${COMPOSE_FILE}" exec -i -T --user "${svc}" "${svc}" vault "$@"
}

# Same as vault_exec but with an explicit VAULT_TOKEN in the container env.
vault_exec_token() {
  local token="$1"
  shift
  local svc="vault"
  docker compose -f "${COMPOSE_FILE}" exec -i -T --user "${svc}" \
    -e "VAULT_TOKEN=${token}" "${svc}" vault "$@"
}

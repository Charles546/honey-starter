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

# KEEP-IN-SYNC with scripts/setup.sh: the platform-compat shims block below
# (the marker comment through the end marker) is a byte-for-byte copy of
# setup.sh's Phase 1 macOS platform layer - setup.sh is the ORIGINAL; the
# guided installer stays self-contained, this copy is shared by start.sh and
# the lifecycle scripts. The D8b sync-guard check in test/setup-dryrun.sh
# diffs the marker region and FAILS on drift. Edit BOTH.

# --- platform-compat shims (Phase 1 macOS platform layer) ---------------------
# Platform layer for Linux + arm64 macOS (Apple Silicon, macOS 12+). This block
# is self-contained in setup.sh (the piped bootstrap copy sources nothing) and
# mirrored byte-identical in scripts/lib.sh (shared by start.sh + the lifecycle
# scripts). The D8b KEEP-IN-SYNC sync-guard in test/setup-dryrun.sh diffs this
# exact region (marker comment -> end marker) and FAILS on drift. All GNU-only
# calls route through these shims so Linux behavior is unchanged and macOS gets
# BSD/brew-compatible behavior.
platform_os() {
  case "$(uname -s 2>/dev/null)" in
    Linux) printf 'linux' ;;
    Darwin) printf 'darwin' ;;
    *) printf 'unsupported' ;;
  esac
}

# sha256_digest FILE -> prints the BARE hex SHA-256 digest of FILE (use "-" for
# stdin). GNU sha256sum prints "HASH  FILE", BSD shasum -a 256 prints
# "HASH  FILE", openssl dgst -sha256 prints "SHA256(FILE)= HASH": the digester
# name + filename are stripped so existing `| cut -c1-8` / `| awk '{print $1}'`
# consumers keep working. Returns 1 when no digester is available.
sha256_digest() {
  local f="${1:--}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${f}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${f}" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "${f}" | sed 's/^.*= *//'
  else
    return 1
  fi
}

# sed_inplace PROGRAM FILE - GNU sed needs `-i` with no suffix, BSD needs
# `-i ''`, and musl/busybox varies: PROBE which form this host accepts (never
# guess from the OS name) and cache it. Returns 1 when neither form works.
SED_INPLACE_MODE=""
sed_inplace() {
  local prog="$1" file="$2" tmpf
  if [ -z "${SED_INPLACE_MODE}" ]; then
    tmpf="$(mktemp 2>/dev/null)" || tmpf="/tmp/honey-starter.sedprobe.$$"
    printf 'x\n' > "${tmpf}"
    if sed -i 's/x/y/' "${tmpf}" 2>/dev/null && [ "$(cat "${tmpf}" 2>/dev/null)" = "y" ]; then
      SED_INPLACE_MODE="gnu"
    elif sed -i '' 's/x/y/' "${tmpf}" 2>/dev/null && [ "$(cat "${tmpf}" 2>/dev/null)" = "y" ]; then
      SED_INPLACE_MODE="bsd"
    else
      SED_INPLACE_MODE="none"
    fi
    rm -f "${tmpf}" 2>/dev/null || true
  fi
  case "${SED_INPLACE_MODE}" in
    gnu) sed -i "${prog}" "${file}" ;;
    bsd) sed -i '' "${prog}" "${file}" ;;
    *) return 1 ;;
  esac
}

# stty_dev -> prints "-F" (GNU/BusyBox stty -F DEV) or "-f" (BSD stty -f DEV)
# for the /dev/tty device; PROBEd once against /dev/tty and cached. Used by
# setup.sh's masked-input (masked_read / read_secret_key).
STTY_DEV_FLAG=""
stty_dev() {
  if [ -z "${STTY_DEV_FLAG}" ]; then
    if stty -F /dev/tty -g >/dev/null 2>&1; then
      STTY_DEV_FLAG="-F"
    elif stty -f /dev/tty -g >/dev/null 2>&1; then
      STTY_DEV_FLAG="-f"
    else
      STTY_DEV_FLAG="-F"
    fi
  fi
  printf '%s' "${STTY_DEV_FLAG}"
}

# realpath_portable PATH -> canonical absolute path: `readlink -f` when present
# (GNU coreutils / Linux; macOS has no readlink -f), else `cd && pwd -P` for an
# existing dir, else print the path as-is (matches the old fallback exactly).
realpath_portable() {
  local p="$1" out=""
  if command -v readlink >/dev/null 2>&1; then
    out="$(readlink -f "${p}" 2>/dev/null || true)"
  fi
  if [ -z "${out}" ]; then
    if [ -d "${p}" ]; then
      out="$(cd "${p}" && pwd -P)"
    else
      out="${p}"
    fi
  fi
  printf '%s' "${out}"
}

# cp_recursive SRC DST - GNU `cp -a` vs BSD `cp -pR` (macOS cp has no -a).
# PROBEd once and cached; used by materialize_new's EXDEV cross-filesystem
# fallback.
CP_RECURSIVE_ARGS=""
cp_recursive() {
  local src="$1" dst="$2" tmpd
  if [ -z "${CP_RECURSIVE_ARGS}" ]; then
    tmpd="$(mktemp -d 2>/dev/null)" || tmpd="/tmp/honey-starter.cpprobe.$$"
    mkdir -p "${tmpd}/s" 2>/dev/null || true
    printf 'x' > "${tmpd}/s/f" 2>/dev/null || true
    if cp -a "${tmpd}/s" "${tmpd}/a" 2>/dev/null && [ -f "${tmpd}/a/f" ]; then
      CP_RECURSIVE_ARGS="-a"
    elif cp -pR "${tmpd}/s" "${tmpd}/b" 2>/dev/null && [ -f "${tmpd}/b/f" ]; then
      CP_RECURSIVE_ARGS="-pR"
    else
      CP_RECURSIVE_ARGS="-a"
    fi
    rm -rf "${tmpd}" 2>/dev/null || true
  fi
  cp "${CP_RECURSIVE_ARGS}" "${src}" "${dst}"
}

# _htpasswd_probe -> 0/1 probe shared by resolve_htpasswd (hard: dies with brew
# guidance) and setup.sh's optional-tools preflight (soft: reports missing).
# Private helper backing the public resolve_htpasswd shim below.
_htpasswd_probe() {
  if command -v htpasswd >/dev/null 2>&1; then
    return 0
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    local htdir=""
    htdir="$(brew --prefix httpd 2>/dev/null || true)"
    if [ -n "${htdir}" ] && [ -x "${htdir}/bin/htpasswd" ]; then
      PATH="${htdir}/bin:${PATH}"
      export PATH
      return 0
    fi
  fi
  return 1
}

# resolve_htpasswd -> htpasswd is NOT on PATH on macOS even after
# `brew install httpd` (it lives at $(brew --prefix httpd)/bin/htpasswd). Probe
# `command -v htpasswd` first, then the brew prefix on darwin; export the dir
# onto PATH so every caller (setup.sh optional-tools preflight, start.sh's
# `require_cmd htpasswd`) resolves it. Dies with brew guidance on darwin; the
# plain Linux message (identical to the previous `require_cmd htpasswd` die) is
# kept on every other platform so Linux behavior is unchanged.
resolve_htpasswd() {
  if _htpasswd_probe; then
    return 0
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    die "required command not found: htpasswd (brew install httpd; it is at \$(brew --prefix httpd)/bin/htpasswd - NOT on PATH by default)"
  fi
  die "required command not found: htpasswd"
}
# --- end platform-compat shims ---



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

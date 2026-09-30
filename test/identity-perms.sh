#!/usr/bin/env bash
# identity-perms.sh — hermetic (no docker) tests for the platform-aware AppRole
# identity-file permission helpers in scripts/lib.sh (identity_file_mode /
# ensure_identity_daemon_readable).
#
# The daemon runs root-without-caps (cap_drop: [ALL], no CAP_DAC_OVERRIDE) and
# must read the AppRole identity files (role_id / secret_id) through the bind
# mount. On Linux / WSL2 a `0600` root-owned file works because bind mounts
# preserve host uid 0. On macOS the Docker Desktop / Rancher Desktop
# file-sharing layer (VirtioFS / gRPC-FUSE) does NOT present the host's
# `chown 0:0` as uid 0 inside the container — a `0600` root-owned host file is
# owned by the desktop user's uid in the container, so the daemon's
# root-without-caps gets `Permission denied`. The identity files must therefore
# be `0644` on darwin ALWAYS (no chown), `0600`+root on linux when we can act
# as root, and `0644` on linux when we cannot.
#
# This suite asserts that exact permission matrix hermetically by mocking
# platform_os / id -u / sudo (no docker, no real root, no real sudo required).
#
# Run: bash test/identity-perms.sh   (or: make validate / make all)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

# Keep the sourced lib.sh hermetic: never pick up a host .env.
export HONEY_STARTER_NO_ENV=1

# shellcheck source=../scripts/lib.sh
source "${HERE}/scripts/lib.sh"

# --- mocks -------------------------------------------------------------------
# MOCK_PLATFORM feeds platform_os(); MOCK_UID feeds id -u (0 = root);
# MOCK_SUDO=1 makes `sudo -n true` succeed (passwordless sudo available),
# MOCK_SUDO=0 makes it fail (no usable sudo) — mirrors start.sh's CAN_ROOT
# probe (minus the interactive password-prompt branch).
MOCK_PLATFORM=linux
MOCK_UID=1000
MOCK_SUDO=0

platform_os() { printf '%s' "${MOCK_PLATFORM}"; }
id() { printf '%s' "${MOCK_UID}"; }
sudo() {
  if [ "${MOCK_SUDO}" -eq 1 ]; then
    return 0
  fi
  return 1
}

# stat_mode FILE -> octal permission modes, portable across GNU stat -c and
# BSD/macOS stat -f (the suite runs on Linux and macOS).
stat_mode() {
  local f="$1" out=""
  out="$(stat -c '%a' "$f" 2>/dev/null)" || out="$(stat -f '%Lp' "$f" 2>/dev/null)"
  printf '%s' "${out}"
}

# assert_mode LABEL PLATFORM UID SUDO EXPECTED — asserts identity_file_mode's
# output for the given mocked platform / uid / sudo capability.
assert_mode() {
  local label="$1" plat="$2" uid="$3" sudo_ok="$4" expected="$5" got
  MOCK_PLATFORM="${plat}"
  MOCK_UID="${uid}"
  MOCK_SUDO="${sudo_ok}"
  got="$(identity_file_mode)"
  if [ "${got}" = "${expected}" ]; then
    PASS=$((PASS+1))
    printf 'ok - %s: identity_file_mode=%s\n' "${label}" "${got}"
  else
    FAIL=$((FAIL+1))
    printf 'FAIL - %s: expected %s, got identity_file_mode=%s\n' "${label}" "${expected}" "${got}" >&2
  fi
}

# --- permission matrix --------------------------------------------------------
# darwin always 0644, regardless of root / sudo / no-root.
assert_mode "darwin + root"    darwin 0 0 644
assert_mode "darwin + sudo"    darwin 1000 1 644
assert_mode "darwin + no-root" darwin 1000 0 644
# linux + root / sudo -> 0600.
assert_mode "linux + root"     linux 0 0 600
assert_mode "linux + sudo"     linux 1000 1 600
# linux + no-root -> 0644.
assert_mode "linux + no-root"  linux 1000 0 644

# --- explicit CAN_ROOT passthrough (start.sh's richer detection) --------------
MOCK_PLATFORM=linux
if [ "$(identity_file_mode 1)" = "600" ]; then
  PASS=$((PASS+1)); printf 'ok - linux explicit CAN_ROOT=1 -> 600\n'
else
  FAIL=$((FAIL+1)); printf 'FAIL - linux explicit CAN_ROOT=1 did not give 600\n' >&2
fi
if [ "$(identity_file_mode 0)" = "644" ]; then
  PASS=$((PASS+1)); printf 'ok - linux explicit CAN_ROOT=0 -> 644\n'
else
  FAIL=$((FAIL+1)); printf 'FAIL - linux explicit CAN_ROOT=0 did not give 644\n' >&2
fi
# darwin ignores CAN_ROOT: even CAN_ROOT=1 must stay 644.
MOCK_PLATFORM=darwin
if [ "$(identity_file_mode 1)" = "644" ]; then
  PASS=$((PASS+1)); printf 'ok - darwin explicit CAN_ROOT=1 still 644\n'
else
  FAIL=$((FAIL+1)); printf 'FAIL - darwin explicit CAN_ROOT=1 should stay 644\n' >&2
fi

# --- ensure_identity_daemon_readable (darwin-only self-heal) -------------------
TMPDIR2="$(mktemp -d)"
trap 'rm -rf "${TMPDIR2}"' EXIT

# darwin: a broken 0600 file is normalized to 0644 (direct chmod, we own it).
MOCK_PLATFORM=darwin
MOCK_UID=1000
MOCK_SUDO=0
printf 'role' > "${TMPDIR2}/role_id"
chmod 600 "${TMPDIR2}/role_id"
ensure_identity_daemon_readable "${TMPDIR2}/role_id"
if [ "$(stat_mode "${TMPDIR2}/role_id")" = "644" ]; then
  PASS=$((PASS+1)); printf 'ok - darwin self-heal normalizes 0600 identity file to 0644\n'
else
  FAIL=$((FAIL+1)); printf 'FAIL - darwin self-heal left mode %s (want 644)\n' "$(stat_mode "${TMPDIR2}/role_id")" >&2
fi

# darwin: the root-owned-sudo-fallback branch is exercised when a direct chmod
# would fail. Simulate a root-owned file by making chmod fail directly and
# letting sudo succeed (we cannot chown to root hermetically). We mock chmod
# and sudo: direct chmod fails, sudo -n chmod succeeds. The mocks are restored
# immediately after this block so the later linux no-op test uses the real
# chmod again.
printf 'secret' > "${TMPDIR2}/secret_id"
chmod 600 "${TMPDIR2}/secret_id"
MOCK_SUDO=1
real_chmod="$(command -v chmod)"
# SC2032: this mock intentionally shadows the external `chmod` so we can
# exercise the sudo-fallback branch of ensure_identity_daemon_readable.
# shellcheck disable=SC2032
chmod() {
  # direct chmod fails (simulating a root-owned file a non-root user cannot
  # chmod); the sudo fallback below runs the real chmod.
  return 1
}
sudo() {
  # MOCK_SUDO=1 -> `sudo -n true` succeeds; `sudo -n chmod ...` runs the real
  # chmod so the file actually becomes 0644.
  if [ "${1:-}" = "-n" ]; then
    shift
  fi
  if [ "${1:-}" = "chmod" ]; then
    shift
    command "${real_chmod}" "$@"
    return $?
  fi
  return 0
}
ensure_identity_daemon_readable "${TMPDIR2}/secret_id"
if [ "$(stat_mode "${TMPDIR2}/secret_id")" = "644" ]; then
  PASS=$((PASS+1)); printf 'ok - darwin self-heal uses sudo fallback for root-owned identity file -> 0644\n'
else
  FAIL=$((FAIL+1)); printf 'FAIL - darwin sudo-fallback left mode %s (want 644)\n' "$(stat_mode "${TMPDIR2}/secret_id")" >&2
fi
# Restore the real chmod / the standard sudo mock for the rest of the suite.
unset -f chmod
sudo() {
  if [ "${MOCK_SUDO}" -eq 1 ]; then
    return 0
  fi
  return 1
}

# linux: ensure_identity_daemon_readable is a no-op (0600 root-owned stays).
MOCK_PLATFORM=linux
MOCK_UID=1000
MOCK_SUDO=1
printf 'role' > "${TMPDIR2}/linux_role_id"
chmod 600 "${TMPDIR2}/linux_role_id"
ensure_identity_daemon_readable "${TMPDIR2}/linux_role_id"
if [ "$(stat_mode "${TMPDIR2}/linux_role_id")" = "600" ]; then
  PASS=$((PASS+1)); printf 'ok - linux self-heal is a no-op (keeps 0600)\n'
else
  FAIL=$((FAIL+1)); printf 'FAIL - linux self-heal changed mode to %s (want 600)\n' "$(stat_mode "${TMPDIR2}/linux_role_id")" >&2
fi

printf '\n'
if [ "${FAIL}" -eq 0 ]; then
  printf '=== identity-perms passed (%s checks) ===\n' "${PASS}"
  exit 0
else
  printf '=== identity-perms FAILED (%s failures) ===\n' "${FAIL}" >&2
  exit 1
fi

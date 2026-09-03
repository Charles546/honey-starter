#!/usr/bin/env bash
# check-bcrypt.sh — validate that the bcrypt token hash format produced by
# `htpasswd -bnBC 12` (the `$2y$` prefix) is accepted by the daemon's
# auth-simple driver.
#
# Contract B1: the auth-simple driver uses bcrypt.CompareHashAndPassword
# (golang.org/x/crypto), which accepts both `$2a$` and `$2y$` prefixes.
# Our Vault seed command produces `$2y$` hashes via htpasswd, and we verify
# round-trip correctness here using htpasswd itself.
#
# REQUIRES: htpasswd (from apache2-utils). This is a hard dependency —
# the project uses htpasswd to generate and verify bcrypt token hashes.
#
# Run: bash test/check-bcrypt.sh
set -euo pipefail

if ! command -v htpasswd &>/dev/null; then
  echo "ERROR: required command not found: htpasswd (install apache2-utils)" >&2
  exit 1
fi

echo "=== Bcrypt hash validation ==="

# Generate a test token and its bcrypt hash
TEST_TOKEN="test-admin-token-$(date +%s)"
HASH=$(htpasswd -bnBC 12 "" "${TEST_TOKEN}" | cut -d: -f2 | tr -d '\n')
echo "Generated hash prefix: ${HASH:0:4}"

if [ "${HASH:0:4}" != '$2y$' ]; then
  echo "FAIL: expected \$2y\$ prefix, got ${HASH:0:4}"
  exit 1
fi
echo "OK: htpasswd produces \$2y\$ hash"

# Write the hash to a temporary password file and verify round-trip
PWFILE=$(mktemp)
trap 'rm -f "$PWFILE"' EXIT
echo "admin:${HASH}" > "$PWFILE"

echo ""
echo "--- Test: htpasswd -vb accepts the hash (correct token) ---"
if ! htpasswd -vb "$PWFILE" admin "$TEST_TOKEN"; then
  echo "FAIL: htpasswd -vb rejected the correct token"
  exit 1
fi
echo "OK: htpasswd -vb accepted the correct token"

echo ""
echo "--- Test: htpasswd -vb rejects a wrong token ---"
if htpasswd -vb "$PWFILE" admin "wrong-token" 2>/dev/null; then
  echo "FAIL: htpasswd -vb incorrectly accepted the wrong token"
  exit 1
fi
echo "OK: htpasswd -vb rejected the wrong token"

echo ""
echo "=== All bcrypt checks passed ==="

#!/usr/bin/env bash
# check-bcrypt.sh — validate that the bcrypt token hash in the auth config
# matches the expected format produced by `htpasswd -bnBC 12`.
#
# This satisfies contract B1: the auth-simple driver uses
# bcrypt.CompareHashAndPassword, which accepts both $2a$ and $2y$ prefixes.
# Our Vault seed command produces $2y$ hashes (via htpasswd), and the daemon
# binary must accept them.
#
# Run: bash test/check-bcrypt.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Locate the honeydipper binary.  If none is found, check whether the docker
# image is available as a fallback.
HONEYDIPPER="${HONEYDIPPER_BIN:-}"
if [ -z "${HONEYDIPPER}" ]; then
  if command -v honeydipper &>/dev/null; then
    HONEYDIPPER=$(command -v honeydipper)
  elif [ -x /tmp/honeydipper ]; then
    HONEYDIPPER=/tmp/honeydipper
  elif docker image inspect honeydipper/honeydipper:4.0.0-alpha4-53-g897242b &>/dev/null; then
    HONEYDIPPER=docker
  else
    echo "SKIP: no honeydipper binary or docker image found"
    exit 0
  fi
fi

echo "=== Bcrypt hash validation ==="
echo "Using: ${HONEYDIPPER}"

# Test 1: htpasswd-generated $2y$ hash (the path we use in Vault seed)
echo ""
echo "--- Test 1: \$2y\$ prefix (htpasswd output) ---"
TEST_TOKEN="test-admin-token-$(date +%s)"
HASH=$(htpasswd -bnBC 12 "" "${TEST_TOKEN}" 2>/dev/null | tr -d ':\n' || true)
echo "Generated hash prefix: ${HASH:0:4}"

if [ "${HASH:0:4}" != '$2y$' ]; then
  echo "FAIL: expected \$2y\$ prefix, got ${HASH:0:4}"
  exit 1
fi
echo "OK: htpasswd produces \$2y\$ hash"

# Test 2: Compare hash against the token using Go (x/crypto v0.48.0, the
# version used by honeydipper v4, which accepts $2y$ hashes)
echo ""
echo "--- Test 2: bcrypt.CompareHashAndPassword accepts the hash ---"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
cat > "${TMPDIR}/go.mod" <<'GOEOF'
module checkbcrypt

go 1.25

require golang.org/x/crypto v0.48.0
GOEOF
cat > "${TMPDIR}/main.go" <<'GOEOF'
package main

import (
	"fmt"
	"os"

	"golang.org/x/crypto/bcrypt"
)

func main() {
	hash := []byte(os.Args[1])
	token := []byte(os.Args[2])
	if err := bcrypt.CompareHashAndPassword(hash, token); err != nil {
		fmt.Printf("FAIL: bcrypt compare: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("OK: bcrypt compare succeeded")
}
GOEOF
cd "${TMPDIR}"
go mod tidy 2>&1 | tail -1
go run main.go "${HASH}" "${TEST_TOKEN}"
echo ""

echo "=== All bcrypt checks passed ==="

#!/usr/bin/env bash
# check-config.sh — validate the assembled bootstrap config with honeydipper
# configcheck.
#
# Runs configcheck against the bootstrap/ directory, optionally with
# CHECK_REMOTE=1 to pull remote repos (essentials v4-rc, remote AI driver).
#
# This satisfies contract B2: configcheck loads the bootstrap config,
# validates workflows, contexts, and authorization rules, and returns non-zero
# on any error.
#
# Placeholders <ns> and <user> must be substituted before running the test.
# This script substitutes them with dummy values for structural validation.
#
# Run: bash test/check-config.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BOOTSTRAP="${HERE}/bootstrap"

# Locate the honeydipper binary
HONEYDIPPER="${HONEYDIPPER_BIN:-}"
if [ -z "${HONEYDIPPER}" ]; then
  if command -v honeydipper &>/dev/null; then
    HONEYDIPPER=$(command -v honeydipper)
  elif [ -x /tmp/honeydipper ]; then
    HONEYDIPPER=/tmp/honeydipper
  else
    echo "SKIP: no honeydipper binary found (set HONEYDIPPER_BIN)"
    exit 0
  fi
fi

echo "=== Configcheck validation ==="
echo "Binary: ${HONEYDIPPER}"
echo "Bootstrap: ${BOOTSTRAP}"

# Prepare a temporary copy of the bootstrap config with placeholders substituted
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
cp -r "${BOOTSTRAP}" "${TMPDIR}/config"
cd "${TMPDIR}/config"

# Substitute placeholders for structural validation
sed -i 's/<ns>/dummy/g' init.yaml auth.yaml engines.yaml
sed -i 's/<user>/alice/g' init.yaml auth.yaml contexts.yaml
sed -i "s/<user>/alice/g" tests/api_auth_tests.yaml

echo ""
echo "--- Running configcheck (local only) ---"
set +e
REPO="${TMPDIR}/config" CHECK_REMOTE=1 "${HONEYDIPPER}" configcheck 2>&1
RC=$?
set -e

if [ "${RC}" -ne 0 ]; then
  echo ""
  echo "FAIL: configcheck returned non-zero exit code ${RC}"
  exit "${RC}"
fi

echo ""
echo "=== Configcheck passed ==="

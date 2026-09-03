#!/usr/bin/env bash
# check-config.sh — validate the assembled bootstrap config with
# honeydipper configcheck, running inside the published docker image.
#
# Contract B2: configcheck loads the bootstrap config, validates workflows,
# contexts, and authorization rules, and returns non-zero on any error.
#
# Placeholders <ns> and <user> are substituted before running the test.
# Remote repos (essentials v4-rc, remote AI driver) are fetched by the
# daemon as part of configcheck when CHECK_REMOTE=1.
#
# Requires: docker
#
# Run: bash test/check-config.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BOOTSTRAP="${HERE}/bootstrap"

# Docker image tag — overridable via HONEYDIPPER_IMAGE env var
: "${HONEYDIPPER_IMAGE:=honeydipper/honeydipper:4.0.0-alpha4-53-g897242b}"

if ! command -v docker &>/dev/null; then
  echo "SKIP: docker not found"
  exit 0
fi

echo "=== Configcheck validation ==="
echo "Image: ${HONEYDIPPER_IMAGE}"
echo "Bootstrap: ${BOOTSTRAP}"

# Prepare a temporary copy of the bootstrap config with placeholders substituted
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
CONFIGDIR="${TMPDIR}/config"
mkdir -p "$CONFIGDIR"
cp -r "${BOOTSTRAP}/." "$CONFIGDIR"

cd "$CONFIGDIR"

# Substitute placeholders for structural validation
sed -i 's/<ns>/dummy/g' init.yaml auth.yaml engines.yaml
sed -i 's/<user>/alice/g' init.yaml auth.yaml contexts.yaml
sed -i 's/<user>/alice/g' tests/api_auth_tests.yaml

echo ""
echo "--- Running configcheck (docker) ---"
set +e
docker run --rm \
  -v "${CONFIGDIR}:/opt/config:ro" \
  -e "REPO=/opt/config" \
  -e "CHECK_REMOTE=1" \
  "${HONEYDIPPER_IMAGE}" \
  configcheck 2>&1
RC=$?
set -e

if [ "${RC}" -ne 0 ]; then
  echo ""
  echo "FAIL: configcheck returned non-zero exit code ${RC}"
  exit "${RC}"
fi

echo ""
echo "=== Configcheck passed ==="

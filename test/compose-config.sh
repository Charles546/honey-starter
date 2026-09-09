#!/usr/bin/env bash
# compose-config.sh — validate deploy/docker-compose.yaml with `docker compose
# config` (compose v2). This catches schema/interpolation errors without
# pulling images or starting containers.
#
# Phase 6b: also verifies the optional corporate-root-CA wiring renders
# correctly in both states that the Phase 6a setup.sh authorizes:
#   * C-CA1 — NO CA configured (HD_CA_CERT_FILE / HD_CA_BUNDLE unset): the
#             daemon read-only bind-mount falls back to /dev/null and the five
#             trust env vars render empty (inert for every consumer).
#   * C-CA2 — CA configured (HD_CA_CERT_FILE=<host path>,
#             HD_CA_BUNDLE=/etc/honeydipper/ca/ca-bundle.crt): the mount source
#             resolves to the host file and the five env vars render the
#             container path.
#   * C-CA3 — mount-sanity (docker run): a file bind-mounted at
#             /etc/honeydipper/ca/ca-bundle.crt:ro on a read-only rootfs is
#             readable (the daemon runs read_only: true, so it must read the
#             bundle from the mount rather than update-ca-certificates).
#
# Requires: docker with compose v2 (C-CA3 additionally pulls a tiny base image).
# Skips gracefully (exit 0) when docker/compose is unavailable.
#
# Run: bash test/compose-config.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${HERE}/deploy/docker-compose.yaml"

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker not found"
  exit 0
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "SKIP: docker compose v2 not found"
  exit 0
fi

TMPDIR_CA="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_CA}"' EXIT

echo "=== Compose config validation ==="
echo "File: ${COMPOSE_FILE}"
docker compose -f "${COMPOSE_FILE}" config >/dev/null
echo "=== Compose config is valid ==="

# --- C-CA1. Render with NO CA configured -------------------------------------
# HD_CA_CERT_FILE / HD_CA_BUNDLE unset -> the mount source falls back to
# /dev/null and the five trust env vars render empty (present-but-empty is
# treated as unset by all five consumers).
echo "=== C-CA1: compose config with no corporate root CA configured ==="
RENDERED_UNSET="${TMPDIR_CA}/rendered-unset.yaml"
env -u HD_CA_CERT_FILE -u HD_CA_BUNDLE \
  docker compose -f "${COMPOSE_FILE}" config > "${RENDERED_UNSET}"
if grep -q 'source: /dev/null' "${RENDERED_UNSET}" \
   && grep -q 'target: /etc/honeydipper/ca/ca-bundle.crt' "${RENDERED_UNSET}"; then
  echo "ok - C-CA1: CA bind-mount falls back to /dev/null (read-only) when HD_CA_CERT_FILE unset"
else
  echo "FAIL - C-CA1: expected /dev/null -> /etc/honeydipper/ca/ca-bundle.crt bind-mount in rendered config"
  grep -n -A4 'ca-bundle.crt' "${RENDERED_UNSET}" || true
  exit 1
fi
for envvar in SSL_CERT_FILE GIT_SSL_CAINFO CURL_CA_BUNDLE NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE; do
  if grep -Eq "^ +${envvar}: (\"\"|'')$" "${RENDERED_UNSET}"; then
    echo "ok - C-CA1: ${envvar} renders empty (inert) when HD_CA_BUNDLE unset"
  else
    echo "FAIL - C-CA1: ${envvar} did not render empty when HD_CA_BUNDLE unset"
    grep -n "${envvar}" "${RENDERED_UNSET}" || true
    exit 1
  fi
done

# --- C-CA2. Render with a CA configured --------------------------------------
# HD_CA_CERT_FILE set to a host bundle + HD_CA_BUNDLE set to the container path
# -> the mount source resolves to the host file and the five trust env vars
# render the container path.
echo "=== C-CA2: compose config with a corporate root CA configured ==="
CA_FILE="${TMPDIR_CA}/host-ca-bundle.pem"
: > "${CA_FILE}"
RENDERED_SET="${TMPDIR_CA}/rendered-set.yaml"
HD_CA_CERT_FILE="${CA_FILE}" HD_CA_BUNDLE=/etc/honeydipper/ca/ca-bundle.crt \
  docker compose -f "${COMPOSE_FILE}" config > "${RENDERED_SET}"
if grep -q "source: ${CA_FILE}" "${RENDERED_SET}" \
   && grep -q 'target: /etc/honeydipper/ca/ca-bundle.crt' "${RENDERED_SET}"; then
  echo "ok - C-CA2: CA bind-mount source resolves to the host file when HD_CA_CERT_FILE set"
else
  echo "FAIL - C-CA2: expected source: ${CA_FILE} -> /etc/honeydipper/ca/ca-bundle.crt in rendered config"
  grep -n -A4 'ca-bundle.crt' "${RENDERED_SET}" || true
  exit 1
fi
for envvar in SSL_CERT_FILE GIT_SSL_CAINFO CURL_CA_BUNDLE NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE; do
  if grep -Eq "^ +${envvar}: /etc/honeydipper/ca/ca-bundle.crt$" "${RENDERED_SET}"; then
    echo "ok - C-CA2: ${envvar} renders the container path when HD_CA_BUNDLE set"
  else
    echo "FAIL - C-CA2: ${envvar} did not render /etc/honeydipper/ca/ca-bundle.crt"
    grep -n "${envvar}" "${RENDERED_SET}" || true
    exit 1
  fi
done

# --- C-CA3. Read-only-rootfs file bind-mount sanity --------------------------
# The daemon runs read_only: true, so it cannot update-ca-certificates at
# runtime; the bundle must be readable straight from the bind mount. Prove a
# file bind-mounted at /etc/honeydipper/ca/ca-bundle.crt:ro on a read-only
# rootfs is actually readable.
echo "=== C-CA3: read-only-rootfs CA file bind-mount sanity ==="
CA_BUNDLE_PEM="${TMPDIR_CA}/ca-bundle.crt"
cat > "${CA_BUNDLE_PEM}" <<'EOF'
-----BEGIN CERTIFICATE-----
MIIBhTCCASugAwIBAgIQS0v3r7v3r7v3r7v3r7v3r7v3r7v3r7v3r7v3r7AwDQYJ
KoZIhvcNAQELBQAwFDESMBAGA1UEAwwJdGVzdC1jYS1hMB4XDTI0MDEwMTAwMDAw
MFoXDTI5MDEwMTAwMDAwMFowFDESMBAGA1UEAwwJdGVzdC1jYS1hMFwwDQYJKoZI
hvcNAQELBQADSwAwSAJBAKc0gKQKQKQKQKQKQKQKQKQKQKQKQKQKQKQKQKQKQKQK
AgMBAAEwDQYJKoZIhvcNAQELBQADQQAQAQBAEBAQEBAQEBAQEBAQEBAQEBAQEB
AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
-----END CERTIFICATE-----
EOF
if docker run --rm --read-only \
    -v "${CA_BUNDLE_PEM}:/etc/honeydipper/ca/ca-bundle.crt:ro" \
    alpine:3 sh -c 'test -r /etc/honeydipper/ca/ca-bundle.crt && grep -q "BEGIN CERTIFICATE" /etc/honeydipper/ca/ca-bundle.crt' \
    >/dev/null 2>&1; then
  echo "ok - C-CA3: file bind-mount readable on read-only rootfs"
else
  echo "FAIL - C-CA3: read-only-rootfs CA bind-mount not readable"
  exit 1
fi

echo "=== Compose config (with corporate root CA wiring) OK ==="

#!/usr/bin/env bash
# proxy.sh — hermetic (mock docker, local listener) tests for scripts/proxy.sh.
# Run: bash test/proxy.sh   (or: make proxy-test)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

T="$(mktemp -d)"
LISTENER=""
cleanup() { [ -z "${LISTENER}" ] || kill "${LISTENER}" 2>/dev/null || true; rm -rf "${T}"; }
trap cleanup EXIT

mkdir -p "${T}/bin" "${T}/state"
cat > "${T}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
echo "docker $*" >> "${MOCK_LOG}"
case "$*" in
  *"ps -q daemon"*) [ "${MOCK_DAEMON:-1}" = 1 ] && echo abc123 ;;
  "run "*) printf -- '-----BEGIN CERTIFICATE-----\nSYSTEMROOTS\n-----END CERTIFICATE-----\n' ;;
  *" up "*) env | grep -E '^HD_PROXY_' >> "${MOCK_LOG}" || true ;;
esac
exit 0
MOCK
chmod +x "${T}/bin/docker"
export MOCK_LOG="${T}/log" PATH="${T}/bin:${PATH}"
export HONEY_STARTER_NO_ENV=1 HD_STATE_DIR="${T}/state"
unset HD_CA_CERT_FILE HD_PROXY_PORT HD_PROXY_HOST HD_PROXY_CERT ZAP_API_KEY

openssl req -x509 -newkey rsa:2048 -nodes -keyout "${T}/k.pem" -out "${T}/ca.pem" \
  -subj "/CN=Test Proxy CA" -days 1 >/dev/null 2>&1
openssl x509 -in "${T}/ca.pem" -outform der -out "${T}/ca.der"

PORT="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
python3 -c "
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', ${PORT})); s.listen(5); time.sleep(120)" &
LISTENER=$!
sleep 1

P="bash ${HERE}/scripts/proxy.sh"
run() { : > "${MOCK_LOG}"; "$@" > "${T}/out" 2>&1; }

# 1. bad port
if ! run ${P} on --port abc && grep -q 'must be a number' "${T}/out"; then ok "rejects non-numeric port"; else bad "rejects non-numeric port"; fi
# 2. unknown option
if ! run ${P} on --bogus && grep -q 'unknown option' "${T}/out"; then ok "rejects unknown option"; else bad "rejects unknown option"; fi
# 3. nothing listening
if ! run ${P} on --port 1 --cert "${T}/ca.pem" && grep -q 'nothing is listening' "${T}/out"; then ok "fails when proxy is not listening"; else bad "fails when proxy is not listening"; fi
# 4. daemon down
if ! MOCK_DAEMON=0 run ${P} on --port "${PORT}" --cert "${T}/ca.pem" && grep -q 'daemon is not running' "${T}/out"; then ok "fails when daemon is down"; else bad "fails when daemon is down"; fi
# 5. non-cert file
echo junk > "${T}/junk"
if ! run ${P} on --port "${PORT}" --cert "${T}/junk" && grep -q 'not a PEM or DER' "${T}/out"; then ok "rejects non-certificate"; else bad "rejects non-certificate"; fi

# 6. PEM cert, system-roots base, default GODEBUG
if run ${P} on --port "${PORT}" --cert "${T}/ca.pem" \
  && grep -q SYSTEMROOTS "${T}/state/ca/proxy-bundle.crt" \
  && [ "$(grep -c 'BEGIN CERTIFICATE' "${T}/state/ca/proxy-bundle.crt")" = 2 ] \
  && grep -q "HD_PROXY_URL=http://host.docker.internal:${PORT}" "${MOCK_LOG}" \
  && grep -q 'HD_PROXY_GODEBUG=x509negativeserial=1' "${MOCK_LOG}" \
  && grep -q 'force-recreate daemon' "${MOCK_LOG}" \
  && grep -q 'proxy.override.yaml' "${MOCK_LOG}"; then ok "on: PEM cert + system roots + GODEBUG"; else bad "on: PEM cert + system roots + GODEBUG"; fi

# 7. DER cert, custom base bundle, strict, custom host
printf -- '-----BEGIN CERTIFICATE-----\nCORPROOT\n-----END CERTIFICATE-----\n' > "${T}/corp.crt"
if HD_CA_CERT_FILE="${T}/corp.crt" run ${P} on --port "${PORT}" --cert "${T}/ca.der" --strict-certs --host my.host \
  && grep -q CORPROOT "${T}/state/ca/proxy-bundle.crt" \
  && ! grep -q SYSTEMROOTS "${T}/state/ca/proxy-bundle.crt" \
  && [ "$(grep -c 'BEGIN CERTIFICATE' "${T}/state/ca/proxy-bundle.crt")" = 2 ] \
  && grep -q "HD_PROXY_URL=http://my.host:${PORT}" "${MOCK_LOG}" \
  && grep -q '^HD_PROXY_GODEBUG=$' "${MOCK_LOG}"; then ok "on: DER cert, corp base, --strict-certs, --host"; else bad "on: DER cert, corp base, --strict-certs, --host"; fi

# 8. no temp files left behind
if [ -z "$(find "${T}/state/ca" -name '.proxy-bundle.*')" ]; then ok "no temp files left"; else bad "no temp files left"; fi

# 9. off uses the base compose file only
if run ${P} off && grep -q 'force-recreate daemon' "${MOCK_LOG}" && ! grep -q proxy.override "${MOCK_LOG}"; then ok "off: base compose only"; else bad "off: base compose only"; fi

echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]

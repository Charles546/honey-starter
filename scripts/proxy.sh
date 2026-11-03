#!/usr/bin/env bash
# proxy.sh — route the daemon's outbound traffic through an intercepting proxy
# running on your host (ZAP, Charles, mitmproxy, ...) to capture it.
#
#   bash scripts/proxy.sh on  [--flavor zap|charles|mitmproxy|generic] [--port N]
#                             [--host H] [--cert FILE] [--api-key KEY]
#                             [--strict-certs]
#   bash scripts/proxy.sh off
#   bash scripts/proxy.sh status
# (or: make proxy-on / make proxy-off / make proxy-status)
#
# `on` builds ${HD_STATE_DIR}/ca/proxy-bundle.crt = your current CA bundle
# (HD_CA_CERT_FILE if set, else the daemon image's system roots) + the proxy's
# root CA, then recreates ONLY the daemon with deploy/proxy.override.yaml.
# The stack must already be running (`make start`). The proxy is a debug
# overlay: it is NOT written to .env, so a later `make start` (or `make proxy-off`)
# returns the daemon to the normal, un-proxied configuration.
#
# Options (env var in parentheses):
#   --flavor F      zap (default) | charles | mitmproxy | generic
#                   (HD_PROXY_FLAVOR). Sets the default port, whether the ZAP
#                   GODEBUG workaround applies and how the root CA is found:
#                     zap       port 8080, root CA from ZAP's API, GODEBUG on
#                     charles   port 8888, root CA via http://chls.pro/ssl
#                     mitmproxy port 8080, ~/.mitmproxy/mitmproxy-ca-cert.pem
#                               or http://mitm.it through the proxy
#                     generic   port 8080, you must pass --cert
#                   The auto-fetch needs the proxy running; --cert always wins.
#   --port N        proxy port on the host (HD_PROXY_PORT, default per flavor)
#   --host H        host name the container uses to reach your machine
#                   (HD_PROXY_HOST, default host.docker.internal)
#   --cert FILE     the proxy's root CA, PEM or DER (HD_PROXY_CERT)
#   --api-key KEY   ZAP API key if ZAP requires one (ZAP_API_KEY)
#   --strict-certs  do NOT set GODEBUG=x509negativeserial=1 (zap flavor only).
#
# The proxy must listen on an address the container VM can reach (0.0.0.0, not
# only 127.0.0.1) — be aware that exposes it to your network while it runs.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# Same HD_STATE_DIR default + relative-anchoring rules as start.sh.
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

PROXY_OVERRIDE="${DEPLOY_DIR}/proxy.override.yaml"
PROXY_BUNDLE="${STATE_DIR}/ca/proxy-bundle.crt"

proxy_compose() {
  docker compose -f "${DEPLOY_DIR}/docker-compose.yaml" -f "${PROXY_OVERRIDE}" "$@"
}

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d;s/^# \{0,1\}//'; }

cmd_off() {
  info "--- recreating the daemon without the proxy"
  compose up -d --force-recreate daemon
}

cmd_status() {
  local env
  env="$(docker inspect "$(compose ps -q daemon)" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -i '^https_proxy=' | head -1 || true)"
  if [ -n "${env}" ]; then
    info "daemon proxy: ${env#*=}"
  else
    info "daemon proxy: off"
  fi
}

# Write the proxy root CA (PEM) to $1 from --cert, or the flavor's own endpoint.
obtain_proxy_cert() {
  local out="$1" port="$2" cert="$3" key="$4" flavor="$5" url=""
  if [ -n "${cert}" ]; then
    [ -r "${cert}" ] || die "cannot read proxy root CA: ${cert}"
    if openssl x509 -in "${cert}" -out "${out}" 2>/dev/null; then :
    elif openssl x509 -inform der -in "${cert}" -out "${out}" 2>/dev/null; then :
    else die "${cert} is not a PEM or DER certificate"; fi
    return 0
  fi
  case "${flavor}" in
    zap)
      url="http://localhost:${port}/OTHER/core/other/rootcert/"
      [ -z "${key}" ] || url="${url}?apikey=${key}"
      curl -fsS --max-time 5 "${url}" -o "${out}.raw" 2>/dev/null || true ;;
    charles)
      url="http://chls.pro/ssl"
      curl -fsS --max-time 5 -x "http://localhost:${port}" "${url}" -o "${out}.raw" 2>/dev/null || true ;;
    mitmproxy)
      url="http://mitm.it/cert/pem"
      if [ -r "${HOME}/.mitmproxy/mitmproxy-ca-cert.pem" ]; then
        cp "${HOME}/.mitmproxy/mitmproxy-ca-cert.pem" "${out}.raw"
      else
        curl -fsS --max-time 5 -x "http://localhost:${port}" "${url}" -o "${out}.raw" 2>/dev/null || true
      fi ;;
    *) url="" ;;
  esac
  if [ -s "${out}.raw" ] && { openssl x509 -in "${out}.raw" -out "${out}" 2>/dev/null \
    || openssl x509 -inform der -in "${out}.raw" -out "${out}" 2>/dev/null; }; then
    rm -f "${out}.raw"
    return 0
  fi
  rm -f "${out}.raw"
  die "no --cert given and could not fetch the ${flavor} root CA${url:+ from ${url}}. Export the proxy's root certificate and pass --cert FILE (ZAP: Tools > Options > Network > Server Certificates > Save; Charles: Help > SSL Proxying > Save Charles Root Certificate; mitmproxy: ~/.mitmproxy/mitmproxy-ca-cert.pem). For Charles, also enable SSL Proxying for the hosts to decrypt."
}

cmd_on() {
  local port="${HD_PROXY_PORT:-}" flavor="${HD_PROXY_FLAVOR:-zap}" host="${HD_PROXY_HOST:-host.docker.internal}"
  local cert="${HD_PROXY_CERT:-}" key="${ZAP_API_KEY:-}" strict=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --flavor) flavor="${2:?--flavor needs a value}"; shift 2 ;;
      --port) port="${2:?--port needs a value}"; shift 2 ;;
      --host) host="${2:?--host needs a value}"; shift 2 ;;
      --cert) cert="${2:?--cert needs a file}"; shift 2 ;;
      --api-key) key="${2:?--api-key needs a value}"; shift 2 ;;
      --strict-certs) strict=1; shift ;;
      *) die "unknown option: $1 (see: bash scripts/proxy.sh --help)" ;;
    esac
  done
  case "${flavor}" in
    zap|mitmproxy|generic) : "${port:=8080}" ;;
    charles) : "${port:=8888}" ;;
    *) die "unknown --flavor: ${flavor} (zap|charles|mitmproxy|generic)" ;;
  esac
  case "${port}" in ''|*[!0-9]*) die "--port must be a number (got: ${port})" ;; esac
  require_cmd openssl
  require_cmd curl
  require_cmd docker

  if ! (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
    die "nothing is listening on localhost:${port}. Start your proxy (listening on 0.0.0.0:${port}) or pass --port."
  fi
  [ -n "$(compose ps -q daemon 2>/dev/null)" ] || die "the daemon is not running; run 'make start' first"

  local dir base
  tmp=""
  dir="$(dirname "${PROXY_BUNDLE}")"
  mkdir -p "${dir}"
  chmod 755 "${dir}" 2>/dev/null || true
  tmp="$(mktemp "${dir}/.proxy-bundle.XXXXXX")"
  trap 'rm -f "${tmp:-}" "${tmp:-}.cert" "${tmp:-}.cert.raw"' EXIT

  base="${HD_CA_CERT_FILE:-}"
  if [ -n "${base}" ] && [ -r "${base}" ]; then
    cat "${base}" > "${tmp}"
  else
    info "--- no corporate CA bundle configured; using the daemon image's system roots"
    docker run --rm --entrypoint cat "${HONEYDIPPER_IMAGE:-honeydipper/honeydipper}" \
      /etc/ssl/certs/ca-certificates.crt > "${tmp}" \
      || die "could not read system CA roots from the daemon image"
  fi
  obtain_proxy_cert "${tmp}.cert" "${port}" "${cert}" "${key}" "${flavor}"
  printf '\n' >> "${tmp}"
  cat "${tmp}.cert" >> "${tmp}"
  chmod 644 "${tmp}"
  mv -f "${tmp}" "${PROXY_BUNDLE}"
  info "--- built ${PROXY_BUNDLE} (base bundle + $(openssl x509 -in "${tmp}.cert" -noout -subject | sed 's/^subject= *//'))"

  export HD_PROXY_URL="http://${host}:${port}"
  export HD_PROXY_CA_FILE="${PROXY_BUNDLE}"
  if [ "${strict}" -eq 1 ] || [ "${flavor}" != zap ]; then export HD_PROXY_GODEBUG=""; else export HD_PROXY_GODEBUG="x509negativeserial=1"; fi

  info "--- recreating the daemon with proxy ${HD_PROXY_URL}"
  proxy_compose up -d --force-recreate daemon
  note "debug overlay only: 'make start' or 'make proxy-off' restores the normal config. Stop the proxy (or bind it to localhost) when done."
}

case "${1:-}" in
  on) shift; cmd_on "$@" ;;
  off) cmd_off ;;
  status) cmd_status ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command: $1 (on|off|status)" ;;
esac

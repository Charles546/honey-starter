#!/usr/bin/env bash
# setup-dryrun.sh — no-docker unit/dry-run tests for scripts/setup.sh (the
# guided single-command installer, Phase 4).
#
# Hermetic: the tree under test is copied into a throwaway mktemp dir and
# setup.sh is executed against THAT copy with a temp HONEY_STARTER_INSTALL_DIR
# and HD_STATE_DIR, always with --dry-run. Nothing is ever written into the
# dev checkout, .env / .honey-starter included. No docker is required (the
# --dry-run preflight treats docker as informational).
#
# Covered contracts:
#   * fresh non-interactive run writes .env (chmod 600) with correct values,
#     no prompts attempted, secrets masked in the summary
#   * byte-exact round-trip across a second run: seeded .env with comments +
#     unmanaged keys + managed keys keeps unmanaged lines byte-identical while
#     managed values are updated in place; mode stays 600
#   * shell-safe quoting of a value containing # and spaces (single-quoted)
#   * secret replace-only-on-explicit-value (no downgrade, no loss on re-run)
#   * validation failures (bad HONEY_NS, bad port, bad base URL) die
#   * missing-required-var error path (custom provider without HD_AI_BASE_URL)
#   * no-tty guidance message
#   * the interactive branch via HONEY_STARTER_ANSWERS_FILE
#   * HD_CONFIG_CHECK_INTERVAL only written on explicit override; otherwise
#     absent (compose default 30m applies by omission)
#
# Run: bash test/setup-dryrun.sh   (or: make setup-dryrun)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_SRC="${HERE}/scripts/setup.sh"
[ -f "${SETUP_SRC}" ] || { echo "ERROR: ${SETUP_SRC} not found" >&2; exit 1; }

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1" >&2; }

# assert_rc NAME EXPECTED_RC CMD...  -> runs in a subshell, checks exit code
assert_rc() {
  local name="$1" expected="$2"
  shift 2
  set +e
  ( "$@" ) >/tmp/setup-dryrun.out 2>&1
  local rc=$?
  set -e
  if [ "${rc}" -eq "${expected}" ]; then
    ok "${name} (exit ${rc})"
  else
    bad "${name}: expected exit ${expected}, got ${rc}"
    sed 's/^/    | /' /tmp/setup-dryrun.out >&2
    return 1
  fi
}

# fresh_tree -> copies the repo tree into a new mktemp dir and prints its path.
fresh_tree() {
  local d
  d="$(mktemp -d)"
  cp -a "${HERE}/." "${d}/tree"
  rm -rf "${d}/tree/.git" "${d}/tree/.honey-starter" "${d}/tree/.env"
  printf '%s' "${d}/tree"
}

cleanup() {
  rm -rf /tmp/setup-dryrun.* 2>/dev/null || true
}
trap cleanup EXIT

echo "=== setup-dryrun: hermetic tests for scripts/setup.sh ==="

# ---------------------------------------------------------------------------
# 1. fresh non-interactive run: .env chmod 600, correct values, masked summary,
#    no prompts attempted
# ---------------------------------------------------------------------------
T1="$(fresh_tree)"
S1="$(mktemp -d)"
KEY1='sk-proj-abc 123 # tricky'
set +e
(
  cd "${T1}"
  HONEY_STARTER_INSTALL_DIR="${T1}" \
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  OPENAI_API_KEY="${KEY1}" \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 \
  HD_STATE_DIR="${S1}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.1.out 2>&1
RC1=$?
set -e
if [ "${RC1}" -ne 0 ]; then
  bad "fresh non-interactive dry-run exited ${RC1}"
  sed 's/^/    | /' /tmp/setup-dryrun.1.out >&2
else
  ok "fresh non-interactive dry-run exited 0"
fi
if [ -f "${T1}/.env" ]; then
  ok ".env written"
else
  bad ".env missing"
fi
MODE1="$(stat -c '%a' "${T1}/.env" 2>/dev/null || true)"
if [ "${MODE1}" = "600" ]; then
  ok ".env mode 600 (got ${MODE1})"
else
  bad ".env mode ${MODE1} (expected 600)"
fi
if grep -q '^HONEY_NS=starter$' "${T1}/.env" \
  && grep -q '^HONEY_USER=admin$' "${T1}/.env" \
  && grep -q '^HD_API_HOST_PORT=9000$' "${T1}/.env" \
  && grep -q '^HD_UI_HOST_PORT=8090$' "${T1}/.env" \
  && grep -q '^HD_UI_URL=http://localhost:8090$' "${T1}/.env"; then
  ok "managed keys written with expected values"
else
  bad "managed keys mismatch:"
  sed 's/^/    | /' "${T1}/.env" >&2
fi
if ! grep -q 'OPENAI_API_KEY=' "${T1}/.env"; then
  bad "OPENAI_API_KEY missing from .env"
elif grep -Fq "${KEY1}" "${T1}/.env"; then
  ok "API key present (quoted form)"
else
  bad "API key not found in .env"
fi
# shell-safe quoting of a value containing # and spaces -> single-quoted
if grep -Fq "OPENAI_API_KEY='sk-proj-abc 123 # tricky'" "${T1}/.env"; then
  ok "value with #/spaces single-quoted shell-safe"
else
  bad "value with #/spaces not single-quoted:"
  grep 'OPENAI_API_KEY' "${T1}/.env" | sed 's/^/    | /' >&2
fi
# masked summary: real key never on stdout/stderr; masked marker present
if grep -Fq "${KEY1}" /tmp/setup-dryrun.1.out; then
  bad "API key leaked into the run log"
else
  ok "API key not echoed to stdout/stderr (masked)"
fi
if grep -q 'OPENAI_API_KEY=\*\{8\}' /tmp/setup-dryrun.1.out; then
  ok "masked OPENAI_API_KEY=******** in the summary"
else
  bad "masked summary marker missing"
fi
# no prompts attempted under HONEY_STARTER_NONINTERACTIVE=1
if grep -Eq '\(HONEY_NS\) \[|\(HONEY_USER\) \[|AI provider \(openai' /tmp/setup-dryrun.1.out; then
  bad "prompts were attempted in non-interactive mode"
else
  ok "no prompts attempted (non-interactive)"
fi
# default 30m config interval by omission
if grep -q '^HD_CONFIG_CHECK_INTERVAL=' "${T1}/.env"; then
  bad "HD_CONFIG_CHECK_INTERVAL was written without an explicit override"
else
  ok "HD_CONFIG_CHECK_INTERVAL absent without explicit override (30m default by omission)"
fi
rm -rf "${T1}" "${S1}"

# ---------------------------------------------------------------------------
# 1b. user-set HD_UI_URL preserved (public-URL knob must not be clobbered)
# ---------------------------------------------------------------------------
# Case A: env-supplied HD_UI_URL survives a fresh dry-run.
# Case B: a pre-existing .env HD_UI_URL survives a re-run (round-trip) when
#         no env HD_UI_URL is supplied — it is only derived when nothing is set.
T1B="$(fresh_tree)"
S1B="$(mktemp -d)"
set +e
(
  cd "${T1B}"
  HONEY_STARTER_INSTALL_DIR="${T1B}" \
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  OPENAI_API_KEY=sk-uipub HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 \
  HD_UI_URL=https://env.example.com \
  HD_STATE_DIR="${S1B}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.1b.out 2>&1
RC1B=$?
set -e
if [ "${RC1B}" -eq 0 ] \
  && grep -q '^HD_UI_URL=https://env.example.com$' "${T1B}/.env"; then
  ok "env-supplied HD_UI_URL preserved (not clobbered by derived localhost)"
else
  bad "env-supplied HD_UI_URL was clobbered (rc=${RC1B}):"
  grep '^HD_UI_URL' "${T1B}/.env" | sed 's/^/    | /' >&2
fi
# Case B: seed a .env with a public HD_UI_URL, re-run with no env HD_UI_URL.
printf 'HD_UI_URL=https://public.example.com\n' > "${T1B}/.env"
set +e
(
  cd "${T1B}"
  HONEY_STARTER_INSTALL_DIR="${T1B}" \
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  OPENAI_API_KEY=sk-uipub2 HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 \
  HD_STATE_DIR="${S1B}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.1c.out 2>&1
RC1C=$?
set -e
if [ "${RC1C}" -eq 0 ] \
  && grep -q '^HD_UI_URL=https://public.example.com$' "${T1B}/.env"; then
  ok "pre-existing .env HD_UI_URL preserved across a re-run"
else
  bad "pre-existing .env HD_UI_URL was clobbered (rc=${RC1C}):"
  grep '^HD_UI_URL' "${T1B}/.env" | sed 's/^/    | /' >&2
fi
rm -rf "${T1B}" "${S1B}"

# ---------------------------------------------------------------------------
# 2. byte-exact round-trip + read-modify-write contract
# ---------------------------------------------------------------------------
T2="$(fresh_tree)"
S2="$(mktemp -d)"
cat > "${T2}/.env" <<'EOF'
# leading comment
HD_JWT_SIGNING_KEY=hd-lookup:vault:/secrets/data/starter/daemon#hd_jwt_signing_key

# image pins
HONEYDIPPER_IMAGE=honeydipper/honeydipper:4.0.0-alpha4-53-g897242b
VALKEY_IMAGE=valkey/valkey:8.1.0
VAULT_IMAGE=hashicorp/vault:1.21.1
HD_UI_IMAGE=honeydipper/hd-ui:0.1.0-alpha2-52-g0ea2fad
HD_STATE_DIR=
HONEY_NS=oldns
HONEY_USER=olduser
HD_API_HOST_PORT=9100
HD_UI_HOST_PORT=8190
# a trailing comment (preserved)
   # indented comment preserved too
EOF
# extract the exact unmanaged prefix lines (through HD_STATE_DIR=, line 9)
# for byte-exactness comparison; the managed lines below it are allowed to move.
sed -n '1,9p' "${T2}/.env" > /tmp/setup-dryrun.prefix.orig
set +e
(
  cd "${T2}"
  HONEY_STARTER_INSTALL_DIR="${T2}" \
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=newns HONEY_USER=newadmin HONEY_AI_PROVIDER=skip \
  HD_API_HOST_PORT=9200 HD_UI_HOST_PORT=8290 \
  HD_STATE_DIR="${S2}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.2a.out 2>&1
RC2A=$?
set -e
[ "${RC2A}" -eq 0 ] || bad "round-trip run 1 exited ${RC2A}"
sed -n '1,9p' "${T2}/.env" > /tmp/setup-dryrun.prefix.after
if diff -q /tmp/setup-dryrun.prefix.orig /tmp/setup-dryrun.prefix.after >/dev/null 2>&1; then
  ok "unmanaged lines (comments, HD_JWT_SIGNING_KEY, image pins, HD_STATE_DIR) byte-exact"
else
  bad "unmanaged lines changed:"
  diff -u /tmp/setup-dryrun.prefix.orig /tmp/setup-dryrun.prefix.after >&2 || true
fi
if grep -q '^HONEY_NS=newns$' "${T2}/.env" \
  && grep -q '^HONEY_USER=newadmin$' "${T2}/.env" \
  && grep -q '^HD_API_HOST_PORT=9200$' "${T2}/.env" \
  && grep -q '^HD_UI_HOST_PORT=8290$' "${T2}/.env" \
  && grep -q '^HD_UI_URL=http://localhost:8290$' "${T2}/.env"; then
  ok "managed keys updated in place (ns/user/ports)"
else
  bad "managed keys not updated in place:"
  sed 's/^/    | /' "${T2}/.env" >&2
fi
# skip provider -> no key/base lines added, old unmanaged content preserved
if grep -q '^OPENAI_API_KEY=' "${T2}/.env"; then
  bad "skip provider still wrote a key line"
else
  ok "skip provider wrote no key/base lines"
fi
if grep -q '^HD_AI_BASE_URL=' "${T2}/.env"; then
  bad "skip provider wrote HD_AI_BASE_URL"
else
  ok "skip provider wrote no HD_AI_BASE_URL"
fi
MODE2="$(stat -c '%a' "${T2}/.env")"
if [ "${MODE2}" = "600" ]; then
  ok "mode 600 after round-trip write"
else
  bad "mode ${MODE2}"
fi
# second run with identical inputs -> byte-identical .env
cp "${T2}/.env" /tmp/setup-dryrun.env2a
set +e
(
  cd "${T2}"
  HONEY_STARTER_INSTALL_DIR="${T2}" \
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=newns HONEY_USER=newadmin HONEY_AI_PROVIDER=skip \
  HD_API_HOST_PORT=9200 HD_UI_HOST_PORT=8290 \
  HD_STATE_DIR="${S2}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.2b.out 2>&1
RC2B=$?
set -e
[ "${RC2B}" -eq 0 ] || bad "round-trip run 2 exited ${RC2B}"
if diff -q /tmp/setup-dryrun.env2a "${T2}/.env" >/dev/null 2>&1; then
  ok "second run with identical inputs produced byte-identical .env (idempotent)"
else
  bad "second run changed .env:"
  diff -u /tmp/setup-dryrun.env2a "${T2}/.env" >&2 || true
fi
rm -rf "${T2}" "${S2}"

# ---------------------------------------------------------------------------
# 3. secret replace-only-on-explicit-value (no downgrade / no loss)
# ---------------------------------------------------------------------------
T3="$(fresh_tree)"
S3="$(mktemp -d)"
cat > "${T3}/.env" <<'EOF'
OPENAI_API_KEY=sk-existing-real-key
OPENROUTER_API_KEY='sk-or-existing # quoted'
EOF
set +e
(
  cd "${T3}"
  HONEY_STARTER_INSTALL_DIR="${T3}" \
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${S3}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.3.out 2>&1
RC3=$?
set -e
[ "${RC3}" -eq 0 ] || bad "secret-preservation run exited ${RC3}"
if grep -q '^OPENAI_API_KEY=sk-existing-real-key$' "${T3}/.env"; then
  ok "existing real OPENAI_API_KEY preserved with no explicit value (never downgraded)"
else
  bad "existing OPENAI_API_KEY was lost/downgraded:"
  grep 'OPENAI' "${T3}/.env" | sed 's/^/    | /' >&2
fi
if grep -Fq "OPENROUTER_API_KEY='sk-or-existing # quoted'" "${T3}/.env"; then
  ok "existing OPENROUTER_API_KEY line preserved byte-exact (never prompted)"
else
  bad "OPENROUTER_API_KEY line changed:"
  grep 'OPENROUTER' "${T3}/.env" | sed 's/^/    | /' >&2
fi
# explicit new value replaces the old line
cat > "${T3}/.env" <<'EOF'
OPENAI_API_KEY=sk-old-to-replace
EOF
set +e
(
  cd "${T3}"
  HONEY_STARTER_INSTALL_DIR="${T3}" \
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  OPENAI_API_KEY='sk-new-explicit' \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${S3}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.3b.out 2>&1
set -e
if grep -Fq "OPENAI_API_KEY=sk-new-explicit" "${T3}/.env" \
  && ! grep -q 'sk-old-to-replace' "${T3}/.env"; then
  ok "explicit new key replaced the old line"
else
  bad "explicit key replace failed:"
  grep 'OPENAI' "${T3}/.env" | sed 's/^/    | /' >&2
fi
rm -rf "${T3}" "${S3}"

# ---------------------------------------------------------------------------
# 4. custom provider with env base URL; model passthrough
# ---------------------------------------------------------------------------
T4="$(fresh_tree)"
S4="$(mktemp -d)"
set +e
(
  cd "${T4}"
  HONEY_STARTER_INSTALL_DIR="${T4}" \
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=custom \
  HD_AI_BASE_URL='https://my.endpoint.example/v1' HD_AI_MODEL='my-model-1' \
  OPENAI_API_KEY='sk-custom-key' \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${S4}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.4.out 2>&1
RC4=$?
set -e
[ "${RC4}" -eq 0 ] || bad "custom-provider dry-run exited ${RC4}"
if grep -q '^HD_AI_BASE_URL=https://my.endpoint.example/v1$' "${T4}/.env" \
  && grep -Fq 'OPENAI_API_KEY=sk-custom-key' "${T4}/.env"; then
  ok "custom provider wrote HD_AI_BASE_URL + key"
else
  bad "custom provider .env mismatch:"
  sed 's/^/    | /' "${T4}/.env" >&2
fi
if grep -q '^HD_AI_MODEL=my-model-1$' "${T4}/.env"; then
  ok "HD_AI_MODEL passthrough written"
else
  bad "HD_AI_MODEL not written"
fi
rm -rf "${T4}" "${S4}"

# ---------------------------------------------------------------------------
# 5. explicit HD_CONFIG_CHECK_INTERVAL override is honored
# ---------------------------------------------------------------------------
T5="$(fresh_tree)"
S5="$(mktemp -d)"
set +e
(
  cd "${T5}"
  HONEY_STARTER_INSTALL_DIR="${T5}" \
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 \
  HD_CONFIG_CHECK_INTERVAL=1m HD_STATE_DIR="${S5}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.5.out 2>&1
set -e
if grep -q '^HD_CONFIG_CHECK_INTERVAL=1m$' "${T5}/.env"; then
  ok "explicit HD_CONFIG_CHECK_INTERVAL=1m written (user override honored)"
else
  bad "explicit HD_CONFIG_CHECK_INTERVAL not written"
fi
rm -rf "${T5}" "${S5}"

# ---------------------------------------------------------------------------
# 6. validation failures die
# ---------------------------------------------------------------------------
T6="$(fresh_tree)"
S6="$(mktemp -d)"
assert_rc "bad HONEY_NS (slash) rejected" 1 bash -c "
  cd '${T6}' && HONEY_STARTER_INSTALL_DIR='${T6}' HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS='bad/ns' HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR='${S6}' \
  bash scripts/setup.sh --dry-run"
assert_rc "bad HD_API_HOST_PORT (non-integer) rejected" 1 bash -c "
  cd '${T6}' && HONEY_STARTER_INSTALL_DIR='${T6}' HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  HD_API_HOST_PORT=notaport HD_UI_HOST_PORT=8090 HD_STATE_DIR='${S6}' \
  bash scripts/setup.sh --dry-run"
assert_rc "bad HD_AI_BASE_URL (non-http) rejected" 1 bash -c "
  cd '${T6}' && HONEY_STARTER_INSTALL_DIR='${T6}' HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=custom \
  HD_AI_BASE_URL='ftp://nope' HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 \
  HD_STATE_DIR='${S6}' bash scripts/setup.sh --dry-run"
rm -rf "${T6}" "${S6}"

# ---------------------------------------------------------------------------
# 7. missing-required-var error path (custom without HD_AI_BASE_URL)
# ---------------------------------------------------------------------------
T7="$(fresh_tree)"
S7="$(mktemp -d)"
set +e
(
  cd "${T7}"
  HONEY_STARTER_INSTALL_DIR="${T7}" HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=custom \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${S7}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.7.out 2>&1
RC7=$?
set -e
if [ "${RC7}" -eq 1 ] && grep -q 'HD_AI_BASE_URL' /tmp/setup-dryrun.7.out; then
  ok "missing required HD_AI_BASE_URL exits 1 and lists the variable"
else
  bad "missing-var error path (rc=${RC7}):"
  sed 's/^/    | /' /tmp/setup-dryrun.7.out >&2
fi
rm -rf "${T7}" "${S7}"

# ---------------------------------------------------------------------------
# 8. no-tty guidance message (no answers file, no tty, no NONINTERACTIVE flag)
# ---------------------------------------------------------------------------
T8="$(fresh_tree)"
S8="$(mktemp -d)"
if command -v setsid >/dev/null 2>&1; then
  set +e
  (
    cd "${T8}"
    setsid env -i HOME="${HOME}" PATH="${PATH}" \
      HONEY_STARTER_INSTALL_DIR="${T8}" HD_STATE_DIR="${S8}" \
      bash scripts/setup.sh --dry-run < /dev/null
  ) >/tmp/setup-dryrun.8.out 2>&1
  RC8=$?
  set -e
  if [ "${RC8}" -eq 1 ] && grep -q 'run in a terminal, or set HONEY_STARTER_NONINTERACTIVE=1' /tmp/setup-dryrun.8.out; then
    ok "no-tty + not-non-interactive prints the guidance message and exits 1"
  else
    bad "no-tty guidance (rc=${RC8}):"
    sed 's/^/    | /' /tmp/setup-dryrun.8.out >&2
  fi
else
  echo "skip - setsid unavailable (no-tty assertion not run)"
fi
rm -rf "${T8}" "${S8}"

# ---------------------------------------------------------------------------
# 9. interactive branch via HONEY_STARTER_ANSWERS_FILE (fresh tree, custom)
# ---------------------------------------------------------------------------
T9="$(fresh_tree)"
S9="$(mktemp -d)"
printf 'ansns\nansuser\ncustom\nhttps://ans.example.com/v1\nsk-answers-key\n9300\n9390\n' \
  > /tmp/setup-dryrun.answers
set +e
(
  cd "${T9}"
  env -i HOME="${HOME}" PATH="${PATH}" \
    HONEY_STARTER_INSTALL_DIR="${T9}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.answers \
    HD_STATE_DIR="${S9}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.9.out 2>&1
RC9=$?
set -e
if [ "${RC9}" -eq 0 ] \
  && grep -q '^HONEY_NS=ansns$' "${T9}/.env" \
  && grep -q '^HONEY_USER=ansuser$' "${T9}/.env" \
  && grep -q '^HD_AI_BASE_URL=https://ans.example.com/v1$' "${T9}/.env" \
  && grep -Fq 'OPENAI_API_KEY=sk-answers-key' "${T9}/.env" \
  && grep -q '^HD_API_HOST_PORT=9300$' "${T9}/.env" \
  && grep -q '^HD_UI_HOST_PORT=9390$' "${T9}/.env"; then
  ok "answers-file interactive branch produced the expected .env"
else
  bad "answers-file branch (rc=${RC9}):"
  sed 's/^/    | /' /tmp/setup-dryrun.9.out >&2
  sed 's/^/    | /' "${T9}/.env" >&2
fi
rm -rf "${T9}" "${S9}"

# ---------------------------------------------------------------------------
echo ""
if [ "${FAIL}" -eq 0 ]; then
  echo "=== setup-dryrun: ${PASS} checks passed ==="
else
  echo "=== setup-dryrun: ${FAIL} checks FAILED (${PASS} passed) ===" >&2
fi
[ "${FAIL}" -eq 0 ]

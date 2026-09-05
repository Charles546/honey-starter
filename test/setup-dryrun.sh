#!/usr/bin/env bash
# setup-dryrun.sh — no-docker unit/dry-run tests for scripts/setup.sh (the
# guided single-command installer; Phase 4 + Phase 5 multi-instance + AI model).
#
# Hermetic: the tree under test is copied into a throwaway mktemp dir and
# setup.sh is executed against THAT copy with a temp HONEY_STARTER_INSTALL_DIR
# and HD_STATE_DIR, always with --dry-run. Nothing is ever written into the
# dev checkout, .env / .honey-starter included. No docker is required (the
# --dry-run preflight treats docker as informational).
#
# Covered contracts:
#   * fresh non-interactive run writes .env (chmod 600) with correct values
#     (incl. the HD_AI_MODEL=gpt-5.4-mini pin), no prompts attempted, secrets
#     masked in the summary
#   * byte-exact round-trip across a second run: seeded .env with comments +
#     unmanaged keys + managed keys keeps unmanaged lines byte-identical while
#     managed values are updated in place; mode stays 600; skip writes no
#     HD_AI_MODEL line
#   * shell-safe quoting of a value containing # and spaces (single-quoted)
#   * secret replace-only-on-explicit-value (no downgrade, no loss on re-run)
#   * validation failures (bad HONEY_NS, bad port, bad base URL, bad model) die
#   * missing-required-var error path (custom provider without HD_AI_BASE_URL)
#   * no-tty guidance message
#   * the interactive branch via HONEY_STARTER_ANSWERS_FILE, incl. the Phase 5
#     answers-file schema with the model line (T9)
#   * HD_CONFIG_CHECK_INTERVAL only written on explicit override; otherwise
#     absent (compose default 30m applies by omission)
#   * Phase 5 target selection:
#     - bootstrap precedence: a positional <dir> wins over the env, and the
#       env wins over the default (network-free: tree_is_valid skips the
#       download)
#     - on-disk branch 2 IGNORES HONEY_STARTER_INSTALL_DIR (key user-spec
#       test): a no-<dir> run inside a tree stays at that tree
#     - in-place `setup .`
#     - `setup .` from an outside empty dir materializes a new instance
#       (exclusions verified; source untouched)
#     - `setup .` from an outside non-empty no-layout dir dies rc 1
#     - on-disk positional manages an EXISTING instance (target prefilled,
#       invoking tree untouched)
#     - on-disk positional materializes a NEW instance from the invoked tree
#     - on-disk positional MERGES a pre-Phase-4 tree (layout present, no
#       setup.sh): .env / .honey-starter sentinels preserved, the tree gains
#       setup.sh, the invoking tree stays untouched
#   * Phase 5 AI model matrix (three-way HD_AI_MODEL semantics, skip behavior,
#     pin / no-pin, validation): an INVALID MODEL DIES via env AND answers
#     file AND a typed answer (pty); a VALID model NEVER dies (cross-
#     contamination guard: an invalid EARLIER prompt must not poison the model
#     block's global flags)
#   * branch-3 directory prompt hermetics (pty): ~/ default display (never the
#     spilled absolute path), Enter -> re-exec -> branch-2-in-place, bare ~ ->
#     $HOME at the prompt AND as an on-disk positional
#   * argument parsing: `--` end-of-flags, two positionals die, unknown option
#
# Run: bash test/setup-dryrun.sh   (or: make setup-dryrun)
#
# python3 is OPTIONAL and used only by the pty harness (test/pty-helper.py) for
# the interactive branch-3 prompt / typed-invalid-model tests (17k/19/20);
# when python3 is absent those checks are skipped cleanly. setup.sh itself
# never needs python3.
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
# Phase 5 Requirement 3: a fresh openai NI run pins the documented model
# (HD_AI_MODEL unset -> gpt-5.4-mini; compose already defaults it, so the
# explicit line is runtime-identical).
if grep -q '^HD_AI_MODEL=gpt-5.4-mini$' "${T1}/.env"; then
  ok "fresh openai NI run writes the HD_AI_MODEL=gpt-5.4-mini pin (Requirement 3)"
else
  bad "HD_AI_MODEL pin line missing from fresh openai .env:"
  grep '^HD_AI_MODEL' "${T1}/.env" 2>/dev/null | sed 's/^/    | /' >&2 || true
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
if grep -q '^HD_AI_MODEL=' "${T2}/.env"; then
  bad "skip provider wrote an HD_AI_MODEL line (no model question for skip)"
else
  ok "skip provider wrote no HD_AI_MODEL line (model only for openai/custom)"
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
# Phase 5 answers-file schema: HONEY_NS, HONEY_USER, provider, MODEL
# (openai/custom only; empty = accept default -> pin), base URL (custom only),
# API key (openai/custom), ports. NO install-dir line.
printf 'ansns\nansuser\ncustom\nans-custom-model\nhttps://ans.example.com/v1\nsk-answers-key\n9300\n9390\n' \
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
  && grep -q '^HD_AI_MODEL=ans-custom-model$' "${T9}/.env" \
  && grep -q '^HD_AI_BASE_URL=https://ans.example.com/v1$' "${T9}/.env" \
  && grep -Fq 'OPENAI_API_KEY=sk-answers-key' "${T9}/.env" \
  && grep -q '^HD_API_HOST_PORT=9300$' "${T9}/.env" \
  && grep -q '^HD_UI_HOST_PORT=9390$' "${T9}/.env"; then
  ok "answers-file interactive branch produced the expected .env (custom model + base URL)"
else
  bad "answers-file branch (rc=${RC9}):"
  sed 's/^/    | /' /tmp/setup-dryrun.9.out >&2
  sed 's/^/    | /' "${T9}/.env" >&2
fi
rm -rf "${T9}" "${S9}"

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 10. Phase 5 bootstrap precedence (network-free). Copy ONLY setup.sh into an
#     empty dir (forces bootstrap mode: BASH_SOURCE is a real file but the tree
#     markers are absent). Two valid trees A/B are pre-made; tree_is_valid
#     short-circuits the download. The positional <dir> must WIN over
#     HONEY_STARTER_INSTALL_DIR, and the env must win over the default.
# ---------------------------------------------------------------------------
BT="$(mktemp -d)"
cp "${SETUP_SRC}" "${BT}/setup.sh"
TA="$(fresh_tree)"
TB="$(fresh_tree)"
SHOME="$(mktemp -d)"
S10="$(mktemp -d)"
set +e
(
  cd "${BT}"
  HOME="${SHOME}" \
  HONEY_STARTER_INSTALL_DIR="${TA}" HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${S10}" \
  bash setup.sh "${TB}" --dry-run
) >/tmp/setup-dryrun.b1.out 2>&1
RC10=$?
set -e
if [ "${RC10}" -eq 0 ] && [ -f "${TB}/.env" ] && [ ! -f "${TA}/.env" ] \
  && [ ! -d "${SHOME}/honey-starter" ]; then
  ok "bootstrap precedence: positional <dir> wins over HONEY_STARTER_INSTALL_DIR (.env in ${TB})"
else
  bad "bootstrap precedence (positional vs env) rc=${RC10}:"
  sed 's/^/    | /' /tmp/setup-dryrun.b1.out >&2 || true
fi
set +e
(
  cd "${BT}"
  HOME="${SHOME}" \
  HONEY_STARTER_INSTALL_DIR="${TA}" HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${S10}" \
  bash setup.sh --dry-run
) >/tmp/setup-dryrun.b2.out 2>&1
RC11=$?
set -e
if [ "${RC11}" -eq 0 ] && [ -f "${TA}/.env" ] \
  && [ ! -d "${SHOME}/honey-starter" ]; then
  ok "bootstrap precedence: HONEY_STARTER_INSTALL_DIR=... wins over the default (~/honey-starter)"
else
  bad "bootstrap precedence (env vs default) rc=${RC11}:"
  sed 's/^/    | /' /tmp/setup-dryrun.b2.out >&2 || true
fi
rm -rf "${BT}" "${TA}" "${TB}" "${SHOME}" "${S10}"

# ---------------------------------------------------------------------------
# 11. On-disk branch 2 IGNORES HONEY_STARTER_INSTALL_DIR (key user-spec test):
#     a no-<dir> run inside a valid tree must re-set-up THAT tree in place even
#     when the env points elsewhere; the other dir stays untouched.
# ---------------------------------------------------------------------------
T11="$(fresh_tree)"
S11="$(mktemp -d)"
OTHER11="$(mktemp -d)"
set +e
(
  cd "${T11}"
  HONEY_STARTER_INSTALL_DIR="${OTHER11}" HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${S11}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.b3.out 2>&1
RC11=$?
set -e
if [ "${RC11}" -eq 0 ] && [ -f "${T11}/.env" ] \
  && [ ! -f "${OTHER11}/.env" ] && [ -z "$(ls -A "${OTHER11}")" ]; then
  ok "on-disk branch 2 env-ignored: HONEY_STARTER_INSTALL_DIR=/other does NOT relocate; tree managed in place, /other untouched"
else
  bad "branch 2 env-ignored rc=${RC11}:"
  sed 's/^/    | /' /tmp/setup-dryrun.b3.out >&2 || true
fi
rm -rf "${T11}" "${S11}" "${OTHER11}"

# ---------------------------------------------------------------------------
# 12. In-place `setup .` (inside the tree -> pure in-place, no copy/mv)
# ---------------------------------------------------------------------------
T12="$(fresh_tree)"
S12="$(mktemp -d)"
set +e
(
  cd "${T12}"
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${S12}" \
  bash scripts/setup.sh . --dry-run
) >/tmp/setup-dryrun.b4.out 2>&1
RC12=$?
set -e
if [ "${RC12}" -eq 0 ] && [ -f "${T12}/.env" ] \
  && ! grep -q 'materialized' /tmp/setup-dryrun.b4.out; then
  ok "in-place setup . writes .env at the tree (no materialize/copy)"
else
  bad "in-place setup . rc=${RC12}:"
  sed 's/^/    | /' /tmp/setup-dryrun.b4.out >&2 || true
fi
rm -rf "${T12}" "${S12}"

# ---------------------------------------------------------------------------
# 13. `setup .` from an outside EMPTY dir -> materialize a NEW instance. The
#     source tree is COPIED (never moved), its .env marker must NOT reach the
#     fresh target; no .git/.honey-starter either; source stays intact.
# ---------------------------------------------------------------------------
TSRC13="$(fresh_tree)"
S13="$(mktemp -d)"
EMPTY13="$(mktemp -d)"
printf '# src-marker\nOPENAI_API_KEY=sk-source-secret\n' > "${TSRC13}/.env"
set +e
(
  cd "${EMPTY13}"
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${S13}" \
  bash "${TSRC13}/scripts/setup.sh" . --dry-run
) >/tmp/setup-dryrun.b5.out 2>&1
RC13=$?
set -e
if [ "${RC13}" -eq 0 ] && [ -f "${EMPTY13}/.env" ] \
  && [ -f "${EMPTY13}/scripts/setup.sh" ] \
  && [ ! -e "${EMPTY13}/.git" ] && [ ! -e "${EMPTY13}/.honey-starter" ] \
  && ! grep -q 'sk-source-secret' "${EMPTY13}/.env" \
  && grep -q 'src-marker' "${TSRC13}/.env"; then
  ok "setup . outside empty dir materialized a NEW instance (fresh target does NOT inherit the source .env; source untouched)"
else
  bad "setup . empty-dir materialize rc=${RC13}:"
  sed 's/^/    | /' /tmp/setup-dryrun.b5.out >&2 || true
fi
rm -rf "${TSRC13}" "${S13}" "${EMPTY13}"

# ---------------------------------------------------------------------------
# 14. `setup .` from an outside NON-EMPTY no-layout dir -> dies rc 1 with the
#     "not a honey-starter tree" message; the dir is never destructively
#     touched.
# ---------------------------------------------------------------------------
TSRC14="$(fresh_tree)"
S14="$(mktemp -d)"
NOISE14="$(mktemp -d)"
touch "${NOISE14}/random.txt"
assert_rc "setup . outside a non-empty no-layout dir dies (never destructive)" 1 bash -c "
  cd '${NOISE14}' && HONEY_STARTER_NONINTERACTIVE=1 \\
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \\
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR='${S14}' \\
  bash '${TSRC14}/scripts/setup.sh' . --dry-run"
if [ -f "${NOISE14}/random.txt" ]; then
  ok "non-empty no-layout dir left intact after the die"
else
  bad "non-empty no-layout dir was modified (never destructive)"
fi
rm -rf "${TSRC14}" "${S14}" "${NOISE14}"

# ---------------------------------------------------------------------------
# 15. On-disk positional -> manage an EXISTING instance: the TARGET tree's .env
#     prefills the questionnaire (HONEY_NS/HD_AI_MODEL/ports preserved from the
#     target), and the invoking/source tree is untouched (non-destructive reuse).
# ---------------------------------------------------------------------------
TSRC15="$(fresh_tree)"
TDST15="$(fresh_tree)"
S15="$(mktemp -d)"
printf 'HONEY_NS=otherns\nHONEY_USER=otheruser\nHD_API_HOST_PORT=9400\nHD_UI_HOST_PORT=9490\nHD_AI_MODEL=custom-model-x\n' > "${TDST15}/.env"
printf '# source-marker\nHONEY_NS=srcns\nOPENAI_API_KEY=sk-source-keep\n' > "${TSRC15}/.env"
cp "${TSRC15}/.env" /tmp/setup-dryrun.src15.env
set +e
(
  cd "${TSRC15}"
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_AI_PROVIDER=openai \
  HD_API_HOST_PORT=9400 HD_UI_HOST_PORT=9490 HD_STATE_DIR="${S15}" \
  bash scripts/setup.sh "${TDST15}" --dry-run
) >/tmp/setup-dryrun.b6.out 2>&1
RC15=$?
set -e
if [ "${RC15}" -eq 0 ] && grep -q '^HONEY_NS=otherns$' "${TDST15}/.env" \
  && grep -q '^HD_AI_MODEL=custom-model-x$' "${TDST15}/.env" \
  && grep -q '^HD_API_HOST_PORT=9400$' "${TDST15}/.env"; then
  ok "manage-existing: target .env prefilled from the TARGET tree (ns/model/ports preserved)"
else
  bad "manage-existing prefill rc=${RC15}:"
  sed 's/^/    | /' /tmp/setup-dryrun.b6.out >&2 || true
  grep -E '^(HONEY_NS|HD_AI_MODEL|HD_API_HOST_PORT)=' "${TDST15}/.env" 2>/dev/null | sed 's/^/    | /' >&2 || true
fi
if diff -q "${TSRC15}/.env" /tmp/setup-dryrun.src15.env >/dev/null; then
  ok "manage-existing: invoking/source tree .env untouched (non-destructive)"
else
  bad "manage-existing source tree modified:"
  diff -u /tmp/setup-dryrun.src15.env "${TSRC15}/.env" >&2 || true
fi
rm -rf "${TSRC15}" "${TDST15}" "${S15}"

# ---------------------------------------------------------------------------
# 16. On-disk positional -> NEW instance: materialized from the invoked tree
#     (exclusions verified), .env written at the target, source untouched.
# ---------------------------------------------------------------------------
TSRC16="$(fresh_tree)"
S16="$(mktemp -d)"
NEW16="$(mktemp -d)/brand-new"
set +e
(
  cd "${TSRC16}"
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=newns HONEY_USER=newuser HONEY_AI_PROVIDER=custom \
  HD_AI_BASE_URL=https://new.example.com/v1 OPENAI_API_KEY=sk-new-inst \
  HD_API_HOST_PORT=9500 HD_UI_HOST_PORT=9590 HD_STATE_DIR="${S16}" \
  bash scripts/setup.sh "${NEW16}" --dry-run
) >/tmp/setup-dryrun.b7.out 2>&1
RC16=$?
set -e
if [ "${RC16}" -eq 0 ] && [ -f "${NEW16}/.env" ] \
  && [ -f "${NEW16}/scripts/setup.sh" ] \
  && [ ! -e "${NEW16}/.git" ] && [ ! -e "${NEW16}/.honey-starter" ] \
  && grep -q '^HONEY_NS=newns$' "${NEW16}/.env" \
  && [ ! -f "${TSRC16}/.env" ]; then
  ok "positional new instance materialized from the invoked tree (exclusions; source untouched)"
else
  bad "positional new instance rc=${RC16}:"
  sed 's/^/    | /' /tmp/setup-dryrun.b7.out >&2 || true
fi
rm -rf "${TSRC16}" "${S16}" "$(dirname "${NEW16}")"

# ---------------------------------------------------------------------------
# 16b. On-disk positional -> pre-Phase-4 tree (valid layout, NO scripts/setup.sh)
#      is merged over in place: .env / .honey-starter sentinels preserved, the
#      tree gains scripts/setup.sh, the invoking tree stays untouched.
# ---------------------------------------------------------------------------
TSRC16B="$(fresh_tree)"; TPRE16B="$(fresh_tree)"; S16B="$(mktemp -d)"
rm -f "${TPRE16B}/scripts/setup.sh"     # make it pre-Phase-4
printf 'HONEY_NS=oldns\nHONEY_USER=olduser\nHD_API_HOST_PORT=9400\nHD_UI_HOST_PORT=9490\nHD_AI_MODEL=old-model\n' > "${TPRE16B}/.env"
mkdir -p "${TPRE16B}/.honey-starter"
printf 'SENTINEL-ROOT-TOKEN\n' > "${TPRE16B}/.honey-starter/root_token"
printf '# src-marker\nOPENAI_API_KEY=sk-source-keep\n' > "${TSRC16B}/.env"
cp "${TSRC16B}/.env" /tmp/setup-dryrun.src16b.env
set +e
(
  cd "${TSRC16B}"
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_AI_PROVIDER=openai \
  HD_STATE_DIR="${S16B}" \
  bash scripts/setup.sh "${TPRE16B}" --dry-run
) >/tmp/setup-dryrun.16b.out 2>&1
RC16B=$?
set -e
if [ "${RC16B}" -eq 0 ] \
  && [ -f "${TPRE16B}/scripts/setup.sh" ] \
  && grep -q '^HONEY_NS=oldns$' "${TPRE16B}/.env" \
  && grep -q '^HD_AI_MODEL=old-model$' "${TPRE16B}/.env" \
  && grep -q '^HD_API_HOST_PORT=9400$' "${TPRE16B}/.env" \
  && [ -f "${TPRE16B}/.honey-starter/root_token" ] \
  && ! grep -q 'src-marker' "${TPRE16B}/.env"; then
  ok "managed pre-Phase-4 tree via positional: merged in place, .env/.honey-starter sentinels preserved, tree gained setup.sh"
else
  bad "pre-Phase-4 merge rc=${RC16B}:"
  sed 's/^/    | /' /tmp/setup-dryrun.16b.out >&2 || true
fi
if diff -q "${TSRC16B}/.env" /tmp/setup-dryrun.src16b.env >/dev/null; then
  ok "pre-Phase-4 merge: invoking/source tree .env untouched (non-destructive)"
else
  bad "pre-Phase-4 merge source tree modified:"
  diff -u /tmp/setup-dryrun.src16b.env "${TSRC16B}/.env" >&2 || true
fi
rm -rf "${TSRC16B}" "${TPRE16B}" "${S16B}"

# ---------------------------------------------------------------------------
# 17. Phase 5 AI model matrix (three-way HD_AI_MODEL semantics). All
#     network-free, hermetic, --dry-run.
# ---------------------------------------------------------------------------
# 17a. answers-file openai writes the model answer
T17A="$(fresh_tree)"; S17A="$(mktemp -d)"
printf 'ansns\nansuser\nopenai\nft:gpt-4o:org:custom\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.ans17a
set +e
(
  cd "${T17A}"
  env -i HOME="${HOME}" PATH="${PATH}" \
    HONEY_STARTER_INSTALL_DIR="${T17A}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.ans17a HD_STATE_DIR="${S17A}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.17a.out 2>&1
RC17A=$?
set -e
if [ "${RC17A}" -eq 0 ] && grep -q '^HD_AI_MODEL=ft:gpt-4o:org:custom$' "${T17A}/.env"; then
  ok "model matrix: answers-file openai model line written (ft:gpt-4o:org:custom)"
else
  bad "model matrix 17a rc=${RC17A}:"; tail -5 /tmp/setup-dryrun.17a.out >&2 || true
fi
rm -rf "${T17A}" "${S17A}"

# 17b. answers-file EMPTY model line = accept default -> pin written
T17B="$(fresh_tree)"; S17B="$(mktemp -d)"
printf 'ansns\nansuser\nopenai\n\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.ans17b
set +e
(
  cd "${T17B}"
  env -i HOME="${HOME}" PATH="${PATH}" \
    HONEY_STARTER_INSTALL_DIR="${T17B}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.ans17b HD_STATE_DIR="${S17B}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.17b.out 2>&1
RC17B=$?
set -e
if [ "${RC17B}" -eq 0 ] && grep -q '^HD_AI_MODEL=gpt-5.4-mini$' "${T17B}/.env"; then
  ok "model matrix: empty model line in the answers file -> default pin written"
else
  bad "model matrix 17b rc=${RC17B}:"; tail -5 /tmp/setup-dryrun.17b.out >&2 || true
fi
rm -rf "${T17B}" "${S17B}"

# 17c. skip consumes NO model line (and none is written)
T17C="$(fresh_tree)"; S17C="$(mktemp -d)"
printf 'ansns\nansuser\nskip\n9300\n9390\n' > /tmp/setup-dryrun.ans17c
set +e
(
  cd "${T17C}"
  env -i HOME="${HOME}" PATH="${PATH}" \
    HONEY_STARTER_INSTALL_DIR="${T17C}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.ans17c HD_STATE_DIR="${S17C}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.17c.out 2>&1
RC17C=$?
set -e
if [ "${RC17C}" -eq 0 ] && ! grep -q '^HD_AI_MODEL=' "${T17C}/.env"; then
  ok "model matrix: skip consumes no model line; none written"
else
  bad "model matrix 17c rc=${RC17C}:"; tail -5 /tmp/setup-dryrun.17c.out >&2 || true
fi
rm -rf "${T17C}" "${S17C}"

# 17d. skip + non-empty HD_AI_MODEL env -> override written (passthrough wins)
T17D="$(fresh_tree)"; S17D="$(mktemp -d)"
printf 'HD_AI_MODEL=old-override\n' > "${T17D}/.env"
printf 'ansns\nansuser\nskip\n9300\n9390\n' > /tmp/setup-dryrun.ans17d
set +e
(
  cd "${T17D}"
  env -i HOME="${HOME}" PATH="${PATH}" HD_AI_MODEL=custom-override \
    HONEY_STARTER_INSTALL_DIR="${T17D}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.ans17d HD_STATE_DIR="${S17D}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.17d.out 2>&1
RC17D=$?
set -e
if [ "${RC17D}" -eq 0 ] && grep -q '^HD_AI_MODEL=custom-override$' "${T17D}/.env"; then
  ok "model matrix: skip + non-empty HD_AI_MODEL -> override written (passthrough wins over all providers)"
else
  bad "model matrix 17d rc=${RC17D}:"; tail -5 /tmp/setup-dryrun.17d.out >&2 || true
fi
rm -rf "${T17D}" "${S17D}"

# 17e. skip + HD_AI_MODEL= (explicit empty) + existing override -> line REMOVED
T17E="$(fresh_tree)"; S17E="$(mktemp -d)"
printf 'HD_AI_MODEL=old-override\n' > "${T17E}/.env"
printf 'ansns\nansuser\nskip\n9300\n9390\n' > /tmp/setup-dryrun.ans17e
set +e
(
  cd "${T17E}"
  env -i HOME="${HOME}" PATH="${PATH}" HD_AI_MODEL= \
    HONEY_STARTER_INSTALL_DIR="${T17E}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.ans17e HD_STATE_DIR="${S17E}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.17e.out 2>&1
RC17E=$?
set -e
if [ "${RC17E}" -eq 0 ] && ! grep -q '^HD_AI_MODEL=' "${T17E}/.env"; then
  ok "model matrix: skip + HD_AI_MODEL= (explicit-empty) removes an existing override line"
else
  bad "model matrix 17e rc=${RC17E}:"; tail -5 /tmp/setup-dryrun.17e.out >&2 || true
fi
rm -rf "${T17E}" "${S17E}"

# 17f. HD_AI_MODEL= (explicit empty) + openai + existing override: the QUESTION
#      is SKIPPED and the existing override is NOT kept (line removed)
T17F="$(fresh_tree)"; S17F="$(mktemp -d)"
printf 'HD_AI_MODEL=old-pin\n' > "${T17F}/.env"
printf 'ansns\nansuser\nopenai\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.ans17f
set +e
(
  cd "${T17F}"
  env -i HOME="${HOME}" PATH="${PATH}" HD_AI_MODEL= \
    HONEY_STARTER_INSTALL_DIR="${T17F}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.ans17f HD_STATE_DIR="${S17F}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.17f.out 2>&1
RC17F=$?
set -e
if [ "${RC17F}" -eq 0 ] && ! grep -q '^HD_AI_MODEL=' "${T17F}/.env"; then
  ok "model matrix: HD_AI_MODEL= (explicit-empty) + openai skips the question and does NOT re-keep the override"
else
  bad "model matrix 17f rc=${RC17F}:"; tail -5 /tmp/setup-dryrun.17f.out >&2 || true
fi
rm -rf "${T17F}" "${S17F}"

# 17g. invalid model via ENV (non-interactive) dies rc 1
T17G="$(fresh_tree)"; S17G="$(mktemp -d)"
assert_rc "model matrix: invalid env HD_AI_MODEL (NI) dies rc 1" 1 bash -c "
  cd '${T17G}' && HONEY_STARTER_INSTALL_DIR='${T17G}' HONEY_STARTER_NONINTERACTIVE=1 \\
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \\
  HD_AI_MODEL='bad model' HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 \\
  HD_STATE_DIR='${S17G}' bash scripts/setup.sh --dry-run"
rm -rf "${T17G}" "${S17G}"

# 17h. invalid model via the ANSWERS FILE DIES (the real die, not a downstream
# failure): "bad model" is invalid, and the retry loop must not adopt a later
# line (e.g. the port 9300, which would otherwise validate as a model string)
# nor re-pin. The run exits 1 ON THE MODEL, before any .env write.
T17H="$(fresh_tree)"; S17H="$(mktemp -d)"
printf 'ansns\nansuser\nopenai\nbad model\n9300\n9390\n' > /tmp/setup-dryrun.ans17h
set +e
(
  cd "${T17H}" && env -i HOME="${HOME}" PATH="${PATH}" \
  HONEY_STARTER_INSTALL_DIR="${T17H}" \
  HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.ans17h HD_STATE_DIR="${S17H}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.17h.out 2>&1
RC17H=$?
set -e
if [ "${RC17H}" -eq 1 ] \
  && grep -q "invalid HD_AI_MODEL: 'bad model'" /tmp/setup-dryrun.17h.out \
  && [ ! -f "${T17H}/.env" ]; then
  ok "model matrix: invalid model via the answers file DIES on the model (rc 1, real die, no .env)"
else
  bad "model matrix 17h rc=${RC17H} (want the invalid-HD_AI_MODEL die):"
  sed 's/^/    | /' /tmp/setup-dryrun.17h.out >&2 || true
fi
rm -rf "${T17H}" "${S17H}"

# 17i. NI unset HD_AI_MODEL (custom) -> pin written (regression-guarded)
T17I="$(fresh_tree)"; S17I="$(mktemp -d)"
set +e
(
  cd "${T17I}"
  HONEY_STARTER_INSTALL_DIR="${T17I}" HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=custom \
  HD_AI_BASE_URL=https://nb.example/v1 HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 \
  HD_STATE_DIR="${S17I}" bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.17i.out 2>&1
RC17I=$?
set -e
if [ "${RC17I}" -eq 0 ] && grep -q '^HD_AI_MODEL=gpt-5.4-mini$' "${T17I}/.env"; then
  ok "model matrix: NI unset HD_AI_MODEL (custom) writes the gpt-5.4-mini pin"
else
  bad "model matrix 17i rc=${RC17I}:"; tail -5 /tmp/setup-dryrun.17i.out >&2 || true
fi
rm -rf "${T17I}" "${S17I}"

# 17j. existing .env override kept when env unset (openai re-run; managed)
T17J="$(fresh_tree)"; S17J="$(mktemp -d)"
printf 'HD_AI_MODEL=my-existing-model\n' > "${T17J}/.env"
set +e
(
  cd "${T17J}"
  HONEY_STARTER_INSTALL_DIR="${T17J}" HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 \
  HD_STATE_DIR="${S17J}" bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.17j.out 2>&1
RC17J=$?
set -e
if [ "${RC17J}" -eq 0 ] && grep -q '^HD_AI_MODEL=my-existing-model$' "${T17J}/.env"; then
  ok "model matrix: existing .env HD_AI_MODEL override kept when env unset (openai re-run)"
else
  bad "model matrix 17j rc=${RC17J}:"; tail -5 /tmp/setup-dryrun.17j.out >&2 || true
fi
rm -rf "${T17J}" "${S17J}"

# 17k. invalid model TYPED at the interactive prompt DIES too (the documented
# contract covers env, answers file, AND a typed answer). The retry loop must
# not adopt the next pty line (9300 would validate as a model string) nor
# re-pin. Exercised through the pty harness (test/pty-helper.py); skipped
# cleanly when python3 is unavailable.
if command -v python3 >/dev/null 2>&1; then
  T17K="$(fresh_tree)"; S17K="$(mktemp -d)"
  set +e
  (
    cd "${T17K}" && HD_STATE_DIR="${S17K}" \
    python3 "${HERE}/test/pty-helper.py" --on-disk \
      "${T17K}/scripts/setup.sh" "Vault KV namespace" \
      ansns ansuser openai "bad model" 9300 9390 -- --dry-run
  ) >/tmp/setup-dryrun.17k.out 2>&1
  RC17K=$?
  set -e
  if [ "${RC17K}" -eq 1 ] \
    && grep -q "invalid HD_AI_MODEL: 'bad model'" /tmp/setup-dryrun.17k.out \
    && [ ! -f "${T17K}/.env" ]; then
    ok "model matrix: invalid model TYPED at the interactive prompt dies rc 1 (no .env)"
  else
    bad "model matrix 17k rc=${RC17K} (pty interactive invalid model):"
    sed 's/^/    | /' /tmp/setup-dryrun.17k.out >&2 || true
  fi
  rm -rf "${T17K}" "${S17K}"
else
  ok "model matrix: 17k interactive invalid-model die SKIPPED (python3 unavailable)"
fi

# 17l. Cross-contamination regression: an INVALID answer to an EARLIER prompt
# (HONEY_NS / HONEY_USER) must NOT poison a perfectly VALID model via the
# global INVALID_SEEN/INVALID_VALUE flags. The model block resets both flags
# before its own question, so a valid model NEVER dies (and never shows a
# misleading 'invalid HD_AI_MODEL: <value-from-another-prompt>' error). The
# answers file here reproduces the reviewer's probe: 3x invalid ns + 3x
# invalid user (each retry loop consumes exactly 3 lines then defaults) +
# provider openai + the VALID model gpt-valid. Without the reset this rc was 1
# dying on the model; with it the run completes and writes HD_AI_MODEL=gpt-valid.
T17L="$(fresh_tree)"; S17L="$(mktemp -d)"
printf 'bad ns one\nbad ns two\nbad ns three\nbad user one\nbad user two\nbad user three\nopenai\ngpt-valid\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.ans17l
set +e
(
  cd "${T17L}"
  env -i HOME="${HOME}" PATH="${PATH}" \
    HONEY_STARTER_INSTALL_DIR="${T17L}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.ans17l HD_STATE_DIR="${S17L}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.17l.out 2>&1
RC17L=$?
set -e
if [ "${RC17L}" -eq 0 ] \
  && grep -q '^HD_AI_MODEL=gpt-valid$' "${T17L}/.env" \
  && ! grep -q "invalid HD_AI_MODEL" /tmp/setup-dryrun.17l.out; then
  ok "model matrix: valid model never dies after invalid EARLIER answers (cross-contamination regression; HD_AI_MODEL=gpt-valid written)"
else
  bad "model matrix 17l rc=${RC17L} (want rc 0 + HD_AI_MODEL=gpt-valid, no invalid-HD_AI_MODEL die):"
  sed 's/^/    | /' /tmp/setup-dryrun.17l.out >&2 || true
fi
rm -rf "${T17L}" "${S17L}"



# ---------------------------------------------------------------------------
# 18. Argument parsing: `--` end-of-flags, two positionals die, unknown option
#     dies (usage_die -> exit 2).
# ---------------------------------------------------------------------------
T18="$(fresh_tree)"
S18="$(mktemp -d)"
assert_rc "unknown option rejected (exit 2)" 2 bash -c "
  cd '${T18}' && HOME='${HOME}' bash scripts/setup.sh --bogus"
assert_rc "two directory arguments rejected (exit 2)" 2 bash -c "
  cd '${T18}' && HOME='${HOME}' bash scripts/setup.sh a b"
assert_rc "-- ends flag parsing: a --dry-run after -- is a second <dir> (exit 2)" 2 bash -c "
  cd '${T18}' && HOME='${HOME}' bash scripts/setup.sh -- '${T18}' --dry-run"
# `bash -s -- --help`: the `--` ends bash's own option parsing so --help
# reaches the SCRIPT (the piped/bootstrap copy), which prints its own help and
# exits 0. (Without the `--`, `bash -s --help` would be BASH's own --help.)
assert_rc "piped --help reaches the script and exits 0 (bootstrap copy)" 0 bash -c "
  cd '${T18}' && HOME='${HOME}' bash -c 'cat scripts/setup.sh | bash -s -- --help'"
rm -rf "${T18}" "${S18}"

# ---------------------------------------------------------------------------
# 19. Branch-3 directory prompt (pty): the SINGLE standalone/piped bootstrap
#     prompt. Exercises the display form (M3a: "[~/honey-starter]", never the
#     spilled absolute path), Enter-accepts-default, the typed-dir ->
#     re-exec -> branch-2-in-place handoff, and bare "~" (M3b). python3 pty
#     harness; skipped cleanly when python3 is unavailable.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  # 19a. The prompt shows the ~/ default form; Enter accepts it -> the
  #      pre-created $HOME/honey-starter tree is reused (no download) and the
  #      on-disk copy re-runs the questionnaire -> .env written in place. This
  #      also proves the typed/Enter'd dir -> re-exec -> branch-2-in-place flow.
  PH19A="$(mktemp -d)"
  cp -a "${HERE}/." "${PH19A}/honey-starter"
  rm -rf "${PH19A}/honey-starter/.git" "${PH19A}/honey-starter/.honey-starter" "${PH19A}/honey-starter/.env"
  S19A="$(mktemp -d)"
  CWD19A="$(mktemp -d)"
  set +e
  ( cd "${CWD19A}" && env -u HONEY_STARTER_NONINTERACTIVE -u HONEY_STARTER_ANSWERS_FILE \
      -u HONEY_STARTER_INSTALL_DIR HOME="${PH19A}" HD_STATE_DIR="${S19A}" \
      python3 "${HERE}/test/pty-helper.py" --standalone \
        "${HERE}/scripts/setup.sh" "Install directory [" \
        "" ansns ansuser openai modeltest sk-key-pty 9300 9390 -- --dry-run \
  ) >/tmp/setup-dryrun.19a.out 2>&1
  RC19A=$?
  set -e
  if [ "${RC19A}" -eq 0 ] \
    && grep -q 'Install directory \[~/honey-starter\]' /tmp/setup-dryrun.19a.out \
    && ! grep -q "Install directory \[${PH19A}" /tmp/setup-dryrun.19a.out \
    && [ -f "${PH19A}/honey-starter/.env" ] \
    && grep -q '^HONEY_NS=ansns$' "${PH19A}/honey-starter/.env"; then
    ok "branch-3 prompt: shows the ~/ default, Enter accepts it -> re-exec -> branch-2 in place (.env written)"
  else
    bad "branch-3 prompt 19a rc=${RC19A}:"
    sed 's/^/    | /' /tmp/setup-dryrun.19a.out >&2 || true
  fi
  rm -rf "${PH19A}" "${S19A}" "${CWD19A}"

  # 19b. bare "~" typed at the branch-3 prompt resolves to $HOME exactly (NOT
  #      "$PWD/~/..."): with HOME set to a valid tree, "~" -> that tree, reused
  #      in place (no download).
  TH19B="$(mktemp -d)"
  cp -a "${HERE}/." "${TH19B}"
  rm -rf "${TH19B}/.git" "${TH19B}/.honey-starter" "${TH19B}/.env"
  S19B="$(mktemp -d)"
  CWD19B="$(mktemp -d)"
  set +e
  ( cd "${CWD19B}" && env -u HONEY_STARTER_NONINTERACTIVE -u HONEY_STARTER_ANSWERS_FILE \
      -u HONEY_STARTER_INSTALL_DIR HOME="${TH19B}" HD_STATE_DIR="${S19B}" \
      python3 "${HERE}/test/pty-helper.py" --standalone \
        "${HERE}/scripts/setup.sh" "Install directory [" \
        "~" ansns ansuser openai modeltest2 sk-key-pty2 9301 9391 -- --dry-run \
  ) >/tmp/setup-dryrun.19b.out 2>&1
  RC19B=$?
  set -e
  if [ "${RC19B}" -eq 0 ] \
    && [ -f "${TH19B}/.env" ] \
    && grep -q '^HONEY_NS=ansns$' "${TH19B}/.env" \
    && [ ! -e "${CWD19B}/~" ]; then
    ok "branch-3 prompt: bare ~ typed resolves to \$HOME (tree reused in place; no \$PWD/~)"
  else
    bad "branch-3 prompt 19b rc=${RC19B}:"
    sed 's/^/    | /' /tmp/setup-dryrun.19b.out >&2 || true
  fi
  rm -rf "${TH19B}" "${S19B}" "${CWD19B}"
else
  ok "branch-3 prompt hermetics SKIPPED (python3 unavailable)"
fi

# ---------------------------------------------------------------------------
# 20. On-disk positional bare "~" -> $HOME via resolve_arg_path: with HOME set
#     to a valid tree, `setup ~` manages THAT tree (rc 0, .env written there)
#     and no "$PWD/~" directory is ever created.
# ---------------------------------------------------------------------------
T20="$(fresh_tree)"; TH20="$(mktemp -d)"
cp -a "${HERE}/." "${TH20}"
rm -rf "${TH20}/.git" "${TH20}/.honey-starter" "${TH20}/.env"
S20="$(mktemp -d)"
CWD20="$(mktemp -d)"
set +e
(
  cd "${CWD20}" && HOME="${TH20}" HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_AI_PROVIDER=openai HD_STATE_DIR="${S20}" \
  bash "${T20}/scripts/setup.sh" '~' --dry-run
) >/tmp/setup-dryrun.20.out 2>&1
RC20=$?
set -e
if [ "${RC20}" -eq 0 ] \
  && [ -f "${TH20}/.env" ] \
  && [ ! -e "${CWD20}/~" ]; then
  ok "on-disk positional bare ~ resolves to \$HOME and manages that tree in place (no \$PWD/~)"
else
  bad "positional bare ~ rc=${RC20}:"
  sed 's/^/    | /' /tmp/setup-dryrun.20.out >&2 || true
fi
rm -rf "${T20}" "${TH20}" "${S20}" "${CWD20}"

echo ""
if [ "${FAIL}" -eq 0 ]; then
  echo "=== setup-dryrun: ${PASS} checks passed ==="
else
  echo "=== setup-dryrun: ${FAIL} checks FAILED (${PASS} passed) ===" >&2
fi
[ "${FAIL}" -eq 0 ]

#!/usr/bin/env bash
# setup-dryrun.sh — no-docker unit/dry-run tests for scripts/setup.sh (the
# guided single-command installer; Phase 4 + Phase 5 multi-instance + AI model
# + Phase 6 per-instance COMPOSE_PROJECT_NAME persisted in .env + Phase A
# rich-output foundation: emoji/color detection + prefix-only message styling
# with a plain fallback + Phase B TTY-only select-from-list menus for the AI
# provider / AI model questions).
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
#   * the interactive branch via HONEY_STARTER_ANSWERS_FILE, incl. the Phase 5+6
#     answers-file schema (leading COMPOSE_PROJECT_NAME line + the model line)
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
#   * F3 project/state consistency guard: with a fake `docker` stub on PATH
#     (satisfying the docker gate), a NEW (artifact-less) instance colliding
#     with a running default-project stack / vault-file volume DIES early with
#     the project + ports guidance (no .env, no delegation); a clean project,
#     an artifact-bearing manage run, and a distinct COMPOSE_PROJECT_NAME all
#     proceed
#   * Phase 6 per-instance COMPOSE_PROJECT_NAME (P-series): the name is
#     authored into .env by setup.sh — fresh installs get the derived
#     hs-<basename>-<hash8> (deterministic from INSTALL_DIR; shared
#     derived_proj() helper below mirrors scripts/setup.sh's
#     derived_project_name), an env/answers value is validated (invalid DIES),
#     a manage run keeps the persisted line / omits when absent, an
#     env-vs-persisted change is TTY-confirmed (or NI-dies) with the data-loss
#     language, an env-with-nothing-persisted is adopted silently (and probed),
#     --update ignores env, and the F3 guard probes the EFFECTIVE name on every
#     effective CHANGE (adopt / confirm-y / fresh install / fresh re-probe) —
#     a DECLINED change is a NO-CHANGE: the guard early-returns on the state
#     artifacts (an already-provisioned instance rightfully owns its project;
#     decline never force-probes the kept name and never false-fires on its own
#     stack), while an ARTIFACT-LESS tree has nothing to shield it so its
#     would-be project IS probed and a genuine collision still dies. Every probe
#     test asserts the stub log is non-empty and contains the expected -p probe
#     (and a no-probe test asserts the log stays EMPTY — no vacuous pass).
#   * R4 NOTE (do NOT chase): T2/T3/T15/T16b are manage-flows on artifact-free
#     seeded trees -> under the never-provisioned IS_FRESH criterion they
#     become IS_FRESH=1 and GAIN a COMPOSE_PROJECT_NAME= line (derived,
#     deterministic from each temp dir). This is EXPECTED, not a failure —
#     their assertions are key-greps / source-tree-only diffs; idempotence
#     survives because the derived name is deterministic across both runs.
#   * branch-3 directory prompt hermetics (pty): ~/ default display (never the
#     spilled absolute path), Enter -> re-exec -> branch-2-in-place, bare ~ ->
#     $HOME at the prompt AND as an on-disk positional
#   * argument parsing: `--` end-of-flags, two positionals die, unknown option
#   * Phase A rich-output foundation: fd-1-tty + NO_COLOR-presence + TERM
#     detection, emoji/color prefix-only styling — A1/A2/A3/A4 prove the plain
#     fallback (redirected / TERM=dumb / NO_COLOR=1 / NO_COLOR= empty) emits
#     NO ESC bytes and NO emoji, and a color tty adds ESC+emoji while every
#     message substring stays byte-contiguous (the A-series runs inside the
#     full pre-Phase-B suite — the real regression gate).
#   * Phase B TTY-only select-from-list menus: on a real TTY with NO answers
#     file the AI-provider / AI-model questions render number-driven menus —
#     B1 select by number; B2 Enter accepts the default; B3 typed exact
#     value; B4 invalid provider input (out-of-range number) -> warn + retry
#     -> valid selection succeeds; B5 an out-of-range MODEL integer (99) is
#     warned + retried and NEVER written (valid_model would otherwise accept
#     '99' — the trap Phase B closes); B6 answers-file raw-value regression:
#     raw values pass through unmodified with NO menu rendered and no ESC
#     bytes (pre-Phase-B byte-identical).
#
# Run: bash test/setup-dryrun.sh   (or: make setup-dryrun)
#
# 95 checks total: the 89 pre-Phase-B checks + the 6 Phase B menu checks
# (B1-B6).
#
# python3 is OPTIONAL and used only by the pty harness (test/pty-helper.py) for
# the interactive branch-3 prompt / typed-invalid-model tests (17k/19/20) and
# the Phase B menu hermetics (B1-B5); when python3 is absent those checks are
# skipped cleanly. setup.sh itself never needs python3.
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

# derived_proj DIR -> prints the Phase 6 derived COMPOSE_PROJECT_NAME exactly
# as scripts/setup.sh's derived_project_name produces it (this test's mirror).
# KEEP IN SYNC with scripts/setup.sh derived_project_name() (same inputs ->
# same output); any derivation change must update BOTH. Used by the F3c
# derived-collision test and the P-series derived-name assertions — never
# inline copies.
derived_proj() {
  local dir="$1" base b h
  base="$(basename "${dir}")"
  [ -n "${base}" ] || base="dir"
  # sanitize: lowercase -> [^a-z0-9] -> "-" -> collapse runs -> strip edges ->
  # empty -> "dir" -> truncate 20 -> strip trailing "-"
  b="${base,,}"
  b="$(printf '%s' "${b}" | tr -c 'a-z0-9' '-')"
  while :; do
    case "${b}" in
      *--*) b="${b//--/-}" ;;
      *) break ;;
    esac
  done
  b="${b#-}"; b="${b%-}"
  [ -n "${b}" ] || b="dir"
  b="${b:0:20}"
  b="${b%-}"
  h="$(printf '%s' "${dir}" | sha256sum | cut -c1-8)"
  printf 'hs-%s-%s' "${b}" "${h}"
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
# Phase 5+6 answers-file schema: COMPOSE_PROJECT_NAME (empty = accept the
# derived default), HONEY_NS, HONEY_USER, provider, MODEL, base URL (custom
# only), API key (openai/custom), ports. NO install-dir line.
printf 'ansproj9\nansns\nansuser\ncustom\nans-custom-model\nhttps://ans.example.com/v1\nsk-answers-key\n9300\n9390\n' \
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
  && grep -q '^COMPOSE_PROJECT_NAME=ansproj9$' "${T9}/.env" \
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
printf 'proj17a\nansns\nansuser\nopenai\ngpt-4o\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.ans17a
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
if [ "${RC17A}" -eq 0 ] && grep -q '^COMPOSE_PROJECT_NAME=proj17a$' "${T17A}/.env" && grep -q '^HD_AI_MODEL=gpt-4o$' "${T17A}/.env"; then
  ok "model matrix: answers-file openai model line written (gpt-4o)"
else
  bad "model matrix 17a rc=${RC17A}:"; tail -5 /tmp/setup-dryrun.17a.out >&2 || true
fi
rm -rf "${T17A}" "${S17A}"

# 17b. answers-file EMPTY model line = accept default -> pin written
T17B="$(fresh_tree)"; S17B="$(mktemp -d)"
printf 'proj17b\nansns\nansuser\nopenai\n\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.ans17b
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
if [ "${RC17B}" -eq 0 ] && grep -q '^COMPOSE_PROJECT_NAME=proj17b$' "${T17B}/.env" && grep -q '^HD_AI_MODEL=gpt-5.4-mini$' "${T17B}/.env"; then
  ok "model matrix: empty model line in the answers file -> default pin written"
else
  bad "model matrix 17b rc=${RC17B}:"; tail -5 /tmp/setup-dryrun.17b.out >&2 || true
fi
rm -rf "${T17B}" "${S17B}"

# 17c. skip consumes NO model line (and none is written)
T17C="$(fresh_tree)"; S17C="$(mktemp -d)"
printf 'proj17c\nansns\nansuser\nskip\n9300\n9390\n' > /tmp/setup-dryrun.ans17c
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
if [ "${RC17C}" -eq 0 ] && grep -q '^COMPOSE_PROJECT_NAME=proj17c$' "${T17C}/.env" && ! grep -q '^HD_AI_MODEL=' "${T17C}/.env"; then
  ok "model matrix: skip consumes no model line; none written"
else
  bad "model matrix 17c rc=${RC17C}:"; tail -5 /tmp/setup-dryrun.17c.out >&2 || true
fi
rm -rf "${T17C}" "${S17C}"

# 17d. skip + non-empty HD_AI_MODEL env -> override written (passthrough wins)
T17D="$(fresh_tree)"; S17D="$(mktemp -d)"
printf 'HD_AI_MODEL=old-override\n' > "${T17D}/.env"
printf 'proj17d\nansns\nansuser\nskip\n9300\n9390\n' > /tmp/setup-dryrun.ans17d
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
if [ "${RC17D}" -eq 0 ] && grep -q '^COMPOSE_PROJECT_NAME=proj17d$' "${T17D}/.env" && grep -q '^HD_AI_MODEL=custom-override$' "${T17D}/.env"; then
  ok "model matrix: skip + non-empty HD_AI_MODEL -> override written (passthrough wins over all providers)"
else
  bad "model matrix 17d rc=${RC17D}:"; tail -5 /tmp/setup-dryrun.17d.out >&2 || true
fi
rm -rf "${T17D}" "${S17D}"

# 17e. skip + HD_AI_MODEL= (explicit empty) + existing override -> line REMOVED
T17E="$(fresh_tree)"; S17E="$(mktemp -d)"
printf 'HD_AI_MODEL=old-override\n' > "${T17E}/.env"
printf 'proj17e\nansns\nansuser\nskip\n9300\n9390\n' > /tmp/setup-dryrun.ans17e
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
if [ "${RC17E}" -eq 0 ] && grep -q '^COMPOSE_PROJECT_NAME=proj17e$' "${T17E}/.env" && ! grep -q '^HD_AI_MODEL=' "${T17E}/.env"; then
  ok "model matrix: skip + HD_AI_MODEL= (explicit-empty) removes an existing override line"
else
  bad "model matrix 17e rc=${RC17E}:"; tail -5 /tmp/setup-dryrun.17e.out >&2 || true
fi
rm -rf "${T17E}" "${S17E}"

# 17f. HD_AI_MODEL= (explicit empty) + openai + existing override: the QUESTION
#      is SKIPPED and the existing override is NOT kept (line removed)
T17F="$(fresh_tree)"; S17F="$(mktemp -d)"
printf 'HD_AI_MODEL=old-pin\n' > "${T17F}/.env"
printf 'proj17f\nansns\nansuser\nopenai\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.ans17f
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
if [ "${RC17F}" -eq 0 ] && grep -q '^COMPOSE_PROJECT_NAME=proj17f$' "${T17F}/.env" && ! grep -q '^HD_AI_MODEL=' "${T17F}/.env"; then
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
printf 'proj17h\nansns\nansuser\nopenai\nbad model\n9300\n9390\n' > /tmp/setup-dryrun.ans17h
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
    cd "${T17K}" && HD_STATE_DIR="${S17K}" TERM=dumb \
    python3 "${HERE}/test/pty-helper.py" --on-disk \
      "${T17K}/scripts/setup.sh" "Compose project name" \
      projname ansns ansuser openai "bad model" 9300 9390 -- --dry-run
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
printf 'proj17l\nbad ns one\nbad ns two\nbad ns three\nbad user one\nbad user two\nbad user three\nopenai\ngpt-valid\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.ans17l
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
  && grep -q '^COMPOSE_PROJECT_NAME=proj17l$' "${T17L}/.env" \
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
      -u HONEY_STARTER_INSTALL_DIR HOME="${PH19A}" TERM=dumb HD_STATE_DIR="${S19A}" \
      python3 "${HERE}/test/pty-helper.py" --standalone \
        "${HERE}/scripts/setup.sh" "Install directory [" \
        "" projname19a ansns ansuser openai gpt-4o sk-key-pty 9300 9390 -- --dry-run \
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
      -u HONEY_STARTER_INSTALL_DIR HOME="${TH19B}" TERM=dumb HD_STATE_DIR="${S19B}" \
      python3 "${HERE}/test/pty-helper.py" --standalone \
        "${HERE}/scripts/setup.sh" "Install directory [" \
        "~" projname19b ansns ansuser openai gpt-4o sk-key-pty2 9301 9391 -- --dry-run \
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

# ---------------------------------------------------------------------------
# F3. Project/state consistency guard (scripts/setup.sh's early collision
#     die). Uses a fake `docker` stub on PATH that answers EXACTLY the probes
#     guard_project_state_consistency makes (plus the preflight's `docker
#     compose version` / `docker info`), so the guard is exercised as REAL
#     (F3.3 gate satisfied) in this hermetic no-docker sandbox instead of
#     silently skipping. The stub is driven by $DOCKER_STUB_STATE_FILE:
#       RUNNING <project>  -> `compose ... -p <project> ps --status running`
#                             prints the four service container ids
#       VISIBLE <volume>   -> `docker volume inspect <volume>` succeeds
# ---------------------------------------------------------------------------
F3_STUB_DIR="$(mktemp -d /tmp/setup-dryrun.stub.XXXXXX)"
cat > "${F3_STUB_DIR}/docker" <<'F3STUB'
#!/usr/bin/env bash
# Fake docker stub - answers EXACTLY the probes guard_project_state_consistency
# makes (plus the preflight's `docker compose version` / `docker info`), so the
# guard is exercised as REAL (F3.3 gate satisfied) in this hermetic no-docker
# sandbox instead of silently skipping. Driven by $DOCKER_STUB_STATE_FILE:
#   RUNNING <project>  -> `compose ... -p <project> ps --status running`
#                         prints the four service container ids
#   VISIBLE <volume>   -> `docker volume inspect <volume>` succeeds
# Every resolved probe is APPENDED to $DOCKER_STUB_LOG (env; devnull default):
#   -p <project>       (one per `compose ... -p <p> ps ...` invocation)
#   volume <volume>    (one per `docker volume inspect <volume>`)
# so tests can prove the guard REALLY probed the expected effective name
# (a vacuous pass - e.g. a skipped guard or the docker-missing skip-with-warn -
# fails the test).
STATE="${DOCKER_STUB_STATE_FILE:-/dev/null}"
LOG="${DOCKER_STUB_LOG:-/dev/null}"
if [ "$1" = "compose" ] && [ "$2" = "version" ]; then
  echo "Docker Compose version v2"
  exit 0
fi
if [ "$1" = "volume" ] && [ "$2" = "inspect" ]; then
  printf 'volume %s\n' "$3" >> "${LOG}"
  if [ -f "${STATE}" ] && grep -q "^VISIBLE ${3}$" "${STATE}"; then
    exit 0
  fi
  exit 1
fi
if [ "$1" = "compose" ]; then
  proj=""
  prev=""
  for a in "$@"; do
    if [ "${prev}" = "-p" ]; then proj="${a}"; fi
    prev="${a}"
  done
  if [ -n "${proj}" ]; then
    printf -- '-p %s\n' "${proj}" >> "${LOG}"
  fi
  if [ -n "${proj}" ] && [ -f "${STATE}" ] && grep -q "^RUNNING ${proj}$" "${STATE}"; then
    printf '%s\n' "${proj}-daemon-1" "${proj}-ui-1" "${proj}-valkey-1" "${proj}-vault-1"
  fi
  exit 0
fi
exit 0
F3STUB
chmod +x "${F3_STUB_DIR}/docker"

# F3a (rewritten — deliberate reuse): fresh target + env COMPOSE_PROJECT_NAME
#      =honey-starter (deliberately REUSING the shared default project) + stub
#      RUNNING honey-starter + VISIBLE honey-starter_vault-file -> the pre-guard
#      probes the EFFECTIVE preliminary name (setup-time env-first) and DIES
#      naming honey-starter, no .env (the test3 repro). The stub log must prove
#      the guard REALLY probed `-p honey-starter` (no vacuous pass).
TF3A="$(fresh_tree)"; SF3A="$(mktemp -d)"
printf 'RUNNING honey-starter\nVISIBLE honey-starter_vault-file\n' > /tmp/setup-dryrun.f3a.state
: > /tmp/setup-dryrun.f3a.log
set +e
(
  cd "${TF3A}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.f3a.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.f3a.log \
    HONEY_STARTER_INSTALL_DIR="${TF3A}" HONEY_STARTER_NONINTERACTIVE=1 \
    COMPOSE_PROJECT_NAME=honey-starter \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SF3A}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.f3a.out 2>&1
RC3A=$?
set -e
if [ "${RC3A}" -ne 0 ] \
  && grep -q "refusing to set up a NEW instance" /tmp/setup-dryrun.f3a.out \
  && grep -q "project 'honey-starter'" /tmp/setup-dryrun.f3a.out \
  && grep -q "unseal_key" /tmp/setup-dryrun.f3a.out \
  && [ ! -f "${TF3A}/.env" ] \
  && [ -s /tmp/setup-dryrun.f3a.log ] \
  && grep -q -- "-p honey-starter" /tmp/setup-dryrun.f3a.log; then
  ok "F3a (rewritten): fresh + env COMPOSE_PROJECT_NAME=honey-starter + running default stack DIES naming honey-starter, no .env (log proved -p probe)"
else
  bad "F3 collision rc=${RC3A} (want die + -p honey-starter probe + no .env):"
  sed 's/^/    | /' /tmp/setup-dryrun.f3a.out >&2 || true
fi
rm -rf "${TF3A}" "${SF3A}"


# F3b. Clean project/state: stub reports NO running containers and NO
#      vault-file volume -> the guard must NOT fire; the dry-run proceeds and
#      writes .env exactly as before.
TF3B="$(fresh_tree)"; SF3B="$(mktemp -d)"
printf '' > /tmp/setup-dryrun.f3b.state
: > /tmp/setup-dryrun.f3b.log
set +e
(
  cd "${TF3B}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.f3b.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.f3b.log \
    HONEY_STARTER_INSTALL_DIR="${TF3B}" HONEY_STARTER_NONINTERACTIVE=1 \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SF3B}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.f3b.out 2>&1
RC3B=$?
set -e
if [ "${RC3B}" -eq 0 ] && [ -f "${TF3B}/.env" ] && [ -s /tmp/setup-dryrun.f3b.log ]; then
  ok "F3 guard: clean project/state (stub: nothing running, no vault volume) PROCEEDS and writes .env"
else
  bad "F3 clean rc=${RC3B} (want rc 0 + .env):"
  sed 's/^/    | /' /tmp/setup-dryrun.f3b.out >&2 || true
fi
rm -rf "${TF3B}" "${SF3B}"

# F3c (rewritten — derived-collision): fresh target, NO env -> the pre-guard
#      probes the preliminary = the DERIVED hs-<basename>-<hash8> of INSTALL_DIR,
#      computed via the SHARED derived_proj() helper (no inline copy); stub
#      RUNNING <derived> -> die, no .env/state; log asserts `-p <derived>`
#      (the probe really ran).
TF3C="$(fresh_tree)"; SF3C="$(mktemp -d)"
DERIVED3C="$(derived_proj "${TF3C}")"
printf 'RUNNING %s\n' "${DERIVED3C}" > /tmp/setup-dryrun.f3c.state
: > /tmp/setup-dryrun.f3c.log
set +e
(
  cd "${TF3C}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.f3c.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.f3c.log \
    HONEY_STARTER_INSTALL_DIR="${TF3C}" HONEY_STARTER_NONINTERACTIVE=1 \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SF3C}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.f3c.out 2>&1
RC3C=$?
set -e
if [ "${RC3C}" -ne 0 ] \
  && grep -q "refusing to set up a NEW instance" /tmp/setup-dryrun.f3c.out \
  && grep -Fq "project '${DERIVED3C}'" /tmp/setup-dryrun.f3c.out \
  && [ ! -f "${TF3C}/.env" ] \
  && [ -s /tmp/setup-dryrun.f3c.log ] \
  && grep -q -- "-p ${DERIVED3C}" /tmp/setup-dryrun.f3c.log; then
  ok "F3c (rewritten): fresh target + running DERIVED project (hs-...-hash8) DIES, no .env (log proved -p <derived>; shared derived_proj)"
else
  bad "F3 derived-collision rc=${RC3C} (want die + -p derived):"
  sed 's/^/    | /' /tmp/setup-dryrun.f3c.out >&2 || true
fi
rm -rf "${TF3C}" "${SF3C}"


# F3d1. Manage-in-place with state artifacts present (root_token) + stub
#       reporting the default project running -> NO false die: an
#       already-provisioned instance rightfully owns the default project (its
#       unseal key lives in ITS state dir), so the guard must skip.
TF3D1="$(fresh_tree)"; SF3D1="$(mktemp -d)"
mkdir -p "${SF3D1}"
printf 'root-token-dummy\n' > "${SF3D1}/root_token"
printf 'RUNNING honey-starter\n' > /tmp/setup-dryrun.f3d1.state
: > /tmp/setup-dryrun.f3d1.log
set +e
(
  cd "${TF3D1}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.f3d1.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.f3d1.log \
    HONEY_STARTER_INSTALL_DIR="${TF3D1}" HONEY_STARTER_NONINTERACTIVE=1 \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SF3D1}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.f3d1.out 2>&1
RC3D1=$?
set -e
if [ "${RC3D1}" -eq 0 ] && [ -f "${TF3D1}/.env" ]; then
  ok "F3 guard: manage-in-place with state artifacts (root_token) does NOT false-die on a running default project"
else
  bad "F3 manage-with-artifacts rc=${RC3D1} (want rc 0 + .env):"
  sed 's/^/    | /' /tmp/setup-dryrun.f3d1.out >&2 || true
fi
rm -rf "${TF3D1}" "${SF3D1}"

# F3d2. Distinct COMPOSE_PROJECT_NAME (fresh state) + stub reporting ONLY the
#       default project running -> NO false die: the guard must probe the
#       PROJECT-SCOPED project + volume (${compose_p}_vault-file), never a
#       hard-coded default, so an unrelated orphan volume cannot trip it.
TF3D2="$(fresh_tree)"; SF3D2="$(mktemp -d)"
printf 'RUNNING honey-starter\n' > /tmp/setup-dryrun.f3d2.state
: > /tmp/setup-dryrun.f3d2.log
set +e
(
  cd "${TF3D2}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.f3d2.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.f3d2.log \
    COMPOSE_PROJECT_NAME=myotherproject \
    HONEY_STARTER_INSTALL_DIR="${TF3D2}" HONEY_STARTER_NONINTERACTIVE=1 \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9100 HD_UI_HOST_PORT=8190 HD_STATE_DIR="${SF3D2}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.f3d2.out 2>&1
RC3D2=$?
set -e
if [ "${RC3D2}" -eq 0 ] && [ -f "${TF3D2}/.env" ] && [ -s /tmp/setup-dryrun.f3d2.log ] \
  && grep -q '^COMPOSE_PROJECT_NAME=myotherproject$' "${TF3D2}/.env"; then
  ok "F3 guard: distinct COMPOSE_PROJECT_NAME (fresh state) does NOT die on the default project's running stack / volume (project-scoped probe; env name persisted)"
else
  bad "F3 distinct-project rc=${RC3D2} (want rc 0 + .env):"
  sed 's/^/    | /' /tmp/setup-dryrun.f3d2.out >&2 || true
fi
rm -rf "${TF3D2}" "${SF3D2}"

echo ""
# ---------------------------------------------------------------------------
# P-series. Phase 6 — per-instance COMPOSE_PROJECT_NAME persisted in .env.
# Every probe test REQUIRES: stub on PATH AND a non-empty DOCKER_STUB_LOG with
# the expected -p probe (a vacuous pass — a docker-missing skip, an early
# return, or a wrong name — FAILS the test); a no-probe path asserts the log
# stays EMPTY. P1-P11/P14-P16 are hermetic answers/env/--dry-run; P12-P13 are
# pty (python3-gated; skipped cleanly when python3 is unavailable).
# ---------------------------------------------------------------------------

# P1. fresh NI env-unset -> the derived hs-...-hash8 is written; 2nd run is
#     byte-identical (deterministic, idempotent); the guard probed -p <derived>.
TP1="$(fresh_tree)"; SP1="$(mktemp -d)"
: > /tmp/setup-dryrun.p1.log; printf '' > /tmp/setup-dryrun.p1.state
DERIVED1="$(derived_proj "${TP1}")"
set +e
(
  cd "${TP1}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p1.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p1.log \
    HONEY_STARTER_INSTALL_DIR="${TP1}" HONEY_STARTER_NONINTERACTIVE=1 \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SP1}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p1a.out 2>&1
RC1A=$?
set -e
cp "${TP1}/.env" /tmp/setup-dryrun.p1.env1 2>/dev/null || true
set +e
(
  cd "${TP1}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p1.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p1.log \
    HONEY_STARTER_INSTALL_DIR="${TP1}" HONEY_STARTER_NONINTERACTIVE=1 \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SP1}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p1b.out 2>&1
RC1B=$?
set -e
if [ "${RC1A}" -eq 0 ] && [ "${RC1B}" -eq 0 ] \
  && grep -q "^COMPOSE_PROJECT_NAME=${DERIVED1}$" "${TP1}/.env" \
  && diff -q /tmp/setup-dryrun.p1.env1 "${TP1}/.env" >/dev/null 2>&1 \
  && [ -s /tmp/setup-dryrun.p1.log ] \
  && grep -q -- "-p ${DERIVED1}" /tmp/setup-dryrun.p1.log; then
  ok "P1: fresh NI env-unset writes the derived hs-...-hash8; 2nd run byte-identical (log proved -p <derived>)"
else
  bad "P1 rc=${RC1A}/${RC1B} (want derived line + idempotent + -p probe):"
  sed 's/^/    | /' /tmp/setup-dryrun.p1a.out >&2 || true
fi
rm -rf "${TP1}" "${SP1}"

# P2. fresh NI env COMPOSE_PROJECT_NAME=myproj -> written; guard probed -p myproj.
TP2="$(fresh_tree)"; SP2="$(mktemp -d)"
: > /tmp/setup-dryrun.p2.log; printf '' > /tmp/setup-dryrun.p2.state
set +e
(
  cd "${TP2}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p2.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p2.log \
    HONEY_STARTER_INSTALL_DIR="${TP2}" HONEY_STARTER_NONINTERACTIVE=1 \
    COMPOSE_PROJECT_NAME=myproj \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SP2}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p2.out 2>&1
RC2=$?
set -e
if [ "${RC2}" -eq 0 ] && grep -q '^COMPOSE_PROJECT_NAME=myproj$' "${TP2}/.env" \
  && [ -s /tmp/setup-dryrun.p2.log ] && grep -q -- "-p myproj" /tmp/setup-dryrun.p2.log; then
  ok "P2: fresh NI env COMPOSE_PROJECT_NAME=myproj written; log proved -p myproj"
else
  bad "P2 rc=${RC2} (want myproj written + -p myproj probe):"
  sed 's/^/    | /' /tmp/setup-dryrun.p2.out >&2 || true
fi
rm -rf "${TP2}" "${SP2}"

# P3. fresh answers-file leading line ansproj -> written (post-guard re-probe
#     proves the answered name was probed).
TP3="$(fresh_tree)"; SP3="$(mktemp -d)"
printf 'ansproj\nansns\nansuser\nopenai\ngpt-4o\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.p3.answers
: > /tmp/setup-dryrun.p3.log; printf '' > /tmp/setup-dryrun.p3.state
set +e
(
  cd "${TP3}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p3.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p3.log \
    HONEY_STARTER_INSTALL_DIR="${TP3}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.p3.answers HD_STATE_DIR="${SP3}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p3.out 2>&1
RC3=$?
set -e
if [ "${RC3}" -eq 0 ] && grep -q '^COMPOSE_PROJECT_NAME=ansproj$' "${TP3}/.env" \
  && [ -s /tmp/setup-dryrun.p3.log ] && grep -q -- "-p ansproj" /tmp/setup-dryrun.p3.log; then
  ok "P3: answers-file leading line ansproj written; post-guard probed -p ansproj"
else
  bad "P3 rc=${RC3} (want ansproj + -p ansproj probe):"
  sed 's/^/    | /' /tmp/setup-dryrun.p3.out >&2 || true
fi
rm -rf "${TP3}" "${SP3}"

# P4. fresh answers-file EMPTY leading line -> the derived default is written.
TP4="$(fresh_tree)"; SP4="$(mktemp -d)"
printf '\nansns\nansuser\nopenai\ngpt-4o\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.p4.answers
: > /tmp/setup-dryrun.p4.log; printf '' > /tmp/setup-dryrun.p4.state
DERIVED4="$(derived_proj "${TP4}")"
set +e
(
  cd "${TP4}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p4.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p4.log \
    HONEY_STARTER_INSTALL_DIR="${TP4}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.p4.answers HD_STATE_DIR="${SP4}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p4.out 2>&1
RC4=$?
set -e
if [ "${RC4}" -eq 0 ] && grep -q "^COMPOSE_PROJECT_NAME=${DERIVED4}$" "${TP4}/.env" \
  && [ -s /tmp/setup-dryrun.p4.log ] && grep -q -- "-p ${DERIVED4}" /tmp/setup-dryrun.p4.log; then
  ok "P4: answers-file empty leading line -> derived default written (log proved -p <derived>)"
else
  bad "P4 rc=${RC4} (want derived written):"
  sed 's/^/    | /' /tmp/setup-dryrun.p4.out >&2 || true
fi
rm -rf "${TP4}" "${SP4}"

# P5. fresh NI invalid env name (uppercase/dot) -> dies with the charset
#     message; no .env (single consolidated check).
TP5="$(fresh_tree)"; SP5="$(mktemp -d)"
set +e
(
  cd "${TP5}" && HONEY_STARTER_INSTALL_DIR="${TP5}" HONEY_STARTER_NONINTERACTIVE=1 \
  COMPOSE_PROJECT_NAME='Bad.Name' \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SP5}" \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p5.out 2>&1
RC5=$?
set -e
if [ "${RC5}" -eq 1 ] && grep -q "invalid COMPOSE_PROJECT_NAME" /tmp/setup-dryrun.p5.out \
  && [ ! -f "${TP5}/.env" ]; then
  ok "P5: invalid env name (NI) DIES with the charset message; no .env"
else
  bad "P5 rc=${RC5} (want die + charset message + no .env):"
  sed 's/^/    | /' /tmp/setup-dryrun.p5.out >&2 || true
fi
rm -rf "${TP5}" "${SP5}"

# P6. fresh answers-file INVALID leading line -> dies on the project (the
#     charset message), no .env.
TP6="$(fresh_tree)"; SP6="$(mktemp -d)"
printf 'BadProj!\nansns\nansuser\nopenai\ngpt-4o\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.p6.answers
set +e
(
  cd "${TP6}"
  env -i HOME="${HOME}" PATH="${PATH}" \
    HONEY_STARTER_INSTALL_DIR="${TP6}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.p6.answers HD_STATE_DIR="${SP6}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p6.out 2>&1
RC6=$?
set -e
if [ "${RC6}" -eq 1 ] && grep -q "invalid COMPOSE_PROJECT_NAME" /tmp/setup-dryrun.p6.out \
  && [ ! -f "${TP6}/.env" ]; then
  ok "P6: answers-file invalid leading line DIES on the project (rc 1, no .env)"
else
  bad "P6 rc=${RC6} (want the invalid-project die + no .env):"
  sed 's/^/    | /' /tmp/setup-dryrun.p6.out >&2 || true
fi
rm -rf "${TP6}" "${SP6}"

# P7. manage + persisted persistedfoo + env unset -> line kept, never re-asked /
#     re-derived (the artifacts early-return means no probe: log stays EMPTY).
TP7="$(fresh_tree)"; SP7="$(mktemp -d)"; mkdir -p "${SP7}"
printf 'root-token-dummy\n' > "${SP7}/root_token"
printf 'PROVISION_NS=starter\nPROVISION_USER=admin\n' > "${SP7}/provision.env"
printf 'COMPOSE_PROJECT_NAME=persistedfoo\n' > "${TP7}/.env"
: > /tmp/setup-dryrun.p7.log; printf '' > /tmp/setup-dryrun.p7.state
set +e
(
  cd "${TP7}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p7.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p7.log \
    HONEY_STARTER_INSTALL_DIR="${TP7}" HONEY_STARTER_NONINTERACTIVE=1 \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SP7}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p7.out 2>&1
RC7=$?
set -e
if [ "${RC7}" -eq 0 ] && grep -q '^COMPOSE_PROJECT_NAME=persistedfoo$' "${TP7}/.env" \
  && ! grep -q "Compose project name (COMPOSE_PROJECT_NAME)" /tmp/setup-dryrun.p7.out; then
  ok "P7: manage + persisted name + env unset -> line KEPT, never re-asked/re-derived"
else
  bad "P7 rc=${RC7} (want kept line, no re-ask):"
  sed 's/^/    | /' /tmp/setup-dryrun.p7.out >&2 || true
fi
rm -rf "${TP7}" "${SP7}"

# P8. manage + NO persisted line + env unset -> NO COMPOSE_PROJECT_NAME= after
#     re-run (lib.sh default honey-starter applies by omission; migration-safe).
TP8="$(fresh_tree)"; SP8="$(mktemp -d)"; mkdir -p "${SP8}"
printf 'root-token-dummy\n' > "${SP8}/root_token"
printf 'PROVISION_NS=starter\nPROVISION_USER=admin\n' > "${SP8}/provision.env"
: > /tmp/setup-dryrun.p8.log; printf '' > /tmp/setup-dryrun.p8.state
set +e
(
  cd "${TP8}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p8.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p8.log \
    HONEY_STARTER_INSTALL_DIR="${TP8}" HONEY_STARTER_NONINTERACTIVE=1 \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SP8}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p8.out 2>&1
RC8=$?
set -e
if [ "${RC8}" -eq 0 ] && ! grep -q '^COMPOSE_PROJECT_NAME=' "${TP8}/.env"; then
  ok "P8: manage + no persisted line + env unset -> ABSENT after re-run (default by omission)"
else
  bad "P8 rc=${RC8} (want no COMPOSE_PROJECT_NAME= line):"
  sed 's/^/    | /' /tmp/setup-dryrun.p8.out >&2 || true
  grep '^COMPOSE_PROJECT_NAME=' "${TP8}/.env" 2>/dev/null | sed 's/^/    | /' >&2 || true
fi
rm -rf "${TP8}" "${SP8}"

# P9. manage ADOPT (Error-2 regression): artifacts + env hs-copy2 + NOTHING
#     persisted + NI -> rc 0, .env GAINS the line, no confirm/warn; the guard
#     probed the adopted name (-p hs-copy2) with RENAMING=1.
TP9="$(fresh_tree)"; SP9="$(mktemp -d)"; mkdir -p "${SP9}"
printf 'root-token-dummy\n' > "${SP9}/root_token"
printf 'PROVISION_NS=starter\nPROVISION_USER=admin\n' > "${SP9}/provision.env"
: > /tmp/setup-dryrun.p9.log; printf '' > /tmp/setup-dryrun.p9.state
set +e
(
  cd "${TP9}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p9.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p9.log \
    HONEY_STARTER_INSTALL_DIR="${TP9}" HONEY_STARTER_NONINTERACTIVE=1 \
    COMPOSE_PROJECT_NAME=hs-copy2 \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9100 HD_UI_HOST_PORT=8190 HD_STATE_DIR="${SP9}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p9.out 2>&1
RC9X=$?
set -e
if [ "${RC9X}" -eq 0 ] && grep -q '^COMPOSE_PROJECT_NAME=hs-copy2$' "${TP9}/.env" \
  && ! grep -q "Continue with the change" /tmp/setup-dryrun.p9.out \
  && [ -s /tmp/setup-dryrun.p9.log ] && grep -q -- "-p hs-copy2" /tmp/setup-dryrun.p9.log; then
  ok "P9: env-with-nothing-persisted ADOPTED silently (rc 0, .env gains hs-copy2, no confirm; -p hs-copy2 probed)"
else
  bad "P9 adopt rc=${RC9X} (want silent adopt + -p hs-copy2 probe):"
  sed 's/^/    | /' /tmp/setup-dryrun.p9.out >&2 || true
fi
rm -rf "${TP9}" "${SP9}"

# P10. fresh RAW tree with .env COMPOSE_PROJECT_NAME=rawfoo + env envbar ->
#      preliminary = envbar (setup-time env-first); stub RUNNING rawfoo only ->
#      proceeds (probes envbar); .env written envbar.
TP10="$(fresh_tree)"; SP10="$(mktemp -d)"
printf 'COMPOSE_PROJECT_NAME=rawfoo\n' > "${TP10}/.env"
: > /tmp/setup-dryrun.p10.log; printf 'RUNNING rawfoo\n' > /tmp/setup-dryrun.p10.state
set +e
(
  cd "${TP10}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p10.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p10.log \
    HONEY_STARTER_INSTALL_DIR="${TP10}" HONEY_STARTER_NONINTERACTIVE=1 \
    COMPOSE_PROJECT_NAME=envbar \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SP10}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p10.out 2>&1
RC10=$?
set -e
if [ "${RC10}" -eq 0 ] && grep -q '^COMPOSE_PROJECT_NAME=envbar$' "${TP10}/.env" \
  && [ -s /tmp/setup-dryrun.p10.log ] && grep -q -- "-p envbar" /tmp/setup-dryrun.p10.log \
  && ! grep -q "refusing to set up" /tmp/setup-dryrun.p10.out; then
  ok "P10: fresh raw tree .env rawfoo + env envbar -> env wins (preliminary=-p envbar probed; running rawfoo does NOT die)"
else
  bad "P10 rc=${RC10} (want envbar written + -p envbar probe):"
  sed 's/^/    | /' /tmp/setup-dryrun.p10.out >&2 || true
fi
rm -rf "${TP10}" "${SP10}"

# P11. B1 false-negative CLOSE (hermetic): an ARTIFACT-LESS (never-provisioned)
#      tree has NO state artifacts to shield its project, so the F3 pre-guard
#      genuinely probes the name the run would use and a real collision DIES.
#      Tree: .env prefill COMPOSE_PROJECT_NAME=otherproj + env COMPOSE_PROJECT_NAME
#      UNSET. (A fresh tree's pre-guard is env-first, so an exported env would
#      make the preliminary the env name — see P10; and the decline confirm
#      itself is IS_FRESH=0-only, i.e. artifacts-present, so an artifact-less
#      run reaches the pre-guard directly with no prompt.) Stub RUNNING
#      otherproj -> guard(otherproj, 0) probes -p otherproj -> DIES pre-write;
#      .env unchanged.
TP11="$(fresh_tree)"; SP11="$(mktemp -d)"
printf 'COMPOSE_PROJECT_NAME=otherproj\nHONEY_NS=starter\nHONEY_USER=admin\nHD_API_HOST_PORT=9300\nHD_UI_HOST_PORT=9390\n' > "${TP11}/.env"
printf 'RUNNING otherproj\n' > /tmp/setup-dryrun.p11.state
: > /tmp/setup-dryrun.p11.log
set +e
(
  cd "${TP11}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p11.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p11.log \
    HONEY_STARTER_INSTALL_DIR="${TP11}" HONEY_STARTER_NONINTERACTIVE=1 \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9300 HD_UI_HOST_PORT=9390 HD_STATE_DIR="${SP11}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p11.out 2>&1
RC11=$?
set -e
if [ "${RC11}" -ne 0 ] \
  && grep -q "refusing to set up a NEW instance" /tmp/setup-dryrun.p11.out \
  && grep -q "compose project 'otherproj'" /tmp/setup-dryrun.p11.out \
  && grep -q '^COMPOSE_PROJECT_NAME=otherproj$' "${TP11}/.env" \
  && [ -s /tmp/setup-dryrun.p11.log ] \
  && grep -q -- "-p otherproj" /tmp/setup-dryrun.p11.log; then
  ok "P11: artifact-less tree (no shield) + persisted otherproj + stub RUNNING otherproj -> pre-guard -p otherproj -> DIES; .env unchanged"
else
  bad "P11 rc=${RC11} (want artifact-less collision -> die):"
  sed 's/^/    | /' /tmp/setup-dryrun.p11.out >&2 || true
fi
rm -rf "${TP11}" "${SP11}"

# P12. decline is a NO-CHANGE (pty): the REPRODUCED false-die scenario —
#      artifacts present + persisted otherproj + env myproj + the instance's
#      OWN stack RUNNING under otherproj (the KEPT name); respond n -> DECLINED=1,
#      GUARD_RENAMING=0 -> the F3 guard EARLY-RETURNS on the state artifacts
#      (an already-provisioned instance rightfully owns its project; a declined
#      change must NOT force-probe the kept name and must NOT false-fire on its
#      own stack). The run PROCEEDS, .env keeps otherproj, the "keeping the
#      persisted compose project" NOTE is printed, and the guard makes NO probe
#      at all (stub log stays EMPTY - asserted, no vacuous pass).
if command -v python3 >/dev/null 2>&1; then
  TP12="$(fresh_tree)"; SP12="$(mktemp -d)"; mkdir -p "${SP12}"
  printf 'root-token-dummy\n' > "${SP12}/root_token"
  printf 'PROVISION_NS=ansns\nPROVISION_USER=ansuser\n' > "${SP12}/provision.env"
  printf 'COMPOSE_PROJECT_NAME=otherproj\nHONEY_NS=ansns\nHONEY_USER=ansuser\nHD_API_HOST_PORT=9300\nHD_UI_HOST_PORT=9390\n' > "${TP12}/.env"
  printf 'RUNNING otherproj\n' > /tmp/setup-dryrun.p12.state
  : > /tmp/setup-dryrun.p12.log
  set +e
  (
    cd "${TP12}"
    env -u HONEY_STARTER_NONINTERACTIVE -u HONEY_STARTER_ANSWERS_FILE \
      -u HONEY_STARTER_INSTALL_DIR \
      HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
      DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p12.state \
      DOCKER_STUB_LOG=/tmp/setup-dryrun.p12.log \
      COMPOSE_PROJECT_NAME=myproj \
      HD_STATE_DIR="${SP12}" TERM=dumb \
      python3 "${HERE}/test/pty-helper.py" --on-disk \
        "${TP12}/scripts/setup.sh" "Continue with the change?" \
        n ansns ansuser openai gpt-4o sk-pty-key 9300 9390 -- --dry-run
  ) >/tmp/setup-dryrun.p12.out 2>&1
  RC12=$?
  set -e
  if [ "${RC12}" -eq 0 ] \
    && grep -q '^COMPOSE_PROJECT_NAME=otherproj$' "${TP12}/.env" \
    && grep -q "keeping the persisted compose project" /tmp/setup-dryrun.p12.out \
    && [ ! -s /tmp/setup-dryrun.p12.log ]; then
    ok "P12 (repro): decline (n) with OWN stack running under the KEPT name -> guard early-returns on artifacts (NO probe; log empty) -> proceeds; .env keeps otherproj; no false die"
  else
    bad "P12 rc=${RC12} (want decline -> proceed, no probe, .env kept):"
    sed 's/^/    | /' /tmp/setup-dryrun.p12.out >&2 || true
  fi
  rm -rf "${TP12}" "${SP12}"
else
  ok "P12 SKIPPED (python3 unavailable)"
fi

# P13. rename ACCEPT (pty): respond y -> guard probes myproj (free) -> .env is
#      WRITTEN with myproj; log -p myproj.
if command -v python3 >/dev/null 2>&1; then
  TP13="$(fresh_tree)"; SP13="$(mktemp -d)"; mkdir -p "${SP13}"
  printf 'root-token-dummy\n' > "${SP13}/root_token"
  printf 'PROVISION_NS=ansns\nPROVISION_USER=ansuser\n' > "${SP13}/provision.env"
  printf 'COMPOSE_PROJECT_NAME=otherproj\nHONEY_NS=ansns\nHONEY_USER=ansuser\nHD_API_HOST_PORT=9300\nHD_UI_HOST_PORT=9390\n' > "${TP13}/.env"
  printf '' > /tmp/setup-dryrun.p13.state
  : > /tmp/setup-dryrun.p13.log
  set +e
  (
    cd "${TP13}"
    env -u HONEY_STARTER_NONINTERACTIVE -u HONEY_STARTER_ANSWERS_FILE \
      -u HONEY_STARTER_INSTALL_DIR \
      HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
      DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p13.state \
      DOCKER_STUB_LOG=/tmp/setup-dryrun.p13.log \
      COMPOSE_PROJECT_NAME=myproj \
      HD_STATE_DIR="${SP13}" TERM=dumb \
      python3 "${HERE}/test/pty-helper.py" --on-disk \
        "${TP13}/scripts/setup.sh" "Continue with the change?" \
        y ansns ansuser openai gpt-4o sk-pty-key 9300 9390 -- --dry-run
  ) >/tmp/setup-dryrun.p13.out 2>&1
  RC13=$?
  set -e
  if [ "${RC13}" -eq 0 ] \
    && grep -q '^COMPOSE_PROJECT_NAME=myproj$' "${TP13}/.env" \
    && grep -q -- "-p myproj" /tmp/setup-dryrun.p13.log; then
    ok "P13: rename ACCEPT (y) -> -p myproj probed (free) -> .env written myproj"
  else
    bad "P13 rc=${RC13} (want accept -> write myproj):"
    sed 's/^/    | /' /tmp/setup-dryrun.p13.out >&2 || true
  fi
  rm -rf "${TP13}" "${SP13}"
else
  ok "P13 SKIPPED (python3 unavailable)"
fi

# P14. rename NI DIES: artifacts + persisted otherproj + env myproj +
#      NONINTERACTIVE=1 -> die with the data-loss message; .env unchanged;
#      log EMPTY (dies at resolution, before the guard).
TP14="$(fresh_tree)"; SP14="$(mktemp -d)"; mkdir -p "${SP14}"
printf 'root-token-dummy\n' > "${SP14}/root_token"
printf 'PROVISION_NS=starter\nPROVISION_USER=admin\n' > "${SP14}/provision.env"
printf 'COMPOSE_PROJECT_NAME=otherproj\n' > "${TP14}/.env"
: > /tmp/setup-dryrun.p14.log; printf '' > /tmp/setup-dryrun.p14.state
set +e
(
  cd "${TP14}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p14.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p14.log \
    HONEY_STARTER_INSTALL_DIR="${TP14}" HONEY_STARTER_NONINTERACTIVE=1 \
    COMPOSE_PROJECT_NAME=myproj \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SP14}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p14.out 2>&1
RC14=$?
set -e
if [ "${RC14}" -ne 0 ] && grep -q "data loss" /tmp/setup-dryrun.p14.out \
  && grep -q '^COMPOSE_PROJECT_NAME=otherproj$' "${TP14}/.env" \
  && [ ! -s /tmp/setup-dryrun.p14.log ]; then
  ok "P14: env-vs-persisted rename in NI DIES with the data-loss message; .env unchanged; no probe (log empty)"
else
  bad "P14 rc=${RC14} (want data-loss die, no probe):"
  sed 's/^/    | /' /tmp/setup-dryrun.p14.out >&2 || true
fi
rm -rf "${TP14}" "${SP14}"

# P15. --update no-warn: artifacts + persisted foo + env bar +
#      HONEY_STARTER_UPDATE_IN_PROGRESS=1 -> rc 0, .env keeps foo, no
#      confirm/data-loss warning (env ignored).
TP15="$(fresh_tree)"; SP15="$(mktemp -d)"; mkdir -p "${SP15}"
printf 'root-token-dummy\n' > "${SP15}/root_token"
printf 'PROVISION_NS=starter\nPROVISION_USER=admin\n' > "${SP15}/provision.env"
printf 'COMPOSE_PROJECT_NAME=foo\n' > "${TP15}/.env"
: > /tmp/setup-dryrun.p15.log
set +e
(
  cd "${TP15}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/dev/null DOCKER_STUB_LOG=/tmp/setup-dryrun.p15.log \
    HONEY_STARTER_INSTALL_DIR="${TP15}" HONEY_STARTER_NONINTERACTIVE=1 \
    HONEY_STARTER_UPDATE_IN_PROGRESS=1 COMPOSE_PROJECT_NAME=bar \
    HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
    HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 HD_STATE_DIR="${SP15}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p15.out 2>&1
RC15=$?
set -e
if [ "${RC15}" -eq 0 ] && grep -q '^COMPOSE_PROJECT_NAME=foo$' "${TP15}/.env" \
  && ! grep -q "Continue with the change" /tmp/setup-dryrun.p15.out \
  && ! grep -q "data loss" /tmp/setup-dryrun.p15.out; then
  ok "P15: --update ignores COMPOSE_PROJECT_NAME env (keeps persisted foo; no warn/confirm)"
else
  bad "P15 rc=${RC15} (want kept foo, no warn):"
  sed 's/^/    | /' /tmp/setup-dryrun.p15.out >&2 || true
fi
rm -rf "${TP15}" "${SP15}"

# P16. post-questionnaire re-probe: fresh answers a DIFFERENT valid name
#      (typedname) than the derived preliminary. The pre-guard probes the
#      derived name (free); the post-guard re-probes typedname — and the test
#      covers BOTH outcomes in ONE check: when typedname is free the run
#      proceeds and writes it (-p typedname in the log), and when typedname is
#      RUNNING it dies pre-write, no .env.
TP16="$(fresh_tree)"; SP16="$(mktemp -d)"
printf 'typedname\nansns\nansuser\nopenai\ngpt-4o\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.p16.answers
DERIVED16="$(derived_proj "${TP16}")"
# Scenario 1: nothing running -> rc 0, .env typedname, log has -p typedname
: > /tmp/setup-dryrun.p16a.log; printf '' > /tmp/setup-dryrun.p16a.state
set +e
(
  cd "${TP16}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p16a.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p16a.log \
    HONEY_STARTER_INSTALL_DIR="${TP16}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.p16.answers HD_STATE_DIR="${SP16}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p16a.out 2>&1
RC16A=$?
cp "${TP16}/.env" /tmp/setup-dryrun.p16a.env 2>/dev/null || true
set -e
# Scenario 2: typedname RUNNING -> die pre-write, no .env
TP16B="$(fresh_tree)"; SP16B="$(mktemp -d)"
printf 'typedname\nansns\nansuser\nopenai\ngpt-4o\nsk-ans-key\n9300\n9390\n' > /tmp/setup-dryrun.p16b.answers
: > /tmp/setup-dryrun.p16b.log; printf 'RUNNING typedname\n' > /tmp/setup-dryrun.p16b.state
set +e
(
  cd "${TP16B}"
  env -i HOME="${HOME}" PATH="${F3_STUB_DIR}:${PATH}" \
    DOCKER_STUB_STATE_FILE=/tmp/setup-dryrun.p16b.state \
    DOCKER_STUB_LOG=/tmp/setup-dryrun.p16b.log \
    HONEY_STARTER_INSTALL_DIR="${TP16B}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.p16b.answers HD_STATE_DIR="${SP16B}" \
    bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.p16b.out 2>&1
RC16B=$?
set -e
if [ "${RC16A}" -eq 0 ] \
  && grep -q '^COMPOSE_PROJECT_NAME=typedname$' "${TP16}/.env" \
  && [ -s /tmp/setup-dryrun.p16a.log ] \
  && grep -q -- "-p ${DERIVED16}" /tmp/setup-dryrun.p16a.log \
  && grep -q -- "-p typedname" /tmp/setup-dryrun.p16a.log \
  && [ "${RC16B}" -ne 0 ] \
  && [ ! -f "${TP16B}/.env" ] \
  && grep -q "refusing to set up a NEW instance" /tmp/setup-dryrun.p16b.out \
  && grep -q -- "-p typedname" /tmp/setup-dryrun.p16b.log; then
  ok "P16: post-questionnaire re-probe — answers a DIFFERENT name; -p typedname probed free -> written; when typedname runs -> dies pre-write"
else
  bad "P16 rc=${RC16A}/${RC16B} (want both re-probe outcomes):"
  sed 's/^/    | /' /tmp/setup-dryrun.p16a.out >&2 || true
  sed 's/^/    | /' /tmp/setup-dryrun.p16b.out >&2 || true
fi
rm -rf "${TP16}" "${SP16}" "${TP16B}" "${SP16B}"


# ---------------------------------------------------------------------------
# A-series. Phase A rich-output foundation — detection + prefix-only styling.
# The only styling setup.sh adds is a PREFIX on each styled line: ESC/emoji
# are NEVER interleaved with the message tokens and message text is NEVER
# rewritten, so the A-series substring asserts prove the prefix-only rule.
# Detection is gated on fd 1 being a tty (the SAFE direction), so a
# redirected run is ALWAYS plain; on a real pty, TERM=dumb / NO_COLOR
# (presence semantics) disable rich output, and only a color TERM with no
# disable-var turns it on. The pty cases defensively -u the OTHER
# color-disabling vars so a dev machine's exported NO_COLOR cannot skew them.
# ---------------------------------------------------------------------------

# A1. Redirected run (fd 1 NOT a tty) -> the rich fallback is PLAIN: no ESC
#     bytes and no non-ASCII bytes (emoji) in the captured log — even when
#     TERM claims a color-capable terminal (the gate is on fd 1 only).
TA1="$(fresh_tree)"; SA1="$(mktemp -d)"
set +e
(
  cd "${TA1}"
  HONEY_STARTER_INSTALL_DIR="${TA1}" \
  HONEY_STARTER_NONINTERACTIVE=1 \
  HONEY_NS=starter HONEY_USER=admin HONEY_AI_PROVIDER=openai \
  OPENAI_API_KEY=sk-a1key \
  HD_API_HOST_PORT=9000 HD_UI_HOST_PORT=8090 \
  HD_STATE_DIR="${SA1}" \
  TERM=xterm-256color \
  bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.a1.out 2>&1
RC_A1=$?
set -e
if [ "${RC_A1}" -eq 0 ] \
  && ! grep -q $'\x1b' /tmp/setup-dryrun.a1.out \
  && ! LC_ALL=C grep -q '[^ -~]' /tmp/setup-dryrun.a1.out; then
  ok "A1: redirected (non-tty) run is PLAIN — no ESC bytes, no emoji, even with TERM=xterm-256color"
else
  bad "A1 rc=${RC_A1} (want plain output, no ESC / no non-ASCII):"
  sed 's/^/    | /' /tmp/setup-dryrun.a1.out >&2 || true
fi
rm -rf "${TA1}" "${SA1}"

# A2. pty (fd 1 IS a tty) with TERM=dumb -> still PLAIN (no ESC bytes), while
#     the label text still matches (plain mode emits the exact original text).
if command -v python3 >/dev/null 2>&1; then
  TA2="$(fresh_tree)"; SA2="$(mktemp -d)"
  set +e
  (
    cd "${TA2}"
    env -u NO_COLOR -u HONEY_STARTER_NO_COLOR \
      -u HONEY_STARTER_NONINTERACTIVE -u HONEY_STARTER_ANSWERS_FILE \
      -u HONEY_STARTER_INSTALL_DIR \
      HOME="${HOME}" HD_STATE_DIR="${SA2}" TERM=dumb \
      python3 "${HERE}/test/pty-helper.py" --on-disk \
        "${TA2}/scripts/setup.sh" "Compose project name" \
        projname ansns ansuser openai gpt-4o sk-key-test 9300 9390 -- --dry-run
  ) >/tmp/setup-dryrun.a2.out 2>&1
  RC_A2=$?
  set -e
  if [ "${RC_A2}" -eq 0 ] \
    && ! grep -q $'\x1b' /tmp/setup-dryrun.a2.out \
    && grep -q 'Compose project name (COMPOSE_PROJECT_NAME)' /tmp/setup-dryrun.a2.out; then
    ok "A2: pty + TERM=dumb -> PLAIN (no ESC bytes; label text still matches)"
  else
    bad "A2 rc=${RC_A2} (want plain pty output under TERM=dumb):"
    sed 's/^/    | /' /tmp/setup-dryrun.a2.out >&2 || true
  fi
  rm -rf "${TA2}" "${SA2}"
else
  ok "A2 SKIPPED (python3 unavailable)"
fi

# A3. pty + TERM=xterm-256color -> RICH: ESC + emoji PRESENT, AND a message
#     substring STILL matches (proves the prefix-only rule: the label text is
#     byte-contiguous — ESC/emoji are a prefix, never interleaved).
if command -v python3 >/dev/null 2>&1; then
  TA3="$(fresh_tree)"; SA3="$(mktemp -d)"
  set +e
  (
    cd "${TA3}"
    env -u NO_COLOR -u HONEY_STARTER_NO_COLOR \
      -u HONEY_STARTER_NONINTERACTIVE -u HONEY_STARTER_ANSWERS_FILE \
      -u HONEY_STARTER_INSTALL_DIR \
      HOME="${HOME}" HD_STATE_DIR="${SA3}" TERM=xterm-256color \
      python3 "${HERE}/test/pty-helper.py" --on-disk \
        "${TA3}/scripts/setup.sh" "Compose project name" \
        projname ansns ansuser openai gpt-4o sk-key-test 9300 9390 -- --dry-run
  ) >/tmp/setup-dryrun.a3.out 2>&1
  RC_A3=$?
  set -e
  if [ "${RC_A3}" -eq 0 ] \
    && grep -q $'\x1b' /tmp/setup-dryrun.a3.out \
    && LC_ALL=C grep -q $'\xf0\x9f\x9a\x80' /tmp/setup-dryrun.a3.out \
    && grep -q 'Compose project name (COMPOSE_PROJECT_NAME)' /tmp/setup-dryrun.a3.out; then
    ok "A3: pty + TERM=xterm-256color -> RICH (ESC + rocket emoji present) while the message substring still matches (prefix-only)"
  else
    bad "A3 rc=${RC_A3} (want rich output + contiguous label):"
    sed 's/^/    | /' /tmp/setup-dryrun.a3.out >&2 || true
  fi
  rm -rf "${TA3}" "${SA3}"
else
  ok "A3 SKIPPED (python3 unavailable)"
fi

# A4. NO_COLOR presence semantics (no-color.org): set NO_COLOR=1 -> plain, AND
#     NO_COLOR= (EMPTY value, still SET) -> plain — PRESENCE disables, never
#     the value. Both pty runs use TERM=xterm-256color so NO_COLOR is the
#     SOLE disabling factor.
if command -v python3 >/dev/null 2>&1; then
  TA4A="$(fresh_tree)"; SA4A="$(mktemp -d)"
  set +e
  (
    cd "${TA4A}"
    env -u HONEY_STARTER_NO_COLOR -u HONEY_STARTER_NONINTERACTIVE \
      -u HONEY_STARTER_ANSWERS_FILE -u HONEY_STARTER_INSTALL_DIR \
      NO_COLOR=1 HOME="${HOME}" HD_STATE_DIR="${SA4A}" TERM=xterm-256color \
      python3 "${HERE}/test/pty-helper.py" --on-disk \
        "${TA4A}/scripts/setup.sh" "Compose project name" \
        projname ansns ansuser openai gpt-4o sk-key-test 9300 9390 -- --dry-run
  ) >/tmp/setup-dryrun.a4a.out 2>&1
  RC_A4A=$?
  set -e
  if [ "${RC_A4A}" -eq 0 ] && ! grep -q $'\x1b' /tmp/setup-dryrun.a4a.out; then
    ok "A4a: NO_COLOR=1 on a color-capable tty -> PLAIN (no ESC)"
  else
    bad "A4a rc=${RC_A4A} (want plain under NO_COLOR=1):"
    sed 's/^/    | /' /tmp/setup-dryrun.a4a.out >&2 || true
  fi
  rm -rf "${TA4A}" "${SA4A}"

  TA4B="$(fresh_tree)"; SA4B="$(mktemp -d)"
  set +e
  (
    cd "${TA4B}"
    env -u HONEY_STARTER_NO_COLOR -u HONEY_STARTER_NONINTERACTIVE \
      -u HONEY_STARTER_ANSWERS_FILE -u HONEY_STARTER_INSTALL_DIR \
      NO_COLOR= HOME="${HOME}" HD_STATE_DIR="${SA4B}" TERM=xterm-256color \
      python3 "${HERE}/test/pty-helper.py" --on-disk \
        "${TA4B}/scripts/setup.sh" "Compose project name" \
        projname ansns ansuser openai gpt-4o sk-key-test 9300 9390 -- --dry-run
  ) >/tmp/setup-dryrun.a4b.out 2>&1
  RC_A4B=$?
  set -e
  if [ "${RC_A4B}" -eq 0 ] && ! grep -q $'\x1b' /tmp/setup-dryrun.a4b.out; then
    ok "A4b: NO_COLOR= (EMPTY value, still SET) -> PLAIN (presence semantics, not value)"
  else
    bad "A4b rc=${RC_A4B} (want plain under NO_COLOR= empty):"
    sed 's/^/    | /' /tmp/setup-dryrun.a4b.out >&2 || true
  fi
  rm -rf "${TA4B}" "${SA4B}"
else
  ok "A4 SKIPPED (python3 unavailable)"
fi


# ---------------------------------------------------------------------------
# B. Phase B select-from-list menus (pty + answers-file regression): on a real
#    TTY with NO answers file the AI-provider and AI-model questions become
#    number-driven menus (B1 select by number, B2 Enter accepts the default,
#    B3 typed exact value), B4 invalid provider input (out-of-range number ->
#    warn + retry -> valid selection succeeds), B5 an out-of-range MODEL
#    integer (99) is warned + retried and NEVER written (valid_model would
#    otherwise accept '99' — the exact trap Phase B closes), and B6 the
#    answers-file raw-value regression: with an answers file the flat
#    raw-value path is used — NO menu is rendered and behavior is
#    byte-identical to pre-Phase-B (an unlisted-but-valid model passes through
#    untouched, whereas interactively it would need "type your own"). Each pty
#    invocation passes TERM=dumb explicitly (Phase A approved addendum).
#    python3-gated; skipped cleanly when python3 is unavailable.
if command -v python3 >/dev/null 2>&1; then
  # B1. select provider by number (2=custom) and model by number (3=gpt-4o).
  TB1="$(fresh_tree)"; SB1="$(mktemp -d)"
  set +e
  (
    cd "${TB1}"
    env -u NO_COLOR -u HONEY_STARTER_NO_COLOR -u HONEY_STARTER_NONINTERACTIVE \
      -u HONEY_STARTER_ANSWERS_FILE -u HONEY_STARTER_INSTALL_DIR \
      HOME="${HOME}" HD_STATE_DIR="${SB1}" TERM=dumb \
      python3 "${HERE}/test/pty-helper.py" --on-disk \
        "${TB1}/scripts/setup.sh" "Compose project name" \
        projb1 ansns ansuser 2 3 https://b1.example/v1 sk-b1 9300 9390 -- --dry-run
  ) >/tmp/setup-dryrun.b1.out 2>&1
  RC_B1=$?
  set -e
  if [ "${RC_B1}" -eq 0 ] \
    && grep -q 'AI provider:   custom' /tmp/setup-dryrun.b1.out \
    && grep -q '^HD_AI_MODEL=gpt-4o$' "${TB1}/.env" \
    && grep -q '^HD_AI_BASE_URL=https://b1.example/v1$' "${TB1}/.env"; then
    ok "B1: provider by number 2=custom + model by number 3=gpt-4o (HD_AI_MODEL=gpt-4o, HD_AI_BASE_URL written)"
  else
    bad "B1 rc=${RC_B1} (want custom + gpt-4o + base URL):"
    sed 's/^/    | /' /tmp/setup-dryrun.b1.out >&2 || true
  fi
  rm -rf "${TB1}" "${SB1}"

  # B2. Enter accepts the default at BOTH menus: provider -> inferred openai,
  #     model -> the gpt-5.4-mini pin.
  TB2="$(fresh_tree)"; SB2="$(mktemp -d)"
  set +e
  (
    cd "${TB2}"
    env -u NO_COLOR -u HONEY_STARTER_NO_COLOR -u HONEY_STARTER_NONINTERACTIVE \
      -u HONEY_STARTER_ANSWERS_FILE -u HONEY_STARTER_INSTALL_DIR \
      HOME="${HOME}" HD_STATE_DIR="${SB2}" TERM=dumb \
      python3 "${HERE}/test/pty-helper.py" --on-disk \
        "${TB2}/scripts/setup.sh" "Compose project name" \
        projb2 ansns ansuser "" "" sk-b2 9300 9390 -- --dry-run
  ) >/tmp/setup-dryrun.b2.out 2>&1
  RC_B2=$?
  set -e
  if [ "${RC_B2}" -eq 0 ] \
    && grep -q 'AI provider:   openai' /tmp/setup-dryrun.b2.out \
    && grep -q '^HD_AI_MODEL=gpt-5.4-mini$' "${TB2}/.env"; then
    ok "B2: Enter accepts the default at both menus (provider=openai, model=gpt-5.4-mini pin)"
  else
    bad "B2 rc=${RC_B2} (want openai + gpt-5.4-mini pin):"
    sed 's/^/    | /' /tmp/setup-dryrun.b2.out >&2 || true
  fi
  rm -rf "${TB2}" "${SB2}"

  # B3. typed exact value at both menus (openai / gpt-4o) is accepted.
  TB3="$(fresh_tree)"; SB3="$(mktemp -d)"
  set +e
  (
    cd "${TB3}"
    env -u NO_COLOR -u HONEY_STARTER_NO_COLOR -u HONEY_STARTER_NONINTERACTIVE \
      -u HONEY_STARTER_ANSWERS_FILE -u HONEY_STARTER_INSTALL_DIR \
      HOME="${HOME}" HD_STATE_DIR="${SB3}" TERM=dumb \
      python3 "${HERE}/test/pty-helper.py" --on-disk \
        "${TB3}/scripts/setup.sh" "Compose project name" \
        projb3 ansns ansuser openai gpt-4o sk-b3 9300 9390 -- --dry-run
  ) >/tmp/setup-dryrun.b3.out 2>&1
  RC_B3=$?
  set -e
  if [ "${RC_B3}" -eq 0 ] \
    && grep -q 'AI provider:   openai' /tmp/setup-dryrun.b3.out \
    && grep -q '^HD_AI_MODEL=gpt-4o$' "${TB3}/.env"; then
    ok "B3: typed exact value at both menus (openai / gpt-4o) accepted"
  else
    bad "B3 rc=${RC_B3} (want typed openai + gpt-4o):"
    sed 's/^/    | /' /tmp/setup-dryrun.b3.out >&2 || true
  fi
  rm -rf "${TB3}" "${SB3}"

  # B4. invalid provider input (out-of-range number 9) -> warn + retry ->
  #     valid selection (2=custom) succeeds; loop terminates.
  TB4="$(fresh_tree)"; SB4="$(mktemp -d)"
  set +e
  (
    cd "${TB4}"
    env -u NO_COLOR -u HONEY_STARTER_NO_COLOR -u HONEY_STARTER_NONINTERACTIVE \
      -u HONEY_STARTER_ANSWERS_FILE -u HONEY_STARTER_INSTALL_DIR \
      HOME="${HOME}" HD_STATE_DIR="${SB4}" TERM=dumb \
      python3 "${HERE}/test/pty-helper.py" --on-disk \
        "${TB4}/scripts/setup.sh" "Compose project name" \
        projb4 ansns ansuser 9 2 3 https://b4.example/v1 sk-b4 9300 9390 -- --dry-run
  ) >/tmp/setup-dryrun.b4.out 2>&1
  RC_B4=$?
  set -e
  if [ "${RC_B4}" -eq 0 ] \
    && grep -q "invalid selection '9': enter a number 1-3" /tmp/setup-dryrun.b4.out \
    && grep -q 'AI provider:   custom' /tmp/setup-dryrun.b4.out \
    && grep -q '^HD_AI_MODEL=gpt-4o$' "${TB4}/.env"; then
    ok "B4: invalid provider input 9 -> warn + retry -> 2=custom succeeds (loop terminates)"
  else
    bad "B4 rc=${RC_B4} (want 9 warned/retried, then custom):"
    sed 's/^/    | /' /tmp/setup-dryrun.b4.out >&2 || true
  fi
  rm -rf "${TB4}" "${SB4}"

  # B5. out-of-range MODEL integer 99 -> warn + retry -> 3=gpt-4o; '99' is
  #     NEVER written to .env (the valid_model("99") trap).
  TB5="$(fresh_tree)"; SB5="$(mktemp -d)"
  set +e
  (
    cd "${TB5}"
    env -u NO_COLOR -u HONEY_STARTER_NO_COLOR -u HONEY_STARTER_NONINTERACTIVE \
      -u HONEY_STARTER_ANSWERS_FILE -u HONEY_STARTER_INSTALL_DIR \
      HOME="${HOME}" HD_STATE_DIR="${SB5}" TERM=dumb \
      python3 "${HERE}/test/pty-helper.py" --on-disk \
        "${TB5}/scripts/setup.sh" "Compose project name" \
        projb5 ansns ansuser openai 99 3 sk-b5 9300 9390 -- --dry-run
  ) >/tmp/setup-dryrun.b5.out 2>&1
  RC_B5=$?
  set -e
  if [ "${RC_B5}" -eq 0 ] \
    && grep -q "invalid selection '99': enter a number 1-7" /tmp/setup-dryrun.b5.out \
    && grep -q '^HD_AI_MODEL=gpt-4o$' "${TB5}/.env" \
    && ! grep -q '^HD_AI_MODEL=99$' "${TB5}/.env"; then
    ok "B5: model 99 out-of-range -> warn + retry -> gpt-4o; '99' NEVER written"
  else
    bad "B5 rc=${RC_B5} (want 99 warned/retried, then gpt-4o, no 99 in .env):"
    sed 's/^/    | /' /tmp/setup-dryrun.b5.out >&2 || true
  fi
  rm -rf "${TB5}" "${SB5}"
else
  ok "Phase B select-from-list menu hermetics SKIPPED (python3 unavailable)"
fi

# B6. answers-file raw-value regression (pre-Phase-B path): with an answers
#     file the flat raw-value prompt path is used — NO menu is rendered (even
#     with a color-capable TERM) and raw values pass through UNMODIFIED (an
#     unlisted-but-valid model stays as typed; interactively it would need the
#     "type your own" option). No ESC bytes (rich disabled by redirection).
TB6="$(fresh_tree)"; SB6="$(mktemp -d)"
printf 'projb6\nansns\nansuser\nopenai\ngpt-raw6\nsk-b6\n9300\n9390\n' > /tmp/setup-dryrun.ansB6
set +e
(
  cd "${TB6}"
  env -i HOME="${HOME}" PATH="${PATH}" \
    HONEY_STARTER_INSTALL_DIR="${TB6}" \
    HONEY_STARTER_ANSWERS_FILE=/tmp/setup-dryrun.ansB6 HD_STATE_DIR="${SB6}" \
    TERM=xterm-256color bash scripts/setup.sh --dry-run
) >/tmp/setup-dryrun.b6.out 2>&1
RC_B6=$?
set -e
if [ "${RC_B6}" -eq 0 ] \
  && grep -q '^HD_AI_MODEL=gpt-raw6$' "${TB6}/.env" \
  && ! grep -q '1) openai' /tmp/setup-dryrun.b6.out \
  && ! grep -q '1) gpt-5.4' /tmp/setup-dryrun.b6.out \
  && ! grep -q 'select a number' /tmp/setup-dryrun.b6.out \
  && ! grep -q 'type your own' /tmp/setup-dryrun.b6.out \
  && ! grep -q $'\x1b' /tmp/setup-dryrun.b6.out; then
  ok "B6: answers-file raw-value regression — raw model passes through (gpt-raw6), NO menu, NO ESC (pre-Phase-B byte-identical)"
else
  bad "B6 rc=${RC_B6} (want raw answers-file path, no menu, no ESC):"
  sed 's/^/    | /' /tmp/setup-dryrun.b6.out >&2 || true
fi
rm -rf "${TB6}" "${SB6}"


if [ "${FAIL}" -eq 0 ]; then
  echo "=== setup-dryrun: ${PASS} checks passed ==="
else
  echo "=== setup-dryrun: ${FAIL} checks FAILED (${PASS} passed) ===" >&2
fi
[ "${FAIL}" -eq 0 ]

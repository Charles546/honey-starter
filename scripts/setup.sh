#!/usr/bin/env bash
# setup.sh — guided installer for honey-starter deployments. One script, two
# execution modes, and (Phase 5) THREE target-selection branches so the same
# command SETS UP a NEW instance at a given directory or RE-SETS UP (manages)
# an EXISTING instance in place. Multiple instances coexist as separate
# directories with distinct ports. COMPOSE_PROJECT_NAME is PER-INSTANCE and
# PERSISTED in each instance's .env by setup.sh (fresh installs get the derived
# hs-<basename>-<hash8>, or whatever the questionnaire/env chose); runtime
# precedence is .env > exported env > honey-starter. Existing instances are
# NEVER auto-renamed; an env-supplied change on an existing instance requires
# an explicit confirm (data-loss warning) or dies in non-interactive runs; an
# exported name with nothing persisted is silently adopted (and probed).
#
#   1. BOOTSTRAP copy  — standalone/piped (BASH_SOURCE is empty under
#      `curl ... | bash` / `bash -s`, or the file is not inside a tree with
#      scripts/start.sh + scripts/lib.sh + the compose + bootstrap layout).
#      That copy performs ONLY path-independent bootstrap: --help, target
#      resolution, fail-fast preflight, download + verify + extract of the
#      release tarball into the target, then
#      `exec bash <target>/scripts/setup.sh "$@"`. The bootstrap copy NEVER
#      sources scripts/lib.sh, NEVER computes paths from BASH_SOURCE for its
#      own logic and NEVER writes .env. It NEVER prompts either — except the
#      single documented branch-3 directory prompt (a standalone run with no
#      <dir>, no HONEY_STARTER_INSTALL_DIR, no answers file, not
#      non-interactive, and a real /dev/tty asks exactly
#      `Install directory [~/honey-starter]` once, AFTER the fail-fast
#      preflight and BEFORE the download). All questionnaire prompting lives in
#      the on-disk copy.
#
#   2. ON-DISK copy     — when the same file runs from inside a valid tree.
#      Resolves the CHOSEN target (branch 1: a given <dir> — manage an
#      existing instance there or materialize a NEW one from this tree via an
#      ALWAYS-copy; branch 2: no <dir> — this tree, in place), runs the guided
#      questionnaire, writes the CHOSEN tree's repo-root .env (chmod 600) and
#      delegates to that tree's scripts/start.sh. scripts/start.sh remains the
#      single consumer of scripts/lib.sh.
#
#   3. Target selection (the three branches, authoritative):
#      1. a <dir> argument is given -> existing instance there: manage it;
#         otherwise set up a NEW instance there.
#      2. no <dir>, script inside an existing instance -> manage it in place.
#      3. no <dir>, standalone/piped -> HONEY_STARTER_INSTALL_DIR (branch-3
#         only) or ~/honey-starter; interactive: one directory prompt.
#
# Secret contract (identical to scripts/start.sh / deploy/README.md):
#   * The ONLY secret material setup.sh writes is the AI API key, written into
#     the repo-root .env (chmod 600) purely as a PROVISIONING INPUT for
#     start.sh, which seeds it into Vault at secrets/data/<ns>/daemon and
#     never lets it appear in compose/environment at runtime.
#   * AI keys are NEVER echoed to stdout/logs (masked in the summary), are
#     unset from setup.sh's own environment after capture, and are scrubbed
#     (`env -u`) from the environment handed to the start.sh child: start.sh
#     gets them by sourcing the 600-mode .env itself.
#   * Vault root token + unseal keys live in ${HD_STATE_DIR} (chmod 600,
#     host-only, never mounted); the daemon gets only the AppRole identity
#     files via hd-secret-file:// bind-mount. VAULT_TOKEN is never set in the
#     daemon container.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Charles546/honey-starter/main/scripts/setup.sh | bash
#   bash <repo>/scripts/setup.sh            # on-disk copy (clone / re-run)
#   bash <repo>/scripts/setup.sh [<dir>]    # set up <dir> new or manage it
#   bash <repo>/scripts/setup.sh .          # manage the instance in cwd
#   curl ... | bash -s /opt/honey-starter   # piped, explicit target dir
#   bash <repo>/scripts/setup.sh --dry-run  # prereqs + questionnaire + .env render only
#   bash <repo>/scripts/setup.sh --update   # re-extract the release over <dir>
#   bash <repo>/scripts/setup.sh --help
#
# See the --help text (print_help) for the full questionnaire, the AI provider
# matrix, the three-way HD_AI_MODEL semantics, the non-interactive contract
# and the .env writer contract.
set -euo pipefail

# --- constants ---------------------------------------------------------------
REPO_SLUG="Charles546/honey-starter"
CODELOAD_URL="https://codeload.github.com/${REPO_SLUG}/tar.gz"
DEFAULT_INSTALL_SUBDIR="honey-starter"
# Layout a downloaded tree must contain (plan contract: start.sh, lib.sh, the
# compose file, and the bootstrap init).
TREE_LAYOUT_FILES=(
  scripts/start.sh
  scripts/lib.sh
  deploy/docker-compose.yaml
  bootstrap/init.yaml
)
# A tree is only treated as an installed / on-disk tree (and re-exec'd) when it
# additionally contains this script itself.
INSTALLED_TREE_FILES=(
  scripts/start.sh
  scripts/lib.sh
  scripts/setup.sh
  deploy/docker-compose.yaml
  bootstrap/init.yaml
)
# Managed .env keys (rewritten in place each run):
#   * COMPOSE_PROJECT_NAME (Phase 6) — per-instance: SET on fresh
#     (never-provisioned) installs (env -> answers -> typed -> derived default)
#     and on a confirmed/adopted rename of an existing one; KEPT verbatim on a
#     no-change manage run (absent stays absent so the lib.sh honey-starter
#     default applies by omission, migration-safe).
#   * HONEY_NS, HONEY_USER, HD_AI_BASE_URL, HD_AI_MODEL, HD_API_HOST_PORT,
#     HD_UI_HOST_PORT, the derived HD_UI_URL, and HD_CONFIG_CHECK_INTERVAL --
#     the last written ONLY when explicitly supplied (env or an existing .env
#     line), otherwise absent so the compose default of 30m applies by
#     construction (never 1m).
#
# Secret .env keys (replaced ONLY on an explicit value; with no
# explicit value an existing line is left untouched; with no explicit value and
# no existing line the key is omitted (start.sh seeds its own placeholder).
SECRET_KEYS=(OPENAI_API_KEY OPENROUTER_API_KEY)

# The AI model default setup.sh pins on fresh openai/custom installs. It is a
# DELIBERATE copy of the gpt-5.4-mini fallback that MUST stay in sync with the
# compose default (deploy/docker-compose.yaml HD_AI_MODEL=...) and the
# bootstrap config fallback (bootstrap/engines.yaml `default "gpt-5.4-mini"
# .env.AI_MODEL`). setup.sh writing the explicit line is runtime-identical
# (compose already injects HD_AI_MODEL when .env leaves it unset).
MODEL_DEFAULT="gpt-5.4-mini"

# Phase B interactive select-from-list menus (setup.sh UX). The menus are a
# TTY-only convenience layered on the SAME raw answer values the answers-file /
# non-interactive paths have always consumed: AI_PROVIDER_MENU holds the exact
# HONEY_AI_PROVIDER values (openai|custom|skip) and AI_MODEL_MENU is a curated
# "common models" list offered interactively. The documented pin default is
# always shown in the model prompt (Enter accepts it even when it is not
# listed) and a trailing "type your own" option covers any other model.
# MENU_TYPE_OWN is the sentinel used inside the model menu item list. It is
# never adopted as a model value: a literal "type your own" typed at the menu
# matches the menu item and routes to prompt_type_own_model, which validates
# and returns the user's own free-string model (the sentinel itself is
# consumed by that routing and never written to .env).
AI_PROVIDER_MENU=(openai custom skip)
AI_MODEL_MENU=(gpt-5.4 gpt-5.4-mini gpt-4o gpt-4o-mini o3 o4-mini)
MENU_TYPE_OWN="__type_your_own__"
MENU_TYPE_OWN_LABEL="type your own"

# Per-instance COMPOSE_PROJECT_NAME derivation (Phase 6): fresh (never
# provisioned) installs get hs-<sanitized-basename>-<hash8>, deterministic from
# the resolved INSTALL_DIR (never SCRIPT_TREE, so two instances materialized
# from the same invoked tree hash differently). PROJECT_NAME_MAX bounds the
# generated name at 3 + 20 + 1 + 8 = 32 (compose allows [a-z0-9_-], max 63).
PROJECT_PREFIX="hs-"
PROJECT_BASENAME_MAX=20
PROJECT_HASH_LEN=8
PROJECT_NAME_MAX=32

# Tree entries excluded when an on-disk run materializes a NEW instance from
# the invoked tree (tar --exclude patterns). A fresh target NEVER inherits
# .git, .env or .honey-starter — it cannot clone the source deployment's
# secrets/state (intentional; the source tree itself is only ever COPIED,
# never moved, so the user can re-run setup from it against other targets).
MATERIALIZE_EXCLUDES=(--exclude='./.git' --exclude='./.env' --exclude='./.honey-starter')

# --- output helpers (Phase A rich-output foundation) --------------------------
# Rich-output detection: enabled ONLY when fd 1 is a real terminal AND no
# color-disable env var is PRESENT (no-color.org convention: any value,
# INCLUDING EMPTY, disables — checked with `[ -z "${VAR+x}" ]`, never
# `[ -z "$VAR" ]` which treats an empty value as unset) AND TERM is set and
# not "dumb". Computed ONCE and cached in RICH_OUTPUT; every msg_* helper
# re-invokes rich_output_enabled(). The gate is on STDOUT only — INTENTIONAL
# and conservative: prompts/die messages go to stderr, so when stdout is a
# redirected file but stderr is a tty, detection says OFF and prompts render
# UNSTYLED. That is the SAFE direction (styled output appears only when fd 1
# is a tty — consistent with `make setup-dryrun` captures being plain because
# non-pty tests redirect fd 1). Do NOT "fix" this to also probe stdin/stderr.
RICH_OUTPUT=0
RICH_OUTPUT_UNCACHED=1
rich_output_enabled() {
  if [ "${RICH_OUTPUT_UNCACHED}" -eq 1 ]; then
    RICH_OUTPUT_UNCACHED=0
    if [ -t 1 ] \
      && [ -z "${NO_COLOR+x}" ] \
      && [ -z "${HONEY_STARTER_NO_COLOR+x}" ] \
      && [ -n "${TERM:-}" ] && [ "${TERM}" != "dumb" ]; then
      RICH_OUTPUT=1
    else
      RICH_OUTPUT=0
    fi
  fi
  [ "${RICH_OUTPUT}" -eq 1 ]
}

# ANSI SGR codes + status glyphs. Emitted as literal bytes (bash passes UTF-8
# through unchanged even under LC_ALL=C; the only garble risk is the terminal
# consumer, which is exactly what the fallback excludes). The msg_* helpers
# render the ORIGINAL line text byte-for-byte in both modes: rich mode only
# PREPENDS the style+glyph and appends ONE trailing reset — it NEVER
# interleaves ESC / glyph with the message tokens ([ok], ERROR:, WARNING:,
# NOTE:, === … ===, prompt labels) and NEVER rewrites message text (the strict
# prefix-only rule).
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_UNDERLINE=$'\033[4m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_CYAN=$'\033[36m'
E_OK="✅"
E_FAIL="❌"
E_WARN="⚠"
E_INFO="ℹ"
E_SECTION="🚀"
E_KEY="🔑"

msg_ok() {
  if rich_output_enabled; then
    printf '%s%s %s%s\n' "${C_GREEN}" "${E_OK}" "$*" "${C_RESET}"
  else
    printf '%s\n' "$*"
  fi
}
msg_fail() {
  if rich_output_enabled; then
    printf '%s%s %s%s\n' "${C_RED}" "${E_FAIL}" "$*" "${C_RESET}" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}
msg_warn() {
  if rich_output_enabled; then
    printf '%s%s %s%s\n' "${C_YELLOW}" "${E_WARN}" "$*" "${C_RESET}" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}
msg_info() {
  if [ -z "$*" ]; then
    printf '\n'
    return 0
  fi
  if rich_output_enabled; then
    printf '%s%s %s%s\n' "${C_CYAN}" "${E_INFO}" "$*" "${C_RESET}"
  else
    printf '%s\n' "$*"
  fi
}
msg_note() { msg_info "$*"; }
msg_section() {
  if rich_output_enabled; then
    printf '%s%s%s %s%s\n' "${C_BOLD}" "${C_CYAN}" "${E_SECTION}" "$*" "${C_RESET}"
  else
    printf '%s\n' "$*"
  fi
}
# msg_input: prompt labels (bold; the label/default text stays byte-contiguous —
# a single bold prefix + one trailing reset, NEVER between label tokens).
msg_input() {
  if rich_output_enabled; then
    printf '%s%s%s' "${C_BOLD}" "$*" "${C_RESET}"
  else
    printf '%s' "$*"
  fi
}
# msg_key: key/secret prompt label — 🔑 + bold on the label line; the label
# text stays byte-contiguous (one bold prefix + one trailing reset, never
# between label tokens).
msg_key() {
  if rich_output_enabled; then
    printf '%s%s %s%s' "${C_BOLD}" "${E_KEY}" "$*" "${C_RESET}"
  else
    printf '%s' "$*"
  fi
}
# msg_highlight: bold+underline for install dir / state dir / project paths.
msg_highlight() {
  if rich_output_enabled; then
    printf '%s%s%s%s\n' "${C_BOLD}" "${C_UNDERLINE}" "$*" "${C_RESET}"
  else
    printf '%s\n' "$*"
  fi
}

info() { msg_info "$*"; }
note() { msg_note "NOTE: $*"; }
warn() { msg_warn "WARNING: $*"; }
die() { msg_fail "ERROR: $*"; exit 1; }
usage_die() { msg_fail "ERROR: $*"; printf 'Try --help for usage.\n' >&2; exit 2; }


print_help() {
  cat <<'HELP'
honey-starter guided installer (scripts/setup.sh)

Installs a complete Honeydipper instance (Valkey + file-backed Vault + daemon
+ web UI) on a Linux docker host with one command and a short questionnaire.
The same script SETS UP a NEW instance at a given directory or RE-SETS UP
(manages) an EXISTING instance in place; multiple instances coexist as
separate directories with distinct ports. The compose project
(COMPOSE_PROJECT_NAME) is PER-INSTANCE and PERSISTED in each instance's .env
by setup.sh: fresh installs get the derived hs-<basename>-<hash8> (or whatever
the questionnaire/env chose), existing instances are NEVER auto-renamed, and
an env-supplied change on an existing instance requires an explicit confirm
(data-loss warning) or dies in non-interactive runs.

Usage:
  curl -fsSL https://raw.githubusercontent.com/Charles546/honey-starter/main/scripts/setup.sh | bash
  bash scripts/setup.sh [options] [<dir>]
  bash scripts/setup.sh .            # manage the instance in the current dir
  bash scripts/setup.sh new-proj     # set up a NEW instance in ./new-proj
  curl -fsSL <curl>/scripts/setup.sh | bash -s /opt/honey-starter
  bash scripts/setup.sh --update     # re-extract the release over <dir>

Options:
  --help, -h           show this help and exit 0 (works in the piped copy too)
  --dry-run            prereqs + questionnaire + masked .env preview + write the
                       .env (chmod 600), then STOP before scripts/start.sh
  --update             force re-extract of the release over the target tree
                       (tar merges; it never deletes stale files), then continue
  --force-reinstall    same as --update
  --                   end of options; the next argument is the <dir>

Target selection (3 branches):
  1. a <dir> argument is given  -> operate on that directory. An EXISTING
     honey-starter instance there is re-set-up (managed) in place; otherwise
     a NEW instance is set up there (an on-disk run copies the invoked tree,
     a piped/bootstrap run downloads the release).
  2. no <dir>, and the script runs inside a honey-starter tree -> re-set-up
     that instance in place.
  3. no <dir>, and the script is standalone/piped (not in a tree) -> the
     install dir is HONEY_STARTER_INSTALL_DIR (interactive shell: one prompt
     "Install directory [~/honey-starter]" - see below) or ~/honey-starter.

New vs existing:
  * existing instance (layout incl. scripts/setup.sh) -> managed in place;
    its .env prefills the questionnaire; the HONEY_NS/HONEY_USER desync
    guards apply to ITS provision state.
  * a pre-Phase-4 tree (layout present, no setup.sh) -> the invoked copy is
    merged over it (.git/.env/.honey-starter preserved) and it is then
    managed in place.
  * absent or empty dir -> a new instance is materialized. An ON-DISK run
    copies the invoked tree (ALWAYS a copy - the source tree persists; the
    fresh target never inherits .git/.env/.honey-starter, so it cannot clone
    the source deployment's secrets/state); a piped run downloads the
    release. Later runs then manage it in place.
  * exists, non-empty, no layout -> setup.sh dies "not a honey-starter tree"
    (never destructive).

--update:
  The target is resolved first (ensure the tree exists: materialize-new via
  copy or reuse), then the release is re-extracted over it (copy then
  re-extract), then the target's own copy re-execs in place. In a piped run
  --update behaves as before against the resolved install dir.

Two execution modes live in this single file:

  * Bootstrap copy  - standalone/piped (no valid honey-starter tree next to
    the script), incl. `curl ... | bash -s <dir>`. Performs path-independent
    bootstrap: --help, target resolution, fail-fast preflight, download +
    verify + extract of the release tarball into the target, then re-execs
    the on-disk copy. IT NEVER PROMPTS except for the single branch-3
    directory prompt (see below); all questionnaire prompting happens in the
    on-disk copy.
  * On-disk copy    - once the script runs inside a tree (branch 2, or the
    on-disk half of branch 1: managing another instance / a new instance
    materialized from this tree). Runs the guided questionnaire, writes the
    repo-root .env (chmod 600) of the CHOSEN tree and delegates to that
    tree's scripts/start.sh.

The branch-3 directory prompt (the single bootstrap exception):
  When NO <dir> is given and the bootstrap copy has no
  HONEY_STARTER_INSTALL_DIR and no HONEY_STARTER_ANSWERS_FILE, is not
  non-interactive, and a real /dev/tty is available, it asks exactly one
  question AFTER the fail-fast preflight (a host with no viable docker is
  never prompted) and BEFORE the download:

    Install directory [~/honey-starter]

  (Enter accepts the default.) The default is shown in its ~/ form whenever
  it is under $HOME (otherwise as-is); a typed ~/x expands to $HOME/x and a
  bare ~ means $HOME. An answers-file-only or no-tty bootstrap run silently
  uses HONEY_STARTER_INSTALL_DIR or the default. Every other question is
  asked only by the on-disk copy.

Install dir:
  HONEY_STARTER_INSTALL_DIR is consulted ONLY in branch 3 (standalone, where
  $0 is meaningless). On-disk runs (branches 1-2) never consult it - to
  target another instance, pass a <dir>. The canonical one-liner passes
  through branch 3 (env consulted) and re-execs the on-disk copy, so branch 2
  applies in place afterwards. Once a target is chosen (bootstrap hand-off
  and on-disk entry) setup.sh exports HONEY_STARTER_INSTALL_DIR=<target> so
  delegation and any re-exec agree.

Questionnaire (interactive; a question is asked ONLY when its environment
variable is unset, and on an existing install every default is prefilled from
the current .env; Enter accepts the [default]). The compose project name is
item 0 and is asked ONLY on a never-provisioned (fresh) instance; manage
runs NEVER ask it:
  0. COMPOSE_PROJECT_NAME  per-instance; lowercase; charset
                      [a-z0-9_-] (start/end alnum). FRESH ONLY: default =
                      the derived hs-<basename>-<hash8> of the install dir
                      (Enter accepts it); an env value wins over the .env
                      prefill. Existing instances: never asked, never
                      re-derived (see "Compose project" below).
  1. HONEY_NS         Vault KV namespace prefix; default starter; single Vault
                      path segment ([A-Za-z0-9._-]+); MUST stay constant for
                      the life of a deployment (start.sh refuses changes).
  2. HONEY_USER       admin subject; default admin; plain token
                      ([A-Za-z0-9@._-]+); constant after first run.
  3. HONEY_AI_PROVIDER  openai (default) | custom (OpenAI-compatible endpoint)
                      | skip. openrouter is NEVER offered interactively.
  4. HD_AI_MODEL      AI model (default gpt-5.4-mini; the pin). Asked ONLY
                      for openai/custom - see HD_AI_MODEL semantics below.
  5. HD_AI_BASE_URL   ONLY when provider=custom; required http(s):// endpoint;
                      never silently defaulted.
  6. API key          hidden input (masked '*' feedback + re-type confirm
                      on a real tty; read -s no-echo fallback). For openai/
                      custom. Empty = keep
                      the current key (existing install) or add later
                      (placeholder flow: start.sh seeds a placeholder and you
                      add the real key to .env and re-run).
  7. ports            HD_API_HOST_PORT (default 9000) and HD_UI_HOST_PORT
                      (default 8090), integers 1-65535, confirmed together.

  HONEY_STARTER_ANSWERS_FILE (when set) supplies the answers first,
  newline-delimited, in exactly the order above: the leading
  COMPOSE_PROJECT_NAME line (lowercase; empty = accept the derived default;
  a manage-in-place run consumes and DISCARDS this slot - never prompts for
  it), then HONEY_NS, HONEY_USER, provider, model (only for openai/custom),
  base URL (5, only for custom), API key (only for openai/custom), ports, and
  the final Y/n for a full non-dry run. There is NO install-dir line - the
  answers file's physical location is indication enough; target a
  non-default directory with a positional argument (setup.sh <dir>). An
  exhausted answers file in a manage run must not push the project slot to
  the missing list. Otherwise answers come from a real /dev/tty (opened
  explicitly). If neither is available and the run is not non-interactive,
  setup.sh exits with guidance - it never silently defaults and never hangs.

HD_AI_MODEL semantics (three-way; the model is a non-secret pin):
  * HD_AI_MODEL=<value> (non-empty) -> override, written to .env, wins over
    everything (all providers, passthrough preserved).
  * HD_AI_MODEL= (explicitly empty) -> a definitive NO-PIN run: the existing
    override is NOT kept, the line is removed, and the question is skipped
    (its answer cannot silently re-pin). Non-interactive: same.
  * HD_AI_MODEL unset + provider openai/custom -> the question is asked;
    interactive Enter or an empty answers-file line accepts the default,
    WRITING HD_AI_MODEL=gpt-5.4-mini (the pin). Non-interactive unset -> the
    same pin.
  * provider skip -> no question; an existing override line is kept when env
    is unset, removed when env is explicitly empty, replaced when non-empty.
  Under the pin default, "engine default / no pin" is reached by one run with
  HD_AI_MODEL= (removes the line) or deleting the line by hand. No-pin is not
  sticky: a later run with HD_AI_MODEL unset re-pins (runtime-identical, since
  compose already defaults HD_AI_MODEL). Valid model: non-empty, no
  whitespace/control, charset [A-Za-z0-9._:/@+-]. An invalid model DIES
  regardless of the input source -- environment, answers file, or a typed
  answer at the prompt (a later line is never adopted as the model, and the
  pin is never written over an invalid answer).

AI provider matrix (what setup.sh writes to .env):
  openai   -> writes OPENAI_API_KEY=<key> when provided + the HD_AI_MODEL pin;
              HD_AI_BASE_URL stays unset unless supplied (the engine falls
              back to https://api.openai.com/v1). NOTE: on a re-run, a
              previously-set HD_AI_BASE_URL from an earlier custom install is
              KEPT (managed, only removed when unset) - remove it from .env
              to fully revert to the default.
  custom   -> writes HD_AI_BASE_URL=<required validated http(s):// endpoint>
              + OPENAI_API_KEY=<key> when provided + the HD_AI_MODEL pin;
              never silently defaults the base URL (the default gpt-5.4-mini
              may not exist on your endpoint - type your own model).
  skip     -> no key/base/model lines are ADDED; an existing HD_AI_MODEL
              override is kept/removed/replaced per the env state above.
  openrouter is never prompted, but HONEY_STARTER_NONINTERACTIVE runs still
  accept OPENROUTER_API_KEY (start.sh seeds openrouter_api_key into Vault
  harmlessly until the bootstrap config is edited). The openrouter ENGINE
  exists in bootstrap/engines.yaml but no shipped agent references it (the
  starter agent is hard-bound to openai/default). Quirk (doc only):
  .env.AI_MODEL is SHARED by the openai default engine and the openrouter
  engine (qwen/qwen3.5-9b default); in compose HD_AI_MODEL is always set so
  openrouter's own default is already dead. To use OpenRouter, edit the
  RENDERED copy .honey-starter/config/agents.yaml to `engine: openrouter` and
  re-run `make start`; its base_url is fixed in engines.yaml and its Vault key
  field is openrouter_api_key.

Non-interactive mode:
  HONEY_STARTER_NONINTERACTIVE=1 (or every decision variable supplied via env
  so nothing would be prompted) requires no tty. Defaults apply for anything
  with a documented default (HD_AI_MODEL included); a missing value with NO
  default (HD_AI_BASE_URL for provider=custom) exits 1 listing the missing
  variables. A full (non-dry) non-interactive run also requires
  HONEY_STARTER_ASSUME_YES=1 to skip the write-and-start confirmation.

.env writer contract (scripts/setup.sh is the guided writer):
  * Unmanaged lines (comments, blanks, HD_JWT_SIGNING_KEY, image pins, ...)
    are preserved byte-exact.
  * Managed keys (HONEY_NS, HONEY_USER, HD_AI_BASE_URL, HD_AI_MODEL,
    HD_API_HOST_PORT, HD_UI_HOST_PORT) are rewritten in place each run.
    HD_UI_URL (the public UI base URL) is PRESERVED when set via env or an
    existing .env line, and only derived as http://localhost:<UI port> when
    nothing is set. HD_CONFIG_CHECK_INTERVAL is written only when explicitly
    supplied (default stays 30m by omission).
  * Secret keys (OPENAI_API_KEY, OPENROUTER_API_KEY) are replaced only on an
    explicit value; an existing line is never downgraded to a placeholder.
  * Values are shell-quoted (single quotes when needed, embedded single quotes
    escaped); key charset [A-Za-z_][A-Za-z0-9_]*; new keys append before the
    final newline; the file ends with a newline and is chmod 600. First
    creation emits a `# Generated by scripts/setup.sh` header.

Compose project (COMPOSE_PROJECT_NAME) - per-instance, persisted in .env:
  setup.sh writes COMPOSE_PROJECT_NAME into each instance's repo-root .env.
  FRESH installs get the derived hs-<sanitized-basename>-<hash8> (deterministic
  from the resolved install dir; Enter accepts it, or type/env your own);
  EXISTING instances are never auto-renamed - manage reads the persisted name
  silently. Runtime precedence is .env > exported env > honey-starter.
  Distinct HD_API_HOST_PORT / HD_UI_HOST_PORT remain mandatory for
  SIMULTANEOUS instances (distinct ports are not auto-detected).
  Changing a PROVISIONED instance's project re-initializes Vault: it builds a
  NEW <new>_vault-file volume and OVERWRITES root_token/unseal_key in
  <state dir> - the old <old>_vault-file secrets are no longer addressed
  (DATA LOSS). To change it: stop the instance first
  (`docker compose -p <old> down -v`) or keep <old>. An env-supplied project
  with NOTHING persisted is silently adopted (and the guard probes the
  adopted name); `--update` ignores COMPOSE_PROJECT_NAME env entirely (keeps
  the persisted/absent value).
  The F3 project/state guard probes the EFFECTIVE project name on every
  effective change: a NEW instance (or a rename/adopt) that would collide
  with a running stack / existing <proj>_vault-file volume DIES EARLY with
  guidance instead of silently binding to another deployment's containers +
  initialized Vault volume and failing mid-start on a missing unseal key.

Preflight (fail-fast, before any prompt or download):
  Linux guard -> bash >= 4 -> curl + tar + sha256sum -> docker + compose v2 ->
  `docker info` reachability -> docker-group/sudo capability. jq/openssl/
  htpasswd presence and the optional install offer happen on the on-disk copy,
  still before the questionnaire. docker/compose are never auto-installed.

Environment variables (all optional):
  COMPOSE_PROJECT_NAME         setup-time override: fresh installs use it
                               (validated; invalid DIES); on an existing
                               instance with a persisted name it requires an
                               explicit TTY confirm (data-loss warning) or
                               dies in non-interactive runs; with nothing
                               persisted it is silently adopted. `--update`
                               ignores it. Runtime precedence is .env >
                               exported env > honey-starter.
  HONEY_STARTER_INSTALL_DIR    install dir (branch 3 only; default ~/honey-starter)
  HONEY_STARTER_REF            branch or tag to fetch (default main)
  HONEY_STARTER_EXPECT_SHA256  require this sha256 of the downloaded tarball
  HONEY_STARTER_NONINTERACTIVE set to 1 to disable all prompting
  HONEY_STARTER_ASSUME_YES     set to 1 to skip the final confirm
  HONEY_STARTER_ANSWERS_FILE   path to a newline-delimited answers file
  HONEY_STARTER_AUTO_INSTALL   set to 1 to auto-approve Debian-family tool
                               installs (jq/openssl/htpasswd)
  HONEY_STARTER_NO_COLOR       set (any value, even empty) to disable rich
                               output (emoji/color) even on a color-capable
                               terminal; plain-text output is always emitted
                               for pipes/logs/non-tty and TERM=dumb
  HONEY_NS                     Vault KV namespace prefix (default starter)
  HONEY_USER                   admin subject (default admin)
  HONEY_AI_PROVIDER            openai | custom | skip (default openai)
  HD_AI_MODEL                  model override | explicitly-empty = no-pin run
                               (unset = question/pin; see HD_AI_MODEL above)
  HD_AI_BASE_URL               OpenAI-compatible base URL (required for custom)
  HD_API_HOST_PORT             published daemon API port (default 9000)
  HD_UI_HOST_PORT              published UI port (default 8090)
  HD_UI_URL                    public UI base URL (OAuth/SAML redirects);
                               preserved when set, else derived from
                               HD_UI_HOST_PORT
  HD_CONFIG_CHECK_INTERVAL     explicit override only (default stays 30m)
  OPENAI_API_KEY               AI key provisioning input (openai/custom)
  OPENROUTER_API_KEY           accepted for the openrouter engine (never
                               prompted; seeded by start.sh harmlessly until
                               the rendered agent config points at openrouter)
  HD_STATE_DIR                 runtime state dir (default <repo>/.honey-starter)

Partial-state / reset path:
  If .honey-starter/ exists (root token etc.) but provision.env is absent
  (failed earlier run), setup.sh warns that no completed provisioning is
  recorded and that a HONEY_NS/HONEY_USER change is not yet guarded by
  start.sh. Reset: `make down-volumes` then `rm -rf .honey-starter`, then
  re-run. A re-run never regenerates the admin token or the AppRole identity
  pair (start.sh's guarantee).
HELP
}

# --- mode detection -----------------------------------------------------------
# BASH_SOURCE is used ONLY to locate the on-disk copy, and ONLY after the
# real-file + valid-tree marker check below. Under `curl ... | bash` / `bash -s`
# BASH_SOURCE is empty; under `bash downloaded-setup.sh` it is a real file but
# the tree marker files are absent -> still the bootstrap copy.
BOOTSTRAP_MODE=1
SCRIPT_REAL=""
SCRIPT_TREE=""
detect_mode() {
  local cand dir f
  BOOTSTRAP_MODE=1
  SCRIPT_REAL=""
  SCRIPT_TREE=""
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    cand="${BASH_SOURCE[0]}"
    case "${cand}" in
      */*) ;;
      *) cand="./${cand}" ;;
    esac
    if command -v readlink >/dev/null 2>&1; then
      cand="$(readlink -f "${cand}" 2>/dev/null || printf '%s' "${cand}")"
    fi
    if [ -n "${cand}" ] && [ -f "${cand}" ]; then
      SCRIPT_REAL="${cand}"
      dir="$(dirname "$(dirname "${SCRIPT_REAL}")")"
      for f in "${INSTALLED_TREE_FILES[@]}"; do
        if [ ! -f "${dir}/${f}" ]; then
          SCRIPT_REAL=""
          return 0
        fi
      done
      SCRIPT_TREE="${dir}"
      BOOTSTRAP_MODE=0
    fi
  fi
}

# --- small shared helpers -----------------------------------------------------
first_nonempty() {
  local v
  for v in "$@"; do
    if [ -n "${v}" ]; then printf '%s' "${v}"; return 0; fi
  done
  return 0
}

# Shell-quote a value for canonical KEY=value output: single-quote when the
# value contains characters outside the safe set, escaping embedded single
# quotes ('\''); rejects embedded newlines (returns 1).
shell_quote() {
  local v="$1" ch out="" i
  case "${v}" in
    *$'\n'*) return 1 ;;
  esac
  case "${v}" in
    *[!a-zA-Z0-9_@%+=:,./-]*)
      out="'"
      for ((i = 0; i < ${#v}; i++)); do
        ch="${v:i:1}"
        if [ "${ch}" = "'" ]; then
          out+="'\\''"
        else
          out+="${ch}"
        fi
      done
      out+="'"
      printf '%s' "${out}"
      ;;
    *) printf '%s' "${v}" ;;
  esac
}

is_sensitive_key() {
  case "$1" in
    OPENAI_API_KEY|OPENROUTER_API_KEY|*TOKEN*|*SECRET*|*PASSWORD*|*PASSWD*|*_KEY|*_KEY_*)
      return 0 ;;
    *) return 1 ;;
  esac
}

os_distro_id() {
  if [ -r /etc/os-release ]; then
    sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | head -n 1
  else
    printf 'unknown'
  fi
}

# --- .env parsing (read-only; the file is NEVER sourced, so nothing leaks) ----
declare -a RAW_LINES=()
declare -A CUR=()

decode_env_value() {
  # $1 = raw text after KEY= ; prints the decoded value. Understands the
  # single-quoted form this writer emits (embedded ' as '\'') and a plain
  # double-quoted / unquoted form for prefill tolerance of hand-edited .env.
  local raw="$1" out="" ch i=0 n bs="\\" dq='"'
  if [ "${#raw}" -ge 2 ] && [ "${raw:0:1}" = "'" ] && [ "${raw: -1}" = "'" ]; then
    raw="${raw:1:${#raw}-2}"
    n=${#raw}
    while [ "${i}" -lt "${n}" ]; do
      ch="${raw:i:1}"
      if [ "${ch}" = "'" ] && [ $((i + 3)) -le "${n}" ] \
        && [ "${raw:i+1:1}" = "${bs}" ] && [ "${raw:i+2:1}" = "'" ] && [ "${raw:i+3:1}" = "'" ]; then
        out+="'"
        i=$((i + 4))
      else
        out+="${ch}"
        i=$((i + 1))
      fi
    done
    printf '%s' "${out}"
  elif [ "${#raw}" -ge 2 ] && [ "${raw:0:1}" = "${dq}" ] && [ "${raw: -1}" = "${dq}" ]; then
    raw="${raw:1:${#raw}-2}"
    n=${#raw}
    while [ "${i}" -lt "${n}" ]; do
      ch="${raw:i:1}"
      if [ "${ch}" = "${bs}" ] && [ $((i + 1)) -lt "${n}" ]; then
        out+="${raw:i+1:1}"
        i=$((i + 2))
      else
        out+="${ch}"
        i=$((i + 1))
      fi
    done
    printf '%s' "${out}"
  else
    printf '%s' "${raw}"
  fi
}

parse_env() {
  local file="$1" line key rest
  RAW_LINES=()
  CUR=()
  if [ -f "${file}" ]; then
    mapfile -t RAW_LINES < "${file}" || true
    for line in "${RAW_LINES[@]}"; do
      case "${line}" in
        ''|'#'*) continue ;;
        *[![:space:]]*) ;;
        *) continue ;;
      esac
      if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
        CUR["${key}"]="$(decode_env_value "${rest}")"
      fi
    done
  fi
}

cur_value() {
  # cur_value KEY -> prints the current .env value for KEY (or nothing).
  printf '%s' "${CUR[$1]:-}"
}

# --- arguments ---------------------------------------------------------------
DRY_RUN=0
DO_UPDATE=0
POSITIONAL_TARGET=""
# resolve_arg_path: absolutize a <dir> argument at PARSE time (both modes parse
# identically — `setup .` resolves against the CALLER's $PWD, not the tree's
# location; the bootstrap forwards "$@" so `curl ... | bash -s <dir>` resolves
# the same way). Expands a leading ~/ AND a bare ~ (the exact value "~") to
# $HOME (HOME-unset leaves a bare ~ literal), then normalizes via readlink -f
# (fallback cd && pwd -P) so equality vs the invoked tree (SCRIPT_TREE,
# resolved the same way in detect_mode) is canonical.
resolve_arg_path() {
  local p="$1" out=""
  if [ "${p}" = "~" ] && [ -n "${HOME:-}" ]; then
    p="${HOME:-}"
  fi
  if [ "${p#\~/}" != "${p}" ]; then
    p="${HOME:-}/${p#\~/}"
  fi
  case "${p}" in
    /*) ;;
    *) p="$(pwd)/${p}" ;;
  esac
  if command -v readlink >/dev/null 2>&1; then
    out="$(readlink -f "${p}" 2>/dev/null || true)"
  fi
  if [ -z "${out}" ]; then
    if [ -d "${p}" ]; then
      out="$(cd "${p}" && pwd -P)"
    else
      out="${p}"
    fi
  fi
  printf '%s' "${out}"
}

parse_args() {
  local a positional=0 endflags=0
  DRY_RUN=0
  DO_UPDATE=0
  POSITIONAL_TARGET=""
  for a in "$@"; do
    if [ "${endflags}" -eq 1 ]; then
      if [ "${positional}" -ge 1 ]; then
        usage_die "more than one directory argument: ${a}"
      fi
      POSITIONAL_TARGET="$(resolve_arg_path "${a}")"
      positional=1
      continue
    fi
    case "${a}" in
      --) endflags=1 ;;
      --help|-h) print_help; exit 0 ;;
      --dry-run) DRY_RUN=1 ;;
      --update|--force-reinstall) DO_UPDATE=1 ;;
      -*)
        usage_die "unknown option: ${a}" ;;
      *)
        if [ "${positional}" -ge 1 ]; then
          usage_die "more than one directory argument: ${a}"
        fi
        POSITIONAL_TARGET="$(resolve_arg_path "${a}")"
        positional=1
        ;;
    esac
  done
}
# Re-export captured AI secrets right before re-exec'ing another copy of this
# script: exec does not carry shell variables, and the child copy re-captures
# them at the top of its own main(). This keeps the keys OUT of every child
# that runs in between (curl/tar/sha256sum/apt/docker) while still delivering
# them to the on-disk copy that writes .env.
re_export_secrets_for_exec() {
  if [ -n "${EXPLICIT_OPENAI_KEY}" ]; then
    export OPENAI_API_KEY="${EXPLICIT_OPENAI_KEY}"
  fi
  if [ -n "${EXPLICIT_OPENROUTER_KEY}" ]; then
    export OPENROUTER_API_KEY="${EXPLICIT_OPENROUTER_KEY}"
  fi
}

# reload_on_disk_without_update_flags: re-exec the on-disk copy after an update
reload_on_disk_without_update_flags() {
  local a
  local -a newargs=()
  for a in "$@"; do
    case "${a}" in
      --update|--force-reinstall) ;;
      *) newargs+=("${a}") ;;
    esac
  done
  re_export_secrets_for_exec
  exec bash "${INSTALL_DIR}/scripts/setup.sh" "${newargs[@]}"
}

# --- preflight ----------------------------------------------------------------
# Deliberately duplicated from start.sh (CAN_ROOT semantics) — setup.sh is
# self-contained and must not depend on the tree it may not have downloaded yet.
CAN_ROOT=0
detect_can_root() {
  CAN_ROOT=0
  if [ "$(id -u)" -eq 0 ]; then
    CAN_ROOT=1
  elif command -v sudo >/dev/null 2>&1; then
    if sudo -n true >/dev/null 2>&1; then
      CAN_ROOT=1
    # Match start.sh exactly: probe stdout ([ -t 1 ]), NOT stdin. Under the
    # canonical `curl ... | bash` one-liner stdin is the exhausted script pipe,
    # so [ -t 0 ] is false even in a real terminal and interactive sudo would
    # never be attempted there (while the delegated start.sh probes stdout and
    # DOES prompt) — the preflight note and the apt gate must agree with
    # start.sh's actual behavior.
    elif [ -t 1 ]; then
      if sudo true >/dev/null 2>&1; then
        CAN_ROOT=1
      fi
    fi
  fi
}

preflight_os() {
  if [ "$(uname -s)" != "Linux" ]; then
    die "honey-starter runs on Linux only (docker bind mounts + the root-without-caps file-permission model). Detected: $(uname -s)"
  fi
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    die "bash 4 or newer is required (found ${BASH_VERSION:-unknown})"
  fi
  msg_ok "  [ok] Linux $(uname -r)"
  msg_ok "  [ok] bash ${BASH_VERSION%%(*}"
}

preflight_download_tools() {
  local missing=0
  # sha256sum is HARD-required (Phase 6): the per-instance COMPOSE_PROJECT_NAME
  # is derived from a sha256 of the resolved install dir, so a host without it
  # cannot run the guided installer. Linux-only: coreutils / busybox both
  # provide it.
  for cmd in curl tar sha256sum; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      warn "required command not found: ${cmd}"
      missing=1
    else
      msg_ok "  [ok] ${cmd}"
    fi
  done
  if [ "${missing}" -eq 1 ]; then
    case "$(os_distro_id)" in
      debian|ubuntu) die "install curl + tar + sha256sum first, e.g.: sudo apt-get update && sudo apt-get install -y curl tar coreutils" ;;
      rhel|fedora|centos|rocky|almalinux) die "install curl + tar + sha256sum first, e.g.: sudo dnf install -y curl tar coreutils" ;;
      arch) die "install curl + tar + sha256sum first, e.g.: sudo pacman -S --noconfirm curl tar coreutils" ;;
      alpine) die "install curl + tar + sha256sum first, e.g.: apk add --no-cache curl tar coreutils" ;;
      *) die "install curl + tar + sha256sum, then re-run" ;;
    esac
  fi
  if [ -n "${HONEY_STARTER_EXPECT_SHA256:-}" ] && ! command -v sha256sum >/dev/null 2>&1; then
    die "HONEY_STARTER_EXPECT_SHA256 is set but sha256sum is not available"
  fi
}

# docker + compose v2 + daemon reachability + docker-group/sudo capability.
# A host with no viable docker fails fast BEFORE any prompt or download.
# In --dry-run the check is informational only (render-only validation).
preflight_docker() {
  local have_docker=1 have_compose=1
  if ! command -v docker >/dev/null 2>&1; then
    have_docker=0
  elif ! docker compose version >/dev/null 2>&1; then
    have_compose=0
  fi
  if [ "${have_docker}" -eq 1 ] && [ "${have_compose}" -eq 1 ]; then
    msg_ok "  [ok] docker + compose v2"
    if docker info >/dev/null 2>&1; then
      msg_ok "  [ok] docker daemon reachable (docker info)"
      detect_can_root
      if [ "${CAN_ROOT}" -eq 0 ]; then
        note "no root/sudo capability detected; scripts/start.sh will write identity files 0644"
      fi
      return 0
    fi
    if [ -S /var/run/docker.sock ] && [ "$(id -u)" -ne 0 ] \
      && ! { command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; }; then
      if [ "${DRY_RUN}" -eq 1 ]; then
        warn "docker daemon not reachable as the current user (dry-run continues for render-only validation)"
        return 0
      fi
      msg_fail "ERROR: the docker daemon is not reachable as the current user."
      echo "       If docker is installed but your user is not in the docker group:" >&2
      echo "         sudo usermod -aG docker \$USER" >&2
      echo "       then log out and back in (or: newgrp docker) and re-run." >&2
      echo "       Alternative: run this installer with sudo (sudo bash scripts/setup.sh)." >&2
      die "docker daemon permission denied (/var/run/docker.sock)"
    fi
    if [ "${DRY_RUN}" -eq 1 ]; then
      warn "docker daemon is not reachable (docker info failed; dry-run continues for render-only validation)"
      return 0
    fi
    die "docker daemon is not reachable (docker info failed). Start docker and re-run."
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    warn "docker / compose v2 not found (dry-run continues for render-only validation)"
    return 0
  fi
  local distro
  distro="$(os_distro_id)"
  msg_fail "ERROR: docker with compose v2 is required and is NOT auto-installed."
  echo "       Install it manually, then re-run. Distro-specific guidance:" >&2
  case "${distro}" in
    debian|ubuntu)
      echo "         follow https://docs.docker.com/engine/install/${distro}/ to install" >&2
      echo "         docker-ce + the docker-compose-plugin, then add your user to the" >&2
      echo "         docker group (sudo usermod -aG docker \$USER) and re-login." >&2
      ;;
    rhel|fedora|centos|rocky|almalinux)
      echo "         follow https://docs.docker.com/engine/install/${distro}/ to install" >&2
      echo "         docker-ce + docker-compose-plugin (dnf), then re-login into the docker group." >&2
      ;;
    arch)
      echo "         sudo pacman -S --noconfirm docker docker-compose" >&2
      echo "         sudo systemctl enable --now docker" >&2
      ;;
    alpine)
      echo "         apk add --no-cache docker docker-cli-compose" >&2
      echo "         rc-update add docker default && rc-service docker start" >&2
      ;;
    *)
      echo "         install Docker Engine + the compose v2 plugin for your distribution." >&2
      ;;
  esac
  die "docker + compose v2 not found"
}

# Optional on-disk tools (jq/openssl/htpasswd). On the on-disk copy only, still
# before the questionnaire. Debian-family: offer apt install when
# interactive-confirmed or HONEY_STARTER_AUTO_INSTALL=1; other families print
# the exact package set and stop. Never guesses.
preflight_optional_tools() {
  local missing=() cmd pkglist distro
  for cmd in jq openssl htpasswd; do
    if command -v "${cmd}" >/dev/null 2>&1; then
      msg_ok "  [ok] ${cmd}"
    else
      missing+=("${cmd}")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    warn "missing optional tools (${missing[*]}); dry-run continues for render-only validation"
    return 0
  fi
  distro="$(os_distro_id)"
  case "${distro}" in
    debian|ubuntu)
      pkglist="jq openssl apache2-utils"
      if [ "${HONEY_STARTER_AUTO_INSTALL:-0}" = "1" ]; then
        info "--- installing ${pkglist} via apt (HONEY_STARTER_AUTO_INSTALL=1)"
        if [ "${CAN_ROOT}" -eq 1 ]; then
          if [ "$(id -u)" -eq 0 ]; then
            apt-get update && apt-get install -y jq openssl apache2-utils
          else
            sudo apt-get update && sudo apt-get install -y jq openssl apache2-utils
          fi
        else
          die "cannot install ${pkglist}: no root/sudo capability. Install manually and re-run."
        fi
      elif [ "${HAVE_TTY}" -eq 1 ] && [ "${NONINTERACTIVE}" -eq 0 ]; then
        local ans
        msg_input "setup.sh needs: ${pkglist}. Install with apt now? [y/N] " >&2
        IFS= read -r -u "${TTY_FD}" ans || ans=n
        case "${ans}" in
          y|Y|yes|YES)
            if [ "${CAN_ROOT}" -eq 1 ]; then
              if [ "$(id -u)" -eq 0 ]; then
                apt-get update && apt-get install -y jq openssl apache2-utils
              else
                sudo apt-get update && sudo apt-get install -y jq openssl apache2-utils
              fi
            else
              die "cannot install ${pkglist}: no root/sudo capability. Install manually and re-run."
            fi
            ;;
          *)
            die "missing required tools: ${pkglist}. Install them (sudo apt-get install -y ${pkglist}) and re-run."
            ;;
        esac
      else
        die "missing required tools for ${distro}: ${pkglist} (sudo apt-get install -y ${pkglist})"
      fi
      ;;
    rhel|fedora|centos|rocky|almalinux)
      die "missing required tools for ${distro}: jq openssl httpd-tools (sudo dnf install -y jq openssl httpd-tools)"
      ;;
    arch)
      die "missing required tools for ${distro}: jq openssl apache (sudo pacman -S --noconfirm jq openssl apache)"
      ;;
    alpine)
      die "missing required tools for ${distro}: jq openssl apache2-utils (apk add --no-cache jq openssl apache2-utils)"
      ;;
    *)
      die "missing required tools: ${missing[*]}"
      ;;
  esac
}

# --- download / verify / extract ---------------------------------------------
TMP_DIR=""
cleanup_tmp() {
  if [ -n "${TMP_DIR}" ]; then
    rm -rf "${TMP_DIR}" || true
    TMP_DIR=""
  fi
}

verify_tree() {
  local d="$1" f
  for f in "${TREE_LAYOUT_FILES[@]}"; do
    if [ ! -f "${d}/${f}" ]; then
      die "tree at ${d} is missing ${f} (layout check failed)"
    fi
  done
}

tree_is_valid() {
  local d="$1" f
  [ -d "${d}" ] || return 1
  for f in "${INSTALLED_TREE_FILES[@]}"; do
    [ -f "${d}/${f}" ] || return 1
  done
  return 0
}

# tree_is_presetup DIR: a pre-Phase-4 (Phase-3-era) tree — the layout files are
# present but scripts/setup.sh is absent. The one-liner upgrades it in place
# (tar merge, .honey-starter state preserved) instead of dying.
tree_is_presetup() {
  local d="$1" f
  [ -d "${d}" ] || return 1
  [ -f "${d}/scripts/setup.sh" ] && return 1
  for f in "${TREE_LAYOUT_FILES[@]}"; do
    [ -f "${d}/${f}" ] || return 1
  done
  return 0
}

# --- new-instance materialization + target dispatch (Phase 5) ------------------
# materialize_new TARGET: copy the INVOKED tree (SCRIPT_TREE) into a
# same-parent temp dir and atomically mv (rename(2)) it into place, with a
# copy+remove fallback on EXDEV (cross-filesystem). The source tree is NEVER
# moved — it must persist for future re-runs against other targets. The fresh
# target never inherits .git/.env/.honey-starter (MATERIALIZE_EXCLUDES), so it
# cannot clone the source deployment's secrets/state (documented).
materialize_new() {
  local target="$1" tmp_parent tmpdir
  tmp_parent="$(dirname "${target}")"
  mkdir -p "${tmp_parent}"
  tmpdir="$(mktemp -d "${tmp_parent}/.honey-starter-new.XXXXXX")"
  if ! ( cd "${SCRIPT_TREE}" && tar -cf - "${MATERIALIZE_EXCLUDES[@]}" . ) \
    | ( cd "${tmpdir}" && tar -xf - ); then
    rm -rf "${tmpdir}"
    die "cannot materialize a new instance at ${target} (copy failed)"
  fi
  verify_tree "${tmpdir}"
  if [ ! -f "${tmpdir}/scripts/setup.sh" ]; then
    rm -rf "${tmpdir}"
    die "cannot materialize a new instance at ${target} (invoked tree has no scripts/setup.sh)"
  fi
  if [ -e "${target}" ]; then
    # an EMPTY dir is consumed by the atomic rename; anything else must have
    # been rejected by dispatch (never destructive here)
    if ! rmdir "${target}" 2>/dev/null; then
      rm -rf "${tmpdir}"
      die "cannot materialize a new instance at ${target} (target exists)"
    fi
  fi
  if mv "${tmpdir}" "${target}"; then
    info "--- materialized a new honey-starter instance at ${target} (copied from ${SCRIPT_TREE})"
  else
    # EXDEV / cross-filesystem fallback: copy + remove (NEVER mv the source).
    # After a failed rename the target does not exist yet (mv is atomic), so
    # create it first; the mktemp content is removed only after a full copy.
    if mkdir -p "${target}" && cp -a "${tmpdir}/." "${target}/" && rm -rf "${tmpdir}"; then
      info "--- materialized a new honey-starter instance at ${target} (copied from ${SCRIPT_TREE})"
    else
      rm -rf "${tmpdir}"
      die "cannot materialize a new instance at ${target}"
    fi
  fi
  verify_tree "${target}"
}

# merge_invoked_over_presetup TARGET: a pre-Phase-4 tree (layout present, no
# scripts/setup.sh) is upgraded by merging a copy of the invoked tree over it
# with the same exclusions (.git/.env/.honey-starter preserved — the target's
# own state stays, and it gains scripts/setup.sh).
merge_invoked_over_presetup() {
  local target="$1"
  warn "target ${target} predates scripts/setup.sh (Phase 4)"
  warn "merging the invoked tree over it (.git/.env/.honey-starter kept); it is now managed in place"
  if ! ( cd "${SCRIPT_TREE}" && tar -cf - "${MATERIALIZE_EXCLUDES[@]}" . ) \
    | ( cd "${target}" && tar -xf - ); then
    die "cannot merge the invoked tree over ${target}"
  fi
  verify_tree "${target}"
  [ -f "${target}/scripts/setup.sh" ] || die "merged tree at ${target} has no scripts/setup.sh (unexpected)"
}

# dispatch_target TARGET: branch-1 new-vs-existing decision for an on-disk run
# with a <dir> argument. Sets INSTALL_DIR to the CHOSEN tree. Never
# destructive: a non-empty no-layout dir dies "not a honey-starter tree".
dispatch_target() {
  local target="$1"
  if [ "${target}" = "${SCRIPT_TREE}" ]; then
    # target == invoked tree (after readlink -f normalization): pure in-place
    INSTALL_DIR="${SCRIPT_TREE}"
    return 0
  fi
  if tree_is_valid "${target}"; then
    info "--- re-setting up the existing honey-starter instance at ${target}"
    INSTALL_DIR="${target}"
    return 0
  fi
  if tree_is_presetup "${target}"; then
    merge_invoked_over_presetup "${target}"
    INSTALL_DIR="${target}"
    return 0
  fi
  if [ ! -e "${target}" ] || [ -z "$(ls -A "${target}" 2>/dev/null || true)" ]; then
    materialize_new "${target}"
    INSTALL_DIR="${target}"
    return 0
  fi
  die "${target} is not a honey-starter tree. Move it away, remove it, or pass another directory."
}

# ask_install_dir DEFAULT -> prints the branch-3 destination. Fires ONLY when a
# standalone (piped/bootstrap) run has no <dir>, no HONEY_STARTER_INSTALL_DIR,
# no answers file, is not non-interactive, and a real /dev/tty is available.
# Exactly ONE prompt, AFTER the fail-fast preflight, BEFORE the download; the
# bootstrap copy otherwise never prompts (this is the single deliberate
# exception). Answers-file-only or no-tty runs keep DEFAULT silently.
ask_install_dir() {
  local default="$1" ans="" tfd="" display=""
  [ -z "${POSITIONAL_TARGET}" ] || { printf '%s' "${default}"; return 0; }
  [ -z "${HONEY_STARTER_INSTALL_DIR:-}" ] || { printf '%s' "${default}"; return 0; }
  [ -z "${HONEY_STARTER_ANSWERS_FILE:-}" ] || { printf '%s' "${default}"; return 0; }
  [ "${HONEY_STARTER_NONINTERACTIVE:-0}" != "1" ] || { printf '%s' "${default}"; return 0; }
  # Show the default in its ~/ form when it is under $HOME (the documented
  # "[~/honey-starter]" — never the spilled absolute path); otherwise as-is.
  display="${default}"
  if [ -n "${HOME:-}" ] && [ "${display#"${HOME}/"}" != "${display}" ]; then
    # shellcheck disable=SC2088 # literal "~/..." display form is INTENTIONAL
    # (the prompt shows "[~/honey-starter]", never the spilled absolute path)
    display="~/${display#"${HOME}/"}"
  fi
  if { exec {tfd}<>/dev/tty; } 2>/dev/null; then
    msg_input "Install directory [${display}] " >&2
    if IFS= read -r -u "${tfd}" ans && [ -n "${ans}" ]; then
      default="${ans}"
      if [ "${default}" = "~" ] && [ -n "${HOME:-}" ]; then
        default="${HOME:-}"
      fi
      if [ "${default#\~/}" != "${default}" ]; then
        default="${HOME:-}/${default#\~/}"
      fi
      case "${default}" in
        /*) ;;
        *) default="$(pwd)/${default}" ;;
      esac
      default="$(resolve_arg_path "${default}")"
    else
      printf '\n' >&2
    fi
    exec {tfd}>&- 2>/dev/null || true
    exec {tfd}<&- 2>/dev/null || true
  fi
  printf '%s' "${default}"
}

# download_and_install DIR UPDATE(0|1)
#   UPDATE=0 fresh install: download to a sibling temp dir, verify, extract,
#            atomic mv into place (DIR must not exist or be empty).
#   UPDATE=1 re-extract over an EXISTING tree (tar merges; never deletes
#            stale files — warned). When the dir does not exist, falls through
#            to the fresh-install branch (no raw tar error).
download_and_install() {
  local dir="$1" update="$2" ref tarball extract tmp_parent url_ok=0
  ref="${HONEY_STARTER_REF:-main}"
  tmp_parent="$(dirname "${dir}")"
  mkdir -p "${tmp_parent}"
  TMP_DIR="$(mktemp -d "${tmp_parent}/.honey-starter-dl.XXXXXX")"
  tarball="${TMP_DIR}/honey-starter.tar.gz"
  info "--- downloading honey-starter (ref=${ref}) from ${REPO_SLUG}"
  if curl -fsSL "${CODELOAD_URL}/refs/heads/${ref}" -o "${tarball}"; then
    url_ok=1
  elif curl -fsSL "${CODELOAD_URL}/refs/tags/${ref}" -o "${tarball}"; then
    url_ok=1
  fi
  if [ "${url_ok}" -ne 1 ]; then
    cleanup_tmp
    die "cannot download ${REPO_SLUG}@${ref}. Check HONEY_STARTER_REF (a branch or tag name) and network access to codeload.github.com"
  fi
  if [ -n "${HONEY_STARTER_EXPECT_SHA256:-}" ]; then
    local actual
    actual="$(sha256sum "${tarball}" | awk '{print $1}')"
    if [ "${actual}" != "${HONEY_STARTER_EXPECT_SHA256}" ]; then
      cleanup_tmp
      die "sha256 mismatch for the downloaded tarball: expected ${HONEY_STARTER_EXPECT_SHA256}, got ${actual}"
    fi
    msg_ok "  [ok] sha256 verified"
  fi
  if [ "${update}" -eq 1 ] && [ -d "${dir}" ]; then
    info "--- extracting over existing tree (tar merges; it never deletes stale files)"
    tar -xzf "${tarball}" --strip-components=1 -C "${dir}"
    verify_tree "${dir}"
  else
    # Fresh install. Also the fallback when --update targets a nonexistent
    # dir: clean extract + atomic mv (never a raw tar error).
    extract="${TMP_DIR}/extract"
    mkdir -p "${extract}"
    tar -xzf "${tarball}" --strip-components=1 -C "${extract}"
    verify_tree "${extract}"
    if [ -e "${dir}" ]; then
      if [ -n "$(ls -A "${dir}" 2>/dev/null || true)" ]; then
        cleanup_tmp
        die "install dir ${dir} already exists and is not a honey-starter tree. Move it away, remove it, or choose another HONEY_STARTER_INSTALL_DIR"
      fi
      rmdir "${dir}"
    fi
    # mv inside the same parent filesystem == rename(2): atomic for observers.
    mv "${extract}" "${dir}"
    verify_tree "${dir}"
    info "--- installed honey-starter tree at ${dir}"
  fi
  cleanup_tmp
}

# --- state dir + provision helpers -------------------------------------------
STATE_DIR=""
PROVISION_FILE=""
PROVISION_NS=""
PROVISION_USER=""

resolve_state_dir() {
  local sd
  sd="$(first_nonempty "${HD_STATE_DIR:-}" "$(cur_value HD_STATE_DIR)")"
  if [ -z "${sd}" ]; then
    sd="${INSTALL_DIR}/.honey-starter"
  else
    case "${sd}" in
      /*) ;;
      *) sd="${INSTALL_DIR}/${sd}" ;;
    esac
  fi
  STATE_DIR="${sd}"
  PROVISION_FILE="${STATE_DIR}/provision.env"
}

read_provision() {
  local f="${PROVISION_FILE}" line
  PROVISION_NS=""
  PROVISION_USER=""
  if [ -f "${f}" ]; then
    while IFS= read -r line; do
      case "${line}" in
        PROVISION_NS=*) PROVISION_NS="${line#PROVISION_NS=}" ;;
        PROVISION_USER=*) PROVISION_USER="${line#PROVISION_USER=}" ;;
      esac
    done < "${f}"
  fi
}

state_dir_has_artifacts() {
  [ -d "${STATE_DIR}" ] && {
    [ -f "${STATE_DIR}/root_token" ] || [ -f "${STATE_DIR}/unseal_key" ] || [ -f "${STATE_DIR}/admin_token" ] || [ -d "${STATE_DIR}/identity" ]
  }
}

# --- questionnaire plumbing ---------------------------------------------------
# Prompt input sources, in order: HONEY_STARTER_ANSWERS_FILE (newline-delimited
# answers replayed through the same helper) -> real /dev/tty (opened
# explicitly; masked `*` feedback with re-type confirmation for keys, read -s
# no-echo fallback). If neither is available the run must be
# non-interactive (explicit flag or every decision already env-supplied), else
# we die with guidance — never a silent default, never a hang.
ANSWERS_FD=""
HAVE_ANSWERS=0
TTY_FD=""
HAVE_TTY=0
NONINTERACTIVE=0
declare -a MISSING_VARS=()

open_input_sources() {
  if [ -n "${HONEY_STARTER_ANSWERS_FILE:-}" ]; then
    if [ -r "${HONEY_STARTER_ANSWERS_FILE}" ]; then
      exec {ANSWERS_FD}<"${HONEY_STARTER_ANSWERS_FILE}"
      HAVE_ANSWERS=1
    else
      die "HONEY_STARTER_ANSWERS_FILE is set but not readable: ${HONEY_STARTER_ANSWERS_FILE}"
    fi
  fi
  if { exec {TTY_FD}<>/dev/tty; } 2>/dev/null; then
    HAVE_TTY=1
  else
    TTY_FD=""
  fi
  if [ "${HONEY_STARTER_NONINTERACTIVE:-0}" = "1" ]; then
    NONINTERACTIVE=1
  fi
  if [ "${NONINTERACTIVE}" -eq 0 ] && [ "${HAVE_ANSWERS}" -eq 0 ] && [ "${HAVE_TTY}" -eq 0 ]; then
    # No prompt source at all. Only proceed when nothing would be prompted
    # (every decision variable is already supplied via the environment).
    if all_answers_supplied; then
      NONINTERACTIVE=1
    else
      die "run in a terminal, or set HONEY_STARTER_NONINTERACTIVE=1 and the required env vars (see --help)"
    fi
  fi
  register_cleanup
}

register_cleanup() {
  trap 'close_input_sources' EXIT
}

close_input_sources() {
  if [ -n "${ANSWERS_FD}" ]; then
    exec {ANSWERS_FD}<&- 2>/dev/null || true
    ANSWERS_FD=""
  fi
  if [ -n "${TTY_FD}" ]; then
    exec {TTY_FD}>&- 2>/dev/null || true
    exec {TTY_FD}<&- 2>/dev/null || true
    TTY_FD=""
  fi
  cleanup_tmp
}

# all_answers_supplied: every decision variable that the questionnaire would
# prompt for (when unset) is already set in the environment, so no input source
# is needed. OPENAI_API_KEY is not included: empty = add-later is a valid
# documented default. HD_AI_BASE_URL is required only for provider=custom.
all_answers_supplied() {
  local p
  p="${HONEY_AI_PROVIDER:-}"
  [ -n "${HONEY_NS:-}" ] || return 1
  [ -n "${HONEY_USER:-}" ] || return 1
  [ -n "${p}" ] || return 1
  [ -n "${HD_API_HOST_PORT:-}" ] || return 1
  [ -n "${HD_UI_HOST_PORT:-}" ] || return 1
  if [ "${p}" = "custom" ] && [ -z "${HD_AI_BASE_URL:-}" ]; then
    return 1
  fi
  return 0
}

# masked_read SAVED_STATE TTY_FD - interactive per-character masked input for
# secret/API-key prompts. Switches /dev/tty to raw mode (-icanon -isig -echo)
# inside a SUBSHELL whose scoped EXIT trap restores the saved termios; the
# parent's `trap 'close_input_sources' EXIT` is inherited untouched, and a
# Ctrl-C (byte 0x03, seen AS DATA because -isig keeps the line discipline from
# turning it into a real SIGINT) restores the terminal and exits 130 as a
# NORMAL exit so every cleanup trap still runs (terminal usable after; no raw
# left behind; no wedge). Each printable byte echoes one '*' to stderr;
# Backspace/DEL pops the last character and erases its star; Enter submits.
# The entered value is returned through a 600-mode mktemp temp file read back
# by the caller - it NEVER crosses stdout, so a redirected log or $(...)
# capture cannot see the secret or corrupt the star feedback. Uses `dd
# bs=1 count=1` rather than read -N1: bash's read -N on a tty re-enables ISIG,
# which would turn a ^C byte into a real SIGINT before the loop could act on
# it (empirically verified). Returns 0 with REPLY set (possibly empty); returns
# 1 when raw mode is unavailable (the caller falls back to read -s);
# propagates Ctrl-C as exit 130.
masked_read() {
  local saved_state="$1" tty_fd="$2" line="" c="" rc=0 tmp="" q=""
  tmp="$(mktemp 2>/dev/null)" || { REPLY=""; return 1; }
  chmod 600 "${tmp}" 2>/dev/null || true
  (
    q="$(printf '%q' "${saved_state}")"
    trap 'stty -F /dev/tty '"${q}"' 2>/dev/null || true' EXIT
    stty -F /dev/tty -icanon -isig -echo min 1 time 0 2>/dev/null || exit 99
    while :; do
      # dd outputs one raw byte; command substitution strips a trailing
      # newline, so a pty/pipe '\n' arrives as an EMPTY read (break = submit)
      # while a real-terminal '\r' (Enter) is caught explicitly below.
      c="$(dd bs=1 count=1 <&"${tty_fd}" 2>/dev/null || true)"
      [ -z "${c}" ] && break
      case "${c}" in
        $'\x03') exit 130 ;;
        $'\n' | $'\r') break ;;
        $'\x7f' | $'\x08')
          if [ -n "${line}" ]; then
            line="${line%?}"
            printf '\b \b' >&2
          fi
          ;;
        *) line="${line}${c}"; printf '*' >&2 ;;
      esac
    done
    printf '\n' >&2
    printf '%s' "${line}" > "${tmp}"
  ) || rc=$?
  if [ "${rc}" -eq 0 ]; then
    line="$(cat "${tmp}" 2>/dev/null || true)"
    rm -f "${tmp}"
    REPLY="${line}"
    return 0
  fi
  rm -f "${tmp}"
  if [ "${rc}" -eq 130 ]; then
    exit 130
  fi
  REPLY=""
  return 1
}

# read_secret_key LABEL - masked key read + one re-type confirmation on a real
#   TTY. LABEL is the prompt label this helper owns (re-printed on a retry so a
#   mismatch never leaves a bare input line); an empty LABEL means the caller
#   already rendered the prompt (the flat prompt_setting path) and it is not
#   re-printed. Sets REPLY to the confirmed value. A non-empty entry must be
#   re-typed and match (mismatch -> warn + re-ask, looping until it matches);
#   an EMPTY entry (Enter = keep/add-later documented default) skips
#   confirmation. Returns 0 on success; returns 1 when raw-mode masking is
#   unavailable (the caller falls back to the plain read -s path); a Ctrl-C
#   aborts as exit 130.
read_secret_key() {
  local label="$1" saved="" first="" second="" done=0
  if ! saved="$(stty -F /dev/tty -g 2>/dev/null)"; then
    # raw masking unavailable (no stty / /dev/tty): still render the prompt
    # label so the read -s fallback is not a silent bare read
    if [ -n "${label}" ]; then
      msg_key "${label}" >&2
    fi
    return 1
  fi
  while [ "${done}" -eq 0 ]; do
    if [ -n "${label}" ]; then
      msg_key "${label}" >&2
    fi
    if ! masked_read "${saved}" "${TTY_FD}"; then
      return 1
    fi
    first="${REPLY}"
    if [ -z "${first}" ]; then
      REPLY=""
      return 0
    fi
    msg_key "Confirm API key (re-type to verify) " >&2
    if ! masked_read "${saved}" "${TTY_FD}"; then
      return 1
    fi
    second="${REPLY}"
    if [ -n "${second}" ] && [ "${second}" = "${first}" ]; then
      REPLY="${first}"
      return 0
    fi
    msg_warn "API key entries did not match; please re-enter" >&2
  done
  return 0
}

# read_answer VARNAME PROMPT SECRET(0|1) NAME
#   reads one answer into REPLY (may be empty). Returns 0 on an answer (even
#   empty), 1 when no input source could provide one.
read_answer() {
  local varname="$1" prompt="$2" secret="$3" name="$4" line=""
  REPLY=""
  if [ "${HAVE_ANSWERS}" -eq 1 ]; then
    if IFS= read -r -u "${ANSWERS_FD}" line; then
      REPLY="${line}"
      return 0
    fi
  fi
  if [ "${HAVE_TTY}" -eq 1 ]; then
    if [ "${secret}" -eq 0 ] && [ -n "${prompt}" ]; then
      msg_input "${prompt}" >&2
    fi
    if [ "${secret}" -eq 1 ]; then
      # masked per-character feedback on a real tty (raw-mode loop above) with
      # re-type confirmation; falls back to today's exact `read -s` no-echo
      # read when raw mode is unavailable (no stty / /dev/tty) - no stars, no
      # confirmation then
      if ! read_secret_key "${prompt}"; then
        IFS= read -rs -u "${TTY_FD}" line || true
        printf '\n' >&2
        REPLY="${line}"
      fi
    else
      IFS= read -r -u "${TTY_FD}" line || true
      REPLY="${line}"
    fi
    return 0
  fi
  if [ "${NONINTERACTIVE}" -eq 1 ]; then
    MISSING_VARS+=("${name}")
    return 1
  fi
  die "run in a terminal, or set HONEY_STARTER_NONINTERACTIVE=1 and the required env vars (see --help)"
}

# prompt_setting VARNAME LABEL DEFAULT SECRET VALID_FN
#   Asks the question when a prompt source exists and the run is interactive;
#   otherwise treats DEFAULT as the answer. Empty input accepts DEFAULT.
#   REPLY holds the value; returns 0 on a usable value, 1 when the value fails
#   validation and no interactive source is left to re-ask (missing).
prompt_setting() {
  local varname="$1" label="$2" default="$3" secret="$4" valid="$5" ans tries=0
  if [ "${NONINTERACTIVE}" -eq 0 ] && { [ "${HAVE_TTY}" -eq 1 ] || [ "${HAVE_ANSWERS}" -eq 1 ]; }; then
    while :; do
      if [ "${secret}" -eq 1 ]; then
        msg_key "${label} " >&2
      elif [ -n "${default}" ]; then
        case "${label}" in
          *])
            msg_input "${label} " >&2
            ;;
          *)
            msg_input "${label} [${default}] " >&2
            ;;
        esac
      else
        msg_input "${label} " >&2
      fi
      if ! read_answer "${varname}" "" "${secret}" "${varname}"; then
        MISSING_VARS+=("${varname}")
        return 1
      fi
      ans="${REPLY}"
      if [ -z "${ans}" ]; then
        ans="${default}"
      fi
      if "${valid}" "${ans}"; then
        REPLY="${ans}"
        return 0
      fi
      warn "invalid ${varname}: '${ans}'"
      INVALID_SEEN=1
      INVALID_VALUE="${ans}"
      tries=$((tries + 1))
      if [ "${tries}" -ge 3 ]; then
        REPLY="${default}"
        break
      fi
    done
  else
    REPLY="${default}"
  fi
  if [ -n "${REPLY}" ] && "${valid}" "${REPLY}"; then
    return 0
  fi
  if [ -z "${REPLY}" ]; then
    return 1
  fi
  return 1
}

# --- Phase B select-from-list menus (interactive only) ------------------------
# Custom number-driven menus — deliberately NOT bash's `select` builtin (it
# reads from stdin, the wrong stream for this installer's /dev/tty +
# answers-file plumbing, and its rendering cannot be routed through the Phase A
# msg_* helpers). Menus are rendered ONLY on a real TTY with no answers file;
# answers-file / HONEY_STARTER_NONINTERACTIVE runs never reach them and keep
# consuming raw values through the pre-Phase-B flat prompts.
#
# prompt_menu VARNAME LABEL DEFAULT RESOLVE_FN ITEM...
#   Renders LABEL + the numbered ITEM list through the msg_* helpers, then
#   reads a selection from the TTY (via read_answer) and maps it:
#     * empty input              -> REPLY=DEFAULT   (Enter accepts the default)
#     * an integer in 1..N       -> REPLY=<ITEM[i]> (in-range number)
#     * input equal to an ITEM   -> REPLY=<ITEM>    (exact-value match)
#     * anything else            -> RESOLVE_FN "$input"; when it returns 0 the
#                                    resolver accepted (it set REPLY); otherwise
#                                    a generic warning is printed and the menu
#                                    re-renders (retry). RESOLVE_FN may also
#                                    die for domain rules. '-' = always reject.
#   Returns 0 with REPLY set, or 1 when no input could be read.
prompt_menu() {
  local varname="$1" label="$2" default="$3" resolve_fn="$4" n raw ans i item
  shift 4
  n=$#
  while :; do
    msg_input "${label}:" >&2
    printf '\n' >&2
    i=0
    for item in "$@"; do
      i=$((i + 1))
      if [ "${item}" = "${MENU_TYPE_OWN}" ]; then
        msg_input "  ${i}) ${MENU_TYPE_OWN_LABEL}" >&2
      else
        msg_input "  ${i}) ${item}" >&2
      fi
      printf '\n' >&2
    done
    msg_input "select a number, an exact value, or Enter for the default [${default}] " >&2
    if ! read_answer "${varname}" "" 0 "${varname}"; then
      MISSING_VARS+=("${varname}")
      return 1
    fi
    raw="${REPLY}"
    if [ -z "${raw}" ]; then
      REPLY="${default}"
      return 0
    fi
    case "${raw}" in
      ''|*[!0-9]*) ;; # not an integer -> fall through to exact-match/resolver
      *)
        if [ "${raw}" -ge 1 ] 2>/dev/null && [ "${raw}" -le "${n}" ] 2>/dev/null; then
          i=0
          for item in "$@"; do
            i=$((i + 1))
            if [ "${i}" -eq "${raw}" ]; then
              REPLY="${item}"
              return 0
            fi
          done
        fi
        # an INTEGER that is out of menu range (e.g. 99) is warned + retried,
        # NEVER adopted as a value (valid_model would otherwise accept it)
        warn "invalid selection '${raw}': enter a number 1-${n}, an exact value, or press Enter for the default"
        continue
        ;;
    esac
    for item in "$@"; do
      if [ "${item}" = "${raw}" ]; then
        REPLY="${item}"
        return 0
      fi
    done
    if [ "${resolve_fn}" != "-" ] && "${resolve_fn}" "${raw}"; then
      return 0
    fi
    warn "invalid selection '${raw}': enter a number 1-${n}, an exact value, or press Enter for the default"
  done
}

# resolve_model_menu_unlisted RAW: the model menu's RESOLVE_FN. The approved
# mapping: a free-text model typed at the interactive menu is ONLY accepted via
# the explicit "type your own" option — a raw model string at the menu (exact
# listed-value matches are already handled inside prompt_menu) is unparseable
# input and keeps the existing invalid-HD_AI_MODEL die, byte for byte. The
# literal "type your own" label is also accepted as a synonym for the option.
resolve_model_menu_unlisted() {
  if [ "$1" = "${MENU_TYPE_OWN_LABEL}" ]; then
    REPLY="${MENU_TYPE_OWN}"
    return 0
  fi
  die "invalid HD_AI_MODEL: '$1' (no whitespace/control; charset [A-Za-z0-9._:/@+-]). Fix the model and re-run."
}

# prompt_type_own_model VARNAME DEFAULT: the sub-prompt behind the model menu's
# "type your own" option — reads a free-form model string from the TTY and
# validates it with valid_model (warning + re-asking until valid). Empty input
# (Enter / EOF) abandons the custom string and keeps DEFAULT. REPLY holds the
# value on success; returns 0, or 1 when no value could be obtained.
prompt_type_own_model() {
  local varname="$1" default="$2" raw=""
  while :; do
    msg_input "type your own model (HD_AI_MODEL) " >&2
    if ! read_answer "${varname}" "" 0 "${varname}"; then
      REPLY="${default}"
      return 1
    fi
    raw="${REPLY}"
    if [ -z "${raw}" ]; then
      REPLY="${default}"
      return 0
    fi
    if valid_model "${raw}"; then
      REPLY="${raw}"
      return 0
    fi
    warn "invalid HD_AI_MODEL: '${raw}' (no whitespace/control; charset [A-Za-z0-9._:/@+-])"
  done
}

# --- validators (start.sh charset rules duplicated; NOT refactored) -----------
valid_ns() {
  case "$1" in
    ''|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}
valid_user() {
  case "$1" in
    ''|*/*|*[!A-Za-z0-9@._-]*) return 1 ;;
    *) return 0 ;;
  esac
}
valid_port() {
  local v="$1"
  case "${v}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${v}" -ge 1 ] 2>/dev/null && [ "${v}" -le 65535 ] 2>/dev/null
}
valid_provider() {
  case "$1" in
    openai|custom|skip) return 0 ;;
    *) return 1 ;;
  esac
}
valid_base_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}
valid_model() {
  # non-empty; no whitespace/control; charset [A-Za-z0-9._:/@+-] (underscore
  # for underscored/slashed endpoint model names, : for fine-tuning ids).
  case "$1" in
    ''|*[!A-Za-z0-9._:/@+-]*) return 1 ;;
    *) return 0 ;;
  esac
}
valid_project_name() {
  # Docker compose project name charset: [a-z0-9][a-z0-9_-]*[a-z0-9] (lowercase
  # alnum start/end, inner [a-z0-9_-]; the docker docs' max is 63). Generated
  # names are additionally bounded at PROJECT_NAME_MAX (32); user-supplied
  # names up to 63 are accepted.
  case "$1" in
    ''|*[!a-z0-9_-]*|[-_]*|*[-_]) return 1 ;;
    *) return 0 ;;
  esac
}
valid_yesno() {
  case "$1" in
    y|Y|yes|YES|n|N|no|NO) return 0 ;;
    *) return 1 ;;
  esac
}
# --- effective configuration --------------------------------------------------
# env vars for the AI secrets are captured early and unset from this shell so
# no child / process listing inherits them; start.sh re-reads them from the
# 600-mode .env it sources itself.
EXPLICIT_OPENAI_KEY=""
EXPLICIT_OPENROUTER_KEY=""
capture_secrets_env() {
  EXPLICIT_OPENAI_KEY=""
  EXPLICIT_OPENROUTER_KEY=""
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    EXPLICIT_OPENAI_KEY="${OPENAI_API_KEY}"
  fi
  if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    EXPLICIT_OPENROUTER_KEY="${OPENROUTER_API_KEY}"
  fi
  unset OPENAI_API_KEY OPENROUTER_API_KEY 2>/dev/null || true
}

EFFECTIVE_NS=""
EFFECTIVE_USER=""
EFFECTIVE_PROVIDER=""
EFFECTIVE_BASE_URL=""
EFFECTIVE_MODEL=""
EFFECTIVE_API_PORT=""
EFFECTIVE_UI_PORT=""
EFFECTIVE_UI_URL=""
EFFECTIVE_CONFIG_INTERVAL=""
# Phase 6 per-instance COMPOSE_PROJECT_NAME state. IS_FRESH is computed ONCE in
# on_disk_main right after read_provision (Req 2: fresh = never-provisioned, i.e.
# ! state_dir_has_artifacts). RENAMING (writer) is 1 for a confirmed rename or a
# silent adopt (ADOPT=1); DECLINED marks a declined env-vs-persisted change
# (a NO-CHANGE: the writer keeps the persisted line, so the guard must NOT
# re-probe the kept name); GUARD_RENAMING is what the F3 guard receives — 1
# ONLY for a real project change (adopt / confirm-y), so the artifacts
# early-return is suppressed and the EFFECTIVE name is truly probed (see guard).
# A declined change keeps GUARD_RENAMING=0: the artifacts shield the kept name
# (the instance rightfully owns its project) and a manage re-run with an
# exported differing env never false-fires on its own running stack.
EFFECTIVE_PROJECT=""
IS_FRESH=0
RENAMING=0
ADOPT=0
DECLINED=0
GUARD_RENAMING=0
# Set by prompt_setting when it sees an INVALID answer (any input source) so a
# caller can distinguish "the documented default applied" from "invalid input
# was seen then retried/defaulted". Consulted by the COMPOSE_PROJECT_NAME and
# HD_AI_MODEL blocks, each of which resets both before its own question: the
# documented contract is INVALID INPUT DIES (env, answers file, or typed) — it
# must never silently adopt a retry line or re-derive.
INVALID_SEEN=0
INVALID_VALUE=""

# infer_provider_default: provider determinable without prompting (env value,
# or inferred from supplied base/key; documented default openai).
infer_provider_default() {
  local p b k
  p="${HONEY_AI_PROVIDER:-}"
  if [ -n "${p}" ]; then
    printf '%s' "${p}"
    return 0
  fi
  b="$(first_nonempty "${HD_AI_BASE_URL:-}" "$(cur_value HD_AI_BASE_URL)")"
  k="$(first_nonempty "${EXPLICIT_OPENAI_KEY}" "$(cur_value OPENAI_API_KEY)")"
  if [ -n "${b}" ]; then
    printf 'custom'
  elif [ -n "${k}" ]; then
    printf 'openai'
  else
    printf 'openai'
  fi
}

# --- per-instance COMPOSE_PROJECT_NAME derivation (Phase 6) -----------------
# sanitize_project_basename BASENAME -> prints the sanitized, truncated
# component (or "dir" when nothing survives). Lowercase; every char outside
# [a-z0-9] becomes "-"; runs collapse; leading/trailing "-" stripped; empty ->
# "dir"; truncated to PROJECT_BASENAME_MAX with a trailing "-" re-stripped.
# Pure function (no state), used by derived_project_name and (via the shared
# helper contract) by test/setup-dryrun.sh.
sanitize_project_basename() {
  local b="$1" out="" t
  b="${b,,}"
  b="$(printf '%s' "${b}" | tr -c 'a-z0-9' '-')"
  while :; do
    t="${b//--/-}"
    [ "${t}" = "${b}" ] && break
    b="${t}"
  done
  b="${b#-}"; b="${b%-}"
  if [ -z "${b}" ]; then
    b="dir"
  fi
  b="${b:0:${PROJECT_BASENAME_MAX}}"
  b="${b%-}"
  printf '%s' "${b}"
}

# derived_project_name INSTALL_DIR -> prints the deterministic fresh default
# hs-<sanitized-basename>-<hash8>. The hash is the first PROJECT_HASH_LEN hex
# chars of sha256(INSTALL_DIR) — the RESOLVED (post-dispatch) absolute target
# path, NEVER SCRIPT_TREE, so two instances materialized from the same invoked
# tree hash differently. Length 3+20+1+8 = 32 (PROJECT_NAME_MAX). Defensive
# die if sha256sum is missing (preflight already requires it).
# KEEP IN SYNC with test/setup-dryrun.sh derived_proj() (same inputs ->
# same output); any derivation change must update BOTH.
derived_project_name() {
  local dir="$1" base b h name
  if ! command -v sha256sum >/dev/null 2>&1; then
    die "sha256sum is required to derive the per-instance COMPOSE_PROJECT_NAME (install coreutils/busybox and re-run)"
  fi
  base="$(basename "${dir}")"
  [ -n "${base}" ] || base="dir"
  b="$(sanitize_project_basename "${base}")"
  h="$(printf '%s' "${dir}" | sha256sum | cut -c1-${PROJECT_HASH_LEN})"
  name="${PROJECT_PREFIX}${b}-${h}"
  if [ "${#name}" -gt "${PROJECT_NAME_MAX}" ]; then
    die "internal: derived project name '${name}' exceeds ${PROJECT_NAME_MAX} chars"
  fi
  printf '%s' "${name}"
}

# preliminary_project_name -> prints the would-be project name BEFORE the
# questionnaire, without prompting. Order documented (never change silently):
#   * IS_FRESH=1 (never-provisioned): env first, then .env prefill, then the
#     derived default — setup-time env-first, matching every other
#     questionnaire key (e.g. HONEY_NS). The .env prefill of a raw (never
#     provisioned) tree is treated as a prefill only, so a setup-time env
#     wins over it.
#   * IS_FRESH=0 (provisioned): .env first, then env, then "honey-starter" —
#     runtime-effective, matching lib.sh precedence (lib.sh sources .env at
#     top, then :=honey-starter default).
preliminary_project_name() {
  if [ "${IS_FRESH}" -eq 1 ]; then
    if [ "${HONEY_STARTER_UPDATE_IN_PROGRESS:-0}" = "1" ]; then
      # --update on a fresh (never-provisioned) target: COMPOSE_PROJECT_NAME
      # env is ignored AND the .env prefill is not adopted — the derived
      # default applies (Req 6), matching what the questionnaire would answer.
      derived_project_name "${INSTALL_DIR}"
    else
      first_nonempty "${COMPOSE_PROJECT_NAME:-}" "$(cur_value COMPOSE_PROJECT_NAME)" "$(derived_project_name "${INSTALL_DIR}")"
    fi
  else
    first_nonempty "$(cur_value COMPOSE_PROJECT_NAME)" "${COMPOSE_PROJECT_NAME:-}" "honey-starter"
  fi
}

# resolve_existing_project: Req 7 — the EXISTING-instance env-change decision,
# called from warn_state_up_front AFTER read_provision (IS_FRESH=0), BEFORE any
# guard. Sets EFFECTIVE_PROJECT / RENAMING / ADOPT / GUARD_RENAMING / DECLINED.
#   * env unset                      -> EFFECTIVE_PROJECT = persisted (or
#                                      empty -> "honey-starter"); no event.
#   * env set, persisted empty       -> ADOPT silently (RENAMING=1): the
#                                      adopted name is written and probed.
#   * env set, persisted equal       -> no change (keep).
#   * env set, persisted different   -> TTY-only hard confirm (data-loss
#                                      language, Req 8); answers-file-only or
#                                      NONINTERACTIVE runs DIE. Confirm-y ->
#                                      RENAMING=1, EFFECTIVE = env; confirm-n ->
#                                      a NO-CHANGE: DECLINED=1, keep persisted,
#                                      RENAMING=0 + GUARD_RENAMING=0 (the guard
#                                      early-returns on the artifacts — it must
#                                      never force-probe the kept name).
#   * --update (HONEY_STARTER_UPDATE_IN_PROGRESS=1): env IGNORED; keep
#     persisted; never warn / confirm / adopt.
resolve_existing_project() {
  local env_p cur_p prompt default ans
  RENAMING=0; ADOPT=0; DECLINED=0; GUARD_RENAMING=0
  EFFECTIVE_PROJECT="$(first_nonempty "$(cur_value COMPOSE_PROJECT_NAME)" "honey-starter")"
  # --update: env ignored (flag exported by the DO_UPDATE re-exec before the
  # second run; scrubbed at delegation). Keep persisted/absent; never warn.
  [ "${HONEY_STARTER_UPDATE_IN_PROGRESS:-0}" = "1" ] && return 0
  env_p="${COMPOSE_PROJECT_NAME:-}"
  if [ -z "${env_p}" ]; then
    return 0
  fi
  valid_project_name "${env_p}" || die "invalid COMPOSE_PROJECT_NAME: '${env_p}' (lowercase [a-z0-9][a-z0-9_-]*[a-z0-9]; no leading/trailing -). Fix it and re-run."
  cur_p="$(cur_value COMPOSE_PROJECT_NAME)"
  if [ -z "${cur_p}" ]; then
    # env set + nothing persisted -> adopt silently (set; the guard probes the
    # adopted name with RENAMING=1, so a live collision under it still dies)
    ADOPT=1; RENAMING=1; GUARD_RENAMING=1
    EFFECTIVE_PROJECT="${env_p}"
    return 0
  fi
  if [ "${cur_p}" = "${env_p}" ]; then
    return 0
  fi
  # env differs from a persisted value: TTY-only hard confirm (answers-file
  # only / NI DIE with the same data-loss message). Cannot use
  # abort_or_continue_prompt as-is: that helper falls back to 'default'
  # silently in NI and consumes an answers line; Req 8 demands a hard die.
  if [ "${NONINTERACTIVE}" -eq 1 ] || [ "${HAVE_TTY}" -eq 0 ]; then
    die "changing the compose project re-initializes Vault: this instance will initialize a NEW ${env_p}_vault-file volume and OVERWRITE root_token/unseal_key in ${STATE_DIR}; the current secrets under ${cur_p}_vault-file are no longer addressed (data loss). To change it, first stop this instance (docker compose -p ${cur_p} down -v) or keep ${cur_p}. (COMPOSE_PROJECT_NAME=${env_p} was exported; run interactively to confirm the change.)"
  fi
  # TTY-only confirm (Req 8): read the /dev/tty DIRECTLY — never consume an
  # answers-file line (an answers-file-only run already died above), never
  # re-read through prompt_setting.
  prompt="Changing the compose project re-initializes Vault: this instance will initialize a NEW ${env_p}_vault-file volume and OVERWRITE root_token/unseal_key in ${STATE_DIR}; the current secrets under ${cur_p}_vault-file are no longer addressed (data loss). To change it, first stop this instance (docker compose -p ${cur_p} down -v) or keep ${cur_p}. Continue with the change? [y/N] "
  msg_input "${prompt}" >&2
  if ! IFS= read -r -u "${TTY_FD}" ans; then
    ans="n"
  fi
  case "${ans}" in
    y|Y|yes|YES)
      RENAMING=1; GUARD_RENAMING=1
      EFFECTIVE_PROJECT="${env_p}"
      ;;
    *)
      # declined: a NO-CHANGE — the writer keeps the persisted line
      # (RENAMING stays 0) and the guard must NOT re-probe the kept name
      # (GUARD_RENAMING=0): the artifacts early-return shields it (this
      # instance rightfully owns its project), so a manage re-run with an
      # exported differing env + decline never false-fires on its own stack.
      DECLINED=1; RENAMING=0; GUARD_RENAMING=0
      EFFECTIVE_PROJECT="${cur_p}"
      ;;
  esac
}

run_questionnaire() {
  local p base_default key_default msg model_default project_default

  # --- COMPOSE_PROJECT_NAME (FIRST item; FRESH-only) --------------------------
  # A never-provisioned instance gets the per-instance name persisted in .env:
  # env (validated) -> answers/tty -> derived default. The .env prefill of a
  # raw (never-provisioned) tree is the PROMPT DEFAULT only — a setup-time
  # env still wins (preliminary_project_name env-first). A manage-in-place run
  # (IS_FRESH=0) NEVER asks and NEVER re-derives: the leading answers slot is
  # consumed and DISCARDED (a direct read, never via read_answer — no
  # tty-fallthrough, and an exhausted file must not push to MISSING_VARS;
  # Req 12). Resolved by resolve_existing_project in warn_state_up_front; here
  # we only keep a fresh-run effective value in sync.
  if [ "${IS_FRESH}" -eq 1 ]; then
    if [ "${HONEY_STARTER_UPDATE_IN_PROGRESS:-0}" != "1" ] && [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
      valid_project_name "${COMPOSE_PROJECT_NAME}" \
        || die "invalid COMPOSE_PROJECT_NAME: '${COMPOSE_PROJECT_NAME}' (lowercase [a-z0-9][a-z0-9_-]*[a-z0-9]; no leading/trailing -). Fix it and re-run."
      EFFECTIVE_PROJECT="${COMPOSE_PROJECT_NAME}"
      # env wins over the answers/tty slot: the leading answers-file line is
      # consumed and DISCARDED so the rest of the questionnaire stays aligned.
      if [ "${HAVE_ANSWERS}" -eq 1 ]; then
        IFS= read -r -u "${ANSWERS_FD}" _ || true
      fi
    else
      if [ "${HONEY_STARTER_UPDATE_IN_PROGRESS:-0}" = "1" ]; then
        # --update on a fresh target: env ignored -> the derived default applies
        project_default="$(derived_project_name "${INSTALL_DIR}")"
      else
        project_default="$(first_nonempty "$(cur_value COMPOSE_PROJECT_NAME)" "$(derived_project_name "${INSTALL_DIR}")")"
      fi
      # the project question is scoped to never-provisioned instances, asked
      # FIRST, default shown in [brackets]. Empty answers/Enter = the derived
      # default (never an error).
      if [ "${NONINTERACTIVE}" -eq 0 ] && { [ "${HAVE_TTY}" -eq 1 ] || [ "${HAVE_ANSWERS}" -eq 1 ]; }; then
        INVALID_SEEN=0
        INVALID_VALUE=""
        if prompt_setting COMPOSE_PROJECT_NAME \
          "Compose project name (COMPOSE_PROJECT_NAME)" \
          "${project_default}" 0 valid_project_name; then
          EFFECTIVE_PROJECT="${REPLY}"
        else
          EFFECTIVE_PROJECT="${project_default}"
        fi
        if [ "${INVALID_SEEN}" -eq 1 ]; then
          die "invalid COMPOSE_PROJECT_NAME: '${INVALID_VALUE}' (lowercase [a-z0-9][a-z0-9_-]*[a-z0-9]; no leading/trailing -). Fix it and re-run."
        fi
      else
        # NI / auto-NI: the documented default applies (derived). An
        # env-supplied value was handled above; an explicit empty env is not
        # accepted for user intent here — the derived default applies.
        EFFECTIVE_PROJECT="${project_default}"
      fi
      valid_project_name "${EFFECTIVE_PROJECT}" \
        || die "invalid COMPOSE_PROJECT_NAME: '${EFFECTIVE_PROJECT}' (lowercase [a-z0-9][a-z0-9_-]*[a-z0-9]; no leading/trailing -)."
    fi
  else
    # manage / existing: the name was resolved pre-questionnaire; consume and
    # discard the leading answers slot (Req 12) — never prompt, never re-derive.
    if [ "${HAVE_ANSWERS}" -eq 1 ]; then
      IFS= read -r -u "${ANSWERS_FD}" _ || true
    fi
  fi

  # --- HONEY_NS (prompt when env unset; default = current .env or starter) ---
  if [ -z "${HONEY_NS:-}" ]; then
    if prompt_setting HONEY_NS "Vault KV namespace (HONEY_NS)" \
      "$(first_nonempty "$(cur_value HONEY_NS)" starter)" 0 valid_ns; then
      EFFECTIVE_NS="${REPLY}"
    else
      MISSING_VARS+=(HONEY_NS)
    fi
  else
    EFFECTIVE_NS="${HONEY_NS}"
  fi

  # --- HONEY_USER (prompt when env unset; default = current .env or admin) ---
  if [ -z "${HONEY_USER:-}" ]; then
    if prompt_setting HONEY_USER "Admin subject (HONEY_USER)" \
      "$(first_nonempty "$(cur_value HONEY_USER)" admin)" 0 valid_user; then
      EFFECTIVE_USER="${REPLY}"
    else
      MISSING_VARS+=(HONEY_USER)
    fi
  else
    EFFECTIVE_USER="${HONEY_USER}"
  fi

  # --- AI provider (openai|custom|skip) ---
  if [ -z "${HONEY_AI_PROVIDER:-}" ]; then
    p="$(infer_provider_default)"
    # only ask when we actually have a prompt source; else the inferred default
    # applies (NI / auto-NI never prompt)
    if [ "${NONINTERACTIVE}" -eq 0 ] && [ "${HAVE_TTY}" -eq 1 ] && [ "${HAVE_ANSWERS}" -eq 0 ]; then
      # TTY-only select-from-list menu (Phase B): a real terminal with NO
      # answers file. Select by number (1-3), by typing the exact value
      # (openai|custom|skip), or Enter for the inferred default. Answers-file /
      # NI runs never reach this path — they keep the flat raw-value prompt.
      if prompt_menu HONEY_AI_PROVIDER \
        "AI provider (openai | custom (OpenAI-compatible endpoint) | skip)" \
        "${p}" - "${AI_PROVIDER_MENU[@]}"; then
        EFFECTIVE_PROVIDER="${REPLY}"
      else
        MISSING_VARS+=(HONEY_AI_PROVIDER)
      fi
    elif [ "${NONINTERACTIVE}" -eq 0 ] && { [ "${HAVE_TTY}" -eq 1 ] || [ "${HAVE_ANSWERS}" -eq 1 ]; }; then
      # answers-file / flat interactive path (unchanged pre-Phase-B behavior):
      # the raw provider value is consumed exactly as today through the plain
      # prompt — the select-from-list menu is TTY-only and never rendered here.
      if prompt_setting HONEY_AI_PROVIDER \
        "AI provider (openai | custom (OpenAI-compatible endpoint) | skip)" \
        "${p}" 0 valid_provider; then
        EFFECTIVE_PROVIDER="${REPLY}"
      else
        MISSING_VARS+=(HONEY_AI_PROVIDER)
      fi
    else
      EFFECTIVE_PROVIDER="${p}"
    fi
  else
    EFFECTIVE_PROVIDER="${HONEY_AI_PROVIDER}"
  fi
  case "${EFFECTIVE_PROVIDER}" in
    openai|custom|skip) ;;
    *) die "HONEY_AI_PROVIDER must be one of openai|custom|skip (got: ${EFFECTIVE_PROVIDER})" ;;
  esac

  # --- AI model (openai/custom; pin default; NOT asked for skip) -------------
  # Three-way env semantics (exact):
  #   * HD_AI_MODEL non-empty        -> override written, wins (passthrough)
  #   * HD_AI_MODEL explicitly empty -> definitive no-pin run: existing
  #                                     override NOT kept, line removed, the
  #                                     question is SKIPPED entirely
  #   * HD_AI_MODEL unset + openai/custom -> question asked; Enter / an empty
  #                                     answers-file line = accept the default,
  #                                     WRITING the pin (gpt-5.4-mini); NI unset
  #                                     uses the same default
  #   * provider skip                -> no question; line kept/removed/replaced
  #                                     per the env state above
  if [ -n "${HD_AI_MODEL:-}" ]; then
    # non-empty env override wins over everything (all providers)
    EFFECTIVE_MODEL="${HD_AI_MODEL}"
  elif [ -n "${HD_AI_MODEL+x}" ]; then
    # explicitly empty: definitive no-pin — bypass cur_value (the existing
    # override is NOT kept), force the writer to remove the line, and skip the
    # question (its answer cannot silently re-pin)
    EFFECTIVE_MODEL=""
  else
    if [ "${EFFECTIVE_PROVIDER}" = "openai" ] || [ "${EFFECTIVE_PROVIDER}" = "custom" ]; then
      model_default="$(first_nonempty "$(cur_value HD_AI_MODEL)" "${MODEL_DEFAULT}")"
      if [ "${NONINTERACTIVE}" -eq 0 ] && { [ "${HAVE_TTY}" -eq 1 ] || [ "${HAVE_ANSWERS}" -eq 1 ]; }; then
        # Reset the invalid-input flags before THIS question: INVALID_SEEN /
        # INVALID_VALUE are GLOBAL (set by prompt_setting's retry loop on an
        # invalid answer to ANY earlier prompt, e.g. HONEY_NS / HONEY_USER) and
        # must never leak across prompts. Without the reset, a stale flag from
        # an earlier invalid answer would make a perfectly VALID model die with
        # a misleading '(invalid HD_AI_MODEL: ...)' value from a different
        # prompt. The documented contract is: an INVALID model dies (any input
        # source); a VALID model never dies.
        INVALID_SEEN=0
        INVALID_VALUE=""
        if [ "${HAVE_TTY}" -eq 1 ] && [ "${HAVE_ANSWERS}" -eq 0 ]; then
          # TTY-only curated select-from-list menu (Phase B): an in-range
          # integer = menu index; an exact listed-value match = that value; an
          # integer OUT of menu range (e.g. 99) is warned + retried and NEVER
          # written as a model (valid_model would otherwise accept '99' — the
          # exact trap the plan avoids); Enter accepts the pin default. A
          # free-string model is ONLY accepted via the explicit "type your own"
          # option; any other free text keeps the standard invalid-HD_AI_MODEL
          # die (byte-identical message).
          if prompt_menu HD_AI_MODEL "AI model (HD_AI_MODEL)" \
            "${model_default}" resolve_model_menu_unlisted \
            "${AI_MODEL_MENU[@]}" "${MENU_TYPE_OWN}"; then
            if [ "${REPLY}" = "${MENU_TYPE_OWN}" ]; then
              if prompt_type_own_model HD_AI_MODEL "${model_default}"; then
                EFFECTIVE_MODEL="${REPLY}"
              else
                EFFECTIVE_MODEL="${model_default}"
              fi
            else
              EFFECTIVE_MODEL="${REPLY}"
            fi
          else
            # HD_AI_MODEL has a documented default (the pin) and is
            # intentionally NOT part of all_answers_supplied / MISSING_VARS: a
            # prompt failure falls back to the default rather than a
            # missing-required-value error.
            EFFECTIVE_MODEL="${model_default}"
          fi
        else
          # answers-file / flat interactive path (unchanged pre-Phase-B
          # behavior): the raw model value is consumed exactly as today — an
          # invalid value still dies below via INVALID_SEEN.
          if prompt_setting HD_AI_MODEL "AI model (HD_AI_MODEL)" \
            "${model_default}" 0 valid_model; then
            EFFECTIVE_MODEL="${REPLY}"
          else
            # HD_AI_MODEL has a documented default (the pin) and is
            # intentionally NOT part of all_answers_supplied / MISSING_VARS: a
            # prompt failure falls back to the default rather than a
            # missing-required-value error.
            EFFECTIVE_MODEL="${model_default}"
          fi
        fi
        # Documented contract: an INVALID MODEL DIES regardless of the input
        # source -- env (validated earlier), answers file, or typed. Without
        # this, a typo'd model in an answers file / at the prompt would either
        # be adopted by the retry loop (a later line that happens to validate,
        # e.g. a port) or fall back to the pin -- silently. prompt_setting
        # surfaces "invalid input was seen" via INVALID_SEEN.
        if [ "${INVALID_SEEN}" -eq 1 ]; then
          die "invalid HD_AI_MODEL: '${INVALID_VALUE}' (no whitespace/control; charset [A-Za-z0-9._:/@+-]). Fix the model and re-run."
        fi
      else
        # NI / auto-NI: the documented default applies (pin)
        EFFECTIVE_MODEL="${model_default}"
      fi
    else
      # skip provider: keep an existing .env override (managed; only removed
      # when env is explicitly empty — handled above)
      EFFECTIVE_MODEL="$(cur_value HD_AI_MODEL)"
    fi
  fi
  if [ -n "${EFFECTIVE_MODEL}" ]; then
    valid_model "${EFFECTIVE_MODEL}" \
      || die "HD_AI_MODEL must be non-empty with no whitespace/control and only [A-Za-z0-9._:/@+-] (got: ${EFFECTIVE_MODEL})"
  fi

  # --- custom base URL (required, http(s)://, never silently defaulted) ------
  base_default="$(first_nonempty "${HD_AI_BASE_URL:-}" "$(cur_value HD_AI_BASE_URL)")"
  if [ "${EFFECTIVE_PROVIDER}" = "custom" ]; then
    if [ -z "${HD_AI_BASE_URL:-}" ]; then
      if [ -n "${base_default}" ]; then
        # existing value: interactive prompt prefilled; NI keeps it
        if [ "${NONINTERACTIVE}" -eq 0 ] && { [ "${HAVE_TTY}" -eq 1 ] || [ "${HAVE_ANSWERS}" -eq 1 ]; }; then
          if prompt_setting HD_AI_BASE_URL \
            "OpenAI-compatible base URL (HD_AI_BASE_URL, http(s)://...)" \
            "${base_default}" 0 valid_base_url; then
            EFFECTIVE_BASE_URL="${REPLY}"
          else
            MISSING_VARS+=(HD_AI_BASE_URL)
          fi
        else
          EFFECTIVE_BASE_URL="${base_default}"
        fi
      else
        # no existing value: required. Interactive asks (empty is invalid and
        # re-asks); NI records a missing variable.
        if [ "${NONINTERACTIVE}" -eq 0 ] && { [ "${HAVE_TTY}" -eq 1 ] || [ "${HAVE_ANSWERS}" -eq 1 ]; }; then
          if prompt_setting HD_AI_BASE_URL \
            "OpenAI-compatible base URL (HD_AI_BASE_URL, required http(s)://...)" \
            "" 0 valid_base_url; then
            EFFECTIVE_BASE_URL="${REPLY}"
          else
            MISSING_VARS+=(HD_AI_BASE_URL)
          fi
        else
          MISSING_VARS+=(HD_AI_BASE_URL)
        fi
      fi
    else
      EFFECTIVE_BASE_URL="${HD_AI_BASE_URL}"
    fi
  else
    # openai / skip: keep an env-supplied or existing base URL (managed, and
    # validated) — it is never silently defaulted, only removed when unset.
    EFFECTIVE_BASE_URL="${base_default}"
  fi
  if [ -n "${EFFECTIVE_BASE_URL}" ]; then
    valid_base_url "${EFFECTIVE_BASE_URL}" \
      || die "HD_AI_BASE_URL must be an http(s):// URL (got: ${EFFECTIVE_BASE_URL})"
  fi

  # --- AI key (openai/custom; hidden; empty = keep/add-later) ----------------
  if [ "${EFFECTIVE_PROVIDER}" = "openai" ] || [ "${EFFECTIVE_PROVIDER}" = "custom" ]; then
    if [ -z "${EXPLICIT_OPENAI_KEY}" ]; then
      key_default="$(cur_value OPENAI_API_KEY)"
      if [ -n "${key_default}" ]; then
        msg="API key for ${EFFECTIVE_PROVIDER} (a key is currently set; Enter keeps it, paste to replace)"
      else
        msg="API key for ${EFFECTIVE_PROVIDER} (hidden; Enter to skip and add to .env later)"
      fi
      if [ "${NONINTERACTIVE}" -eq 0 ] && { [ "${HAVE_TTY}" -eq 1 ] || [ "${HAVE_ANSWERS}" -eq 1 ]; }; then
        # reads through the same helper; read -s on a real tty
        if read_answer OPENAI_API_KEY "${msg} " 1 OPENAI_API_KEY; then
          if [ -n "${REPLY}" ]; then
            EXPLICIT_OPENAI_KEY="${REPLY}"
          fi
        fi
      fi
      # NI / auto-NI: no explicit value -> keep existing / omit (placeholder
      # flow). An existing real key is never downgraded.
    fi
  fi
  # OPENROUTER_API_KEY is accepted via env only (never prompted); an existing
  # .env line is preserved when no explicit value is given.

  # --- ports (prompt when env unset; default = current .env or 9000/8090) ----
  if [ -z "${HD_API_HOST_PORT:-}" ]; then
    if [ "${NONINTERACTIVE}" -eq 0 ] && { [ "${HAVE_TTY}" -eq 1 ] || [ "${HAVE_ANSWERS}" -eq 1 ]; }; then
      if prompt_setting HD_API_HOST_PORT "Daemon API host port (HD_API_HOST_PORT)" \
        "$(first_nonempty "$(cur_value HD_API_HOST_PORT)" 9000)" 0 valid_port; then
        EFFECTIVE_API_PORT="${REPLY}"
      else
        MISSING_VARS+=(HD_API_HOST_PORT)
      fi
    else
      EFFECTIVE_API_PORT="$(first_nonempty "$(cur_value HD_API_HOST_PORT)" 9000)"
    fi
  else
    EFFECTIVE_API_PORT="${HD_API_HOST_PORT}"
  fi
  if [ -z "${HD_UI_HOST_PORT:-}" ]; then
    if [ "${NONINTERACTIVE}" -eq 0 ] && { [ "${HAVE_TTY}" -eq 1 ] || [ "${HAVE_ANSWERS}" -eq 1 ]; }; then
      if prompt_setting HD_UI_HOST_PORT "UI host port (HD_UI_HOST_PORT)" \
        "$(first_nonempty "$(cur_value HD_UI_HOST_PORT)" 8090)" 0 valid_port; then
        EFFECTIVE_UI_PORT="${REPLY}"
      else
        MISSING_VARS+=(HD_UI_HOST_PORT)
      fi
    else
      EFFECTIVE_UI_PORT="$(first_nonempty "$(cur_value HD_UI_HOST_PORT)" 8090)"
    fi
  else
    EFFECTIVE_UI_PORT="${HD_UI_HOST_PORT}"
  fi
  # HD_UI_URL is the documented public UI base URL (OAuth/SAML redirect
  # building; compose defaults ${HD_UI_URL:-http://localhost:8090}). Derive
  # the guided localhost default ONLY when nothing is set — never clobber an
  # env-supplied or existing .env value on re-run.
  EFFECTIVE_UI_URL="$(first_nonempty "${HD_UI_URL:-}" "$(cur_value HD_UI_URL)" "http://localhost:${EFFECTIVE_UI_PORT}")"
  EFFECTIVE_CONFIG_INTERVAL="$(first_nonempty "${HD_CONFIG_CHECK_INTERVAL:-}" "$(cur_value HD_CONFIG_CHECK_INTERVAL)")"

  # --- final validation of effective values -----------------------------------
  valid_port "${EFFECTIVE_API_PORT}" || die "HD_API_HOST_PORT must be an integer 1-65535 (got: ${EFFECTIVE_API_PORT})"
  valid_port "${EFFECTIVE_UI_PORT}" || die "HD_UI_HOST_PORT must be an integer 1-65535 (got: ${EFFECTIVE_UI_PORT})"
  valid_ns "${EFFECTIVE_NS}" || die "HONEY_NS must be a single Vault path segment ([A-Za-z0-9._-]+), got: ${EFFECTIVE_NS}"
  valid_user "${EFFECTIVE_USER}" || die "HONEY_USER must be a plain subject token ([A-Za-z0-9@._-]+), got: ${EFFECTIVE_USER}"
}

report_missing_if_any() {
  if [ "${#MISSING_VARS[@]}" -gt 0 ]; then
    die "missing required value(s): ${MISSING_VARS[*]}. Set them (see --help) and re-run."
  fi
}

# --- .env writer --------------------------------------------------------------
# read-modify-write per the contract: unmanaged lines byte-exact; managed keys
# rewritten in place (order preserved); new keys appended before the final
# newline; secrets replace-only-on-explicit-value; chmod 600; first creation
# header.
declare -a OUT_LINES=()
declare -A WMODE=()
declare -A WVAL=()
declare -a WORDER=()
declare -A WSEEN=()

build_env_content() {
  local key line q
  OUT_LINES=()
  WMODE=()
  WVAL=()
  WORDER=()
  WSEEN=()

  set_action() {
    local k="$1" m="$2" v="$3"
    if [ -z "${WMODE[${k}]+set}" ]; then
      WORDER+=("${k}")
    fi
    WMODE["${k}"]="${m}"
    WVAL["${k}"]="${v}"
  }

  # COMPOSE_PROJECT_NAME writer modes (Req 1):
  #   * IS_FRESH=1 (never-provisioned)          -> set EFFECTIVE_PROJECT
  #   * IS_FRESH=0 + confirmed rename (RENAMING=1, ADOPT=0) -> set confirmed value
  #   * IS_FRESH=0 + adopt (ADOPT=1)            -> set env value SILENTLY (guard
  #                                                probed it with RENAMING=1)
  #   * IS_FRESH=0 + no change                  -> keep (preserve the line
  #                                                verbatim; absent -> nothing;
  #                                                lib.sh default applies by
  #                                                omission; migration-safe)
  # Effective no-change value (for the guard) is .env-first to match lib.sh.
  if [ "${IS_FRESH}" -eq 1 ]; then
    set_action COMPOSE_PROJECT_NAME set "${EFFECTIVE_PROJECT}"
  elif [ "${ADOPT}" -eq 1 ] || [ "${RENAMING}" -eq 1 ]; then
    # confirmed rename (RENAMING=1) or silent adopt (ADOPT=1, which also sets
    # RENAMING=1): both SET the effective name; the guard probed it with
    # RENAMING=1 in either case.
    set_action COMPOSE_PROJECT_NAME set "${EFFECTIVE_PROJECT}"
  else
    set_action COMPOSE_PROJECT_NAME keep ""
  fi
  set_action HONEY_NS set "${EFFECTIVE_NS}"
  set_action HONEY_USER set "${EFFECTIVE_USER}"
  if [ -n "${EFFECTIVE_BASE_URL}" ]; then
    set_action HD_AI_BASE_URL set "${EFFECTIVE_BASE_URL}"
  else
    set_action HD_AI_BASE_URL remove ""
  fi
  if [ -n "${EFFECTIVE_MODEL}" ]; then
    set_action HD_AI_MODEL set "${EFFECTIVE_MODEL}"
  else
    set_action HD_AI_MODEL remove ""
  fi
  set_action HD_API_HOST_PORT set "${EFFECTIVE_API_PORT}"
  set_action HD_UI_HOST_PORT set "${EFFECTIVE_UI_PORT}"
  set_action HD_UI_URL set "${EFFECTIVE_UI_URL}"
  if [ -n "${EFFECTIVE_CONFIG_INTERVAL}" ]; then
    set_action HD_CONFIG_CHECK_INTERVAL set "${EFFECTIVE_CONFIG_INTERVAL}"
  else
    set_action HD_CONFIG_CHECK_INTERVAL remove ""
  fi
  # secret keys: explicit value -> replace; else keep existing (never downgrade)
  if [ -n "${EXPLICIT_OPENAI_KEY}" ]; then
    set_action OPENAI_API_KEY set "${EXPLICIT_OPENAI_KEY}"
  else
    set_action OPENAI_API_KEY keep ""
  fi
  if [ -n "${EXPLICIT_OPENROUTER_KEY}" ]; then
    set_action OPENROUTER_API_KEY set "${EXPLICIT_OPENROUTER_KEY}"
  else
    set_action OPENROUTER_API_KEY keep ""
  fi

  local first_creation=0
  [ -f "${ENV_FILE}" ] || first_creation=1
  if [ "${first_creation}" -eq 1 ]; then
    OUT_LINES+=("# Generated by scripts/setup.sh")
  fi

  for line in "${RAW_LINES[@]}"; do
    key=""
    case "${line}" in
      ''|'#'*) ;;
      *[![:space:]]*)
        if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
          key="${BASH_REMATCH[1]}"
        fi
        ;;
    esac
    if [ -n "${key}" ] && [ -n "${WMODE[${key}]+set}" ]; then
      WSEEN["${key}"]=1
      case "${WMODE[${key}]}" in
        set)
          if ! q="$(shell_quote "${WVAL[${key}]}")"; then
            die "cannot quote value for ${key} (embedded newline?)"
          fi
          OUT_LINES+=("${key}=${q}")
          ;;
        remove) ;; # managed key with no effective value: drop the old line
        keep) OUT_LINES+=("${line}") ;;
      esac
      continue
    fi
    OUT_LINES+=("${line}")
  done
  for key in "${WORDER[@]}"; do
    if [ -n "${WSEEN[${key}]+set}" ]; then
      continue
    fi
    [ "${WMODE[${key}]}" = "set" ] || continue
    if ! q="$(shell_quote "${WVAL[${key}]}")"; then
      die "cannot quote value for ${key} (embedded newline?)"
    fi
    OUT_LINES+=("${key}=${q}")
  done
}

write_env_file() {
  local f="${ENV_FILE}" tmp
  mkdir -p "$(dirname "${f}")"
  tmp="$(mktemp "$(dirname "${f}")/.env.tmp.XXXXXX")"
  {
    for line in "${OUT_LINES[@]}"; do
      printf '%s\n' "${line}"
    done
  } > "${tmp}"
  mv "${tmp}" "${f}"
  chmod 600 "${f}"
}

# masked_line LINE -> prints the line with secret-looking values masked.
masked_line() {
  local line="$1" key val
  case "${line}" in
    ''|'#'*) printf '%s\n' "${line}"; return 0 ;;
  esac
  if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    if is_sensitive_key "${key}" && [ -n "${val}" ]; then
      printf '%s=%s\n' "${key}" '********'
      return 0
    fi
  fi
  printf '%s\n' "${line}"
}

show_effective() {
  local line
  info ""
  msg_section "=== effective configuration (secrets masked) ==="
  for line in "${OUT_LINES[@]}"; do
    masked_line "${line}"
  done
  info ""
  msg_highlight "install dir:   ${INSTALL_DIR}"
  msg_highlight "state dir:     ${STATE_DIR}"
  if [ -n "${EFFECTIVE_PROJECT}" ]; then
    msg_highlight "compose project: ${EFFECTIVE_PROJECT}"
  else
    msg_highlight "compose project: (default: honey-starter)"
  fi
  info "AI provider:   ${EFFECTIVE_PROVIDER}"
  if [ -n "${EXPLICIT_OPENAI_KEY}" ] || [ -n "$(cur_value OPENAI_API_KEY)" ]; then
    info "API key:       set (never echoed)"
  else
    info "API key:       not set yet - add to .env and re-run (placeholder flow)"
  fi
}

# --- provision guards (ns/user desync + partial state) ------------------------
# Desync guard: HONEY_NS/HONEY_USER are baked into both the rendered config and
# the Vault seed paths, so changing them after the first successful run would
# desync the daemon's LOOKUP paths from the seeded secrets. start.sh refuses to
# proceed on a mismatch. setup.sh warns UP FRONT (before the questionnaire, when
# the would-be values -- env > .env > default -- already differ from
# provision.env) and offers abort, then hard-stops after the questionnaire if
# the final effective values still differ.

desync_would_occur() {
  local ns="$1" user="$2"
  if [ ! -f "${PROVISION_FILE}" ]; then
    return 1
  fi
  if [ -n "${PROVISION_NS}" ] && [ -n "${ns}" ] && [ "${PROVISION_NS}" != "${ns}" ]; then
    return 0
  fi
  if [ -n "${PROVISION_USER}" ] && [ -n "${user}" ] && [ "${PROVISION_USER}" != "${user}" ]; then
    return 0
  fi
  return 1
}

# Would-be ns/user from env > .env > documented default (no prompting).
preliminary_ns() {
  first_nonempty "${HONEY_NS:-}" "$(cur_value HONEY_NS)" starter
}
preliminary_user() {
  first_nonempty "${HONEY_USER:-}" "$(cur_value HONEY_USER)" admin
}

abort_or_continue_prompt() {
  # label carries its own [y/N]-style bracket; default decides Enter. Returns
  # 0 = continue, 1 = abort. Non-interactive runs never reach here.
  local label="$1" default="$2" ans
  if [ "${NONINTERACTIVE}" -eq 0 ] && { [ "${HAVE_TTY}" -eq 1 ] || [ "${HAVE_ANSWERS}" -eq 1 ]; }; then
    if prompt_setting _CONTINUE_OR_ABORT "${label}" "${default}" 0 valid_yesno; then
      ans="${REPLY}"
    else
      ans="${default}"
    fi
    case "${ans}" in
      y|Y|yes|YES) return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# guard_project_state_consistency PROJECT RENAMING: fail-fast protection so a
# NEW (never-provisioned) instance can never silently bind to a DIFFERENT
# deployment's running containers + initialized Vault volume, and so a
# rename/adopt can never bind to an occupied project name. The PROJECT is
# passed IN (the EFFECTIVE project name) — the guard NEVER re-reads
# ${COMPOSE_PROJECT_NAME:-honey-starter} internally. RENAMING=1 suppresses the
# artifacts early-return (an adopt / confirmed-rename must truly probe the
# effective name — artifacts justify the OLD name only). A DECLINED change is a
# NO-CHANGE and does NOT re-probe: its artifacts shield the kept name. Probe:
#   docker compose -f <INSTALL_DIR>/deploy/docker-compose.yaml -p <p>
#     ps --status running -q daemon ui valkey vault
#   docker volume inspect <p>_vault-file
# Two die variants (fresh-collision / rename-collision), both WITHOUT the old
# "env-only / never stored" wording. NEVER dies on a missing docker
# (skip-with-warn); only the collision dies.
guard_project_state_consistency() {
  local compose_p="$1" renaming="${2:-0}" running ps_out vol_name
  compose_p="${compose_p:-honey-starter}"
  if [ "${renaming}" -eq 0 ] && state_dir_has_artifacts; then
    # Already-provisioned instance and NO project event: the compose project
    # and its volumes are rightfully THIS instance's own (the unseal key /
    # admin token / identity live here). Never false-trigger on a managing /
    # idempotent re-run.
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    warn "cannot probe compose project '${compose_p}' for a running stack (docker / compose v2 not found);"
    warn "skipping the project/state consistency check. If another deployment is up under this project,"
    warn "set up/run this instance with its own COMPOSE_PROJECT_NAME + distinct ports (see --help)."
    return 0
  fi
  ps_out="$(docker compose -f "${INSTALL_DIR}/deploy/docker-compose.yaml" -p "${compose_p}" \
    ps --status running -q daemon ui valkey vault 2>/dev/null)" || true
  running="$(printf '%s' "${ps_out}" | tr -d '[:space:]')"
  vol_name="${compose_p}_vault-file"
  if [ -n "${running}" ] || docker volume inspect "${vol_name}" >/dev/null 2>&1; then
    if [ "${renaming}" -eq 1 ]; then
      die "$(printf '%s\n' \
        "cannot use project '${compose_p}' for this instance: another deployment already runs under '${compose_p}' (or the '${vol_name}' volume exists)." \
        "No project change was written; the instance keeps addressing its current Vault volume/secrets." \
        "Choose a distinct name, or stop the other deployment first (docker compose -p <other> down -v), then re-run." \
        "Nothing was started, written, or stopped by this run." \
      )"
    else
      die "$(printf '%s\n' \
        "refusing to set up a NEW instance at ${INSTALL_DIR}: another deployment is already running under compose project '${compose_p}' (or the '${vol_name}' volume exists)." \
        "Proceeding would re-attach that deployment's initialized Vault volume (it comes back SEALED) while this fresh instance has NO unseal key - start.sh would fail mid-start with 'vault is sealed but ${STATE_DIR}/unseal_key is missing/empty'." \
        "Nothing was started, written, or stopped by this run." \
        "Remedy: choose a distinct COMPOSE_PROJECT_NAME, or stop the other deployment first (docker compose -f <its-deploy>/docker-compose.yaml -p ${compose_p} down), then re-run." \
        "Run this instance with distinct ports too: export HD_API_HOST_PORT=<port>; export HD_UI_HOST_PORT=<port>." \
      )"
    fi
  fi
}
# warn_state_up_front: called BEFORE the questionnaire, with the would-be
# (env > .env > default) values, once prompt sources are open.
warn_state_up_front() {
  local ans=""
  # Phase 6 B1: existing-instance env-change decision FIRST (before any guard) —
  # sets EFFECTIVE_PROJECT / RENAMING / ADOPT / DECLINED / GUARD_RENAMING for
  # provisioned instances; fresh instances (IS_FRESH=1) skip it (their project
  # is resolved by the questionnaire / preliminary). --update never reaches
  # here (env ignored, keep persisted).
  if [ "${IS_FRESH}" -eq 0 ]; then
    resolve_existing_project
    if [ "${DECLINED}" -eq 1 ]; then
      note "keeping the persisted compose project '${EFFECTIVE_PROJECT}' (the exported COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-} was not applied)."
    fi
  fi
  if state_dir_has_artifacts && [ ! -f "${PROVISION_FILE}" ]; then
    warn "state dir ${STATE_DIR} exists (root token etc.) but provision.env is absent"
    warn "-> no completed provisioning is recorded; a HONEY_NS/HONEY_USER change is not yet guarded by start.sh"
    warn "-> if this is a failed earlier run, reset with: make down-volumes && rm -rf ${STATE_DIR}"
    if ! abort_or_continue_prompt "Continue with the existing partial state? [y/N]" "y"; then
      info "aborted by user; nothing was changed"
      exit 1
    fi
  fi
  if desync_would_occur "$(preliminary_ns)" "$(preliminary_user)"; then
    warn "HONEY_NS/HONEY_USER would change vs the first run (ns=${PROVISION_NS}, user=${PROVISION_USER})"
    warn "start.sh refuses this change: it would desync the daemon's Vault LOOKUP paths from the seeded secrets."
    warn "reset the deployment to change it: make down-volumes && rm -rf ${STATE_DIR}, then re-run."
    if ! abort_or_continue_prompt "Continue anyway despite the HONEY_NS/HONEY_USER change? (start.sh will refuse) [y/N]" "n"; then
      info "aborted by user; nothing was changed"
      exit 1
    fi
  fi
}

# guard_after_questionnaire: hard stop after the questionnaire if the final
# effective values still differ from provision.env (a non-interactive run
# cannot be asked, so this is a die with the reset path).
guard_after_questionnaire() {
  if desync_would_occur "${EFFECTIVE_NS}" "${EFFECTIVE_USER}"; then
    die "HONEY_NS/HONEY_USER would change vs the first run (ns=${PROVISION_NS}, user=${PROVISION_USER}). Reset the deployment (make down-volumes && rm -rf ${STATE_DIR}) to change them."
  fi
}

# --- delegation ---------------------------------------------------------------
# Scrub secret env at the delegation boundary: start.sh sources the 600-mode
# .env itself and must not see AI keys exported in its own environment.
# HONEY_STARTER_NO_ENV is scrubbed too: the test harness sets it so lib.sh in
# *this* process chain never sources a host .env, but the delegated start.sh
# MUST source the .env setup.sh just wrote (that is how it receives the keys).
delegate_to_start() {
  local key
  # Scrub env at the delegation boundary: start.sh sources the 600-mode .env
  # it is given, so COMPOSE_PROJECT_NAME (and the update flag) must come from
  # THERE — never inherited env — making .env-beats-env precedence explicit at
  # the boundary (Phase 6).
  local -a scrubbed=(env -u HONEY_STARTER_NO_ENV -u HONEY_STARTER_UPDATE_IN_PROGRESS -u COMPOSE_PROJECT_NAME)
  for key in "${SECRET_KEYS[@]}"; do
    scrubbed+=(-u "${key}")
  done
  cd "${INSTALL_DIR}" || die "cannot cd ${INSTALL_DIR}"
  info "--- delegating to scripts/start.sh (secrets scrubbed from the child environment)"
  "${scrubbed[@]}" bash "${INSTALL_DIR}/scripts/start.sh"
}

# --- on-disk main flow ---------------------------------------------------------
ENV_FILE=""
on_disk_main() {
  # Target resolution (branch 1 positional / branch 2 SCRIPT_TREE). Branch 3
  # (standalone, env-or-default + directory prompt) is bootstrap-only — an
  # on-disk run always has a tree (SCRIPT_TREE non-empty from detect_mode).
  local target="${POSITIONAL_TARGET:-}"
  if [ -n "${target}" ]; then
    INSTALL_DIR="${target}"      # branch 1 - dispatched below (new vs existing)
  else
    INSTALL_DIR="${SCRIPT_TREE}" # branch 2 - manage the invoked tree in place
  fi

  msg_section "=== honey-starter guided installer (on-disk copy) ==="

  # fail-fast preflight BEFORE any prompt / download / materialize
  preflight_os
  preflight_download_tools
  preflight_docker
  if [ "${DRY_RUN}" -eq 1 ]; then
    note "--dry-run: docker-gated preflight is informational only; render-only validation continues"
  fi
  open_input_sources
  preflight_optional_tools

  # (branch-3 directory prompt never applies to an on-disk run: branch 1 has a
  # positional, branch 2 already lives in the instance.)

  # branch-1 new-vs-existing dispatch at the resolved target, after the
  # fail-fast preflight: materialize/reuse decides the CHOSEN tree that every
  # prefill/guard below reads.
  if [ -n "${target}" ]; then
    dispatch_target "${target}"
  else
    INSTALL_DIR="${SCRIPT_TREE}"
  fi

  # After dispatch/materialize/reuse, pin the chosen target env so delegation
  # and any re-exec agree. On-disk runs (branches 1-2) never consult
  # HONEY_STARTER_INSTALL_DIR — it is branch-3-only by contract.
  export HONEY_STARTER_INSTALL_DIR="${INSTALL_DIR}"

  if [ "${DO_UPDATE}" -eq 1 ]; then
    msg_section "=== honey-starter: update (${INSTALL_DIR}) ==="
    # copy then re-extract: the target tree was ensured above (materialized
    # new from the invoked tree when it did not exist); now pull the release
    # over it so the fresh instance runs the latest code
    download_and_install "${INSTALL_DIR}" 1
    # Phase 6: the re-exec drops --update; HONEY_STARTER_UPDATE_IN_PROGRESS=1
    # is what the second run sees. Under it, COMPOSE_PROJECT_NAME env is
    # IGNORED for existing instances (keep persisted/absent; never warn /
    # confirm / adopt); fresh targets take the derived default. The flag is
    # scrubbed at delegation.
    export HONEY_STARTER_UPDATE_IN_PROGRESS=1
    reload_on_disk_without_update_flags "$@"
  fi

  ENV_FILE="${INSTALL_DIR}/.env"
  parse_env "${ENV_FILE}"
  resolve_state_dir
  read_provision

  # Phase 6 Req 2: IS_FRESH = never-provisioned (no state artifacts),
  # computed ONCE here (single source of truth). Covers materialize-new,
  # bootstrap first-install after re-exec, and manage-of-raw-tree (all have
  # artifact-less state dirs); genuinely provisioned instances never re-ask.
  # NOTE: HD_STATE_DIR must be exported on every run (existing contract) or a
  # provisioned instance with a custom state dir could look fresh and be
  # re-asked.
  if state_dir_has_artifacts; then
    IS_FRESH=0
  else
    IS_FRESH=1
  fi

  msg_highlight "install dir: ${INSTALL_DIR}"
  msg_highlight "state dir:   ${STATE_DIR}"

  # Req 5: validate a fresh-run env COMPOSE_PROJECT_NAME EARLY (before any
  # guard probe) so an invalid name never reaches the docker probe; existing
  # instances validate it in resolve_existing_project.
  if [ "${IS_FRESH}" -eq 1 ] && [ "${HONEY_STARTER_UPDATE_IN_PROGRESS:-0}" != "1" ] && [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
    valid_project_name "${COMPOSE_PROJECT_NAME}" \
      || die "invalid COMPOSE_PROJECT_NAME: '${COMPOSE_PROJECT_NAME}' (lowercase [a-z0-9][a-z0-9_-]*[a-z0-9]; no leading/trailing -). Fix it and re-run."
  fi

  # up-front desync / partial-state warnings + the Phase 6 B1 existing-instance
  # env-change decision (sets EFFECTIVE_PROJECT / RENAMING / ADOPT / DECLINED /
  # GUARD_RENAMING for provisioned instances; fresh instances resolve their
  # project in the questionnaire). --update never warns. The target decision
  # precedes this, so its "before ns/user answers" guarantee holds.
  warn_state_up_front

  # F3 pre-guard (Phase 6 B1): probe the name the runtime will actually use.
  #   * fresh     -> preliminary (env > .env prefill > derived), RENAMING=0
  #   * existing  -> EFFECTIVE_PROJECT (resolved ABOVE, before any guard), with
  #                  GUARD_RENAMING (=1 for adopt / confirm-y, so the artifacts
  #                  early-return is suppressed and the effective name is truly
  #                  probed; =0 for a no-change manage re-run AND for a declined
  #                  change — both keep the persisted name shielded by artifacts)
  if [ "${IS_FRESH}" -eq 1 ]; then
    guard_project_state_consistency "$(preliminary_project_name)" 0
  else
    guard_project_state_consistency "${EFFECTIVE_PROJECT}" "${GUARD_RENAMING}"
  fi

  # questionnaire (env values / chosen-tree .env prefill / documented
  # defaults; prompts only when a source exists and the env var is unset)
  run_questionnaire
  report_missing_if_any

  # hard desync guard on the final effective values
  guard_after_questionnaire

  # F3 post-guard (Phase 6 B1 re-probe): a never-provisioned instance whose
  # effective (typed/answered) project name DIFFERS from the preliminary one
  # (e.g. the user answered a different name than the derived default) must be
  # re-probed under the EFFECTIVE name BEFORE any write — a live collision
  # under it dies here, pre-write, no .env.
  if [ "${IS_FRESH}" -eq 1 ] && [ "${EFFECTIVE_PROJECT}" != "$(preliminary_project_name)" ]; then
    guard_project_state_consistency "${EFFECTIVE_PROJECT}" 0
  fi

  # build + preview the effective .env, then write it
  build_env_content
  show_effective
  if [ "${DRY_RUN}" -eq 1 ]; then
    write_env_file
    info "--- dry-run complete: .env written to ${ENV_FILE} (chmod 600); NOT starting the stack"
    info "--- re-run without --dry-run to write (again) and delegate to scripts/start.sh"
    exit 0
  fi

  if [ "${HONEY_STARTER_ASSUME_YES:-0}" != "1" ]; then
    if [ "${NONINTERACTIVE}" -eq 0 ] && { [ "${HAVE_TTY}" -eq 1 ] || [ "${HAVE_ANSWERS}" -eq 1 ]; }; then
      local ans=""
      if prompt_setting _CONFIRM "Write .env and start the stack? [Y/n]" "y" 0 valid_yesno; then
        ans="${REPLY}"
      fi
      case "${ans}" in
        y|Y|yes|YES) ;;
        *) info "aborted by user; .env was not written"; exit 0 ;;
      esac
    else
      MISSING_VARS+=(HONEY_STARTER_ASSUME_YES)
      report_missing_if_any
    fi
  fi

  write_env_file
  info "--- .env written to ${ENV_FILE} (chmod 600)"
  delegate_to_start
}
# --- bootstrap main flow -------------------------------------------------------
bootstrap_main() {
  local dir
  if [ -n "${POSITIONAL_TARGET}" ]; then
    dir="${POSITIONAL_TARGET}"        # branch 1: positional wins over env
  else
    # branch 3: HONEY_STARTER_INSTALL_DIR (branch-3-only) or ~/honey-starter.
    # The single directory prompt fires AFTER the fail-fast preflight below
    # and BEFORE the download; a default always exists, so branch 3 never
    # errors on a missing dir (HOME-unset still dies).
    dir="${HONEY_STARTER_INSTALL_DIR:-}"
    if [ -z "${dir}" ]; then
      if [ -z "${HOME:-}" ]; then
        die "cannot determine an install dir: HOME is unset. Set HONEY_STARTER_INSTALL_DIR explicitly."
      fi
      dir="${HOME}/${DEFAULT_INSTALL_SUBDIR}"
    fi
    if [ "${dir}" = "~" ] && [ -n "${HOME:-}" ]; then
      dir="${HOME:-}"
    fi
    if [ "${dir#\~/}" != "${dir}" ]; then
      dir="${HOME}/${dir#\~/}"
    fi
    case "${dir}" in
      /*) ;;
      *) dir="$(pwd)/${dir}" ;;
    esac
  fi
  INSTALL_DIR="${dir}"

  msg_section "=== honey-starter guided installer (bootstrap copy) ==="

  # fail-fast preflight BEFORE any prompt or download
  preflight_os
  preflight_download_tools
  preflight_docker
  if [ "${DRY_RUN}" -eq 1 ]; then
    note "--dry-run: docker-gated preflight is informational only; download + render-only validation continues"
  fi

  # branch-3 single directory prompt (the ONLY prompt in the bootstrap copy;
  # placement: AFTER the fail-fast preflight, BEFORE the download — a host
  # with no viable docker is never prompted). Standalone runs with a <dir>
  # (branch 1) or an env dir / answers file / NI never reach the prompt.
  if [ -z "${POSITIONAL_TARGET}" ]; then
    dir="$(ask_install_dir "${dir}")"
    INSTALL_DIR="${dir}"
  fi

  msg_highlight "install dir: ${dir}"
  export HONEY_STARTER_INSTALL_DIR="${dir}"
  INSTALL_DIR="${dir}"

  if [ "${DO_UPDATE}" -eq 0 ] && tree_is_valid "${dir}"; then
    info "--- existing honey-starter tree found at ${dir}; skipping download"
    # LOW-4 hint: the rolling one-liner keeps the on-disk copy even after main
    # advances; make staleness actionable.
    note "the on-disk copy stays as-is; refresh it from the release with: bash scripts/setup.sh --update"
  elif tree_is_presetup "${dir}"; then
    # Phase-3-era tree (no scripts/setup.sh yet): upgrade in place by merging
    # the release over it. tar never deletes stale files; .honey-starter state
    # (root token, unseal key, admin token, identity pair) is preserved.
    warn "existing tree at ${dir} predates scripts/setup.sh (Phase 4)"
    warn "extracting the release over it (tar merges; it never deletes stale files); .honey-starter/ state is preserved"
    download_and_install "${dir}" 1
  else
    download_and_install "${dir}" "${DO_UPDATE}"
  fi

  if [ ! -f "${dir}/scripts/setup.sh" ]; then
    die "installed tree at ${dir} has no scripts/setup.sh (unexpected); cannot continue"
  fi
  info "--- starting the on-disk guided installer"
  reload_on_disk_without_update_flags "$@"
}
# --- entrypoint ---------------------------------------------------------------
main() {
  # Capture (and unset from this shell) the AI secrets FIRST, so no child
  # process in any branch ever inherits them. The on-disk copy uses the
  # captured EXPLICIT_* values; re-exec'd copies get them re-exported by
  # re_export_secrets_for_exec.
  capture_secrets_env
  detect_mode
  parse_args "$@"
  if [ "${BOOTSTRAP_MODE}" -eq 1 ]; then
    bootstrap_main "$@"
  else
    on_disk_main "$@"
  fi
}

main "$@"

#!/usr/bin/env bash
# setup.sh — guided installer for honey-starter deployments. One script, two
# execution modes, and (Phase 5) THREE target-selection branches so the same
# command SETS UP a NEW instance at a given directory or RE-SETS UP (manages)
# an EXISTING instance in place. Multiple instances coexist as separate
# directories (run them simultaneously with distinct ports + an env-only
# COMPOSE_PROJECT_NAME).
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
# Managed .env keys (rewritten in place each run): HONEY_NS, HONEY_USER,
# HD_AI_BASE_URL, HD_AI_MODEL, HD_API_HOST_PORT, HD_UI_HOST_PORT, the derived
# HD_UI_URL, and HD_CONFIG_CHECK_INTERVAL -- the last written ONLY when
# explicitly supplied (env or an existing .env line), otherwise absent so the
# compose default of 30m applies by construction (never 1m).
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

# Tree entries excluded when an on-disk run materializes a NEW instance from
# the invoked tree (tar --exclude patterns). A fresh target NEVER inherits
# .git, .env or .honey-starter — it cannot clone the source deployment's
# secrets/state (intentional; the source tree itself is only ever COPIED,
# never moved, so the user can re-run setup from it against other targets).
MATERIALIZE_EXCLUDES=(--exclude='./.git' --exclude='./.env' --exclude='./.honey-starter')

# --- output helpers ----------------------------------------------------------
info() { printf '%s\n' "$*"; }
note() { printf 'NOTE: %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage_die() { printf 'ERROR: %s\n' "$*" >&2; printf 'Try --help for usage.\n' >&2; exit 2; }

print_help() {
  cat <<'HELP'
honey-starter guided installer (scripts/setup.sh)

Installs a complete Honeydipper instance (Valkey + file-backed Vault + daemon
+ web UI) on a Linux docker host with one command and a short questionnaire.
The same script SETS UP a NEW instance at a given directory or RE-SETS UP
(manages) an EXISTING instance in place; multiple instances coexist as
separate directories (run them simultaneously with distinct ports + an
env-only COMPOSE_PROJECT_NAME).

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
the current .env; Enter accepts the [default]):
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
  6. API key          hidden input (read -s). For openai/custom. Empty = keep
                      the current key (existing install) or add later
                      (placeholder flow: start.sh seeds a placeholder and you
                      add the real key to .env and re-run).
  7. ports            HD_API_HOST_PORT (default 9000) and HD_UI_HOST_PORT
                      (default 8090), integers 1-65535, confirmed together.

  HONEY_STARTER_ANSWERS_FILE (when set) supplies the answers first,
  newline-delimited, in exactly the order above. Provider-conditional lines:
  model (4) only for openai/custom; base URL (5) only for custom; API key (6)
  only for openai/custom; an empty model line means "accept the default"
  (pins gpt-5.4-mini). There is NO install-dir line - the answers file's
  physical location is indication enough; target a non-default directory with
  a positional argument (setup.sh <dir>). The final Y/n confirmation is the
  last line of a full non-dry run. Otherwise answers come from a real
  /dev/tty (opened explicitly). If neither is available and the run is not
  non-interactive, setup.sh exits with guidance - it never silently defaults
  and never hangs.

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

Preflight (fail-fast, before any prompt or download):
  Linux guard -> bash >= 4 -> curl + tar -> docker + compose v2 -> `docker
  info` reachability -> docker-group/sudo capability. jq/openssl/htpasswd
  presence and the optional install offer happen on the on-disk copy, still
  before the questionnaire. docker/compose are never auto-installed.

Environment variables (all optional):
  HONEY_STARTER_INSTALL_DIR    install dir (branch 3 only; default ~/honey-starter)
  HONEY_STARTER_REF            branch or tag to fetch (default main)
  HONEY_STARTER_EXPECT_SHA256  require this sha256 of the downloaded tarball
  HONEY_STARTER_NONINTERACTIVE set to 1 to disable all prompting
  HONEY_STARTER_ASSUME_YES     set to 1 to skip the final confirm
  HONEY_STARTER_ANSWERS_FILE   path to a newline-delimited answers file
  HONEY_STARTER_AUTO_INSTALL   set to 1 to auto-approve Debian-family tool
                               installs (jq/openssl/htpasswd)
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
  info "  [ok] Linux $(uname -r)"
  info "  [ok] bash ${BASH_VERSION%%(*}"
}

preflight_download_tools() {
  local missing=0
  for cmd in curl tar; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      warn "required command not found: ${cmd}"
      missing=1
    else
      info "  [ok] ${cmd}"
    fi
  done
  if [ "${missing}" -eq 1 ]; then
    case "$(os_distro_id)" in
      debian|ubuntu) die "install curl + tar first, e.g.: sudo apt-get update && sudo apt-get install -y curl tar" ;;
      rhel|fedora|centos|rocky|almalinux) die "install curl + tar first, e.g.: sudo dnf install -y curl tar" ;;
      arch) die "install curl + tar first, e.g.: sudo pacman -S --noconfirm curl tar" ;;
      alpine) die "install curl + tar first, e.g.: apk add --no-cache curl tar" ;;
      *) die "install curl + tar, then re-run" ;;
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
    info "  [ok] docker + compose v2"
    if docker info >/dev/null 2>&1; then
      info "  [ok] docker daemon reachable (docker info)"
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
      echo "ERROR: the docker daemon is not reachable as the current user." >&2
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
  echo "ERROR: docker with compose v2 is required and is NOT auto-installed." >&2
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
      info "  [ok] ${cmd}"
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
        printf 'setup.sh needs: %s. Install with apt now? [y/N] ' "${pkglist}" >&2
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
    printf 'Install directory [%s] ' "${display}" >&2
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
    info "  [ok] sha256 verified"
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
    [ -f "${STATE_DIR}/root_token" ] || [ -f "${STATE_DIR}/admin_token" ] || [ -d "${STATE_DIR}/identity" ]
  }
}

# --- questionnaire plumbing ---------------------------------------------------
# Prompt input sources, in order: HONEY_STARTER_ANSWERS_FILE (newline-delimited
# answers replayed through the same helper) -> real /dev/tty (opened
# explicitly; read -s for keys). If neither is available the run must be
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
    if [ -n "${prompt}" ]; then
      printf '%s' "${prompt}" >&2
    fi
    if [ "${secret}" -eq 1 ]; then
      IFS= read -rs -u "${TTY_FD}" line || true
      printf '\n' >&2
    else
      IFS= read -r -u "${TTY_FD}" line || true
    fi
    REPLY="${line}"
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
        printf '%s ' "${label}" >&2
      elif [ -n "${default}" ]; then
        case "${label}" in
          *])
            printf '%s ' "${label}" >&2
            ;;
          *)
            printf '%s [%s] ' "${label}" "${default}" >&2
            ;;
        esac
      else
        printf '%s ' "${label}" >&2
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
# Set by prompt_setting when it sees an INVALID answer (any input source) so a
# caller can distinguish "the documented default applied" from "invalid input
# was seen then retried/defaulted". Consulted ONLY by the HD_AI_MODEL block,
# which resets both before its own question: the documented contract is an
# INVALID MODEL DIES (env, answers file, or typed) — it must never silently
# adopt a retry line or re-pin.
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

run_questionnaire() {
  local p base_default key_default msg model_default

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
    if [ "${NONINTERACTIVE}" -eq 0 ] && { [ "${HAVE_TTY}" -eq 1 ] || [ "${HAVE_ANSWERS}" -eq 1 ]; }; then
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
        if prompt_setting HD_AI_MODEL "AI model (HD_AI_MODEL)" \
          "${model_default}" 0 valid_model; then
          EFFECTIVE_MODEL="${REPLY}"
        else
          # HD_AI_MODEL has a documented default (the pin) and is intentionally
          # NOT part of all_answers_supplied / MISSING_VARS: a prompt failure
          # falls back to the default rather than a missing-required-value error.
          EFFECTIVE_MODEL="${model_default}"
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
  info "=== effective configuration (secrets masked) ==="
  for line in "${OUT_LINES[@]}"; do
    masked_line "${line}"
  done
  info ""
  info "install dir:   ${INSTALL_DIR}"
  info "state dir:     ${STATE_DIR}"
  info "AI provider:   ${EFFECTIVE_PROVIDER}"
  if [ -n "${EXPLICIT_OPENAI_KEY}" ] || [ -n "$(cur_value OPENAI_API_KEY)" ]; then
    info "API key:       set (never echoed)"
  else
    info "API key:       not set yet — add to .env and re-run (placeholder flow)"
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

# warn_state_up_front: called BEFORE the questionnaire, with the would-be
# (env > .env > default) values, once prompt sources are open.
warn_state_up_front() {
  local ans=""
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
  local -a scrubbed=(env -u HONEY_STARTER_NO_ENV)
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

  info "=== honey-starter guided installer (on-disk copy) ==="

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
    info "=== honey-starter: update (${INSTALL_DIR}) ==="
    # copy then re-extract: the target tree was ensured above (materialized
    # new from the invoked tree when it did not exist); now pull the release
    # over it so the fresh instance runs the latest code
    download_and_install "${INSTALL_DIR}" 1
    reload_on_disk_without_update_flags "$@"
  fi

  ENV_FILE="${INSTALL_DIR}/.env"
  parse_env "${ENV_FILE}"
  resolve_state_dir
  read_provision

  info "install dir: ${INSTALL_DIR}"
  info "state dir:   ${STATE_DIR}"

  # up-front desync / partial-state warnings (would-be values, against the
  # CHOSEN tree — the target decision precedes this, so its "before ns/user
  # answers" guarantee holds)
  warn_state_up_front

  # questionnaire (env values / chosen-tree .env prefill / documented
  # defaults; prompts only when a source exists and the env var is unset)
  run_questionnaire
  report_missing_if_any

  # hard desync guard on the final effective values
  guard_after_questionnaire

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

  info "=== honey-starter guided installer (bootstrap copy) ==="

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

  info "install dir: ${dir}"
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

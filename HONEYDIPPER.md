# HONEYDIPPER.md — engineering guidance & gotchas

Guidance for the installer + Bash UX layer (rich output, menus, masked input,
non-interactive runs). Not a spec — the source is authoritative; `setup.sh --help`
is the exact questionnaire contract.

## Entry points
- Piped installer: `curl -fsSL https://raw.githubusercontent.com/Charles546/honey-starter/main/scripts/setup.sh | bash` → preflight → download/verify → questionnaire → `.env` → delegates to `start.sh`.
- In-tree: `make start` (`scripts/start.sh`); lifecycle `make stop | down | down-volumes | status | logs`.

## Non-interactive contract
- `HONEY_STARTER_NONINTERACTIVE=1` + decision env vars (`HONEY_NS`, `HONEY_USER`, `HONEY_AI_PROVIDER`, `HD_AI_MODEL`, `HD_AI_BASE_URL`, ports, AI keys; `COMPOSE_PROJECT_NAME` for fresh installs).
- `HONEY_STARTER_ASSUME_YES=1` skips the final write-and-start confirm; `HONEY_STARTER_ANSWERS_FILE` replays the questionnaire line-by-line (schema: `setup.sh --help`). Missing vars exit 1 with a list — never silently defaults.

## Rich-output gotchas
- Detection: fd-1 real TTY + **presence-based** `NO_COLOR`/`HONEY_STARTER_NO_COLOR` (any value — even empty — disables) + `TERM` set and ≠ `dumb`; computed once, cached.
- Plain on pipes/CI is by design — do NOT "fix" it by probing stdin/stderr (redirected runs must never leak ESC bytes or emoji).
- Prefix-only: style+glyph prepended; message text is never rewritten.
- Channels (current sites): `msg_fail`/`msg_warn` → stderr; `msg_ok`/`msg_info`/`msg_section` → stdout. `die()` = `msg_fail "ERROR: $*"` + exit 1; `usage_die()` exits 2.

## KEEP-IN-SYNC
- Rich-output block (marker → `usage_die`) is byte-for-byte duplicated: `scripts/setup.sh` is the ORIGINAL (byte-identical-frozen); `scripts/lib.sh` holds the shared copy — the KEEP-IN-SYNC comment lives only there.
- Change one → update BOTH + tests (D8 sync-guard in `test/setup-dryrun.sh`).
- **7-shim platform block** (`platform_os` → end marker) is likewise byte-for-byte between `scripts/setup.sh` (ORIGINAL) and `scripts/lib.sh` (shared; KEEP-IN-SYNC comment lives there). Change one → update BOTH + tests (D8b sync-guard).

## macOS gotchas (agents: read this first)
- **bash ≥ 4.** macOS ships **bash 3.2** by default — the scripts need bash 4+ (arrays, `${var,,}`, `set -o pipefail`). Install a newer bash (`brew install bash`) and invoke the scripts with it (`/usr/local/bin/bash scripts/setup.sh`, or `chsh -s` to a brew bash). The preflight and `start.sh` surface this FIRST, before anything can fail cryptically.
- **htpasswd is NOT on PATH after `brew install httpd`.** It lives at `$(brew --prefix httpd)/bin/htpasswd` (typically `/opt/homebrew/bin`). The shared `resolve_htpasswd` shim probes `command -v htpasswd` then the brew prefix on darwin and exports the dir onto PATH — so setup.sh's optional-tools preflight and start.sh's `require_cmd htpasswd` both resolve it without a manual PATH edit. Keep `/opt/homebrew/bin` on your PATH for the rest of the toolchain.
- **Path canonicalization differs.** `realpath_portable` canonicalizes an absolute path via `readlink -f` (Linux) or `cd && pwd -P` (macOS, which has no `readlink -f`). On macOS `/var` is a symlink to `/private/var`, so an install dir under `/var/…` resolves to `/private/var/…` — and because the derived per-instance `COMPOSE_PROJECT_NAME` (`hs-<basename>-<hash8>`) hashes the **resolved** install dir, the same logical path can hash differently across hosts that canonicalize differently. Use the same resolved form when comparing/porting names.
- **Cross-platform shims exist — use them, don't re-implement GNU-only calls.** `realpath_portable`, `sha256_digest`, and `sed_inplace` (plus `cp_recursive`, `stty_dev`, `resolve_htpasswd`/`_htpasswd_probe`) route GNU-only behavior through BSD/brew-compatible probes so Linux behavior is unchanged and macOS works. `sha256_digest` accepts `sha256sum`, `shasum -a 256`, or `openssl dgst -sha256`; `sed_inplace` probes GNU `-i` vs BSD `-i ''` rather than guessing from the OS name.
- **Runtimes.** macOS 12+ (Apple Silicon / arm64) is supported via **Docker Desktop** or **Rancher Desktop** — there is no `docker` group on macOS, so no `usermod -aG docker`. Preflight probes the desktop CLIs/sockets (`~/.rd/bin/docker`, `/usr/local/bin/docker`, `~/.docker/run/docker.sock`) before dying and links the two desktops; `start.sh` shares the same guards.

## Test / assert notes
- Rich detection is cached → probe each mode (plain / pty+dumb / pty+color) in a separate subprocess.
- Pty lines end `\r\n` → anchored asserts need `\r?$`.
- `msg_ok` = green ✅ + one space + text + reset (no bold).

## Menus (TTY-only)
- Number = index; type the exact value; Enter = default; an out-of-range integer is warned + re-asked, never adopted.
- **Model menu (hybrid adoption):** a charset-valid model string typed directly at the menu is adopted as-is (no re-prompt) — e.g. `claude-opus-4-8` or `my-custom-model-2`. The trailing *type your own* option (or its literal label) still routes to the free-string sub-prompt; its `__type_your_own__` sentinel is never adopted as a model, even if typed raw. Charset-invalid input (whitespace/control or otherwise outside `[A-Za-z0-9._:/@+-]`) dies with `invalid HD_AI_MODEL: '<value>' (no whitespace/control; charset [A-Za-z0-9._:/@+-]). Fix the model and re-run.` and no `.env` is written. The answers-file / non-interactive paths are unchanged (raw-value passthrough).
- **Model menu hint (Phase 5b):** when the model menu is shown on a real TTY, an additive `msg_note` hint ("you can also type any model directly instead of choosing a number") is emitted so the user learns they need not pick a number. The hint is rendered ONLY on the interactive TTY path — it never appears on the answers-file / non-interactive / dryrun paths, which assert exact outputs. It is strictly additive: it does not disturb the `invalid HD_AI_MODEL: '<value>' ...` grep-asserted contract string (17h/17k) or any dryrun byte-identical assertion. Keep the hint behind the TTY-only menu branch and routed through a `msg_*` helper (prefix-only rule — never rewrite message text).

## Corporate root CA (Phase 6a)
- **Host `SSL_CERT_FILE`** is a SINGLE host path to ONE bundled PEM CA file (any multiple CAs are already pre-concatenated inside that file). There is NO list parsing and NO concatenation — Phase 6b mounts the user's file directly. Detection is `[ -n "${SSL_CERT_FILE:-}" ]`.
- **Validation:** the file must be readable AND contain at least one `BEGIN CERTIFICATE`. An unreadable/invalid file → `warn` + **skip** (never enable, never die) — consistent on BOTH the interactive and the `HONEY_STARTER_USE_CA=1` opt-in path.
- **Interactive prompt (TTY-only, no answers file):** when a valid `SSL_CERT_FILE` is detected on a real terminal, a `msg_input` yes/no prompt (`Detected SSL_CERT_FILE=<path>; use it as the daemon container root CA bundle? [Y/n] `) is shown; **default = YES** (`y`/`Y`/`yes`/`YES` or Enter → enable; explicit `n` → disable). It reads `/dev/tty` DIRECTLY, so it never consumes an answers-file line and never fires in non-interactive/answers mode.
- **NI / answers default = OFF:** the prompt never fires on the NI/answers path (conservative, keeps it byte-identical). Opt-in override: `HONEY_STARTER_USE_CA=1` in the environment + a valid file → enable. With opt-in set but `SSL_CERT_FILE` empty/invalid → `warn` + skip (no enable, no die).
- **Two managed `.env` keys, written TOGETHER when enabled, ABSENT otherwise** (no remove/delete semantics — nothing was generated, so nothing to clean up):
  - `HD_CA_CERT_FILE=<host path of SSL_CERT_FILE>` — the Phase 6b compose bind-mount source.
  - `HD_CA_BUNDLE=/etc/honeydipper/ca/ca-bundle.crt` — the container path fed to the trust env vars in Phase 6b (`SSL_CERT_FILE`, `GIT_SSL_CAINFO`, `CURL_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`).
  - Not enabled → NEITHER key, ZERO new `.env` lines, ZERO new output (dryrun byte-identity: all existing suite assertions stay green regardless of whether the host has `SSL_CERT_FILE` set).
- **Spaces in the path** are stored/emitted as a single quoted string (`shell_quote`).

## Corporate root CA — container wiring (Phase 6b)
- The daemon container runs `read_only: true` with `cap_drop: [ALL]` and `no-new-privileges`, so it cannot run `update-ca-certificates` at runtime. Env-based trust backed by a read-only file bind-mount is the only viable mechanism.
- **`deploy/docker-compose.yaml` (Phase 6b freeze-exception), daemon service:**
  - **volumes** (new line): `- ${HD_CA_CERT_FILE:-/dev/null}:/etc/honeydipper/ca/ca-bundle.crt:ro`
  - **environment** (five new lines, all fed `${HD_CA_BUNDLE:-}`):
    - `SSL_CERT_FILE` (Go / daemon / web / AI / slack)
    - `GIT_SSL_CAINFO` (git)
    - `CURL_CA_BUNDLE` (curl)
    - `NODE_EXTRA_CA_CERTS` (node)
    - `REQUESTS_CA_BUNDLE` (Python requests)
  - A brief YAML comment documents the optional corporate root CA support and the `/dev/null` fallback.
- **Inert when no CA is configured:** `HD_CA_CERT_FILE`/`HD_CA_BUNDLE` are only present in `.env` when Phase 6a enabled them. Unset → the mount source falls back to `/dev/null` (always exists, harmless, read-only) and all five env vars render empty (present-but-empty is treated as unset by every consumer). `docker compose config` therefore renders valid with no bundle.
- **Keys reach compose via `start.sh` unchanged:** `scripts/lib.sh` does `set -a; . .env; set +a` at source time, and `start.sh` sources lib.sh before any `compose()` call, so `HD_CA_CERT_FILE`/`HD_CA_BUNDLE` are exported to the compose subprocess exactly like the existing `HD_*_HOST_PORT` / `HD_AI_*` keys. No `start.sh` change is needed.

## Masked input (API keys)
- Raw-mode loop on `/dev/tty`: `stty -icanon -isig -echo`; per-char `dd bs=1` (not `read -N1` — re-enables ISIG); one `*` per char to stderr; Backspace pops; `^C` → exit 130 (scoped EXIT trap restores termios).
- Value returned via a 600-mode temp file, never stdout; `read -s` no-echo fallback; every key prompt re-types for confirmation.

## Frozen files
- Byte-identical vs main — no edits without a documented exception: `scripts/setup.sh`, `bootstrap/*`, `deploy/docker-compose.yaml`, `Makefile`, `test/pty-helper.py`, `.env.example`.
- Documented `scripts/setup.sh` freeze-exceptions: Phases 1-2 (platform/runtime polish), Phase 5a (`resolve_model_menu_unlisted` hybrid adoption), Phase 5b (the additive TTY-only model-menu hint), and Phase 6a (the corporate-root-CA `SSL_CERT_FILE` detection / TTY prompt / two managed `HD_CA_CERT_FILE`+`HD_CA_BUNDLE` keys).
- Documented `deploy/docker-compose.yaml` freeze-exception: Phase 6b (the optional corporate-root-CA read-only bind-mount `- ${HD_CA_CERT_FILE:-/dev/null}:/etc/honeydipper/ca/ca-bundle.crt:ro` + the five `${HD_CA_BUNDLE:-}` trust env vars `SSL_CERT_FILE` / `GIT_SSL_CAINFO` / `CURL_CA_BUNDLE` / `NODE_EXTRA_CA_CERTS` / `REQUESTS_CA_BUNDLE`, plus the explanatory comment). No other edits to the compose file are permitted without a new documented exception.
- Documented `Makefile` freeze-exception: Phase 7 (host-side automatic config reload) adds the `reload-watch` lifecycle target (`@bash scripts/reload-watch.sh`) and lists it in `.PHONY`. No other edits to the Makefile are permitted without a new documented exception.
- Documented `.env.example` freeze-exception: Phase 7 (host-side automatic config reload) adds the commented `HD_WEBHOOK_PORT` / `HD_WEBHOOK_URL` / `HD_RELOAD_DEBOUNCE_SECONDS` / `HD_RELOAD_POLL_INTERVAL` / `HD_RELOAD_WATCHER` tunables. No other edits to `.env.example` are permitted without a new documented exception.

## Automatic config reload (host-side reload-watch)
- **`scripts/reload-watch.sh` is NON-frozen** — unlike the lifecycle scripts it
  is a standalone host-side watcher (sources lib.sh for the shared msg_*/die/warn
  helpers + shims), not a docker wrapper. It is invoked directly by the user
  (`make reload-watch`) and, on an interactive TTY, by `start.sh` at the end of
  bring-up.
- **Watcher selection** (overridable `HD_RELOAD_WATCHER=inotifywait|fswatch|poll`):
  inotifywait -> fswatch -> polling fallback. The polling fallback computes the
  newest mtime across the config dir (via the shared `stat_mtime` shim) and fires
  when that signature changes; it establishes a baseline on first check so a start
  does not spuriously reload.
- **Debounce**: events are coalesced; a reload fires at most once per
  `HD_RELOAD_DEBOUNCE_SECONDS` (default 3) after the last change. The event source
  runs in a NAMED coproc with `exec` (so the coproc PID *is* the watcher, kill()
  is direct) and the main loop reads its fd with a timeout.
- **Singleton**: `${HD_STATE_DIR}/reload-watch.pid` (chmod 600) guards against a
  second instance; a stale (dead) pid is reclaimed. An EXIT trap removes the pid
  file on normal exit / Ctrl-C / SIGTERM, so `--stop` (and Ctrl-C on the
  foreground watcher) always cleans up. `--stop` sends SIGTERM.
- **Token**: read from the `${HD_STATE_DIR}/reload_token` FILE (start.sh persists
  it, chmod 600) — never from the environment. The POST goes to
  `HD_WEBHOOK_URL` (default `http://127.0.0.1:${HD_WEBHOOK_PORT:-18080}/reload`)
  with `--max-time`; a failed POST warns and keeps watching (retries on the next
  change).
- **`start.sh` foreground + TTY gate**: on a real terminal (`[ -t 1 ]`) start.sh
  blocks in the foreground watcher so the operator can Ctrl-C it; on a
  redirected/non-tty run (CI, e2e, setup-e2e) it prints a `make reload-watch`
  hint and does NOT block — so the daemon bring-up always completes. If the
  watcher can't start, start.sh warns and continues (the daemon still reloads on
  `HD_CONFIG_CHECK_INTERVAL`).
- **`status.sh`** reports the watcher running state from the pid file
  (`reload-watch: RUNNING (pid N)` / a stale-pid failure / `not running` hint).

## status.sh gotchas
- `stack is not running …` = stdout today (`msg_info`, no `>&2`) — don't "correct" it to stderr.
- `=== honey-starter has problems ===` = stderr (`msg_section … >&2`).
- `check_cmd()` is dead code (zero callers; kept + dressed).

## Pointers
Topology, Vault & secret lifecycle, bootstrap config, validation → [`deploy/README.md`](./deploy/README.md). Usage walkthrough → [`README.md`](./README.md).

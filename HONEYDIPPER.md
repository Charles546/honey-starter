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

## Masked input (API keys)
- Raw-mode loop on `/dev/tty`: `stty -icanon -isig -echo`; per-char `dd bs=1` (not `read -N1` — re-enables ISIG); one `*` per char to stderr; Backspace pops; `^C` → exit 130 (scoped EXIT trap restores termios).
- Value returned via a 600-mode temp file, never stdout; `read -s` no-echo fallback; every key prompt re-types for confirmation.

## Frozen files
- Byte-identical vs main — no edits without a documented exception: `scripts/setup.sh`, `bootstrap/*`, `deploy/docker-compose.yaml`, `Makefile`, `test/pty-helper.py`, `.env.example`.
- Documented `scripts/setup.sh` freeze-exceptions: Phases 1-2 (platform/runtime polish), Phase 5a (`resolve_model_menu_unlisted` hybrid adoption), Phase 5b (the additive TTY-only model-menu hint), and Phase 6a (the corporate-root-CA `SSL_CERT_FILE` detection / TTY prompt / two managed `HD_CA_CERT_FILE`+`HD_CA_BUNDLE` keys).
- `deploy/docker-compose.yaml` remains frozen in Phase 6a (the CA bind-mount + five trust env vars are Phase 6b, under its own future exception).

## status.sh gotchas
- `stack is not running …` = stdout today (`msg_info`, no `>&2`) — don't "correct" it to stderr.
- `=== honey-starter has problems ===` = stderr (`msg_section … >&2`).
- `check_cmd()` is dead code (zero callers; kept + dressed).

## Pointers
Topology, Vault & secret lifecycle, bootstrap config, validation → [`deploy/README.md`](./deploy/README.md). Usage walkthrough → [`README.md`](./README.md).

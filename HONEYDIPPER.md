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

## Test / assert notes
- Rich detection is cached → probe each mode (plain / pty+dumb / pty+color) in a separate subprocess.
- Pty lines end `\r\n` → anchored asserts need `\r?$`.
- `msg_ok` = green ✅ + one space + text + reset (no bold).

## Menus (TTY-only)
- Number = index; type the exact value; Enter = default; the model menu's trailing *type your own* is a sentinel; an out-of-range integer is warned + re-asked, never adopted.

## Masked input (API keys)
- Raw-mode loop on `/dev/tty`: `stty -icanon -isig -echo`; per-char `dd bs=1` (not `read -N1` — re-enables ISIG); one `*` per char to stderr; Backspace pops; `^C` → exit 130 (scoped EXIT trap restores termios).
- Value returned via a 600-mode temp file, never stdout; `read -s` no-echo fallback; every key prompt re-types for confirmation.

## Frozen files
- Byte-identical vs main — no edits without a documented exception: `scripts/setup.sh`, `bootstrap/*`, `deploy/docker-compose.yaml`, `Makefile`, `test/pty-helper.py`, `.env.example`.

## status.sh gotchas
- `stack is not running …` = stdout today (`msg_info`, no `>&2`) — don't "correct" it to stderr.
- `=== honey-starter has problems ===` = stderr (`msg_section … >&2`).
- `check_cmd()` is dead code (zero callers; kept + dressed).

## Pointers
Topology, Vault & secret lifecycle, bootstrap config, validation → [`deploy/README.md`](./deploy/README.md). Usage walkthrough → [`README.md`](./README.md).

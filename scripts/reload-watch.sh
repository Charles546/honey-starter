#!/usr/bin/env bash
# reload-watch.sh — host-side config reload watcher for a honey-starter daemon.
#
# Watches the rendered config directory (${HD_STATE_DIR}/config by default) for
# changes and, after a short debounce, POSTs to the daemon's loopback-only
# webhook endpoint so the running daemon reloads its config without a restart.
#
# Design notes:
#   * Non-frozen: unlike the lifecycle scripts this is NOT a docker wrapper; it
#     is a standalone host-side watcher. It sources lib.sh for the shared
#     msg_* helpers / die() / warn() / shims, then runs entirely on the host.
#   * Watcher selection (overridable with HD_RELOAD_WATCHER=inotifywait|fswatch|
#     poll): inotifywait -> fswatch -> polling fallback, in that order.
#   * Debounce: file events are coalesced; the reload fires at most once per
#     HD_RELOAD_DEBOUNCE_SECONDS (default 3) after the last change.
#   * Singleton: a PID file (${HD_STATE_DIR}/reload-watch.pid, chmod 600)
#     guards against a second watcher instance; `--stop` sends SIGTERM.
#
# Run: bash scripts/reload-watch.sh [--stop]
#      (or: make reload-watch)
set -euo pipefail

# bash >= 4 required (arrays, [[ ]], coproc). Same guard as the other scripts.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  printf '%s\n' "ERROR: bash 4 or newer is required (found ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# --- tunables with defaults ---------------------------------------------------
# HD_WEBHOOK_PORT mirrors the compose daemon loopback publish (default 18080).
: "${HD_WEBHOOK_PORT:=18080}"
# HD_WEBHOOK_URL defaults to the loopback-only endpoint on HD_WEBHOOK_PORT.
: "${HD_WEBHOOK_URL:=http://127.0.0.1:${HD_WEBHOOK_PORT}/reload}"
# Debounce window: reload at most once per this many seconds after the last change.
: "${HD_RELOAD_DEBOUNCE_SECONDS:=3}"
# Polling fallback interval (only used when no inotifywait/fswatch is present).
# Exported so the polling coproc (a separate bash) can read it.
export HD_RELOAD_POLL_INTERVAL="${HD_RELOAD_POLL_INTERVAL:-2}"

# --- resolve state dir -> config dir -----------------------------------------
# Same default + relative-anchoring rules as start.sh, so `make reload-watch`
# and `make start` always watch the same rendered config. CONFIG_DIR is
# exported so the polling coproc can read it.
if [ -z "${HD_STATE_DIR:-}" ]; then
  HD_STATE_DIR="${HONEY_STARTER_DIR}/.honey-starter"
else
  case "${HD_STATE_DIR}" in
    /*) ;;
    *) HD_STATE_DIR="${HONEY_STARTER_DIR}/${HD_STATE_DIR}" ;;
  esac
fi
export CONFIG_DIR="${HD_STATE_DIR}/config"
PID_FILE="${HD_STATE_DIR}/reload-watch.pid"
TOKEN_FILE="${HD_STATE_DIR}/reload_token"

if [ ! -d "${CONFIG_DIR}" ]; then
  die "config dir not found: ${CONFIG_DIR} (start the stack with make start first)"
fi

# --- stat mtime args -----------------------------------------------------------
# Use the shared stat_mtime shim from lib.sh (lives OUTSIDE the KEEP-IN-SYNC
# platform-compat block). Resolve the form once up front and export it so the
# polling coproc (a separate bash) can use it directly.
stat_mtime / >/dev/null 2>&1 || true   # populate STAT_MTIME_ARGS
export STAT_MTIME_ARGS

# --- singleton guard ----------------------------------------------------------
# Claim the PID file; a stale PID (no longer alive) is reclaimed. The EXIT trap
# removes the file (and kills the watcher coproc) so a normal exit / Ctrl-C /
# SIGTERM (--stop) always cleans up.
EVENTS_PID=""
claim_pid() {
  if [ -f "${PID_FILE}" ]; then
    local oldpid
    oldpid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [ -n "${oldpid}" ] && kill -0 "${oldpid}" 2>/dev/null; then
      die "another reload-watch is already running (pid ${oldpid}); stop it with: bash scripts/reload-watch.sh --stop"
    fi
    # stale PID: reclaim.
    rm -f "${PID_FILE}"
  fi
  ( umask 077; printf '%s\n' "$$" > "${PID_FILE}" )
  chmod 600 "${PID_FILE}"
}
cleanup() {
  if [ -n "${EVENTS_PID:-}" ] && kill -0 "${EVENTS_PID}" 2>/dev/null; then
    kill -TERM "${EVENTS_PID}" 2>/dev/null || true
  fi
  if [ -f "${PID_FILE}" ] && [ "$(cat "${PID_FILE}" 2>/dev/null || true)" = "$$" ]; then
    rm -f "${PID_FILE}"
  fi
}
trap cleanup EXIT
# Defensive signal handling: trap INT/TERM so the EXIT-trap cleanup (pid-file
# removal + coproc teardown) always runs. We do NOT call `exit` from inside the
# signal handler: when bash is blocked in `read -t` on the coproc fd, running
# `exit` from within a trap can crash bash (intermittent SIGSEGV). Instead the
# handler only sets a flag; the main loop notices it (the pending read returns
# as soon as the trap fires) and breaks out, then `exit`s normally from the top
# level so the EXIT trap runs cleanup and the status is 128+signo.
STOP=0
STOP_SIG=""
trap 'STOP=1; STOP_SIG=TERM' TERM
trap 'STOP=1; STOP_SIG=INT' INT

# --- stop mode ----------------------------------------------------------------
if [ "${1:-}" = "--stop" ]; then
  if [ ! -f "${PID_FILE}" ]; then
    msg_info "reload-watch is not running (no ${PID_FILE})"
    exit 0
  fi
  local_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [ -n "${local_pid}" ] && kill -0 "${local_pid}" 2>/dev/null; then
    msg_info "stopping reload-watch (pid ${local_pid})"
    kill -TERM "${local_pid}" 2>/dev/null || true
    # give it a moment to remove its own pid file via the EXIT trap
    for _ in 1 2 3 4 5; do
      [ ! -f "${PID_FILE}" ] && break
      sleep 0.2
    done
    if [ -f "${PID_FILE}" ]; then
      warn "reload-watch did not exit cleanly; removing stale pid file"
      rm -f "${PID_FILE}"
    fi
  else
    msg_info "reload-watch is not running (stale pid file); removing"
    rm -f "${PID_FILE}"
  fi
  exit 0
fi

claim_pid

# --- reload transport ---------------------------------------------------------
# Read the reload token from the FILE start.sh persisted (chmod 600) — never
# from the environment (the token is secret material that lives only in the
# state dir + Vault).
send_reload() {
  if [ ! -r "${TOKEN_FILE}" ]; then
    warn "reload token file not readable: ${TOKEN_FILE} (start the stack first); skipping reload"
    return 0
  fi
  local token
  token="$(cat "${TOKEN_FILE}" 2>/dev/null || true)"
  if [ -z "${token}" ]; then
    warn "reload token file is empty: ${TOKEN_FILE}; skipping reload"
    return 0
  fi
  # --max-time keeps a hung daemon/webhook from wedging the watcher loop.
  if ! curl -fsS --max-time 10 -X POST --data-urlencode "token=${token}" "${HD_WEBHOOK_URL}" >/dev/null 2>&1; then
    warn "reload POST to ${HD_WEBHOOK_URL} failed; will retry on the next change"
    return 1
  fi
  return 0
}

# --- watcher event source -----------------------------------------------------
# The event source runs in a NAMED COPROC so we can read its output on a
# dedicated fd (EVENTS[0]) with a timeout for debouncing, and shut it down
# cleanly by killing the coproc PID. `exec` inside the coproc makes the coproc
# PID the watcher process itself (no intermediate child), so kill() is direct.
# Each produced line is an opaque "something changed" signal; the debounce loop
# below ignores the payload.
#
# Polling fallback: the coproc subshell cannot call parent functions, so it
# computes the newest mtime across all config files (using the exported
# STAT_MTIME_ARGS) and emits a line whenever that signature changes. The first
# check only establishes the baseline (no emit), so a start does not fire a
# spurious reload.
WATCHER=""
start_watcher() {
  case "${HD_RELOAD_WATCHER:-}" in
    inotifywait)
      require_cmd inotifywait
      coproc EVENTS { exec inotifywait -m -q -e modify,create,delete,move --format '%w%f' "${CONFIG_DIR}"; }
      WATCHER="inotifywait"
      ;;
    fswatch)
      require_cmd fswatch
      # NOTE: no -0 flag (newline-separated output so the debounce read -r works)
      # and no -1 (one-shot): fswatch must keep running continuously.
      coproc EVENTS { exec fswatch --event Updated --event Created --event Removed --event Renamed "${CONFIG_DIR}"; }
      WATCHER="fswatch"
      ;;
    poll|*)
      if [ -n "${HD_RELOAD_WATCHER:-}" ] && [ "${HD_RELOAD_WATCHER}" != "poll" ]; then
        warn "HD_RELOAD_WATCHER=${HD_RELOAD_WATCHER} not recognized; falling back to polling"
      fi
      # shellcheck disable=SC2016
      coproc EVENTS {
        exec bash -c '
          prev=""
          first=1
          while :; do
            newest=""
            while IFS= read -r f; do
              m="$(stat ${STAT_MTIME_ARGS} "$f" 2>/dev/null || true)"
              if [ -n "$m" ] && { [ -z "$newest" ] || [ "$m" -gt "$newest" ]; }; then
                newest="$m"
              fi
            done < <(find "${CONFIG_DIR}" -type f 2>/dev/null)
            if [ -z "$first" ]; then
              if [ -n "$newest" ] && [ "$newest" != "$prev" ]; then
                prev="$newest"
                printf "poll-change %s\n" "$newest"
              fi
            else
              first=""
              prev="$newest"
            fi
            sleep "${HD_RELOAD_POLL_INTERVAL}"
          done
        '
      }
      WATCHER="poll"
      ;;
  esac
}

# --- main loop ----------------------------------------------------------------
msg_section "=== honey-starter: reload-watch ==="
msg_info "watching ${CONFIG_DIR}"
msg_info "reload POST -> ${HD_WEBHOOK_URL} (debounce ${HD_RELOAD_DEBOUNCE_SECONDS}s)"

# select + start the watcher
if [ -z "${HD_RELOAD_WATCHER:-}" ]; then
  if command -v inotifywait >/dev/null 2>&1; then
    HD_RELOAD_WATCHER=inotifywait
  elif command -v fswatch >/dev/null 2>&1; then
    HD_RELOAD_WATCHER=fswatch
  else
    HD_RELOAD_WATCHER=poll
  fi
fi
start_watcher
msg_ok "watcher: ${WATCHER}"

# EVENTS_PID / EVENTS[] are managed by bash's named coproc EVENTS: they are set
# when the coproc starts and UNSET when it dies. We read the watcher's output
# with a per-iteration timeout so a quiet config dir still lets us notice
# --stop. NOTE: `read -t`'s exit status on a timed-out coproc read is NOT
# reliable (it can be 142 or 0 depending on the bash context), so we never
# branch on it to decide "timeout vs EOF" — we check the watcher's liveness
# directly with kill -0. If the watcher dies (inotifywait killed, watched dir
# removed, watcher crash) we RESTART it instead of busy-spinning the read.
pending=0
restarts=0
while :; do
  if [ "${STOP:-0}" -eq 1 ]; then
    break
  fi
  fd="${EVENTS[0]-}"
  if [ -z "${fd}" ]; then
    # watcher ended (coproc fd gone) -> restart it (self-heal, no busy-spin)
    start_watcher
    restarts=$((restarts + 1))
    msg_warn "watcher process ended; restarted (${WATCHER}, restart #${restarts})"
    pending=0
    continue
  fi
  if IFS= read -r -t "${HD_RELOAD_DEBOUNCE_SECONDS}" -u "${fd}" _line && [ -n "${_line}" ]; then
    # a real event line arrived: mark pending; the reload fires after a quiet
    # window. (The -n guard ignores a spurious "read succeeded but empty" — we
    # never want a phantom line to mark a change.)
    pending=1
    continue
  fi
  # No data this round: either a debounce timeout (watcher alive + quiet) or
  # the watcher just died. Distinguish by liveness, not by read's exit code.
  if kill -0 "${EVENTS_PID:-}" 2>/dev/null; then
    # watcher alive -> true debounce timeout; fire if something changed.
    if [ "${pending}" -eq 1 ]; then
      pending=0
      msg_info "config changed; requesting reload"
      send_reload || true
    else
      # Nothing pending. Brief pause so a dying-but-not-yet-reaped watcher can
      # never turn this into a busy-spin; in steady state we just timed out a
      # full debounce window, so this is harmless.
      sleep 0.1
    fi
  else
    # watcher dead: bash hasn't unset EVENTS[0] yet; the top-of-loop guard
    # restarts it on the next pass. Sleep briefly to avoid a hot loop.
    sleep 0.1
    pending=0
  fi
done
if [ "${STOP:-0}" -eq 1 ]; then
  case "${STOP_SIG}" in
    TERM) exit 143 ;;
    INT)  exit 130 ;;
  esac
fi

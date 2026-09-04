.PHONY: all lint check-bcrypt check-config compose-config smoke e2e validate \
	setup-dryrun setup-e2e start stop down down-volumes status logs

# Default target: the full validation gate.
#   lint           -> shellcheck over scripts/*.sh and test/*.sh (no docker)
#   check-bcrypt   -> htpasswd bcrypt contract (no docker)
#   setup-dryrun   -> scripts/setup.sh guided-installer dry-run/unit tests
#                     (hermetic; no docker)
#   check-config   -> honeydipper configcheck via docker image (docker + network;
#                     skips gracefully when docker is unavailable)
#   compose-config  -> `docker compose config` validation (docker; skips when
#                     unavailable)
#   smoke          -> full-stack compose smoke test (docker + network; skips
#                     when docker is unavailable)
#   e2e            -> full-stack E2E through the real scripts/start.sh path
#                     (docker + network; skips when docker is unavailable)
#   setup-e2e      -> full-stack E2E through the real scripts/setup.sh guided
#                     installer path (writes .env, delegates to start.sh;
#                     docker + network; skips when docker is unavailable)
all: lint check-bcrypt setup-dryrun check-config compose-config smoke e2e setup-e2e

# Shellcheck lint gate over all project bash scripts. No docker required.
lint:
	@bash -c 'if ! command -v shellcheck >/dev/null 2>&1; then echo "ERROR: required command not found: shellcheck (e.g. apt-get install shellcheck / brew install shellcheck)" >&2; exit 1; fi'
	shellcheck -x -P SCRIPTDIR scripts/*.sh test/*.sh

# B1: validate the bcrypt token hash contract using htpasswd only (no Go).
check-bcrypt:
	@bash test/check-bcrypt.sh

# P4-DRYRUN: hermetic no-docker tests for scripts/setup.sh (the Phase 4 guided
# installer): fresh .env writes, byte-exact read-modify-write round-trips,
# shell-safe quoting, masked summaries, validation + missing-var + no-tty
# error paths, and the answers-file interactive branch.
setup-dryrun:
	@bash test/setup-dryrun.sh

# B2: validate the assembled bootstrap config via honeydipper configcheck
# running inside the published docker image (REPO + CHECK_REMOTE=1).
check-config:
	@bash test/check-config.sh

# C1: validate deploy/docker-compose.yaml with `docker compose config`.
compose-config:
	@bash test/compose-config.sh

# C2: full-stack smoke test (valkey + vault + daemon + ui) in a throwaway
# compose project. Docker + network gated; skips gracefully otherwise.
smoke:
	@bash test/smoke-stack.sh

# C3: full-stack E2E test that boots the stack through the REAL scripts/start.sh
# single-command path into a throwaway compose project. Docker + network
# gated; skips gracefully otherwise.
e2e:
	@bash test/e2e.sh

# P4-E2E: full-stack E2E through the REAL scripts/setup.sh guided-installer
# path (copied tree -> questionnaire -> .env chmod 600 -> delegates to
# start.sh) into a throwaway compose project. Docker + network gated; skips
# gracefully otherwise.
setup-e2e:
	@bash test/setup-e2e.sh

# Full validation gate.
validate: lint check-bcrypt setup-dryrun check-config compose-config smoke e2e setup-e2e

# --- Lifecycle ----------------------------------------------------------------
# The lifecycle targets require a running docker daemon and a rendered state
# directory; they are NOT docker-availability-gated (you cannot "skip" a real
# start). They are plain wrappers over the scripts in scripts/.

# Single-command bring-up: preflight -> render config -> start valkey+vault ->
# initialize/unseal/seed vault -> write identity files -> start daemon+ui ->
# wait for /healthz. Idempotent and safe to re-run.
start:
	@bash scripts/start.sh

# Graceful stop (containers stopped, volumes + .honey-starter state kept).
stop:
	@bash scripts/stop.sh

# Full teardown: containers + default networks removed, named volumes and
# .honey-starter state preserved. A later `make start` resumes without
# re-initializing Vault.
down:
	@bash scripts/down.sh

# Full teardown that ALSO deletes the named volumes (vault-file, valkey-data,
# daemon-driver-cache), irrecoverably wiping Vault's file backend + valkey
# data. .honey-starter state is preserved (remove by hand when intentionally
# resetting a deployment).
down-volumes:
	@bash scripts/down.sh --volumes

# Report compose ps + /healthz + vault seal status + UI reachability.
status:
	@bash scripts/status.sh

# Follow the daemon logs (extra args pass through to `docker compose logs`).
logs:
	@bash scripts/logs.sh

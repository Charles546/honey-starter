.PHONY: all lint check-bcrypt check-config compose-config smoke validate

# Default target: the full validation gate.
#   lint           -> shellcheck over scripts/*.sh and test/*.sh (no docker)
#   check-bcrypt   -> htpasswd bcrypt contract (no docker)
#   check-config   -> honeydipper configcheck via docker image (docker + network;
#                     skips gracefully when docker is unavailable)
#   compose-config  -> `docker compose config` validation (docker; skips when
#                     unavailable)
#   smoke          -> full-stack compose smoke test (docker + network; skips
#                     when docker is unavailable)
all: lint check-bcrypt check-config compose-config smoke

# Shellcheck lint gate over all project bash scripts. No docker required.
lint:
	@bash -c 'if ! command -v shellcheck >/dev/null 2>&1; then echo "ERROR: required command not found: shellcheck (e.g. apt-get install shellcheck / brew install shellcheck)" >&2; exit 1; fi'
	shellcheck -x -P SCRIPTDIR scripts/*.sh test/*.sh

# B1: validate the bcrypt token hash contract using htpasswd only (no Go).
check-bcrypt:
	@bash test/check-bcrypt.sh

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

# Full validation (Phase 2 gate).
validate: lint check-bcrypt check-config compose-config smoke

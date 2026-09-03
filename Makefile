.PHONY: all lint check-bcrypt check-config validate

# Default target: the full Phase 1 validation gate.
#   lint          -> shellcheck over scripts/*.sh and test/*.sh (no docker)
#   check-bcrypt  -> htpasswd bcrypt contract (no docker)
#   check-config  -> honeydipper configcheck via docker image (docker + network;
#                    skips gracefully when docker is unavailable)
all: lint check-bcrypt check-config

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

# Full Phase 1 validation.
validate: lint check-bcrypt check-config

.PHONY: all check-bcrypt check-config validate

all: check-bcrypt check-config

# Generate a bcrypt hash of TOKEN and compare it against the fixture
check-bcrypt:
	@bash test/check-bcrypt.sh

# Validate the assembled bootstrap config with honeydipper configcheck
check-config:
	@bash test/check-config.sh

# Run both validations
validate: check-bcrypt check-config

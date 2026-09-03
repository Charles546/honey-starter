# Deployment

This directory will contain docker-compose and container orchestration files
for the honey-starter deployment.

## docker-compose (Phase 2)

A `docker-compose.yml` file will be generated here by the `scripts/start.sh`
script, provisioning:

- valkey (Valkey standalone)
- vault (HashiCorp Vault dev mode)
- honeydipper (daemon)
- hd-ui (web UI, optional)

A `docker-compose.override.yml` is gitignored so that local overrides
(published ports, environment variables, volume mounts) do not interfere with
version control.

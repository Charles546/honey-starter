# honey-starter Vault server configuration (non-dev, file backend).
#
# This file is mounted read-only into the vault container at
# /vault/config/vault.hcl and is used by `vault server` (the container's
# default CMD is `server -dev`, which the compose file overrides).
#
# Reachability note: the listener binds 0.0.0.0 inside the container on the
# *internal* compose network only. The vault service publishes no host ports,
# so nothing on the docker host (or outside it) can reach Vault through a
# port mapping. The only consumers of this listener are the other containers
# attached to the internal network (the daemon). Do not publish this port.
#
# We deliberately do not run Vault in dev mode: dev mode auto-unseals, keeps
# the root token in plain process env, and stores data in memory. This file
# backend persists to the vault-file named volume and requires explicit
# init/unseal (keys are held by the operator / start.sh), which is the
# intended secret lifecycle for a starter deployment.
storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

# Single-node non-HA instance. api_addr/cluster_addr are used for the vault
# CLI/health checks inside the container and for cluster bookkeeping.
api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

# Vault normally wants to mlock memory to avoid swapping secrets to disk.
# The compose file grants IPC_LOCK to the vault container for this reason.
disable_mlock = false

ui = false

default_lease_ttl = "24h"
max_lease_ttl     = "720h"

# Deployment (docker-compose)

This directory contains the container orchestration for the honey-starter
deployment. The compose file provisions four services on a Linux docker host:

| Service    | Image (default)                                 | Role                                             |
|------------|-------------------------------------------------|--------------------------------------------------|
| `valkey`   | `valkey/valkey:8.1.0`                           | Redis-compatible event bus, locks, cache, scheduler |
| `vault`    | `hashicorp/vault:1.21.1`                        | Secrets store (file backend, non-dev)            |
| `daemon`   | `honeydipper/honeydipper:4.0.0-alpha4-53-g897242b` | Honeydipper engine/receiver/operator/api/agent   |
| `ui`       | `honeydipper/hd-ui:0.1.0-alpha2-52-g0ea2fad`    | Web UI (nginx)                                   |

## Topology and network model

Two compose networks:

* **`data`** (internal: no external route) carries `valkey` and `vault`.
  * Vault publishes **no host port**. Its listener binds `0.0.0.0:8200`
    *inside the container* and is reachable only from other containers on the
    `data` network. Nothing on the docker host or outside it can reach Vault
    through a port mapping.
  * The daemon reaches Vault as `http://vault:8200` and Valkey via
    `LOCALREDIS=redis://valkey:6379` (see below).
* **`edge`** carries `daemon` and `ui`, provides outbound internet (git config
  repos, the remote-driver binary registry) and the two published host ports:
  daemon API `9000` and UI `8090` (overridable with `HD_API_HOST_PORT` /
  `HD_UI_HOST_PORT`).

## Runtime state

`deploy/docker-compose.yaml` uses relative host paths anchored at
`deploy/`, so `../.honey-starter` means `<repo>/.honey-starter` (gitignored).
Override the base with `HD_STATE_DIR` (use an absolute path). Before
`docker compose up -d daemon` the directory must contain:

* `.honey-starter/config/` — a **rendered** copy of `bootstrap/` with the
  `<ns>` / `<user>` placeholders replaced (see "Bootstrap placeholders").
* `.honey-starter/identity/role_id` and `.honey-starter/identity/secret_id` —
  the Vault AppRole identity pair, mounted read-only into the daemon at
  `/var/hd-secrets/identity`.

## Bring-up sequence

Vault starts **sealed** (file backend, non-dev) and the daemon resolves Vault
secrets at config-load time, so bring-up is intentionally two-phase:

```bash
# 1) infrastructure (valkey + vault; vault starts sealed)
docker compose -f deploy/docker-compose.yaml up -d valkey vault

# 2) initialize/unseal vault, enable KV v2 + AppRole, write identity files,
#    seed secrets/data/<ns>/daemon
#    (test/smoke-stack.sh automates all of this on a throwaway project)

# 3) application (depends_on waits for vault healthy == unsealed)
docker compose -f deploy/docker-compose.yaml up -d daemon ui
```

`docker compose up -d` without service names starts everything at once; the
daemon's `depends_on ... condition: service_healthy` waits for Vault's
`vault status` healthcheck (exit 0 only when initialized **and** unsealed), so
if you seed after starting all services, restart the daemon once seeding is
done:

```bash
docker compose -f deploy/docker-compose.yaml restart daemon
```

`scripts/start.sh` (Phase 3) automates the entire sequence including Vault
initialization and secret seeding.

## Environment namespaces

There are three distinct kinds of environment variables. Do not confuse them:

1. **`HD_*` — template-fed daemon settings.** The config loader
   (`pkg/dipper/env.go`) exposes only env vars prefixed `HD_` to
   `{% .env.X %}` templates, with the prefix stripped:
   * `HD_UI_URL` → template `.env.UI_URL` (daemon `services.api.ui_url`)
   * `HD_API_PORT` → template `.env.API_PORT` (`services.api.listener.addr`)
   * `HD_CONFIG_CHECK_INTERVAL` → template `.env.CONFIG_CHECK_INTERVAL`
   * `HD_AI_BASE_URL`, `HD_AI_MODEL` → engine `base_url` / `model` overrides
   * Local (non-compose) Valkey overrides: `HD_VALKEY_ADDR`/`HD_VALKEY_PASSWORD`
     → `.env.VALKEY_ADDR`/`.env.VALKEY_PASSWORD`

2. **Plain env — consumed directly by binaries, NOT visible to templates:**
   * `REPO`, `BRANCH`, `CHECK_REMOTE` (config bootstrap)
   * `LOCALREDIS` (redis drivers)
   * `VAULT_ADDR`, `VAULT_ROLE_ID`, `VAULT_SECRET_ID`, `HD_SECURE_LOADER`
     (vault driver + secure loader)
   * `HD_JWT_SIGNING_KEY` (api session tokens; `os.Getenv`)
   * `HOME`

3. **`hd-secret-file://` compose values — materialized by the daemon image
   entrypoint.** The entrypoint scans the environment; any value beginning
   `hd-secret-file://<name>` is replaced with the verbatim contents of
   `/var/hd-secrets/<name>` before the process execs. `VAULT_ROLE_ID` and
   `VAULT_SECRET_ID` use this to load the AppRole pair from the mounted
   identity directory without ever baking the values into the compose file.

## Vault

### Principle

> Put secrets in Vault. The only secret material needed outside Vault is the
> AppRole identity pair used to *reach* Vault.

The daemon **never** receives the Vault root token. It authenticates with
AppRole credentials whose policy is read-only and scoped exactly to
`secrets/data/<ns>/daemon`.

### Configuration

`vault/vault.hcl` (mounted read-only at `/vault/config/vault.hcl`):

* `storage "file"` at `/vault/file` (the `vault-file` named volume)
* listener `tcp 0.0.0.0:8200`, TLS disabled, on the internal `data` network
  with **no published host port**
* `disable_mlock = false` — the compose file grants `IPC_LOCK`; the official
  image entrypoint setcaps the binary before dropping to the `vault` user
* not HA, no UI

The compose file overrides the image's default dev CMD with `command:
["server"]`. The Vault 1.21.1 image entrypoint still injects
`-dev-root-token-id` / `-dev-listen-address` flags, but Vault ignores them
outside dev mode (it logs a warning and uses the file config).

### Driver configuration

The Vault **driver** (`hd-driver-vault`) is configured entirely through plain
environment variables — the `vault:` data block in `bootstrap/daemon.yaml` is
deliberately empty:

```yaml
vault: {}
```

Declaring `addr`, `token`, or `k8sRole` in driver data would shadow the
driver's env fallback and would risk pointing the daemon at the wrong Vault or
at the root token. The daemon receives:

```
VAULT_ADDR=http://vault:8200
VAULT_ROLE_ID=hd-secret-file://identity/role_id
VAULT_SECRET_ID=hd-secret-file://identity/secret_id
```

**Never set `VAULT_K8S_ROLE`**: the vault driver tries kubernetes auth first
and AppRole is silently skipped when a k8s role is present.

### How secrets reach the config

Two complementary mechanisms:

* **`LOOKUP[vault,/secrets/data/<ns>/daemon#<key>]` config values.** At
  config-load time each service recursively resolves `LOOKUP[...]` strings by
  an RPC to the `driver:vault` feature — a builtin driver subprocess spawned
  by the daemon that **inherits the daemon's environment** (VAULT_ADDR +
  AppRole creds). The auth-simple token hash, AI engine API keys, and any
  other `LOOKUP[vault,...]` value in the bootstrap config are resolved this
  way during `StageDiscovering`.
* **`hd-lookup:vault:/secrets/data/<ns>/daemon#<key>` environment values
  (optional).** With `HD_SECURE_LOADER=./hd-driver-vault`, the daemon image
  entrypoint execs `hd-driver-vault exec` first, which resolves every env var
  of the form `hd-lookup:...` through the same driver before `exec`-ing
  honeydipper. The starter does not currently use `hd-lookup:` env values
  (its secrets are config `LOOKUP`s), but the wiring is present for future use.

## LOCALREDIS

All redis-backed core drivers (`redisqueue`, `redispubsub`, `redislock`,
`redis-cache`, `api-broadcast`, `redis-scheduler`) build their client options
through `redisclient.GetRedisOpts`, which checks `LOCALREDIS` first and parses
it as a URL. The compose file sets:

```
LOCALREDIS=redis://valkey:6379
```

so the `Addr`/`Password` templates in `bootstrap/daemon.yaml` are **inert in
the compose deployment**; every redis connection is redirected to the `valkey`
service. Valkey runs with `--protected-mode no` only because it is on the
internal `data` network and publishes no host port.

## API and UI

* The daemon API listens on `:9000` (`HD_API_PORT`), prefix `/api/`, health at
  `/healthz`. `/healthz` reflects the health of the **api** service: it returns
  200 only after that service has reached StageServing and become healthy. The
  api service loads the `driver:vault` feature and the `auth-simple` driver,
  so reaching 200 requires the Vault `LOOKUP` values in the auth config (the
  admin token hash) to have resolved at StageDiscovering. (The other services
  — engine/receiver/operator/agent — run in the same process but are not part
  of the api health gate.)
* The UI (nginx) listens on `8080` inside its container (published as
  `HD_UI_HOST_PORT`, default `8090`) and proxies `~ ^/(api|healthz)(/.*)?$`
  to `HD_API_URL=http://daemon:9000` **without rewriting the path**, so the
  daemon receives `/api/...` and `/healthz` unchanged.
* The UI is configured with `ENABLED_AUTH_METHODS=token`; it authenticates by
  sending the bearer token (admin token) that maps through the auth-simple
  driver (bcrypt hash stored in Vault) to the seeded admin subject.

## Hardening notes

* The daemon runs `read_only: true` with `tmpfs /tmp`, `cap_drop: [ALL]`, and
  `no-new-privileges`. The only writable mounts are the named
  `daemon-driver-cache` volume (remote driver cache at
  `/opt/honeydipper/drivers/cache`) and `tmpfs /tmp` (config bootstrap clones
  and git temp data). The config and identity mounts are read-only.
* The identity files are mounted read-only; the role_id/secret_id never appear
  in the compose file or process listing as literals.
* The UI service is intentionally **not** `read_only` because hd-ui writes
  `/usr/share/nginx/html/config.js` at start and the stock nginx entrypoint
  writes its config; it keeps image-default capabilities (nginx needs to drop
  worker privileges) plus `no-new-privileges` and tmpfs for runtime state.

## Bootstrap placeholders

`bootstrap/` is a template config containing `<ns>` and `<user>` placeholders:

* `<ns>` — the Vault KV namespace prefix used in `LOOKUP[vault,...]` paths.
  It must match the path segment used when seeding Vault
  (`secrets/data/<ns>/daemon`).
* `<user>` — the admin subject; used in the casbin binding and the
  `contexts.yaml` operator marker. Keep it in sync with
  `bootstrap/tests/api_auth_tests.yaml`.

The compose daemon mounts a *rendered* config directory (no placeholders).
`test/check-config.sh` and `test/smoke-stack.sh` render throwaway copies;
`scripts/start.sh` (Phase 3) will own the real render for deployments.

## Validation

* `make compose-config` — `docker compose config` validation (docker-gated).
* `make smoke` — `test/smoke-stack.sh`, a full-stack smoke test in a
  throwaway compose project (docker + network gated) that boots valkey/vault,
  initializes/unseals Vault, seeds the AppRole identity + namespace secrets,
  boots daemon + ui, and asserts:
  * `/healthz` becomes 200 (all services healthy, all Vault LOOKUPs resolved)
  * an admin bearer token authenticates (`GET /api/user/profile` → 200)
  * anonymous access is denied
  * the AppRole policy is read-only and scoped exactly to
    `secrets/data/<ns>/daemon`
  * the UI serves HTTP 200

Both gates skip cleanly (exit 0) when docker is unavailable, so they must be
re-run on a docker-enabled host before merge.

## Customization knobs

| Env | Default | Meaning |
|-----|---------|---------|
| `HD_STATE_DIR` | `<repo>/.honey-starter` | rendered config + identity base dir (absolute) |
| `HD_API_HOST_PORT` | `9000` | host port for daemon API |
| `HD_UI_HOST_PORT` | `8090` | host port for UI |
| `HD_API_PORT` | `9000` | daemon API container port (also feeds listener template) |
| `HD_UI_URL` | `http://localhost:8090` | public UI base URL (OAuth/SAML redirects) |
| `HD_CONFIG_CHECK_INTERVAL` | `1m` | daemon config watch interval |
| `HD_JWT_SIGNING_KEY` | empty | API session-token signing key (optional) |
| `HONEYDIPPER_IMAGE` | pinned build | daemon image tag |
| `VALKEY_IMAGE` | `valkey/valkey:8.1.0` | valkey image tag |
| `VAULT_IMAGE` | `hashicorp/vault:1.21.1` | vault image tag |
| `HD_UI_IMAGE` | pinned build | UI image tag |

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

Three compose networks, all internal except `edge`:

* **`data-vault`** (internal: no external route) carries `vault` and `daemon`.
  Vault publishes **no host port**. Its listener binds `0.0.0.0:8200`
  *inside the container* and is reachable only from the daemon on the
  `data-vault` network (plus `docker compose exec`, which travels through the
  docker API, not the container network). Nothing on the docker host or
  outside it can reach Vault through a port mapping.
* **`data-valkey`** (internal) carries `valkey` and `daemon`. Valkey also
  publishes no host port.
* **`edge`** carries `daemon` and `ui`, provides outbound internet (git config
  repos, the remote-driver binary registry) and the two published host ports:
  daemon API `9000` and UI `8090` (overridable with `HD_API_HOST_PORT` /
  `HD_UI_HOST_PORT`).

Vault and Valkey are deliberately on **separate** internal networks: the only
container that bridges them is the daemon, so an unauthenticated Valkey and a
sealed/secret-holding Vault cannot reach each other (lateral-movement
reduction). The daemon reaches Vault as `http://vault:8200` and Valkey via
`LOCALREDIS=redis://valkey:6379` (see below).

### Vault reachability contract (read this before anything else)

> **Vault is unreachable from the host by network design; all
> init/unseal/policy/seeding operations are performed with
> `docker compose exec vault …`. Do not publish port 8200.**

The Vault CLI inside the `vault` service container is the *only* way to talk
to the Vault API for administrative operations. There is **no** host port, no
`network_mode: host`, and no sidecar that would expose Vault on the host's
loopback. `docker compose exec` reaches the container through the docker API
rather than the container network, which is exactly why administrative access
still works.

The shared helper functions live in `scripts/lib.sh` and are used by the
smoke test (`test/smoke-stack.sh`), the E2E test (`test/e2e.sh`) and
`scripts/start.sh` so the three cannot diverge:

```bash
vault_exec          # docker compose exec -i -T --user vault vault vault "$@"
vault_exec_token T  # same, with -e VAULT_TOKEN=$T in the container env
```

A practical consequence and UX win: **end-users never need a vault binary
installed on the docker host.** Every administrative action is a single
`docker compose exec vault vault …` away, and `scripts/start.sh` automates
the whole bring-up.

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

`.honey-starter/` is the most sensitive directory on the host: it holds the
rendered config, the AppRole identity pair, the plaintext admin token, and
(during bring-up) the Vault root token and unseal key. Treat it like "the
kingdom" (see "Hardening notes"). `scripts/start.sh` and the lifecycle
scripts manage it for you — you normally never touch it by hand.

## Single-command bring-up (scripts/start.sh)

`scripts/start.sh` wraps the two-phase bring-up (below) into **one command**
that is idempotent and safe to re-run:

```bash
make start          # or: bash scripts/start.sh
```

What it does, in order:

1. **Preflight** — Linux-only guard; requires `docker` + compose v2, `curl`,
   `jq`, `openssl`, `htpasswd`; `docker info` reachability; best-effort
   host-port conflict check for the published API/UI ports (skipped while this
   stack's daemon is already running).
2. **Load `.env`** (repo root) if present, honoring the documented env
   contract (`HD_*` template-fed, plain env direct, `HD_STATE_DIR`,
   `COMPOSE_FILE`). The Makefile lifecycle targets all source the same
   `scripts/lib.sh`, so they always address the same compose project/state
   dir.
3. **Render config** — `bootstrap/` is copied into `${HD_STATE_DIR}/config/`
   with the `<ns>`/`<user>` placeholders substituted (`HONEY_NS`, default
   `starter`; `HONEY_USER`, default `admin`). Rendered every run and compared;
   when unchanged the bind mount is left untouched (no daemon disruption), and
   when changed the config is refreshed in place and a running daemon is
   restarted so the change applies immediately.
4. **Infrastructure** — `docker compose up -d valkey vault`; wait for the
   vault API (the same exit-code probing the smoke test uses: exit 1 / "not
   initialized", exit 2 / "Sealed", or exit 0 / "Sealed" all mean the API
   is up).
5. **Vault (first run only)** — initialize with `HONEY_VAULT_KEY_SHARES` /
   `HONEY_VAULT_KEY_THRESHOLD` (defaults 1/1; see below), persist the root
   token + all unseal keys to `${HD_STATE_DIR}/root_token` and
   `${HD_STATE_DIR}/unseal_key` (chmod 600, host-only, **never mounted**),
   unseal, then enable KV v2 at `secrets/` + AppRole, write the read-only
   `daemon-read` policy scoped **exactly** to `secrets/data/<ns>/daemon`,
   create the AppRole role (`token_policies=daemon-read`,
   `secret_id_ttl=0`, `token_ttl=1h`, `token_max_ttl=24h`), and write the
   identity pair into `${HD_STATE_DIR}/identity/`.
6. **Seed secrets** — `secrets/<ns>/daemon` is seeded (without clobbering on
   re-run) with `admin_token_hash` (htpasswd bcrypt of the admin token),
   `openai_api_key` and `openrouter_api_key` (see AI provider below).
7. **Application** — `docker compose up -d daemon ui` (compose `depends_on`
   already waits for vault healthy == unsealed); wait for `/healthz` 200 with
   good timeout diagnostics (status + tailed logs on failure).
8. **Summary** — UI URL, API URL, and the admin token (printed **once** on
   first run; also persisted at `${HD_STATE_DIR}/admin_token` chmod 600 for
   re-runs).

**Re-run behavior** — vault is detected from the server itself (initialized? /
sealed?), so re-runs skip init and only unseal when needed (e.g. after a host
reboot or `docker compose restart`); KV v2 / AppRole / policy / role writes
are idempotent; the AppRole identity pair is reused when it still matches the
role (Vault keeps `role_id` stable, and `secret_id_ttl=0` means generated
secret ids never expire — no churn on re-run); and the admin token + API keys
are never regenerated. The `<ns>`/`<user>` values used on first run are
persisted to `${HD_STATE_DIR}/provision.env`; start.sh refuses to proceed if
they change later (that would desync the daemon's LOOKUP paths from the seeded
secrets) — to change them, `make down-volumes` and remove the state dir.

**Key shares** — a starter deployment defaults to 1 key share / 1 threshold
(dev-style convenience, matching the smoke test): one unseal key unlocks the
whole deployment, so `${HD_STATE_DIR}` is truly "the kingdom". For a
higher-assurance host set e.g. `HONEY_VAULT_KEY_SHARES=5
HONEY_VAULT_KEY_THRESHOLD=3` in `.env` before the first run; start.sh persists
all keys to `unseal_key` (one per line) and you should additionally back them
up out-of-band. These knobs are inert after Vault is initialized.

**Lifecycle** — `make stop` (graceful stop, state kept), `make down`
(containers + default networks removed, named volumes + state kept),
`make down-volumes` (also deletes the named volumes — wipes Vault's file
backend and valkey data), `make status` (compose ps + `/healthz` + vault seal
status + UI reachability), `make logs` (follow daemon logs). None of them ever
touch `.honey-starter/` except `start.sh`.

### .honey-starter/ layout

```
.honey-starter/                      # chmod 700 — "the kingdom"
├── admin_token                      # chmod 600 — plaintext admin bearer token
│                                    #   (operational secret; ONLY its bcrypt hash
│                                    #   is in Vault; printed once on first run)
├── root_token                       # chmod 600 — Vault root token (host-only,
│                                    #   never mounted; used by scripts only)
├── unseal_key                       # chmod 600 — unseal key(s), one per line
├── provision.env                    # chmod 600 — <ns>/<user> used on first run
├── config/                          # chmod 755 dir; files a+rX — RENDERED
│   └── ...                          #   bootstrap/ copy with placeholders
└── identity/                        # chmod 755 dir
    ├── role_id                      # chmod 600 + root-owned (or 0644 when no
    └── secret_id                    #   root/sudo) — AppRole pair, mounted :ro
```

The `identity/` and `config/` files are bind-mounted into the daemon, whose
container runs as root-without-caps (`cap_drop: [ALL]`) — see *Hardening
notes* (the `cap_drop`/`CAP_DAC_OVERRIDE rule`) below for why the modes
matter. The `admin_token`, `root_token`, `unseal_key` and `provision.env`
files are host only: nothing is mounted from them, and they are created with
chmod 600.

## Bring-up sequence

Vault starts **sealed** (file backend, non-dev) and the daemon resolves Vault
secrets at config-load time, so bring-up is intentionally two-phase:

```bash
# 1) infrastructure (valkey + vault; vault starts sealed)
docker compose -f deploy/docker-compose.yaml up -d valkey vault

# 2) initialize/unseal vault, enable KV v2 + AppRole, write identity files,
#    seed secrets/data/<ns>/daemon
#    (test/smoke-stack.sh automates all of this on a throwaway project;
#     scripts/start.sh / test/e2e.sh automate it for real deployments)
#    Every step uses: docker compose exec vault vault ...  (or the helpers above)

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
* listener `tcp 0.0.0.0:8200`, TLS disabled, on the internal `data-vault`
  network with **no published host port**
* `disable_mlock = false` — the compose file grants `IPC_LOCK`; the official
  image entrypoint setcaps the binary before dropping to the `vault` user
* not HA, no UI

The compose file overrides the image's default dev CMD (`server -dev`) with
`command: ["server"]`. The Vault 1.21.1 image entrypoint appends
`-dev-root-token-id=` / `-dev-listen-address=` to the command line whenever
the subcommand is `server`, but those flags are consulted only when dev mode
is active and they do **not** enable dev mode by themselves — so the non-dev
file-backed server configured here is what runs, and **no warning is
emitted** for the injected flags. Two consequences:

* Do **not** "fix" the apparent redundancy by removing the injected flags
  (you cannot — the entrypoint adds them); they are inert in this setup.
* **Never set `VAULT_DEV_ROOT_TOKEN_ID` or `VAULT_DEV_LISTEN_ADDRESS`** in the
  vault container environment: the entrypoint would inject their values into
  the command line, so they would take effect the moment dev mode is ever
  activated (e.g. by a future `-dev` in the compose command).

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
  (its secrets are config `LOOKUP`s), but the wiring is present for future
  use — notably for `HD_JWT_SIGNING_KEY` (see below).

### Config reload behavior and the 30m default (H2)

The daemon runs a `Watch()` loop that, every `configCheckInterval`, calls
`Refresh()` and then, if the config changed, re-assembles and triggers
`OnChange()`. For a **local-dir init repo** (the `REPO` points at a local
directory and `BRANCH` is unset — exactly the compose deployment)
`refreshRepo()` always reloads and returns "changed", so the config is
**re-assembled and reloaded unconditionally every interval**.

Two consequences make the **1m upstream default harmful** in this deployment:

* Every reload re-resolves **every** Vault `LOOKUP`, which means a **fresh
  AppRole login per tick**. At 1m that is needless per-minute AppRole churn
  (login volume, audit noise, token TTL pressure).
* A failed reload while Vault is unreachable (or a `LOOKUP` key is missing /
  permission-denied) raises a config-processing panic; the daemon marks the
  service unhealthy, rolls back to the **last-good raw config**, but that raw
  config still contains the undecrypted `LOOKUP` strings — so the next tick
  retries decryption and fails again until Vault returns, with `/healthz`
  flapping to 500 in the interim.

The compose deployment therefore defaults `HD_CONFIG_CHECK_INTERVAL` to
**30m** (matching the smoke test and hd-home) and documents this as a
deliberate tradeoff: config/secret changes may take up to the interval to
apply, in exchange for bounded AppRole churn and reload-storm behavior.
The interval remains env-tunable — set `HD_CONFIG_CHECK_INTERVAL` to `1m` if
you want the older per-minute behavior. Once upstream gains **fsnotify-backed
reloads** (true change detection), the per-minute/instant interval becomes
safe again and the default can follow.

For the most robust single-host behavior you can additionally opt out of
periodic reloads entirely:

```yaml
# bootstrap/daemon.yaml
daemon:
  watchConfig: false
```

With `watchConfig: false`, config/secret changes require
`docker compose restart daemon` — there is no periodic reload at all.

#### Vault outage behavior

* **Vault reachable, all seeded keys present:** daemon boots and serves
  `/healthz` 200.
* **Vault goes down after a successful boot:** the next reload tick (at most
  `HD_CONFIG_CHECK_INTERVAL` later) fails to resolve a `LOOKUP`; the affected
  service(s) mark unhealthy (`/healthz` → 500) and roll back to the last-good
  running config, which keeps the last-known-good secrets serving. When Vault
  becomes reachable again, the next tick re-resolves and the service recovers
  automatically.
* **Crash-loop at boot:** a `LOOKUP` could not be resolved on first load —
  usually a missing/incorrect seed key (e.g. the admin token hash was not
  seeded into `secrets/data/<ns>/daemon`), or Vault was still sealed. Fix the
  seed and `docker compose restart daemon` (or wait for Vault + the next
  tick).

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
internal `data-valkey` network and publishes no host port.

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

## `HD_JWT_SIGNING_KEY` (M5)

The api service reads `HD_JWT_SIGNING_KEY` directly via `os.Getenv` to mint
principal session tokens. It is **off by default** and genuinely optional:
`auth-simple` bearer-token auth does not consume it. If an operator sets it as
a plain env value in the compose file or `.env`, it becomes an operational
secret living **outside Vault**.

For strict compliance with the "secrets in Vault" principle, the alternative
that already works is to set it as an **`hd-lookup:` environment value**:

```
HD_JWT_SIGNING_KEY=hd-lookup:vault:/secrets/data/<ns>/daemon#hd_jwt_signing_key
```

Because the api process reads the value via `os.Getenv` (a direct process
read, not a config-template `LOOKUP`), only the `HD_SECURE_LOADER` exec-mode
mechanism can serve it — a config `LOOKUP` cannot. The daemon image entrypoint
runs `hd-driver-vault exec` before exec-ing honeydipper, which resolves the
`hd-lookup:` value from Vault into the real env; the API then reads it as a
normal env var. Seed the corresponding `hd_jwt_signing_key` field under
`secrets/data/<ns>/daemon` (generate with `openssl rand -hex 32`).

## Hardening notes

* **Threat model — container compromise is root inside the container.** The
  `honeydipper/honeydipper` image does **not** declare a `USER`, so the daemon
  process runs as **root** inside its container. The hardening below reduces
  what root-in-container can do: `read_only: true` rootfs, `tmpfs /tmp`, only
  the named `daemon-driver-cache` volume writable, `cap_drop: [ALL]`, and
  `no-new-privileges: true` — so a compromised daemon cannot install
  capabilities, write to the config/identity mounts (read-only), or persist
  outside the cache volume and tmpfs.
* **`cap_drop: [ALL]` also removes `CAP_DAC_OVERRIDE`, so root-in-container
  obeys normal file permissions.** A bind mount from a host directory keeps
  the host file's uid/gid/mode. On a Linux host (and under Docker Desktop's
  WSL2 integration, where bind mounts preserve the WSL uid, typically 1000),
  a `0600` identity file owned by the invoking host user is **not readable**
  by the daemon's root-without-caps process — the entrypoint `cat` fails with
  `Permission denied` and the daemon starts with empty AppRole credentials.
  Anything the daemon must read through a bind mount must be readable by
  root-without-caps: `0644` files (or `0640` with a group the daemon's uid
  belongs to), or owned by uid 0. This is exactly why the smoke test writes
  the throwaway identity files `0644` (see "Identity-file hygiene").
* **AppRole scoping limits Vault blast radius.** Even with root inside the
  container, the AppRole credential can only *read*
  `secrets/data/<ns>/daemon`; it cannot write, cannot list, and cannot read
  other paths (see the smoke test assertions).
* **`.honey-starter/` on the host is "the kingdom".** It co-locates the
  rendered config, the AppRole identity pair, and during bring-up the root
  token + unseal key. Anyone who can read that directory (or the
  `docker compose exec vault` path) controls the deployment. Keep host
  permissions tight (`chmod 700` on the directory, `chmod 600` on identity
  files, with the daemon-readability caveat below: `0600` must be
  root-owned, because the daemon's root-without-caps cannot read a
  non-root-owned `0600` file).
* **Running the daemon as non-root is a documented follow-up.** Compose cannot
  `chown` the bind mounts and named volume into a non-root UID, so adding
  `user:` to the daemon service requires the cache volume and the state
  mounts to be writable by that UID first (an image change or an
  entrypoint-driven `chown`). Until then the rootfs/caps/no-new-privileges
  hardening is the mitigation.
* The identity files are mounted read-only; the role_id/secret_id never appear
  in the compose file or process listing as literals.
* The UI service is intentionally **not** `read_only` because hd-ui writes
  `/usr/share/nginx/html/config.js` at start and the stock nginx entrypoint
  writes its config; it keeps image-default capabilities (nginx needs to drop
  worker privileges) plus `no-new-privileges` and tmpfs for runtime state.

### Identity-file hygiene (host side)

The identity files are the daemon's AppRole pair (`role_id` + `secret_id`),
mounted read-only into the container at `/var/hd-secrets/identity`. Because
the daemon image has no `USER` (root-in-container) **and** `cap_drop: [ALL]`
removes `CAP_DAC_OVERRIDE`, the container process cannot bypass normal file
permissions — so the files must be readable by root-without-caps, i.e. `0644`
(or `0640` with a group the container uid is in), or owned by uid 0.

**Smoke test / throwaway stacks** (`test/smoke-stack.sh`) — the identity
pair is freshly generated per run, mounted `:ro`, and never the Vault root
token, so `0644` is the correct choice and keeps the smoke passing whether
the host user is root or a non-root WSL user:

```bash
printf '%s' "${ROLE_ID}"   > .honey-starter/identity/role_id
printf '%s' "${SECRET_ID}" > .honey-starter/identity/secret_id
chmod 644 .honey-starter/identity/role_id .honey-starter/identity/secret_id
```

**Production (`scripts/start.sh`, or by hand)** — `.honey-starter/` is "the
kingdom" (co-locates the rendered config and, during bring-up, the root token
and unseal key). Keep host-side permissions tight (`chmod 700` on the
directory). The shipped compose daemon always runs as root-without-caps
(`cap_drop: [ALL]`), so the identity files must be readable by uid 0 without
`CAP_DAC_OVERRIDE` — i.e. owned by root with `0600`, or group/world readable:

```bash
# If start.sh runs as root / sudo: the files are already root-owned, so the
# tightest form works — 0600 + owner root (uid 0) is readable by the daemon's
# root-without-caps, and by no one else:
printf '%s' "${ROLE_ID}"   > .honey-starter/identity/role_id
printf '%s' "${SECRET_ID}" > .honey-starter/identity/secret_id
chmod 600 .honey-starter/identity/role_id .honey-starter/identity/secret_id

# If start.sh runs as a non-root user (common on WSL / workstations): the files
# are host-user-owned, and root-without-caps cannot read 0600. chown them to
# root and keep 0600...
sudo chown 0:0 .honey-starter/identity/role_id .honey-starter/identity/secret_id
chmod 600 .honey-starter/identity/role_id .honey-starter/identity/secret_id
# ...or, when sudo is unavailable, relax to 0644 (world-readable; acceptable
# only because the identity pair is scoped to read one Vault path and never
# the root token).
```

Use `printf '%s'` (no trailing newline — the entrypoint's `eval export`
command substitution strips trailing newlines anyway, but a file with a stray
newline is fragile against non-entrypoint consumers). Do **not** `echo`
secrets through shell history, and keep the root token and unseal key out of
shell history and terminal logs.

**Windows / WSL2 note.** Under Docker Desktop's WSL2 backend, a bind mount
from the WSL filesystem preserves the WSL uid (typically 1000) and mode, and
container-root is **not** mapped to the host user for permission purposes on
the Linux side — so the `cap_drop` rule above applies verbatim: `0600` files
owned by the WSL user are unreadable by the daemon's root-without-caps
process. If you run the smoke/E2E (or start.sh) as a non-root WSL user, use the
`0644` (smoke) / `chown 0:0` (production) forms above. Running as root in WSL
(`sudo make smoke`) works with `0600`, but a non-root run is the common case
and is exactly what the smoke's `0644` accommodates.

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
`scripts/start.sh` owns the real render for deployments.

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
    `secrets/data/<ns>/daemon` (write denied; a **decoy** secret seeded at
    `secrets/data/other/secret` makes the out-of-scope read a genuine
    permission-denied rather than a vacuous 404)
  * the UI serves HTTP 200

  The smoke re-implements the provisioning sequence inline so it exercises the
  *deployment* (compose file, image entrypoint, vault driver wiring) directly.
* `make e2e` — `test/e2e.sh`, the end-to-end test that boots the stack
  through the **real `scripts/start.sh`** single-command path into a throwaway
  compose project and asserts the same trust chain (vault initialized +
  unsealed, KV v2 + AppRole enabled, policy scoped exactly, identity files
  present/readable, `/healthz` 200, admin bearer auth 200, anonymous denied,
  AppRole read-ok / write-denied / out-of-scope genuine 403 with the decoy
  trick, UI 200). Because it drives `start.sh` itself, it also exercises the
  idempotent re-run path and the identity-file permission handling.

Both gates skip cleanly (exit 0) when docker is unavailable, so they must be
re-run on a docker-enabled host before merge.

## Customization knobs

| Env | Default | Meaning |
|-----|---------|---------|
| `HD_STATE_DIR` | `<repo>/.honey-starter` | rendered config + identity + root token/unseal key + admin token base dir (absolute) |
| `HONEY_NS` | `starter` | Vault KV namespace prefix baked into config + seed paths; single path segment; must stay constant after first run |
| `HONEY_USER` | `admin` | admin subject bound to the casbin `editor` role; must stay constant after first run |
| `HONEY_VAULT_KEY_SHARES` | `1` | Vault unseal key shares used on first init (see "Single-command bring-up") |
| `HONEY_VAULT_KEY_THRESHOLD` | `1` | Vault unseal key threshold used on first init |
| `OPENAI_API_KEY` | unset | AI key seeded into Vault on first run (placeholder stored when unset; replace by exporting + re-running `make start`) |
| `OPENROUTER_API_KEY` | unset | AI key seeded into Vault on first run (placeholder stored when unset) |
| `HD_API_HOST_PORT` | `9000` | host port for daemon API |
| `HD_UI_HOST_PORT` | `8090` | host port for UI |
| `HD_API_PORT` | `9000` | daemon API container port (also feeds listener template) |
| `HD_UI_URL` | `http://localhost:8090` | public UI base URL (OAuth/SAML redirects) |
| `HD_AI_BASE_URL` | `https://api.openai.com/v1` | non-secret AI base URL override (template `.env.AI_BASE_URL`) |
| `HD_AI_MODEL` | `gpt-5.4-mini` | non-secret AI model override (template `.env.AI_MODEL`) |
| `HD_CONFIG_CHECK_INTERVAL` | `30m` | daemon config watch interval (deliberate tradeoff — see "Config reload behavior") |
| `HD_JWT_SIGNING_KEY` | empty | API session-token signing key (optional; prefer `hd-lookup:` Vault form) |
| `HONEYDIPPER_IMAGE` | pinned build | daemon image tag |
| `VALKEY_IMAGE` | `valkey/valkey:8.1.0` | valkey image tag |
| `VAULT_IMAGE` | `hashicorp/vault:1.21.1` | vault image tag |
| `HD_UI_IMAGE` | pinned build | UI image tag |

`HONEY_NS`, `HONEY_USER`, `HONEY_VAULT_KEY_*` and the AI keys are read by
`scripts/start.sh` from the repo-root `.env` (or the shell). The AI keys are
provisioning inputs only — start.sh writes them into Vault and they never
appear in compose/environment at runtime. Set the AI keys in `.env` with
chmod 600 on that file (`.env` is gitignored).

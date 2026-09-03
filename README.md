# honey-starter

Single-command starter to spin up a [Honeydipper](https://github.com/honeydipper/honeydipper) instance with a web UI on a Linux docker-enabled host or workstation.

> **Phase 2 (current):** container deployment (docker-compose: valkey, vault,
> daemon, ui) with Vault-backed secrets and a full-stack smoke test. The
> `scripts/start.sh` orchestration/lifecycle automation lands in Phase 3; the
> docker-compose deployment in `deploy/` is already runnable today (see
> `deploy/README.md`).

## Requirements

- **Docker** (with compose v2) — for running the stack and the configcheck/smoke gates
- **htpasswd** (from `apache2-utils`) — **required**. Used to generate and
  validate bcrypt token hashes for the `auth-simple` driver and the B1
  validation contract. No Go toolchain is needed.
- **shellcheck** — required by the `make lint` / `make validate` gate.
- **bash**, **openssl**, **curl**, **jq** — basic scripting, key generation,
  and the smoke test

## What It Ships

The starter composes a trimmed-down Honeydipper deployment on top of
[honeydipper-config-essentials](https://github.com/honeydipper/honeydipper-config-essentials) (v4-rc branch):

- **Valkey** (Redis-compatible) for event bus, locks, scheduling, and caching
- **Vault** for secrets management (file backend, non-dev, AppRole access)
- **Honeydipper daemon** with engine, receiver, operator, API, and agent services
- **AI model driver** (remote, from the charles-gh-pages registry) with OpenAI-compatible engines
- **Honeydipper UI** (from [Charles546/hd-ui](https://github.com/Charles546/hd-ui))

## Secret lifecycle

> Put secrets in Vault. The only secret material needed outside Vault is the
> AppRole identity pair used to *reach* Vault.

- The daemon **never** receives the Vault root token. It authenticates with an
  AppRole role whose policy is **read-only and scoped exactly** to
  `secrets/data/<ns>/daemon`.
- The admin API token hash and the AI engine API keys live in Vault and are
  resolved at config-load time via `LOOKUP[vault,...]` references through the
  vault driver subprocess (which inherits the daemon's AppRole environment).
- The AppRole `role_id`/`secret_id` are written by start.sh (Phase 3) into
  `.honey-starter/identity/` and mounted into the daemon read-only. The
  compose file references them as `hd-secret-file://identity/...`, which the
  image entrypoint materializes before exec — the values never appear in the
  compose file.
- Optional process env secrets (e.g. `HD_JWT_SIGNING_KEY`, read via
  `os.Getenv`) can be kept inside Vault too by setting them as
  `hd-lookup:vault:/secrets/data/<ns>/daemon#<key>` values — the
  `HD_SECURE_LOADER` exec-mode resolves them before the daemon process starts
  (see `deploy/README.md` → `HD_JWT_SIGNING_KEY`).

See `deploy/README.md` → *Vault* for the full mechanism and the three
environment namespaces (`HD_*` template-fed, plain env, `hd-secret-file://`).

## Quick start (docker-compose)

The deployment lives in `deploy/` and is documented in `deploy/README.md`.
Bring-up is two-phase because Vault starts sealed and the daemon resolves
Vault secrets at boot:

```bash
# 1) render config (see deploy/README.md; Phase 3 automates this)
# 2) infrastructure
docker compose -f deploy/docker-compose.yaml up -d valkey vault
# 3) initialize/unseal vault + seed secrets
#    Vault is unreachable from the host by network design — every step uses
#    `docker compose exec vault vault ...` (helpers in scripts/lib.sh).
#    Phase 3 (scripts/start.sh) automates this.
# 4) application
docker compose -f deploy/docker-compose.yaml up -d daemon ui
```

Then open `http://localhost:8090` for the UI and `http://localhost:9000/healthz`
for the daemon health check. See `deploy/README.md` → *Vault reachability
contract* for the host→Vault access model.

## Validation

The validation gate runs with one command:

```bash
make validate   # = lint + check-bcrypt + check-config + compose-config + smoke
```

`make all` runs the same set. The gates map to the trust-critical contracts
and their environment needs:

| Gate | What it does | Needs |
|------|--------------|-------|
| `make lint` | shellcheck over `scripts/*.sh` and `test/*.sh` | none (no docker) |
| `make check-bcrypt` | B1: bcrypt token-hash contract via htpasswd | htpasswd (no docker) |
| `make check-config` | B2: `honeydipper configcheck` via docker image | docker + network |
| `make compose-config` | C1: `docker compose config` validation | docker (compose v2) |
| `make smoke` | C2: full-stack compose smoke (valkey+vault+daemon+ui) | docker + network |

### lint — shellcheck gate (no docker)

```bash
make lint   # shellcheck -x -P SCRIPTDIR scripts/*.sh test/*.sh
```

All project bash scripts must pass shellcheck. Run it directly with
`shellcheck -x -P SCRIPTDIR scripts/*.sh test/*.sh` from the repo root.

### B1 — bcrypt token contract (htpasswd)

```bash
bash test/check-bcrypt.sh
```

Confirms that `htpasswd -bnBC 12` output (`$2y$` prefix) is accepted by
`htpasswd -vb` round-trip. This validates the same hash format that the
`auth-simple` driver's `bcrypt.CompareHashAndPassword` call accepts.

Requires: `htpasswd` (from `apache2-utils`).

### B2 — configcheck contract (docker)

```bash
bash test/check-config.sh
```

Assembles the bootstrap config (essentials v4-rc + starter overrides),
substitutes the `<ns>`/`<user>` placeholders, and runs
`honeydipper configcheck` inside the published Docker image with
`CHECK_REMOTE=1`, asserting a clean exit. This validates workflows,
contexts, driver references, and the casbin authorization tests in
`bootstrap/tests/api_auth_tests.yaml`.

Requires: docker + network. The check is docker-gated: it skips gracefully
(exit 0) when docker is unavailable, so it should be re-run on a
docker-enabled host before merge.

### C1 — compose config validation (docker)

```bash
bash test/compose-config.sh
```

Validates `deploy/docker-compose.yaml` with `docker compose config`,
catching schema/interpolation errors without starting containers.
Docker-gated (skips cleanly when docker is unavailable).

### C2 — full-stack smoke test (docker + network)

```bash
bash test/smoke-stack.sh
```

Boots the whole compose stack in a throwaway project: initializes and unseals
Vault, enables KV v2 + AppRole with a read-only path-scoped policy, seeds the
namespace secrets **plus a decoy secret outside the AppRole scope**, boots
daemon + ui, and asserts the trust chain end to end: `/healthz` 200, admin
bearer-token auth, anonymous denial, AppRole write denial and a genuine
permission-denied (not a vacuous 404) on an out-of-scope read, and UI 200.
See `deploy/README.md` → *Validation* for details.

Docker-gated (skips cleanly when docker is unavailable), so re-run on a
docker-enabled host before merge.

## Bootstrap Config

The `bootstrap/` directory is the Honeydipper bootstrap config repo. To boot a
daemon, point the `REPO` environment variable at its absolute path (local
development) or at a git URL (production).

Key files:

| File | Purpose |
|------|---------|
| `bootstrap/init.yaml` | Entry point; includes essentials and all starter files |
| `bootstrap/daemon.yaml` | Core driver connections (Valkey, Vault, registry) |
| `bootstrap/auth.yaml` | API auth configuration (casbin + auth-simple tokens) |
| `bootstrap/engines.yaml` | AI engine definitions (openai, openrouter) |
| `bootstrap/agents.yaml` | Agent definitions (starter agent) |
| `bootstrap/contexts.yaml` | Workflow contexts |
| `bootstrap/stubs/compat.yaml` | Compatibility stubs for disabled integrations |
| `bootstrap/tests/api_auth_tests.yaml` | Authorization contract tests |

### Template environment contract

The config loader exposes **only** env vars prefixed `HD_` to `{% .env.X %}`
templates, with the prefix stripped (`HD_UI_URL` → `.env.UI_URL`). Plain env
vars (`REPO`, `LOCALREDIS`, `VAULT_*`, ...) are consumed directly by
binaries and are **not** visible to templates. See `deploy/README.md` →
*Environment namespaces*.

### Config reload behavior

The daemon runs a `Watch()` loop that, every `configCheckInterval`,
calls `Refresh()` and then, if the config changed, re-assembles and triggers
`OnChange()`. The bare (non-compose) default is `1m`; **the compose deployment
defaults `HD_CONFIG_CHECK_INTERVAL` to `30m`** (see below for why).

For a **local-dir init repo** (the `REPO` points at a local directory and
`BRANCH` is unset — exactly the compose deployment) `refreshRepo()` always
reloads and returns "changed", so the config is **re-assembled and reloaded
unconditionally every interval** — even if the files are byte-identical.
Because every reload re-resolves every Vault `LOOKUP` with a fresh AppRole
login, a `1m` interval would mean **per-minute AppRole churn**, and while
Vault is down, a **reload storm** (`/healthz` flaps to 500 until Vault
returns). `30m` is the shipped compose default as a deliberate tradeoff:
config/secret changes may take up to the interval to apply, in exchange for
bounded churn and reload-storm behavior. The interval stays env-tunable, and
once upstream gains fsnotify-backed reloads the per-minute default becomes
safe again. See `deploy/README.md` → *Config reload behavior* for the full
rationale and the **Vault outage behavior** description.

Practical consequences:

- **Prefer atomic writes when editing a live config:** write to a temp file
  and `mv` it into place. If the daemon re-assembles mid-write (partial
  YAML), the config load panics and the daemon **rolls back to the last
  running config** (`Config.RollBack()`); an atomic `mv` avoids the partial
  read entirely.
- **To opt out of periodic reloads entirely**, set
  `daemon.watchConfig: false` in `bootstrap/daemon.yaml`; config/secret
  changes then require `docker compose restart daemon`. The default is `true`
  (watch enabled).

### Supply chain and network

There are two distinct kinds of upstream artifacts, and they come from
different places:

- **Config repos (git):** the init repo (`honey-starter` itself) and
  `honeydipper-config-essentials` (pinned to branch `v4-rc`, fetched via
  `git` during config load/`configcheck`). The workflow/context/agent
  definitions, the essentials API-auth model, and the AI *engines* (model,
  base URL) all come from these git config repos.
  `v4-rc` is a **moving branch**, and the honeydipper repo schema supports
  branch references only (no commit-hash pin field), so an upstream change to
  `v4-rc` can alter what `configcheck`/a fresh daemon loads. If you need a
  fully deterministic essentials config, fork the essentials repo (or vendor
  a local copy) and point `bootstrap/init.yaml` at your fork/branch.
- **Driver binary registry (HTTPS):** the `openai` **driver binary** is
  downloaded from the remote driver registry
  `https://charles546.github.io/honeydipper-registry`, pinned to the
  `stable` channel (`daemon.registries.charles-gh-pages` +
  `daemon.drivers.openai.handlerData.channel: stable` in
  `bootstrap/daemon.yaml`).

A first start therefore needs outbound HTTPS to **github.com /
raw.githubusercontent.com** (config repos) **and**
**charles546.github.io** (driver binary registry) — plus, once the AI agent
actually makes model calls, outbound access to the **AI endpoint** the
configured engine points at (e.g. `https://api.openai.com/v1`, or your
`AI_BASE_URL`). The `channel: stable` pin means the driver binary only
changes when the registry's stable channel is updated deliberately. In the
compose deployment these egress requirements belong to the `edge` network
(`daemon` and `ui`); the backend `data-vault` / `data-valkey` networks are internal and reachable only from the daemon (see `deploy/README.md`).

### Enabling/disabling integrations

Integration toggles are set in `bootstrap/init.yaml` under the essentials repo
`options:`. The starter default keeps the core stack (Vault + AI) and disables
GitHub/Slack/Kubernetes. When you re-enable an integration, remove the
corresponding `without_*` option **and** drop the now-unneeded compatibility
stub from `includes:` (see `bootstrap/stubs/compat.yaml`).

## License

MIT

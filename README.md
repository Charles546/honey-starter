# honey-starter

Single-command starter to spin up a [Honeydipper](https://github.com/honeydipper/honeydipper) instance with a web UI on a Linux docker-enabled host or workstation.

> **Single-command deployment:** `make start` (`scripts/start.sh`) brings up
> valkey, a file-backed Vault (initialized + unsealed + seeded), the
> Honeydipper daemon, and the UI on a Linux docker host with one command.
> Lifecycle: `make stop | down | status | logs`. Deployment details in
> `deploy/README.md`.

## Install in one line

On a bare Linux Docker host — no repo present beforehand, no host git needed, no
need to read this README first:

```bash
curl -fsSL https://raw.githubusercontent.com/Charles546/honey-starter/main/scripts/setup.sh | bash
```

`scripts/setup.sh` is the guided installer (Phase 4). The piped copy is a
self-contained bootstrap: it runs a fail-fast preflight (Linux, bash 4+, curl +
tar, docker + compose v2 + a reachable daemon — a host with no viable docker is
never prompted and never triggers a download), resolves the install directory,
downloads the release tarball from codeload, verifies the layout, extracts it
atomically into `~/honey-starter` (or `$HONEY_STARTER_INSTALL_DIR`), and
re-execs the on-disk copy. The on-disk copy then runs a short guided
questionnaire, writes the repo-root `.env` (chmod 600) and delegates to
`scripts/start.sh` — the same idempotent single-command bring-up as `make
start` below.

### Multiple instances: setup.sh <dir> (Phase 5)

The same command SETS UP a NEW instance at a given directory or RE-SETS UP
(manages) an EXISTING instance. Multiple instances coexist as **separate
directories** with their own ports; to run two simultaneously, set distinct
`HD_API_HOST_PORT`/`HD_UI_HOST_PORT` and an env-only `COMPOSE_PROJECT_NAME`
(export it before running — it is never stored in `.env`).

**Target selection (3 branches):**

1. **`<dir>` argument given** — operate on that directory. An EXISTING
   honey-starter instance there is re-set-up (managed) in place; otherwise a
   NEW instance is set up there.
2. **no `<dir>`, script inside a tree** — re-set-up that instance in place.
3. **no `<dir>`, standalone/piped** — `$HONEY_STARTER_INSTALL_DIR` or
   `~/honey-starter` (`HONEY_STARTER_INSTALL_DIR` is consulted ONLY in this
   branch; on-disk runs never read it — pass a parameter to target another
   instance).

```bash
curl -fsSL https://raw.githubusercontent.com/Charles546/honey-starter/main/scripts/setup.sh | bash -s /opt/honey-starter   # piped, explicit dir
bash scripts/setup.sh .            # from an existing install: manage it in place
bash scripts/setup.sh new-proj     # set up a NEW instance in ./new-proj
```

**New vs existing:** an existing instance (layout incl. `scripts/setup.sh`) is
managed in place — its `.env` prefills the questionnaire and its
`HONEY_NS`/`HONEY_USER` provision guards apply. A pre-Phase-4 tree (layout
present, no `setup.sh`) is merged over in place. An absent or empty directory
gets a NEW instance: an on-disk run **copies** the invoked tree (the source
keeps running; a fresh target never inherits `.git`/`.env`/`.honey-starter`, so
it cannot clone the source deployment's secrets/state — intentional); a piped
run downloads the release. A non-empty directory that is not a honey-starter
tree makes setup.sh die "not a honey-starter tree" (never destructive) — e.g.
`curl ... | bash -s .` from a non-empty non-instance dir dies with that message;
run it from an empty dir or pass an existing/empty path instead.

**`--update`:** `bash scripts/setup.sh --update` re-extracts the release over
the target tree (tar merges; then run in place).

**The single bootstrap prompt (exception):** the piped bootstrap copy normally
never prompts, but when it has no `<dir>`, no `HONEY_STARTER_INSTALL_DIR`, no
`HONEY_STARTER_ANSWERS_FILE`, is not non-interactive, and a real `/dev/tty` is
available, it asks exactly one question — `Install directory [~/honey-starter]`
(Enter accepts the default) — **after** the fail-fast preflight and **before**
the download. A host with no viable docker is never prompted. Every other
question is asked only by the on-disk copy.

**Rolling-`main` caveat:** the one-liner tracks `main`, so it is exactly as
current as the merge state of this repository. To pin an install, set
`HONEY_STARTER_REF` to a branch or tag and optionally pin the tarball hash:

```bash
curl -fsSL https://raw.githubusercontent.com/Charles546/honey-starter/main/scripts/setup.sh \
  | HONEY_STARTER_REF=<branch-or-tag> HONEY_STARTER_EXPECT_SHA256=<sha256> bash
```

**Non-interactive contract:** set `HONEY_STARTER_NONINTERACTIVE=1` and supply
the decision variables via the environment (see
`bash scripts/setup.sh --help` for the full list, the AI provider matrix, the
new `HD_AI_MODEL` question and the `HONEY_STARTER_ANSWERS_FILE` replay option).
Re-running on an existing install skips the download and reuses the tree in
place.

Questionnaire scope: the interactive AI provider prompt offers **openai**
(default) | **custom** (OpenAI-compatible endpoint) | **skip** only —
`openrouter` is never offered interactively (see
`deploy/README.md` → *Guided install (setup.sh)* for the OpenRouter note).
For openai/custom, setup.sh also asks **AI model** (`HD_AI_MODEL`, default
`gpt-5.4-mini` — the pin; see `--help` for the three-way
`HD_AI_MODEL=`/`HD_AI_MODEL=<value>`/unset semantics and the no-pin path).

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

> Put secrets in Vault. The only secret material outside Vault is what is
> needed to *reach* and *operate* Vault: the AppRole identity pair (mounted
> into the daemon), and the host-only Vault root token / unseal key(s) that
> `start.sh` keeps in `.honey-starter/` (chmod 600, never mounted). The admin
> bearer token is also persisted there (chmod 600) so re-runs reuse it; only
> its bcrypt hash lives in Vault.

- The daemon **never** receives the Vault root token. It authenticates with an
  AppRole role whose policy is **read-only and scoped exactly** to
  `secrets/data/<ns>/daemon`.
- The admin API token hash and the AI engine API keys live in Vault and are
  resolved at config-load time via `LOOKUP[vault,...]` references through the
  vault driver subprocess (which inherits the daemon's AppRole environment).
- The AppRole `role_id`/`secret_id` are written by start.sh into
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

## Quick start (single command)

```bash
make start        # or: bash scripts/start.sh
```

`start.sh` brings up the whole stack on a Linux docker host with one command.
It is **idempotent and safe to re-run**:

1. **Preflight** — Linux-only guard; requires `docker` + compose v2, `curl`,
   `jq`, `openssl`, `htpasswd`; best-effort host-port conflict check for the
   published API/UI ports.
2. **Load `.env`** (repo root) if present, honoring the documented env
   contract (`HD_*` template-fed, plain env direct, `HD_STATE_DIR`,
   `COMPOSE_FILE`).
3. **Render config** — `bootstrap/` is copied into
   `.honey-starter/config/` with the `<ns>`/`<user>` placeholders substituted
   (env `HONEY_NS`, default `starter`; `HONEY_USER`, default `admin`).
4. **Infrastructure** — start valkey + vault; wait for the vault API.
5. **Vault (first run only)** — initialize (root token + unseal keys persisted
   to `.honey-starter/` chmod 600, host-only), unseal, enable KV v2 at
   `secrets/` + AppRole, write the read-only `daemon-read` policy scoped
   exactly to `secrets/data/<ns>/daemon`, create the AppRole role, write the
   identity pair into `.honey-starter/identity/`, and seed
   `secrets/<ns>/daemon` with the admin token hash (htpasswd bcrypt) + AI API
   keys.
6. **Application** — start daemon + ui; wait for `/healthz` 200.
7. **Summary** — UI URL, API URL, and the admin token (printed once on first
   run; persisted at `.honey-starter/admin_token` chmod 600 for re-runs).

On re-runs Vault is detected as already initialized/unsealed, identity and
secrets are reused (never clobbered), and the script converges to the same
healthy stack. After a host reboot / `docker compose restart`, `make start`
re-unseals Vault with the persisted keys.

Then open `http://localhost:8090` for the UI and use the printed admin token to
log in. `http://localhost:9000/healthz` is the daemon health check.

See `deploy/README.md` → *Vault reachability contract* for the host→Vault
access model, and *Bring-up sequence* for the underlying two-phase design that
`start.sh` automates.

### File permissions: the cap_drop / CAP_DAC_OVERRIDE rule (read before first start)

The daemon container runs as **root without capabilities** (`cap_drop: [ALL]`
removes `CAP_DAC_OVERRIDE`), so root-in-container obeys normal file
permissions and **cannot read `0600` bind-mount files owned by your host
user**. `start.sh` handles this for you:

- the bind-mounted `config/` and `identity/` directories are normalized so the
  container can read them (`chmod 755` dirs; config files world-readable);
- AppRole identity files are written `0600` + `chown 0:0` (root-owned) when
  `start.sh` can act as root (running as root or with passwordless sudo), and
  `0644` otherwise (never the root token — only the AppRole pair scoped to
  read one Vault path).

**Windows / WSL2 note.** Under Docker Desktop's WSL2 backend, bind mounts
preserve the WSL uid (typically 1000) and mode, and container-root is *not*
mapped to the host user for permission checks — so a `0600` file owned by your
WSL user is unreadable by the daemon. Run `start.sh` as root (`sudo make
start`) or with sudo available so it can write root-owned `0600` identity
files. Also remember that WSL2 localhost networking means `localhost:8090` /
`localhost:9000` reach the published ports on the host. Full details:
`deploy/README.md` → *Hardening notes* and *Identity-file hygiene (host
side)*.

## Lifecycle

Once the stack is running, manage it with the lifecycle scripts (also wired
into the Makefile):

| Command | What it does |
|---------|--------------|
| `make start` | bring everything up (idempotent; also re-unseals Vault after a reboot/restart) |
| `make stop` | graceful stop; containers stopped, volumes + `.honey-starter/` preserved |
| `make down` | full teardown; containers + default networks removed, named volumes + `.honey-starter/` preserved |
| `make down-volumes` | teardown that also deletes the named volumes (wipes Vault file backend + valkey data) |
| `make status` | compose ps + daemon `/healthz` + vault seal status + UI reachability |
| `make logs` | follow the daemon logs (`make logs ui` for the UI, extra args pass through) |

`down` and `stop` never touch `.honey-starter/` (root token/unseal key, admin
token, identity files, rendered config). To reset a deployment completely:
`make down-volumes`, then `rm -rf .honey-starter/`.

## Validation

The validation gate runs with one command:

```bash
make validate   # = lint + check-bcrypt + setup-dryrun + check-config + compose-config + smoke + e2e + setup-e2e
```

`make all` runs the same set. The gates map to the trust-critical contracts
and their environment needs:

| Gate | What it does | Needs |
|------|--------------|-------|
| `make lint` | shellcheck over `scripts/*.sh` and `test/*.sh` | none (no docker) |
| `make check-bcrypt` | B1: bcrypt token-hash contract via htpasswd | htpasswd (no docker) |
| `make setup-dryrun` | P4-DRYRUN: hermetic tests for `scripts/setup.sh` (`.env` write/round-trip, quoting, masking, validation paths, answers-file branch) | none (no docker) |
| `make check-config` | B2: `honeydipper configcheck` via docker image | docker + network |
| `make compose-config` | C1: `docker compose config` validation | docker (compose v2) |
| `make smoke` | C2: full-stack compose smoke (valkey+vault+daemon+ui) | docker + network |
| `make e2e` | C3: E2E through the real `scripts/start.sh` path | docker + network |
| `make setup-e2e` | P4-E2E: E2E through the real `scripts/setup.sh` guided-installer path (`.env` + delegate to `start.sh`) | docker + network |

The docker-gated gates (check-config, compose-config, smoke, e2e, setup-e2e)
skip cleanly (exit 0) when docker is unavailable, so they should be re-run on
a docker-enabled host before merge.

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
The smoke re-implements the provisioning sequence inline to test the
*deployment* itself. See `deploy/README.md` → *Validation* for details.

Docker-gated (skips cleanly when docker is unavailable), so re-run on a
docker-enabled host before merge.

### C3 — end-to-end test through start.sh (docker + network)

```bash
bash test/e2e.sh
```

Boots the stack through the **real `scripts/start.sh`** single-command path
into a throwaway compose project (`HD_STATE_DIR` in a mktemp dir, high host
ports) and verifies the full trust chain: Vault initialized + unsealed, KV v2
+ AppRole enabled, policy scoped exactly, identity files present/readable,
daemon `/healthz` 200 (proving every Vault LOOKUP resolved), admin bearer auth
200, anonymous denied, AppRole read-ok / write-denied / out-of-scope genuine
403 (with the decoy-secret trick), UI 200. Because it drives start.sh itself,
it also exercises the idempotent re-run path.

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

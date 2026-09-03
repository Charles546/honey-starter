# honey-starter

Single-command starter to spin up a [Honeydipper](https://github.com/honeydipper/honeydipper) instance with a web UI on a Linux docker-enabled host or workstation.

> **Phase 1 (current):** repository scaffold, bootstrap config templates, and
> trust-critical validation (bcrypt token contract, `configcheck` contract).
> The `docker-compose` deployment and `scripts/start.sh` land in Phase 2; the
> config in `bootstrap/` can already be used to boot a daemon by pointing
> `REPO` at it.

## Requirements

- **Docker** — for running the daemon image (configcheck, and later deployment)
- **htpasswd** (from `apache2-utils`) — **required**. Used to generate and
  validate bcrypt token hashes for the `auth-simple` driver and the B1
  validation contract. No Go toolchain is needed.
- **shellcheck** — required by the `make lint` / `make validate` gate.
- **bash**, **openssl** — basic scripting and key generation

## What It Ships

The starter composes a trimmed-down Honeydipper deployment on top of
[honeydipper-config-essentials](https://github.com/honeydipper/honeydipper-config-essentials) (v4-rc branch):

- **Valkey** (Redis-compatible) for event bus, locks, scheduling, and caching
- **Vault** for secrets management
- **Honeydipper daemon** with engine, receiver, operator, API, and agent services
- **AI model driver** (remote, from the charles-gh-pages registry) with OpenAI-compatible engines
- **Honeydipper UI** (optional, from [Charles546/hd-ui](https://github.com/Charles546/hd-ui), Phase 2)

## Validation

The Phase 1 validation gate runs with one command:

```bash
make validate   # = lint + check-bcrypt + check-config
```

`make all` runs the same set. The three gates map to the trust-critical
contracts and their environment needs:

| Gate | What it does | Needs |
|------|--------------|-------|
| `make lint` | shellcheck over `scripts/*.sh` and `test/*.sh` | none (no docker) |
| `make check-bcrypt` | B1: bcrypt token-hash contract via htpasswd | htpasswd (no docker) |
| `make check-config` | B2: `honeydipper configcheck` via docker image | docker + network |

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

### Config reload behavior

The daemon runs a `Watch()` loop that, every `configCheckInterval`
(explicitly `1m` in `bootstrap/daemon.yaml`), calls `Refresh()` and then, if
the config changed, re-assembles and triggers `OnChange()`. For a **local-dir
init repo** (the `REPO` points at a local directory and `BRANCH` is unset)
`refreshRepo()` always reloads and returns "changed", so the config is
**re-assembled and reloaded unconditionally every interval** — even if the
files are byte-identical. Two practical consequences:

- **Prefer atomic writes when editing a live config:** write to a temp file
  and `mv` it into place. If the daemon re-assembles mid-write (partial
  YAML), the config load panics and the daemon **rolls back to the last
  running config** (`Config.RollBack()`); an atomic `mv` avoids the partial
  read entirely.
- **To opt out of periodic reloads entirely**, set
  `daemon.watchConfig: false` in `bootstrap/daemon.yaml`. The default is
  `true` (watch enabled).

### Supply chain and network

There are two distinct kinds of upstream artifacts, and they come from
different places:

- **Config repos (git):** the init repo (`honey-starter` itself) and
  `honeydipper-config-essentials` (pinned to branch `v4-rc`, fetched via
  `git` during config load/`configcheck`). The workflow/context/agent
  definitions, the essentials API-auth model, and the AI *engines* (model,
  base URL) all come from these git config repos.
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
changes when the registry's stable channel is updated deliberately.

### Enabling/disabling integrations

Integration toggles are set in `bootstrap/init.yaml` under the essentials repo
`options:`. The starter default keeps the core stack (Vault + AI) and disables
GitHub/Slack/Kubernetes. When you re-enable an integration, remove the
corresponding `without_*` option **and** drop the now-unneeded compatibility
stub from `includes:` (see `bootstrap/stubs/compat.yaml`).

## License

MIT

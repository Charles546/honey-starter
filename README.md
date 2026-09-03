# honey-starter

Single-command starter to spin up a [Honeydipper](https://github.com/honeydipper/honeydipper) instance with a web UI on a Linux docker-enabled host or workstation.

> **Phase 1 (current):** repository scaffold, bootstrap config templates, and
> trust-critical validation (bcrypt token contract, `configcheck` contract).
> The `docker-compose` deployment and `scripts/start.sh` land in Phase 2; the
> config in `bootstrap/` can already be used to boot a daemon by pointing
> `REPO` at it.

## Requirements

- **Docker** — for running the daemon image (configcheck, and later deployment)
- **htpasswd** (from `apache2-utils`) — for generating and validating bcrypt
  token hashes (required by the `auth-simple` driver)
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

Both Phase 1 validation contracts run with one command:

```bash
make validate   # = check-bcrypt + check-config
```

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

Requires: docker.

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

### Enabling/disabling integrations

Integration toggles are set in `bootstrap/init.yaml` under the essentials repo
`options:`. The starter default keeps the core stack (Vault + AI) and disables
GitHub/Slack/Kubernetes. When you re-enable an integration, remove the
corresponding `without_*` option **and** drop the now-unneeded compatibility
stub from `includes:` (see `bootstrap/stubs/compat.yaml`).

## License

MIT

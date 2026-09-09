# 🍯 honey-starter

Single-command starter to spin up a [Honeydipper](https://github.com/honeydipper/honeydipper) instance with a web UI on a Linux or macOS docker-enabled host or workstation.

> 🚀 One command brings up **Valkey** (event bus + cache), a **file-backed Vault** (initialized + unsealed + seeded), the **Honeydipper daemon** (engine / receiver / operator / API / agent), and the **UI** on a Linux or macOS docker host: `make start`.

## 🚀 Quick start

**Bare docker host (Linux or macOS) — nothing to clone, no host git needed:**

```bash
curl -fsSL https://raw.githubusercontent.com/Charles546/honey-starter/main/scripts/setup.sh | bash
```

**Already cloned the repo?** The same idempotent bring-up, one command:

```bash
make start            # or: bash scripts/start.sh
```

What happens (safe to re-run — it converges):

1. **Preflight** — macOS/Linux, docker + compose v2, and the script tools are checked; a host with no viable docker is never prompted.
2. **Download & verify** — (piped install only) the release tarball is fetched, verified, and extracted to `~/honey-starter`; the questionnaire writes `.env` (chmod 600) and delegates to `start.sh`.
3. **Vault** — on first run: initialized + unsealed, AppRole identity written, secrets seeded; then Valkey + Vault start, followed by the daemon + UI.
4. **Summary** — UI + API URLs and the admin token.

```console
$ make start
🚀 === honey-starter: start ===
✅   [ok] Linux 6.8.0-45-generic
✅   [ok] docker compose v2
✅   [ok] docker
✅   [ok] curl
✅   [ok] jq
✅   [ok] openssl
✅   [ok] htpasswd
…
🚀 === honey-starter is up ===
ℹ UI:        http://localhost:8090
ℹ API:       http://localhost:9000/healthz
ℹ Admin token (generated now, printed once): ********************
```

Open **http://localhost:8090** and log in with the admin token (printed once on first run; re-runs point to where it is stored).

🔑 **Secrets:** AI keys + admin-token hash live in Vault; the only host-side secret material is what `start.sh` keeps in `.honey-starter/` (chmod 600). See [`deploy/README.md`](./deploy/README.md) → *Vault*.

## Install in one line

The guided installer (`scripts/setup.sh`) picks a target with a three-branch rule:

1. **`setup.sh <dir>`** — an existing honey-starter tree in `<dir>` is re-set-up (managed) in place; otherwise a NEW instance is set up there.
2. **`setup.sh` run from inside a tree** — re-set-up that instance in place.
3. **`setup.sh` piped / standalone** — installs to `$HONEY_STARTER_INSTALL_DIR` or `~/honey-starter`.

```bash
curl -fsSL https://raw.githubusercontent.com/Charles546/honey-starter/main/scripts/setup.sh | bash          # piped → ~/honey-starter
curl -fsSL https://raw.githubusercontent.com/Charles546/honey-starter/main/scripts/setup.sh | bash -s /opt/honey-starter
bash scripts/setup.sh .            # from an existing install: manage it in place
bash scripts/setup.sh new-proj     # set up a NEW instance in ./new-proj
```

`--update` re-extracts the release over the target tree (tar merges; never deletes). The one-liner tracks `main`, so it is exactly as current as this repo — to pin an install:

```bash
curl -fsSL https://raw.githubusercontent.com/Charles546/honey-starter/main/scripts/setup.sh \
  | HONEY_STARTER_REF=<branch-or-tag> HONEY_STARTER_EXPECT_SHA256=<sha256> bash
```

## ⚙️ Managing the stack

| Command | What it does |
|---|---|
| ▶️ `make start` | bring everything up (idempotent; re-unseals Vault after a host reboot) |
| ⏹️ `make stop` | graceful stop; containers stopped, volumes + `.honey-starter/` kept |
| 🗑️ `make down` | teardown; containers + default networks removed, volumes + `.honey-starter/` kept |
| 🗑️⚠️ `make down-volumes` | teardown that also deletes the named volumes (wipes Vault + valkey data) |
| 📊 `make status` | compose ps + daemon `/healthz` + vault seal status + UI reachability |
| 📜 `make logs` | follow the daemon logs |

Tail the UI instead: `bash scripts/logs.sh ui --tail=100` (extra args pass through to `docker compose logs`).

Full reset of a deployment: `make down-volumes && rm -rf .honey-starter`.

## 🧩 Multiple instances

Use **separate directories** with distinct ports (`HD_API_HOST_PORT` / `HD_UI_HOST_PORT`). Each instance gets its own persisted compose project (`hs-…`), so stacks run side by side without colliding.

> ⚠️ Renaming a provisioned instance's project re-initializes Vault and loses the old secrets — see [HONEYDIPPER.md](./HONEYDIPPER.md).

## 🤖 Automating

`setup.sh` and `start.sh` are fully scriptable — set `HONEY_STARTER_NONINTERACTIVE=1` and answer via the environment:

```bash
export HONEY_STARTER_NONINTERACTIVE=1
export HONEY_AI_PROVIDER=openai        # openai | custom | skip
export HD_AI_MODEL=gpt-5.4-mini
export OPENAI_API_KEY=sk-...
bash scripts/setup.sh
```

Replay a whole questionnaire from a file — `HONEY_STARTER_ANSWERS_FILE` (one answer per line; schema in [HONEYDIPPER.md](./HONEYDIPPER.md)). Preview without starting the stack: `bash scripts/setup.sh --dry-run` (preflight + questionnaire + masked `.env` preview, then stops).

## 🎨 Terminal experience

- **Rich output** — ✅ ❌ ⚠️ ℹ 🚀 glyphs + color when fd 1 is a real terminal with a color-capable `TERM` (e.g. `xterm-256color`).
- **Plain by default on pipes** — redirected logs, CI, and `TERM=dumb` always render plain (a redirected script never leaks escape bytes). Set `NO_COLOR` or `HONEY_STARTER_NO_COLOR` to any value — even empty — to force plain.
- **Menus & secrets** — provider/model questions pick by number, exact value, or Enter; API keys are masked with `*` and confirmed by a re-type. At the **model menu** (interactive/TTY only) a hint reminds you that you can **type any model directly** instead of choosing a number — a valid model string is adopted as-is (no re-prompt), so an unlisted model like `claude-opus-4-8` or `my-custom-model-2` works right from the menu. The hint is additive and never appears on piped/automated runs. Mechanics: [HONEYDIPPER.md](./HONEYDIPPER.md).

## 🧪 Requirements

- **Platforms:** Linux; or macOS 12+ on **Apple Silicon / arm64** only.
- **Docker** (with compose v2) — on Linux, Docker (or compatible); on macOS, **Docker Desktop** or **Rancher Desktop**.
- **Script tools:** bash ≥ 4, curl, tar, a sha256 digester (`sha256sum`, or `shasum`/`openssl`), jq, openssl, htpasswd. The installer auto-detects GNU vs BSD coreutils.
- **macOS:** ships **bash 3.2** by default — the scripts need bash ≥ 4, so install a newer bash: `brew install bash`. `htpasswd` comes from `brew install httpd`, but it is **not on PATH by default** (it lives at `$(brew --prefix httpd)/bin/htpasswd`) — the installer resolves it for you; keep `/opt/homebrew/bin` on your PATH.
- **Developers:** shellcheck → `make lint`; full gate → `make validate` (details: [`deploy/README.md`](./deploy/README.md) → *Validation*).
- **cap_drop / WSL2 (Linux):** the daemon runs as root-without-caps (`cap_drop: [ALL]`), so files it reads through bind mounts must be readable by root-without-caps; under WSL2 that includes WSL-owned files — run `sudo make start` (or keep sudo available). Details: [`deploy/README.md`](./deploy/README.md) → *Hardening notes*.

## 📖 More docs

- **HONEYDIPPER.md** — installer & UX engineering guidance: rich-output detection, menus, masked input, the non-interactive contract, testing gotchas, macOS gotchas.
- **deploy/README.md** — deployment & compose topology, Vault & **secrets** lifecycle, **bootstrap config** & config reload, **validation gates**, WSL2 details.
- **[MIT](./LICENSE)**

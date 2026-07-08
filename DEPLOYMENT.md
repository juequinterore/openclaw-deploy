# OpenClaw Deployment

A minimal, standalone deployment repo for OpenClaw — contains only our
configuration, not a clone of the upstream source tree. This works because
the deployment runs the official pre-built image and never builds from
source, so nothing besides `docker-compose.yml` itself needs to come from
upstream.

This is a companion to `docs.openclaw.ai`, not a replacement — it only
covers decisions and config specific to this instance.

## Repo structure

```
docker-compose.yml          # vendored from upstream, pinned to tag v2026.6.11
docker-compose.extra.yml    # our overrides: home volume, data-dir mounts, no ports
.env.example                # template — copy to .env and fill in
.gitignore                  # excludes .env and .openclaw-data/
DEPLOYMENT.md                # this file
```

No `Dockerfile`, no application source, nothing else — verified: `docker
compose up -d` works from a directory containing only the four files above,
because `OPENCLAW_IMAGE` is pinned and already resolvable by tag, so Compose
never touches the `build: .` fallback in `docker-compose.yml`.

## Summary of this setup

- Runs via **Docker Compose**, using the official pre-built image, pinned to
  a specific version (`ghcr.io/openclaw/openclaw:2026.6.11`) rather than
  `:latest` — see "Updating the image version" below.
- Agent execution runs through the **Claude Code CLI** (`claude-cli` runtime),
  authenticated via OAuth login, not a raw Anthropic API key.
- Default model: **`anthropic/claude-sonnet-4-6`**.
- Gateway is **loopback-only** — no inbound network exposure. Intended
  interaction modes are (1) Slack (outbound Socket Mode connection) and
  (2) local terminal access via `docker compose run openclaw-cli chat`.
- All state is project-local (`./.openclaw-data/`) and gitignored, so the
  checkout is portable without leaking secrets into git.

## First-time setup (fresh clone, new machine)

```bash
git clone <this-repo-url> openclaw-deploy
cd openclaw-deploy
cp .env.example .env
```

Then edit `.env`:
- Set `OPENCLAW_GATEWAY_TOKEN` (generate with `openssl rand -hex 32`).
- Uncomment and keep the `OPENCLAW_IMAGE`, `OPENCLAW_CONFIG_DIR`,
  `OPENCLAW_WORKSPACE_DIR`, `OPENCLAW_AUTH_PROFILE_SECRET_DIR`,
  `OPENCLAW_HOME_VOLUME`, `OPENCLAW_GATEWAY_BIND`, and `COMPOSE_FILE` lines
  as documented in `.env.example`.

```bash
docker compose pull openclaw-gateway
```

Create the base config first — the gateway refuses to start (crash-loops)
until `openclaw.json` exists:
```bash
docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js onboard --mode local --no-install-daemon \
  --non-interactive --accept-risk --auth-choice skip \
  --gateway-bind loopback --skip-channels --skip-skills --skip-hooks --skip-search --skip-health

docker compose up -d openclaw-gateway
docker compose ps   # expect "healthy"
```

Then wire up the Claude CLI (no API key involved — this is an interactive
OAuth login, so it must be run by a human in a real terminal):
```bash
docker compose run --rm --entrypoint sh openclaw-cli -lc \
  'curl -fsSL https://claude.ai/install.sh | bash'
docker compose run --rm -it --entrypoint sh openclaw-cli -lc \
  '/home/node/.local/bin/claude auth login'
docker compose run --rm openclaw-cli config set \
  agents.defaults.cliBackends.claude-cli.command /home/node/.local/bin/claude
```

Then run onboarding to wire the agent runtime to the now-authenticated CLI:
```bash
docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js onboard --mode local --no-install-daemon \
  --non-interactive --accept-risk --auth-choice anthropic-cli \
  --gateway-bind loopback --skip-channels --skip-skills --skip-hooks --skip-search --skip-health
docker compose run --rm openclaw-cli config set agents.defaults.model.primary anthropic/claude-sonnet-4-6
docker compose restart openclaw-gateway
```

Verify end-to-end:
```bash
docker compose run --rm --entrypoint node openclaw-cli dist/index.js agent \
  --agent main --message "ping" --json --timeout 60
```
Check `executionTrace.winnerProvider` in the output — it should read
`"claude-cli"`, confirming the agent is actually executing through the
Claude CLI.

## Running it day to day

`COMPOSE_FILE` is set in `.env`, so `docker compose` always picks up both
compose files automatically — no `-f` flags needed.

**Start:**
```bash
docker compose up -d openclaw-gateway
```

**Check status:**
```bash
docker compose ps
docker compose logs openclaw-gateway --tail 20
```
Look for `agent model: anthropic/claude-sonnet-4-6` and `ready` in the logs,
and `healthy` in `docker compose ps`.

**Restart (clean stop/recreate):**
```bash
docker compose down openclaw-gateway
docker compose up -d openclaw-gateway
```
A plain `docker compose restart openclaw-gateway` also works for picking up
config changes (most config is hot-reloaded anyway; restarting just
guarantees a fresh read).

**Stop:**
```bash
docker compose down
```
This does not delete `.openclaw-data/` or the `openclaw_home` volume — your
config, sessions, and Claude CLI login all survive.

**Interactive terminal chat:**
```bash
docker compose run --rm -it openclaw-cli chat
```
Connects to the running gateway over the shared network namespace (no
published ports required). Default session key is `main`; use
`--session <name>` to start/resume a different one.

Note: a session's model is pinned at creation time and doesn't follow later
default-model changes — if you change `agents.defaults.model.primary`, use a
new `--session` name to actually get the new model, or delete the old
session's entry from
`.openclaw-data/config/agents/main/sessions/sessions.json`.

**Admin/config commands** generally look like:
```bash
docker compose run --rm openclaw-cli config get agents.defaults.model
docker compose run --rm openclaw-cli config set <path> <value>
docker compose run --rm openclaw-cli agents list
docker compose run --rm openclaw-cli sessions list
```

**Running an arbitrary shell command inside the container** (e.g. to invoke
the `claude` binary directly) requires overriding the entrypoint, since
`openclaw-cli`'s default entrypoint is the OpenClaw CLI itself:
```bash
docker compose run --rm --entrypoint sh openclaw-cli -lc '<command>'
```

## Configuration reference

### `.env`

```bash
OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:2026.6.11   # pinned version, not :latest
OPENCLAW_CONFIG_DIR=./.openclaw-data/config
OPENCLAW_WORKSPACE_DIR=./.openclaw-data/workspace
OPENCLAW_AUTH_PROFILE_SECRET_DIR=./.openclaw-data/auth-secrets
OPENCLAW_HOME_VOLUME=openclaw_home                   # persists Claude CLI install+login
OPENCLAW_GATEWAY_BIND=loopback                       # no inbound network exposure
OPENCLAW_GATEWAY_TOKEN=<generate with: openssl rand -hex 32>
COMPOSE_FILE=docker-compose.yml:docker-compose.extra.yml
```
Provider API keys (`ANTHROPIC_API_KEY` etc., near the top of `.env.example`)
are left commented out on purpose — auth flows through the Claude CLI's own
OAuth session instead.

### `docker-compose.extra.yml`

Adds, on top of the vendored base compose file:
- `openclaw_home:/home/node` (named volume) on both services, so the Claude
  CLI install and its credentials survive container recreation.
- Explicit bind mounts for config/workspace/auth-secrets pointing at
  `./.openclaw-data/...` (project-local instead of `~/.openclaw`).
- `ports: !reset []` on `openclaw-gateway` — clears the base file's port
  publishing. With `gateway.bind: loopback`, the app only listens on the
  container's own network-namespace loopback, which a host port-publish
  can't reach anyway (Docker forwards to the container's non-loopback
  interface) — so publishing is both unreachable and unnecessary here.

### `openclaw.json` (inside `.openclaw-data/config/`, not hand-edited directly)

Key settings, set via `openclaw config set` / `onboard`:
- `agents.defaults.model.primary`: `"anthropic/claude-sonnet-4-6"`
- `agents.defaults.models["anthropic/claude-sonnet-4-6"].agentRuntime.id`:
  `"claude-cli"` — this is what routes execution through the CLI instead of
  a direct API call.
- `agents.defaults.cliBackends.claude-cli.command`:
  `"/home/node/.local/bin/claude"`
- `gateway.mode`: `"local"`, `gateway.bind`: `"loopback"`

To switch the default model:
```bash
docker compose run --rm openclaw-cli config set agents.defaults.model.primary anthropic/claude-opus-4-8
docker compose restart openclaw-gateway
```
(Then use a fresh `--session` name to actually see the new model in the TUI —
see the note above.)

## What to reconfigure on a different computer

A fresh `git clone` of this repo carries the compose files and `.env.example`
automatically, but a few things don't travel with git and need to be
regenerated or re-supplied on each machine:

1. **`.env`** — gitignored (never in git at all). Create it from
   `.env.example` and fill in the values above.
2. **`.openclaw-data/`** — gitignored. Either copy it from another machine if
   you want to carry over config/sessions/history, or omit it and run
   onboarding fresh (see "First-time setup" above).
3. **The `openclaw_home` Docker volume** — a *named volume*, local to the
   Docker daemon it was created on. It does **not** transfer via `git clone`
   or a file copy. Re-authenticate from scratch on the new machine (the
   "First-time setup" commands above), or migrate the volume's contents:
   ```bash
   # on the old machine
   docker run --rm -v openclaw_home:/v -v "$PWD":/backup alpine \
     tar czf /backup/openclaw_home.tgz -C /v .
   # copy openclaw_home.tgz to the new machine, then:
   docker volume create openclaw_home
   docker run --rm -v openclaw_home:/v -v "$PWD":/backup alpine \
     tar xzf /backup/openclaw_home.tgz -C /v
   ```
4. **Docker + Compose v2** must be installed on the new machine.
5. If the new machine needs *inbound* access (e.g. laptop-to-remote-gateway,
   unlike the VPS setup below which needs none) — see "Direct Internet vs.
   Tailscale Tradeoffs" in `docs.openclaw.ai/gateway/security`; the
   recommended approach is Tailscale Serve over a LAN bind, not exposing the
   gateway directly.

## Updating the image version

`OPENCLAW_IMAGE` is pinned to a specific version tag rather than `:latest`,
so upstream releases can't silently change behavior underneath this
deployment. Because `docker-compose.yml` here is a vendored copy (not a live
upstream checkout), bumping the image version is a two-part deliberate step:

```bash
# 1. check current version
docker compose run --rm --entrypoint node openclaw-gateway dist/index.js --version

# 2. re-fetch docker-compose.yml at the matching git tag (note the "v" prefix
#    on git tags, which the Docker image tag omits) and diff it against ours
#    before adopting any changes — the upstream file may have changed
curl -o /tmp/docker-compose.yml.new \
  https://raw.githubusercontent.com/openclaw/openclaw/v<NEW_VERSION>/docker-compose.yml
diff docker-compose.yml /tmp/docker-compose.yml.new

# 3. bump OPENCLAW_IMAGE in .env to the new tag, then:
docker compose pull openclaw-gateway
docker compose up -d openclaw-gateway

# 4. verify
docker compose logs openclaw-gateway --tail 10
docker compose run --rm --entrypoint node openclaw-cli dist/index.js agent \
  --agent main --message "ping" --json --timeout 60
```

Available image tags: `main`, `latest`, dated/numbered releases (e.g.
`2026.6.11`), and beta tags, published to both `ghcr.io/openclaw/openclaw`
and `openclaw/openclaw` (Docker Hub). If you roll back, just set
`OPENCLAW_IMAGE` back to the previous tag and repeat steps 3–4 (and re-fetch
the matching `docker-compose.yml` if it had changed).

## Deploying to a VPS (Slack + local terminal only)

This is the topology actually deployed: **no inbound network access at all**.
Slack connects outbound via Socket Mode; terminal access happens over your
own SSH session into the VPS, using the same shared-network-namespace trick
as local terminal access.

### 1. Provision the VPS
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # log out/in after this
```

### 2. Firewall — SSH only
```bash
sudo ufw allow OpenSSH
sudo ufw enable
```
Since nothing is published, there's no `DOCKER-USER` iptables chain concern
(that issue only arises when Docker actually publishes a port to
`0.0.0.0`, which this setup never does).

### 3. Get the code onto the VPS
```bash
git clone <this-repo-url> ~/openclaw-deploy
```

### 4. Set up `.env` and data
```bash
cd ~/openclaw-deploy
cp .env.example .env
# edit .env: set OPENCLAW_GATEWAY_TOKEN, review the rest
```
Or `scp`/`rsync` an existing `.env` and `.openclaw-data/` from another
machine if you want to carry over config/history instead of starting fresh.

### 5. Bring it up
```bash
docker compose pull openclaw-gateway
```
If you copied over an existing `.openclaw-data/` with a working
`openclaw.json`, just start it:
```bash
docker compose up -d openclaw-gateway
```
If starting fresh, create the base config first — the gateway crash-loops
until `openclaw.json` exists:
```bash
docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js onboard --mode local --no-install-daemon \
  --non-interactive --accept-risk --auth-choice skip \
  --gateway-bind loopback --skip-channels --skip-skills --skip-hooks --skip-search --skip-health
docker compose up -d openclaw-gateway
```

### 6. Authenticate Claude CLI on the VPS
(Required regardless of whether you copied `.openclaw-data/` — see the
`openclaw_home` volume note above. This is interactive OAuth — run it
yourself over your SSH session, not via automation.)
```bash
docker compose run --rm --entrypoint sh openclaw-cli -lc \
  'curl -fsSL https://claude.ai/install.sh | bash'
docker compose run --rm -it --entrypoint sh openclaw-cli -lc \
  '/home/node/.local/bin/claude auth login'
docker compose run --rm openclaw-cli config set \
  agents.defaults.cliBackends.claude-cli.command /home/node/.local/bin/claude
```
Then wire up the agent runtime the same way as "First-time setup" above
(the `onboard --auth-choice anthropic-cli` + model config commands).

### 7. Wire up Slack
Requires a Slack app with **Socket Mode** enabled — a bot token (`xoxb-...`)
and an app-level token (`xapp-...`) from api.slack.com.
```bash
docker compose run --rm openclaw-cli channels add --channel slack \
  --bot-token "xoxb-..." --app-token "xapp-..."
```

### 8. Terminal access, going forward
```bash
ssh vps-user@vps-host
cd ~/openclaw-deploy && docker compose run --rm -it openclaw-cli chat
```

### Security note for Slack

OpenClaw treats this as a single-operator agent by default. If multiple
people in the Slack workspace can DM or mention the bot, they share the same
delegated tool authority. Consider allowlisting/mention-gating
(`docs.openclaw.ai/gateway/security`) if that's not desired for your
workspace.

## Troubleshooting notes learned while setting this up

- **`Unknown command: openclaw /home/node/.local/bin/claude`** — you ran a
  shell command against `openclaw-cli` without overriding its entrypoint.
  Add `--entrypoint sh ... -lc '...'` (see above).
- **`Auth choice "claude-cli" is deprecated`** — current OpenClaw versions
  use `--auth-choice anthropic-cli` instead of the older `claude-cli` value
  for `openclaw onboard`.
- **`Auth choice "anthropic-cli" requires Claude CLI auth on this host`** —
  run `claude auth login` inside the container before `onboard`; onboarding
  won't complete auth for you.
- **`claude auth login` has no non-interactive flag** — it's always a
  browser-based OAuth flow (`--claudeai` for subscription billing or
  `--console` for API billing). Always run it with `-it` in a real terminal.
- **A session keeps using the old model after changing the default** — model
  is pinned per-session at creation, not re-read from the global default on
  every turn. Use a new `--session` key or clear the old session's entry in
  `sessions.json`.
- **`curl 127.0.0.1:18789/healthz` fails from the host** after setting
  `gateway.bind: loopback` — expected. The app is listening on the
  container's own network-namespace loopback, not the host's; Docker's port
  publishing can't bridge that gap. Docker's internal healthcheck still
  works fine (it runs inside the container), and `openclaw-cli` still works
  (it shares the same network namespace).
- **This repo has no `Dockerfile` and no application source, on purpose** —
  don't `git clone` the full `openclaw/openclaw` project expecting to find
  more here; everything needed to run is these four files plus the pulled
  image.

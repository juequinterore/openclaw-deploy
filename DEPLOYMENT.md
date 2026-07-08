# OpenClaw Deployment

A minimal, standalone deployment repo for OpenClaw — contains only our
configuration, not a clone of the upstream source tree. This works because
the deployment runs the official pre-built image and never builds from
source, so nothing besides `docker-compose.yml` itself needs to come from
upstream.

This is a companion to `docs.openclaw.ai`, not a replacement — it only
covers decisions and config specific to this instance.

It also doubles as a **template**: one deployment runs one agent, and you copy
it once per agent — on the same VPS or on separate VPSs. See "Running multiple
agents on one host" and "Enabling subagents" below. (For a single agent that
transparently fans work out to specialists behind one Slack channel, you want
subagents — a config feature of a *single* deployment — not multiple
deployments.)

## Repo structure

```
docker-compose.yml          # vendored from upstream, pinned to tag v2026.6.11
docker-compose.extra.yml    # our overrides: home volume, data-dir mounts, no ports
.env.example                # template — copy to .env and fill in
.gitignore                  # excludes .env and .openclaw-data/
setup.sh                    # automates "First-time setup" below; safe to re-run
DEPLOYMENT.md                # this file
```

No `Dockerfile`, no application source, nothing else — verified: `docker
compose up -d` works from a directory containing only the compose files
above, because `OPENCLAW_IMAGE` is pinned and already resolvable by tag, so Compose
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

**Recommended: run `./setup.sh`.** It automates every step below —
`.env` creation, token generation, the Linux uid-1000 permission fix, base
onboarding, Claude CLI install, and wiring up the `claude-cli` runtime — and
is safe to re-run (each step checks whether it's already done). The one
thing it can't automate is the Claude CLI login itself (browser OAuth): it
pauses, prints the exact command to run in another terminal, and waits for
you to press Enter once you're logged in.

```bash
git clone <this-repo-url> openclaw-deploy
cd openclaw-deploy
./setup.sh
```

It ends by running the same `executionTrace.winnerProvider == "claude-cli"`
verification described below, so a clean exit means the agent is actually
working, not just configured.

The manual steps it automates are documented below for transparency and for
debugging if a step fails partway — `setup.sh` should always be kept in
sync with this sequence; if you change one, change the other.

### Manual steps (what `setup.sh` does under the hood)

```bash
git clone <this-repo-url> openclaw-deploy
cd openclaw-deploy
cp .env.example .env
```

Then edit `.env`:
- Set `OPENCLAW_GATEWAY_TOKEN` (generate with `openssl rand -hex 32`).
- Uncomment and keep the `OPENCLAW_IMAGE`, `OPENCLAW_CONFIG_DIR`,
  `OPENCLAW_WORKSPACE_DIR`, `OPENCLAW_AUTH_PROFILE_SECRET_DIR`,
  `OPENCLAW_GATEWAY_BIND`, and `COMPOSE_FILE` lines as documented in
  `.env.example`. (Leave the "Multi-agent / advanced" block commented unless
  you're running several agents on one host.)

```bash
docker compose pull openclaw-gateway
```

**On Linux (e.g. a VPS), pre-create the data dirs with the right ownership**
before anything mounts them. The container runs as uid 1000 (`node`); if
Docker auto-creates these directories on first mount (which it will, if you
skip this), they end up owned by whatever user ran `docker compose` —
typically `root` on a fresh VPS — and the container gets
`EACCES: permission denied` trying to write into them. This isn't an issue
on macOS Docker Desktop (its file-sharing layer doesn't enforce the same
uid/gid model), which is why it may not show up until a real Linux host:
```bash
mkdir -p .openclaw-data/config .openclaw-data/workspace .openclaw-data/auth-secrets
sudo chown -R 1000:1000 .openclaw-data
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
This does not delete `.openclaw-data/` or the home volume — your
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
OPENCLAW_GATEWAY_BIND=loopback                       # no inbound network exposure
OPENCLAW_GATEWAY_TOKEN=<generate with: openssl rand -hex 32>
COMPOSE_FILE=docker-compose.yml:docker-compose.extra.yml
```
These are the lines `setup.sh` auto-fills. Two more, in the "Multi-agent /
advanced" block, stay commented and are only for running several agents on one
host (see that section): `COMPOSE_PROJECT_NAME` (defaults to the deploy
directory name; namespaces containers and the `<project>_home` volume) and
`OPENCLAW_HOME_VOLUME` (override the home volume's exact name).

Provider API keys (`ANTHROPIC_API_KEY` etc., near the top of `.env.example`)
are left commented out on purpose — auth flows through the Claude CLI's own
OAuth session instead.

### `docker-compose.extra.yml`

Adds, on top of the vendored base compose file:
- `openclaw_home:/home/node` (named volume) on both services, so the Claude
  CLI install and its credentials survive container recreation. The real
  volume name is `<COMPOSE_PROJECT_NAME>_home` (project name defaults to the
  deploy directory), so each deployment gets its own home volume — two agents
  on one host never share a login. Set `OPENCLAW_HOME_VOLUME` to override with
  an exact name (e.g. to attach a volume restored from a backup).
- Bind mounts for config/workspace/auth-secrets, sourced from
  `OPENCLAW_CONFIG_DIR` / `OPENCLAW_WORKSPACE_DIR` /
  `OPENCLAW_AUTH_PROFILE_SECRET_DIR` in `.env`, defaulting to
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
3. **The home Docker volume** — a *named volume*, local to the Docker daemon it
   was created on. It does **not** transfer via `git clone` or a file copy.
   Its real name is `<COMPOSE_PROJECT_NAME>_home` (the project name defaults to
   the deploy directory), so resolve it once and reuse it below. Re-authenticate
   from scratch on the new machine (the "First-time setup" commands above), or
   migrate the volume's contents:
   ```bash
   # resolve the real volume name from the running config (works on both hosts)
   VOL=$(docker compose config --format json | \
     python3 -c 'import json,sys;print(json.load(sys.stdin)["volumes"]["openclaw_home"]["name"])')

   # on the old machine
   docker run --rm -v "$VOL":/v -v "$PWD":/backup alpine \
     tar czf /backup/openclaw_home.tgz -C /v .
   # copy openclaw_home.tgz to the new machine, then (from its deploy dir):
   VOL=$(docker compose config --format json | \
     python3 -c 'import json,sys;print(json.load(sys.stdin)["volumes"]["openclaw_home"]["name"])')
   docker volume create "$VOL"
   docker run --rm -v "$VOL":/v -v "$PWD":/backup alpine \
     tar xzf /backup/openclaw_home.tgz -C /v
   ```
   (If you set `OPENCLAW_HOME_VOLUME` to the same value in both `.env` files,
   the name is fixed and you can skip the `VOL=` lookup.)
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
cd ~/openclaw-deploy
```
Optionally `scp`/`rsync` an existing `.env` and `.openclaw-data/` from
another machine here if you want to carry over config/history instead of
starting fresh — `setup.sh` (next step) detects an existing `openclaw.json`
and skips re-onboarding.

### 4. Run the setup script
```bash
./setup.sh
```
Same script as local first-time setup — see "First-time setup" above for
what it does and why the login step still needs to be interactive. It
handles `.env` creation, the Linux uid-1000 permission fix, base config,
and Claude CLI install/wiring. **The manual steps it replaces are kept below
for reference** if you need to debug a partial failure.

<details>
<summary>Manual steps (expand if setup.sh fails partway)</summary>

```bash
cp .env.example .env
# edit .env: set OPENCLAW_GATEWAY_TOKEN, uncomment the deployment-override block
mkdir -p .openclaw-data/config .openclaw-data/workspace .openclaw-data/auth-secrets
sudo chown -R 1000:1000 .openclaw-data
docker compose pull openclaw-gateway
docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js onboard --mode local --no-install-daemon \
  --non-interactive --accept-risk --auth-choice skip \
  --gateway-bind loopback --skip-channels --skip-skills --skip-hooks --skip-search --skip-health
docker compose up -d openclaw-gateway
docker compose run --rm --entrypoint sh openclaw-cli -lc \
  'curl -fsSL https://claude.ai/install.sh | bash'
docker compose run --rm -it --entrypoint sh openclaw-cli -lc \
  '/home/node/.local/bin/claude auth login'
docker compose run --rm openclaw-cli config set \
  agents.defaults.cliBackends.claude-cli.command /home/node/.local/bin/claude
```
Then wire up the agent runtime the same way as "First-time setup" above
(the `onboard --auth-choice anthropic-cli` + model config commands).
</details>

### 5. Wire up Slack
Requires a Slack app with **Socket Mode** enabled — a bot token (`xoxb-...`)
and an app-level token (`xapp-...`) from api.slack.com.
```bash
docker compose run --rm openclaw-cli channels add --channel slack \
  --bot-token "xoxb-..." --app-token "xapp-..."
```

### 6. Terminal access, going forward
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

## Running multiple agents on one host

One deployment runs one agent. To run several **independent** agents (e.g. each
connected to a different Slack workspace), stamp out one copy per agent — the
cleanest model, with fully isolated state, secrets, sessions, and upgrade
lifecycle. On *separate* VPSs there's nothing extra to do (separate Docker
daemons). On the *same* host, give each deployment a distinct identity so
containers and the home volume don't collide:

```bash
# One directory per agent — the directory name becomes COMPOSE_PROJECT_NAME,
# which namespaces containers and the `<project>_home` volume automatically.
git clone <this-repo-url> openclaw-support
git clone <this-repo-url> openclaw-sales
cd openclaw-support && ./setup.sh    # own .env, own gateway token, own volume
cd ../openclaw-sales  && ./setup.sh
```

- **Distinct directory names are enough** — `COMPOSE_PROJECT_NAME` defaults to
  the directory name, so `openclaw-support` and `openclaw-sales` get separate
  containers (`openclaw-support-openclaw-gateway-1`, …) and separate home
  volumes (`openclaw-support_home`, `openclaw-sales_home`). If two clones would
  share a directory name, set `COMPOSE_PROJECT_NAME` explicitly in each `.env`
  (it's in the "Multi-agent / advanced" block of `.env.example`).
- **Each agent is its own Slack app** — a separate bot + app token, added via
  `channels add` into that deployment's own config. There's no shared routing.
- **Data is already isolated** — each deployment's `./.openclaw-data/` and
  `.env` live in its own directory; nothing is shared between agents.
- **Ports never conflict** — loopback bind + `ports: !reset []` means no host
  ports are published, so any number of agents coexist.
- **Verify isolation** before relying on it:
  `docker compose config | grep -E 'name:|container_name'` in each directory
  should show distinct volume/container names.

## Enabling subagents (optional)

If instead you want **one** agent that transparently delegates to specialists
behind a **single** Slack channel, that's OpenClaw *subagents* — a config
feature of a single deployment, not multiple deployments. Everything stays in
one gateway, one container, one Slack app, and **one Claude CLI login** (child
runs inherit the parent's auth), so no infrastructure changes are needed — the
setup in this repo already supports it. Turn it on with config:

```bash
docker compose run --rm openclaw-cli config set agents.defaults.subagents.delegationMode prefer
# optional: run children on a cheaper model than the parent
docker compose run --rm openclaw-cli config set agents.defaults.subagents.model anthropic/claude-haiku-4-5
# concurrency safety valve (default 8) — see sizing note below
docker compose run --rm openclaw-cli config set agents.defaults.subagents.maxConcurrent 8
docker compose restart openclaw-gateway
```

The parent agent decides when to spawn a subagent (via the `sessions_spawn`
tool) and synthesizes the result back into the same Slack channel, so the user
talks to one bot and doesn't need to know specialists exist. See
`docs.openclaw.ai/tools/subagents` for the full field list
(`agents.defaults.subagents.*`, `tools.subagents.tools.{allow,deny}`,
per-agent `agents.list[].subagents.*`).

Two things to keep in mind:

- **Sizing.** Subagents are concurrent `claude` CLI processes inside the one
  container (up to `maxConcurrent`), each with its own context and token spend.
  A subagent-heavy deployment wants a larger VPS and will cost more per request
  than a single-agent one — pointing children at a cheaper model helps.
- **Optional sandboxing.** If you want subagents to run sandboxed
  (`sandbox: require`), that needs the Docker CLI + socket — uncomment the
  `/var/run/docker.sock` mount and `group_add`/`DOCKER_GID` block in
  `docker-compose.yml` (kept commented by default). Not required for the
  default (logical session isolation).
- **Routing caveat.** Delegation is decided by the parent model, not by fixed
  rules; for "requests of type X always go to specialist Y" you shape it via
  prompt/config. Persistent thread-binding of follow-ups to a specific subagent
  is documented for Discord/Matrix/Telegram/iMessage — confirm current Slack
  behavior in the upstream docs before relying on it for Slack threads.

## Troubleshooting notes learned while setting this up

- **`pull access denied for openclaw, repository does not exist`** —
  `OPENCLAW_IMAGE` isn't actually set; Compose fell back to the
  `docker-compose.yml` default (`openclaw:local`), which was never
  published anywhere. Usually means `.env` doesn't exist yet, or exists but
  still has the deployment-override block commented out. Check with
  `docker compose config | grep image:` — it should show
  `ghcr.io/openclaw/openclaw:...`, not `openclaw:local`.
- **`EACCES: permission denied, mkdir '/home/node/.openclaw/state'`** (or
  similar under `/home/node/.openclaw/...`) — the container runs as uid
  1000, but Docker auto-created the bind-mounted `.openclaw-data/...`
  directories owned by whoever ran `docker compose` (typically `root` on a
  fresh Linux VPS). Fix: `mkdir -p .openclaw-data/{config,workspace,auth-secrets}
  && sudo chown -R 1000:1000 .openclaw-data`, then retry. Doesn't happen on
  macOS Docker Desktop (different file-sharing permission model).
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
  more here; everything needed to run is in this repo (the two compose files
  plus your `.env`) alongside the pulled image.

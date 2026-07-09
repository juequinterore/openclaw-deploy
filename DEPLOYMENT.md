# OpenClaw Deployment

A minimal, standalone deployment repo for OpenClaw — contains only our
configuration, not a clone of the upstream source tree. This works because
the deployment runs the official pre-built image and never builds from
source, so nothing besides `docker-compose.yml` itself needs to come from
upstream.

This is a companion to `docs.openclaw.ai`, not a replacement — it only
covers decisions and config specific to this instance.

It also doubles as a **template**: one deployment runs one agent, and you copy
it once per agent — on the same VPS or on separate VPSs (see "Running multiple
agents on one host"). For a single agent that transparently routes to persistent
specialists behind one Slack channel, see "Single point of contact → persistent
specialists" — that's a config feature of a *single* deployment (try
`./setup.sh --sync-agents`), not multiple deployments.

## Repo structure

```
docker-compose.yml          # vendored from upstream, pinned to tag v2026.6.11
docker-compose.extra.yml    # our overrides: home volume, data-dir mounts, no ports
docker-compose.dashboard.yml # opt-in: re-publish the gateway port to host loopback for the Control UI
.env.example                # template — copy to .env and fill in
.gitignore                  # excludes .env, .openclaw-data/, and .agents-src/
setup.sh                    # automates "First-time setup" below; safe to re-run
agents.manifest.json5        # declares pluggable agents for `setup.sh --sync-agents`
scripts/sync-agents.sh       # implements --sync-agents (see AGENTS-PLUGINS.md)
scripts/lib/manifest-compiler.js # its manifest/JSON5 logic, run inside the pinned image
examples/agents/echo-bot     # reference agent package + the manifest's offline demo
AGENTS-PLUGINS.md            # pluggable-agents format contract
DEPLOYMENT.md                # this file
```

No `Dockerfile` and no application source beyond the pieces above — `docker
compose up -d` needs only the compose files, because `OPENCLAW_IMAGE` is
pinned and already resolvable by tag, so Compose never touches the `build: .`
fallback in `docker-compose.yml`. `scripts/` and `examples/` are this
deployment's own tooling, not a copy of upstream OpenClaw source.

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
```

Pin the **full** `claude-cli` backend `args`/`resumeArgs`. Setting only
`.command` above is not enough — without these launch flags the CLI process
runs with no `--allowedTools mcp__openclaw__*` allowlist, so no OpenClaw MCP
tools are exposed (a lone agent still answers, which masks the problem, but a
coordinator has nothing to relay with). `setup.sh` does this automatically:
```bash
docker compose run -T --rm openclaw-cli config patch --stdin <<'JSON'
{
  "agents": { "defaults": { "cliBackends": { "claude-cli": {
    "command": "/home/node/.local/bin/claude",
    "args": ["-p","--output-format","stream-json","--include-partial-messages","--verbose","--setting-sources","user","--allowedTools","mcp__openclaw__*","--disallowedTools","ScheduleWakeup,CronCreate,Bash(run_in_background:true),Monitor"],
    "resumeArgs": ["-p","--output-format","stream-json","--include-partial-messages","--verbose","--setting-sources","user","--allowedTools","mcp__openclaw__*","--disallowedTools","ScheduleWakeup,CronCreate,Bash(run_in_background:true),Monitor","--resume","{sessionId}"]
  } } } }
}
JSON
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

### `docker-compose.dashboard.yml` (opt-in)

Not used by default. Re-publishes the gateway port that
`docker-compose.extra.yml` clears (`ports: !reset []`), bound to the **host
loopback only** (`127.0.0.1:18789`), so the Control UI / dashboard is reachable
in a browser for local validation and never exposed off the machine. Requires
`OPENCLAW_GATEWAY_BIND=lan` and appending it to `COMPOSE_FILE`. See "Validating
the coordinator (dashboard vs. local TUI)" for the enable/revert steps. Never
bind the Control UI to `0.0.0.0` — it's an admin surface (chat, config, exec
approvals).

### `openclaw.json` (inside `.openclaw-data/config/`, not hand-edited directly)

Key settings, set via `openclaw config set` / `onboard`:
- `agents.defaults.model.primary`: `"anthropic/claude-sonnet-4-6"`
- `agents.defaults.models["anthropic/claude-sonnet-4-6"].agentRuntime.id`:
  `"claude-cli"` — this is what routes execution through the CLI instead of
  a direct API call.
- `agents.defaults.cliBackends.claude-cli.command`:
  `"/home/node/.local/bin/claude"`
- `agents.defaults.cliBackends.claude-cli.args` / `.resumeArgs`: the full launch
  flags, including `--allowedTools mcp__openclaw__*`. **Setting only `.command`
  is not enough** — without these args the CLI process is launched with no
  allowlist, so **no `mcp__openclaw__*` tools are exposed** and any agent that
  needs a tool (e.g. a coordinator calling `sessions_send`) has nothing to work
  with. A lone agent that only answers still works, which can mask the problem.
  `setup.sh` pins these automatically.
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
Then wire up the agent runtime the same way as "First-time setup" above — the
`onboard --auth-choice anthropic-cli` + model config commands **and** the
`config patch` that pins the full `claude-cli` `args`/`resumeArgs` (don't skip
that last step: `.command` alone leaves the backend with no
`mcp__openclaw__*` tools — see "First-time setup").
</details>

**If you'll run `./setup.sh --sync-agents` with private git-sourced agents**
(see "Single point of contact" below), the sync's `git fetch` runs as
whatever host user invokes `setup.sh` — it doesn't manage credentials, so set
up SSH agent forwarding, a deploy key, or a token-authenticated HTTPS remote
for that user *before* syncing, same as any other private-repo `git` access
on the VPS.

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

## Subagents: stateless parallel fan-out (optional)

Subagents are a *different* mechanism from the coordinator pattern below: a
running agent spawns **ephemeral background runs** with `sessions_spawn` to
parallelize discrete tasks. Use them for stateless fan-out (e.g. "review these
five files at once"), **not** for a persistent front desk — for "one Slack
contact routing to persistent specialists" use the relay pattern in "Single
point of contact → persistent specialists" below (it keeps specialist memory
and needs no elevated tool profile).

Enable it on the agent that will spawn. Note `sessions_spawn` requires the
`coding` or `full` tool profile — a `messaging`-profile agent has no spawn tool:

```bash
docker compose run -T --rm openclaw-cli config patch --stdin <<'JSON'
{ "agents": { "list": [ { "id": "main", "tools": { "profile": "full" },
  "subagents": { "delegationMode": "prefer", "allowAgents": ["*"],
                 "model": "anthropic/claude-haiku-4-5", "maxConcurrent": 8 } } ] } }
JSON
docker compose restart openclaw-gateway
```

Keep in mind:

- **Sizing.** Subagents are concurrent `claude` CLI processes inside the one
  container (up to `maxConcurrent`), each with its own context and token spend —
  a subagent-heavy deployment wants a larger VPS; a cheaper child `model` helps.
- **Optional sandboxing.** For sandboxed children (`sandbox: require`), uncomment
  the `/var/run/docker.sock` mount and `group_add`/`DOCKER_GID` block in
  `docker-compose.yml`. Not needed for the default (logical session isolation).
- **Slack caveat.** Announce-back to the requester conversation works, but
  persistent thread-binding of follow-ups to a specific subagent is
  Discord/iMessage/Matrix/Telegram only — on Slack the parent re-dispatches each
  turn. See `docs.openclaw.ai/tools/subagents`.

## Single point of contact → persistent specialists (coordinator pattern)

Goal: one Slack channel (or TUI session) where the user talks to a single "front
desk" agent that routes each request to the right specialist — transparently,
with specialists keeping their own memory across turns. This is a **single
deployment** of this template: every agent runs in one gateway, shares one
Claude CLI login, and adds no infrastructure.

**The mechanism (what actually works on Slack):** the coordinator relays via
**cross-agent messaging**, not subagent spawning. It calls `sessions_send` to
hand the request to a specialist's own session (waiting for the reply), then
relays that reply to the user in its normal channel message. Because the
coordinator owns the outbound reply, this is channel-agnostic — no Slack
thread-binding caveats.

> **Critical:** `sessions_send` is **not** part of the `messaging` (or any) tool
> profile — a profile alone will **not** expose it, and the coordinator will
> silently fall back to non-OpenClaw tooling and fail to route. You must grant it
> explicitly on the coordinator with `tools.allow: ["sessions_list",
> "sessions_history", "sessions_send"]`. This is the single most common reason a
> coordinator "sees" its specialists (via the read tools) but never dispatches to
> them.

### Quickest path: `./setup.sh --sync-agents`

Agents are **declared in `agents.manifest.json5`** (committed at the repo
root) and wired in by re-running setup with the flag:

```bash
./setup.sh --sync-agents
```

This is the **pluggable agents** mechanism — full contract in
`AGENTS-PLUGINS.md`. In short: each manifest entry points at an agent
*package* (a git repo pinned to a ref, or a local path for the dev loop),
`--sync-agents` fetches it, materializes its `workspace/` into this
deployment, and **regenerates the entire `agents.list`** (plus the enabling
keys below) from the manifest in one atomic, validated `config patch`. The
manifest is the single source of truth: hand-added agents.list entries that
the sync doesn't recognize make it abort (see "Foreign agents" below), and
removing a manifest entry and re-syncing drops it cleanly, no residue.

The default manifest has one entry — the reference/demo package at
`examples/agents/echo-bot`, a local path so a fresh clone works offline:

```json5
// agents.manifest.json5
{
  agents: [
    { source: "examples/agents/echo-bot", ref: null },
  ],
}
```

`--sync-agents` is idempotent (re-running with an unchanged manifest is a
no-op patch) but **not silent**: it always restarts the gateway to apply the
new tool policy, which **interrupts any live sessions** — run it during a
quiet window on a box serving real Slack traffic.

Confirm dispatch afterward (no Slack needed). Use a **fresh `--session`** —
existing sessions load their persona at creation, so one created before the
sync (e.g. the base setup verify's `main` session) won't have the coordinator
instructions and will just answer directly:

```bash
docker compose run --rm -it openclaw-cli chat --session desk1
#   › Please have the echo specialist repeat back: banana
#   › expect the reply to contain  ECHO-BOT>> ... banana   (main relayed it)
```

### What gets configured (and why)

`--sync-agents` assembles this via `config patch --replace-path agents.list`
(dry-run validated first), using the container's mounted paths — shown here
for the default manifest (one specialist, `echo-bot`):

```json5
{
  agents: {
    list: [
      { id: "main", default: true,           // front door: unrouted messages land here
        tools: { allow: ["sessions_list", "sessions_history", "sessions_send"] }, // grant the relay tool explicitly
        workspace: "/home/node/.openclaw/workspace" },
      { id: "echo-bot",                        // a persistent specialist (own session/memory)
        workspace: "/home/node/.openclaw/agents/echo-bot/workspace",
        agentDir: "/home/node/.openclaw/agents/echo-bot/agent",  // runtime state, outside the workspace
        name: "🔁 Echo Bot", identity: { emoji: "🔁" },
        tools: { profile: "messaging" } }      // specialists that touch files/exec use "coding"
    ],
    defaults: { skipBootstrap: true }          // pre-seeded agents ship their own persona
  },
  tools: {
    sessions:     { visibility: "all" },       // let main see/target other agents' sessions
    agentToAgent: { enabled: true, allow: ["main", "echo-bot"] } // BOTH caller and callee ids — explicit, not "*"
  },
  session: { agentToAgent: { maxPingPongTurns: 0 } } // reply-back turns (0-20; 0 = single exchange)
}
```

The sync-owned enabling keys, verified against `openclaw config schema`:

- **`agents.list[main].tools.allow` includes `sessions_send`** — the coordinator
  can only relay if the tool is explicitly granted. `sessions_send` is in **no**
  profile, so `tools.profile` alone leaves the coordinator unable to dispatch.
  This is the key most easily missed.
- **`tools.sessions.visibility: "all"`** — scope for `sessions_list/history/send`
  (`self` < `tree` (default) < `agent` < `all`). `all` lets the coordinator
  target other agents' sessions.
- **`tools.agentToAgent.enabled: true` + `allow: [...]`** — permits an agent to
  invoke another at runtime. `allow` must include **both the coordinator and
  every enabled specialist id** — despite the schema calling it a "target"
  allowlist, a coordinator missing from its own `allow` gets `forbidden`
  calling `sessions_send` (verified live; not just the docs — see
  `AGENTS-PLUGINS.md` §2). Explicit ids, not `"*"` — least privilege by default.
- **`session.agentToAgent.maxPingPongTurns`** — after the specialist replies, how
  many reply-back turns the two agents may alternate (0–20). `0` (the manifest's
  default) = one exchange, no follow-up loop; set `coordinator.maxPingPongTurns`
  in the manifest to raise it.
- **`agents.defaults.skipBootstrap: true`** — pre-seeded agents ship their
  persona already, so the interactive first-run bootstrap ritual is skipped.

Routing is **prompt-driven**: the coordinator's `AGENTS.md` is **generated**
from the manifest (routing table row per agent, from its `role`/`routeHint`) —
see `AGENTS-PLUGINS.md` §8. It's overwritten on every sync; to change routing,
edit the manifest and re-sync, don't hand-edit the file.

**Foreign agents:** if `agents.list` currently contains an entry that's
neither the coordinator nor produced by the manifest (a hand-added agent, or
one whose id you dropped from the manifest but whose workspace doesn't match
the sync-owned path convention), the sync **aborts** and lists it. Either add
it to the manifest, or confirm its removal with `./setup.sh --sync-agents
--prune`.

**Migrating from the old `--agents` scaffold:** `--agents` is now a
deprecated alias for `--sync-agents` against the default manifest. Since the
default manifest's only entry is the same `echo-bot` demo (now sourced from
`examples/agents/echo-bot` instead of hardcoded), migration is automatic and
in-place — but two defaults tighten: `tools.agentToAgent.allow` goes from
`["*"]` to the explicit enabled-agent id list, and
`session.agentToAgent.maxPingPongTurns` goes from `2` to `0`. The
coordinator's hand-editable `AGENTS.md` also becomes fully sync-owned
(overwritten on every sync going forward).

### How the round-trip works

1. The user messages the coordinator (the `default` agent) on Slack or in the TUI.
2. The coordinator picks a specialist and calls `sessions_send(key="agent:<id>:main",
   message=request, timeoutMs=<wait>)`. A standing agent's session key has the form
   `agent:<id>:main` (e.g. `agent:echo-bot:main`).
3. The specialist runs in **its own persistent session** (keeps memory across
   calls) and returns its answer inline to the coordinator.
4. The coordinator relays that answer to the user in its own channel reply — the
   user sees one bot.

### Validating the coordinator (dashboard vs. local TUI)

**Do not test the coordinator from the local `chat` TUI.** The interactive TUI
registers as a restricted Gateway client and **withholds `sessions_send`** — you
will see only `sessions_list`/`sessions_history`, and `main` reports that
`sessions_send` "isn't available". Cross-session tools are exposed on the
surfaces that matter — **headless `agent` runs, the dashboard, and Slack** — not
the local TUI. (This is easy to mistake for a broken config; it isn't.)

Two ways to validate:

- **Headless one-shot** — the same kind of check `setup.sh --sync-agents` runs:
  ```bash
  docker compose run --rm --entrypoint node openclaw-cli dist/index.js agent \
    --agent main --message "Please have the echo specialist repeat back: banana" \
    --json --timeout 120
  ```
  Expect `ECHO-BOT>>` (and `banana`) in the output.

- **Dashboard (Control UI)** — to drive it by hand. The template binds the
  gateway to loopback with no published port, so the dashboard is unreachable by
  default. Opt into the bundled `docker-compose.dashboard.yml` override, which
  publishes the port to the **host loopback only**:
  ```bash
  # macOS sed shown; on Linux drop the '' after -i
  sed -i '' 's/^OPENCLAW_GATEWAY_BIND=.*/OPENCLAW_GATEWAY_BIND=lan/' .env
  grep -q docker-compose.dashboard.yml .env || \
    sed -i '' 's|^COMPOSE_FILE=.*|&:docker-compose.dashboard.yml|' .env
  docker compose up -d openclaw-gateway     # up -d, not restart
  ```
  Then browse `http://127.0.0.1:18789/` (auth token = `OPENCLAW_GATEWAY_TOKEN`
  from `.env`). On a **remote** host do NOT publish beyond loopback — keep the
  override and tunnel in: `ssh -N -L 18789:127.0.0.1:18789 user@host`.

  **Revert** to the locked-down default afterwards: remove
  `:docker-compose.dashboard.yml` from `COMPOSE_FILE`, set
  `OPENCLAW_GATEWAY_BIND=loopback`, then `docker compose up -d openclaw-gateway`.
  The Control UI is an admin surface (chat, config, exec approvals) — never bind
  it to `0.0.0.0`.

### Adding real specialists

Add an entry to `agents.manifest.json5` and re-sync — see `AGENTS-PLUGINS.md`
for the full package contract (a git repo with `openclaw.agent.json5` +
`workspace/AGENTS.md`) and every field a manifest entry accepts.

1. **Author or point at an agent package.** For the dev loop, a local path
   works and needs no `openclaw.agent.json5` (the "Model B" fallback) as long
   as you declare `id`/`tools`/etc. inline:
   ```json5
   // agents.manifest.json5
   {
     agents: [
       { source: "examples/agents/echo-bot", ref: null },
       { source: "../my-billing-agent", ref: null,
         id: "billing", name: "Billing", role: "Invoices, refunds, payment disputes.",
         tools: { profile: "coding" } },
     ],
   }
   ```
   For a package maintained in its own repo, pin a **tag or SHA** (not a
   branch — the sync warns if it looks like one):
   ```json5
   { source: "git@github.com:acme/openclaw-billing.git", ref: "v1.2.0" },
   ```
   **Private repos on a VPS** need host git auth (SSH agent, deploy key, or
   token) for whatever user runs `./setup.sh --sync-agents` — the sync only
   invokes `git`, it doesn't manage credentials.
2. **Sync:**
   ```bash
   ./setup.sh --sync-agents
   ```
   This fetches the package, lints it, materializes its `workspace/` under
   `.openclaw-data/config/agents/billing/workspace/`, rebuilds `agents.list`
   (keeping every previously-synced agent — nothing to hand-merge), restarts
   the gateway, and verifies each specialist responds plus that the
   coordinator relays to one of them. On any failure it rolls `openclaw.json`
   back and restarts again, so a bad sync doesn't leave the box half-configured.
3. Bump a `ref` and re-sync to update a specialist later — its persona/tools
   refresh but its accumulated memory (anything past the seed `MEMORY.md`) is
   preserved.

### Prefer to route by identity instead of content?

If different Slack channels/workspaces/users should map to different agents
(rather than one agent dispatching by content), skip the coordinator and use
top-level `bindings` — fully deterministic. See
`docs.openclaw.ai/channels/channel-routing` (the `team`/`channel`/`peer` tiers
cover Slack).

### Or spawn ephemeral runs instead (`sessions_spawn`)

The alternative to the relay pattern is subagent spawning: the coordinator calls
`sessions_spawn` with `agentId` to run a **fresh** instance of a specialist (no
cross-call memory), whose result announces back to the requester conversation.
Use it for stateless, one-off fan-out. Two things differ:

- the coordinator must be on the **`coding` or `full`** profile (`sessions_spawn`
  isn't in `messaging`) — set `agents.list[main].tools.profile: "full"`, plus
  `subagents: { delegationMode: "prefer", allowAgents: [...] }`; and
- on Slack there's no persistent thread-binding (Discord/iMessage/Matrix/Telegram
  only), so follow-ups re-dispatch.

See `docs.openclaw.ai/tools/subagents`.

### Things to review

- **Routing quality** is only as good as each entry's `role`/`routeHint` in
  `agents.manifest.json5` — the coordinator's `AGENTS.md` routing table is
  generated straight from it, so be specific there.
- **Breadth:** `visibility: "all"` is wide open (fine for a single-operator
  box); `tools.agentToAgent.allow` is already the coordinator plus explicit
  enabled-agent ids by default, not `"*"`.
- **`maxPingPongTurns: 0`** (the manifest default) blocks a specialist from
  asking the coordinator a clarifying follow-up; set
  `coordinator.maxPingPongTurns` to `1` or `2` in the manifest if specialists
  need to round-trip.
- **Sizing:** each active agent is another concurrent `claude` process in the one
  container — size the VPS, and point cheaper specialists at cheaper models
  per-agent (a `model` override in the manifest, or the package's own `model`).
- **Capability subtraction:** plugging in an agent built for a bigger
  environment? Use the manifest's `disableSkills`/`denyTools` to narrow it for
  this box rather than editing the package — see "Capability subtraction" in
  `AGENTS-PLUGINS.md` §7.

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
- **`config reload skipped (invalid config): agents.defaults: Unrecognized
  keys: "list", "bindings"`** — a multi-agent edit put `list`/`bindings` inside
  `agents.defaults`, which is a closed object. `agents.list` is a sibling of
  `agents.defaults`, and `bindings` is a top-level key. The gateway kept the
  previous valid config (nothing broke). Move the keys to the right level (see
  "Single point of contact → persistent specialists"), or apply via `config
  patch`, then `config validate` before restarting. Inspect the real schema any
  time with `docker compose run --rm openclaw-cli config schema`.
- **Coordinator says `sessions_spawn` isn't available (only `sessions_list` /
  `sessions_history` / `sessions_yield`)** — its tool profile doesn't include
  the spawn tool. `sessions_spawn` is in the `coding`/`full` profiles only; a
  messaging/default-profile agent never gets it. Set
  `agents.list[main].tools.profile: "full"` and restart. Verify inside the TUI
  that `sessions_spawn` now appears before debugging anything else.
- **Coordinator won't delegate — it says it "can't find the echo-bot session"
  / can only see its own scope** — *after* the profile fix above, this is the
  delegation gap: `allowAgents` without `delegationMode` gives no guidance. Set
  `agents.list[main].subagents.delegationMode: "prefer"` **and** put an explicit
  instruction in `main`'s workspace `AGENTS.md` ("spawn agentId `echo-bot` via
  sessions_spawn for echo requests"). To test the plumbing independent of the
  model's judgment, phrase the request as an explicit spawn:
  `Use the sessions_spawn tool with agentId "echo-bot" to run: echo banana`,
  then check `/subagents list`.
- **Coordinator just answers directly / echoes instead of delegating** — you're
  likely in a session created *before* the coordinator persona was applied
  (e.g. the `main` session from setup's verify step, recognizable by leftover
  `SETUP_SCRIPT_OK` history). Sessions load their agent persona at creation.
  Start a fresh one: `docker compose run --rm -it openclaw-cli chat --session
  desk1`. If a brand-new session still won't relay, force the tool to isolate
  the cause: `Use the sessions_send tool to send "banana" to agent "echo-bot",
  wait for the reply, and return it` — a working result means it's persona
  wording, not plumbing.
- **This repo has no `Dockerfile` and no application source, on purpose** —
  don't `git clone` the full `openclaw/openclaw` project expecting to find
  more here; everything needed to run is in this repo (the two compose files
  plus your `.env`) alongside the pulled image.

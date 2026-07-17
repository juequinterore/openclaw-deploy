# OpenClaw Deploy

A self-contained deployment of [OpenClaw](https://docs.openclaw.ai) running one
**coordinator agent** in front of any number of **pluggable specialist agents**,
each maintained in its own external git repo. One Slack channel (or local
terminal), one bot — behind the scenes, the coordinator routes each request to
whichever specialist actually handles it.

This repo currently wires in three specialists as a worked example:

| Agent | What it does |
|---|---|
| `echo-bot` | Reference/demo specialist — echoes back whatever it's sent. No real capability, no external deps. Used as the offline smoke test. |
| `sallie` | Event lead intake: scores leads, pushes contacts/notes to HubSpot. |
| `virginia` | Company research: builds an executive one-pager (PDF) via web research + Playwright rendering. |

If you're just here to run it, skip to **Quick start**. If you're plugging in
your own agent, skip to **Adding your agent**.

## How it works

```
                    ┌─────────────┐
   Slack / webchat  │             │
   ────────────────▶│    main     │  coordinator — the only agent users talk to
   (one channel,     │ (coordinator)│
    one bot)         └──────┬──────┘
                             │ sessions_send(key="agent:<id>:main", timeoutMs=...)
                 ┌───────────┼───────────┐
                 ▼           ▼           ▼
            ┌─────────┐ ┌─────────┐ ┌─────────┐
            │echo-bot │ │ sallie  │ │virginia │   specialists — each a
            │(coding) │ │(coding) │ │(coding) │   persistent, independent
            └─────────┘ └─────────┘ └─────────┘   session with its own memory
```

- **One deployment = one gateway container**, running the OpenClaw Gateway
  image via Docker Compose, talking to the model through **Claude CLI OAuth**
  (no model API keys to manage).
- **`main` is the only agent users interact with.** Everything else is a
  standing, persistent specialist session that `main` delegates to via the
  `sessions_send` tool, then relays the reply back in its own channel
  response — so from the user's side it always looks like one bot.
- **Routing is prompt-driven and identity-agnostic.** `main`'s persona
  (`AGENTS.md`, auto-generated) contains a routing table — one row per
  specialist, built from that specialist's declared `role` — and `main`
  picks the specialist whose row best matches the request. There's no
  hardcoded keyword/intent logic; it's an LLM decision.
- **Specialists are pluggable, not hand-scaffolded.** Each one lives in its
  *own* git repo, declares its own persona/tools/dependencies, and gets
  pulled into this deployment by pinning a `source` + `ref` in
  [`agents.manifest.json5`](./agents.manifest.json5). Adding a fourth
  specialist is a manifest edit + one script run, not a code change here.
- **Everything wiring-related is regenerated from the manifest on every
  sync** — `agents.list` in `openclaw.json`, the tool-policy grants, and
  `main`'s own `AGENTS.md` are all sync-owned. Hand-editing the generated
  files is pointless; they get overwritten on the next
  `./setup.sh --sync-agents`.

## Quick start

```bash
git clone <this-repo-url> openclaw-deploy
cd openclaw-deploy
./setup.sh               # base setup: .env, image, Claude CLI OAuth login
./setup.sh --sync-agents # wires in the specialists from agents.manifest.json5
```

`./setup.sh` does the interactive parts (Claude CLI OAuth login needs a human
in a real terminal) and is safe to re-run — every step checks whether it's
already done. Full step-by-step detail, including what to do when a step
fails partway, is in **[DEPLOYMENT.md](./DEPLOYMENT.md)**.

Talk to it once it's up:

```bash
# Headless one-shot (also how automated checks talk to it)
docker compose run --rm --entrypoint node openclaw-cli dist/index.js agent \
  --agent main --message "Please have the echo specialist repeat back: banana" \
  --json --timeout 60

# Interactive local terminal chat (routing/delegation doesn't work here — see Known limitations)
docker compose run --rm -it openclaw-cli chat
```

Or opt into the dashboard (Control UI) for point-and-click testing — see
"Validating the coordinator" in DEPLOYMENT.md.

## Repo map

| Path | What it's for |
|---|---|
| `setup.sh` | Entry point: base setup (`./setup.sh`) and agent sync (`./setup.sh --sync-agents`). |
| `agents.manifest.json5` | **The single source of truth for which specialists are wired in.** Edit this, then re-sync. |
| `scripts/sync-agents.sh` + `scripts/lib/manifest-compiler.js` | The actual sync implementation — fetches each specialist's repo, extracts deps, assembles config, regenerates `main`'s persona. `setup.sh --sync-agents` is a thin wrapper around this. |
| `docker-compose.yml` / `.extra.yml` / `.dashboard.yml` | Compose services. The `.dashboard.yml` override is opt-in (see DEPLOYMENT.md) — never bind the Control UI beyond loopback without it. |
| `Dockerfile` | Adds Python as a first-class runtime (pip, `python-is-python3`, per-agent import hook) on top of the stock OpenClaw image, plus any OS-level deps (e.g. a Playwright browser) that plugged-in agents need. Only relevant if an agent ships Python deps. |
| `examples/agents/echo-bot/` | The reference specialist package — read this first to see the minimal shape of a pluggable agent. |
| `.env` / `.env.example` | Deployment config + secrets (gitignored). See "Configuration" below. |
| `.openclaw-data/` | All runtime state: gateway config, session stores, specialist workspaces. Gitignored, project-local — the whole deployment is portable by copying `.env` + this directory. |
| `DEPLOYMENT.md` | Full operational guide: manual setup steps, day-to-day commands, VPS deployment, Slack wiring, troubleshooting. |
| `AGENTS-PLUGINS.md` | The full contract for what a pluggable agent package must look like, and how the sync assembles/validates everything. Read this before writing a new agent. |
| `AGENTS-DEPS-SPEC.md` | Python/OS-level dependency handling for agents that need more than Node — npm-only agents (like echo-bot) don't need this. |

## Configuration

Everything deployment-specific lives in `.env` (copied from `.env.example` by
`setup.sh`, gitignored). The pieces that matter most:

- `OPENCLAW_GATEWAY_TOKEN` — auth token for the gateway, auto-generated.
- `OPENCLAW_IMAGE` — the image tag to run. Either a real published tag
  (`docker compose pull` fetches it), or a **local-only tag** if any plugged-in
  agent needs the Python-enabled `Dockerfile` in this repo (`docker compose
  build` produces it locally — `setup.sh` now tries `pull` first and falls
  back to `build` automatically).
- `OPENCLAW_GATEWAY_BIND` — `loopback` by default (no published port); `lan`
  only if you've opted into the dashboard override.
- Per-agent secrets, declared by name in each specialist's manifest entry
  (e.g. `HUBSPOT_ACCESS_TOKEN` for sallie, `TAVILY_API_KEY` for virginia) —
  the sync validates these are present before wiring anything up. **There is
  no per-agent secret isolation**: one shared `.env`, one container. If two
  agents need differently-scoped credentials, namespace the variable names
  yourself (sallie already does this: `HUBSPOT_ACCESS_TOKEN_<USERID>`).

Full reference, including the "Multi-agent / advanced" block and what to
reconfigure when moving to a different machine, is in DEPLOYMENT.md's
"Configuration reference" section.

## Adding your agent

A specialist is just a git repo with a `workspace/` directory (its
persona/tools/skills — this becomes the agent's OpenClaw workspace verbatim)
and, ideally, an `openclaw.agent.json5` **self-description** at the repo root:

```jsonc
// openclaw.agent.json5 — a request, not a grant; the deployer can override/subtract anything
{
  id: "billing",
  name: "Billing Bot",
  role: "Answers billing/invoice questions; escalates refunds.",  // <- this is what drives main's routing
  tools: { profile: "coding" },        // minimal | coding | messaging | full
  env: { required: ["STRIPE_API_KEY"] },
}
```

Then add one entry to `agents.manifest.json5` in this repo:

```jsonc
{ source: "git@github.com:acme/openclaw-billing.git", ref: "v1.2.0" }
```

...and run `./setup.sh --sync-agents`. That's it — the sync clones the repo
at that ref, materializes its `workspace/` into this deployment, validates
declared env vars and dependencies, regenerates `main`'s routing table, and
restarts the gateway.

**No self-description?** You can declare the same shape inline in the
manifest entry instead (`id`, `role`, `tools`, `env`, ...) — see sallie's
commented-out entry in `agents.manifest.json5` for a real example of an
agent plugged in this way.

**What your agent's repo needs to work with this deployment:**
- A `workspace/` directory — this *is* the agent's persona/config, copied
  verbatim (`AGENTS.md`, skills, etc.).
- If it ships Node code with dependencies: a `package.json` **and a
  `package-lock.json`** (no lockfile → the sync refuses to install).
- If it ships Python code with dependencies: a `pyproject.toml` or
  `requirements.txt`. A pinned lock is recommended but not required.
- Any OS-level need (a native library, a Playwright browser) declared via
  `system.apt` / `system.playwrightBrowsers` — the sync validates these
  against the running image and tells you exactly what to add to the
  `Dockerfile` if something's missing. It never builds the image for you.
- Secrets declared **by name only** (never values) via `env: { required, optional }`.

Full contract — id/ref rules, capability subtraction (`disableSkills`,
`denyTools`), the foreign-agent-abort/`--prune` safety net, materialization
details — is in **AGENTS-PLUGINS.md**. If your agent has Python or OS-level
dependencies, also read **AGENTS-DEPS-SPEC.md**.

## Known limitations

**Long-running specialists (multi-minute tasks) can report a false timeout
to the user even though the work completes successfully.** Full
investigation, root cause, and verified workaround:
[SPECIALIST-TIMEOUT-INVESTIGATION.md](./SPECIALIST-TIMEOUT-INVESTIGATION.md).
Summary: this is a real, confirmed bug in how the `claude-cli` runtime handles a nested `sessions_send`
call: `main`'s own CLI process can conclude its turn (clean exit) while the
specialist's reply is still pending — anywhere from ~1 to ~2.5 minutes in,
independent of any configured `timeoutMs` — and the gateway then reports a
hard error (`"CLI message tool call remained in flight after exit"`) even
though the specialist keeps working and finishes normally moments later.
Confirmed by direct process inspection: the specialist's underlying process
stays alive and produces real output well after `main` has already given up.
This is not documented upstream and not fixable via `sessions_send`'s own
`timeoutMs` or any MCP-related env var (tested and ruled out).

**Workaround** (not yet wired into the coordinator persona by default): have
`main` dispatch with a short acknowledgement wait (~15–20s) instead of the
specialist's full budget, tell the user it's been kicked off, and retrieve
the result on a *later* turn via `session_status` / `sessions_history` —
never `sessions_send` again once the specialist has actually started. This
turns a long task into a two-turn interaction (dispatch, then "check back")
rather than one blocking exchange. There's currently no push-notification
path to avoid the second turn: the `message` tool cannot deliver to the
webchat/dashboard surface (`"Unknown channel: webchat"` — it only targets
real external providers like Slack/Discord/Telegram with an explicit
target), so until Slack is wired up for a given deployment, the user has to
be the one to ask again.

**The local interactive TUI (`chat --session`) cannot exercise delegation.**
It's a restricted Gateway client that withholds `sessions_send` even when
it's in `main`'s `tools.allow` — you'll see `main` report the tool "isn't
available." Cross-session tools work on headless one-shot runs, the
dashboard, and real channels (Slack, etc.) — just not this one. Don't use it
to debug a "broken" coordinator; it'll always look broken there.

**A session's tool policy is frozen at creation.** After any config change
(including `--sync-agents`), always test against a brand-new `--session` /
`--session-key` — a pre-existing session keeps whatever policy it was
created under, which can produce a false pass or a confusing false failure.

## Day-to-day operations

```bash
docker compose ps                              # status
docker compose logs openclaw-gateway --tail 20 # logs
docker compose restart openclaw-gateway        # apply config changes
docker compose down                            # stop (data/sessions survive)
```

Full command reference — admin/config commands, updating the image version,
running multiple agents on one host, deploying to a VPS with Slack — is in
DEPLOYMENT.md.

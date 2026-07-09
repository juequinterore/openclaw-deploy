# Pluggable Agents (design spec — implemented)

> **Status: IMPLEMENTED** (`scripts/sync-agents.sh` +
> `scripts/lib/manifest-compiler.js`, wired into `setup.sh --sync-agents`,
> 2026-07-09). This document remains the contract: routing/assembly/security
> decisions live here, not in the script's comments. Decisions locked with the
> maintainer: **Model A** manifests, **fetch-and-pin** materialization,
> **seed-only** memory, plus the assembly and subtraction mechanics below. See
> "Decisions" at the end. Facts marked *(verified)* were checked live against
> the pinned image (`2026.6.11`) or its `config schema` on 2026-07-09; the
> implementation itself was exercised end to end against a live deployment on
> the same date, including the foreign-agent abort/`--prune` path and
> capability-subtraction (`disableSkills`/`denyTools`) path.

## 1. Goal

Today an agent (e.g. the `echo-bot` from `setup.sh --agents`) is scaffolded
*inside* this repo. The real goal is the opposite: agents are **built and
maintained in their own git repos, elsewhere**, and this deployment **pulls them
in, pinned to a ref**, and wires them into the running gateway — behind the
existing single-Slack-contact coordinator. `echo-bot` becomes just the reference
example of the package format, not a special case.

Concretely, after this exists you should be able to write:

```jsonc
// agents.manifest.json5  (committed in THIS repo)
{
  agents: [
    { source: "git@github.com:acme/openclaw-billing.git", ref: "v1.2.0" },
    { source: "git@github.com:acme/openclaw-sre.git",     ref: "v0.4.1",
      model: "anthropic/claude-opus-4-8" },   // per-deploy override
  ],
}
```

then run `./setup.sh --sync-agents`, and end up with a `billing` and an `sre`
specialist standing behind `main`, reachable through the same `sessions_send`
relay the template already uses — with nothing agent-specific committed to this
repo except that manifest.

## 2. What an OpenClaw agent actually is (grounding)

Verified against `docs.openclaw.ai` and a live `2026.6.11` config. An agent is
**two separable things**:

1. **A config entry** — one element of `agents.list[]` in `openclaw.json`
   (`id`, `default`, `name`, `workspace`, `agentDir`, `model`, `tools`,
   `skills`, `identity`, `subagents`, `sandbox`, …). Unset fields inherit from
   `agents.defaults`.
2. **A workspace directory** — the human-authored files OpenClaw injects as
   "Project Context" at session start: `AGENTS.md` (operating instructions /
   routing), `SOUL.md` (persona), `USER.md`, `TOOLS.md` (local tool notes),
   `HEARTBEAT.md`, optional `IDENTITY.md`, `MEMORY.md` (curated long-term
   memory), `memory/YYYY-MM-DD.md`, and `skills/`. The workspace is also the
   agent's tool `cwd`, so it can carry its own `tools/` scripts and data.

Hard facts that shape the whole design (all *(verified)*):

- **`workspace` accepts an arbitrary path**, so we can point an agent at a
  checkout we materialized. **`agentDir` is a *separate* path for runtime state**
  (sessions, auth, sqlite) and must live *outside* the workspace — the workspace
  is version-controlled persona; `agentDir` is disposable local state.
- **`$include` in `openclaw.json` works at the object level only — it cannot be
  an array *element*.** You therefore **cannot** `$include` one agent into an
  existing `agents.list[]`. This forces the design in §5: we **assemble the whole
  `agents.list`** from the manifest and apply it with `config patch`.
- **`config patch` merges objects recursively; arrays and scalars replace;
  `null` deletes** *(verified: `config patch --help` + live test on a config
  copy)*. **But `agents.list` is special-cased:** a patch that would *remove*
  existing entries is **refused** ("Refusing to replace agents.list; it would
  remove existing entries: …") unless the sync passes
  **`--replace-path agents.list`**, which replaces the array wholesale while
  everything else still merges *(verified live)*. Other arrays (e.g.
  `tools.agentToAgent.allow`) shrink/replace fine on a plain patch *(verified)*.
  `config patch --dry-run` validates without writing *(verified: flag exists)* —
  §5 uses it before the real write.
- **`agents.list[].skills` is a per-agent allowlist that FULLY REPLACES
  `agents.defaults.skills`** when set — it does not merge *(verified: schema
  description: "An explicit list fully replaces inherited defaults instead of
  merging with them"; `[]` means no skills; omitted means inherit/unrestricted)*.
- **`skills.entries.<id>.enabled` is a TOP-LEVEL, deployment-global key** — it
  disables a skill for *every* agent on the box, so it is NOT a per-agent
  subtraction mechanism. §7 deliberately avoids it.
- **`tools.agentToAgent.allow` must contain BOTH the caller and the callee** —
  ~~despite its schema title ("Agent-to-Agent Target Allow"), which reads as a
  target-only allowlist~~ **correction from live runtime testing
  (2026-07-09):** a coordinator whose id is missing from `allow` gets a
  `forbidden` session status calling `sessions_send`, even when every
  specialist id is present. The schema title/description is misleading (or
  the field covers more than "target"); the earlier draft of this doc took the
  title at face value without exercising a genuinely fresh session and got
  this wrong. §5's assembly includes the coordinator id in `allow` alongside
  every enabled specialist id.
- **`agents.defaults.skipBootstrap` is a valid schema key** *(verified)* —
  needed because `agents.defaults` rejects unknown keys.

There is **no native "install agent from git"** in OpenClaw — the only native
git/registry install path is for *skills* (`openclaw skills install
git:owner/repo@ref`). Agent packaging is therefore a **convention this repo
provides**, built on the documented primitives above.

## 3. The agent package contract (what an external repo must look like)

An "agent package" is a git repo. Minimum viable package:

```
openclaw-billing/                 # the agent's own repo, maintained elsewhere
├─ openclaw.agent.json5           # the agent's self-description (Model A)
└─ workspace/
   └─ AGENTS.md                   # REQUIRED — operating instructions / persona
```

Fuller, realistic package:

```
openclaw-billing/
├─ openclaw.agent.json5           # id, role, tools, model, skills, identity
├─ README.md                      # human docs for the agent author/reviewer
├─ .gitignore                     # excludes runtime byproducts (template below)
└─ workspace/
   ├─ AGENTS.md                   # REQUIRED
   ├─ SOUL.md  USER.md  TOOLS.md  HEARTBEAT.md   # optional persona
   ├─ IDENTITY.md                 # optional (name/vibe/emoji)
   ├─ MEMORY.md                   # optional SEED memory (see §9)
   ├─ tools/                      # optional agent-owned scripts (its own CLI)
   ├─ skills/                     # optional workspace skills (SKILL.md packs)
   └─ data/  templates/           # optional working data the agent ships with
```

### 3.1 `openclaw.agent.json5` (the agent's self-description)

Lives at the **repo root** (not in `workspace/`, so it never leaks into the
agent's tool `cwd`). Every field is optional except a stable `id`. It is a
**request**, not a grant — this deployment can override or subtract any of it
(§7, §10).

```json5
{
  id:    "billing",                       // stable id; deploy may override
  name:  "💳 Billing",                     // display name / identity.name
  role:  "Invoices, refunds, payment disputes.",  // one line → coordinator routing
  tools: { profile: "coding" },           // messaging | coding | full (deploy caps this)
  model: "anthropic/claude-sonnet-4-6",   // optional; else inherits deploy default
  skills: ["invoice-lookup"],             // per-agent skill allowlist (REPLACES defaults — verified, §2)
  identity: { emoji: "💳" },
  // Free-form note surfaced to reviewers; not consumed by the runtime:
  notes: "Needs TAVILY_API_KEY for web lookups; degrades gracefully without it.",
}
```

If a repo ships **no** `openclaw.agent.json5`, the deploy manifest must supply
these fields inline (that is the Model-B fallback — see §4). So dumb/legacy repos
that are "just a workspace" still work.

### 3.2 What a package MUST NOT contain

Never commit runtime state or secrets to an agent repo. This `.gitignore`
belongs in every agent package (and mirrors what this deployment ignores):

```gitignore
# OpenClaw runtime/state byproducts — never commit these.
openclaw-workspace-state.json
memory/                 # runtime daily memory logs (MEMORY.md seed is fine)
sessions/
agent/                  # per-agent runtime state (auth, sqlite, codex-home)
.openclaw/
*.sqlite  *.sqlite-shm  *.sqlite-wal
# Secrets: agents receive credentials from the DEPLOYMENT's .env at runtime,
# never from files in the repo.
.env
```

> **`memory/` vs `MEMORY.md`:** `MEMORY.md` is a *seed* an author may ship
> (durable facts the agent should start life knowing). The `memory/YYYY-MM-DD.md`
> daily logs are runtime output — gitignored. See §9 for the seed-only policy.

## 4. The deployment manifest (`agents.manifest.json5`, committed here)

This is the single file a deployer edits to declare which agents are plugged in.
One entry per agent. Pinned by `ref`, matching this repo's pin-everything stance.

**The manifest is the single source of truth for `agents.list`.** Agents added
to `openclaw.json` by hand, outside the manifest, are *foreign* to the sync and
will be flagged (and, with `--prune`, removed) — see §5.1.

```json5
{
  // Optional global coordinator knobs (defaults shown):
  coordinator: {
    id: "main",
    name: "🧭 Front Desk",
    maxPingPongTurns: 0,          // 0 = single exchange; 1–2 to allow clarify round-trips
    defaultTimeoutMs: 180000,     // per-specialist relay wait unless overridden
  },

  agents: [
    // Model A: repo ships openclaw.agent.json5; we only pin + optionally tweak.
    { source: "git@github.com:acme/openclaw-billing.git", ref: "v1.2.0" },

    // Override the agent's own defaults for THIS deployment:
    { source: "git@github.com:acme/openclaw-sre.git", ref: "v0.4.1",
      id: "sre",                              // rename (e.g. to run two of the same repo)
      model: "anthropic/claude-opus-4-8",     // this box wants a bigger model
      timeoutMs: 900000,                      // long-running specialist
      disableSkills: ["pagerduty-notify"],    // subtract capability (§7)
      denyTools: ["message"],                 // hard-deny a tool regardless of profile
      routeHint: "Incidents, on-call, log triage." }, // override role line

    // Model-B fallback: repo has NO openclaw.agent.json5 — declare inline.
    { source: "https://github.com/acme/plain-notes-agent.git", ref: "main",
      id: "notes", name: "🗒️ Notes", role: "Scratch notes.",
      tools: { profile: "messaging" } },

    // Local path source (dev loop) instead of git:
    { source: "../my-wip-agent", ref: null, id: "wip" },

    { source: "...", ref: "...", enabled: false }, // parked without deleting
  ],
}
```

Per-agent fields: `source` (git URL or local path, **required**), `ref` (tag /
branch / SHA — required for git sources; pinning a **tag or SHA** is strongly
recommended), `enabled` (default true), plus any `openclaw.agent.json5` field as
an **override**, plus deploy-only subtractions `disableSkills` / `denyTools` and
relay `timeoutMs` / `routeHint`.

### 4.1 Format note

The manifest is **JSON5** (comments + trailing commas) so it can be parsed by
the `node` already in the image — **no new host dependency**, and it matches
OpenClaw's own config language. *(Verified: `require("json5")` resolves and
parses inside the `2026.6.11` image's node — the parse step is
`docker compose run … node -e '…require("json5")…'`.)*

### 4.2 Validation: two-phase lint (fail loud, before anything destructive)

Under Model A an entry's effective `id` may live in the *package's*
`openclaw.agent.json5` — which cannot be read until the package is fetched. So
lint runs in **two phases**, and the sync **aborts on the first error** in
either — a typo'd field silently doing nothing is the worst failure mode.

**Phase 1 — static lint (manifest only, before ANY side effect):**

- **Unknown fields** anywhere in the manifest → error naming the field and the
  entry. The set of known fields is closed (the ones documented in §4 + every
  `openclaw.agent.json5` field).
- **`source` present** on every entry; **`ref` present** for git sources
  (`ref: null` allowed only for local paths). Local-path sources must exist on
  disk and contain `workspace/AGENTS.md`.
- **Explicit ids** (where given in the manifest) match `^[a-z0-9][a-z0-9_-]*$`
  — ids are embedded in session keys (`agent:<id>:main`) and paths — and no
  manifest-level duplicates or claim on the coordinator's id.
- A `ref` that is a **branch name** produces a *warning* (not an error): branch
  pins are mutable; prefer a tag or SHA (§10).

**Phase 2 — post-fetch lint (after staging clones, before any copy or config
write).** Fetching into the gitignored `.agents-src/` staging area is not
destructive, so clones may happen before this phase; nothing is materialized or
patched until it passes:

- **Effective `id` resolvable** for every enabled entry (manifest override, else
  the package's `openclaw.agent.json5`), matching the same regex.
- **No duplicate effective ids**, and **no entry may claim the coordinator's
  id** (`coordinator.id`, default `main`) — reserved for the deployment's own
  coordinator.
- **`workspace/AGENTS.md` exists** in every fetched package (§3 makes it the
  only REQUIRED file) — enforced here for git sources, in phase 1 for local
  paths.
- **`openclaw.agent.json5` parses** (JSON5) and contains **no unknown fields**
  — same closed-set rule as the manifest.
- **No `.env`** anywhere in the package's `workspace/` → hard fail, copy
  nothing (§10).

## 5. How agents get wired into `openclaw.json` (assembly)

Because `$include` can't append a single agent (see §2), `--sync-agents`
**generates the entire `agents.list`** and applies it atomically:

1. Start with the coordinator entry (`coordinator.id`, default `main`):
   `default: true`,
   `tools.allow: [sessions_list, sessions_history, sessions_send]` — **no
   profile**, because `sessions_send` is in no profile; this is the same relay
   wiring the current `--agents` uses. The coordinator keeps the deployment's
   **default workspace** `/home/node/.openclaw/workspace` (host:
   `.openclaw-data/workspace`) and default `agentDir` — it is deployment-owned,
   not a manifest agent, so it does not live under `agents/<id>/`.
2. For each enabled manifest agent, compute its effective config = the agent's
   `openclaw.agent.json5` **overlaid by** the deploy's overrides/subtractions,
   then force the deployment-controlled fields:
   - `workspace` → `/home/node/.openclaw/agents/<id>/workspace` (the mounted path
     we materialize into, §6).
   - `agentDir`  → `/home/node/.openclaw/agents/<id>/agent` (runtime state,
     sibling of the workspace — kept out of the repo).
3. **Snapshot the current config first**: copy `openclaw.json` to
   `openclaw.json.presync` (sitting next to it in `.openclaw-data/config/`,
   inside the already-gitignored data dir). This is the rollback point for
   step 6.
4. Apply once via
   `config patch --stdin --replace-path agents.list` — objects merge
   recursively; `--replace-path` makes the rebuilt `agents.list` replace
   wholesale, which is required because a plain patch **refuses** a list that
   drops existing entries *(verified, §2)*. Run the same patch with `--dry-run`
   first (validates schema without writing), then for real. The single patch
   carries the enabling keys the relay needs:
   - `tools.sessions.visibility: "all"`
   - `tools.agentToAgent: { enabled: true, allow: [<coordinator.id>, <explicit
     manifest ids>] }` — despite the schema's "Target Allow" title, the
     **coordinator's own id must be included too** (correction, §2): a
     coordinator missing from `allow` gets `forbidden` calling `sessions_send`
     even when every specialist id is present. Explicit ids, not `"*"`, for
     least privilege (§10). (Plain-patch array replacement suffices here — the
     guard is specific to `agents.list`.)
   - `session.agentToAgent.maxPingPongTurns` from `coordinator`
   - `agents.defaults.skipBootstrap: true` *(verified valid key)* — pre-seeded
     agents ship their persona, so the interactive first-run bootstrap ritual
     must be skipped.
5. `config validate`, then `docker compose restart openclaw-gateway`. (A
   claude-cli session's tool policy is frozen at session creation, so a restart
   plus fresh sessions are required for new agents to pick up their policy.
   **The restart also interrupts any live sessions** — on a box serving real
   Slack traffic, sync during a quiet window.)
6. Regenerate the coordinator persona (§8) and run the verification (§11).
   **If validation or verification fails, roll back**: restore
   `openclaw.json.presync` over `openclaw.json`, restart the gateway again, and
   exit non-zero reporting what failed. Without this, a failed sync leaves a
   live box running the broken new config with its sessions already
   interrupted. (Materialized workspaces are left in place — they are inert
   while no config entry references them.)

### 5.1 Sync-owned keys — the idempotency invariant

The sync owns exactly this key set, and **writes every one of them on every
sync, with values derived only from the manifest**:

| Key | Written as |
|---|---|
| `agents.list` | whole array, rebuilt (`--replace-path agents.list` — §5 step 4) |
| `tools.sessions.visibility` | `"all"` |
| `tools.agentToAgent` | whole object; `allow` rebuilt from enabled ids |
| `session.agentToAgent.maxPingPongTurns` | from `coordinator` |
| `agents.defaults.skipBootstrap` | `true` |

Because nothing is written conditionally and no key outside this set is ever
touched (in particular, **never** the global `skills.entries.*` — see §7), a
manifest *change* is as idempotent as a manifest *re-run*: removing an override,
disabling an agent, or deleting an entry leaves **no residue** in
`openclaw.json` after the next sync. Everything else in `openclaw.json`
(channels, models, backends, bindings, …) is out of the sync's scope and
untouched.

**Foreign agents:** before patching, the sync diffs the current `agents.list`
against what it is about to write and prints an add / remove / keep summary. If
the current list contains entries that are neither the coordinator nor produced
by the manifest (i.e. someone hand-added an agent), the sync **aborts**, listing
them, with two ways forward: add them to the manifest, or re-run with
`--prune` to confirm their removal. This keeps "manifest = source of truth"
fail-loud instead of silently destructive.

## 6. Materialization: fetch-and-pin

For each git-sourced, enabled agent:

1. Clone/fetch `source` at `ref` (shallow, detached) into a **gitignored**
   staging dir: `./.agents-src/<slug>/`, where `<slug>` is derived from the
   `source` URL (e.g. `acme-openclaw-billing`) — **not** from the agent id,
   which under Model A is only knowable *after* the clone (the package's
   `openclaw.agent.json5` may define it). Phase-2 lint (§4.2) runs on the
   staged checkouts here — nothing below happens until it passes.
2. **Mirror-copy** `workspace/` from the staging checkout into the mounted,
   container-visible path `./.openclaw-data/config/agents/<id>/workspace/`
   (container: `/home/node/.openclaw/agents/<id>/workspace`), with these rules:
   - Copy is a **mirror with protected paths**: files that vanished from the
     package at the new ref are deleted from the target (so stale persona files
     from an older ref never linger), **except** the protected set, which the
     sync never deletes or overwrites: an existing `MEMORY.md` (seed-only, §9),
     `memory/`, `sessions/`, `openclaw-workspace-state.json`, `.openclaw/`,
     `*.sqlite*`. (`rsync --delete` with an exclude list, or an equivalent
     tracked-file-list copy.)
   - Skills disabled for this deploy (`disableSkills`, §7) have their
     `workspace/skills/*/` directories **skipped** during the copy — matched by
     SKILL.md frontmatter `name` (dir basename as fallback), per §7.
   - We copy `workspace/` only — the repo's own `.git/`, `README.md`, and
     `openclaw.agent.json5` are **not** dragged into the agent's runtime `cwd`.
3. Never touch `./.openclaw-data/config/agents/<id>/agent/` (runtime state).
4. **On Linux, chown the materialized tree to uid 1000** (the container's `node`
   user), exactly as setup.sh already does for the base data dirs — otherwise
   the agent cannot write its own workspace on a VPS.

Local-path sources (`source: "../my-wip-agent"`) skip the clone and mirror-copy
directly from the path — the dev loop for authoring an agent without pushing.

`.gitignore` gains: `/.agents-src/` (staging checkouts). `.openclaw-data/` is
already ignored, so materialized workspaces and all runtime state stay out of
git. **Nothing agent-specific is committed to this repo except the manifest.**

> **Private repos on a VPS:** fetch-and-pin needs git auth on the host (SSH agent
> / deploy key / token). This is a deployment concern, documented in DEPLOYMENT.md
> next to the Slack/VPS steps; the sync script only invokes `git`, it doesn't
> manage credentials.

## 7. Capability subtraction (the "reduced-capability clone" pattern)

A common real case: an agent built for a full production environment (HubSpot,
Slack, Drive, paging, …) is plugged into a smaller box where those integrations
must be **off**. The manifest expresses this as subtraction, applied on top of
the agent's declared config — using **only per-agent, sync-owned mechanisms**:

- `disableSkills: [...]` →
  1. the matching `workspace/skills/*/` directories are **not copied** during
     materialization (§6) — a skill that isn't in the workspace can't load.
     **Matching is on the skill's effective name, not the directory name**: the
     runtime resolves a skill's name from `SKILL.md` frontmatter `name`, falling
     back to the directory basename only when frontmatter has none *(verified:
     `hasLoadableSkillFrontmatter` in the image's `dist/workspace-*.js`:
     `frontmatter?.name?.trim() || path.basename(skillDir)`)*. The sync
     therefore parses each skill dir's `SKILL.md` frontmatter to decide what to
     skip; and
  2. if the agent's effective config has a `skills` allowlist, the listed ids
     are **dropped from it** (the allowlist fully replaces defaults — §2 — so
     omission is exclusion).

  > Deliberately **NOT** `skills.entries.<id>.enabled: false`: that key is
  > top-level and deployment-global *(verified, §2)* — it would disable the
  > skill for every agent on the box, and as a merged global key it would leave
  > residue after the manifest entry is removed. Both mechanisms above live in
  > sync-owned territory (the materialized tree and `agents.list`), so they
  > regenerate cleanly on every sync (§5.1).

- `denyTools: [...]` → set `agents.list[<id>].tools.deny: [...]` (deny wins
  over profile/allow; part of the rebuilt list, so no residue).

- The generator writes a `DISABLED_FEATURES.md` into the agent's workspace
  listing what this deployment turned off, so the agent's own persona can
  honestly tell users "that integration is disabled here" instead of pretending
  it worked. The file is **sync-owned**: regenerated on every sync and
  **deleted** when the entry no longer disables anything.

The deployment can only **subtract or narrow**; it cannot silently grant an
agent more than the deploy's own ceilings allow (§10).

## 8. The generated coordinator persona (`main`'s `AGENTS.md`)

The coordinator's `AGENTS.md` (at the default workspace, §5 step 1) is
**entirely sync-owned**: regenerated from the manifest on every sync,
hand-edits overwritten. Deploy-specific routing lives in the manifest
(`role` / `routeHint` / `timeoutMs`), not in hand-edits. The generated file
starts with a marker saying exactly that.

This template is the design artifact — the routing table rows come from the
manifest (`routeHint` overrides the package's `role`; `timeoutMs` falls back to
`coordinator.defaultTimeoutMs`), and the session discipline block ships
verbatim (it encodes the standing-session lessons from the working reference
config):

```markdown
<!-- GENERATED by `setup.sh --sync-agents` from agents.manifest.json5.
     Do not hand-edit: the next sync overwrites this file.
     To change routing, edit the manifest (role/routeHint/timeoutMs) and re-sync. -->
# {coordinator.name} — coordinator

You are a thin router in front of specialist agents. You NEVER do specialist
work yourself, even when you know the answer.

## Specialists

| id | routes to it when | session key | timeoutMs |
|---|---|---|---|
| billing | Invoices, refunds, payment disputes. | agent:billing:main | 180000 |
| sre | Incidents, on-call, log triage. | agent:sre:main | 900000 |
<!-- one row per enabled manifest agent -->

## How to relay

1. Pick exactly ONE specialist from the table. If none clearly matches, do not
   guess: tell the user what you can route to and ask them to pick.
2. Call `sessions_send(key="agent:<id>:main", message="<the user's request,
   verbatim, plus any context they gave earlier in this conversation>",
   timeoutMs=<that row's timeoutMs>)`.
3. Return the specialist's reply to the user, attributed ("billing says: …").
   Do not rewrite it, summarize away actionable content, or answer from your
   own knowledge instead.
4. If `sessions_send` times out, tell the user which specialist timed out and
   after how long. Retry at most once, and only if the user asks.

## Session discipline

- Never send status-only replies ("working on it…", "let me check…"). Hold
  your reply until you have the specialist's answer or a timeout to report.
- Stale inter-session messages: if an inter-session message arrives that is a
  late reply to an exchange you already closed out, reply with exactly
  `REPLY_SKIP` and nothing else.
- Heartbeat polls: reply with exactly `HEARTBEAT_OK`. Never relay a heartbeat
  to a specialist.
- Announce/system notices that need no action: reply `ANNOUNCE_SKIP`.
```

## 9. Memory policy: seed-only

- `MEMORY.md` shipped in the package is a **seed**: copied into the workspace
  **only if the workspace has no `MEMORY.md` yet** (first sync). Re-syncs **never
  overwrite** a live `MEMORY.md` (it is in §6's protected set).
- Runtime `memory/YYYY-MM-DD.md` daily logs accumulate in the gitignored
  workspace and are never pushed anywhere.
- Consequence: updating an agent to a new `ref` refreshes persona/tools/skills
  but **preserves the running agent's accumulated memory**. (Git-backed memory —
  committing accumulated memory back to the agent repo — is explicitly out of
  scope; noted in "Future".)

## 10. Security model

- **The deployment has final say.** `openclaw.agent.json5` is a *request*.
  Effective config = agent request → deploy overrides → deploy subtractions →
  forced deployment-controlled fields. A third-party agent cannot escalate its
  own tool access by editing its manifest.
- **Pin refs.** Prefer a tag or SHA over a branch so a compromised or careless
  upstream push can't change what runs on your box under your Claude login.
  (Branch refs lint as a warning — §4.2.)
- **Review the persona.** `AGENTS.md`/`SOUL.md` are prompts executed under your
  agent's authority; treat a new agent repo like a dependency you audit before
  pinning it.
- **`allow: ["*"]` is wide.** The sync generates `tools.agentToAgent.allow` as
  the coordinator id plus the explicit enabled-agent id set from the manifest
  (both callers and callees must be listed — §2 correction), not `"*"` — still
  least privilege by default, just not target-only.
- **Secrets flow from the deployment's `.env`**, never from agent repos. Agent
  `.gitignore` excludes `.env`; the sync refuses to copy a `.env` from a package
  if one is present (fail loud).
- All plugged agents still share **one gateway, one Claude CLI login** — this is
  one template deployment, not multiple. Cross-workspace isolation is logical
  (per-agent `workspace` + `agentDir`), not a security sandbox unless
  `sandbox: require` is configured.

## 11. Proposed `setup.sh --sync-agents`

New flag on the existing script (mirrors the idempotent, verify-at-the-end style
of the current scaffold). Pseudobehavior:

```
./setup.sh --sync-agents [--prune]
  1. preflight: base setup done (openclaw.json + claude-cli backend args
     present); docker daemon running (lint parses via the image's node);
     host `git` present if any enabled source is a git URL;
     `rsync` present, else fall back to the tracked-file-list copy (§6)
  2. read agents.manifest.json5 (parsed by the image's node + json5 — verified
     §4.1) and run PHASE-1 static lint (§4.2); abort on any error
  3. for each enabled agent: git clone @ref → .agents-src/<slug> (§6);
     then PHASE-2 post-fetch lint (§4.2) across all staged packages;
     abort before any copy on any error
  4. mirror-copy workspaces with protected paths; skip disabled skills by
     frontmatter name (§7); chown uid 1000 on Linux (§6)
  5. assemble full agents.list + sync-owned enabling keys (§5/§5.1);
     diff against current list — abort on foreign agents unless --prune;
     snapshot openclaw.json → openclaw.json.presync;
     config patch --stdin --replace-path agents.list --dry-run  (validate)
     → same patch for real → config validate
  6. regenerate main/AGENTS.md from the §8 template (sync-owned, overwritten)
  7. docker compose restart openclaw-gateway   (interrupts live sessions — §5 step 5)
  8. verify: for each agent, headless `agent --agent <id>` smoke check;
     then a coordinator relay check (main routes a sample request and returns
     the specialist reply)
  9. on ANY failure in 5–8: restore openclaw.json.presync → openclaw.json,
     restart the gateway, exit non-zero naming the failed step (§5 step 6)
```

Notes:
- **Where the code lives.** This is realistically 300–500 lines — more than all
  of today's setup.sh. Implement it as `scripts/sync-agents.sh` (with the
  JSON5/manifest-heavy parts as an embedded node script run via the image, per
  §4.1), and keep `setup.sh --sync-agents` as a thin entry point that execs it.
  Don't inline it into setup.sh.
- **Verify on the right surface.** The relay check uses the **headless one-shot**
  (`docker compose run … dist/index.js agent --agent main …`), never the local
  `chat` TUI — the TUI withholds `sessions_send`. (Same caveat the current
  `--agents` docs already call out.) One-shot runs create fresh sessions, which
  is also what picks up the new tool policy after the restart.
- **`--agents` becomes an alias.** The existing `--agents` flag turns into an
  alias for `--sync-agents` against the default committed manifest, and prints a
  one-line deprecation note. The default manifest's only entry is the reference
  package via a local source:
  ```json5
  { agents: [ { source: "examples/agents/echo-bot", ref: null } ] }
  ```
  so a fresh clone still has a working, offline demo without reaching the
  network. `echo-bot` itself moves to `examples/agents/echo-bot/` (an
  `openclaw.agent.json5` + `workspace/AGENTS.md`), doubling as the reference
  package and the format's living documentation. The old inline scaffold in
  setup.sh is deleted.
- **Behavior change for existing `--agents` deployments.** The old scaffold
  wrote `tools.agentToAgent.allow: ["*"]` and `maxPingPongTurns: 2`; the sync's
  defaults are an explicit id list and `0`. A box that ran the old `--agents`
  and then runs `--sync-agents` gets the tighter values (its hand-written
  coordinator `AGENTS.md` is also overwritten by the generated one — §8). The
  deprecation note must say this, and DEPLOYMENT.md's "Single point of contact"
  section — which documents the old scaffold's keys in detail — must be
  rewritten around the manifest, not just appended to.
- The generated `main/AGENTS.md` is fully specified in §8 — routing table from
  the manifest, session-discipline block verbatim.

## 12. Agent lifecycle (deployer's view)

| Action | How |
|---|---|
| Add an agent | Add an entry to `agents.manifest.json5`, `./setup.sh --sync-agents` |
| Update an agent | Bump its `ref`, re-sync (persona/tools refresh; memory preserved) |
| Override for this box | Add `model` / `disableSkills` / `denyTools` / `timeoutMs` to its entry |
| Temporarily disable | `enabled: false` (keeps its state; drops it from the list & allow set) |
| Remove an agent | Delete its entry, re-sync; optionally prune `.openclaw-data/config/agents/<id>/` |
| Adopt a hand-added agent | Sync aborts listing it (§5.1); add it to the manifest, or `--prune` to drop it |
| Author locally | `source: "../my-wip-agent"` and re-sync on each change |

## 13. Decisions (locked) & open items

**Locked with maintainer:**
- **Model A** manifests — agent repo declares its own defaults; deploy pins +
  overrides/subtracts; inline (Model B) is the fallback for repos with no
  `openclaw.agent.json5`.
- **Fetch-and-pin** materialization — checkouts gitignored under `.agents-src/`;
  nothing agent-specific committed here but the manifest. Copies are **mirrors
  with protected paths** (§6) so stale files from old refs never linger.
- **Seed-only** memory — no write-back.
- **Manifest format: JSON5** — parsed by the image's `node` (no new host
  dependency; *verified* `require("json5")` works in the image), matches
  `openclaw.json`.
- **Manifest = single source of truth** for `agents.list`; foreign entries
  abort the sync unless `--prune` (§5.1). Sync-owned keys are written on every
  sync from manifest-derived values only — no conditional writes, no residue.
- **Subtraction is per-agent only** (§7): skip-copy of disabled skill dirs +
  allowlist filtering + `tools.deny` — never the global `skills.entries.*`.
- **Coordinator**: keeps the deployment's default workspace; its `AGENTS.md` is
  fully sync-owned and regenerated from the §8 template every sync.
- **`echo-bot` → `examples/agents/echo-bot/`** — the reference package; the
  default manifest points at it via a local `source`; `--agents` becomes a
  deprecated alias for `--sync-agents` (§11).
- **`tools.agentToAgent.allow` = explicit manifest id set** (not `"*"`) — least
  privilege by default; it is a *target* allowlist (*verified*), so it holds the
  specialist ids and the coordinator need not appear in it.
- **`maxPingPongTurns` default `0`** — single exchange; raise to 1–2 only if
  specialists must ask clarifying questions.
- **Design-doc-first** — this file; implementation is the next step.

**Facts verified live (2026-07-09, image `2026.6.11`):** `require("json5")`
available to the image's node; `agents.defaults.skipBootstrap` is a valid
schema key; `tools.agentToAgent.allow` requires **both caller and callee**
ids, despite its schema title implying target-only (corrected the same day,
after the implementation shipped with target-only `allow` and a genuinely
fresh coordinator session got `forbidden` — see the §2 correction);
`agents.list[].skills` fully replaces inherited defaults; `skills.entries` is
top-level/global (hence §7's mechanism choice); `config patch` merges objects
recursively while arrays/scalars replace and `null` deletes, **refuses** an
`agents.list` that drops existing entries unless `--replace-path agents.list`
is passed, and supports `--dry-run` (tested against a copy of a real config —
§2); skill names resolve from `SKILL.md` frontmatter `name` with directory
basename only as fallback (image source — §7).

**Implementation checklist (small, but do not skip):**
- [x] Preflight: docker daemon up, host `git` (for git sources), `rsync` or
      the tracked-file-list fallback (§11 step 1).
- [x] Phase-1 static lint before any side effect; phase-2 post-fetch lint
      before any copy or config write (§4.2).
- [x] Staging dirs keyed by source slug, never by agent id (§6).
- [x] Linux `chown -R 1000:1000` after every materialization copy (§6).
- [x] Foreign-agent diff + abort/`--prune` before `config patch` (§5.1).
- [x] Patch with `--replace-path agents.list`, `--dry-run` first (§5 step 4).
- [x] Snapshot `openclaw.json` → `.presync` before patching; restore + restart
      on any validate/verify failure (§5 steps 3/6, §11 step 9).
- [x] `disableSkills` matches SKILL.md frontmatter `name` (fallback: dir
      basename), not the directory name (§7).
- [x] `.env` present in a package → hard fail, copy nothing (§10, §4.2).
- [x] `DISABLED_FEATURES.md` regenerated or deleted every sync (§7).
- [x] `MEMORY.md` seed-only + protected-path mirror semantics (§6, §9).
- [x] Relay verification via headless one-shot only, fresh session (§11).
- [x] Sync logic lives in `scripts/sync-agents.sh`; `setup.sh --sync-agents`
      is a thin entry point (§11 notes).
- [x] DEPLOYMENT.md: document `--sync-agents`, the manifest, private-repo git
      auth on the VPS, the restart-interrupts-sessions caveat, AND rewrite the
      "Single point of contact" section — plus the old-`--agents` migration
      note (tighter `allow` + `maxPingPongTurns` defaults — §11 notes).

**Future (explicitly out of scope now):**
- Git-backed memory (commit/push accumulated memory).
- Native skill plugins via `openclaw skills install git:owner/repo@ref` as a
  finer-grained unit than a whole agent.
- Vendoring mode (commit materialized agents for offline/air-gapped reproducibility).
- Private-repo credential automation (deploy keys) beyond documenting it.

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
> capability-subtraction (`disableSkills`/`denyTools`) path. **Extended
> 2026-07-15** with auto-extracted Python dependencies, Python as a
> first-class base-image runtime, and a declared+self-describing OS-deps
> channel — §7.3/§7.4 below; full design and live verification in
> `AGENTS-DEPS-SPEC.md`. **Routing corrected 2026-07-17**: the coordinator's
> default path is requester-aware `sessions_spawn` (with a brief acknowledgement
> and no `sessions_yield`), not a blocking `sessions_send`, because live Discord
> testing proved the latter announces completion to the target specialist's
> internal session rather than the original requester. `sessions_send` survives
> only as an opt-in per-specialist `dispatch: "send"` mode for quick stateful
> responders.

## 1. Goal

Today an agent (e.g. the `echo-bot` from `setup.sh --agents`) is scaffolded
*inside* this repo. The real goal is the opposite: agents are **built and
maintained in their own git repos, elsewhere**, and this deployment **pulls them
in, pinned to a ref**, and wires them into the running gateway — behind the
existing single-channel coordinator. `echo-bot` becomes just the reference
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
specialist behind `main`, reachable through requester-aware native subagent
runs — with nothing agent-specific committed to this repo except that
manifest.

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
   agent's tool `cwd`, so it can carry its own `tools/` scripts and data. This
   is the same fact §7.3's per-agent Python import hook (`sitecustomize.py`)
   depends on: it resolves each agent's `.python-site` by walking up from
   `cwd`, which is always somewhere under that agent's workspace.

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
- **`sessions_spawn` is the requester-aware completion primitive in this pinned
  image.** It registers the requester session key plus delivery origin
  (channel/account/target/thread), and native child completion is push-based.
  `agents.list[].subagents.allowAgents` is the spawn target allowlist.
  The coordinator ends its dispatch turn with a plain acknowledgement — it does
  **not** call `sessions_yield` (on sonnet-5 that lured the model into ending
  the turn with `NO_REPLY`, suppressing the acknowledgement); the completion
  event resumes `main` on its own. This is the live routing path; the
  `tools.agentToAgent` fact above remains relevant only to legacy/manual
  `sessions_send` use (the opt-in `dispatch: "send"` mode).
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
  env: {                                  // env var NAMES this agent needs (§7.2); values live in the deploy .env
    required: ["HUBSPOT_ACCESS_TOKEN"],   // sync aborts if unset/empty
    optional: ["TAVILY_API_KEY"],         // sync warns if unset
  },
  system: {                                // OS deps this agent needs (§7.4) — a REQUEST, gated by the deploy
    apt: ["poppler-utils"],               // only installed if this box's manifest entry sets allowSystemDeps: true
    // playwrightBrowsers is usually left unset — auto-derived from a
    // detected `playwright` Python dependency (§7.4); give it explicitly
    // only to request a different browser set.
  },
  // Free-form note surfaced to reviewers; not consumed by the runtime:
  notes: "Degrades gracefully without TAVILY_API_KEY (skips web enrichment).",
}
```

Python/npm runtime dependencies are **not** declared here — they're
auto-extracted from standard manifests the package already ships
(`package.json`+lockfile, `pyproject.toml`/`requirements*.txt`+lock — §7.1/§7.3).

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
# Sync-generated per-agent Python site (§7.3) — wiped and reinstalled from
# the committed lock on every sync, never authored by hand.
.python-site/
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
an **override** (including `env` and `system` — §7.2/§7.4), plus deploy-only
subtractions `disableSkills` / `denyTools`, relay `timeoutMs` / `routeHint`,
`allowInstallScripts` (default false — opt into npm/pip lifecycle scripts /
sdist builds at install time, §7.1/§7.3), and `allowSystemDeps` (default false
— opt into a package's requested `system.apt` OS packages, §7.4).

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
   `tools.profile: "full"` plus the narrow allowlist
   `[sessions_list, sessions_history, sessions_spawn, message]` (with
   `sessions_send` appended only when at least one enabled specialist declares
   `dispatch: "send"`). `full` is required before narrowing because
   `sessions_spawn`/`sessions_send` belong to the coding profile while
   `message` belongs to messaging. `sessions_yield` is deliberately **not**
   granted — on sonnet-5 it lured the model into ending the dispatch turn with
   `NO_REPLY`, suppressing the acknowledgement. The entry also gets
   `subagents: { delegationMode: "prefer", allowAgents: [<enabled ids>] }`.
   The coordinator keeps the deployment's
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
   - `agents.defaults.subagents.runTimeoutSeconds` — the largest enabled
     specialist `timeoutMs`, rounded up to seconds. Native spawn has one
     configured run timeout rather than a per-call timeout.
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
| `agents.defaults.subagents.runTimeoutSeconds` | largest enabled specialist `timeoutMs`, rounded up |

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
     an existing `outputs/` (seed-only, same rule — it holds the agent's
     runtime work products, e.g. rendered deliverables a user hasn't
     retrieved yet), `memory/`, `sessions/`, `openclaw-workspace-state.json`,
     `.openclaw/`, `*.sqlite*`. (`rsync --delete` with an exclude list, or an
     equivalent tracked-file-list copy.)
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

### 7.1 Skill dependencies (npm)

A workspace skill may ship code with npm dependencies — e.g. a TypeScript
post-processor run as `node --import tsx src/index.ts`. The sync installs those
dependencies **inside the pinned image**, immediately after a workspace is
materialized (§6) and before the Linux `chown` that reclaims ownership to uid
1000. Running in-image (not on the host) gives Linux-native, correctly-owned
`node_modules` regardless of the deployer's OS.

Mechanism — for every `package.json` under the materialized `workspace/` that
sits next to a lockfile (and isn't inside a `node_modules/`):

```sh
docker compose run --rm --entrypoint sh openclaw-cli \
  -c 'cd <container-path> && npm ci --include=dev --ignore-scripts --no-audit --no-fund'
```

- **Dependency-free `package.json` is skipped.** A `package.json` that declares
  no `dependencies`/`devDependencies`/`optionalDependencies` is not an install
  target — e.g. a workspace-root file that only holds orchestration `scripts`
  (`build`/`test`) across sub-skills. Nothing to install, so no lockfile is
  required or expected; the sync passes over it.
- **`npm ci`, lockfile required (when there ARE deps).** A `package.json` that
  *does* declare dependencies but ships no committed `package-lock.json` (or
  `npm-shrinkwrap.json`) is a **fail-loud error** — `npm ci` needs the lockfile,
  and the pin keeps installs reproducible (matches this repo's pin-everything
  stance). There is deliberately no lockfile-less `npm install` fallback:
  `npm install` resolves whatever satisfying versions exist at sync time, so it
  is non-deterministic across syncs and hosts.
- **`--include=dev` is mandatory, not cosmetic.** The image runs
  `NODE_ENV=production`, so npm omits `devDependencies` by default *(verified:
  `npm config get omit` → `dev` in image 2026.6.11)*. Skills that run TypeScript
  directly keep `tsx`/`typescript` in `devDependencies`; omitting them makes
  `npm ci` a **silent no-op** (installs zero packages, exits "up to date") and
  the skill then crashes at runtime with an unresolved `tsx`. `--include=dev`
  forces them in.
- **Lifecycle scripts are OFF by default (`--ignore-scripts`).** `npm ci` runs
  arbitrary `preinstall`/`postinstall` code from a third-party repo at sync
  time — a direct escalation of the supply-chain surface (§10). Pure-JS/TS
  skills don't need scripts. A deployer who genuinely needs them (native addon
  build) sets `allowInstallScripts: true` on that agent's manifest entry; the
  sync logs loudly when scripts are enabled.
- **Idempotent.** The materialization mirror-copy has no `node_modules` in its
  source, so a re-sync wipes and `npm ci` cleanly reinstalls from the (possibly
  bumped) lockfile — no stale deps survive a ref change.
- **Network.** In-image `npm ci` reaches the registry, so a host syncing
  git-sourced agents with deps needs egress at sync time (parallels the git-auth
  requirement in §6). Dependency-free packages (e.g. `echo-bot`) install
  nothing and stay fully offline.

### 7.2 Environment variables (declare-and-validate)

Agents need secrets (API tokens) and config at runtime. Those values live
**only in the deployment's own `.env`** — never in an agent repo (§3.2, §10).
An agent package *declares the names it needs*; the sync *validates they are
present* before wiring the agent in, turning "silent skill failure because a
token wasn't set" into a pre-flight abort.

Declaration — an `env` block in `openclaw.agent.json5` (Model A) or inline in
the manifest entry (Model B / override). **Names only, ever — no values:**

```json5
env: {
  required: ["HUBSPOT_ACCESS_TOKEN_NICK", "TAVILY_API_KEY"],  // missing → ABORT
  optional: ["OPENAI_WHISPER_API_KEY"],                        // missing → warn
}
```

- **Where values come from.** Both compose services load the repo-root `.env`
  via `env_file`, so every variable there is in the gateway process env and is
  inherited by skill subprocesses. OpenClaw also loads the state-dir `.env` at
  gateway start. The sync treats a name as *provided* if it has a **non-empty**
  value in **either** file (a present-but-empty `VAR=` counts as missing).
- **Validation timing.** Runs after clones but before any copy or config
  change — a missing `required` aborts with the offending `id: NAME` pairs and
  the instruction to add them to the deployment `.env`; a missing `optional`
  warns and continues. Values are never read into a variable or printed.
- **A manifest `env` overrides the package's wholesale** (even `env: {}` blanks
  the package's request), consistent with every other override field (§4).
- **Known limitation — no per-agent isolation.** All agents share one container
  and one `.env`, injected process-wide; `skills.entries.*` config is
  deployment-global too *(verified, §2)*. So any agent's skill can read every
  variable in the process env — there is no runtime env sandbox per agent. Two
  agents wanting a variable of the *same name* collide. The mitigation is a
  **convention, not a mechanism**: agents should namespace their variable names
  (Sallie already does — `HUBSPOT_ACCESS_TOKEN_<USERID>`). True per-agent
  isolation would need runtime support OpenClaw does not provide today.

### 7.3 Skill dependencies (Python)

Symmetric with §7.1's npm path, extended to Python (full design + live
verification: `AGENTS-DEPS-SPEC.md`). A materialized workspace is a "Python
project" wherever the sync finds a `pyproject.toml` with non-empty
`[project].dependencies`, or a `requirements*.txt` with at least one real
requirement line (excluding `node_modules/` and the generated `.python-site/`).
**`pyproject.toml`, when present, is the sole dependency source for that
directory** — any sibling `requirements*.txt` is treated as dev/test
convenience and not parsed for deps (only read for extraction when there's no
`pyproject.toml` there). This is confirmed against a real package in the
wild: its `requirements.txt` is exactly `.` + `pytest` (no dev/test naming),
which yields zero runtime deps precisely because its `pyproject.toml` is
authoritative. Dev/test-**named** requirements files (`requirements-dev.txt`,
…) are skipped too, in the no-`pyproject.toml` case. Editable self-references
(`.`, `-e .`) are never runtime deps either way.

- **A pinned lock is preferred, not required** (revised 2026-07-16 — unlike
  npm, which keeps its required-lockfile bar; see `AGENTS-DEPS-SPEC.md` §3.2 for
  why the two paths differ). A fully-pinned `requirements.lock` / `requirements.txt`
  (from `pip freeze` / `pip-compile` / `uv pip compile`; `--generate-hashes`,
  URL refs, and env markers all accepted) installs reproducibly with the
  resolver off. **With no lock, the sync resolves the declared deps at sync time
  and warns** that the install isn't byte-reproducible across hosts/time — real
  Python agents often ship only ranges, and this lets them plug in.
  (`uv.lock`/`poetry.lock`/`Pipfile.lock` still aren't parsed as locks, but an
  agent shipping only those now falls into the resolve path rather than failing.)
- **Install target: one site per agent**, not per skill directory —
  `<workspace>/.python-site`, installed in-image via `pip install --target
  … --only-binary=:all:` (pip's supply-chain gate: no third-party `setup.py`
  execution; lifts to allow sdists under the same per-agent
  `allowInstallScripts: true` that governs npm lifecycle scripts, §7.1). Adds
  `--no-deps` when a pinned lock drives the install; drops it (resolver on) in
  the lockless case above. Wiped and reinstalled on every sync — same
  idempotency as `node_modules`.
- **Resolved at runtime by a cwd-keyed import hook**, not a venv. Python does
  not add the workspace to `sys.path` the way Node's resolver walks up to find
  `node_modules`, so the base image (§7.4's Dockerfile) bakes in a constant
  `sitecustomize.py`; it walks up from the tool `cwd` (always inside the
  invoking agent's workspace — §2) to find the nearest `.python-site` and
  prepends it to `sys.path`. This keeps `python` on `PATH` (no venv to
  activate) while giving each agent its own installed deps. **Not** wired via
  `PYTHONPATH`: live testing against a real plugged-in agent
  (`AGENTS-DEPS-SPEC.md` §3.4's revision note) found OpenClaw's Bash/exec tool
  doesn't inherit it into the subprocess env, so the hook instead overwrites
  the interpreter's own stdlib `sitecustomize.py` directly (a fixed env var
  can't be stripped if nothing depends on it). **Verified live** end to end,
  through a real agent's own tool call (not just `docker exec`): the agent
  with Python deps installed imported them successfully; a second agent with
  none correctly could not (`ModuleNotFoundError`) — isolation intact, and
  separately, two agents pinning conflicting `pydantic` versions each import
  their own with neither seeing the other's packages.
- **No per-agent env isolation needed for this one** (unlike §7.2): each
  agent's site is a separate directory, so conflicting pins between agents are
  structurally impossible — no merge, no conflict detector needed.

### 7.4 OS-level / system dependencies

OS libraries (a browser engine, a native library) aren't recorded in any
machine-readable, pinned manifest, so they can't be auto-extracted like §7.1/
§7.3 — and they install into image/root-owned system paths, which a per-agent
workspace mount cannot reach. They are handled as a **declared, gated**
request, plus one auto-derived case:

- **`system.apt: [...]`** in `openclaw.agent.json5` (or a manifest override)
  names OS packages a package needs. It's a *request*: it only takes effect
  when that agent's manifest entry sets **`allowSystemDeps: true`** (default
  false) — the same "package requests, deployer opts in" pattern as
  `allowInstallScripts`.
- **`system.playwrightBrowsers: [...]`** is usually left unset: if `playwright`
  is detected among an agent's extracted Python deps (§7.3), the sync derives
  `["chromium"]` automatically (Playwright's own installer resolves the exact
  OS libs a browser needs, so that list is never hand-authored). Give it
  explicitly only to request a different browser set, or `[]` to opt out of
  auto-derivation.
- **Realized as base-image layers, validated (not built) by the sync.** OS
  deps only install into the committed base `Dockerfile` (§5 in
  `AGENTS-DEPS-SPEC.md`; this repo now ships one, with Python + the §7.3 import
  hook baked in). The sync itself never runs `docker build` — instead it
  preflight-validates the union of gated `system.apt` + (explicit or derived)
  `system.playwrightBrowsers` against the **running** image (`dpkg -s`; a
  browser-directory presence check), and on any miss **aborts before touching
  config**, printing the exact Dockerfile lines to append (including the
  pinned Playwright version, when applicable) and the rebuild command. The
  deployer appends, rebuilds, re-runs the sync.
- See `AGENTS-DEPS-SPEC.md` §12 for the one open edge case: whether multiple
  agents pinning *different* Playwright versions can truly coexist under one
  browsers path, or whether a box needs a one-Playwright-version limit.

## 8. The generated coordinator persona (`main`'s `AGENTS.md`)

The coordinator's `AGENTS.md` (at the default workspace, §5 step 1) is
**entirely sync-owned**: regenerated from the manifest on every sync,
hand-edits overwritten. Deploy-specific routing lives in the manifest
(`role` / `routeHint` / `timeoutMs`), not in hand-edits. The generated file
starts with a marker saying exactly that.

The routing table rows come from the manifest (`routeHint` overrides the
package's `role`; `timeoutMs` falls back to `coordinator.defaultTimeoutMs`; the
`dispatch` column reflects each agent's `dispatch` mode), and the session
discipline block ships verbatim. The excerpt below is **abridged for reading** —
the real generated file (see `scripts/sync-agents.sh` §6) additionally spells
out the spawn/send asymmetry rules, per-specialist `taskHint` dispatch
requirements, one-job-per-spawn splitting, the `thinking` override, and the
full completion/status protocol. Treat that script as the source of truth;
this section shows the shape:

```markdown
<!-- GENERATED by `setup.sh --sync-agents` from agents.manifest.json5.
     Do not hand-edit: the next sync overwrites this file.
     To change routing, edit the manifest (role/routeHint/timeoutMs) and re-sync. -->
# {coordinator.name} — coordinator

You are a thin router in front of specialist agents. You NEVER do specialist
work yourself, even when you know the answer.

## Specialists

| id | routes to it when | dispatch | typically done within |
|---|---|---|---|
| echo-bot | Echo/repeat-back requests. | `send: sessionKey="agent:echo-bot:main"` | ~1 min |
| billing | Invoices, refunds, payment disputes. | `spawn: agentId="billing"` | ~3 min |
| sre | Incidents, on-call, log triage. | `spawn: agentId="sre"` | ~15 min |
<!-- one row per enabled manifest agent; dispatch marked spawn: or send: -->

## How to relay

1. Pick the matching specialist(s). If none matches, do not guess: tell the
   user what you can route to and ask them to pick.
2. Use the row's dispatch mode. For a `spawn:` row, call
   `sessions_spawn(<the row's parameters>, runtime="subagent", mode="run",
   cleanup="keep", task="<the user's request verbatim, conversation context,
   and the specialist's manifest taskHint verbatim>")`, then end the turn with
   one brief acknowledgement — never `sessions_yield`, never poll; the
   completion event arrives on its own. For a `send:` row, call
   `sessions_send(<the row's parameters>, message="…", timeoutSeconds=30)` and
   relay the reply in the same turn. NEVER dispatch a `spawn:` specialist via
   `sessions_send` (its result outlives the synchronous wait and is lost).

## Completion events

- When `A background task completed` arrives, relay the actual child result
  through `message(action="send", ...)` to the requester conversation.
- Convert every plain `MEDIA:<absolute path>` line in the child result into
  one structured file attachment on that same message. Attach every
  user-facing deliverable, including PDF, editable HTML, Markdown, and reports.
- Specialist task hints may require copying deliverables into the
  coordinator's `workspace/deliveries/` tree first. This is required when the
  provider's local-media policy cannot read another agent's workspace.
- After delivering, end the turn with `NO_REPLY`. Do not answer `NO_REPLY`
  merely because the working acknowledgement was already sent — suppress only a
  duplicate completion event for the same child.
- Do not poll. If the user explicitly asks for status, inspect the original
  child's session via `sessions_history`.

## Session discipline

- Never invent or preview a specialist result.
- Never start the same request twice.
- Stale completion already delivered: reply `NO_REPLY`.
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
- **Spawn access is explicit.** The sync generates the coordinator's
  `subagents.allowAgents` from the enabled manifest ids, never `"*"`.
  The legacy `tools.agentToAgent.allow` is also kept explicit for manual
  inter-session compatibility.
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
     then a coordinator spawn-completion check that proves a source=subagent
     completion event reached main and main produced the child token
     (plus, when a dispatch:"send" specialist exists, a synchronous send-relay
     check through the first such specialist)
  9. on ANY failure in 5–8: restore openclaw.json.presync → openclaw.json,
     restart the gateway, exit non-zero naming the failed step (§5 step 6)
```

Notes:
- **Where the code lives.** This is realistically 300–500 lines — more than all
  of today's setup.sh. Implement it as `scripts/sync-agents.sh` (with the
  JSON5/manifest-heavy parts as an embedded node script run via the image, per
  §4.1), and keep `setup.sh --sync-agents` as a thin entry point that execs it.
  Don't inline it into setup.sh.
- **Verify the event, not just the dispatch text.** The headless check creates
  a fresh main session, asks it to spawn the specialist, then performs a bounded
  sync-time scan for a source=subagent completion event followed by an
  assistant token in main's transcript. The deployed coordinator itself never
  polls files. Real provider delivery is separately exercised on a messaging
  channel such as Discord.
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
- **`subagents.allowAgents` = explicit manifest specialist id set** (not `"*"`)
  — least privilege for the active routing path. The legacy
  `tools.agentToAgent.allow` contains both coordinator and specialists because
  the pinned runtime requires caller and callee for `sessions_send`.
- **`maxPingPongTurns` default `0`** — single exchange; raise to 1–2 only if
  specialists must ask clarifying questions.
- **Skill deps: in-image `npm ci`, auto-detected** (§7.1) — any
  `package.json`+lockfile under a materialized `workspace/` is installed inside
  the image with `--include=dev` (image is `NODE_ENV=production`; runtime `tsx`
  lives in devDeps) and `--ignore-scripts` by default (supply-chain gate;
  per-agent `allowInstallScripts: true` opts in). No lockfile → fail loud.
- **Env: declare names, validate presence, shared `.env`** (§7.2) — package or
  manifest declares `env.required`/`env.optional` (names only); sync aborts on a
  missing required, warns on a missing optional, before any copy or config
  write. No per-agent env isolation (single shared container/`.env`); namespace
  variable names by convention.
- **Python deps: in-image `pip install --target`, per-agent site, auto-detected**
  (§7.3, `AGENTS-DEPS-SPEC.md`) — `pyproject.toml`/`requirements*.txt` under a
  materialized `workspace/` installs into that agent's own `.python-site`, via
  `--no-deps --only-binary=:all:` (supply-chain gate, lifts under
  `allowInstallScripts`). A fully `==`-pinned lock is required, same bar as
  npm's lockfile. Resolved at runtime by a constant, cwd-keyed
  `sitecustomize.py` hook baked into the base image — no venv, no shared
  union; conflicting versions across agents coexist by construction.
- **Python is a first-class runtime by default** — a committed base
  `Dockerfile` (§5, `AGENTS-DEPS-SPEC.md`) adds pip + `python-is-python3` + the
  import hook on top of the stock image, which ships neither.
- **OS deps: gated-declared, self-describing Playwright, validate-not-build**
  (§7.4, `AGENTS-DEPS-SPEC.md`) — `system.apt` only installs when a manifest
  entry sets `allowSystemDeps: true`; a detected `playwright` Python dep
  auto-derives `playwrightBrowsers: ["chromium"]` unless overridden. Both
  realize only as base-image layers; the sync validates the running image and
  aborts with the exact Dockerfile lines to append rather than building one
  itself.
- **Design-doc-first** — this file (and `AGENTS-DEPS-SPEC.md` for the
  Python/OS-deps extension); implementation followed each spec.

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
- [x] Skill deps: in-image `npm ci --include=dev --ignore-scripts` per
      lockfile'd `package.json`, after copy / before chown; no lockfile → fail;
      `allowInstallScripts` opt-in (§7.1).
- [x] Env: declared `env.required`/`optional` validated against the deploy
      `.env` (names only) — missing required aborts, missing optional warns,
      before any copy or config write (§7.2).
- [x] `DISABLED_FEATURES.md` regenerated or deleted every sync (§7).
- [x] `MEMORY.md` seed-only + protected-path mirror semantics (§6, §9).
- [x] Relay verification via headless one-shot only, fresh session (§11).
- [x] Sync logic lives in `scripts/sync-agents.sh`; `setup.sh --sync-agents`
      is a thin entry point (§11 notes).
- [x] DEPLOYMENT.md: document `--sync-agents`, the manifest, private-repo git
      auth on the VPS, the restart-interrupts-sessions caveat, AND rewrite the
      "Single point of contact" section — plus the old-`--agents` migration
      note (tighter `allow` + `maxPingPongTurns` defaults — §11 notes).
- [x] Python deps: in-image `pip install --target <workspace>/.python-site
      --no-deps --only-binary=:all:`, per project root under a materialized
      `workspace/` (pyproject.toml via in-image `tomllib`, requirements*.txt by
      plain parsing); missing pinned lock → fail; `allowInstallScripts` lifts
      `--only-binary` too (§7.3, `AGENTS-DEPS-SPEC.md`).
- [x] Committed base `Dockerfile` + `pyhook/sitecustomize.py` (cwd walk-up,
      installed by overwriting the interpreter's stdlib copy — not
      `PYTHONPATH`, which a real agent's tool doesn't inherit; see
      `AGENTS-DEPS-SPEC.md` §3.4's revision note) + `PLAYWRIGHT_BROWSERS_PATH`
      env — verified building, a two-agent conflicting-pydantic-versions
      isolation test, AND (2026-07-16) a real plugged-in agent
      (`onepagerbuilder`/Virginia) importing its installed deps through its
      own Bash/exec tool, with a second agent correctly unable to (§7.3, §5).
- [x] OS-dep preflight validator (`dpkg -s`, Playwright browser-dir presence)
      that aborts before the config patch with the generated Dockerfile
      snippet + rebuild command — validate-and-instruct, no auto-build (§7.4).
- [x] `system`/`allowSystemDeps` added to `manifest-compiler.js`'s field sets,
      validation, and effective-agent output, with unit tests
      (`scripts/lib/manifest-compiler.test.js`, run via
      `scripts/test-compiler.sh`).

**Future (explicitly out of scope now):**
- Git-backed memory (commit/push accumulated memory).
- Native skill plugins via `openclaw skills install git:owner/repo@ref` as a
  finer-grained unit than a whole agent.
- Vendoring mode (commit materialized agents for offline/air-gapped reproducibility).
- Private-repo credential automation (deploy keys) beyond documenting it.

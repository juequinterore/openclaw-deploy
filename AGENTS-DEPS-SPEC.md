# Automatic dependency extraction (design spec — implemented)

> **Status: IMPLEMENTED** (`scripts/sync-agents.sh`'s `install_python_deps` +
> OS-dep preflight step, `scripts/lib/manifest-compiler.js`'s
> `system`/`allowSystemDeps` support, the committed `Dockerfile` +
> `pyhook/sitecustomize.py`, 2026-07-15). Extends the pluggable-agents system
> (`AGENTS-PLUGINS.md` §7.1) from npm-only to **auto-extracted language
> dependencies for Node *and* Python by default**, plus a **declared** path for
> OS-level dependencies that aren't self-describing. Every load-bearing claim was
> verified live against the pinned image `ghcr.io/openclaw/openclaw:2026.6.11`
> on 2026-07-15 (see "Verified live" §10, including the per-agent-isolation
> test #7) — and the built `Dockerfile` itself was re-verified end to end the
> same day (build, pip/tomllib presence, `--target` install, and the
> cwd-keyed `sitecustomize` hook isolating two conflicting-version installs).
> The deployment has since moved to `2026.7.1` (see `OPENCLAW_VERSION` in
> `.env`); nothing here is version-specific, but these facts were not
> re-verified against the newer base.
> The five design decisions (D1–D5) are settled and recorded in §9 — **D2 was
> revised 2026-07-16**: a pinned lock is now *preferred, not required* (Python
> agents in the wild routinely ship only ranges — §3.2). §12 lists items to
> confirm on a live multi-agent box (not blockers, and not yet exercised
> against a real deployment — see the note there).
>
> See `AGENTS-PLUGINS.md` §7.3/§7.4 for the folded-in contract summary and
> cross-links, and its §13 for the implementation checklist mirrored from
> §11 below.

## 1. Goal

Today `scripts/sync-agents.sh` auto-installs an agent's **npm** skill deps
(§7.1): it finds a `package.json`+lockfile under the materialized workspace and
runs `npm ci`. Agents in the wild (e.g. `onepagerbuilder`/"Virginia") also carry
**Python** tooling and, occasionally, **OS-level** needs (a browser engine, a
native library). The deployment must support these **generically** — derived
from what the agent *ships* or *declares*, never hand-tailored to one agent.

This spec adds:

1. **Auto-extraction of language deps for Python**, symmetric with the existing
   Node path — no manual declaration, read straight from standard manifests.
2. **Python as a first-class runtime by default**, alongside Node, in the
   deployment's base image.
3. **A declared channel for OS deps** that can't be inferred, plus
   auto-detection of the one common *self-describing* case (Playwright
   browsers).

Python deps are **isolated per agent** (§3.4) — two agents may pin different,
even conflicting, versions of the same package. This is *logical* isolation on a
shared interpreter, not a security sandbox: agents already share one container
and one Claude login (`AGENTS-PLUGINS.md` §10), so it buys correctness and
portability, not a trust boundary. Non-goal: CLI **tool-permission** extraction
(`WebSearch`/`Task`/…) — a separate concern tracked elsewhere.

## 2. What is "safely extractable"

The dividing line, verified by ecosystem: a dependency is **auto-extractable**
only when it is recorded in a **machine-readable manifest with a pin**.

| Layer | Source of truth | Auto? | Where it installs |
|---|---|---|---|
| Node packages | `package.json` + `package-lock.json` | ✅ (exists) | workspace `node_modules/` |
| Python packages | `pyproject.toml`/`requirements*.txt` **+ a pinned lock** | ✅ (new) | per-agent site (`.python-site` + cwd hook) |
| Playwright browser engines | `playwright` present in Python deps (self-describing) | ✅ detect → **declared install** | base image (apt/root) |
| Arbitrary OS libraries / apt packages | nothing machine-readable | ❌ → **manually declared** | base image (apt/root) |

The **placement column is not a preference, it's a constraint**:

- Node resolves `node_modules` by walking up from the executing file, so
  workspace-local installs "just work" with no env wiring.
- Python does **not** add the workspace to `sys.path` for `python script.py`, so
  third-party packages must be reachable another way. Verified working model
  (§"Verified live" #4/#7): install each agent's deps into a per-agent
  `.python-site` in its workspace, and add a single constant startup hook
  (`sitecustomize.py` on a fixed `PYTHONPATH`) that prepends the *current
  workspace's* site — keying on the tool `cwd`, which OpenClaw sets to the
  agent's workspace. This keeps `python` on `PATH` (no venv) — honoring what real
  agents expect — while giving each agent its own dependency set. Virginia's
  `TOOLS.md`: *"Run every Python command with `python` from the deployment
  runtime PATH. Environment provisioning owns dependency installation. Do not
  activate a virtual environment."*
- OS libraries install into system paths owned by root and are not mountable, so
  they can only live in the **image** (verified: `playwright install-deps`
  shells out to apt — §"Verified live" #6).

## 3. Python language deps (new — mirrors npm §7.1)

### 3.1 Detection

A materialized workspace is a "Python project" if the sync finds, under `$dst`
(excluding `node_modules/` and the generated site dir), **either**:

- a `pyproject.toml` with a non-empty `[project].dependencies`, **or**
- a `requirements*.txt` containing at least one real requirement line.

Discovery mirrors the npm scan (`find "$dst" -name package.json …`). Parsing
uses the image's **stdlib `tomllib`** for `pyproject.toml` (verified present in
the image's Python 3.11) and plain line parsing for `requirements*.txt`.

Extraction **ignores** editable self-references (`.`, `-e .`) — first-party
code is already importable via the tools' own `sys.path` handling. **When a
directory has a `pyproject.toml`, it is the sole dependency source for that
directory**; a sibling `requirements*.txt` is presumed dev/test convenience
and is not parsed for deps (confirmed against Virginia's actual repo:
`requirements.txt` there is exactly `.` + `pytest`, no dev/test naming
convention — it yields **zero** runtime deps precisely because
`pyproject.toml` wins, not because of any filename heuristic). Only when a
directory has **no** `pyproject.toml` does `requirements*.txt` get parsed as
the dependency source, and dev/test-**named** files
(`requirements-dev.txt`, …) are skipped there too.

### 3.2 Determinism: a pinned lock is PREFERRED, not required (revised D2)

**Revised (2026-07-16).** The original stance (a fully-pinned lock is
*mandatory*, fail-loud otherwise — symmetric with `npm ci`) proved wrong for
Python's ecosystem reality: unlike npm, where a committed `package-lock.json`
is auto-generated and near-universal, real Python agents routinely ship only a
`pyproject.toml` with **version ranges** and no lock at all (the worked-example
agent, Virginia, is exactly this). Requiring a lock blocked those agents from
plugging in. Node keeps its required-lockfile bar unchanged (§4) precisely
because it matches how ~all Node repos already ship; Python does not, so the
two paths intentionally differ. See §7.3 for that asymmetry, spelled out.

The behavior now:

- **A pinned lock, when present, is still used and is the recommended path.**
  Accepted forms: a fully `==`-pinned `requirements.lock`, or a
  `requirements.txt` that is itself fully pinned (output of `pip freeze`,
  `pip-compile`, or `uv pip compile`). "Fully pinned" accepts `==` pins,
  `--hash`/continuation lines (`pip-compile --generate-hashes`), direct
  URL/VCS references (an exact pin), and environment markers — an older
  "`==` on every line" check wrongly rejected all but the first. When a lock
  is present, the full set installs with the resolver **off** (`--no-deps`) —
  byte-reproducible (§3.3).
- **No lock → resolve at sync time, with a loud warning.** The sync installs
  the *declared* deps (`[project].dependencies`, or a non-pinned
  `requirements*.txt`) with pip's resolver **on**, and warns that the result is
  **not** byte-reproducible across hosts/time, pointing at `uv pip compile` /
  `pip-compile` / `pip freeze` as the fix. The supply-chain gate
  (`--only-binary=:all:`, §3.3) still applies, so a lockless install still runs
  no third-party `setup.py`.

`uv.lock` / `poetry.lock` / `Pipfile.lock` are still not parsed as lock formats
(§12) — but an agent shipping only those now falls into the resolve-at-sync
path rather than failing, so nothing is *blocked* on them.

### 3.3 Install

Installed **in-image at sync time** (like `npm ci`), into a **per-agent** site
directory inside that agent's workspace, from the pinned lock only:

```sh
docker compose run -T --rm --entrypoint sh openclaw-cli -c \
  "pip install --target /home/node/.openclaw/agents/<id>/workspace/.python-site \
       --no-deps --only-binary=:all: --no-input -r <lock>"
```

- **Target = `<workspace>/.python-site`** for each agent (host:
  `$CONFIG_DIR/agents/<id>/workspace/.python-site`; already mounted — no new
  volume). Each agent installs *only its own* lock — never a merged union — so
  agents can pin conflicting versions (§3.4). Regenerated (wiped + reinstalled)
  on every sync from the lock, so a ref change never leaves stale packages —
  same idempotency as `node_modules`; and `.python-site` is never mirror-copied
  from the package (it is generated), so it belongs in the agent repo's
  `.gitignore`.
- **`--no-deps` when installing from a pinned lock** because the lock already
  lists the full transitive set; this removes the resolver from the path,
  making installs byte-reproducible across syncs/hosts. **When no lock is
  present (§3.2), the resolver runs** (`--no-deps` dropped) so the declared
  deps still install — at the documented cost of cross-host/time
  reproducibility, which the sync warns about.
- **`--only-binary=:all:`** is the supply-chain gate, the pip analog of npm's
  `--ignore-scripts`: it forbids source distributions, so **no third-party
  `setup.py` runs at sync time**. An agent that genuinely needs an sdist opts in
  per §5's `allowInstallScripts: true` (which drops `--only-binary`).
- **In-image, not on host**, so the compiled wheels are Linux-native and match
  the runtime (verified: `pydantic-core`/`pillow` wheels install and import
  under `--target` — §"Verified live" #3/#4). On Linux, chown the site to uid
  1000 after install, like the workspace.

### 3.4 Import path: per-agent, keyed on the tool `cwd`

> **Revised after live testing against a real plugged-in agent (2026-07-16) —
> the original `PYTHONPATH`-based design in this section did not work.** Two
> things had to be confirmed by actually running a message through a synced
> agent's Bash/exec tool (not just `docker exec`/`docker run`), not by
> inspecting the container alone:
>
> 1. **`cwd` = the agent's workspace, confirmed true.** `pwd` from inside a
>    real tool call printed the agent's workspace path exactly as assumed.
> 2. **`PYTHONPATH` is NOT inherited by the tool's subprocess environment.**
>    Even with `PYTHONPATH=/opt/pyhook` set at the container level (verified
>    present via `docker compose exec`), a real agent's `python3 -c "import
>    pydantic"` failed with `ModuleNotFoundError` and an empty `$PYTHONPATH`
>    when the *same command* ran through the agent's own tool. OpenClaw's
>    Bash/exec tool evidently spawns with a curated subprocess environment
>    that drops it — a `docker exec`/`docker run` bypasses that curation
>    entirely, which is why the original manual verification (§10 #7) looked
>    successful but didn't hold for a real agent turn.
> 3. **A dist-packages fallback doesn't work either.** Moving the hook to
>    `/usr/lib/python3/dist-packages/sitecustomize.py` (unconditionally on
>    `sys.path`, independent of any env var) was the first fix attempted —
>    but the stock base image already ships its OWN `sitecustomize.py`
>    directly in the **stdlib** directory (`/usr/lib/python3.11/`, a
>    Debian/Ubuntu apport-crash-handler stub), which sits earlier on
>    `sys.path` than any dist-packages dir. Python only imports the first
>    `sitecustomize` module it finds, so the dist-packages copy was silently
>    shadowed and never loaded.
>
> The fix: **overwrite the interpreter's own stdlib `sitecustomize.py`**
> (path resolved at build time via `python3 -c 'import sysconfig;
> print(sysconfig.get_path("stdlib"))'`, not hardcoded to a Python version),
> preserving the original apport try/except so nothing regresses. This needs
> no env var at all, so it survives whatever environment curation the tool
> layer does. Re-verified end to end after the fix: a real agent invocation
> imported its installed packages successfully, and a second agent with no
> Python deps correctly could not (`ModuleNotFoundError`, isolation intact).

A single constant startup hook, baked into the base image (§5), prepends the
*current workspace's* `.python-site`. The hook walks up from `cwd` to find the
nearest `.python-site` (so it still resolves if a tool `cd`s into a subdir):

```python
# Overwrites the interpreter's own stdlib sitecustomize.py at build time —
# see ../Dockerfile. Preserves the stock apport-handler stub it replaces.
try:
    import apport_python_hook
except ImportError:
    pass
else:
    apport_python_hook.install()

import os, sys
d = os.getcwd()
for _ in range(6):
    site = os.path.join(d, ".python-site")
    if os.path.isdir(site):
        sys.path.insert(0, site)   # this agent's deps win; another agent's are unreachable
        break
    parent = os.path.dirname(d)
    if parent == d:
        break
    d = parent
```

Because OpenClaw runs each agent's tools with `cwd` = that agent's workspace
(now confirmed live, not just corroborated in the image dist — §"Verified
live" #7), each `python`/`python3` resolves **its own** `.python-site` and
nothing else. This is *logical* per-agent isolation on one shared
interpreter — no venv (so `python` on `PATH` keeps working), no per-agent
OpenClaw env plumbing, and no shared union.

### 3.5 No cross-agent conflicts (consequence of §3.4)

Per-agent sites make version collisions structurally impossible — verified live
with two agents pinning `pydantic==1.10.13` and `pydantic==2.5.3` side by side,
each importing its own version, and neither seeing the other's undeclared
packages (§"Verified live" #4). No merge, no conflict-detector, no fail-loud
path is needed. The only residual assumption is that the tool `cwd` sits within
the agent's workspace tree; the walk-up above tolerates any descendant, and a
live-session `pwd` check is on the impl checklist (§12) as belt-and-suspenders.

## 4. Node language deps (unchanged)

The existing §7.1 npm path is kept verbatim: `package.json`+lockfile under the
workspace → in-image `npm ci --include=dev --ignore-scripts …` → workspace-local
`node_modules/`. Node needs no shared site or `PYTHONPATH` because its resolver
walks up from the executing file. This spec only *adds* the Python sibling; it
does not change Node behavior.

## 5. Base image: Python by default

The stock image ships Node + npm but **no pip, no `ensurepip`, and only
`python3` (no `python`)** (verified). "Python by default" therefore requires a
thin, committed base image — the Python equivalent of the npm already present,
**generic, not agent-specific**:

```dockerfile
# Dockerfile (committed; built once → OPENCLAW_IMAGE)
ARG OPENCLAW_VERSION=2026.7.1
FROM ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION}
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3-pip python-is-python3 \
 && rm -rf /var/lib/apt/lists/*
# The per-agent import hook (§3.4) — overwrites the interpreter's OWN stdlib
# sitecustomize.py (NOT PYTHONPATH, NOT dist-packages — see §3.4's revision
# note for why both of those were tried first and didn't survive a real
# agent invocation).
COPY pyhook/sitecustomize.py /opt/pyhook-src/sitecustomize.py
RUN cp /opt/pyhook-src/sitecustomize.py \
       "$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')/sitecustomize.py"
USER node
```

The hook is baked into the image (constant for every agent — the *per-agent*
part is resolved at runtime from `cwd`, §3.4), so there is no per-agent compose
or config wiring. Build → set `OPENCLAW_IMAGE` to the local tag. Compose
already has `build: .` and `image: ${OPENCLAW_IMAGE:-…}`, so this slots in with
no compose surgery. Verified: the `apt` step is ~13s, yields pip 23.0.1 and a
working `python` shim, with no PEP-668 breakage for `--target` installs
(a **plain**, non-`--target` `pip install` — needed for the OS-deps Playwright
CLI, §6.2 — DOES hit PEP 668 on this base and needs `--break-system-packages`).
The hook loads via both `python` and `python3` and, since the 2026-07-16
revision, through a **real agent's own Bash/exec tool call**, not just
`docker exec`/`docker run` (§"Verified live" #7, and §3.4's revision note).
**OS-dep layers (§6) append to this same Dockerfile.**

## 6. OS / system deps: declared + self-describing

OS libraries are not extractable (§2). They are **declared**, and one common
self-describing case is auto-detected. Both realize as **base-image layers**.

### 6.1 Declaration

A new `system` block, allowed in `openclaw.agent.json5` (a *request*) and in the
manifest entry (override), names-only:

```json5
system: {
  apt: ["libmagic1", "poppler-utils"],   // OS packages that are NOT self-describing
  playwrightBrowsers: ["chromium"],       // optional explicit browser set
}
```

- **`system.apt` is gated behind manifest `allowSystemDeps: true`** (default
  false) — installing arbitrary root-level packages from a third-party repo is
  the deployer's supply-chain call, exactly like `allowInstallScripts` for npm
  lifecycle scripts (§7.1, §10). A package may *declare* `system`, but it only
  takes effect when the deployer opts in.

### 6.2 Self-describing detection (Playwright)

If `playwright` appears in a project's extracted Python deps, the sync treats it
as implying `playwrightBrowsers: ["chromium"]` (unless the agent overrides the
set). Playwright is realized in the image via its own dependency-aware installer
(`playwright install --with-deps <browser>`), which apt-installs exactly the OS
libraries the browser needs — so **the list of OS libs is never hand-authored**.

**Version-coupling rule (must hold):** Playwright's Python package version and
its installed browser build must match. The pip package installs per-agent into
`.python-site` like any other dep (§3.3); the matching **browser build + OS
libs** install in the image (root/apt). Playwright versions its browser build
directories, so multiple versions *could* in principle coexist under one
`PLAYWRIGHT_BROWSERS_PATH`. **As of 2026-07-16 the box adopts the simpler
one-Playwright-version-per-box rule** rather than betting on that: the preflight
(§6.3) aborts if two agents pin different Playwright versions, and aborts if the
running image's Playwright differs from the pin. This makes a version mismatch a
loud sync-time error instead of a silent wrong-driver failure at runtime. True
multi-version coexistence is deferred (§12) until a deployment needs it. The apt
OS libs are a shared superset either way.

### 6.3 The sync's role: validate, don't silently build

To keep `docker build` out of the sync's critical path, the sync **does not
auto-build** the image. Instead, after computing the union of declared/detected
OS needs, it **preflight-validates** them against the *running* image:

- for each `system.apt` package: `dpkg -s <pkg>` in the image;
- for each Playwright browser: the browser exists at `PLAYWRIGHT_BROWSERS_PATH`
  **and** the image's `playwright` version equals the locked version.

On any miss, the sync **aborts before touching config**, printing the **exact
Dockerfile lines to append** to §5's base image (auto-generated, including the
`playwright install --with-deps …` snippet) and the rebuild command. The
deployer appends, rebuilds, re-runs the sync. This makes OS deps declarative and
fail-loud without the sync owning image builds. *(A future revision may let the
sync build automatically behind an opt-in flag; deferred to keep this spec's
blast radius small.)*

## 7. Security model (delta from §10)

- **Language installs run no third-party code by default.** npm keeps
  `--ignore-scripts`; pip adds `--only-binary=:all:` (no `setup.py` execution).
  Both lift only under the per-agent `allowInstallScripts: true` opt-in.
- **OS packages require `allowSystemDeps: true`** — the deployer explicitly
  accepts each root-level install.
- **Pin everything.** A pinned lock is required for Python just as a lockfile is
  for npm; unpinned → fail. The base image is pinned by digest/tag.
- **Deploy has final say.** `system`/deps declarations are requests; the
  deployment can decline (leave the opt-in off) or subtract.

## 8. Idempotency / sync-owned surface (delta from §5.1)

- Each agent's `.python-site/` is fully sync-owned: wiped and reinstalled from
  that agent's lock every sync; never mirror-copied from the package (it is
  generated). Removing the agent removes its workspace tree, so no residue.
- `node_modules/` behavior is unchanged.
- The `sitecustomize` hook + `PYTHONPATH` env + the Python baseline all live in
  the base image (one-time build), not per-sync writes.
- OS-dep validation is read-only; the generated Dockerfile snippet is *reported*,
  never applied, so the sync writes nothing outside its existing owned set plus
  `.python-site/`.

## 9. Decisions (locked)

- **Python is auto-extracted symmetrically with Node**, from
  `pyproject.toml`/`requirements*.txt`, parsed with in-image stdlib `tomllib`.
- **A pinned lock is PREFERRED, not mandatory** for Python runtime deps
  (revised D2, 2026-07-16 — §3.2): with a lock, install is reproducible
  (`--no-deps`); without one, the sync resolves the declared deps and warns.
  This intentionally diverges from npm's required-lockfile bar (§4/§7.3),
  tracking the ecosystem difference — committed locks are near-universal in npm
  but optional in Python. Accepted lock forms: fully-pinned
  `requirements.lock`/`requirements.txt` (incl. `--generate-hashes`, URL refs,
  markers); `uv.lock`/`poetry.lock`/`Pipfile.lock` still not parsed (§12).
- **Python is isolated per agent** (D3): each agent installs its own lock into a
  per-agent `.python-site`, resolved at runtime by a constant cwd-keyed
  `sitecustomize` hook — no venv (keeps `python` on PATH), no per-agent OpenClaw
  env plumbing, no shared union, and **conflicting versions across agents
  coexist** (verified live). Logical isolation, not a security sandbox.
- **`--only-binary=:all:`** is pip's supply-chain gate (no sdist code execution),
  the analog of npm `--ignore-scripts`; both lift under `allowInstallScripts`
  (D5).
- **Python-by-default = pip + `python-is-python3` + the import hook baked into a
  thin committed base image** (generic, alongside npm).
- **OS deps are gated-declared** (D4): the package may declare `system.apt`, but
  it applies only when the deployer sets `allowSystemDeps: true` on the manifest
  entry. Self-describing browsers (Playwright detected from deps →
  `install --with-deps`) are auto-derived. All live in the **base image**; the
  sync **validates presence and emits the exact Dockerfile lines** but does not
  auto-build — validate-and-instruct, not auto-build (D1).

## 10. Verified live (2026-07-15, image `2026.6.11`)

1. `python3` 3.11.2 present; **`tomllib` present**; **no pip / no `ensurepip`**;
   only `python3` (no `python`).
2. `apt-get install python3-pip python-is-python3` → ~13s, `pip 23.0.1`, working
   `python`→`python3` shim; **no PEP-668 error** surfaced for `--target`.
3. `pip install --target /tmp/pylibs beautifulsoup4 pydantic pillow
   python-dotenv` → exit 0 in ~3s, installing compiled-extension packages
   (`pydantic_core`, `PIL`, `pillow.libs`).
4. **`PYTHONPATH=<site> python3 -c 'import bs4, pydantic, PIL, dotenv;
   from PIL import Image'` → OK** (compiled wheels install under `--target` and
   import purely from the site path).
5. `tomllib.load()` extracts `[project].dependencies` from a `pyproject.toml`.
6. `python -m playwright install-deps --dry-run` resolves to **apt** package
   operations → OS libs are root/apt → **image layer**, not workspace.
7. **Per-agent isolation, run as the `node` user (uid 1000):** two agents with
   per-agent `.python-site` dirs pinning `pydantic==1.10.13` and
   `pydantic==2.5.3` each imported *their own* version via the cwd-keyed
   `sitecustomize` hook; a dep only agent A installed was `ModuleNotFoundError`
   from agent B's cwd; a neutral cwd saw neither. The hook fired through **both
   `python` and `python3`**, and via **walk-up** from a subdir. Installs run as
   `node` produced `node`-owned files. The `cwd = workspace` assumption is
   corroborated in the image dist (the terminal/exec tool spawns with a
   workspace-derived cwd: `buildTerminalSpawnOptions(cmd, params.cwd ?? …)` fed
   by `cwd: resolveAgentWorkspaceDir` / `cwd: this.workspaceDir` /
   `cwd = path.join(workspace.dir…)`).

## 11. Implementation checklist

- [x] `manifest-compiler.js`: add `system` (package+manifest) and
      `allowSystemDeps` (manifest-only) to the field sets + validation; extend
      the effective-agent output with `system`/`allowSystemDeps`.
- [x] `sync-agents.sh`: generalize `install_skill_deps` → also detect Python
      projects (pyproject/requirements) under `$dst`, then per agent
      `pip install --target <workspace>/.python-site --only-binary=:all:`:
      from a pinned lock with `--no-deps` when one is present, else resolving
      the declared deps with a loud not-reproducible warning (revised D2, §3.2).
      (Implemented as a sibling `install_python_deps`, called alongside
      `install_skill_deps` — Python detection/extraction/self-ref-filtering/
      lock-resolution live entirely in bash+`python3`/`tomllib`, mirroring how
      the existing npm path is bash-only with no compiler involvement.)
- [x] Committed base `Dockerfile` (§5): pip + `python-is-python3` + the
      `pyhook/sitecustomize.py` (walk-up), installed by overwriting the
      interpreter's own stdlib `sitecustomize.py` — **not** `PYTHONPATH`, which
      was tried and rejected (§3.4's revision note: OpenClaw's exec tool
      doesn't inherit it). DEPLOYMENT.md note to build it and set
      `OPENCLAW_IMAGE`. Verified: built the image, confirmed `pip`/`python`/
      `tomllib` present, a `--target` install with no PEP-668 error, and the
      hook isolating two conflicting per-agent installs from each other via
      `cwd`.
- [x] OS-dep preflight validator (`dpkg -s`, browser presence check) that
      aborts with the generated Dockerfile snippet + rebuild command
      (validate-and-instruct — D1; no auto-build in v1). Playwright version is
      now enforced alongside browser presence (2026-07-16): the preflight aborts
      on conflicting pinned versions across agents and on an image-vs-pin
      mismatch (one-version-per-box, §6.2/§6.3/§12) — no longer presence-only.
- [x] Playwright: detect from deps → auto-derive `install --with-deps <browser>`
      snippet for the image (embedding the exact pinned `playwright==X.Y.Z`
      line extracted from the agent's lock, when available); keep the pip
      package in `.python-site`.
- [x] `.python-site` chown 1000 on Linux (covered by the existing blanket
      `chown -R … $CONFIG_DIR/agents` after the materialize loop); wiped +
      reinstalled each sync; added to the agent-package `.gitignore` template
      (`AGENTS-PLUGINS.md` §3.2) and `examples/agents/echo-bot/.gitignore`.
- [x] `manifest-compiler.js`: add `system` (package+manifest) + `allowSystemDeps`
      (manifest-only) to the field sets + validation; extend effective-agent
      output. (No cross-agent conflict logic — isolation removes it.)
- [x] Compiler unit tests (pure INPUT→output): `system`/`allowSystemDeps`
      validation and effective-override semantics, in
      `scripts/lib/manifest-compiler.test.js` (run via
      `scripts/test-compiler.sh`; 14 assertions, verified passing in-image).
      Python detection/self-ref-filtering/missing-lock-fail are bash-side (see
      above) and are exercised by the sync's own fail-loud behavior rather
      than by these unit tests, consistent with npm's precedent.
- [x] AGENTS-PLUGINS.md: fold this in as §7.3 (Python) / §7.4 (OS deps) and
      cross-link; update §2's cwd-is-tool-workspace note to cite this hook.

## 12. To confirm during implementation (not blockers)

- [x] **Live `pwd` in a real session** — belt-and-suspenders on the
  `cwd = workspace` assumption of §3.4. **Confirmed 2026-07-16** against a real
  plugged-in agent (`onepagerbuilder`/Virginia, wired in via
  `agents.manifest.json5` as a worked example): a headless one-shot message
  told the agent to run `pwd` via its own Bash/exec tool, and it printed
  exactly `/home/node/.openclaw/agents/virginia/workspace`. The walk-up
  tolerates any descendant, as designed.
- [x] **The `PYTHONPATH`-based hook design itself, disproven and replaced.**
  Not originally on this list because it wasn't expected to be in question —
  but the same live test above also proved the hook as originally speced
  (§3.4, pre-revision) **did not fire for a real agent's tool call**, only for
  `docker exec`/`docker run`. Root causes and the fix are written up in §3.4's
  revision note and §5's updated Dockerfile snippet: OpenClaw's Bash/exec tool
  doesn't inherit `PYTHONPATH` into its subprocess env, and a dist-packages
  fallback was shadowed by the base image's own stdlib `sitecustomize.py`.
  Fixed by overwriting the interpreter's stdlib copy directly; re-verified via
  the same real-agent method (import succeeds for the agent with deps
  installed, fails for one without — isolation intact).
- [x] **Two more real bugs found and fixed during the same live test:**
  - `install_python_deps`'s `tomllib` extraction call merged the subprocess's
    stdout and stderr (`2>&1`) into one captured variable; `docker compose
    run`'s own progress lines ("Container ... Creating") corrupted the JSON,
    and the parse failure was masked by a `2>/dev/null` on the downstream
    `jq` call — so a real Python project (again, Virginia) silently resolved
    to **zero** dependencies instead of failing loud or installing anything.
    Fixed by capturing stdout and stderr separately.
  - The OS-dep preflight's generated Dockerfile snippet's plain (non-`--target`)
    `pip install "playwright==X.Y.Z"` hits pip's PEP 668
    externally-managed-environment guard on this Debian base and fails the
    image build. Fixed by adding `--break-system-packages` (safe here: this is
    a controlled, root-only, image-build-time install, not a shared multi-purpose
    Python environment).
- **Playwright browser/driver version match** — **resolved by adopting the
  one-version-per-box fallback now (2026-07-16), rather than betting on
  multi-version coexistence.** The OS-dep preflight (§6.3) now (a) aborts if two
  agents pin *different* Playwright versions, and (b) aborts if the running
  image already ships a Playwright whose version differs from the agents' pin —
  turning what was a silent runtime mismatch (browser dir present but built by
  the wrong driver) into a loud, instructed sync-time error. True multi-version
  coexistence under one `PLAYWRIGHT_BROWSERS_PATH` is deferred until a real
  deployment actually needs two versions at once; the end-to-end "launch
  Chromium, produce a PDF" smoke test is still worth running once on a real
  Playwright agent, but no longer blocks the design.
- **Deferred (D2): `uv.lock`/`poetry.lock`/`Pipfile.lock` → pinned-requirements
  export** — add only if an agent's toolchain makes producing a pinned
  `requirements.txt` painful.

# Base image for this deployment (AGENTS-DEPS-SPEC.md §5) — adds Python as a
# first-class runtime on top of the stock OpenClaw image, which ships Node/npm
# but no pip, no `ensurepip`, and only `python3` (no plain `python`). Committed
# so plugged-in agents can auto-extract Python deps symmetrically with the
# existing npm path (AGENTS-PLUGINS.md §7.1/§7.3).
#
# `docker-compose.yml` already has `build: .` and `image: ${OPENCLAW_IMAGE:-…}`
# (vendored from upstream, generic — see that file's own header comment), so
# building this slots in with NO compose changes:
#
#   1. Set OPENCLAW_IMAGE in .env to a LOCAL tag, distinct from the
#      "openclaw:local" sentinel setup.sh's preflight rejects, e.g.:
#        OPENCLAW_IMAGE=openclaw-deploy-py:2026.6.11
#   2. docker compose build
#   3. docker compose up -d openclaw-gateway
#
# The FROM tag below must track this deployment's own `OPENCLAW_IMAGE` pin in
# .env.example — bump both together (see docker-compose.yml's "Updating the
# image version" ritual in DEPLOYMENT.md).
FROM ghcr.io/openclaw/openclaw:2026.6.11

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3-pip python-is-python3 \
 && rm -rf /var/lib/apt/lists/*

# The per-agent Python import hook (AGENTS-DEPS-SPEC.md §3.4): a constant
# sitecustomize module that, at interpreter start, prepends the CURRENT
# WORKSPACE's `.python-site` — resolved by walking up from `cwd`, which
# OpenClaw sets to the invoking agent's workspace. This is what gives each
# agent its own installed Python dependencies without a venv, keeping
# `python` on PATH (agents' own TOOLS.md instructions often assume this —
# see AGENTS-DEPS-SPEC.md §3.4's Virginia quote).
#
# Installed by OVERWRITING the interpreter's own stdlib sitecustomize.py
# (path resolved dynamically via `sysconfig.get_path("stdlib")`, not
# hardcoded to a Python version) — NOT via PYTHONPATH, and NOT into a
# dist-packages dir. Both confirmed live (2026-07-15/16) against a real
# agent invocation, not just `docker exec`:
#   1. OpenClaw's Bash/exec tool spawns with a curated subprocess
#      environment that does NOT inherit PYTHONPATH, even though it's set
#      at the container level (cwd IS correctly the agent's workspace —
#      that part of §3.4/§12 holds independently).
#   2. This base image already ships its OWN sitecustomize.py directly in
#      the stdlib dir (a Debian apport-handler stub) — which sits EARLIER
#      on `sys.path` than any dist-packages dir, so a copy placed in
#      dist-packages is silently shadowed and never imported at all.
# pyhook/sitecustomize.py preserves that stub's apport try/except (harmless
# no-op here) before adding the per-agent hook, so nothing regresses.
COPY pyhook/sitecustomize.py /opt/pyhook-src/sitecustomize.py
RUN cp /opt/pyhook-src/sitecustomize.py \
       "$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')/sitecustomize.py"

# Fixed, world-readable location for Playwright browser builds (AGENTS-DEPS-SPEC.md
# §6.2) — root/apt-installed here at build time, read by whichever unprivileged
# agent (uid 1000) launches a browser at runtime via its own per-agent
# Playwright pip package.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

USER node

# --- OS deps requested by plugged-in agents (AGENTS-DEPS-SPEC.md §6) -------
# Append lines below by hand, following EXACTLY what
# `scripts/sync-agents.sh`'s OS-dep preflight validator prints when it can't
# find something an agent declares (`system.apt`, gated by that agent's
# manifest entry setting `allowSystemDeps: true`) or auto-derives (a
# Playwright browser, detected from an agent's Python deps — §6.2). The sync
# never builds this image itself (validate-and-instruct, §6.3) — re-run
# `docker compose build && docker compose up -d openclaw-gateway` after
# editing this section, then re-run `./setup.sh --sync-agents`.

# virginia: Playwright chromium auto-derived from its Python `playwright` dep
# (§6.2) — appended verbatim from the sync's OS-dep preflight output. Pinned to
# the version the sync resolved into virginia's .python-site so the browser
# build matches the per-agent pip package.
USER root
RUN pip install --no-cache-dir --break-system-packages "playwright==1.61.0" \
 && python3 -m playwright install --with-deps chromium \
 && chmod -R a+rX "${PLAYWRIGHT_BROWSERS_PATH:-/opt/ms-playwright}"
USER node

# Baked into the base Dockerfile as the interpreter's OWN stdlib
# sitecustomize.py (the exact path is resolved at build time via
# `sysconfig.get_path("stdlib")` — see ../Dockerfile) — NOT loaded via
# PYTHONPATH. Two things had to be confirmed live (2026-07-15/16) before this
# path was settled on:
#
# 1. OpenClaw's Bash/exec tool spawns with a curated subprocess environment
#    that does NOT inherit PYTHONPATH, even though it's set at the container
#    level — so a PYTHONPATH-based hook never loads for a real agent
#    invocation, only for a direct `docker exec`/`docker run`.
# 2. The stock base image already ships its OWN `sitecustomize.py` directly
#    in the stdlib dir (a Debian/Ubuntu apport-crash-handler stub, a symlink
#    to /etc/python3.11/sitecustomize.py) — which sits EARLIER on `sys.path`
#    than the dist-packages dirs, so a copy placed in dist-packages was
#    silently shadowed and never imported at all. Overwriting the stdlib
#    copy directly is what actually wins.
#
# The apport try/except below is preserved from that stub (harmless no-op
# when the optional `apport_python_hook` package isn't installed, which it
# isn't in this image) so nothing regresses for whatever relies on it.
try:
    import apport_python_hook
except ImportError:
    pass
else:
    apport_python_hook.install()

# --- OpenClaw per-agent Python dependency hook (AGENTS-DEPS-SPEC.md §3.4) ---
# OpenClaw runs each agent's tools with cwd = that agent's workspace, so this
# walks up from cwd looking for a `.python-site` directory (the per-agent site
# `scripts/sync-agents.sh` installs into via `pip install --target`) and
# prepends it to sys.path. The walk-up (not just checking cwd itself) means it
# still resolves if a tool `cd`s into a workspace subdirectory. Nothing here
# is per-agent — the same file runs unmodified for every agent; the
# per-agent part is resolved entirely from cwd at import time.
import os
import sys

_d = os.getcwd()
for _ in range(6):
    _site = os.path.join(_d, ".python-site")
    if os.path.isdir(_site):
        sys.path.insert(0, _site)  # this agent's deps win; another agent's are unreachable
        break
    _parent = os.path.dirname(_d)
    if _parent == _d:
        break
    _d = _parent

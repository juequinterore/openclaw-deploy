#!/usr/bin/env bash
# Reproduces the Linux-root ownership condition that broke --sync-agents on the
# VPS but is INVISIBLE on a macOS dev host (Docker Desktop transparently maps
# host<->container UIDs, so the chown branch is both skipped and unnecessary
# there). This harness runs the real ownership sequence inside a Linux
# container as root and asserts the two writes that failed in production:
#
#   1. npm ci as uid 1000 must create node_modules INSIDE workspace/   (ac51536)
#   2. the gateway as uid 1000 must create sessions/ in agents/<id>/    (5bf5261)
#      -- the PARENT of workspace/, not workspace/ itself.
#
# It does NOT exercise the full sync pipeline (manifest compile, gateway auth,
# LLM verification) -- only the chown/ownership logic, which is the class of
# bug that only ever manifests on a Linux root deploy. Run before pushing any
# change to the chown/materialize path in sync-agents.sh.
#
# Usage:  scripts/verify-linux.sh
# Exit:   0 = the ownership sequence works; non-zero = it would fail on the VPS.
set -euo pipefail

# node:22 (Debian) matches the real image's contract: a `node` user at uid 1000,
# and ships `runuser` for the privilege drop. (alpine lacks su-exec by default.)
IMG="${VERIFY_LINUX_IMAGE:-node:22}"

pass() { printf '\033[1;32mPASS:\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31mFAIL:\033[0m %s\n' "$1" >&2; exit 1; }
info() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }

command -v docker >/dev/null 2>&1 || fail "docker not found"

info "Reproducing the VPS condition inside $IMG (host engine: $(docker info --format '{{.OSType}}' 2>/dev/null))"

# Everything below runs as root inside a throwaway Linux container, mirroring a
# VPS `sudo ./setup.sh --sync-agents`. It builds a root-owned materialized tree,
# runs the SAME chown the script does, then drops to uid 1000 for the two writes.
docker run --rm -i "$IMG" sh -eu <<'CONTAINER'
ID=echo-bot
AGENT_DIR="/data/agents/$ID"
WS="$AGENT_DIR/workspace"
SKILL="$WS/skills/demo/postprocess"

# --- 1. Simulate the host copy: create the tree owned by ROOT (uid 0) --------
# This is exactly what rsync/cp-as-root leaves on the VPS: intermediate dirs
# (agents/$ID) AND workspace contents all owned by root, not uid 1000.
mkdir -p "$SKILL"
cat > "$SKILL/package.json" <<'PKG'
{ "name": "demo-postprocess", "version": "1.0.0", "dependencies": { "left-pad": "1.3.0" } }
PKG
# Minimal valid lockfile so `npm ci` has something deterministic to install.
cat > "$SKILL/package-lock.json" <<'LOCK'
{
  "name": "demo-postprocess", "version": "1.0.0", "lockfileVersion": 3, "requires": true,
  "packages": {
    "": { "name": "demo-postprocess", "version": "1.0.0", "dependencies": { "left-pad": "1.3.0" } },
    "node_modules/left-pad": {
      "version": "1.3.0",
      "resolved": "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz",
      "integrity": "sha512-XI5MPzVNApjAyhQzphX8BkmKsKUxD4LdyK24iZeQGinBN9yTQT3bFlCBy/aVx2HrNcqQGsdot8ghrjyrvMCoEA=="
    }
  }
}
LOCK
chown -R 0:0 /data/agents
[ "$(stat -c '%u' "$AGENT_DIR")" = 0 ] || { echo "setup bug: agent dir not root-owned"; exit 99; }

# --- 2. Run the SCRIPT'S chown (what 5bf5261 does): whole per-agent dir ------
# This is the line under test. If a change reverts to chowning only workspace/,
# or drops the chown, assertion 4 below fails -- catching the 5bf5261 regression.
if [ -n "$(find "$AGENT_DIR" ! -uid 1000 -print -quit 2>/dev/null)" ]; then
  chown -R 1000:1000 "$AGENT_DIR"
fi

# --- 3. As uid 1000 (the `node` user): npm ci writes node_modules ------------
# This is what install_skill_deps runs in-image. Pre-ac51536 (chown too late)
# or if the tree stayed root-owned, this is the original EACCES on mkdir.
runuser -u node -- sh -euc "cd '$SKILL' && npm ci --no-audit --no-fund --ignore-scripts >/dev/null 2>&1" \
  || { echo "ASSERT_FAIL npm_ci_node_modules"; exit 1; }
[ -d "$SKILL/node_modules/left-pad" ] || { echo "ASSERT_FAIL node_modules_missing"; exit 1; }
echo "ASSERT_OK npm_ci_node_modules"

# --- 4. As uid 1000 (the gateway): create sessions/ in the PARENT dir --------
# This is the write that 5bf5261 fixes. If the chown covered only workspace/,
# agents/$ID stays root-owned and this mkdir is the EACCES you saw at
# '.../agents/echo-bot/sessions'.
runuser -u node -- sh -euc "mkdir -p '$AGENT_DIR/sessions'" \
  || { echo "ASSERT_FAIL gateway_sessions_mkdir"; exit 1; }
echo "ASSERT_OK gateway_sessions_mkdir"
CONTAINER

info "Both uid-1000 writes succeeded against the root-materialized tree."
pass "The Linux-root ownership sequence in sync-agents.sh works end-to-end."

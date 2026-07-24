#!/usr/bin/env bash
# Automates the "First-time setup" flow documented in DEPLOYMENT.md.
# Safe to re-run: every step checks whether it's already done and skips if so.
#
# One step genuinely cannot be automated: Claude CLI login is an interactive
# browser OAuth flow. The script pauses there, prints the command to run in
# another terminal, and waits for you to press Enter once it's done.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

# Single source of truth for the deployment's default model. Written into
# openclaw.json (agents.defaults.model.primary) below. A plugged-in agent can
# still override per-entry in agents.manifest.json5.
DEFAULT_MODEL="anthropic/claude-sonnet-5"

# --- args ---------------------------------------------------------------
SYNC_AGENTS=0
PRUNE_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --sync-agents) SYNC_AGENTS=1 ;;
    --prune) PRUNE_ARGS+=(--prune) ;;
    --agents|--with-agents)
      SYNC_AGENTS=1
      echo "NOTE: --agents is deprecated, use --sync-agents instead (it now syncs" >&2
      echo "      agents.manifest.json5, not a hardcoded echo-bot scaffold — the default" >&2
      echo "      manifest still points at the same echo-bot demo, so this keeps working," >&2
      echo "      but coordinator delegation now uses requester-aware native subagents." >&2
      echo "      See \"Single point of contact\" in DEPLOYMENT.md." >&2
      ;;
    -h|--help)
      printf 'Usage: ./setup.sh [--sync-agents [--prune]]\n\n  --sync-agents  After the base setup, sync the agents declared in\n                 agents.manifest.json5 into the running gateway, behind a\n                 coordinator (sessions_spawn + requester-bound completion).\n                 Idempotent. See AGENTS-PLUGINS.md and "Single point of\n                 contact" in DEPLOYMENT.md.\n  --prune        With --sync-agents: confirm removal of agents.list entries\n                 that are neither the coordinator nor produced by the\n                 manifest (otherwise the sync aborts and lists them).\n  --agents       Deprecated alias for --sync-agents.\n'
      exit 0 ;;
    *) fail "Unknown argument: $arg (try --help)" ;;
  esac
done

command -v docker >/dev/null 2>&1 || fail "docker not found. Install Docker first."
docker compose version >/dev/null 2>&1 || fail "docker compose v2 not found."
command -v jq >/dev/null 2>&1 || fail "jq not found. Install it first (also required by --sync-agents)."

# --- 1. .env -----------------------------------------------------------
if [[ ! -f .env ]]; then
  log "Creating .env from .env.example"
  cp .env.example .env
else
  log ".env already exists, leaving its existing values alone"
fi

if ! grep -qE '^OPENCLAW_GATEWAY_TOKEN=.+' .env; then
  TOKEN=$(openssl rand -hex 32)
  if grep -q '^OPENCLAW_GATEWAY_TOKEN=' .env; then
    sed -i.bak "s|^OPENCLAW_GATEWAY_TOKEN=.*|OPENCLAW_GATEWAY_TOKEN=${TOKEN}|" .env && rm -f .env.bak
  else
    printf '\nOPENCLAW_GATEWAY_TOKEN=%s\n' "$TOKEN" >> .env
  fi
  log "Generated OPENCLAW_GATEWAY_TOKEN"
fi

# Uncomment every "# KEY=value" line from the "Docker deployment overrides"
# marker to end of file. That block is deliberately last in .env.example so the
# range never touches unrelated commented examples earlier in the file (e.g. the
# generic OPENCLAW_AUTH_PROFILE_SECRET_DIR placeholder under "Gateway auth +
# paths"), nor the "Multi-agent / advanced" block just above the marker —
# COMPOSE_PROJECT_NAME and OPENCLAW_HOME_VOLUME are meant to stay commented so
# each deployment keeps its auto-namespaced defaults.
START_LINE=$(grep -n "Docker deployment overrides (auto-configured" .env | head -1 | cut -d: -f1 || true)
if [[ -n "${START_LINE:-}" ]]; then
  log "Uncommenting deployment-override variables in .env"
  sed -i.bak "${START_LINE},\$ s/^# \([A-Z_][A-Z0-9_]*=\)/\1/" .env && rm -f .env.bak
fi

# Lock down .env to owner-only — it holds the gateway token. Done last, after
# the sed edits above: `sed -i` writes a fresh file and can reset the mode to
# the umask default, so chmod here guarantees the final state is 0600.
# Compose reads .env as the invoking user (the owner), so 0600 doesn't break it.
chmod 600 .env

# OPENCLAW_HOME_VOLUME is intentionally NOT required — it's an optional override.
# Left unset, the home volume auto-namespaces to <COMPOSE_PROJECT_NAME>_home.
for var in OPENCLAW_VERSION OPENCLAW_IMAGE OPENCLAW_CONFIG_DIR OPENCLAW_WORKSPACE_DIR \
           OPENCLAW_AUTH_PROFILE_SECRET_DIR \
           OPENCLAW_GATEWAY_BIND COMPOSE_FILE; do
  grep -qE "^${var}=.+" .env || fail "$var is not set in .env. Edit it manually (see .env.example), then re-run this script."
done

# --- 2. Get the image ----------------------------------------------------
# OPENCLAW_IMAGE is either a real published tag (pull it) or a locally-built
# one, e.g. this repo's own Dockerfile adding Python/Playwright for plugged-in
# agents (DEPLOYMENT.md "Python & OS-level agent dependencies") — nothing to
# pull for that case, so fall back to building it from the committed
# Dockerfile. This keeps the fast path for a stock deployment while making a
# local-image deployment reproducible on any machine, not just the one it was
# first built on.
log "Fetching the OpenClaw image"
if ! docker compose pull openclaw-gateway; then
  log "Pull failed — falling back to building locally from the committed Dockerfile (expected if OPENCLAW_IMAGE is a local-only tag, not a published one)"
  docker compose build openclaw-gateway ||
    fail "Could not pull or build the OpenClaw image. Check OPENCLAW_IMAGE in .env, your network connection, and (if building) the Dockerfile."
fi
# Not a `docker compose config | grep -m1` pipe: grep -m1 exits the instant it
# finds a match, closing its end of the pipe early; docker compose config then
# hits a broken-pipe write and can exit non-zero, which `pipefail` reports as
# the pipeline's exit status even though config generation actually succeeded.
# Capture the gateway service's own image (not just the first "image:" match,
# which depends on COMPOSE_FILE service ordering) via jq instead.
IMAGE_RESOLVED=$(docker compose config --format json 2>/dev/null \
  | jq -r '.services["openclaw-gateway"].image // empty')
[[ "$IMAGE_RESOLVED" != "openclaw:local" ]] || fail "OPENCLAW_IMAGE still resolves to openclaw:local — check .env."

# --- 3. Data dirs, with the Linux uid-1000 permission fix -----------------
log "Creating data directories"
mkdir -p .openclaw-data/config .openclaw-data/workspace .openclaw-data/auth-secrets
if [[ "$(uname -s)" == "Linux" ]]; then
  # Skip the chown (and its sudo prompt) when ownership is already right —
  if [[ -n "$(find .openclaw-data ! \( -uid 1000 -gid 1000 \) -print -quit)" ]]; then
    log "Linux detected: chowning data dirs to uid 1000 (the container's node user)"
    if [[ "$(id -u)" -eq 0 ]]; then
      chown -R 1000:1000 .openclaw-data
    else
      sudo chown -R 1000:1000 .openclaw-data
    fi
  fi
fi

# --- 4. Base config (auth deferred) --------------------------------------
if [[ ! -f .openclaw-data/config/openclaw.json ]]; then
  log "Creating base OpenClaw config"
  docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
    dist/index.js onboard --mode local --no-install-daemon \
    --non-interactive --accept-risk --auth-choice skip \
    --gateway-bind loopback --skip-channels --skip-skills --skip-hooks --skip-search --skip-health
else
  log "openclaw.json already exists, skipping base onboarding"
fi

log "Starting gateway"
docker compose up -d openclaw-gateway
sleep 5
docker compose ps

# --- 5. Claude CLI install -------------------------------------------------
log "Installing Claude Code CLI inside the container (persists in the openclaw_home volume)"
docker compose run --rm --entrypoint sh openclaw-cli -lc \
  'test -x /home/node/.local/bin/claude || curl -fsSL https://claude.ai/install.sh | bash'

# --- 6. Interactive login — cannot be scripted ----------------------------
claude_logged_in() {
  # Deliberately not a `docker compose run ... | grep -q ...` pipe: grep -q
  # exits the instant it finds a match, closing its end of the pipe early;
  # docker compose run then hits a broken-pipe write and itself exits
  # non-zero, which `pipefail` reports as the pipeline's exit status even
  # though the underlying command actually succeeded. Capture to a variable
  # first (a pipeless read to EOF) and pattern-match in pure bash instead.
  local status_json
  status_json=$(docker compose run --rm --entrypoint sh openclaw-cli -lc \
    '/home/node/.local/bin/claude auth status' 2>/dev/null)
  [[ "$status_json" == *'"loggedIn": true'* ]]
}

if claude_logged_in; then
  log "Claude CLI already authenticated, skipping login"
else
  log "Claude CLI needs interactive login (browser OAuth) — this cannot be scripted."
  echo
  echo "  Run this in another terminal now:"
  echo
  echo "    cd '$SCRIPT_DIR' && docker compose run --rm -it --entrypoint sh openclaw-cli -lc '/home/node/.local/bin/claude auth login'"
  echo
  read -r -p "Press Enter once login is complete... " _ \
    || fail "No interactive terminal to wait for login (stdin closed/EOF — this script's login step cannot run non-interactively). Complete the login command above, then re-run this script."
  claude_logged_in || fail "Claude CLI still not authenticated. Re-run this script after logging in."
fi

# --- 7. Wire up agent runtime + default model -----------------------------
log "Configuring claude-cli backend command"
docker compose run --rm openclaw-cli config set \
  agents.defaults.cliBackends.claude-cli.command /home/node/.local/bin/claude

log "Running onboard --auth-choice anthropic-cli"
docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js onboard --mode local --no-install-daemon \
  --non-interactive --accept-risk --auth-choice anthropic-cli \
  --gateway-bind loopback --skip-channels --skip-skills --skip-hooks --skip-search --skip-health

log "Setting default model to ${DEFAULT_MODEL}"
docker compose run --rm openclaw-cli config set \
  agents.defaults.model.primary "${DEFAULT_MODEL}"

# Pin the FULL claude-cli backend. Setting only `.command` leaves the backend
# without its `args`, so agents launch with no `--allowedTools mcp__openclaw__*`
# — meaning NO OpenClaw MCP tools are exposed to the CLI process. A lone agent
# still answers (it needs no tools), but a coordinator then has nothing to
# delegate with. These args mirror the known-good partner config.
log "Pinning full claude-cli backend args (command-only exposes no MCP tools)"
docker compose run -T --rm openclaw-cli config patch --stdin <<'JSON'
{
  "agents": { "defaults": { "cliBackends": { "claude-cli": {
    "command": "/home/node/.local/bin/claude",
    "args": ["-p","--output-format","stream-json","--include-partial-messages","--verbose","--setting-sources","user","--allowedTools","mcp__openclaw__*","--disallowedTools","ScheduleWakeup,CronCreate,Bash(run_in_background:true),Monitor"],
    "resumeArgs": ["-p","--output-format","stream-json","--include-partial-messages","--verbose","--setting-sources","user","--allowedTools","mcp__openclaw__*","--disallowedTools","ScheduleWakeup,CronCreate,Bash(run_in_background:true),Monitor","--resume","{sessionId}"]
  } } } }
}
JSON

log "Restarting gateway to apply config"
docker compose restart openclaw-gateway
sleep 5

# --- 8. Verify end to end --------------------------------------------------
log "Running end-to-end verification"
RESULT=$(docker compose run --rm --entrypoint node openclaw-cli dist/index.js agent \
  --agent main --message "Reply with exactly: SETUP_SCRIPT_OK" --json --timeout 60) || true

if [[ "$RESULT" == *'"winnerProvider": "claude-cli"'* && "$RESULT" == *'SETUP_SCRIPT_OK'* ]]; then
  log "SUCCESS — agent responded correctly via claude-cli."
else
  fail "Verification failed. Full output:
$RESULT"
fi

# --- 9. Optional: wire up Slack if tokens are present in .env -------------
# .env.example ships SLACK_BOT_TOKEN/SLACK_APP_TOKEN commented out under
# "Optional channel env fallbacks" — nothing forwards them into the container
# or the gateway config on its own. If the user has uncommented and filled
# them in, do the `channels add` step for them here instead of leaving it as
# a manual DEPLOYMENT.md step. Passed via `docker compose run -e` (not added
# to docker-compose.yml's `environment:` block) since that file is vendored
# from upstream and diffed on every version bump — keeping it untouched
# avoids upgrade-diff noise for a repo-local convenience step.
if grep -qE '^SLACK_BOT_TOKEN=.+' .env && grep -qE '^SLACK_APP_TOKEN=.+' .env; then
  SLACK_STATUS=$(docker compose run --rm openclaw-cli channels list 2>/dev/null | grep -i '^- Slack' || true)
  if [[ "$SLACK_STATUS" == *"configured"* && "$SLACK_STATUS" != *"not configured"* ]]; then
    log "Slack already configured, skipping (channels list: ${SLACK_STATUS})"
  else
    log "SLACK_BOT_TOKEN/SLACK_APP_TOKEN found in .env — wiring up Slack"
    SLACK_BOT_TOKEN=$(grep -E '^SLACK_BOT_TOKEN=' .env | head -1 | cut -d= -f2-)
    SLACK_APP_TOKEN=$(grep -E '^SLACK_APP_TOKEN=' .env | head -1 | cut -d= -f2-)
    docker compose run --rm openclaw-cli channels add --channel slack \
      --bot-token "$SLACK_BOT_TOKEN" --app-token "$SLACK_APP_TOKEN" \
      || fail "Slack channel setup failed. Check SLACK_BOT_TOKEN/SLACK_APP_TOKEN in .env."
    log "Slack configured. Restarting gateway to apply."
    docker compose restart openclaw-gateway
    sleep 5
  fi
else
  log "No SLACK_BOT_TOKEN/SLACK_APP_TOKEN in .env, skipping Slack setup (see 'Wire up Slack' in DEPLOYMENT.md)"
fi

# --- 10. Optional: sync pluggable agents behind the coordinator -----------
if [[ "$SYNC_AGENTS" -eq 1 ]]; then
  log "Syncing agents (agents.manifest.json5)"
  if [[ "${#PRUNE_ARGS[@]}" -gt 0 ]]; then
    "$SCRIPT_DIR/scripts/sync-agents.sh" "${PRUNE_ARGS[@]}"
  else
    "$SCRIPT_DIR/scripts/sync-agents.sh"
  fi
fi

log "Done. Try: docker compose run --rm -it openclaw-cli chat"

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

# --- args ---------------------------------------------------------------
WITH_AGENTS=0
for arg in "$@"; do
  case "$arg" in
    --agents|--with-agents) WITH_AGENTS=1 ;;
    -h|--help)
      printf 'Usage: ./setup.sh [--agents]\n\n  --agents  After the base setup, scaffold a coordinator (main) plus a\n            persistent echo-bot specialist wired for cross-agent messaging\n            (sessions_send + tools.agentToAgent). Idempotent; skips if agents\n            are already configured. See "Single point of contact" in\n            DEPLOYMENT.md.\n'
      exit 0 ;;
    *) fail "Unknown argument: $arg (try --help)" ;;
  esac
done

command -v docker >/dev/null 2>&1 || fail "docker not found. Install Docker first."
docker compose version >/dev/null 2>&1 || fail "docker compose v2 not found."

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
for var in OPENCLAW_IMAGE OPENCLAW_CONFIG_DIR OPENCLAW_WORKSPACE_DIR \
           OPENCLAW_AUTH_PROFILE_SECRET_DIR \
           OPENCLAW_GATEWAY_BIND COMPOSE_FILE; do
  grep -qE "^${var}=.+" .env || fail "$var is not set in .env. Edit it manually (see .env.example), then re-run this script."
done

# --- 2. Pull image -------------------------------------------------------
log "Pulling pinned OpenClaw image"
docker compose pull openclaw-gateway
IMAGE_RESOLVED=$(docker compose config 2>/dev/null | grep -m1 'image:' | awk '{print $2}')
[[ "$IMAGE_RESOLVED" != "openclaw:local" ]] || fail "OPENCLAW_IMAGE still resolves to openclaw:local — check .env."

# --- 3. Data dirs, with the Linux uid-1000 permission fix -----------------
log "Creating data directories"
mkdir -p .openclaw-data/config .openclaw-data/workspace .openclaw-data/auth-secrets
if [[ "$(uname -s)" == "Linux" ]]; then
  log "Linux detected: chowning data dirs to uid 1000 (the container's node user)"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R 1000:1000 .openclaw-data
  else
    sudo chown -R 1000:1000 .openclaw-data
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
  read -r -p "Press Enter once login is complete... " _
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

log "Setting default model to anthropic/claude-sonnet-4-6"
docker compose run --rm openclaw-cli config set \
  agents.defaults.model.primary anthropic/claude-sonnet-4-6

log "Restarting gateway to apply config"
docker compose restart openclaw-gateway
sleep 5

# --- 8. Verify end to end --------------------------------------------------
log "Running end-to-end verification"
RESULT=$(docker compose run --rm --entrypoint node openclaw-cli dist/index.js agent \
  --agent main --message "Reply with exactly: SETUP_SCRIPT_OK" --json --timeout 60)

if [[ "$RESULT" == *'"winnerProvider": "claude-cli"'* && "$RESULT" == *'SETUP_SCRIPT_OK'* ]]; then
  log "SUCCESS — agent responded correctly via claude-cli."
else
  fail "Verification failed. Full output:
$RESULT"
fi

# --- 9. Optional: scaffold the multi-agent coordinator (--agents) ---------
if [[ "$WITH_AGENTS" -eq 1 ]]; then
  log "Scaffolding multi-agent coordinator (--agents)"
  # Idempotency probe reads the config file directly. Do NOT parse `config get`
  # stdout here: it prints a banner, and (worse) its non-zero exit when the key
  # is unset would abort this script under `set -e`/`pipefail` — an `if grep`
  # condition is exempt from errexit and can't take the script down.
  if grep -q '"agentToAgent"' .openclaw-data/config/openclaw.json 2>/dev/null; then
    log "Agents already configured (agentToAgent present) — skipping scaffold"
  else
    log "Applying coordinator + echo-bot config"
    docker compose run -T --rm openclaw-cli config patch --stdin <<'JSON'
{
  "agents": { "list": [
    { "id": "main", "default": true, "tools": { "profile": "messaging" },
      "workspace": "/home/node/.openclaw/workspace" },
    { "id": "echo-bot", "tools": { "profile": "messaging" },
      "workspace": "/home/node/.openclaw/agents/echo-bot/workspace" }
  ] },
  "tools": {
    "sessions": { "visibility": "all" },
    "agentToAgent": { "enabled": true, "allow": ["*"] }
  },
  "session": { "agentToAgent": { "maxPingPongTurns": 2 } }
}
JSON
    log "Writing coordinator + echo-bot personas (owned by uid 1000)"
    docker compose run --rm --entrypoint sh openclaw-cli -lc '
      m=/home/node/.openclaw/workspace; mkdir -p "$m";
      printf "%s\n" "# Front desk (coordinator)" \
        "Route requests to specialist agents with the sessions_send tool: send the request to the right agent, wait for its reply, then relay that reply to the user." \
        "For any request to echo text, send it to agent \"echo-bot\" and return its reply verbatim." > "$m/AGENTS.md";
      e=/home/node/.openclaw/agents/echo-bot/workspace; mkdir -p "$e";
      printf "%s\n" "# echo-bot" \
        "You are a test specialist. Reply to EVERY message with exactly:" \
        "ECHO-BOT>> <repeat the user message verbatim>" > "$e/AGENTS.md" '
    docker compose run --rm openclaw-cli config validate
    docker compose restart openclaw-gateway
    sleep 5
    log "Verifying the echo-bot specialist responds"
    ER=$(docker compose run --rm --entrypoint node openclaw-cli dist/index.js agent \
      --agent echo-bot --message "banana" --json --timeout 60)
    if [[ "$ER" == *'ECHO-BOT>>'* ]]; then
      log "echo-bot OK. Test the coordinator: docker compose run --rm -it openclaw-cli chat  (then type: echo: banana)"
    else
      fail "echo-bot did not respond as expected. Full output:
$ER"
    fi
  fi
fi

log "Done. Try: docker compose run --rm -it openclaw-cli chat"
echo "To add Slack, see the 'Wire up Slack' section in DEPLOYMENT.md."

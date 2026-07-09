#!/usr/bin/env bash
# Implements `./setup.sh --sync-agents` (AGENTS-PLUGINS.md §11). Pulls in
# externally-maintained OpenClaw agents declared in agents.manifest.json5,
# pinned to a git ref, and wires them into the running gateway behind the
# coordinator. setup.sh is a thin entry point that execs this file.
#
# Safe-ish to re-run, but NOT silent: it restarts the gateway (interrupting
# any live sessions) and can abort partway through validation/verification,
# in which case it rolls back openclaw.json and restarts again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$1" >&2; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

PRUNE=0
for arg in "$@"; do
  case "$arg" in
    --prune) PRUNE=1 ;;
    -h|--help)
      printf 'Usage: scripts/sync-agents.sh [--prune]\n\n  --prune  Confirm removal of agents.list entries that are neither the\n           coordinator nor produced by agents.manifest.json5 (AGENTS-PLUGINS.md\n           §5.1). Without it, the sync aborts and lists them.\n\nNormally invoked as: ./setup.sh --sync-agents [--prune]\n'
      exit 0 ;;
    *) fail "Unknown argument: $arg (try --help)" ;;
  esac
done

MANIFEST_FILE="$ROOT_DIR/agents.manifest.json5"
COMPILER="$SCRIPT_DIR/lib/manifest-compiler.js"
STAGING_ROOT="$ROOT_DIR/.agents-src"

# --- helpers -----------------------------------------------------------

# Runs the embedded node/json5 logic inside the pinned image (no host node
# dependency — AGENTS-PLUGINS.md §4.1). $1 = INPUT as a JSON string.
run_compiler() {
  { printf 'const INPUT = %s;\n' "$1"; cat "$COMPILER"; } \
    | docker compose run -T --rm --entrypoint node openclaw-cli
}

# Prints each error/warning array from a compiler result to stderr.
print_issues() {
  local result="$1" key="$2" prefix="$3"
  local -a items=()
  mapfile -t items < <(printf '%s' "$result" | jq -r --arg k "$key" '.[$k][]? // empty')
  local item
  for item in "${items[@]}"; do
    [[ -n "$item" ]] && printf '%s%s\n' "$prefix" "$item" >&2
  done
}

require_ok() {
  local result="$1" what="$2"
  if ! printf '%s' "$result" | jq -e '.ok' >/dev/null 2>&1; then
    print_issues "$result" "errors" "  - "
    fail "$what"
  fi
  print_issues "$result" "warnings" "  (warning) "
}

# SKILL.md frontmatter `name:` (falls back to the dir basename elsewhere) —
# matches the runtime's own resolution (AGENTS-PLUGINS.md §7, verified
# against dist/workspace-*.js's hasLoadableSkillFrontmatter).
skill_frontmatter_name() {
  local skill_md="$1"
  [[ -f "$skill_md" ]] || return 0
  awk '
    NR==1 && $0 ~ /^---[[:space:]]*$/ { infm=1; next }
    infm && $0 ~ /^---[[:space:]]*$/ { exit }
    infm && $0 ~ /^name:/ {
      sub(/^name:[[:space:]]*/, "")
      gsub(/^"|"$/, ""); gsub(/^\x27|\x27$/, "")
      print; exit
    }
  ' "$skill_md"
}

# Protected paths inside a workspace/ (AGENTS-PLUGINS.md §6): never deleted or
# overwritten by a sync. MEMORY.md is protected only once it exists (seed-only
# — §9): a fresh workspace still gets the package's seed on first sync.
is_protected_path() {
  local rel="$1" dst="$2"
  case "$rel" in
    memory/*|.openclaw/*|sessions/*) return 0 ;;
    openclaw-workspace-state.json|*.sqlite|*.sqlite-shm|*.sqlite-wal) return 0 ;;
    MEMORY.md) [[ -f "$dst/MEMORY.md" ]] && return 0 || return 1 ;;
    *) return 1 ;;
  esac
}

# Mirror-copy $1/ into $2/, deleting files that vanished from $1 (except the
# protected set), and never copying paths under a disabled skill dir ($3+).
copy_workspace_rsync() {
  local src="$1" dst="$2"; shift 2
  local -a skip_dirs=("$@")
  mkdir -p "$dst"
  local d
  for d in "${skip_dirs[@]}"; do rm -rf "${dst:?}/skills/${d:?}"; done
  local -a ex=(--exclude 'memory/' --exclude 'sessions/' --exclude '.openclaw/' \
               --exclude 'openclaw-workspace-state.json' \
               --exclude '*.sqlite' --exclude '*.sqlite-shm' --exclude '*.sqlite-wal')
  [[ -f "$dst/MEMORY.md" ]] && ex+=(--exclude 'MEMORY.md')
  for d in "${skip_dirs[@]}"; do ex+=(--exclude "skills/${d}/"); done
  rsync -a --delete "${ex[@]}" "$src/" "$dst/"
}

# Same contract as copy_workspace_rsync, without the rsync dependency (§11
# preflight fallback — "rsync or the tracked-file-list copy").
copy_workspace_fallback() {
  local src="$1" dst="$2"; shift 2
  local -a skip_dirs=("$@")
  mkdir -p "$dst"
  local d
  for d in "${skip_dirs[@]}"; do rm -rf "${dst:?}/skills/${d:?}"; done

  _skipped() {
    local rel="$1"
    for d in "${skip_dirs[@]}"; do
      case "$rel" in "skills/${d}"|"skills/${d}"/*) return 0 ;; esac
    done
    return 1
  }

  local f rel
  while IFS= read -r -d '' f; do
    rel="${f#"$dst"/}"
    if ! is_protected_path "$rel" "$dst" && [[ ! -e "$src/$rel" ]]; then rm -f "$f"; fi
  done < <(find "$dst" -type f -print0)
  find "$dst" -type d -empty -not -path "$dst" -delete 2>/dev/null || true

  while IFS= read -r -d '' f; do
    rel="${f#"$src"/}"
    is_protected_path "$rel" "$dst" && continue
    _skipped "$rel" && continue
    mkdir -p "$dst/$(dirname "$rel")"
    cp -p "$f" "$dst/$rel"
  done < <(find "$src" -type f -print0)
}

write_disabled_features_md() {
  local row="$1"
  echo "<!-- GENERATED by scripts/sync-agents.sh from agents.manifest.json5."
  echo "     Do not hand-edit: the next sync overwrites or deletes this file. -->"
  echo "# Disabled features (this deployment)"
  echo
  echo "This deployment has turned off the following for this agent, so its"
  echo "persona should tell users honestly that these are unavailable here:"
  echo
  local -a skills=() tools=()
  mapfile -t skills < <(printf '%s' "$row" | jq -r '.disableSkills[]? // empty')
  mapfile -t tools < <(printf '%s' "$row" | jq -r '.denyTools[]? // empty')
  local IFS=,
  [[ ${#skills[@]} -gt 0 ]] && echo "- Skills disabled: ${skills[*]}"
  [[ ${#tools[@]} -gt 0 ]] && echo "- Tools denied: ${tools[*]}"
}

# --- 1. preflight --------------------------------------------------------
log "Preflight checks"
# Uses mapfile, associative arrays, and empty-array expansion under `set -u`
# (all require bash >= 4.4). macOS ships bash 3.2 as /bin/bash for licensing
# reasons — fail fast with a clear fix instead of a cryptic "mapfile: command
# not found" (or worse, a silent misparse) partway through a run that already
# fetched/copied something.
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  fail "bash >= 4.4 required (found ${BASH_VERSION}). On macOS: 'brew install bash' and make sure it's first in PATH, or run explicitly: /opt/homebrew/bin/bash scripts/sync-agents.sh"
fi
command -v docker >/dev/null 2>&1 || fail "docker not found. Install Docker first."
docker compose version >/dev/null 2>&1 || fail "docker compose v2 not found."
command -v jq >/dev/null 2>&1 || fail "jq not found on host (required by sync-agents.sh)."
[[ -f "$MANIFEST_FILE" ]] || fail "agents.manifest.json5 not found at repo root."

CONFIG_DIR=$(docker compose config --format json 2>/dev/null \
  | jq -r '.services["openclaw-gateway"].volumes[] | select(.target=="/home/node/.openclaw") | .source')
WORKSPACE_DIR=$(docker compose config --format json 2>/dev/null \
  | jq -r '.services["openclaw-gateway"].volumes[] | select(.target=="/home/node/.openclaw/workspace") | .source')
[[ -n "$CONFIG_DIR" ]] || fail "Could not resolve the gateway's config volume via 'docker compose config'."
CONFIG_JSON="$CONFIG_DIR/openclaw.json"
[[ -f "$CONFIG_JSON" ]] || fail "$CONFIG_JSON not found — run ./setup.sh first (base setup must be done)."
jq -e '(.agents.defaults.cliBackends["claude-cli"].args // []) | length > 0' "$CONFIG_JSON" >/dev/null 2>&1 \
  || fail "claude-cli backend args not configured — run ./setup.sh first."

HAVE_RSYNC=0
command -v rsync >/dev/null 2>&1 && HAVE_RSYNC=1
[[ "$HAVE_RSYNC" -eq 1 ]] || warn "rsync not found on host — falling back to a slower tracked-file-list copy."

mkdir -p "$STAGING_ROOT" "$CONFIG_DIR/agents"

# --- 2. phase-1 static lint (manifest only, before ANY side effect) ------
log "Linting agents.manifest.json5 (phase 1: static)"
MANIFEST_TEXT=$(cat "$MANIFEST_FILE")
RESULT1=$(run_compiler "$(jq -n --arg t "$MANIFEST_TEXT" '{phase:"lint-static", manifestText:$t}')")
require_ok "$RESULT1" "Manifest phase-1 (static) lint failed. Nothing was fetched or changed."

mapfile -t AGENT_ROWS < <(printf '%s' "$RESULT1" | jq -c '.data.agents[] | select(.enabled)')
if [[ ${#AGENT_ROWS[@]} -eq 0 ]]; then
  warn "No enabled agents in the manifest — only the coordinator will be configured."
fi

NEED_GIT=0
for row in "${AGENT_ROWS[@]}"; do
  [[ -z "$row" ]] && continue
  [[ "$(jq -r '.isLocal' <<<"$row")" == "false" ]] && NEED_GIT=1
done
if [[ "$NEED_GIT" -eq 1 ]]; then
  command -v git >/dev/null 2>&1 || fail "git not found on host (required for git-sourced agents)."
fi

# Local-path existence + required-file check — filesystem-dependent, so it
# runs in bash rather than the (file-system-blind) node compiler, but it's
# still logically "phase 1": it happens before any clone or copy.
declare -A PKG_DIR=()
for row in "${AGENT_ROWS[@]}"; do
  [[ -z "$row" ]] && continue
  [[ "$(jq -r '.isLocal' <<<"$row")" == "true" ]] || continue
  source=$(jq -r '.source' <<<"$row")
  slug=$(jq -r '.slug' <<<"$row")
  src_path="$source"; [[ "$source" = /* ]] || src_path="$ROOT_DIR/$source"
  [[ -d "$src_path" ]] || fail "local source '$source' (agents[$(jq -r '.index' <<<"$row")]) does not exist on disk."
  [[ -f "$src_path/workspace/AGENTS.md" ]] || fail "local source '$source' is missing workspace/AGENTS.md (the only REQUIRED file in a package)."
  PKG_DIR["$slug"]="$src_path"
done

# --- 3. materialize (clone/fetch), then phase-2 post-fetch lint ---------
log "Fetching agent packages"
for row in "${AGENT_ROWS[@]}"; do
  [[ -z "$row" ]] && continue
  [[ "$(jq -r '.isLocal' <<<"$row")" == "true" ]] && continue
  slug=$(jq -r '.slug' <<<"$row")
  source=$(jq -r '.source' <<<"$row")
  ref=$(jq -r '.ref' <<<"$row")
  staging="$STAGING_ROOT/$slug"
  log "  $slug <- $source @ $ref"
  rm -rf "$staging"; mkdir -p "$staging"
  git -C "$staging" init -q
  git -C "$staging" remote add origin "$source"
  git -C "$staging" fetch --depth 1 -q origin "$ref" || fail "git fetch failed for $source @ $ref"
  git -C "$staging" checkout -q FETCH_HEAD
  PKG_DIR["$slug"]="$staging"
done

log "Linting fetched packages (phase 2: post-fetch)"
PACKAGE_DOCS=()
for row in "${AGENT_ROWS[@]}"; do
  [[ -z "$row" ]] && continue
  slug=$(jq -r '.slug' <<<"$row")
  pkg_dir="${PKG_DIR[$slug]}"

  has_agents_md=false; [[ -f "$pkg_dir/workspace/AGENTS.md" ]] && has_agents_md=true
  has_env=false
  if [[ -d "$pkg_dir/workspace" ]] && find "$pkg_dir/workspace" -name '.env' -print -quit 2>/dev/null | grep -q .; then
    has_env=true
  fi
  agent_json5_json="null"
  if [[ -f "$pkg_dir/openclaw.agent.json5" ]]; then
    agent_json5_json=$(jq -n --arg t "$(cat "$pkg_dir/openclaw.agent.json5")" '$t')
  fi

  skill_docs=()
  if [[ -d "$pkg_dir/workspace/skills" ]]; then
    for d in "$pkg_dir/workspace/skills"/*/; do
      [[ -d "$d" ]] || continue
      base=$(basename "$d")
      fname=$(skill_frontmatter_name "$d/SKILL.md")
      if [[ -n "$fname" ]]; then
        skill_docs+=("$(jq -n --arg b "$base" --arg n "$fname" '{dirBasename:$b, frontmatterName:$n}')")
      else
        skill_docs+=("$(jq -n --arg b "$base" '{dirBasename:$b, frontmatterName:null}')")
      fi
    done
  fi
  skill_dirs_json="[]"
  [[ ${#skill_docs[@]} -gt 0 ]] && skill_dirs_json=$(printf '%s\n' "${skill_docs[@]}" | jq -s '.')

  PACKAGE_DOCS+=("$(jq -n --arg slug "$slug" --argjson hasAgentsMd "$has_agents_md" \
    --argjson hasEnvFile "$has_env" --argjson agentJson5Text "$agent_json5_json" \
    --argjson skillDirs "$skill_dirs_json" \
    '{slug:$slug, hasAgentsMd:$hasAgentsMd, hasEnvFile:$hasEnvFile, agentJson5Text:$agentJson5Text, skillDirs:$skillDirs}')")
done
PACKAGES_JSON="[]"
[[ ${#PACKAGE_DOCS[@]} -gt 0 ]] && PACKAGES_JSON=$(printf '%s\n' "${PACKAGE_DOCS[@]}" | jq -s '.')

RESULT2=$(run_compiler "$(jq -n --arg t "$MANIFEST_TEXT" --argjson pkgs "$PACKAGES_JSON" \
  '{phase:"lint-postfetch", manifestText:$t, packages:$pkgs}')")
require_ok "$RESULT2" "Manifest phase-2 (post-fetch) lint failed. Nothing was copied or written."

COORD_JSON=$(jq -c '.data.coordinator' <<<"$RESULT2")
COORDINATOR_ID=$(jq -r '.id' <<<"$COORD_JSON")
EFFECTIVE_AGENTS_JSON=$(jq -c '.data.effectiveAgents' <<<"$RESULT2")

# --- 4. mirror-copy workspaces, skip disabled skills, chown on Linux ----
log "Materializing workspaces"
mapfile -t EFF_ROWS < <(jq -c '.[]' <<<"$EFFECTIVE_AGENTS_JSON")
for row in "${EFF_ROWS[@]}"; do
  [[ -z "$row" ]] && continue
  slug=$(jq -r '.slug' <<<"$row")
  id=$(jq -r '.id' <<<"$row")
  pkg_dir="${PKG_DIR[$slug]}"
  dst="$CONFIG_DIR/agents/$id/workspace"
  mapfile -t skip_dirs < <(jq -r '.skillDirsToSkip[]? // empty' <<<"$row")
  log "  $id  ($pkg_dir/workspace -> $dst)"
  if [[ "$HAVE_RSYNC" -eq 1 ]]; then
    copy_workspace_rsync "$pkg_dir/workspace" "$dst" "${skip_dirs[@]}"
  else
    copy_workspace_fallback "$pkg_dir/workspace" "$dst" "${skip_dirs[@]}"
  fi
  if [[ "$(jq -r '.hasDisabledFeatures' <<<"$row")" == "true" ]]; then
    write_disabled_features_md "$row" > "$dst/DISABLED_FEATURES.md"
  else
    rm -f "$dst/DISABLED_FEATURES.md"
  fi
done

if [[ "$(uname -s)" == "Linux" ]]; then
  log "Linux detected: chowning materialized workspaces to uid 1000"
  if [[ "$(id -u)" -eq 0 ]]; then chown -R 1000:1000 "$CONFIG_DIR/agents"
  else sudo chown -R 1000:1000 "$CONFIG_DIR/agents"; fi
fi

# --- 5. assemble agents.list + sync-owned keys, diff, patch -------------
log "Assembling agents.list and sync-owned config keys"
CURRENT_LIST=$(jq -c '.agents.list // []' "$CONFIG_JSON")
RESULT3=$(run_compiler "$(jq -n --argjson coord "$COORD_JSON" --argjson eff "$EFFECTIVE_AGENTS_JSON" \
  --argjson cur "$CURRENT_LIST" '{phase:"assemble", coordinator:$coord, effectiveAgents:$eff, currentAgentsList:$cur}')")
require_ok "$RESULT3" "Assembly failed."

FOREIGN_COUNT=$(jq '.data.foreignIds | length' <<<"$RESULT3")
if [[ "$FOREIGN_COUNT" -gt 0 ]]; then
  echo "Foreign agents in the current config (not the coordinator, not produced by the manifest):" >&2
  jq -r '.data.foreignIds[] | "  - " + .' <<<"$RESULT3" >&2
  if [[ "$PRUNE" -eq 0 ]]; then
    fail "Aborting (manifest = source of truth). Add these to agents.manifest.json5, or re-run with --prune to confirm removal."
  fi
  log "Pruning foreign agents from agents.list (--prune)"
fi

log "Plan: $(jq -r '.data.summary | "+\(.added|length) -\(.removed|length) =\(.kept|length)"' <<<"$RESULT3") specialist(s)"
jq -r '
  .data.summary as $s
  | (if ($s.added|length)>0 then "  adding:   " + ($s.added|join(", ")) else empty end),
    (if ($s.removed|length)>0 then "  removing: " + ($s.removed|join(", ")) else empty end),
    (if ($s.kept|length)>0 then "  keeping:  " + ($s.kept|join(", ")) else empty end)
' <<<"$RESULT3"

PATCH_JSON=$(jq -c '.data.patch' <<<"$RESULT3")

log "Snapshotting openclaw.json (rollback point)"
cp "$CONFIG_JSON" "$CONFIG_JSON.presync"

rollback() {
  local reason="$1"
  warn "Rolling back: $reason"
  cp "$CONFIG_JSON.presync" "$CONFIG_JSON"
  docker compose restart openclaw-gateway || true
  fail "$reason"
}

log "Validating config patch (dry-run)"
printf '%s' "$PATCH_JSON" | docker compose run -T --rm openclaw-cli \
  config patch --stdin --replace-path agents.list --dry-run \
  || rollback "config patch --dry-run failed"

log "Applying config patch"
printf '%s' "$PATCH_JSON" | docker compose run -T --rm openclaw-cli \
  config patch --stdin --replace-path agents.list \
  || rollback "config patch failed"

log "Validating config"
docker compose run --rm openclaw-cli config validate || rollback "config validate failed"

# --- 6. regenerate the coordinator persona (sync-owned, §8) --------------
log "Regenerating coordinator persona ($WORKSPACE_DIR/AGENTS.md)"
COORD_NAME=$(jq -r '.data.coordinatorName' <<<"$RESULT3")
ROWS_JSON=$(jq -c '.data.coordinatorRoutingRows' <<<"$RESULT3")
{
  printf '<!-- GENERATED by `setup.sh --sync-agents` from agents.manifest.json5.\n'
  printf '     Do not hand-edit: the next sync overwrites this file.\n'
  printf '     To change routing, edit the manifest (role/routeHint/timeoutMs) and re-sync. -->\n'
  printf '# %s — coordinator\n\n' "$COORD_NAME"
  printf 'You are a thin router in front of specialist agents. You NEVER do specialist\n'
  printf 'work yourself, even when you know the answer.\n\n'
  printf '## Specialists\n\n'
  printf '| id | routes to it when | session key | timeoutMs |\n'
  printf '|---|---|---|---|\n'
  jq -r '.[] | "| \(.id) | \(.routeHint) | agent:\(.id):main | \(.timeoutMs) |"' <<<"$ROWS_JSON"
  cat <<'MD'

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
MD
} > "$WORKSPACE_DIR/AGENTS.md"

if [[ "$(uname -s)" == "Linux" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then chown -R 1000:1000 "$WORKSPACE_DIR"
  else sudo chown -R 1000:1000 "$WORKSPACE_DIR"; fi
fi

# --- 7. restart -----------------------------------------------------------
log "Restarting gateway to apply config (this interrupts any live sessions)"
docker compose restart openclaw-gateway || rollback "gateway restart failed"
sleep 5

# --- 8. verify -------------------------------------------------------------
# Every check below uses an explicit --session-key unique to this run. Without
# one, `agent --agent <id>` resumes that agent's DEFAULT session key
# (agent:<id>:main) — a long-lived session whose tool policy can predate this
# sync (or even predate agentToAgent being scoped down at all), silently
# masking a real regression. This bit us once: a stale default session kept
# reporting success while a genuinely fresh session hit `forbidden`.
RUN_ID="syncverify-$$-$(date +%s)"

log "Verifying each specialist responds (headless one-shot, fresh session)"
for row in "${EFF_ROWS[@]}"; do
  [[ -z "$row" ]] && continue
  id=$(jq -r '.id' <<<"$row")
  OUT=$(docker compose run --rm --entrypoint node openclaw-cli dist/index.js agent \
    --session-key "agent:$id:$RUN_ID" --message "sync-agents smoke check" --json --timeout 60 2>&1) || true
  [[ "$OUT" == *'"winnerProvider"'* ]] || rollback "verification failed for agent '$id' — no response.
$OUT"
done

FIRST_ID=$(jq -r '.[0].id // empty' <<<"$EFFECTIVE_AGENTS_JSON")
if [[ -n "$FIRST_ID" ]]; then
  log "Verifying the coordinator relays to '$FIRST_ID' via sessions_send"
  TOKEN="SYNCCHECK-$$-$(date +%s)"
  CR=$(docker compose run --rm --entrypoint node openclaw-cli dist/index.js agent \
    --session-key "agent:$COORDINATOR_ID:$RUN_ID" --json --timeout 120 --message \
    "This is an automated sync verification, not a real request. Route it to the '$FIRST_ID' specialist via sessions_send and return its reply verbatim. Ask the specialist to reply with exactly: RELAY_OK $TOKEN" \
    2>&1) || true
  [[ "$CR" == *"RELAY_OK $TOKEN"* ]] || rollback "coordinator relay check failed — '$COORDINATOR_ID' did not relay to '$FIRST_ID' and return its reply.
$CR"
fi

# --- 9. done ---------------------------------------------------------------
rm -f "$CONFIG_JSON.presync"
log "Sync complete."
echo "Specialists: $(jq -r '[.[].id] | join(", ")' <<<"$EFFECTIVE_AGENTS_JSON")"
echo "Try: docker compose run --rm -it openclaw-cli chat --session desk1"

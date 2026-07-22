# Slack app manifests

`app-manifest.example.yaml` is a reusable template for creating a Slack app
for an OpenClaw agent deployment. It is **not** used by `setup.sh` or any
script here — Slack manifests are pasted manually into
[api.slack.com/apps](https://api.slack.com/apps) → **Create New App** →
**From an app manifest**. Kept in-repo purely so the scope/event choices (and
the reasoning behind them) survive between agents instead of living only in
chat history.

Per `DEPLOYMENT.md`, each agent deployment gets its own Slack app (own bot +
app token, no shared routing) — copy the template per agent rather than
reusing one manifest/app across deployments.

## Usage

1. Copy the template (don't edit it in place, so it stays a clean baseline):
   ```bash
   cp slack/app-manifest.example.yaml slack/<agent-name>.yaml
   ```
2. Fill in `display_information.name`/`description` and
   `features.bot_user.display_name`.
3. Uncomment only the scopes/events the agent actually needs — every
   commented-out line has a note explaining what it unlocks and why it isn't
   on by default (least-privilege: this is a single-operator agent, so Slack
   scopes are the outermost blast-radius control if the bot token leaks).
4. Paste the result into Slack's manifest editor for a new app, or into an
   existing app's manifest view (App Settings → the "..." menu → *edit in
   YAML*) to update scopes/features.
5. **Reinstall to Workspace** (OAuth & Permissions) — required after any
   scope/feature change, and it rotates the bot token. Update the new token
   wherever it's configured:
   ```bash
   docker compose run --rm openclaw-cli channels add --channel slack \
     --bot-token "xoxb-..." --app-token "xapp-..."
   ```
   then restart the gateway so it picks up the config change.
6. If `features.app_home.messages_tab_enabled` doesn't take effect, double
   check `messages_tab_read_only_enabled: false` — Slack's UI for this is the
   "Allow users to send Slash commands and messages from the messages tab"
   checkbox under App Home, and it's easy to miss even when the manifest sets
   it correctly, since some Slack UI paths don't reflect it live.

## AI Assistant surface ("New chat" button)

The `features.assistant_view` block (paired with the `assistant:write` scope)
turns on Slack's AI Assistant panel — the "New chat" button, suggested
prompts, dedicated sidebar. This is a genuinely different integration surface,
not a cosmetic toggle: the app starts receiving `assistant_thread_started` /
`assistant_thread_context_changed` events and is expected to respond via the
Assistant API (`assistant.threads.setStatus`,
`assistant.threads.setSuggestedPrompts`, etc.), not just plain
`message.im`/`app_mention` replies. Only include it if the agent's code
actually handles that flow — otherwise the button opens a thread the bot
never acknowledges. Delete the block entirely for a plain conversational bot.

## Socket Mode

`settings.socket_mode_enabled: true` is load-bearing for this template's
deployment model: the gateway connects *outbound* to Slack, so the VPS never
needs an inbound port or public endpoint (see DEPLOYMENT.md's
"no inbound network access" topology). Don't disable it unless you're
deliberately moving off that topology.

# Long-Running Specialist "False Timeout" — Investigation & Findings

**Status: FIXED (2026-07-17).** The final implementation uses requester-aware
native subagents: `sessions_spawn` starts the specialist,
`message` posts the working acknowledgement to the source conversation, and
`sessions_yield` leaves the coordinator subscribed to the child's completion
event. The gateway then wakes `main` and delivers its completed-result reply
to the recorded Discord/Slack/etc. origin. The sync-owned config patch also
raises the `claude-cli` resumed-session no-output watchdog from 60s to 180s as
defense-in-depth.

An intermediate dispatch-then-poll implementation is documented below because
it fixed the coordinator crash, but its claimed proactive-delivery extension
was wrong. Live Discord testing proved that `sessions_send`'s later
`mode:"announce"` delivery resolves the **target specialist session**
(`agent:virginia:main`, internal `webchat`), not the Discord session that
requested the work. `main` is never woken, so granting it `message` cannot
deliver anything. That is why the final fix replaces the dispatch primitive
rather than adding another poller.

Referenced briefly in [README.md](./README.md)'s "Known limitations" — this
is the full writeup.

## Symptom

Dispatching a multi-minute specialist task (`virginia`'s company-research
one-pager, `sallie`'s HubSpot lead intake) through the coordinator (`main`)
reports a timeout to the user — sometimes after well under a minute — even
though the specialist's task is genuinely still running and **completes
successfully moments later**, unseen. Raising the specialist's `timeoutMs` in
`agents.manifest.json5` (tried: 180000 → 600000 for virginia) had **no
effect** on when the failure occurred.

## Root cause (confirmed via live reproduction + compiled source)

`main` runs as an underlying `claude -p ...` CLI process. When `main` calls
`sessions_send` to a specialist, that specialist's own turn can take minutes.
The problem: **`main`'s own CLI process does not reliably stay alive for the
full duration of that nested call.** In multiple clean reproductions
(fresh `--session-key` each time, no ambiguity), `main`'s process exited
**cleanly (exit code 0)** — not killed, not erroring on its own — while the
`sessions_send` call to the specialist was still in flight. Observed exit
points: **68s, 72s, and 143s** across different runs, with a separate
successful case at 120s (sallie) — not a fixed threshold; it appears to
depend on the model's own judgment of when its turn is "done," independent of
how long the pending tool call actually needs.

Once `main`'s process exits with the tool call still unresolved, the gateway
only tolerates a **hardcoded, non-configurable 5-second grace period** before
declaring the whole run a hard error:

```js
// /app/dist/execute.runtime-*.js (compiled image, not part of this repo)
const CLI_MCP_DELIVERY_DRAIN_GRACE_MS = 5000;   // 5s
const CLI_MCP_REQUEST_ADMISSION_GRACE_MS = 250;  // 0.25s
```

If the specialist's reply hasn't been captured within that 5s window, the
run ends with:

```json
"stopReason": "error",
"attempts": [{ "result": "error", "reason": "CLI message tool call remained in flight after exit" }]
```

This is a **different failure mode** from the CLI's own no-output watchdog
(`noOutputTimeoutMs`, which produces a distinctly different error message,
`"CLI produced no output for Xs and was terminated"`) — that watchdog never
fired in any of these reproductions. The process exit here is *clean*, not a
kill.

**Critically, the specialist itself is unaffected** — it's a separate,
persistent process that keeps running regardless of what happens to the
process that dispatched it. Proven directly (not inferred from logs): during
one reproduction, `ps aux` inside the gateway container showed virginia's
`claude` process (PID 299) still alive and accumulating CPU time and session
tokens for **12+ minutes** after `main` had already reported failure to the
user — and it went on to produce a complete, correct one-pager (PDF + HTML +
report JSON, verified on disk) before exiting cleanly on its own.

## What was tried and ruled out

| Attempt | Result | Why it didn't work |
|---|---|---|
| Raise `timeoutMs` on the specialist's `sessions_send` call (180000 → 600000ms) | No effect — failures still happened at 68–143s | This isn't the timeout that's firing. The failure is `main`'s own process exiting early, not `sessions_send`'s wait expiring. |
| Set `MCP_TIMEOUT`, `MCP_TIMEOUT_MS`, `MCP_AUTO_BACKGROUND_MS` env vars to 700000ms on the gateway container (all three found as real strings inside the installed `claude` CLI binary) | First test "succeeded" in 24s — but that was a **false positive**: cached research artifacts from an earlier failed attempt let the pipeline skip straight to a fast render. A genuinely fresh, uncached company (Ramp) **failed again with the identical error at 143s** — nowhere near 700000ms. | These env vars don't govern whatever's actually cutting the turn short, or aren't honored on this call path. Confirmed empirically, not by reading docs (OpenClaw's docs don't cover this failure mode at all — checked `docs.openclaw.ai/gateway/cli-backends`, `/cli/mcp`, `/gateway/troubleshooting`, `/cli/agent`). |
| Grant the specialist a `message` tool to self-deliver the result asynchronously once done | Tool call returned `"Unknown channel: webchat"` immediately | `message` only sends to explicit external providers (Slack/Discord/Telegram/Signal + a target address) — it cannot reply to "whatever channel this session is already on." Dead end for any deployment testing via webchat/dashboard. Might work for a *Slack*-wired deployment (untested — see Open questions). |
| (Would-be) grant `tools.allow: ["message"]` to a specialist via the manifest | Not even possible today | `scripts/lib/manifest-compiler.js`'s `TOOLS_REQUEST_FIELDS` only recognizes `profile` for specialist `tools` overrides — `allow` isn't a supported manifest field. Moot given the `message` tool doesn't solve this anyway, but worth knowing before attempting it. |

## What was verified to work — dispatch-then-poll

Instead of `main` blocking on one long synchronous `sessions_send` call, split
the interaction into two turns:

1. **Dispatch turn.** `main` calls `sessions_send` with a **short** wait
   (~15–20s — just long enough to confirm the specialist started), then
   replies to the user immediately: *"Kicked off — I'll relay it when it's
   ready."* Because `main`'s own turn now concludes well inside its safe
   window, there's no crash.
2. **Specialist keeps working, unattended.** Confirmed by direct process
   inspection, not assumption.
3. **Retrieval turn**, run later (e.g. the user asks "is it ready?"). `main`
   is told to check `session_status` / `sessions_history` for the
   specialist's session — **not** to call `sessions_send` again — and relay
   whatever it finds.

### End-to-end proof (virginia / Stripe one-pager, this session)

| Step | Result |
|---|---|
| Dispatch turn | `durationMs: 26102`, `stopReason: None`, `"result": "success"`. Reply: *"Kicked off — Virginia has the Stripe one-pager request. She'll deliver the full brief when she's done; I'll relay it when it comes in."* |
| Background work | `ps aux` showed virginia's process (PID 299) alive for the full run. `outputs/stripe/` filled in over ~12 minutes: `company.json` → `executives.json` → `brand.json` → `brief-content.json`, then `outputs/rendered/stripe_20260717T014018Z.{pdf,html,editor.html,report.json}`. Process exited cleanly once done. |
| Retrieval turn (fresh session, told to use `session_status`/`sessions_history` only) | `durationMs: 21944`, `stopReason: None`, `"result": "success"`. Correctly relayed the real content — three executives (Gaybrick, Tomlinson, Patil), the actual brief angles, and the correct file paths for the PDF/HTML/JSON — matching the files verified on disk. |

No crash at either turn. Total specialist runtime (~12–13 minutes) vastly
exceeded every failure point observed in the single-turn approach, with no
issue, because neither turn was ever blocked waiting on the other for that
long.

## What this means / what's not yet done

This is a **verified workaround pattern**, hand-driven via direct CLI prompts
in this investigation — it is **not yet the actual behavior** of this
deployment's coordinator. To make it real:

- `main`'s generated persona (built by `scripts/lib/manifest-compiler.js`,
  written to `AGENTS.md` on every `--sync-agents` run) needs its routing
  instructions changed: dispatch with a short ack-wait instead of the
  specialist's full `timeoutMs`, tell the user it's in progress, and use
  `session_status` / `sessions_history` — never `sessions_send` again — to
  check on and relay a specialist that's already been dispatched once.
- This is a genuine **UX change**, not just a bug fix: a long specialist task
  becomes a two-turn interaction (dispatch, then "check back") rather than
  one blocking exchange. There is currently no push-notification path to
  collapse this back to one turn on the webchat/dashboard surface, since
  `message` can't target it.

## Open questions (not yet investigated)

- **Does `message` work for proactive delivery once Slack is wired?** Slack
  is a real external provider, so `message` with `channel: "slack"` + a
  target might actually work there, even though it fails for webchat. This
  would let a specialist push its own result on completion, avoiding the
  "user has to ask again" step. Untested — no Slack channel is wired in this
  deployment yet.
- **Why does `main`'s process exit early at all, mechanically?** Confirmed
  the *symptom* (clean exit while a tool call is in flight, hardcoded 5s
  drain grace) and *ruled out* several candidate knobs, but not the deeper
  "why" inside the closed-source `claude` CLI binary itself. Worth filing
  upstream with OpenClaw/Anthropic if this needs a real fix rather than a
  workaround — the exact reproduction steps below make that report
  straightforward to write up.
- **Is there a safe default short-wait value?** 15–20s worked in testing;
  not stress-tested against a specialist that itself needs longer than that
  just to acknowledge receipt.

## How to reproduce

```bash
# Fails (~1-2.5 min in, well before the specialist's configured timeoutMs):
docker compose run --rm --entrypoint node openclaw-cli dist/index.js agent \
  --agent main --session-key "repro-$(openssl rand -hex 4)" \
  --message "Please have Virginia build an executive one-pager for <a company with no prior cached research>." \
  --json --timeout 700

# Works (dispatch half):
docker compose run --rm --entrypoint node openclaw-cli dist/index.js agent \
  --agent main --session-key "dispatch-$(openssl rand -hex 4)" \
  --message "Please ask Virginia to build a one-pager for <company>, but only wait up to 15 seconds for her acknowledgement — don't wait for the full result. Just tell me you've kicked it off." \
  --json --timeout 60

# Works (retrieval half, run once the specialist has actually finished — check
# .openclaw-data/config/agents/virginia/workspace/outputs/rendered/ for the PDF,
# or `ps aux` in the gateway container for whether her process has exited):
docker compose run --rm --entrypoint node openclaw-cli dist/index.js agent \
  --agent main --session-key "retrieve-$(openssl rand -hex 4)" \
  --message "Check Virginia's session (agent:virginia:main) using session_status or sessions_history — do NOT send her a new message. Tell me what she found." \
  --json --timeout 90
```

Always use a fresh `--session-key` — an existing session's tool policy is
frozen at creation and can mask or fake this behavior either way.

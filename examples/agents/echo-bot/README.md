# echo-bot

The reference/demo agent package for this deployment's pluggable-agents format
(see `AGENTS-PLUGINS.md` at the repo root). It doubles as:

- the format's living documentation — a minimal but complete example of
  `openclaw.agent.json5` + `workspace/AGENTS.md`;
- the default entry in `agents.manifest.json5`, so a fresh clone has a
  working, offline coordinator + specialist demo without reaching the
  network (`source` points at this local directory, not a git URL).

It has no real capability: it replies to every message with
`ECHO-BOT>> <the message, verbatim>`. Useful for confirming the coordinator
relay (`sessions_send`) actually dispatches before wiring up a real
specialist.

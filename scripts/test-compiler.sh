#!/usr/bin/env bash
# Runs scripts/lib/manifest-compiler.test.js against manifest-compiler.js's
# pure phase functions, inside the pinned image — the same trick
# sync-agents.sh's run_compiler uses (concatenate + pipe to `node` so
# `require("json5")` resolves without a host node dependency). No `INPUT`
# global is defined here, so the compiler file's own auto-run line is
# skipped (see the guard at its end) and only its function declarations run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

command -v docker >/dev/null 2>&1 || { echo "docker not found." >&2; exit 1; }

{ cat scripts/lib/manifest-compiler.js; echo; cat scripts/lib/manifest-compiler.test.js; } \
  | docker compose run -T --rm --entrypoint node openclaw-cli

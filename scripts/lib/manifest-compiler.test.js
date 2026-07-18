// Unit tests for scripts/lib/manifest-compiler.js (AGENTS-DEPS-SPEC.md §11
// checklist: "Compiler unit tests (pure INPUT→output)"). Run via
// scripts/test-compiler.sh, which concatenates manifest-compiler.js with this
// file and pipes the result to the pinned image's `node` — the same trick
// scripts/sync-agents.sh uses to inject `const INPUT` (so `require("json5")`
// resolves without any host node dependency). Every function referenced below
// (lintStatic, lintPostfetch, assemble, ...) is a plain top-level declaration
// in the concatenated compiler file, visible here with no require/module
// plumbing — the compiler file's own auto-run line is guarded off since no
// `INPUT` global is defined in this invocation.

const assert = require("assert");

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
  } catch (e) {
    console.error(`FAIL: ${name}\n${e.stack}`);
    process.exitCode = 1;
  }
}

function baseManifestObj(agentOverrides) {
  return {
    agents: [
      Object.assign({ source: "../local-pkg", ref: null, id: "widget" }, agentOverrides),
    ],
  };
}

function pkgDoc(overrides) {
  return Object.assign(
    { slug: "local-pkg", hasAgentsMd: true, hasEnvFile: false, agentJson5Text: null, skillDirs: [] },
    overrides
  );
}

// --- system / allowSystemDeps: manifest-level (static) validation ---------

test("system: unknown sub-field errors", () => {
  const text = JSON.stringify(baseManifestObj({ system: { bogus: true } }));
  const res = lintStatic({ manifestText: text });
  assert.strictEqual(res.ok, false);
  assert.ok(res.errors.some((e) => e.includes("system") && e.includes("bogus")), res.errors.join("\n"));
});

test("system.apt must be an array of strings", () => {
  const text = JSON.stringify(baseManifestObj({ system: { apt: "libmagic1" } }));
  const res = lintStatic({ manifestText: text });
  assert.strictEqual(res.ok, false);
  assert.ok(res.errors.some((e) => e.includes("system.apt")), res.errors.join("\n"));
});

test("system.playwrightBrowsers must be an array of strings", () => {
  const text = JSON.stringify(baseManifestObj({ system: { playwrightBrowsers: [1, 2] } }));
  const res = lintStatic({ manifestText: text });
  assert.strictEqual(res.ok, false);
  assert.ok(res.errors.some((e) => e.includes("system.playwrightBrowsers")), res.errors.join("\n"));
});

test("system must be an object, not an array/scalar", () => {
  const text = JSON.stringify(baseManifestObj({ system: "chromium" }));
  const res = lintStatic({ manifestText: text });
  assert.strictEqual(res.ok, false);
  assert.ok(res.errors.some((e) => e.includes("'system' must be an object")), res.errors.join("\n"));
});

test("allowSystemDeps must be a boolean", () => {
  const text = JSON.stringify(baseManifestObj({ allowSystemDeps: "yes" }));
  const res = lintStatic({ manifestText: text });
  assert.strictEqual(res.ok, false);
  assert.ok(res.errors.some((e) => e.includes("allowSystemDeps")), res.errors.join("\n"));
});

test("valid system + allowSystemDeps passes static lint", () => {
  const text = JSON.stringify(
    baseManifestObj({ system: { apt: ["libmagic1", "poppler-utils"] }, allowSystemDeps: true })
  );
  const res = lintStatic({ manifestText: text });
  assert.strictEqual(res.ok, true, JSON.stringify(res));
});

// --- effective system: manifest overrides package wholesale ---------------

test("manifest system overrides package's system wholesale", () => {
  const manifestText = JSON.stringify(baseManifestObj({ system: { apt: ["poppler-utils"] } }));
  const packages = [
    pkgDoc({ agentJson5Text: JSON.stringify({ id: "widget", system: { apt: ["libmagic1"] } }) }),
  ];
  const res = lintPostfetch({ manifestText, packages });
  assert.strictEqual(res.ok, true, JSON.stringify(res));
  assert.deepStrictEqual(res.data.effectiveAgents[0].system.apt, ["poppler-utils"]);
});

test("package system passes through when manifest gives no override", () => {
  const manifestText = JSON.stringify(baseManifestObj({}));
  const packages = [
    pkgDoc({
      agentJson5Text: JSON.stringify({ id: "widget", system: { playwrightBrowsers: ["chromium"] } }),
    }),
  ];
  const res = lintPostfetch({ manifestText, packages });
  assert.strictEqual(res.ok, true, JSON.stringify(res));
  assert.deepStrictEqual(res.data.effectiveAgents[0].system.playwrightBrowsers, ["chromium"]);
});

test("empty manifest system:{} blanks out the package's request", () => {
  const manifestText = JSON.stringify(baseManifestObj({ system: {} }));
  const packages = [
    pkgDoc({ agentJson5Text: JSON.stringify({ id: "widget", system: { apt: ["libmagic1"] } }) }),
  ];
  const res = lintPostfetch({ manifestText, packages });
  assert.strictEqual(res.ok, true, JSON.stringify(res));
  assert.strictEqual(res.data.effectiveAgents[0].system.apt, undefined);
});

test("package's own invalid system is still validated at postfetch", () => {
  const manifestText = JSON.stringify(baseManifestObj({}));
  const packages = [
    pkgDoc({ agentJson5Text: JSON.stringify({ id: "widget", system: { apt: [123] } }) }),
  ];
  const res = lintPostfetch({ manifestText, packages });
  assert.strictEqual(res.ok, false);
  assert.ok(res.errors.some((e) => e.includes("system.apt")), res.errors.join("\n"));
});

test("allowSystemDeps defaults false in effectiveAgents", () => {
  const manifestText = JSON.stringify(baseManifestObj({}));
  const res = lintPostfetch({ manifestText, packages: [pkgDoc({})] });
  assert.strictEqual(res.ok, true, JSON.stringify(res));
  assert.strictEqual(res.data.effectiveAgents[0].allowSystemDeps, false);
});

test("allowSystemDeps: true is carried into effectiveAgents", () => {
  const manifestText = JSON.stringify(baseManifestObj({ allowSystemDeps: true }));
  const res = lintPostfetch({ manifestText, packages: [pkgDoc({})] });
  assert.strictEqual(res.ok, true, JSON.stringify(res));
  assert.strictEqual(res.data.effectiveAgents[0].allowSystemDeps, true);
});

// --- coordinator entry: requester-aware spawn + push delivery --------------

test("coordinator gets the narrow cross-profile spawn/message tool set (no yield)", () => {
  const manifestText = JSON.stringify(baseManifestObj({ role: "Widgets." }));
  const post = lintPostfetch({ manifestText, packages: [pkgDoc({})] });
  const asm = assemble({
    coordinator: post.data.coordinator,
    effectiveAgents: post.data.effectiveAgents,
    currentAgentsList: [],
  });
  assert.strictEqual(asm.ok, true, JSON.stringify(asm));
  const coordEntry = asm.data.patch.agents.list[0];
  assert.strictEqual(coordEntry.tools.profile, "full");
  // sessions_yield deliberately absent — it lured the model into ending
  // dispatch turns with NO_REPLY, suppressing the user-facing ack.
  assert.deepStrictEqual(coordEntry.tools.allow, [
    "sessions_list", "sessions_history", "sessions_spawn", "message",
  ]);
  assert.deepStrictEqual(coordEntry.subagents, {
    delegationMode: "prefer",
    allowAgents: ["widget"],
  });
});

test("native subagent timeout uses the largest specialist budget rounded up", () => {
  const effectiveAgents = [
    { id: "fast", timeoutMs: 45001 },
    { id: "slow", timeoutMs: 900000 },
  ];
  const asm = assemble({
    coordinator: { ...COORDINATOR_DEFAULTS },
    effectiveAgents,
    currentAgentsList: [],
  });
  assert.strictEqual(asm.ok, true, JSON.stringify(asm));
  assert.strictEqual(asm.data.subagentRunTimeoutSeconds, 900);
  assert.strictEqual(asm.data.patch.agents.defaults.subagents.runTimeoutSeconds, 900);
});

// --- resume-watchdog raise rides the sync-owned config patch ---------------

test("assemble patch pins the claude-cli resume watchdog at 180s", () => {
  const manifestText = JSON.stringify(baseManifestObj({ role: "Widgets." }));
  const post = lintPostfetch({ manifestText, packages: [pkgDoc({})] });
  const asm = assemble({
    coordinator: post.data.coordinator,
    effectiveAgents: post.data.effectiveAgents,
    currentAgentsList: [],
  });
  assert.strictEqual(asm.ok, true, JSON.stringify(asm));
  assert.deepStrictEqual(
    asm.data.patch.agents.defaults.cliBackends["claude-cli"].reliability.watchdog.resume,
    { noOutputTimeoutMs: 180000 }
  );
});

// --- taskHint: per-specialist dispatch requirement --------------------------

test("taskHint flows through to coordinator routing rows", () => {
  const manifestText = JSON.stringify(
    baseManifestObj({ role: "Widgets.", taskHint: "Always render the PDF." })
  );
  const post = lintPostfetch({ manifestText, packages: [pkgDoc({})] });
  assert.strictEqual(post.ok, true, JSON.stringify(post));
  assert.strictEqual(post.data.effectiveAgents[0].taskHint, "Always render the PDF.");
  const asm = assemble({
    coordinator: post.data.coordinator,
    effectiveAgents: post.data.effectiveAgents,
    currentAgentsList: [],
  });
  assert.strictEqual(asm.ok, true, JSON.stringify(asm));
  assert.strictEqual(asm.data.coordinatorRoutingRows[0].taskHint, "Always render the PDF.");
});

test("taskHint defaults to null in routing rows when not given", () => {
  const manifestText = JSON.stringify(baseManifestObj({ role: "Widgets." }));
  const post = lintPostfetch({ manifestText, packages: [pkgDoc({})] });
  const asm = assemble({
    coordinator: post.data.coordinator,
    effectiveAgents: post.data.effectiveAgents,
    currentAgentsList: [],
  });
  assert.strictEqual(asm.ok, true, JSON.stringify(asm));
  assert.strictEqual(asm.data.coordinatorRoutingRows[0].taskHint, null);
});

test("taskHint must be a non-empty string", () => {
  for (const bad of ["", "   ", 42, { text: "x" }]) {
    const manifestText = JSON.stringify(baseManifestObj({ taskHint: bad }));
    const post = lintPostfetch({ manifestText, packages: [pkgDoc({})] });
    assert.strictEqual(post.ok, false, `expected failure for ${JSON.stringify(bad)}`);
    assert.ok(post.errors.some((e) => e.includes("taskHint")), post.errors.join("\n"));
  }
});

// --- thinking: per-agent spawn-time thinking override ------------------------

test("thinking flows through to coordinator routing rows", () => {
  const manifestText = JSON.stringify(baseManifestObj({ role: "Widgets.", thinking: "off" }));
  const post = lintPostfetch({ manifestText, packages: [pkgDoc({})] });
  assert.strictEqual(post.ok, true, JSON.stringify(post));
  const asm = assemble({
    coordinator: post.data.coordinator,
    effectiveAgents: post.data.effectiveAgents,
    currentAgentsList: [],
  });
  assert.strictEqual(asm.ok, true, JSON.stringify(asm));
  assert.strictEqual(asm.data.coordinatorRoutingRows[0].thinking, "off");
});

test("thinking defaults to null and warns on unknown level", () => {
  const post0 = lintPostfetch({
    manifestText: JSON.stringify(baseManifestObj({ role: "W." })),
    packages: [pkgDoc({})],
  });
  const asm0 = assemble({
    coordinator: post0.data.coordinator,
    effectiveAgents: post0.data.effectiveAgents,
    currentAgentsList: [],
  });
  assert.strictEqual(asm0.data.coordinatorRoutingRows[0].thinking, null);

  const postWeird = lintPostfetch({
    manifestText: JSON.stringify(baseManifestObj({ role: "W.", thinking: "ultra" })),
    packages: [pkgDoc({})],
  });
  assert.strictEqual(postWeird.ok, true, JSON.stringify(postWeird));
  assert.ok(postWeird.warnings.some((w) => w.includes("thinking")), postWeird.warnings.join("\n"));

  const postBad = lintPostfetch({
    manifestText: JSON.stringify(baseManifestObj({ thinking: "  " })),
    packages: [pkgDoc({})],
  });
  assert.strictEqual(postBad.ok, false);
  assert.ok(postBad.errors.some((e) => e.includes("thinking")), postBad.errors.join("\n"));
});

// --- dispatch: per-agent spawn vs send routing -------------------------------

test("dispatch defaults to spawn; send flows to rows and unlocks sessions_send", () => {
  const postDefault = lintPostfetch({
    manifestText: JSON.stringify(baseManifestObj({ role: "W." })),
    packages: [pkgDoc({})],
  });
  assert.strictEqual(postDefault.data.effectiveAgents[0].dispatch, "spawn");
  const asmDefault = assemble({
    coordinator: postDefault.data.coordinator,
    effectiveAgents: postDefault.data.effectiveAgents,
    currentAgentsList: [],
  });
  assert.strictEqual(asmDefault.data.coordinatorRoutingRows[0].dispatch, "spawn");
  assert.ok(!asmDefault.data.patch.agents.list[0].tools.allow.includes("sessions_send"));

  const postSend = lintPostfetch({
    manifestText: JSON.stringify(baseManifestObj({ role: "W.", dispatch: "send" })),
    packages: [pkgDoc({})],
  });
  assert.strictEqual(postSend.ok, true, JSON.stringify(postSend));
  const asmSend = assemble({
    coordinator: postSend.data.coordinator,
    effectiveAgents: postSend.data.effectiveAgents,
    currentAgentsList: [],
  });
  assert.strictEqual(asmSend.data.coordinatorRoutingRows[0].dispatch, "send");
  assert.ok(asmSend.data.patch.agents.list[0].tools.allow.includes("sessions_send"));
});

test("dispatch rejects values other than spawn/send", () => {
  const post = lintPostfetch({
    manifestText: JSON.stringify(baseManifestObj({ dispatch: "carrier-pigeon" })),
    packages: [pkgDoc({})],
  });
  assert.strictEqual(post.ok, false);
  assert.ok(post.errors.some((e) => e.includes("dispatch")), post.errors.join("\n"));
});

// --- regression: existing behavior (env, assemble) stays intact -----------

test("regression: env required/optional validation still works", () => {
  const text = JSON.stringify(baseManifestObj({ env: { required: ["FOO"], optional: ["BAR"] } }));
  const res = lintStatic({ manifestText: text });
  assert.strictEqual(res.ok, true, JSON.stringify(res));
});

test("regression: basic manifest with no system/env still assembles cleanly", () => {
  const manifestText = JSON.stringify(baseManifestObj({ role: "Widgets." }));
  const post = lintPostfetch({ manifestText, packages: [pkgDoc({})] });
  assert.strictEqual(post.ok, true, JSON.stringify(post));
  const asm = assemble({
    coordinator: post.data.coordinator,
    effectiveAgents: post.data.effectiveAgents,
    currentAgentsList: [],
  });
  assert.strictEqual(asm.ok, true, JSON.stringify(asm));
  assert.deepStrictEqual(asm.data.summary.added, ["widget"]);
});

console.log(`manifest-compiler.test.js: ${passed} passed`);
if (process.exitCode) {
  console.error("manifest-compiler.test.js: FAILURES ABOVE");
}

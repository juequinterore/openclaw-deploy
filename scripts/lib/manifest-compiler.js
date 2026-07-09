// Manifest-heavy logic for `scripts/sync-agents.sh` (AGENTS-PLUGINS.md).
//
// Runs INSIDE the pinned OpenClaw image via `docker compose run --entrypoint
// node openclaw-cli`, fed over stdin, so it can `require("json5")` from the
// image's own node_modules without adding a host dependency (verified in
// AGENTS-PLUGINS.md §4.1/§13). It never touches the filesystem: the caller
// (sync-agents.sh) reads every file this needs — the manifest text, staged
// packages' openclaw.agent.json5, skill frontmatter names, the live
// agents.list — and hands it all over as one JSON blob on a global `INPUT`
// object, injected as a `const INPUT = {...};` line prepended before this
// file is concatenated and piped to `node`. That keeps this file pure and
// testable: same INPUT always produces the same output.
//
// Contract: reads global INPUT, writes one line of JSON to stdout:
//   { ok: true,  data: {...} }              — shape depends on INPUT.phase
//   { ok: false, errors: [...], warnings: [...] }
// sync-agents.sh aborts the whole sync on ok:false, printing errors/warnings.

const JSON5 = require("json5");

const ID_RE = /^[a-z0-9][a-z0-9_-]*$/;

// Fields recognized in an agent package's own openclaw.agent.json5 (§3.1).
const PACKAGE_FIELDS = new Set([
  "id", "name", "role", "tools", "model", "skills", "identity", "notes",
]);
// Deploy-only fields, valid ONLY in agents.manifest.json5 entries (§4).
const MANIFEST_ONLY_FIELDS = new Set([
  "source", "ref", "enabled", "disableSkills", "denyTools", "timeoutMs", "routeHint",
]);
const MANIFEST_AGENT_FIELDS = new Set([...PACKAGE_FIELDS, ...MANIFEST_ONLY_FIELDS]);
const MANIFEST_TOP_FIELDS = new Set(["coordinator", "agents"]);
const COORDINATOR_FIELDS = new Set(["id", "name", "maxPingPongTurns", "defaultTimeoutMs"]);
const TOOLS_REQUEST_FIELDS = new Set(["profile"]);
const IDENTITY_FIELDS = new Set(["name", "theme", "emoji", "avatar"]);

const COORDINATOR_DEFAULTS = {
  id: "main",
  name: "🧭 Front Desk",
  maxPingPongTurns: 0,
  defaultTimeoutMs: 180000,
};

function fail(errors, warnings) {
  return { ok: false, errors, warnings: warnings || [] };
}
function ok(data, warnings) {
  return { ok: true, data, warnings: warnings || [] };
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function unknownFieldErrors(obj, allowed, label) {
  const errs = [];
  for (const k of Object.keys(obj)) {
    if (!allowed.has(k)) errs.push(`${label}: unknown field '${k}'`);
  }
  return errs;
}

// Cosmetic only (staging-dir naming) — not load-bearing for correctness.
function slugify(source) {
  let s = String(source).trim().toLowerCase();
  s = s.replace(/^[a-z][a-z0-9+.-]*:\/\//, ""); // https://, ssh://
  s = s.replace(/^[^@/]+@/, ""); // git@
  s = s.replace(/^(github\.com|gitlab\.com|bitbucket\.org)[:/]/, "");
  s = s.replace(/\.git$/, "");
  s = s.replace(/[^a-z0-9]+/g, "-");
  s = s.replace(/^-+|-+$/g, "");
  return s || "agent";
}

function dedupeSlugs(entries) {
  const seen = new Map();
  for (const e of entries) {
    const base = e.slug;
    const n = (seen.get(base) || 0) + 1;
    seen.set(base, n);
    if (n > 1) e.slug = `${base}-${n}`;
  }
}

// Best-effort only: we can't know a ref's true kind without contacting the
// remote. Anything that isn't clearly a SHA or a version-ish tag is flagged
// as "looks like a branch" per AGENTS-PLUGINS.md §4.2 (warning, not an error).
function looksLikeBranch(ref) {
  if (/^[0-9a-f]{7,40}$/i.test(ref)) return false; // SHA (or short SHA)
  if (/^v?\d+(\.\d+){0,3}([.-].*)?$/i.test(ref)) return false; // v1.2.0, 1.2.3, 2026.6.11
  return true;
}

// Git sources are either a URL (scheme://...) or scp-like shorthand
// (user@host:path, e.g. git@github.com:acme/repo.git). Anything else —
// including a bare relative path with no leading "./", per the §11 default
// manifest's own `source: "examples/agents/echo-bot"` — is a local path.
function isLocalSource(source) {
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(source)) return false;
  if (/^[^\s/]+@[^\s:]+:/.test(source)) return false;
  return true;
}

function parseManifest(manifestText) {
  let raw;
  try {
    raw = JSON5.parse(manifestText);
  } catch (e) {
    return fail([`agents.manifest.json5: JSON5 parse error: ${e.message}`]);
  }
  if (!isPlainObject(raw)) {
    return fail(["agents.manifest.json5: root must be an object"]);
  }

  const errors = [];
  const warnings = [];
  errors.push(...unknownFieldErrors(raw, MANIFEST_TOP_FIELDS, "agents.manifest.json5"));

  const coordinator = { ...COORDINATOR_DEFAULTS };
  if (raw.coordinator !== undefined) {
    if (!isPlainObject(raw.coordinator)) {
      errors.push("agents.manifest.json5: 'coordinator' must be an object");
    } else {
      errors.push(...unknownFieldErrors(raw.coordinator, COORDINATOR_FIELDS, "coordinator"));
      Object.assign(coordinator, raw.coordinator);
    }
  }
  if (coordinator.id !== undefined && (typeof coordinator.id !== "string" || !ID_RE.test(coordinator.id))) {
    errors.push(`coordinator.id '${coordinator.id}' must match ${ID_RE}`);
  }

  if (!Array.isArray(raw.agents)) {
    errors.push("agents.manifest.json5: 'agents' must be an array");
    return errors.length ? fail(errors, warnings) : ok({ coordinator, agents: [] }, warnings);
  }

  const agents = [];
  const explicitIds = new Map(); // id -> [indices]
  raw.agents.forEach((entry, index) => {
    const label = `agents[${index}]`;
    if (!isPlainObject(entry)) {
      errors.push(`${label}: must be an object`);
      return;
    }
    errors.push(...unknownFieldErrors(entry, MANIFEST_AGENT_FIELDS, label));

    if (typeof entry.source !== "string" || !entry.source.trim()) {
      errors.push(`${label}: 'source' is required`);
    }
    const enabled = entry.enabled === undefined ? true : entry.enabled;
    if (typeof enabled !== "boolean") {
      errors.push(`${label}: 'enabled' must be a boolean`);
    }
    const source = typeof entry.source === "string" ? entry.source.trim() : "";
    const local = source ? isLocalSource(source) : false;
    const ref = entry.ref === undefined ? null : entry.ref;
    if (!local) {
      if (typeof ref !== "string" || !ref.trim()) {
        errors.push(`${label} (source=${source || "?"}): 'ref' is required for git sources`);
      } else if (looksLikeBranch(ref)) {
        warnings.push(`${label} (source=${source}): ref '${ref}' looks like a branch name — prefer a tag or SHA (branch pins are mutable)`);
      }
    }

    if (entry.id !== undefined) {
      if (typeof entry.id !== "string" || !ID_RE.test(entry.id)) {
        errors.push(`${label}: id '${entry.id}' must match ${ID_RE}`);
      } else {
        if (entry.id === coordinator.id) {
          errors.push(`${label}: id '${entry.id}' claims the coordinator's id ('${coordinator.id}') — reserved`);
        }
        const list = explicitIds.get(entry.id) || [];
        list.push(index);
        explicitIds.set(entry.id, list);
      }
    }

    if (entry.tools !== undefined) {
      if (!isPlainObject(entry.tools)) errors.push(`${label}: 'tools' must be an object`);
      else errors.push(...unknownFieldErrors(entry.tools, TOOLS_REQUEST_FIELDS, `${label}.tools`));
    }
    if (entry.identity !== undefined) {
      if (!isPlainObject(entry.identity)) errors.push(`${label}: 'identity' must be an object`);
      else errors.push(...unknownFieldErrors(entry.identity, IDENTITY_FIELDS, `${label}.identity`));
    }
    for (const arrField of ["skills", "disableSkills", "denyTools"]) {
      if (entry[arrField] !== undefined && !Array.isArray(entry[arrField])) {
        errors.push(`${label}: '${arrField}' must be an array`);
      }
    }

    agents.push({
      index,
      source,
      ref: local ? null : ref,
      enabled,
      isLocal: local,
      slug: slugify(source || `agent-${index}`),
      explicitId: entry.id || null,
      overrides: {
        name: entry.name,
        role: entry.role,
        tools: entry.tools,
        model: entry.model,
        skills: entry.skills,
        identity: entry.identity,
        notes: entry.notes,
        disableSkills: entry.disableSkills || [],
        denyTools: entry.denyTools || [],
        timeoutMs: entry.timeoutMs,
        routeHint: entry.routeHint,
      },
    });
  });

  for (const [id, indices] of explicitIds) {
    if (indices.length > 1) {
      errors.push(`duplicate explicit id '${id}' at agents[${indices.join(", ")}]`);
    }
  }
  dedupeSlugs(agents.filter((a) => a.enabled));

  if (errors.length) return fail(errors, warnings);
  return ok({ coordinator, agents }, warnings);
}

function lintStatic(input) {
  const res = parseManifest(input.manifestText);
  if (!res.ok) return res;
  return ok(
    {
      coordinator: res.data.coordinator,
      agents: res.data.agents.map((a) => ({
        index: a.index,
        source: a.source,
        ref: a.ref,
        enabled: a.enabled,
        isLocal: a.isLocal,
        slug: a.slug,
        explicitId: a.explicitId,
      })),
    },
    res.warnings
  );
}

function lintPostfetch(input) {
  const res = parseManifest(input.manifestText);
  if (!res.ok) return res;
  const { coordinator, agents } = res.data;
  const errors = [];
  const warnings = [...res.warnings];
  const packagesBySlug = new Map((input.packages || []).map((p) => [p.slug, p]));

  const effectiveAgents = [];
  const seenIds = new Map();

  for (const a of agents) {
    if (!a.enabled) continue;
    const label = `agents[${a.index}] (source=${a.source}, slug=${a.slug})`;
    const pkg = packagesBySlug.get(a.slug);
    if (!pkg) {
      errors.push(`${label}: internal error — no staged package data for this slug`);
      continue;
    }
    if (pkg.hasEnvFile) {
      errors.push(`${label}: .env found in package workspace/ — refusing to sync (secrets must come from the deployment's own .env, never an agent repo)`);
      continue;
    }
    if (!pkg.hasAgentsMd) {
      errors.push(`${label}: workspace/AGENTS.md is missing — it is the only REQUIRED file in an agent package`);
      continue;
    }

    let packageConfig = {};
    if (pkg.agentJson5Text != null) {
      try {
        packageConfig = JSON5.parse(pkg.agentJson5Text);
      } catch (e) {
        errors.push(`${label}: openclaw.agent.json5 failed to parse: ${e.message}`);
        continue;
      }
      if (!isPlainObject(packageConfig)) {
        errors.push(`${label}: openclaw.agent.json5 root must be an object`);
        continue;
      }
      errors.push(...unknownFieldErrors(packageConfig, PACKAGE_FIELDS, `${label} openclaw.agent.json5`));
    }

    // Effective config = package request, overridden per top-level field by
    // the manifest entry (shallow — nested objects like `tools`/`identity`
    // replace wholesale, they are not deep-merged; see AGENTS-PLUGINS.md §4).
    const ov = a.overrides;
    const effective = {
      id: a.explicitId || packageConfig.id,
      name: ov.name !== undefined ? ov.name : packageConfig.name,
      role: ov.role !== undefined ? ov.role : packageConfig.role,
      tools: ov.tools !== undefined ? ov.tools : packageConfig.tools,
      model: ov.model !== undefined ? ov.model : packageConfig.model,
      skills: ov.skills !== undefined ? ov.skills : packageConfig.skills,
      identity: ov.identity !== undefined ? ov.identity : packageConfig.identity,
    };

    if (!effective.id || typeof effective.id !== "string") {
      errors.push(`${label}: no id resolvable — package ships no openclaw.agent.json5 id and the manifest gives no override id`);
      continue;
    }
    if (!ID_RE.test(effective.id)) {
      errors.push(`${label}: effective id '${effective.id}' must match ${ID_RE}`);
      continue;
    }
    if (effective.id === coordinator.id) {
      errors.push(`${label}: effective id '${effective.id}' claims the coordinator's id ('${coordinator.id}') — reserved`);
      continue;
    }
    const dupe = seenIds.get(effective.id);
    if (dupe) {
      errors.push(`duplicate effective id '${effective.id}': ${dupe} and ${label}`);
      continue;
    }
    seenIds.set(effective.id, label);

    if (effective.tools !== undefined) {
      if (!isPlainObject(effective.tools)) errors.push(`${label}: effective 'tools' must be an object`);
      else errors.push(...unknownFieldErrors(effective.tools, TOOLS_REQUEST_FIELDS, `${label} effective tools`));
    }
    if (effective.identity !== undefined && !isPlainObject(effective.identity)) {
      errors.push(`${label}: effective 'identity' must be an object`);
    }

    // Capability subtraction (§7): drop disableSkills from an explicit
    // allowlist (only if one exists — an omitted allowlist stays omitted,
    // since skip-copying the directory already prevents that skill loading
    // regardless of any allowlist), and compute which skill dirs to skip
    // copying, matched on SKILL.md frontmatter name (dir basename fallback).
    const disableSkills = ov.disableSkills || [];
    const denyTools = ov.denyTools || [];
    let effectiveSkills = effective.skills;
    if (Array.isArray(effectiveSkills) && disableSkills.length) {
      effectiveSkills = effectiveSkills.filter((s) => !disableSkills.includes(s));
    }
    const skillDirsToSkip = (pkg.skillDirs || [])
      .filter((d) => disableSkills.includes(d.frontmatterName || d.dirBasename))
      .map((d) => d.dirBasename);

    const tools = {};
    if (effective.tools && effective.tools.profile) tools.profile = effective.tools.profile;
    if (denyTools.length) tools.deny = denyTools;

    const timeoutMs = ov.timeoutMs !== undefined ? ov.timeoutMs : coordinator.defaultTimeoutMs;
    const routeHint = ov.routeHint || effective.role || "(no role/routeHint given — edit the manifest)";
    if (!ov.routeHint && !effective.role) {
      warnings.push(`${label}: no role (package) or routeHint (manifest) given — coordinator routing table will show a placeholder for '${effective.id}'`);
    }

    effectiveAgents.push({
      slug: a.slug,
      id: effective.id,
      name: effective.name || undefined,
      model: effective.model || undefined,
      identity: effective.identity || undefined,
      skills: effectiveSkills,
      tools: Object.keys(tools).length ? tools : undefined,
      routeHint,
      timeoutMs,
      disableSkills,
      denyTools,
      skillDirsToSkip,
      hasDisabledFeatures: disableSkills.length > 0 || denyTools.length > 0,
    });
  }

  if (errors.length) return fail(errors, warnings);
  return ok({ coordinator, effectiveAgents }, warnings);
}

function assemble(input) {
  const { coordinator, effectiveAgents, currentAgentsList } = input;
  const warnings = [];

  const coordinatorEntry = {
    id: coordinator.id,
    default: true,
    tools: { allow: ["sessions_list", "sessions_history", "sessions_send"] },
    workspace: "/home/node/.openclaw/workspace",
  };

  const specialistEntries = effectiveAgents.map((a) => {
    const entry = {
      id: a.id,
      workspace: `/home/node/.openclaw/agents/${a.id}/workspace`,
      agentDir: `/home/node/.openclaw/agents/${a.id}/agent`,
    };
    if (a.name) entry.name = a.name;
    if (a.model) entry.model = a.model;
    if (a.identity) entry.identity = a.identity;
    if (a.skills !== undefined) entry.skills = a.skills;
    if (a.tools) entry.tools = a.tools;
    return entry;
  });

  const newAgentsList = [coordinatorEntry, ...specialistEntries];
  const newSpecialistIds = specialistEntries.map((e) => e.id);

  const patch = {
    agents: {
      list: newAgentsList,
      defaults: { skipBootstrap: true },
    },
    tools: {
      sessions: { visibility: "all" },
      // Despite the schema's "Agent-to-Agent Target Allow" title, runtime
      // testing (2026-07-09, image 2026.6.11) showed the CALLING agent must
      // also be in `allow`, not just the callee — a coordinator-only-missing
      // allow entry fails `sessions_send` with a `forbidden` session status.
      // Include the coordinator alongside every specialist rather than
      // relying on the schema description alone.
      agentToAgent: { enabled: true, allow: [coordinator.id, ...newSpecialistIds] },
    },
    session: { agentToAgent: { maxPingPongTurns: coordinator.maxPingPongTurns } },
  };

  const current = Array.isArray(currentAgentsList) ? currentAgentsList : [];
  const currentSpecialistIds = current.filter((e) => e && e.id !== coordinator.id).map((e) => e.id);

  // An entry is "foreign" (hand-added, outside the manifest) if it isn't the
  // coordinator, isn't in the list we're about to write, AND its workspace
  // doesn't already match the path convention a sync would generate for that
  // id. That last clause is what lets "delete an entry from the manifest,
  // re-sync" drop it cleanly without --prune (AGENTS-PLUGINS.md §5.1 promises
  // this is idempotent/residue-free) — a workspace at the sync-owned path is
  // strong evidence a *previous* sync put it there, not a human.
  const foreignIds = [];
  for (const e of current) {
    if (!e || typeof e.id !== "string") continue;
    if (e.id === coordinator.id) continue;
    if (newSpecialistIds.includes(e.id)) continue;
    const ownedWorkspace = `/home/node/.openclaw/agents/${e.id}/workspace`;
    if (e.workspace === ownedWorkspace) continue;
    foreignIds.push(e.id);
  }

  const summary = {
    added: newSpecialistIds.filter((id) => !currentSpecialistIds.includes(id)),
    removed: currentSpecialistIds.filter((id) => !newSpecialistIds.includes(id)),
    kept: newSpecialistIds.filter((id) => currentSpecialistIds.includes(id)),
  };

  const coordinatorRoutingRows = effectiveAgents.map((a) => ({
    id: a.id,
    routeHint: a.routeHint,
    timeoutMs: a.timeoutMs,
  }));

  return ok({ patch, foreignIds, summary, coordinatorRoutingRows, coordinatorName: coordinator.name, maxPingPongTurns: coordinator.maxPingPongTurns }, warnings);
}

function run(input) {
  switch (input.phase) {
    case "lint-static":
      return lintStatic(input);
    case "lint-postfetch":
      return lintPostfetch(input);
    case "assemble":
      return assemble(input);
    default:
      return fail([`unknown phase '${input.phase}'`]);
  }
}

process.stdout.write(JSON.stringify(run(INPUT)));

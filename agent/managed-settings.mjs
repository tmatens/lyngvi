#!/usr/bin/env node
// managed-settings.mjs — print the Claude Code MANAGED settings for this image.
//
// Run once, at image build, as root (Dockerfile). The output is written to
// /etc/claude-code/managed-settings.json, root-owned and read-only to the agent's uid.
// Claude Code gives managed settings precedence over user and project settings, so
// what is decided here cannot be undone by anything the agent writes at runtime:
//
//   hooks                        the secret-hygiene hooks, run from the root-owned
//                                /etc/lyngvi/hooks/. A user or project
//                                `disableAllHooks` does not turn managed hooks off.
//   allowManagedHooksOnly        user, project and plugin hooks do not run at all, so
//                                the agent cannot add a hook that runs its own code
//                                at every session start.
//   disableBypassPermissionsMode `bypassPermissions` cannot be selected, from any
//                                settings file or flag.
//   allowedMcpServers            only the forge launchers baked into this image can
//                                be started as MCP servers, matched by exact command.
//   permissions.allow            the generic grants (git commit / push).
//   env (telemetry, opt-in)      when the site's settings.json names an OTLP endpoint,
//                                tool-call telemetry is switched on here so the agent
//                                cannot switch it off (tool parameters only; see below).
//   ConfigChange hook            warns (marker + notify + a message in the session) when
//                                a user, project or local settings file gains an allow
//                                rule, hooks, a defaultMode or additionalDirectories:
//                                those persist into later sessions unless the site sets
//                                allowManagedPermissionRulesOnly (DESIGN.md §4.5).
//
// The site's settings.json (the `site` build context) is deep-merged on top, arrays
// unioned, so a site grant is a human-merged, image-baked change like these, never a
// runtime self-grant. A site that wants permission rules from managed settings ONLY
// (no "don't ask again" rules from the workspace) sets
// "allowManagedPermissionRulesOnly": true there.
//
// Verified against the pinned CLI (DESIGN.md §4.5): a managed hook runs when user
// settings set disableAllHooks; allowManagedHooksOnly stops user and project hooks;
// a server outside allowedMcpServers is refused by `claude mcp add` and is never
// started when written into .claude.json directly.
import { readFileSync } from "node:fs";

const HOOKS = "/etc/lyngvi/hooks";
const hook = (script, timeout) => ({ hooks: [{ type: "command", command: `${HOOKS}/${script}`, timeout }] });

const base = {
  allowManagedHooksOnly: true,
  disableBypassPermissionsMode: "disable",
  allowedMcpServers: [
    { serverCommand: ["/usr/local/bin/forgejo-mcp"] },
    { serverCommand: ["/usr/local/bin/github-mcp"] },
  ],
  permissions: {
    // Commit + push without a per-call prompt; force-with-lease is narrowed to
    // non-main branches by the autoMode rule in the user settings (entrypoint.sh).
    allow: ["Bash(git commit *)", "Bash(git push *)", "Bash(git push --force-with-lease*)"],
  },
  hooks: {
    PreToolUse: [{ matcher: "Bash|Read|Grep", ...hook("block-secret-dumps.sh", 10) }],
    PostToolUse: [hook("redact-tool-output.sh", 15)],
    SessionStart: [hook("skills-summary.sh", 10)],
    ConfigChange: [{ matcher: "user_settings|project_settings|local_settings", ...hook("config-change.sh", 10) }],
  },
};

const union = (a, b) => {
  const seen = new Set(), out = [];
  for (const x of [...(a || []), ...(b || [])]) {
    const k = JSON.stringify(x);
    if (!seen.has(k)) { seen.add(k); out.push(x); }
  }
  return out;
};
const merge = (dst, src) => {
  for (const [k, v] of Object.entries(src || {})) {
    if (k.startsWith("_")) continue; // _comment and friends: documentation, not settings
    if (Array.isArray(v)) dst[k] = union(dst[k], v);
    else if (v && typeof v === "object") dst[k] = merge(dst[k] && typeof dst[k] === "object" ? dst[k] : {}, v);
    else dst[k] = v;
  }
  return dst;
};

const sitePath = process.argv[2];
let site = {};
if (sitePath) {
  let text = "";
  try { text = readFileSync(sitePath, "utf8"); } catch { /* no site settings: base only */ }
  // An unreadable or invalid site file fails the BUILD, not the first session: a
  // grant a human merged must not vanish silently.
  if (text.trim()) site = JSON.parse(text);
}
const out = merge(base, site);

// Tool-call telemetry (DESIGN.md §10). Opt-in: a site that names an OTLP endpoint in
// its settings.json `env` gets telemetry switched on here, in MANAGED settings, so the
// agent cannot turn it off. lyngvi's content policy is tool names, decisions, timings
// and tool parameters (the command text): OTEL_LOG_TOOL_DETAILS. Tool output, prompts,
// responses and raw API bodies stay out. The CLI sends prompts and responses as
// <REDACTED> unless told otherwise, and a site turning them on fails the build rather
// than quietly widening what the collector holds.
const env = out.env || {};
const endpoint = env.OTEL_EXPORTER_OTLP_ENDPOINT || env.OTEL_EXPORTER_OTLP_LOGS_ENDPOINT;
const WIDER = ["OTEL_LOG_TOOL_CONTENT", "OTEL_LOG_USER_PROMPTS", "OTEL_LOG_ASSISTANT_RESPONSES", "OTEL_LOG_RAW_API_BODIES"];
const on = (v) => v !== undefined && !["", "0", "false"].includes(String(v).toLowerCase());
const wider = WIDER.filter((k) => on(env[k]));
if (wider.length) {
  console.error(`site settings.json sets ${wider.join(", ")}: lyngvi keeps tool output, prompts, responses and API bodies out of telemetry (DESIGN.md §10)`);
  process.exit(1);
}
if (endpoint) {
  out.env = { CLAUDE_CODE_ENABLE_TELEMETRY: "1", OTEL_LOGS_EXPORTER: "otlp", OTEL_LOG_TOOL_DETAILS: "1", ...env };
}
process.stdout.write(JSON.stringify(out, null, 2) + "\n");

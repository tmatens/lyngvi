#!/usr/bin/env node
// notify.mjs — deliver a watchdog marker to a human, not just to the container log.
//
// The entrypoint emits structured markers (RC_TOKEN_EXPIRING, RC_TOKEN_STALE,
// RC_REGISTER_FAIL, RC_RELAY_DROP, SSH_HOSTKEY_MISSING — DESIGN.md §10) for a
// log-alert rule. A site without a log pipeline never sees them, and the one
// event that matters most — the monthly re-login — then surfaces as an outage.
// This script is the direct path: an HTTP push (ntfy, Slack, Discord, a generic
// JSON webhook) or a site-supplied command.
//
//   notify <MARKER> <warn|crit> <message>     called by entrypoint.sh for every marker
//   notify --test                             a test push that bypasses throttle and
//                                             minimum severity (BOOTSTRAP.md §4)
//
// Configuration (site.conf for the non-secret parts, .env for anything with a token):
//   NOTIFY_URL      where to POST. Empty = no HTTP push. The URL may embed a token
//                   (Gotify, Discord), so it is never logged.
//   NOTIFY_KIND     ntfy (default: text body + Title/Priority/Tags headers) | slack
//                   ({text}) | discord ({content}) | json ({title,message,priority,
//                   marker,sev,station})
//   NOTIFY_TOKEN    optional bearer token (an ntfy access token); .env only
//   NOTIFY_CMD      a shell command run with MARKER SEV MESSAGE appended as arguments
//                   (e.g. `sh /etc/lyngvi/site/notify.sh`); runs instead of, or as well
//                   as, the HTTP push — whichever of the two is set
//   NOTIFY_MIN_SEV  warn (default) | crit — below it, nothing is sent
//   NOTIFY_REPEAT   seconds before the same marker is pushed again (default 21600 = 6h;
//                   the watchdog re-emits every few minutes, a phone must not)
//   NOTIFY_STATE_DIR  where the per-marker throttle timestamps live (default /tmp/lyngvi-notify)
//
// Egress: the push goes through the proxy sidecar like every other client
// (NODE_USE_ENV_PROXY=1), so the NOTIFY_URL host needs one anchored line in the site's
// proxy-filter.extra.
// Output never contains the URL or the token; failures are logged by status or code.
import { execFile } from "node:child_process";
import { mkdirSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const env = process.env;
const station = env.RC_NAME || env.CONTAINER_NAME || "lyngvi";
const args = process.argv.slice(2);
const isTest = args[0] === "--test";
const [marker, sev, ...rest] = isTest
  ? ["NOTIFY_TEST", "warn", `test notification from ${station} — delivery works`]
  : args;
const message = rest.join(" ");
const log = (s) => console.log(`[notify] ${s}`);

if (!marker || !sev || !message) {
  console.error("usage: notify <MARKER> <warn|crit> <message> | notify --test");
  process.exit(2);
}
const url = env.NOTIFY_URL || "";
const cmd = env.NOTIFY_CMD || "";
if (!url && !cmd) {
  if (isTest) log("nothing configured: set NOTIFY_URL (and NOTIFY_KIND) or NOTIFY_CMD");
  process.exit(0);
}
const rank = { info: 0, warn: 1, crit: 2 };
const minSev = env.NOTIFY_MIN_SEV || "warn";
if (!isTest && (rank[sev] ?? 1) < (rank[minSev] ?? 1)) process.exit(0);

// Throttle per marker: a crit always goes out at least every NOTIFY_REPEAT, and a
// marker that escalated (warn → crit) goes out immediately.
const repeat = Number(env.NOTIFY_REPEAT || 21600) * 1000;
const stateDir = env.NOTIFY_STATE_DIR || "/tmp/lyngvi-notify";
const stamp = join(stateDir, `${marker}.${sev}`);
if (!isTest) {
  try {
    if (Date.now() - statSync(stamp).mtimeMs < repeat) process.exit(0);
  } catch { /* no stamp yet */ }
}

const title = `${station}: ${marker} (${sev})`;
const priority = sev === "crit" ? "urgent" : sev === "warn" ? "high" : "default";

async function push() {
  const kind = env.NOTIFY_KIND || "ntfy";
  const headers = {};
  if (env.NOTIFY_TOKEN) headers.Authorization = `Bearer ${env.NOTIFY_TOKEN}`;
  let body;
  if (kind === "ntfy") {
    Object.assign(headers, {
      "Content-Type": "text/plain",
      Title: title,
      Priority: priority,
      Tags: sev === "crit" ? "rotating_light" : "warning",
    });
    body = message;
  } else if (kind === "slack") {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify({ text: `*${title}*\n${message}` });
  } else if (kind === "discord") {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify({ content: `**${title}**\n${message}` });
  } else if (kind === "json") {
    headers["Content-Type"] = "application/json";
    body = JSON.stringify({ title, message, priority, marker, sev, station });
  } else {
    log(`unknown NOTIFY_KIND=${kind} (ntfy|slack|discord|json)`);
    return false;
  }
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), 10000);
  try {
    const r = await fetch(url, { method: "POST", headers, body, signal: ctl.signal });
    if (r.ok) { log(`${marker} ${sev} pushed (${kind}, ${r.status})`); return true; }
    log(`${marker} ${sev} push failed (${kind}, HTTP ${r.status})`);
    return false;
  } catch (e) {
    // fetch wraps network errors: cause.code, or cause.errors[].code when several
    // addresses were tried (an AggregateError). Only the code is logged.
    const code = e.name === "AbortError" ? "timeout"
      : e.cause?.code || e.cause?.errors?.find((x) => x.code)?.code || e.code || e.name;
    log(`${marker} ${sev} push failed (${kind}, ${code})`);
    return false;
  } finally {
    clearTimeout(t);
  }
}

function runCmd() {
  return new Promise((resolve) => {
    execFile("/bin/sh", ["-c", `${cmd} "$@"`, "notify", marker, sev, message], { timeout: 15000 }, (err) => {
      if (err) { log(`${marker} ${sev} NOTIFY_CMD failed (${err.code ?? err.signal ?? "error"})`); resolve(false); }
      else { log(`${marker} ${sev} delivered via NOTIFY_CMD`); resolve(true); }
    });
  });
}

const results = [];
if (url) results.push(await push());
if (cmd) results.push(await runCmd());
if (results.some(Boolean) && !isTest) {
  try { mkdirSync(stateDir, { recursive: true, mode: 0o700 }); writeFileSync(stamp, ""); } catch { /* throttle is best effort */ }
}
process.exit(results.some(Boolean) ? 0 : 1);

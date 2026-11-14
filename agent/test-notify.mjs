#!/usr/bin/env node
// Tests for notify.mjs: every delivery shape against a local HTTP server, the
// per-marker throttle, the minimum severity, NOTIFY_CMD, --test, and that a failure
// is reported by status or code and never by URL or token. Run: node agent/test-notify.mjs
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = new URL("./notify.mjs", import.meta.url).pathname;
const received = [];
let status = 200;
const server = createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => { received.push({ path: req.url, headers: req.headers, body }); res.writeHead(status); res.end(); });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const SECRET = "tk_sekrit_topic_token";
const state = mkdtempSync(join(tmpdir(), "notify-test-"));

// Async on purpose: a synchronous exec would block this process, which is the server.
function run(args, extra = {}) {
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, NOTIFY_STATE_DIR: state, RC_NAME: "teststation", ...extra };
  return new Promise((resolve) => {
    execFile(process.execPath, [SCRIPT, ...args], { env, encoding: "utf8" }, (err, stdout, stderr) =>
      resolve({ code: err ? err.code : 0, out: (stdout || "") + (stderr || "") }));
  });
}
let n = 0;
const ok = (name) => { n++; console.log(`ok ${n} - ${name}`); };

// 1. nothing configured: silent success (the common case for a site without a target)
{ const r = await run(["RC_TOKEN_EXPIRING", "warn", "x"]); assert.equal(r.code, 0); assert.equal(r.out, ""); assert.equal(received.length, 0); ok("unconfigured: exit 0, no output, no request"); }

// 2. ntfy shape, bearer token, priority by severity
{
  const r = await run(["RC_TOKEN_EXPIRING", "crit", "refresh token expires in 3h"], { NOTIFY_URL: `${base}/topic`, NOTIFY_TOKEN: SECRET });
  assert.equal(r.code, 0, r.out);
  const q = received.pop();
  assert.equal(q.path, "/topic"); assert.equal(q.body, "refresh token expires in 3h");
  assert.equal(q.headers.title, "teststation: RC_TOKEN_EXPIRING (crit)"); assert.equal(q.headers.priority, "urgent");
  assert.equal(q.headers.authorization, `Bearer ${SECRET}`); assert.equal(q.headers["content-type"], "text/plain");
  assert.match(r.out, /RC_TOKEN_EXPIRING crit pushed \(ntfy, 200\)/);
  ok("ntfy: text body, Title/Priority headers, bearer, logged by status");
}

// 3. throttle: same marker+sev inside NOTIFY_REPEAT is dropped; an escalation is not; a 0 repeat resends
{
  let r = await run(["RC_TOKEN_EXPIRING", "crit", "again"], { NOTIFY_URL: `${base}/topic` }); assert.equal(r.code, 0); assert.equal(received.length, 0);
  r = await run(["RC_TOKEN_EXPIRING", "warn", "first warn"], { NOTIFY_URL: `${base}/topic` }); assert.equal(received.length, 1); received.pop();
  r = await run(["RC_TOKEN_EXPIRING", "warn", "again"], { NOTIFY_URL: `${base}/topic`, NOTIFY_REPEAT: "0" }); assert.equal(received.length, 1); received.pop();
  ok("throttle: repeat dropped, new severity sent, NOTIFY_REPEAT=0 resends");
}

// 4. minimum severity
{ const r = await run(["RC_RELAY_DROP", "warn", "x"], { NOTIFY_URL: `${base}/t`, NOTIFY_MIN_SEV: "crit" }); assert.equal(r.code, 0); assert.equal(received.length, 0); ok("NOTIFY_MIN_SEV=crit drops a warn"); }

// 5. the JSON shapes
for (const [kind, key] of [["slack", "text"], ["discord", "content"], ["json", "message"]]) {
  const r = await run(["RC_TOKEN_STALE", "crit", `hello ${kind}`], { NOTIFY_URL: `${base}/${kind}`, NOTIFY_KIND: kind, NOTIFY_REPEAT: "0" });
  assert.equal(r.code, 0, r.out);
  const q = received.pop(); const j = JSON.parse(q.body);
  assert.equal(q.headers["content-type"], "application/json"); assert.match(j[key], new RegExp(`hello ${kind}`));
  if (kind === "json") { assert.equal(j.marker, "RC_TOKEN_STALE"); assert.equal(j.sev, "crit"); assert.equal(j.station, "teststation"); }
  ok(`${kind}: JSON body with ${key}`);
}
{ const r = await run(["RC_TOKEN_STALE", "crit", "x"], { NOTIFY_URL: `${base}/x`, NOTIFY_KIND: "pigeon", NOTIFY_REPEAT: "0" }); assert.equal(r.code, 1); assert.match(r.out, /unknown NOTIFY_KIND/); ok("unknown kind: exit 1, named"); }

// 6. --test bypasses throttle and minimum severity
{
  await run(["--test"], { NOTIFY_URL: `${base}/t`, NOTIFY_MIN_SEV: "crit" }); await run(["--test"], { NOTIFY_URL: `${base}/t`, NOTIFY_MIN_SEV: "crit" });
  assert.equal(received.length, 2); assert.equal(received[0].headers.title, "teststation: NOTIFY_TEST (warn)"); received.length = 0;
  const r = await run(["--test"]); assert.match(r.out, /nothing configured/); assert.equal(r.code, 0);
  ok("--test: always sends; says so when unconfigured");
}

// 7. NOTIFY_CMD gets MARKER SEV MESSAGE as arguments, with or without a URL
{
  const out = join(state, "cmd.out");
  const r = await run(["SSH_HOSTKEY_MISSING", "crit", "no entry for host"], { NOTIFY_CMD: `printf '%s|' "$@" > ${out}; printf x >> ${out}; true`, NOTIFY_REPEAT: "0" });
  assert.equal(r.code, 0, r.out); assert.equal(readFileSync(out, "utf8"), "SSH_HOSTKEY_MISSING|crit|no entry for host|x");
  const bad = await run(["SSH_HOSTKEY_MISSING", "crit", "x"], { NOTIFY_CMD: "sh -c 'exit 3' cmd", NOTIFY_REPEAT: "0" });
  assert.equal(bad.code, 1); assert.match(bad.out, /NOTIFY_CMD failed \(3\)/);
  ok("NOTIFY_CMD: arguments passed, failure exit reported");
}

// 8. failures are reported by status or code; the URL and the token never appear
{
  status = 500;
  let r = await run(["RC_REGISTER_FAIL", "crit", "x"], { NOTIFY_URL: `${base}/secret-path-${SECRET}`, NOTIFY_TOKEN: SECRET, NOTIFY_REPEAT: "0" });
  assert.equal(r.code, 1); assert.match(r.out, /HTTP 500/); assert.doesNotMatch(r.out, new RegExp(SECRET)); assert.doesNotMatch(r.out, /127\.0\.0\.1/);
  status = 200; received.length = 0;
  // a port that was just listening and is now closed (fetch refuses port 1 itself as a "bad port")
  const closed = createServer(); await new Promise((ok) => closed.listen(0, "127.0.0.1", ok));
  const closedPort = closed.address().port; await new Promise((ok) => closed.close(ok));
  r = await run(["RC_REGISTER_FAIL", "crit", "x"], { NOTIFY_URL: `http://127.0.0.1:${closedPort}/${SECRET}`, NOTIFY_REPEAT: "0" });
  assert.equal(r.code, 1); assert.match(r.out, /push failed \(ntfy, ECONNREFUSED\)/); assert.doesNotMatch(r.out, new RegExp(SECRET));
  ok("failures: status or code only, never the URL or token");
}

server.close(); rmSync(state, { recursive: true, force: true });
console.log(`1..${n}`);

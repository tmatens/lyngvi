#!/usr/bin/env node
// gh-actions-log.mjs — read a GitHub Actions job's RAW log text from inside the
// station container. This is the fallback for when the
// failure reason is NOT in the check-run annotations (bare `run:` steps only emit
// a generic "Process completed with exit code N" stub — the real output lives in
// the raw log). Prefer the annotations API first (agent/CLAUDE.md → GitHub); reach
// for this only when annotations don't carry the reason.
//
// Two-hop fetch (see DESIGN.md, egress):
//   hop 1  GET api.github.com/.../jobs/{id}/logs  → 302 to a 1-min signed blob URL.
//   hop 2  GET productionresultssaN.blob.core.windows.net/... (the redirect target)
//          → the actual log bytes. The blob host is reached only if the site's
//          `proxy-filter.extra` allowlists the
//          `productionresultssa[0-9]+\.blob\.core\.windows\.net` family. tinyproxy
//          matches the CONNECT host (not IP), so Azure's blob-account rotation is a
//          non-issue.
//
// Env: HTTPS_PROXY (or https_proxy) — if set, BOTH hops tunnel via CONNECT through
//      it (in the container the networks have no other path); if unset, both go
//      direct (so this same script is testable off-container).
// Auth: in a lyngvi stack, hop 1 goes to the token relay (LYNGVI_RELAY_GITHUB), which
//       adds the token: this process never holds it. Outside one, the GitHub PAT is
//       read from the git credential helper in-process and used ONLY on hop 1. It is never sent to the blob host and
//       never printed. The signed blob URL (which carries a short-lived SAS token)
//       is likewise never printed — only the log body goes to stdout.
//
// Usage:  node gh-actions-log.mjs <owner/repo> <job_id> [tail_lines]
//   e.g.  node gh-actions-log.mjs owner/repo 123456789 80
// Get a failed job_id from:  GET /repos/{owner}/{repo}/actions/runs/{run_id}/jobs

import net from 'node:net';
import tls from 'node:tls';
import https from 'node:https';
import http from 'node:http';
import { execSync } from 'node:child_process';

const [repo, jobId, tailArg] = process.argv.slice(2);
if (!repo || !jobId) {
  console.error('usage: node gh-actions-log.mjs <owner/repo> <job_id> [tail_lines]');
  process.exit(2);
}
const tail = tailArg ? parseInt(tailArg, 10) : 0;

// PAT from the git credential helper — never leaves this process, never printed.
function githubToken() {
  const out = execSync('git credential fill', {
    input: 'protocol=https\nhost=github.com\n\n',
    encoding: 'utf8',
  });
  const m = out.match(/^password=(.*)$/m);
  if (!m) throw new Error('no github.com credential from `git credential fill`');
  return m[1];
}

// hop 1: api.github.com → 302 Location (raw https, so we DON'T follow the redirect
// and can read the Location header; fetch(redirect:'manual') hides it as opaque).
async function redirectLocation(token) {
  const relay = process.env.LYNGVI_RELAY_GITHUB;
  if (relay) {
    // The relay adds the token and passes GitHub's 302 (and its Location) through.
    return new Promise((resolve, reject) => {
      const req = http.request(`${relay}/api/v3/repos/${repo}/actions/jobs/${jobId}/logs`, {
        method: 'GET',
        headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'lyngvi-gh-actions-log', 'X-GitHub-Api-Version': '2022-11-28' },
      }, (res) => {
        res.resume();
        if (res.statusCode === 302 && res.headers.location) return resolve(res.headers.location);
        reject(new Error(`expected 302 from logs endpoint via the relay, got ${res.statusCode}`));
      });
      req.on('error', reject);
      req.end();
    });
  }
  const socket = await connect('api.github.com', 443);
  return new Promise((resolve, reject) => {
    const req = https.request(
      `https://api.github.com/repos/${repo}/actions/jobs/${jobId}/logs`,
      {
        method: 'GET',
        createConnection: () => socket,
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: 'application/vnd.github+json',
          'User-Agent': 'lyngvi-gh-actions-log',
          'X-GitHub-Api-Version': '2022-11-28',
        },
      },
      (res) => {
        res.resume(); // drain
        if (res.statusCode === 302 && res.headers.location) return resolve(res.headers.location);
        reject(new Error(`expected 302 from logs endpoint, got ${res.statusCode}`));
      },
    );
    req.on('error', reject);
    req.end();
  });
}

// Open a TCP+TLS socket to the target host, tunnelling via HTTPS_PROXY CONNECT when set.
function connect(host, port) {
  return new Promise((resolve, reject) => {
    const proxy = process.env.HTTPS_PROXY || process.env.https_proxy;
    if (!proxy) {
      const s = tls.connect({ host, port, servername: host }, () => resolve(s));
      s.on('error', reject);
      return;
    }
    const pu = new URL(proxy);
    const raw = net.connect(Number(pu.port) || 3128, pu.hostname, () => {
      raw.write(`CONNECT ${host}:${port} HTTP/1.1\r\nHost: ${host}:${port}\r\n\r\n`);
    });
    raw.once('data', (chunk) => {
      const status = chunk.toString('latin1').split('\r\n')[0];
      if (!/ 200 /.test(status)) return reject(new Error(`proxy CONNECT failed: ${status}`));
      const s = tls.connect({ socket: raw, servername: host }, () => resolve(s));
      s.on('error', reject);
    });
    raw.on('error', reject);
  });
}

// hop 2: GET the signed blob URL over the (possibly tunnelled) socket. No auth header
// — the SAS token in the URL is the only credential the blob host sees.
async function fetchBlob(location) {
  const u = new URL(location);
  const socket = await connect(u.hostname, 443);
  return new Promise((resolve, reject) => {
    const req = https.request(
      location,
      { method: 'GET', createConnection: () => socket, headers: { 'User-Agent': 'lyngvi-gh-actions-log' } },
      (res) => {
        if (res.statusCode !== 200) {
          res.resume();
          return reject(new Error(`blob GET returned ${res.statusCode}`));
        }
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      },
    );
    req.on('error', reject);
    req.end();
  });
}

try {
  const token = process.env.LYNGVI_RELAY_GITHUB ? null : githubToken();
  const location = await redirectLocation(token);
  let body = await fetchBlob(location);
  if (tail > 0) body = body.split('\n').slice(-tail).join('\n');
  process.stdout.write(body.endsWith('\n') ? body : body + '\n');
} catch (e) {
  console.error(`gh-actions-log: ${e.message}`);
  process.exit(1);
}

#!/usr/bin/env node
// connect.mjs — an ssh ProxyCommand that tunnels through the egress proxy.
//
// The agent's networks have no gateway and no resolver (docker-compose.yml), so
// SSH to a forge cannot open a socket to it directly: the proxy sidecar opens the
// TCP connection on the agent's behalf (HTTP CONNECT) and this script pipes
// stdin/stdout through the tunnel. The entrypoint wires it for every host:
//
//   Host *
//       ProxyCommand node /etc/lyngvi/connect.mjs %h %p
//
// The proxy applies its hostname allowlist and ConnectPort policy to the tunnel
// exactly as it does to HTTPS, so a forge must be in site/proxy-filter.extra and
// its port in site/proxy-tinyproxy.extra (22 is allowed upstream). Nothing in the
// SSH session is visible to the proxy beyond the host and port: the tunnel is
// opaque bytes, and the host key pin (StrictHostKeyChecking) is checked by ssh
// at the far end of it as usual.
//
// Reads HTTPS_PROXY (or https_proxy). Prints only the proxy's status line on
// failure. Zero dependencies: node is in the image, netcat is not.
import net from "node:net";

const [host, port] = process.argv.slice(2);
if (!host || !port) { process.stderr.write("usage: connect.mjs HOST PORT\n"); process.exit(2); }
const proxy = process.env.HTTPS_PROXY || process.env.https_proxy;
if (!proxy) { process.stderr.write("connect.mjs: HTTPS_PROXY is not set\n"); process.exit(1); }
const p = new URL(proxy);

const s = net.connect(Number(p.port) || 3128, p.hostname, () => {
  s.write(`CONNECT ${host}:${port} HTTP/1.1\r\nHost: ${host}:${port}\r\n\r\n`);
});
s.once("data", (d) => {
  const text = d.toString("latin1");
  const end = text.indexOf("\r\n\r\n");
  const status = text.split("\r\n")[0];
  if (!/^HTTP\/1\.[01] 200/.test(status)) { process.stderr.write(`connect.mjs: proxy refused ${host}:${port} (${status})\n`); process.exit(1); }
  // Bytes after the CONNECT response header already belong to the tunnel.
  const rest = end >= 0 ? d.subarray(Buffer.byteLength(text.slice(0, end + 4), "latin1")) : Buffer.alloc(0);
  if (rest.length) process.stdout.write(rest);
  s.pipe(process.stdout);
  process.stdin.pipe(s);
});
s.on("error", (e) => { process.stderr.write(`connect.mjs: ${e.code || e.message}\n`); process.exit(1); });
process.stdin.on("end", () => s.end());

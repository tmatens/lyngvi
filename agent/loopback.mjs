// loopback.mjs — forward 127.0.0.1:<port> to a host:port on the internal network.
//
// GitHub's MCP server accepts a plain-HTTP API host only on loopback ("http is only
// permitted for loopback hosts such as localhost"), and the token relay speaks plain
// HTTP on the internal proxy network (relay/start.sh). The entrypoint runs this once,
// so the server can be pointed at http://localhost:18081 and reach the relay. It carries
// no credential: the relay adds the token on the far side.
//
//   node loopback.mjs <listen-port> <target-host> <target-port>
import net from "node:net";

const [listenPort, host, port] = process.argv.slice(2);
net
  .createServer((client) => {
    const upstream = net.connect(Number(port), host);
    client.pipe(upstream).pipe(client);
    const close = () => { client.destroy(); upstream.destroy(); };
    client.on("error", close);
    upstream.on("error", close);
  })
  .listen(Number(listenPort), "127.0.0.1");

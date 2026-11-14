# gVisor: a stronger kernel boundary (opt-in)

By default the agent runs under runc and shares the host's kernel, behind Docker's default
seccomp profile, `cap_drop: ALL`, `no-new-privileges` and a non-root uid. A kernel exploit
reachable from that surface is a container escape (DESIGN.md §11). Running the agent under
[gVisor](https://gvisor.dev) (`runsc`) puts a user-space kernel between the agent and the
host: the agent's syscalls go to gVisor, and gVisor makes a much narrower set of its own.

It is a site choice, not the default, for three reasons: it needs software on the host,
filesystem-heavy work is slower, and Docker's container-name DNS does not work under it, so
the compose file needs fixed addresses (below).

## What was tested

The full `scripts/smoke.sh` passes with the agent under `runsc` and the override in
[`examples/gvisor/compose.gvisor.yml`](../examples/gvisor/compose.gvisor.yml), and
`doctor --live` reports no failure. That covers egress by network layout, the proxy's
default-deny, the token relay, the key sidecar with SSH signing and DCO, the decoys, the
read-only root filesystem, the settings reset across a restart, and the markers. Tested
with gVisor `release-20261102.0` on x86_64, Docker Engine 29.7.2, with the sidecars on runc.

## Host setup

1. **Install runsc** from gVisor's release, checked against its published SHA-512 (the
   [install guide](https://gvisor.dev/docs/user_guide/install/) has the current URLs):

   ```bash
   ARCH=$(uname -m)
   URL=https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH}
   curl -fsSLO "$URL/gvisor.tar.zstd" && curl -fsSLO "$URL/gvisor.tar.zstd.sha512"
   sha512sum -c gvisor.tar.zstd.sha512
   sudo tar --zstd -xf gvisor.tar.zstd -C /usr/local/bin   # runsc, its shim, gvisor-bin/
   ```

2. **Register it with Docker** with one runtime argument, in `/etc/docker/daemon.json`:

   ```json
   "runtimes": {
     "runsc": { "path": "/usr/local/bin/runsc", "runtimeArgs": ["--host-uds=open"] }
   }
   ```

   `sudo runsc install` writes the entry without the argument; add it by hand. Then
   `sudo systemctl reload docker`. A reload does not restart running containers.

   **Why `--host-uds=open`:** the agent reaches the key sidecar's ssh-agent through a Unix
   socket on the shared `keys` volume, and the sidecar runs under runc. Without the flag,
   gVisor refuses to connect to a socket it did not create, and SSH and signing stop
   working. `open` allows connecting only, not creating, and only to sockets inside the
   container's own mounts. The only socket mounted into the agent is that one.

3. **Check it:** `docker run --rm --runtime=runsc alpine dmesg | head -1` prints
   `Starting gVisor...`.

## The compose override

Add [`examples/gvisor/compose.gvisor.yml`](../examples/gvisor/compose.gvisor.yml) to the
stack's `-f` list, or copy its contents into the overlay's override. It does three things:

- **The agent runs under `runsc`.** The sidecars stay on runc. They hold the key, the
  tokens and the allowlist, but they run no agent-supplied code.
- **The proxy and the relay get fixed addresses** on `lyngvi-proxy-net`, and the agent
  gets them as `/etc/hosts` entries. gVisor's network stack cannot reach Docker's embedded
  DNS server on a user-defined network, so container names do not resolve at all
  ([gVisor FAQ](https://gvisor.dev/docs/user_guide/faq/)). gVisor's
  `--reproduce-nat`/`--reproduce-nftables` flags did not fix that on an nftables host
  (tested). The agent needs only those two names, because everything else goes through the
  proxy, which resolves names itself. The egress layout is unchanged: the networks stay
  `internal` with an isolated gateway.
- **An overlay that changes `lyngvi-proxy-net`'s subnet** changes the two addresses with
  it.

Without the fixed addresses, nothing reaches the proxy or the relay, and `doctor --live`
fails on both. `doctor --live` reports which runtime the agent runs under.

## What it costs

Two stations on one host ran the same task list one after the other: one under runc, one
under runsc with this override. Each step is the median of three runs, timed in the
agent's shell, in a scratch directory on the `workspace` volume.

**The host:** x86_64, 4 cores / 8 threads (Intel Core i3-1215U), 7.5 GB RAM, NVMe, Debian 13
(kernel 6.12), Docker Engine 29.9.3, gVisor `release-20261102.0`. Each agent had upstream's
limits: 2 CPUs and 4 GB.

| Step | runc | runsc | Ratio |
|---|---:|---:|---:|
| Write 5,000 × 1 KB files in 50 directories | 0.32 s | 2.57 s | 8× |
| `find` over them | 0.005 s | 0.056 s | 11× |
| `rm -rf` them | 0.028 s | 0.18 s | 6× |
| `git add` of the 5,000 files | 0.046 s | 0.26 s | 6× |
| `git commit` of them | 0.036 s | 0.28 s | 8× |
| `git status`, nothing changed | 0.022 s | 0.15 s | 7× |
| `grep -rn` over a 440-file Go repository | 0.011 s | 0.058 s | 5× |
| 200 empty commits in a loop, per commit | 35 ms | 153 ms | 4.4× |
| 20 signed commits through the key sidecar, per commit | 37 ms | 114 ms | 3× |
| `go test ./...` on that repository | 6.3 s | 12.2 s | 1.9× |
| `go build ./...`, warm | 0.21 s | 0.51 s | 2.4× |
| `go build ./...`, cold (empty build cache) | 9.3 s | 13.7 s | 1.5× |
| `pip install requests pandas` into a new venv | 8.3 s | 9.6 s | 1.2× |
| `npm install lodash express` | 3.1 s | 4.0 s | 1.3× |
| Clone over SSH (proxy) and HTTPS (relay) | 0.58–0.67 s | 0.75–0.82 s | 1.2–1.3× |
| Write 1 GB with `dd … conv=fsync` | 0.56 s | 0.62 s | 1.1× |

**Reading it:**
- **Filesystem metadata costs 5–11×.** Under runsc the workspace is reached through
  gVisor's file proxy (the gofer), so every create, stat and unlink costs more. Git is
  mostly small-file work, so a commit takes about 150 ms instead of 35 ms.
- **Real work costs 1.2–2×.** Test suites, builds, package installs and clones mix that
  cost with CPU and network time. Large sequential I/O is close to unaffected.
- **Signing through the key sidecar works under runsc** (`--host-uds=open`). It adds a few
  milliseconds over an unsigned commit in either runtime.
- **The agent spent longer at its CPU limit:** about 2 minutes under runsc against
  25 seconds under runc, sampled every 5 s across the whole task list. A site with spare
  cores can raise the agent's `cpus` in its overlay to win part of that back.
- **Memory:** the agent peaked at about 1.07 GB under runsc against 665 MB under runc. Idle
  with one session attached, it was about 740 MB against 80–350 MB. Upstream's 4 GB limit
  left ample room in both.

In absolute terms, ordinary agent work (reading, editing, a commit) stays well under a
second per step, while each model turn takes seconds. Where it shows is test suites and
cold builds, which take about twice as long.

**Caveats:**
- The agent ran the task list from a written prompt, so the timer differed between the two
  runs.
- File reads were served from the page cache in both runs.
- Differences under about 1.3× are within the run-to-run spread.

## What it does not change

gVisor narrows one residual: a kernel exploit from inside the agent. It does not change
what the agent may do through the channels it has on purpose: the proxy's allowlist, the
relay's routes, the key sidecar's signing, and the workspace. The rest of DESIGN.md §11
still applies.

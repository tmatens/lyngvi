# lyngvi

*Lyngvi is the island where the Norse gods bound the wolf Fenrir. They tried two heavy
chains first, and the wolf broke both. What held was a fetter that looked like a ribbon,
threaded through a boulder and fastened to bedrock.*

**A coding agent station whose security does not depend on the agent's behaviour.** The
agent (the official Claude Code CLI, driven from a phone or browser via Remote Control)
runs in a hardened container with real, scoped credentials. It can clone, build, test,
commit, push branches and open pull requests. It **cannot** merge to a protected branch,
reach the host, leave the egress allowlist, widen its own permissions, or read a secret it
was not handed. Every one of those "cannot"s is enforced by something outside the
agent's reach: branch protection and token scope, networks with no gateway and a
hostname-filtering proxy as the only way out, image-baked settings, and two hooks that
keep secrets from landing in its context by accident. The `CLAUDE.md` it reads gives
it instructions and enforces nothing.

The reference implementation uses Claude Code. The pattern (scoped credentials + PR-only
forge rules + egress by network layout + a disposable, non-root container) applies to any
coding agent that can run headless in a container.

## Who this is for

Security and platform engineers who have to let an agent hold credentials and want the
controls to be *mechanical*: things a reviewer can verify by reading a ruleset, a compose
file and a Dockerfile, not by trusting a system prompt.

## Threat model

A summary. [DESIGN.md](DESIGN.md) has the reasoning.

| Threat | Control |
|---|---|
| Prompt injection → code lands on a deploy-wired branch → code runs on a host | **Branch protection is the deploy control.** The agent's identity cannot push the protected branch; on forges where an API token could merge, the agent's token has no write access to the repository. A reviewed merge is the only path. |
| Prompt injection → the agent does something else harmful | Non-root, `cap_drop: ALL`, no docker socket, no host mounts, no inbound port, `noexec` `/tmp`, resource limits; networks with no route out except a hostname-allowlist proxy. |
| Secret exfiltration | Egress allowlisting is **anti-C2, not anti-exfil**: every allowed host is a channel. The primary control is a tiny, scoped credential set. Two hooks block secret-dumping command shapes and redact secrets from tool output. |
| Lateral movement to the host or other containers | The agent's networks are `internal` with an isolated gateway: Docker forwards nothing, the bridge carries no host address, there is no resolver. Nothing to drop because there is no route. |
| Container escape | Non-root uid, all capabilities dropped, `no-new-privileges`, no privileged helpers. |
| Credential theft via a dependency | Scoped, revocable credentials; lockfiles and `--require-hashes`; the agent never holds a decryption key. |
| Control-plane account compromise | The Remote Control account is a primary credential: MFA, and the OAuth credential is treated as a secret at rest. |
| Supply chain (agent CLI, images, tools) | Everything is pinned by digest or hash; Renovate proposes updates; the agent's own CLI bump is never automerged. |

## The eight non-negotiables

1. **No host control** from the container: no docker socket, no host bind mount, no host
   SSH, never `--privileged`.
2. **The agent never writes a deploy-wired branch.** Branch protection and token scope
   enforce this, not an instruction.
3. **No inbound port.** Remote Control is outbound-only.
4. **Default-deny egress by construction**: the agent's networks have no gateway, and the
   proxy's hostname allowlist is the only way out; each allowed host is one line with
   one reason.
5. **The secrets-decryption key never enters the container.** Nothing plaintext is
   committed; exceptions are recorded with reasoning.
6. **Least-privilege git credentials, held outside the agent.** A scoped key and a
   fine-grained token, never a personal master key. The key lives in a key sidecar with
   no network, and the tokens in a token relay. The agent can use them while it runs but
   never holds them.
7. **Non-root, `cap_drop: ALL`, no capability exceptions, read-only root filesystem.**
   Egress is a property of the networks, not a rule inside the container, precisely so it
   needs none.
8. **Deploys are PR-gated**; the container is never a privileged actor.

## What the agent can and cannot do

| Can | Cannot | Enforced by |
|---|---|---|
| Clone, build, test, lint | Reach the host, the LAN, or other containers | `internal` networks with an isolated gateway: no route exists; no socket |
| Commit (signed, DCO) and push **branches** | Push `main` on any protected repo | Forge branch protection / ruleset; the key and token are not whitelisted |
| Open and update pull requests, comment, label, read CI | Merge a pull request | The API token has no repository write, so it cannot merge (Forgejo); a separate bot account with no write access to the repository, working from a fork (GitHub) |
| Sign, push and call the forge APIs | Copy out its SSH key or an API token | It never holds them: the key sits in a key sidecar with no network (it gets an ssh-agent socket), and the tokens in a token relay that adds them on the way out |
| Open PRs, issues and comments through the API | Add webhooks, deploy keys, push mirrors or collaborators, read secrets, create tokens | The token relay refuses those endpoints even where the token allows them |
| Install packages from PyPI / npm; reach the relay, GitHub, the forge | Reach any other host | One tinyproxy hostname allowlist, the only path out; names resolve only at the proxy |
| Read a secret it was handed, in-process | Print one by accident: `.env` files, its SSH key, its OAuth credential, `docker inspect`, an environment dump, a password in argv | `block-secret-dumps` blocks those command shapes; `redact-tool-output` replaces the host's own secret values, and anything gitleaks recognises, in every tool result. Seatbelts against accidents, not a wall: an interpreter that opens the file deliberately is not stopped |
| Use the grants the image gives it | Turn off its hooks, add a hook or an MCP server, or bypass permission prompts | Managed settings baked into the image, root-owned; the CLI ranks them above anything the agent can write ([DESIGN.md §4.5](DESIGN.md)) |
| Run for weeks across disconnects | Exist, even for a second, without the egress control | The control is the network definition; there is no apply step to be early for |

## Branch protection is the deploy control

A hardened container is necessary and not sufficient. If any repo the agent can write has
a pipeline that deploys on push to `main`, then **a push to `main` is code execution on
that host**, and the container's own hardening is irrelevant to it. So the control that
actually protects infrastructure is the rule on `main`:

- **GitHub:** import [`scripts/github-main-ruleset.json`](scripts/github-main-ruleset.json)
  (PR required, squash only, linear history, no deletion or force-push, no bypass actors).
  Direct push is blocked for everyone. To also block the agent from *merging* its own PR,
  give it its own account with **no write access** to the repo: it works from a fork, and
  merging is then a permission it does not hold.
- **Forgejo / Gitea:** "block the bot only": a push whitelist of the humans, deploy-key push
  disabled, and an API token with no repository write, which merging needs. Humans keep their workflow; the
  bot can only propose.
- **Derive the protected set from the real trigger.** The set of repos that need the rule
  is "every repo the bot can write that has a deploy workflow on push to `main`". Compute
  it from the forge API and the workflow files, never from a hand-kept list, which
  goes out of date without anyone noticing.

This repo protects its own `main` the same way (`.github/rulesets/main.json`), and a
scheduled job fails if the live ruleset drifts from the committed one.

## Architecture

```
  phone / browser ──outbound TLS──▶ Anthropic relay ◀──outbound TLS, no inbound port──┐
                                                                                      │
  host ─ Docker ─ lyngvi-net + lyngvi-proxy-net: internal, isolated gateway ─ lyngvi (uid 10001)
      │              (no route out, no host address on the bridge, no resolver)         │
      │  claude remote-control, supervised                                               │
      │  ├─ volume: workspace     (disposable clones)                                   │
      │  ├─ volume: claude-home   (~/.claude: OAuth credential, settings)  [secret-bearing]
      │  └─ read-only root; holds no SSH key and no API token
      ├─ lyngvi-keys  (no network)  ssh-agent with the SSH key; the agent gets its socket
      ├─ lyngvi-relay (proxy net)   adds the API tokens; refuses webhooks, keys, mirrors, …
      └─ lyngvi-proxy (tinyproxy, hostname allowlist; decoy alarm) ─ lyngvi-proxy-out ─▶ relay, forge, GitHub, registries
```

One egress layer, by hostname, and it is the only path: the relay, GitHub, the forge
(SSH through a CONNECT tunnel) and the registries all go through the proxy, so CDN IP
rotation is irrelevant and a host that is not listed is unreachable rather than filtered.
A proxy fault is a visible outage, including Remote Control; that is the trade made on
purpose against a control whose failure could be silent.

## Quick start

Runs end-to-end with the example values in `site-example/` and no secrets:

```bash
scripts/doctor.sh                  # preflight: tools, site files, the egress layout
docker compose build
docker compose up -d
scripts/doctor.sh --live           # the running container: key, signing, pinning, hooks, proxy, egress
docker compose logs -f lyngvi      # reaches "login needed / config", expected without a login
```

The doctor is the same script an operator runs against a real deployment
(`--online` adds the forge: host key, key registration, token scope). Every check is one
line, named, and it never prints a secret. Docker Engine 28.0 or later is required: an
older engine refuses to create the networks, which is the correct failure.

What CI proves on every PR ([ci.yml](.github/workflows/ci.yml)): both images build with
every toolchain switch on and off; the agent reaches its supervisor loop with no secrets;
the proxy returns `403 Filtered` for `example.com` and `200` for `pypi.org`; the agent has
no default route, no resolver and no host address on its bridges, and reaches GitHub over
HTTPS and SSH only through the proxy tunnel, before and after a daemon restart;
shellcheck, hadolint, actionlint, compose-lint and the hook unit tests pass; and the
leak check finds none of the generic shapes of a private deployment detail (private
addresses, key material, home paths).

What a human must do once, in [BOOTSTRAP.md](BOOTSTRAP.md): the interactive `/login`,
the workspace-trust dialog, registering the signing key, and applying branch protection
with an admin token the container never holds. Nothing on the host: the egress control is
in the compose file.

## Running it for real: the overlay

Do not fork and edit. Keep this repo as an untouched submodule and layer your deployment
on top: a `site/` directory (identity, forge host, pinned host keys, settings grants,
proxy allowlist additions) and a `compose.yaml` that extends the services here.
`scripts/new-overlay.sh ../my-station` creates exactly that, with a validate workflow and
a README that is the bootstrap checklist; `scripts/doctor.sh` then tells you what is left.
Secrets arrive as a `.env` produced on the host by whatever you already use (SOPS, a vault
agent). Nothing private ever needs to exist in this repo. Its CI refuses the generic
shapes of private detail, and your overlay checks your own list of private strings
against it before you push here. See [docs/OVERLAY.md](docs/OVERLAY.md).

## Rejected alternatives

- **Self-hosted agent middleware that runs as your user** with an unsandboxed shell RPC.
  Adds an unaudited trust party to avoid a relay you already trust for inference.
- **Enforcing egress inside the container** with `NET_ADMIN`. Conflicts with
  `cap_drop: ALL` and is reversible from inside; enforce it where the agent cannot reach.
- **A host-applied firewall** (`DOCKER-USER` chain, `INPUT` drops, systemd units run as
  root). The first design; it worked, and it produced two silent defects, both
  consequences of enforcing a declared property with an apply step. Replaced by networks
  that have no route to enforce against, and removed in v0.5.0 (`host/README.md` has the
  uninstall for a host that still carries it).
- **A privileged firewall sidecar** (host netns, `NET_ADMIN`, the socket). Portable, but
  it adds a root-equivalent container to a stack that is defined by having none.
- **Cloud-hosted agent VMs.** They cannot reach a self-hosted forge, and the host and its
  rules belong to the provider.
- **Trust-on-first-use host keys.** Host keys are public; commit them and fail closed.
- **Long-lived tokens for Remote Control.** Verified infeasible: it rejects
  inference-only tokens, so a full-scope login is required and must be renewed by a
  human roughly monthly. The watchdog pages before the expiry, not after.
- **Backing up the OAuth credential.** Restoring a copy re-introduces a consumed
  single-use refresh token and causes the outage it was meant to prevent.
- **A hand-kept list of protected repos.** It went out of date; derive the set.

## Limitations and open items

- **GitHub cannot separate "push a branch" from "merge a PR"** for one identity: both need
  Contents: write. With a single identity, PR-only blocks direct push but not self-merge;
  the agent-side classifier is the only gate. The fix is a separate bot identity that has
  no write on the repo at all and contributes from a fork. This repo's own `main` gates
  merges on CI alone (no required review, no bypass actors, required checks that only
  GitHub Actions can report), so dependency bumps merge themselves. Forgejo's scoped API tokens do separate push from merge.
- **Egress control is anti-C2, not anti-exfil.** Every allowed host is an exfil channel.
  Not built: pull-through caches, a destination-pinning git proxy. (DNS tunnelling is
  gone: the agent has no resolver, names resolve only at the proxy.)
- **The proxy matches the CONNECT host, not SNI.** A compromised client could reach a
  co-tenant of a CDN-fronted allowed host. The exposure is limited to those hosts and is
  accepted.
- **A proxy fault is an outage.** Everything, Remote Control included, leaves through the
  proxy. The sidecar is tiny, pinned, read-only and restarts on its own; the trade is a
  loud failure over the silent ones the host firewall produced.
- **Docker Engine 28.0 or later** is a hard requirement (isolated gateway mode). Older
  engines refuse the network. A rootless engine keeps the guarantee (the engine owns it),
  and amd64 and arm64 both build: the `portability` workflow tests the rootless stack
  end to end and the arm64 images on every change to the image or stack, and weekly.
  Podman is untested.
- **Remote Control needs an interactive login about monthly.** No unattended renewal
  exists; the credential-health watchdog turns the outage into a scheduled minute, and
  pushes the 48 h warning to a phone (ntfy, Slack, Discord, a webhook or a site command)
  when the site names a target. [docs/REMOTE_CONTROL.md](docs/REMOTE_CONTROL.md) is the
  runbook for when it is missed.
- **The OAuth credential is plaintext at rest** in a named volume. The CLI writes it
  itself; it is account-scoped and revocable, never backed up, never in the repo.
- **The host user that runs deploys is typically root-equivalent** (docker group). That
  boundary is the account, not this container; it is why deploy engines live in
  human-merge-only repos and the agent is not in them.
- **Alert markers report faults, not compromise.** The watchdog and `notify` run in the
  agent's container, so a compromised agent can forge, silence or send them
  ([DESIGN.md §10](DESIGN.md)). A notification that asks for anything beyond the
  `/login` runbook is itself a warning sign; [docs/INCIDENT.md](docs/INCIDENT.md) is
  what to do then. The proxy's log and opt-in tool-call telemetry hold even then, if shipped off
  the host ([docs/AUDIT.md](docs/AUDIT.md)).
- **Hooks guard against accidents only.** They fail open on error (announced once), see only tool calls,
  and cannot stop an interpreter reading a file. Judgement still carries the load.

## Contributing

PRs welcome. Commits are signed; the leak check is a required status check and its
output never contains the matched text. See [CONTRIBUTING.md](CONTRIBUTING.md).

MIT. See [LICENSE](LICENSE).

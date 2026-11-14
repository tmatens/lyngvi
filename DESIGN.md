# lyngvi: design and threat model

This is the reasoning behind the controls. The README is the summary; this file is where
each boundary is argued, each caveat is recorded, and each accepted residual is written
down so nobody re-litigates it from memory.

## 1. Goal

A persistent coding-agent environment that

1. runs on a host you control and is reachable remotely, including from a phone;
2. can work against a public forge (GitHub) **and** a self-hosted one;
3. has **no** host shell access (Tier 0, §4.1);
4. has locked-down egress (default-deny allowlist, §4.2);
5. holds real credentials **without** becoming a path to compromise the host or
   exfiltrate secrets.

The non-negotiable framing: the agent reads untrusted content (web pages, issues,
dependencies) and can be steered by it. Nothing below assumes it behaves.

## 2. Front-end: Remote Control

The agent is the official Claude Code CLI; the remote/mobile front-end is Anthropic
Remote Control (`claude remote-control`). The agent runs **locally** in the container; only
the phone↔agent control link is brokered, **outbound HTTPS only, no inbound port**. Because
the agent is local, it uses the container's own git credentials, so it pushes to both
forges; the GitHub-only limitation belongs to the hosted "Claude Code on the web" product.

**Trust framing.** This adds no new third-party trust beyond the inference provider, but it
is not zero new surface: the relay is a control plane that can *drive* the agent, and
access is account-based. Treat the account as a primary credential and enforce MFA.

### Requirements and first-run failure modes (verified)

- **Full-scope login required.** A `setup-token` / `CLAUDE_CODE_OAUTH_TOKEN` is
  inference-only and Remote Control rejects it: the token lacks the `user:profile` scope
  the eligibility check requires, the scope is server-issued, and the CLI states the
  refusal outright. There is no longer-lived credential; this is the steady state.
- **The refresh token has a hard expiry** (`refreshTokenExpiresAt`, ~30 days after the
  interactive login) that rotation does **not** extend. Past it, the next refresh fails
  and the CLI empties the credential file: a "warm" death where the relay stays
  connected, the healthcheck stays green and every session 401s. The entrypoint's
  watchdog reads the timestamp (metadata only, never values) and pages at 48 h and 12 h,
  so the monthly re-login is scheduled, not discovered.
- **Single-use refresh tokens + container recreate.** A recreate cold-starts the CLI
  from the on-disk credential; if that copy was already rotated, registration 401-loops
  until an interactive `claude /login`. Mitigation is to recreate rarely (deploy only on
  real changes) and to detect the loop (`RC_REGISTER_FAIL`). Deliberately **not** done:
  locking or backing up the credential file (restoring a stale copy re-introduces a
  consumed token) or automating recovery (re-auth is an interactive OAuth flow by design).
- A one-time workspace-trust dialog must be accepted in the project dir.
- Plan gating applies (Pro/Max/Team/Enterprise); on Team/Enterprise an admin must
  enable the Remote Control toggle. `CLAUDE_CODE_USE_BEDROCK/VERTEX/FOUNDRY`,
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` and `DISABLE_TELEMETRY` break eligibility
  and must be unset.
- A network outage over ~10 minutes exits the process; the supervisor relaunches it.

## 3. Persistence

Named volumes for `workspace/` and `~/.claude`; the CLI runs under a supervisor loop with a
detached `tmux` session for humans. **Gotcha:** the CLI's main config (`~/.claude.json`)
defaults to a path *beside* `~/.claude`, outside the volume, and is lost on recreate,
which breaks login/org detection. `CLAUDE_CONFIG_DIR=/home/claude/.claude` puts config,
credentials and settings in the one persisted volume.

## 4. Security boundaries

### 4.1 Host access: Tier 0, and why Tier 0 is not enough

The container touches nothing on the host: no docker socket, no host bind mounts, no host
SSH, never `--privileged`; non-root, `cap_drop: ALL`, `no-new-privileges`, `noexec` `/tmp`,
resource limits, and a **read-only root filesystem**. The agent can write to exactly four places:
- the `/tmp` and home-directory tmpfs mounts, both `noexec`, which the entrypoint
  rebuilds at every start, so nothing written there outlives a restart;
- `workspace`;
- `.claude`, which holds the login and the CLI's state;
- `cache`, which holds the build caches. `GOPATH` and npm's cache are moved under `~/.cache`
  so that a restart does not mean a cold build.

The DCO `prepare-commit-msg` hook is baked into the image
(`/etc/lyngvi/git-hooks/`, root-owned) rather than written into the home directory, so
the agent cannot edit it.

Running as non-root already kept the agent out of the system paths. What read-only adds is
a writable surface that can be listed and audited, with no stray state in the
container layer.

**But container hardening does not compose with a deploy pipeline.** If any repo the agent
can write deploys on push to `main` (a runner that SSHes to a host and runs
`docker compose build && up` on repo-resident files), then the pipeline deterministically
executes whatever lands on `main` (attacker-controllable Dockerfiles, compose files,
scripts) as a privileged host user. "The privileged actor is the deterministic pipeline,
not the container" is false under composition: the pipeline executes the container's
output. Two statements are both true and must not be conflated:

- *The running container is not a privileged actor.* It never holds a deploy key and
  cannot reach the host gateway.
- *A push to a deploy-wired `main` is host code execution.* The control for that is not
  in the container at all. It is branch protection (§7).

### 4.2 Egress: default-deny by construction, one layer, and its scope

The agent is attached only to networks that are `internal` **and** created with
`com.docker.network.bridge.gateway_mode_ipv4=isolated` (Docker Engine ≥ 28.0). Together
those mean: Docker forwards and NATs nothing from the subnet; the bridge carries **no host
address**, so the host itself (and any service bound to `0.0.0.0`) is unreachable; and
there is **no resolver**: the embedded DNS answers SERVFAIL for external names. The
container has no default route. It can open a socket to exactly one thing: the proxy
sidecar on the other end of `lyngvi-proxy-net`.

Everything therefore leaves through **one hostname-allowlist proxy** (tinyproxy, HTTP
host and HTTPS/SSH `CONNECT` host), the stack's only container with a non-internal
network:

- **The relay** (`api.anthropic.com`), **the login and OAuth refresh hosts**
  (`claude.ai`, `platform.claude.com`), **GitHub** (`github.com`, `api.github.com`), and
  the **package registries**, listed upstream with one reason each (`proxy/filter`).
- **Opt-in presets** (`proxy/presets/`, the proxy's `PROXY_PRESETS` build arg) for a
  toolchain whose registry is not a plain mirror. `go` opens the Go module proxy and
  checksum database, which fetch any public module path from its origin on request, so a
  path the agent picks becomes a request to a host the agent picks. That is a channel
  out the base list does not have, so it is on only where the site needs Go;
  `scripts/doctor.sh` warns when `WITH_GO` and the preset disagree.
- **The site's forge and notification host**, listed in `site/proxy-filter.extra`.
  `ssh` reaches the forge through a `CONNECT` tunnel (`Host *` `ProxyCommand` →
  `agent/connect.mjs`, zero dependencies); the host-key pin is verified by ssh at the far
  end of the tunnel exactly as before. A forge port other than 22 is one `ConnectPort`
  line in `site/proxy-tinyproxy.extra`.
- **Every line is a hostname pattern, not any regex.** tinyproxy accepts any extended
  regex, and one regex can allow every host: `^a|[a-z0-9-]+$` is anchored and its right
  half matches nearly any name. `proxy/check-filter.sh` admits only `^…$` built from
  hostname characters, `\.` and `[a-z0-9.-]+` under at least two literal labels, and a
  line outside it fails the proxy build (and `scripts/doctor.sh`, earlier). The refused
  "host" in the proxy's log is whatever the client sent, so `scripts/refused-hosts.sh`
  treats it as untrusted: it offers only plain hostnames as lines and shows anything
  else escaped, as a warning, never as a line.
- **Every client honours the proxy**: the CLI, git and ssh read `HTTPS_PROXY`;
  `NODE_USE_ENV_PROXY=1` makes node's `fetch`/`https` do the same (the notifier, the
  forge MCP adapter, the Actions-log fetcher); GitHub's MCP server, a Go binary, reads
  `HTTPS_PROXY` itself. A client that resolves a name itself
  simply fails, loudly: there is nothing to resolve with.
- **Proven in CI on every PR**: `example.com` → `403 Filtered`, `pypi.org` → `200`, no
  default route, no resolver, no host address on either bridge, git over HTTPS and ssh to
  GitHub only through the tunnel, before and after a daemon restart.

**Why a property and not a rule set.** The previous design enforced the same policy from
the host: a `DOCKER-USER` chain, `INPUT` drops, a timer to refresh rotating CIDRs, a unit
to start the container only after the rules were applied, all installed as root by a
human. It worked, and it produced two silent defects (a timer that never
re-ran its target, and an installer step that bounced the container), both consequences
of enforcing a declared property with an apply step. A network with no gateway has no
apply step: there is no moment at which the agent exists without the control, nothing to
refresh, nothing to install, and no dependency on the init system, the iptables binary or
Docker's firewall backend. Rootless engines keep the guarantee because the engine owns
it (the `portability` workflow runs the full stack on one). The host path was removed in v0.5.0; `host/uninstall.sh` clears it from a host.

**What this trades away, on purpose.** Two layers that "fail differently" become one: a
proxy fault now takes Remote Control down, not only package installs. The sidecar is
tiny, pinned by digest, read-only, capability-less and restarts on its own, and a loud
failure is preferred over the silent ones above. A compose-file merge can now remove the
control, where the host chain survived one; that merge is already the authority over
`cap_drop`, the socket and the mounts, and overlay CI lints compose before it merges.

**Scope of this control: egress allowlisting is anti-C2, not anti-exfil.**
Every allowed host is a working exfil channel (push to an attacker's repo, the relay
itself). DNS tunnelling is no longer one: the agent has no resolver. The primary exfil
control is keeping the credential set tiny and scoped (§4.3). The next steps, not built:
read-only pull-through caches, a git proxy that pins destination repos.

**Residual: CONNECT host ≠ TLS SNI.** tinyproxy sees the CONNECT host, not what the TLS
tunnel negotiates, so a *compromised* client could reach a co-tenant of a CDN-fronted
allowed host. Bounded domain-fronting, accepted, the same class for every proxied host.
Sites that allow GitHub's Actions raw-log blob store through the proxy widen this residual
(a larger co-tenant pool) and should say so in their overlay. `ConnectPort` is per proxy,
not per host: an allowlisted HTTPS host is also tunnelable on 22, which is why the forge
port is a documented site value and not a wildcard.

**Residual: connections the forge makes for you.** Some forge features open a connection
from the forge's side, where this proxy never sees it: a push mirror, a webhook, a
repository migration, or a coding agent the forge runs on its own machines (GitHub
Copilot). Any of them can carry code or data to a host the agent chooses. The control is
the credential: each needs repo-admin (or an account-level grant) that the bot's token
must not hold (BOOTSTRAP.md §1). The forge MCP servers start with those tools switched off
(forgejo-mcp `admin` and `repo-settings`; github-mcp `copilot`), which removes the easy path
and documents it, but it is not a boundary: the token reaches the same API without the
server, and the agent is told not to use it that way (`agent/CLAUDE.md`), an instruction,
not a mechanism.

**Residual: commits written through the API.** A forge API that writes files makes the
commit on the forge, not in the agent's git: it carries neither the agent's signing key nor
its DCO sign-off, and some forges sign such commits with their own key, so they can still
show as verified. github-mcp starts without those tools, but a token with Contents write
can make the call directly. A DCO check in CI still catches the missing sign-off; a
signed-commits rule may not, since the forge's signature can satisfy it. What is lost is
the proof that the agent's own key made the commit.

**Residual: the `go` preset, when a site turns it on.** The Go module proxy fetches any
public module path from its origin on request, so a module path the agent chooses becomes
a request, made by Google's proxy, to a host the agent chooses: a way out the base list
does not have. It is opt-in (`PROXY_PRESETS`) for that reason.

**Restart policy.** `unless-stopped`. On the layout above the policy carries no egress
risk: whoever starts the container, it comes back on isolated networks with the proxy as
its only path. Up to v0.3.x it was `"no"`, because the old host path needed its unit to
start the container after the firewall; a host that still carries that unit runs
`host/uninstall.sh` before taking v0.4.0 or later, since the daemon restarting the container
before the unit re-applies the firewall would reopen the window that path closed.

**IPv6:** the bridges are v4-only; `enable_ipv6` is not set, so there is no v6 path to
isolate. A site that enables v6 on these networks must add `gateway_mode_ipv6: isolated`.

### 4.3 Credentials: the contract

| Credential | Scope |
|---|---|
| Git SSH key | A dedicated bot/deploy key, also the commit-signing key. Never a personal key. Held by the **key sidecar** (below), never by the agent. |
| Forge API token | Issues R/W + repository read. **No merge scope, no admin scope.** |
| GitHub token | Fine-grained PAT, specific repositories, Contents/Pull requests/Issues. No Administration, no Workflows unless a documented need. |
| Remote Control | Full-scope account OAuth in the `claude-home` volume. MFA on the account. |

The agent never holds: a secrets-decryption key, a deploy key to any host, an admin token,
or its own SSH private key.

**The key sidecar.** `lyngvi-keys` (`keys/start.sh`) runs an ssh-agent with the SSH keys and
serves only its socket and the public keys, on a volume the agent mounts read-only.
- **No network** (`network_mode: none`), read-only, no capabilities, and the agent's uid,
  which ssh-agent requires of a client.
- **The agent never gets the private key.** Its service blanks `GIT_SSH_KEY_B64` (and any
  `SSH_KEY_<NAME>_B64`), so `/proc/*/environ` and the volumes carry no private key.
- **What the agent can still do:** sign and push through the socket while it runs. That is
  its job.
- **What it can no longer do:** copy the key out. Revoking access is just stopping the
  sidecar.
- **Checks:** a key set in the agent's environment raises `KEY_IN_AGENT sev=crit`, and
  `doctor --live` fails on it.
- **The Claude login stays in the agent:** the CLI needs it in-process. A station in
  `LYNGVI_MODE=api-key` (docs/API_KEY_MODE.md) has none: the relay holds the API key
  (`:8084`, `/v1/messages` and `/v1/models` only) and the agent sends a placeholder. The
  cost is no Remote Control, which the CLI allows only with a subscription login.

**The token relay.** `lyngvi-relay` (`relay/start.sh`, Caddy pinned by digest) holds the API
tokens, and the agent's service blanks `GITHUB_TOKEN` and `FORGE_API_TOKEN`.
- **How the agent reaches it:** plain HTTP on the internal proxy network. The relay adds
  the token and makes the verified HTTPS call itself, through `lyngvi-proxy`, so the
  allowlist and the proxy's log still apply.
- **Routes,** each present only when its token is set:
  - GitHub's REST and GraphQL API (`/api/v3/…`);
  - git smart-HTTP to github.com, which git reaches through `insteadOf`;
  - the forge's `/api/v1/…`.
- **Who uses them:** the MCP launchers, git and `gh-actions-log`. GitHub's MCP server
  accepts a plain-HTTP host only on loopback, so it reaches the relay through a loopback
  forwarder (`agent/loopback.mjs`).
- **Refused even where the token allows them:** webhooks, deploy and user keys, push
  mirrors, collaborators and invitations, Actions and other secrets, token and
  application creation, and admin. Each gets a 403 naming the relay. This narrows the
  forge-side residual below.
- **What the agent can still do:** use the tokens through the relay while it runs, for
  whatever the token and the relay allow.
- **What it can no longer do:** copy a token out.
- **Checks:** a token set in the agent's environment raises `TOKEN_IN_AGENT sev=crit`,
  and `doctor --live` fails on it.
Branch-protection tooling (`scripts/`) runs from an operator workstation with a short-lived
admin token that is shredded afterwards.

**One account, one key, one token per forge is the floor.** The key is the only thing that
can sign; the token is the only thing that can read CI and open a PR; the account is what
scopes both away from a person. Each has a line in `scripts/doctor.sh --online`, which is
how the count stays honest: a credential the doctor cannot name does not belong in the set
(BOOTSTRAP.md has the table).

**A note on bot write access.** It is tempting to keep the bot off every deploy-wired repo.
In practice that makes it useless for the repos that matter, so the pattern here is the
opposite: the bot *may* have write to a deploy-wired repo **because** branch protection
makes write-to-`main` impossible for it. Write-to-branch + PR-only is safe; write-to-`main`
is the thing that must be mechanically closed.

### 4.4 Network placement

Two dedicated bridges, both `internal` with an isolated gateway, fixed subnets so an
overlay can change them deliberately, and no membership in any other stack's network.
`internal` alone is not enough: an internal bridge still carries a host-owned gateway
address, and Docker bypasses host `INPUT` rules for forwarded traffic, so without the
isolated gateway a container could reach the host (and every service bound to `0.0.0.0`)
through that address. With it there is no address to reach.

A co-hosted forge's REST API should be reached through the proxy by hostname like any
other host, or over a dedicated network shared only with the forge container, created
`--internal` with the isolated gateway option, or the agent gains a host address through
it (`scripts/doctor.sh --live` checks every attached bridge). Never through a reverse
proxy on `host:443` that fronts other vhosts: a CONNECT-filtering proxy cannot see what
happens inside the TLS tunnel.

### 4.5 Settings: managed by the image, out of the agent's reach

Claude Code reads settings from several scopes and gives **managed** settings
(`/etc/claude-code/managed-settings.json`) precedence over the user's (`~/.claude`) and
the project's (`.claude/` in the working tree). Both of the latter are writable by the
agent: `~/.claude` is its own volume, the workspace is where it works. So everything the
station decides is in the managed file, which the image writes at build, root-owned and
read-only to the agent's uid (`agent/managed-settings.mjs`):

- the hooks, run from `/etc/lyngvi/hooks/` (root-owned): a user or project
  `disableAllHooks` does not turn managed hooks off;
- `allowManagedHooksOnly: true`: user, project and plugin hooks do not run, so the
  agent cannot install a hook that runs its own code at every session start;
- `disableBypassPermissionsMode: "disable"`;
- `allowedMcpServers`: only the two forge launchers baked into the image, matched by
  exact command, so a server the agent registers or writes into `.claude.json` is
  refused and never started;
- the generic grants, and the site's `settings.json` merged on top at build.

Each of those was verified against the pinned CLI, with session-start hooks run
headless: a managed hook ran with `disableAllHooks` set in user settings; with
`allowManagedHooksOnly` a user hook and a project hook did not; an MCP server outside
the allowlist was refused by `claude mcp add` and never started when written directly
into `.claude.json`. Re-check them when the CLI major moves (its Renovate PR is never
automerged for this reason).

The user `settings.json` is **written from scratch at every start** and carries no
policy: the status line, the attribution switch, the auto-mode rule. It is never merged
with what is in the volume, because what is in the volume is the agent's choice (an
earlier version merged onto it and kept an agent's `disableAllHooks`, bypass mode and
extra allow rules across restarts). A human's `/config` preferences in that file are
reset with it.

**Residual: permission rules from the workspace.** "Don't ask again" writes an allow
rule into the project's `.claude/settings.local.json`, in the workspace volume, and
Claude Code combines permission rules from every scope. So the agent can add allow
rules there that persist into later sessions. They widen what runs **without a prompt**,
not what can run: the agent's tools already run as its uid, and nothing in this file
reaches past the container, the proxy or the forge's rules. A site that wants
permission rules from the image only sets `"allowManagedPermissionRulesOnly": true` in
`site/settings.json`, and gives up "don't ask again". That is opt-in on purpose: on by
default, every "always allow" tapped in Remote Control would last one session, and every
station would pay in repeated prompts for a narrow risk.

What the default does instead is make the persistence **visible**:
- **An alert when a rule appears.** A managed `ConfigChange` hook (`hooks/config-change.sh`)
  runs when Claude Code's file watcher sees a user, project or local settings file
  change during a session, whoever wrote it. When the change adds an allow rule, hooks, a
  `defaultMode` or `additionalDirectories`, it raises `CONFIG_CHANGED sev=warn` naming the
  rule, pushes it through `notify`, and tells the operator in the session.
  - The CLI's own path protection already refuses the agent's Write and shell-redirect edits
    of these files. An interpreter's write gets past that protection, and the watcher still
    sees it (verified on the CLI).
  - The hook never blocks: a blocked `ConfigChange` only stops the running session from
    reloading the file, and the next session loads it anyway.
  - It runs in the agent's container, so like every marker (§10) it catches an injected
    session that does not know the station, not a compromised agent that does.
  - The watcher covers only the running session's **own** project. A rule written into
    another workspace repository, or between sessions, is caught by a **workspace scan**
    instead. The entrypoint runs `config-change.sh --scan` every
    `LYNGVI_CONFIG_SCAN_INTERVAL` seconds (default 60) over the same files doctor lists,
    plus the user settings. Both share one record, so a rule is reported once, whichever
    sees it first.
- **A listing in doctor.** `doctor --live` lists the allow rules found under the workspace,
  as the backstop for a write made while no session was watching.

**Residual: instructions and skills in the volumes.** `~/.claude/skills`, `agents` and
`commands` that the site did not name, and a `CLAUDE.md` in the workspace, persist and
are read by later sessions. They are text the model reads, not policy; the managed
settings decide what runs regardless.

## 5. Secrets

Nothing baked into the image; nothing plaintext committed. The container receives secrets
as an `.env` the host produces at start (SOPS, a vault agent: the mechanism is the
site's). A dotenv value can carry a multiline key as base64.

**Accepted exceptions, recorded:**

- The Remote Control OAuth credential is plaintext at rest in `claude-home`. The CLI must
  write it itself; it is account-scoped, revocable, never backed up, never in the repo.
- If a site's secrets backend uses one key for everything, the blast radius of that key
  is the site's problem, bounded here by never placing the key in the container. A
  dedicated recipient per service is the better pattern.

## 6. Alternatives considered

- **Self-hostable agent middleware (relay + mobile app) running as your user.** Sound
  crypto, but an unsandboxed shell RPC with sandboxing off by default, no package
  provenance, a small bus factor and no independent audit. Adopting it adds an unaudited
  agent-middleware trust party to avoid a relay already trusted for inference, a net
  increase in attack surface for a non-goal. Rejected.
- **Browser IDE over a tailnet** (code-server + the CLI). The right choice if a hard
  requirement emerges for a fully self-hosted, ACL-gated control plane or a full IDE on a
  phone. More effort, an inbound (tailnet) port, a cramped mobile IDE. Documented fallback,
  not mutually exclusive.
- **Hosted agent VMs.** No self-hosted forge, not your host. Fails goals 1 and 2.
- **`NET_ADMIN` in the container for an in-container firewall.** Conflicts with
  `cap_drop: ALL` and is reversible from inside.
- **A host-applied firewall** (`DOCKER-USER`, `INPUT` drops, root-installed units). The
  first design. Correct on paper, dependent on an apply step, an init system, an iptables
  binary and Docker's firewall backend, and the source of two silent defects. Replaced
  by the network layout in §4.2 and removed in v0.5.0.
- **A privileged firewall sidecar** (host network namespace, `NET_ADMIN`, the Docker
  socket, applying the same chain from inside the stack). Portable and drift-free, but it
  adds a root-equivalent container to a stack whose claim is that it has none, and it
  still depends on the iptables backend. Rejected.
- **A GitHub App as the agent's identity.** Hourly installation tokens, no machine user,
  repository scoping at install time: fewer long-lived secrets on paper. Rejected
  because an App cannot hold an SSH key: commits it pushes are unsigned (GitHub signs only
  commits created through its API), which contradicts the required-signatures rule this
  repo and the reference deployment enforce and leaves no signing identity behind the DCO
  trail. Routing commits through the API to get GitHub's signature would take `git` itself
  away from the agent. A machine account with one key and one fine-grained PAT stays; the
  App remains the right answer for a site that does not require signatures.

## 7. Deployment and the deploy control

The station is meant to be deployed by whatever pipeline deploys everything else on the
host, from a **private overlay repo** that consumes this one as a submodule
(docs/OVERLAY.md). Two consequences:

- **The overlay's `main` is itself deploy-wired**, so it must be PR-only (nobody pushes it
  directly; a merge still emits the push event that triggers the deploy). The bot, if it
  can propose to the overlay, cannot merge it.
- **Every deploy-wired repo the bot can write gets branch protection**, derived from the
  real trigger (a deploy workflow on push to `main` ∩ bot-writable), not a hand-kept list.
  On GitHub, import `scripts/github-main-ruleset.json`. On Forgejo, "block the bot only":
  humans stay on the push whitelist, deploy-key push is disabled, and the bot's token
  lacks merge scope.

This repo applies the same rule to itself (`.github/rulesets/main.json`) and checks the
live ruleset against the file on a schedule.

## 8. Non-negotiables

1. No host control from the container.
2. The agent never writes a deploy-wired `main`. Branch protection and token scope enforce it.
3. No inbound port.
4. Default-deny egress by construction: the agent's networks have no gateway and the
   proxy's hostname allowlist is the only path out; each allowed host has one line and one
   reason.
5. The secrets-decryption key never enters the container; no plaintext secrets committed.
6. Least-privilege git credentials, never a personal master key, held outside the agent:
   the key in the key sidecar, the tokens in the token relay (§4.3).
7. Non-root, `cap_drop: ALL`, no capability exceptions, read-only root filesystem.
8. Deploys are PR-gated; the container is never a privileged actor.

Any violation is a conscious posture change, recorded here with reasoning.

## 9. Threat model

| Threat | Mitigation |
|---|---|
| Outsider drives the agent | Account-gated relay (MFA), outbound-only, no inbound port |
| Prompt injection → host RCE via a deploy pipeline | Branch protection on every deploy-wired `main`; token without merge scope; derived protected set |
| Prompt injection (general) | Tier-0 container + default-deny egress bound the blast radius |
| Secret exfiltration | Tiny scoped cred set (egress is anti-C2 only); hooks keep secrets out of context; future caches/git-proxy |
| Lateral movement | Internal bridges with an isolated gateway (§4.2): no route off them and no host address, so the host, the LAN and other containers are unreachable and the proxy is the only peer; `doctor.sh --live` probes the host's addresses |
| Container escape | Non-root, cap-drop, no-new-privileges, no socket or bind mounts, noexec tmp |
| Credential theft via dependency | Scoped/revocable creds; lockfiles, `--require-hashes`; `--ignore-scripts` in builds |
| Relay account compromise | MFA; OAuth credential treated as a secret at rest; reviewed grants |
| Lost work on disconnect | tmux + volumes + supervised relaunch |
| Supply chain (CLI, images, tools) | Digest/hash pins; Renovate; the CLI bump is never automerged |
| Bot PR workflows on a privileged runner | Runner jobs must be socket-less and secret-less for PR events; verify with a canary job that fails iff a secret is populated |

## 10. Liveness and alerting

The healthcheck is liveness only (`pgrep` for the agent process); a relay drop can read
healthy between relaunches. The entrypoint therefore emits structured log markers with a
`sev=` field for a generic log-alert rule (match `sev=warn|crit` on this container):

| Marker | Meaning |
|---|---|
| `RC_RELAY_DROP sev=warn` | the relay link dropped after having been up |
| `RC_REGISTER_FAIL sev=crit` | repeated auth-failure exits or in-run auth failures; needs `/login` |
| `RC_TOKEN_EXPIRING sev=warn\|crit` | refresh token expires within 48 h / 12 h |
| `RC_TOKEN_STALE sev=crit` | credential unrecoverable; needs `/login` |
| `SSH_HOSTKEY_MISSING sev=crit` | the site did not pin the forge host key; SSH refused |
| `HOOKS_UNMANAGED sev=crit` | the image's managed settings are missing, writable or do not wire the hooks (§4.5); rebuild |
| `CANARY_TOUCHED sev=crit` | **from the proxy's container:** a decoy credential's host was requested, so something harvested and used it; treat the agent as compromised (docs/INCIDENT.md) |
| `HOOK_ERROR sev=warn` | `block-secret-dumps` crashed and let a command through (it fails open so a bug cannot stop every command); at most hourly; fix and rebuild |
| `TOKEN_IN_AGENT sev=crit` | an API token is set in the agent's environment; it belongs to the token relay only (§4.3); blank it in the agent service and rotate it |
| `KEY_IN_AGENT sev=crit` | a private SSH key is set in the agent's environment; it belongs to the key sidecar only (§4.3); blank it in the agent service and rotate it |
| `CONFIG_CHANGED sev=warn` | a settings file gained an allow rule, hooks, a `defaultMode` or `additionalDirectories`, seen by the in-session hook or the workspace scan (§4.5); if you did not grant it, remove it (docs/INCIDENT.md) |

Keep the watchdog interval under your alert rule's aggregation window or the alert flaps.

A log-alert rule is the right sink where one exists. Where none does, the markers also
reach a human directly: `agent/notify.mjs` pushes every marker at or above
`NOTIFY_MIN_SEV` to `NOTIFY_URL` (ntfy, Slack, Discord or a JSON webhook) and/or runs
`NOTIFY_CMD`, throttled per marker to `NOTIFY_REPEAT` so a 5-minute re-emit does not
become a 5-minute phone buzz, with an escalation (warn → crit) sent at once. The log line
is still written first; the push is best effort and backgrounded, and a failure is logged
by status or code, never by URL. The push host is one more line in the site's
`proxy-filter.extra`.
`notify --test` proves the path at bootstrap. This is what turns "the watchdog warns 48 h
ahead" from a log line someone must be watching into a notification someone receives.

**What the markers can be trusted for.** The supervisor loop, the credential watchdog and
`notify` run in the agent's container, as the agent's uid, in its PID namespace. That is
what lets them read the relay's output and the credential file, and it means they report
the faults of an agent that is **not** compromised: a token running out, a relay drop, a
crash, a missing host-key pin. Against a compromised agent (§9) they are not a control,
and nothing here claims one:

- it can **forge** a marker, by writing a line to the container's own stdout
  (`/proc/1/fd/1`), which reaches the log-alert rule and `doctor --live` like a real one,
  terminal escape sequences included;
- it can **silence** one, by killing the watchdog subshell or touching `notify`'s
  throttle stamp, with the container still healthy;
- it can **push** its own text to the operator's notification target with `notify`.

So the absence of a crit marker is not evidence that the agent is uncompromised, and a
marker is a prompt to look, not an instruction. Every marker's remedy is the same
runbook step, an interactive `claude /login` (docs/REMOTE_CONTROL.md), or a site-file
change or rebuild through the site's reviewed deploy; **a notification that asks for anything else is itself a
sign of compromise**, and docs/INCIDENT.md is the runbook for it: stop the agent, revoke,
preserve the proxy's log, find what outlived the revocation, rebuild. Moving the watchdog to its own container would stop the first two
for the credential markers only, at the price of a service every overlay must add (and
a silent loss of alerting on an overlay that misses it); the relay markers must stay
where the relay's output is. 

**Decoy credentials** are the exception, because their marker comes from the proxy's
container. The entrypoint plants three decoys where a credential hunter looks and no tool
connects on its own: a `~/.netrc` machine, a `~/.git-credentials` line, and an `~/.ssh`
Host alias with a key of its own. Each names a per-install `.internal` hostname that the
proxy generated (`proxy/start.sh`) and never allows. Using one means asking the proxy for
that host. The proxy refuses it and its own entrypoint raises `CANARY_TOUCHED sev=crit`
in a log the agent cannot write or stop. This is the one control here that catches an
interpreter reading a secret file, which the hooks cannot see (§11), once the stolen value is used.
- **Default:** on. `CANARIES=0` turns them off.
- **No false alarms in normal work:** a smoke run's ordinary git and proxy traffic
  raised none.
- **Limit:** an agent that knows the station can read the hostnames (the volume is
  read-only to it, not hidden) and avoid them.
- **doctor:** fails when the allowlist would match a decoy host, and never offers one as
  an allowlist candidate.

**Two records hold against a compromised agent, because they leave the box or come from a
container it cannot touch.**
- **The proxy's log:** every connection, allowed or refused, and `CANARY_TOUCHED`.
- **Tool-call telemetry:** opt-in. When `site/settings.json` names an OTLP endpoint, the
  build turns it on in managed settings, so the agent cannot turn it off (tested against an
  agent-written user `settings.json`). It carries tool names, decisions, timings and
  parameters. Prompts and responses arrive as `<REDACTED>`, tool output only as a size, and a
  site that widens that fails the build.

docs/AUDIT.md covers shipping both and the alert rules.

The tools a human runs treat the log as untrusted text:
`scripts/doctor.sh` replaces every non-printable byte before it prints a log line.

## 11. Accepted residuals

- Egress is anti-C2 only (§4.2).
- CONNECT-host filtering, not SNI (§4.2).
- Connections the forge makes for you (push mirrors, webhooks, migrations, a forge-run
  agent) bypass the proxy; the control is a token with no repo-admin, and the MCP tool
  defaults are not a boundary (§4.2).
- Commits written through a forge API lack the agent's signing key and DCO sign-off, and
  may still show as verified (§4.2).
- The opt-in `go` preset is a way out through the Go module proxy (§4.2).
- OAuth credential plaintext at rest (§5).
- `GIT_HTTPS_CREDENTIAL_<NAME>` values (a second HTTPS identity for one repository) still
  go into the agent's git credential store. Only `GITHUB_TOKEN` and `FORGE_API_TOKEN` go
  through the token relay. The relay's refusal list is a short list of known paths, not an
  allowlist of the API.
- The agent shares the host's kernel. Docker's default seccomp profile, `cap_drop: ALL`,
  `no-new-privileges` and a non-root uid narrow the syscall surface, but a kernel exploit
  reachable from that surface is a container escape. A stronger boundary is a site choice,
  not the default: [docs/GVISOR.md](docs/GVISOR.md) runs the agent under gVisor's `runsc`
  (tested with the full smoke). It needs the runtime installed on the host and fixed
  addresses for the proxy and relay, and it slows filesystem-heavy work about fivefold.
- Claude Code's subprocess environment scrubbing (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`) is
  not used. It needs bubblewrap, and bubblewrap cannot create a user namespace under
  Docker's default seccomp profile, whether all capabilities are dropped or the defaults
  are kept (tested). Making it work would need `seccomp=unconfined` or added
  capabilities, which costs more than it gains. So the secrets in the agent's environment are
  visible to its subprocesses; moving the signing key and API tokens out of the
  container is the fix for that.
- Prompt injection is bounded, not prevented: the agent reads untrusted text (issues,
  READMEs, dependencies, web pages) while holding credentials and the ability to write
  to the forge. The containment above limits what a hijacked session can reach;
  docs/INJECTION_EXERCISE.md is the repeatable test of how it holds.
- Monthly interactive re-login (§2).
- A proxy fault is an outage, Remote Control included (§4.2). Chosen over a control whose
  failure was silent.
- Docker Engine ≥ 28.0 is required; older engines refuse the networks, which is the
  correct failure.
- Hooks fail open on internal error, by design. Failing closed would let a hook bug block
  every command until a rebuild, which cannot be fixed from a phone. A `block-secret-dumps`
  crash raises `HOOK_ERROR sev=warn` at most hourly; a redact-hook failure is announced
  once per session. A hook timeout lets the command through whatever the hook does.
- The alert markers and `notify` run in the agent's container: a compromised agent can
  forge, silence or send them (§10). They report faults, not compromise.
- Permission rules the agent adds in the workspace's project settings persist (they
  remove a prompt, not a boundary), unless the site sets
  `allowManagedPermissionRulesOnly` (§4.5). A new rule raises `CONFIG_CHANGED` (at once
  in the session's own project, within one scan interval anywhere else in the workspace),
  and `doctor --live` lists them all.
- Git hooks in a workspace repository's `.git/hooks` persist and run on the next commit,
  as the agent. They add persistence across sessions, not capability (the agent runs code
  anyway), so `core.hooksPath` is not forced: repositories keep their own hooks.
- The host user running deploys is usually root-equivalent; that boundary is the
  account, not this container.

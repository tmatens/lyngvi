# Changelog

What changed in each release, for the people running a station. Every release is a signed
`vX.Y.Z` tag; a GitHub release carries the same notes. Releases up to v0.14.0 were made
before this repository was published, so their tags are not in it. **Breaking** marks a change a site
must act on before or while upgrading. Releases follow semantic versioning loosely while the
version is 0.x: a minor bump can break, and says how.

## Unreleased

## v0.15.0 (2026-11-13)

- **Breaking: the leak check no longer reads a hash list.** `scripts/check-site-leaks.py`
  compared tokens with salted SHA-256 hashes in `leakcheck/denylist.sha256`, so that
  upstream CI could refuse a site's private strings without holding them. A short token,
  such as an address or a host name, is recovered from such a hash by guessing, and the
  salt has to be public for CI to use it.
  - `leakcheck/denylist.sha256`, `leakcheck/salt` and the `--hash-list` and `--salt`
    options are gone. Upstream CI runs the generic rules only.
  - An overlay checks its own plaintext list with `--plaintext`, as the template's
    `validate` workflow already does.
  - **Site action:** stop generating hashes, and do not publish any you generated.

- **A session is told when its installed skills are behind their source.** Skills are
  installed from `SKILLS_REPO` once, when the container starts, so a fix merged in that
  repo was invisible until the next restart and nothing said so. A session followed a
  skill step that had been corrected in the source days earlier.
  - The entrypoint records the commit it installed from in `~/.claude/skills/.source-sha`.
  - The `skills-summary.sh` SessionStart hook compares it with the source's head (one
    `git ls-remote`, 5 s limit) and, when they differ, warns the person and tells the agent
    to read the skill from a fresh clone. It stays silent when the check cannot run.
  - Nothing is reinstalled mid-session: a restart is still what updates the files.
  - No site action. The marker appears at the first start on this version.

## v0.14.0 (2026-11-07)

- **Breaking: the site identity is enforced.** A station once committed for days under
  an identity left in its `.env`: compose loads `.env` after `site.conf`, so the old value
  won without a word, and a forge's squash merge published it as a co-author.
  - The image's git hooks refuse a commit whose author, committer or `Signed-off-by` is not
    a site identity: `site.conf`'s `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`, or a `user.*` in a
    `site/gitconfig*` fragment. They read the files baked into the image, never the
    environment. The hooks are now always on; `GIT_DCO_SIGNOFF=0` only turns off the trailer.
  - The entrypoint takes the identity from the baked `site.conf`, unsets
    `GIT_AUTHOR_*`/`GIT_COMMITTER_*` for Remote Control sessions, and raises
    `SITE_CONF_OVERRIDDEN sev=warn` (key names only) for any `site.conf` key the environment
    overrides.
  - `doctor` fails on a key set in both `site.conf` and `.env`; `doctor --live` fails when the
    identity is overridden.
  - `GIT_NO_AI_ATTRIBUTION=1` now sets `"attribution": false` (the deprecated
    `includeCoAuthoredBy` covered the co-author trailer only), and `commit-msg` refuses AI
    attribution lines.
  - `scripts/check-attribution.py` also fails a commit whose author, committer or sign-off
    names the assistant.
  - **Site action:** remove `GIT_AUTHOR_*`, and any other `site.conf` key, from `.env`.
    Run `scripts/doctor.sh` to list them.
## v0.13.1 (2026-11-07)

- **A default `TMPDIR` on the workspace volume** (`~/workspace/.tmp`). `/tmp` and the home
  tmpfs are both `noexec`, and the home tmpfs is 64 MB, so tools that exec out of their temp
  dir (pytest fixtures, venv console scripts) failed, and pointing `TMPDIR` under `$HOME`
  filled it mid-test-suite. The entrypoint empties the directory at every start. The CLI's
  own temp files stay on `/tmp` (`CLAUDE_CODE_TMPDIR`). `agent/CLAUDE.md` now says where temp
  files go and where they must not. No site action needed.
- **docs/GVISOR.md: a same-host benchmark.** A runc station and a runsc station ran one task
  list back to back on the same host.
  - Filesystem metadata is 5–11× slower under runsc, and a git commit takes about 150 ms
    instead of 35 ms.
  - Real work is 1.2–2× slower: tests, builds, package installs and clones.
  - The agent peaks about 400 MB higher.
  - This replaces the earlier three-row microbenchmark.

## v0.13.0 (2026-11-05)

- **gVisor as an opt-in kernel boundary** (`docs/GVISOR.md`,
  `examples/gvisor/compose.gvisor.yml`). With the override, the agent runs under `runsc`
  while the sidecars stay on runc. The full smoke passes, as does `doctor --live`.
  - **Host:** install runsc and register it with `runtimeArgs: ["--host-uds=open"]`, so
    the agent can reach the key sidecar's socket.
  - **Compose:** the proxy and relay get fixed addresses, because Docker's container-name
    DNS does not work under gVisor.
  - **Cost:** filesystem-heavy work runs about five times slower (measured).
  - `doctor --live` now reports the agent's runtime. The default is unchanged.

## v0.12.1 (2026-11-05)

- **api-key mode: attach lands at the prompt.** The entrypoint now also completes Claude
  Code's first-run welcome and theme screens (a theme already chosen is kept), so the
  first `tmux attach` no longer opens on them. The workspace-trust prompt is still asked
  once, as in remote-control mode.
- **docs/API_KEY_MODE.md: what pays for it.** A real-key trial found that promotional
  Console credits do not cover Claude Code requests; only purchased credit does. For
  someone with a Claude subscription, remote-control stays the economical mode. Also
  measured: a new session's first call costs about $0.19 on Opus, mostly cache writes.

## v0.12.0 (2026-11-05)

- **A workspace settings scan** (tmatens/lyngvi#78). The CLI's `ConfigChange` watcher covers
  only the running session's own project, so the injection exercise's python write of an
  allow rule into another workspace repository raised nothing. The entrypoint now runs
  `config-change.sh --scan` every `LYNGVI_CONFIG_SCAN_INTERVAL` seconds (default 60; `0`
  turns it off), in both modes. It walks the workspace like `doctor --live` and adds the
  user settings. It raises the same `CONFIG_CHANGED sev=warn`, marked `(workspace scan)`,
  from the same record as the hook, so each rule is reported once.
  - **On upgrade:** a rule already in a workspace repository is reported once, the first
    time the scan sees it. It is new to the station's record. Check it and remove it if
    you did not grant it.
- **`LYNGVI_MODE=api-key`** (`docs/API_KEY_MODE.md`) runs a station on an Anthropic API key
  instead of the claude.ai login.
  - **The key:** the token relay holds it (`LYNGVI_ANTHROPIC_API_KEY`) and adds it on a new
    `:8084` route, which passes only `/v1/messages` and `/v1/models`. The agent sends a
    placeholder, written with `ANTHROPIC_BASE_URL` into the user `settings.json` `env`, so
    every session uses it, and pre-approved. The agent therefore holds no model credential.
  - **What it changes:** no monthly `/login`, no refresh race. There is no Remote Control
    (the CLI allows it only with a subscription login). Claude Code runs in a supervised
    tmux session, `claude`, reached through `docker exec … tmux attach -t claude`.
  - **Checks:** a real key in the agent's environment raises `TOKEN_IN_AGENT`. The
    healthcheck and `doctor --live` understand the mode.
  - **Default:** `remote-control`, unchanged.

## v0.11.0 (2026-11-05)

- **Breaking (security): the API tokens moved out of the agent's container.** A new token
  relay, `lyngvi-relay` (`relay/`, Caddy pinned by digest), holds `GITHUB_TOKEN` and
  `FORGE_API_TOKEN`, and the agent's service blanks both.
  - **How the agent reaches it:** plain HTTP. The relay adds the token and calls the
    API through the proxy.
  - **Clients:** GitHub's MCP server (through a loopback forwarder, since it takes plain
    HTTP only on loopback), forgejo-mcp, git over HTTPS to github.com (`insteadOf`) and
    `gh-actions-log`.
  - **Refused even where the token allows them:** webhooks, deploy and user keys, push
    mirrors, collaborators, secrets, token creation and admin.
  - **Checks:** a token left in the agent's environment raises `TOKEN_IN_AGENT sev=crit`.
    `doctor --live` fails on it, checks that the relay is on the proxy's network only,
    and reports its routes. doctor and `refused-hosts.sh` now find the proxy by its
    `lyngvi-proxy` name, not as "the other container on the network". The decoy-versus-
    allowlist check ignores blank lines and comments.
  - **Overlays:** add the `lyngvi-relay` service, as the template now does.
  - **Not covered:** `GIT_HTTPS_CREDENTIAL_<NAME>` values still go into the agent's git
    credential store.

- `scripts/injection-exercise/` is a kit for `docs/INJECTION_EXERCISE.md`: the eight
  scenarios in three phrasings each, a script that plants them in a scratch repository and
  files the issues, the ordinary tasks to give the agent, and a script that gathers the
  evidence afterwards (proxy refusals, decoy use, markers, left-behind rules and git
  hooks, and the scratch repository's webhooks, keys, collaborators and commits). Every
  payload is harmless if obeyed.

- `scripts/recreate-safe.sh` says whether recreating the agent container now would risk
  the claude.ai login. The single-use refresh token can be consumed around a restart if
  the access token is near expiry, and only `/login` recovers from that. It reads the
  credential's expiry timestamp only and exits 0 (safe) or 1 (risky), so a deploy can gate
  on it. `doctor --live` reports the same. On a live station the access token lasted about
  8 hours after a login. docs/REMOTE_CONTROL.md explains when to recreate.

- Sessions started with `docker exec` now see the token relay and the key sidecar.
  `LYNGVI_RELAY_*` and `SSH_AUTH_SOCK` are image environment, not entrypoint exports. The
  operating context says the blank `GITHUB_TOKEN` and `FORGE_API_TOKEN` are deliberate. Found
  by the first injection exercise.
- **The first prompt-injection exercise has run** (`docs/INJECTION_EXERCISE.md`).
  - **Model:** across three phrasings, it acted on none of the 24 planted payloads.
  - **Control layer** (each action asked for explicitly):
    - the block hook stopped the environment and key dumps;
    - the proxy refused the decoy's use and raised `CANARY_TOUCHED`;
    - managed settings outranked an agent-written `disableAllHooks`;
    - the relay refused webhooks, deploy keys and collaborators;
    - the proxy refused the unlisted host.
  - **Open:** a workspace rule written into another repository raised no
    `CONFIG_CHANGED`, which is tracked. v0.10.0's pending exercise is closed by this run.
- The README's architecture, capability table and non-negotiables describe the key
  sidecar, the token relay and the read-only root.

## v0.10.0 (2026-11-05)

The release steps call for the prompt-injection exercise (`docs/INJECTION_EXERCISE.md`)
before a release that changes the hooks or the managed policy, and this one does. Its first
run is **pending**: the release went out without it, as a stated exception, because every
change here adds a control and none removes one. The run is the next task, and its results
are recorded in that doc.

- **Breaking (security): the SSH key moved out of the agent's container.** A new key sidecar, `lyngvi-keys`
  (`keys/`), holds the keys in an ssh-agent.
  - **The sidecar:** no network (`network_mode: none`), read-only, the agent's uid. It
    serves only the socket and the public keys, on a `keys` volume the agent mounts
    read-only.
  - **The agent:** its service blanks `GIT_SSH_KEY_B64`, so the private key is no longer in
    its environment or anywhere on its disk. It signs and pushes through the socket, so a
    compromised agent can use the key while it runs but cannot copy it out.
  - **Checks:** a private key left in the agent's environment raises
    `KEY_IN_AGENT sev=crit`, and `doctor --live` fails on it and on a key sidecar that has
    a network.
  - **Overlays:** add the `lyngvi-keys` service and the `keys` volume, as the template now
    does. A site with extra `SSH_KEY_<NAME>_B64` keys blanks each in the agent service and
    points its gitconfig at `~/.ssh/<name>.pub`.
  - The API tokens are the next step.

- **Breaking: the agent's root filesystem is read-only.** Its writable state is now four places:
  - the `/tmp` and home-directory tmpfs mounts, both `noexec`, rebuilt at every start;
  - the `workspace` and `.claude` volumes;
  - a new `cache` volume for build caches. `GOPATH` and npm's cache moved under
    `~/.cache`, and uv, pip and Go's build cache were already there.
  
  Anything written elsewhere in the home directory is gone after a restart. The DCO hook
  moved into the image (`/etc/lyngvi/git-hooks/`, root-owned), so the agent cannot edit
  it. `doctor --live` warns if an overlay turns `read_only` off. An overlay declares
  `cache` with its other volumes, as the template now does.

- **Breaking: decoy credentials, on by default.** The agent's home now holds three decoys: a
  `~/.netrc` machine, a `~/.git-credentials` line, and an `~/.ssh` Host alias with its own
  key. Each names a per-install hostname that the proxy generates and never allows. Using
  one is refused at the proxy, and the proxy's entrypoint (`proxy/start.sh`) raises
  `CANARY_TOUCHED sev=crit` in its own log, which the agent cannot write or stop. That
  catches a harvested secret being used, which the hooks cannot see.
  - `doctor --live` reports the decoys, fails on a touch or on an allowlist line that
    matches a decoy host, and, like `refused-hosts.sh`, never offers a decoy host for the
    allowlist.
  - `CANARIES=0` in `site.conf` turns them off.
  - The hostnames live in a new `canary` volume, read-write in the proxy and read-only in
    the agent. An overlay declares it with its other volumes, as the template now does.

- **An audit trail outside the agent's reach** (`docs/AUDIT.md`).
  - **Proxy log:** how to ship it (Alloy and Vector examples), plus alert rules for
    `CANARY_TOUCHED`, refusal bursts and markers.
  - **Tool-call telemetry, opt-in:** an OTLP endpoint in `site/settings.json` `env` turns
    Claude Code's telemetry on in managed settings, where an agent-written user setting
    cannot turn it off (tested). It carries tool names, decisions, timings and the
    parameters, meaning the command text. Prompts and responses arrive as `<REDACTED>` and
    tool output only as a size. A site that enables tool content, prompts, responses or raw
    API bodies fails the build.
  - `doctor --live` reports telemetry on or off, and warns when the proxy refuses the
    collector.

- **A new workspace permission rule raises an alert.** Allow rules the agent writes into a
  workspace's `.claude/settings*.json` persist into later sessions, and nothing said so.
  A managed `ConfigChange` hook now raises `CONFIG_CHANGED sev=warn`. It fires when a
  settings file gains an allow rule, hooks, a `defaultMode` or `additionalDirectories`
  during a session, and it names the rule. The marker goes to the log-alert rule and
  `notify`, and to the session as a message. The CLI already refuses the agent's own
  edits of these files, but not an interpreter's, and the hook covers that case.
  `doctor --live` lists the workspace's allow rules. Blocking them stays opt-in
  (`allowManagedPermissionRulesOnly`). Git hooks in workspace repositories are
  recorded as an accepted residual.

- A crash in `block-secret-dumps` is now reported. The hook still fails open, so a bug
  cannot block every command until a rebuild, but it now raises `HOOK_ERROR sev=warn`
  in the container log and through `notify`, at most once an hour. The marker names the
  exception type, never the command. Before, a crash let commands through with nothing
  to show for it.

- `block-secret-dumps` no longer mistakes a later `config` for a compose render. The rule
  matched `config` anywhere after `docker compose`: across `;`, `&&` or `|`, and inside a
  path such as `~/.ssh/config`. So reading `docker-compose.yml` and `~/.ssh/config` in one
  command was blocked. `config` must now be a word of the same command, not part of a path
  or file name.

- `docs/INCIDENT.md` is the runbook for a station whose agent may be compromised. It
  covers stopping the agent while keeping the proxy and its log, revoking every
  credential it held, and preserving the logs and volumes. It then covers finding what
  outlived the revocation on the forge (webhooks, keys, mirrors, collaborators), reading
  the proxy log, and rebuilding without the old volumes. DESIGN.md §10, SECURITY.md and
  the README link to it.

- `docs/INJECTION_EXERCISE.md` is a repeatable prompt-injection exercise against a
  throwaway stack. It has eight scenarios: exfiltration, decoy use, settings persistence,
  bypass, egress, forge overreach, self-merge and git-hook persistence. Each lists the
  controls expected to hold and what counts as a failure, plus a results table. It runs by
  hand before a release that touches the policy, the hooks, the egress layout or the CLI.
  DESIGN.md §11 also records three residuals: the shared kernel, with gVisor or a microVM
  as a site choice; Claude Code's subprocess env scrubbing, which needs bubblewrap and
  cannot run under Docker's default seccomp profile (tested); and that prompt injection
  is bounded, not prevented.

## v0.9.0 (2026-11-04)

- **Breaking (security):** the agent could widen its own settings, and the change survived restarts
  and recreates. The entrypoint merged its grants onto the `settings.json` already in the
  `claude-home` volume, so an agent-written `disableAllHooks`, bypass mode, extra allow
  rule or extra hook was kept, and a neutered hook still counted as wired. The policy now
  lives in Claude Code **managed settings** baked into the image
  (`/etc/claude-code/managed-settings.json`, root-owned): the three hooks (run from
  `/etc/lyngvi/hooks/`), `allowManagedHooksOnly`, no bypass mode, an MCP allowlist of the
  baked forge launchers, and the grants. The user `settings.json` is rewritten from
  scratch at every start. `scripts/doctor.sh --live` checks the managed file and each
  hook command, and the smoke proves an agent-written `settings.json` does not survive a
  restart. **Action for sites:** `site/settings.json` now goes into the managed settings
  at build, so its grants can no longer be overridden at runtime. A site that registers
  its own MCP server adds the launcher to `allowedMcpServers` there. A human's `/config`
  preferences in `~/.claude/settings.json` are reset at each start.

- **Breaking (security):** a compromised agent could plant an allowlist line that allows every
  host. The proxy logs whatever host a client asks for, and `scripts/refused-hosts.sh`
  turned a request for `registry-x|[a-z0-9-]+` into the suggested line
  `^registry-x|[a-z0-9-]+$`. That line is an alternation whose right half matches nearly
  any name, and `scripts/doctor.sh` accepted it because it starts with `^` and ends with
  `$`. Every filter line must now fit a hostname grammar (`proxy/check-filter.sh`: hostname
  characters, `\.`, and `[a-z0-9.-]+` under at least two literal labels), enforced by the
  proxy build and by `doctor.sh` as a FAIL. `refused-hosts.sh` and `doctor --live` offer
  only plain hostnames and report anything else as escaped text, which also stops
  terminal escape sequences in a refused name from reaching the operator's screen.
  **Action for sites:** a `site/proxy-filter.extra` line outside the grammar now fails the
  proxy build; `scripts/doctor.sh` names it.

- **Security:** the secret-hygiene hooks missed the station's own secrets. The block
  hook did not recognise the SSH key (loaded as `~/.ssh/git_key`, not `id_*`), the OAuth
  credential (`~/.claude/.credentials.json`), `~/.git-credentials` or
  `/proc/*/environ`, and blocked only `cat` of a `.env`, so `cat ~/.ssh/git_key`,
  `export -p`, `declare -x` and a bare `set` all went through. The redact hook passed
  the Claude OAuth tokens (`sk-ant-oat01-`/`sk-ant-ort01-`), the base64 key in
  `GIT_SSH_KEY_B64` and a bare 40-hex forge token. Now: any file under `~/.ssh` other
  than config, known_hosts and `.pub` is a key, the credential files and `environ` are
  secret paths for Read, Grep content mode and every shell renderer, and the env dumps
  are blocked. The redact hook replaces the host's **own secret values** wherever they
  appear (every env var named like a secret, the OAuth tokens from the credential file),
  which needs no pattern and works without gitleaks, and adds gitleaks rules for the
  OAuth token formats and base64-wrapped PEM keys. The hook matcher now includes `Grep`.

- `scripts/doctor.sh --live` probed the wrong address for "the agent cannot reach the
  host". It took the first address of the agent's bridge, but an isolated bridge gives
  that address to a container, so the check reached a peer and passed whatever the
  layout was. It also counted a refused connection as blocked, though a refusal means
  something answered. It now probes the host's real addresses (the default route's
  source and the default bridge's gateway), and a refused connection counts as
  reachable.

- DESIGN.md §10 states what the alert markers can be trusted for. They report the
  faults of an agent that is not compromised. A compromised agent shares their uid and
  PID namespace, so it can forge a marker in the container log, silence the credential
  watchdog, or push its own text through `notify`. A notification asking for anything
  beyond the documented runbook is a sign of compromise. A watchdog sidecar was
  considered and not taken: it would cover only the credential markers, and an overlay
  that missed the new service would lose its alerting silently. `scripts/doctor.sh` now
  replaces non-printable bytes in log lines before printing them, so a forged marker
  cannot carry terminal escapes to the operator. `HOOKS_UNMANAGED` joins the marker
  table.

- DESIGN.md records three residuals that the forge adapters made concrete: connections the
  forge makes itself (mirrors, webhooks, migrations, a forge-run agent) bypass the proxy,
  so the control is a token without repo-admin and the MCP tool defaults are not a
  boundary; commits written through a forge API lack the agent's key and sign-off; and the opt-in `go` preset is a way out through the Go module proxy. BOOTSTRAP's
  GitHub token step names the permissions to leave off.

## v0.8.0 (2026-11-04)

- **Action for sites with `WITH_GO: "1"`:** add `PROXY_PRESETS: "go"` to the proxy's
  build args. Until now no Go module could be downloaded through the proxy, because the
  Go module proxy and checksum database were not allowlisted anywhere. They are an opt-in
  preset rather than base entries: the Go module proxy fetches any public module path
  from its origin on request, which is a way out that the base list does not have.
  `scripts/doctor.sh` warns when `WITH_GO` and the preset disagree, and CI proves a real
  download through the proxy with the agent image's own Go.
- GitHub's own MCP server (`github/github-mcp-server`, pinned by digest) is baked with
  `WITH_GITHUB_MCP: "1"` (on in the upstream compose and the overlay template) and
  registered whenever `GITHUB_TOKEN` is set, whatever `FORGE_KIND` is. lyngvi's defaults
  leave out the `copilot` toolset, which runs GitHub's own agent outside the egress proxy,
  and the tools that write commits through the API, which skip the agent's signing key
  and DCO hook. `GITHUB_TOOLSETS` / `GITHUB_EXCLUDE_TOOLS` in `site.conf` change that.
  An overlay that `extends` the upstream service inherits the build arg, so a site with a
  `GITHUB_TOKEN` gets the server on its next build.
- The agent's operating context (`agent/CLAUDE.md`) states the current limits. It drops
  the stale DNS and host-unit lines and says which forge tools are off and why, which
  includes not getting their effect with a raw API call. It also says what to tell the
  human when the proxy refuses a host (the anchored line, or the go preset) instead of
  routing around it, and lists what only a human can do.
- `docs/REMOTE_CONTROL.md`: a runbook for a signed-out station. It says what each `RC_*`
  marker means and how urgent it is, how to log in from another machine, how to confirm
  the login worked, and what keeps it from happening again. BOOTSTRAP links to it.
- `scripts/refused-hosts.sh` prints what the proxy refused as allowlist lines for review,
  and names the preset when one covers the host. `doctor --live` points at it.

## v0.7.0 (2026-11-04)

- **Breaking for sites that use forgejo-mcp's admin or repo-settings tools:** both areas are
  now off by default. repo-settings creates push mirrors, webhooks and migrations, which
  the forge connects out for itself, so they bypass the egress proxy. A site that needs
  them sets `FORGEJO_DISABLED_AREAS` in `site/site.conf` (empty = every area on), and
  should do that only with a token that lacks repo-admin rights. The token's scopes stay
  the real control.
- forgejo-mcp 0.1.7 → 0.3.1. It fixes a dot-segment path escape that could reach an
  endpoint outside a tool's own (including a switched-off area) and an error path that
  could quote the token into tool output, and grows from 103 to 457 tools.

## v0.6.0 (2026-11-04)

- **Breaking for overlays that rename the proxy service:** the agent now starts only once
  the proxy is healthy (`depends_on`), and `extends` carries that dependency. An overlay
  that keeps upstream's service names needs nothing; one that renames the proxy adds
  `depends_on: !override` naming its own (docs/OVERLAY.md). Compose 2.20 is now the
  minimum (the proxy healthcheck's `start_interval`).
- The entrypoint waits up to `PROXY_WAIT` (60s) for the proxy before its first network use,
  since the daemon ignores `depends_on` after a reboot; `PROXY_UNREACHABLE sev=warn` if it
  never answers.
- `DISABLE_AUTOUPDATER=1` in the image: the CLI version is pinned by the image and no longer
  tries to update itself (its update check was refused by the proxy on every start).
- `doctor --live` reads start-up facts from a per-run status file the entrypoint writes
  (`/tmp/lyngvi-status`) instead of the log, and lists the hosts the proxy refused in the
  last 24 hours.
- CI tests an in-place upgrade from the previous release (the login volume must survive);
  a `portability` workflow runs the whole stack on a rootless engine (Docker's
  dind-rootless image) and builds and runs both images for arm64. Podman is untested.
- This changelog, and GitHub releases for every tag.

## v0.5.0 (2026-11-03)

- **Breaking:** the deprecated host firewall path is removed. `host/` keeps only
  `uninstall.sh`, which clears a pre-v0.5 install from a host without stopping the agent
  (CI proves it against v0.4.0's own installer). The doctor warns while leftovers exist and
  treats any reachable non-proxy probe as a failure.
- `doctor --live` reads start-up facts from the container's own start instead of a fixed log
  tail, which a Remote Control login could overrun and turn into false failures.

## v0.4.0 (2026-11-03)

- **Breaking for a site still on the host firewall path:** the agent is
  `restart: unless-stopped`. Run `host/install.sh --uninstall` (v0.3.2) first, or the daemon
  would restart the agent before the host unit re-applies the firewall. On the egress layout
  the policy carries no egress risk; CI proves the agent comes back after a daemon restart.

## v0.3.2 (2026-11-03)

- `host/install.sh --uninstall` removes the host firewall side (units, drop-in, root-owned
  copies, chain, jump, INPUT drops) without stopping the agent, reading the subnets from the
  installed `firewall.conf`; idempotent. The migration path off the host firewall.

## v0.3.1 (2026-11-03)

- The site-leak check no longer fails on the `(#N)` suffix a squash merge repeats in its body
  bullets, so a release's own CI and an overlay's check over the pinned tree pass. No runtime
  change.

## v0.3.0 (2026-11-03)

- **Breaking:** egress is default-deny by network layout. The agent's networks are `internal`
  with an isolated gateway (Docker Engine 28 or later), and the hostname-allowlist proxy is its
  only path; every client (Node, git, ssh through `agent/connect.mjs`) goes through it. An
  overlay declares its agent networks the same way, and allowlists its forge (and a non-22
  forge port) in `site/`. Nothing is applied on the host; the host firewall path is deprecated.
- `doctor --live` and the smoke test verify the layout; CI checks it survives a daemon restart.

## v0.2.2 (2026-11-02)

- Host units: the installer applies the firewall without restarting the firewall unit (a
  restart propagated through the agent unit and bounced the container), and the daily timer
  triggers a plain refresh unit (the previous target never re-ran). Re-run the installer.
- v0.2.1 was tagged before this change landed and carries only the doctor fixes, despite its
  message. Use v0.2.2.

## v0.2.1 (2026-11-02)

- Doctor: honours the pre-split `.env` names, runs the forge API probes inside the container,
  uses POST for the merge-scope probe, `--gh-repo` for GitHub repos, `LYNGVI_UPSTREAM` for
  piped runs.

## v0.2.0 (2026-11-02)

- Setup ergonomics: `scripts/doctor.sh` (static, `--online`, host and `--live` checks, never a
  secret value), the host installer with `--check` drift, `agent/notify.mjs` behind every
  watchdog marker (ntfy, Slack, Discord, JSON webhook, or a site command; `notify --test`),
  `scripts/new-overlay.sh` with a CI-validated overlay template, and the credential inventory
  in BOOTSTRAP.md.
- Site inputs: five optional `NOTIFY_*` keys in `site.conf`, `NOTIFY_URL`/`NOTIFY_TOKEN` in
  `.env`.

## v0.1.1 (2026-11-02)

- The smoke test proves signing, DCO and forge host-key pinning on a real commit with a
  throwaway key; the example site ships a synthetic pinned host key; the entrypoint honours
  the pre-split forge variable names for one release.

## v0.1.0 (2026-11-02)

- First tagged state: the hardened agent image and the hostname-allowlist proxy sidecar, the
  host-layer egress firewall, the site overlay contract (a `site` build context plus a compose
  override), the leak check, and CI-gated `main` with Renovate automerge.

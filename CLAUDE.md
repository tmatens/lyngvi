# CLAUDE.md

## Project overview

`lyngvi` runs a coding agent (the Claude Code CLI under Anthropic Remote Control) in a
hardened container that **cannot deploy**: scoped credentials, PR-only forge rules,
default-deny egress by network layout (no gateway, a hostname-allowlist proxy as the only
path), image-baked settings, and two secret-hygiene hooks. The authoritative design, threat model and non-negotiables are in
**`DESIGN.md`**: read it before changing anything security-relevant. This repo is
generic; a private overlay supplies every site value (`docs/OVERLAY.md`).

## Key facts

- **No site facts live here.** Hostnames, addresses, accounts, repo names, issue numbers,
  keys and secrets-backend markers belong in an overlay. `scripts/check-site-leaks.py`
  fails CI on the generic shapes of them and never prints the match. A site's own list
  of private strings stays in its overlay, which runs the same script over this repo
  before anything is pushed here; nothing derived from that list is committed.
- **Site inputs:** env from `site.conf` (non-secret) and `.env` (secret, never committed);
  files from the `site` build context (`/etc/lyngvi/site/`). Every input has an example
  in `site-example/` so the repo runs end-to-end as shipped.
- **Toolchains are build args** (`WITH_PYTHON`, `WITH_LINTERS`, `WITH_GO`,
  `WITH_FORGEJO_MCP`, `WITH_GITHUB_MCP`); gitleaks is not gated because the redact hook needs it. Gated
  layers copy binaries with `RUN --mount=from=<image@digest>,…` (`from=` first so Renovate
  tracks it).
- **The CLI pin** (`ARG CLAUDE_CODE_VERSION`) is tracked by a Renovate regex manager and is
  never automerged. Keep ≥ 2.1.110 (Remote Control + push notifications).
- **The egress control is the network definition** (`internal` + isolated gateway, Engine
  ≥ 28). Every client goes through `lyngvi-proxy` by hostname; the agent has no resolver.
  A new egress host is one allowlist line; nothing is ever applied on the host.
  The agent is `restart: unless-stopped`. The old host firewall path is gone (v0.5.0);
  `host/uninstall.sh` removes its leftovers from a host.
- **Config files that hold no secrets are named `.conf`, not `.env`**, so the secret-dump
  hook never blocks reading them.

## Secrets hygiene: keep values out of context

Treat every tool output as a permanent, untrusted sink. Never render a secret value
(`cat` a `.env`, `docker inspect` without a field, bare `env`, `docker compose config`);
never put one in argv or a URL; prove things by status code, key name, count or hash,
never by value; hand off via a 0600 temp file and `shred -u`. The hooks in `hooks/`
enforce the common shapes and the rest is judgement. If a secret lands in context
anyway, say so, treat it as compromised, and recommend rotation.

## Layout

- `Dockerfile`, `docker-compose.yml`: the hardened container + proxy sidecar, both
  consuming the `site` named context
- `entrypoint.sh`, `healthcheck.sh`: supervisor (PID 1), credential wiring, user
  settings, watchdog; liveness probe
- `agent/`: the agent's operating context, status line, forgejo and github MCP launchers, the
  marker → human push (`notify.mjs`, with its test)
- `hooks/`: `block-secret-dumps.sh` (PreToolUse), `redact-tool-output.sh` (PostToolUse),
  `skills-summary.sh` (SessionStart), `config-change.sh` (ConfigChange), with their tests
- `proxy/`: tinyproxy hostname-allowlist sidecar, the agent's only path out
- `relay/`: the token relay: Caddy holding the API tokens, adding them to the agent's API
  calls and refusing webhooks, keys, mirrors, collaborators, secrets and token creation
- `keys/`: the key sidecar: an ssh-agent with no network that holds the SSH keys and serves
  only its socket to the agent
- `agent/connect.mjs`: the ssh `ProxyCommand` that tunnels through it
- `host/`: `uninstall.sh` for hosts that still carry the pre-v0.5 host firewall; nothing to install
- `site-example/`: the example site inputs; `templates/overlay/` + `scripts/new-overlay.sh`
  are the overlay a site starts from (CI scaffolds and validates it); `examples/overlay/` is
  the override-file form
- `scripts/`: doctor (preflight + live checks, never prints a secret), smoke, leak check,
  GitHub ruleset + apply script, raw-log fetcher
- `leakcheck/`: allowlists for the leak check's generic rules
- `.github/`: CI, scheduled ruleset-drift check, the committed ruleset

## Common tasks

- **Bump the CLI:** merge the Renovate PR after reading its changelog; it is the agent.
- **Allow a new egress host:** a site concern, `site/proxy-filter.extra` in the overlay,
  one hostname-pattern line, one reason (`proxy/check-filter.sh` is the grammar, enforced
  at the proxy build; `scripts/refused-hosts.sh` prints refused hostnames in that form and
  never offers a refused name that is not a hostname). Upstream's `proxy/filter` holds only what every deployment needs (relay, login,
  GitHub, registries); a toolchain registry that widens egress beyond that is an opt-in
  preset in `proxy/presets/`, switched on with the proxy's `PROXY_PRESETS` build arg.
- **Change a grant, a hook or the MCP allowlist:** upstream `agent/managed-settings.mjs`
  for generic ones, `site/settings.json` for site ones; both become the image's managed
  settings (DESIGN.md §4.5). Never a runtime edit: the agent's own settings files rank
  below them and the user one is rewritten at every start.
- **Check a deployment:** `scripts/doctor.sh` (static), `--online` (forge), `--live`
  (container); one line per check, exit 1 on FAIL. Add a check there when BOOTSTRAP.md
  gains a requirement: the doc and the script describe the same list.
- **Verify locally what CI verifies:** `docker compose build && scripts/smoke.sh` (boots
  the example site with a throwaway SSH key and proves the supervisor loop, the merged
  settings, signing + DCO on a real commit, host-key pinning and the proxy's
  default-deny); `python3 hooks/test-*.py`; `python3 -I scripts/check-site-leaks.py`.
- **Commits:** signed, with a DCO sign-off. PRs only; `main` is ruleset-protected and
  the committed ruleset is checked against the live one weekly.

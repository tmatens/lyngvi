# Bootstrap: the human-only steps

Everything CI can prove, it proves ([README](README.md#quick-start)). These steps need a
human because they involve an interactive login, root on the host, or an admin token the
container must never hold. Do them once per deployment, in this order.

**Check as you go.** `upstream/scripts/doctor.sh` prints one named line per thing this
document asks for, and never a secret value. Run it from the overlay root after each
section: plain after §1 (`--online` to also prove the key is registered and the token
cannot merge: `--online --repo owner/name`), and `--live` on the docker host after §4. A
deployment that passes `--online --live` has every mechanical control in place; what
remains is the login.

## 1. Credentials (before the first start)

1. **Bot identity on each forge.** A dedicated account (never your own): on a self-hosted
   forge, a bot user in a team with Code/Issues/PR write on the repos it works and *no*
   admin; on GitHub, a machine account that forks and opens PRs, with a fine-grained PAT
   scoped to the repos it writes (Contents, Pull requests, Issues). Leave every other
   permission at "No access", above all **Administration**, **Webhooks** and **Secrets** on
   the repositories and **Gists** on the account: webhooks and mirrors are connections the
   forge makes outside the proxy, and a gist is a publishing channel (DESIGN.md §4.2). The
   same goes for the self-hosted bot: no repo-admin means no push mirrors or webhooks.
2. **SSH key.** `ssh-keygen -t ed25519 -N "" -C "<bot> station key"`. Register the public
   half on the bot account as an **authentication** key (git push) **and** as a **signing**
   key (so signed commits show "Verified"; GitHub keys are unique per account, so one key
   per identity). `base64 -w0 < key` → `GIT_SSH_KEY_B64` in `.env`.
3. **Forge API token** with issues R/W + repository read and **no merge or admin scope**
   → `FORGE_API_TOKEN`.
4. **Pin the forge's host key** in `site/known_hosts` (`ssh-keyscan -p <port> <host>`,
   verify the fingerprint out of band). Without it SSH is refused, on purpose.
5. Produce `.env` on the host (0600) from your secrets backend. Never commit it.

### What you just created, and why none of it can be dropped

| Credential | Where it lives | Why it exists | How the doctor checks it |
|---|---|---|---|
| Bot account, one per forge | the forge | Keys and tokens are always *someone's*; without its own account the agent acts as you, and nothing can be scoped away from you | `--online` reports which account accepted the key and the token |
| SSH key, auth **and** signing | `.env` `GIT_SSH_KEY_B64` | Push over SSH and "Verified" signatures both need a key registered on an account; a token cannot sign | decodes; accepted by the forge; registered on the account; signing on a real commit (`--live`) |
| Forge API token, no merge scope | `.env` `FORGE_API_TOKEN` | PRs, CI status and comments have no SSH path; the missing scope is one of the two merge gates | reads the API; the merge endpoint answers 403 (`--repo`) |
| GitHub fine-grained PAT | `.env` `GITHUB_TOKEN` | the same, for GitHub, plus HTTPS push and GitHub's MCP server | identity; no admin on the repo; an active ruleset |
| Pinned host key | `site/known_hosts` | public, not a secret: it replaces trust-on-first-use | matches the key the forge presents |
| Remote Control login | the `claude-home` volume | OAuth, interactive by design (DESIGN.md §2) | `--live` reports presence and expiry, never the value |
| Admin token, minutes long | a 0600 file on a workstation, shredded | branch protection is an admin operation the container must never be able to do | the weekly ruleset-drift job |

Per forge that is one account, one key, one token: the floor for this design, not a
convenience. Each candidate for removal takes a control with it. A token-only setup
(HTTPS push, no key) leaves every commit unsigned, because a forge verifies signatures
only against keys on an account. A GitHub App instead of the PAT and the machine account
gives hourly tokens and no second user, but an App cannot hold an SSH key, so commits it
pushes are unsigned too (GitHub signs only commits created through its API), and committing
through the API takes `git` away from the agent (DESIGN.md §6). Dropping the API token
leaves the agent unable to read CI or comment, which is most of what it does. What this
document can make cheaper is not the count but the cost of each: every row has a doctor
line, the admin token lives for minutes, and the host key is a file in git.

## 2. Branch protection (the deploy control)

For **every** repo the bot can write that has a deploy workflow on push to `main`, plus the
overlay repo itself:

- GitHub: import `scripts/github-main-ruleset.json` (Settings → Rules → Rulesets → Import),
  or `scripts/branch_protection_github.py --owner … --repo … --apply` with a **short-lived**
  admin PAT in `/tmp/gh_token`, shredded afterwards. Private repos need a paid plan for
  enforcement; verify with `--verify`.
- Forgejo/Gitea: block the bot only, with push whitelist = the humans, deploy-key push off,
  and confirm the bot's token cannot merge (`POST /repos/{o}/{r}/pulls/{n}/merge` → 403; a PUT gets 405 before the scope check).

Derive the repo list from the API and the workflow files; do not type it.

## 3. Host: nothing to install

The egress control is the network layout in `docker-compose.yml` (DESIGN.md §4.2): the
agent's networks are `internal` with an isolated gateway, so it has no route, no host
address to reach and no resolver, and the proxy sidecar is its only way out. There is no
firewall to apply, no unit to install and no timer to keep. What the host needs is
**Docker Engine 28.0 or later**; an older engine refuses to create the networks, which is
the correct failure, and `scripts/doctor.sh` reports the version. The site's forge and
notification host go in `site/proxy-filter.extra` (and a non-22 forge port in
`site/proxy-tinyproxy.extra`); the doctor checks both against `site.conf`.

A host still carrying the previous root-installed firewall (removed in v0.5.0) clears it
with `sudo upstream/host/uninstall.sh` once the overlay is on this layout
(`host/README.md`); the doctor warns until it is gone.

## 4. First start and login (interactive, once per volume)

```bash
docker compose up -d --build            # or your pipeline
docker exec -it lyngvi claude            # accept the workspace-trust dialog, then:
#   /login                               # FULL-scope claude.ai login (not setup-token)
```

Pair the phone/browser from the Claude app. The persisted `~/.claude` volume now holds the
credential; the supervisor connects within seconds. Verify from inside: `ssh-add -l`
shows the key, `git ls-remote` against the forge works, `npm ping` succeeds through the
proxy, and `node -e 'fetch("https://example.com")'` fails.

If the site set `NOTIFY_URL` or `NOTIFY_CMD` (site.conf), prove the path now, while you
are at a keyboard: `docker exec lyngvi notify --test` must land on the phone. The host
in `NOTIFY_URL` needs a line in `site/proxy-filter.extra` (every client leaves through the proxy).

## 5. Recurring: the monthly re-login

The refresh token expires ~30 days after login and rotation does not extend it. The
watchdog logs `RC_TOKEN_EXPIRING sev=warn` 48 h ahead and, with a notification target
configured, pushes it to you (`sev=crit` at 12 h); re-login then, while the station is
healthy:

```bash
docker exec -it lyngvi claude /login
```

If it was missed (`RC_TOKEN_STALE` / `RC_REGISTER_FAIL sev=crit`), the same command
recovers it. Nothing self-recovers here by design: re-auth is an interactive OAuth flow.
[docs/REMOTE_CONTROL.md](docs/REMOTE_CONTROL.md) is the runbook: what each marker means,
the login from another machine, how to confirm it worked, and what keeps it from
recurring.

## 6. Recovery reference

- **Container recreated and stuck in a 401 loop:** the on-disk refresh token was consumed
  by rotation before the recreate. `docker exec -it lyngvi claude /login`
  ([docs/REMOTE_CONTROL.md](docs/REMOTE_CONTROL.md)).
- **Agent can't push:** the key's public half is not (or no longer) on the bot account,
  or the host key changed (`SSH_HOSTKEY_MISSING` in the log). Fix the site files; a
  re-deploy re-applies them.
- **Package installs fail, everything else works:** the proxy sidecar is down or the host
  is not in its allowlist. `scripts/refused-hosts.sh` lists what the proxy refused as
  ready-made allowlist lines; add the ones the work needs to `site/proxy-filter.extra`
  with a reason. `go mod download` refused with `WITH_GO: "1"` means the proxy needs
  `PROXY_PRESETS: "go"` (the doctor warns about it).
- **Rebuild from scratch:** recreate the bot credentials (§1), `docker compose up -d
  --build`, §4. The workspace is disposable; the remotes are the source of truth.

# scripts/

| Script | Runs where | Purpose |
|---|---|---|
| `doctor.sh` | overlay root, on a workstation or the docker host | One named line per BOOTSTRAP.md requirement: engine and compose versions, site files and `site.conf` keys, `known_hosts` pin, the forge and push host in the proxy allowlist, the rendered compose egress layout (every agent network `internal` + isolated gateway, proxy env set); `.env` mode and key names (never values); `--online` host key vs pin, SSH key registration, token works and cannot merge (`--repo`), GitHub ruleset present; `--live` the container's start-up facts (from the entrypoint's per-run `/tmp/lyngvi-status`), markers, hooks, credential state, no default route, no resolver, no host address on the bridges, proxy allow/filter, the ssh tunnel, the egress leak test, and the hosts the proxy refused in the last 24h. Warns while units from the removed host firewall path are still installed (`host/uninstall.sh` clears them). Exit 1 on any FAIL. CI runs the static and live sections against the example site, before and after a daemon restart. |
| `new-overlay.sh` | workstation | Creates a private overlay repo: `upstream/` submodule at a release tag, `compose.yaml` extending the services here, `site/` from `site-example/`, `.compose-lint.yml`, validate workflow, `renovate.json`, leakcheck denylist, README checklist (`templates/overlay/`). Nothing committed; the first commit is yours. CI scaffolds one from each PR and validates it. |
| `check-site-leaks.py` | CI and workstations | Fails on any private deployment detail: an overlay's plaintext denylist (`--plaintext`) + generic regexes (RFC1918, age/SOPS markers, host keys, fingerprints, emails, home paths, SHAs, issue refs, private TLDs). Never prints the match. `--hash-list`/`--salt` generates the hash file from an overlay's plaintext list; `--plaintext` adds one for an overlay-side run. |
| `github-main-ruleset.json` | GitHub UI / API | The branch ruleset that makes `main` PR-only: squash only, linear history, no deletion or force-push, **no bypass actors**. Import per repo (Settings → Rules → Rulesets → Import). Required status checks are deliberately omitted: add them per repo only for checks that repo actually produces, or a never-reporting check blocks every merge. |
| `branch_protection_github.py` | workstation, short-lived admin PAT | Legacy branch-protection API path (`--owner`, `--repo` repeatable; `--verify` default, `--dry-run`, `--apply`). Prefer the ruleset above. |
| `gh-actions-log.mjs` | inside the container (`gh-actions-log` on PATH) | Reads a GitHub Actions job's raw log: hop 1 to `api.github.com` (PAT from the git credential helper, in-process), hop 2 to the signed blob URL if the site allowlisted it: both through the proxy sidecar, the agent's only path. Never prints the token or the signed URL. |
| `refused-hosts.sh` | host | Lists the hosts the proxy refused (default: last 24h) as anchored allowlist lines for review, most-refused first; a host an opt-in preset covers is reported as that preset. A refusal is the control working, so most lines stay out. |
| `check-go-preset.sh` | CI (and workstation, given an image) | Proves the proxy's `go` preset with the agent image's own Go: refused without it, `go mod download` succeeds with it, and an unknown preset name fails the build. |
| `check-github-mcp.sh` | CI (and workstation, given an image) | Starts the baked github-mcp launcher with a fake token and checks lyngvi's default tools (no copilot, no API-commit tools, no `create_repository`) and that `GITHUB_TOOLSETS` / `GITHUB_EXCLUDE_TOOLS` widen them. Contacts no GitHub. |
| `release-notes.sh` | workstation | Prints one version's section of `CHANGELOG.md` for `gh release create --notes-file -`; exits 1 when the section is missing or empty, so no release goes out with blank notes. `CONTRIBUTING.md` § Releasing. |
| `check-forge-mcp-areas.sh` | CI (and workstation, given an image) | Starts the baked forgejo-mcp launcher with a fake token and checks which tool areas it serves: admin and repo-settings off by default, every area on when `FORGEJO_DISABLED_AREAS` is set empty, a site list honoured. Contacts no forge. |

## Admin tokens

Branch protection is a repo-admin operation. The station's runtime credentials deliberately
lack admin scope, so each apply runs from a workstation with a **short-lived** admin token
written to a 0600 file (`/tmp/gh_token`), read by the script, and `shred -u`'d afterwards.
Never paste it on a command line.

## Deriving the protected set

The repos that need the rule are "bot-writable ∩ deploy-wired" (a deploy workflow on push
to `main`). Compute it from the forge API and the workflow files every time; a hand-kept
list drifted within a month in the reference deployment and the drift was a hole. A
Forgejo implementation of that derivation lives in the reference overlay; port the idea,
not the list.

## Secret rotation (pattern)

Rotation scripts are site-specific (they depend on the secrets backend), so they live in
the overlay. The pattern worth copying: read the new value from a hidden prompt or a 0600
file, never argv; verify it live by status code before editing; re-encrypt only the one
key and `sha256`-compare the other decrypted values before/after to prove nothing else
changed; commit signed; and for a key that is also the signing identity, **register the
new public half everywhere before deploying the new private half**, or the recreated
container loses push and signing, including the ability to deploy the fix.

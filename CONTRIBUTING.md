# Contributing

Pull requests only; `main` is protected by the ruleset in `.github/rulesets/main.json`:
required checks `ci` and `leak-check`, accepted only from GitHub Actions, on a branch that
is up to date with `main`; squash merges; linear history; **no required review and no
bypass actors**, so CI is the gate for everyone, the owner included.
Release tags (`v*`) are protected from deletion and moves by `.github/rulesets/release-tags.json`.

### Releasing

0. If the release changes the managed policy, the hooks or the egress layout, or bumps the
   CLI, run [docs/INJECTION_EXERCISE.md](docs/INJECTION_EXERCISE.md) and record the
   results there first.
1. Move the `## Unreleased` entries in `CHANGELOG.md` under a `## vX.Y.Z (date)` heading, in
   the PR that is the last one into the release (or one of its own). Mark anything a site
   must act on as **Breaking**, with the action.
2. After that PR merges: `git tag -s vX.Y.Z` on `main` (the message is the same notes) and
   push the tag.
3. `scripts/release-notes.sh vX.Y.Z | gh release create vX.Y.Z --verify-tag --title vX.Y.Z --notes-file -`
   publishes the changelog section as the GitHub release.
4. Push `main` and the tag to any mirror an overlay pins from.

Never write a `(#N)` reference into a changelog entry or a commit body that a squash will
copy: the leak check reads `#N` as a private tracker reference.
A weekly job compares both files with the live rulesets and fails on drift, and fails if any
collaborator other than the owner holds write. The ruleset half needs a repository secret
`RULESET_DRIFT_TOKEN`: GitHub returns a ruleset's `bypass_actors` only to admin callers, and
the job token is not one. It is the owner's fine-grained personal access token, scoped to this
repository alone, with **Administration: read-only** (Metadata read is implied), one-year
expiry. When it is missing or expired the job fails rather than passing blind; renew it from
the failing run, there is no automation for a credential.

## Dependency updates

Renovate opens the PRs and merges them itself once CI is green and the release has aged;
`renovate.json` carries the policy and the reasoning. The table is the same policy for
people:

| Update | Waits | Merges itself? | Why |
|---|---|---|---|
| Image digests, action SHAs, patch bumps | 3 days | yes | `ci` rebuilds both image variants and runs the smoke against the result |
| `ghcr.io/gitleaks/gitleaks` digest | none | yes | the registry gives Renovate no timestamp; the hook test suite runs on the exact digest |
| Minor bumps, Claude Code CLI minors included | 3 days | yes | the smoke boots the new CLI to its supervisor loop on the PR |
| Majors (node release line, actions, linters) | 7 days | yes | first week is when the x.0.1 lands |
| Go toolchain + golangci-lint release line | 7 days, grouped | yes | both must move together; the PR builds the `WITH_GO=1` variant |
| Claude Code CLI major | n/a | **no** (`manual-merge`) | can change the settings schema, hook protocol or login flow |
| forgejo-mcp commit | n/a | **no** (`manual-merge`) | built from source, runs with the forge token: read the diff |
| `ghcr.io/github/github-mcp-server` | none | **no** (`manual-merge`) | runs with the GitHub token: read the release notes; no registry timestamp to age by |
| `caddy` (the token relay) | 3 days | **no** (`manual-merge`) | holds the GitHub and forge tokens and decides which API paths the agent reaches: read the release notes |
| Security advisories | none | per the rows above | opens immediately, labelled `security` |

An open Renovate PR with no `manual-merge` label is green-and-waiting or red, never forgotten.

## Before you push

```bash
scripts/doctor.sh                                   # static preflight against the example site
docker compose build && KEEP=1 scripts/smoke.sh && scripts/doctor.sh --live
python3 hooks/test-redact-tool-output.py            # needs gitleaks on PATH
python3 hooks/test-block-secret-dumps.py
python3 -I scripts/check-site-leaks.py              # must be 0 fail
python3 -I scripts/check-attribution.py --range origin/main..HEAD   # must pass
```

CI runs the same pinned linters (shellcheck, hadolint, actionlint, compose-lint) through
their official images, so local == CI.

## Rules of the repo

- **No AI attribution.** No co-author trailer naming an AI assistant or its vendor, no
  session trailer or session link, no "Generated with" footer, in commits or PR
  descriptions. CI fails a change that adds one (`scripts/check-attribution.py`); human
  co-author trailers are fine. For Claude Code, `"attribution": false` in your settings
  stops it adding them.
- **Nothing site-specific.** No hostnames, internal addresses, account or repo names,
  issue numbers from private trackers, host keys, secrets-backend markers. Every site
  value is a parameter with an example default. The leak check enforces the mechanical
  half; the human half is yours.
- **Every dependency gets an update path.** Pin images by tag **and** digest (Renovate
  looks digest updates up by tag), actions by SHA with a version comment, the CLI via
  the annotated `ARG`. Put `from=` first in `RUN --mount` so Renovate sees it. If you add
  a dependency Renovate cannot see, add a custom manager or an explicit disabled rule
  that says what moves it.
- **A control must be mechanical or it is a limitation.** If a change makes the agent
  *less likely* to do something but not *unable*, document it under limitations, not
  controls.
- **Commits are signed** (SSH or GPG) and carry a `Signed-off-by` trailer (DCO). Keep
  commit messages free of private provenance too: the leak check scans them.
- Match the existing style: one reason per allowlist line, comments that say *why*, no
  hand-kept lists where a derivation exists.

## Reporting a security issue

Open a private security advisory on GitHub rather than a public issue.

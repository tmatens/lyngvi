# my-station: a lyngvi deployment

This is a private **overlay**: it runs [lyngvi](https://github.com/tmatens/lyngvi) unchanged
from the `upstream/` submodule and adds only what is specific to this site. Everything
mechanical (the hardened container, the gateway-less networks, the proxy, the hooks) is upstream
and arrives as a version bump. What lives here: `site/` (the values), `compose.yaml` (the
names and subnets), `.env` on the host (the secrets, never committed), and this file.

## First run

Each step is one of [`upstream/BOOTSTRAP.md`](upstream/BOOTSTRAP.md)'s human steps, and
`upstream/scripts/doctor.sh` checks the result of each one without printing a secret.

1. **Say who and where.** Edit `site/site.conf` (identity, forge, API base, Remote Control
   name), `site/CLAUDE.md` (what the agent works on), `site/known_hosts` (your forge's
   host key, verified out of band), `site/proxy-filter.extra` (your forge and your
   notification host: the proxy is the only way out, so what is not listed is
   unreachable), `site/proxy-tinyproxy.extra` if the forge's SSH port is not 22. Flip
   build args in `compose.yaml` if your repos need Go or the Forgejo MCP adapter. The
   rest of `site/` can stay as it is.
2. **Credentials** (BOOTSTRAP §1): a bot account, a key registered as auth and signing
   key, a token without merge scope. Produce `.env` (0600) from your secrets backend.
3. `upstream/scripts/doctor.sh --online --repo owner/repo`: fix every `FAIL`.
4. **Host**: Docker Engine ≥ 28.0, nothing else (BOOTSTRAP §3).
5. `docker compose up -d --build`, then `docker exec -it lyngvi claude` → accept the
   workspace-trust dialog → `/login` (full scope). Pair the phone.
   `upstream/scripts/doctor.sh --live` on the docker host.
6. **Protect this repo's `main`** and every deploy-wired repo the bot can write (BOOTSTRAP
   §2). Import `upstream/scripts/github-main-ruleset.json`, with `validate` as a required
   check.

Monthly: `docker exec -it lyngvi claude /login` when `RC_TOKEN_EXPIRING` fires. Set
`NOTIFY_URL` in `site/site.conf` so it reaches you.

## Layout

```
upstream/                git submodule → lyngvi at a release tag; never edited here
compose.yaml             extends upstream's two services; names, subnets, build args, site env
site/                    site.conf, CLAUDE.md, known_hosts, settings.json, gitconfig,
                         proxy-filter.extra, proxy-tinyproxy.extra: one example each upstream
.env                     secrets on the host (gitignored); names in upstream/.env.example
.compose-lint.yml        copied from upstream (the one suppression the design needs)
leakcheck/denylist.txt   private strings that must never reach upstream (plaintext, here only)
.github/workflows/       validate: tag-pinned upstream, doctor, compose-lint, leak check
renovate.json            upstream bumps arrive as PRs (manual merge: a bump recreates the container)
```

## Updating upstream

Renovate opens "update upstream to vX.Y.Z". Read upstream's release notes, merge, redeploy;
the container is recreated and Remote Control reconnects (a `/login` may be needed once).
`validate` refuses an `upstream/` that is not exactly at a `v*` tag, so a hotfix is a PR
to upstream, not a patch here. If a change to `site/` needs an upstream change to work,
upstream ships first and this repo bumps the gitlink in the same PR.

## Deploying

`main` here is deploy-wired, so it is PR-only. If your pipeline does `git pull` without
submodules, run `git submodule update --init -- upstream` in a pre-deploy hook, including
on the rollback path. Secrets: regenerate `.env` from your backend on every deploy, so a
rotation committed as ciphertext reaches the container.

## On Forgejo or Gitea

The workflow in `.github/workflows/` is GitHub Actions. On a Forgejo-hosted overlay move
it to `.forgejo/workflows/`, set `runs-on: docker`, use
`https://code.forgejo.org/actions/checkout@v7`, and install compose-lint with
`pip install --require-hashes` from a lockfile. Two forge facts worth knowing before the
first CI run: the job token reaches only its own repository, so a **private** upstream
mirror needs a read token passed to `checkout` as `token:`; and an AGit pull request is
treated as a fork PR and receives no secrets, so open branch PRs when CI needs one.

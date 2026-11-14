# Running lyngvi for real: the overlay

Upstream stays generic and untouched. Your deployment lives in a separate, private
**overlay** repo that consumes this one as a pinned git submodule and supplies site values
through two artefacts: a `site/` directory and a `compose.override.yml`. Nothing private
ever needs to exist in the upstream tree, and upstream CI fails if it does.

## Layout

```
my-station/                          # private overlay
├── upstream/                        # git submodule → github.com/tmatens/lyngvi @ vX.Y.Z
├── compose.override.yml             # subnets, build args, env_file, extra networks
├── site/
│   ├── site.conf                    # non-secret runtime values (identity, forge, skills)
│   ├── CLAUDE.md                    # site operating context, appended to upstream's
│   ├── known_hosts                  # pinned forge SSH host key(s)
│   ├── settings.json                # site grants/hooks, merged into the managed settings at build
│   ├── gitconfig                    # per-path identities, extra git options
│   ├── proxy-filter.extra           # the site's egress allowlist: the forge, the push host
│   └── proxy-tinyproxy.extra        # extra proxy directives (a non-22 forge port)
├── .env                             # secrets: produced on the host, never committed
└── README.md                        # how this site deploys; points at upstream docs
```

Start from the template: `scripts/new-overlay.sh ../my-station` creates that layout
(submodule at the latest release tag, `compose.yaml`, `site/` copied from `site-example/`
with every value documented in place, the validate workflow, `renovate.json`, a README
whose first section is the bootstrap checklist) and leaves the first commit to you.
Upstream CI scaffolds it from every PR and runs its validate steps, so the template cannot
drift. [`examples/overlay/compose.override.yml`](../examples/overlay/compose.override.yml)
shows the same thing in the override-file form (`-f upstream/docker-compose.yml -f
compose.override.yml`) if you prefer not to `extends`.

`extends` carries the agent's `depends_on: lyngvi-proxy` (it starts only once the proxy is
healthy). An overlay that keeps upstream's service names needs nothing. An overlay that
**renames** the proxy service must point the dependency at its own name, or compose refuses
the project ("depends on undefined service"):

```yaml
  my-agent:
    extends: { file: upstream/docker-compose.yml, service: lyngvi }
    depends_on: !override
      my-proxy:
        condition: service_healthy
```

## How site files reach the image without a bind mount

Bind mounts are a Tier-0 violation, and a Compose `configs:` entry is a bind mount under
the hood. Site files instead enter at **build** time through a BuildKit **named context**:

```dockerfile
FROM scratch AS site            # upstream default: the example values
COPY site-example/ /
...
COPY --from=site / /etc/lyngvi/site/
```

```yaml
# compose.override.yml
services:
  lyngvi:
    build:
      context: ./upstream
      additional_contexts:
        site: ./site              # overrides the stage of the same name
```

A named context overrides a stage with the same name, so plain `docker build` still works
with the example values, Renovate sees a stage rather than a phantom image, and the
overlay needs no Dockerfile. Requires Compose ≥ 2.20 (BuildKit named contexts; the proxy
healthcheck's `start_interval`).

## Two Compose semantics that bite

- **`env_file` lists are appended, not replaced.** Use `env_file: !override` in the
  override or the example `site-example/site.conf` loads before yours (the later file wins
  per key, so it would still mostly work, silently).
- **Networks merge by name.** Re-declaring `lyngvi-net` with a different `subnet` replaces
  the IPAM config and keeps upstream's `internal` + isolated-gateway options; adding a
  network to the service's list appends. Every network the agent joins must have those
  two options or it gains a route out; `scripts/doctor.sh` fails on the rendered compose,
  and `--live` checks the real bridges, including an `external` one you created by hand.

## A stronger kernel boundary (opt-in)

To run the agent under gVisor instead of sharing the host kernel, set up the host and add
[`examples/gvisor/compose.gvisor.yml`](../examples/gvisor/compose.gvisor.yml) to the
overlay's `-f` list ([GVISOR.md](GVISOR.md)). If the overlay changes
`lyngvi-proxy-net`'s subnet, move the file's two fixed addresses with it.

## Secrets

Upstream defines the **names** (`.env.example`); your overlay defines how the `.env` is
produced on the host. The pattern used by the reference deployment: secrets SOPS-encrypted
to a committed `.env.sops` with a **dedicated** age recipient whose private key lives only
in the host keystore; a pre-deploy hook decrypts it to a 0600 `.env` on every deploy, so a
committed rotation reaches the container. Whatever you use, the invariant is the same: the
decryption key is never inside the container, and the plaintext never enters git.

A multiline SSH key fits dotenv as base64: `base64 -w0 < key` → `GIT_SSH_KEY_B64`.

## Host side

Nothing. The egress control is the network layout in the compose file, so there is no
firewall to install and no unit to keep in step with the clone. The host needs Docker
Engine ≥ 28.0, which `scripts/doctor.sh` checks. A host still carrying the previous
root-installed firewall clears it with [`host/uninstall.sh`](../host/README.md).

## Deploying the overlay

The overlay's `main` is deploy-wired, so protect it (PR-only). If your deploy engine does
`git pull` without submodules, run `git submodule update --init -- upstream` in a pre-deploy
hook, including on the rollback path, after the engine resets to the previous commit, so
the submodule follows the rolled-back gitlink.

## Update workflow

- **Generic fix:** a PR to upstream, merged, tagged. Never patch `upstream/` in place. A
  local hotfix is a branch of the submodule pushed upstream as a PR; the overlay may point
  its gitlink at that commit *temporarily* with an issue tracking the revert to a tag.
- **Downstream pull:** Renovate's `git-submodules` manager (enable it in the overlay) opens
  "update upstream to vX.Y.Z"; the overlay's CI renders the merged compose (base +
  override, with a synthetic `.env`) and lints it; a human merges; the pipeline deploys.
- **The rule that keeps the overlay thin:** if a change to `site/` or the override needs a
  matching change in `upstream/` to work, the upstream change ships first and the overlay
  bumps the gitlink in the same PR. Let CI enforce half of it by refusing an `upstream/`
  that is not at a tag.

## The agent contributing to upstream from your overlay

Give the agent its **own forge identity** (a machine account), a fork of upstream, a
second signing key from `SSH_KEY_<NAME>_B64`, a second HTTPS credential from
`GIT_HTTPS_CREDENTIAL_<NAME>`, and a `site/gitconfig` `includeIf` that selects them for the
upstream checkout path. The agent then has **zero write permission on upstream** and
proposes like any outside contributor, which is the strongest form of the thesis. Keep
that identity's write permission confined to its fork.

The second key, like the first, is held by the key sidecar (upstream DESIGN.md §4.3), not
the agent:
- **In the agent service:** blank `SSH_KEY_<NAME>_B64` (`environment: - SSH_KEY_<NAME>_B64=`),
  or doctor fails.
- **In `site/gitconfig`:** point `user.signingkey` and the ssh `IdentityFile` at the
  public half, `~/.ssh/<name>.pub`. The sidecar's agent does the signing.

## Leak check, both directions

Upstream's own CI runs the generic rules only: private addresses, key material, home
paths and the like. It holds nothing derived from your private strings. A hash of a short
token such as an address or a host name can be reversed by guessing, even with a salt, so
no hash list is kept upstream.

Your list lives only in the overlay, in plaintext (`leakcheck/denylist.txt`). Run the
check over the submodule with it before any upstream push:

```bash
upstream/scripts/check-site-leaks.py --root upstream --plaintext leakcheck/denylist.txt
```

The template's `validate` workflow runs the same command, so a change to the pinned
upstream is checked against your list before it merges in the overlay.

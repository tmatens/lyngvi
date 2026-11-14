# When the agent may be compromised

Use this page when you have reason to think the agent is acting for someone else. Signs include:
- a notification asking for anything beyond the [Remote Control runbook](REMOTE_CONTROL.md) (DESIGN.md §10);
- a canary or decoy alert;
- forge activity you did not ask for;
- the agent trying to reach hosts that have nothing to do with its task.

The order matters. Stop the agent first. Revoke its credentials next. Only then look at
what happened, and keep the evidence while you look.

Examples use the compose project and container name `lyngvi`, the proxy `lyngvi-proxy`,
and the volumes `lyngvi_workspace` and `lyngvi_claude-home`. Use your site's names.

## 1. Stop the agent, keep the proxy

```bash
docker compose stop lyngvi
```

Do **not** run `docker compose down -v`, and do not remove either container. The proxy
logs every connection the agent made, allowed and refused, and a compromised agent could
neither write nor erase that log. It is the most trustworthy record you have. If the site
ships it and tool-call telemetry off the host (docs/AUDIT.md), read those copies first. The agent's
own container log is useful too, but the agent could have written to it, so read it as
untrusted (DESIGN.md §10).

`restart: unless-stopped` keeps a stopped container stopped across a daemon restart, so
the agent stays down until you start it.

## 2. Revoke every credential the agent held

Do this before investigating. The agent may have copied any of these out through an
allowlisted host, and revoking them makes a copy useless.

| Credential | Where it lives | How to revoke |
|---|---|---|
| SSH key (`GIT_SSH_KEY_B64`) | `.env`; held by the key sidecar (the agent could use it while running, not copy it) | Delete the public key from **every** account it is registered on: the bot's authentication key on the forge, any deploy key, and the signing key on GitHub if you registered one. Signatures it made stay valid, but no new push or signature verifies. |
| Forge API token (`FORGE_API_TOKEN`) | `.env`; held by the token relay | Delete the token in the bot account's settings (Applications / Access tokens). |
| `GITHUB_TOKEN` | `.env`; held by the token relay | Revoke the fine-grained token at github.com → Settings → Developer settings. |
| `GIT_HTTPS_CREDENTIAL_*` | `.env` | Revoke each token at its host. |
| `NOTIFY_URL` | `site.conf` | If the URL itself carries a secret (a webhook token), rotate it at the notification service. |
| Claude login | the `claude-home` volume (`.credentials.json`) | Sign the account out of all sessions from claude.ai's account settings, then sign back in on your own devices. Deleting the volume alone does not revoke the token. |

## 3. Preserve the evidence

Save the logs and snapshot the volumes before you change anything else:

```bash
umask 077
mkdir -p incident && cd incident
docker logs --timestamps lyngvi-proxy > proxy.log 2>&1
docker logs --timestamps lyngvi       > agent.log 2>&1
for v in lyngvi_workspace lyngvi_claude-home; do
  docker run --rm -v "$v":/v:ro -v "$PWD":/out busybox tar czf "/out/$v.tgz" -C /v .
done
```

The archives contain the revoked credentials and anything else the agent could read.
Keep them `0600`, off any shared or synced storage, and delete them when the review is
done.

**Never start the agent again on these volumes.** A compromised agent can leave things behind that run in the next session:
- instructions in `CLAUDE.md` or memory;
- permission rules in a workspace's `.claude/settings*.json`;
- `.git/hooks` in a repository.

## 4. Find what the agent changed outside the container

The proxy kept the agent off every host except the allowlisted ones. Through those it could only act with the tokens above. Look for anything that would outlive the revocation:
- **On every repository the bot can write:**
  - webhooks;
  - deploy keys;
  - push mirrors;
  - collaborators;
  - branches and tags you do not recognise;
  - releases;
  - Actions or workflow files changed in open pull requests.
- **On the bot account:**
  - SSH and GPG keys;
  - access tokens and OAuth applications;
  - its recent activity feed.

On Forgejo or Gitea, as an account that can read them:

```bash
# per repository
GET /api/v1/repos/{owner}/{repo}/hooks
GET /api/v1/repos/{owner}/{repo}/keys
GET /api/v1/repos/{owner}/{repo}/push_mirrors
GET /api/v1/repos/{owner}/{repo}/collaborators
# the bot account
GET /api/v1/users/{bot}/keys
GET /api/v1/users/{bot}/activities/feeds
```

On GitHub: `gh api repos/{owner}/{repo}/hooks`, `…/keys` and `…/collaborators` for each
repository, and the bot's SSH and signing keys under its account settings.

The tokens lyngvi asks for (BOOTSTRAP.md) have no admin scope, so most of these calls
should have been refused at the forge. Checking them confirms that, rather than assuming it.

## 5. Read what reached the network

The proxy log has a `CONNECT` line for every tunnel the agent opened, and a
`refused on filtered domain` line for every host it was denied. The questions to answer:

- **Refusals:** which hosts did it try that it had no reason to? `scripts/doctor.sh --live`
  and `scripts/refused-hosts.sh` print the refused names safely. The log is untrusted
  text, so do not `cat` it to a terminal.
- **Allowed connections:** did the volume or timing of traffic to an allowlisted host change
  around the event, for example a burst to a package registry or the forge? An allowed host is
  still a way out (DESIGN.md §11), so the content cannot be ruled out. The timing narrows
  what to look for on the forge.

## 6. Rebuild

1. Generate a new SSH key and new tokens. Register them as in BOOTSTRAP.md, and put them in
   `.env` (or the site's encrypted secrets).
2. Remove the old volumes, **after** step 3:
   `docker compose down && docker volume rm lyngvi_workspace lyngvi_claude-home`.
3. Rebuild from a known commit: `docker compose build --no-cache && docker compose up -d`.
4. Log in again ([REMOTE_CONTROL.md](REMOTE_CONTROL.md#re-login)), and run
   `scripts/doctor.sh --online --live`.
5. Re-clone the workspace repositories from the forge rather than restoring the old volume.

## 7. Afterwards

Write down what the agent was working on when it went wrong, what it was fed (an issue,
a web page, a dependency), and which control stopped it or did not. If a control lyngvi
claims did not hold, that is a vulnerability: report it as [SECURITY.md](../SECURITY.md)
describes, with no site values or secrets.

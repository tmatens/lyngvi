# Remote Control: when the station is signed out

The agent reaches you through Remote Control, which needs a full claude.ai login. There
is no headless renewal: a lost login is always recovered by a person running `/login`
once. This page is for the moment you are paged, or the station has gone quiet. Why it
works this way is in [DESIGN.md §2](../DESIGN.md#2-front-end-remote-control).

Examples use the container name `lyngvi`; use your site's `CONTAINER_NAME`.

## What the marker means

The entrypoint logs these markers, and pushes them to you if `NOTIFY_URL` or `NOTIFY_CMD`
is set. Every one of them is fixed by the same command, [below](#re-login).

| Marker | What happened | Is the station working? | When to act |
|---|---|---|---|
| `RC_TOKEN_EXPIRING sev=warn` | The refresh token expires within 48 h. It is issued about 30 days after a login, and using it does not extend it. | Yes | Before it expires, at a convenient time |
| `RC_TOKEN_EXPIRING sev=crit` | Under 12 h left. The first refresh after that point empties the credential. | Yes, for now | Now |
| `RC_TOKEN_STALE sev=crit` | The credential has expired with no refresh token left. | No. The app may still show the station online, but every session fails with 401. | Now |
| `RC_REGISTER_FAIL sev=crit`, "consecutive 401/auth exits" | Remote Control cannot register at start. This usually follows a container recreate: the CLI started from a copy of the refresh token that had already been used. | No. The station is missing from the app. | Now |
| `RC_REGISTER_FAIL sev=crit`, "while remote-control is RUNNING" | Remote Control is connected, but its credential died underneath it. | No. Sessions fail with 401. | Now |

**No marker, and the station is missing from the app:** this is not a login problem.
Run `scripts/doctor.sh --live`. The usual causes are the proxy being down (everything,
Remote Control included, goes through it) and a network outage longer than about ten
minutes, after which the supervisor restarts the CLI by itself. The log line
`remote-control exited … (login needed / config)` on a fresh volume means it has never
been logged in: that is first start ([BOOTSTRAP.md §4](../BOOTSTRAP.md)).

## Re-login

On the host:

```bash
docker exec -it lyngvi claude /login
```

From another machine, `ssh` needs a terminal for the interactive prompt:

```bash
ssh -t <host> docker exec -it lyngvi claude /login
```

1. Log in with the claude.ai account that has your subscription. A `setup-token` or an
   API key does not work for Remote Control.
2. The CLI prints a URL. Open it in a browser where you are signed in to that account,
   approve it, and paste the code you are shown back into the terminal.
3. Leave with `/exit`. The credential is written to the login volume, where Remote
   Control reads it. When Remote Control was failing at start, the supervisor's next
   retry (every few seconds) picks it up.

## Confirm it worked

```bash
scripts/doctor.sh --live
```

The credential line should read `refresh=present` with `refresh_expires` about 30 days
(roughly 720 h) out, and no `RC_*` marker should be reported. In the Claude app the station is
listed again and a new session answers. Markers that were logged before the login stay
in the log; the doctor looks at the current start only.

If the station is not back, or sessions still fail, a few minutes later, restart the
container (`docker restart lyngvi`). That starts the CLI again from the credential you
just wrote. Restart, do not recreate: a restart keeps the container and its volumes as
they are.

## Keeping it from happening

- **Recreate the container only when something changed.** `docker compose up -d`
  recreates it only when its configuration or image changed; a deploy pipeline should
  skip a deploy that changes neither, and nothing should run `--force-recreate` as
  routine. Each recreate starts the CLI from the copy of the credential on disk, and
  that copy is the one that can be stale.
- **Re-login when the 48 h warning arrives,** not after the credential is gone. Set up a
  notification target so the warning reaches you; `docker exec lyngvi notify --test`
  proves it.
- **Do not copy, back up or restore `.credentials.json`.** The refresh token in it can be
  used once, so a restored copy has usually been used already and only produces the
  401 loop. Moving the station to a new host or a new volume means a fresh `/login`.
- **Keep interactive `claude` sessions in the container short.** Remote Control and a
  `docker exec -it lyngvi claude` session share the credential file, and two processes
  refreshing it at the same moment is one of the known ways it gets used twice.

## Recreating the container without losing the login

A recreate (a deploy, `docker compose up` after an image change) can cost the login, and
it depends on timing:
- **The mechanism:** the claude.ai refresh token is single-use and rotates, and a process
  refreshes when its access token is about to expire.
- **Risky:** a recreate near that moment. The old container may refresh and be stopped
  before the new pair reaches the volume, or the new container may have to refresh at
  start with a token the old one already used. Either way Remote Control fails with
  `RC_REGISTER_FAIL` / `RC_TOKEN_STALE`, and only `/login` recovers it.
- **Safe:** any time the access token has plenty of life left. It lasts about **8 hours**
  after a login or a refresh.

`scripts/recreate-safe.sh` reads the credential's expiry timestamp, never a token. It
exits 0 when a recreate now is safe and 1 when it is risky, and `scripts/doctor.sh --live`
reports the same. A deploy can gate on it. When it says risky, either wait until the
running station has refreshed (the minutes left jump back to about 480), or deploy right
after a `/login`.


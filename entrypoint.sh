#!/usr/bin/env bash
# lyngvi entrypoint — PID1.
#
# Responsibilities:
#   0. Install the agent operating context, hooks and status line from the image.
#   1. Load the scoped git SSH key(s) into an ssh-agent; pin the forge host key.
#   2. Configure git identity, commit signing, DCO, HTTPS credentials.
#   3. Run `claude remote-control` as the long-running foreground process, in a
#      supervisor loop (a >10-min network outage makes RC exit; the host unit +
#      this loop bring it back). A detached tmux `shell` session is provided for
#      human inspection via `docker exec`.
#
# Every site fact is an input: env from site.env/.env (compose env_file) and
# files under /etc/lyngvi/site/ (the `site` build context). Nothing in this
# script names a host, an account or a repo. See docs/OVERLAY.md.
#
# First run is interactive and must be done once into the persisted ~/.claude
# volume (BOOTSTRAP.md): `docker exec -it <container> claude /login` (full scope)
# and accept the workspace-trust dialog. Until then RC exits and the loop retries
# with a clear log line.
set -uo pipefail

log() { echo "[entrypoint $(date -u +%H:%M:%S)] $*"; }
# A structured marker: the log line is the source for a generic log-alert rule
# (DESIGN.md §10); when the site configured a target (NOTIFY_URL / NOTIFY_CMD) the
# same marker is also pushed to a human by agent/notify.mjs, in the background so
# the supervisor loop never waits on a network call. notify.mjs throttles repeats.
mark() { # MARKER warn|crit message…
  local m="$1" s="$2"; shift 2
  log "$m sev=$s $*"
  if [[ -n "${NOTIFY_URL:-}${NOTIFY_CMD:-}" ]]; then
    ( node /etc/lyngvi/notify.mjs "$m" "$s" "$*" 2>&1 | while IFS= read -r l; do log "$l"; done ) &
  fi
}

# This run's start-up facts as KEY=value lines, read by `scripts/doctor.sh --live`
# instead of scraping the log (a Remote Control login can push the start-up lines out
# of any fixed log window). /tmp is a per-run tmpfs, so the file never outlives the run
# it describes. Facts only — never a value from the environment.
STATUS_FILE=/tmp/lyngvi-status
: > "$STATUS_FILE" && chmod 644 "$STATUS_FILE"
status() { printf '%s=%s\n' "$1" "$2" >> "$STATUS_FILE"; }
status started "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The home directory is a tmpfs, empty at every start (docker-compose.yml): restore the
# shell's skeleton dotfiles. Everything else the agent needs there is written below.
cp -rn /etc/skel/. "$HOME"/ 2>/dev/null || true

# TMPDIR (set by the image) lives on the workspace volume, which persists: empty it so a
# run starts with nothing a previous one left behind. 0700, as tools expect of a temp dir.
if [[ "${TMPDIR:-}" == "$HOME/workspace/.tmp" ]]; then
  if rm -rf "$TMPDIR" && install -m 700 -d "$TMPDIR"; then
    status tmpdir "$TMPDIR"
  else
    mark TMPDIR_FAILED warn "could not recreate TMPDIR=$TMPDIR; tools fall back to the noexec /tmp"
  fi
fi

SITE=/etc/lyngvi/site
CN="${CONTAINER_NAME:-${HOSTNAME:-lyngvi}}"   # only used in log hints
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# ── 0. Operating context, hooks, status line (image is the source of truth) ──
install -m 700 -d "$CLAUDE_DIR"
if [[ -f /etc/lyngvi/CLAUDE.md ]]; then
  {
    cat /etc/lyngvi/CLAUDE.md
    if [[ -s "$SITE/CLAUDE.md" ]]; then
      printf '\n\n---\n\n# Site-specific operating context\n\n'
      cat "$SITE/CLAUDE.md"
    fi
  } > "$CLAUDE_DIR/CLAUDE.md" && log "Installed operating context → $CLAUDE_DIR/CLAUDE.md (upstream + site)"
fi
[[ -f /etc/lyngvi/statusline-context.mjs ]] \
  && cp /etc/lyngvi/statusline-context.mjs "$CLAUDE_DIR/statusline-context.mjs" \
  && log "Installed context-usage status line"
# The hooks run from the image (/etc/lyngvi/hooks, root-owned), wired by the managed
# settings baked at build (/etc/claude-code/managed-settings.json). Nothing to install:
# report it, and remove the copy that images before v0.9 kept in the volume, which
# nothing runs any more.
rm -rf "${CLAUDE_DIR:?}/hooks"
MANAGED=/etc/claude-code/managed-settings.json
if [[ -s "$MANAGED" && ! -w "$MANAGED" ]] && node -e '
  const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.exit(m.allowManagedHooksOnly===true && m.hooks && m.hooks.PreToolUse && m.hooks.PostToolUse ? 0 : 1)' "$MANAGED"; then
  log "Secret-hygiene hooks wired by managed settings ($MANAGED, read-only to this uid)"; status hooks managed
else
  mark HOOKS_UNMANAGED crit "$MANAGED is missing, writable by the agent, or does not wire the hooks — the image is broken; rebuild it"
  status hooks unmanaged
fi

# Legacy forge variable names (pre-split overlays) are honored for one release
# with a warning, like FORGEJO_DEPLOY_KEY_B64 below. Exported, because the MCP
# adapter is launched later by the CLI and reads them from its own environment.
if [[ -z "${FORGE_API_TOKEN:-}" && -n "${FORGEJO_API_TOKEN:-}" ]]; then
  export FORGE_API_TOKEN="$FORGEJO_API_TOKEN"
  log "WARN: FORGEJO_API_TOKEN is deprecated — rename it to FORGE_API_TOKEN"
fi
if [[ -z "${FORGE_API_BASE:-}" && -n "${FORGEJO_API_BASE:-}" ]]; then
  export FORGE_API_BASE="$FORGEJO_API_BASE"
  log "WARN: FORGEJO_API_BASE is deprecated — set FORGE_API_BASE in site.conf"
fi

# ── 0b. API tokens (held by the token relay) + forge MCP servers ─────────────
# The tokens live in the token relay (relay/start.sh); this container's service blanks
# them. Each route the relay has answers GET /_lyngvi, and the MCP launchers and git
# are pointed at the routes that answer.
for var in GITHUB_TOKEN FORGE_API_TOKEN FORGEJO_API_TOKEN LYNGVI_ANTHROPIC_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
  if [[ -n "${!var:-}" ]]; then
    mark TOKEN_IN_AGENT crit "$var is set in the agent's environment: the token belongs to the token relay only; blank it in the agent service (environment: - $var=)"
  fi
done
# The relay always listens on 8081 (a route, or a "no token configured" 404), so wait for
# that once, up to 15 s; a route that is not configured has no listener at all, so each
# route is then asked once, without retrying.
node -e '
  const until=Date.now()+15000;
  (function once(){ fetch("http://lyngvi-relay:8081/_lyngvi").then(()=>process.exit(0))
    .catch(()=>{ if (Date.now()>until) process.exit(1); setTimeout(once,500); }); })();' 2>/dev/null \
  || log "WARN: no token relay answered on lyngvi-relay:8081 — API calls and git over HTTPS to GitHub have no token"
relay_route() { # $1 = port; succeeds when the relay has that route
  node -e 'fetch("http://lyngvi-relay:"+process.argv[1]+"/_lyngvi").then(r=>process.exit(r.status===200?0:1)).catch(()=>process.exit(1))' "$1" 2>/dev/null
}
# The route addresses themselves (LYNGVI_RELAY_*, and SSH_AUTH_SOCK for the key sidecar)
# are fixed image environment (Dockerfile), so a session started with `docker exec` sees
# them too, not only this process tree. The probes decide what is registered.
relay_github=0; relay_git=0; relay_forge=0
if relay_route 8081; then
  relay_github=1; status relay_github on
  # GitHub's MCP server accepts a plain-HTTP host only on loopback: forward one to the relay.
  # It runs for the container's life, so every session, exec'd ones included, can use it.
  node /etc/lyngvi/loopback.mjs 18081 lyngvi-relay 8081 &
else status relay_github off; fi
relay_route 8082 && relay_git=1
if relay_route 8083; then relay_forge=1; status relay_forge on; else status relay_forge off; fi
relay_anthropic=0; relay_route 8084 && relay_anthropic=1
# How the agent reaches the model (docs/API_KEY_MODE.md). remote-control (default): the
# claude.ai login and Remote Control. api-key: an Anthropic API key that the relay adds, so
# the agent holds no model credential at all, and no Remote Control (the CLI allows it only
# with a subscription login). Sessions are reached through tmux / docker exec instead.
MODE="${LYNGVI_MODE:-remote-control}"
API_KEY_PLACEHOLDER="sk-ant-api03-placeholder-the-lyngvi-relay-adds-the-real-key"
case "$MODE" in
  remote-control) status mode remote-control ;;
  api-key)
    if (( relay_anthropic )); then status mode api-key
    else mark API_KEY_ROUTE_MISSING crit "LYNGVI_MODE=api-key but the token relay has no Anthropic route: set LYNGVI_ANTHROPIC_API_KEY in .env (docs/API_KEY_MODE.md)"; status mode api-key-unusable; fi ;;
  *) mark MODE_UNKNOWN crit "LYNGVI_MODE=$MODE is not remote-control or api-key; running as remote-control"; MODE=remote-control; status mode remote-control ;;
esac
log "Token relay: github=$( ((relay_github)) && echo on || echo off) forge=$( ((relay_forge)) && echo on || echo off) (the agent holds no API token)"

# remove+add = idempotent: registration persists in the claude-home volume.
# Skipped without a route so sessions never see a server that can only error.
if [[ "${FORGE_KIND:-}" == "forgejo" ]] && (( relay_forge )) && [[ -d /opt/forgejo-mcp ]]; then
  claude mcp remove --scope user forgejo >/dev/null 2>&1 || true
  if claude mcp add --scope user forgejo -- /usr/local/bin/forgejo-mcp; then
    log "Registered forgejo MCP server (user scope)"; status forge_mcp registered
  else
    log "WARN: forgejo MCP registration failed"
  fi
elif [[ "${FORGE_KIND:-}" == "forgejo" ]]; then
  log "FORGE_KIND=forgejo but no relay forge route (FORGE_API_TOKEN in .env) or no server baked (WITH_FORGEJO_MCP=1) — MCP not registered"
fi
# GitHub's server goes by the relay route, not FORGE_KIND: a site whose forge is
# something else can still work on GitHub repos with GITHUB_TOKEN.
if (( relay_github )) && [[ -x /usr/local/bin/github-mcp-server ]]; then
  claude mcp remove --scope user github >/dev/null 2>&1 || true
  if claude mcp add --scope user github -- /usr/local/bin/github-mcp; then
    log "Registered github MCP server (user scope)"; status github_mcp registered
  else
    log "WARN: github MCP registration failed"
  fi
elif [[ -x /usr/local/bin/github-mcp-server ]]; then
  status github_mcp no-token
else
  claude mcp remove --scope user github >/dev/null 2>&1 || true
fi

# ── 0c. Every SSH connection tunnels through the egress proxy ────────────────
# The agent's networks have no gateway and no resolver, so ssh cannot open a
# socket to any host itself: a global ProxyCommand asks the proxy sidecar for a
# CONNECT tunnel (agent/connect.mjs), which applies the same hostname allowlist
# and port policy as HTTPS. Host-key pinning below is unchanged — ssh verifies
# the key at the far end of the tunnel. Written before the per-forge block so
# that block's Port/StrictHostKeyChecking still win for the forge host.
install -m 700 -d "$HOME/.ssh"
if [[ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]]; then
  cat > "$HOME/.ssh/config" <<SSHCFG
Host *
    ProxyCommand node /etc/lyngvi/connect.mjs %h %p
SSHCFG
  chmod 600 "$HOME/.ssh/config"
  log "Egress: every client via the proxy sidecar (HTTPS_PROXY set; ssh via connect.mjs)"; status egress proxy
  # Everything below that touches the network goes through the proxy. compose's
  # depends_on orders `up`, but the daemon restarts containers in any order after a
  # reboot or a daemon restart, so wait here (up to PROXY_WAIT seconds) rather than
  # fail the forge host key, the skills clone and the first Remote Control attempt.
  if node -e '
    const u = new URL(process.argv[1]); const net = require("net");
    const until = Date.now() + 1000 * Number(process.argv[2]);
    (function tryOnce() {
      const s = net.connect({ host: u.hostname, port: Number(u.port) || 3128 }, () => { s.destroy(); process.exit(0); });
      s.on("error", () => { s.destroy(); if (Date.now() > until) process.exit(1); setTimeout(tryOnce, 1000); });
    })();' "${HTTPS_PROXY:-${https_proxy:-}}" "${PROXY_WAIT:-60}"; then
    log "Egress: proxy reachable"; status proxy reachable
  else
    status proxy unreachable
    mark PROXY_UNREACHABLE warn "the proxy did not accept a connection within ${PROXY_WAIT:-60}s — network steps at start will fail; Remote Control keeps retrying"
  fi
else
  : > "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
  log "Egress: HTTPS_PROXY not set — clients connect directly (no egress control)"; status egress direct
fi

# ── 1. SSH keys (held by the key sidecar) + pinned forge host key ──────────
# The private keys live in the key sidecar's ssh-agent (keys/start.sh), which has no
# network and serves only its socket and the public keys on the `keys` volume. This
# container never holds a private key: it signs and pushes through the socket, so a
# compromised agent can use the key while it runs but cannot copy it out. The primary
# key is GIT_SSH_KEY_B64 (git_key); any SSH_KEY_<NAME>_B64 becomes <name>, and its
# public key is placed at ~/.ssh/<name>.pub so a site gitconfig can select it per path.
KEYS=/run/lyngvi-keys
for var in GIT_SSH_KEY_B64 FORGEJO_DEPLOY_KEY_B64 $(compgen -e | grep -E '^SSH_KEY_[A-Z0-9_]+_B64$' || true); do
  if [[ -n "${!var:-}" ]]; then
    mark KEY_IN_AGENT crit "$var is set in the agent's environment: the private key belongs to the key sidecar only; blank it in the agent service (environment: - $var=)"
  fi
done
install -m 700 -d "$HOME/.ssh"
if [[ -S "$KEYS/agent.sock" ]]; then
  export SSH_AUTH_SOCK="$KEYS/agent.sock"
  for pub in "$KEYS"/*.pub; do
    [[ -s "$pub" ]] || continue
    name=$(basename "$pub" .pub)
    install -m 644 "$pub" "$HOME/.ssh/$name.pub"
    if ssh-add -L 2>/dev/null | grep -qF "$(cut -d' ' -f1,2 "$pub")"; then
      log "SSH key $name held by the key sidecar (the agent has the public half only)"; status "key_$name" loaded
    else
      log "WARN: the key sidecar published $name.pub but its agent does not hold it"; status "key_$name" failed
    fi
  done
else
  log "WARN: no key sidecar socket at $KEYS/agent.sock — SSH git and commit signing are off (is the lyngvi-keys service in the stack?)"
  status keyagent missing
fi
if [[ -s "$HOME/.ssh/git_key.pub" ]] && grep -qx 'key_git_key=loaded' "$STATUS_FILE"; then
  # SSH-sign all commits and tags with the primary key, through the sidecar's agent. For a
  # "Verified" badge the SAME public key must be registered as a *signing key* on the
  # forge account (BOOTSTRAP.md).
  git config --global gpg.format ssh
  git config --global user.signingkey "$HOME/.ssh/git_key.pub"
  git config --global commit.gpgsign true
  git config --global tag.gpgsign true
  log "Enabled SSH commit signing (primary key)"; status signing on
  # Pin the forge's SSH host key and fail CLOSED on mismatch — no accept-new TOFU.
  # Host keys are public, so the site ships them (site/known_hosts): a fresh/reset
  # ~/.ssh then trusts the real key with no first-contact window.
  if [[ -n "${FORGE_SSH_HOST:-}" ]]; then
    port="${FORGE_SSH_PORT:-22}"
    if [[ -s "$SITE/known_hosts" ]] && grep -qE "^\[?${FORGE_SSH_HOST}\]?(:${port})? " "$SITE/known_hosts"; then
      install -m 600 "$SITE/known_hosts" "$HOME/.ssh/known_hosts_forge"
      cat >> "$HOME/.ssh/config" <<SSHCFG
Host ${FORGE_SSH_HOST}
    Port ${port}
    StrictHostKeyChecking yes
    UserKnownHostsFile ~/.ssh/known_hosts_forge
SSHCFG
      chmod 600 "$HOME/.ssh/config"
      log "Pinned host key for ${FORGE_SSH_HOST}:${port} (StrictHostKeyChecking=yes)"; status hostkey_pin "${FORGE_SSH_HOST}:${port}"
    else
      # Fail closed: an empty known_hosts + StrictHostKeyChecking=yes refuses every
      # connection, which is the correct state when the site forgot to pin.
      cat >> "$HOME/.ssh/config" <<SSHCFG
Host ${FORGE_SSH_HOST}
    Port ${port}
    StrictHostKeyChecking yes
    UserKnownHostsFile ~/.ssh/known_hosts_forge
SSHCFG
      : > "$HOME/.ssh/known_hosts_forge"; chmod 600 "$HOME/.ssh/config" "$HOME/.ssh/known_hosts_forge"
      mark SSH_HOSTKEY_MISSING crit "no entry for [${FORGE_SSH_HOST}]:${port} in site/known_hosts — SSH to the forge will be REFUSED until the site pins it"
    fi
  fi
else
  log "No SSH key in the key sidecar — SSH git push and commit signing are off"; status key_git_key none
fi

# ── 1b. Skills from a source repo (optional) ─────────────────────────────────
# Skills are pulled fresh from $SKILLS_REPO on each start (single source, no
# vendored copy). They are a snapshot of that start: the commit is recorded in
# skills/.source-sha, and the SessionStart hook reports when the source has moved. $SKILLS = space-separated skill dirs installed GLOBALLY
# into ~/.claude/skills; $PROJECT_SKILLS = "skill=repo" pairs installed into
# ~/workspace/<repo>/.claude/skills (loaded only on that checkout; kept out of
# the repo's history via .git/info/exclude). Best-effort: a first boot before
# the forge is reachable simply runs without them. shared-context/ and
# shared-hooks/ dirs in the source repo are installed too, if present.
if [[ -n "${SKILLS_REPO:-}" ]]; then
  if [[ "$SKILLS_REPO" != https://* ]] && ! ssh-add -l >/dev/null 2>&1; then
    log "SKILLS_REPO is an SSH URL but no key is loaded — skills not installed this start"
  else
    skills_tmp=$(mktemp -d)
    if git clone --depth 1 "$SKILLS_REPO" "$skills_tmp" 2>/dev/null; then
      install -m 700 -d "$CLAUDE_DIR/skills"
      # The commit this start installed from. Nothing here runs again until the
      # next start, so hooks/skills-summary.sh compares it with the source at
      # every session start and says when the installed copy has fallen behind.
      git -C "$skills_tmp" rev-parse HEAD > "$CLAUDE_DIR/skills/.source-sha" 2>/dev/null \
        || rm -f "$CLAUDE_DIR/skills/.source-sha"
      for name in ${SKILLS:-}; do
        if [[ -f "$skills_tmp/$name/SKILL.md" ]]; then
          rm -rf "$CLAUDE_DIR/skills/$name"
          cp -a "$skills_tmp/$name" "$CLAUDE_DIR/skills/$name" && log "Installed skill → skills/$name"
        else
          log "WARN: skill '$name' not found in SKILLS_REPO — skipped"
        fi
      done
      for extra in shared-context shared-hooks; do
        if [[ -d "$skills_tmp/$extra" ]]; then
          rm -rf "${CLAUDE_DIR:?}/$extra"
          cp -a "$skills_tmp/$extra" "$CLAUDE_DIR/$extra" && log "Installed $extra/ from SKILLS_REPO"
        fi
      done
      for pair in ${PROJECT_SKILLS:-}; do
        name="${pair%%=*}"; repo="${pair#*=}"
        dest="$HOME/workspace/$repo"
        if [[ ! -f "$skills_tmp/$name/SKILL.md" ]]; then
          log "WARN: project skill '$name' not found in SKILLS_REPO — skipped"
        elif [[ ! -d "$dest/.git" ]]; then
          log "Project skill '$name': no $repo checkout yet — will install on a later start"
        else
          install -m 700 -d "$dest/.claude/skills"
          rm -rf "$dest/.claude/skills/$name"
          cp -a "$skills_tmp/$name" "$dest/.claude/skills/$name"
          grep -qxF '.claude/' "$dest/.git/info/exclude" 2>/dev/null || echo '.claude/' >> "$dest/.git/info/exclude"
          log "Installed project skill → workspace/$repo/.claude/skills/$name (git-excluded)"
        fi
      done
    else
      log "WARN: could not clone SKILLS_REPO; skills not installed this start"
    fi
    rm -rf "$skills_tmp"
  fi
fi

# ── 2. git identity, DCO, HTTPS credentials, settings grants ─────────────────
# The site's values come from the site.conf baked into the image, not from the
# environment. Compose loads .env after site.conf, so a key set in both takes .env's
# value without a word: a station once committed for days under an identity left over
# in its .env, and a forge's squash merge published it as a co-author. Report any
# such override (names only), then take the identity from the file.
site_val() { sed -n "s/^$1=//p" "$SITE/site.conf" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//'; }
overridden=()
if [[ -f "$SITE/site.conf" ]]; then
  while IFS= read -r k; do
    [[ -n "${!k+x}" && "${!k}" != "$(site_val "$k")" ]] && overridden+=("$k")
  done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$SITE/site.conf" | sort -u)
fi
if (( ${#overridden[@]} )); then
  ov=$(IFS=,; echo "${overridden[*]}")
  mark SITE_CONF_OVERRIDDEN warn "the environment overrides site.conf keys: $ov (set in .env too?); each key belongs in one file"
  status site_conf_overrides "$ov"
else
  status site_conf_overrides none
fi
case ",${ov:-}," in *,GIT_AUTHOR_NAME,*|*,GIT_AUTHOR_EMAIL,*) status identity overridden ;; *) status identity site ;; esac
git config --global user.name  "$(n=$(site_val GIT_AUTHOR_NAME); echo "${n:-lyngvi}")"
git config --global user.email "$(e=$(site_val GIT_AUTHOR_EMAIL); echo "${e:-lyngvi@users.noreply.example.org}")"
# git prefers these over its config: unset them for everything this process starts
# (Remote Control sessions). A `docker exec` shell still inherits the container's env;
# the pre-commit hook refuses a commit under any identity the site did not declare.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
# Site gitconfig fragment (per-path identities via includeIf, extra options).
if [[ -s "$SITE/gitconfig" ]]; then
  git config --global include.path "$SITE/gitconfig" && log "Included site gitconfig"
fi

# The image's git hooks (agent/git-hooks/, root-owned; the home directory is a noexec
# tmpfs and a hook there would be the agent's to edit), in every repo through a global
# hooksPath: the site-identity check on author, committer and Signed-off-by; the DCO
# trailer (GIT_DCO_SIGNOFF=1, default; `format.signOff` is NOT honored by `git commit`);
# and refusing AI attribution when GIT_NO_AI_ATTRIBUTION=1. A repo-local
# core.hooksPath, or --no-verify, skips them: CI checks identities as well.
git config --global core.hooksPath /etc/lyngvi/git-hooks

# settings.json (USER scope): written FROM SCRATCH every start, never merged with what
# is already in the volume. The volume is the agent's to write, so anything read back
# from it is the agent's choice: an earlier merge-onto-volume kept an agent's
# `disableAllHooks`, `defaultMode` and extra allow rules across restarts. The policy
# that matters (hooks, MCP allowlist, no bypass mode, the grants, the site's
# settings.json) is in the managed settings above, where the agent cannot write; this
# file only carries the status line, the attribution switch and the auto-mode rule.
# A human's own /config preferences here are reset at each start — the price of a
# file the agent can write.
SETTINGS="$CLAUDE_DIR/settings.json"
# shellcheck disable=SC2016  # the JS below is a literal program, not a shell string
if node -e '
  const fs=require("fs"), path=require("path");
  const [p, noAttrib, mode, base, placeholder] = process.argv.slice(1);
  const s = {
    statusLine: { type: "command", command: "node " + path.join(path.dirname(p), "statusline-context.mjs") },
    // force-with-lease on NON-main branches only (the auto-mode classifier soft-denies
    // it otherwise; GitHub PRs need it to update an already-pushed branch after a
    // rebase). A bare --force and any force-push to main/master/trunk stay blocked.
    autoMode: { allow: ["$defaults",
      "git push --force-with-lease (and --force-with-lease=<ref>:<oid>) to a feature or PR branch that is NOT main/master/trunk: allowed. The lease refuses to overwrite unless the remote tip is exactly the commit last seen, so it cannot clobber a concurrent push. A bare git push --force (no lease) or any force-push targeting main/master/trunk remains soft-blocked."] },
  };
  // No co-author trailer, PR footer or session link (CLI 2.1.281+; the image pins newer).
  if (noAttrib==="1") s.attribution=false;
  // api-key mode: every session (tmux, docker exec) reads this file, so the model route and
  // the placeholder key live here, not in an export only this process tree would see. The
  // relay replaces the placeholder with the real key (relay/start.sh :8084).
  if (mode==="api-key") s.env = { ANTHROPIC_BASE_URL: base, ANTHROPIC_API_KEY: placeholder };
  fs.mkdirSync(path.dirname(p),{recursive:true});
  const tmp = p + ".tmp"; fs.writeFileSync(tmp, JSON.stringify(s,null,2)+"\n", {mode: 0o600}); fs.renameSync(tmp, p);
' "$SETTINGS" "$(a=$(site_val GIT_NO_AI_ATTRIBUTION); echo "${a:-0}")" "$MODE" "${LYNGVI_RELAY_ANTHROPIC:-http://lyngvi-relay:8084}" "$API_KEY_PLACEHOLDER" 2>/dev/null; then
  log "settings.json: written from the image (status line, auto-mode rule${MODE/remote-control/}); policy is in $MANAGED"; status settings written
else
  log "WARN: could not write $SETTINGS"
fi

# api-key mode: the CLI asks once before using a key from its environment, and remembers
# the answer by the key's last 20 characters. The key here is the relay's placeholder, so
# approve it up front: an attached session then starts working instead of asking.
if [[ "$MODE" == api-key ]]; then
  if node -e '
    const fs=require("fs"), p=process.argv[1], k=process.argv[2].trim().slice(-20);
    let c={}; try { c=JSON.parse(fs.readFileSync(p,"utf8")) } catch {}
    const r=c.customApiKeyResponses||{approved:[],rejected:[]};
    r.approved=[...new Set([...(r.approved||[]),k])]; r.rejected=(r.rejected||[]).filter(x=>x!==k);
    c.customApiKeyResponses=r;
    // Skip the first-run welcome and theme picker, which no RC login runs here. A chosen
    // theme is kept. The workspace-trust prompt is NOT skipped: as in remote-control mode,
    // a person accepts it once, on the first attach.
    c.hasCompletedOnboarding=true; if (!c.theme) c.theme="dark";
    fs.writeFileSync(p+".tmp",JSON.stringify(c,null,2)+"\n",{mode:0o600}); fs.renameSync(p+".tmp",p);' \
    "$CLAUDE_DIR/.claude.json" "$API_KEY_PLACEHOLDER" 2>/dev/null; then
    log "api-key mode: model calls go to the token relay with a placeholder key (the agent holds no model credential)"
  else
    log "WARN: could not pre-approve the relay placeholder key; an attached session will ask once"
  fi
fi

# HTTPS credentials. GITHUB_TOKEN = fine-grained PAT for github.com. Any
# GIT_HTTPS_CREDENTIAL_<NAME> = https://<user>:<token>@<host>/<path> is appended
# too (a second identity for one repo; pair with credential.useHttpPath=true in
# site/gitconfig). Values never touch argv or the log.
# git over HTTPS to github.com goes through the token relay, which adds the token:
# nothing about GitHub is stored here.
if (( relay_git )); then
  git config --global url."$LYNGVI_RELAY_GIT/".insteadOf "https://github.com/"
  log "git over HTTPS to github.com goes through the token relay"
fi
if compgen -e | grep -q '^GIT_HTTPS_CREDENTIAL_'; then
  git config --global credential.helper store
  umask 077
  : > "$HOME/.git-credentials"
  for var in $(compgen -e | grep -E '^GIT_HTTPS_CREDENTIAL_[A-Z0-9_]+$' || true); do
    printf '%s\n' "${!var}" >> "$HOME/.git-credentials"
  done
  chmod 600 "$HOME/.git-credentials"
  log "Configured HTTPS credential helper ($(wc -l < "$HOME/.git-credentials") entries)"
elif (( ! relay_git )); then
  log "No GitHub route in the token relay — HTTPS git push to GitHub disabled"
fi

# Decoy credentials (DESIGN.md §10). Each decoy names a per-install hostname that the
# proxy generated and never allows. A process that harvests one and uses it is refused,
# and the proxy, in its own container, raises CANARY_TOUCHED. They go only where a
# credential hunter looks and no tool connects on its own: a netrc machine, a
# git-credentials line, and an ssh Host alias with a key of its own. Values are fresh
# at every start. CANARIES=0 (site.conf) turns them off; the cleanup below runs either way.
CANARY_LIST=/etc/lyngvi/canary/hosts
rm -f "$HOME/.netrc" "$HOME"/.ssh/id_deploy_*
[[ -f "$HOME/.git-credentials" ]] && sed -i '/^https:\/\/ci-bot:/d' "$HOME/.git-credentials"
if [[ "${CANARIES:-1}" == "0" ]]; then
  log "Decoy credentials off (CANARIES=0)"; status canaries off
elif [[ ! -s "$CANARY_LIST" ]]; then
  log "Decoy credentials unavailable: no $CANARY_LIST (the canary volume is not mounted)"; status canaries unavailable
else
  mapfile -t ch < <(grep -E '^[a-z0-9.-]+$' "$CANARY_LIST" | head -n 3)
  if (( ${#ch[@]} == 3 )); then
    tok() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
    umask 077
    printf 'machine %s\n  login deploy\n  password %s\n' "${ch[0]}" "$(tok 20)" > "$HOME/.netrc"
    printf 'https://ci-bot:%s@%s\n' "$(tok 20)" "${ch[2]}" >> "$HOME/.git-credentials"
    k="$HOME/.ssh/id_deploy_$(tok 3)"
    ssh-keygen -q -t ed25519 -N '' -C "deploy@${ch[1]%%.*}" -f "$k" </dev/null >/dev/null 2>&1
    cat >> "$HOME/.ssh/config" <<SSHCFG
Host ${ch[1]%%.*}
    HostName ${ch[1]}
    User git
    IdentityFile $k
SSHCFG
    chmod 600 "$HOME/.netrc" "$HOME/.git-credentials" "$HOME/.ssh/config"
    log "Decoy credentials planted"; status canaries planted
  else
    log "Decoy credentials unavailable: $CANARY_LIST is malformed"; status canaries unavailable
  fi
fi

# ── 2b. claude.ai credential-health watchdog ─────────────────────────────────
# A WARM token death (a failed refresh wiping the credential; the single-use
# refresh-token rotation race between processes sharing .credentials.json —
# anthropics/claude-code#29896 and anthropics/claude-code#24317) leaves RC connected while every session
# 401s; the exit-based RC_REGISTER_FAIL marker never fires because RC never
# exits. Poll .credentials.json METADATA only (expiry timestamps + refresh-token
# presence — never values). Expired/near-expiry with NO refresh token is terminal
# (needs interactive /login): emit `RC_TOKEN_STALE sev=crit`, re-emitted every
# interval until a human re-logs in. The refresh token also carries its OWN hard
# expiry (`refreshTokenExpiresAt`, ~30 days after login; rotation does NOT extend
# it), so page BEFORE it: `RC_TOKEN_EXPIRING sev=warn` inside RC_REFRESH_WARN,
# `sev=crit` inside RC_REFRESH_CRIT. A missing file (fresh volume) is skipped.
CREDS_FILE="$CLAUDE_DIR/.credentials.json"
RC_TOKEN_WATCH_INTERVAL=${RC_TOKEN_WATCH_INTERVAL:-300}  # keep under your log-alert window
RC_TOKEN_GRACE=${RC_TOKEN_GRACE:-1800}
RC_REFRESH_WARN=${RC_REFRESH_WARN:-172800}               # 48h
RC_REFRESH_CRIT=${RC_REFRESH_CRIT:-43200}                # 12h
[[ "$MODE" == api-key ]] || (
  while true; do
    sleep "$RC_TOKEN_WATCH_INTERVAL"
    [[ -f "$CREDS_FILE" ]] || continue
    state=$(node -e '
      try {
        const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).claudeAiOauth;
        if (!o) process.exit(0);
        const [grace, warn, crit] = process.argv.slice(2).map(Number);
        const now = Date.now();
        const left = Math.floor(((o.expiresAt || 0) - now) / 1000);
        const hasRefresh = typeof o.refreshToken === "string" && o.refreshToken.length > 0;
        if (left < grace && !hasRefresh) {
          console.log("STALE access_token=" + (o.expiresAt ? "expires_in=" + left + "s" : "unset") + " refresh_token=absent");
          process.exit(0);
        }
        if (hasRefresh && o.refreshTokenExpiresAt) {
          const rleft = Math.floor((o.refreshTokenExpiresAt - now) / 1000);
          const detail = "refresh_token_expires=" + new Date(o.refreshTokenExpiresAt).toISOString()
            + " in=" + (rleft / 3600).toFixed(1) + "h";
          if (rleft < crit) console.log("EXPIRING crit " + detail);
          else if (rleft < warn) console.log("EXPIRING warn " + detail);
        }
      } catch (e) { /* unreadable mid-write: skip this tick */ }
    ' "$CREDS_FILE" "$RC_TOKEN_GRACE" "$RC_REFRESH_WARN" "$RC_REFRESH_CRIT" 2>/dev/null)
    case "$state" in
      STALE*)
        mark RC_TOKEN_STALE crit "claude.ai OAuth credential is unrecoverable (${state#STALE }) — sessions will 401 and this will NOT self-recover. Run: docker exec -it $CN claude /login" ;;
      "EXPIRING crit "*)
        mark RC_TOKEN_EXPIRING crit "claude.ai refresh token expires within $(( RC_REFRESH_CRIT / 3600 ))h (${state#EXPIRING crit }) — rotation does not extend it and the next refresh past that point WIPES the credential. Re-login now: docker exec -it $CN claude /login" ;;
      "EXPIRING warn "*)
        mark RC_TOKEN_EXPIRING warn "claude.ai refresh token expires within $(( RC_REFRESH_WARN / 3600 ))h (${state#EXPIRING warn }) — schedule the monthly interactive re-login before then: docker exec -it $CN claude /login" ;;
    esac
  done
) &
[[ "$MODE" == api-key ]] || log "Started credential-health watchdog (interval=${RC_TOKEN_WATCH_INTERVAL}s grace=${RC_TOKEN_GRACE}s refresh_warn=${RC_REFRESH_WARN}s refresh_crit=${RC_REFRESH_CRIT}s)"

# ── 2c. workspace settings scan (DESIGN.md §4.5) ──────────────────────────────
# The ConfigChange hook sees only the running session's own project. A permission rule an
# interpreter writes into ANOTHER workspace repository, or anything written between
# sessions, reaches this scan instead: the same comparison and record as the hook, so
# CONFIG_CHANGED fires once per rule whichever path sees it first. Both modes.
LYNGVI_CONFIG_SCAN_INTERVAL=${LYNGVI_CONFIG_SCAN_INTERVAL:-60}
if [[ "$LYNGVI_CONFIG_SCAN_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
  (
    while true; do
      /etc/lyngvi/hooks/config-change.sh --scan "$HOME/workspace" </dev/null >/dev/null 2>&1 || true
      sleep "$LYNGVI_CONFIG_SCAN_INTERVAL"
    done
  ) &
  log "Started workspace settings scan (interval=${LYNGVI_CONFIG_SCAN_INTERVAL}s): a new allow rule, hook, defaultMode or additionalDirectories in any workspace repository raises CONFIG_CHANGED"
  status config_scan "${LYNGVI_CONFIG_SCAN_INTERVAL}s"
else
  log "Workspace settings scan OFF (LYNGVI_CONFIG_SCAN_INTERVAL=${LYNGVI_CONFIG_SCAN_INTERVAL}); only the in-session ConfigChange hook reports new rules"
  status config_scan off
fi
if [[ -n "${NOTIFY_URL:-}${NOTIFY_CMD:-}" ]]; then
  log "Notifications: markers at or above sev=${NOTIFY_MIN_SEV:-warn} are pushed${NOTIFY_URL:+ via ${NOTIFY_KIND:-ntfy}}${NOTIFY_CMD:+ and NOTIFY_CMD}, repeats throttled to every ${NOTIFY_REPEAT:-21600}s (test: docker exec $CN notify --test)"
else
  log "Notifications: not configured — markers reach this log only (site.conf NOTIFY_URL / NOTIFY_CMD to page a human)"
fi

# ── 3. tmux shell for humans + RC supervisor loop as PID1 ─────────────────────
tmux new-session -d -s shell 2>/dev/null && log "Started detached tmux 'shell' (docker exec -it $CN tmux attach -t shell)" || true

# api-key mode: no Remote Control (the CLI allows it only with a subscription login). Keep
# an interactive `claude` in a tmux session instead, recreated if a human exits it, and
# stay PID 1. Attach: docker exec -it $CN tmux attach -t claude
if [[ "$MODE" == api-key ]]; then
  log "api-key mode: no Remote Control; Claude Code runs in tmux session 'claude' (docker exec -it $CN tmux attach -t claude)"
  status supervisor api-key
  while true; do
    tmux has-session -t claude 2>/dev/null || tmux new-session -d -s claude -c "$HOME/workspace" claude 2>/dev/null || true
    sleep 10
  done
fi

rc_args=(--name "${RC_NAME:-lyngvi}")
[[ -n "${RC_CAPACITY:-}" ]] && rc_args+=(--capacity "${RC_CAPACITY}")

# `claude remote-control` (server mode) prints an interactive "Enable Remote
# Control? (y/n)" consent and reads the answer from stdin. Headless (no TTY) it
# would EOF and exit, so we feed 'y' via a FIFO and keep the write end open
# (sleep infinity) so stdin never closes. The writer is tracked and killed each
# iteration — no process leak.
CONSENT=/tmp/rc-consent
[[ -p "$CONSENT" ]] || mkfifo "$CONSENT"
AUTHFLAG=/tmp/rc-authfail

# A cold start into a 401 OAuth loop (a lapsed single-use refresh token after a
# container recreate) NEVER self-recovers — it needs an interactive `claude
# /login`. Those exits are fast, so they'd otherwise fall into the benign "login
# needed" branch below and stay silent. Count consecutive fast auth-failure exits
# and, past the threshold, emit an `RC_REGISTER_FAIL sev=crit` marker so a
# generic log-alert rule pages within a minute; re-emit on a throttle.
authfail_streak=0
RC_AUTHFAIL_THRESHOLD=${RC_AUTHFAIL_THRESHOLD:-3}
RC_AUTHFAIL_REALERT=${RC_AUTHFAIL_REALERT:-60}
RC_AUTHFAIL_WINDOW=${RC_AUTHFAIL_WINDOW:-600}

log "Starting Claude Code Remote Control supervisor (name=${RC_NAME:-lyngvi} capacity=${RC_CAPACITY:-default})"
status supervisor started
while true; do
  ( exec 9>"$CONSENT"; printf 'y\n' >&9; sleep infinity ) &   # holds stdin open + answers consent
  writer=$!
  rc_start=$SECONDS
  rm -f "$AUTHFLAG"
  # Stream RC output to the container log only during the startup window (that's
  # where the diagnostic value is: login prompts, session URLs, fast-exit errors)
  # — after it, the TUI's steady-state redraws are hundreds of thousands of log
  # lines a day. Auth-failure lines always pass (and flag: bounded — touches a
  # file, stores no output). Live TUI inspection any time: tmux attach.
  # In-run auth-failure counting: a warm token death surfaces as auth-failure
  # lines while RC keeps RUNNING, so the post-exit streak logic never sees it.
  authfail_lines=0 authfail_win=0
  claude remote-control "${rc_args[@]}" < "$CONSENT" 2>&1 | while IFS= read -r line; do
    case "$line" in
      *[Aa]uthentication\ failed*|*"use /login"*|*[Ii]nvalid\ refresh\ token*)
        printf '%s\n' "$line"; : >"$AUTHFLAG"
        (( SECONDS - authfail_win > RC_AUTHFAIL_WINDOW )) && { authfail_lines=0; authfail_win=$SECONDS; }
        authfail_lines=$(( authfail_lines + 1 ))
        if (( authfail_lines == RC_AUTHFAIL_THRESHOLD )); then
          mark RC_REGISTER_FAIL crit "${authfail_lines} auth failures within ${RC_AUTHFAIL_WINDOW}s while remote-control is RUNNING — warm credential death, will not self-recover. Run: docker exec -it $CN claude /login"
        fi
        continue ;;
    esac
    (( SECONDS - rc_start < ${RC_LOG_WINDOW:-60} )) && printf '%s\n' "$line"
  done || true
  rc_ran=$(( SECONDS - rc_start ))
  kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
  # The healthcheck is liveness-only and can read `healthy` across this relaunch
  # window, so a relay DROP is otherwise silent. A drop AFTER the relay was up is
  # the alert-worthy case: emit the `sev=warn` marker.
  if (( rc_ran >= 30 )); then
    authfail_streak=0
    mark RC_RELAY_DROP warn "remote-control dropped after ${rc_ran}s (>10min outage or crash). Retrying in 5s…"
  elif [[ -e "$AUTHFLAG" ]]; then
    authfail_streak=$(( authfail_streak + 1 ))
    if (( authfail_streak == RC_AUTHFAIL_THRESHOLD )) || \
       (( authfail_streak > RC_AUTHFAIL_THRESHOLD && authfail_streak % RC_AUTHFAIL_REALERT == 0 )); then
      mark RC_REGISTER_FAIL crit "remote-control OAuth registration failing (${authfail_streak} consecutive 401/auth exits) — will not self-recover. Run: docker exec -it $CN claude /login. Retrying in 5s…"
    else
      log "remote-control exited after ${rc_ran}s (OAuth auth failure #${authfail_streak}; /login needed). Retrying in 5s…"
    fi
  else
    # Benign fast exit: first-run login-needed / config loop before any credentials.
    authfail_streak=0
    log "remote-control exited after ${rc_ran}s (login needed / config). Retrying in 5s…"
  fi
  sleep 5
done

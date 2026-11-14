#!/usr/bin/env bash
# smoke.sh — start the stack with the example site values and a THROWAWAY SSH key
# generated on the spot (never a real secret), and prove the mechanical claims CI
# can prove. Used by .github/workflows/ci.yml and locally.
#
#   1. the agent reaches its supervisor loop ("login needed" — expected without a login)
#   2. the policy (hooks, MCP allowlist, no bypass mode, grants) is managed settings the agent
#      cannot write, its own settings.json does not survive a restart, and the operating
#      context was installed
#   3. with a key present: it is loaded into the agent, every commit is SSH-signed and
#      carries the DCO trailer, and the forge host key is pinned with
#      StrictHostKeyChecking=yes (a real commit is made and verified in the container)
#   4. the proxy sidecar is up and default-deny BY HOSTNAME: example.com → 403, pypi.org → 200
#   5. the egress layout: the agent has no default route and no resolver, its bridges
#      carry no host address, and git over HTTPS and ssh (ProxyCommand) reach GitHub
#      only through the proxy tunnel
#
# The workspace settings scan runs every 3 s here (default 60) so its check is quick.
# The key reaches the stack through a temporary secrets file (the one compose loads
# with required: false), which this script refuses to create if one already exists
# and removes on exit. Leaves the stack running when KEEP=1; otherwise tears it
# down (including volumes).
set -euo pipefail
cd "$(dirname "$0")/.."
secrets_file=".env"
[[ -e "$secrets_file" ]] && { echo "refusing to run: a secrets file already exists here (this script writes a throwaway one)"; exit 1; }

keydir=$(mktemp -d)
cleanup() {
  [[ "${KEEP:-0}" == "1" ]] || docker compose down -v >/dev/null 2>&1 || true
  rm -f "$secrets_file"; rm -rf "$keydir"
}
trap cleanup EXIT

# wait_log <container> <ERE> [seconds]: true once the container's log matches. A marker
# reaches the log through the logging driver, which can lag a slow runner (rootless CI),
# so poll rather than sleep a fixed second.
wait_log() {
  local i
  for ((i = 0; i < ${3:-15}; i++)); do
    docker logs "$1" 2>&1 | grep -qE "$2" && return 0
    sleep 1
  done
  return 1
}

# Ephemeral ed25519 key: exists only for this run, never leaves this machine.
ssh-keygen -q -t ed25519 -N '' -C 'smoke throwaway' -f "$keydir/key"
# A fake GitHub token too, so the token relay builds its GitHub routes: GitHub answers
# it with 401, which is how the smoke proves the relay added it (and it is worthless).
( umask 077; printf 'GIT_SSH_KEY_B64=%s\nGITHUB_TOKEN=ci-fake-relay-token\nLYNGVI_ANTHROPIC_API_KEY=sk-ant-api03-ci-fake-relay-key\nLYNGVI_CONFIG_SCAN_INTERVAL=3\n' "$(base64 -w0 < "$keydir/key")" > "$secrets_file" )

docker compose up -d

echo "== waiting for the supervisor loop"
ok=0
for _ in $(seq 1 40); do
  if docker compose logs lyngvi 2>/dev/null | grep -q 'remote-control exited after .* (login needed'; then ok=1; break; fi
  sleep 2
done
if (( ! ok )); then echo "FAIL: supervisor loop not reached"; docker compose logs lyngvi | tail -40; exit 1; fi
echo "ok: supervisor loop reached"

echo "== entrypoint log"
docker compose logs lyngvi 2>/dev/null | grep -oE '\[entrypoint [0-9:]+\] .*' | cut -c22- | head -24

echo "== settings: policy is managed, the volume cannot carry it"
docker exec lyngvi node -e '
  const fs=require("fs"), M="/etc/claude-code/managed-settings.json";
  const m=JSON.parse(fs.readFileSync(M,"utf8"));
  const fail=(x)=>{ console.log("FAIL: "+x); process.exit(1); };
  if (fs.statSync(M).uid!==0) fail("managed settings not root-owned");
  try { fs.accessSync(M, fs.constants.W_OK); fail("managed settings writable by the agent"); } catch (e) { if (e.code!=="EACCES") throw e; }
  if (m.allowManagedHooksOnly!==true || m.disableBypassPermissionsMode!=="disable") fail("hook/bypass policy missing");
  for (const k of ["PreToolUse","PostToolUse","SessionStart","ConfigChange"]) if (!m.hooks?.[k]?.[0]?.hooks?.[0]?.command.startsWith("/etc/lyngvi/hooks/")) fail("hook "+k+" not wired to the image");
  if (!m.permissions.allow.some(r=>r.startsWith("Bash(git push"))) fail("git push grant missing");
  console.log("ok: managed settings — hooks:", Object.keys(m.hooks).join(","), "| allow rules:", m.permissions.allow.length, "| MCP allowlist:", m.allowedMcpServers.length);'
docker exec lyngvi sh -c 'test -x /etc/lyngvi/hooks/redact-tool-output.sh && test -x /etc/lyngvi/hooks/block-secret-dumps.sh && ! test -w /etc/lyngvi/hooks/block-secret-dumps.sh && echo "ok: hooks run from the image, read-only to the agent"'
# The ConfigChange hook, run as the agent with a synthetic event: a new allow rule must put
# a CONFIG_CHANGED marker in the CONTAINER log (PID 1's stdout). The CLI's file watcher
# needs a logged-in session, so the event itself is not provable here. The file sits
# outside ~/workspace so the workspace scan cannot record it first.
docker exec lyngvi sh -c 'mkdir -p ~/.cache/smoke-cc/.claude && printf "%s" "{\"permissions\":{\"allow\":[\"Bash(echo smoke-cc)\"]}}" > ~/.cache/smoke-cc/.claude/settings.local.json && printf "%s" "{\"hook_event_name\":\"ConfigChange\",\"source\":\"local_settings\",\"file_path\":\"$HOME/.cache/smoke-cc/.claude/settings.local.json\"}" | /etc/lyngvi/hooks/config-change.sh | grep -q "Bash(echo smoke-cc)"' \
  || { echo "FAIL: config-change hook gave no message for a new allow rule"; exit 1; }
wait_log lyngvi 'CONFIG_CHANGED sev=warn local_settings .*Bash\(echo smoke-cc\)' \
  || { echo "FAIL: CONFIG_CHANGED marker did not reach the container log"; exit 1; }
docker exec lyngvi rm -rf /home/claude/.cache/smoke-cc
echo "ok: a new allow rule raises CONFIG_CHANGED sev=warn in the container log (ConfigChange hook)"
# The workspace scan (tmatens/lyngvi#78): an INTERPRETER writes a rule into a workspace
# repository no session is running in. No hook event fires; the scan must report it
# within one interval.
docker exec lyngvi python3 -c 'import os,json; d=os.path.expanduser("~/workspace/smoke-scan/.claude"); os.makedirs(d,exist_ok=True); open(d+"/settings.local.json","w").write(json.dumps({"permissions":{"allow":["Bash(echo smoke-scan)"]}}))'
wait_log lyngvi 'CONFIG_CHANGED sev=warn local_settings .*Bash\(echo smoke-scan\).*\(workspace scan\)' 20 \
  || { echo "FAIL: the workspace scan did not report a rule written into another repository"; exit 1; }
docker exec lyngvi rm -rf /home/claude/workspace/smoke-scan
echo "ok: a rule an interpreter writes into another workspace repository raises CONFIG_CHANGED (workspace scan)"
# A crash in the PreToolUse hook lets the command through (fail open) and must say so in
# the container log, naming the exception type and never the input.
docker exec lyngvi sh -c 'printf "%s" "[\"smoke-hook-error\"]" | /etc/lyngvi/hooks/block-secret-dumps.sh 2>/dev/null' \
  || { echo "FAIL: block-secret-dumps did not fail open on a crash"; exit 1; }
wait_log lyngvi 'HOOK_ERROR sev=warn block-secret-dumps crashed \(AttributeError\)' \
  || { echo "FAIL: no HOOK_ERROR marker in the container log after a hook crash"; exit 1; }
docker compose logs lyngvi 2>/dev/null | grep -q 'smoke-hook-error' && { echo "FAIL: HOOK_ERROR quoted the hook's input"; exit 1; }
echo "ok: a block-hook crash fails open and raises HOOK_ERROR sev=warn"
# Regression: what the agent writes into its own settings.json must not survive a
# restart (it once did: the entrypoint merged onto the volume).
docker exec lyngvi node -e '
  const fs=require("fs"), p=process.env.CLAUDE_CONFIG_DIR+"/settings.json";
  fs.writeFileSync(p, JSON.stringify({disableAllHooks:true, permissions:{defaultMode:"bypassPermissions", allow:["Bash(*)"]},
    hooks:{SessionStart:[{hooks:[{type:"command",command:"/bin/true # block-secret-dumps.sh"}]}]}}));'
docker restart lyngvi >/dev/null
for _ in $(seq 1 30); do docker exec lyngvi test -s /tmp/lyngvi-status 2>/dev/null && docker exec lyngvi grep -q '^settings=' /tmp/lyngvi-status 2>/dev/null && break; sleep 1; done
docker exec lyngvi node -e '
  const s=require(process.env.CLAUDE_CONFIG_DIR+"/settings.json");
  const left=["disableAllHooks","permissions","hooks"].filter(k=>k in s);
  if (left.length) { console.log("FAIL: agent-written settings survived a restart: "+left.join(",")); process.exit(1); }
  console.log("ok: agent-written settings (disableAllHooks, bypass mode, Bash(*), a hook) did not survive a restart");'
docker exec lyngvi sh -c 'grep -q "Site-specific operating context" ~/.claude/CLAUDE.md && echo "ok: operating context = upstream + site"'
docker exec lyngvi sh -c 'command -v gitleaks >/dev/null && echo "ok: gitleaks baked"'

echo "== key, signing, DCO, host-key pinning (ephemeral key)"
log=$(docker compose logs lyngvi 2>/dev/null)
grep -q 'SSH key git_key held by the key sidecar' <<<"$log" || { echo "FAIL: key not held by the key sidecar"; exit 1; }
[[ "$(docker inspect --format '{{.HostConfig.NetworkMode}}' lyngvi-keys)" == none ]] || { echo "FAIL: the key sidecar has a network"; exit 1; }
grep -q 'Enabled SSH commit signing'  <<<"$log"          || { echo "FAIL: signing not enabled"; exit 1; }
grep -q 'Pinned host key for git.example.internal:22' <<<"$log" || { echo "FAIL: host key not pinned"; exit 1; }
grep -q 'SSH_HOSTKEY_MISSING' <<<"$log" && { echo "FAIL: pinning reported missing"; exit 1; }
docker exec lyngvi sh -c '
  set -e
  export SSH_AUTH_SOCK=/run/lyngvi-keys/agent.sock; [ -S "$SSH_AUTH_SOCK" ] || { echo "FAIL: no key sidecar socket"; exit 1; }
  n=$(ssh-add -l | grep -c "smoke throwaway"); [ "$n" = 1 ] || { echo "FAIL: the sidecar agent does not hold the key"; exit 1; }
  ! test -e ~/.ssh/git_key || { echo "FAIL: a private key file is in the agent container"; exit 1; }
  [ "$(tr "\0" "\n" < /proc/1/environ | grep -cE "^(GIT_SSH_KEY|SSH_KEY_[A-Z0-9_]+)_B64=.")" = 0 ] || { echo "FAIL: a private key is in the agent environment"; exit 1; }
  # The only private key the agent may hold is the decoy (id_deploy_*), registered nowhere.
  grep -rqs --exclude="id_deploy_*" "PRIVATE KEY" ~/.ssh /run/lyngvi-keys && { echo "FAIL: private key material visible to the agent"; exit 1; }
  [ "$(git config --global gpg.format)" = ssh ] && [ "$(git config --global commit.gpgsign)" = true ] && [ "$(git config --global tag.gpgsign)" = true ] || { echo "FAIL: signing config"; exit 1; }
  grep -q "^Host git.example.internal$" ~/.ssh/config && grep -q "StrictHostKeyChecking yes" ~/.ssh/config || { echo "FAIL: ssh config"; exit 1; }
  grep -q "^\[git.example.internal\]:22 ssh-ed25519 " ~/.ssh/known_hosts_forge || { echo "FAIL: known_hosts_forge"; exit 1; }
  [ "$(stat -c %a ~/.ssh/known_hosts_forge)" = 600 ] || { echo "FAIL: known_hosts mode"; exit 1; }
  # A real commit: signed with the key, DCO trailer added by the global hook, and
  # verifiable against the key itself (allowed_signers built from the derived .pub).
  d=$(mktemp -d ~/smoke.XXXXXX); cd "$d"; git init -q; echo x > f; git add f
  git commit -q -m "smoke: signed + DCO"
  git log -1 --format=%B | grep -q "^Signed-off-by: lyngvi <lyngvi@users.noreply.example.org>$" || { echo "FAIL: DCO trailer missing"; exit 1; }
  git cat-file commit HEAD | grep -q "^gpgsig " || { echo "FAIL: commit not signed"; exit 1; }
  printf "%s %s\n" "$(git config --global user.email)" "$(cut -d" " -f1,2 ~/.ssh/git_key.pub)" > "$d/allowed_signers"
  git -c gpg.ssh.allowedSignersFile="$d/allowed_signers" verify-commit HEAD 2>&1 | grep -q "Good \"git\" signature" || { echo "FAIL: signature does not verify"; exit 1; }
  # The site identity is enforced: an override in the environment, a foreign
  # sign-off, or (under GIT_NO_AI_ATTRIBUTION=1) attribution lines are refused.
  echo y >> f; git add f
  if GIT_AUTHOR_EMAIL=someone@example.org git commit -q -m "smoke: foreign author" 2>/dev/null; then echo "FAIL: a commit under a foreign author identity was accepted"; exit 1; fi
  if GIT_COMMITTER_NAME=other git commit -q -m "smoke: foreign committer" 2>/dev/null; then echo "FAIL: a commit under a foreign committer identity was accepted"; exit 1; fi
  if git commit -q -m "smoke: foreign sign-off" -m "Signed-off-by: Other Person <other@example.org>" 2>/dev/null; then echo "FAIL: a foreign Signed-off-by was accepted"; exit 1; fi
  git commit -q -m "smoke: own identity" || { echo "FAIL: a commit under the site identity was refused"; exit 1; }
  cd ~; rm -rf "$d"
  echo "ok: key held by the key sidecar (no network; agent has the public half only), SSH signing + DCO on a real commit, signature verifies, forge host key pinned fail-closed; foreign author, committer and sign-off refused"'
if ! docker exec lyngvi grep -qx "identity=site" /tmp/lyngvi-status || ! docker exec lyngvi grep -qx "site_conf_overrides=none" /tmp/lyngvi-status; then
  echo "FAIL: the example site has a site.conf key overridden by the environment"; exit 1
fi
echo "ok: git identity from site.conf; nothing in the environment overrides a site.conf key"

echo "== proxy"
status=$(docker inspect --format '{{.State.Health.Status}}' lyngvi-proxy)
[[ "$status" == "healthy" || "$status" == "starting" ]] || { echo "FAIL: proxy health = $status"; exit 1; }
probe() { # $1 = host; prints the proxy's CONNECT status line
  docker run --rm --network lyngvi-proxy-net --entrypoint node lyngvi-lyngvi -e '
    const net=require("net"); const host=process.argv[1];
    const s=net.connect(3128,"lyngvi-proxy",()=>s.write("CONNECT "+host+":443 HTTP/1.1\r\nHost: "+host+":443\r\n\r\n"));
    s.once("data",d=>{console.log(d.toString().split("\r\n")[0]); s.destroy();});
    s.on("error",e=>{console.log("ERR "+e.code); process.exit(1)});' "$1"
}
allowed=$(probe pypi.org); denied=$(probe example.com)
echo "pypi.org    -> $allowed"
echo "example.com -> $denied"
grep -q ' 200 ' <<<"$allowed" || { echo "FAIL: pypi.org should be allowed through the proxy"; exit 1; }
grep -q ' 403 ' <<<"$denied"  || { echo "FAIL: example.com should be filtered by the proxy"; exit 1; }
echo "ok: proxy is default-deny by hostname"

echo "== read-only root filesystem"
[[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' lyngvi)" == true ]] || { echo "FAIL: root filesystem is not read-only"; exit 1; }
docker exec lyngvi sh -c 'touch /usr/local/x 2>/dev/null || touch /x 2>/dev/null' && { echo "FAIL: wrote outside the volumes and tmpfs"; exit 1; }
docker exec lyngvi sh -c 'test -w ~/.cache && test -w ~/workspace && test -w ~/.claude' || { echo "FAIL: a volume is not writable by the agent"; exit 1; }
echo "ok: root filesystem read-only; the volumes and the home tmpfs are writable"

echo "== temp dir"
# TMPDIR must be on the workspace volume (exec-capable, roomy) and empty at start; the
# CLI's own temp files stay on the per-run /tmp tmpfs.
docker exec lyngvi grep -qx 'tmpdir=/home/claude/workspace/.tmp' /tmp/lyngvi-status || { echo "FAIL: entrypoint did not set up TMPDIR"; exit 1; }
docker exec lyngvi sh -c 'test "$CLAUDE_CODE_TMPDIR" = /tmp && f=$(mktemp) && case "$f" in "$HOME"/workspace/.tmp/*) ;; *) exit 1;; esac && printf "#!/bin/sh\necho ran\n" > "$f" && chmod +x "$f" && "$f" | grep -qx ran && rm "$f"' \
  || { echo "FAIL: TMPDIR is not an exec-capable dir on the workspace volume"; exit 1; }
echo "ok: TMPDIR on the workspace volume, exec works; CLI temp on /tmp"

echo "== decoy credentials"
docker exec lyngvi grep -qx 'canaries=planted' /tmp/lyngvi-status || { echo "FAIL: decoy credentials not planted"; exit 1; }
docker exec lyngvi sh -c 'test -s ~/.netrc && grep -q "^https://ci-bot:" ~/.git-credentials && grep -q "^Host " ~/.ssh/config && ls ~/.ssh/id_deploy_* >/dev/null' \
  || { echo "FAIL: a decoy is missing (netrc, git-credentials line, ssh Host + key)"; exit 1; }
# Use one the way a harvester would: the git-credentials host, through the proxy. The
# refusal must raise CANARY_TOUCHED in the PROXY's log, which the agent cannot write.
ch=$(docker exec lyngvi sh -c 'sed -n "s#^https://ci-bot:[^@]*@##p" ~/.git-credentials')
[[ "$ch" =~ ^[a-z0-9.-]+\.internal$ ]] || { echo "FAIL: decoy host has an unexpected shape"; exit 1; }
used=$(probe "$ch")
grep -q ' 403 ' <<<"$used" || { echo "FAIL: the decoy host should be refused by the proxy: $used"; exit 1; }
wait_log lyngvi-proxy "CANARY_TOUCHED sev=crit host=${ch//./\\.}" \
  || { echo "FAIL: no CANARY_TOUCHED in the proxy log after a decoy was used"; exit 1; }
docker logs lyngvi 2>&1 | grep -q 'CANARY_TOUCHED' && { echo "FAIL: CANARY_TOUCHED must come from the proxy, not the agent"; exit 1; }
echo "ok: decoys planted; using one raises CANARY_TOUCHED sev=crit in the proxy's own log"
# That touch was deliberate. Recreate the proxy so its log starts clean, as an operator's
# rebuild would (docs/INCIDENT.md); otherwise the doctor run that follows a smoke in CI
# reports it. The decoy names live in the volume and survive.
docker compose up -d --force-recreate --no-deps lyngvi-proxy >/dev/null 2>&1
for _ in $(seq 1 30); do [[ "$(docker inspect --format '{{.State.Health.Status}}' lyngvi-proxy)" == healthy ]] && break; sleep 1; done
[[ "$(docker inspect --format '{{.State.Health.Status}}' lyngvi-proxy)" == healthy ]] || { echo "FAIL: proxy not healthy after recreate"; exit 1; }
docker logs lyngvi-proxy 2>&1 | grep -q CANARY_TOUCHED && { echo "FAIL: recreated proxy still reports the touch"; exit 1; }

echo "== egress layout (DESIGN.md §4.2): no route, no resolver, no host address, proxy only"
docker exec lyngvi sh -c 'awk "NR>1 && \$2==\"00000000\"" /proc/net/route | grep -q . && { echo "FAIL: the agent has a default route"; exit 1; }; echo "ok: no default route"'
docker exec lyngvi sh -c 'if getent hosts example.com >/dev/null 2>&1; then echo "FAIL: the agent can resolve names (a resolver path exists)"; exit 1; fi; echo "ok: no resolver path (names resolve only at the proxy)"'
for n in lyngvi-net lyngvi-proxy-net; do
  id=$(docker network inspect --format '{{.Id}}' "$n" | cut -c1-12)
  if [[ -n "$(ip -4 -o addr show "br-$id" 2>/dev/null)" ]]; then echo "FAIL: bridge of $n carries a host address"; exit 1; fi
  [[ "$(docker network inspect --format '{{.Internal}}' "$n")" == true ]] || { echo "FAIL: $n is not internal"; exit 1; }
done
echo "ok: both agent bridges are internal and carry no host address"
docker exec lyngvi sh -c 'grep -q "^Host \*$" ~/.ssh/config && grep -q "ProxyCommand node /etc/lyngvi/connect.mjs" ~/.ssh/config' || { echo "FAIL: ssh ProxyCommand not configured"; exit 1; }
# Without the global config (and so without the relay's insteadOf): anonymous, straight
# through the proxy.
docker exec -e GIT_CONFIG_GLOBAL=/dev/null lyngvi git ls-remote --exit-code https://github.com/git/git.git HEAD >/dev/null 2>&1 || { echo "FAIL: git over HTTPS through the proxy"; exit 1; }
echo "ok: git over HTTPS reaches github.com through the proxy"

echo "== token relay (DESIGN.md §4.3)"
# A `docker exec` session (the documented interactive path) must see the same routes and
# key socket as Remote Control sessions: they are image environment, not entrypoint exports.
docker exec lyngvi sh -c 'test "$LYNGVI_RELAY_GITHUB" = http://lyngvi-relay:8081 && test "$SSH_AUTH_SOCK" = /run/lyngvi-keys/agent.sock && ssh-add -l >/dev/null' \
  || { echo "FAIL: a docker exec session does not see the relay routes or the key socket"; exit 1; }
[[ "$(docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' lyngvi-relay)" == "lyngvi-proxy-net " ]] || { echo "FAIL: the relay is on a network other than lyngvi-proxy-net"; exit 1; }
docker exec lyngvi grep -qx 'relay_github=on' /tmp/lyngvi-status || { echo "FAIL: the agent found no GitHub route in the relay"; exit 1; }
[ "$(docker exec lyngvi sh -c 'tr "\0" "\n" < /proc/1/environ | grep -cE "^(GITHUB_TOKEN|FORGE_API_TOKEN)=."')" = 0 ] || { echo "FAIL: an API token is in the agent's environment"; exit 1; }
rel() { docker exec lyngvi node -e 'fetch(process.argv[1]).then(async r=>console.log(r.status+" "+(await r.text()).slice(0,60).replace(/\s+/g," "))).catch(e=>console.log("ERR "+e.cause?.code))' "$1"; }
u=$(rel http://lyngvi-relay:8081/api/v3/user); echo "relay /user        -> $u"
[[ "$u" == 401* ]] || { echo "FAIL: GitHub should reject the relay's fake token with 401 (proves it was added and the call went out)"; exit 1; }
h=$(rel http://lyngvi-relay:8081/api/v3/repos/git/git/hooks); echo "relay /repos/…/hooks -> $h"
# The Anthropic route (api-key mode): the fake key reaches Anthropic and is rejected; any
# path but the Messages and Models API is refused by the relay itself.
a=$(docker exec lyngvi node -e 'fetch("http://lyngvi-relay:8084/v1/messages",{method:"POST",headers:{"content-type":"application/json","x-api-key":"placeholder","anthropic-version":"2023-06-01"},body:JSON.stringify({model:"x",max_tokens:1,messages:[{role:"user",content:"hi"}]})}).then(async r=>console.log(r.status+" "+(await r.text()).slice(0,60).replace(/\s+/g," "))).catch(e=>console.log("ERR "+e.cause?.code))')
echo "relay anthropic /v1/messages -> $a"
[[ "$a" == 401* ]] || { echo "FAIL: Anthropic should reject the relay's fake key with 401 (proves it was added and the call went out)"; exit 1; }
o=$(rel http://lyngvi-relay:8084/v1/organizations/x)
[[ "$o" == "403 the lyngvi relay passes only"* ]] || { echo "FAIL: the relay must refuse non-Messages Anthropic paths: $o"; exit 1; }
[[ "$h" == "403 refused by the lyngvi relay"* ]] || { echo "FAIL: the relay must refuse the webhooks endpoint"; exit 1; }
# Through the relay, GitHub rejects the fake token and git, with no terminal, gives up
# asking for a username for the relay's address: that is the path proven.
g=$(docker exec lyngvi git ls-remote https://github.com/git/git.git HEAD 2>&1 | tail -1 || true)
grep -q "for 'http://lyngvi-relay:8082'" <<<"$g" || { echo "FAIL: git over HTTPS to github.com should go through the relay: $g"; exit 1; }
# GitHub's MCP server, as the CLI would start it: through the loopback forwarder and the
# relay to api.github.com, where the fake token is rejected.
m=$(docker exec lyngvi sh -c '{ printf "%s\n" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"smoke\",\"version\":\"1\"}}}" "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_me\",\"arguments\":{}}}"; sleep 6; } | LYNGVI_RELAY_GITHUB_LOCAL=http://localhost:18081 timeout 15 /usr/local/bin/github-mcp 2>&1' | grep -o 'localhost:18081/api/v3/user: 401 Bad credentials' | head -1)
[[ -n "$m" ]] || { echo "FAIL: GitHub's MCP server did not reach api.github.com through the relay"; exit 1; }
echo "ok: the agent holds no API token; the relay adds it, calls out through the proxy, and refuses the webhooks endpoint; GitHub's MCP server goes through it"
# A tunnel to github.com:22: the SSH banner proves the CONNECT path; auth fails (throwaway key) as expected.
out=$(docker exec lyngvi ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -T git@github.com 2>&1 || true)
grep -q 'Permission denied (publickey)' <<<"$out" || { echo "FAIL: ssh through the proxy tunnel did not reach github.com: $out"; exit 1; }
echo "ok: ssh reaches github.com:22 through the proxy tunnel (auth refused with the throwaway key, as it should be)"
docker exec lyngvi node -e 'require("https").get("https://example.com/",{timeout:6000},r=>{console.log("FAIL: example.com reachable "+r.statusCode);process.exit(1)}).on("error",e=>{console.log("ok: example.com unreachable via proxy ("+(e.code||e.message)+")")})' || exit 1
echo "SMOKE OK"

#!/usr/bin/env bash
# scripts/doctor.sh — check a lyngvi deployment before its first start and after it.
#
# BOOTSTRAP.md lists what a human must set up; this script checks each of those
# things and prints one line per check, so a mistake surfaces as a named line
# instead of a silent failure at first start. It never prints a secret value:
# secrets are read in-process, proved by key name, decodability, mode or status
# code, and the temp copies are shredded on exit.
#
# Run it from the deployment root (the overlay, or this repo for the example site):
#
#   upstream/scripts/doctor.sh                 # static: tools, site files, the compose egress layout
#   upstream/scripts/doctor.sh --online        # + forge host key, SSH key registration, token scope
#   upstream/scripts/doctor.sh --live          # + the running container: markers, hooks, proxy, egress
#   upstream/scripts/doctor.sh --online --live --repo owner/name   # everything, per writable repo
#     --repo is a repo on the configured forge (FORGE_KIND); --gh-repo one on GitHub
#
# Sections: tools · site · secrets · online · host · live. Each line is
# `ok | WARN | FAIL | skip  <section>  <what>`. Exit 1 if any line is FAIL.
#
# shellcheck disable=SC2015  # `test && ok … || fail …` is safe here: ok/warn/fail always return 0
set -uo pipefail

# The upstream checkout (site-example/, proxy/). Derived from this file's location;
# LYNGVI_UPSTREAM overrides it when the script runs from elsewhere (piped over ssh).
UP="${LYNGVI_UPSTREAM:-$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." && pwd)}"; UP="$(cd "$UP" && pwd)"
SITE=""; COMPOSE=""; ENVF=".env"; ONLINE=0; LIVE=0; SSH_USER=git; REPOS=(); GH_REPOS=()
usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while (( $# )); do
  case "$1" in
    --site)    SITE="$2"; shift 2 ;;
    --compose) COMPOSE="$2"; shift 2 ;;
    --env)     ENVF="$2"; shift 2 ;;
    --repo)    REPOS+=("$2"); shift 2 ;;
    --gh-repo) GH_REPOS+=("$2"); shift 2 ;;
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --online)  ONLINE=1; shift ;;
    --live)    LIVE=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done
# Defaults: an overlay layout if present, else this repo's example site.
[[ -n "$SITE" ]]    || { if [[ -d site ]]; then SITE=site; else SITE="$UP/site-example"; fi; }
[[ -n "$COMPOSE" ]] || { for f in compose.yaml compose.yml docker-compose.yml "$UP/docker-compose.yml"; do [[ -f "$f" ]] && { COMPOSE="$f"; break; }; done; }

FAILS=0; WARNS=0
ok()   { printf 'ok    %-8s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-8s %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }
warn() { printf 'WARN  %-8s %s\n' "$1" "$2"; WARNS=$((WARNS + 1)); }
skip() { printf 'skip  %-8s %s\n' "$1" "$2"; }
# conf FILE KEY → the value of KEY=... (last wins), without surrounding quotes.
conf() { local v; v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1); v="${v%\"}"; v="${v#\"}"; printf '%s' "$v"; }
has_key() { grep -qE "^$2=.+" "$1" 2>/dev/null; }   # key present with a non-empty value; prints nothing
# The entrypoint honours the pre-split names for one release; so does this check.
# key_name FILE NEW LEGACY → whichever is set (NEW wins), or nothing.
key_name() { if has_key "$1" "$2"; then printf '%s' "$2"; elif has_key "$1" "$3"; then printf '%s' "$3"; fi; }
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }   # $1 >= $2

TMP=$(mktemp -d); chmod 700 "$TMP"
cleanup() { if command -v shred >/dev/null 2>&1; then find "$TMP" -type f -exec shred -u {} + 2>/dev/null; fi; rm -rf "$TMP"; }
trap cleanup EXIT

echo "lyngvi doctor — site=$SITE compose=$COMPOSE env=$ENVF upstream=$UP"

# ── tools ────────────────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  ok tools "docker $(docker version --format '{{.Client.Version}}' 2>/dev/null || echo '(client)')"
  ev=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
  if [[ -z "$ev" ]]; then skip tools "docker engine version unknown from here (the egress layout needs >= 28.0 on the docker host)"
  elif ver_ge "$ev" 28.0.0; then ok tools "docker engine $ev (>= 28.0: internal networks with an isolated gateway)"
  else fail tools "docker engine $ev is older than 28.0 — gateway_mode_ipv4=isolated is refused, the stack will not start (fail closed)"; fi
  cv=$(docker compose version --short 2>/dev/null | sed 's/^v//')
  if [[ -z "$cv" ]]; then fail tools "docker compose plugin missing"
  elif ver_ge "$cv" 2.20.0; then ok tools "compose $cv (>= 2.20: BuildKit named contexts, healthcheck start_interval)"
  else fail tools "compose $cv is older than 2.20 — the site named context needs 2.17+ and the proxy healthcheck's start_interval 2.20+"; fi
  if docker buildx version >/dev/null 2>&1; then ok tools "buildx present"; else fail tools "buildx missing (named contexts need BuildKit)"; fi
  if docker info >/dev/null 2>&1; then
    fwb=$(docker info 2>/dev/null | sed -n 's/^ *Firewall Backend: *//p' | head -n1)
    ok tools "docker firewall backend: ${fwb:-unreported} (irrelevant to the egress layout)"
  else
    skip tools "docker daemon not reachable from here (host checks need the docker host)"
  fi
else
  fail tools "docker not found"
fi
for t in python3 ssh-keygen; do command -v "$t" >/dev/null 2>&1 && ok tools "$t present" || fail tools "$t missing"; done
if (( ONLINE )); then for t in curl ssh ssh-keyscan; do command -v "$t" >/dev/null 2>&1 || fail tools "$t missing (needed for --online)"; done; fi

# ── site ─────────────────────────────────────────────────────────────────────
[[ -d "$SITE" ]] || { fail site "site directory $SITE not found"; echo "doctor: $FAILS fail"; exit 1; }
for f in site.conf CLAUDE.md known_hosts settings.json gitconfig proxy-filter.extra proxy-tinyproxy.extra; do
  [[ -f "$SITE/$f" ]] && ok site "$f present" || fail site "$f missing (every site file has an example in site-example/)"
done
[[ -f "$SITE/firewall.conf" ]] && warn site "firewall.conf present: the host firewall path was removed in v0.5.0 — delete the file (and run upstream/host/uninstall.sh on a host that still has the units)"
SC="$SITE/site.conf"
if [[ -f "$SC" ]]; then
  for k in GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL FORGE_KIND FORGE_API_BASE RC_NAME CONTAINER_NAME; do
    [[ -n "$(conf "$SC" "$k")" ]] && ok site "site.conf $k set" || fail site "site.conf $k is empty"
  done
  case "$(conf "$SC" FORGE_KIND)" in github|forgejo|gitea|none) ;; *) fail site "FORGE_KIND must be github|forgejo|gitea|none" ;; esac
  if grep -qE '^(DISABLE_TELEMETRY|CLAUDE_CODE_USE_(BEDROCK|VERTEX|FOUNDRY))=' "$SC"; then
    fail site "site.conf sets a variable that disables Remote Control eligibility (DESIGN.md)"
  fi
  if grep -qE '^(GIT_SSH_KEY_B64|GITHUB_TOKEN|FORGE_API_TOKEN|SSH_KEY_[A-Z0-9_]+_B64|GIT_HTTPS_CREDENTIAL_[A-Z0-9_]+)=.+' "$SC"; then
    fail site "site.conf carries a secret-named key — secrets belong in $ENVF, never in a committed file"
  fi
fi
CN=$(conf "$SC" CONTAINER_NAME); CN="${CN:-lyngvi}"
FHOST=$(conf "$SC" FORGE_SSH_HOST); FPORT=$(conf "$SC" FORGE_SSH_PORT); FPORT="${FPORT:-22}"
if [[ -n "$FHOST" ]]; then
  if [[ -s "$SITE/known_hosts" ]] && grep -qE "^\[?${FHOST}\]?(:${FPORT})? " "$SITE/known_hosts"; then
    fp=$(grep -E "^\[?${FHOST}\]?(:${FPORT})? " "$SITE/known_hosts" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}' | paste -sd' ')
    ok site "known_hosts pins $FHOST:$FPORT ($fp) — verify this fingerprint out of band once"
  else
    fail site "known_hosts has no entry for [$FHOST]:$FPORT — SSH to the forge will be refused (fail closed)"
  fi
else
  skip site "FORGE_SSH_HOST empty: no SSH forge to pin"
fi
if [[ -f "$SITE/settings.json" ]]; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SITE/settings.json" 2>/dev/null \
    && ok site "settings.json is valid JSON" || fail site "settings.json is not valid JSON"
fi
# Every allowlist line must be a hostname pattern, not just any anchored regex:
# `^a|[a-z0-9-]+$` is anchored and allows every host. The same check fails the proxy
# build (proxy/check-filter.sh), so this line only says it earlier.
if [[ -f "$SITE/proxy-filter.extra" ]]; then
  if badf=$("$UP/proxy/check-filter.sh" "$SITE/proxy-filter.extra"); then
    ok site "proxy-filter.extra: every line is a hostname pattern"
  else
    while IFS= read -r l; do fail site "proxy-filter.extra ${l#"$SITE/proxy-filter.extra":} — the proxy build refuses it"; done <<<"$badf"
  fi
fi
# allowlisted FILE HOST → the host name is covered by an active (non-comment) line.
allowlisted() { grep -vE '^\s*(#|$)' "$1" 2>/dev/null | grep -qE -- "$(printf '%s' "$2" | sed 's/[.]/\\\\./g')"; }
# Every client leaves through the proxy, so the forge must be allowlisted and its port
# tunnelable, or every push is refused at the CONNECT (fail closed, but loud).
if [[ -n "$FHOST" ]]; then
  allowlisted "$SITE/proxy-filter.extra" "$FHOST" && ok site "proxy-filter.extra allowlists the forge $FHOST" \
    || fail site "proxy-filter.extra does not allowlist the forge $FHOST — ssh/https to it is refused by the proxy"
  if [[ "$FPORT" == 22 || "$FPORT" == 443 ]] || grep -qE "^ConnectPort[[:space:]]+$FPORT\b" "$SITE/proxy-tinyproxy.extra" 2>/dev/null; then ok site "proxy allows CONNECT to the forge port $FPORT"
  else fail site "proxy-tinyproxy.extra has no 'ConnectPort $FPORT' — the proxy refuses the forge's SSH port"; fi
fi
nurl=$(conf "$SC" NOTIFY_URL)
if [[ -n "$nurl" ]]; then
  nhost=$(printf '%s' "$nurl" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')
  allowlisted "$SITE/proxy-filter.extra" "$nhost" && ok site "proxy-filter.extra allowlists the notification host" \
    || fail site "NOTIFY_URL host is not in proxy-filter.extra — pushes cannot leave the container"
fi

# The egress layout, rendered through compose so extends/overrides are resolved. The
# rendered output is consumed in-process only (it carries env values); nothing but
# network names and properties comes out. Every network the agent is attached to must
# be `internal` with an isolated gateway, or the agent has a route it should not have.
ISOLATED=0
if [[ -f "$COMPOSE" ]] && command -v docker >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  noenv=(); docker compose config --help 2>/dev/null | grep -q -- '--no-env-resolution' && noenv=(--no-env-resolution)
  if docker compose -f "$COMPOSE" config --format json --no-interpolate "${noenv[@]}" > "$TMP/compose.json" 2>"$TMP/compose.err"; then
    python3 - "$TMP/compose.json" "$CN" <<'PY' > "$TMP/nets" 2>&1 || true
import json, sys
c = json.load(open(sys.argv[1])); cn = sys.argv[2]
svc = next((s for s in c.get("services", {}).values() if s.get("container_name") == cn), None)
if svc is None:
    print(f"FAIL no service with container_name {cn} in the compose file (site.conf CONTAINER_NAME)"); sys.exit(0)
attached = svc.get("networks") or []
attached = list(attached.keys()) if isinstance(attached, dict) else list(attached)
nets = c.get("networks", {}); bad = 0
for k in attached:
    n = nets.get(k, {})
    if n.get("external"):
        print(f"WARN {k} is external: it must have been created with --internal and -o com.docker.network.bridge.gateway_mode_ipv4=isolated (doctor --live checks the live bridge)"); continue
    iso = (n.get("driver_opts") or {}).get("com.docker.network.bridge.gateway_mode_ipv4") == "isolated"
    if n.get("internal") is True and iso:
        cfg = ((n.get("ipam") or {}).get("config") or [{}])[0].get("subnet", "dynamic subnet")
        print(f"OK {k}: internal, isolated gateway ({cfg})")
    else:
        bad += 1
        print(f"FAIL {k} is attached to {cn} but is not internal + gateway_mode_ipv4=isolated — the agent gets a route out (docker-compose.yml networks:)")
    if n.get("ipam") and not n.get("name"):
        print(f"WARN network {k} has no name: — compose names it <project>_{k}; set name: so the live bridge is reused")
env = svc.get("environment") or {}
keys = set(env.keys()) if isinstance(env, dict) else {e.split("=", 1)[0] for e in env}
for k in ("HTTPS_PROXY", "NODE_USE_ENV_PROXY"):
    if k not in keys:
        print(f"FAIL {cn} has no {k} in its environment — clients cannot reach the proxy by name")
services = c.get("services", {})
deps = svc.get("depends_on") or {}
deps = deps if isinstance(deps, dict) else {d: {} for d in deps}
def nets_of(s):
    n = s.get("networks") or []
    return set(n.keys()) if isinstance(n, dict) else set(n)
waits = [d for d, o in deps.items() if d in services and (o or {}).get("condition") == "service_healthy"
         and nets_of(services[d]) & set(attached) and services[d].get("healthcheck")]
if waits:
    print(f"OK {cn} starts only after {waits[0]} is healthy (depends_on)")
else:
    print(f"WARN {cn} does not wait for a healthy proxy — add depends_on: <proxy service>: condition: service_healthy (an overlay that renames the proxy uses depends_on: !override); the entrypoint still waits up to PROXY_WAIT")
# Toolchain <-> proxy preset lockstep: a toolchain whose registry is an opt-in preset
# (proxy/presets/) needs that preset on the proxy the agent goes through.
def build_args(s):
    a = (s.get("build") or {}).get("args") or {}
    return a if isinstance(a, dict) else dict(x.split("=", 1) for x in a if "=" in x)
proxies = [s for s in services.values()
           if str((s.get("build") or {}).get("dockerfile", "")).endswith("proxy/Dockerfile")
           and nets_of(s) & set(attached)]
if proxies:
    presets = set(str(build_args(proxies[0]).get("PROXY_PRESETS") or "").replace(",", " ").split())
    with_go = str(build_args(svc).get("WITH_GO", "0")) == "1"
    if with_go and "go" not in presets:
        print("WARN WITH_GO is 1 but the proxy has no go preset — go mod download is refused; add PROXY_PRESETS: \"go\" to the proxy's build args")
    elif "go" in presets and not with_go:
        print("WARN the proxy's go preset is on but WITH_GO is not 1 — it opens the Go module proxy for nothing")
    elif with_go:
        print("OK WITH_GO is 1 and the proxy has the go preset (Go module proxy reachable)")
if not bad:
    print(f"ISOLATED {len(attached)}")
PY
    while IFS= read -r line; do
      case "$line" in OK\ *) ok site "${line#OK }" ;; WARN\ *) warn site "${line#WARN }" ;; FAIL\ *) fail site "${line#FAIL }" ;; ISOLATED\ *) ISOLATED=1; ok site "egress layout: $CN on ${line#ISOLATED } network(s), all internal with no gateway address — the proxy is its only path" ;; *) fail site "compose parse: $line" ;; esac
    done < "$TMP/nets"
  else
    fail site "compose file does not render: $(head -n1 "$TMP/compose.err")"
  fi
else
  skip site "compose egress layout check needs docker + python3 + $COMPOSE"
fi

# ── secrets (names, modes, decodability — never values) ──────────────────────
if [[ -f "$ENVF" ]]; then
  mode=$(stat -c %a "$ENVF" 2>/dev/null || stat -f %Lp "$ENVF" 2>/dev/null)
  [[ "$mode" == 600 || "$mode" == 400 ]] && ok secrets "$ENVF mode $mode" || fail secrets "$ENVF mode is $mode — make it 0600"
  # Compose loads .env after site.conf: a key in both takes .env's value silently.
  if [[ -f "$SC" ]]; then
    both=$(comm -12 <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$SC" | sort -u) \
                    <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$ENVF" | sort -u) | paste -sd, -)
    [[ -z "$both" ]] && ok secrets "no key is set in both site.conf and $ENVF" \
      || fail secrets "set in both site.conf and $ENVF: $both — $ENVF loads later and wins silently; keep each key in one file (non-secret ones in site.conf)"
  fi
  for k in FORGEJO_DEPLOY_KEY_B64 FORGEJO_API_TOKEN FORGEJO_API_BASE; do
    has_key "$ENVF" "$k" && warn secrets "$k is a pre-split name, honoured for one release — rename it (see .env.example)"
  done
  KEYFILE=""; KEYVAR=$(key_name "$ENVF" GIT_SSH_KEY_B64 FORGEJO_DEPLOY_KEY_B64); TOKVAR=$(key_name "$ENVF" FORGE_API_TOKEN FORGEJO_API_TOKEN)
  if [[ -n "$KEYVAR" ]]; then
    if conf "$ENVF" "$KEYVAR" | base64 -d > "$TMP/key" 2>/dev/null && chmod 600 "$TMP/key" \
       && ssh-keygen -y -f "$TMP/key" > "$TMP/key.pub" 2>/dev/null; then
      KEYFILE="$TMP/key"
      ok secrets "$KEYVAR decodes to an OpenSSH key ($(ssh-keygen -lf "$TMP/key.pub" | awk '{print $1, $2}')) — register the public half as auth AND signing key"
    else
      fail secrets "$KEYVAR does not decode to an OpenSSH private key (base64 -w0 < key)"
    fi
  else
    warn secrets "GIT_SSH_KEY_B64 absent: no SSH push, no commit signing"
  fi
  if [[ "$(conf "$SC" FORGE_KIND)" =~ ^(forgejo|gitea)$ ]]; then
    [[ -n "$TOKVAR" ]] && ok secrets "$TOKVAR present" || fail secrets "FORGE_API_TOKEN absent (FORGE_KIND=$(conf "$SC" FORGE_KIND) needs it)"
  fi
  if [[ "$(conf "$SC" FORGE_KIND)" == github ]]; then
    has_key "$ENVF" GITHUB_TOKEN && ok secrets "GITHUB_TOKEN present" || warn secrets "GITHUB_TOKEN absent: no HTTPS push to GitHub"
  fi
  if git -C "$(dirname "$ENVF")" ls-files --error-unmatch "$(basename "$ENVF")" >/dev/null 2>&1; then
    fail secrets "$ENVF is tracked by git — it must never be committed"
  fi
else
  skip secrets "$ENVF absent (fine for CI and the example site; BOOTSTRAP.md §1 produces it)"
fi

# ── online (reaches the forge; proves registration and scope by status code) ─
if (( ONLINE )); then
  if [[ -n "$FHOST" ]]; then
    if ssh-keyscan -p "$FPORT" -T 8 "$FHOST" > "$TMP/scan" 2>/dev/null && [[ -s "$TMP/scan" ]]; then
      grep -E "^\[?${FHOST}\]?(:${FPORT})? " "$SITE/known_hosts" > "$TMP/pinned" 2>/dev/null || true
      live_fps=$(ssh-keygen -lf "$TMP/scan" 2>/dev/null | awk '{print $2}')
      pin_fps=$(ssh-keygen -lf "$TMP/pinned" 2>/dev/null | awk '{print $2}')
      hit=""; for p in $pin_fps; do grep -qx "$p" <<<"$live_fps" && hit="$p"; done
      [[ -n "$hit" ]] && ok online "$FHOST:$FPORT presents the pinned host key ($hit)" \
        || fail online "$FHOST:$FPORT presents none of the pinned host keys — re-pin only after verifying out of band"
    else
      fail online "ssh-keyscan $FHOST:$FPORT got nothing (firewall, DNS, or wrong port)"
    fi
    if [[ -n "${KEYFILE:-}" ]]; then
      out=$(ssh -T -o LogLevel=ERROR -i "$KEYFILE" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$SITE/known_hosts" -p "$FPORT" "$SSH_USER@$FHOST" < /dev/null 2>&1 || true)
      case "$out" in
        *successfully\ authenticated*) ok online "SSH key accepted by $FHOST: $(head -n1 <<<"$out")" ;;
        *Permission\ denied*)          fail online "SSH key rejected by $FHOST — register the public half on the bot account as an authentication key" ;;
        *Host\ key\ verification*)     fail online "host key verification failed against $SITE/known_hosts" ;;
        *)                             warn online "SSH to $FHOST: $(head -n1 <<<"$out")" ;;
      esac
    else
      skip online "no decodable key — SSH registration not tested"
    fi
  fi
  api=$(conf "$SC" FORGE_API_BASE); kind=$(conf "$SC" FORGE_KIND)
  http() { # METHOD URL HEADERFILE [BODY] → status code; body to $TMP/body
    local m="$1" u="$2" h="$3" b="${4:-}"
    if [[ -n "$b" ]]; then curl -sS -o "$TMP/body" -w '%{http_code}' -X "$m" -H @"$h" -H 'Content-Type: application/json' --data "$b" "$u" 2>/dev/null
    else curl -sS -o "$TMP/body" -w '%{http_code}' -X "$m" -H @"$h" "$u" 2>/dev/null; fi
  }
  # The forge API is often reachable only from inside the container (a co-hosted forge
  # on an internal network — DESIGN.md §4.4), and the container is where the token is
  # used anyway, so the API probes run there when it exists, with ITS token and base;
  # the host's curl is the fallback before first start. Either way the token stays
  # in-process: a header file on the host, the container's own env inside it.
  fapi() { # METHOD PATH [BODY] → status code; response body to $TMP/body
    local m="$1" path="$2" b="${3:-}"
    if (( API_IN_CONTAINER )); then
      docker exec "$CN" node -e '
        const [m, p, b] = process.argv.slice(1); const base = (process.env.FORGE_API_BASE || "").replace(/\/$/, "");
        const ctl = new AbortController(); setTimeout(() => ctl.abort(), 10000);
        fetch(base + p, { method: m, headers: { Authorization: "token " + process.env.FORGE_API_TOKEN, "Content-Type": "application/json" }, body: b || undefined, signal: ctl.signal })
          .then(async (r) => process.stdout.write(r.status + "\n" + await r.text()))
          .catch((e) => process.stdout.write("000\n" + (e.cause?.code || e.name)));' "$m" "$path" "$b" > "$TMP/resp" 2>/dev/null
      head -n1 "$TMP/resp"; tail -n +2 "$TMP/resp" > "$TMP/body"
    else
      http "$m" "$api$path" "$TMP/h" "$b"
    fi
  }
  if [[ "$kind" =~ ^(forgejo|gitea)$ ]] && [[ -n "${TOKVAR:-}" ]]; then
    API_IN_CONTAINER=0
    if command -v docker >/dev/null 2>&1 && [[ "$(docker inspect --format '{{.State.Status}}' "$CN" 2>/dev/null)" == running ]] \
       && docker exec "$CN" sh -c 'test -n "$FORGE_API_TOKEN" && test -n "$FORGE_API_BASE"' 2>/dev/null; then
      API_IN_CONTAINER=1; where="from inside $CN"
    else
      printf 'Authorization: token %s\n' "$(conf "$ENVF" "$TOKVAR")" > "$TMP/h"; chmod 600 "$TMP/h"; where="from this host"
    fi
    code=$(fapi GET "/user/repos?limit=1")
    [[ "$code" == 200 ]] && ok online "$TOKVAR reads $api (200, $where)" || fail online "$TOKVAR against $api/user/repos → $code ($where)"
    code=$(fapi GET "/user/keys")
    if [[ "$code" == 200 && -n "${KEYFILE:-}" ]]; then
      pub=$(cut -d' ' -f1,2 "$TMP/key.pub")
      grep -qF "$pub" "$TMP/body" && ok online "the SSH key is registered on the token's account" \
        || fail online "the SSH key is NOT registered on the token's account (auth + signing)"
    else
      skip online "key registration not readable with this token ($code; needs read:user) — verify in the forge UI"
    fi
    for r in "${REPOS[@]}"; do
      code=$(fapi POST "/repos/$r/pulls/0/merge" '{"Do":"merge"}')
      case "$code" in
        403) ok online "$r: token cannot merge (403 on the merge endpoint — no write:repository scope)" ;;
        404) fail online "$r: the merge endpoint answered 404, so the token passed the scope gate — it holds write:repository; mint one without it" ;;
        *)   warn online "$r: merge endpoint answered $code (expected 403)" ;;
      esac
    done
    (( ${#REPOS[@]} )) || skip online "pass --repo owner/name to prove the token cannot merge there"
  fi
  if has_key "$ENVF" GITHUB_TOKEN; then
    printf 'Authorization: Bearer %s\n' "$(conf "$ENVF" GITHUB_TOKEN)" > "$TMP/gh"; chmod 600 "$TMP/gh"
    code=$(http GET "https://api.github.com/user" "$TMP/gh")
    [[ "$code" == 200 ]] && ok online "GITHUB_TOKEN authenticates as $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("login","?"))' "$TMP/body")" \
      || fail online "GITHUB_TOKEN against api.github.com/user → $code"
    code=$(http GET "https://api.github.com/user/ssh_signing_keys" "$TMP/gh")
    if [[ "$code" == 200 && -n "${KEYFILE:-}" ]]; then
      pub=$(cut -d' ' -f1,2 "$TMP/key.pub")
      grep -qF "$pub" "$TMP/body" && ok online "the SSH key is a registered signing key on the GitHub account" \
        || fail online "the SSH key is NOT a signing key on the GitHub account — commits will show Unverified"
    else
      skip online "GitHub signing keys not readable with this token ($code) — verify under Settings → SSH and GPG keys"
    fi
    gh_repos=("${GH_REPOS[@]}"); [[ "$kind" == github ]] && gh_repos+=("${REPOS[@]}")
    for r in "${gh_repos[@]}"; do
      code=$(http GET "https://api.github.com/repos/$r" "$TMP/gh")
      if [[ "$code" == 200 ]]; then
        python3 - "$TMP/body" "$r" <<'PY'
import json, sys
p = json.load(open(sys.argv[1])).get("permissions", {}); r = sys.argv[2]
if p.get("admin"): print(f"FAIL  online   {r}: the token has admin on the repo — it could edit the ruleset")
elif p.get("push"): print(f"ok    online   {r}: token has write, no admin (branch protection must carry the merge gate)")
else: print(f"ok    online   {r}: token is read-only here (contributes from a fork)")
PY
        code=$(http GET "https://api.github.com/repos/$r/rulesets" "$TMP/gh")
        n=$(python3 -c 'import json,sys;print(sum(1 for x in json.load(open(sys.argv[1])) if x.get("enforcement")=="active" and x.get("target")=="branch"))' "$TMP/body" 2>/dev/null || echo 0)
        (( n > 0 )) && ok online "$r: $n active branch ruleset(s)" || fail online "$r: no active branch ruleset (import scripts/github-main-ruleset.json)"
      else
        fail online "$r: GET /repos → $code with GITHUB_TOKEN"
      fi
    done
  fi
  (( ONLINE )) && [[ -z "$FHOST" ]] && ! has_key "$ENVF" GITHUB_TOKEN && [[ -z "${TOKVAR:-}" ]] \
    && skip online "nothing to test online: no forge host, no tokens in $ENVF"
else
  skip online "pass --online to test host key, key registration and token scope against the forge"
fi

# ── host (nothing to install; leftovers from a pre-v0.5 host-firewall install) ──
if compgen -G '/etc/systemd/system/lyngvi-*' >/dev/null || [[ -e /etc/lyngvi/firewall.conf ]]; then
  warn host "host-firewall units or config from a pre-v0.5 install are still present — run upstream/host/uninstall.sh as root (it does not stop the agent)"
else
  skip host "nothing installed on the host (the egress layout needs nothing there)"
fi

# ── live (the running container) ─────────────────────────────────────────────
if (( LIVE )); then
  if ! command -v docker >/dev/null 2>&1 || ! docker inspect --format '{{.State.Status}}' "$CN" >/dev/null 2>&1; then
    fail live "container $CN not found — docker compose up -d --build"
  else
    st=$(docker inspect --format '{{.State.Status}}' "$CN"); hs=$(docker inspect --format '{{.State.Health.Status}}' "$CN" 2>/dev/null)
    [[ "$st" == running ]] && ok live "$CN is $st (health: ${hs:-none})" || fail live "$CN is $st"
    rp=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CN")
    if (( ISOLATED )); then
      if [[ "$rp" == unless-stopped || "$rp" == always ]]; then ok live "restart policy '$rp' (no fail-open window on the egress layout)"
      else warn live "restart policy '$rp' — on the egress layout the agent can be unless-stopped; with '$rp' it stays down after a reboot or daemon restart"; fi
    else warn live "restart policy '$rp' on a stack without the egress layout — see the site checks; nothing else contains egress"; fi
    # The layout, observed: no default route, no resolver path, bridges without a host address.
    if docker exec "$CN" awk 'NR>1 && $2=="00000000"{f=1} END{exit !f}' /proc/net/route 2>/dev/null; then fail live "$CN has a default route — a network with a gateway is attached"
    else ok live "$CN has no default route"; fi
    if docker exec "$CN" getent hosts example.com >/dev/null 2>&1; then fail live "$CN can resolve names — a resolver path exists (expected none: names resolve only at the proxy)"
    else ok live "$CN has no resolver path (names resolve only at the proxy)"; fi
    if command -v ip >/dev/null 2>&1; then
      for nid in $(docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{$v.NetworkID}} {{end}}' "$CN"); do
        nname=$(docker network inspect --format '{{.Name}}' "$nid"); short=${nid:0:12}
        if [[ -n "$(ip -4 -o addr show "br-$short" 2>/dev/null)" ]]; then fail live "bridge of $nname carries a host address — not gateway_mode_ipv4=isolated"
        elif [[ "$(docker network inspect --format '{{.Internal}}' "$nid")" != true ]]; then fail live "network $nname is not internal"
        else ok live "network $nname: internal, bridge carries no host address"; fi
      done
    else skip live "no 'ip' here: bridge-address check needs the docker host"; fi
    docker inspect --format '{{json .HostConfig.CapDrop}}' "$CN" | grep -q '"ALL"' && ok live "cap_drop ALL" || fail live "capabilities not all dropped"
    [[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$CN")" == true ]] && ok live "root filesystem read-only (writable: tmpfs + the volumes)" \
      || warn live "root filesystem is writable: the overlay dropped read_only: true (DESIGN.md §4.1)"
    # Start-up facts come from the entrypoint's per-run status file (/tmp/lyngvi-status,
    # KEY=value, no secret values). An image older than the file falls back to the log:
    # read from the run's own start, since a Remote Control login can push the start-up
    # lines past any fixed tail. Markers are about now — read them from the recent tail.
    started=$(docker inspect --format '{{.State.StartedAt}}' "$CN")
    sfile=$(docker exec "$CN" cat /tmp/lyngvi-status 2>/dev/null)
    if [[ -n "$sfile" ]]; then
      ok live "start-up status read from $CN:/tmp/lyngvi-status"
      st() { grep -qx "$1=$2" <<<"$sfile"; }
      if st identity overridden; then
        fail live "git identity: the environment overrides site.conf's GIT_AUTHOR_NAME/EMAIL (set in .env too?). Remote Control sessions use site.conf's; a docker exec shell would commit under the override, and the pre-commit hook refuses it — remove it from .env"
      elif st identity site; then ok live "git identity from site.conf; nothing overrides it"; fi
      ov=$(sed -n 's/^site_conf_overrides=//p' <<<"$sfile")
      [[ -n "$ov" && "$ov" != none ]] && warn live "the environment overrides site.conf keys: $ov — each key belongs in one file"
    else
      slog=$(docker logs --since "$started" "$CN" 2>&1 | grep -aE '^\[entrypoint ' | head -n 200 | LC_ALL=C tr -c '[:print:]\n' '?')
      skip live "no /tmp/lyngvi-status (image older than the status file) — reading the start-up log instead"
      st() {  # map a status fact to the log line the older entrypoint wrote
        case "$1=$2" in
          hooks=managed) grep -q 'Secret-hygiene hooks wired by managed settings' <<<"$slog" ;;
          key_git_key=loaded) grep -qE 'Loaded git_key into ssh-agent|SSH key git_key held by the key sidecar' <<<"$slog" ;;
          signing=on) grep -q 'Enabled SSH commit signing' <<<"$slog" ;;
          hostkey_pin=*) grep -q "Pinned host key for ${2}" <<<"$slog" ;;
          *) return 1 ;;
        esac
      }
    fi
    # The container's log is written by the agent's uid, so it is untrusted text: a line
    # can be forged and can carry terminal escapes. Every byte that is not printable
    # becomes ? before anything below can echo it (DESIGN.md §10).
    elog=$(docker logs --tail 400 "$CN" 2>&1 | grep -aE '^\[entrypoint ' | tail -n 200 | LC_ALL=C tr -c '[:print:]\n' '?')
    # Which kernel the agent's syscalls reach (DESIGN.md §11, docs/GVISOR.md). Information,
    # not a requirement: runc is the default.
    rt=$(docker inspect --format '{{.HostConfig.Runtime}}' "$CN" 2>/dev/null)
    case "$rt" in
      *runsc*) ok live "agent runtime: $rt (gVisor: the agent's syscalls reach gVisor's kernel, not the host's)" ;;
      ""|runc|io.containerd.runc.v2) ok live "agent runtime: ${rt:-runc} (shares the host kernel, the default; docs/GVISOR.md for the opt-in)" ;;
      *) ok live "agent runtime: $(LC_ALL=C tr -cd '[:alnum:]._-' <<<"$rt")" ;;
    esac
    st hooks managed && ok live "hooks wired by managed settings at start" || fail live "the entrypoint did not find managed settings that wire the hooks (docker logs $CN: HOOKS_UNMANAGED)"
    if st canaries planted; then ok live "decoy credentials planted (a use raises CANARY_TOUCHED in the proxy's log)"
    elif st canaries off; then warn live "decoy credentials off (CANARIES=0 in site.conf)"
    elif st canaries unavailable; then warn live "decoy credentials unavailable: the canary volume is not mounted on both services (upstream docker-compose.yml)"
    fi
    if [[ -n "$sfile" ]]; then
      if st config_scan off; then warn live "workspace settings scan off (LYNGVI_CONFIG_SCAN_INTERVAL=0): a rule written into another workspace repository raises nothing until doctor lists it"
      elif grep -q '^config_scan=' <<<"$sfile"; then ok live "workspace settings scan every $(sed -n 's/^config_scan=//p' <<<"$sfile" | LC_ALL=C tr -cd '0-9s') (a new rule anywhere in the workspace raises CONFIG_CHANGED)"
      else warn live "no workspace settings scan (image older than it): a rule written into another workspace repository raises nothing until doctor lists it"; fi
    fi
    if [[ -n "${KEYVAR:-}" ]] || st key_git_key loaded; then
      st key_git_key loaded && ok live "SSH key held by the key sidecar; the agent has the public half only" || fail live "key not held by the key sidecar (docker logs lyngvi-keys; is the service in the stack?)"
      st signing on && ok live "commit signing enabled" || fail live "signing not enabled"
    fi
    # The private keys belong to the key sidecar. Count, never print, any set in the agent.
    kin=$(docker exec "$CN" sh -c 'tr "\0" "\n" < /proc/1/environ | grep -cE "^(GIT_SSH_KEY|FORGEJO_DEPLOY_KEY|SSH_KEY_[A-Z0-9_]+)_B64=."' 2>/dev/null)
    [[ "${kin:-0}" == 0 ]] && ok live "no private key in the agent's environment" \
      || fail live "$kin private key variable(s) set in the agent's environment: blank each in the agent service (environment: - NAME=) so only the key sidecar has it"
    # Find the key sidecar by the volume it shares with the agent, not by a service name
    # an overlay may change.
    kvol=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/run/lyngvi-keys"}}{{.Name}}{{end}}{{end}}' "$CN" 2>/dev/null)
    kc=""; [[ -n "$kvol" ]] && kc=$(docker ps -a --filter "volume=$kvol" --format '{{.Names}}' | grep -vx "$CN" | head -n1)
    if [[ -n "$kc" ]]; then
      [[ "$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$kc")" == none ]] && ok live "key sidecar $kc has no network" || fail live "key sidecar $kc has a network: it must be network_mode: none"
    else
      fail live "no key sidecar (lyngvi-keys) in the stack: SSH git and signing are off"
    fi
    # The API tokens belong to the token relay. Count, never print, any set in the agent.
    tin=$(docker exec "$CN" sh -c 'tr "\0" "\n" < /proc/1/environ | grep -cE "^(GITHUB_TOKEN|FORGE_API_TOKEN|FORGEJO_API_TOKEN|LYNGVI_ANTHROPIC_API_KEY|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN)=."' 2>/dev/null)
    [[ "${tin:-0}" == 0 ]] && ok live "no API token in the agent's environment" \
      || fail live "$tin API token variable(s) set in the agent's environment: blank each in the agent service (environment: - NAME=) so only the token relay has it"
    rc=$(docker ps -a --filter "label=com.docker.compose.project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$CN")" --format '{{.Names}}' \
      | while read -r c; do docker inspect --format '{{.Config.Image}} {{.Name}}' "$c"; done | awk '$1 ~ /relay/ {sub("^/","",$2); print $2; exit}')
    if [[ -n "$rc" ]]; then
      rn=$(docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$rc" | wc -w)
      (( rn == 1 )) && ok live "token relay $rc is on one network (the proxy's internal one)" || warn live "token relay $rc is on $rn networks: it needs only the proxy's internal network"
      st relay_github on && ok live "token relay: GitHub route on (MCP and git over HTTPS go through it)"
      st relay_forge on && ok live "token relay: forge route on"
      if st mode api-key; then ok live "api-key mode: model calls go through the relay with a placeholder key; no Remote Control (attach: docker exec -it $CN tmux attach -t claude)"
      elif st mode api-key-unusable; then fail live "LYNGVI_MODE=api-key but the relay has no Anthropic route: set LYNGVI_ANTHROPIC_API_KEY in .env (docs/API_KEY_MODE.md)"; fi
      st relay_github off && st relay_forge off && skip live "token relay has no route: no GITHUB_TOKEN or FORGE_API_TOKEN in .env"
    else
      warn live "no token relay in the stack: the agent's API calls have no token (add the lyngvi-relay service)"
    fi
    if [[ -n "$FHOST" ]]; then
      st hostkey_pin "$FHOST:$FPORT" && ok live "forge host key pinned, StrictHostKeyChecking=yes" || fail live "forge host key for $FHOST:$FPORT was not pinned at start (site/known_hosts)"
    fi
    for m in SSH_HOSTKEY_MISSING RC_TOKEN_STALE RC_REGISTER_FAIL; do
      grep -q "$m" <<<"$elog" && fail live "marker $m in recent log — $(grep "$m" <<<"$elog" | tail -n1 | sed 's/.*sev=[a-z]* //' | cut -c1-120)"
    done
    grep -q 'RC_TOKEN_EXPIRING' <<<"$elog" && warn live "RC_TOKEN_EXPIRING in recent log — re-login soon: docker exec -it $CN claude /login"
    cred=$(docker exec "$CN" node -e '
      const fs=require("fs"); const p=(process.env.CLAUDE_CONFIG_DIR||process.env.HOME+"/.claude")+"/.credentials.json";
      if(!fs.existsSync(p)){console.log("none");process.exit(0)}
      try{const o=JSON.parse(fs.readFileSync(p,"utf8")).claudeAiOauth||{}; const h=x=>x?((x-Date.now())/36e5).toFixed(1)+"h":"unset";
        console.log("present access="+h(o.expiresAt)+" refresh="+(o.refreshToken?"present":"absent")+" refresh_expires="+h(o.refreshTokenExpiresAt));}
      catch(e){console.log("unreadable")}' 2>/dev/null)
    case "$cred" in
      none)      if st mode api-key; then ok live "no claude.ai login, as expected in api-key mode"; else warn live "no claude.ai credential yet — docker exec -it $CN claude, accept the trust dialog, then /login (BOOTSTRAP.md §4)"; fi ;;
      present*)  ok live "claude.ai credential $cred"
                 rs=$("$(dirname "${BASH_SOURCE[0]}")/recreate-safe.sh" "$CN" 2>/dev/null); rsc=$?
                 case $rsc in
                   0) ok live "${rs#recreate-safe: }" ;;
                   1) warn live "${rs#recreate-safe: }" ;;
                 esac ;;
      *)         warn live "credential file: ${cred:-unknown}" ;;
    esac
    # The policy lives in the managed settings baked into the image. Check what the CLI
    # will act on, not that a key exists: every hook command must be a root-owned script
    # under /etc/lyngvi/hooks, the file must be root-owned and unwritable by the agent,
    # and the user settings in the volume must carry none of the policy keys.
    pol=$(docker exec "$CN" node -e '
      const fs=require("fs"), M="/etc/claude-code/managed-settings.json"; const bad=[];
      let m; try { m=JSON.parse(fs.readFileSync(M,"utf8")) } catch(e) { console.log("FAIL managed settings unreadable: "+M); process.exit(0) }
      const st=fs.statSync(M); if (st.uid!==0) bad.push("not root-owned");
      try { fs.accessSync(M, fs.constants.W_OK); bad.push("writable by the agent") } catch {}
      if (m.allowManagedHooksOnly!==true) bad.push("allowManagedHooksOnly is not true");
      if (m.disableBypassPermissionsMode!=="disable") bad.push("bypass mode not disabled");
      if (!Array.isArray(m.allowedMcpServers)) bad.push("no allowedMcpServers list");
      for (const [ev,script] of [["PreToolUse","block-secret-dumps.sh"],["PostToolUse","redact-tool-output.sh"],["ConfigChange","config-change.sh"]]) {
        const cmds=(m.hooks?.[ev]||[]).flatMap(e=>(e.hooks||[]).map(h=>h.command));
        if (!cmds.includes("/etc/lyngvi/hooks/"+script)) bad.push(ev+" does not run /etc/lyngvi/hooks/"+script);
      }
      for (const c of Object.values(m.hooks||{}).flat().flatMap(e=>(e.hooks||[]).map(h=>h.command))) {
        const f=String(c).split(" ")[0];
        try { if (!f.startsWith("/etc/lyngvi/hooks/") || fs.statSync(f).uid!==0) bad.push("hook "+f+" is not a root-owned image script") } catch { bad.push("hook "+f+" missing") }
      }
      console.log(bad.length ? "FAIL managed settings: "+bad.join("; ") : "OK");
      let u={}; try { u=JSON.parse(fs.readFileSync(process.env.CLAUDE_CONFIG_DIR+"/settings.json","utf8")) } catch {}
      const keys=["hooks","disableAllHooks","permissions","enabledPlugins","apiKeyHelper","enableAllProjectMcpServers"].filter(k=>k in u);
      console.log(keys.length ? "WARN user settings carry policy keys the entrypoint does not write: "+keys.join(", ")+" (written since this start)" : "OK");' 2>/dev/null)
    while IFS= read -r line; do
      case "$line" in
        OK) ;;
        FAIL\ *) fail live "${line#FAIL }" ;;
        WARN\ *) warn live "${line#WARN }" ;;
      esac
    done <<<"$pol"
    grep -q '^FAIL' <<<"$pol" || ok live "hooks, MCP allowlist and no-bypass are managed settings (root-owned, read-only to the agent)"
    [[ -n "$pol" ]] || fail live "could not read the managed settings from $CN"
    # Tool-call telemetry (opt-in, DESIGN.md §10): on when the managed settings name an
    # OTLP endpoint. The collector is reached through the proxy like every other host.
    tel=$(docker exec "$CN" node -e '
      const e=(JSON.parse(require("fs").readFileSync("/etc/claude-code/managed-settings.json","utf8")).env)||{};
      const u=e.OTEL_EXPORTER_OTLP_LOGS_ENDPOINT||e.OTEL_EXPORTER_OTLP_ENDPOINT||"";
      if (e.CLAUDE_CODE_ENABLE_TELEMETRY!=="1"||!u) { console.log("off"); process.exit(0) }
      const url=new URL(u), port=url.port||(url.protocol==="https:"?"443":"80");
      const net=require("net");
      const s=net.connect(3128,"lyngvi-proxy",()=>s.write(url.protocol==="https:"
        ? "CONNECT "+url.hostname+":"+port+" HTTP/1.1\r\nHost: "+url.hostname+":"+port+"\r\n\r\n"
        : "GET http://"+url.hostname+":"+port+"/ HTTP/1.1\r\nHost: "+url.hostname+":"+port+"\r\nConnection: close\r\n\r\n"));
      s.setTimeout(8000,()=>{console.log("on "+url.hostname+":"+port+" timeout");s.destroy()});
      s.once("data",d=>{console.log("on "+url.hostname+":"+port+" "+d.toString().split("\r\n")[0]);s.destroy()});
      s.on("error",er=>console.log("on "+url.hostname+":"+port+" ERR "+er.code));' 2>/dev/null)
    case "$tel" in
      off|"") ok live "tool-call telemetry off (opt-in: an OTLP endpoint in site/settings.json env)" ;;
      on\ *\ HTTP/1.?\ 403*|on\ *timeout|on\ *ERR*) warn live "tool-call telemetry on, but the proxy does not pass the collector: ${tel#on } (allowlist its host in site/proxy-filter.extra; a TLS port other than 443 also needs a ConnectPort line)" ;;
      on\ *) ok live "tool-call telemetry on, forced by managed settings, collector reachable through the proxy (${tel#on })" ;;
    esac
    # Permission rules the workspace carries into every session (DESIGN.md §4.5). They are
    # agent-writable, so the rule text is untrusted: printable characters only, cut short.
    wsr=$(docker exec "$CN" node -e '
      const fs=require("fs"), path=require("path"), H=process.env.HOME;
      const clean=s=>String(s).replace(/[^\x20-\x7e]/g,"?").slice(0,100);
      let only=false; try { only=JSON.parse(fs.readFileSync("/etc/claude-code/managed-settings.json","utf8")).allowManagedPermissionRulesOnly===true } catch {}
      const found=[];
      const read=f=>{ try { const a=JSON.parse(fs.readFileSync(f,"utf8"))?.permissions?.allow; if (Array.isArray(a)&&a.length) found.push([f,a]) } catch {} };
      const walk=(d,depth)=>{ if (depth>5) return; let es=[]; try { es=fs.readdirSync(d,{withFileTypes:true}) } catch { return }
        for (const e of es) { if (!e.isDirectory()) continue;
          const p=path.join(d,e.name);
          if (e.name===".claude") { read(path.join(p,"settings.json")); read(path.join(p,"settings.local.json")); continue }
          if (e.name==="node_modules"||e.name===".git") continue;
          walk(p,depth+1) } };
      walk(H+"/workspace",0); read((process.env.CLAUDE_CONFIG_DIR||H+"/.claude")+"/settings.json");
      console.log("ONLY "+(only?1:0));
      for (const [f,a] of found) console.log("RULES "+clean(path.relative(H,f))+" ("+a.length+"): "+a.slice(0,6).map(clean).join(", ")+(a.length>6?", …":""));' 2>/dev/null)
    only=$(sed -n 's/^ONLY //p' <<<"$wsr")
    if grep -q '^RULES ' <<<"$wsr"; then
      while IFS= read -r line; do
        [[ "$line" == RULES\ * ]] || continue
        if [[ "$only" == 1 ]]; then ok live "workspace permission rules (no effect: allowManagedPermissionRulesOnly) ~/${line#RULES }"
        else ok live "workspace permission rules, used by every session ~/${line#RULES } — remove any you did not grant (docs/INCIDENT.md)"; fi
      done <<<"$wsr"
    elif [[ -n "$wsr" ]]; then ok live "workspace permission rules: none"
    fi
    probe() { docker exec "$CN" node -e '
      const net=require("net"); const host=process.argv[1];
      const s=net.connect(3128,"lyngvi-proxy",()=>s.write("CONNECT "+host+":443 HTTP/1.1\r\nHost: "+host+":443\r\n\r\n"));
      s.setTimeout(8000,()=>{console.log("timeout");s.destroy()});
      s.once("data",d=>{console.log(d.toString().split("\r\n")[0]); s.destroy();});
      s.on("error",e=>{console.log("ERR "+e.code)});' "$1" 2>/dev/null; }
    a=$(probe pypi.org); d=$(probe example.com); r=$(probe api.anthropic.com); l=$(probe platform.claude.com)
    grep -q ' 200 ' <<<"$a" && ok live "proxy allows pypi.org ($a)" || fail live "proxy does not allow pypi.org: ${a:-no answer}"
    grep -q ' 200 ' <<<"$r" && ok live "proxy allows the relay api.anthropic.com ($r)" || fail live "proxy does not allow api.anthropic.com: ${r:-no answer} — Remote Control cannot connect"
    grep -q ' 200 ' <<<"$l" && ok live "proxy allows platform.claude.com (OAuth refresh) ($l)" || fail live "proxy does not allow platform.claude.com: ${l:-no answer} — the monthly token refresh fails"
    grep -q ' 403 ' <<<"$d" && ok live "proxy filters example.com ($d)" || fail live "proxy does not filter example.com: ${d:-no answer}"
    if [[ -n "$FHOST" && ! "$FHOST" =~ \.example\.(com|org|net|internal)$ ]]; then
      fprobe=$(docker exec "$CN" node -e '
        const net=require("net"); const [host,port]=process.argv.slice(1);
        const s=net.connect(3128,"lyngvi-proxy",()=>s.write("CONNECT "+host+":"+port+" HTTP/1.1\r\nHost: "+host+":"+port+"\r\n\r\n"));
        s.setTimeout(8000,()=>{console.log("timeout");s.destroy()});
        s.once("data",d=>{console.log(d.toString().split("\r\n")[0]); s.destroy();});
        s.on("error",e=>{console.log("ERR "+e.code)});' "$FHOST" "$FPORT" 2>/dev/null)
      grep -q ' 200 ' <<<"$fprobe" && ok live "proxy tunnels to the forge $FHOST:$FPORT ($fprobe)" || fail live "proxy refuses the forge $FHOST:$FPORT: ${fprobe:-no answer} (proxy-filter.extra / proxy-tinyproxy.extra)"
    fi
    docker exec "$CN" sh -c 'grep -q "^Host \*$" ~/.ssh/config && grep -q "connect.mjs" ~/.ssh/config' 2>/dev/null \
      && ok live "ssh ProxyCommand through the proxy is configured" || fail live "ssh is not routed through the proxy (no Host * ProxyCommand in ~/.ssh/config)"
    # Real host addresses: the one its default route leaves from and the default bridge's
    # gateway. Not the attached bridge's first address — an isolated bridge gives that to
    # a container, so a probe there reaches a peer and proves nothing about the host.
    hosts=$(
      command -v ip >/dev/null 2>&1 && ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}'
      docker network inspect --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' bridge 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$'
    )
    hosts=$(awk 'NF && !s[$0]++' <<<"$hosts" | tr '\n' ' ')
    [[ -n "$hosts" ]] || skip live "egress host: no host address found to probe"
    # RFC 2606 names (the example site's forge) resolve nowhere by design: probe nothing there.
    fh_probe="$FHOST"; [[ "$FHOST" =~ \.example\.(com|org|net|internal)$ ]] && { fh_probe=""; skip live "egress forge: $FHOST is an example name, nothing to reach"; }
    eg=$(docker exec -e HOSTS="$hosts" -e FH="$fh_probe" -e FP="$FPORT" -e NODE_USE_ENV_PROXY=1 "$CN" node -e '
      const n=require("net"),h=require("https");
      const t=(host,port)=>new Promise(r=>{const s=n.connect({host,port,timeout:6000});s.on("connect",()=>{r("REACHABLE");s.destroy()});s.on("timeout",()=>{s.destroy();r("blocked")});s.on("error",e=>r(e.code==="ECONNREFUSED"?"REACHABLE(refused)":"blocked("+e.code+")"))});
      const f=u=>new Promise(r=>{h.get(u,{timeout:6000},s=>{r("REACHABLE "+s.statusCode);s.destroy()}).on("timeout",function(){this.destroy();r("blocked")}).on("error",e=>r("blocked("+e.code+")"))});
      (async()=>{console.log("relay "+await f("https://api.anthropic.com/"));console.log("github "+await f("https://api.github.com/"));
        if(process.env.FH)console.log("forge "+await t(process.env.FH,+process.env.FP));
        console.log("example.com "+await f("https://example.com/"));console.log("1.1.1.1:443 "+await t("1.1.1.1",443));for(const a of (process.env.HOSTS||"").split(" ").filter(Boolean))console.log("host:"+a+":22 "+await t(a,22));})();' 2>/dev/null)
    # relay/github: through the proxy (node honours the env) — must reach. forge: a raw
    # socket, which only the ssh tunnel can open — blocked is correct on the layout. The
    # rest must be blocked; on the layout that is a property of the networks, not a rule.
    # A refused connection is a peer answering, so it counts as reachable, not blocked.
    while read -r name res; do
      [[ -n "$name" ]] || continue
      case "$name" in
        relay|github) [[ "$res" == REACHABLE* ]] && ok live "egress $name via proxy: $res" || fail live "egress $name: $res (must be reachable through the proxy)" ;;
        forge) if (( ISOLATED )); then [[ "$res" == blocked* ]] && ok live "egress forge direct: $res (only the ssh tunnel reaches it)" || warn live "egress forge direct: $res — a direct route to the forge exists"
               else [[ "$res" == REACHABLE* ]] && ok live "egress forge: $res" || fail live "egress forge: $res (must be reachable)"; fi ;;
        *) if [[ "$res" == blocked* ]]; then ok live "egress $name: $res"
           else fail live "egress $name: $res — must be unreachable"; fi ;;
      esac
    done <<<"$eg"
  fi
  # What the agent tried to reach and the proxy refused, from the proxy's own log. Not
  # a failure — a refusal is the control working — but it is the one place that shows
  # which hosts a site may want to allowlist (or which noise to expect).
  pcn=""
  for nid in $(docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{$v.NetworkID}} {{end}}' "$CN" 2>/dev/null); do
    for c in $(docker network inspect --format '{{range .Containers}}{{.Name}} {{end}}' "$nid" 2>/dev/null); do
      # The proxy is the container the agent reaches as `lyngvi-proxy` (its name, or an
    # overlay's alias); the token relay shares the network and must not be mistaken for it.
    [[ "$c" != "$CN" ]] && docker inspect --format '{{range .NetworkSettings.Networks}}{{.Aliases}} {{.DNSNames}} {{end}}' "$c" 2>/dev/null | grep -qw lyngvi-proxy && { pcn="$c"; break 2; }
    done
  done
  if [[ -n "$pcn" ]]; then
    # The refused "host" is whatever the client sent, so it is untrusted text: only a
    # plain hostname is printed; anything else is counted, never echoed to the terminal.
    # Decoy hostnames (proxy/start.sh) are never allowlist candidates; a refusal of one
    # is the CANARY_TOUCHED marker, which the proxy itself wrote.
    canary=$(docker exec "$pcn" cat /canary/hosts 2>/dev/null | grep -E '^[a-z0-9.-]+$' || true)
    touched=$(docker logs "$pcn" 2>&1 | grep -aoE 'CANARY_TOUCHED sev=crit host=[a-z0-9.-]+' | sed 's/.*host=//' | sort | uniq -c | awk '{printf "%s%s×%s", (NR>1?", ":""), $2, $1}')
    if [[ -n "$touched" ]]; then fail live "CANARY_TOUCHED: a decoy credential was used ($touched) — treat the agent as compromised (docs/INCIDENT.md)"
    elif [[ -n "$canary" ]]; then ok live "no decoy credential used since the proxy started"; fi
    if [[ -n "$canary" ]]; then
      # Blank lines and comments are not patterns: an empty pattern would match every name.
      pats=$(docker exec "$pcn" cat /etc/tinyproxy/filter 2>/dev/null | grep -vE '^[[:space:]]*(#|$)')
      hit=""; [[ -n "$pats" ]] && hit=$(grep -Ei -f <(printf '%s\n' "$pats") <<<"$canary" | tr '\n' ' ')
      [[ -z "$hit" ]] || fail live "the allowlist matches a decoy hostname ($hit): a use would connect instead of raising CANARY_TOUCHED"
    fi
    names=$(docker logs --since 24h "$pcn" 2>&1 | grep -aoE 'refused on filtered domain "[^"]+"' | sed -E 's/.*"([^"]+)"/\1/' | LC_ALL=C tr '[:upper:]' '[:lower:]' | grep -vxF -f <(printf '%s\n' "${canary:-\n}") || true)
    refused=$(grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' <<<"$names" | sort | uniq -c | sort -rn | head -n 10 | awk '{printf "%s%s×%s", (NR>1?", ":""), $2, $1}')
    odd=$(grep -cvE '^([a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*)?$' <<<"$names")
    if [[ -n "$refused" ]]; then ok live "proxy ($pcn) refused in the last 24h: $refused (scripts/refused-hosts.sh prints them as allowlist lines)"
    else ok live "proxy ($pcn) refused nothing in the last 24h"; fi
    (( odd > 0 )) && warn live "proxy ($pcn) refused $odd request(s) naming something that is not a hostname — a malformed or hostile client (scripts/refused-hosts.sh shows them escaped)"
  else
    skip live "no proxy container found on $CN's networks — cannot list refused hosts"
  fi
else
  skip live "pass --live to check the running container (markers, hooks, proxy, egress)"
fi

echo "doctor: $FAILS fail, $WARNS warn"
(( FAILS == 0 ))

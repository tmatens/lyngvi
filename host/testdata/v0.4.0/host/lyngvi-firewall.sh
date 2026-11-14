#!/usr/bin/env bash
# lyngvi network containment + default-deny egress (HOST, run as root).
#
#   Review before first run, then TEST with the verification block in HOST_SETUP.md.
#   Idempotent: re-running flushes and rebuilds the LYNGVI_EGRESS chain. Assumes the
#   iptables Docker backend (`docker info` → Firewall Backend: iptables).
#
# Configuration comes from an env file (default /etc/lyngvi/firewall.conf; override
# with LYNGVI_FIREWALL_ENV). firewall.conf.example documents every key. The script
# refuses to run without LYNGVI_SUBNET so a missing file cannot silently apply
# nothing (or the wrong thing).
#
# Model (DESIGN.md, egress):
#   * LYNGVI_EGRESS chain = default-deny allowlist for the agent subnet, jumped to
#     from DOCKER-USER (FORWARD). Anything not RETURNed is dropped, so LAN + other
#     container subnets are blocked automatically.
#   * INPUT rules block container -> host from EVERY agent-attached subnet (incl.
#     the internal proxy segment — its bridge gateway IP is a host address too).
#   * Package registries are NOT allowed here — they go through the hostname-
#     allowlist proxy sidecar, which beats CDN IP rotation.
#
# KNOWN LIMITATION: the relay sits behind a CDN and GitHub's published CIDRs
# ROTATE. This script is point-in-time — the timer re-runs it daily. A miss = an
# install/connection fails closed (safe), not a leak.
#
#   --dry-run   print the iptables/ip6tables commands instead of running them
#               (needs no root; CI diffs this against host/testdata/firewall.expected)
set -euo pipefail

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
if (( ! DRY )); then
  [[ $EUID -eq 0 ]] || { echo "run as root (or --dry-run)" >&2; exit 1; }
fi

ENVFILE="${LYNGVI_FIREWALL_ENV:-/etc/lyngvi/firewall.conf}"
if [[ -f "$ENVFILE" ]]; then
  set -a; # shellcheck disable=SC1090
  . "$ENVFILE"; set +a
fi
: "${LYNGVI_SUBNET:?LYNGVI_SUBNET is unset — nothing to protect; install firewall.conf first}"
LYNGVI_SUBNETS="${LYNGVI_SUBNETS:-$LYNGVI_SUBNET}"   # all agent-attached subnets (INPUT drops + v6 guard)
DNS_RESOLVER="${DNS_RESOLVER:-}"                     # empty = no DNS rule (Docker embedded DNS egresses from the host netns)
ALLOW_443_HOSTS="${ALLOW_443_HOSTS:-api.anthropic.com}"
GITHUB_META="${GITHUB_META:-1}"
FORGE_SSH_HOST="${FORGE_SSH_HOST:-}"
FORGE_SSH_PORT="${FORGE_SSH_PORT:-22}"

log() { echo "[lyngvi-fw] $*"; }
run() { if (( DRY )); then printf '%q ' "$@"; echo; else "$@"; fi; }
# `-C` probes must stay real even in dry-run? No: dry-run has no root. Treat every
# probe as "absent" so the output is the full rule set, deterministic.
probe() { if (( DRY )); then return 1; else "$@" 2>/dev/null; fi; }
resolve() {
  if (( DRY )); then echo "198.51.100.10"; else getent ahostsv4 "$1" | awk '{print $1}' | sort -u; fi
}

# ── LYNGVI_EGRESS: create + flush for idempotent rebuild ─────────────────────
probe iptables -nL LYNGVI_EGRESS >/dev/null || run iptables -N LYNGVI_EGRESS
run iptables -F LYNGVI_EGRESS

# return-path + DNS to the configured resolver only
run iptables -A LYNGVI_EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
if [[ -n "$DNS_RESOLVER" ]]; then
  run iptables -A LYNGVI_EGRESS -d "$DNS_RESOLVER" -p udp --dport 53 -j RETURN
  run iptables -A LYNGVI_EGRESS -d "$DNS_RESOLVER" -p tcp --dport 53 -j RETURN
fi

allow443() { # allow :443 to each resolved IP of a host
  local host="$1" ip
  for ip in $(resolve "$host"); do
    run iptables -A LYNGVI_EGRESS -d "$ip" -p tcp --dport 443 -j RETURN
    log "allow 443 -> $host ($ip)"
  done
}
for h in $ALLOW_443_HOSTS; do allow443 "$h"; done

# GitHub published CIDRs (web/api/git) on :443 — fetched live, may rotate.
if [[ "$GITHUB_META" == "1" ]]; then
  if (( DRY )); then
    GH_CIDRS="192.0.2.0/24"
  else
    log "fetching GitHub meta CIDRs"
    GH_CIDRS="$(curl -fsS --max-time 15 https://api.github.com/meta \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print("\n".join(d.get("web",[])+d.get("api",[])+d.get("git",[])))' \
      | grep -E '^[0-9]+\.' || true)"   # IPv4 only
  fi
  for cidr in $GH_CIDRS; do
    run iptables -A LYNGVI_EGRESS -d "$cidr" -p tcp --dport 443 -j RETURN
  done
  log "allowed $(wc -w <<<"$GH_CIDRS") GitHub IPv4 CIDRs on :443"
fi

# Forge SSH to its resolved IP(s). Matched on the ORIGINAL pre-DNAT destination
# via conntrack: when the forge is a published Docker port on this same host the
# dest is DNAT'd in nat/PREROUTING before FORWARD sees it and a plain `-d` match
# never fires; ctorigdst == the real dst when there is no NAT, so this form works
# for a remote forge too.
if [[ -n "$FORGE_SSH_HOST" ]]; then
  for ip in $(resolve "$FORGE_SSH_HOST"); do
    run iptables -A LYNGVI_EGRESS -p tcp -m conntrack --ctorigdst "$ip" --ctorigdstport "$FORGE_SSH_PORT" -j RETURN
    log "allow $FORGE_SSH_PORT -> $FORGE_SSH_HOST ($ip, via conntrack orig-dst)"
  done
fi

# default-deny (log a little, then drop)
run iptables -A LYNGVI_EGRESS -m limit --limit 6/min -j LOG --log-prefix "lyngvi-egress-drop: "
run iptables -A LYNGVI_EGRESS -j DROP

# ── jump into LYNGVI_EGRESS from DOCKER-USER (insert once) ───────────────────
probe iptables -C DOCKER-USER -s "$LYNGVI_SUBNET" -j LYNGVI_EGRESS \
  || run iptables -I DOCKER-USER -s "$LYNGVI_SUBNET" -j LYNGVI_EGRESS

# ── INPUT: container -> host blocked, from EVERY agent-attached subnet ────────
# Each docker bridge puts a host-owned gateway IP on the segment — including the
# `internal: true` ones (internal only means no NAT/default route). Nothing
# legitimate flows container->host INPUT: forge SSH and DNS (embedded 127.0.0.11,
# forwarded from the HOST netns) both ride other paths.
for s in $LYNGVI_SUBNETS; do
  probe iptables -C INPUT -s "$s" -j DROP || run iptables -I INPUT -s "$s" -j DROP
done

# ── IPv6 fail-closed guard ───────────────────────────────────────────────────
# Everything above is IPv4-only. If the bridges are IPv6-off there is no v6
# egress path — but a future daemon/compose edit turning IPv6 on would silently
# open one with no fail-closed rule. Defensively DROP all IPv6 forwarding from
# the agent bridge interfaces in ip6tables DOCKER-USER: a no-op while v6 is off,
# fail-closed the moment it is ever enabled. Scoped to these bridges only
# (resolved by each subnet's .1 gateway), never a global v6 drop. Guarded so a
# missing ip6tables / absent bridge cannot abort the IPv4 rules already applied.
ipv6_guard() {
  if (( ! DRY )); then
    command -v ip6tables >/dev/null 2>&1 || { log "ip6tables absent — skipping v6 guard"; return 0; }
    ip6tables -nL DOCKER-USER >/dev/null 2>&1 || { log "no ip6tables DOCKER-USER chain — skipping v6 guard"; return 0; }
  fi
  local cidr gw iface
  for cidr in $LYNGVI_SUBNETS; do
    gw="${cidr%.0/24}.1"
    if (( DRY )); then iface="br-dryrun"; else
      iface="$(ip -o -4 addr show 2>/dev/null | awk -v g="$gw/" 'index($4,g)==1{print $2; exit}')"
    fi
    [[ -n "$iface" ]] || continue                          # bridge down — re-run covers it
    probe ip6tables -C DOCKER-USER -i "$iface" -j DROP || run ip6tables -I DOCKER-USER -i "$iface" -j DROP
    log "v6 fail-closed: DROP forward from $iface ($cidr)"
    if (( ! DRY )) && ip -o -6 addr show dev "$iface" scope global 2>/dev/null | grep -q inet6; then
      log "WARNING: $iface ($cidr) has a global IPv6 address — the agent bridges were meant to be v6-off; review egress containment."
    fi
  done
}
ipv6_guard || log "WARNING: IPv6 guard errored (non-fatal); IPv4 containment stands."

log "applied. VERIFY per HOST_SETUP.md before trusting."
log "NOTE: re-run after CDN/GitHub IP rotation, or let the timer do it."

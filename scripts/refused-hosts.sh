#!/usr/bin/env bash
# Prints the hosts the proxy refused as allowlist lines, most-refused first, for a
# person to review and paste into the overlay's site/proxy-filter.extra. A refusal
# is the control working: a host listed here is one the agent TRIED, not one it
# needs. Telemetry and update checks show up too; leave those refused.
#
# A host that an opt-in preset covers (proxy/presets/) is reported as that preset
# instead, which is turned on with the proxy's PROXY_PRESETS build arg.
#
#   scripts/refused-hosts.sh [AGENT_CONTAINER] [SINCE]
#     AGENT_CONTAINER  default: CONTAINER_NAME from site/site.conf, else lyngvi
#     SINCE            docker logs --since value, default 24h
set -euo pipefail

# The upstream checkout (proxy/presets/); LYNGVI_UPSTREAM overrides it when piped over ssh.
UP="${LYNGVI_UPSTREAM:-$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." && pwd)}"
cn="${1:-}"
if [[ -z "$cn" && -f site/site.conf ]]; then
  cn=$(sed -n 's/^CONTAINER_NAME=//p' site/site.conf | tail -n1)
fi
cn="${cn:-lyngvi}"
since="${2:-24h}"

# The proxy is the other container on the agent's networks, as in doctor.sh --live.
pcn=""
for nid in $(docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{$v.NetworkID}} {{end}}' "$cn" 2>/dev/null); do
  for c in $(docker network inspect --format '{{range .Containers}}{{.Name}} {{end}}' "$nid" 2>/dev/null); do
    # The proxy is the container the agent reaches as `lyngvi-proxy` (its name, or an
    # overlay's alias); the token relay shares the network and must not be mistaken for it.
    [[ "$c" != "$cn" ]] && docker inspect --format '{{range .NetworkSettings.Networks}}{{.Aliases}} {{.DNSNames}} {{end}}' "$c" 2>/dev/null | grep -qw lyngvi-proxy && { pcn="$c"; break 2; }
  done
done
[[ -n "$pcn" ]] || { echo "no proxy container found on $cn's networks (is $cn running?)" >&2; exit 1; }

# The refused "host" is whatever the client put in its request line, so it is untrusted
# text: a compromised agent can make the proxy log `^a|[a-z0-9-]+$`, which as an
# allowlist line allows every host, or terminal escape sequences. Only a plain hostname
# is offered as a line; anything else is shown escaped, as a comment, and never offered.
HOST_RE='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'
# Decoy hostnames (proxy/start.sh) are never offered: a refusal of one is CANARY_TOUCHED.
canary=$(docker exec "$pcn" cat /canary/hosts 2>/dev/null | grep -E '^[a-z0-9.-]+$' || true)
names=$(docker logs --since "$since" "$pcn" 2>&1 \
  | grep -aoE 'refused on filtered domain "[^"]+"' | sed -E 's/.*"([^"]+)"/\1/' \
  | LC_ALL=C tr '[:upper:]' '[:lower:]' | grep -vxF -f <(printf '%s\n' "${canary:-\n}") || true)
if docker logs --since "$since" "$pcn" 2>&1 | grep -aq 'CANARY_TOUCHED sev=crit'; then
  echo "# WARNING: a decoy credential was used (CANARY_TOUCHED in $pcn's log). Treat the agent"
  echo "# as compromised before allowlisting anything: docs/INCIDENT.md."
fi
refused=$(grep -E "$HOST_RE" <<<"$names" | sort | uniq -c | sort -rn || true)
odd=$(grep -vE "$HOST_RE" <<<"$names" | grep -v '^$' | LC_ALL=C tr -c '[:print:]\n' '?' | sort | uniq -c | sort -rn || true)
if [[ -z "$refused$odd" ]]; then
  echo "# $pcn refused nothing in the last $since"; exit 0
fi

if [[ -n "$refused" ]]; then
  echo "# Hosts $pcn refused in the last $since. Review each one: add only what the site's"
  echo "# work needs, to site/proxy-filter.extra, one anchored line per host."
  while read -r n host; do
    line="^$(printf '%s' "$host" | sed 's/[.]/\\./g')\$"
    preset=""
    for f in "$UP"/proxy/presets/*.filter; do
      [[ -f "$f" ]] && grep -qxF -- "$line" "$f" && { preset=$(basename "$f" .filter); break; }
    done
    if [[ -n "$preset" ]]; then
      echo "# ${n}x $host: covered by the $preset preset, turn on PROXY_PRESETS=\"$preset\" instead"
    else
      echo "# ${n}x"
      echo "$line"
    fi
  done <<<"$refused"
fi
if [[ -n "$odd" ]]; then
  echo "#"
  echo "# NOT HOSTNAMES — never allowlist these. A client asked the proxy for each of the"
  echo "# following, which no real tool does; a compromised agent probing the filter can."
  echo "# Shown escaped (non-printable bytes as ?):"
  while read -r n what; do echo "#   ${n}x  $what"; done <<<"$odd"
fi

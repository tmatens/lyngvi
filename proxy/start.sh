#!/bin/sh
# start.sh — the proxy's entrypoint: run tinyproxy, and raise CANARY_TOUCHED when it
# refuses a decoy host.
#
# The agent's entrypoint plants decoy credentials (a ~/.netrc machine, a ~/.git-credentials
# line, an ~/.ssh Host with a key of its own). Each one names a hostname that only this
# install knows and that is never allowlisted. A process that harvests and uses one ends
# up asking this proxy for that host and is refused. The refusal is logged here, in the
# proxy's own container, which the agent can neither write to nor stop. So this marker
# holds against a compromised agent in a way the agent-side markers do not (DESIGN.md §10),
# with one caveat: an agent that knows the station can read the names and avoid them.
#
# /canary is a named volume: rw here, read-only in the agent. The names are generated
# once per install, the first time the volume is empty, and look like ordinary internal
# hosts under the reserved `.internal` TLD, so they resolve nowhere and are never
# allowlisted by accident. No volume mounted means no decoys: tinyproxy runs as before.
set -u
CONF=/etc/tinyproxy/tinyproxy.conf
C=/canary/hosts

if [ -d /canary ] && [ -w /canary ] && [ ! -s "$C" ]; then
  rnd() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
  pick() { shift "$(( $(od -An -N1 -tu1 /dev/urandom | tr -d ' ') % $# ))"; printf '%s' "$1"; }
  dom=$(pick corp infra svc ops prod int)
  for p in "$(pick ci build deploy git)" "$(pick vault secrets kms)" "$(pick registry artifacts pkg)"; do
    printf '%s-%s.%s.internal\n' "$p" "$(rnd 3)" "$dom"  # leakcheck:ignore (a generated decoy suffix, not a site host)
  done > "$C.tmp" && chmod 0644 "$C.tmp" && mv "$C.tmp" "$C"
fi

watch() {
  while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$line" in
      *'refused on filtered domain "'*)
        h=${line#*refused on filtered domain \"}; h=${h%%\"*}
        h=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')
        if [ -s "$C" ] && grep -qxF -- "$h" "$C"; then
          printf '[proxy %s] CANARY_TOUCHED sev=crit host=%s: a decoy credential was used; treat the agent as compromised (docs/INCIDENT.md)\n' \
            "$(date -u +%H:%M:%S)" "$h"
        fi ;;
    esac
  done
}

# The pipeline runs in the background so this shell (PID 1) can take the stop signal
# and pass it on: a shell does not run traps while it waits on a foreground pipeline.
tinyproxy -d -c "$CONF" 2>&1 | watch &
trap 'kill -TERM $(pidof tinyproxy) 2>/dev/null' TERM INT
wait

#!/usr/bin/env bash
# Starts the baked forgejo-mcp launcher in an image and checks which tool areas
# it serves: by default admin and repo-settings are off, and site.conf can turn
# them back on (empty) or pick its own list. No forge is contacted: tools/list
# is answered locally. The token is a fixed fake value.
#   scripts/check-forge-mcp-areas.sh IMAGE
set -euo pipefail
image="${1:?usage: $0 IMAGE}"

# $1 = "unset", or the value to set FORGEJO_DISABLED_AREAS to (may be empty).
tools() {
  local env=(-e FORGE_API_TOKEN=ci-fake-token -e FORGE_API_BASE=https://forge.invalid/api/v1)
  [[ "$1" == unset ]] || env+=(-e "FORGEJO_DISABLED_AREAS=$1")
  { printf '%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ci","version":"0"}}}' \
      '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
      '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    sleep 5; } \
  | docker run --rm -i "${env[@]}" --entrypoint /usr/local/bin/forgejo-mcp "$image" 2>/dev/null \
  | python3 -c 'import sys,json
for l in sys.stdin:
    m=json.loads(l)
    if m.get("id")==2: print(" ".join(t["name"] for t in m["result"]["tools"]))'
}

fail=0
expect() { # label, tool list, tool, present|absent
  local have=absent
  [[ " $2 " == *" $3 "* ]] && have=present
  if [[ "$have" == "$4" ]]; then echo "ok   $1: $3 $4"; else echo "FAIL $1: $3 is $have, expected $4"; fail=1; fi
}

default=$(tools unset)
[[ -n "$default" ]] || { echo "FAIL the server listed no tools (did it start?)"; exit 1; }
expect default "$default" get_repo present
expect default "$default" admin_create_user absent
expect default "$default" add_push_mirror absent

all=$(tools "")
expect "empty (every area)" "$all" admin_create_user present
expect "empty (every area)" "$all" add_push_mirror present

own=$(tools admin)
expect "site list (admin)" "$own" admin_create_user absent
expect "site list (admin)" "$own" add_push_mirror present

exit "$fail"

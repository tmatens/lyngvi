#!/usr/bin/env bash
# Starts the baked github-mcp launcher in an image and checks the tools it serves:
# lyngvi's default toolsets (no copilot), no API-commit tools, and that site.conf
# can widen both. No GitHub call is made: tools/list is answered locally, and the
# token is a fixed fake value.
#   scripts/check-github-mcp.sh IMAGE      (an image built with WITH_GITHUB_MCP=1)
set -euo pipefail
image="${1:?usage: $0 IMAGE}"

# $@ = extra docker -e arguments; prints the served tool names on one line.
tools() {
  { printf '%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ci","version":"0"}}}' \
      '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
      '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    sleep 5; } \
  | docker run --rm -i -e GITHUB_TOKEN=ci-fake-token "$@" --entrypoint /usr/local/bin/github-mcp "$image" 2>/dev/null \
  | python3 -c 'import sys,json
for l in sys.stdin:
    try: m=json.loads(l)
    except ValueError: continue
    if m.get("id")==2: print(" ".join(t["name"] for t in m["result"]["tools"]))'
}

fail=0
expect() { # label, tool list, tool, present|absent
  local have=absent
  [[ " $2 " == *" $3 "* ]] && have=present
  if [[ "$have" == "$4" ]]; then echo "ok   $1: $3 $4"; else echo "FAIL $1: $3 is $have, expected $4"; fail=1; fi
}

default=$(tools)
[[ -n "$default" ]] || { echo "FAIL the server listed no tools (did it start?)"; exit 1; }
expect default "$default" create_pull_request present
expect default "$default" issue_write present
expect default "$default" assign_copilot_to_issue absent
expect default "$default" push_files absent
expect default "$default" create_or_update_file absent
expect default "$default" create_repository absent
expect default "$default" actions_list absent

wide=$(tools -e GITHUB_TOOLSETS=context,repos,issues,pull_requests,actions -e GITHUB_EXCLUDE_TOOLS=)
expect "site widens" "$wide" actions_list present
expect "site widens" "$wide" push_files present

exit "$fail"

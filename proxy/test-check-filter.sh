#!/usr/bin/env bash
# proxy/test-check-filter.sh — the allowlist grammar accepts every shipped line and
# refuses the shapes that would widen egress. Run by CI; no network, no docker.
set -euo pipefail
cd "$(dirname "$0")/.."
check=proxy/check-filter.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0

# Everything shipped must pass, including the commented-out examples a site uncomments.
"$check" proxy/filter proxy/presets/*.filter site-example/proxy-filter.extra \
  || { echo "FAIL: a shipped filter line is refused"; fails=1; }
grep -E '^#\^' site-example/proxy-filter.extra | sed 's/^#//' > "$tmp/examples"
"$check" "$tmp/examples" || { echo "FAIL: a commented example line is refused"; fails=1; }

good=('^api\.example\.org$' '^[a-z0-9.-]+\.pythonhosted\.org$' '^productionresultssa[0-9]+\.blob\.core\.windows\.net$' '^localhost$')
bad=('^registry-x|[a-z0-9-]+$'   # alternation: the right half allows every host
     '^github\.com|\.*$'         # same, with a quantifier
     '^example.com$'             # bare dot: any character
     '^(evil|good)\.com$'        # group
     '^[a-z0-9.-]+$'             # wildcard with nothing fixed
     '^[a-z0-9.-]+\.org$'        # wildcard under a TLD only
     '^[^.]+\.github\.com$'      # negated class
     'github\.com'               # unanchored: substring match
     '^github\.com'              # unanchored end
     '^git hub\.com$'            # whitespace
     $'^x\e]52;c;eA==\ay$')      # terminal escape bytes
for l in "${good[@]}"; do printf '%s\n' "$l" > "$tmp/l"; "$check" "$tmp/l" >/dev/null || { echo "FAIL: refused good line: $l"; fails=1; }; done
for l in "${bad[@]}";  do printf '%s\n' "$l" > "$tmp/l"; "$check" "$tmp/l" >/dev/null && { echo "FAIL: accepted bad line: $(printf '%q' "$l")"; fails=1; }; done

# A refused line is reported with its bytes made printable, never raw.
printf '%s\n' $'^x\e]52;c;eA==\ay$' > "$tmp/esc"
out=$("$check" "$tmp/esc" || true)
[[ "$out" == *$'\e'* || "$out" == *$'\a'* ]] && { echo "FAIL: escape bytes echoed raw"; fails=1; }

(( fails == 0 )) && echo "check-filter: ${#good[@]} good, ${#bad[@]} bad, shipped files — all as expected"
exit "$fails"

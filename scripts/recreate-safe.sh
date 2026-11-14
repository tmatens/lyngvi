#!/usr/bin/env bash
# recreate-safe.sh — is now a safe moment to recreate the agent container without
# losing the claude.ai login? Exit 0 = safe, 1 = risky, 2 = cannot tell.
#
# Why it matters: the claude.ai refresh token is single-use and rotates. A process
# refreshes when its access token is about to expire. If the old container refreshes
# just before it is stopped and dies before writing the new pair to the volume, or the
# new container must refresh at start with a refresh token the old one already used, the
# refresh fails with a 401. Then only an interactive /login recovers it
# (docs/REMOTE_CONTROL.md). While the access token has plenty of life left, neither
# process refreshes around the recreate, and the new container starts on the
# credential as it is.
#
# This reads the credential's EXPIRY TIMESTAMP only, in-process, and prints minutes
# left. Never a token.
#
#   scripts/recreate-safe.sh [container] [min_minutes]
#     container    default: CONTAINER_NAME from site/site.conf, else lyngvi
#     min_minutes  default 30: the access token must outlive the recreate by this much
#
# A deploy can gate on it:  scripts/recreate-safe.sh || { echo "wait, or /login first"; exit 1; }
set -euo pipefail
cn="${1:-}"
if [[ -z "$cn" && -f site/site.conf ]]; then cn=$(sed -n 's/^CONTAINER_NAME=//p' site/site.conf | tail -n1); fi
cn="${cn:-lyngvi}"
min="${2:-${RECREATE_MIN_MINUTES:-30}}"

left=$(docker exec "$cn" node -e '
  const fs=require("fs"); const p=(process.env.CLAUDE_CONFIG_DIR||process.env.HOME+"/.claude")+"/.credentials.json";
  try { const o=JSON.parse(fs.readFileSync(p,"utf8")).claudeAiOauth||{};
        console.log(o.expiresAt ? Math.floor((o.expiresAt-Date.now())/60000) : "none"); }
  catch { console.log("none") }' 2>/dev/null || echo "none")

if [[ "$left" == none || -z "$left" ]]; then
  echo "recreate-safe: no claude.ai credential readable in $cn: cannot tell (a fresh station needs /login anyway)"; exit 2
fi
if (( left >= min )); then
  echo "recreate-safe: safe. The access token has ${left} min left (need ${min}): a recreate now starts without a refresh"; exit 0
fi
echo "recreate-safe: RISKY. The access token has ${left} min left (need ${min}): a recreate now may refresh around the restart and lose the login. Wait for the next refresh (the token is renewed shortly before expiry) or recreate right after a /login"
exit 1

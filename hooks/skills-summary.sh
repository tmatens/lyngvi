#!/usr/bin/env bash
# SessionStart hook (any host): surface the currently-installed skills and
# shared-context fragments to the user, each with a short when-to-use line
# parsed live from its own SKILL.md description — no hand-kept list to drift.
#
# Single-sourced in the lyngvi repo (hooks/); the station image runs it from
# /etc/lyngvi/hooks/, wired by its managed settings; a workstation can vendor
# it the same way. JSON is emitted via python3 — present on all hosts,
# unlike jq — and handles quotes in descriptions safely.

skill_desc() {  # full (possibly folded) frontmatter description of $1/SKILL.md
  awk '
    /^---[[:space:]]*$/ { f++; next }
    f==1 && /^description:/ { d=1; sub(/^description:[[:space:]]*>?-?[[:space:]]*/, ""); if (length($0)) desc=$0; next }
    f==1 && d && /^[A-Za-z_-]+:/ { d=0 }
    f==1 && d { gsub(/^[[:space:]]+/, ""); desc = desc (desc ? " " : "") $0 }
    END { print desc }
  ' "$1/SKILL.md"
}

when_line() {  # prefer the "Use when/for/to …" sentence; fall back to sentence 1
  local desc="$1" use
  use=$(sed -n 's/.*\(Use \(when\|for\|to\) \)/\1/p' <<<"$desc" | sed 's/\. .*//')
  [ -z "$use" ] && use="${desc%%. *}"
  [ "${#use}" -gt 120 ] && use="${use:0:117}..."
  printf '%s' "$use"
}

msg="Skills installed:"
for d in "$HOME/.claude/skills"/*/; do
  [ -f "$d/SKILL.md" ] || continue
  msg+=$'\n'"• $(basename "$d") — $(when_line "$(skill_desc "$d")")"
done
for f in "$HOME/.claude/shared-context"/*.md; do
  [ -f "$f" ] || continue
  msg+=$'\n'"• shared-context/$(basename "$f" .md) — always-on working-style rules imported into CLAUDE.md (not a skill)"
done

# Freshness. The entrypoint installs skills once, at container start, and
# records the source commit in skills/.source-sha. A fix merged in the source
# repo an hour later is invisible until the next start, and nothing said so: a
# session followed a skill step that had been corrected upstream days earlier.
# So ask the source where it is now, at every session start, and tell both the
# person and the agent when the installed copy is behind.
#
# One ls-remote, bounded, and silent on any failure: no marker (an image older
# than the entrypoint that writes it, or no SKILLS_REPO), no network, no key.
# A check that cannot run must not delay or fail a session start.
stale=""
sha_file="$HOME/.claude/skills/.source-sha"
repo="${SKILLS_REPO:-}"
[ -z "$repo" ] && repo=$(sed -n 's/^SKILLS_REPO=//p' "${LYNGVI_SITE_DIR:-/etc/lyngvi/site}/site.conf" 2>/dev/null | tail -n1 | sed -e 's/^"//' -e 's/"$//')
if [ -n "$repo" ] && [ -r "$sha_file" ]; then
  have=$(head -n1 "$sha_file" | tr -d '[:space:]')
  now=$(GIT_TERMINAL_PROMPT=0 timeout 5 git ls-remote "$repo" HEAD 2>/dev/null | awk 'NR==1 { print $1 }')
  if [[ "$have" =~ ^[0-9a-f]{40,64}$ && "$now" =~ ^[0-9a-f]{40,64}$ && "$have" != "$now" ]]; then
    stale="Installed skills are out of date: they were installed from ${have:0:7} when the container started, and the skills source is now at ${now:0:7}. A skill on disk may describe steps that have since been corrected. Before following a skill, read its SKILL.md from a fresh clone of the skills source (SKILLS_REPO). A container restart reinstalls them."
    msg+=$'\n'"⚠ $stale"
  fi
fi

# systemMessage reaches the person; additionalContext reaches the agent, which
# is the one that would otherwise follow the stale file.
printf '%s' "$msg" | STALE="$stale" python3 -c '
import json, os, sys
out = {"systemMessage": sys.stdin.read()}
if os.environ.get("STALE"):
    out["hookSpecificOutput"] = {
        "hookEventName": "SessionStart",
        "additionalContext": os.environ["STALE"],
    }
print(json.dumps(out))'
exit 0

#!/bin/sh
# proxy/check-filter.sh — refuse an allowlist line that is not a hostname pattern.
#
#   check-filter.sh FILE...     prints each bad line as `FILE:N: <reason>: <line>` (bytes
#                               outside printable ASCII shown as ?), exit 1 if any
#
# The proxy's filter is an extended regex per line, so any regex is accepted by
# tinyproxy, and one regex can allow every host: `^registry-x|[a-z0-9-]+$` is an
# alternation whose right half matches nearly any name, yet it starts with ^ and ends
# with $. This is the one grammar every line must fit, enforced where it cannot be
# skipped (proxy/Dockerfile fails the build) and where an operator sees it first
# (scripts/doctor.sh):
#
#   ^ ( hostname character | \. | [class]+ )+ $
#
#   hostname character   a-z 0-9 -   (lowercase: the filter is case-insensitive)
#   \.                   a literal dot
#   [class]+             a bracket of a-z 0-9 . - only, then +  (no ^, no ranges
#                        beyond those three), for a rotating label such as
#                        [a-z0-9.-]+\.pythonhosted\.org or productionresultssa[0-9]+
#
# and every bracket must be followed by at least two literal labels (\.name\.tld) before
# the $, so a wildcard always sits under a fixed registrable domain. No |, (, ), *, ?, {,
# bare ., whitespace or backslash other than \. can appear. POSIX sh + grep -E only: it
# runs in the alpine proxy build and on the operator's host.
set -u
bad=0
for f in "$@"; do
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$trimmed" in ''|'#'*) continue ;; esac
    reason=""
    if ! printf '%s\n' "$trimmed" | grep -qE '^\^([a-z0-9-]|\\\.|\[[a-z0-9.-]+\]\+)+\$$'; then
      reason="not a hostname pattern (allowed: a-z 0-9 - \\. and [a-z0-9.-]+, anchored ^...\$)"
    elif printf '%s\n' "$trimmed" | grep -qF ']+'; then
      tail=${trimmed##*]+}
      printf '%s\n' "$tail" | grep -qE '^(\\\.[a-z0-9-]+){2,}\$$' \
        || reason="a wildcard must be followed by at least two literal labels (\\.name\\.tld\$)"
    fi
    if [ -n "$reason" ]; then
      shown=$(printf '%s' "$trimmed" | LC_ALL=C tr -c '[:print:]' '?')
      printf '%s:%s: %s: %s\n' "$f" "$n" "$reason" "$shown"
      bad=1
    fi
  done < "$f"
done
exit "$bad"

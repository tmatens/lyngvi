#!/usr/bin/env bash
# release-notes.sh vX.Y.Z — print that version's section of CHANGELOG.md (without its
# heading), for `gh release create --notes-file -`. Exit 1 if the section is missing or
# empty, so a release is never published with blank notes.
set -euo pipefail
v="${1:?usage: $0 vX.Y.Z}"
cd "$(dirname "$0")/.."
notes=$(awk -v v="$v" '
  $0 ~ "^## " v "( |$)" { on=1; next }
  on && /^## / { exit }
  on { print }' CHANGELOG.md | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
[[ -n "$notes" ]] || { echo "no CHANGELOG.md section for $v" >&2; exit 1; }
printf '%s\n' "$notes"

#!/usr/bin/env bash
# scripts/new-overlay.sh — create a private overlay repo that runs lyngvi unchanged.
#
#   scripts/new-overlay.sh ../my-station                 # upstream at its latest release tag
#   scripts/new-overlay.sh ../my-station --ref v1.2.3
#   scripts/new-overlay.sh ../my-station --upstream git@github.com:you/lyngvi-fork.git
#
# The result (docs/OVERLAY.md) is a git repo with: upstream/ as a submodule pinned to
# --ref, compose.yaml extending upstream's services, site/ copied from upstream's
# site-example/ (every value documented in place), .compose-lint.yml from upstream,
# a validate workflow, renovate.json, a leakcheck denylist and a README whose first
# section is the bootstrap checklist. Nothing is committed: the first commit is yours,
# under your identity and signing key. The directory name becomes the project name.
set -euo pipefail
UP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$UP/templates/overlay"
URL="https://github.com/tmatens/lyngvi.git"; REF=""; DIR=""
while (( $# )); do
  case "$1" in
    --upstream) URL="$2"; shift 2 ;;
    --ref)      REF="$2"; shift 2 ;;
    -h|--help)  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; exit 2 ;;
    *)          [[ -z "$DIR" ]] || { echo "one directory only" >&2; exit 2; }; DIR="$1"; shift ;;
  esac
done
[[ -n "$DIR" ]] || { echo "usage: $0 DIR [--upstream URL] [--ref TAG]" >&2; exit 2; }
if [[ -e "$DIR" ]] && [[ -n "$(ls -A "$DIR" 2>/dev/null)" ]]; then echo "$DIR exists and is not empty" >&2; exit 1; fi
command -v git >/dev/null || { echo "git not found" >&2; exit 1; }

# A local path as the upstream (CI scaffolds from its own checkout) needs git's
# file-transport allowance for submodules; a URL does not.
gitopts=()
[[ -d "$URL" ]] && gitopts=(-c protocol.file.allow=always)

mkdir -p "$DIR"; DIR="$(cd "$DIR" && pwd)"; NAME="$(basename "$DIR")"
git init -q -b main "$DIR"
echo "== submodule upstream/ ← $URL"
git -C "$DIR" "${gitopts[@]}" submodule add -q "$URL" upstream
if [[ -z "$REF" ]]; then
  REF="$(git -C "$DIR/upstream" tag -l 'v*' --sort=-v:refname | head -n1)"
  [[ -n "$REF" ]] || { echo "upstream has no v* tag; pass --ref" >&2; exit 1; }
fi
git -C "$DIR/upstream" -c advice.detachedHead=false checkout -q "$REF"
echo "== upstream at $(git -C "$DIR/upstream" describe --tags --always)"

echo "== site/ from upstream's site-example/, template files, project name $NAME"
cp -R "$DIR/upstream/site-example" "$DIR/site"
cp -R "$TEMPLATE/." "$DIR/"
cp "$DIR/upstream/.compose-lint.yml" "$DIR/.compose-lint.yml"
sed -i "s/my-station/$NAME/g" "$DIR/compose.yaml" "$DIR/README.md"
git -C "$DIR" add -A

cat <<EOF

Created $DIR (nothing committed yet). Next:
  1. edit site/site.conf, site/CLAUDE.md, site/known_hosts, site/proxy-filter.extra (your forge, your push host); build args in compose.yaml
  2. produce .env from your secrets backend (names: upstream/.env.example), mode 0600
  3. upstream/scripts/doctor.sh --online         # then --live after the first start
  4. docker compose up -d --build && docker exec -it lyngvi claude   # Engine >= 28; trust dialog, /login
  5. git commit, push, protect main — README.md has the full checklist
EOF

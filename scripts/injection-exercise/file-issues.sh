#!/usr/bin/env bash
# file-issues.sh — file the issue bodies setup.sh wrote, on the SCRATCH repository.
#
#   GH_TOKEN_FILE=/path/0600-file scripts/injection-exercise/file-issues.sh <clone-dir> <owner/repo>
#
# The token is read from the file in-process and never printed or put on a command line.
set -euo pipefail
dir="${1:?usage: $0 <clone-dir> <owner/repo>}"; repo="${2:?owner/repo}"
[[ -r "${GH_TOKEN_FILE:-}" ]] || { echo "GH_TOKEN_FILE must name a readable 0600 file with the scratch token" >&2; exit 1; }
python3 -I - "$dir/.exercise-issues" "$repo" "$GH_TOKEN_FILE" <<'PY'
import glob, json, os, sys, urllib.request
d, repo, tf = sys.argv[1:]
tok = open(tf).read().strip()
for f in sorted(glob.glob(os.path.join(d, "*.md")), key=lambda p: int(os.path.basename(p)[:-3])):
    title, _, body = open(f).read().partition("\n\n")
    req = urllib.request.Request(f"https://api.github.com/repos/{repo}/issues", method="POST",
        data=json.dumps({"title": title.strip(), "body": body.strip()}).encode(),
        headers={"Authorization": "Bearer " + tok, "Accept": "application/vnd.github+json",
                 "User-Agent": "lyngvi-exercise", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        print("filed", json.load(r)["html_url"])
PY

#!/usr/bin/env python3
# Apply / verify branch protection on the GitHub repos the bot can write.
#
#   Ruleset = "PR-only / block all direct push" (DESIGN.md, branch protection):
#     no one pushes `main` directly (enforce_admins=true), a pull request is
#     required, 0 approvals (solo operator merges his own PRs). The bot can only
#     ever propose via a feature-branch PR.
#
#   This is operator tooling, run from the desktop (NOT from the container).
#   stdlib only. Idempotent: GitHub's PUT .../protection replaces the rule.
#
# Token: a SHORT-LIVED fine-grained PAT with **Administration: write** on these
# repos (the station's runtime PAT must NOT carry it). Mint at github.com -> Settings -> Developer settings ->
# Fine-grained tokens, scoped to just these repos, hand it over without
# persisting:
#     printf '%s' '<TOKEN>' > /tmp/gh_token && chmod 600 /tmp/gh_token
#     python3 scripts/branch_protection_github.py --verify
#     python3 scripts/branch_protection_github.py --apply
#     shred -u /tmp/gh_token
#
# Usage:
#   --verify            show current protection (default, read-only)
#   --dry-run           print the body that WOULD be sent, change nothing
#   --apply             apply the protection rule
#   --token-file PATH   default /tmp/gh_token

import argparse
import json
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
# NOTE on scope: on the Free plan, branch protection enforces on PUBLIC repos only; private
# repos need Pro (personal) or Team (org). Prefer importing scripts/github-main-ruleset.json
# (a ruleset, with no bypass actors) via the UI; this script is the API path for legacy
# branch protection when a ruleset is not an option.

# PR-only / block all direct push. required_pull_request_reviews present (so a PR
# is required) with 0 approvals; enforce_admins true so even the owner must PR.
PROTECTION = {
    "required_status_checks": None,
    "enforce_admins": True,
    "required_pull_request_reviews": {
        "dismiss_stale_reviews": False,
        "require_code_owner_reviews": False,
        "required_approving_review_count": 0,
    },
    "restrictions": None,
    "allow_force_pushes": False,
    "allow_deletions": False,
    "required_linear_history": False,
    "required_conversation_resolution": False,
}


def api(method, path, token, body=None):
    url = API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "lyngvi-branch-protection")
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            payload = json.loads(raw)
        except Exception:
            payload = raw.decode(errors="replace")
        return e.code, payload


def default_branch(owner, repo, token):
    status, info = api("GET", f"/repos/{owner}/{repo}", token)
    if status != 200:
        return None
    return info.get("default_branch") or "main"


def summarize(rule):
    if not isinstance(rule, dict) or "enforce_admins" not in rule:
        return f"  (no protection / {rule})"
    return (
        f"  enforce_admins={rule['enforce_admins'].get('enabled')} "
        f"required_pull_request_reviews="
        f"{'present' if rule.get('required_pull_request_reviews') else 'none'} "
        f"allow_force_pushes={rule.get('allow_force_pushes', {}).get('enabled')}"
    )


def read_token(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError as e:
        sys.exit(f"cannot read token file {path}: {e}")


def main():
    ap = argparse.ArgumentParser(description="GitHub branch protection (PR-only)")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--verify", action="store_true", help="show current protection (default)")
    mode.add_argument("--dry-run", action="store_true", help="print body that would be sent")
    mode.add_argument("--apply", action="store_true", help="apply the rule")
    ap.add_argument("--token-file", default="/tmp/gh_token")
    ap.add_argument("--owner", required=True, help="GitHub user/org that owns the repos")
    ap.add_argument("--repo", action="append", required=True, help="repo name (repeatable)")
    args = ap.parse_args()

    token = read_token(args.token_file)
    status, me = api("GET", "/user", token)
    if status != 200:
        sys.exit(f"token check failed (GET /user -> {status}): {me}")
    print(f"authenticated as: {me.get('login')}\n")

    if args.dry_run:
        print("body that would be PUT to .../branches/<default>/protection:")
        print(json.dumps(PROTECTION, indent=2))
        print()

    failures = 0
    for repo in args.repo:
        branch = default_branch(args.owner, repo, token)
        if branch is None:
            print(f"{repo}: ERROR cannot read repo (token has access?)")
            failures += 1
            continue
        path = f"/repos/{args.owner}/{repo}/branches/{branch}/protection"

        if args.dry_run:
            print(f"{repo} ({branch}): would PUT")
            continue

        if args.apply:
            status, resp = api("PUT", path, token, PROTECTION)
            ok = status == 200
            print(f"{repo} ({branch}): {'OK' if ok else 'FAIL'} ({status})")
            if not ok:
                print(f"    {resp}")
                failures += 1
        else:  # verify (default)
            status, rule = api("GET", path, token)
            print(f"{repo} ({branch}):")
            print(summarize(rule) if status == 200 else f"  (GET -> {status}: {rule})")

    if failures:
        sys.exit(f"\n{failures} repo(s) failed")
    print("\ndone")


if __name__ == "__main__":
    main()

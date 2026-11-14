#!/usr/bin/env python3
"""Fail on AI attribution in the commits and the pull request a change adds.

Attribution here means a line that credits the coding assistant: a co-author
trailer or sign-off naming Claude or Anthropic, a Claude-Session trailer or
claude.ai session link, or a "Generated with/by Claude" footer, and a commit whose
author or committer names it (a forge's squash merge turns a different author into
a co-author line). Human co-author trailers are fine.

Only what the change ADDS is checked: the commits in BASE..HEAD and, on a pull
request, its description. History from before this check is out of scope.

Usage:
  check-attribution.py [--range BASE..HEAD] [--body-env VAR] [--root DIR]

  --range     a git revision range; omitted or with an all-zero BASE (a new
              branch push), nothing is checked from history
  --body-env  name of an environment variable holding the pull request body
              (CI passes it through env, never through the command line)

Output names the commit and the rule, never the matched text. Exit 1 on any hit.
"""
import argparse
import os
import re
import subprocess
import sys

RULES = [
    ("ai-co-author", re.compile(r"^\s*co-authored-by:[^\n]*(claude|anthropic)", re.I | re.M)),
    ("ai-session-trailer", re.compile(r"^\s*claude-session:", re.I | re.M)),
    ("ai-session-link", re.compile(r"claude\.ai/code/session", re.I)),
    ("ai-generated-footer", re.compile(r"generated (with|by) \[?(claude|anthropic)", re.I)),
    ("ai-robot-footer", re.compile("\U0001F916\\s*generated", re.I)),
    ("ai-sign-off", re.compile(r"^\s*signed-off-by:[^\n]*(claude|anthropic)", re.I | re.M)),
]
# A commit's author or committer naming the assistant. A forge's squash merge turns
# every other author into a co-author line, so this is attribution too.
AI_IDENT = re.compile(r"claude|anthropic", re.I)


def rules_hit(text):
    return [name for name, rx in RULES if rx.search(text)]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--range", dest="rng")
    ap.add_argument("--body-env")
    ap.add_argument("--root", default=".")
    args = ap.parse_args()

    hits = []
    rng = args.rng or ""
    base = rng.split("..", 1)[0] if ".." in rng else ""
    if rng and base.strip("0"):
        log = subprocess.run(
            ["git", "-C", args.root, "log", "--format=%H%x00%an <%ae>%x00%cn <%ce>%x00%B%x01", rng],
            capture_output=True, text=True, check=True).stdout
        for rec in log.split("\x01"):
            if rec.count("\x00") < 3:
                continue
            sha, author, committer, body = rec.strip("\n").split("\x00", 3)
            hits += [f"commit {sha[:10]}  rule={r}" for r in rules_hit(body)]
            hits += [f"commit {sha[:10]}  rule=ai-{who}" for who, ident in (("author", author), ("committer", committer))
                     if AI_IDENT.search(ident)]
    if args.body_env:
        hits += [f"pull request description  rule={r}" for r in rules_hit(os.environ.get(args.body_env, ""))]

    for h in hits:
        print(f"FAIL  {h}")
    if hits:
        print("Remove the AI attribution lines: reword the commit(s) or edit the description, "
              "then push again. Human co-author trailers are fine.", file=sys.stderr)
        return 1
    print("check-attribution: no AI attribution in what this change adds")
    return 0


if __name__ == "__main__":
    sys.exit(main())

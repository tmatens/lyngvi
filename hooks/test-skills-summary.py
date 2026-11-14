#!/usr/bin/env python3
"""Tests for skills-summary.sh: it lists installed skills, and says when the copy
installed at container start is behind the skills source. It never fails or stalls a
session start, whatever state the source is in."""
import json, os, pathlib, subprocess, sys, tempfile, time

HOOK = str(pathlib.Path(__file__).with_name("skills-summary.sh"))
fails = 0


def check(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1


def git(cwd, *args):
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.org",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.org",
           "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull}
    return subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + os.devnull,
                           *args], cwd=cwd, env=env, capture_output=True, text=True, check=True).stdout.strip()


with tempfile.TemporaryDirectory() as d:
    d = pathlib.Path(d)
    home = d / "home"
    skill = home / ".claude" / "skills" / "demo"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("---\nname: demo\ndescription: Use when testing the summary.\n---\n")
    marker = home / ".claude" / "skills" / ".source-sha"

    source = d / "source"
    source.mkdir()
    git(source, "init", "-q", "-b", "main")
    (source / "a").write_text("1\n")
    git(source, "add", "a")
    git(source, "commit", "-q", "-m", "one")
    first = git(source, "rev-parse", "HEAD")
    (source / "a").write_text("2\n")
    git(source, "commit", "-q", "-am", "two")
    second = git(source, "rev-parse", "HEAD")

    site = d / "site"
    site.mkdir()

    def fire(repo=None, **extra):
        env = {k: v for k, v in os.environ.items() if k != "SKILLS_REPO"}
        env.update(HOME=str(home), LYNGVI_SITE_DIR=str(site), **extra)
        if repo is not None:
            env["SKILLS_REPO"] = repo
        start = time.monotonic()
        r = subprocess.run([HOOK], capture_output=True, text=True, env=env, timeout=30)
        return r, json.loads(r.stdout or "{}"), time.monotonic() - start

    r, out, _ = fire()
    check("no source configured: exit 0, skills listed, no warning",
          r.returncode == 0 and "demo" in out.get("systemMessage", "")
          and "hookSpecificOutput" not in out and "out of date" not in out["systemMessage"])

    r, out, _ = fire(repo=str(source))
    check("source configured, no marker (older image): no warning",
          r.returncode == 0 and "hookSpecificOutput" not in out)

    marker.write_text(second + "\n")
    r, out, _ = fire(repo=str(source))
    check("installed commit is the source head: no warning",
          r.returncode == 0 and "hookSpecificOutput" not in out
          and "out of date" not in out["systemMessage"])

    marker.write_text(first + "\n")
    r, out, _ = fire(repo=str(source))
    ctx = out.get("hookSpecificOutput", {})
    check("installed commit is behind: the person is told",
          r.returncode == 0 and "out of date" in out["systemMessage"]
          and first[:7] in out["systemMessage"] and second[:7] in out["systemMessage"])
    check("installed commit is behind: the agent is told (SessionStart additionalContext)",
          ctx.get("hookEventName") == "SessionStart" and "fresh clone" in ctx.get("additionalContext", ""))
    check("the warning does not print the source URL", str(source) not in r.stdout)

    (site / "site.conf").write_text('OTHER=x\nSKILLS_REPO="%s"\n' % source)
    r, out, _ = fire()
    check("source read from the baked site.conf when the environment lacks it",
          "hookSpecificOutput" in out)
    (site / "site.conf").unlink()

    r, out, took = fire(repo=str(d / "absent"))
    check("unreachable source: exit 0, skills still listed, no warning",
          r.returncode == 0 and "demo" in out.get("systemMessage", "") and "hookSpecificOutput" not in out)
    check("unreachable source: returns promptly", took < 8)

    marker.write_text("not-a-commit\n")
    r, out, _ = fire(repo=str(source))
    check("marker that is not a commit id: no warning", r.returncode == 0 and "hookSpecificOutput" not in out)

sys.exit(1 if fails else 0)

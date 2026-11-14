#!/usr/bin/env python3
"""Tests for agent/git-hooks (identity, DCO, attribution). Run: python3 scripts/test-git-hooks.py

The hooks read the site from the fixed path /etc/lyngvi/site, on purpose: a path the
agent could set would let it point the check at a site.conf of its own. So the test
copies them into a temporary directory and rewrites that one path to a fixture site.
"""
import os, pathlib, shutil, subprocess, sys, tempfile

SRC = pathlib.Path(__file__).resolve().parent.parent / "agent" / "git-hooks"
SITE_ID = ("Site Bot", "bot@users.noreply.example.org")
REPO_ID = ("Repo Bot", "repo-bot@users.noreply.example.org")


def make_env(tmp, no_ai="0", dco="1"):
    site = tmp / "site"; hooks = tmp / "hooks"
    site.mkdir(); hooks.mkdir()
    (site / "site.conf").write_text(
        f"GIT_AUTHOR_NAME={SITE_ID[0]}\nGIT_AUTHOR_EMAIL={SITE_ID[1]}\n"
        f"GIT_DCO_SIGNOFF={dco}\nGIT_NO_AI_ATTRIBUTION={no_ai}\n")
    (site / "gitconfig").write_text("# no identity here\n")
    (site / "gitconfig-repo").write_text(f"[user]\n\tname = {REPO_ID[0]}\n\temail = {REPO_ID[1]}\n")
    for f in SRC.iterdir():
        text = f.read_text().replace("/etc/lyngvi/site", str(site)).replace("/etc/lyngvi/git-hooks", str(hooks))
        (hooks / f.name).write_text(text)
        (hooks / f.name).chmod(0o755)
    home = tmp / "home"; home.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(HOME=str(home), GIT_CONFIG_NOSYSTEM="1")
    subprocess.run(["git", "config", "--global", "core.hooksPath", str(hooks)], env=env, check=True)
    subprocess.run(["git", "config", "--global", "user.name", SITE_ID[0]], env=env, check=True)
    subprocess.run(["git", "config", "--global", "user.email", SITE_ID[1]], env=env, check=True)
    subprocess.run(["git", "config", "--global", "commit.gpgsign", "false"], env=env, check=True)
    repo = tmp / "repo"; repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], env=env, check=True)
    return env, repo


def commit(env, repo, *args, extra_env=None):
    (repo / "f").write_text(os.urandom(4).hex())
    subprocess.run(["git", "-C", str(repo), "add", "f"], env=env, check=True)
    e = dict(env, **(extra_env or {}))
    p = subprocess.run(["git", "-C", str(repo), "commit", "-q", *args], env=e, capture_output=True, text=True)
    return p.returncode, p.stderr


TRAILER = "Co-Authored-By: Claude Example <noreply@anthropic.com>"
CASES = [
    # (name, site no_ai, commit args, extra env, expect_ok)
    ("own identity", "0", ["-m", "x"], None, True),
    ("author override in env", "0", ["-m", "x"], {"GIT_AUTHOR_EMAIL": "someone@example.org"}, False),
    ("author name override", "0", ["-m", "x"], {"GIT_AUTHOR_NAME": "station-bot"}, False),
    ("committer override", "0", ["-m", "x"], {"GIT_COMMITTER_NAME": "other"}, False),
    ("--author flag", "0", ["-m", "x", "--author", "Other <o@example.org>"], None, False),
    ("foreign sign-off", "0", ["-m", "x", "-m", "Signed-off-by: Other <o@example.org>"], None, False),
    ("own sign-off twice is fine", "0", ["-m", "x", "-m", f"Signed-off-by: {SITE_ID[0]} <{SITE_ID[1]}>"], None, True),
    ("human co-author allowed", "1", ["-m", "x", "-m", "Co-authored-by: A Human <h@example.org>"], None, True),
    ("AI trailer allowed when site permits", "0", ["-m", "x", "-m", TRAILER], None, True),
    ("AI trailer refused when site forbids", "1", ["-m", "x", "-m", TRAILER], None, False),
    ("session trailer refused when site forbids", "1", ["-m", "x", "-m", "Claude-Session: https://claude.ai/code/session_x"], None, False),
]

fails = 0
for name, no_ai, args, extra, expect_ok in CASES:
    with tempfile.TemporaryDirectory() as t:
        env, repo = make_env(pathlib.Path(t), no_ai=no_ai)
        rc, err = commit(env, repo, *args, extra_env=extra)
        if (rc == 0) != expect_ok:
            print(f"  FAIL {name}: exit={rc} expected {'ok' if expect_ok else 'refused'}\n        {err.strip()[:200]}"); fails += 1

# DCO trailer is added with the site identity; off when the site turns it off.
with tempfile.TemporaryDirectory() as t:
    env, repo = make_env(pathlib.Path(t))
    commit(env, repo, "-m", "x")
    body = subprocess.run(["git", "-C", str(repo), "log", "-1", "--format=%B"], env=env, capture_output=True, text=True).stdout
    if f"Signed-off-by: {SITE_ID[0]} <{SITE_ID[1]}>" not in body:
        print("  FAIL DCO trailer missing"); fails += 1
with tempfile.TemporaryDirectory() as t:
    env, repo = make_env(pathlib.Path(t), dco="0")
    commit(env, repo, "-m", "x")
    body = subprocess.run(["git", "-C", str(repo), "log", "-1", "--format=%B"], env=env, capture_output=True, text=True).stdout
    if "Signed-off-by" in body:
        print("  FAIL DCO trailer added although GIT_DCO_SIGNOFF=0"); fails += 1

# A per-path identity from a site gitconfig fragment is accepted, sign-off included.
with tempfile.TemporaryDirectory() as t:
    env, repo = make_env(pathlib.Path(t))
    subprocess.run(["git", "-C", str(repo), "config", "user.name", REPO_ID[0]], env=env, check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", REPO_ID[1]], env=env, check=True)
    rc, err = commit(env, repo, "-m", "x")
    if rc != 0:
        print(f"  FAIL per-path site identity refused: {err.strip()[:200]}"); fails += 1

# A merge commit goes through the same identity check.
with tempfile.TemporaryDirectory() as t:
    env, repo = make_env(pathlib.Path(t))
    commit(env, repo, "-m", "base")
    g = lambda *a, **k: subprocess.run(["git", "-C", str(repo), *a], env=dict(env, **k), capture_output=True, text=True)
    main = g("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    g("switch", "-q", "-c", "side"); commit(env, repo, "-m", "side"); g("switch", "-q", main); commit(env, repo, "-m", "main2")
    p = g("merge", "--no-ff", "--no-edit", "side", GIT_COMMITTER_EMAIL="someone@example.org")
    if p.returncode == 0:
        print("  FAIL merge commit under a foreign committer was accepted"); fails += 1

total = len(CASES) + 4
print(f"\n{total - fails}/{total} passed" + ("" if fails else "  — OK"))
sys.exit(1 if fails else 0)

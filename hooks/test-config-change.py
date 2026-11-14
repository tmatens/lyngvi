#!/usr/bin/env python3
"""Tests for config-change.sh: it warns when a settings file gains a permission rule,
stays quiet otherwise, never blocks, and never prints anything but rule strings."""
import json, os, pathlib, subprocess, sys, tempfile

HOOK = str(pathlib.Path(__file__).with_name("config-change.sh"))
fails = 0


def check(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1


with tempfile.TemporaryDirectory() as d:
    d = pathlib.Path(d)
    log = d / "container.log"
    env = {k: v for k, v in os.environ.items() if not k.startswith("NOTIFY_")}
    env.update(LYNGVI_MARKER_LOG=str(log), LYNGVI_STATE_DIR=str(d / "state"), HOME=str(d))
    settings = d / "ws" / ".claude" / "settings.local.json"
    settings.parent.mkdir(parents=True)

    def fire(source="local_settings", path=settings, content=None):
        if content is not None:
            path.write_text(json.dumps(content) if not isinstance(content, str) else content)
        before = log.read_text() if log.exists() else ""
        r = subprocess.run([HOOK], input=json.dumps({"hook_event_name": "ConfigChange", "source": source,
                                                      "file_path": str(path)}),
                           capture_output=True, text=True, env=env, timeout=20)
        after = log.read_text() if log.exists() else ""
        return r, after[len(before):]

    r, new = fire(content={"permissions": {"allow": ["Bash(echo one)"]}})
    check("added allow rule: exit 0 (never blocks)", r.returncode == 0)
    check("added allow rule: CONFIG_CHANGED sev=warn marker in the container log",
          "CONFIG_CHANGED sev=warn" in new and "Bash(echo one)" in new)
    msg = json.loads(r.stdout or "{}").get("systemMessage", "")
    check("added allow rule: systemMessage names the rule and the runbook",
          "Bash(echo one)" in msg and "INCIDENT.md" in msg)

    r, new = fire(content={"permissions": {"allow": ["Bash(echo one)"]}})
    check("same rules again: quiet", new == "" and r.stdout.strip() == "")

    r, new = fire(content={"permissions": {"allow": []}})
    check("rule removed: quiet", new == "" and r.stdout.strip() == "")

    r, new = fire(content={"permissions": {"allow": ["Bash(echo one)"]}})
    check("rule re-added after removal: warned again", "Bash(echo one)" in new)

    r, new = fire(content={"permissions": {"allow": ["Bash(echo one)", "Bash(curl *)"]}})
    check("second rule: only the new one is named", "Bash(curl *)" in new and "echo one" not in new.split("rule(s):")[1])

    r, new = fire(content={"permissions": {"allow": ["Bash(echo one)", "Bash(curl *)"]},
                           "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "x"}]}]}})
    check("hooks added: warned", "hooks added or changed" in new)

    r, new = fire(content={"permissions": {"allow": ["Bash(echo one)", "Bash(curl *)"], "defaultMode": "acceptEdits"},
                           "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "x"}]}]}})
    check("defaultMode set: warned", "defaultMode set to acceptEdits" in new)

    r, new = fire(content={"permissions": {"allow": ["Bash(echo one)", "Bash(curl *)"], "defaultMode": "acceptEdits",
                                           "additionalDirectories": ["/etc"]},
                           "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "x"}]}]}})
    check("additionalDirectories added: warned", "new additionalDirectories: /etc" in new)

    r, new = fire(content={"permissions": {"allow": ["Bash(echo one)", "Bash(curl *)"], "defaultMode": "acceptEdits",
                                           "additionalDirectories": ["/etc"]},
                           "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "x"}]}]},
                           "env": {"SOME_TOKEN": "s3cr3t-value-never-printed"}, "model": "x"})
    check("unrelated keys (env, model): quiet, and no env value printed",
          new == "" and "s3cr3t" not in r.stdout)

    r, new = fire(content={"permissions": {"allow": ["Bash(echo one)", "Bash(curl *)", "Bash(\x1b[31mevil\x07)"]},
                           "env": {"SOME_TOKEN": "s3cr3t-value-never-printed"}})
    check("control characters in a rule are neutralised", "\x1b" not in new and "\x07" not in new and "evil" in new)
    check("an env value in the same file is never printed", "s3cr3t" not in new and "s3cr3t" not in r.stdout)

    r, new = fire(content={"permissions": {"allow": [f"Bash(echo {i})" for i in range(30)]}})
    check("many rules: list capped", "more)" in new and len(new) < 4000)

    for src in ("skills", "policy_settings"):
        r, new = fire(source=src, content={"permissions": {"allow": ["Bash(rm -rf /)"]}})
        check(f"source {src}: ignored", new == "" and r.returncode == 0 and r.stdout.strip() == "")

    r, new = fire(content="{ not json")
    check("unparseable file: quiet, exit 0", new == "" and r.returncode == 0)

    r = subprocess.run([HOOK], input="garbage", capture_output=True, text=True, env=env, timeout=20)
    check("garbage event: fails open (exit 0, no output)", r.returncode == 0 and r.stdout.strip() == "")

    other = d / "proj" / ".claude" / "settings.json"
    other.parent.mkdir(parents=True)
    r, new = fire(source="project_settings", path=other, content={"permissions": {"allow": ["Bash(make *)"]}})
    check("project_settings in another repo: tracked separately and warned", "Bash(make *)" in new and "project_settings" in new)

    r, new = fire(source="local_settings", path=d / "gone" / "settings.local.json")
    check("deleted file: quiet", new == "")

# ── the --scan mode (the gap the CLI's watcher leaves: another repository, between sessions)
with tempfile.TemporaryDirectory() as d:
    d = pathlib.Path(d)
    log = d / "container.log"
    env = {k: v for k, v in os.environ.items() if not k.startswith("NOTIFY_")}
    env.update(LYNGVI_MARKER_LOG=str(log), LYNGVI_STATE_DIR=str(d / "state"), HOME=str(d),
               CLAUDE_CONFIG_DIR=str(d / "cfg"))
    ws = d / "workspace"
    (d / "cfg").mkdir()

    def scan():
        before = log.read_text() if log.exists() else ""
        r = subprocess.run([HOOK, "--scan", str(ws)], capture_output=True, text=True, env=env, timeout=30)
        after = log.read_text() if log.exists() else ""
        return r, after[len(before):]

    def put(rel, content):
        f = ws / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps(content))
        return f

    ws.mkdir()
    r, new = scan()
    check("scan, empty workspace: quiet, exit 0, no stdout", new == "" and r.returncode == 0 and r.stdout == "")

    a = put("repo-a/.claude/settings.local.json", {"permissions": {"allow": ["Bash(curl *)"]}})
    r, new = scan()
    check("scan: a rule in a workspace repository raises CONFIG_CHANGED",
          "CONFIG_CHANGED sev=warn local_settings" in new and "Bash(curl *)" in new and "(workspace scan)" in new)
    r, new = scan()
    check("scan: the same rule is reported once", new == "")

    put("deep/x/y/z/repo-b/.claude/settings.json", {"permissions": {"allow": ["Bash(make *)"]}})
    r, new = scan()
    check("scan: nested repository found, as project_settings", "project_settings" in new and "Bash(make *)" in new)

    put("too/deep/a/b/c/d/repo/.claude/settings.json", {"permissions": {"allow": ["Bash(deep)"]}})
    put("x/node_modules/pkg/.claude/settings.json", {"permissions": {"allow": ["Bash(nm)"]}})
    put("x/.git/.claude/settings.json", {"permissions": {"allow": ["Bash(git)"]}})
    r, new = scan()
    check("scan: depth limit and skipped dirs match doctor", new == "")

    put("repo-a/.claude/settings.local.json", {"permissions": {"allow": ["Bash(curl *)"]},
                                              "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x"}]}]},
                                              "env": {"T": "s3cr3t-value-never-printed"}})
    r, new = scan()
    check("scan: hooks added in a known file are reported, env never printed",
          "hooks added or changed" in new and "s3cr3t" not in new)

    # The hook and the scan share one record: what the hook reported, the scan does not repeat.
    c = put("repo-c/.claude/settings.local.json", {"permissions": {"allow": ["Bash(echo hook-first)"]}})
    subprocess.run([HOOK], input=json.dumps({"hook_event_name": "ConfigChange", "source": "local_settings",
                                             "file_path": str(c)}), capture_output=True, text=True, env=env, timeout=20)
    r, new = scan()
    check("scan after the hook reported the rule: quiet (one report per rule)", new == "")

    import shutil
    shutil.rmtree(ws / "repo-a")
    r, new = scan()
    check("scan: a deleted repository is quiet", new == "")
    put("repo-a/.claude/settings.local.json", {"permissions": {"allow": ["Bash(curl *)"]}})
    r, new = scan()
    check("scan: the same rule written again after the repository was deleted is reported again", "Bash(curl *)" in new)

    (d / "cfg" / "settings.json").write_text(json.dumps({"permissions": {"defaultMode": "acceptEdits"}}))
    r, new = scan()
    check("scan: the user settings are covered too", "user_settings" in new and "defaultMode set to acceptEdits" in new)

    put("bad/.claude/settings.json", {"permissions": {"allow": ["x"]}}).write_text("{ nope")
    r, new = scan()
    check("scan: an unparseable file is skipped, exit 0", r.returncode == 0 and new == "")

    r = subprocess.run([HOOK, "--scan", str(d / "missing")], capture_output=True, text=True, env=env, timeout=30)
    check("scan of a missing root: exit 0, no output", r.returncode == 0 and r.stdout == "")

print(f"\n{fails} failure(s)")
sys.exit(1 if fails else 0)

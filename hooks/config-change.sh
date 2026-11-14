#!/usr/bin/env python3
"""ConfigChange hook: tell the operator when a settings file gains a permission rule.

Wire as a ConfigChange hook with matcher `user_settings|project_settings|local_settings`.

WHY THIS EXISTS. Permission rules in a workspace's `.claude/settings.json` or
`settings.local.json` persist across sessions. So a session fed hostile instructions can
leave an allow rule that a later session uses without asking. The CLI's own path
protection stops the agent's Write and shell-redirect edits of those files, but not an
interpreter writing them. The station keeps that persistence opt-in to block
(`allowManagedPermissionRulesOnly`, DESIGN.md §4.5), so this hook makes it visible
instead.

WHAT IT DOES. Claude Code runs it when its file watcher sees a settings file change during a
session. The event carries `source` and `file_path`, and the watcher sees every writer,
interpreters included. When the change ADDS a permission allow rule, adds or changes hooks,
or changes `defaultMode` or `additionalDirectories`, the hook does three things:

  * writes a `CONFIG_CHANGED sev=warn` marker to the container log, for the generic
    log-alert rule (DESIGN.md §10);
  * pushes the same marker through notify.mjs when the site configured a target;
  * shows the operator a systemMessage in the session.

Removals and unrelated edits stay quiet, and `skills` / `policy_settings` events are ignored.

WHAT IT DOES NOT DO. It never blocks. Blocking only stops the running session from
reloading the change ("the file itself was not touched"), so the next session would load it
anyway. That would hide the problem rather than stop it. It is a fault signal, not a
control against a compromised agent (DESIGN.md §10): an agent that knows about it can
avoid it, for example by writing between sessions. `scripts/doctor.sh --live` lists the
workspace rules as the backstop.

THE SCAN. The CLI's watcher covers only the settings of the session's OWN project, so an
interpreter writing into ANOTHER repository's `.claude/` (or anything writing between
sessions) is invisible to it. `config-change.sh --scan [root]` closes that gap: it walks the
workspace the way `doctor --live` lists it (depth 5, skipping `.git` and `node_modules`),
plus the user settings, and runs the same comparison against the same state. The
entrypoint runs it every LYNGVI_CONFIG_SCAN_INTERVAL seconds. A rule is reported once,
whichever path sees it first. A rule already present when the scan first sees a file is
reported too: it is new to the station's record.

It never prints anything from the file except rule strings and setting names. Rule
strings are cut to printable text and a fixed length, because the file is agent-written
and untrusted. It fails open and silently: a crash must not break the session.
"""
import fcntl
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time

WATCHED = {"user_settings", "project_settings", "local_settings"}
MAX_RULE = 160
MAX_LIST = 8


def clean(s):
    s = "".join(ch if ch.isprintable() else "?" for ch in str(s))
    return s if len(s) <= MAX_RULE else s[: MAX_RULE - 1] + "…"


def facts(path):
    """The security-relevant parts of a settings file, or None if it is unreadable."""
    try:
        data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        data = {}
    except Exception:
        return None
    if not isinstance(data, dict):
        return None
    perms = data.get("permissions") if isinstance(data.get("permissions"), dict) else {}
    allow = perms.get("allow") if isinstance(perms.get("allow"), list) else []
    return {
        "allow": sorted({clean(r) for r in allow}),
        "hooks": hashlib.sha256(json.dumps(data.get("hooks"), sort_keys=True).encode()).hexdigest()
        if "hooks" in data else None,
        "defaultMode": clean(perms.get("defaultMode", "")) or None,
        "additionalDirectories": sorted(clean(d) for d in perms.get("additionalDirectories", []) or [])
        if isinstance(perms.get("additionalDirectories"), list) else [],
    }


def state_dir():
    # In the claude-home volume, so a recreate does not make every existing rule look new.
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or str(pathlib.Path.home() / ".claude")
    base = pathlib.Path(os.environ.get("LYNGVI_STATE_DIR") or (pathlib.Path(cfg) / "lyngvi-config-state"))
    base.mkdir(parents=True, exist_ok=True)
    return base


def state_file(path):
    return state_dir() / (hashlib.sha256(str(path).encode()).hexdigest()[:24] + ".json")


def emit(marker_line, message):
    # The container log is PID 1's stdout; a hook's own stdout belongs to the CLI.
    target = os.environ.get("LYNGVI_MARKER_LOG", "/proc/1/fd/1")
    stamp = time.strftime("%H:%M:%S", time.gmtime())
    try:
        with open(target, "a", encoding="utf-8") as f:
            f.write(f"[config-change {stamp}] {marker_line}\n")
    except OSError:
        pass
    if os.environ.get("NOTIFY_URL") or os.environ.get("NOTIFY_CMD"):
        notify = os.environ.get("LYNGVI_NOTIFY", "/etc/lyngvi/notify.mjs")
        if os.path.exists(notify):
            try:
                subprocess.Popen(["node", notify, "CONFIG_CHANGED", "warn", message],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
            except OSError:
                pass


EMPTY = {"allow": [], "hooks": None, "defaultMode": None, "additionalDirectories": []}


def compare(source, path):
    """Record the file's current facts and return a summary of what it gained, or None.

    Held under a lock, so the hook and the scan never both report one change."""
    path = os.path.abspath(path)
    now = facts(path)
    if now is None:
        return None
    with open(state_dir() / ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        sf = state_file(path)
        try:
            before = json.loads(sf.read_text(encoding="utf-8"))
        except Exception:
            before = EMPTY
        tmp = sf.with_suffix(".tmp")
        tmp.write_text(json.dumps({**now, "path": path}), encoding="utf-8")
        tmp.replace(sf)

    changes = []
    added = [r for r in now["allow"] if r not in set(before.get("allow", []))]
    if added:
        shown = ", ".join(added[:MAX_LIST]) + (f" (+{len(added) - MAX_LIST} more)" if len(added) > MAX_LIST else "")
        changes.append(f"new allow rule(s): {shown}")
    if now["hooks"] != before.get("hooks") and now["hooks"] is not None:
        changes.append("hooks added or changed")
    if now["defaultMode"] != before.get("defaultMode") and now["defaultMode"]:
        changes.append(f"defaultMode set to {now['defaultMode']}")
    new_dirs = [d for d in now["additionalDirectories"] if d not in set(before.get("additionalDirectories", []))]
    if new_dirs:
        changes.append("new additionalDirectories: " + ", ".join(new_dirs[:MAX_LIST]))
    if not changes:
        return None
    return f"{source} {clean(path)}: " + "; ".join(changes)


def main():
    event = json.load(sys.stdin)
    source = event.get("source")
    path = event.get("file_path")
    if source not in WATCHED or not path:
        return
    summary = compare(source, path)
    if not summary:
        return
    emit(f"CONFIG_CHANGED sev=warn {summary}", summary)
    print(json.dumps({"systemMessage": (
        f"Settings changed ({summary}). This persists into future sessions. If you did not "
        "grant it, remove it and see docs/INCIDENT.md.")}))


SCAN_DEPTH = 5
SCAN_SKIP = {".git", "node_modules"}


def scan_paths(root):
    """Every workspace settings file, walked like doctor --live lists them."""
    out = []

    def walk(d, depth):
        if depth > SCAN_DEPTH:
            return
        try:
            entries = list(os.scandir(d))
        except OSError:
            return
        for e in entries:
            if not e.is_dir(follow_symlinks=False):
                continue
            if e.name == ".claude":
                out.append((os.path.join(e.path, "settings.json"), "project_settings"))
                out.append((os.path.join(e.path, "settings.local.json"), "local_settings"))
            elif e.name not in SCAN_SKIP:
                walk(e.path, depth + 1)

    walk(root, 0)
    return out


def scan(root):
    """One pass: report what any settings file gained since the last look, from any writer."""
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or str(pathlib.Path.home() / ".claude")
    targets = scan_paths(root) + [(os.path.join(cfg, "settings.json"), "user_settings")]
    seen = {os.path.abspath(p) for p, _ in targets}
    # A tracked file that has gone (a repository deleted) is recorded as empty, so the same
    # rule written there again is reported again.
    root_abs = os.path.abspath(root) + os.sep
    for sf in state_dir().glob("*.json"):
        try:
            p = json.loads(sf.read_text(encoding="utf-8")).get("path")
        except Exception:
            continue
        if isinstance(p, str) and p.startswith(root_abs) and p not in seen:
            targets.append((p, "local_settings" if p.endswith(".local.json") else "project_settings"))
    for path, source in targets:
        if not os.path.exists(path) and not state_file(os.path.abspath(path)).exists():
            continue
        try:
            summary = compare(source, path)
        except Exception:
            continue
        if summary:
            emit(f"CONFIG_CHANGED sev=warn {summary} (workspace scan)", summary)


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["--scan"]:
            scan(sys.argv[2] if len(sys.argv) > 2 else str(pathlib.Path.home() / "workspace"))
        else:
            main()
    except Exception:  # fail open: a settings change must never break the session or the scan loop
        pass
    sys.exit(0)

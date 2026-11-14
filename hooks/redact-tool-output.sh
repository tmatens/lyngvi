#!/usr/bin/env python3
"""PostToolUse filter: redact secrets from tool output before the model sees it.

Wire as a PostToolUse hook with no matcher (every tool), or at least
`Bash|Read|Grep|WebFetch|mcp__.*`.

WHY THIS EXISTS. block-secret-dumps.sh stops the command shapes that have
leak in practice, but it only sees the command, never what the command prints. Every
leak we have seen was a secret riding along in output read for another reason, and an
unfamiliar command shape walks straight past a PreToolUse guard. This hook
looks at the result instead: it runs gitleaks over every string in the tool's
response and, if anything matches, hands Claude a copy with each match replaced
by ``<REDACTED:rule-id>``.

HOW. The response is walked recursively and only string leaves are rewritten,
so the replacement has exactly the shape of the original. That matters: Claude
Code silently IGNORES an ``updatedToolOutput`` that doesn't match a built-in
tool's output schema and shows the original, so a shape change would turn this
filter off without any error. test-redact-tool-output.py pins the shapes.

DESIGN NOTES.

  * Fail OPEN, loudly. A crash or a missing gitleaks must not wedge every tool
    call, so errors exit 0 and the original output goes through. Unlike a
    blocking guard, a fail-open here means a secret can reach the model, so the
    first failure in each session is announced to the user (systemMessage),
    not just logged.
  * Never echo a secret. Nothing found is written to stderr, a log or the
    message; the user is told which rules fired and how many times, never what
    matched.
  * Detection is gitleaks' default ruleset plus the formats it lacks (see
    redact-tool-output.gitleaks.toml). gitleaks comes from the host: a distro
    package on a workstation, a digest-pinned COPY in the station image.
  * Portable: python3 and gitleaks only, no jq, $HOME-relative.

WHAT IT CANNOT DO (from the hooks reference, and why the other rules stand):

  * It only changes what the model sees. The tool has already run, and Claude
    Code's transcript, telemetry and tool spans record the original output
    before this hook fires. It keeps secrets out of context, not off disk.
  * It does not see prompts. A secret pasted by the user cannot be redacted.
  * Pattern-based: a secret with no recognisable shape (a short password with
    no key name next to it) passes. Treat it as a seatbelt, not a wall.
"""

import base64
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
CONFIG = HERE / "redact-tool-output.gitleaks.toml"
TIMEOUT_S = 8
MAX_SCAN_BYTES = 8 * 1024 * 1024  # bigger outputs are scanned up to this size
SESSION = None  # set from the payload, used by the fail-open warning


def find_gitleaks():
    found = shutil.which("gitleaks")
    if found:
        return found
    # Hooks inherit Claude Code's PATH, which covers /usr/bin and /usr/local/bin on
    # both hosts; ~/.local/bin is the one common install spot it may lack.
    cand = pathlib.Path.home() / ".local/bin/gitleaks"
    if cand.is_file() and os.access(cand, os.X_OK):
        return str(cand)
    return None


def strings_in(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from strings_in(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from strings_in(v)


def replace_in(obj, subs):
    if isinstance(obj, str):
        for secret, label in subs:
            if secret in obj:
                obj = obj.replace(secret, label)
        return obj
    if isinstance(obj, dict):
        return {k: replace_in(v, subs) for k, v in obj.items()}
    if isinstance(obj, list):
        return [replace_in(v, subs) for v in obj]
    return obj


def scan(gitleaks, text):
    """Return gitleaks findings for text (list of dicts with RuleID/Secret/Match)."""
    cmd = [gitleaks, "stdin", "--no-banner", "--log-level", "error",
           "--report-format", "json", "--report-path", "-", "--exit-code", "0"]
    if CONFIG.is_file():
        cmd += ["--config", str(CONFIG)]
    p = subprocess.run(cmd, input=text, capture_output=True, text=True, timeout=TIMEOUT_S)
    if p.returncode != 0:
        raise RuntimeError(f"gitleaks exited {p.returncode}")
    return json.loads(p.stdout or "[]")


# Literal values. A pattern cannot tell a 40-hex forge token from a commit SHA, or a
# base64-wrapped key from any other base64, but this process knows the actual values:
# hooks inherit the CLI's environment, which holds every secret the host was started
# with, and the CLI's OAuth credential is a file in its config dir. Each such value is
# replaced wherever it appears, whatever its shape, with or without gitleaks.
SECRET_ENV_NAME = re.compile(
    r"(TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|CREDENTIAL|API_?KEY|PRIVATE_?KEY|_B64$|^NOTIFY_URL$)",
    re.I)
NOT_SECRET_ENV_NAME = re.compile(r"(_SOCK|_FILE|_PATH|_DIR)$", re.I)
MIN_LITERAL = 12  # shorter values would match ordinary text


def literal_secrets():
    """{value: label} for the secrets this host actually holds. Never logged."""
    vals = {}
    for name, value in os.environ.items():
        if not value or len(value) < MIN_LITERAL:
            continue
        if not SECRET_ENV_NAME.search(name) or NOT_SECRET_ENV_NAME.search(name):
            continue
        vals.setdefault(value, f"env:{name}")
        if name.upper().endswith("_B64"):
            # a key delivered base64 is also on disk decoded: catch that form too
            try:
                decoded = base64.b64decode(value, validate=True).decode()
                for line in decoded.splitlines():
                    if len(line) >= MIN_LITERAL and not line.startswith("-----"):
                        vals.setdefault(line, f"env:{name}")
            except (ValueError, UnicodeDecodeError):
                pass
    dirs = [os.environ.get("CLAUDE_CONFIG_DIR"), str(pathlib.Path.home() / ".claude")]
    for d in filter(None, dirs):
        try:
            oauth = json.loads((pathlib.Path(d) / ".credentials.json").read_text()).get("claudeAiOauth") or {}
        except (OSError, ValueError, AttributeError):
            continue
        for key in ("accessToken", "refreshToken"):
            v = oauth.get(key)
            if isinstance(v, str) and len(v) >= MIN_LITERAL:
                vals.setdefault(v, "claude-oauth-" + key)
    return vals


def warn_once(session_id, message, emit=True):
    """Tell the user about a fail-open, once per session (no spam on every call).

    With emit=False the message is returned instead of printed (None when this
    session was already warned), so main() can fold it into its one JSON output:
    two JSON objects on stdout is not a hook result Claude Code can parse."""
    stamp_dir = pathlib.Path(tempfile.gettempdir()) / f"redact-tool-output-{os.getuid()}"
    try:
        stamp_dir.mkdir(mode=0o700, exist_ok=True)
        stamp = stamp_dir / (str(session_id or "nosession").replace("/", "_") + ".warned")
        if stamp.exists():
            return None
        stamp.touch()
    except OSError:
        pass
    if emit:
        print(json.dumps({"systemMessage": message}))
    return message


def main():
    payload = json.load(sys.stdin)
    response = payload.get("tool_response")
    if response is None:
        return
    global SESSION
    session = SESSION = payload.get("session_id")

    text = "\n".join(strings_in(response))
    if not text.strip():
        return

    # The host's own secrets first: exact values, no scanner needed, so they are
    # redacted even when gitleaks is missing.
    subs, counts = {}, {}
    for value, label in literal_secrets().items():
        if value in text:
            subs.setdefault(value, f"<REDACTED:{label}>")
            counts[label] = counts.get(label, 0) + 1

    gitleaks = find_gitleaks()
    findings, notice = [], None
    if gitleaks:
        findings = scan(gitleaks, text[:MAX_SCAN_BYTES])
    else:
        notice = warn_once(session, emit=False, message="redact-tool-output: gitleaks not found — tool output is only "
                           "checked for this host's own secret values, not scanned for "
                           "other secrets, this session. Install gitleaks to enable it.")

    # Replace the narrow secret where gitleaks isolated one, else the whole match.
    # Longest first, so a secret that contains another is replaced intact.
    for f in findings:
        rule = f.get("RuleID", "secret")
        for value in (f.get("Secret"), f.get("Match")):
            if value and len(value) >= 6 and value in text:
                subs.setdefault(value, f"<REDACTED:{rule}>")
                break
        counts[rule] = counts.get(rule, 0) + 1
    if not subs:
        if notice:
            print(json.dumps({"systemMessage": notice}))
        return
    ordered = sorted(subs.items(), key=lambda kv: len(kv[0]), reverse=True)

    summary = ", ".join(f"{rule} x{n}" for rule, n in sorted(counts.items()))
    message = (f"redact-tool-output: redacted {sum(counts.values())} secret(s) "
               f"from {payload.get('tool_name', 'tool')} output ({summary}).")
    print(json.dumps({
        "systemMessage": message + (" " + notice if notice else ""),
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "updatedToolOutput": replace_in(response, ordered),
        },
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # fail open, but say so: a silent failure here leaks
        try:
            warn_once(SESSION, f"redact-tool-output: internal error ({type(e).__name__}) — this "
                           f"tool output was NOT scanned for secrets.")
        except Exception:
            pass
        print(f"redact-tool-output: {type(e).__name__}: failing open", file=sys.stderr)
    sys.exit(0)

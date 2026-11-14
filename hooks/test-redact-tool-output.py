#!/usr/bin/env python3
# leakcheck:ignore-file — this file deliberately contains the patterns the leak check looks for
"""Tests for redact-tool-output.sh. Run: python3 shared-hooks/test-redact-tool-output.py

Needs gitleaks on PATH (or GITLEAKS_DIR pointing at a directory holding it).

Three things are pinned here, and the second matters most:

  * secrets are replaced, for every credential shape the hook is meant to catch;
  * the replacement has EXACTLY the shape of the original response. Claude Code
    silently ignores an updatedToolOutput that doesn't match a built-in tool's
    schema and shows the original, so a shape change would disable the filter
    with no error anywhere;
  * ordinary output (digests, SHAs, sops ciphertext...) is left untouched, and
    a missing gitleaks fails open with a warning instead of breaking the call.

Every secret below is generated at runtime from random characters: nothing in
this file is, or ever was, a real credential.
"""
import json, os, pathlib, random, string, subprocess, sys

HOOK = str(pathlib.Path(__file__).with_name("redact-tool-output.sh"))
ENV = dict(os.environ)
if os.environ.get("GITLEAKS_DIR"):
    ENV["PATH"] = os.environ["GITLEAKS_DIR"] + os.pathsep + ENV.get("PATH", "")

rng = random.Random(7)
def rnd(n, alphabet=string.ascii_letters + string.digits):
    return "".join(rng.choice(alphabet) for _ in range(n))
HEX = "0123456789abcdef"

SECRETS = {
    "github-pat": "ghp_" + rnd(36),
    "slack-bot-token": "xoxb-1234567890-1234567890123-" + rnd(24),
    "tailscale-key": "tskey-auth-" + rnd(17) + "-" + rnd(33),
    "age-secret-key": "AGE-SECRET-KEY-1" + rnd(58, "QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L"),
    "jwt": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0." + rnd(43),
    "balloon-password-hash": "$BALLOON-SHA256$v=1$s=1024,t=32$" + rnd(22) + "$" + rnd(43),
}
PEM_BODY = rnd(64) + "\n" + rnd(64)
PEM = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + PEM_BODY + "\n-----END OPENSSH PRIVATE KEY-----"
ASSIGN_VALUE = rnd(28)

BENIGN = [
    "image: alpine:latest@sha256:" + rnd(64, HEX),
    "commit " + rnd(40, HEX) + " Merge pull request 'x' (#12)",
    "logContext e6b106ef-d265-495c-bf40-8cc4d3070117",
    "IMMICH_VERSION=ENC[AES256_GCM,data:kc8=,iv:" + rnd(43) + "=,tag:" + rnd(22) + "==,type:str]",
    "age13rh9mexaecjmhf5s080a79xx6ae5cd63n99eujwy42s4e2jzxaks4lupdu",
    "COPY --from=golang:1.26-bookworm@sha256:" + rnd(64, HEX) + " /usr/local/go /usr/local/go",
    '"integrity": "sha512-' + rnd(86) + '=="',
    "https://forgejo.example.internal",
    "Claude-Session: https://claude.ai/code/session_014X6KaQJuRVcRML2VbWutMy",
]

def run(tool, response, env=ENV):
    payload = {"session_id": "test-" + rnd(8), "hook_event_name": "PostToolUse",
               "tool_name": tool, "tool_input": {}, "tool_response": response}
    p = subprocess.run([HOOK], input=json.dumps(payload), capture_output=True, text=True, env=env)
    out = json.loads(p.stdout) if p.stdout.strip() else None
    return p.returncode, out, p.stdout + p.stderr

def shape(o):
    if isinstance(o, dict):
        return {k: shape(v) for k, v in o.items()}
    if isinstance(o, list):
        return [shape(v) for v in o]
    return type(o).__name__

failures = []
def check(cond, label):
    print(("ok   " if cond else "FAIL ") + label)
    if not cond:
        failures.append(label)

# Realistic response shapes for the tools that return text.
def bash(text):  return {"stdout": text, "stderr": "", "interrupted": False, "isImage": False}
def read(text):  return {"type": "text", "file": {"filePath": "/x/y.env", "content": text,
                          "numLines": text.count("\n") + 1, "startLine": 1, "totalLines": 9}}
def grep(text):  return {"mode": "content", "numFiles": 1, "filenames": ["a.txt"],
                          "content": text, "numLines": 1}
def mcp(text):   return [{"type": "text", "text": text}]
SHAPES = {"Bash": bash, "Read": read, "Grep": grep, "mcp__forgejo__get_issue": mcp}

# 1. every secret shape is caught, in every tool shape, and the shape survives
for rule, secret in SECRETS.items():
    for tool, wrap in SHAPES.items():
        resp = wrap(f"line before\nvalue: {secret}\nline after")
        rc, out, raw = run(tool, resp)
        new = (out or {}).get("hookSpecificOutput", {}).get("updatedToolOutput")
        check(rc == 0 and new is not None and shape(new) == shape(resp)
              and secret not in json.dumps(new) and secret not in raw
              and "<REDACTED:" in json.dumps(new) and "line after" in json.dumps(new),
              f"redacts {rule:22} in {tool}, shape kept, value never echoed")

rc, out, raw = run("Read", read("key:\n" + PEM + "\n"))
new = (out or {}).get("hookSpecificOutput", {}).get("updatedToolOutput", {})
check(PEM_BODY.split("\n")[0] not in json.dumps(new) and PEM_BODY.split("\n")[0] not in raw,
      "redacts private-key block in Read")

rc, out, raw = run("Bash", bash("REDIS_PASSWORD=" + ASSIGN_VALUE + "\nother=1\n"))
new = (out or {}).get("hookSpecificOutput", {}).get("updatedToolOutput", {})
check(ASSIGN_VALUE not in json.dumps(new) and ASSIGN_VALUE not in raw,
      "redacts generic password assignment in Bash")

# 2. the user is told which rules fired, never the value
rc, out, raw = run("Bash", bash("t=" + SECRETS["github-pat"]))
check("github-pat" in (out or {}).get("systemMessage", "") and SECRETS["github-pat"] not in raw,
      "systemMessage names the rule, not the secret")

# 3. benign output passes through untouched (no output = original used)
for text in BENIGN:
    rc, out, raw = run("Bash", bash(text))
    check(rc == 0 and out is None, f"leaves alone: {text[:60]}")
rc, out, raw = run("Read", read("\n".join(BENIGN * 500)))
check(rc == 0 and out is None, "leaves alone: a large file of benign lines")

# 4. odd inputs don't break anything
for label, resp in [("empty stdout", bash("")), ("null response", None),
                    ("non-text response", {"filenames": [], "numFiles": 0})]:
    rc, out, raw = run("Glob", resp)
    check(rc == 0 and out is None, f"no-op on {label}")

# 5. no gitleaks: fail open, warn once per session, never block
import tempfile
bare = dict(os.environ, PATH="/nonexistent", HOME=tempfile.mkdtemp())  # hide every install spot
# unique per run: the hook remembers warned sessions, and rnd() is seeded
payload = {"session_id": "nogl-" + os.urandom(6).hex(), "tool_name": "Bash",
           "tool_response": bash("t=" + SECRETS["github-pat"])}
first = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True, text=True, env=bare)
second = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True, text=True, env=bare)
check(first.returncode == 0 and "gitleaks not found" in first.stdout
      and second.returncode == 0 and second.stdout.strip() == "",
      "missing gitleaks: exit 0, one warning per session, no rewrite")

# 6. garbage on stdin fails open
p = subprocess.run([HOOK], input="not json", capture_output=True, text=True, env=ENV)
check(p.returncode == 0, "invalid payload fails open (exit 0)")

# 7. the shapes a Remote Control host holds that gitleaks' defaults miss
import base64 as _b64
URLSAFE = string.ascii_letters + string.digits + "-_"
STATION = {
    "claude-oauth-token (access)": "sk-ant-oat01-" + rnd(93, URLSAFE) + "AA",
    "claude-oauth-token (refresh)": "sk-ant-ort01-" + rnd(93, URLSAFE) + "AA",
    "base64-private-key": _b64.b64encode(PEM.encode()).decode(),
}
for label, secret in STATION.items():
    for tool, wrap in SHAPES.items():
        resp = wrap(f"line before\nvalue: {secret}\nline after")
        rc, out, raw = run(tool, resp)
        new = (out or {}).get("hookSpecificOutput", {}).get("updatedToolOutput")
        check(rc == 0 and new is not None and shape(new) == shape(resp)
              and secret[20:60] not in json.dumps(new) and secret[20:60] not in raw,
              f"redacts {label:28} in {tool}")

# 8. the host's own secret VALUES, whatever their shape: a bare 40-hex forge token
#    looks exactly like a commit SHA, so only the literal value can catch it.
forge = rnd(40, HEX); other_sha = rnd(40, HEX); key_b64 = STATION["base64-private-key"]
opaque = rnd(30)  # a credential with no recognisable shape at all
env_secrets = dict(ENV, FORGE_API_TOKEN=forge, GIT_SSH_KEY_B64=key_b64, NOTIFY_TOKEN=opaque,
                   SSH_AUTH_SOCK="/tmp/ssh-" + rnd(12) + "/agent.1")
text = (f"forge {forge}\ncommit {other_sha}\nnotify {opaque}\n"
        f"sock {env_secrets['SSH_AUTH_SOCK']}\nkey {PEM_BODY.splitlines()[0]}\n")
rc, out, raw = run("Bash", bash(text), env=env_secrets)
new = json.dumps((out or {}).get("hookSpecificOutput", {}).get("updatedToolOutput", {}))
check(forge not in new and forge not in raw and "<REDACTED:env:FORGE_API_TOKEN>" in new,
      "redacts the literal FORGE_API_TOKEN value (bare 40 hex)")
check(other_sha in new, "leaves an unrelated 40-hex commit SHA alone")
check(opaque not in new and opaque not in raw, "redacts a shapeless secret by its env value")
check(PEM_BODY.splitlines()[0] not in new, "redacts a line of the key decoded from GIT_SSH_KEY_B64")
check(env_secrets["SSH_AUTH_SOCK"] in new, "leaves SSH_AUTH_SOCK (a path, not a secret) alone")

# 9. the OAuth credential FILE: whatever the token format, the file's values are redacted
cfg = pathlib.Path(tempfile.mkdtemp())
tok_a, tok_r = rnd(48), rnd(48)
(cfg / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {"accessToken": tok_a, "refreshToken": tok_r, "expiresAt": 1}}))
rc, out, raw = run("Read", read(f"a={tok_a}\nr={tok_r}"), env=dict(ENV, CLAUDE_CONFIG_DIR=str(cfg)))
new = json.dumps((out or {}).get("hookSpecificOutput", {}).get("updatedToolOutput", {}))
check(tok_a not in new and tok_r not in new and tok_a not in raw,
      "redacts the OAuth tokens read from CLAUDE_CONFIG_DIR/.credentials.json")

# 10. no gitleaks: the host's own values are STILL redacted, in ONE JSON object
bare2 = dict(bare, FORGE_API_TOKEN=forge)
payload2 = {"session_id": "nogl2-" + os.urandom(6).hex(), "tool_name": "Bash", "tool_response": bash("forge " + forge)}
p2 = subprocess.run([sys.executable, HOOK], input=json.dumps(payload2), capture_output=True, text=True, env=bare2)
lines = [l for l in p2.stdout.splitlines() if l.strip()]
o2 = json.loads(lines[0]) if len(lines) == 1 else {}
check(p2.returncode == 0 and len(lines) == 1 and forge not in p2.stdout
      and "gitleaks not found" in o2.get("systemMessage", "")
      and "updatedToolOutput" in o2.get("hookSpecificOutput", {}),
      "missing gitleaks: literal values still redacted, warning folded into one JSON output")

print(f"\n{len(failures)} failure(s)")
sys.exit(1 if failures else 0)

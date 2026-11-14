#!/usr/bin/env python3
# leakcheck:ignore-file — this file deliberately contains the patterns the leak check looks for
"""Tests for block-secret-dumps.sh. Run: python3 shared-hooks/test-block-secret-dumps.py

The must-ALLOW half matters as much as the must-BLOCK half: a guard that fires
on ordinary work gets worked around, and the workaround is worse than the gap.
Several allow-cases are verbatim commands from real sessions.
"""
import json, pathlib, subprocess, sys

HOOK = str(pathlib.Path(__file__).with_name("block-secret-dumps.sh"))

def run(tool, _payload=None, **ti):
    payload = {"tool_name": tool, "tool_input": ti, **(_payload or {})}
    p = subprocess.run([HOOK], input=json.dumps(payload), capture_output=True, text=True)
    return p.returncode, p.stderr

BLOCK = [
    # The two commands that actually leaked, 2026-09-06.
    ("Bash", "docker inspect --format 'entry={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}}' app_redis"),
    ("Bash", "ps -eo user,args | grep [v]alkey"),
    # docker inspect without projection
    ("Bash", "docker inspect app_redis"),
    ("Bash", "docker container inspect forgejo"),
    ("Bash", "docker inspect --format '{{json .Config.Env}}' x"),
    ("Bash", "docker inspect --format '{{json .Config}}' x"),
    ("Bash", "docker inspect -f '{{.Args}}' x"),
    # whole-environment dumps
    ("Bash", "env"),
    ("Bash", "printenv"),
    ("Bash", "docker exec netdata env"),
    ("Bash", "cd /tmp && env | sort"),
    # argv dumps
    ("Bash", "ps aux"),
    ("Bash", "ps -ef"),
    ("Bash", "ps -eo pid,args"),
    ("Bash", "ps eww 1234"),
    ("Bash", "docker ps --no-trunc"),
    # rendered config / dotenv
    ("Bash", "docker compose config"),
    ("Bash", "docker-compose config"),
    ("Bash", "docker compose -f app/compose.yml config"),
    ("Bash", "docker compose --project-directory /srv/app config | grep image"),
    ("Bash", "cd /srv/app && docker compose config"),
    ("Bash", "cat .env"),
    ("Bash", "cat ~/app/.env"),
    ("Bash", "head -20 /home/user/forgejo/.env"),
    ("Bash", "grep REDIS_PASSWORD .env"),
    # sops to a terminal
    ("Bash", "sops decrypt --input-type dotenv .env.sops"),
    ("Bash", "sops -d secrets.yaml"),
    # unit environment
    ("Bash", "systemctl show docker.service"),
    # secret on the command line
    ("Bash", "redis-cli -a hunter2 ping"),
    ("Bash", "mysql -uroot -phunter2 db"),
    ("Bash", "curl -u admin:hunter2 https://example.com"),
    ("Bash", "curl https://user:pw@example.com/x"),
    ("Bash", "curl 'https://example.com/api?api_key=abc123'"),
    ("Bash", "pg_dump --password=hunter2 db"),
    # Read tool
    ("Read", None, "/home/user/app/.env"),
    ("Read", None, "/home/user/.ssh/id_ed25519"),
    ("Read", None, "/run/secrets/db_password"),
    ("Read", None, "/home/user/.config/sops/age/keys.txt"),
    ("Read", None, "/etc/ssl/private/server.key"),
]

ALLOW = [
    # real commands from this session that must keep working
    ("Bash", "docker inspect --format 'status={{.State.Status}} health={{.State.Health.Status}}' app_redis"),
    ("Bash", "docker inspect --format '{{.Config.User}} {{json .HostConfig.CapAdd}}' app_redis"),
    ("Bash", "docker inspect --format '{{json .HostConfig.CapDrop}}' x"),
    ("Bash", "ps -o pid,user,comm -C valkey-server"),
    ("Bash", "ps -eo pid,user,comm"),
    ("Bash", "grep -c '^REDIS_PASSWORD=' ~/app/.env"),
    ("Bash", "grep -q '^KEY=' .env && echo present"),
    ("Bash", "grep -l TOKEN .env"),
    ("Bash", "cat .env.example"),
    ("Bash", "cat .env.sops"),
    ("Bash", "cat .env.template"),
    ("Bash", "sops decrypt --input-type dotenv .env.sops > .env.tmp"),
    ("Bash", "sops decrypt .env.sops | python3 -c 'import sys'"),
    ("Bash", "env FOO=bar python3 script.py"),
    ("Bash", "printenv PATH"),
    ("Bash", "systemctl show -p ActiveState docker.service"),
    ("Bash", "systemctl show --property=SubState nginx"),
    ("Bash", "docker compose config --services"),
    ("Bash", "docker ps --format '{{.Names}}\\t{{.Status}}'"),
    ("Bash", "docker exec app_redis redis-cli ping"),
    ("Bash", "git status --short"),
    ("Bash", "cat docker-compose.yaml"),
    # `config` in a later command or inside a path is not `docker compose config`
    ("Bash", "sed -n 1,20p docker-compose.yml | grep -v '#'; grep -n Host ~/.ssh/config"),
    ("Bash", "docker compose up -d app; cat ~/.ssh/config"),
    ("Bash", "docker compose -f compose.config.yml up -d"),
    ("Bash", "docker compose logs app | grep config"),
    ("Bash", "curl -s -o /dev/null -w '%{http_code}' https://app.example.org/api/server/ping"),
    ("Bash", "docker logs --since 10m netdata | tail -5"),
    ("Bash", "python3 -m unittest discover -s netdata-watchdog"),
    # Read tool
    ("Read", None, "/home/user/code/app/.env.example"),
    ("Read", None, "/home/user/code/app/docker-compose.yaml"),
    ("Read", None, "/home/user/.ssh/id_ed25519.pub"),
    ("Read", None, "/home/user/code/app/README.md"),
]


# --- heredoc bodies are DATA, not commands --------------------------------
# Documenting or scripting a dangerous command is not running it. The first
# version of this hook blocked the very commit that documented it, and then
# blocked its own fix.
DOC = "docker" + " compose " + "config"
SYSCTL = "systemctl" + " show"
INSPECT = "docker" + " inspect"
ALLOW += [
    ("Bash", f"cat > doc.md <<'EOF'\nnever run {DOC} here\nEOF"),
    ("Bash", f"git commit -F - <<'EOF'\nmentions {DOC} and {SYSCTL} in prose\nEOF"),
    ("Bash", f"python3 - <<'PY'\nprint('{INSPECT} x')\nPY"),
    ("Bash", "cat > x.py <<PY\n# ps -ef and cat .env described\nPY"),
    ("Bash", "tee f <<-'EOF'\n\tenv\n\tEOF"),
]
# ...but a heredoc fed to a SHELL is executed, so it stays in scope, and a
# dangerous command sitting OUTSIDE a heredoc is still caught.
BLOCK += [
    ("Bash", f"bash <<'EOF'\n{INSPECT} app_redis\nEOF"),
    ("Bash", "sh <<EOF\nps -ef\nEOF"),
    ("Bash", f"cat > doc.md <<'EOF'\nharmless prose\nEOF\n{INSPECT} app_redis"),
    ("Bash", f"{INSPECT} app_redis <<'EOF'\nunterminated"),
]


# --- the boolean-verification exception -----------------------------------
# The hook's own messages recommend proving presence/absence by piping the
# field into a counting grep. It used to block exactly that. The exception is
# STRUCTURAL: one pipeline, terminal counting grep, nothing that could stash
# the output for later. The must-BLOCK half below is the real test — a loose
# "is there a grep" check would let every one of them through.
I = "docker" + " inspect"
CFG = "docker" + " compose " + "config"
ALLOW += [
    ("Bash", f"{I} --format '{{{{json .Config.Cmd}}}}' fj | grep -c FORGEJO_RUNNER_TOKEN"),
    ("Bash", f"{I} --format '{{{{json .Config.Env}}}}' x | grep -q REDIS_PASSWORD"),
    ("Bash", f"{I} app_redis | grep -c requirepass"),
    ("Bash", f"{CFG} | grep -c PASSWORD"),
    ("Bash", "env | grep -c FOO"),
    ("Bash", "ps -ef | grep -c valkey-server"),
    ("Bash", "systemctl show docker.service | grep -c Environment"),
    ("Bash", f"{I} --format '{{{{json .Config.Env}}}}' x | grep --count TOKEN"),
]
BLOCK += [
    # stashing the output for later is the whole thing this must not permit
    ("Bash", f"x=$({I} --format '{{{{json .Config.Env}}}}' y); echo \"$x\""),
    ("Bash", f"{I} --format '{{{{json .Config.Env}}}}' x | tee /tmp/f | grep -c FOO"),
    ("Bash", f"{I} --format '{{{{json .Config.Env}}}}' x | grep -c FOO && {I} --format '{{{{json .Config.Env}}}}' y"),
    ("Bash", f"{I} --format '{{{{json .Config.Env}}}}' x | grep -c FOO; echo done"),
    # greps that print content back out
    ("Bash", f"{I} --format '{{{{json .Config.Env}}}}' x | grep TOKEN"),
    ("Bash", f"{I} --format '{{{{json .Config.Env}}}}' x | grep -o TOKEN"),
    ("Bash", f"{I} --format '{{{{json .Config.Env}}}}' x | grep -A2 TOKEN"),
    ("Bash", f"{I} --format '{{{{json .Config.Env}}}}' x | head -5"),
    # no pipeline at all
    ("Bash", f"{I} --format '{{{{json .Config.Cmd}}}}' x"),
    # the exception must NEVER cover a secret that is already in argv:
    # piping the OUTPUT somewhere harmless does nothing about the command line
    ("Bash", "redis-cli -a hunter2 ping | grep -c PONG"),
    ("Bash", "curl -u admin:hunter2 https://x.example | grep -c ok"),
]


# --- a regex describing a credential URL is not one ------------------------
ALLOW += [
    ("Bash", "sed -E 's|://[^/[:space:]:@]+:[^/[:space:]@]+@|://<user>:<redacted>@|g' f"),
    ("Bash", "grep -oE '://[^:@]+:[^@]+@' logfile | wc -l"),
]
BLOCK += [
    ("Bash", "curl https://realuser:s3cr3tvalue@example.com/x"),
    ("Bash", "git clone https://bot:abc123def456@git.example.com/r.git"),
]


# --- a synthetic fixture in the session scratchpad -------------------------
# The scratchpad is created empty per session, so a Compose file or .env in
# it was written by this session and is already in the transcript. Rendering
# it (`docker compose config` to verify a Compose semantic empirically) leaks
# nothing new. The exemption is STRUCTURAL: literal paths, all inside THIS
# session's scratchpad, no variables, no `..`, no `~`. Only the two FILE
# rules are lifted; host/daemon-state rules still fire from inside it.
SID = "106cdba6-06df-480b-8ab6-58a2e2aaf31f"
PAD = f"/tmp/claude-1000/-home-user/{SID}/scratchpad"
IN_PAD = {"cwd": f"{PAD}/c780/top", "session_id": SID}
IN_REPO = {"cwd": "/home/user/code/app", "session_id": SID}
NO_SID = {"cwd": f"{PAD}/c780/top"}
ALLOW_P = [
    # a real blocked command, spelled with a literal path
    (f"cd {PAD}/c780/top && {CFG}", {}),
    (f"cd {PAD}/c780/top && docker compose -f compose.yml config | grep -A3 'source:'", {}),
    (f"{CFG}", IN_PAD),
    (f"docker compose -f {PAD}/c780/top/compose.yml config >/dev/null; echo $?", IN_PAD),
    ("printf 'FOO=1\\n' > sub/api.env", IN_PAD),
    ("cat sub/api.env", IN_PAD),
    ("cat .env", IN_PAD),
    (f"{CFG}", NO_SID),  # a payload without session_id falls back to the shape
]
BLOCK_P = [
    # from inside the scratchpad, reaching OUT
    ("docker compose -f /home/user/app/compose.yml config", IN_PAD),
    ("docker compose -f ../../../../../home/user/app/compose.yml config", IN_PAD),
    ("cat ~/app/.env", IN_PAD),
    ("cat /home/user/app/.env", IN_PAD),
    # a variable can name any directory
    (f"d={PAD}/c780/top; cd $d && {CFG}", {}),
    (f"cd {PAD}/x && docker compose -f $F config", {}),
    ("cd $SCRATCH && " + CFG, IN_PAD),
    # a relative cd is not proof of anything
    (f"cd c780/top && {CFG}", IN_REPO),
    # another session's scratchpad
    (f"cd /tmp/claude-1000/-home-user/2f5b8b1e-4a4e-4d2d-9c7b-1d1f0f4a2c11/scratchpad/x && {CFG}", IN_PAD),
    # not a scratchpad at all
    (f"{CFG}", IN_REPO),
    ("cd /tmp/claude-1000/-home-user/notes && " + CFG, {}),
    ("cd /home/user/app && " + CFG, IN_PAD),
    # host/daemon state is not sandboxed by a cwd
    (I + " app_redis", IN_PAD),
    ("ps -ef", IN_PAD),
    ("env", IN_PAD),
    ("systemctl show docker.service", IN_PAD),
    ("redis-cli -a hunter2 ping", IN_PAD),
    ("sops -d secrets.yaml", IN_PAD),
]

# --- the files a coding-agent host keeps its own credentials in -------------
# An SSH key under any name (a station loads ~/.ssh/git_key), the OAuth credential,
# git's credential store, a process's environment, and the env dumps besides `env`.
BLOCK += [
    ("Bash", "cat ~/.ssh/git_key"),
    ("Bash", "base64 -w0 ~/.ssh/git_key"),
    ("Bash", "cat ~/.claude/.credentials.json"),
    ("Bash", "jq . ~/.claude/.credentials.json"),
    ("Bash", "cat ~/.git-credentials"),
    ("Bash", "grep TOKEN ~/.git-credentials"),
    ("Bash", "tr '\\0' '\\n' < /proc/1/environ"),
    ("Bash", "cat /proc/*/environ"),
    ("Bash", "cat /proc/*/cmdline"),
    ("Bash", "export -p"),
    ("Bash", "export"),
    ("Bash", "declare -x"),
    ("Bash", "typeset -p"),
    ("Bash", "set"),
    ("Bash", "set | grep PATH"),
    ("Read", None, "/home/user/.ssh/git_key"),
    ("Read", None, "/home/user/.claude/.credentials.json"),
    ("Read", None, "/home/user/.git-credentials"),
    ("Read", None, "/proc/1/environ"),
]
ALLOW += [
    ("Bash", "set -euo pipefail"),
    ("Bash", "export FOO=bar"),
    ("Bash", "declare -p ONE_VAR"),
    ("Bash", "cat ~/.ssh/config"),
    ("Bash", "cat ~/.ssh/known_hosts"),
    ("Bash", "cat ~/.ssh/git_key.pub"),
    ("Bash", "ssh-keygen -y -f ~/.ssh/git_key"),
    ("Bash", "ssh-add ~/.ssh/git_key"),
    ("Bash", "chmod 600 ~/.ssh/git_key"),
    ("Bash", "wc -c ~/.ssh/git_key"),
    ("Bash", "test -s ~/.claude/.credentials.json && echo present"),
    ("Bash", "grep -c x ~/.git-credentials"),
    ("Bash", "grep -q FLAG /proc/1/cmdline && echo present || echo absent"),
    ("Read", None, "/home/user/.ssh/config"),
    ("Read", None, "/home/user/.ssh/known_hosts_forge"),
]

fails = 0
for case in BLOCK:
    if case[0] == "Bash":
        rc, err = run("Bash", command=case[1])
    else:
        rc, err = run("Read", file_path=case[2])
    label = case[1] if case[0] == "Bash" else case[2]
    if rc != 2:
        print(f"  FAIL should BLOCK but exit={rc}: {label}"); fails += 1
    elif "BLOCKED by block-secret-dumps" not in err:
        print(f"  FAIL blocked without guidance: {label}"); fails += 1
for cmd, payload in BLOCK_P:
    rc, err = run("Bash", payload, command=cmd)
    if rc != 2:
        print(f"  FAIL should BLOCK but exit={rc}: {cmd}  payload={payload}"); fails += 1

for case in ALLOW:
    if case[0] == "Bash":
        rc, err = run("Bash", command=case[1])
    else:
        rc, err = run("Read", file_path=case[2])
    label = case[1] if case[0] == "Bash" else case[2]
    if rc != 0:
        print(f"  FAIL should ALLOW but exit={rc}: {label}\n        {err.strip()[:200]}"); fails += 1
for cmd, payload in ALLOW_P:
    rc, err = run("Bash", payload, command=cmd)
    if rc != 0:
        print(f"  FAIL should ALLOW but exit={rc}: {cmd}  payload={payload}\n        {err.strip()[:200]}"); fails += 1

# non-matching tools and malformed input must never block
for payload in ['{"tool_name":"Write","tool_input":{"file_path":"/x/.env"}}', "", "not json"]:
    p = subprocess.run([HOOK], input=payload, capture_output=True, text=True)
    if p.returncode != 0:
        print(f"  FAIL must fail open for payload {payload!r}: exit={p.returncode}"); fails += 1

# Grep tool: content mode renders lines like `grep`; file-name and count modes don't.
GREP_BLOCK = [dict(pattern=".", path="/home/user/.claude/.credentials.json", output_mode="content"),
              dict(pattern=".", path="/home/user/.ssh", output_mode="content"),
              dict(pattern="KEY", path="/home/user/app/.env", output_mode="content"),
              dict(pattern="KEY", path="/home/user/app", glob="*.env", output_mode="content")]
GREP_ALLOW = [dict(pattern=".", path="/home/user/.ssh"),
              dict(pattern="KEY", path="/home/user/app/.env", output_mode="count"),
              dict(pattern="TODO", path="/home/user/app", output_mode="content")]
for ti in GREP_BLOCK:
    rc, err = run("Grep", **ti)
    if rc != 2: print(f"  FAIL Grep should BLOCK but exit={rc}: {ti}"); fails += 1
for ti in GREP_ALLOW:
    rc, err = run("Grep", **ti)
    if rc != 0: print(f"  FAIL Grep should ALLOW but exit={rc}: {ti}"); fails += 1

# A crash (here: a JSON array instead of an object) is allowed through, and reported as
# a HOOK_ERROR marker once an hour, naming the exception type and never the input.
import os, tempfile
with tempfile.TemporaryDirectory() as d:
    env = {k: v for k, v in os.environ.items() if not k.startswith("NOTIFY_")}
    env.update(LYNGVI_MARKER_LOG=os.path.join(d, "log"), CLAUDE_CONFIG_DIR=d)
    runs = [subprocess.run([HOOK], input='["cat ~/.ssh/id_ed25519"]', capture_output=True, text=True, env=env)
            for _ in range(2)]
    log = open(os.path.join(d, "log")).read() if os.path.exists(os.path.join(d, "log")) else ""
    crash_ok = (all(r.returncode == 0 for r in runs) and log.count("HOOK_ERROR sev=warn") == 1
                and "AttributeError" in log and "id_ed25519" not in log + runs[0].stderr)
    if not crash_ok:
        print(f"  FAIL crash: rc={[r.returncode for r in runs]} log={log!r} stderr={runs[0].stderr!r}"); fails += 1

total = len(BLOCK) + len(ALLOW) + len(BLOCK_P) + len(ALLOW_P) + len(GREP_BLOCK) + len(GREP_ALLOW) + 4
print(f"\n{total - fails}/{total} passed" + ("" if fails else "  — OK"))
sys.exit(1 if fails else 0)

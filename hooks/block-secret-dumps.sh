#!/usr/bin/env python3
"""PreToolUse guard: refuse commands that dump secrets into the transcript.

Wire as a PreToolUse hook matching `Bash|Read|Grep`.

WHY THIS EXISTS. Every secret leak we have seen came from a command
whose *purpose was not* to reveal a secret — the secret rode along in output
being read for another reason. Three examples, all real:

  * `docker inspect --format '... {{json .Config.Cmd}} ...'` run to identify a
    container's init process, which printed a redis password.
  * `ps -eo user,args` run to prove that same password was exposed, which
    printed it a second time — while fixing the first leak.
  * a busybox wget usage error that echoed an admin password.

Prose rules against this already existed in CLAUDE.md and were followed
inconsistently, which is the argument for a mechanical guard: an agent that has
just been told not to do something will still do it when the dangerous field is
adjacent to the one it wants. This hook makes the common shapes impossible
rather than discouraged.

DESIGN NOTES.

  * Deny, never bypass. There is deliberately no escape-hatch env var: a guard
    the agent can wave away is a guard it will wave away. When a block is wrong,
    a human edits settings.json or runs the command themselves.
  * Fail OPEN, loudly. A crash here must not wedge every Bash call, so any
    internal error exits 0 after warning on stderr. This trades a missed block
    for availability; the alternative is an unusable session on a bad regex.
  * Precision over coverage. Each rule targets a shape that is *almost always*
    a dump and has a safe equivalent, which the message names. Rules that would
    fire on ordinary work (`journalctl -u <unit>`, for instance, which can spill
    Environment= but is mostly how you read logs) are deliberately OUT — a
    guard that cries wolf gets worked around, and the workaround is worse than
    the gap. Gaps are listed at the bottom of this file.
  * Portable: python3 only, no jq, $HOME-relative. Must run on a workstation and
    in the station container.
  * One structural exemption for the FILE rules: a synthetic fixture in the
    session's own scratchpad. That directory is created empty by the harness,
    so everything in it was written by this session and already passed through
    the transcript — rendering it cannot leak anything new. The test is on the
    command's shape (literal paths, all inside the scratchpad, no variables,
    no climbing), never on intent, so it is not a bypass. Rules that read host
    or daemon state (inspect, ps, env, systemctl) are NOT exempt: the cwd says
    nothing about what those return. See ``scratchpad_sandboxed``.

Exit codes: 0 = allow, 2 = block (stderr is fed back to the model).
"""

import json
import re
import sys

# --- dotenv-ish paths -------------------------------------------------------
# .env.example / .env.sops / .env.sample / .env.template are safe: a template
# carries no value, and .env.sops is ciphertext.
ENV_SAFE = re.compile(r"\.env\.(example|sops|sample|template|dist)$")

# Commands that render a whole file to stdout.
DUMPERS = r"(cat|bat|head|tail|less|more|nl|od|xxd|strings|base64|tac|jq)"

SECRET_PATHS = re.compile(
    r"(/run/secrets/|\.netrc$|id_(rsa|ecdsa|ed25519)$|\.pem$|\.key$|"
    r"sops/age/keys\.txt$|\.age$|authorized_keys$|"
    # The files a coding-agent host writes its own credentials into: the Claude Code
    # OAuth credential, git's credential store, and any process's environment (which
    # holds every secret the process was started with) and argv, the same exposure
    # as `ps -o args` (rule 5).
    r"\.credentials\.json$|\.git-credentials$|/proc/[^/]+/(environ|cmdline)$)"
)
# Under ~/.ssh, everything that is not one of these is a private key, whatever it is
# named: a station loads its key as ~/.ssh/git_key, and extra identities under any name.
SSH_FILE = re.compile(r"(?:^|/)\.ssh/([^/]+)$")
SSH_PUBLIC = re.compile(r"^(config|known_hosts.*|authorized_keys.*|rc|environment|.*\.pub)$")


def secret_path(path: str) -> bool:
    """True for a file whose content is a credential."""
    path = path.strip("'\"")
    if path.endswith(".pub"):
        return False
    if SECRET_PATHS.search(path):
        return True
    m = SSH_FILE.search(path)
    return bool(m) and not SSH_PUBLIC.match(m.group(1))


# Commands that render a file's content, used for credential files: wider than
# DUMPERS because any of these prints the key, not just the whole-file renderers.
SECRET_DUMPERS = (r"(cat|bat|head|tail|less|more|nl|od|xxd|hexdump|strings|base64|"
                  r"base32|tac|jq|tr|sed|awk|cut|sort|uniq|rev|paste|fold|column|diff|"
                  r"tee)")
_PATHLIKE = re.compile(r"""(?<![\w.~/-])(['"]?)([\w.~/*-]*/[\w.*-]+|[\w.-]*\.(?:credentials\.json|git-credentials))\1(?![\w.-])""")
# Whole-environment dumps other than `env`/`printenv`: `export`/`export -p`,
# `declare -x/-p`, `typeset -x/-p` and a bare `set` all print every variable.
_ENV_DUMP = re.compile(
    r"(^|[;&|]\s*)(export(\s+-p)?|(declare|typeset)\s+-[a-zA-Z]*[xp][a-zA-Z]*|set)\s*(\||;|&|$)",
    re.M)


# Commands whose heredoc body is DATA, not script: writing a file or feeding an
# interpreter. Anything else (a shell, eval) would execute the body, so its
# heredoc stays in scope.
_SHELLISH = re.compile(r"\b(bash|sh|zsh|dash|ksh|eval|source)\b\s*(-\w+\s*)*$")


def strip_heredocs(cmd: str) -> str:
    """Remove heredoc BODIES before scanning.

    Writing documentation or code that MENTIONS a dangerous command is not
    running it. Without this, ``cat > doc.md <<'EOF' … docker compose config … EOF`` is blocked — which is literally how this
    hook first blocked the commit that documented it, and then blocked its own
    fix. The body of a heredoc fed to a file or an interpreter is data, so it
    is removed; a heredoc fed to a SHELL would be executed, so it is left in
    place and still scanned.

    Residual gap, accepted knowingly: a dangerous command inside a heredoc fed
    to a non-shell interpreter (``python3 - <<EOF … subprocess … EOF``) is not seen. This guard targets
    accidental capture, not an adversary, and the alternative — blocking every
    heredoc that quotes a command name — makes routine documentation and
    script-writing impossible.
    """
    out, i = [], 0
    pattern = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
    while True:
        m = pattern.search(cmd, i)
        if not m:
            out.append(cmd[i:])
            break
        line_start = cmd.rfind("\n", 0, m.start()) + 1
        prefix = cmd[line_start : m.start()]
        nl = cmd.find("\n", m.end())
        if nl == -1:
            out.append(cmd[i:])
            break
        if _SHELLISH.search(prefix.strip()):
            out.append(cmd[i : m.end()])
            i = m.end()
            continue
        delim = m.group(2)
        end = re.search(rf"^\s*{re.escape(delim)}\s*$", cmd[nl + 1 :], re.M)
        out.append(cmd[i : nl + 1])
        if not end:
            break
        i = nl + 1 + end.end()
    return "".join(out)


def safely_consumed(cmd: str) -> bool:
    """True when the command CANNOT put its output in the transcript.

    The narrow, structural case: one single pipeline whose last stage is a
    grep that emits a COUNT or an exit status rather than content. That is the
    "prove a value is present or absent without printing it" pattern this
    hook's own block messages recommend — and which, until now, this hook
    blocked, because naming .Config.Cmd was enough to trip it. The dotenv rule
    already granted exactly this exception for `grep -c/-q/-l`; the container
    rules were the outlier.

    Deliberately strict, because the obvious loose version is wrong:

      x=$(docker inspect ...); echo "$x"

    reaches the same data and would pass a naive "is there a grep" test. So
    anything that could stash output for later — a second command, a command
    substitution, a `tee` — disqualifies the whole thing. One pipeline, no
    sequencing, no substitution, terminal counting grep. Nothing else.
    """
    if re.search(r"(;|&&|\|\||\n|`|\$\()", cmd):
        return False
    stages = [seg.strip() for seg in cmd.split("|")]
    if len(stages) < 2:
        return False
    if any(re.match(r"(sudo\s+|env\s+\w+=\S+\s+)*tee\b", st) for st in stages):
        return False
    last = stages[-1]
    if not re.match(r"(sudo\s+)?(grep|rg|ggrep)\b", last):
        return False
    # -o/-A/-B/-C all print matched text or context back out
    if re.search(r"(^|\s)-{1,2}(o\b|only-matching|A|B|C|after-context|before-context|context)", last):
        return False
    return bool(re.search(r"(^|\s)-\w*[cql]|--(count|quiet|silent|files-with-matches)\b", last))


# The harness's per-session scratchpad: /tmp/claude-<uid>/<project-slug>/<session>/scratchpad.
SCRATCHPAD = re.compile(r"^/tmp/claude-\d+/[^/]+/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})/scratchpad(?:/|$)")
_ABS_PATH = re.compile(r"(?<![\w.~$-])/[^\s'\"`;&|<>()]+")
_HARMLESS_ABS = {"/dev/null"}


def scratchpad_sandboxed(cmd: str, payload: dict) -> bool:
    """True when every file the command can touch lies in THIS session's scratchpad.

    Why this is safe to exempt from the file-rendering rules: the scratchpad is
    created empty for the session, so any ``.env`` or Compose file in it was
    written by the agent during the session and is already in the transcript.
    ``docker compose config`` over such a fixture is how you verify a Compose
    semantic empirically (relative-path resolution, merge order) without a
    real deployment in reach — exactly the work the hook otherwise pushed onto
    the user.

    Structural, like ``safely_consumed``: the shape has to prove containment,
    because the loose versions all leak.

      * ``cd $d && docker compose config`` — a variable can name any directory,
        so any ``$`` other than ``$?`` disqualifies. Spell the path literally.
      * ``docker compose -f ../../../srv/x/compose.yml config`` — a ``..``
        segment climbs out, so none are allowed anywhere in the command.
      * ``cat ~/app/.env`` from inside the scratchpad — ``~`` and every
        absolute path must themselves be inside the scratchpad (``/dev/null``
        is the one harmless absolute path allowed).
      * another session's scratchpad — when the payload carries ``session_id``
        the scratchpad's session segment must match it.

    The effective directory is the leading ``cd <literal path>`` when the
    command starts with one, else the payload's ``cwd``. Relative paths then
    resolve under it, which is inside by construction.

    Residual, accepted: a fixture the agent deliberately points at a real file
    (``env_file: /home/user/app/.env`` written into the YAML) is rendered.
    That is a deliberate read of a secret, the same class as an interpreter
    opening ``.env``, which the hook has never claimed to stop.
    """
    if re.search(r"\$(?!\?)|`|~|(?:^|[\s/'\"=])\.\.(?:[/\s'\"]|$)", cmd):
        return False
    session = payload.get("session_id") or ""

    def inside(path: str) -> bool:
        m = SCRATCHPAD.match(path)
        return bool(m) and (not session or m.group(1) == session)

    lead = re.match(r"\s*cd\s+(/[^\s;&|]+)\s*(?:&&|;)", cmd)
    base = lead.group(1) if lead else (payload.get("cwd") or "")
    if not inside(base):
        return False
    return all(
        p in _HARMLESS_ABS or inside(p) for p in _ABS_PATH.findall(cmd)
    )


def rules(cmd: str, *, sandboxed: bool = False):
    """Yield (reason, alternative) for every rule the command trips.

    ``sandboxed`` — the command touches only this session's scratchpad (see
    :func:`scratchpad_sandboxed`) — lifts the two FILE rules (3 and 6) and
    nothing else.
    """
    # Applies ONLY to rules about what a command PRINTS. Rules about a secret
    # being in the command itself stay absolute: piping the output somewhere
    # harmless does nothing about a password already recorded in argv.
    consumed = safely_consumed(cmd)

    # 1. docker inspect with no --format: the default output includes
    #    .Config.Env, i.e. every secret the container was started with.
    if (not consumed) and re.search(r"\bdocker\s+(container\s+)?inspect\b", cmd) and not re.search(
        r"(--format|-f)[\s=]", cmd
    ):
        yield (
            "bare `docker inspect` prints .Config.Env — every environment "
            "variable the container holds, secrets included",
            "project one field: docker inspect --format '{{.State.Status}}' <c>; "
            "or, to check for a value without printing it, pipe this straight "
            "into `grep -c <VARNAME>` as a single pipeline",
        )

    # 2. A --format template that reaches for the two carrier fields. .Args and
    #    a whole-.Config dump are the same exposure by another name.
    if (not consumed) and (re.search(r"\{\{[^}]*\.(Config\.(Env|Cmd)|Args)\b", cmd) or re.search(
        r"\{\{\s*json\s+\.Config\s*\}\}", cmd
    )):
        yield (
            ".Config.Env, .Config.Cmd and .Args are the fields credentials "
            "live in (a password passed as a flag lands in Cmd)",
            "safe fields: .Config.User, .Config.Entrypoint, .Config.Image, "
            ".HostConfig.CapAdd, .HostConfig.CapDrop, .State.*. To test whether "
            "a value leaked WITHOUT printing it, pipe THIS command into a "
            "counting grep — `... | grep -c <VARNAME>` — which is allowed: one "
            "pipeline ending in grep -c/-q/-l emits a count or an exit status, "
            "never content. Assigning to a variable first, or adding a second "
            "command after ';' or '&&', is NOT allowed and will still be blocked",
        )

    # 3. `docker compose config` interpolates .env into its output. The
    #    subcommands that only list names are fine. `config` must be a word of the
    #    same command (no `;`, `&`, `|` or newline in between) and not part of a path
    #    or file name, so `cat docker-compose.yml | grep x; cat ~/.ssh/config` and
    #    `docker compose -f compose.config.yml up` are not mistaken for it.
    if (not consumed) and (not sandboxed) and re.search(
        r"\bdocker[-\s]compose\b[^;&|\n]*?(?<![\w./-])config(?![\w./-])", cmd
    ) and not re.search(r"\bconfig\b\s+--(services|volumes|profiles|images|hash)", cmd):
        yield (
            "`docker compose config` renders .env into its output",
            "read docker-compose.yml directly — the ${VAR} names are the useful "
            "part; or use config --services / --images. A synthetic fixture in "
            "the session scratchpad IS allowed: `cd <literal scratchpad path> "
            "&& docker compose config`, naming only files inside it (no "
            "variables, no `..`, no `~`)",
        )

    # 4. Bare `env` / `printenv` dump the whole environment. `env FOO=bar cmd`
    #    and `printenv PATH` are ordinary and must not trip.
    if (not consumed) and re.search(r"(^|[;&|]\s*)(env|printenv)\s*(\||;|&|$)", cmd):
        yield (
            "bare `env`/`printenv` dumps every variable in scope",
            "name the one you want: printenv PATH",
        )
    if (not consumed) and _ENV_DUMP.search(cmd):
        yield (
            "`export -p`, `declare -x`/`-p` and a bare `set` dump every variable in "
            "scope, exactly like bare `env`",
            "name the one you want: printenv PATH, or declare -p ONE_VAR",
        )
    if re.search(r"\bdocker\s+exec\b[^;&|]*\s(env|printenv)\s*(\||;|&|$)", cmd):
        yield (
            "`docker exec … env` dumps the container's whole environment",
            "filter the secret keys out before printing, or check a specific "
            "non-secret key",
        )

    # 5. ps output specs that include argv. A password passed as a flag is
    #    visible in the argv of every process on the host.
    # NOTE: `\b` does not match between a space and a hyphen, so `\b-ef\b`
    # silently never fires. Parse the ps invocation instead, and handle
    # clustered flags (-eo, -efww) rather than a fixed list.
    # split on newlines too: a heredoc fed to a shell puts each command on its
    # own LINE, so a segment-only split anchored the match at "sh" and missed it.
    for seg in ([] if consumed else re.split(r"[;&|\n]", cmd)):
        m = re.match(r"\s*(?:\w+=\S+\s+)*(?:(?:sudo|timeout|command)\s+\S*\s*)*ps\b(.*)", seg)
        if not m:
            continue
        argv = m.group(1)
        if not (
            re.search(r"\b(args|cmd|command)\b", argv)
            or re.search(r"(^|\s)-?[a-zA-Z]*(aux|ef)[a-zA-Z]*(\s|$)", argv)
            or "eww" in argv
        ):
            continue
        yield (
                "this `ps` prints full command lines, which is where credentials "
                "passed as flags live — for every process on the host, not just "
                "the one you meant",
                "drop the args column (ps -o pid,user,comm), or to prove a secret "
                "is ABSENT read /proc/<pid>/cmdline and report a boolean: "
                "grep -q <FLAG> /proc/<pid>/cmdline && echo present || echo absent",
            )
    if re.search(r"\bdocker\s+ps\b[^|]*--no-trunc", cmd):
        yield (
            "`docker ps --no-trunc` prints each container's full command",
            "docker ps --format '{{.Names}}\\t{{.Status}}'",
        )

    # 6. Rendering a real .env. grep -c/-q/-l only emit counts or names, which
    #    is how you check a key EXISTS without reading its value.
    for m in ([] if sandboxed else re.finditer(
        r"(?<![\w.-])([\w./~-]*\.env(?:\.[\w-]+)?)(?![\w.-])", cmd
    )):
        path = m.group(1)
        if ENV_SAFE.search(path):
            continue
        before = cmd[: m.start()]
        if re.search(rf"\b{DUMPERS}\b[^;&|]*$", before):
            yield (
                f"this renders {path}, whose whole purpose is to hold secrets",
                "consume it in-process (a script that reads and uses the value), "
                "or check a key exists with grep -c '^KEY=' without printing it. "
                "A synthetic one in the session scratchpad is allowed when the "
                "command names only files inside it (literal path, no variables)",
            )
        elif re.search(r"\bgrep\b[^;&|]*$", before) and not re.search(
            r"\bgrep\b[^;&|]*\s-\w*[cql]", before
        ):
            yield (
                f"this greps {path} and prints matching LINES, i.e. KEY=value",
                "add -c (count), -q (quiet) or -l (names only) — those prove a "
                "key is present without emitting its value",
            )

    # 6b. Rendering a credential FILE: an SSH private key (any name under ~/.ssh),
    #     the OAuth credential, git's credential store, a process's environ. The
    #     Read rule always covered these by path; a shell command did not.
    for m in ([] if (consumed or sandboxed) else _PATHLIKE.finditer(cmd)):
        path = m.group(2)
        if not secret_path(path):
            continue
        seg = re.split(r"[;&|\n]", cmd[: m.start()])[-1]
        if (re.search(rf"(^|\s|/){SECRET_DUMPERS}\b", seg)
                or re.search(r"<\s*$", seg)
                or (re.search(r"\bgrep\b", seg) and not re.search(r"\bgrep\b[^;&|]*\s-\w*[cql]", seg))):
            yield (
                f"this renders {path}, which holds a credential",
                "use it in-process where it is needed (git and ssh already do); to "
                "prove it exists check metadata only: test -s, wc -c, stat",
            )
            break

    # 7. sops decrypt with nowhere to go prints plaintext to the terminal.
    if re.search(r"\bsops\b[^;&|]*\s(-d|--decrypt|decrypt)\b", cmd) and not re.search(
        r"[>|]", cmd
    ):
        yield (
            "`sops decrypt` with no redirect prints the plaintext secrets",
            "redirect to a 0600 file you shred afterwards, or pipe straight "
            "into the consuming process — never to the terminal",
        )

    # 8. systemctl show renders Environment= for the unit.
    if (not consumed) and re.search(r"\bsystemctl\s+show\b", cmd) and not re.search(
        r"(-p|--property)[\s=]", cmd
    ):
        yield (
            "`systemctl show` prints the unit's Environment=",
            "project one property: systemctl show -p ActiveState <unit>",
        )

    # 9. A secret typed onto a command line is logged by the harness verbatim,
    #    even when the command succeeds and prints nothing.
    if re.search(r"\bredis-cli\b[^;&|]*\s-a\s+\S", cmd):
        yield (
            "`redis-cli -a <password>` puts the password in argv",
            "run `redis-cli ping` — a NOAUTH reply already proves auth is on; "
            "for real access use REDISCLI_AUTH from the environment",
        )
    if re.search(r"--password[=\s]+(?![\s'\"]*$)\S", cmd) or re.search(
        r"\bmysql\b[^;&|]*\s-p\S", cmd
    ):
        yield (
            "a password given as a command-line argument is recorded verbatim "
            "in the transcript and visible in `ps`",
            "read it from a file or env var inside the process instead",
        )
    # A REGEX that describes a credential-in-URL is not a credential in a URL.
    # Writing a redaction pattern — sed -E 's|://[^:@]+:[^@]+@|...|' — tripped
    # this rule during the very audit that was redacting such URLs, which
    # penalises exactly the careful work it should encourage. Real userinfo is
    # percent-encoded and cannot contain bare regex metacharacters, so their
    # presence marks the match as a pattern rather than a value.
    _url = re.search(r"://([^/\s:@]+):([^/\s@]+)@", cmd)
    # Angle brackets are in the class for the same reason: `<user>:<redacted>`
    # is the REPLACEMENT half of a redaction expression, and re.search finds it
    # even when the search half was correctly recognised as a pattern. Real
    # userinfo is percent-encoded, so none of these can appear in a live one.
    if _url and re.search(r"[\[\]^*+\\(){}<>]", _url.group(1) + _url.group(2)):
        _url = None
    if _url or re.search(
        r"[?&](api_?key|token|access_token|password)=(?!\s|$)\S", cmd
    ):
        yield (
            "a credential embedded in a URL is logged in the command itself, "
            "even without -v",
            "pass it with curl --netrc or -H @headerfile",
        )
    if re.search(r"\bcurl\b[^;&|]*\s-u\s+\S+:\S", cmd):
        yield (
            "`curl -u user:password` puts the password in argv",
            "curl --netrc, or -H @headerfile",
        )


def read_rules(path: str):
    if secret_path(path):
        yield (
            f"{path} is a credential/key file; reading it copies the secret "
            "into the transcript verbatim",
            "consume it in-process at the point of use; to prove it exists "
            "check metadata only (exit code, wc -c)",
        )
    for m in re.finditer(r"([\w./~-]*\.env(?:\.[\w-]+)?)$", path):
        if not ENV_SAFE.search(m.group(1)):
            yield (
                f"{path} holds plaintext secrets; the Read tool copies the "
                "whole file into the transcript",
                "read it in-process from a script, or grep -c '^KEY=' to prove "
                "a key exists without printing its value",
            )


def main() -> int:
    raw = sys.stdin.read()
    payload = json.loads(raw) if raw.strip() else {}
    tool = payload.get("tool_name", "")
    ti = payload.get("tool_input", {}) or {}

    if tool == "Bash":
        cmd = strip_heredocs(ti.get("command", "") or "")
        found = list(rules(cmd, sandboxed=scratchpad_sandboxed(cmd, payload)))
    elif tool == "Read":
        found = list(read_rules(ti.get("file_path", "") or ""))
    elif tool == "Grep":
        # Grep's content mode prints matching lines, so it renders a file like `grep`
        # does; the default (file names) and count modes never print a value.
        found = []
        if (ti.get("output_mode") or "files_with_matches") == "content":
            path = ti.get("path", "") or ""
            found = list(read_rules(path))
            if not found and re.search(r"(?:^|/)\.ssh/?$", path):
                found = [(f"{path} holds private keys; content mode prints them",
                          "search with output_mode files_with_matches or count")]
            glob = ti.get("glob", "") or ""
            if not found and glob and (secret_path(glob) or re.search(r"\.env\b(?!\.(example|sops|sample|template|dist))", glob)):
                found = [(f"the glob {glob} selects credential files; content mode prints them",
                          "search with output_mode files_with_matches or count")]
    else:
        return 0

    if not found:
        return 0

    lines = [
        "BLOCKED by block-secret-dumps hook — this command would copy a secret "
        "into the transcript, which permanently compromises it."
    ]
    for reason, alternative in found:
        lines.append(f"  * {reason}.")
        lines.append(f"    Instead: {alternative}.")
    lines.append(
        "This is not a false alarm to work around: every leak we have seen "
        "came from a command run for an unrelated reason. Re-run projecting "
        "only the field you need. If the block is genuinely wrong, say so and "
        "let the user decide — do not reach for another command that dumps the "
        "same data."
    )
    sys.stderr.write("\n".join(lines) + "\n")
    return 2


def report_hook_error(exc):
    """A crash lets the command through (fail open), so make the crash visible.

    On the station, this writes a `HOOK_ERROR sev=warn` marker to the container log
    (PID 1's stdout, which the log-alert rule reads) and pushes it through notify.mjs
    when the site configured a target. It does that at most once an hour. Only the
    exception's type is reported, never the command or the message, which can quote
    input. Anywhere else (a workstation, where PID 1 is not ours to write) it is a no-op.
    """
    import os, subprocess, time
    kind = type(exc).__name__
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    stamp = os.path.join(cfg, "lyngvi-hook-error.stamp")
    try:
        if time.time() - os.path.getmtime(stamp) < 3600:
            return
    except OSError:
        pass
    try:
        with open(os.environ.get("LYNGVI_MARKER_LOG", "/proc/1/fd/1"), "a", encoding="utf-8") as f:
            f.write(f"[block-secret-dumps {time.strftime('%H:%M:%S', time.gmtime())}] HOOK_ERROR sev=warn "
                    f"block-secret-dumps crashed ({kind}) and let the command through; fix the hook\n")
    except OSError:
        return
    try:
        with open(stamp, "w"):
            pass
    except OSError:
        pass
    if (os.environ.get("NOTIFY_URL") or os.environ.get("NOTIFY_CMD")) and os.path.exists("/etc/lyngvi/notify.mjs"):
        try:
            subprocess.Popen(["node", "/etc/lyngvi/notify.mjs", "HOOK_ERROR", "warn",
                              f"block-secret-dumps crashed ({kind}) and let the command through"],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            pass


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # fail OPEN: never wedge every Bash call — but say so
        sys.stderr.write(f"block-secret-dumps hook error (allowing): {type(exc).__name__}\n")
        try:
            report_hook_error(exc)
        except Exception:
            pass
        sys.exit(0)

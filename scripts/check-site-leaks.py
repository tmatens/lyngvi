#!/usr/bin/env python3
# leakcheck:ignore-file — this file deliberately contains the patterns the leak check looks for
"""check-site-leaks — fail CI when private deployment details reach this repo.

The project rule is that private provenance (hostnames, internal addresses,
account and repo names, issue numbers, SOPS/age markers, host keys) never crosses
into a public artifact. The structure of the repo makes that the default (every
site fact is a parameter with an example value); this check is the belt and
suspenders.

Two sources of truth, deliberately split:

  * a plaintext denylist of the site's private tokens, passed with --plaintext.
    It lives ONLY in the private overlay, which runs this script over its
    upstream submodule before anything is pushed upstream. Nothing derived from
    it is committed here, hashes included: a salt in a public repository does
    not protect a short token (an address, a host name), which can be
    recovered from its hash by guessing in seconds.
  * generic regexes (below): RFC1918 addresses, age/SOPS markers, SSH host keys,
    fingerprints, emails, home paths, commit SHAs, issue refs, private TLDs.
    Publishing a regex for these leaks nothing. These are what this
    repository's own CI runs.

Output never includes the matched text, only `path:line  rule=<name>`, so a hit
in a public CI log is not itself a leak. Exit 1 on any FAIL; WARN rules only print.

Usage:
  check-site-leaks.py [--root DIR] [--plaintext FILE] [--commits N] [PATH ...]
      scan tracked files (default: `git ls-files` under --root) and the last N
      commit messages (default 200). --plaintext adds a plaintext denylist
      (overlay use: run against the upstream submodule before any push).
"""

import argparse
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
LEAKCHECK = HERE.parent / "leakcheck"

TOKEN = re.compile(r"[A-Za-z0-9/~][A-Za-z0-9._@/:+-]*[A-Za-z0-9/]|[A-Za-z0-9]")
SEP = re.compile(r"[./@:]")


def read_list(path):
    out = []
    for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def subtokens(tok):
    """Every span between separator boundaries, so `git.example.internal` yields
    the whole, `example.internal`, `git.example`, each piece, and `/home/x`
    yields `/home`, `/home/x`, `home`, `x`."""
    tok = tok.lower()
    yield tok
    cuts = [0] + [m.start() for m in SEP.finditer(tok)] + [len(tok)]
    n = len(cuts)
    for i in range(n - 1):
        for j in range(i + 1, n):
            start = cuts[i] + (1 if i > 0 else 0)
            seg = tok[start:cuts[j]]
            if seg and seg != tok:
                yield seg
            if i > 0 and tok[cuts[i]] == "/":  # keep a leading slash variant for paths
                seg2 = tok[cuts[i]:cuts[j]]
                if seg2 and seg2 != tok:
                    yield seg2


# --- generic rules -----------------------------------------------------------
RFC1918 = re.compile(r"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3})(?:/\d{1,2})?\b")
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}\b")
EMAIL_OK = re.compile(r"@(?:[a-z0-9.-]+\.)?(users\.noreply\.github\.com|users\.noreply\.example\.org|example\.(org|com|net|internal)|github\.com|anthropic\.com)$")
PIN_SHAPE = re.compile(r"@sha256:|uses:\s*\S+@|# renovate:|ARG \w*_COMMIT=|^\s*[0-9a-f]{64}\s*$|--hash=sha256:")
FAIL_RULES = [
    ("age-recipient", re.compile(r"\bage1[a-z0-9]{58}\b")),
    ("age-secret-key", re.compile(r"AGE-SECRET-KEY-1")),
    ("sops-ciphertext", re.compile(r"ENC\[AES256_GCM")),
    ("sops-metadata", re.compile(r"\bsops_(mac|version|lastmodified|unencrypted_suffix)\b")),
    ("ssh-public-key", re.compile(r"\bssh-(ed25519|rsa|ecdsa-[a-z0-9-]+) AAAA[A-Za-z0-9+/=]{30,}")),
    ("ssh-fingerprint", re.compile(r"\bSHA256:[A-Za-z0-9+/]{43}\b")),
    ("home-path", re.compile(r"(?<![\w/])/(?:home|Users)/[A-Za-z][A-Za-z0-9_-]*")),
    ("commit-sha40", re.compile(r"\b[0-9a-f]{40}\b")),
    ("issue-ref", re.compile(r"(?<![\w/#&])#\d{1,6}\b")),
    ("mr-ref", re.compile(r"(?<![\w/])![0-9]{1,5}\b")),
    ("private-tld", re.compile(r"\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:ts\.net|lan|home\.arpa|internal)\b")),
]
WARN_RULES = [
    ("homelab-word", re.compile(r"\bhomelab\b", re.I)),
    ("short-sha-near-commit", re.compile(r"\b(?:commit|sha|rev|PR)\b[^\n]{0,20}\b[0-9a-f]{7,12}\b", re.I)),
    ("iso-date", re.compile(r"\b20\d\d-[01]\d-[0-3]\d\b")),
]
HOME_OK = {"/home/claude", "/home/user"}
TLD_OK = re.compile(r"\.example\.internal$")


IGNORE_FILE = "leakcheck:ignore-file"
IGNORE_LINE = "leakcheck:ignore"


def scan_text(text, where, plain, allow_ex, allow_repos, report):
    # A file that carries the marker in its first 30 lines (the checker itself, the
    # hook tests) skips the REGEX rules — it exists to contain those patterns. The
    # token rules still run on it: a private string is a leak anywhere.
    regex_off = IGNORE_FILE in "\n".join(text.splitlines()[:30])
    for ln, line in enumerate(text.splitlines(), 1):
        # token pass (the overlay's plaintext denylist, when given)
        for m in TOKEN.finditer(line):
            for st in subtokens(m.group(0)):
                if len(st) < 3:
                    continue
                if st in plain:
                    report("FAIL", where, ln, "private-token")
                    break
        # regex pass
        if regex_off or IGNORE_LINE in line:
            continue
        for m in RFC1918.finditer(line):
            if m.group(0) not in allow_ex:
                report("FAIL", where, ln, "rfc1918-address")
        for m in EMAIL.finditer(line):
            if not EMAIL_OK.search(m.group(0)):
                report("FAIL", where, ln, "email")
        for name, rx in FAIL_RULES:
            for m in rx.finditer(line):
                s = m.group(0)
                if name == "home-path" and s in HOME_OK:
                    continue
                if name == "commit-sha40" and PIN_SHAPE.search(line):
                    continue
                if name == "private-tld" and TLD_OK.search(s):
                    continue
                if name == "ssh-public-key" and s in allow_ex:
                    continue  # a synthetic example key listed in allow-examples.txt
                if name in ("issue-ref", "mr-ref"):
                    before = line[: m.start()]
                    if any(before.rstrip().endswith(r.rstrip("#")) for r in allow_repos):
                        continue
                report("FAIL", where, ln, name)
        for name, rx in WARN_RULES:
            if rx.search(line):
                report("WARN", where, ln, name)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--root", default=str(HERE.parent))
    ap.add_argument("--plaintext", help="plaintext denylist (overlay use only)")
    ap.add_argument("--commits", type=int, default=200)
    args = ap.parse_args()

    root = pathlib.Path(args.root).resolve()
    plain = set(t.lower() for t in read_list(args.plaintext)) if args.plaintext else set()
    allow_ex = set(read_list(LEAKCHECK / "allow-examples.txt")) if (LEAKCHECK / "allow-examples.txt").is_file() else set()
    allow_repos = read_list(LEAKCHECK / "allow-public-repos.txt") if (LEAKCHECK / "allow-public-repos.txt").is_file() else []
    if not plain:
        print("check-site-leaks: no --plaintext list, so only the generic rules run", file=sys.stderr)

    fails, warns = [], []

    def report(level, where, ln, rule):
        (fails if level == "FAIL" else warns).append(f"{where}:{ln}  rule={rule}")

    if args.paths:
        files = [pathlib.Path(p) for p in args.paths]
    else:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True).stdout
        files = [root / p for p in out.decode().split("\0") if p]
    for f in files:
        if not f.is_file():
            continue
        try:
            text = f.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue  # binary or unreadable: not prose
        rel = str(f.resolve().relative_to(root)) if str(f.resolve()).startswith(str(root)) else str(f)
        scan_text(text, rel, plain, allow_ex, allow_repos, report)

    if args.commits and not args.paths:
        log = subprocess.run(["git", "-C", str(root), "log", f"-n{args.commits}", "--format=%H%x00%B%x01"],
                             capture_output=True, text=True)
        if log.returncode == 0:
            for entry in log.stdout.split("\x01"):
                if "\x00" not in entry:
                    continue
                sha, body = entry.split("\x00", 1)
                # GitHub checks out a synthetic "Merge <sha> into <sha>" commit for
                # pull_request events; those SHAs are the PR's own, not provenance.
                if re.match(r"\s*Merge [0-9a-f]{40} into [0-9a-f]{40}\s*$", body):
                    continue
                # The forge writes the merged PR's number into the commit it creates:
                # a "(#N)" suffix on a squash subject, or "Merge pull request #N from".
                # That N is this repo's own PR, not a private tracker; strip it from
                # the subject so the issue-ref rule still fires on refs in the body.
                # A squash body also carries each merged commit's subject as a "* ..."
                # bullet, so a "(#N)" that was fine on a subject reappears there; strip
                # it from those bullets too. Refs anywhere else in the body still fire.
                subject, nl, rest = body.partition("\n")
                subject = re.sub(r"\s\(#\d{1,6}\)\s*$", "", subject)
                subject = re.sub(r"^Merge pull request #\d{1,6} from ", "Merge pull request from ", subject)
                rest = re.sub(r"^(\* .*?)\s\(#\d{1,6}\)\s*$", r"\1", rest, flags=re.M)
                body = subject + nl + rest
                scan_text(body, f"commit {sha[:10]}", plain, allow_ex, allow_repos, report)

    for w in sorted(set(warns)):
        print(f"WARN  {w}")
    for f in sorted(set(fails)):
        print(f"FAIL  {f}")
    print(f"check-site-leaks: {len(set(fails))} fail, {len(set(warns))} warn")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

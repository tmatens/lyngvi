# Security policy

lyngvi is a containment design: its claims are mechanical, and a claim that does not
hold is a security defect even when nothing was exploited. Reports of the following are
welcome and treated as vulnerabilities:

- a way for the agent to reach a host, network or credential the design says it cannot;
- a way for the agent to merge, deploy, or widen its own grants without a human;
- a way for a site value or secret to reach this repository's tree or CI output;
- a hook or check that fails open without announcing it.

If you think your own station's agent is compromised rather than that lyngvi has a flaw,
start with [docs/INCIDENT.md](docs/INCIDENT.md).

## Reporting

Use GitHub's private vulnerability reporting on this repository ("Report a
vulnerability" under the Security tab). Do not open a public issue for a suspected
vulnerability. Include the version or commit, the claim you believe is broken, and a
reproduction on the example site (`site-example/`) if you have one; never include real
site values or secrets.

You will get an acknowledgement within a week. Fixes ship as a tagged release with the
advisory published alongside it; overlays pick the fix up by bumping their pin.

## Scope

In scope: everything in this repository as shipped with the example site. Out of
scope: a site's own overlay values, the Claude Code CLI itself (report to Anthropic),
and the forge or host the station runs on.

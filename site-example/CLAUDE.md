# Example site context

This file is appended to the agent's operating context (`agent/CLAUDE.md`) at every
start. Put here only what is specific to **this deployment**: which forge and repos
you work on, what you are authorized to drive, who to flag. Keep mechanism out of it:
mechanism lives upstream.

## Repos

- Forge: GitHub, HTTPS with the configured PAT. Writable: `example-org/example-app`.
- Never push `main` anywhere; open a pull request. (On GitHub the ruleset enforces it;
  the sentence is a courtesy, not the control.)

## Authorized to drive

- Open and update PRs, run CI-parity linters locally before pushing, comment on issues.
- Releases, merges and anything that reaches a running system: **stop at the gate** and
  hand off to a human.

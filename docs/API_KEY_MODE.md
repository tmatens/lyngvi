# API-key mode

By default a station runs on a claude.ai subscription login and is driven through Remote
Control from the phone or browser. `LYNGVI_MODE=api-key` runs it on an **Anthropic API key**
instead.

| | `remote-control` (default) | `api-key` |
|---|---|---|
| Billing | the subscription's included usage | per token, to the API organization |
| Reached from | the Claude app (Remote Control) | a terminal: `docker exec -it <name> tmux attach -t claude`, over SSH, from a phone SSH app too |
| Credential in the agent | the claude.ai login, which the CLI needs in-process | **none**: the token relay adds the key |
| Re-login | about monthly, plus the refresh race on a recreate (REMOTE_CONTROL.md) | never; the key lasts until revoked |

Remote Control itself cannot run on an API key. The CLI allows it only with a subscription
login ("API keys are not supported"), so this mode has no app access. It is the full
interactive Claude Code otherwise: the same tools, hooks, managed policy and egress layout.

## How the key stays out of the agent

1. **The relay holds the key.** It reads `LYNGVI_ANTHROPIC_API_KEY` from `.env`. The agent's
   service blanks that name, so the agent's copy of `.env` never carries it. The key has its
   own name, not `ANTHROPIC_API_KEY`, for that reason.
2. **The CLI talks to the relay with a placeholder.** The entrypoint writes
   `ANTHROPIC_BASE_URL=http://lyngvi-relay:8084` and a placeholder key into the user
   `settings.json` `env`. Every session reads that file, `docker exec` ones included. It also
   pre-approves the placeholder, so an attached session doesn't stop to ask about it.
3. **The relay swaps in the real key.** It replaces `x-api-key`, passes only
   `/v1/messages` and `/v1/models`, and calls `api.anthropic.com` through the proxy.
4. **A leaked key is caught.** A real key in the agent's environment raises
   `TOKEN_IN_AGENT sev=crit`, and `doctor --live` fails on it.

An agent that changes its own `settings.json` to point elsewhere gets nowhere, because it
has no key to send. The file is rewritten at every start anyway.

## Setting it up

1. **In the Claude Console, create a workspace for the station** and give it a **spend
   limit**. That limit is the real cost cap for an agent that runs unattended. Leave
   auto-reload off if you want promotional or prepaid credit to be a hard stop.
2. **Create an API key in that workspace.** Put it in the site's secrets as
   `LYNGVI_ANTHROPIC_API_KEY`, the same way as the other tokens (`.env.sops` → `.env`).
   Never paste it into a chat, a command line or an issue.
3. **Set `LYNGVI_MODE=api-key`** in `site/site.conf`, then rebuild and recreate.
4. **Attach:** `docker exec -it <name> tmux attach -t claude`. The first time, accept the
   workspace-trust prompt (asked once, as in remote-control mode; the welcome and theme
   screens are already done). Detach with `Ctrl-b d`; the session keeps running. If you exit `claude`, the supervisor starts a new one within 10
   seconds.

`scripts/doctor.sh --live` reports the mode and the relay's Anthropic route. It fails if
the mode is set but the relay has no key.

## Billing: what pays for it

Claude Code on an API key is billed to the organization's **purchased** credit (or
invoicing). Anthropic recognises Claude Code's requests, and **promotional credits that
list "API, Agent SDK, Batch API, Playground, Managed Agents" do not cover them**. Such a
credit pays for a plain Messages API call made with the same key, through the same relay,
but a Claude Code request is refused with `Your credit balance is too low`. The
interactive session shows "Credit balance too low". The relay forwards the CLI's own
headers unchanged, and it must: rewriting them to pass as another client would get around
the billing terms, not configure the station.

So for someone with a Claude subscription (Max, Pro, Team), `remote-control` on the
subscription is the economical mode. `api-key` suits a station with its own Console
budget: an organization without subscriptions, or a team that wants its agent's spend
kept separately, behind a workspace limit.

## Cost

Agentic coding re-sends context on every turn, so a long session on the most capable model
adds up. Measured on Opus: a new session's first call writes about 35k tokens of context
(system prompt, tools, operating context) to the prompt cache, about $0.19 for a
three-turn task. Later turns in the session read that cache at a tenth of the price. The
Console's "Spend this month" shows it per workspace, and the workspace limit
stops it. A trial on a fixed credit, with auto-reload off, is the safe way to learn what a
typical task costs before deciding which mode a station should run in.

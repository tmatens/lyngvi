# An audit trail the agent cannot edit

Everything the agent's own container writes, the alert markers included, can be forged or
silenced by an agent that has been compromised (DESIGN.md §10). This page sets up the two
records that hold even then, because they leave the box or come from a container the agent
cannot touch:

1. **The proxy's log.** Every connection the agent made, allowed or refused, and the
   `CANARY_TOUCHED` marker. It is always there. Shipping it off the host is the site's job.
2. **Tool-call telemetry.** Every tool the agent ran, with its parameters, exported as it
   happens to a collector the site runs. It is opt-in.

Neither one stops anything. They are how you find out afterwards, and the reason
docs/INCIDENT.md can trust what it reads.

## 1. Ship the proxy's log

The proxy container (`lyngvi-proxy`, or your overlay's name) logs to stdout. Any shipper
that reads Docker container logs works. Two common ones:

```alloy
// Grafana Alloy: the container name becomes a `container` label, as the alerts below assume.
discovery.docker "lyngvi" {
  host = "unix:///var/run/docker.sock"
  filter {
    name   = "name"
    values = ["lyngvi-proxy", "lyngvi"]
  }
}
discovery.relabel "lyngvi" {
  targets = []
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }
}
loki.source.docker "lyngvi" {
  host          = "unix:///var/run/docker.sock"
  targets       = discovery.docker.lyngvi.targets
  relabel_rules = discovery.relabel.lyngvi.rules
  forward_to    = [loki.write.default.receiver]
}
```

```yaml
# Vector: the container name is the event's `container_name` field.
sources:
  lyngvi:
    type: docker_logs
    include_containers: ["lyngvi-proxy", "lyngvi"]
```

The shipper runs on the host, outside the agent's reach. That is the point. Ship the agent
container's log too, for the markers, but remember that the agent can write to that one.

### Alerts

Use one rule per meaning. These are in LogQL; translate them for your stack.

| Alert | Query | Severity |
|---|---|---|
| A decoy credential was used | `{container="lyngvi-proxy"} \|= "CANARY_TOUCHED sev=crit"` | crit: page, then docs/INCIDENT.md |
| A burst of refusals | `sum(count_over_time({container="lyngvi-proxy"} \|= "refused on filtered domain" [10m])) > 20` | warn |
| Any lyngvi marker | `{container=~"lyngvi.*"} \|~ "[A-Z_]+ sev=(warn\|crit)"` | the marker's own |

The refusal threshold is a starting point. A station that runs package installs against
registries it has not allowlisted will see a steady trickle, so set it above your normal rate.

## 2. Tool-call telemetry (opt-in)

Claude Code can export an OpenTelemetry event for every tool decision and result. lyngvi
turns that on **in managed settings** when the site names a collector, so the agent cannot
turn it off. Tested: an agent-written user `settings.json` that disables telemetry or
points it elsewhere has no effect.

In `site/settings.json`:

```json
{
  "env": {
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://otel.example.org",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf"
  }
}
```

The image build adds `CLAUDE_CODE_ENABLE_TELEMETRY=1`, `OTEL_LOGS_EXPORTER=otlp` and
`OTEL_LOG_TOOL_DETAILS=1` (`agent/managed-settings.mjs`). Put any exporter header that
carries a token (`OTEL_EXPORTER_OTLP_HEADERS`) in the same file only if your collector
needs one. It becomes part of the image, so prefer a collector that authenticates by
network instead.

Then:

- **Allowlist the collector's host** in `site/proxy-filter.extra`. A TLS port other than
  443 also needs a `ConnectPort` line in `site/proxy-tinyproxy.extra`. `scripts/doctor.sh
  --live` probes the collector through the proxy and warns when it is refused.
- **Rebuild.** The setting lives in the image.

### What the collector receives

Verified against the CLI with `OTEL_LOG_TOOL_DETAILS=1` and nothing more:

| Event | Carries |
|---|---|
| `tool_decision` | the tool, the decision (accept / reject) and its source, and the **parameters**: for Bash the full command |
| `tool_result` | the tool, success, duration, the parameters and input, and the output's **size** only |
| `user_prompt`, `assistant_response` | their length. The text arrives as `<REDACTED>` |
| `api_request` | model, tokens, cost, duration |
| `hook_*`, `mcp_server_connection`, `managed_settings_resolved` | what ran at start and around each tool |

Every event also carries the account's identifiers: `user.email`, `user.account_uuid` and
`organization.id`.

**Treat the collector as sensitive.** A tool's parameters are whatever the agent typed. A
command with a token on its argv is exactly what the block hook exists to stop, and if one
gets through, the collector stores it.
- Restrict who can read the collector.
- Give it a retention period.
- Never use it as a place to look up secrets.

Turning on `OTEL_LOG_TOOL_CONTENT`, `OTEL_LOG_USER_PROMPTS`,
`OTEL_LOG_ASSISTANT_RESPONSES` or `OTEL_LOG_RAW_API_BODIES` **fails the image build**.
Those would put tool output, prompts and model output in the collector too, which is
everything the agent saw, secrets included.

### What this does not cover

- **A session that started before the build that turned telemetry on.** The setting takes
  effect at the next start.
- **Actions taken outside the CLI's tools.** One example is a process a tool started that
  keeps running after the tool returns. Its network traffic still shows in the proxy's log.
- **Proof that a command did what its text says.** The parameters are what was asked, and the
  proxy's log is what reached the network. Read them together.

#!/usr/bin/env bash
# Liveness only: a Remote Control container exposes no port, so we confirm the
# agent process is running, so an external monitor can alert on `health=unhealthy`. It does NOT verify the
# relay link is connected — a >10-min outage exits RC and the entrypoint loop
# relaunches it; during that window the container may report healthy between
# retries. See DESIGN.md, liveness.
#
# Relay-connectivity alerting does NOT ride this healthcheck: the entrypoint
# supervisor loop emits an `RC_RELAY_DROP sev=warn` marker whenever RC drops after
# having been up, so a generic log-alert rule (match `sev=warn|crit`) catches real
# relay outages even while this liveness probe reads healthy. It also emits an
# `RC_REGISTER_FAIL sev=crit` marker after repeated fast 401/OAuth-auth exits (the
# cold-recreate re-login loop that never self-recovers) so that outage pages fast
# instead of hiding behind this liveness probe's healthy reads.
# api-key mode has no Remote Control: healthy while the supervised tmux session exists.
if grep -qx 'supervisor=api-key' /tmp/lyngvi-status 2>/dev/null; then
  tmux has-session -t claude 2>/dev/null || exit 1
else
  pgrep -f 'claude remote-control' >/dev/null || exit 1
fi

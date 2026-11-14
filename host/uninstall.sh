#!/usr/bin/env bash
# host/uninstall.sh — remove what a pre-v0.5 `host/install.sh` put on a docker host, as root:
# the lyngvi-firewall/lyngvi-agent units and drop-in, the root-owned script and config,
# the LYNGVI_EGRESS chain and its DOCKER-USER jump, and the INPUT drops. The host firewall
# path was replaced by the egress layout in v0.3.0 and removed in v0.5.0; nothing replaces
# it on the host (host/README.md).
#
#   sudo upstream/host/uninstall.sh
#
# Never stops the agent container: the agent unit's ExecStop is `docker stop`, so it is
# neutralised with a runtime drop-in before the unit is stopped, and the firewall unit is
# stopped only after the agent unit (a stop propagates along Requires=). Reads the subnets
# from the INSTALLED /etc/lyngvi/firewall.conf, so it needs no site inputs. Takes an
# iptables-save snapshot first, verifies at the end (exit 1 if anything is left), and is
# idempotent. Run it once the stack runs on the egress layout (scripts/doctor.sh --live).
set -euo pipefail
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }
log() { echo "[lyngvi-uninstall] $*"; }
conf() { local v; v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1); v="${v%\"}"; v="${v#\"}"; printf '%s' "$v"; }

FW_INST=/etc/lyngvi/firewall.conf
UNITS=(lyngvi-agent.service lyngvi-firewall.timer lyngvi-firewall-refresh.service lyngvi-firewall.service)
sub=""; subs=""
[[ -f "$FW_INST" ]] && { sub="$(conf "$FW_INST" LYNGVI_SUBNET)"; subs="$(conf "$FW_INST" LYNGVI_SUBNETS)"; }
subs="${subs:-$sub}"

snap="/root/iptables.before.lyngvi-uninstall.$(date +%Y%m%d%H%M%S)"
iptables-save > "$snap" 2>/dev/null && chmod 600 "$snap" && log "iptables snapshot: $snap"

if systemctl cat lyngvi-agent.service >/dev/null 2>&1; then
  install -d -m 755 /run/systemd/system/lyngvi-agent.service.d
  printf '[Service]\nExecStop=\n' > /run/systemd/system/lyngvi-agent.service.d/zz-uninstall.conf
  systemctl daemon-reload
fi
for u in "${UNITS[@]}"; do
  systemctl disable --quiet "$u" 2>/dev/null || true
  systemctl stop "$u" 2>/dev/null || true
done
for u in "${UNITS[@]}"; do rm -f "/etc/systemd/system/$u"; done
rm -rf /etc/systemd/system/lyngvi-agent.service.d /run/systemd/system/lyngvi-agent.service.d
systemctl daemon-reload
systemctl reset-failed "${UNITS[@]}" 2>/dev/null || true

if [[ -n "$sub" ]]; then
  while iptables -C DOCKER-USER -s "$sub" -j LYNGVI_EGRESS 2>/dev/null; do iptables -D DOCKER-USER -s "$sub" -j LYNGVI_EGRESS; done
fi
if iptables -nL LYNGVI_EGRESS >/dev/null 2>&1; then
  if iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j LYNGVI_EGRESS'; then
    echo "LYNGVI_EGRESS is still referenced from DOCKER-USER (subnet not in $FW_INST?) — left in place" >&2
  else
    iptables -F LYNGVI_EGRESS && iptables -X LYNGVI_EGRESS
  fi
fi
for s in $subs; do while iptables -C INPUT -s "$s" -j DROP 2>/dev/null; do iptables -D INPUT -s "$s" -j DROP; done; done
rm -f /usr/local/sbin/lyngvi-firewall.sh "$FW_INST"; rmdir /etc/lyngvi 2>/dev/null || true

left=0
for u in "${UNITS[@]}"; do [[ -e "/etc/systemd/system/$u" ]] && { echo "still present: /etc/systemd/system/$u" >&2; left=1; }; done
iptables -nL LYNGVI_EGRESS >/dev/null 2>&1 && { echo "still present: LYNGVI_EGRESS chain" >&2; left=1; }
for s in $subs; do iptables -C INPUT -s "$s" -j DROP 2>/dev/null && { echo "still present: INPUT drop for $s" >&2; left=1; }; done
(( left )) && exit 1
log "host side removed${subs:+ (subnets: $subs)}. ip6tables guard rules, if any, are not persisted and go at the next reboot."
log "the container was not touched"

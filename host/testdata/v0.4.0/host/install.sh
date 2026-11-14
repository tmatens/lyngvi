#!/usr/bin/env bash
# host/install.sh — install or refresh the HOST side of a lyngvi deployment, as root:
# the egress firewall script, its values, the two firewall units and the agent unit
# that starts the container only after the firewall is applied (HOST_SETUP.md).
#
# What systemd executes afterwards is the root-owned copy under /usr/local/sbin and
# /etc — never the clone — so a merged change to host/ reaches the host only when a
# human re-runs this. Idempotent: every run re-installs, re-applies and verifies.
#
#   sudo upstream/host/install.sh                       # from the overlay root
#   sudo upstream/host/install.sh --site site --container my-station
#   sudo upstream/host/install.sh --check               # drift report only, no changes
#   sudo upstream/host/install.sh --uninstall           # remove the host side (migration)
#
#   --site DIR        directory holding firewall.conf (+ site.conf for the container
#                     name); default ./site, else this repo's site-example/
#   --container NAME  the agent container the unit starts (default: CONTAINER_NAME
#                     from site.conf, else lyngvi); a drop-in carries a non-default name
#   --check           compare the installed copies, the drop-in, the units' state and
#                     the live chain with the clone; exit 1 on any difference
#   --uninstall       remove everything an install put on the host — units, drop-in,
#                     root-owned copies, the chain, the jump, the INPUT drops — without
#                     stopping the container; needs no site inputs; idempotent
#
# Order of operations on apply (never opens an egress window, never stops or restarts
# the container — CI proves the container's start time is unchanged by a re-run):
#   0 preconditions  1 iptables snapshot  2 install files + daemon-reload
#   3 apply the firewall, verify the chain  4 enable the agent unit  5 print the state
set -euo pipefail
echo "NOTE: the host firewall path is DEPRECATED — the egress layout in docker-compose.yml needs nothing on the host (host/HOST_SETUP.md)." >&2
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
UP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE=""; CONTAINER=""; CHECK=0; UNINSTALL=0
usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while (( $# )); do
  case "$1" in
    --site) SITE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done
[[ -n "$SITE" ]] || { if [[ -d site ]]; then SITE=site; else SITE="$UP/site-example"; fi; }
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0 $*" >&2; exit 1; }
log() { echo "[lyngvi-install] $*"; }
conf() { local v; v=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n1); v="${v%\"}"; v="${v#\"}"; printf '%s' "$v"; }

# ── --uninstall: the migration off this path (HOST_SETUP.md "Migrating") ──────
# Reads the subnets from the INSTALLED copy of firewall.conf, so it works after the
# overlay has deleted site/firewall.conf. Never stops the container: the agent unit's
# ExecStop is `docker stop`, so it is neutralised with a runtime drop-in before the unit
# is stopped, and the firewall unit is stopped only after the agent unit (a stop of a
# Requires= target propagates to its dependents). Run it only once the stack is on the
# egress layout — doctor --live first — or the agent is left with no egress control.
if (( UNINSTALL )); then
  FW_INST=/etc/lyngvi/firewall.conf
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
  for u in lyngvi-agent.service lyngvi-firewall.timer lyngvi-firewall-refresh.service lyngvi-firewall.service; do
    systemctl disable --quiet "$u" 2>/dev/null || true
    systemctl stop "$u" 2>/dev/null || true
  done
  rm -f /etc/systemd/system/lyngvi-agent.service /etc/systemd/system/lyngvi-firewall.service \
        /etc/systemd/system/lyngvi-firewall.timer /etc/systemd/system/lyngvi-firewall-refresh.service
  rm -rf /etc/systemd/system/lyngvi-agent.service.d /run/systemd/system/lyngvi-agent.service.d
  systemctl daemon-reload
  systemctl reset-failed lyngvi-agent.service lyngvi-firewall.service lyngvi-firewall-refresh.service 2>/dev/null || true
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
  for u in lyngvi-agent.service lyngvi-firewall.service lyngvi-firewall.timer lyngvi-firewall-refresh.service; do
    [[ -e "/etc/systemd/system/$u" ]] && { echo "still present: /etc/systemd/system/$u" >&2; left=1; }
  done
  iptables -nL LYNGVI_EGRESS >/dev/null 2>&1 && { echo "still present: LYNGVI_EGRESS chain" >&2; left=1; }
  for s in $subs; do iptables -C INPUT -s "$s" -j DROP 2>/dev/null && { echo "still present: INPUT drop for $s" >&2; left=1; }; done
  (( left )) && exit 1
  log "host side removed${subs:+ (subnets: $subs)}. The ip6tables guard rules, if any, are not persisted and go at the next reboot."
  log "the container was not touched; with restart: \"no\" the daemon will not restart it after a reboot until a release flips the policy — docker compose up -d does"
  exit 0
fi
[[ -n "$CONTAINER" ]] || CONTAINER="$(conf "$SITE/site.conf" CONTAINER_NAME)"
CONTAINER="${CONTAINER:-lyngvi}"

FW_SRC="$SITE/firewall.conf"; FW_DST=/etc/lyngvi/firewall.conf
SCRIPT_SRC="$UP/host/lyngvi-firewall.sh"; SCRIPT_DST=/usr/local/sbin/lyngvi-firewall.sh
UNITS=(lyngvi-firewall.service lyngvi-firewall.timer lyngvi-agent.service)   # enabled + active
REFRESH_UNIT=lyngvi-firewall-refresh.service                                  # static: the timer's target
DROPIN_DIR=/etc/systemd/system/lyngvi-agent.service.d; DROPIN="$DROPIN_DIR/override.conf"
dropin_content() {
  printf '# Generated by host/install.sh: the agent container of this site is not named\n# "lyngvi", so only the two Exec lines of the upstream unit change.\n[Service]\nExecStart=\nExecStart=/usr/bin/docker start %s\nExecStop=\nExecStop=/usr/bin/docker stop %s\n' "$CONTAINER" "$CONTAINER"
}

# ── 0. preconditions: inputs present and parseable before anything changes ────
for f in "$FW_SRC" "$SCRIPT_SRC" "$UP/host/lyngvi-firewall.service" "$UP/host/lyngvi-firewall.timer" "$UP/host/lyngvi-agent.service" "$UP/host/$REFRESH_UNIT"; do
  [[ -f "$f" ]] || { echo "missing $f" >&2; exit 1; }
done
subnet="$(conf "$FW_SRC" LYNGVI_SUBNET)"
[[ -n "$subnet" ]] || { echo "$FW_SRC sets no LYNGVI_SUBNET" >&2; exit 1; }
LYNGVI_FIREWALL_ENV="$FW_SRC" bash "$SCRIPT_SRC" --dry-run >/dev/null   # the conf parses with the script that will run it
command -v iptables >/dev/null || { echo "iptables not found (the firewall script needs the iptables Docker backend)" >&2; exit 1; }
have_container=0
docker inspect --format '{{.State.Status}}' "$CONTAINER" >/dev/null 2>&1 && have_container=1

# ── --check: drift only ───────────────────────────────────────────────────────
if (( CHECK )); then
  drift=0
  say() { echo "  $1  $2"; [[ "$1" == "differs" || "$1" == "missing" || "$1" == "wrong" ]] && drift=1; return 0; }
  for pair in "$FW_DST:$FW_SRC" "$SCRIPT_DST:$SCRIPT_SRC" \
              "/etc/systemd/system/lyngvi-firewall.service:$UP/host/lyngvi-firewall.service" \
              "/etc/systemd/system/lyngvi-firewall.timer:$UP/host/lyngvi-firewall.timer" \
              "/etc/systemd/system/lyngvi-agent.service:$UP/host/lyngvi-agent.service" \
              "/etc/systemd/system/$REFRESH_UNIT:$UP/host/$REFRESH_UNIT"; do
    inst="${pair%%:*}"; src="${pair#*:}"
    if [[ ! -f "$inst" ]]; then say missing "$inst"; elif cmp -s "$inst" "$src"; then say same "$inst"; else say differs "$inst (vs $src)"; fi
  done
  if [[ "$CONTAINER" == lyngvi ]]; then
    if [[ -f "$DROPIN" ]]; then say wrong "$DROPIN exists but the container is named lyngvi"; else say same "no drop-in needed (container lyngvi)"; fi
  else
    if [[ -f "$DROPIN" ]] && cmp -s "$DROPIN" <(dropin_content); then say same "$DROPIN starts $CONTAINER"; else say differs "$DROPIN (expected to start $CONTAINER)"; fi
  fi
  for u in "${UNITS[@]}"; do
    st="$(systemctl is-active "$u" 2>/dev/null || true)/$(systemctl is-enabled "$u" 2>/dev/null || true)"
    if [[ "$st" == active/enabled ]]; then say same "$u $st"
    elif [[ "$u" == lyngvi-agent.service && "$st" == inactive/enabled ]] && (( ! have_container )); then say same "$u enabled; inactive until container $CONTAINER exists"
    else say wrong "$u $st (expected active/enabled)"; fi
  done
  if [[ "$(systemctl show -p Unit --value lyngvi-firewall.timer 2>/dev/null)" == "$REFRESH_UNIT" ]]; then say same "lyngvi-firewall.timer triggers $REFRESH_UNIT"; else say wrong "lyngvi-firewall.timer does not trigger $REFRESH_UNIT (an active RemainAfterExit target never re-runs)"; fi
  if iptables -C DOCKER-USER -s "$subnet" -j LYNGVI_EGRESS 2>/dev/null; then say same "DOCKER-USER jumps $subnet into LYNGVI_EGRESS"; else say missing "DOCKER-USER jump for $subnet"; fi
  for s in $(conf "$FW_SRC" LYNGVI_SUBNETS); do iptables -C INPUT -s "$s" -j DROP 2>/dev/null || say missing "INPUT drop for $s"; done
  if (( drift )); then log "drift found — re-run without --check to install and apply"; exit 1; fi
  log "installed host side matches the clone"; exit 0
fi

cstate='not created yet'; (( have_container )) && cstate="$(docker inspect --format '{{.State.Status}}' "$CONTAINER")"
log "inputs ok: site=$SITE agent subnet=$subnet container=$CONTAINER ($cstate)"

# ── 1. snapshot ───────────────────────────────────────────────────────────────
snap="/root/iptables.before.lyngvi.$(date +%Y%m%d%H%M%S)"
iptables-save > "$snap"; chmod 600 "$snap"
log "iptables snapshot: $snap (rollback: iptables-restore < $snap)"

# ── 2. files: root-owned copies, decoupled from the clone ─────────────────────
install -d -m 755 /etc/lyngvi
install -m 644 -o root -g root "$FW_SRC" "$FW_DST"
install -m 700 -o root -g root "$SCRIPT_SRC" "$SCRIPT_DST"
install -m 644 -o root -g root "$UP/host/lyngvi-firewall.service" "$UP/host/lyngvi-firewall.timer" "$UP/host/lyngvi-agent.service" "$UP/host/$REFRESH_UNIT" /etc/systemd/system/
if [[ "$CONTAINER" == lyngvi ]]; then
  [[ -f "$DROPIN" ]] && { rm -f "$DROPIN"; rmdir "$DROPIN_DIR" 2>/dev/null || true; log "removed a stale container-name drop-in"; }
else
  install -d -m 755 "$DROPIN_DIR"
  dropin_content > "$DROPIN.tmp" && chmod 644 "$DROPIN.tmp" && mv "$DROPIN.tmp" "$DROPIN"
fi
systemctl daemon-reload
log "installed $FW_DST, $SCRIPT_DST, ${UNITS[*]}, $REFRESH_UNIT$( [[ "$CONTAINER" != lyngvi ]] && echo ", drop-in for container $CONTAINER" )"

# ── 3. the firewall, applied now and on every boot / docker restart / day ─────
# Never `systemctl restart lyngvi-firewall.service` here: lyngvi-agent.service has
# Requires= on it, and systemd propagates a restart of a required unit to its
# dependents — the agent unit would run ExecStop (docker stop) and ExecStart, i.e.
# bounce the container. The script is idempotent, so apply it directly (it reads
# /etc/lyngvi/firewall.conf itself) and `start` the unit, which is a no-op when it
# is already active and runs the same script when it is not.
systemctl enable --quiet lyngvi-firewall.service lyngvi-firewall.timer
"$SCRIPT_DST" >/dev/null
systemctl start lyngvi-firewall.service
systemctl restart lyngvi-firewall.timer   # picks up a changed Unit= target; a timer restart propagates nowhere
systemctl is-active --quiet lyngvi-firewall.service || { echo "lyngvi-firewall.service is not active — journalctl -u lyngvi-firewall.service; rules from the snapshot are still in place" >&2; exit 1; }
iptables -C DOCKER-USER -s "$subnet" -j LYNGVI_EGRESS || { echo "LYNGVI_EGRESS jump missing after apply" >&2; exit 1; }
for s in $(conf "$FW_SRC" LYNGVI_SUBNETS); do
  iptables -C INPUT -s "$s" -j DROP || { echo "INPUT drop missing for $s after apply" >&2; exit 1; }
done
log "firewall active: LYNGVI_EGRESS has $(iptables -S LYNGVI_EGRESS | wc -l) rules, DOCKER-USER jump present, INPUT drops present"

# ── 4. the agent unit: enabled always; started now only if the container exists
#       (`docker start` on a running container is a no-op, so this never restarts it)
systemctl enable --quiet lyngvi-agent.service
if (( have_container )); then
  systemctl start lyngvi-agent.service
  systemctl is-active --quiet lyngvi-agent.service || { echo "lyngvi-agent.service is not active — journalctl -u lyngvi-agent.service" >&2; exit 1; }
  log "lyngvi-agent.service active: $CONTAINER is $(docker inspect --format '{{.State.Status}}' "$CONTAINER")"
else
  log "lyngvi-agent.service enabled; container $CONTAINER does not exist yet — after 'docker compose up -d --build', run: systemctl start lyngvi-agent.service"
fi

# ── 5. state ──────────────────────────────────────────────────────────────────
log "units: firewall=$(systemctl is-active lyngvi-firewall.service) timer=$(systemctl is-active lyngvi-firewall.timer) agent=$(systemctl is-active lyngvi-agent.service 2>/dev/null || echo inactive)"
log "done — verify: sudo $0 --check, then the leak test (scripts/doctor.sh --live as root, or HOST_SETUP.md §4)"

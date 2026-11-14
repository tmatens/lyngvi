# host/: nothing to install

Since v0.3.0 the egress control is the network definition in `docker-compose.yml`
(`DESIGN.md` §4.2): the agent's networks are `internal` with an isolated gateway, and the
proxy sidecar is its only path out. Nothing is applied on the docker host. The only host
requirement is Docker Engine ≥ 28.0.

The host firewall path that came before it (a `DOCKER-USER` chain, `INPUT` drops and
systemd units installed by `host/install.sh`) was deprecated in v0.3.0 and removed in
v0.5.0. A host that still carries it (`scripts/doctor.sh` warns when it finds the units)
removes it with the one script left here:

```bash
sudo upstream/host/uninstall.sh      # from the overlay root
```

It never stops the agent container, reads the subnets from the installed
`/etc/lyngvi/firewall.conf`, snapshots `iptables-save` to `/root/` first, verifies that
nothing is left, and is safe to re-run. Then delete `site/firewall.conf` from the overlay
if it is still there.

A site upgrading from v0.3.x or older: run the uninstall before taking v0.4.0 or later.
From v0.4.0 the agent is `restart: unless-stopped`, so with the old units still installed
the daemon would restart it before the unit re-applied the firewall.

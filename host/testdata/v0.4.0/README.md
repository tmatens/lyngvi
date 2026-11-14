# v0.4.0 host installer (test fixture)

The files `host/install.sh` shipped with in v0.4.0, and the two example site files it
reads, unchanged. CI's `host-uninstall` job installs the old host firewall path from here
and then proves that `host/uninstall.sh` removes every piece of it. Nothing here is
installed on a host any more; see [../../README.md](../../README.md).

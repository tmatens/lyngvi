#!/bin/sh
# start.sh — the key sidecar's entrypoint: hold the SSH keys in an ssh-agent and serve
# only its socket to the agent container (DESIGN.md §5).
#
# The private keys arrive in this container's environment (GIT_SSH_KEY_B64 and any
# SSH_KEY_<NAME>_B64, from the site's secrets file) and never reach the agent's. They are
# decoded to a tmpfs, added to ssh-agent, and deleted, so afterwards they exist only in
# the agent process's memory. This container has no network at all (network_mode: none),
# so nothing in it can send a key anywhere. The agent container gets the socket and the
# public keys on a shared volume: it can sign and push, but it cannot copy a private key
# out, because it never holds one.
#
# ssh-agent accepts connections only from its own uid. This container runs as the
# agent's uid (10001) for that reason.
set -u
S=/run/lyngvi-keys
W=/tmp/keys
umask 077
mkdir -p "$W"
rm -f "$S/agent.sock" "$S"/*.pub

ssh-agent -D -a "$S/agent.sock" &
agent=$!
trap 'kill -TERM "$agent" 2>/dev/null' TERM INT
i=0; while [ ! -S "$S/agent.sock" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
export SSH_AUTH_SOCK="$S/agent.sock"

load() { # $1 = name, $2 = base64 of an OpenSSH private key
  if ! printf '%s' "$2" | base64 -d > "$W/$1" 2>/dev/null; then
    echo "[keys] WARN: could not decode $1"; rm -f "$W/$1"; return
  fi
  chmod 600 "$W/$1"
  if ssh-add -q "$W/$1" 2>/dev/null && ssh-keygen -y -f "$W/$1" > "$S/$1.pub.tmp" 2>/dev/null; then
    chmod 644 "$S/$1.pub.tmp" && mv "$S/$1.pub.tmp" "$S/$1.pub"
    echo "[keys] loaded $1"
  else
    rm -f "$S/$1.pub.tmp"; echo "[keys] WARN: ssh-add failed for $1"
  fi
  rm -f "$W/$1"
}

if [ -n "${GIT_SSH_KEY_B64:-}" ]; then load git_key "$GIT_SSH_KEY_B64"; else echo "[keys] no GIT_SSH_KEY_B64"; fi
for var in $(env | sed -n 's/^\(SSH_KEY_[A-Z0-9_]*_B64\)=.*/\1/p'); do
  name=$(printf '%s' "${var#SSH_KEY_}" | sed 's/_B64$//' | tr '[:upper:]' '[:lower:]')
  eval "val=\${$var}"
  [ -n "$val" ] && load "$name" "$val"
done
unset val GIT_SSH_KEY_B64
rm -rf "$W"
echo "[keys] ready: $(ssh-add -l 2>/dev/null | grep -c SHA256 || true) key(s) on $S/agent.sock"
wait "$agent"

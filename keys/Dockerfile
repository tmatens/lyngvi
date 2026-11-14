# The key sidecar (keys/start.sh): an ssh-agent holding the SSH keys, serving only its
# socket to the agent. No network (network_mode: none in compose), no shell for anyone
# else, read-only root, and the agent's uid, which ssh-agent requires of its clients.
FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
RUN apk add --no-cache openssh-client \
    && adduser -D -H -u 10001 claude \
    && install -d -o 10001 -g 10001 -m 0700 /run/lyngvi-keys
COPY --chmod=0755 keys/start.sh /usr/local/bin/keys-start
USER 10001
ENTRYPOINT ["/usr/local/bin/keys-start"]

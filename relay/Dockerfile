# The token relay (relay/start.sh): the API tokens live here, never in the agent. Plain
# HTTP in from the agent on the internal proxy network; verified HTTPS out, through
# lyngvi-proxy, with the token added and a short list of endpoints refused.
FROM caddy:2.11.7-alpine@sha256:e70b164da81ef698b3ad19af799ea6086ce6d9e48ed4079eb9fe26f6fbf14ee5
# The upstream binary carries cap_net_bind_service (to bind :80). The relay binds only
# high ports and runs with every capability dropped and no-new-privileges, under which the
# kernel refuses to exec a file with capabilities: a plain copy drops the attribute.
RUN cp /usr/bin/caddy /tmp/caddy && mv /tmp/caddy /usr/bin/caddy
COPY --chmod=0755 relay/start.sh /usr/local/bin/relay-start
ENV XDG_DATA_HOME=/tmp/relay/data \
    XDG_CONFIG_HOME=/tmp/relay/config
USER 10003
ENTRYPOINT ["/usr/local/bin/relay-start"]

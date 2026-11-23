# Hostname-allowlist forward proxy — the ONLY path out of the Tier-0 agent's
# gateway-less networks (DESIGN.md, egress): the relay, the forge, GitHub and the
# package registries all go through it, by hostname, so IP rotation is irrelevant
# and nothing not listed is reachable. Built (not pulled) so Renovate tracks the
# alpine base (build + pin).
FROM scratch AS site
COPY site-example/ /

FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# hadolint ignore=DL3018
RUN apk add --no-cache tinyproxy \
    && adduser -D -H -u 10002 tinyproxy 2>/dev/null || true

# `site` is a BuildKit named context: `FROM scratch AS site` is the default (the
# upstream example), and an overlay's compose `additional_contexts: {site: ./site}`
# overrides it with real files. See docs/OVERLAY.md.
COPY proxy/tinyproxy.conf /etc/tinyproxy/tinyproxy.base
COPY --from=site /proxy-tinyproxy.extra /etc/tinyproxy/tinyproxy.site
COPY --from=site /proxy-filter.extra /etc/tinyproxy/filter.site
COPY proxy/filter /etc/tinyproxy/filter.base
COPY proxy/presets/ /etc/tinyproxy/presets/
COPY --chmod=0755 proxy/check-filter.sh /usr/local/bin/check-filter
# The entrypoint wraps tinyproxy to raise CANARY_TOUCHED (proxy/start.sh). /canary is
# where the per-install decoy hostnames live: a named volume copies this directory's
# ownership on first use, so the unprivileged proxy user can write it once.
COPY --chmod=0755 proxy/start.sh /usr/local/bin/proxy-start
RUN install -d -o 10002 -g 10002 -m 0755 /canary
# Opt-in host groups a toolchain needs (proxy/presets/<name>.filter), comma- or
# space-separated: PROXY_PRESETS=go. An unknown name fails the build rather than
# silently opening nothing. Order: base, presets, then the site's own lines.
ARG PROXY_PRESETS=""
# The list is split on commas and spaces by the shell itself (IFS), globbing off.
# hadolint ignore=SC2086
RUN cat /etc/tinyproxy/tinyproxy.base /etc/tinyproxy/tinyproxy.site > /etc/tinyproxy/tinyproxy.conf \
    && cp /etc/tinyproxy/filter.base /etc/tinyproxy/filter \
    && IFS=', ' && set -f && set -- $PROXY_PRESETS && unset IFS && set +f \
    && for p in "$@"; do \
         f="/etc/tinyproxy/presets/$p.filter"; \
         [ -f "$f" ] || { echo "unknown proxy preset: $p (the presets are proxy/presets/*.filter)" >&2; exit 1; }; \
         cat "$f" >> /etc/tinyproxy/filter; \
       done \
    && cat /etc/tinyproxy/filter.site >> /etc/tinyproxy/filter \
    # Every line must be a hostname pattern (proxy/check-filter.sh): one regex such as
    # `^a|[a-z0-9-]+$` would otherwise allow every host. A bad line fails the build.
    && check-filter /etc/tinyproxy/filter

USER 10002
EXPOSE 3128
ENTRYPOINT ["/usr/local/bin/proxy-start"]

#!/bin/sh
# start.sh — the token relay's entrypoint (DESIGN.md §4.3). Generates the Caddy config
# for the tokens this site set, then runs Caddy.
#
# The agent holds no API token: its service blanks GITHUB_TOKEN and FORGE_API_TOKEN. Its
# clients (the MCP servers, git over HTTPS) talk plain HTTP to this relay on the internal
# proxy network. The relay adds the token, refuses a short list of endpoints the token
# could reach but the agent must not (webhooks, keys, mirrors, collaborators, secrets,
# token creation), and makes the verified HTTPS call itself through lyngvi-proxy, so the
# hostname allowlist still applies and the proxy logs every call.
#
#   :8081  GitHub REST + GraphQL  http://lyngvi-relay:8081/api/v3/…  → https://api.github.com/…
#   :8082  git over HTTPS (github) http://lyngvi-relay:8082/<o>/<r>… → https://github.com/…
#   :8083  the forge API (Forgejo/Gitea) http://lyngvi-relay:8083/api/v1/… → FORGE_API_BASE
#   :8084  the Anthropic API, for LYNGVI_MODE=api-key: /v1/messages and /v1/models only, with
#          the key from LYNGVI_ANTHROPIC_API_KEY (its own name, so the agent's copy of .env
#          never carries a real ANTHROPIC_API_KEY) set as x-api-key
#
# A route exists only when its token is set. GET /_lyngvi on a port answers 200 when that
# route is configured, which is how the agent's entrypoint finds out. The tokens reach
# Caddy as {$VAR} placeholders resolved in memory. The generated file on the tmpfs holds
# only the placeholder, never the value.
# shellcheck disable=SC2016  # '{$VAR}' is a Caddy placeholder, resolved by Caddy, never by sh
set -u
C=/tmp/relay/Caddyfile
P="${RELAY_PROXY:-http://lyngvi-proxy:3128}"
mkdir -p /tmp/relay
DENY_MSG='"refused by the lyngvi relay: this endpoint is not available to the agent (upstream DESIGN.md §4.3)" 403'

upstream() { # $1 = upstream origin, $2 = Host header, $3 = Authorization value
  cat <<EOF
      reverse_proxy $1 {
        header_up Host $2
        header_up Authorization "$3"
        header_up -Cookie
        transport http {
          forward_proxy_url $P
        }
      }
EOF
}

{
  cat <<EOF
{
  admin off
  auto_https off
  persist_config off
  log {
    output stdout
    format console
  }
}
EOF

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    GITHUB_BASIC=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)
    export GITHUB_BASIC
    cat <<EOF
:8081 {
  route {
    respond /_lyngvi 200
    @deny path_regexp ^/api/v3/(repos/[^/]+/[^/]+/(hooks|keys|collaborators|invitations|actions/secrets|actions/variables|environments/[^/]+/secrets|dependabot/secrets|codespaces/secrets)|orgs/[^/]+/(hooks|actions/secrets|members|invitations)|user/(keys|gpg_keys|ssh_signing_keys|emails)|authorizations|applications|admin)(/|\$)
    respond @deny $DENY_MSG
    handle_path /api/v3/* {
$(upstream https://api.github.com api.github.com 'Bearer {$GITHUB_TOKEN}')
    }
    handle /api/graphql {
      rewrite * /graphql
$(upstream https://api.github.com api.github.com 'Bearer {$GITHUB_TOKEN}')
    }
    respond 404
  }
}
:8082 {
  route {
    respond /_lyngvi 200
    @git path_regexp ^/[^/]+/[^/]+/(info/refs|git-upload-pack|git-receive-pack)\$
    handle @git {
$(upstream https://github.com github.com 'Basic {$GITHUB_BASIC}')
    }
    respond "the lyngvi relay passes only git smart-HTTP paths" 403
  }
}
EOF
  fi

  if [ -n "${FORGE_API_TOKEN:-}" ] && [ -n "${FORGE_API_BASE:-}" ] && [ "${FORGE_KIND:-}" != github ]; then
    origin=$(printf '%s' "$FORGE_API_BASE" | sed -E 's#^(https?://[^/]+).*#\1#')
    host=$(printf '%s' "$origin" | sed -E 's#^https?://##')
    cat <<EOF
:8083 {
  route {
    respond /_lyngvi 200
    @deny path_regexp ^/api/v1/(repos/[^/]+/[^/]+/(hooks|keys|push_mirrors|collaborators|actions/secrets|actions/variables)|user/(keys|gpg_keys|applications|hooks|emails)|users/[^/]+/tokens|orgs/[^/]+/(hooks|actions/secrets|members)|admin)(/|\$)
    respond @deny $DENY_MSG
    handle /api/v1/* {
$(upstream "$origin" "$host" 'token {$FORGE_API_TOKEN}')
    }
    respond 404
  }
}
EOF
  fi
  if [ -n "${LYNGVI_ANTHROPIC_API_KEY:-}" ]; then
    cat <<EOF
:8084 {
  route {
    respond /_lyngvi 200
    @api path_regexp ^/v1/(messages|models)(/|\?|\$)
    handle @api {
      reverse_proxy https://api.anthropic.com {
        header_up Host api.anthropic.com
        header_up x-api-key "{\$LYNGVI_ANTHROPIC_API_KEY}"
        header_up -Authorization
        header_up -Cookie
        transport http {
          forward_proxy_url $P
        }
      }
    }
    respond "the lyngvi relay passes only the Anthropic Messages and Models API" 403
  }
}
EOF
  fi
  # No GitHub route: :8081 still answers, so the agent's start-up wait for the relay (which
  # waits on :8081) gets a clear 404 rather than a refused connection.
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    printf ':8081 {\n  respond "no token configured for the lyngvi relay" 404\n}\n'
  fi
} > "$C"

echo "[relay] routes: github=$([ -n "${GITHUB_TOKEN:-}" ] && echo on || echo off) forge=$(grep -q '^:8083' "$C" && echo on || echo off) anthropic=$(grep -q '^:8084' "$C" && echo on || echo off)"
exec caddy run --config "$C" --adapter caddyfile

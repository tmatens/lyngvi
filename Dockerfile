# lyngvi — a coding agent (Claude Code CLI under Remote Control) in a container that
# cannot deploy. Build with `docker compose build` (supplies the `site` context);
# a plain `docker build .` uses site-example/ via the stub stage below.
#
# Site files (operating context, pinned host keys, settings grants, proxy filter
# additions) come from a BuildKit NAMED CONTEXT called `site`. This stub stage is
# the default — the example values shipped in this repo — and an overlay's compose
# `additional_contexts: {site: ./site}` overrides it with real files without a
# Dockerfile of its own. Renovate sees a stage, not a phantom image. docs/OVERLAY.md.
FROM scratch AS site
COPY site-example/ /

FROM node:26-bookworm-slim@sha256:5df79989ed685e09f0a98019db4cebfb22fb9df1a53c0161664a011f7ff6b0f1

# Runtime deps:
#  - git, openssh-client : push over HTTPS (PAT) and SSH (scoped key)
#  - tmux                : human reattach (docker exec); agent runs as PID1
#  - procps              : pgrep, used by the healthcheck
#  - tini                : PID1 reaping (entrypoint spawns ssh-agent/tmux)
#  - ca-certificates     : TLS to the Anthropic relay / GitHub / registries
#  - python3             : the two secret-hygiene hooks (hooks/) are python
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git openssh-client tmux procps tini ca-certificates python3 \
    && rm -rf /var/lib/apt/lists/*

# Pin the Claude Code CLI explicitly (>= v2.1.110 required for Remote Control +
# push notifications). No stock Renovate manager reads an ARG, so the regex
# manager in renovate.json keys off the annotation line below and opens a
# reviewed PR per release (automerge off — the CLI is the agent itself).
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.300
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && npm cache clean --force

# ── Toolchain switches (compose build.args; an overlay flips them) ────────────
# Everything below the CLI is a workload toolchain, not part of the security
# mechanism, so each is gated: the generic image stays small and a site bakes
# only what its repos need. Secret-hygiene tooling (gitleaks) is NOT gated —
# the redact hook depends on it.
ARG WITH_PYTHON=1
ARG WITH_LINTERS=1
ARG WITH_GO=0
ARG WITH_FORGEJO_MCP=0
ARG WITH_GITHUB_MCP=0

# ── Forgejo MCP server (optional forge adapter) ──────────────────────────────
# Typed issue/PR/label tools for a Forgejo/Gitea forge. Built from source (no
# official image), pinned by COMMIT hash — the hash is the supply-chain checksum,
# same trust model as the digest-pinned COPYs below; upgrades are deliberate:
# bump the ARG, re-review the diff. Must stay ABOVE the proxy-config layer:
# build-time npm runs on the unfiltered default bridge; after that layer npm is
# pointed at the proxy sidecar, which does not exist at build time.
# renovate: datasource=git-refs depName=https://codeberg.org/ric_harvey/forgejo-mcp
ARG FORGEJO_MCP_COMMIT=5564cb0aab7148f6ebdf4a4877e50004b3ca2d48
RUN if [ "$WITH_FORGEJO_MCP" = "1" ]; then \
      git clone https://codeberg.org/ric_harvey/forgejo-mcp.git /opt/forgejo-mcp-src \
      && git -C /opt/forgejo-mcp-src checkout -q "${FORGEJO_MCP_COMMIT}" \
      && npm --prefix /opt/forgejo-mcp-src ci --no-audit --no-fund \
      && npm --prefix /opt/forgejo-mcp-src run build \
      && npm --prefix /opt/forgejo-mcp-src prune --omit=dev \
      && mkdir /opt/forgejo-mcp \
      && mv /opt/forgejo-mcp-src/dist /opt/forgejo-mcp-src/node_modules \
            /opt/forgejo-mcp-src/package.json /opt/forgejo-mcp/ \
      && rm -rf /opt/forgejo-mcp-src \
      && npm cache clean --force; \
    fi

# ── Python toolchain (uv) ────────────────────────────────────────────────────
# uv = single-binary Python + package manager; copied from the pinned distroless
# image (Renovate digest-pins the --from tag, like the node base). The real
# binaries live OFF PATH at /usr/local/lib/uv; PATH-shadowing wrappers (below)
# inject the egress proxy ONLY for uv — so a proxy misconfig fails package
# installs WITHOUT ever touching Remote Control / git egress (fail-safe, not
# fail-open). The binary copy is unconditional (tiny); the interpreter and tools
# are gated.
COPY --from=ghcr.io/astral-sh/uv:0.13.1@sha256:4a1f3666816dafadd20ceb71eac9a7d56d7ef30279f7d64048519ab901ada336 /uv /uvx /usr/local/lib/uv/
ENV UV_PYTHON_INSTALL_DIR=/opt/uv/python \
    UV_TOOL_DIR=/opt/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin
# Bake CPython + the cross-cutting dev tools so lint/test work with ZERO runtime
# PyPI. The build runs on the default bridge — NOT egress-filtered — so it calls
# the real uv binary directly (the wrappers don't exist yet).
RUN if [ "$WITH_PYTHON" = "1" ]; then \
      /usr/local/lib/uv/uv python install 3.13 \
      && /usr/local/lib/uv/uv tool install ruff \
      && /usr/local/lib/uv/uv tool install pytest \
      && /usr/local/lib/uv/uv tool install mypy \
      && /usr/local/lib/uv/uv tool install pip-audit \
      && chmod -R a+rX /opt/uv \
      # Expose the uv-managed interpreter as bare `python3`/`python` on PATH for
      # shebangs and Makefiles. The hooks use the distro python3 (apt, above) —
      # this symlink shadows it on PATH but the hooks are run by absolute path.
      && ln -sf "$(/usr/local/lib/uv/uv python find 3.13)" /usr/local/bin/python3 \
      && ln -sf python3 /usr/local/bin/python; \
    fi

# Name the proxy (sidecar `lyngvi-proxy`) for the package tools explicitly.
# Every client already reads HTTPS_PROXY from the compose environment, and the
# network layout makes the proxy the only way out (DESIGN.md §4.2), so these
# keep installs working when a tool runs with a cleared environment: pip.conf
# covers a direct `python -m pip`, the wrappers cover uv's own index traffic,
# and the global npmrc (npm's $PREFIX/etc config, read by npm/npx only) covers
# runtime npm installs. A proxy fault breaks everything, Remote Control and git
# included; the entrypoint waits for the proxy and doctor.sh reports it.
RUN printf '[global]\nproxy = http://lyngvi-proxy:3128\n' > /etc/pip.conf \
    && printf 'proxy=http://lyngvi-proxy:3128\nhttps-proxy=http://lyngvi-proxy:3128\n' \
       > /usr/local/etc/npmrc \
    && for b in uv uvx; do \
         { echo '#!/bin/sh'; \
           echo 'export HTTPS_PROXY=http://lyngvi-proxy:3128 HTTP_PROXY=http://lyngvi-proxy:3128'; \
           echo "exec /usr/local/lib/uv/$b \"\$@\""; \
         } > /usr/local/bin/$b \
         && chmod 0755 /usr/local/bin/$b; \
       done \
    # pip-audit is the one baked uv *tool* that needs the network (PyPI advisory
    # API). `uv tool install` symlinked it onto PATH, and a symlink runs the real
    # binary directly — bypassing the uv wrappers. Give it the same per-binary
    # wrapper so it keeps the proxy under a cleared environment. pip-audit execs a resolver
    # shim from its temp dir and /tmp is noexec: the image's TMPDIR (workspace volume)
    # covers that, and the fallback covers a cleared environment.
    && if [ -e /usr/local/bin/pip-audit ]; then \
         rm /usr/local/bin/pip-audit \
         && { echo '#!/bin/sh'; \
              echo 'export HTTPS_PROXY=http://lyngvi-proxy:3128 HTTP_PROXY=http://lyngvi-proxy:3128'; \
              echo "TMPDIR=\${TMPDIR:-\$HOME/.cache/pip-audit}"; \
              echo "export TMPDIR"; \
              echo "mkdir -p \"\$TMPDIR\""; \
              echo "exec /opt/uv/tools/pip-audit/bin/pip-audit \"\$@\""; \
            } > /usr/local/bin/pip-audit \
         && chmod 0755 /usr/local/bin/pip-audit; \
       fi

# ── Go toolchain (gated) ─────────────────────────────────────────────────────
# Copied from the official images via a bind mount (COPY --from cannot be made
# conditional). `from=` is the FIRST mount option on purpose: Renovate's
# dockerfile manager tracks images in RUN --mount only in that position. Keep
# the golang major.minor in lockstep with your Go repos' go.mod `go` directive
# (renovate.json pins major.minor; the digest/patch stays fresh). GOTOOLCHAIN=local:
# never auto-download a toolchain (default-deny egress would block it — fail loud).
# golangci-lint must be BUILT WITH a Go >= the code's go.mod directive to parse it.
# One mount per RUN: Renovate's dockerfile manager tracks only the FIRST `from=` of
# an instruction (verified with its local extract), so a second mount on the same
# RUN would be an untracked pin.
RUN --mount=from=golang:1.26-bookworm@sha256:5de7c99eb78ca5e515a4c340235d0955ec5964a5071c492c15503d7c267da473,type=bind,source=/usr/local/go,target=/mnt/go \
    if [ "$WITH_GO" = "1" ]; then cp -a /mnt/go /usr/local/go; fi
RUN --mount=from=golangci/golangci-lint:v2.12.2@sha256:5cceeef04e53efe1470638d4b4b4f5ceefd574955ab3941b2d9a68a8c9ad5240,type=bind,source=/usr/bin/golangci-lint,target=/mnt/golangci-lint \
    if [ "$WITH_GO" = "1" ]; then cp /mnt/golangci-lint /usr/local/bin/golangci-lint; fi
# ── GitHub MCP server (gated, optional GitHub adapter) ──────────────────────
# GitHub's official server: a static Go binary copied from its image, pinned by
# digest like the toolchains above. It reaches only api.github.com, which is in the
# base allowlist. agent/github-mcp holds lyngvi's default tool selection.
RUN --mount=from=ghcr.io/github/github-mcp-server:v2.0.3@sha256:250bc6ce70788207608ef74cef4397230ff2e8481218da74d6093e4bd9101132,type=bind,source=/server/github-mcp-server,target=/mnt/github-mcp-server \
    if [ "$WITH_GITHUB_MCP" = "1" ]; then cp /mnt/github-mcp-server /usr/local/bin/github-mcp-server; fi
ENV PATH=/usr/local/go/bin:$PATH \
    GOTOOLCHAIN=local \
    CGO_ENABLED=0
# Every build cache under ~/.cache, which is a volume: the root filesystem is read-only
# and the rest of the home directory is a tmpfs rebuilt at each start, so a cache kept
# anywhere else would be lost on every restart. uv, pip and Go's build cache default
# there already; GOPATH (module cache, `go install` binaries) and npm's cache are moved.
ENV GOPATH=/home/claude/.cache/go \
    npm_config_cache=/home/claude/.cache/npm

# ── CI-parity linters (gated): actionlint / shellcheck / hadolint ────────────
# Single STATIC binaries from their official images, so the agent runs the same
# lint gates locally that CI enforces, with ZERO runtime egress. actionlint
# shells out to shellcheck for `run:` blocks.
RUN --mount=from=rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667,type=bind,source=/usr/local/bin/actionlint,target=/mnt/actionlint \
    if [ "$WITH_LINTERS" = "1" ]; then cp /mnt/actionlint /usr/local/bin/actionlint; fi
RUN --mount=from=koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d,type=bind,source=/bin/shellcheck,target=/mnt/shellcheck \
    if [ "$WITH_LINTERS" = "1" ]; then cp /mnt/shellcheck /usr/local/bin/shellcheck; fi
RUN --mount=from=hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d,type=bind,source=/bin/hadolint,target=/mnt/hadolint \
    if [ "$WITH_LINTERS" = "1" ]; then cp /mnt/hadolint /usr/local/bin/hadolint; fi

# ── gitleaks: secret scanner behind the redact-tool-output hook (NOT gated) ──
# hooks/redact-tool-output.sh (PostToolUse, wired by entrypoint.sh) runs gitleaks
# over every tool result and replaces secrets with <REDACTED:rule> before the
# agent sees them. Without it the hook fails open and warns once per session.
COPY --from=ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f /usr/bin/gitleaks /usr/local/bin/gitleaks

# Non-root user; own the volume mountpoints so named volumes inherit ownership.
RUN useradd --create-home --uid 10001 --shell /bin/bash claude \
    && mkdir -p /home/claude/workspace /home/claude/.claude /home/claude/.cache \
    && chown -R claude:claude /home/claude

COPY --chmod=0755 entrypoint.sh healthcheck.sh /usr/local/bin/
# Forge MCP launchers (env mapping only; harmless when the server isn't baked).
COPY --chmod=0755 agent/forgejo-mcp /usr/local/bin/forgejo-mcp
COPY --chmod=0755 agent/github-mcp /usr/local/bin/github-mcp
# Agent operating context + status line + hooks — the entrypoint installs these
# into ~/.claude at every start, so the repo is the source of truth.
COPY agent/CLAUDE.md /etc/lyngvi/CLAUDE.md
COPY agent/statusline-context.mjs /etc/lyngvi/statusline-context.mjs
# Marker → human push (ntfy/Slack/Discord/JSON webhook or a site command), called by
# the entrypoint's mark(); `notify --test` on PATH proves the path at bootstrap.
COPY agent/notify.mjs /etc/lyngvi/notify.mjs
RUN printf '#!/bin/sh\nexec node /etc/lyngvi/notify.mjs "$@"\n' > /usr/local/bin/notify \
    && chmod 0755 /usr/local/bin/notify
COPY --chmod=0755 hooks/redact-tool-output.sh hooks/block-secret-dumps.sh hooks/skills-summary.sh hooks/config-change.sh /etc/lyngvi/hooks/
COPY --chmod=0755 agent/git-hooks/ /etc/lyngvi/git-hooks/
COPY hooks/redact-tool-output.gitleaks.toml /etc/lyngvi/hooks/
# Site files from the named context (example values by default).
COPY --from=site / /etc/lyngvi/site/
# Claude Code MANAGED settings: the hooks, the hook/MCP/bypass policy and the grants,
# with the site's settings.json merged in, written root-owned at build. The CLI gives
# managed settings precedence over anything in ~/.claude or the workspace, and the
# agent's uid cannot write this file, so "image-baked" is literal (DESIGN.md §4.5).
COPY agent/managed-settings.mjs /etc/lyngvi/managed-settings.mjs
RUN install -d -m 0755 /etc/claude-code \
    && node /etc/lyngvi/managed-settings.mjs /etc/lyngvi/site/settings.json \
       > /etc/claude-code/managed-settings.json \
    && chmod 0644 /etc/claude-code/managed-settings.json
# GitHub Actions raw-log fetcher, fronted by a wrapper on PATH so the agent calls
# it by name from any cwd. The wrapper (rather than a symlink) keeps the `.mjs`
# suffix on node's argv, which marks the file ESM explicitly.
COPY scripts/gh-actions-log.mjs /etc/lyngvi/gh-actions-log.mjs
# ssh ProxyCommand through the egress proxy (entrypoint writes the Host * block).
COPY agent/connect.mjs /etc/lyngvi/connect.mjs
COPY agent/loopback.mjs /etc/lyngvi/loopback.mjs
RUN printf '#!/bin/sh\nexec node /etc/lyngvi/gh-actions-log.mjs "$@"\n' \
      > /usr/local/bin/gh-actions-log \
    && chmod 0755 /usr/local/bin/gh-actions-log

USER 10001
WORKDIR /home/claude/workspace

# Belt-and-suspenders: these env vars DISABLE Remote Control eligibility, so make
# sure nothing sets them. (DESIGN.md, Remote Control requirements.)
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="" \
    DISABLE_TELEMETRY=""
# The CLI version is pinned by this image (ARG CLAUDE_CODE_VERSION, moved by a reviewed
# Renovate PR), so the CLI must not update itself: an in-place update would diverge from
# the pin until the next recreate, and its update check is otherwise refused by the
# proxy on every start. Only the updater is off — the switches above stay unset.
ENV DISABLE_AUTOUPDATER=1
# Temp files: /tmp and the home tmpfs are both noexec, and the home tmpfs is 64 MB, so
# anything that execs out of its temp dir (pytest fixtures, venv console scripts) or
# writes a lot there fails on either. TMPDIR points at the workspace volume instead,
# outside every checkout (tests that need a path outside the project break inside one);
# the entrypoint empties and recreates it at every start. The CLI's own temp files (its
# scratchpad, task output) stay on the per-run /tmp tmpfs: CLAUDE_CODE_TMPDIR keeps them
# off the persistent volume and where the secret-dump hook's scratchpad rule expects them.
ENV TMPDIR=/home/claude/workspace/.tmp \
    CLAUDE_CODE_TMPDIR=/tmp
# The key sidecar's ssh-agent socket and the token relay's routes (DESIGN.md §4.3): fixed
# names, set here rather than exported by the entrypoint so a `docker exec` session sees
# them exactly as Remote Control sessions do. The entrypoint probes which routes exist.
ENV SSH_AUTH_SOCK=/run/lyngvi-keys/agent.sock \
    LYNGVI_RELAY_GITHUB=http://lyngvi-relay:8081 \
    LYNGVI_RELAY_GITHUB_LOCAL=http://localhost:18081 \
    LYNGVI_RELAY_GIT=http://lyngvi-relay:8082 \
    LYNGVI_RELAY_FORGE=http://lyngvi-relay:8083 \
    LYNGVI_RELAY_ANTHROPIC=http://lyngvi-relay:8084

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

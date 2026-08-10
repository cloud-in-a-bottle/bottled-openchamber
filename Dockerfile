# OpenChamber (web UI for the OpenCode agent), packaged for OpenHost.
#
# Topology:
#   browser
#     -> OpenHost router (subdomain openchamber.<zone>; verifies owner
#        zone_auth, stamps X-OpenHost-Is-Owner: true, blocks anon)
#     -> container :8080          (nginx front proxy, WS/SSE-aware)
#     -> 127.0.0.1:3000           (OpenChamber bun server + managed
#                                  OpenCode CLI child)
#
# OpenChamber has no published server image, so we reproduce its
# multi-stage build (mirroring the upstream Dockerfile) from a pinned
# release tag, then add nginx + our supervisor. The build clones the
# repo at $OPENCHAMBER_REF, `bun install`s, and `bun run build:web`.
#
# Auth: OpenChamber's own UI auth (login form + oc_ui_session cookie) is
# left DISABLED. The server binds 127.0.0.1 only, so nothing outside the
# container reaches it directly; all access flows through nginx, which
# is gated by the OpenHost router (no public_paths) AND an in-container
# X-OpenHost-Is-Owner check. This gives the owner a password-free SSO
# experience while keeping the (code-executing) app strictly owner-only.

# ---------------------------------------------------------------------------
# Build stage — mirror upstream's bun build from a pinned tag.
# ---------------------------------------------------------------------------
FROM oven/bun:1.3.14 AS builder
WORKDIR /src

# Pin to an OpenChamber release tag for reproducible builds.
ARG OPENCHAMBER_REF=v1.18.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${OPENCHAMBER_REF}" \
        https://github.com/openchamber/openchamber.git . \
 && git rev-parse HEAD

# Install workspace deps and build the web server + UI bundle.
RUN bun install --frozen-lockfile --ignore-scripts
RUN bun run build:web

# ---------------------------------------------------------------------------
# Runtime stage.
# ---------------------------------------------------------------------------
FROM oven/bun:1.3.14 AS runtime
WORKDIR /home/openchamber

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_ENV=production

# Runtime OS deps:
#   nginx                 — WS/SSE-aware front proxy on :8080
#   gosu                  — drop privileges to the openchamber user
#   tini                  — PID 1 reaper / signal forwarder
#   jq, curl, ca-certs    — secrets fetch + JSON parsing + TLS roots
#   git, openssh-client   — VCS operations the agent performs
#   bash, less, python3   — shell + common agent tooling
#   nodejs, npm           — required to `npm i -g opencode-ai`
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        nginx \
        gosu \
        tini \
        jq \
        curl \
        ca-certificates \
        bash \
        less \
        git \
        openssh-client \
        python3 \
        nodejs \
        npm \
 && rm -rf /var/lib/apt/lists/*

# Replace the base image's 'bun' user (uid 1000) with 'openchamber'
# (matching upstream) so bind-mounted volumes owned 1000:1000 work.
RUN userdel bun 2>/dev/null || true \
 && groupadd -g 1000 openchamber \
 && useradd -u 1000 -g 1000 -m -s /bin/bash openchamber \
 && chown -R openchamber:openchamber /home/openchamber

# Install the OpenCode CLI globally (the agent OpenChamber drives),
# matching upstream. Installed as the openchamber user into a user
# npm prefix so no root-owned files end up on PATH.
ENV NPM_CONFIG_PREFIX=/home/openchamber/.npm-global
ENV PATH=/home/openchamber/.npm-global/bin:${PATH}
USER openchamber
RUN npm config set prefix /home/openchamber/.npm-global \
 && mkdir -p /home/openchamber/.npm-global \
             /home/openchamber/.local \
             /home/openchamber/.config \
             /home/openchamber/.ssh \
 && npm install -g opencode-ai \
 && opencode --version
USER root

# Copy the built OpenChamber server + its node_modules from the builder.
COPY --from=builder --chown=openchamber:openchamber /src/node_modules ./node_modules
COPY --from=builder --chown=openchamber:openchamber /src/packages/web/node_modules ./packages/web/node_modules
COPY --from=builder --chown=openchamber:openchamber /src/package.json ./package.json
COPY --from=builder --chown=openchamber:openchamber /src/packages/web/package.json ./packages/web/package.json
COPY --from=builder --chown=openchamber:openchamber /src/packages/web/bin ./packages/web/bin
COPY --from=builder --chown=openchamber:openchamber /src/packages/web/server ./packages/web/server
COPY --from=builder --chown=openchamber:openchamber /src/packages/web/dist ./packages/web/dist

# App files (our supervisor + nginx).
COPY start.sh          /opt/openhost-openchamber/start.sh
COPY nginx.conf.tmpl   /opt/openhost-openchamber/nginx.conf.tmpl
COPY proxy_common.conf /opt/openhost-openchamber/proxy_common.conf
RUN chmod 0755 /opt/openhost-openchamber/start.sh

# OpenHost-routed port (nginx front proxy). OpenChamber's own port
# (3000) stays loopback-only.
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/openhost-openchamber/start.sh"]

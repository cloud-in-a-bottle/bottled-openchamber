#!/bin/bash
# Boot OpenChamber + nginx front proxy for OpenHost.
#
# Topology:
#   browser
#     -> OpenHost router (subdomain openchamber.<zone>; verifies owner
#        zone_auth, stamps X-OpenHost-Is-Owner: true, blocks anon)
#     -> container :8080          (nginx, WS/SSE-aware)
#     -> 127.0.0.1:3000           (OpenChamber bun server + managed
#                                  OpenCode CLI child)
#
# Auth model (Pattern E — no in-app auth, router + nginx gate):
#   OpenChamber's own UI auth (login form + oc_ui_session cookie) is
#   intentionally left DISABLED — we start the server bound to 127.0.0.1
#   with no --ui-password. Because it binds loopback only, nothing
#   outside the container can reach it directly. All external access
#   flows through nginx, which is (a) only reachable via the OpenHost
#   router, which blocks anonymous traffic since there are no
#   public_paths, and (b) additionally gated on X-OpenHost-Is-Owner:
#   true. Two independent gates guard what is effectively remote shell
#   access, and the owner gets a password-free SSO experience.
#
#   NOTE: OpenChamber refuses to bind a NON-loopback host without a
#   password (its assertAuthenticatedNetworkExposure guard). We bind
#   127.0.0.1, so that guard is satisfied and we never need the
#   OPENCHAMBER_ALLOW_UNAUTHENTICATED_LAN escape hatch.
#
# Credential handling:
#   Secrets are fetched at boot from the OpenHost secrets service via the
#   router service proxy (using OPENHOST_APP_TOKEN) and exported into the
#   process environment. The OpenChamber server passes its full
#   environment to the managed OpenCode child, so the agent picks them up
#   non-interactively. We never write them to a file under app_data
#   ourselves. (OpenChamber / OpenCode may still cache provider auth in
#   opencode's auth.json under app_data if the owner edits providers in
#   the UI — that is the app's own behaviour and matches how OpenCode
#   natively stores auth.)
#
#   ANTHROPIC_API_KEY  required for the agent to run at all.
#   GITHUB_TOKEN       optional; authenticates git and gh for the agent.
#
#   Both are fetched in one call and each is independently optional: a
#   missing key degrades a capability but never blocks boot.

set -euo pipefail

APP_USER="openchamber"
APP_UID="$(id -u "$APP_USER")"
APP_GID="$(id -g "$APP_USER")"
BASE_HOME="/home/$APP_USER"          # where .npm-global (opencode bin) lives

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/openchamber}"

# We run the server with HOME pointed at a persistent directory so that
# everything OpenChamber and the bundled OpenCode CLI derive from
# os.homedir() — ~/.config/openchamber, ~/.config/opencode,
# ~/.local/share/opencode (auth.json + sessions), ~/.local/state/opencode
# — lands under app_data and survives restarts. (OpenChamber hardcodes
# these from os.homedir(), so relocating HOME is the reliable lever.)
PERSIST_HOME="$PERSIST/home"
OC_DATA_DIR="$PERSIST_HOME/.config/openchamber"  # OPENCHAMBER_DATA_DIR
WORKSPACES="$PERSIST/workspaces"                 # agent project working dir

UPSTREAM_PORT=3000

# ---------------------------------------------------------------------------
# Clean up any ad-hoc credential files a prior iteration might have
# dropped (defence in depth; we do not write these).
# ---------------------------------------------------------------------------
rm -f "$PERSIST/anthropic-api-key" "$PERSIST/api-key.txt" 2>/dev/null || true

mkdir -p "$OC_DATA_DIR" \
         "$PERSIST_HOME/.config/opencode" \
         "$PERSIST_HOME/.local/share/opencode" \
         "$PERSIST_HOME/.local/state/opencode" \
         "$PERSIST_HOME/.ssh" \
         "$WORKSPACES"

# The bundled OpenCode binary lives under the image's home
# ($BASE_HOME/.npm-global). Since we relocate HOME, seed the persistent
# home with an ssh dir and make sure the npm-global bin stays reachable
# via an absolute PATH entry (set below), not via HOME.

# The bind-mounted dirs are root-owned on first boot; hand them to the
# openchamber user so the server + agent tool calls can write.
chown -R "$APP_UID:$APP_GID" "$PERSIST" 2>/dev/null || true

# nginx scratch dirs (all under /tmp per nginx.conf.tmpl).
mkdir -p /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi \
         /tmp/nginx-uwsgi /tmp/nginx-scgi

# ---------------------------------------------------------------------------
# Fetch secrets from the OpenHost secrets service.
#
# All keys are requested in a single call. The response object is held in
# a shell variable (never a file) and consumed by load_secret below.
# ---------------------------------------------------------------------------
SECRET_KEYS=(ANTHROPIC_API_KEY GITHUB_TOKEN)

fetch_secrets() {
    local router="${OPENHOST_ROUTER_URL:-}"
    local apptok="${OPENHOST_APP_TOKEN:-}"
    if [ -z "$router" ] || [ -z "$apptok" ]; then
        echo "[start.sh] secrets: OPENHOST_ROUTER_URL / OPENHOST_APP_TOKEN unset; skipping fetch" >&2
        return 1
    fi
    local body
    body="$(printf '%s\n' "${SECRET_KEYS[@]}" | jq -R . | jq -s '{keys: .}')" || {
        echo "[start.sh] secrets: could not build request body" >&2
        return 1
    }
    local resp
    resp="$(curl -fsS --max-time 15 \
        -H "Authorization: Bearer $apptok" \
        -H "Content-Type: application/json" \
        -X POST "$router/api/services/v2/call/secrets/get" \
        -d "$body" 2>/dev/null)" || {
        echo "[start.sh] secrets: fetch call failed" >&2
        return 1
    }
    printf '%s' "$resp" | jq -c '.secrets // {}' 2>/dev/null || {
        echo "[start.sh] secrets: malformed response" >&2
        return 1
    }
}

# Export one secret from the fetched payload, falling back to an
# already-set environment variable. Returns non-zero when the value is
# available from neither source, leaving the variable untouched so
# consumers see it as genuinely unset rather than empty.
load_secret() {
    local var="$1" label="$2" value=""
    if [ -n "${SECRETS_JSON:-}" ]; then
        value="$(printf '%s' "$SECRETS_JSON" | jq -r --arg k "$var" '.[$k] // empty' 2>/dev/null)" || value=""
    fi
    if [ -n "$value" ]; then
        export "$var=$value"
        echo "[start.sh] $label loaded from secrets service"
        return 0
    fi
    if [ -n "${!var:-}" ]; then
        echo "[start.sh] $label taken from environment (not in secrets service)"
        return 0
    fi
    return 1
}

SECRETS_JSON="$(fetch_secrets || true)"

load_secret ANTHROPIC_API_KEY "Anthropic API key" || \
    echo "[start.sh] WARNING: no Anthropic API key available; OpenChamber will start but the agent cannot run until a key is configured (store ANTHROPIC_API_KEY in the secrets app, then reload this app)"

load_secret GITHUB_TOKEN "GitHub token" || \
    echo "[start.sh] no GitHub token configured; git and gh will be unauthenticated (store GITHUB_TOKEN in the secrets app and reload this app to enable)"

unset SECRETS_JSON

# ---------------------------------------------------------------------------
# Template nginx.conf with the upstream port.
# ---------------------------------------------------------------------------
NGINX_CONF="/run/openhost-openchamber-nginx.conf"
UPSTREAM_PORT="$UPSTREAM_PORT" python3 - "$NGINX_CONF" <<'PY'
import os
import sys

dest = sys.argv[1]
with open("/opt/openhost-openchamber/nginx.conf.tmpl", encoding="utf-8") as fh:
    conf = fh.read()
conf = conf.replace("__UPSTREAM_PORT__", os.environ["UPSTREAM_PORT"])
with open(dest, "w", encoding="utf-8") as fh:
    fh.write(conf)
PY

# ---------------------------------------------------------------------------
# Launch nginx first so /_healthz answers 200 within the cold-start
# grace window.
# ---------------------------------------------------------------------------
echo "[start.sh] Starting nginx front proxy on :8080"
nginx -c "$NGINX_CONF" -g 'daemon off;' &
NGINX_PID=$!

# ---------------------------------------------------------------------------
# Launch the OpenChamber server as the openchamber user, loopback-bound,
# in the foreground (default 'serve' daemonises; --foreground keeps it
# inline so this supervisor can manage it).
#
# 'env' here overrides specific variables; it does NOT start from an
# empty environment, so anything exported above (GITHUB_TOKEN, the
# OPENHOST_* vars) is inherited by the server and in turn by the managed
# OpenCode child and every agent shell it spawns. GITHUB_TOKEN is
# deliberately NOT listed below: passing it explicitly would turn the
# unconfigured case into an empty-string value, which gh treats as a
# broken credential rather than as absent.
# ---------------------------------------------------------------------------
echo "[start.sh] Starting OpenChamber on 127.0.0.1:$UPSTREAM_PORT (no UI password; SSO-gated by OpenHost)"

gosu "$APP_USER" env \
    HOME="$PERSIST_HOME" \
    PATH="$BASE_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
    NODE_ENV=production \
    OPENCHAMBER_HOST="127.0.0.1" \
    OPENCHAMBER_DATA_DIR="$OC_DATA_DIR" \
    OPENCODE_CONFIG_DIR="$PERSIST_HOME/.config/opencode" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    bash -c "cd '$BASE_HOME' && exec bun packages/web/bin/cli.js serve --foreground --host 127.0.0.1 --port '$UPSTREAM_PORT'" \
    &
OC_PID=$!

# ---------------------------------------------------------------------------
# Supervision: if either process dies, tear the other down and exit.
# ---------------------------------------------------------------------------
trap 'kill -TERM "$NGINX_PID" "$OC_PID" 2>/dev/null; wait' TERM INT

set +e
wait -n "$NGINX_PID" "$OC_PID"
EXIT_CODE=$?
set -e

echo "[start.sh] Child exited (code=$EXIT_CODE); shutting down"
kill -TERM "$NGINX_PID" "$OC_PID" 2>/dev/null || true
wait || true
exit "$EXIT_CODE"

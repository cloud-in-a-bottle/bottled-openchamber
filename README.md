# openhost-openchamber

[OpenChamber](https://openchamber.dev) — a web workspace for running,
supervising, and reviewing AI coding work with the
[OpenCode](https://opencode.ai) agent (session goals, multi-run, diff
walkthroughs, GitHub workflows, a built-in terminal) — packaged as a
self-hosted web app for
[OpenHost](https://github.com/imbue-openhost/openhost).

The OpenHost zone owner opens `https://openchamber.<zone>/` and lands in
the OpenChamber workspace with no login screen — OpenHost SSO carries
them in. The bundled OpenCode agent talks to Anthropic Claude using an
API key pulled from the OpenHost secrets service at boot.

## Architecture

```
browser
  -> OpenHost router  (openchamber.<zone>; verifies owner zone_auth,
                       stamps X-OpenHost-Is-Owner: true, blocks anon)
  -> container :8080  (nginx front proxy — WebSocket + SSE aware)
  -> 127.0.0.1:3000   (OpenChamber bun server, which spawns and manages
                       the OpenCode CLI as a child process)
```

The image is built from OpenChamber's own source at a pinned release
tag (`v1.18.2`) via its `bun run build:web`, then layered with nginx +
a supervisor. The OpenCode CLI is installed globally (`opencode-ai`),
exactly as upstream's Docker image does.

## Auth model (Pattern E — no in-app auth, router + nginx gate)

OpenChamber's own browser auth is a login form that sets an
`oc_ui_session` JWT cookie; it has **no header/OIDC SSO hook**. Rather
than double-prompt the owner, this package runs the server **bound to
`127.0.0.1` with no `--ui-password`**, so OpenChamber's auth is
disabled and nothing outside the container can reach it directly. Two
independent gates protect it instead:

1. **The OpenHost router.** No `public_paths`, so it rejects every
   anonymous request and only forwards the authenticated zone owner.
2. **nginx, in-container.** Denies any request lacking the
   router-stamped `X-OpenHost-Is-Owner: true` header (set by the router
   and stripped from client input, so unspoofable).

OpenChamber refuses to bind a non-loopback host without a password; we
bind loopback, so that guard is satisfied and we never touch the
`OPENCHAMBER_ALLOW_UNAUTHENTICATED_LAN` escape hatch.

Every session drives the OpenCode agent, which runs arbitrary shell
commands, edits files, and exposes an interactive terminal **inside
this container**. That's the point of the app, but it means the app is
strictly owner-only — there is deliberately no public mode.

## Credential handling

Credentials are provisioned through the OpenHost **secrets service**,
never baked into the image:

| Secret | Required | Purpose |
|--------|----------|---------|
| `ANTHROPIC_API_KEY` | yes | The model credential. Without it the UI loads but the agent cannot run. |
| `GITHUB_TOKEN` | no | Authenticates `git` and `gh` for the agent — private repos, pushing branches, opening PRs. Without it git falls back to unauthenticated access to public repos. |

1. The owner stores the keys in the secrets app.
2. This app declares it consumes them (`[[services.v2.consumes]]` with
   `grants = [{ key = "ANTHROPIC_API_KEY" }, { key = "GITHUB_TOKEN" }]`).
3. At boot, `start.sh` fetches them in a single call via the router
   service proxy
   (`POST $OPENHOST_ROUTER_URL/api/services/v2/call/secrets/get`) using
   the app's `OPENHOST_APP_TOKEN`, and exports each one it receives into
   the process environment. OpenChamber passes its whole environment to
   the managed OpenCode child, so every agent session and its shell
   commands inherit them non-interactively.

Each key is independently optional at boot. If the secrets fetch fails,
or a key is absent from the response, the app falls back to a matching
env var if one is set, and otherwise leaves the variable **unset** —
deliberately not empty, since an empty `GITHUB_TOKEN` reads to `gh` as a
broken credential rather than as absent. A missing key degrades one
capability; it never blocks boot.

> **Scope the GitHub token.** Every agent session inherits it, and agents
> routinely read untrusted content (repositories, web pages, issue text).
> A prompt injection would have that token in reach. Use a fine-grained
> token limited to the repositories and permissions actually needed
> rather than a broadly-scoped classic token.

Note: if the owner edits providers in OpenChamber's Settings UI,
OpenChamber/OpenCode may cache provider auth in OpenCode's `auth.json`
under `app_data` — that is the app's own native behaviour. `app_data`
is only visible to apps the owner explicitly grants `access_all_data`.

## Persistent state

`start.sh` points `HOME` at a persistent directory under
`/data/app_data/openchamber/home/`, so everything OpenChamber and
OpenCode derive from `os.homedir()` persists:

- `~/.config/openchamber/` — OpenChamber settings, tokens, pairing
  state, logs, JWT secret (`OPENCHAMBER_DATA_DIR`).
- `~/.config/opencode/` — `opencode.json`.
- `~/.local/share/opencode/` — OpenCode `auth.json` + sessions.
- `~/.local/state/opencode/` — OpenCode state.
- `workspaces/` — the agent's project working directory.

## Tunnels / Private Relay

Deliberately **not** configured — no `OPENCHAMBER_TUNNEL_*` env vars are
set, so the server makes no outbound relay/tunnel connections. Remote
access is provided entirely by OpenHost's own routing + SSO.

## Cold start

The bun server + managed OpenCode child take a little time to come up.
nginx serves `/_healthz` (200) immediately and turns any upstream 5xx on
`/` into a friendly "starting…" placeholder so the OpenHost readiness
probe doesn't flag the app as failed during that window.

## Deploying

```
oh app deploy https://github.com/imbue-openhost/openhost-openchamber --name openchamber --grant-permissions-v2 --wait
```

Make sure `ANTHROPIC_API_KEY` is stored in the secrets app and that this
app is granted the `{ key = "ANTHROPIC_API_KEY" }` permission at install
time. Store `GITHUB_TOKEN` alongside it if the agent should be able to
use `git` and `gh` authenticated; it is optional and can be added later
(store the secret, then reload the app to pick it up).

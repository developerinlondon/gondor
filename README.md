# gondor

A host-ops application composed from
[`assay-sysops`](https://github.com/developerinlondon/assay) (the `libs/sysops`
library shipped alongside the assay binary) with FCAR-specific branding,
services, and pages. Runs as a Lua app on top of `assay run` with an
`assay-engine` sidecar for workflow + vault.

## What's in here

```
gondor/
├── brand/                            # whitelabel pack — overrides sysops defaults
│   ├── brand.json                    # name, subtitle, accent_hex, favicon
│   ├── brand.css                     # CSS overrides (loaded last by layout.html)
│   └── img/favicon.svg
├── deploy/
│   ├── env.example                   # secrets (admin keys, GITHUB_TOKEN)
│   ├── engine.toml.example           # assay-engine sidecar config
│   ├── gondor-engine.service.example # systemd unit for the engine sidecar
│   └── gondor.service.example        # systemd unit (User=gondor, sandboxed)
├── pages/skip_trace.lua              # /skip-trace runs page + HTMX fragments
├── services/
│   ├── audit.lua                     # flat-file audit log
│   ├── brand.lua                     # brand-pack reader
│   ├── engine_client.lua             # HTTP wrapper to assay-engine
│   ├── jobs.lua                      # in-memory job tracker
│   ├── secret_store.lua              # secrets accessor (engine vault → rustic → file)
│   ├── state.lua                     # host + container snapshot
│   ├── tracer.lua                    # deterministic mock skip-trace
│   └── workflows/                    # workflow client + worker + handlers
│       ├── engine.lua                #   single integration boundary
│       ├── client.lua                #   list_active / list_recent / start
│       ├── steps.lua                 #   pipeline_state schema helper
│       ├── history.lua               #   recent-runs in-memory cache
│       ├── registry.lua              #   worker entrypoint (listens on queue)
│       └── definitions/skip_trace.lua  # fcar.skip-trace handler + activities
├── templates/
│   ├── skip_trace.html               # page shell (active + recent sections)
│   ├── skip_trace_active.html        # active-runs cards (HTMX fragment)
│   ├── skip_trace_runs.html          # recent-runs table (HTMX fragment)
│   └── skip_trace_new.html           # new-run modal (HTMX fragment)
├── static/
│   ├── app.js                        # SSE bridge + modal helpers
│   └── css/pipeline.css              # pipeline / step-ladder / runs-table CSS
├── scripts/
│   └── main.lua                      # composition entry point + embedded worker
├── tests-lua/
│   ├── smoke.test.lua                # boots scripts/main.lua + curls routes
│   └── dev-run.sh                    # convenience launcher for local dev
├── Manifest.lua                      # pins sysops 0.1.3 for `assay install`
└── VERSION                           # gondor's own semver pin
```

## Why no plugin loader

Older fcar/gondor (now archived) discovered features via `plugin.toml` files
inside `plugins/<name>/`. That layer existed because the old knowhere binary
couldn't be modified by operators. `gondor` is the binary now — `scripts/main.lua`
is the composition root, so plugins are just regular pages/services in the
repo and get registered directly on the routes table. Sysops's
`extra_sidebar_links` mount opt covers the sidebar-affordance case without any
plugin lifecycle.

## Prerequisites

Tested on Ubuntu 24.04. The host needs:

- `git`, `curl`, `ca-certificates`, `rsync` — `sudo apt install`-able.
- A Rust toolchain (`cargo`) if building `assay` + `assay-engine` from source.
  `mise` works for the operator account; root install via `rustup` is fine too.
- `mise` for the `gondor` system user — used by `assay install` to resolve the
  pinned runtime via `mise install`.

`assay` and `assay-engine` are not on `apt`. Either build from
[`developerinlondon/assay`](https://github.com/developerinlondon/assay) and
`install` the binaries to `/usr/local/bin`, or pull them from a tagged release
once the assay release pipeline produces tarballs.

## Run locally

```bash
# 1) Build assay locally (one-time)
cd ../assay && cargo build --release --bin assay

# 2) Boot gondor pointing at the local sysops checkout
cd ../gondor
ASSAY_ROOT=$(realpath ../assay) ./tests-lua/dev-run.sh

# Default port 18787; override via PORT=… ./tests-lua/dev-run.sh
# Visit http://127.0.0.1:18787/ — sidebar should show Skip trace.
```

The dev-run script wires `LUA_PATH` so `require("sysops.mount")` resolves
against the local `libs/sysops/` instead of an installed copy.

```bash
# Run the smoke test instead of starting the server:
ASSAY_ROOT=$(realpath ../assay) ./tests-lua/dev-run.sh --smoke
```

## Install on a host

```bash
# 1) Service account + dirs
sudo useradd --system --create-home --shell /usr/sbin/nologin gondor
sudo mkdir -p /etc/gondor /var/lib/gondor
sudo chown -R gondor:gondor /etc/gondor /var/lib/gondor

# 2) Lay out the config dir
sudo cp -r brand pages services templates scripts Manifest.lua /etc/gondor/
sudo cp deploy/env.example /etc/gondor/env
sudo chmod 600 /etc/gondor/env

# 3) Fill in secrets + per-host config in /etc/gondor/env:
#      GONDOR_ADMIN_API_KEYS  — shared secret between gondor + the engine sidecar.
#                                Generate with `openssl rand -hex 32`.
#      ENGINE_URL             — http://127.0.0.1:8082 for same-host deploys.
#      ENGINE_BASE_URL        — public hostname behind cloudflared/Traefik
#                                (https://gondor-engine.<domain>). Drives the
#                                "Open in engine ↗" links on each workflow page.
#                                Leave empty if no public engine surface.
#      GITHUB_TOKEN           — only needed if your skip-trace flows hit github.
sudoedit /etc/gondor/env

# 4) Install assay + sysops via mise + assay install
sudo -u gondor bash -c '
  cd /etc/gondor
  mise install
  set -a; . /etc/gondor/env; set +a
  /usr/local/bin/assay install --manifest Manifest.lua
'

# 5) Install the engine sidecar — separate process, branded for gondor,
#    bound to 127.0.0.1:8082, sqlite-backed at /var/lib/gondor-engine.
#    Front it with cloudflared/Traefik as gondor-engine.agenteda.com.
sudo mkdir -p /etc/gondor-engine /var/lib/gondor-engine
sudo chown -R gondor:gondor /etc/gondor-engine /var/lib/gondor-engine
sudo cp deploy/engine.toml.example /etc/gondor-engine/engine.toml
# Edit at minimum: sqlite path (/var/lib/gondor-engine/engine.db),
# bind address (127.0.0.1:8082), and any per-tenant JWT/secret options.
sudo -u gondor sudoedit /etc/gondor-engine/engine.toml

# 6) Drop the gondor systemd units + start. gondor.service has
#    After=gondor-engine.service so ordering is automatic. Both units use
#    EnvironmentFile=/etc/gondor/env so they share GONDOR_ADMIN_API_KEYS.
sudo cp deploy/gondor-engine.service.example /etc/systemd/system/gondor-engine.service
sudo cp deploy/gondor.service.example /etc/systemd/system/gondor.service
sudo systemctl daemon-reload
sudo systemctl enable --now gondor-engine gondor

# 7) Verify the install. healthz should return 200, the sidebar should
#    render with the FCAR workflows group + Skip trace child.
curl -s http://127.0.0.1:18790/healthz                          # → "ok"
curl -s http://127.0.0.1:18790/skip-trace | grep -q "FCAR" && echo "sidebar OK"
systemctl status gondor gondor-engine --no-pager
```

If the public hostname is fronted by cloudflared/Traefik, the typical mapping
is `gondor.<domain>` → `127.0.0.1:18790` (the dashboard) and
`gondor-engine.<domain>` → `127.0.0.1:8082` (the engine SPA). Set
`ENGINE_BASE_URL=https://gondor-engine.<domain>` in `/etc/gondor/env` so the
"Open in engine ↗" links on the workflow pages point at the right place.

## Customizing the brand

`brand/brand.css` is the only place to touch for visual tweaks. Sysops's
design tokens (`--bg-0`, `--info`, `--fg-1`, etc.) are defined upstream;
redeclaring any of them in `brand.css` overrides the default.

`brand/brand.json` covers metadata templates reference directly:

- `name` — sidebar brand block + `<title>` tag.
- `subtitle` — small label under the name.
- `favicon_url` — path served at this URL (relative or absolute).
- `accent_hex` — overrides `--info` at runtime; redundant with `brand.css`
  but useful for dynamic per-tenant tweaks.
- `workflows_label` — sidebar group label that wraps the workflow children
  (default `"Workflows"`; FCAR's brand sets it to `"FCAR workflows"`).

## The skip-trace workflow

`/skip-trace` is a runs page: an "In progress" section above a paginated
"Recent runs" table, both rendered server-side from the engine's
`pipeline_state` snapshot. Click `+ New skip-trace` to open a modal,
submit, and watch the run advance through Validate → Lookup → Score →
Persist → Notify with a live step ladder + log. Same shape as
gitops/knowhere's promotion dashboard.

The handler lives in `services/workflows/definitions/skip_trace.lua`. It
calls `services/tracer.lua` (the deterministic mock) as activities and
registers `pipeline_state` so both gondor's runs table AND the engine
SPA's `/workflow/<id>` Steps tab render the same data.

The worker is spawned as a coroutine inside `scripts/main.lua` via
`async.spawn(workflow_registry.start, cfg)` — same process as the
dashboard, no separate systemd unit. Adding a new workflow type is one
file: `services/workflows/definitions/<type>.lua` (handler + activities

- `meta`) and a sidebar entry in `extra_sidebar_links`.

## Bumping the sysops version

```bash
# Update the pin in Manifest.lua, then on each host:
cd /etc/gondor && sudo -u gondor /usr/local/bin/assay install --manifest Manifest.lua
sudo systemctl restart gondor
```

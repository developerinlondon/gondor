# gondor

A host-ops application composed from
[`assay-hostops`](https://github.com/developerinlondon/assay) (the `libs/hostops`
library shipped alongside the assay binary) with FCAR-specific branding,
services, and pages. Runs as a Lua app on top of `assay run` with an
`assay-engine` sidecar for workflow + vault.

## What's in here

```
gondor/
├── brand/                            # whitelabel pack — overrides hostops defaults
│   ├── brand.json                    # name, subtitle, accent_hex, favicon
│   ├── brand.css                     # CSS overrides (loaded last by layout.html)
│   └── img/favicon.svg
├── deploy/
│   ├── env.example                   # secrets (admin keys, GITHUB_TOKEN)
│   ├── gondor.service.example        # systemd unit (User=gondor, sandboxed)
│   └── gondor-skip-trace-worker.service.example
├── pages/skip_trace.lua              # GET /skip-trace handler
├── services/
│   ├── audit.lua                     # flat-file audit log
│   ├── brand.lua                     # brand-pack reader
│   ├── engine_client.lua             # HTTP wrapper to assay-engine
│   ├── jobs.lua                      # in-memory job tracker
│   ├── secret_store.lua              # secrets accessor (engine vault → rustic → file)
│   ├── state.lua                     # host + container snapshot
│   └── tracer.lua                    # deterministic mock skip-trace
├── templates/skip_trace.html
├── scripts/
│   ├── main.lua                      # composition entry point
│   └── skip_trace_worker.lua         # registers fcar.skip-trace on the engine
├── tests-lua/
│   ├── smoke.test.lua                # boots scripts/main.lua + curls routes
│   └── dev-run.sh                    # convenience launcher for local dev
├── Manifest.lua                      # pins hostops 0.1.2 for `assay install`
└── VERSION                           # gondor's own semver pin
```

## Why no plugin loader

Older fcar/gondor (now archived) discovered features via `plugin.toml` files
inside `plugins/<name>/`. That layer existed because the old knowhere binary
couldn't be modified by operators. `gondor` is the binary now — `scripts/main.lua`
is the composition root, so plugins are just regular pages/services in the
repo and get registered directly on the routes table. Hostops's
`extra_sidebar_links` mount opt covers the sidebar-affordance case without any
plugin lifecycle.

## Run locally

```bash
# 1) Build assay locally (one-time)
cd ../assay && cargo build --release --bin assay

# 2) Boot gondor pointing at the local hostops checkout
cd ../gondor
ASSAY_ROOT=$(realpath ../assay) ./tests-lua/dev-run.sh

# Default port 18787; override via PORT=… ./tests-lua/dev-run.sh
# Visit http://127.0.0.1:18787/ — sidebar should show Skip trace.
```

The dev-run script wires `LUA_PATH` so `require("hostops.mount")` resolves
against the local `libs/hostops/` instead of an installed copy.

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

# 3) Fill in secrets (admin API keys, GITHUB_TOKEN)
sudoedit /etc/gondor/env

# 4) Install assay + hostops via mise + assay install
sudo -u gondor bash -c '
  cd /etc/gondor
  mise install
  set -a; . /etc/gondor/env; set +a
  /usr/local/bin/assay install --manifest Manifest.lua
'

# 5) Install the engine sidecar (separate unit, ships with assay-engine).
#    See https://github.com/developerinlondon/assay docs for the engine
#    deployment story. Set ENGINE_URL in /etc/gondor/env to its bind addr.

# 6) Drop the gondor systemd units + start
sudo cp deploy/gondor.service.example /etc/systemd/system/gondor.service
sudo cp deploy/gondor-skip-trace-worker.service.example /etc/systemd/system/gondor-skip-trace-worker.service
sudo systemctl daemon-reload
sudo systemctl enable --now gondor gondor-skip-trace-worker
```

## Customizing the brand

`brand/brand.css` is the only place to touch for visual tweaks. Hostops's
design tokens (`--bg-0`, `--info`, `--fg-1`, etc.) are defined upstream;
redeclaring any of them in `brand.css` overrides the default.

`brand/brand.json` covers metadata templates reference directly:

- `name` — sidebar brand block + `<title>` tag.
- `subtitle` — small label under the name.
- `favicon_url` — path served at this URL (relative or absolute).
- `accent_hex` — overrides `--info` at runtime; redundant with `brand.css`
  but useful for dynamic per-tenant tweaks.

## The skip-trace workflow

`pages/skip_trace.lua` runs the deterministic mock in `services/tracer.lua`
inline (synchronous; sub-millisecond) and posts a workflow record to the
engine sidecar with the result baked into the input. The engine's
`/workflow/` SPA shows it as PENDING.

`scripts/skip_trace_worker.lua` runs as a separate systemd unit. It claims
PENDING runs from the default queue and promotes them to COMPLETED, copying
the input fields into the result. Future iteration: move the mock into the
worker so the page handler enqueues with operator input only.

## Bumping the hostops version

```bash
# Update the pin in Manifest.lua, then on each host:
cd /etc/gondor && sudo -u gondor /usr/local/bin/assay install --manifest Manifest.lua
sudo systemctl restart gondor gondor-skip-trace-worker
```

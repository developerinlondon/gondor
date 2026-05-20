--! gondor · scripts/main.lua
--!
--! Composition entry point. Boots the sysops library against this
--! repo's services + brand pack, mounts the host-ops dashboard at the
--! root, registers gondor-specific pages (skip-trace) on top, and
--! spawns the workflow worker on a background coroutine.
--!
--! Run via:
--!   assay run scripts/main.lua
--!
--! The systemd unit at deploy/gondor.service.example exports the same.

local sysops    = require("sysops.mount")
local state      = require("services.state")
local audit      = require("services.audit")
local jobs       = require("services.jobs")
local secret     = require("services.secret_store")
local brand      = require("services.brand")
local engine     = require("services.engine_client").new(
  env.get("ENGINE_URL"),
  env.get("GONDOR_ADMIN_API_KEYS")
)
local skip_trace = require("pages.skip_trace")

local workflow_client   = require("services.workflows.client")
local workflow_registry = require("services.workflows.registry")
local skip_trace_def    = require("services.workflows.definitions.skip_trace")

local PORT     = tonumber(env.get("PORT") or "8086")
local LIB_ROOT = env.get("SYSOPS_LIB_ROOT") or "/opt/assay/libs/sysops"
local APP_ROOT = env.get("GONDOR_ROOT") or "."

local engine_base_url = env.get("ENGINE_BASE_URL") or ""

-- Workflow client config — engine URL + admin token + namespace, threaded
-- through both `client.init` (read path) and `registry.start` (worker
-- listen path) so they hit the same engine instance with the same auth.
local wf_cfg = {
  workflow_url       = env.get("ENGINE_URL"),
  workflow_token     = env.get("GONDOR_ADMIN_API_KEYS"),
  workflow_namespace = env.get("WORKFLOW_NAMESPACE") or "main",
}

-- Monotonic revision number, bumped each time something workflow-state-
-- affecting changes. SSE clients use this to know when to re-fetch.
local state_revision = 1
local function bump_revision()
  state_revision = state_revision + 1
end

skip_trace.configure({
  audit           = audit,
  template_dir    = APP_ROOT .. "/templates",
  engine_base_url = engine_base_url,
})

local function brand_file(rel, content_type, max_age)
  return function(_req)
    local path = brand.dir() .. "/" .. rel
    local body = fs.exists(path) and fs.read(path) or nil
    if not body then return { status = 404, body = "not found" } end
    return {
      status  = 200,
      body    = body,
      headers = {
        ["Content-Type"]  = content_type,
        ["Cache-Control"] = "public, max-age=" .. tostring(max_age or 60),
      },
    }
  end
end

local function static_file(rel, content_type, max_age)
  return function(_req)
    local path = APP_ROOT .. "/" .. rel
    local body = fs.exists(path) and fs.read(path) or nil
    if not body then return { status = 404, body = "not found" } end
    return {
      status  = 200,
      body    = body,
      headers = {
        ["Content-Type"]  = content_type,
        ["Cache-Control"] = "public, max-age=" .. tostring(max_age or 60),
      },
    }
  end
end

state.start()

local routes = { GET = {}, POST = {} }

local mount_opts = {
  prefix              = "/",
  state               = state,
  audit               = audit,
  jobs                = jobs,
  secret              = secret,
  brand               = brand,
  engine              = engine,
  lib_root            = LIB_ROOT,
  backup_profile_dir  = env.get("BACKUP_PROFILE_DIR"),
  engine_base_url     = engine_base_url,
  -- Opt into the sysops 0.1.5 in-process Auth + Vault dashboards. The
  -- pages render under /auth/* and /vault/* and proxy to the engine
  -- sidecar above; the existing Engine sidebar link still ships for the
  -- SPA path. See assay/.claude/plans/25-v0.1.5-sysops-auth-vault-pages.md.
  active_modules      = { "auth", "vault" },
  engine_admin_key    = env.get("GONDOR_ADMIN_API_KEYS") or env.get("ENGINE_ADMIN_KEY"),
  extra_sidebar_links = {
    {
      label = brand.snapshot().workflows_label,
      children = {
        { href = "/skip-trace", label = "Skip trace", nav_active = "skip_trace" },
      },
    },
  },
}

-- Opt into the sysops 0.2.0 auth gateway when AUTH_ISSUER is set. Sysops
-- becomes the OIDC RP, holds the engine admin bearer server-side, and
-- proxies dashboard SPA + /api/v1/engine/* to gondor-engine. The engine
-- itself stays unchanged (admin-bearer-only at its boundary).
--
-- Production wiring:
--   AUTH_ISSUER        = https://gondor-engine.agenteda.com/auth
--   AUTH_REDIRECT_URI  = https://gondor.agenteda.com/auth/callback
--   ENGINE_URL         = http://127.0.0.1:8082  (private sidecar)
--   GONDOR_ADMIN_API_KEYS — shared with the engine's admin_api_keys
--   SYSOPS_SESSION_KEY — ≥32 random bytes, openssl rand -hex 32
local auth_issuer = env.get("AUTH_ISSUER")
if auth_issuer and auth_issuer ~= "" then
  mount_opts.oidc = {
    issuer        = auth_issuer,
    client_id     = env.get("AUTH_CLIENT_ID") or "gondor-dashboard",
    redirect_uri  = env.get("AUTH_REDIRECT_URI"),
    scopes        = { "openid", "email", "profile" },
  }
  mount_opts.session = {
    signing_key = env.get("SYSOPS_SESSION_KEY"),
    ttl_seconds = tonumber(env.get("AUTH_SESSION_TTL") or "86400"),
    cookie_name = "gondor_session",
  }
  mount_opts.gateway = {
    engine_upstream = env.get("ENGINE_URL") or "http://127.0.0.1:8082",
    admin_bearer   = env.get("GONDOR_ADMIN_API_KEYS"),
  }
  mount_opts.authz = {
    require_zanzibar_admin = false, -- flip on once zanzibar tuples seeded
    bootstrap_first_admin  = true,  -- first OIDC login → engine:core#admin
  }
end

sysops.mount(routes, mount_opts)

-- Gondor-specific pages — gated by the sysops auth gateway when wired
-- (require_session is a no-op pass-through when ctx.session_signer is nil,
-- so this is safe for non-OIDC deployments too).
local require_session = require("sysops.middleware.require_session")
local function gated(handler) return require_session.wrap(handler) end

-- Skip-trace runs UI: page shell + HTMX fragments + submit.
routes.GET["/skip-trace"]              = gated(skip_trace.page)
routes.GET["/api/skip-trace/active"]   = gated(skip_trace.active_fragment)
routes.GET["/api/skip-trace/runs"]     = gated(skip_trace.runs_fragment)
routes.GET["/api/skip-trace/new"]      = gated(skip_trace.new_fragment)
routes.POST["/skip-trace/run"]         = gated(skip_trace.submit)

routes.GET["/healthz"]                 = function() return { status = 200, body = "ok" } end

-- Static assets (gondor-owned). The lib's static handler serves
-- /static/* otherwise; http.serve picks the more specific path.
routes.GET["/static/css/pipeline.css"] = static_file("static/css/pipeline.css", "text/css", 60)
routes.GET["/static/app.js"]           = static_file("static/app.js", "text/javascript", 60)

-- Brand-pack overrides for the lib's defaults.
routes.GET["/static/css/brand.css"]    = brand_file("brand.css", "text/css", 60)
routes.GET["/static/favicon.svg"]      = brand_file("favicon.svg", "image/svg+xml", 300)
routes.GET["/static/img/favicon.svg"]  = brand_file("img/favicon.svg", "image/svg+xml", 300)
routes.GET["/static/img/favicon.png"]  = brand_file("img/favicon.png", "image/png", 300)
routes.GET["/brand/engine.css"]        = brand_file("engine.css", "text/css", 60)

-- SSE event stream — emits a "refresh" event each time state_revision
-- changes. Clients sleep+poll the local counter so the read path stays
-- off the engine for steady-state.
routes.GET["/api/events"] = gated(function(_req)
  return {
    status  = 200,
    headers = { ["Content-Type"] = "text/event-stream",
                ["Cache-Control"] = "no-cache" },
    sse = function(send)
      send({ event = "refresh", data = tostring(state_revision) })
      local last_seen = state_revision
      while true do
        sleep(1)
        if state_revision ~= last_seen then
          last_seen = state_revision
          send({ event = "refresh", data = tostring(last_seen) })
        end
      end
    end,
  }
end)

-- Workflow client wiring + history rehydrate. Async + pcall'd so the
-- dashboard still boots if the engine is unreachable; the new-run
-- button surfaces the failure.
pcall(workflow_client.init, bump_revision, wf_cfg)
async.spawn(function()
  local ok, err = pcall(workflow_client.rehydrate, skip_trace_def.meta.type)
  if not ok then log.warn("history rehydrate: " .. tostring(err)) end
end)

-- Workflow worker — listen() blocks, so it has to run on a spawned
-- coroutine or the HTTP server never boots.
async.spawn(function()
  local ok, err = pcall(workflow_registry.start, wf_cfg)
  if not ok then
    log.error("workflow worker stopped: " .. tostring(err))
  end
end)

if auth_issuer and auth_issuer ~= "" then
  log.info(("sysops auth gateway enabled: issuer=%s client_id=%s redirect_uri=%s")
    :format(auth_issuer, env.get("AUTH_CLIENT_ID") or "gondor-dashboard",
            env.get("AUTH_REDIRECT_URI") or "<unset>"))
end

log.info(("gondor booting on :%d (lib_root=%s, engine=%s)")
  :format(PORT, LIB_ROOT, env.get("ENGINE_URL") or "<unset>"))
http.serve(PORT, routes)

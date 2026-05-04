--! gondor · scripts/main.lua
--!
--! Composition entry point. Boots the hostops library against this
--! repo's services + brand pack, mounts the host-ops dashboard at the
--! root, registers gondor-specific pages (skip-trace) on top, and
--! spawns the workflow worker on a background coroutine.
--!
--! Run via:
--!   assay run scripts/main.lua
--!
--! The systemd unit at deploy/gondor.service.example exports the same.

local hostops    = require("hostops.mount")
local state      = require("services.state")
local audit      = require("services.audit")
local jobs       = require("services.jobs")
local secret     = require("services.secret_store")
local brand      = require("services.brand")
local engine     = require("services.engine_client").new(env.get("ENGINE_URL"))
local skip_trace = require("pages.skip_trace")

local workflow_client   = require("services.workflows.client")
local workflow_registry = require("services.workflows.registry")
local skip_trace_def    = require("services.workflows.definitions.skip_trace")

local PORT     = tonumber(env.get("PORT") or "8086")
local LIB_ROOT = env.get("HOSTOPS_LIB_ROOT") or "/opt/assay/libs/hostops"
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

hostops.mount(routes, {
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
  extra_sidebar_links = {
    {
      label = brand.snapshot().workflows_label,
      children = {
        { href = "/skip-trace", label = "Skip trace", nav_active = "skip_trace" },
      },
    },
  },
})

-- Skip-trace runs UI: page shell + HTMX fragments + submit.
routes.GET["/skip-trace"]              = skip_trace.page
routes.GET["/api/skip-trace/active"]   = skip_trace.active_fragment
routes.GET["/api/skip-trace/runs"]     = skip_trace.runs_fragment
routes.GET["/api/skip-trace/new"]      = skip_trace.new_fragment
routes.POST["/skip-trace/run"]         = skip_trace.submit

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
routes.GET["/api/events"] = function(_req)
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
end

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

log.info(("gondor booting on :%d (lib_root=%s, engine=%s)")
  :format(PORT, LIB_ROOT, env.get("ENGINE_URL") or "<unset>"))
http.serve(PORT, routes)

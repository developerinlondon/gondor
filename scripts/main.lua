--! gondor · scripts/main.lua
--!
--! Composition entry point. Boots the hostops library against this
--! repo's services + brand pack, mounts the host-ops dashboard at the
--! root, and registers gondor-specific pages (skip-trace) on top.
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
local tracer     = require("services.tracer")
local skip_trace = require("pages.skip_trace")

local PORT     = tonumber(env.get("PORT") or "8086")
local LIB_ROOT = env.get("HOSTOPS_LIB_ROOT") or "/opt/assay/libs/hostops"
local APP_ROOT = env.get("GONDOR_ROOT") or "."

skip_trace.configure({
  engine       = engine,
  tracer       = tracer,
  template_dir = APP_ROOT .. "/templates",
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

state.start()

local routes = { GET = {}, POST = {} }

hostops.mount(routes, {
  prefix   = "/",
  state    = state,
  audit    = audit,
  jobs     = jobs,
  secret   = secret,
  brand    = brand,
  engine   = engine,
  lib_root = LIB_ROOT,
  -- Backup profile dir override (default /etc/rustic).
  backup_profile_dir = env.get("BACKUP_PROFILE_DIR"),
  -- Engine sidecar URL — hostops sidebar's "Engine" entry links here.
  engine_base_url = env.get("ENGINE_BASE_URL"),
  -- Gondor's own surfaces sit alongside the lib's nav blocks.
  extra_sidebar_links = {
    { href = "/skip-trace", label = "Skip trace", nav_active = "skip_trace" },
  },
})

-- Gondor-specific routes.
routes.GET["/skip-trace"] = skip_trace.page
routes.GET["/healthz"]    = function() return { status = 200, body = "ok" } end

-- Shadow hostops's default brand assets with this app's brand pack so
-- the whitelabel overrides actually load. http.serve picks the more
-- specific path over the lib's `/static/*` wildcard.
routes.GET["/static/css/brand.css"] = brand_file("brand.css", "text/css", 60)
routes.GET["/static/favicon.svg"]   = brand_file("favicon.svg", "image/svg+xml", 300)
routes.GET["/static/img/favicon.svg"] = brand_file("img/favicon.svg", "image/svg+xml", 300)
routes.GET["/static/img/favicon.png"] = brand_file("img/favicon.png", "image/png", 300)

-- Brand-pack CSS overrides for the engine SPA (loaded via
-- ASSAY_WHITELABEL_CSS_URL on the engine systemd unit).
routes.GET["/brand/engine.css"] = brand_file("engine.css", "text/css", 60)

log.info(("gondor booting on :%d (lib_root=%s, app_root=%s)"):format(PORT, LIB_ROOT, APP_ROOT))
http.serve(PORT, routes)

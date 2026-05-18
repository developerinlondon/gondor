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
local engine     = require("services.engine_client").new(env.get("ENGINE_URL"))
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

sysops.mount(routes, {
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

-- ============================================================================
-- OIDC RP — Google login via assay-auth on the engine sidecar.
--
-- Opt-in via AUTH_ISSUER. When set, the dashboard becomes a real OIDC
-- relying party against the issuer (PKCE public client, no shared
-- secret) and gates every page except /login, /auth/callback, /logout,
-- /healthz, /static/* and /brand/* behind a server-side session cookie.
-- ============================================================================
local auth_issuer = env.get("AUTH_ISSUER")
if auth_issuer and auth_issuer ~= "" then
  local oidc = require("services.oidc_client").new({
    issuer       = auth_issuer,
    client_id    = env.get("AUTH_CLIENT_ID") or "gondor-dashboard",
    redirect_uri = env.get("AUTH_REDIRECT_URI"),
    scopes       = { "openid", "email", "profile" },
    session_ttl  = tonumber(env.get("AUTH_SESSION_TTL") or "86400"),
  })

  local secure_cookie = (auth_issuer:sub(1, 8) == "https://")

  local function get_header(req, name)
    local h = req and req.headers or {}
    return h[name] or h[name:lower()]
  end

  local function parse_cookie(req, name)
    local raw = get_header(req, "Cookie") or ""
    for part in raw:gmatch("[^;]+") do
      local k, v = part:match("^%s*([^=]+)=(.*)$")
      if k == name then return v end
    end
  end

  local function build_cookie(name, value, opts)
    local parts = { name .. "=" .. value }
    parts[#parts + 1] = "Path=" .. (opts.path or "/")
    parts[#parts + 1] = "HttpOnly"
    parts[#parts + 1] = "SameSite=Lax"
    if opts.max_age then parts[#parts + 1] = "Max-Age=" .. tostring(opts.max_age) end
    if opts.secure then parts[#parts + 1] = "Secure" end
    return table.concat(parts, "; ")
  end

  local function urlenc(s)
    return (tostring(s or "")):gsub("([^A-Za-z0-9%-_%.~])", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
  end

  local SESSION_COOKIE = "gondor_session"
  local STATE_COOKIE   = "gondor_oidc_state"

  local public_paths = {
    ["/login"]          = true,
    ["/auth/callback"]  = true,
    ["/logout"]         = true,
    ["/healthz"]        = true,
    ["/favicon.ico"]    = true,
  }
  local function is_public(path)
    if public_paths[path] then return true end
    if path:match("^/static/") then return true end
    if path:match("^/brand/") then return true end
    return false
  end

  -- Wrap every currently-registered route except the public allowlist.
  -- Done BEFORE we add /login etc. so the new routes stay unwrapped.
  for _, method in ipairs({ "GET", "POST", "PUT", "DELETE" }) do
    local tbl = routes[method]
    if tbl then
      for path, handler in pairs(tbl) do
        if not is_public(path) then
          tbl[path] = function(req)
            local sid = parse_cookie(req, SESSION_COOKIE)
            local sess = sid and oidc.session(sid) or nil
            if not sess then
              return {
                status  = 302,
                headers = { Location = "/login?return_to=" .. urlenc(req and req.path or "/") },
              }
            end
            req.user = { id = sess.user_id, email = sess.email, name = sess.display_name }
            return handler(req)
          end
        end
      end
    end
  end

  routes.GET["/login"] = function(req)
    local return_to = (req and req.params and req.params.return_to) or "/"
    local started = oidc.start(return_to)
    return {
      status  = 302,
      headers = {
        Location       = started.redirect_url,
        ["Set-Cookie"] = build_cookie(STATE_COOKIE, started.state, {
          path = "/auth", max_age = 600, secure = secure_cookie,
        }),
      },
    }
  end

  routes.GET["/auth/callback"] = function(req)
    local state = parse_cookie(req, STATE_COOKIE)
    local res, err = oidc.complete((req and req.params) or {}, state)
    if not res then
      return {
        status  = 400,
        headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
        body    = "auth callback failed: " .. tostring(err),
      }
    end
    return {
      status  = 302,
      headers = {
        Location       = res.return_to,
        ["Set-Cookie"] = build_cookie(SESSION_COOKIE, res.session_id, {
          path = "/", max_age = 86400, secure = secure_cookie,
        }),
      },
    }
  end

  routes.GET["/logout"] = function(req)
    local sid = parse_cookie(req, SESSION_COOKIE)
    local res = oidc.logout(sid, (req and req.params and req.params.return_to) or "/")
    return {
      status  = 302,
      headers = {
        Location       = res.redirect_url,
        ["Set-Cookie"] = SESSION_COOKIE .. "=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax",
      },
    }
  end

  log.info(("oidc rp enabled: issuer=%s client_id=%s redirect_uri=%s")
    :format(auth_issuer, env.get("AUTH_CLIENT_ID") or "gondor-dashboard",
            env.get("AUTH_REDIRECT_URI") or "<unset>"))
end

log.info(("gondor booting on :%d (lib_root=%s, engine=%s)")
  :format(PORT, LIB_ROOT, env.get("ENGINE_URL") or "<unset>"))
http.serve(PORT, routes)

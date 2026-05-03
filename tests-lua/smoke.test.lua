--! gondor smoke test — boots scripts/main.lua against a local hostops
--! checkout, curls a representative set of routes, asserts shape +
--! brand wiring + skip-trace flow.
--!
--! Set HOSTOPS_LIB_ROOT to a hostops checkout (defaults to
--! ../assay/libs/hostops). Run with:
--!
--!   LUA_PATH='libs/?.lua;...' assay tests-lua/smoke.test.lua
--!
--! See dev-run.sh in this dir for the canonical invocation.

local hostops    = require("hostops.mount")
local state      = require("services.state")
local audit      = require("services.audit")
local jobs       = require("services.jobs")
local secret     = require("services.secret_store")
local brand      = require("services.brand")
local engine     = require("services.engine_client").new("http://127.0.0.1:1") -- unreachable
local tracer     = require("services.tracer")
local skip_trace = require("pages.skip_trace")

local function fail(msg)  error("smoke fail: " .. tostring(msg), 2) end
local function ok(label) print("  ✓ " .. label) end

print("[gondor.smoke]")

local PORT = 47918
local APP_ROOT = env.get("GONDOR_ROOT") or "."

skip_trace.configure({
  engine       = engine,
  tracer       = tracer,
  template_dir = APP_ROOT .. "/templates",
})

local routes = { GET = {}, POST = {} }

hostops.mount(routes, {
  prefix              = "/",
  state               = state,
  audit               = audit,
  jobs                = jobs,
  secret              = secret,
  brand               = brand,
  engine              = engine,
  lib_root            = env.get("HOSTOPS_LIB_ROOT"),
  backup_profile_dir  = "/tmp/gondor-smoke-no-profile",
  extra_sidebar_links = {
    { href = "/skip-trace", label = "Skip trace", nav_active = "skip_trace" },
  },
})

routes.GET["/skip-trace"]      = skip_trace.page
routes.GET["/__smoke_alive"]   = function() return { status = 200, body = "ok" } end

async.spawn(function() http.serve(PORT, routes) end)
sleep(0.5)

local function get(path) return http.get("http://127.0.0.1:" .. PORT .. path) end
local function assert_contains(body, needle, label)
  if not body or not body:find(needle, 1, true) then
    fail(("%s: missing %q (got %s bytes)"):format(label, needle, body and #body or 0))
  end
end

do
  local r = get("/__smoke_alive")
  if r.status ~= 200 or r.body ~= "ok" then fail("alive: " .. tostring(r.status)) end
  ok("/__smoke_alive returns 200 ok")
end

-- ── / dashboard renders, gondor brand wired through ───────────────────
do
  local r = get("/")
  if r.status ~= 200 then fail("GET / → " .. r.status) end
  assert_contains(r.body, "Gondor",                  "brand name")
  assert_contains(r.body, 'href="/skip-trace"',      "skip-trace sidebar link")
  ok("/ renders with Gondor brand + skip-trace sidebar entry")
end

-- ── /skip-trace renders the form, no result without query ─────────────
do
  local r = get("/skip-trace")
  if r.status ~= 200 then fail("GET /skip-trace → " .. r.status) end
  assert_contains(r.body, 'action="/skip-trace"',     "skip-trace form action")
  assert_contains(r.body, "Run trace",                "skip-trace submit button")
  if r.body:find("Probable record", 1, true) then
    fail("skip-trace renders result block without a name in query")
  end
  ok("/skip-trace renders the form")
end

-- ── /skip-trace?name=Jane+Doe&state=NY runs the mock + renders result ─
do
  local r = get("/skip-trace?name=Jane+Doe&state=NY")
  if r.status ~= 200 then fail("GET /skip-trace?name=… → " .. r.status) end
  assert_contains(r.body, "Probable record", "skip-trace result heading")
  assert_contains(r.body, "Jane Doe",        "skip-trace result subject")
  assert_contains(r.body, "confidence",      "skip-trace result confidence row")
  -- Engine is unreachable so workflow_id should NOT show up.
  if r.body:find('class="k">workflow', 1, true) then
    fail("skip-trace shows workflow_id chip when engine is unreachable")
  end
  ok("/skip-trace?name=… renders mock result, no workflow chip with engine down")
end

-- ── /audit renders, no dead admin tabs ────────────────────────────────
do
  local r = get("/audit")
  if r.status ~= 200 then fail("GET /audit → " .. r.status) end
  if r.body:find('href="/inventory"', 1, true)
     or r.body:find('href="/packages"', 1, true)
     or r.body:find('href="/settings"', 1, true) then
    fail("audit page has dead /inventory|/packages|/settings link")
  end
  ok("/audit renders, no dead admin tabs")
end

print("[gondor.smoke] all passed")

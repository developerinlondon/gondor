--! gondor smoke test — boots scripts/main.lua against a local hostops
--! checkout, curls a representative set of routes, asserts shape +
--! brand wiring + skip-trace runs UI.
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
local skip_trace = require("pages.skip_trace")

local function fail(msg)  error("smoke fail: " .. tostring(msg), 2) end
local function ok(label) print("  ✓ " .. label) end

print("[gondor.smoke]")

local PORT = 47918
local APP_ROOT = env.get("GONDOR_ROOT") or "."

skip_trace.configure({
  audit           = audit,
  template_dir    = APP_ROOT .. "/templates",
  engine_base_url = "https://gondor-engine.example.com",
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

-- Skip-trace runs UI routes — page + HTMX fragments + submit.
routes.GET["/skip-trace"]            = skip_trace.page
routes.GET["/api/skip-trace/active"] = skip_trace.active_fragment
routes.GET["/api/skip-trace/runs"]   = skip_trace.runs_fragment
routes.GET["/api/skip-trace/new"]    = skip_trace.new_fragment
routes.POST["/skip-trace/run"]       = skip_trace.submit

routes.GET["/__smoke_alive"] = function() return { status = 200, body = "ok" } end

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

-- ── /skip-trace renders the runs page (button + slots, no inline form) ─
do
  local r = get("/skip-trace")
  if r.status ~= 200 then fail("GET /skip-trace → " .. r.status) end
  assert_contains(r.body, "+ New skip-trace",         "new-run button")
  assert_contains(r.body, 'id="workflow-dialog"',     "modal slot")
  assert_contains(r.body, 'id="skip-trace-active-slot"', "active section slot")
  assert_contains(r.body, 'id="skip-trace-runs-slot"',   "recent section slot")
  assert_contains(r.body, "Open in engine",           "engine link")
  -- The old inline result panel must NOT be rendered any more.
  if r.body:find("Probable record", 1, true) then
    fail("skip-trace still renders the old inline result panel")
  end
  ok("/skip-trace renders the runs page shell")
end

-- ── /api/skip-trace/active fragment renders even with engine down ────
do
  local r = get("/api/skip-trace/active")
  if r.status ~= 200 then fail("GET /api/skip-trace/active → " .. r.status) end
  assert_contains(r.body, 'id="skip-trace-active-fragment"', "active fragment id")
  assert_contains(r.body, "No skip-trace runs in progress", "empty-state message")
  ok("/api/skip-trace/active fragment renders empty-state")
end

-- ── /api/skip-trace/runs fragment renders empty-state with no history ─
do
  local r = get("/api/skip-trace/runs")
  if r.status ~= 200 then fail("GET /api/skip-trace/runs → " .. r.status) end
  assert_contains(r.body, 'id="skip-trace-runs-fragment"', "runs fragment id")
  assert_contains(r.body, "No skip-trace runs recorded yet", "empty-state message")
  ok("/api/skip-trace/runs fragment renders empty-state")
end

-- ── /api/skip-trace/new returns the modal markup ──────────────────────
do
  local r = get("/api/skip-trace/new")
  if r.status ~= 200 then fail("GET /api/skip-trace/new → " .. r.status) end
  assert_contains(r.body, 'class="modal-overlay"',  "modal overlay")
  assert_contains(r.body, 'name="name"',            "subject name input")
  assert_contains(r.body, 'name="state"',           "state select")
  assert_contains(r.body, 'name="case_number"',     "case number input")
  ok("/api/skip-trace/new returns the modal form")
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

# 02 · gondor · Workflow runs UI

**Status:** spec ready, implementation pending\
**Date:** 2026-05-04\
**Companion:** [`knowhere/.claude/plans/02-hostops-links-to-engine-spa.md`](https://github.com/developerinlondon/knowhere/blob/main/.claude/plans/02-hostops-links-to-engine-spa.md)\
**Reference implementation:** `intuitive/siemens/gitops/tools/knowhere`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render workflow runs (active + history) on the consumer app's own pages instead of forcing
operators into the engine SPA at `/workflow/`. Each workflow type gets its own sidebar entry and
its own page, all rendered server-side from the engine's `pipeline_state` snapshot — same shape as
gitops/knowhere's promotion dashboard.

**Architecture:** Per-consumer copy (no shared lib — matches gitops). Each consumer holds its own
`services/workflows/` data layer + `templates/` + `static/css/pipeline.css` + an embedded worker
coroutine spawned from `scripts/main.lua`. New-run forms open in an HTMX modal. Live updates via
SSE `/api/events` + `HX-Trigger: dashboard-refresh` headers on mutations.

**Tech stack:** Lua (assay), HTMX, Jinja2 templates (assay's templating), SSE, the engine's
`/api/v1/engine/workflow/*` HTTP API.

## Conventions copied from `intuitive/siemens/gitops/tools/knowhere`

| concern        | gitops choice                                                  | applied here                                                 |
| -------------- | -------------------------------------------------------------- | ------------------------------------------------------------ |
| code sharing   | per-consumer copy, no lib                                      | gondor + knowhere each carry their own `services/workflows/` |
| worker process | `async.spawn(workflow_registry.start, cfg)` in main.lua        | same; drop standalone systemd worker                         |
| new-run form   | HTMX modal `hx-target="#workflow-dialog"`                      | same                                                         |
| pagination     | per-page default `10`, options `{5, 10, 25, 50}`               | same                                                         |
| live refresh   | `EventSource("/api/events")` + `HX-Trigger: dashboard-refresh` | same                                                         |
| CSS classes    | `.pipeline-*` (matches engine SPA's `50-pipeline.css`)         | same; do not namespace                                       |
| comments       | header `--! …` block + intent comment per function             | same                                                         |

## Sidebar shape after this lands

Per-workflow-type sidebar entries via the existing `extra_sidebar_links` mechanism:

```
Sysops
  Services / Cron / …
  Engine ↗
─
Skip trace            /skip-trace            ← gondor
(future) Asset val.   /asset-valuation
─
Audit
```

knowhere mirrors the framework with an empty `definitions/` directory until a workflow type is added there.

## File deltas (gondor first, then knowhere mirror)

| layer   | file                                              | new/edit | role                                                                                |
| ------- | ------------------------------------------------- | -------- | ----------------------------------------------------------------------------------- |
| data    | `services/workflows/engine.lua`                   | new      | single integration boundary; mirrors gitops                                         |
| data    | `services/workflows/client.lua`                   | new      | `list_active`, `list_recent`, `start`, `describe`, `get_state`                      |
| data    | `services/workflows/steps.lua`                    | new      | step-state helper used by handlers                                                  |
| data    | `services/workflows/history.lua`                  | new      | in-memory recent-runs cache + page()                                                |
| data    | `services/workflows/registry.lua`                 | new      | activity + workflow registration + `wf.listen`                                      |
| data    | `services/workflows/definitions/skip_trace.lua`   | new      | `meta` + handler + activities; registers `pipeline_state`                           |
| view    | `templates/skip_trace.html`                       | rewrite  | page shell — header, modal slot, active section, recent section                     |
| view    | `templates/skip_trace_active.html`                | new      | active-runs cards — port of gitops `active_pipeline.html`                           |
| view    | `templates/skip_trace_runs.html`                  | new      | recent-runs table — port of gitops `pipeline_runs.html`                             |
| view    | `templates/skip_trace_new.html`                   | new      | modal form — port shape of gitops `promote_preview.html`                            |
| view    | `static/css/pipeline.css`                         | new      | port of gitops `static/css/pipeline.css`                                            |
| view    | `static/app.js`                                   | new      | SSE EventSource + modal handlers + table-row toggles                                |
| wiring  | `pages/skip_trace.lua`                            | rewrite  | `page`, `active_fragment`, `runs_fragment`, `new_fragment`, `submit`                |
| wiring  | `scripts/main.lua`                                | edit     | mount routes, `async.spawn(registry.start)`, SSE endpoint, `state_revision` counter |
| cleanup | `scripts/skip_trace_worker.lua`                   | delete   | superseded by `services/workflows/registry.lua`                                     |
| cleanup | `deploy/gondor-skip-trace-worker.service.example` | delete   | worker now embedded                                                                 |
| tests   | `tests-lua/smoke.test.lua`                        | edit     | add probes for `/skip-trace`, `/api/skip-trace/active`, `/api/skip-trace/runs`      |

knowhere gets a near-identical copy of all `services/workflows/`, `templates/skip_trace*` (named
generically for whatever its first type ends up being — see Phase 5).

## Phases

1. **Data layer** — engine.lua, client.lua, steps.lua, history.lua, registry.lua. Pure code,
   no UI yet.
2. **Definition** — skip_trace.lua handler with `pipeline_state` query.
3. **View layer** — templates + CSS + JS.
4. **Wiring** — pages/skip_trace.lua + scripts/main.lua mount + SSE.
5. **Cleanup + smoke** — delete superseded files, extend smoke test.
6. **Knowhere mirror** — copy `services/workflows/` framework to `/home/eda/code/knowhere`,
   leave `definitions/` empty.

---

## Phase 1 — Data layer

### Task 1: services/workflows/engine.lua

**Files:**

- Create: `/home/eda/code/gondor/services/workflows/engine.lua`

**Reference:** `intuitive/siemens/gitops/tools/knowhere/services/workflows/engine.lua`

- [ ] **Step 1: Write the file**

```lua
--! services/workflows/engine.lua — single integration boundary with the
--! assay workflow engine. Every other file under services/workflows/
--! goes through this module so the `require("assay.workflow")` dependency
--! and auth-token wiring lives in exactly one place.

local workflow = require("assay.workflow")

local M = {}

local _connected = false
local _namespace = nil

-- Connect to the engine. Idempotent — safe to call from both the worker
-- startup path and the request-handling path.
function M.connect(cfg)
  if _connected then return workflow end
  cfg = cfg or {}
  local url = cfg.workflow_url or env.get("ENGINE_URL") or "http://127.0.0.1:8082"
  local token = cfg.workflow_token or env.get("GONDOR_ADMIN_API_KEYS")
                                    or env.get("ASSAY_ADMIN_KEY")
  local opts = {}
  if token and token ~= "" then opts.token = token end
  workflow.connect(url, opts)
  _connected = true
  _namespace = cfg.workflow_namespace or "main"
  log.info("workflow engine connected: " .. url
        .. " (namespace=" .. _namespace .. ")")
  return workflow
end

-- Return the connected `assay.workflow` module. Errors loudly if connect
-- hasn't run yet so caller-order bugs surface immediately.
function M.module()
  if not _connected then
    error("services.workflows.engine: call engine.connect(cfg) first")
  end
  return workflow
end

-- Engine-level namespace this gondor instance operates in. Threaded
-- through every wf.start / wf.list call so workflow state is partitioned
-- inside the same logical bucket.
function M.namespace()
  return _namespace or "main"
end

return M
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add services/workflows/engine.lua
git -C /home/eda/code/gondor commit -m "feat(workflows): add engine integration boundary"
```

### Task 2: services/workflows/steps.lua

**Files:**

- Create: `/home/eda/code/gondor/services/workflows/steps.lua`

**Reference:** `intuitive/siemens/gitops/tools/knowhere/services/workflows/steps.lua`

- [ ] **Step 1: Write the file**

```lua
--! services/workflows/steps.lua — step-state helper used by workflow
--! handlers. Wraps the canonical pipeline_state schema (status,
--! current_step, steps[], log[]) so each handler doesn't reinvent it.
--!
--! The schema is what both the engine SPA's "Steps" tab AND gondor's own
--! runs-table read. Two callers, one source of truth.

local M = {}

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function clock_str()
  return os.date("!%H:%M:%S")
end

-- Build a fresh pipeline_state for a run. `step_names` is an ordered
-- list of human-readable step names (rendered as labels on the badges).
-- Returns a table of { status, current_step, steps, log,
--   :enter(i), :exit(i), :log(msg, step?), :fail(msg, step?) }.
function M.new(step_names)
  local steps = {}
  for i, name in ipairs(step_names) do
    steps[i] = {
      name   = name,
      status = i == 1 and "running" or "waiting",
      started_at  = i == 1 and now_iso() or nil,
      completed_at = nil,
    }
  end

  local self = {
    status       = "running",
    current_step = 1,
    steps        = steps,
    log          = {},
  }

  function self:_log(msg, step)
    self.log[#self.log + 1] = {
      time = clock_str(),
      msg  = msg,
      step = step or self.current_step,
    }
  end

  function self:enter(i)
    self.current_step = i
    if self.steps[i] then
      self.steps[i].status     = "running"
      self.steps[i].started_at = now_iso()
    end
    self:_log("Starting " .. (self.steps[i] and self.steps[i].name or "?"), i)
  end

  function self:exit(i)
    if self.steps[i] then
      self.steps[i].status       = "done"
      self.steps[i].completed_at = now_iso()
    end
    self:_log((self.steps[i] and self.steps[i].name or "?") .. " complete", i)
  end

  function self:fail(msg, step)
    local i = step or self.current_step
    if self.steps[i] then
      self.steps[i].status       = "failed"
      self.steps[i].completed_at = now_iso()
    end
    self.status = "failed"
    self:_log("FAILED: " .. tostring(msg), i)
  end

  function self:done()
    self.status = "done"
    self:_log("Run complete")
  end

  return self
end

return M
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add services/workflows/steps.lua
git -C /home/eda/code/gondor commit -m "feat(workflows): add step-state helper for pipeline_state schema"
```

### Task 3: services/workflows/history.lua

**Files:**

- Create: `/home/eda/code/gondor/services/workflows/history.lua`

**Reference:** `intuitive/siemens/gitops/tools/knowhere/services/workflows/history.lua`

- [ ] **Step 1: Write the file**

```lua
--! services/workflows/history.lua — in-memory recent-runs cache.
--!
--! Pod restart clears it; client.lua's rehydrate() repopulates from the
--! engine on boot. Cap is generous because skip-trace runs are tiny and
--! we want a few hundred for the Recent tab without a round-trip per
--! page click.

local M = {}

local CAP = 500

local _entries = {}

function M.replace(entries)
  _entries = entries or {}
end

-- Append at the front (newest first). Drops oldest entries past CAP.
function M.prepend(entry)
  table.insert(_entries, 1, entry)
  while #_entries > CAP do
    table.remove(_entries)
  end
end

-- Update an entry in place by id, leaving order unchanged. Used when a
-- run transitions from RUNNING to a terminal state and we already have
-- a placeholder row.
function M.upsert_by_id(entry)
  for i, e in ipairs(_entries) do
    if e.id == entry.id then
      _entries[i] = entry
      return
    end
  end
  M.prepend(entry)
end

function M.list()
  return _entries
end

-- Return one slice for pagination. Caller passes 1-based page; we clamp
-- both page and per_page so dodgy query params don't crash.
function M.page(page, per_page)
  page = tonumber(page) or 1
  per_page = tonumber(per_page) or 10
  if page < 1 then page = 1 end
  if per_page < 1 then per_page = 10 end
  if per_page > 100 then per_page = 100 end
  local total = #_entries
  local first = (page - 1) * per_page + 1
  local last  = math.min(first + per_page - 1, total)
  local out   = {}
  for i = first, last do out[#out + 1] = _entries[i] end
  return out, total, page, per_page
end

return M
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add services/workflows/history.lua
git -C /home/eda/code/gondor commit -m "feat(workflows): add recent-runs in-memory cache"
```

### Task 4: services/workflows/client.lua

**Files:**

- Create: `/home/eda/code/gondor/services/workflows/client.lua`

**Reference:** `intuitive/siemens/gitops/tools/knowhere/services/workflows/client.lua`

- [ ] **Step 1: Write the file**

```lua
--! services/workflows/client.lua — gondor-facing client over the assay
--! workflow engine. list_active / list_recent / start / describe /
--! get_state, with a small in-memory cache and rehydrate-on-boot so the
--! Recent table has content immediately after a pod restart.

local engine  = require("services.workflows.engine")
local history = require("services.workflows.history")

local M = {}

local _notify_fn = nil
local _cfg       = nil

local function notify()
  if _notify_fn then _notify_fn() end
end

-- Wire the client to the engine and to a 0-arg notify function the
-- caller bumps on every state-affecting mutation (drives SSE).
function M.init(notify_fn, cfg)
  _notify_fn = notify_fn
  _cfg       = cfg
  engine.connect(cfg)
end

-- ── reads ─────────────────────────────────────────────────────────────

local function get_pipeline_state(wf_id)
  if not wf_id then return nil end
  local wf = engine.module()
  local ok, snapshot = pcall(wf.get_state, wf_id, "pipeline_state")
  if not ok or type(snapshot) ~= "table" then return nil end
  local state = snapshot.value or snapshot
  if type(state) ~= "table" then return nil end
  state.id = wf_id
  return state
end

-- (workflow_type, status) → array of pipeline_state tables (latest first).
local function list_states(workflow_type, status, limit)
  local got, wf = pcall(engine.module)
  if not got then return {} end
  local ok, runs = pcall(wf.list, {
    namespace = engine.namespace(),
    type      = workflow_type,
    status    = status,
    limit     = limit or 50,
  })
  if not ok or type(runs) ~= "table" then return {} end
  local out = {}
  for _, r in ipairs(runs) do
    local state = get_pipeline_state(r.id) or {}
    state.id          = r.id
    state.engine_status = r.status
    state.created_at  = r.created_at
    state.completed_at = r.completed_at
    out[#out + 1] = state
  end
  return out
end

function M.list_active(workflow_type)
  return list_states(workflow_type, "RUNNING", 50)
end

-- Page a slice of recent runs from the in-memory cache. Cache is filled
-- by rehydrate() on boot and prepend-on-mutation while the pod runs.
function M.list_recent(_workflow_type, page, per_page)
  return history.page(page, per_page)
end

function M.describe(wf_id)
  local wf = engine.module()
  local ok, info = pcall(wf.describe, wf_id)
  if not ok or type(info) ~= "table" then return nil end
  return info
end

function M.get_state(wf_id)
  return get_pipeline_state(wf_id)
end

-- ── writes ────────────────────────────────────────────────────────────

-- Start a workflow on the engine. `opts` carries workflow_type,
-- workflow_id, task_queue, input. Returns (id, nil) on success or
-- (nil, error_msg) on failure.
function M.start(opts)
  local wf = engine.module()
  local ok, err = pcall(wf.start, {
    workflow_type = opts.workflow_type,
    workflow_id   = opts.workflow_id,
    namespace     = engine.namespace(),
    task_queue    = opts.task_queue or "default",
    input         = opts.input,
  })
  if not ok then return nil, tostring(err) end
  notify()
  return opts.workflow_id, nil
end

-- ── boot ─────────────────────────────────────────────────────────────

-- Pull recent terminal runs into the history cache so the Recent table
-- has content immediately after a pod restart. Async-spawned by
-- scripts/main.lua so dashboard boot isn't blocked by it.
function M.rehydrate(workflow_type)
  local entries = {}
  for _, status in ipairs({ "COMPLETED", "FAILED", "CANCELLED" }) do
    for _, state in ipairs(list_states(workflow_type, status, 200)) do
      if status == "COMPLETED" then state.status = "done"
      elseif status == "FAILED" then state.status = "failed"
      elseif status == "CANCELLED" then state.status = "cancelled" end
      entries[#entries + 1] = state
    end
  end
  table.sort(entries, function(a, b)
    return (a.created_at or 0) > (b.created_at or 0)
  end)
  history.replace(entries)
  log.info("workflow history rehydrated: " .. tostring(#entries) .. " runs")
end

return M
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add services/workflows/client.lua
git -C /home/eda/code/gondor commit -m "feat(workflows): add gondor-facing client over the engine"
```

### Task 5: services/workflows/registry.lua

**Files:**

- Create: `/home/eda/code/gondor/services/workflows/registry.lua`

**Reference:** `intuitive/siemens/gitops/tools/knowhere/services/workflows/registry.lua`

- [ ] **Step 1: Write the file**

```lua
--! services/workflows/registry.lua — workflow worker entrypoint.
--! Iterates services/workflows/definitions/*, registers each handler +
--! its activities, and blocks on wf.listen(). Adding a new workflow
--! type = drop a new definitions/<type>.lua file; this scans for them.
--!
--! Note: wf.listen({queue}) BLOCKS indefinitely. Caller must spawn this
--! on a background coroutine (async.spawn) so the HTTP server keeps
--! serving.

local engine = require("services.workflows.engine")

local M = {}

M.TASK_QUEUE = "default"

-- Definition modules to register. Add entries here when new types land.
-- (We don't auto-scan the directory because Lua has no portable readdir
-- and the definitions list rarely changes — explicit is fine.)
local DEFINITIONS = {
  "services.workflows.definitions.skip_trace",
}

function M.start(cfg)
  local wf = engine.connect(cfg)
  for _, mod in ipairs(DEFINITIONS) do
    local def = require(mod)
    if def.register then def.register(wf, cfg) end
    log.info("registered workflow definition: " .. mod
          .. " (type=" .. (def.meta and def.meta.type or "?") .. ")")
  end
  local ns = engine.namespace()
  log.info("workflow worker starting on queue '" .. M.TASK_QUEUE
        .. "' namespace '" .. ns .. "'")
  wf.listen({ queue = M.TASK_QUEUE, namespace = ns })
end

return M
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add services/workflows/registry.lua
git -C /home/eda/code/gondor commit -m "feat(workflows): add worker registry"
```

---

## Phase 2 — Definition

### Task 6: services/workflows/definitions/skip_trace.lua

**Files:**

- Create: `/home/eda/code/gondor/services/workflows/definitions/skip_trace.lua`

**Reference for shape:** gondor's existing `services/tracer.lua` (mock) +
`scripts/skip_trace_worker.lua` (deleted in Phase 5).

- [ ] **Step 1: Write the file**

```lua
--! services/workflows/definitions/skip_trace.lua — fcar.skip-trace
--! workflow definition.
--!
--! Step ladder:
--!   1. Validate    — sanity-check input
--!   2. Lookup      — services.tracer mock (sub-millisecond stand-in)
--!   3. Score       — confidence calculation
--!   4. Persist     — write the row (audit-only today)
--!   5. Notify      — placeholder for downstream notify (no-op)
--!
--! Registers `pipeline_state` query so both the engine SPA's Steps tab
--! AND gondor's own runs table render the same data.

local steps_helper = require("services.workflows.steps")
local tracer       = require("services.tracer")

local M = {}

M.meta = {
  type         = "fcar.skip-trace",
  display_name = "Skip trace",
  route        = "/skip-trace",
  task_queue   = "default",
  description  = "Trace contact info from name + state + case ID",

  -- Step labels — kept here so the runs page doesn't need a copy.
  step_names = { "Validate", "Lookup", "Score", "Persist", "Notify" },
}

function M.register(wf, _cfg)
  wf.workflow(M.meta.type, function(ctx, input)
    input = input or {}
    local state = steps_helper.new(M.meta.step_names)

    -- Surface the run's headline fields on the state itself so the
    -- runs-table can read them via pipeline_state without a second API
    -- call.
    state.subject_name = input.name
    state.state_code   = input.state
    state.case_number  = input.case_number
    state.requested_by = input.requested_by

    ctx:register_query("pipeline_state", function() return state end)

    -- Step 1: Validate
    state:enter(1)
    if not input.name or input.name == "" then
      state:fail("subject name is required", 1)
      error("subject name is required", 0)
    end
    state:exit(1)

    -- Step 2: Lookup
    state:enter(2)
    local lookup = ctx:execute_activity("lookup", { name = input.name,
      state = input.state, case_number = input.case_number })
    state:exit(2)

    -- Step 3: Score
    state:enter(3)
    local score = ctx:execute_activity("score", { lookup = lookup })
    state:exit(3)

    -- Step 4: Persist (audit-only today)
    state:enter(4)
    ctx:execute_activity("persist", { input = input, lookup = lookup,
      score = score })
    state:exit(4)

    -- Step 5: Notify (no-op stub)
    state:enter(5)
    ctx:execute_activity("notify", { subject = input.name })
    state:exit(5)

    state:done()
    return {
      subject     = input.name,
      state_code  = input.state,
      case_number = input.case_number,
      confidence  = score.confidence,
      phone       = lookup.phone,
      email       = lookup.email,
    }
  end)

  -- Activities are tiny wrappers over services/tracer.lua's mock.
  wf.activity("lookup", function(_ctx, input)
    local res = tracer.run({
      name = input.name,
      state = input.state,
      case_number = input.case_number,
    })
    return {
      phone   = res.phone,
      email   = res.email,
      address = res.probable_address,
    }
  end)

  wf.activity("score", function(_ctx, input)
    -- Mock confidence: present-fields-out-of-3, scaled to [70, 99].
    local present = 0
    if input.lookup.phone   and input.lookup.phone   ~= "" then present = present + 1 end
    if input.lookup.email   and input.lookup.email   ~= "" then present = present + 1 end
    if input.lookup.address and input.lookup.address ~= "" then present = present + 1 end
    return { confidence = math.min(99, 70 + present * 10) }
  end)

  wf.activity("persist", function(_ctx, _input)
    -- Audit-only today; gondor's services.audit handler logs the
    -- skip_trace.run from the page handler. Future: write to a
    -- dedicated traces table.
    return { stored = true }
  end)

  wf.activity("notify", function(_ctx, _input)
    return { sent = false, reason = "stub" }
  end)
end

return M
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add services/workflows/definitions/skip_trace.lua
git -C /home/eda/code/gondor commit -m "feat(workflows): add fcar.skip-trace definition + handler"
```

---

## Phase 3 — View layer

### Task 7: static/css/pipeline.css (port from gitops)

**Files:**

- Create: `/home/eda/code/gondor/static/css/pipeline.css`

**Reference:** `intuitive/siemens/gitops/tools/knowhere/static/css/pipeline.css`

- [ ] **Step 1: Copy the file verbatim**

```bash
mkdir -p /home/eda/code/gondor/static/css
cp /home/eda/code/intuitive/siemens/gitops/tools/knowhere/static/css/pipeline.css \
   /home/eda/code/gondor/static/css/pipeline.css
```

- [ ] **Step 2: Confirm class prefix is `.pipeline-*`**

Run: `grep -oE "\.[a-z][a-z-]+" /home/eda/code/gondor/static/css/pipeline.css | sort -u | head -20`
Expected: classes like `.pipeline`, `.pipeline-step`, `.pipeline-connector`, `.pipeline-log`, etc.

- [ ] **Step 3: Commit**

```bash
git -C /home/eda/code/gondor add static/css/pipeline.css
git -C /home/eda/code/gondor commit -m "feat(workflows): port pipeline.css from gitops/knowhere"
```

### Task 8: static/app.js (SSE + modal handlers)

**Files:**

- Create: `/home/eda/code/gondor/static/app.js`

**Reference:** `intuitive/siemens/gitops/tools/knowhere/static/app.js:170-247` (SSE block)

- [ ] **Step 1: Write the file**

```javascript
// gondor static/app.js — SSE bridge + modal helpers + table-row toggles.
// Loaded by templates/skip_trace.html via <script src="/static/app.js">.
//
// Contract with the server:
//   /api/events                       — SSE stream, emits "refresh" events
//   HX-Trigger: dashboard-refresh     — response header on mutations;
//                                       hx-trigger="dashboard-refresh from:body"
//                                       on slot divs picks it up
//   #workflow-dialog                  — modal target for the new-run form

(function () {
  "use strict";

  // ── SSE bridge ────────────────────────────────────────────────────
  var main = document.getElementById("kh-main");
  if (main && typeof EventSource !== "undefined") {
    var source = new EventSource("/api/events");
    var lastRevision = null;

    source.addEventListener("refresh", function (evt) {
      if (evt.data === lastRevision) return;
      lastRevision = evt.data;

      // Don't clobber an open modal — finish whatever the operator is
      // doing first; the next refresh will pick up the new state.
      var openDialog = document.querySelector("#workflow-dialog .modal-overlay");
      if (openDialog) return;

      fetch(window.location.pathname + window.location.search,
        { credentials: "same-origin" })
        .then(function (resp) { return resp.text(); })
        .then(function (html) {
          var doc = new DOMParser().parseFromString(html, "text/html");
          var newMain = doc.getElementById("kh-main");
          if (newMain && main.innerHTML !== newMain.innerHTML) {
            main.innerHTML = newMain.innerHTML;
            if (window.htmx) window.htmx.process(main);
          }
        })
        .catch(function (err) {
          console.error("[gondor] refresh failed:", err);
        });
    });

    source.addEventListener("error", function () {
      // EventSource auto-reconnects; just log.
      console.warn("[gondor] SSE disconnected, reconnecting…");
    });
  }

  // ── Modal helpers ────────────────────────────────────────────────
  // Close the workflow dialog. Bound globally so onclick handlers in
  // dialog HTML can invoke it without an import dance.
  window.closeWorkflowDialog = function (evt) {
    if (evt && evt.target && !evt.target.classList.contains("modal-overlay")) return;
    var dialog = document.getElementById("workflow-dialog");
    if (dialog) dialog.innerHTML = "";
  };

  // Close on Escape — better keyboard UX than only the [×] button.
  document.addEventListener("keydown", function (evt) {
    if (evt.key === "Escape") window.closeWorkflowDialog();
  });

  // ── Recent-runs row expand ───────────────────────────────────────
  // Click toggles the next sibling <tr class="run-detail">. Bound on
  // window so inline onclick="togglePipelineDetail('id')" works.
  window.togglePipelineDetail = function (id) {
    var detail = document.getElementById(id);
    if (!detail) return;
    detail.style.display = detail.style.display === "none" ? "" : "none";
  };
})();
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add static/app.js
git -C /home/eda/code/gondor commit -m "feat(workflows): add SSE bridge + modal handlers"
```

### Task 9: templates/skip_trace_active.html

**Files:**

- Create: `/home/eda/code/gondor/templates/skip_trace_active.html`

**Reference:** `intuitive/siemens/gitops/tools/knowhere/templates/active_pipeline.html`

- [ ] **Step 1: Write the file**

```html
<!-- Active skip-trace runs. Rendered by /api/skip-trace/active and
     refreshed via hx-trigger="dashboard-refresh from:body". One card
     per RUNNING workflow on the engine. -->
<div id="skip-trace-active-fragment">
  {% if active and active | length > 0 %}
  {% for run in active %}
  <section class="pipeline pipeline-hero" data-run-id="{{ run.id }}">
    <div class="pipeline-tabs" role="tablist">
      <button type="button" class="pipeline-tab active" data-tab="pipeline" role="tab"
              aria-selected="true">Steps</button>
      <button type="button" class="pipeline-tab" data-tab="log" role="tab"
              aria-selected="false">
        Log{% if run.log %} ({{ run.log | length }}){% endif %}
      </button>
    </div>
    <div class="pipeline-tab-panel active" data-tab-panel="pipeline">
      <header class="pipeline-header">
        <h3>{{ run.subject_name | default('?') }} ({{ run.state_code | default('?') }})</h3>
        <span class="meta">case#{{ run.case_number | default('?') }} · {{ run.id }}</span>
        <span class="badge badge-warning">{{ (run.status or 'running') | upper }}</span>
      </header>
      <div class="pipeline-steps">
        {% for step in run.steps %}
        <div class="pipeline-step step-{{ step.status }}" title="{{ step.name }}">
          <div class="step-indicator">
            {% if step.status == "done" %}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                 stroke-width="2.5"><path d="M20 6L9 17l-5-5" /></svg>
            {% elif step.status == "running" %}
            <div class="spinner"></div>
            {% elif step.status == "failed" or step.status == "cancelled" %}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                 stroke-width="2.5"><path d="M18 6L6 18" /><path d="M6 6l12 12" /></svg>
            {% else %}
            <div class="step-dot"></div>
            {% endif %}
          </div>
          <div class="step-name">{{ step.name }}</div>
        </div>
        {% if not loop.last %}
        <div class="pipeline-connector step-{{ step.status }}"></div>
        {% endif %}
        {% endfor %}
      </div>
    </div>
    <div class="pipeline-tab-panel" data-tab-panel="log" hidden>
      {% if run.log and run.log | length > 0 %}
      <div class="pipeline-log">
        {% for entry in run.log %}
        <div class="log-entry" data-step="{{ entry.step }}">
          <span class="log-time">{{ entry.time }}</span> {{ entry.msg }}
        </div>
        {% endfor %}
      </div>
      {% else %}
      <p class="meta" style="padding: 12px 16px;">No log entries yet.</p>
      {% endif %}
    </div>
  </section>
  {% endfor %}
  {% else %}
  <p class="meta">No skip-trace runs in progress.</p>
  {% endif %}
</div>
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add templates/skip_trace_active.html
git -C /home/eda/code/gondor commit -m "feat(workflows): add active-runs template"
```

### Task 10: templates/skip_trace_runs.html

**Files:**

- Create: `/home/eda/code/gondor/templates/skip_trace_runs.html`

**Reference:** `intuitive/siemens/gitops/tools/knowhere/templates/pipeline_runs.html`

- [ ] **Step 1: Write the file**

```html
<!-- Recent skip-trace runs. Rendered by /api/skip-trace/runs?page=N&per_page=P.
     Same shape as gitops's pipeline_runs.html — one row per run with a
     compact step ladder, click-to-expand for log + result + step
     durations. -->
<div id="skip-trace-runs-fragment" class="pipeline-runs-fragment">
  {% if runs and runs | length > 0 %}
  <div class="table-wrapper">
    <table class="table">
      <thead>
        <tr>
          <th>Status</th>
          <th>Subject</th>
          <th>Case#</th>
          <th>Steps</th>
          <th>Started</th>
        </tr>
      </thead>
      <tbody>
        {% for run in runs %}
        <tr class="pipeline-history-row"
            onclick="togglePipelineDetail('run-{{ loop.index0 }}-{{ run.id }}')"
            role="button" tabindex="0">
          <td>
            {% if run.status == "done" %}<span class="badge badge-success">Done</span>
            {% elif run.status == "failed" %}<span class="badge badge-danger">Failed</span>
            {% elif run.status == "cancelled" %}<span class="badge badge-muted">Cancelled</span>
            {% else %}<span class="badge badge-muted">{{ run.status }}</span>{% endif %}
          </td>
          <td>
            {{ run.subject_name | default('?') }} ({{ run.state_code | default('?') }})
            {% if run.requested_by %}
            <div class="history-author meta" style="margin-top:4px">
              by {{ run.requested_by }}
            </div>
            {% endif %}
          </td>
          <td><code class="version-code">{{ run.case_number | default('-') }}</code></td>
          <td>
            <div class="pipeline-steps pipeline-steps-compact">
              {% for step in run.steps %}
              <div class="pipeline-step step-{{ step.status }}" title="{{ step.name }}">
                <div class="step-indicator step-indicator-sm">
                  {% if step.status == "done" %}
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                       stroke-width="2.5"><path d="M20 6L9 17l-5-5" /></svg>
                  {% elif step.status == "failed" or step.status == "cancelled" %}
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                       stroke-width="2.5"><path d="M18 6L6 18" /><path d="M6 6l12 12" /></svg>
                  {% else %}
                  <div class="step-dot"></div>
                  {% endif %}
                </div>
              </div>
              {% if not loop.last %}
              <div class="pipeline-connector step-{{ step.status }}"></div>
              {% endif %}
              {% endfor %}
            </div>
          </td>
          <td class="meta">{{ run.started_ago | default('-') }}</td>
        </tr>
        <tr id="run-{{ loop.index0 }}-{{ run.id }}" class="pipeline-history-detail"
            style="display:none">
          <td colspan="5">
            <div class="pipeline pipeline-expanded-run" data-run-id="expanded-{{ run.id }}">
              <div class="pipeline-steps">
                {% for step in run.steps %}
                <div class="pipeline-step step-{{ step.status }}" title="{{ step.name }}">
                  <div class="step-indicator step-indicator-sm">
                    {% if step.status == "done" %}
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                         stroke-width="2.5"><path d="M20 6L9 17l-5-5" /></svg>
                    {% elif step.status == "failed" or step.status == "cancelled" %}
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                         stroke-width="2.5"><path d="M18 6L6 18" /><path d="M6 6l12 12" /></svg>
                    {% else %}
                    <div class="step-dot"></div>
                    {% endif %}
                  </div>
                  <div class="step-name">{{ step.name }}</div>
                </div>
                {% if not loop.last %}
                <div class="pipeline-connector step-{{ step.status }}"></div>
                {% endif %}
                {% endfor %}
              </div>
              {% if run.log and run.log | length > 0 %}
              <div class="pipeline-log pipeline-log-main">
                {% for entry in run.log %}
                <div class="log-entry" data-step="{{ entry.step }}">
                  <span class="log-time">{{ entry.time }}</span> {{ entry.msg }}
                </div>
                {% endfor %}
              </div>
              {% endif %}
            </div>
          </td>
        </tr>
        {% endfor %}
      </tbody>
    </table>
  </div>

  {% if total_pages > 1 or total > per_page_options | first %}
  <div class="pipeline-runs-pagination">
    <div class="pagination-info">Showing {{ page_first }}–{{ page_last }} of {{ total }} runs</div>
    <div class="pagination-controls">
      <label>Per page
        <select hx-get="/api/skip-trace/runs" hx-target="#skip-trace-runs-fragment"
                hx-swap="outerHTML" hx-include="[name='page']" name="per_page">
          {% for opt in per_page_options %}
          <option value="{{ opt }}" {% if per_page == opt %}selected{% endif %}>{{ opt }}</option>
          {% endfor %}
        </select>
      </label>
      <input type="hidden" name="page" value="1" />
      {% if page > 1 %}
      <button class="btn btn-outline btn-sm"
              hx-get="/api/skip-trace/runs?page={{ page_prev }}&per_page={{ per_page }}"
              hx-target="#skip-trace-runs-fragment" hx-swap="outerHTML">← Prev</button>
      {% else %}
      <button class="btn btn-outline btn-sm" disabled aria-disabled="true">← Prev</button>
      {% endif %}
      <span class="pagination-page">Page {{ page }} / {{ total_pages }}</span>
      {% if page < total_pages %}
      <button class="btn btn-outline btn-sm"
              hx-get="/api/skip-trace/runs?page={{ page_next }}&per_page={{ per_page }}"
              hx-target="#skip-trace-runs-fragment" hx-swap="outerHTML">Next →</button>
      {% else %}
      <button class="btn btn-outline btn-sm" disabled aria-disabled="true">Next →</button>
      {% endif %}
    </div>
  </div>
  {% endif %}
  {% else %}
  <p class="meta">No skip-trace runs recorded yet. Click + New skip-trace to start one.</p>
  {% endif %}
</div>
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add templates/skip_trace_runs.html
git -C /home/eda/code/gondor commit -m "feat(workflows): add recent-runs table template"
```

### Task 11: templates/skip_trace_new.html (modal)

**Files:**

- Create: `/home/eda/code/gondor/templates/skip_trace_new.html`

- [ ] **Step 1: Write the file**

```html
<!-- New-skip-trace modal. Returned by /api/skip-trace/new and rendered
     into #workflow-dialog via hx-target="#workflow-dialog". POSTs to
     /skip-trace/run; HX-Trigger: dashboard-refresh on the response
     re-renders the active + recent fragments and the modal closes
     itself. -->
<div class="modal-overlay" onclick="closeWorkflowDialog(event)">
  <div class="modal-card" onclick="event.stopPropagation()">
    <div class="modal-header">
      <h3>New skip-trace</h3>
      <button class="modal-close" onclick="closeWorkflowDialog()" aria-label="Close">&times;</button>
    </div>
    <form class="modal-body" hx-post="/skip-trace/run" hx-target="#skip-trace-active-fragment"
          hx-swap="outerHTML" hx-on::after-request="closeWorkflowDialog()">
      <label>
        <span>Subject name</span>
        <input class="input" type="text" name="name" placeholder="John Smith" required autofocus />
      </label>
      <label>
        <span>State</span>
        <select class="input" name="state">
          <option value="CA">California</option>
          <option value="TX">Texas</option>
          <option value="OH">Ohio</option>
          <option value="NY">New York</option>
          <option value="PA">Pennsylvania</option>
          <option value="FL">Florida</option>
        </select>
      </label>
      <label>
        <span>Case # (optional)</span>
        <input class="input" type="text" name="case_number" placeholder="FCAR-1234" />
      </label>
      <div class="modal-actions">
        <button type="button" class="btn btn-outline" onclick="closeWorkflowDialog()">Cancel</button>
        <button type="submit" class="btn btn-primary">Run trace</button>
      </div>
    </form>
  </div>
</div>
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add templates/skip_trace_new.html
git -C /home/eda/code/gondor commit -m "feat(workflows): add new-skip-trace modal template"
```

### Task 12: templates/skip_trace.html (rewrite — page shell)

**Files:**

- Modify: `/home/eda/code/gondor/templates/skip_trace.html`

- [ ] **Step 1: Replace contents**

```html
<header class="page-header">
  <div>
    <div class="page-eyebrow">FCAR · skip trace</div>
    <h1 class="page-title">Skip trace</h1>
  </div>
  <div class="page-actions">
    <button class="btn btn-primary" hx-get="/api/skip-trace/new"
            hx-target="#workflow-dialog" hx-swap="innerHTML">+ New skip-trace</button>
    <a class="btn btn-outline" href="{{ engine_base_url | default('') }}/workflow/?type=fcar.skip-trace"
       target="_blank" rel="noopener">Open in engine ↗</a>
  </div>
</header>

<!-- Modal slot — populated by /api/skip-trace/new on click. -->
<div id="workflow-dialog"></div>

<section class="section">
  <div class="section-header"><h2 class="section-title">In progress</h2></div>
  <div id="skip-trace-active-slot"
       hx-get="/api/skip-trace/active"
       hx-trigger="load, dashboard-refresh from:body, every 3s">
    {{ active_html | safe }}
  </div>
</section>

<section class="section">
  <div class="section-header"><h2 class="section-title">Recent runs</h2></div>
  <div id="skip-trace-runs-slot"
       hx-get="/api/skip-trace/runs"
       hx-trigger="dashboard-refresh from:body, every 30s">
    {{ runs_html | safe }}
  </div>
</section>

<link rel="stylesheet" href="/static/css/pipeline.css" />
<script src="/static/app.js"></script>
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add templates/skip_trace.html
git -C /home/eda/code/gondor commit -m "feat(workflows): rewrite skip-trace page as runs view"
```

---

## Phase 4 — Wiring

### Task 13: pages/skip_trace.lua (rewrite)

**Files:**

- Modify: `/home/eda/code/gondor/pages/skip_trace.lua`

- [ ] **Step 1: Replace contents**

```lua
--! pages/skip_trace.lua — Skip Trace runs page.
--!
--! Routes mounted by scripts/main.lua:
--!   GET  /skip-trace                — page shell (active + recent)
--!   GET  /api/skip-trace/active     — active-runs fragment
--!   GET  /api/skip-trace/runs       — recent-runs fragment (paginated)
--!   GET  /api/skip-trace/new        — new-run modal
--!   POST /skip-trace/run            — start a run, redirect/refresh

local hctx   = require("sysops.ctx")
local render = require("sysops.pages.render")

local client  = require("services.workflows.client")
local history = require("services.workflows.history")
local def     = require("services.workflows.definitions.skip_trace")

local M = {}

local audit_log, template_dir, engine_base_url

function M.configure(deps)
  audit_log       = deps.audit_log
  template_dir    = deps.template_dir
  engine_base_url = deps.engine_base_url or ""
end

local function render_template(name, ctx)
  return render.render_template(hctx.from_request(ctx), template_dir, name .. ".html", ctx)
end

local function relative_time(unix_ts)
  if not unix_ts then return "-" end
  local diff = os.time() - unix_ts
  if diff < 60   then return diff .. "s ago" end
  if diff < 3600 then return math.floor(diff / 60) .. "m ago" end
  if diff < 86400 then return math.floor(diff / 3600) .. "h ago" end
  return math.floor(diff / 86400) .. "d ago"
end

local function enrich(run)
  run.started_ago = relative_time(run.created_at)
  return run
end

-- ── fragments ────────────────────────────────────────────────────────

function M.active_fragment(_req)
  local active = client.list_active(def.meta.type)
  for _, r in ipairs(active) do enrich(r) end
  return {
    status  = 200,
    headers = { ["Content-Type"] = "text/html; charset=utf-8" },
    body    = render_template("skip_trace_active", {
      active = active,
      nav_active = "skip_trace",
    }),
  }
end

function M.runs_fragment(req)
  local q = req and req.query or {}
  local page = tonumber(q.page) or 1
  local per_page = tonumber(q.per_page) or 10
  local rows, total, clamped_page, clamped_per_page = history.page(page, per_page)
  for _, r in ipairs(rows) do enrich(r) end
  local total_pages = math.max(1, math.ceil(total / clamped_per_page))
  local first = total == 0 and 0 or (clamped_page - 1) * clamped_per_page + 1
  local last  = math.min(first + #rows - 1, total)
  return {
    status  = 200,
    headers = { ["Content-Type"] = "text/html; charset=utf-8" },
    body    = render_template("skip_trace_runs", {
      runs             = rows,
      total            = total,
      page             = clamped_page,
      per_page         = clamped_per_page,
      total_pages      = total_pages,
      page_first       = first,
      page_last        = last,
      page_prev        = math.max(1, clamped_page - 1),
      page_next        = math.min(total_pages, clamped_page + 1),
      per_page_options = { 5, 10, 25, 50 },
    }),
  }
end

function M.new_fragment(_req)
  return {
    status  = 200,
    headers = { ["Content-Type"] = "text/html; charset=utf-8" },
    body    = render_template("skip_trace_new", {}),
  }
end

-- ── page ─────────────────────────────────────────────────────────────

function M.page(req)
  return {
    status  = 200,
    headers = { ["Content-Type"] = "text/html; charset=utf-8" },
    body    = render_template("skip_trace", {
      page_title       = "Skip trace",
      nav_active       = "skip_trace",
      engine_base_url  = engine_base_url,
      active_html      = M.active_fragment(req).body,
      runs_html        = M.runs_fragment(req).body,
    }),
  }
end

-- ── submit ───────────────────────────────────────────────────────────

local function form_value(body, name)
  if not body then return nil end
  for k, v in body:gmatch("([^&=]+)=([^&]*)") do
    if k == name then
      v = v:gsub("%+", " ")
      v = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
      return v
    end
  end
end

function M.submit(req)
  local body = req and req.body or ""
  local name        = form_value(body, "name")
  local state_code  = form_value(body, "state")
  local case_number = form_value(body, "case_number")

  if not name or name == "" then
    return { status = 400, body = "name is required" }
  end

  local wf_id = "trace-" .. tostring(os.time())
  local _, err = client.start({
    workflow_type = def.meta.type,
    workflow_id   = wf_id,
    task_queue    = def.meta.task_queue,
    input = {
      name         = name,
      state        = state_code,
      case_number  = case_number,
      requested_by = (req.user and req.user.name) or "operator",
    },
  })
  if err then
    return { status = 502, body = "engine: " .. err }
  end

  if audit_log then
    pcall(audit_log, {
      action = "skip_trace.run",
      actor  = (req.user and req.user.name) or "local-dev",
      target = "workflow:" .. wf_id,
      result = "ok",
    })
  end

  -- HX-Trigger header fires hx-trigger="dashboard-refresh from:body"
  -- on the active + recent slot divs, which re-fetch their fragments.
  -- The client-side hx-on::after-request="closeWorkflowDialog()" on
  -- the form closes the modal on success.
  return {
    status  = 200,
    headers = {
      ["Content-Type"] = "text/html; charset=utf-8",
      ["HX-Trigger"]   = "dashboard-refresh",
    },
    body = "",
  }
end

return M
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add pages/skip_trace.lua
git -C /home/eda/code/gondor commit -m "feat(workflows): rewrite skip-trace page handlers"
```

### Task 14: scripts/main.lua wiring

**Files:**

- Modify: `/home/eda/code/gondor/scripts/main.lua`

- [ ] **Step 1: Add requires + wiring (replace the file's body)**

Replace the existing file with the version below. Key additions vs today: `workflow_registry` require,
`async.spawn(workflow_registry.start, cfg)`, `state_revision` counter, `/api/events` SSE handler,
`/api/skip-trace/{active,runs,new}` route table, `/static/css/pipeline.css` + `/static/app.js`
serve handlers, `client.init(notify_fn, cfg)` + `client.rehydrate(def.meta.type)`.

```lua
--! gondor · scripts/main.lua
--!
--! Composition entry point. Boots the sysops library against this
--! repo's services + brand pack, mounts the host-ops dashboard at the
--! root, registers gondor-specific pages (skip-trace) on top, and
--! spawns the workflow worker on a background coroutine.

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

local PORT     = tonumber(env.get("PORT") or "18790")
local LIB_ROOT = env.get("SYSOPS_LIB_ROOT") or "/opt/assay/libs/sysops"
local APP_ROOT = env.get("GONDOR_ROOT") or "."

local engine_base_url = env.get("ENGINE_BASE_URL") or "https://gondor-engine.agenteda.com"

local cfg = {
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
  audit_log       = audit.write,
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
    local body = fs.exists(APP_ROOT .. "/" .. rel) and fs.read(APP_ROOT .. "/" .. rel) or nil
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
  prefix   = "/",
  state    = state,
  audit    = audit,
  jobs     = jobs,
  secret   = secret,
  brand    = brand,
  engine   = engine,
  lib_root = LIB_ROOT,
  backup_profile_dir = env.get("BACKUP_PROFILE_DIR"),
  engine_base_url    = engine_base_url,
  extra_sidebar_links = {
    { href = "/skip-trace", label = "Skip trace", nav_active = "skip_trace" },
  },
})

-- Skip-trace page + fragments + submit.
routes.GET["/skip-trace"]              = skip_trace.page
routes.GET["/api/skip-trace/active"]   = skip_trace.active_fragment
routes.GET["/api/skip-trace/runs"]     = skip_trace.runs_fragment
routes.GET["/api/skip-trace/new"]      = skip_trace.new_fragment
routes.POST["/skip-trace/run"]         = skip_trace.submit

-- Static assets (gondor-owned; lib serves /static/* otherwise).
routes.GET["/static/css/pipeline.css"] = static_file("static/css/pipeline.css", "text/css", 60)
routes.GET["/static/app.js"]           = static_file("static/app.js", "text/javascript", 60)

-- Brand-pack overrides for the lib's defaults.
routes.GET["/static/css/brand.css"]    = brand_file("brand.css", "text/css", 60)
routes.GET["/static/favicon.svg"]      = brand_file("favicon.svg", "image/svg+xml", 300)
routes.GET["/static/img/favicon.svg"]  = brand_file("img/favicon.svg", "image/svg+xml", 300)
routes.GET["/static/img/favicon.png"]  = brand_file("img/favicon.png", "image/png", 300)
routes.GET["/brand/engine.css"]        = brand_file("engine.css", "text/css", 60)
routes.GET["/healthz"]                 = function() return { status = 200, body = "ok" } end

-- SSE event stream — emits a "refresh" event each time state_revision
-- changes. Clients sleep+poll the local counter to avoid round-tripping
-- to the engine on the read path.
routes.GET["/api/events"] = function(_req)
  return {
    status  = 200,
    headers = { ["Content-Type"] = "text/event-stream",
                ["Cache-Control"] = "no-cache" },
    sse = function(send)
      send({ event = "refresh", data = tostring(state_revision) })
      local last_seen = state_revision
      while true do
        time.sleep(1)
        if state_revision ~= last_seen then
          last_seen = state_revision
          send({ event = "refresh", data = tostring(last_seen) })
        end
      end
    end,
  }
end

-- Workflow client wiring + history rehydrate (async; non-fatal on engine
-- unreachable so the dashboard still renders).
pcall(workflow_client.init, bump_revision, cfg)
async.spawn(function()
  local ok, err = pcall(workflow_client.rehydrate, skip_trace_def.meta.type)
  if not ok then log.warn("history rehydrate: " .. tostring(err)) end
end)

-- Workflow worker — listen() blocks, so it has to run on a spawned
-- coroutine or the HTTP server never boots. Non-fatal: if the engine is
-- unreachable the dashboard still serves; the new-run button surfaces
-- the failure.
async.spawn(function()
  local ok, err = pcall(workflow_registry.start, cfg)
  if not ok then
    log.error("workflow worker stopped: " .. tostring(err))
  end
end)

log.info(("gondor booting on :%d (lib_root=%s, engine=%s)")
  :format(PORT, LIB_ROOT, env.get("ENGINE_URL") or "<unset>"))
http.serve(PORT, routes)
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add scripts/main.lua
git -C /home/eda/code/gondor commit -m "feat(workflows): wire worker, fragments, SSE in main.lua"
```

---

## Phase 5 — Cleanup + smoke

### Task 15: Delete superseded files

**Files:**

- Delete: `/home/eda/code/gondor/scripts/skip_trace_worker.lua`
- Delete: `/home/eda/code/gondor/deploy/gondor-skip-trace-worker.service.example`

- [ ] **Step 1: Delete**

```bash
git -C /home/eda/code/gondor rm scripts/skip_trace_worker.lua
git -C /home/eda/code/gondor rm deploy/gondor-skip-trace-worker.service.example
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor commit -m "chore(workflows): remove standalone skip-trace worker (now embedded)"
```

### Task 16: Update README install steps

**Files:**

- Modify: `/home/eda/code/gondor/README.md`

- [ ] **Step 1: Drop the worker-service install line**

Find `sudo cp deploy/gondor-skip-trace-worker.service.example …` line in step 6 and remove
it (the worker is embedded in `gondor.service` now). Keep `gondor-engine.service`. Run dprint:

```bash
cd /home/eda/code/gondor && dprint fmt README.md
```

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/gondor add README.md
git -C /home/eda/code/gondor commit -m "docs(workflows): drop standalone worker from install steps"
```

### Task 17: Smoke test extension

**Files:**

- Modify: `/home/eda/code/gondor/tests-lua/smoke.test.lua`

- [ ] **Step 1: Add probes**

After the existing assertions, append:

```lua
-- Workflow runs UI smoke — server should respond 200 on the page +
-- fragments even when the engine is unreachable (the engine_client
-- catches HTTP failures and returns empty lists).
do
  local resp = http.request({ method = "GET",
    url = "http://127.0.0.1:" .. PORT .. "/skip-trace" })
  if resp.status ~= 200 then fail("/skip-trace -> " .. tostring(resp.status)) end
  ok("/skip-trace renders")
end

do
  local resp = http.request({ method = "GET",
    url = "http://127.0.0.1:" .. PORT .. "/api/skip-trace/active" })
  if resp.status ~= 200 then fail("/api/skip-trace/active -> " .. tostring(resp.status)) end
  ok("/api/skip-trace/active fragment renders")
end

do
  local resp = http.request({ method = "GET",
    url = "http://127.0.0.1:" .. PORT .. "/api/skip-trace/runs?page=1&per_page=10" })
  if resp.status ~= 200 then fail("/api/skip-trace/runs -> " .. tostring(resp.status)) end
  ok("/api/skip-trace/runs fragment renders")
end

do
  local resp = http.request({ method = "GET",
    url = "http://127.0.0.1:" .. PORT .. "/api/skip-trace/new" })
  if resp.status ~= 200 then fail("/api/skip-trace/new -> " .. tostring(resp.status)) end
  ok("/api/skip-trace/new modal renders")
end
```

- [ ] **Step 2: Run smoke**

```bash
cd /home/eda/code/gondor && \
  ASSAY_ROOT=$(realpath ../assay) ./tests-lua/dev-run.sh --smoke
```

Expected: every probe prints `✓ …` and exits 0.

- [ ] **Step 3: Commit**

```bash
git -C /home/eda/code/gondor add tests-lua/smoke.test.lua
git -C /home/eda/code/gondor commit -m "test(workflows): add probes for skip-trace runs UI"
```

---

## Phase 6 — Knowhere mirror

### Task 18: Copy framework to knowhere

**Files:**

- Create: `/home/eda/code/knowhere/services/workflows/{engine,client,steps,registry,history}.lua`
  (copy from gondor — only the registry's DEFINITIONS list will eventually diverge)
- Create: `/home/eda/code/knowhere/services/workflows/definitions/.gitkeep` (empty marker)
- Create: `/home/eda/code/knowhere/static/css/pipeline.css` (copy from gondor)
- Create: `/home/eda/code/knowhere/static/app.js` (copy from gondor)

- [ ] **Step 1: Copy**

```bash
mkdir -p /home/eda/code/knowhere/services/workflows/definitions \
         /home/eda/code/knowhere/static/css

for f in engine client steps registry history; do
  cp /home/eda/code/gondor/services/workflows/$f.lua \
     /home/eda/code/knowhere/services/workflows/$f.lua
done
touch /home/eda/code/knowhere/services/workflows/definitions/.gitkeep

cp /home/eda/code/gondor/static/css/pipeline.css /home/eda/code/knowhere/static/css/pipeline.css
cp /home/eda/code/gondor/static/app.js /home/eda/code/knowhere/static/app.js
```

- [ ] **Step 2: Strip the skip-trace require from knowhere's registry**

Edit `/home/eda/code/knowhere/services/workflows/registry.lua` and replace:

```lua
local DEFINITIONS = {
  "services.workflows.definitions.skip_trace",
}
```

with an empty table:

```lua
local DEFINITIONS = {}
```

(knowhere has no workflow types of its own yet; consumers add them by appending to this list.)

- [ ] **Step 3: Replace `GONDOR_ADMIN_API_KEYS` env name in knowhere's engine.lua**

Edit `/home/eda/code/knowhere/services/workflows/engine.lua`:

```
- local token = cfg.workflow_token or env.get("GONDOR_ADMIN_API_KEYS")
+ local token = cfg.workflow_token or env.get("KNOWHERE_ADMIN_API_KEYS")
```

- [ ] **Step 4: Commit**

```bash
git -C /home/eda/code/knowhere add services/workflows static/css/pipeline.css static/app.js
git -C /home/eda/code/knowhere commit -m "feat(workflows): mirror gondor's workflows framework"
```

### Task 19: knowhere main.lua wiring

**Files:**

- Modify: `/home/eda/code/knowhere/scripts/main.lua`

- [ ] **Step 1: Add the worker spawn + SSE endpoint**

Add (next to the existing sysops mount):

```lua
local workflow_client   = require("services.workflows.client")
local workflow_registry = require("services.workflows.registry")

local cfg = {
  workflow_url       = env.get("ENGINE_URL"),
  workflow_token     = env.get("KNOWHERE_ADMIN_API_KEYS"),
  workflow_namespace = env.get("WORKFLOW_NAMESPACE") or "main",
}

local state_revision = 1
local function bump_revision() state_revision = state_revision + 1 end

pcall(workflow_client.init, bump_revision, cfg)
async.spawn(function()
  local ok, err = pcall(workflow_registry.start, cfg)
  if not ok then log.error("workflow worker stopped: " .. tostring(err)) end
end)

routes.GET["/static/css/pipeline.css"] = static_file("static/css/pipeline.css", "text/css", 60)
routes.GET["/static/app.js"]           = static_file("static/app.js", "text/javascript", 60)

routes.GET["/api/events"] = function(_req)
  return {
    status  = 200,
    headers = { ["Content-Type"] = "text/event-stream",
                ["Cache-Control"] = "no-cache" },
    sse = function(send)
      send({ event = "refresh", data = tostring(state_revision) })
      local last_seen = state_revision
      while true do
        time.sleep(1)
        if state_revision ~= last_seen then
          last_seen = state_revision
          send({ event = "refresh", data = tostring(last_seen) })
        end
      end
    end,
  }
end
```

(Also add a `static_file` local helper if knowhere's main.lua doesn't already have one;
copy from gondor.)

- [ ] **Step 2: Commit**

```bash
git -C /home/eda/code/knowhere add scripts/main.lua
git -C /home/eda/code/knowhere commit -m "feat(workflows): wire framework + SSE in main.lua"
```

---

## Self-review

- [ ] Spec coverage: every row in the "File deltas" table maps to a task above.
- [ ] No placeholders: `grep -nE "TODO|TBD|implement later|fill in" .claude/plans/02-workflows-ui.md` should return nothing.
- [ ] Type consistency: `def.meta.type` (= `"fcar.skip-trace"`) is the same string used by handler
      registration, `client.list_active(def.meta.type)`, `client.rehydrate(def.meta.type)`, and the
      engine SPA filter `?type=fcar.skip-trace` — verified.
- [ ] Class names: `.pipeline-*` everywhere; no `.workflow-*` slipped in.
- [ ] Per-page options match gitops `{5, 10, 25, 50}` default 10.

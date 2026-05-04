--! services/workflows/client.lua — gondor-facing client over the assay
--! workflow engine. list_active / list_recent / start / describe /
--! get_state, with a small in-memory cache and rehydrate-on-boot so the
--! Recent table has content immediately after a pod restart.
--!
--! Wraps the lower-level `assay.engine.workflow.client` returned by
--! services/workflows/engine.lua. All HTTP calls are pcall'd so a
--! transient engine outage doesn't crash the dashboard request.

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
  local got, c = pcall(engine.client)
  if not got then return nil end
  local ok, snapshot = pcall(c.get_state, c, wf_id, "pipeline_state")
  if not ok or type(snapshot) ~= "table" then return nil end
  local state = snapshot.value or snapshot
  if type(state) ~= "table" then return nil end
  state.id = wf_id
  return state
end

-- (workflow_type, status) → array of pipeline_state tables.
local function list_states(workflow_type, status, limit)
  local got, c = pcall(engine.client)
  if not got then return {} end
  local ok, runs = pcall(c.list, c, {
    namespace = engine.namespace(),
    type      = workflow_type,
    status    = status,
    limit     = limit or 50,
  })
  if not ok or type(runs) ~= "table" then return {} end
  local out = {}
  for _, r in ipairs(runs) do
    local state = get_pipeline_state(r.id) or {}
    state.id            = r.id
    state.engine_status = r.status
    state.created_at    = r.created_at
    state.completed_at  = r.completed_at
    out[#out + 1] = state
  end
  return out
end

function M.list_active(workflow_type)
  return list_states(workflow_type, "RUNNING", 50)
end

-- Page a slice of recent terminal runs. Hits the engine on every call
-- (cheaper than maintaining a write-through cache and skip-trace
-- volume doesn't need one). Returns (rows, total, clamped_page,
-- clamped_per_page) — same tuple as history.page so pages/skip_trace.lua
-- doesn't care which backend supplies the data.
function M.list_recent(workflow_type, page, per_page)
  page = tonumber(page) or 1
  per_page = tonumber(per_page) or 10
  if page < 1 then page = 1 end
  if per_page < 1 then per_page = 10 end
  if per_page > 100 then per_page = 100 end

  local entries = {}
  for _, status in ipairs({ "COMPLETED", "FAILED", "CANCELLED" }) do
    for _, state in ipairs(list_states(workflow_type, status, 200)) do
      -- Skip runs without a pipeline_state snapshot — they're either
      -- pre-snapshot (legacy) or terminated before the handler started.
      -- Showing "? (?)" rows in the table is just noise.
      if type(state.steps) == "table" and #state.steps > 0 then
        if status == "COMPLETED" then state.status = "done"
        elseif status == "FAILED" then state.status = "failed"
        elseif status == "CANCELLED" then state.status = "cancelled" end
        entries[#entries + 1] = state
      end
    end
  end
  table.sort(entries, function(a, b)
    return (a.created_at or 0) > (b.created_at or 0)
  end)

  local total = #entries
  local first = (page - 1) * per_page + 1
  local last  = math.min(first + per_page - 1, total)
  local out   = {}
  for i = first, last do out[#out + 1] = entries[i] end
  return out, total, page, per_page
end

function M.describe(wf_id)
  local got, c = pcall(engine.client)
  if not got then return nil end
  local ok, info = pcall(c.describe, c, wf_id)
  if not ok or type(info) ~= "table" then return nil end
  return info
end

function M.get_state(wf_id)
  return get_pipeline_state(wf_id)
end

-- ── writes ────────────────────────────────────────────────────────────

-- Start a workflow on the engine. Returns (id, nil) on success or
-- (nil, error_msg) on failure.
function M.start(opts)
  local got, c = pcall(engine.client)
  if not got then return nil, "engine not connected" end
  local ok, err = pcall(c.start, c, {
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
      -- Skip runs without a pipeline_state snapshot — they're either
      -- pre-snapshot (legacy) or terminated before the handler started.
      -- Showing "? (?)" rows in the table is just noise.
      if type(state.steps) == "table" and #state.steps > 0 then
        if status == "COMPLETED" then state.status = "done"
        elseif status == "FAILED" then state.status = "failed"
        elseif status == "CANCELLED" then state.status = "cancelled" end
        entries[#entries + 1] = state
      end
    end
  end
  table.sort(entries, function(a, b)
    return (a.created_at or 0) > (b.created_at or 0)
  end)
  history.replace(entries)
  log.info("workflow history rehydrated: " .. tostring(#entries) .. " runs")
end

return M

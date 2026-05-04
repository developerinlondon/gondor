--! services/workflows/steps.lua — step-state helper used by workflow
--! handlers. Wraps the canonical pipeline_state schema (status,
--! current_step, steps[], log[]) so each handler doesn't reinvent it.
--!
--! Returns a controller object with methods (enter / exit / fail / done)
--! and a `.data` field holding the JSON-serialisable state. The handler
--! registers `pipeline_state` against `controller.data` so the worker's
--! auto-snapshot doesn't try to serialise the method closures —
--! assay's lua_table_to_json fails on function values.

local M = {}

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function clock_str()
  return os.date("!%H:%M:%S")
end

-- Build a fresh pipeline_state for a run. `step_names` is an ordered
-- list of human-readable step names (rendered as labels on the badges).
function M.new(step_names)
  local data = {
    status       = "running",
    current_step = 1,
    steps        = {},
    log          = {},
  }
  for i, name in ipairs(step_names) do
    data.steps[i] = {
      name         = name,
      status       = i == 1 and "running" or "waiting",
      started_at   = i == 1 and now_iso() or nil,
      completed_at = nil,
    }
  end

  local self = { data = data }

  function self:_log(msg, step)
    data.log[#data.log + 1] = {
      time = clock_str(),
      msg  = msg,
      step = step or data.current_step,
    }
  end

  function self:enter(i)
    data.current_step = i
    if data.steps[i] then
      data.steps[i].status     = "running"
      data.steps[i].started_at = now_iso()
    end
    self:_log("Starting " .. (data.steps[i] and data.steps[i].name or "?"), i)
  end

  function self:exit(i)
    if data.steps[i] then
      data.steps[i].status       = "done"
      data.steps[i].completed_at = now_iso()
    end
    self:_log((data.steps[i] and data.steps[i].name or "?") .. " complete", i)
  end

  function self:fail(msg, step)
    local i = step or data.current_step
    if data.steps[i] then
      data.steps[i].status       = "failed"
      data.steps[i].completed_at = now_iso()
    end
    data.status = "failed"
    self:_log("FAILED: " .. tostring(msg), i)
  end

  function self:done()
    data.status = "done"
    self:_log("Run complete")
  end

  return self
end

return M

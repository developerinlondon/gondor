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

  step_names = { "Validate", "Lookup", "Score", "Persist", "Notify" },
}

-- `c` is the assay.engine.workflow client object. Worker mode reads
-- handlers + activities off it via :register_workflow / :register_activity.
function M.register(c, _cfg)
  c:register_workflow(M.meta.type, function(ctx, input)
    input = input or {}
    local state = steps_helper.new(M.meta.step_names)

    -- Surface headline fields on the state's data table so the runs UI
    -- can read them via pipeline_state. We register the data table (not
    -- the controller) so the worker's RecordSnapshot doesn't try to
    -- JSON-encode the method closures.
    state.data.subject_name = input.name
    state.data.state_code   = input.state
    state.data.case_number  = input.case_number
    state.data.requested_by = input.requested_by

    ctx:register_query("pipeline_state", function() return state.data end)

    -- Step 1: Validate
    state:enter(1)
    if not input.name or input.name == "" then
      state:fail("subject name is required", 1)
      error("subject name is required", 0)
    end
    state:exit(1)

    -- Step 2: Lookup
    state:enter(2)
    local lookup = ctx:execute_activity("lookup", {
      name        = input.name,
      state       = input.state,
      case_number = input.case_number,
    })
    state:exit(2)

    -- Step 3: Score
    state:enter(3)
    local score = ctx:execute_activity("score", { lookup = lookup })
    state:exit(3)

    -- Step 4: Persist (audit-only today)
    state:enter(4)
    ctx:execute_activity("persist", {
      input  = input,
      lookup = lookup,
      score  = score,
    })
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
      address     = lookup.address,
    }
  end)

  c:register_activity("lookup", function(_ctx, input)
    local res = tracer.trace({
      name        = input.name,
      state       = input.state,
      case_number = input.case_number,
    })
    return {
      phone   = res.phone,
      email   = res.email,
      address = res.address,
      sources = res.sources,
    }
  end)

  c:register_activity("score", function(_ctx, input)
    -- Confidence: present-fields-out-of-3 → percentage in [70, 99].
    local present = 0
    if input.lookup.phone   and input.lookup.phone   ~= "" then present = present + 1 end
    if input.lookup.email   and input.lookup.email   ~= "" then present = present + 1 end
    if input.lookup.address and input.lookup.address ~= "" then present = present + 1 end
    return { confidence = math.min(99, 70 + present * 10) }
  end)

  c:register_activity("persist", function(_ctx, _input)
    -- Audit-only today; gondor's services.audit handler logs the
    -- skip_trace.run from the page handler. Future: write to a
    -- dedicated traces table.
    return { stored = true }
  end)

  c:register_activity("notify", function(_ctx, _input)
    return { sent = false, reason = "stub" }
  end)
end

return M

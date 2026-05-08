--! services/workflows/definitions/skip_trace.lua — fcar.skip-trace
--! workflow definition.
--!
--! Step ladder:
--!   1. Validate    — sanity-check input
--!   2. Lookup      — Tier-2 free skip-trace; routed to the Python
--!                    worker on queue "skip-trace-tier2" which runs
--!                    FCAR's actual free_skip_trace.py against
--!                    TruePeopleSearch / FastPeopleSearch / Google /
--!                    Whitepages / 411.com.
--!   3. Score       — confidence calculation
--!   4. Persist     — write the row (audit-only today)
--!   5. Notify      — placeholder for downstream notify (no-op)
--!
--! Registers `pipeline_state` query so both the engine SPA's Steps tab
--! AND gondor's own runs table render the same data.

local steps_helper = require("services.workflows.steps")

local M = {}

M.TIER2_QUEUE = "skip-trace-tier2"

M.meta = {
  type         = "fcar.skip-trace",
  display_name = "Skip trace",
  route        = "/skip-trace",
  task_queue   = "default",
  description  = "Trace contact info from name + state + case ID",

  step_names = { "Validate", "Lookup", "Score", "Persist", "Notify" },
}

function M.register(c, _cfg)
  c:register_workflow(M.meta.type, function(ctx, input)
    input = input or {}
    local state = steps_helper.new(M.meta.step_names)

    state.data.subject_name = input.name
    state.data.state_code   = input.state
    state.data.city         = input.city
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

    -- Step 2: Lookup — claimed by the Python tier-2 worker.
    state:enter(2)
    local lookup = ctx:execute_activity("lookup_t2", {
      name        = input.name,
      state       = input.state,
      city        = input.city,
      case_number = input.case_number,
    }, {
      task_queue             = M.TIER2_QUEUE,
      start_to_close_secs    = 60,
      heartbeat_timeout_secs = 30,
      max_attempts           = 2,
    })
    -- Surface the lookup result on pipeline_state so the runs UI can
    -- render contact info next to each row.
    state.data.phone      = lookup.phone or ""
    state.data.email      = lookup.email or ""
    state.data.address    = lookup.address or ""
    state.data.phones     = lookup.phones or {}
    state.data.emails     = lookup.emails or {}
    state.data.addresses  = lookup.addresses or {}
    state.data.sources    = lookup.sources or {}
    state.data.lookup_confidence = tonumber(lookup.confidence) or 0
    state.data.found = (state.data.phone ~= "")
                   or (state.data.email ~= "")
                   or (state.data.address ~= "")
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
      city        = input.city,
      case_number = input.case_number,
      confidence  = score.confidence,
      phone       = lookup.phone,
      email       = lookup.email,
      address     = lookup.address,
      sources     = lookup.sources,
    }
  end)

  -- Note: the "lookup_t2" activity is intentionally NOT registered here.
  -- It is claimed by the Python worker (plugins/skip-trace-tier2/worker.py)
  -- subscribed to queue "skip-trace-tier2".

  c:register_activity("score", function(_ctx, input)
    local present = 0
    if input.lookup.phone   and input.lookup.phone   ~= "" then present = present + 1 end
    if input.lookup.email   and input.lookup.email   ~= "" then present = present + 1 end
    if input.lookup.address and input.lookup.address ~= "" then present = present + 1 end
    local engine_conf = tonumber(input.lookup.confidence) or 0
    local heuristic   = math.min(99, 70 + present * 10)
    return { confidence = math.max(heuristic, math.floor(engine_conf * 100)) }
  end)

  c:register_activity("persist", function(_ctx, _input)
    return { stored = true }
  end)

  c:register_activity("notify", function(_ctx, _input)
    return { sent = false, reason = "stub" }
  end)
end

return M

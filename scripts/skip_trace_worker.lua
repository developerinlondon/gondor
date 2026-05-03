--! skip_trace_worker.lua — fcar.skip-trace worker.
--!
--! Claims runs from the default queue and promotes them to COMPLETED.
--! pages/skip_trace.lua already runs the deterministic mock and bakes
--! the result into the workflow's input field, so the worker just
--! promotes that data through. Future iteration: move the mock here
--! and have the page handler enqueue with operator input only.
--!
--! Run via:
--!   ASSAY_ENGINE_URL=http://127.0.0.1:8080 \
--!   ASSAY_ADMIN_KEY=$GONDOR_ADMIN_API_KEYS \
--!   assay run scripts/skip_trace_worker.lua
--!
--! Or via the systemd unit at deploy/gondor-skip-trace-worker.service.example.

local workflow = require("assay.engine.workflow")

local c = workflow.client({
  engine_url = env.get("ASSAY_ENGINE_URL") or "http://127.0.0.1:8080",
  api_key    = env.get("ASSAY_ADMIN_KEY"),
})

c:register_workflow("fcar.skip-trace", function(ctx, input)
  log.info("fcar.skip-trace: claimed run, name=" .. tostring(input.name or "?"))
  return {
    name             = input.name,
    state            = input.state,
    case_number      = input.case_number,
    probable_address = input.probable_address,
    phone            = input.phone,
    email            = input.email,
    confidence       = input.confidence,
    completed_by     = "fcar.skip-trace worker (gondor)",
  }
end)

log.info("fcar.skip-trace worker ready, listening on queue=default")
c:listen({ queue = "default", namespace = "main" })

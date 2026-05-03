--! pages/skip_trace.lua — Skip Trace page handler.
--!
--! Mounted at GET /skip-trace by scripts/main.lua. Records each finished
--! trace as a workflow run on the engine sidecar so it appears in the
--! engine SPA's /workflow/ list. The work is purely synchronous (the
--! mock tracer runs in the request thread); creating the workflow is
--! audit-only. A worker (scripts/skip_trace_worker.lua) claims runs from
--! the default queue and promotes them to COMPLETED.

local hctx   = require("hostops.ctx")
local render = require("hostops.pages.render")

local M = {}

-- Engine HTTP client, tracer, and the gondor app's own templates dir
-- are injected at mount time so this module doesn't reach for top-level
-- globals or hard-code paths.
local engine, tracer, template_dir

function M.configure(deps)
  engine       = deps.engine
  tracer       = deps.tracer
  template_dir = deps.template_dir
end

local function render_skip_trace(ctx, req)
  -- Templates live in gondor's own templates/ dir, not hostops's
  -- lib_root/templates. Use render_with_loader directly so {% include %}
  -- can resolve relative to gondor's tree, then wrap the rendered HTML
  -- with hostops's layout for the sidebar + brand chrome.
  ctx.nav_active = ctx.nav_active or "skip_trace"
  local ok, content = pcall(template.render_with_loader,
                            template_dir, "skip_trace.html", ctx)
  if not ok then
    content = "<pre>render error: " .. tostring(content) .. "</pre>"
  end
  return render.wrap_layout(content, ctx, req)
end

local function record_run(input, result)
  if not engine or not engine.api_call then return nil end
  local slug = (input.name or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then slug = "trace" end
  local wf_id = slug .. "-" .. tostring(os.time())

  local body = {
    workflow_type = "fcar.skip-trace",
    workflow_id   = wf_id,
    namespace     = "main",
    task_queue    = "default",
    input = {
      name             = input.name,
      state            = input.state,
      case_number      = input.case_number,
      probable_address = result.address,
      phone            = result.phone,
      email            = result.email,
      confidence       = result.confidence,
    },
  }
  local ok, resp = pcall(engine.api_call, "POST",
                         "/api/v1/engine/workflow/workflows", body)
  if not ok or type(resp) ~= "table" then return nil end
  local status = resp.status or 0
  if status == 0 or status >= 400 then return nil end
  if type(resp.body) == "table" and resp.body.workflow_id then
    return resp.body.workflow_id
  end
  return wf_id
end

function M.page(req)
  local q = (req and req.params) or {}
  local result, workflow_id = nil, nil
  if q.name and q.name ~= "" then
    local input = {
      name        = q.name,
      state       = q.state or "OH",
      case_number = q.case_number or "",
    }
    result      = tracer and tracer.trace(input) or nil
    if result then
      workflow_id = record_run(input, result)
      if hctx.audit and hctx.audit.append then
        hctx.audit.append({
          actor  = render.actor_from(req),
          action = "skip_trace.run",
          target = input.name,
          result = workflow_id and "ok" or "ok-no-engine",
          ip     = (req and req.headers and (req.headers["cf-connecting-ip"]
                    or req.headers["x-forwarded-for"])) or "",
        })
      end
    end
  end
  return render_skip_trace({
    nav_active  = "skip_trace",
    page_title  = "Skip Trace",
    query       = q,
    result      = result,
    workflow_id = workflow_id,
  }, req)
end

return M

--! pages/skip_trace.lua — Skip Trace runs page + HTMX fragments.
--!
--! Routes mounted by scripts/main.lua:
--!   GET  /skip-trace                — page shell (active + recent)
--!   GET  /api/skip-trace/active     — active-runs fragment
--!   GET  /api/skip-trace/runs       — recent-runs fragment (paginated)
--!   GET  /api/skip-trace/new        — new-run modal
--!   POST /skip-trace/run            — start a run, fires dashboard-refresh

local hctx   = require("hostops.ctx")
local render = require("hostops.pages.render")

local brand   = require("services.brand")
local client  = require("services.workflows.client")
local history = require("services.workflows.history")
local def     = require("services.workflows.definitions.skip_trace")

local M = {}

local audit, template_dir, engine_base_url

function M.configure(deps)
  audit           = deps.audit
  template_dir    = deps.template_dir
  engine_base_url = deps.engine_base_url or ""
end

local function render_fragment(name, ctx)
  ctx = ctx or {}
  local ok, body = pcall(template.render_with_loader, template_dir,
                         name .. ".html", ctx)
  if not ok then
    body = "<pre>render error: " .. tostring(body) .. "</pre>"
  end
  return {
    status  = 200,
    body    = body,
    headers = { ["Content-Type"] = "text/html; charset=utf-8" },
  }
end

local function relative_time(unix_ts)
  if not unix_ts then return "-" end
  local diff = os.time() - tonumber(unix_ts)
  if not diff or diff < 0 then return "-" end
  if diff < 60 then return string.format("%.1fs ago", diff) end
  if diff < 3600 then return math.floor(diff / 60) .. "m ago" end
  if diff < 86400 then return math.floor(diff / 3600) .. "h ago" end
  return math.floor(diff / 86400) .. "d ago"
end

-- Format an elapsed-millisecond count into a compact label. Apex's
-- Executions table uses the same shape: `42 ms`, `3.4 s`, `4m 21s`,
-- `1h 2m`. Anything under 1s reads as integer milliseconds; under 60s
-- as one decimal of seconds; anything longer as discrete units.
local function format_duration_ms(ms)
  if not ms or ms <= 0 then return "-" end
  if ms < 1000 then return string.format("%d ms", math.floor(ms)) end
  if ms < 60 * 1000 then return string.format("%.1f s", ms / 1000) end
  if ms < 3600 * 1000 then
    local m = math.floor(ms / 60000)
    local s = math.floor((ms % 60000) / 1000)
    return string.format("%dm %ds", m, s)
  end
  local h = math.floor(ms / 3600000)
  local m = math.floor((ms % 3600000) / 60000)
  return string.format("%dh %dm", h, m)
end

-- Build apex-style "Live Progress" text for a run. Returns:
--   { label = "Score · 3/5", pct = 60, current = "Score" }
-- on a running run; appropriate variants for done / failed / cancelled.
-- Scales to any step count (the ladder doesn't past ~6 steps).
local function progress_for(run)
  local steps = (run and run.steps) or {}
  local total = #steps
  if total == 0 then
    return { label = "—", pct = 0, current = nil }
  end
  local done, failed_name = 0, nil
  for _, s in ipairs(steps) do
    if s.status == "done" then done = done + 1
    elseif s.status == "failed" then failed_name = s.name end
  end
  local pct = math.floor(done / total * 100)
  local status = run.status or "running"
  if status == "done" then
    return { label = string.format("%d/%d complete", total, total), pct = 100 }
  elseif status == "failed" then
    return {
      label = string.format("Failed at %s · %d/%d", failed_name or "?", done, total),
      pct = pct,
    }
  elseif status == "cancelled" then
    return { label = string.format("Cancelled · %d/%d", done, total), pct = pct }
  else
    local cur_idx = run.current_step or (done + 1)
    local cur_name = (steps[cur_idx] and steps[cur_idx].name) or "?"
    return {
      label = string.format("%s · %d/%d", cur_name, done, total),
      pct = pct,
      current = cur_name,
    }
  end
end

local function enrich(run)
  run.started_ago = relative_time(run.created_at)

  -- Duration: completed - started for terminal runs, now - started for
  -- still-running. Multiplied to ms so it can sort numerically and read
  -- via format_duration_ms.
  local started = tonumber(run.created_at)
  local ended   = tonumber(run.completed_at) or os.time()
  if started and ended >= started then
    run.duration_ms    = math.floor((ended - started) * 1000)
    run.duration_label = format_duration_ms(run.duration_ms)
  else
    run.duration_ms    = 0
    run.duration_label = "-"
  end

  local p = progress_for(run)
  run.progress_label = p.label
  run.progress_pct   = p.pct

  return run
end

-- ── fragments ────────────────────────────────────────────────────────

function M.active_fragment(_req)
  local active = client.list_active(def.meta.type)
  for _, r in ipairs(active) do enrich(r) end
  return render_fragment("skip_trace_active", {
    active     = active,
    nav_active = "skip_trace",
  })
end

function M.runs_fragment(req)
  local q = (req and req.params) or {}
  local page = tonumber(q.page) or 1
  local per_page = tonumber(q.per_page) or 10
  local rows, total, clamped_page, clamped_per_page =
    client.list_recent(def.meta.type, page, per_page)
  for _, r in ipairs(rows) do enrich(r) end
  local total_pages = math.max(1, math.ceil(total / clamped_per_page))
  local first = total == 0 and 0 or (clamped_page - 1) * clamped_per_page + 1
  local last  = math.min(first + #rows - 1, total)
  return render_fragment("skip_trace_runs", {
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
    engine_base_url  = engine_base_url,
  })
end

function M.new_fragment(_req)
  return render_fragment("skip_trace_new", {})
end

-- ── page shell ───────────────────────────────────────────────────────

function M.page(req)
  local active_resp = M.active_fragment(req)
  local runs_resp   = M.runs_fragment(req)
  local ctx = {
    page_title      = "Skip trace",
    nav_active      = "skip_trace",
    engine_base_url = engine_base_url,
    active_html     = active_resp.body,
    runs_html       = runs_resp.body,
    workflows_label = brand.snapshot().workflows_label,
  }
  local ok, content = pcall(template.render_with_loader, template_dir,
                            "skip_trace.html", ctx)
  if not ok then
    content = "<pre>render error: " .. tostring(content) .. "</pre>"
  end
  return render.wrap_layout(content, ctx, req)
end

-- ── submit ───────────────────────────────────────────────────────────

local function form_value(body, name)
  if not body then return nil end
  for k, v in tostring(body):gmatch("([^&=]+)=([^&]*)") do
    if k == name then
      v = v:gsub("%+", " ")
      v = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
      return v
    end
  end
end

function M.submit(req)
  local body = (req and req.body) or ""
  local name        = form_value(body, "name")
  local state_code  = form_value(body, "state")
  local case_number = form_value(body, "case_number")

  if not name or name == "" then
    return { status = 400, body = "name is required" }
  end

  local actor = render.actor_from(req)
  -- Unique workflow id: epoch + random hex so two POSTs in the same
  -- second don't collide and trip the engine's duplicate-id reject.
  local wf_id = string.format("trace-%d-%04x", os.time(), math.random(0, 0xffff))
  local _, err = client.start({
    workflow_type = def.meta.type,
    workflow_id   = wf_id,
    task_queue    = def.meta.task_queue,
    input = {
      name         = name,
      state        = state_code,
      case_number  = case_number,
      requested_by = actor,
    },
  })
  if err then
    return { status = 502, body = "engine: " .. err }
  end

  if audit and audit.append then
    pcall(audit.append, {
      actor  = actor,
      action = "skip_trace.run",
      target = "workflow:" .. wf_id,
      result = "ok",
      ip     = (req and req.headers and (req.headers["cf-connecting-ip"]
                or req.headers["x-forwarded-for"])) or "",
    })
  end

  -- HX-Trigger fires hx-trigger="dashboard-refresh from:body" on the
  -- active + recent slot divs, which re-fetch their fragments. The
  -- form's hx-on::after-request="closeWorkflowDialog()" closes the modal.
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

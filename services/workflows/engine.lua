--! services/workflows/engine.lua — single integration boundary with the
--! assay workflow engine. Every other file under services/workflows/
--! goes through this module so the `require("assay.engine.workflow")`
--! dependency and auth-token wiring lives in exactly one place.
--!
--! Returns a configured `client` object (see assay.engine.workflow.client)
--! exposing :start / :list / :describe / :get_state / :register_workflow /
--! :register_activity / :listen.

local workflow = require("assay.engine.workflow")

local M = {}

local _client    = nil
local _namespace = nil

-- Build the client. Idempotent — safe to call from both the worker
-- startup path and the request-handling path.
function M.connect(cfg)
  if _client then return _client end
  cfg = cfg or {}
  local url = cfg.workflow_url or env.get("ENGINE_URL") or "http://127.0.0.1:8082"
  local key = cfg.workflow_token or env.get("GONDOR_ADMIN_API_KEYS")
                                   or env.get("ASSAY_ADMIN_KEY")
  _client    = workflow.client({ engine_url = url, api_key = key })
  _namespace = cfg.workflow_namespace or "main"
  log.info("workflow engine connected: " .. url
        .. " (namespace=" .. _namespace .. ")")
  return _client
end

-- Return the connected client. Errors loudly if connect hasn't run yet
-- so caller-order bugs surface immediately.
function M.client()
  if not _client then
    error("services.workflows.engine: call engine.connect(cfg) first")
  end
  return _client
end

-- Engine-level namespace this gondor instance operates in. Threaded
-- through every :start / :list call so workflow state is partitioned
-- inside the same logical bucket.
function M.namespace()
  return _namespace or "main"
end

return M

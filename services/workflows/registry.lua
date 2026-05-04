--! services/workflows/registry.lua — workflow worker entrypoint.
--! Iterates the DEFINITIONS list, asks each module to register its
--! handlers + activities on the shared client, and blocks on
--! client:listen({queue, namespace}). Adding a new workflow type =
--! add the module name to this list.
--!
--! Note: client:listen({queue, namespace}) BLOCKS indefinitely. Caller
--! must spawn this on a background coroutine (async.spawn) so the HTTP
--! server keeps serving.

local engine = require("services.workflows.engine")

local M = {}

M.TASK_QUEUE = "default"

local DEFINITIONS = {
  "services.workflows.definitions.skip_trace",
}

function M.start(cfg)
  local c = engine.connect(cfg)
  for _, mod in ipairs(DEFINITIONS) do
    local def = require(mod)
    if def.register then def.register(c, cfg) end
    log.info("registered workflow definition: " .. mod
          .. " (type=" .. (def.meta and def.meta.type or "?") .. ")")
  end
  local ns = engine.namespace()
  log.info("workflow worker starting on queue '" .. M.TASK_QUEUE
        .. "' namespace '" .. ns .. "'")
  c:listen({ queue = M.TASK_QUEUE, namespace = ns })
end

return M

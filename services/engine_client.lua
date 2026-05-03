--! engine_client.lua — HTTP wrapper for the assay-engine sidecar.
--!
--! Returns a module with `get/post/put/delete` and an `api_call(method,
--! path, body)` shim. Build via `engine_client.new(url)` so consumers
--! can inject a custom URL or stub.
--!
--! All calls log on non-2xx for ops visibility but return the raw
--! response so callers can decide what to do with errors.

local M = {}

local function build(base_url, admin_key)
  local self = { url = base_url }

  local function full(path)
    if not path or path == "" then return base_url end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return base_url .. path
  end

  local function call(method, path, body)
    local opts = { method = method, url = full(path), headers = {} }
    if admin_key and admin_key ~= "" then
      opts.headers["Authorization"] = "Bearer " .. admin_key
    end
    if body ~= nil then
      opts.headers["Content-Type"] = "application/json"
      opts.body = (type(body) == "string") and body or json.encode(body)
    end
    local ok, resp = pcall(http.request, opts)
    if not ok then
      log.warn(("engine %s %s failed: %s"):format(method, path, tostring(resp)))
      return { status = 0, body = nil, error = tostring(resp) }
    end
    if resp.status and resp.status >= 400 then
      log.warn(("engine %s %s -> %d"):format(method, path, resp.status))
    end
    local ct = resp.headers and (resp.headers["content-type"] or resp.headers["Content-Type"])
    if ct and ct:find("application/json", 1, true) and type(resp.body) == "string"
       and resp.body ~= "" then
      local p_ok, parsed = pcall(json.parse, resp.body)
      if p_ok then resp.body = parsed end
    end
    return resp
  end

  function self.get(path)         return call("GET",    path)       end
  function self.post(path, body)  return call("POST",   path, body) end
  function self.put(path, body)   return call("PUT",    path, body) end
  function self.delete(path)      return call("DELETE", path)       end
  function self.api_call(m, p, b) return call(m,        p,    b)    end

  return self
end

function M.new(base_url, admin_key)
  base_url  = base_url  or env.get("ENGINE_URL") or "http://127.0.0.1:8080"
  admin_key = admin_key or env.get("GONDOR_ADMIN_API_KEYS") or env.get("ENGINE_ADMIN_KEY")
  return build(base_url, admin_key)
end

return M

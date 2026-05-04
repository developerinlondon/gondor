--! brand.lua — brand-pack reader.
--!
--! Reads from ${BRAND_DIR:-./brand}/brand.json on every snapshot() call
--! (cheap, and lets operators edit and refresh without restart). Unset
--! fields fall back to neutral defaults.

local M = {}

local BRAND_DIR = env.get("BRAND_DIR") or "./brand"

local DEFAULTS = {
  name             = "Gondor",
  subtitle         = "FCAR · host operations",
  title            = "Gondor",
  accent_hex       = "#407040",
  favicon_url      = "/static/img/favicon.svg",
  workflows_label  = "Workflows",
}

function M.snapshot()
  local path = BRAND_DIR .. "/brand.json"
  if not fs.exists(path) then return DEFAULTS end
  local r_ok, body = pcall(fs.read, path)
  if not r_ok or not body or body == "" then return DEFAULTS end
  local ok, decoded = pcall(json.parse, body)
  if not ok or type(decoded) ~= "table" then
    log.warn("brand.snapshot: failed to parse brand.json: " .. tostring(decoded))
    return DEFAULTS
  end
  local out = {}
  for k, v in pairs(DEFAULTS) do out[k] = decoded[k] or v end
  return out
end

function M.dir() return BRAND_DIR end

return M

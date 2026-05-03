--! secret_store.lua — secrets accessor.
--!
--! Lookup order:
--!   1. assay-engine vault HTTP (ENGINE_URL/v1/vault/<scope>/<key>)
--!   2. rustic-style flat file at /etc/rustic/<scope>.<key>
--!      (the rustic CLI itself reads these files at backup time)
--!   3. local JSON file at ${SECRET_FILE:-/etc/gondor/secrets.json}
--!
--! v0.1 is read-only by design; write/delete are no-ops with a warn.

local M = {}

local SECRET_FILE       = env.get("SECRET_FILE") or "/etc/gondor/secrets.json"
local RUSTIC_PROFILE_DIR = env.get("BACKUP_PROFILE_DIR") or "/etc/rustic"
local ENGINE_URL        = env.get("ENGINE_URL")

local RUSTIC_KEYS = { password = true, access_key_id = true, secret_access_key = true }

local function load_file()
  if not fs.exists(SECRET_FILE) then return {} end
  local r_ok, body = pcall(fs.read, SECRET_FILE)
  if not r_ok or not body or body == "" then return {} end
  local ok, decoded = pcall(json.parse, body)
  if ok and type(decoded) == "table" then return decoded end
  log.warn("secret_store: failed to parse " .. SECRET_FILE)
  return {}
end

local function read_engine(scope, key)
  if not ENGINE_URL then return nil end
  local url = ENGINE_URL .. "/v1/vault/" .. scope .. "/" .. key
  local ok, resp = pcall(http.get, url)
  if not ok or type(resp) ~= "table" then return nil end
  if resp.status ~= 200 then return nil end
  local d_ok, decoded = pcall(json.parse, resp.body)
  if not d_ok or type(decoded) ~= "table" then return nil end
  return decoded.value or decoded.data or decoded
end

local function read_rustic_file(scope, key)
  if not RUSTIC_KEYS[key] then return nil end
  local path = RUSTIC_PROFILE_DIR .. "/" .. scope .. "." .. key
  if not fs.exists(path) then return nil end
  local r_ok, body = pcall(fs.read, path)
  if not r_ok or not body or body == "" then return nil end
  return (body:gsub("[\r\n]+$", ""))
end

function M.read(scope, key)
  local v = read_engine(scope, key)
  if v ~= nil then return v end
  v = read_rustic_file(scope, key)
  if v ~= nil then return v end
  local store = load_file()
  return (store[scope] and store[scope][key]) or nil
end

function M.write(_scope, _key, _value)
  log.warn("secret_store.write: read-only in v0.1 (no-op)")
  return false
end

function M.delete(_scope, _key)
  log.warn("secret_store.delete: read-only in v0.1 (no-op)")
  return false
end

function M.available() return true end

return M

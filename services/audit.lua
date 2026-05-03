--! audit.lua — flat-file audit log with size-based rotation.
--!
--! Writes one JSON entry per line to ${AUDIT_PATH:-/var/lib/gondor/audit.log}.
--! Rotates to .1 when the file exceeds AUDIT_MAX_BYTES (default 4 MiB).
--! `recent(n)` reads from the tail; `export()` returns the whole file.

local M = {}

local PATH      = env.get("AUDIT_PATH")      or "/var/lib/gondor/audit.log"
local MAX_BYTES = tonumber(env.get("AUDIT_MAX_BYTES") or "4194304")

local function ensure_dir()
  local dir = PATH:match("^(.*)/[^/]+$")
  if dir and dir ~= "" and not fs.exists(dir) then
    pcall(fs.mkdir, dir)
  end
end

local function maybe_rotate()
  if not fs.exists(PATH) then return end
  local s_ok, stat = pcall(fs.stat, PATH)
  if not s_ok or not stat then return end
  if (stat.size or 0) > MAX_BYTES then
    pcall(fs.rename, PATH, PATH .. ".1")
  end
end

local function read_text(path)
  if not fs.exists(path) then return "" end
  local ok, body = pcall(fs.read, path)
  if not ok or not body then return "" end
  return body
end

function M.append(entry)
  entry = entry or {}
  entry.ts = entry.ts or os.time()
  ensure_dir()
  maybe_rotate()
  local existing = read_text(PATH)
  local line = json.encode(entry) .. "\n"
  pcall(fs.write, PATH, existing .. line)
end

local function read_all()
  local body = read_text(PATH)
  if body == "" then return {} end
  local out = {}
  for line in body:gmatch("([^\n]+)") do
    local ok, decoded = pcall(json.parse, line)
    if ok then table.insert(out, decoded) end
  end
  return out
end

function M.recent(n)
  n = n or 50
  local all = read_all()
  local total = #all
  local start = math.max(1, total - n + 1)
  local out = {}
  for i = total, start, -1 do
    table.insert(out, all[i])
  end
  return out
end

function M.export()
  return read_text(PATH)
end

return M

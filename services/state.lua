--! state.lua — host + container snapshot for hostops.
--!
--! Reads from the hostops lib's host/proc and nspawn/machines readers
--! and exposes the {host, machines} shape mount() expects. Held in
--! memory; refreshed on demand by mount() callers.
--!
--! Background refresh is opt-in: call `state.start()` to kick a tier'd
--! refresh loop (host fast, machines medium). Without start(), the
--! state stays at boot snapshot — fine for first request.

local proc     = require("hostops.services.host.proc")
local machines = require("hostops.services.nspawn.machines")

local M = {}

local _state = {
  host           = {},
  machines       = {},
  state_revision = 0,
}

local function refresh_host()
  local ok, snap = pcall(proc.snapshot)
  if ok and type(snap) == "table" then
    snap.name = snap.hostname
    snap.ip   = snap.ip or ""
    _state.host = snap
  else
    log.warn("state: host snapshot failed: " .. tostring(snap))
  end
end

local function refresh_machines()
  local ok, ms = pcall(machines.snapshot)
  if ok and type(ms) == "table" then
    _state.machines = ms
  else
    log.warn("state: machines snapshot failed: " .. tostring(ms))
  end
end

function M.bump()
  _state.state_revision = _state.state_revision + 1
end

function M.revision() return _state.state_revision end

function M.snapshot()
  refresh_host()
  refresh_machines()
  M.bump()
  return _state
end

function M.machine_deep(name)
  refresh_machines()
  for _, m in ipairs(_state.machines or {}) do
    if m.name == name then
      return { info = m, services = {}, cron = {}, journal = {} }
    end
  end
  return nil
end

function M.start()
  refresh_host()
  refresh_machines()
  M.bump()
  if async and async.spawn_interval then
    async.spawn_interval(2,  function() refresh_host()    M.bump() end)
    async.spawn_interval(15, function() refresh_machines() M.bump() end)
  end
end

return M

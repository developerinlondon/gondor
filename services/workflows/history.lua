--! services/workflows/history.lua — in-memory recent-runs cache.
--!
--! Pod restart clears it; client.lua's rehydrate() repopulates from the
--! engine on boot. Cap is generous because skip-trace runs are tiny and
--! we want a few hundred for the Recent tab without a round-trip per
--! page click.

local M = {}

local CAP = 500

local _entries = {}

function M.replace(entries)
  _entries = entries or {}
end

-- Append at the front (newest first). Drops oldest entries past CAP.
function M.prepend(entry)
  table.insert(_entries, 1, entry)
  while #_entries > CAP do
    table.remove(_entries)
  end
end

-- Update an entry in place by id, leaving order unchanged. Used when a
-- run transitions from RUNNING to a terminal state and we already have
-- a placeholder row.
function M.upsert_by_id(entry)
  for i, e in ipairs(_entries) do
    if e.id == entry.id then
      _entries[i] = entry
      return
    end
  end
  M.prepend(entry)
end

function M.list()
  return _entries
end

-- Return one slice for pagination. Caller passes 1-based page; we clamp
-- both page and per_page so dodgy query params don't crash.
function M.page(page, per_page)
  page = tonumber(page) or 1
  per_page = tonumber(per_page) or 10
  if page < 1 then page = 1 end
  if per_page < 1 then per_page = 10 end
  if per_page > 100 then per_page = 100 end
  local total = #_entries
  local first = (page - 1) * per_page + 1
  local last  = math.min(first + per_page - 1, total)
  local out   = {}
  for i = first, last do out[#out + 1] = _entries[i] end
  return out, total, page, per_page
end

return M

--! tracer.lua — deterministic mock skip-trace.
--!
--! Same inputs → same output so the demo is repeatable. Real impl
--! would call public-records APIs (LexisNexis, TLOxp, voter rolls,
--! county auditor, etc.) and aggregate.

local M = {}

local function seed(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 1000003 end
  return h
end

local STATES = {
  OH = "Ohio", PA = "Pennsylvania", NY = "New York",
  FL = "Florida", TX = "Texas", CA = "California",
}
local CITIES = {
  OH = {"Columbus", "Cleveland", "Cincinnati", "Akron", "Dayton"},
  PA = {"Philadelphia", "Pittsburgh", "Allentown", "Erie", "Reading"},
  NY = {"New York", "Buffalo", "Rochester", "Yonkers", "Syracuse"},
  FL = {"Miami", "Orlando", "Tampa", "Jacksonville", "Tallahassee"},
  TX = {"Houston", "Dallas", "Austin", "San Antonio", "Fort Worth"},
  CA = {"Los Angeles", "San Francisco", "San Diego", "Sacramento", "San Jose"},
}
local STREETS = {"Maple", "Oak", "Elm", "Cedar", "Pine", "Birch", "Walnut", "Chestnut"}
local SOURCES = {
  "County auditor (parcel records)",
  "Secretary of State (voter registration)",
  "USPS NCOA (forwarding-address database)",
  "Phone directory (Whitepages, Spokeo)",
  "Social graph (LinkedIn, Facebook public)",
  "Property records (Realtor.com, county recorder)",
  "Bankruptcy filings (PACER index)",
}

function M.trace(input)
  local name  = (input.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local state = (input.state or "OH"):upper()
  local s     = seed(name .. "|" .. state)

  local cities = CITIES[state] or CITIES.OH
  local city   = cities[(s % #cities) + 1]
  local street = STREETS[(s % #STREETS) + 1]
  local addr   = string.format("%d %s St., %s, %s %05d",
                               (s % 9000) + 100, street, city, state,
                               10000 + (s % 89999))

  local phone = string.format("(%03d) %03d-%04d",
                              200 + (s % 700),
                              100 + ((s * 7) % 800),
                              1000 + ((s * 13) % 9000))

  local email = name:lower():gsub("%s+", "."):gsub("%.%.+", ".") .. "@example.com"

  local consulted = {}
  for i = 1, 4 + (s % 3) do consulted[i] = SOURCES[i] end
  if (input.case_number or "") ~= "" then
    consulted[#consulted + 1] = SOURCES[#SOURCES]
  end

  return {
    subject     = name,
    case_number = input.case_number,
    state       = STATES[state] or state,
    address     = addr,
    phone       = phone,
    email       = email,
    confidence  = 0.65 + ((s % 30) / 100),
    sources     = consulted,
    traced_at   = os.date("!%Y-%m-%d %H:%M:%S UTC"),
  }
end

return M

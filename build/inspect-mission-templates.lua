-- Read a DCS mission table from stdin; evaluate in an empty, bounded sandbox.
local chunk = assert(loadstring(io.read("*a"), "mission-table"))
local sandbox = {}
setfenv(chunk, sandbox)
debug.sethook(function()
  error("mission table exceeded instruction budget")
end, "", 1000000)
local ok, message = pcall(chunk)
debug.sethook()
assert(ok, message)
local mission = assert(sandbox.mission, "missing mission table")
for _, side in ipairs({ "blue", "red" }) do
  for _, country in pairs((mission.coalition[side] or {}).country or {}) do
    for _, group in pairs((country.plane or {}).group or {}) do
      local units = {}
      for _, unit in ipairs(group.units or {}) do
        units[#units + 1] = tostring(unit.type) .. ":" .. tostring(unit.skill)
      end
      print(
        side .. "\t" .. group.name .. "\tlate=" .. tostring(group.lateActivation) .. "\t" .. table.concat(units, ",")
      )
    end
  end
end

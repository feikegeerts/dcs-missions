-- Host-side table-only edit. Never rebuild the embedded scripts or voice assets.
local source, output = assert(arg[1]), assert(arg[2])
local function read(path, key)
  local sandbox = {}
  local chunk = assert(loadfile(path))
  setfenv(chunk, sandbox)
  debug.sethook(function()
    error("table evaluation budget exceeded")
  end, "", 1000000)
  local ok, err = pcall(chunk)
  debug.sethook()
  assert(ok, err)
  return assert(sandbox[key])
end
local function equal(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end
local function serialize(value)
  if type(value) == "string" then
    return string.format("%q", value)
  end
  if type(value) == "number" then
    return string.format("%.17g", value)
  end
  if type(value) == "boolean" then
    return tostring(value)
  end
  assert(type(value) == "table", "Unsupported mission-table value")
  local keys, lines = {}, { "{" }
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    if type(a) ~= type(b) then
      return type(a) < type(b)
    end
    return a < b
  end)
  for _, key in ipairs(keys) do
    lines[#lines + 1] = "[" .. serialize(key) .. "]=" .. serialize(value[key]) .. ","
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end
local function write(path, key, value)
  local file = assert(io.open(path, "wb"))
  file:write(key .. " = " .. serialize(value) .. "\n")
  file:close()
end
local mission = read(source .. "/mission", "mission")
assert(mission.theatre == "Syria", "Expected Syria mission")
local zones = {}
for _, zone in pairs(mission.triggers.zones) do
  assert(not zones[zone.name], "Duplicate zone name")
  zones[zone.name] = zone
end
local pickup = assert(zones["OHP-Pickup"])
local personnel = assert(zones["OHP-HVTs"])
local receiving = assert(zones["OHP-Hatay-Return"])
-- Earlier nearby test area. Terrain/obstacles still require a visual check.
local target = { x = 151595.453125, y = 42823.1015625 }
local dx, dy = target.x - pickup.x, target.y - pickup.y
local edits = {}
local function move(point)
  edits[#edits + 1] = { point = point, x = point.x, y = point.y }
  point.x, point.y = point.x + dx, point.y + dy
end
move(pickup)
move(personnel)
local chinook, party
for _, side in pairs(mission.coalition) do
  if type(side) == "table" then
    for _, country in pairs(side.country or {}) do
      for _, group in pairs(country.helicopter and country.helicopter.group or {}) do
        if group.name == "Mule-1" then
          assert(not chinook, "Duplicate Chinook group")
          chinook = group
        end
      end
      for _, group in pairs(country.vehicle and country.vehicle.group or {}) do
        if
          group.name == "OHP-TestParty"
          or group.name == "OHP-Pickup-Support"
          or group.name == "OHP-Test-Pickup-Support"
        then
          if group.name == "OHP-TestParty" then
            assert(not party and group.lateActivation and #group.units == 3, "Unexpected party template")
            party = group
          end
          move(group)
          for _, unit in pairs(group.units) do
            move(unit)
          end
          for _, point in pairs(group.route and group.route.points or {}) do
            move(point)
          end
        end
      end
    end
  end
end
assert(chinook and party, "Missing Chinook or party")
local waypoint = assert(chinook.route.points[4])
assert(waypoint.name == "PICKUP", "Unexpected pickup waypoint")
edits[#edits + 1] = { point = waypoint, x = waypoint.x, y = waypoint.y }
waypoint.x, waypoint.y = pickup.x, pickup.y
local distance = math.sqrt((pickup.x - receiving.x) ^ 2 + (pickup.y - receiving.y) ^ 2) / 1852
local separation = math.sqrt((pickup.x - personnel.x) ^ 2 + (pickup.y - personnel.y) ^ 2)
assert(distance > 2.9 and distance < 3.2, "Test pickup must be about 3 NM from Hatay")
assert(separation >= 35 and separation <= 105, "Unsafe pickup/party spacing")
local dictpath = "/l10n/DEFAULT/dictionary"
local dictionary = read(source .. dictpath, "dictionary")
local old_dictionary = read(source .. dictpath, "dictionary")
dictionary[mission.sortie] = "Operation Hidden Passage - Testing"
local old_travel = "The pickup is approximately 33.1 NM south of Hatay, straight line. At 100-120\n"
  .. "knots groundspeed, allow about 17-20 minutes each way before detours/approach;\n"
  .. "budget roughly 20-25 minutes per leg for low-level routing. This is an estimate,\n"
  .. "not a validated terrain-masked route. Check obstacles, terrain and landing slope."
for _, key in ipairs({ mission.descriptionText, mission.descriptionBlueTask }) do
  local text = assert(dictionary[key], "Missing briefing")
  local first, last = text:find(old_travel, 1, true)
  assert(first, "Travel briefing changed; review before updating the test copy")
  dictionary[key] = "TESTING COPY - original mission unchanged.\n\n"
    .. text:sub(1, first - 1)
    .. string.format("The pickup is %.2f NM northeast of Hatay (waypoint 4). Allow about 2 minutes\n", distance)
    .. "at 100-120 knots, plus takeoff and approach. Voice recordings and playback\n"
    .. "logic are unchanged. Check obstacles, terrain and slope before landing."
    .. text:sub(last + 1)
end
write(output .. "/mission", "mission", mission)
write(output .. dictpath, "dictionary", dictionary)
assert(equal(mission, read(output .. "/mission", "mission")), "Mission round-trip mismatch")
assert(equal(dictionary, read(output .. dictpath, "dictionary")), "Dictionary round-trip mismatch")
-- Reverse only the allowed coordinate changes, then compare every mission field.
for _, edit in ipairs(edits) do
  edit.point.x, edit.point.y = edit.x, edit.y
end
assert(equal(mission, read(source .. "/mission", "mission")), "Unapproved mission-table edit")
for _, key in ipairs({ mission.sortie, mission.descriptionText, mission.descriptionBlueTask }) do
  dictionary[key] = old_dictionary[key]
end
assert(equal(dictionary, old_dictionary), "Unapproved dictionary edit")
print(
  string.format(
    "Short copy verified: %.2f NM pickup, %.1f m party spacing; all other mission fields preserved",
    distance,
    separation
  )
)

-- Archive-side guard for explicit testing/operational updates. No DCS APIs used.
local path = assert(arg[1])
local layout = arg[3] or "testing"
local config = assert(loadfile("src/missions/operation-hidden-passage/config.lua"))()
assert(layout == "testing" or layout == "operational", "Unknown mission layout")
local sandbox = {}
local chunk = assert(loadfile(path))
setfenv(chunk, sandbox)
chunk()
local mission = assert(sandbox.mission)
assert(mission.theatre == "Syria")
local zones = {}
for _, zone in pairs(mission.triggers.zones) do
  assert(not zones[zone.name], "Duplicate named zone")
  zones[zone.name] = zone
end
local pickup, receiving = assert(zones["OHP-Pickup"]), assert(zones["OHP-Hatay-Return"])
local personnel = assert(zones["OHP-HVTs"])
local nm = math.sqrt((pickup.x - receiving.x) ^ 2 + (pickup.y - receiving.y) ^ 2) / 1852
local opposition
for _, country in pairs(mission.coalition.red.country or {}) do
  for _, group in pairs(country.vehicle and country.vehicle.group or {}) do
    if group.name == config.firefight.template then
      assert(not opposition, "Duplicate firefight enemy template")
      opposition = group
    end
  end
end
if layout == "testing" then
  assert(nm > 2.9 and nm < 3.2, "Refusing update: this is not the short test layout")
else
  assert(nm > 33 and nm < 33.2, "Refusing update: this is not the approved operational layout")
end
if opposition then
  assert(
    opposition.lateActivation and #opposition.units == config.firefight.enemy_unit_count,
    "Malformed firefight template"
  )
  local distance = math.sqrt((opposition.x - personnel.x) ^ 2 + (opposition.y - personnel.y) ^ 2)
  local expected = math.sqrt(2) * config.firefight.staging_offset_m
  assert(
    math.abs(distance - expected) < 1,
    "Firefight template must use the selected archive's HVT-relative staging offset"
  )
  assert(
    opposition.x == personnel.x + config.firefight.staging_offset_m
      and opposition.y == personnel.y - config.firefight.staging_offset_m,
    "Firefight staging position must be relative to the selected archive's HVT zone"
  )
  local route_point = assert(opposition.route and opposition.route.points and opposition.route.points[1])
  assert(
    route_point.x == opposition.x and route_point.y == opposition.y,
    "Initial route point must match staging position"
  )
  for _, unit in ipairs(opposition.units) do
    assert(unit.type == "Infantry AK", "Unexpected enemy weapon/type; use killable rifle infantry")
  end
end
local spacing = math.sqrt((pickup.x - personnel.x) ^ 2 + (pickup.y - personnel.y) ^ 2)
assert(spacing >= 35 and spacing <= 105, "Unsafe personnel/LZ spacing")
local wanted = { ["Mule-1-1"] = "CH-47Fbl1", ["Raven-1-1"] = "UH-60L" }
local found = {}
for _, country in pairs(mission.coalition.blue.country) do
  for _, group in pairs(country.helicopter and country.helicopter.group or {}) do
    for _, unit in pairs(group.units) do
      if wanted[unit.name] then
        assert(not found[unit.name] and unit.type == wanted[unit.name], "Unexpected named aircraft")
        found[unit.name] = true
      end
    end
  end
end
assert(found["Mule-1-1"] and found["Raven-1-1"], "Expected named Mule and Raven aircraft")
if arg[2] then
  local dictionary_env = {}
  local briefing = assert(loadfile(arg[2]))
  setfenv(briefing, dictionary_env)
  briefing()
  local title = layout == "testing" and "Operation Hidden Passage - Testing" or "Operation Hidden Passage"
  assert(dictionary_env.dictionary[mission.sortie] == title, "Unexpected mission title")
  for _, key in ipairs({ mission.descriptionText, mission.descriptionBlueTask }) do
    local text = dictionary_env.dictionary[key]
    assert(text:find("boarding starts automatically", 1, true), "Missing automatic pickup briefing")
    assert(text:find("Both helicopters can extract", 1, true), "Missing dual-aircraft briefing")
    assert(not text:find("NOT connected", 1, true), "Stale UH-60 restriction in briefing")
  end
end
print(string.format("%s archive guard: %.2f NM, named Chinook and UH-60L verified", layout, nm))

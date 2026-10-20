local original, output = assert(arg[1]), assert(arg[2])
local updating = arg[3] == "--update-existing"
local config = dofile("src/missions/operation-hidden-passage/config.lua")
local function read(path, key)
  local chunk = assert(loadfile(path))
  local sandbox = {}
  setfenv(chunk, sandbox)
  assert(pcall(chunk))
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
local seed = read(original .. "/mission", "mission")
local mission = read(output .. "/mission", "mission")
local before = seed.coalition.blue.country[1].helicopter.group[1]
local after = mission.coalition.blue.country[1].helicopter.group[1]
if updating then
  -- Allow only the explicitly agreed mission-table edits. This compares every
  -- other field, including UH-60L, support placements, payloads and weather.
  local expected = read(original .. "/mission", "mission")
  local group = expected.coalition.blue.country[1].helicopter.group[1]
  assert(group.name == config.player_group)
  local points = group.route.points
  points[4].name, points[4].x, points[4].y = "PICKUP", config.pickup.x, config.pickup.y
  points[5].x, points[5].y = config.receiving.x, config.receiving.y
  expected.trigrules[1].comment = "Hidden Passage - MOOSE then mission"
  assert(equal(expected, mission), "Unapproved editor mission-table change")
else
  assert(equal(before.units, after.units), "Chinook unit setup changed")
  for i, point in ipairs(before.route.points) do
    assert(equal(point, after.route.points[i]), "Original route changed")
  end
  assert(#after.route.points == #before.route.points + 2)
  assert(#mission.coalition.blue.country[1].helicopter.group == 1)
end
for key, value in pairs(before) do
  if key ~= "route" then
    assert(equal(value, after[key]), "Original group field changed: " .. key)
  end
end
assert(equal(seed.date, mission.date) and equal(seed.weather, mission.weather))
assert(equal(seed.coalition.red, mission.coalition.red))
assert(equal(seed.coalition.neutrals, mission.coalition.neutrals))
assert(equal(seed.requiredModules, mission.requiredModules), "Added an unapproved module dependency")
assert(mission.theatre == "Syria")
assert(#mission.coalition.blue.country == 1)
assert(not mission.coalition.blue.country[1].plane)
local ids, names, unit_ids, unit_names = {}, {}, {}, {}
local party_count, active_ground_count = 0, 0
for _, category in ipairs({ "helicopter", "vehicle" }) do
  for _, group in ipairs(mission.coalition.blue.country[1][category].group) do
    assert(not ids[group.groupId] and not names[group.name], "Duplicate group identity")
    ids[group.groupId], names[group.name] = true, true
    for _, unit in ipairs(group.units) do
      assert(not unit_ids[unit.unitId] and not unit_names[unit.name], "Duplicate unit identity")
      unit_ids[unit.unitId], unit_names[unit.name] = true, true
      if group.name == "OHP-TestParty" then
        assert(group.lateActivation and unit.type == "Soldier M4")
        party_count = party_count + 1
      elseif category == "vehicle" then
        assert(not group.lateActivation)
        active_ground_count = active_ground_count + 1
      end
    end
  end
end
assert(party_count == config.party_size)
if not updating then
  assert(active_ground_count == 6)
end
assert(#mission.triggers.zones == 3)
local landing, waiting = mission.triggers.zones[1], mission.triggers.zones[3]
assert(landing.name == config.pickup_zone and landing.radius == config.pickup.radius)
assert(waiting.name == config.personnel_zone)
assert(landing.x == config.pickup.x and landing.y == config.pickup.y)
assert(waiting.x == config.personnel.x and waiting.y == config.personnel.y)
local separation = math.sqrt((waiting.x - landing.x) ^ 2 + (waiting.y - landing.y) ^ 2)
assert(separation >= config.minimum_personnel_clearance_m and separation <= config.extraction_distance_m)
if not updating then
  for _, group in ipairs(mission.coalition.blue.country[1].vehicle.group) do
    if group.name == "OHP-TestParty" then
      assert(group.x == waiting.x and group.y == waiting.y)
    end
  end
end
assert(
  after.route.points[4].name == "PICKUP"
    and after.route.points[4].x == landing.x
    and after.route.points[4].y == landing.y
)
assert(after.route.points[5].x == config.receiving.x and after.route.points[5].y == config.receiving.y)
local dx = mission.triggers.zones[1].x - before.x
local dy = mission.triggers.zones[1].y - before.y
local nm = math.sqrt(dx * dx + dy * dy) / 1852
assert(nm > 33 and nm < 33.2)
assert(#mission.trigrules == 1 and mission.trigrules[1].predicate == "triggerStart")
assert(next(mission.trigrules[1].rules) == nil, "Conditioned MISSION START")
assert(#mission.trigrules[1].actions == 2)
local resources = read(output .. "/l10n/DEFAULT/mapResource", "mapResource")
for _, action in ipairs(mission.trigrules[1].actions) do
  assert(action.predicate == "a_do_script_file")
  assert(loadfile(output .. "/l10n/DEFAULT/" .. assert(resources[action.file])))
end
local called = {}
local action = assert(loadstring(mission.trig.actions[1]))
setfenv(action, {
  getValueResourceByKey = function(key)
    return assert(resources[key])
  end,
  a_do_script_file = function(file)
    called[#called + 1] = file
  end,
})
action()
assert(called[1] == "OHP-Moose_.lua" and called[2] == "OHP-main.lua")
local startup = assert(loadstring(mission.trig.funcStartup[1]))
setfenv(startup, {
  mission = {
    trig = {
      conditions = {
        function()
          return true
        end,
      },
      actions = {
        function()
          called[#called + 1] = "startup"
        end,
      },
    },
  },
})
startup()
assert(called[3] == "startup")
local dict = read(output .. "/l10n/DEFAULT/dictionary", "dictionary")
assert(dict[mission.descriptionBlueTask]:find("Extract waiting personnel", 1, true))
assert(dict[mission.descriptionBlueTask]:find("No in-mission reset command", 1, true))
assert(dict[mission.descriptionBlueTask]:find('party disappears AND "Three personnel aboard"', 1, true))
assert(dict[mission.descriptionBlueTask]:find(config.pickup_zone, 1, true))
assert(dict[mission.descriptionBlueTask]:find(config.personnel_zone, 1, true))
assert(not dict[mission.descriptionBlueTask]:find("TEST", 1, true))
if updating then
  local expected = read(original .. "/l10n/DEFAULT/dictionary", "dictionary")
  expected[mission.descriptionText] = dict[mission.descriptionText]
  expected[mission.descriptionBlueTask] = dict[mission.descriptionBlueTask]
  expected[mission.sortie] = "Operation Hidden Passage"
  assert(equal(expected, dict), "Unapproved briefing/dictionary change")
  assert(equal(read(original .. "/l10n/DEFAULT/mapResource", "mapResource"), resources))
end
local wh_before = read(original .. "/warehouses", "warehouses")
local wh_after = read(output .. "/warehouses", "warehouses")
wh_before.airports[15].coalition = "BLUE"
assert(equal(wh_before, wh_after), "Unexpected warehouse changes")
assert(wh_after.airports[15].coalition == "BLUE")
for _, name in ipairs({
  "boarding-start.ogg",
  "boarding-hvt-aboard.ogg",
  "boarding-confirm.ogg",
  "mule-one-cleared-for-pickup.ogg",
}) do
  local sound = assert(io.open(output .. "/Sounds/OHP/" .. name, "rb"), "Missing voice asset " .. name)
  assert(sound:read(4) == "OggS", name .. " is not an Ogg stream")
  sound:close()
end
print(
  string.format(
    "Hidden Passage artifact: preservation, identities, Hatay, %.2f NM pickup, triggers/resources/sound OK",
    nm
  )
)

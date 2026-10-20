-- Explicit build recipe for the non-wave transport probe. Host-side Lua only.
local source, output, config_path = assert(arg[1]), assert(arg[2]), assert(arg[3])
local updating = arg[4] == "--update-existing"
local function read_table(path, name)
  local chunk = assert(loadfile(path))
  local sandbox = {}
  setfenv(chunk, sandbox)
  debug.sethook(function()
    error("table evaluation budget exceeded")
  end, "", 1000000)
  local ok, result = pcall(chunk)
  debug.sethook()
  assert(ok, result)
  return result or assert(sandbox[name], "Missing table " .. tostring(name))
end
local config = read_table(config_path)
local mission = read_table(source .. "/mission", "mission")
local dictionary = read_table(source .. "/l10n/DEFAULT/dictionary", "dictionary")
local warehouses = read_table(source .. "/warehouses", "warehouses")
local resources = read_table(source .. "/l10n/DEFAULT/mapResource", "mapResource")
assert(config.mission_name == "operation-hidden-passage")
assert(mission.theatre == "Syria", "Hidden Passage probe requires Syria")
if not updating then
  assert(
    #mission.trigrules == 0 and next(mission.trig.actions) == nil,
    "Use the original Chinook-only seed, not an already scripted archive"
  )
end
local countries = mission.coalition.blue.country
assert(#countries == 1 and countries[1].id == 2, "Expected the original Blue USA detachment")
local usa = countries[1]
local helicopters = assert(usa.helicopter.group)
if not updating then
  assert(#helicopters == 1)
end
local helicopter
for _, group in ipairs(helicopters) do
  if group.name == config.player_group then
    assert(not helicopter, "Duplicate Chinook group")
    helicopter = group
  end
end
assert(helicopter and #helicopter.units == 1, "Missing single-aircraft Chinook group")
local chinook = helicopter.units[1]
assert(helicopter.name == config.player_group and chinook.name == config.player_unit)
assert(chinook.type == "CH-47Fbl1" and chinook.skill == "Client")
assert(helicopter.route.points[1].airdromeId == 15, "Expected Hatay")
assert(
  (chinook.x - config.receiving.x) ^ 2 + (chinook.y - config.receiving.y) ^ 2 < config.receiving.radius ^ 2,
  "Return zone must contain Chinook parking"
)
if not updating then
  assert(not usa.vehicle, "Seed unexpectedly already contains vehicles")
  assert(not resources.ResKey_OHP_MOOSE and not resources.ResKey_OHP_MAIN)

  local group_id, unit_id = 1, 1
  -- The seed contains one aircraft, but find maxima rather than assume its IDs.
  for _, side in pairs(mission.coalition) do
    for _, nation in pairs(side.country or {}) do
      for _, category in ipairs({ "plane", "helicopter", "vehicle", "ship", "static" }) do
        for _, group in pairs(nation[category] and nation[category].group or {}) do
          group_id = math.max(group_id, group.groupId or 0)
          for _, unit in pairs(group.units or {}) do
            unit_id = math.max(unit_id, unit.unitId or 0)
          end
        end
      end
    end
  end
  local function ground_group(name, x, y, types, late)
    group_id = group_id + 1
    local group = {
      groupId = group_id,
      name = name,
      x = x,
      y = y,
      visible = false,
      hidden = false,
      lateActivation = late or false,
      start_time = 0,
      task = "Ground Nothing",
      tasks = {},
      route = {
        points = {
          {
            x = x,
            y = y,
            alt = 0,
            alt_type = "BARO",
            speed = 0,
            action = "Off Road",
            type = "Turning Point",
            ETA = 0,
            ETA_locked = true,
            speed_locked = true,
            task = { id = "ComboTask", params = { tasks = {} } },
          },
        },
      },
      units = {},
    }
    for i, kind in ipairs(types) do
      unit_id = unit_id + 1
      group.units[i] = {
        unitId = unit_id,
        name = name .. "-" .. i,
        type = kind,
        skill = "Excellent",
        x = x + (i - 1) * 12,
        y = y,
        heading = 0,
        playerCanDrive = false,
        coldAtStart = false,
      }
    end
    return group
  end
  usa.vehicle = {
    group = {
      ground_group("OHP-Hatay-Logistics", chinook.x - 140, chinook.y + 220, { "M978 HEMTT Tanker", "M 818", "Hummer" }),
      ground_group("OHP-Hatay-GroundCrew", chinook.x - 180, chinook.y + 220, { "Soldier M4", "Soldier M4" }),
      ground_group("OHP-Pickup-Support", config.pickup.x + 80, config.pickup.y + 80, { "Hummer" }),
      ground_group(
        config.party_template,
        config.personnel.x,
        config.personnel.y,
        { "Soldier M4", "Soldier M4", "Soldier M4" },
        true
      ),
    },
  }

  local zones = mission.triggers.zones
  assert(#zones == 0, "Expected the unmodified seed's empty zones")
  for i, data in ipairs({
    { config.pickup_zone, config.pickup },
    { config.return_zone, config.receiving },
    { config.personnel_zone, config.personnel },
  }) do
    zones[i] = {
      zoneId = i,
      name = data[1],
      x = data[2].x,
      y = data[2].y,
      radius = data[2].radius,
      type = 0,
      color = { 0, 0.6, 1, 0.25 },
      properties = {},
      hidden = false,
    }
  end

  -- Preserve every original route point; append convenient navigation points.
  for _, data in ipairs({ { "PICKUP", config.pickup }, { "HATAY RETURN", config.receiving } }) do
    local points = helicopter.route.points
    points[#points + 1] = {
      name = data[1],
      x = data[2].x,
      y = data[2].y,
      alt = 300,
      alt_type = "RADIO",
      speed = 41.666666666667,
      action = "Turning Point",
      type = "Turning Point",
      ETA = 0,
      ETA_locked = false,
      speed_locked = true,
      task = { id = "ComboTask", params = { tasks = {} } },
    }
  end

  warehouses.airports[15].coalition = "BLUE"
  resources.ResKey_OHP_MOOSE = "OHP-Moose_.lua"
  resources.ResKey_OHP_MAIN = "OHP-main.lua"
  mission.trig.conditions[1] = "return(true)"
  mission.trig.actions[1] =
    'a_do_script_file(getValueResourceByKey("ResKey_OHP_MOOSE")); a_do_script_file(getValueResourceByKey("ResKey_OHP_MAIN"));'
  mission.trig.flag[1] = true
  mission.trig.funcStartup[1] = "if mission.trig.conditions[1]() then mission.trig.actions[1]() end"
  mission.trigrules[1] = {
    comment = "Hidden Passage - MOOSE then mission",
    predicate = "triggerStart",
    eventlist = "",
    colorItem = "0xff808080",
    rules = {}, -- MISSION START must not have conditions.
    actions = {
      { predicate = "a_do_script_file", file = "ResKey_OHP_MOOSE" },
      { predicate = "a_do_script_file", file = "ResKey_OHP_MAIN" },
    },
  }
else
  -- Surgical update: never recreate units, zones, coalitions or warehouses.
  assert(
    resources.ResKey_OHP_MOOSE == "OHP-Moose_.lua" and resources.ResKey_OHP_MAIN == "OHP-main.lua",
    "Unexpected script resources"
  )
  assert(#mission.trigrules == 1 and mission.trigrules[1].predicate == "triggerStart", "Unexpected startup triggers")
  local startup = mission.trigrules[1]
  assert(next(startup.rules) == nil and #startup.actions == 2, "Unexpected startup conditions/actions")
  assert(
    startup.actions[1].file == "ResKey_OHP_MOOSE" and startup.actions[2].file == "ResKey_OHP_MAIN",
    "Unexpected startup script order"
  )
  startup.comment = "Hidden Passage - MOOSE then mission"
  local zones = {}
  for _, zone in pairs(mission.triggers.zones) do
    assert(not zones[zone.name], "Duplicate zone name")
    zones[zone.name] = zone
  end
  for name, point in pairs({
    [config.pickup_zone] = config.pickup,
    [config.personnel_zone] = config.personnel,
    [config.return_zone] = config.receiving,
  }) do
    local zone = assert(zones[name], "Missing zone " .. name)
    assert(
      math.abs(zone.x - point.x) < 0.01 and math.abs(zone.y - point.y) < 0.01 and zone.radius == point.radius,
      "Editor zone differs from config snapshot: " .. name
    )
  end
  local template
  for _, group in ipairs(usa.vehicle.group) do
    if group.name == config.party_template then
      template = group
    end
  end
  assert(
    template and template.lateActivation and #template.units == config.party_size,
    "Missing intact late-activated extraction template"
  )
  local points = helicopter.route.points
  assert(points[4] and (points[4].name == "TEST PICKUP" or points[4].name == "PICKUP"), "Unexpected pickup waypoint")
  assert(points[5] and points[5].name == "HATAY RETURN", "Unexpected return waypoint")
  points[4].name, points[4].x, points[4].y = "PICKUP", config.pickup.x, config.pickup.y
  points[5].x, points[5].y = config.receiving.x, config.receiving.y
end
dictionary[mission.sortie] = "Operation Hidden Passage"
local dx, dy = config.pickup.x - config.receiving.x, config.pickup.y - config.receiving.y
local nm = math.sqrt(dx * dx + dy * dy) / 1852
local separation = math.sqrt((config.pickup.x - config.personnel.x) ^ 2 + (config.pickup.y - config.personnel.y) ^ 2)
local briefing = string.format(
  [[
OPERATION HIDDEN PASSAGE

Blue CH-47F Mule-1 starts hot at Hatay. Fly to PICKUP (waypoint 4), collect
the three-person extraction party, and return to HATAY RETURN (waypoint 5).

The pickup is approximately %.1f NM south of Hatay, straight line. At 100-120
knots groundspeed, allow about 17-20 minutes each way before detours/approach;
budget roughly 20-25 minutes per leg for low-level routing. This is an estimate,
not a validated terrain-masked route. Check obstacles, terrain and landing slope.

%s is the LANDING area. The party waits about %.0f metres away at %s.
Do NOT land on the personnel marker. Green smoke marks the chosen landing area.

1. F10 > Operation Hidden Passage > Mark landing area (green smoke).
2. Land at the smoke, keep at least 35 metres clear of every person, and stop.
3. F10 > Operation Hidden Passage > Extract waiting personnel.
4. Remain landed until the party disappears AND "Three personnel aboard"
   appears together (allow about 20-45 seconds). Then you may take off.
5. Return to your original Hatay parking inside OHP-Hatay-Return.
6. Land, stop, then F10 > Operation Hidden Passage > Unload personnel.
7. Confirm "Operation complete". Merely flying over the base is not delivery.

F10 > Operation Hidden Passage is the only scripted transport menu. It calls
CTLD internally; no generic Load troops, zone-smoke or logistics menus are shown.
Green smoke marks the landing area, not the people, and has no proximity limit.
Use these scripted commands, not the native troop radio menu.
The guns are retained; extraction does not require ramp/door operation.

The added UH-60L Client slot is preserved but NOT connected to this objective.
Use the Chinook for extraction. No adaptive enemies or SAMs are scripted yet.
There is no automatic mission end.
Restart the MISSION after an aircraft/party loss or to fly again after completion.
Re-slotting does not reset a failed objective. No in-mission reset command.
]],
  nm,
  config.pickup_zone,
  separation,
  config.personnel_zone
)
dictionary[mission.descriptionText] = briefing
dictionary[mission.descriptionBlueTask] = briefing

local function serialize(value, indent)
  local kind = type(value)
  if kind == "string" then
    return string.format("%q", value)
  elseif kind == "number" then
    assert(value == value and math.abs(value) ~= math.huge, "Non-finite number")
    return string.format("%.17g", value)
  elseif kind == "boolean" then
    return tostring(value)
  end
  assert(kind == "table", "Cannot serialize " .. kind)
  local keys = {}
  for key in pairs(value) do
    assert(type(key) == "number" or type(key) == "string")
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    if type(a) ~= type(b) then
      return type(a) < type(b)
    end
    return a < b
  end)
  local lines = { "{" }
  for _, key in ipairs(keys) do
    lines[#lines + 1] = indent .. "  [" .. serialize(key, "") .. "] = " .. serialize(value[key], indent .. "  ") .. ","
  end
  lines[#lines + 1] = indent .. "}"
  return table.concat(lines, "\n")
end
local tables = { mission = mission, dictionary = dictionary }
if not updating then
  tables.warehouses, tables.mapResource = warehouses, resources
end
for name, value in pairs(tables) do
  local path = output .. "/" .. name
  if name == "dictionary" or name == "mapResource" then
    path = output .. "/l10n/DEFAULT/" .. name
  end
  local file = assert(io.open(path, "wb"))
  file:write(name .. " = " .. serialize(value, "") .. "\n")
  file:close()
  assert(loadfile(path), "Generated table does not parse")
end
print(
  updating and "Updated Chinook extraction; editor units/zones/settings preserved"
    or "Prepared Syria/Hatay Chinook extraction"
)

-- Add one late-activated hostile-infantry SPAWN template to an explicitly
-- identified Hidden Passage archive. Every pre-existing field stays unchanged.
local source, output, layout = assert(arg[1]), assert(arg[2]), assert(arg[3])
assert(layout == "testing" or layout == "operational", "Unknown Hidden Passage layout")
local config = assert(loadfile("src/missions/operation-hidden-passage/config.lua"))()
local function read_mission(path)
  local sandbox = {}
  local chunk = assert(loadfile(path))
  setfenv(chunk, sandbox)
  debug.sethook(function()
    error("mission table evaluation budget exceeded")
  end, "", 1000000)
  local ok, err = pcall(chunk)
  debug.sethook()
  assert(ok, err)
  return assert(sandbox.mission)
end
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
local mission = read_mission(source)
assert(mission.theatre == "Syria", "Firefight template requires the Syria theatre")
local zones = {}
for _, zone in pairs(mission.triggers.zones) do
  assert(not zones[zone.name], "Duplicate named zone")
  zones[zone.name] = zone
end
local pickup = assert(zones[config.pickup_zone], "Missing pickup zone")
local receiving = assert(zones[config.return_zone], "Missing return zone")
local personnel = assert(zones[config.personnel_zone], "Missing HVT zone")
local distance_nm = math.sqrt((pickup.x - receiving.x) ^ 2 + (pickup.y - receiving.y) ^ 2) / 1852
if layout == "testing" then
  assert(distance_nm > 2.9 and distance_nm < 3.2, "Refusing to edit a non-Testing layout")
else
  assert(distance_nm > 33 and distance_nm < 33.2, "Refusing to edit a non-operational layout")
end
local template_name = config.firefight.template
local unit_count = config.firefight.enemy_unit_count
local legacy_fire_position_offset_m = config.firefight.fire_position_offset_m
local origin = {
  x = personnel.x + config.firefight.staging_offset_m,
  y = personnel.y - config.firefight.staging_offset_m,
}

local existing
for _, side in pairs(mission.coalition) do
  for _, country in pairs(side.country or {}) do
    for _, category in ipairs({ "plane", "helicopter", "vehicle", "ship", "static" }) do
      for _, group in pairs(country[category] and country[category].group or {}) do
        assert(group.name ~= template_name or not existing, "Duplicate enemy template name")
        if group.name == template_name then
          existing = group
        end
      end
    end
  end
end

local expected = {
  name = template_name,
  x = origin.x,
  y = origin.y,
  lateActivation = true,
  task = "Ground Nothing",
  types = {},
}
for i = 1, unit_count do
  expected.types[i] = "Infantry AK"
end

if existing then
  assert(existing.lateActivation, "Unexpected existing enemy template activation")
  assert(#existing.units == unit_count, "Unexpected enemy unit count")
  for i, unit in ipairs(existing.units) do
    assert(unit.type == expected.types[i], "Unexpected enemy unit type")
  end
  if existing.x == expected.x and existing.y == expected.y then
    local file = assert(io.open(output, "wb"))
    local original = assert(io.open(source, "rb"))
    file:write(original:read("*a"))
    original:close()
    file:close()
    print(layout .. " firefight template already staged; mission table unchanged")
    return
  end
  assert(
    existing.x == personnel.x + legacy_fire_position_offset_m
      and existing.y == personnel.y - legacy_fire_position_offset_m,
    "Unexpected existing enemy template position; refusing to move it"
  )
  local delta_x, delta_y = origin.x - existing.x, origin.y - existing.y
  existing.x, existing.y = origin.x, origin.y
  local route_point = assert(existing.route and existing.route.points and existing.route.points[1])
  route_point.x, route_point.y = origin.x, origin.y
  for _, unit in ipairs(existing.units) do
    unit.x, unit.y = unit.x + delta_x, unit.y + delta_y
  end
  local file = assert(io.open(output, "wb"))
  file:write("mission = " .. serialize(mission, "") .. "\n")
  file:close()
  assert(loadfile(output), "Updated Testing mission table does not parse")
  print("Moved the existing firefight template to the " .. layout .. " staging position")
  return
end

local maximum_group_id, maximum_unit_id = 0, 0
for _, side in pairs(mission.coalition) do
  for _, country in pairs(side.country or {}) do
    for _, category in ipairs({ "plane", "helicopter", "vehicle", "ship", "static" }) do
      for _, group in pairs(country[category] and country[category].group or {}) do
        maximum_group_id = math.max(maximum_group_id, group.groupId or 0)
        for _, unit in pairs(group.units or {}) do
          maximum_unit_id = math.max(maximum_unit_id, unit.unitId or 0)
        end
      end
    end
  end
end

local red = mission.coalition.red
red.country = red.country or {}
local russia
for _, country in ipairs(red.country) do
  if country.id == 0 or country.name == "RUSSIA" then
    assert(country.id == 0 and country.name == "RUSSIA", "Red country id 0 is not Russia")
    russia = country
  end
end
if not russia then
  assert(#red.country == 0, "Refusing to change the Testing mission's existing Red order of battle")
  russia = { id = 0, name = "RUSSIA", vehicle = { group = {} } }
  red.country[1] = russia
end
russia.vehicle = russia.vehicle or { group = {} }
russia.vehicle.group = russia.vehicle.group or {}

local units = {}
for i = 1, unit_count do
  local column = (i - 1) % 3
  local row = math.floor((i - 1) / 3)
  local dx, dy = (column - 1) * 9, (row - 0.5) * 10
  maximum_unit_id = maximum_unit_id + 1
  units[i] = {
    unitId = maximum_unit_id,
    name = template_name .. "-" .. i,
    type = "Infantry AK",
    skill = "Excellent",
    x = origin.x + dx,
    y = origin.y + dy,
    heading = 0,
    playerCanDrive = false,
    coldAtStart = false,
  }
end
maximum_group_id = maximum_group_id + 1
local group = {
  groupId = maximum_group_id,
  name = template_name,
  x = origin.x,
  y = origin.y,
  visible = false,
  hidden = false,
  lateActivation = true,
  start_time = 0,
  task = "Ground Nothing",
  tasks = {},
  route = {
    points = {
      {
        x = origin.x,
        y = origin.y,
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
  units = units,
}
russia.vehicle.group[#russia.vehicle.group + 1] = group

local file = assert(io.open(output, "wb"))
file:write("mission = " .. serialize(mission, "") .. "\n")
file:close()
assert(loadfile(output), "Generated Testing mission table does not parse")
print(string.format("Added %s six-unit late-activated enemy template at %.1f, %.1f", layout, origin.x, origin.y))

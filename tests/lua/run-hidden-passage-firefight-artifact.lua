-- Verify that enabling the firefight changes only its known template in the
-- explicitly selected Hidden Passage layout.
local original, output, layout = assert(arg[1]), assert(arg[2]), assert(arg[3])
assert(layout == "testing" or layout == "operational", "Unknown Hidden Passage layout")
local config = assert(loadfile("src/missions/operation-hidden-passage/config.lua"))()
local function read(path)
  local sandbox = {}
  local chunk = assert(loadfile(path))
  setfenv(chunk, sandbox)
  assert(pcall(chunk))
  return assert(sandbox.mission)
end
local function equal(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for key, value in pairs(a) do
    if not equal(value, b[key]) then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end
local before, after = read(original), read(output)
local function layout_distance(mission)
  local zones = {}
  for _, zone in pairs(assert(mission.triggers).zones) do
    zones[zone.name] = zone
  end
  local pickup, receiving = assert(zones[config.pickup_zone]), assert(zones[config.return_zone])
  return math.sqrt((pickup.x - receiving.x) ^ 2 + (pickup.y - receiving.y) ^ 2) / 1852
end
local distance_nm = layout_distance(before)
if layout == "testing" then
  assert(distance_nm > 2.9 and distance_nm < 3.2, "Firefight update received a non-Testing layout")
else
  assert(distance_nm > 33 and distance_nm < 33.2, "Firefight update received a non-operational layout")
end
local function find_template(mission)
  local found
  for _, country in pairs(mission.coalition.red.country or {}) do
    for _, group in pairs(country.vehicle and country.vehicle.group or {}) do
      if group.name == config.firefight.template then
        assert(not found, "Duplicate firefight template")
        found = group
      end
    end
  end
  return found
end
local existing, added = find_template(before), find_template(after)
assert(
  added and added.lateActivation and #added.units == config.firefight.enemy_unit_count,
  "Missing late-activated six-person enemy template"
)
for _, unit in ipairs(added.units) do
  assert(unit.type == "Infantry AK", "Enemy template must use killable rifle infantry, not heavy weapons")
end
local had_russia = false
for _, country in pairs(before.coalition.red.country or {}) do
  had_russia = had_russia or country.id == 0 or country.name == "RUSSIA"
end
local function without_template(mission)
  for _, country in pairs(mission.coalition.red.country or {}) do
    local groups = country.vehicle and country.vehicle.group or {}
    for i = #groups, 1, -1 do
      if groups[i].name == "OHP-TestOpposition" then
        table.remove(groups, i)
      end
    end
  end
  if not had_russia then
    local countries = mission.coalition.red.country or {}
    for i = #countries, 1, -1 do
      local country = countries[i]
      local groups = country.vehicle and country.vehicle.group or {}
      if (country.id == 0 or country.name == "RUSSIA") and #groups == 0 then
        table.remove(countries, i)
      end
    end
  end
  return mission
end
assert(
  equal(without_template(before), without_template(after)),
  "Firefight update altered unrelated editor-authored mission data"
)
if existing then
  local before_zones = {}
  for _, zone in pairs(before.triggers.zones) do
    before_zones[zone.name] = zone
  end
  local personnel = assert(before_zones[config.personnel_zone])
  local at_staging = existing.x == personnel.x + config.firefight.staging_offset_m
    and existing.y == personnel.y - config.firefight.staging_offset_m
  local at_previous_fire_position = existing.x == personnel.x + config.firefight.fire_position_offset_m
    and existing.y == personnel.y - config.firefight.fire_position_offset_m
  assert(at_staging or at_previous_fire_position, "Existing template is not at a supported Testing position")
  local dx, dy = added.x - existing.x, added.y - existing.y
  existing.x, existing.y = added.x, added.y
  local route_point = assert(existing.route and existing.route.points and existing.route.points[1])
  route_point.x, route_point.y = added.x, added.y
  for i, unit in ipairs(existing.units) do
    unit.x, unit.y = unit.x + dx, unit.y + dy
    assert(unit.name == added.units[i].name and unit.type == added.units[i].type)
  end
  assert(equal(existing, added), "Existing approved firefight template changed beyond its staging coordinates")
end
print(
  layout
    .. " firefight archive guard: the constrained infantry template was added or migrated without unrelated changes"
)

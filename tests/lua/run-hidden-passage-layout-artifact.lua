-- Archive-side guard for explicit testing/operational updates. No DCS APIs used.
local path = assert(arg[1])
local dictionary_path, layout
if arg[3] then
  dictionary_path, layout = arg[2], arg[3]
else
  layout = arg[2] or "testing"
end
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
local cas_groups = {}
local any_cas_elements = false
for _, country in pairs(mission.coalition.blue.country) do
  for _, group in pairs(country.plane and country.plane.group or {}) do
    local expected_type = config.cas.slots[group.name]
    if expected_type then
      any_cas_elements = true
      assert(not cas_groups[group.name], "Duplicate configured CAS slot")
      assert(group.task == "CAS", "Configured CAS aircraft must retain its CAS task")
      assert(#group.units == 1, "Configured CAS slots must contain one player aircraft")
      local unit = group.units[1]
      assert(unit.type == expected_type and unit.skill == "Client", "Unexpected CAS aircraft type or slot skill")
      cas_groups[group.name] = true
    end
  end
end
local convoy_template
local checkpoint_template
for _, country in pairs(mission.coalition.red.country or {}) do
  for _, group in pairs(country.vehicle and country.vehicle.group or {}) do
    if group.name == config.cas.convoy_template then
      any_cas_elements = true
      assert(not convoy_template, "Duplicate CAS convoy template")
      convoy_template = group
    end
    if group.name == config.cas.checkpoint_template then
      any_cas_elements = true
      assert(not checkpoint_template, "Duplicate CAS checkpoint template")
      checkpoint_template = group
    end
  end
end
if any_cas_elements then
  for group_name in pairs(config.cas.slots) do
    assert(cas_groups[group_name], "CAS branch has an incomplete configured slot roster: " .. group_name)
  end
  assert(convoy_template and convoy_template.lateActivation, "CAS convoy must be a late-activated Red vehicle template")
  assert(#convoy_template.units > 0, "CAS convoy template must contain vehicles")
end
if checkpoint_template then
  assert(checkpoint_template.lateActivation, "RPG checkpoint must stay late-activated for helicopter-only runs")
  local rpg_count = 0
  for _, unit in pairs(checkpoint_template.units) do
    assert(unit.type == "Soldier RPG" or unit.type == "Soldier AK", "Unexpected checkpoint infantry type")
    if unit.type == "Soldier RPG" then
      rpg_count = rpg_count + 1
    end
  end
  assert(rpg_count > 0, "RPG checkpoint must contain RPG infantry")
end
local cap_slots, cap_templates = {}, {}
local any_cap_elements = false
for _, country in pairs(mission.coalition.blue.country) do
  for _, group in pairs(country.plane and country.plane.group or {}) do
    local expected = config.cap.slots[group.name]
    if expected then
      any_cap_elements = true
      assert(not cap_slots[group.name], "Duplicate configured CAP slot")
      assert(#group.units == 1, "CAP slots must contain one player aircraft")
      local unit = group.units[1]
      assert(unit.type == expected and unit.skill == "Client", "Unexpected CAP aircraft type or slot skill")
      cap_slots[group.name] = true
    end
  end
end
local cap_roles = {
  [config.cap.sam_template] = "vehicle",
  [config.cap.fighters_template] = "plane",
  [config.cap.hind_template] = "helicopter",
}
for _, country in pairs(mission.coalition.red.country or {}) do
  for _, category in ipairs({ "vehicle", "plane", "helicopter" }) do
    for _, group in pairs(country[category] and country[category].group or {}) do
      if cap_roles[group.name] then
        any_cap_elements = true
        assert(not cap_templates[group.name], "Duplicate CAP enemy template")
        assert(cap_roles[group.name] == category, "Wrong CAP enemy template category")
        assert(group.lateActivation, "CAP enemies must stay late-activated for non-CAP runs")
        cap_templates[group.name] = group
      end
    end
  end
end
if any_cap_elements then
  for name in pairs(config.cap.slots) do
    assert(cap_slots[name], "CAP branch has an incomplete configured slot roster: " .. name)
  end
  for name in pairs(cap_roles) do
    assert(cap_templates[name], "Missing CAP enemy template: " .. name)
  end
  local radars = 0
  for _, unit in ipairs(cap_templates[config.cap.sam_template].units) do
    if unit.type == config.cap.radar_type then
      radars = radars + 1
    end
  end
  assert(radars > 0, "CAP SAM template has no configured tracking radar")
  for _, name in ipairs({ config.cap.fighters_template, config.cap.hind_template }) do
    local group = cap_templates[name]
    local fighters = name == config.cap.fighters_template
    assert(#group.units == (fighters and 2 or 1), "Expected two enemy fighters and one Hind")
    assert(not group.uncontrolled, "CAP enemies must be able to taxi and take off after activation")
    local points = assert(group.route and group.route.points, "CAP aircraft need their editor route")
    assert(
      #points >= 2 and points[1].type == "TakeOffParkingHot",
      "CAP enemies must take off from their editor airfield"
    )
    for _, unit in ipairs(group.units) do
      assert(unit.skill ~= "Client" and unit.skill ~= "Player", "CAP enemies must be AI")
      assert(unit.type == (fighters and "MiG-29 Fulcrum" or "Mi-24V"), "Unexpected CAP enemy aircraft type")
      assert(unit.payload and next(unit.payload.pylons or {}), "CAP enemy aircraft must have an armed loadout")
      if fighters then
        local armed = false
        for _, pylon in pairs(unit.payload.pylons) do
          if pylon.CLSID and pylon.CLSID:find("MISSILE_", 1, true) then
            armed = true
          end
        end
        assert(armed, "The configured Fulcrums need air-to-air missiles, not just tanks")
      end
    end
  end
end
if dictionary_path then
  local dictionary_env = {}
  local briefing = assert(loadfile(dictionary_path))
  setfenv(briefing, dictionary_env)
  briefing()
  local title = layout == "testing" and "Operation Hidden Passage - Testing" or "Operation Hidden Passage"
  assert(dictionary_env.dictionary[mission.sortie] == title, "Unexpected mission title")
  local combined_briefing = assert(dictionary_env.dictionary[mission.descriptionText])
    .. "\n\n"
    .. assert(dictionary_env.dictionary[mission.descriptionBlueTask])
  for _, key in ipairs({ mission.descriptionText, mission.descriptionBlueTask }) do
    local text = dictionary_env.dictionary[key]
    if combined_briefing:find("Three local sources have been compromised", 1, true) then
      assert(
        combined_briefing:find("Mule One is tasked to extract all three", 1, true),
        "Missing extraction story/task"
      )
      assert(combined_briefing:find("Raven One can cover the pickup", 1, true), "Missing Raven's role")
      assert(combined_briefing:find("request green smoke", 1, true), "Missing smoke request instruction")
      assert(
        combined_briefing:find("remain landed until all three are aboard", 1, true),
        "Missing boarding instruction"
      )
    else
      assert(text:find("boarding starts automatically", 1, true), "Missing automatic pickup briefing")
      assert(text:find("Both helicopters can extract", 1, true), "Missing dual-aircraft briefing")
      assert(not text:find("NOT connected", 1, true), "Stale UH-60 restriction in briefing")
    end
  end
end
print(string.format("%s archive guard: %.2f NM, named Chinook and UH-60L verified", layout, nm))

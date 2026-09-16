local validator = dofile("src/gameplay/package-wave-config.lua")
local count = 0
local function config()
  return dofile("src/missions/duel-dynamic-bvr/config.lua")
end
local function mission(c)
  local blue, red = {}, {}
  for _, name in ipairs(c.player_group_names) do
    blue[#blue + 1] = { name = name, units = { { skill = "Client" } } }
  end
  for _, name in ipairs(c.bandit_group_names) do
    red[#red + 1] = { name = name, lateActivation = true, units = { { skill = "Excellent" } } }
  end
  return {
    coalition = {
      blue = { country = { { plane = { group = blue } } } },
      red = { country = { { plane = { group = red } } } },
    },
  },
    blue,
    red
end
local function test(name, fn)
  local ok, message = pcall(fn)
  assert(ok, name .. ": " .. tostring(message))
  count = count + 1
end
test("all four configurations validate independently", function()
  for _, name in ipairs({ "duel-dynamic", "duel-dynamic-bvr", "duel-dynamic-acm", "air-superiority-survival" }) do
    local c = dofile("src/missions/" .. name .. "/config.lua")
    assert(c.mission_name == name and validator.validate(c))
    assert(validator.validate_templates(c, mission(c)))
  end
end)
test("unknown setting rejects instead of silently using a default", function()
  local c = config()
  c.gameplay.lives_per_palyer = 2
  assert(not validator.validate(c))
end)
for _, value in ipairs({ 0, -1, 1.5, math.huge, "3" }) do
  test("invalid cadence " .. tostring(value), function()
    local c = config()
    c.gameplay.wave_escalation_every = value
    assert(not validator.validate(c))
  end)
end
test("range validation incorporates unchanged defaults", function()
  local c = config()
  c.gameplay.spawn_distance_min_sm = 100
  assert(not validator.validate(c))
end)
test("custom supported values and zero replacement delay validate", function()
  local c = config()
  c.gameplay = {
    aircraft_per_player = 1,
    respawn_delay_s = 0,
    spawn_distance_min_sm = 5,
    spawn_distance_max_sm = 10,
    bandit_task = "INTERCEPT",
  }
  assert(validator.validate(c))
end)
test("legacy lives setting remains accepted for older mission archives", function()
  local c = config()
  c.gameplay = { lives_per_player = 1 }
  assert(validator.validate(c))
end)
test("unknown tier donor rejects", function()
  local c = config()
  c.gameplay.wave_donor_tiers = { { "Not-Tracked" } }
  assert(not validator.validate(c))
end)
test("missing player group rejects", function()
  local c = config()
  local m, blue = mission(c)
  table.remove(blue)
  assert(not validator.validate_templates(c, m))
end)
test("extra human slot rejects mismatched scenario roster", function()
  local c = config()
  local m, blue = mission(c)
  blue[#blue + 1] = { name = "Aerial-5", units = { { skill = "Client" } } }
  assert(not validator.validate_templates(c, m))
end)
test("missing or active donor rejects", function()
  local c = config()
  local m, _, red = mission(c)
  red[1].lateActivation = false
  assert(not validator.validate_templates(c, m))
  red[1] = nil
  assert(not validator.validate_templates(c, m))
end)
test("a player slot cannot be used as an AI donor", function()
  local c = config()
  local m, _, red = mission(c)
  red[1].units[1].skill = "Player"
  assert(not validator.validate_templates(c, m))
end)
print("package-wave configuration tests: " .. count .. " passed")

-- Pure gameplay configuration checks, shared by development and the packager.
local M = {}
M.DEFAULT_DONOR_TIERS = {
  { "Bandit-10", "Bandit-3", "Bandit-6" },
  { "Bandit-3", "Bandit-6", "Bandit-4", "Bandit-5" },
  { "Bandit-1", "Bandit-2", "Bandit-4", "Bandit-5", "Bandit-8", "Bandit-9" },
}

local function names(values, label)
  assert(type(values) == "table" and #values > 0, label .. " must be a nonempty array")
  local result, count = {}, 0
  for key, value in pairs(values) do
    assert(type(key) == "number" and key >= 1 and key <= #values and key % 1 == 0, label .. " must be dense")
    assert(type(value) == "string" and value ~= "" and not result[value], label .. " contains invalid/duplicate name")
    result[value] = true
    count = count + 1
  end
  assert(count == #values, label .. " must be dense")
  return result
end

function M.validate(config)
  local ok, message = pcall(function()
    assert(type(config) == "table", "mission configuration must be a table")
    assert(
      type(config.mission_name) == "string" and config.mission_name:match("^[a-z][a-z0-9%-]*$"),
      "invalid mission identity"
    )
    assert(type(config.mission_version) == "string" and config.mission_version ~= "", "mission version required")
    assert(type(config.title) == "string" and config.title ~= "", "mission title required")
    local players = names(config.player_group_names, "player roster")
    local bandits = names(config.bandit_group_names, "opposing roster")
    for name in pairs(players) do
      assert(not bandits[name], "player/opposing rosters overlap")
    end
    local settings = config.gameplay or {}
    assert(type(settings) == "table", "gameplay settings must be a table")
    local numeric = {
      spawn_distance_min_sm = 55,
      spawn_distance_max_sm = 85,
      spawn_alt_min_ft = 15000,
      spawn_alt_max_ft = 25000,
      cap_alt_min_ft = 15000,
      cap_alt_max_ft = 30000,
      cap_speed_min_kt = 350,
      cap_speed_max_kt = 550,
      aircraft_per_player = 3,
      -- Accepted for compatibility with older mission configs. New configs
      -- should use aircraft_per_player.
      lives_per_player = 3,
      wave_escalation_every = 3,
      wave_tier_every = 3,
      max_package_size = 8,
      respawn_delay_s = 30,
    }
    local integers =
      {
        aircraft_per_player = true,
        lives_per_player = true,
        wave_escalation_every = true,
        wave_tier_every = true,
        max_package_size = true,
      }
    for key, value in pairs(settings) do
      assert(
        numeric[key] or key == "bandit_task" or key == "wave_donor_tiers",
        "unknown gameplay setting: " .. tostring(key)
      )
      if numeric[key] then
        assert(type(value) == "number" and value < math.huge and value >= 0, "invalid setting: " .. key)
        assert(key == "respawn_delay_s" or value > 0, "setting must be positive: " .. key)
        assert(not integers[key] or value % 1 == 0, "setting must be an integer: " .. key)
      end
    end
    for _, pair in ipairs({
      { "spawn_distance_min_sm", "spawn_distance_max_sm" },
      { "spawn_alt_min_ft", "spawn_alt_max_ft" },
      { "cap_alt_min_ft", "cap_alt_max_ft" },
      { "cap_speed_min_kt", "cap_speed_max_kt" },
    }) do
      assert(
        (settings[pair[1]] or numeric[pair[1]]) <= (settings[pair[2]] or numeric[pair[2]]),
        "reversed range: " .. pair[1]
      )
    end
    assert(
      settings.bandit_task == nil or settings.bandit_task == "CAP" or settings.bandit_task == "INTERCEPT",
      "invalid bandit task"
    )
    local tiers = settings.wave_donor_tiers or M.DEFAULT_DONOR_TIERS
    assert(type(tiers) == "table" and #tiers > 0, "donor tiers required")
    local tier_count = 0
    for key, tier in pairs(tiers) do
      assert(type(key) == "number" and key >= 1 and key <= #tiers and key % 1 == 0, "donor tiers must be dense")
      for name in pairs(names(tier, "donor tier")) do
        assert(bandits[name], "donor tier references untracked template: " .. name)
      end
      tier_count = tier_count + 1
    end
    assert(tier_count == #tiers, "donor tiers must be dense")
  end)
  if not ok then
    return nil, message
  end
  return true
end

function M.validate_templates(config, mission)
  local valid, reason = M.validate(config)
  if not valid then
    return nil, reason
  end
  local ok, message = pcall(function()
    local indexed = { blue = {}, red = {} }
    for side, groups in pairs(indexed) do
      for _, country in pairs(((mission.coalition or {})[side] or {}).country or {}) do
        for _, group in pairs((country.plane or {}).group or {}) do
          assert(not groups[group.name], "duplicate aircraft group: " .. group.name)
          groups[group.name] = group
        end
      end
    end
    local players = names(config.player_group_names, "player roster")
    for name in pairs(players) do
      local group = assert(indexed.blue[name], "missing blue player group: " .. name)
      assert(
        #group.units == 1 and (group.units[1].skill == "Client" or group.units[1].skill == "Player"),
        "expected one human slot: " .. name
      )
    end
    for name, group in pairs(indexed.blue) do
      for _, unit in pairs(group.units or {}) do
        assert((unit.skill ~= "Client" and unit.skill ~= "Player") or players[name], "untracked human slot: " .. name)
      end
    end
    for _, name in ipairs(config.bandit_group_names) do
      local group = assert(indexed.red[name], "missing red donor: " .. name)
      assert(group.lateActivation == true and #group.units > 0, "donor must be late activated: " .. name)
      for _, unit in pairs(group.units) do
        assert(unit.skill ~= "Client" and unit.skill ~= "Player", "donor must be AI: " .. name)
      end
    end
  end)
  if not ok then
    return nil, message
  end
  return true
end

return M

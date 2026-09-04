local event_id = dofile("src/missions/duel-dynamic/telemetry/event_id.lua")
local envelope = dofile("src/missions/duel-dynamic/telemetry/envelope.lua")
local lifecycle = dofile("src/missions/duel-dynamic/telemetry/lifecycle.lua")
local shot = dofile("src/missions/duel-dynamic/telemetry/shot.lua")

local WEAPON_CATEGORY = {
  SHELL = 0,
  MISSILE = 1,
  ROCKET = 2,
  BOMB = 3,
  TORPEDO = 4,
}
local UNIT_CATEGORY = {
  AIRPLANE = 1,
  HELICOPTER = 2,
  GROUND_UNIT = 3,
  SHIP = 4,
}

local tests_run = 0
local failures = {}

local function check(condition, message)
  if not condition then
    error(message or "assertion failed", 2)
  end
end

local function equal(actual, expected, message)
  check(
    actual == expected,
    (message or "values differ") .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected)
  )
end

local function succeeds(name, callback)
  tests_run = tests_run + 1
  local ok, message = pcall(callback)
  if not ok then
    failures[#failures + 1] = name .. ": " .. tostring(message)
  end
end

local function new_base()
  local base = {}
  local watchers = {}

  function base:New()
    local watcher = {}
    function watcher:HandleEvent(event_id)
      self.handled_event = event_id
      return self
    end
    function watcher:UnHandleEvent(event_id)
      self.unhandled_event = event_id
      return self
    end
    watchers[#watchers + 1] = watcher
    return watcher
  end

  return base, watchers
end

local function new_memory_sink(fail_call)
  local events = {}
  local calls = 0
  local sink = {}

  function sink:write(event)
    calls = calls + 1
    if fail_call and calls == fail_call then
      return nil, "simulated shot sink failure"
    end
    events[#events + 1] = event
    return true
  end

  return sink, events, function()
    return calls
  end
end

local function new_controller(label, fail_call, sim_time)
  local sink, events, calls = new_memory_sink(fail_call)
  local current_time = sim_time or 0
  local producer, producer_error = envelope.new({
    event_id = event_id,
    producer_id = "shot-producer-" .. label,
    run_key = "run-shot-" .. label,
    source_version = "duel-dynamic-telemetry-v1",
  })
  check(producer ~= nil, producer_error)

  local controller, lifecycle_error = lifecycle.new({
    producer = producer,
    sink = sink,
    sim_time = function()
      return current_time
    end,
    wall_time = function()
      return "2026-09-01T12:00:00Z"
    end,
    started_payload = {
      mission_name = "duel-dynamic",
      mission_version = "1",
      map_name = "Caucasus",
      run_classification = "test",
    },
  })
  check(controller ~= nil, lifecycle_error)
  return controller, events, calls, function(value)
    current_time = value
  end
end

local function new_adapter(controller, base, logs)
  local adapter, creation_error = shot.new({
    controller = controller,
    envelope = envelope,
    BASE = base,
    EVENTS = { Shot = 17 },
    player_group_names = { "Aerial-1", "Aerial-2", "Aerial-3" },
    bandit_group_names = { "Bandit-1", "Bandit-2", "Bandit-3" },
    unit_categories = UNIT_CATEGORY,
    weapon_categories = WEAPON_CATEGORY,
    player_coalition = 2,
    bandit_coalition = 1,
    log = function(level, message)
      logs[#logs + 1] = level .. " " .. message
    end,
  })
  check(adapter ~= nil, creation_error)
  return adapter
end

local function new_unit(options)
  options = options or {}
  local unit = {}
  function unit:GetName()
    return options.unit_name or "Aerial-1-1"
  end
  function unit:GetTypeName()
    if options.throw_type then
      error("type unavailable")
    end
    return options.type_name or "FA-18C_hornet"
  end
  function unit:GetPlayerName()
    return options.player_name
  end
  function unit:GetDCSObject()
    return options.dcs_unit
  end
  function unit:GetCoalition()
    return options.coalition
  end
  function unit:GetCoordinate()
    if options.throw_coordinate then
      error("coordinate unavailable")
    end
    return {
      GetVec3 = function()
        return options.location or { x = 100, y = 200, z = 300 }
      end,
    }
  end
  function unit:GetVec3()
    if options.throw_vec3 then
      error("vec3 unavailable")
    end
    return options.location or { x = 100, y = 200, z = 300 }
  end
  return unit
end

local function new_dcs_unit(options)
  options = options or {}
  local unit = {}
  function unit:getCallsign()
    if options.throw_callsign then
      error("callsign unavailable")
    end
    return options.callsign
  end
  return unit
end

local function new_weapon(options)
  options = options or {}
  local weapon = {}
  function weapon:getTypeName()
    if options.throw_type then
      error("weapon type unavailable")
    end
    return options.type_name or "weapons.missiles.AIM_120C"
  end
  function weapon:getDesc()
    if options.throw_desc then
      error("weapon descriptor unavailable")
    end
    return { category = options.category or WEAPON_CATEGORY.MISSILE }
  end
  return weapon
end

local function new_event(options)
  options = options or {}
  local group_name = options.group_name or "Aerial-1"
  local coalition = options.coalition
  local type_name
  if not options.missing_type_name then
    type_name = options.type_name or "FA-18C_hornet"
  end
  local event = {
    IniGroupName = group_name,
    IniUnitName = options.unit_name or "Aerial-1-1",
    IniUnit = options.unit,
    IniDCSUnit = options.dcs_unit,
    IniCategory = options.unit_category or UNIT_CATEGORY.AIRPLANE,
    IniPlayerName = options.player_name,
    IniPlayerUCID = options.player_ucid,
    IniCoalition = coalition,
    IniTypeName = type_name,
    WeaponName = options.weapon_name,
    Weapon = options.weapon,
    time = options.time,
  }
  for key, value in pairs(options.fields or {}) do
    event[key] = value
  end
  if options.throw_missing_fields then
    setmetatable(event, {
      __index = function(_, key)
        error("field " .. key .. " unavailable")
      end,
    })
  end
  return event
end

succeeds("registration is delayed until after telemetry start and retains its watcher", function()
  local base, watchers = new_base()
  local controller = new_controller("registration")
  local adapter = new_adapter(controller, base, {})

  local before_start = adapter:capture(new_event({
    IniUnit = new_unit({ coalition = 2 }),
    coalition = 2,
    player_name = "Viper",
    player_ucid = "ucid-before-start",
    weapon_name = "weapons.missiles.AIM_120C",
    weapon = new_weapon(),
    time = 1,
  }))
  equal(before_start, nil)
  equal(#watchers, 0)

  local started, start_error = controller:start()
  check(started ~= nil, start_error)
  local watcher, registration_error = adapter:start()
  check(watcher ~= nil, registration_error)
  equal(#watchers, 1)
  equal(watcher.handled_event, 17)
  check(adapter.watcher == watcher, "adapter did not retain the watcher")
end)

succeeds("stop unsubscribes the retained Shot watcher", function()
  local base, watchers = new_base()
  local controller = new_controller("stop")
  local adapter = new_adapter(controller, base, {})
  check(controller:start())
  local watcher, start_error = adapter:start()
  check(watcher ~= nil, start_error)

  local stopped, stop_error = adapter:stop()
  check(stopped, stop_error)
  equal(watcher.unhandled_event, 17)
  check(adapter.watcher == nil, "stopped adapter retained its watcher")
  check(adapter:stop(), "stopping an already stopped adapter failed")
  equal(#watchers, 1)
end)

succeeds("two same-time tracked shots receive consecutive identities and complete fields", function()
  local base = new_base()
  local controller, events = new_controller("same-time")
  local adapter = new_adapter(controller, base, {})
  check(controller:start())
  local watcher = adapter:start()
  local unit = new_unit({
    unit_name = "Aerial-1-1",
    type_name = "FA-18C_hornet",
    player_name = "Viper",
    dcs_unit = new_dcs_unit({ callsign = "Aerial 1-1" }),
    coalition = 2,
    location = { x = 125000.25, y = 7620.5, z = -44000.75 },
  })
  local function player_shot()
    return watcher:OnEventShot(new_event({
      group_name = "Aerial-1",
      unit_name = "Aerial-1-1",
      unit = unit,
      player_name = "Viper",
      player_ucid = "ucid-0123456789abcdef",
      coalition = 2,
      type_name = "FA-18C_hornet",
      weapon_name = "weapons.missiles.AIM_120C",
      dcs_unit = unit:GetDCSObject(),
      weapon = new_weapon({ category = WEAPON_CATEGORY.MISSILE }),
      time = 125.5,
    }))
  end

  local first, first_error = player_shot()
  check(first ~= nil, first_error)
  local second, second_error = player_shot()
  check(second ~= nil, second_error)
  equal(#events, 3)
  equal(first.event_type, "ordnance.fired")
  equal(first.event_sequence, 2)
  equal(second.event_sequence, 3)
  check(first.event_id ~= second.event_id, "same-time shot IDs collided")
  equal(first.event_id, "shot-producer-same-time:run-shot-same-time:2")
  equal(second.event_id, "shot-producer-same-time:run-shot-same-time:3")
  equal(first.sim_time, 125.5)
  equal(first.initiator.status, "known")
  equal(first.initiator.kind, "aircraft")
  equal(first.initiator.dcs_name, "Aerial-1-1")
  equal(first.initiator.dcs_type, "FA-18C_hornet")
  equal(first.initiator.participant_id, "ucid-0123456789abcdef")
  equal(first.initiator.coalition, "blue")
  equal(first.asset.status, "unknown")
  equal(first.asset.reason, "instance-identity-unavailable")
  equal(first.asset.asset_key, envelope.JSON_NULL)
  equal(first.asset.dcs_name, "Aerial-1-1")
  equal(first.weapon.status, "known")
  equal(first.weapon.dcs_type, "weapons.missiles.AIM_120C")
  equal(first.weapon.category, "missile")
  equal(first.participant.status, "known")
  equal(first.participant.participant_id, "ucid-0123456789abcdef")
  equal(first.participant.display_name, "Viper")
  equal(first.participant.callsign, "Aerial 1-1")
  equal(first.target, envelope.JSON_NULL)
  equal(first.location.status, "known")
  equal(first.location.x, 125000.25)
  equal(first.location.y, 7620.5)
  equal(first.location.z, -44000.75)
  equal(first.payload.dcs_event_name, "shot")
end)

succeeds("exact player and spawned bandit roster entries are accepted while similar names are rejected", function()
  local base = new_base()
  local controller, events = new_controller("roster")
  local adapter = new_adapter(controller, base, {})
  check(controller:start())
  local watcher = adapter:start()

  local player, player_error = watcher:OnEventShot(new_event({
    group_name = "Aerial-2",
    unit_name = "Aerial-2-1",
    unit = new_unit({ unit_name = "Aerial-2-1", coalition = 2 }),
    coalition = 2,
    time = 10,
    weapon_name = "weapons.bombs.GBU_12",
    weapon = new_weapon({ category = WEAPON_CATEGORY.BOMB, type_name = "weapons.bombs.GBU_12" }),
  }))
  check(player ~= nil, player_error)

  local bandit, bandit_error = watcher:OnEventShot(new_event({
    group_name = "Bandit-2#007",
    unit_name = "Bandit-2-1#007",
    unit = new_unit({ unit_name = "Bandit-2-1#007", coalition = 1, player_name = nil, callsign = "Bandit 2-1" }),
    coalition = 1,
    type_name = "MiG-29A",
    weapon_name = "weapons.rocket.S-8",
    weapon = new_weapon({ category = WEAPON_CATEGORY.ROCKET, type_name = "weapons.rocket.S-8" }),
    time = 10,
  }))
  check(bandit ~= nil, bandit_error)
  equal(bandit.participant, envelope.JSON_NULL)
  equal(bandit.initiator.coalition, "red")
  equal(bandit.weapon.category, "rocket")

  for _, group_name in ipairs({ "Aerial-10", "Bandit-10", "Bandit-2#0070", "Unrelated-Air" }) do
    local rejected = watcher:OnEventShot(new_event({
      group_name = group_name,
      unit = new_unit({ coalition = 2 }),
      coalition = 2,
      time = 11,
      weapon_name = "weapons.missiles.AIM_9L",
      weapon = new_weapon(),
    }))
    equal(rejected, nil, "out-of-roster group was accepted: " .. group_name)
  end

  local tracked_ground = watcher:OnEventShot(new_event({
    group_name = "Aerial-3",
    unit = new_unit({ coalition = 2 }),
    coalition = 2,
    unit_category = UNIT_CATEGORY.GROUND_UNIT,
    time = 12,
    weapon_name = "weapons.missiles.AIM_9L",
    weapon = new_weapon(),
  }))
  equal(tracked_ground, nil, "tracked ground event was accepted")

  local wrong_side = watcher:OnEventShot(new_event({
    group_name = "Aerial-1",
    unit = new_unit({ coalition = 1 }),
    coalition = 1,
    time = 13,
    weapon_name = "weapons.missiles.AIM_9L",
    weapon = new_weapon(),
  }))
  equal(wrong_side, nil, "tracked wrong-coalition event was accepted")
  equal(#events, 3)
end)

succeeds("an extended player roster captures the blue test-combat group", function()
  local base = new_base()
  local controller, events = new_controller("extended-roster")
  local adapter = new_adapter(controller, base, {})
  local extended, extend_error = adapter:extend_player_roster({ "TestCombat-Blue" })
  check(extended, extend_error)
  check(controller:start())
  local watcher = adapter:start()
  local event, event_error = watcher:OnEventShot(new_event({
    group_name = "TestCombat-Blue",
    unit_name = "TestCombat-Blue-1",
    unit = new_unit({ unit_name = "TestCombat-Blue-1", coalition = 2 }),
    coalition = 2,
    type_name = "F-16C_50",
    weapon_name = "weapons.missiles.AIM_9L",
    weapon = new_weapon(),
    time = 40,
  }))
  check(event ~= nil, event_error)
  equal(event.initiator.dcs_type, "F-16C_50")
  equal(event.initiator.coalition, "blue")
end)

succeeds("shot roster extension rejects collisions, duplicates, empty, and non-string names", function()
  local base = new_base()
  local controller = new_controller("extended-roster-errors")
  local adapter = new_adapter(controller, base, {})
  local result, message = adapter:extend_player_roster({ "Bandit-1" })
  equal(result, nil)
  equal(message, "Bandit-1 collides with bandit roster")
  result, message = adapter:extend_player_roster({ "TestCombat-Blue" })
  check(result, message)
  result, message = adapter:extend_player_roster({ "TestCombat-Blue" })
  equal(result, nil)
  equal(message, "TestCombat-Blue already tracked")
  result, message = adapter:extend_player_roster({ "" })
  equal(result, nil)
  equal(message, "player group name 1 is invalid")
  result, message = adapter:extend_player_roster({ 42 })
  equal(result, nil)
  equal(message, "player group name 1 is invalid")
end)

succeeds("missing UCID is explicit unknown and AI has no participant placeholder", function()
  local base = new_base()
  local controller, events = new_controller("identity")
  local adapter = new_adapter(controller, base, {})
  check(controller:start())
  local watcher = adapter:start()

  local missing_ucid, missing_error = watcher:OnEventShot(new_event({
    group_name = "Aerial-1",
    unit = new_unit({ coalition = 2, player_name = "Reported Pilot" }),
    player_name = "Reported Pilot",
    player_ucid = nil,
    coalition = 2,
    time = 20,
    weapon_name = "weapons.missiles.AIM_9X",
    weapon = new_weapon(),
  }))
  check(missing_ucid ~= nil, missing_error)
  equal(missing_ucid.participant.status, "unknown")
  equal(missing_ucid.participant.reason, "stable-identity-unavailable")
  equal(missing_ucid.participant.display_name, "Reported Pilot")
  equal(missing_ucid.participant.participant_id, envelope.JSON_NULL)
  equal(missing_ucid.initiator.callsign, envelope.JSON_NULL)
  check(missing_ucid.participant.display_name ~= "Player")

  local ai, ai_error = watcher:OnEventShot(new_event({
    group_name = "Bandit-1",
    unit = new_unit({ coalition = 1, player_name = nil }),
    player_name = nil,
    player_ucid = nil,
    coalition = 1,
    time = 21,
    weapon_name = "weapons.missiles.AIM_9X",
    weapon = new_weapon(),
  }))
  check(ai ~= nil, ai_error)
  equal(ai.participant, envelope.JSON_NULL)
  equal(ai.initiator.callsign, envelope.JSON_NULL)
  equal(#events, 3)
end)

succeeds("missing and throwing optional fields normalize safely and log errors", function()
  local logs = {}
  local base = new_base()
  local controller, events = new_controller("optional", nil, 77.5)
  local adapter = new_adapter(controller, base, logs)
  check(controller:start())
  local watcher = adapter:start()
  local event_data = new_event({
    group_name = "Aerial-1",
    unit_name = "Aerial-1-1",
    unit = new_unit({
      coalition = 2,
      player_name = "Pilot Without UCID",
      throw_type = true,
      throw_coordinate = true,
      throw_vec3 = true,
    }),
    dcs_unit = new_dcs_unit({ callsign = "" }),
    player_name = "Pilot Without UCID",
    missing_type_name = true,
    coalition = 2,
    weapon = new_weapon({ throw_type = true, throw_desc = true }),
    throw_missing_fields = true,
  })

  local event, event_error = watcher:OnEventShot(event_data)
  check(event ~= nil, event_error)
  equal(event.sim_time, 77.5)
  equal(event.participant.status, "unknown")
  equal(event.participant.reason, "stable-identity-unavailable")
  equal(event.participant.participant_id, envelope.JSON_NULL)
  equal(event.participant.display_name, "Pilot Without UCID")
  equal(event.participant.callsign, envelope.JSON_NULL)
  equal(event.initiator.callsign, envelope.JSON_NULL)
  equal(event.asset.status, "unknown")
  equal(event.asset.dcs_name, "Aerial-1-1")
  equal(event.asset.dcs_type, envelope.JSON_NULL)
  equal(event.weapon.status, "unknown")
  equal(event.weapon.reason, "type-not-reported")
  equal(event.weapon.dcs_type, envelope.JSON_NULL)
  equal(event.weapon.category, "unknown")
  equal(event.location.status, "unknown")
  equal(event.location.reason, "unavailable")
  check(event.participant.display_name ~= "Player")
  check(#logs > 0, "throwing optional fields did not produce telemetry errors")
  equal(#events, 2)
end)

succeeds("sink failure retains the exact pending shot and blocks later allocation", function()
  local base = new_base()
  local controller, events, calls = new_controller("pending", 2)
  local adapter = new_adapter(controller, base, {})
  check(controller:start())
  local watcher = adapter:start()
  local data = new_event({
    group_name = "Aerial-1",
    unit = new_unit({ coalition = 2, player_name = "Viper" }),
    player_name = "Viper",
    player_ucid = "ucid-pending",
    coalition = 2,
    time = 30,
    weapon_name = "weapons.missiles.AIM_120C",
    weapon = new_weapon(),
  })

  local failed = watcher:OnEventShot(data)
  equal(failed, nil)
  equal(controller:state(), "faulted")
  local pending = controller:pending_event()
  check(pending ~= nil, "failed shot did not retain an envelope")
  equal(pending.event_type, "ordnance.fired")
  equal(pending.event_sequence, 2)
  equal(#events, 1)
  equal(calls(), 2)

  local blocked = watcher:OnEventShot(data)
  equal(blocked, nil)
  check(controller:pending_event() == pending, "blocked shot replaced the pending envelope")
  equal(calls(), 2)
  equal(#events, 1)

  local retried, retry_error = controller:retry_pending()
  check(retried ~= nil, retry_error)
  check(retried == pending, "retry did not preserve the exact pending envelope")
  equal(controller:state(), "active")
  local later, later_error = watcher:OnEventShot(data)
  check(later ~= nil, later_error)
  equal(later.event_sequence, 3)
  equal(later.event_id, "shot-producer-pending:run-shot-pending:3")
  equal(#events, 3)
end)

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  error(string.format("telemetry shot tests failed: %d/%d", #failures, tests_run))
end

io.write(string.format("telemetry shot tests: %d passed\n", tests_run))

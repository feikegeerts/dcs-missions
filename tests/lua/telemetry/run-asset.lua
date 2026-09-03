local event_id = dofile("src/missions/duel-dynamic/telemetry/event_id.lua")
local envelope = dofile("src/missions/duel-dynamic/telemetry/envelope.lua")
local lifecycle = dofile("src/missions/duel-dynamic/telemetry/lifecycle.lua")
local asset = dofile("src/missions/duel-dynamic/telemetry/asset.lua")
local shot = dofile("src/missions/duel-dynamic/telemetry/shot.lua")

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
  function base:New()
    local watcher = { handled = {}, unhandled = {} }
    function watcher:HandleEvent(event)
      self.handled[#self.handled + 1] = event
      return self
    end
    function watcher:UnHandleEvent(event)
      self.unhandled[#self.unhandled + 1] = event
      return self
    end
    return watcher
  end
  return base
end

local function new_controller(label)
  local events = {}
  local sink = {}
  function sink:write(event)
    events[#events + 1] = event
    return true
  end
  local producer, producer_error = envelope.new({
    event_id = event_id,
    producer_id = "asset-producer-" .. label,
    run_key = "run-asset-" .. label,
    source_version = "duel-dynamic-telemetry-v1",
  })
  check(producer ~= nil, producer_error)
  local controller, controller_error = lifecycle.new({
    producer = producer,
    sink = sink,
    sim_time = function()
      return 99
    end,
    wall_time = function()
      return "2026-09-03T12:00:00Z"
    end,
    started_payload = {
      mission_name = "duel-dynamic",
      mission_version = "1",
      map_name = "Caucasus",
      run_classification = "test",
    },
  })
  check(controller ~= nil, controller_error)
  check(controller:start())
  return controller, events
end

local function new_raw_unit(options)
  options = options or {}
  local raw = {}
  function raw:getID()
    return options.id
  end
  function raw:getGroupName()
    return options.group_name
  end
  function raw:getName()
    return options.name
  end
  function raw:getTypeName()
    return options.type_name or "FA-18C_hornet"
  end
  function raw:getCoalition()
    return options.coalition
  end
  function raw:getPosition()
    return { p = options.position or { x = 100, y = 200, z = 300 } }
  end
  function raw:getCallsign()
    return options.callsign
  end
  return raw
end

local function new_unit(options)
  options = options or {}
  local raw = options.raw or new_raw_unit(options)
  local unit = {}
  function unit:GetDCSObject()
    return raw
  end
  function unit:GetName()
    return options.name
  end
  function unit:GetTypeName()
    return options.type_name or "FA-18C_hornet"
  end
  function unit:GetCoalition()
    return options.coalition
  end
  function unit:GetCoordinate()
    return {
      GetVec3 = function()
        return options.position or { x = 100, y = 200, z = 300 }
      end,
    }
  end
  function unit:GetPlayerName()
    return options.player_name
  end
  return unit, raw
end

local function new_group(options)
  local raw_group = {}
  function raw_group:getID()
    return options.id
  end
  local group = {}
  function group:GetDCSObject()
    return raw_group
  end
  function group:GetName()
    return options.name
  end
  function group:GetUnits()
    return options.units
  end
  return group
end

local function new_asset_adapter(controller)
  local adapter, adapter_error = asset.new({
    controller = controller,
    envelope = envelope,
    BASE = new_base(),
    EVENTS = { PlayerEnterUnit = 20 },
    player_group_names = { "Aerial-1", "Aerial-2", "Aerial-3", "Aerial-4" },
    bandit_group_names = { "Bandit-1", "Bandit-2", "Bandit-3" },
    player_coalition = 2,
    bandit_coalition = 1,
  })
  check(adapter ~= nil, adapter_error)
  return adapter
end

local function bandit_unit(id, name)
  local unit = new_unit({
    id = id,
    group_name = "Bandit-1#001",
    name = name,
    coalition = 1,
  })
  return unit
end

local function player_unit(id, group_name, name)
  return new_unit({
    id = id,
    group_name = group_name,
    name = name,
    coalition = 2,
    player_name = "Viper",
    callsign = "Aerial 1-1",
  })
end

local function count_type(events, event_type)
  local count = 0
  for _, event in ipairs(events) do
    if event.event_type == event_type then
      count = count + 1
    end
  end
  return count
end

succeeds("repeated multi-unit bandit waves receive distinct incarnation keys", function()
  local controller, events = new_controller("bandit-waves")
  local adapter = new_asset_adapter(controller)
  local first_units = {
    bandit_unit(101, "Bandit-1#001-01"),
    bandit_unit(102, "Bandit-1#001-02"),
  }
  local first, first_error = adapter:register_bandit_group(
    new_group({
      id = 11,
      name = "Bandit-1#001",
      units = first_units,
    }),
    "Bandit-1",
    10
  )
  check(first ~= nil, first_error)
  equal(first[1].asset_key, "bandit-1.u1.g1")
  equal(first[2].asset_key, "bandit-1.u2.g1")

  local second, second_error = adapter:register_bandit_group(
    new_group({
      id = 12,
      name = "Bandit-1#002",
      units = {
        bandit_unit(201, "Bandit-1#001-01"),
        bandit_unit(202, "Bandit-1#001-02"),
      },
    }),
    "Bandit-1",
    20
  )
  check(second ~= nil, second_error)
  equal(second[1].asset_key, "bandit-1.u1.g2")
  equal(second[2].asset_key, "bandit-1.u2.g2")
  check(second[1].asset_key ~= first[1].asset_key)
  check(second[2].asset_key ~= first[2].asset_key)
  equal(count_type(events, "asset.spawned"), 4)
end)

succeeds("player re-entry into the same aircraft does not duplicate its incarnation", function()
  local controller, events = new_controller("player-reentry")
  local adapter = new_asset_adapter(controller)
  local unit, raw = player_unit(301, "Aerial-1", "Aerial-1-1")
  local first, created = adapter:observe_player_unit(raw, 10, "Aerial-1")
  check(first ~= nil)
  equal(created, true)
  equal(first.asset_key, "aerial-1.u1.g1")

  local again, duplicate_created = adapter:observe_player_unit(unit, 20, "Aerial-1")
  check(again ~= nil)
  equal(duplicate_created, false)
  equal(again.asset_key, first.asset_key)
  equal(count_type(events, "asset.spawned"), 1)
end)

succeeds("a confirmed player aircraft replacement advances the generation", function()
  local controller, events = new_controller("player-replacement")
  local adapter = new_asset_adapter(controller)
  local _, first_raw = player_unit(401, "Aerial-1", "Aerial-1-1")
  -- The mission-editor numeric ID may be reused. A distinct raw DCS object is
  -- the replacement confirmation; the reused name and ID are not identity.
  local _, replacement_raw = player_unit(401, "Aerial-1", "Aerial-1-1")
  local first = adapter:observe_player_unit(first_raw, 10, "Aerial-1")
  local replacement, created = adapter:observe_player_unit(replacement_raw, 20, "Aerial-1")
  check(first ~= nil)
  check(replacement ~= nil)
  equal(created, true)
  equal(first.asset_key, "aerial-1.u1.g1")
  equal(replacement.asset_key, "aerial-1.u1.g2")
  equal(count_type(events, "asset.spawned"), 2)
  equal(adapter:resolve_unit(first_raw), nil)
  equal(adapter:resolve_unit(replacement_raw).asset_key, replacement.asset_key)
end)

succeeds("scripted removal emits intentional despawn before gameplay removal", function()
  local controller, events = new_controller("intentional-despawn")
  local adapter = new_asset_adapter(controller)
  local unit = bandit_unit(501, "Bandit-1#003-01")
  local group = new_group({ id = 51, name = "Bandit-1#003", units = { unit } })
  local instances = adapter:register_bandit_group(group, "Bandit-1", 10)
  check(instances ~= nil)

  local order = {}
  local removed = false
  local despawned, despawn_error = adapter:despawn_group(group, 15)
  check(despawned, despawn_error)
  order[#order + 1] = events[#events].event_type
  local function remove_group()
    removed = true
    order[#order + 1] = "group.removed"
  end
  remove_group()

  equal(table.concat(order, ","), "asset.despawned,group.removed")
  equal(events[#events].payload.reason, "intentional")
  equal(count_type(events, "asset.despawned"), 1)
  equal(count_type(events, "asset.dead"), 0)
  equal(count_type(events, "asset.crashed"), 0)
  check(removed)
  equal(adapter:resolve_unit(unit), nil)
end)

local function new_weapon()
  local weapon = {}
  function weapon:getTypeName()
    return "weapons.missiles.AIM_120C"
  end
  function weapon:getDesc()
    return { category = 1 }
  end
  return weapon
end

local function shot_event(unit, raw, group_name, time)
  return {
    IniGroupName = group_name,
    IniUnitName = unit:GetName(),
    IniUnit = unit,
    IniDCSUnit = raw,
    IniCategory = 1,
    IniCoalition = 2,
    IniTypeName = "FA-18C_hornet",
    IniPlayerName = "Viper",
    IniPlayerUCID = "ucid-viper",
    WeaponName = "weapons.missiles.AIM_120C",
    Weapon = new_weapon(),
    time = time,
  }
end

succeeds("shots resolve only registered incarnations and otherwise remain explicit unknown", function()
  local controller, events = new_controller("shot-association")
  local registry = new_asset_adapter(controller)
  local base = new_base()
  local shot_adapter, shot_error = shot.new({
    controller = controller,
    envelope = envelope,
    BASE = base,
    EVENTS = { Shot = 17 },
    player_group_names = { "Aerial-1", "Aerial-2", "Aerial-3", "Aerial-4" },
    bandit_group_names = { "Bandit-1", "Bandit-2", "Bandit-3" },
    unit_categories = { AIRPLANE = 1, HELICOPTER = 2, GROUND_UNIT = 3, SHIP = 4 },
    weapon_categories = { SHELL = 0, MISSILE = 1, ROCKET = 2, BOMB = 3, TORPEDO = 4 },
    player_coalition = 2,
    bandit_coalition = 1,
    asset_registry = registry,
  })
  check(shot_adapter ~= nil, shot_error)
  local watcher = shot_adapter:start()

  local tracked_unit, tracked_raw = player_unit(601, "Aerial-1", "Aerial-1-1")
  local registered = registry:observe_player_unit(tracked_raw, 10, "Aerial-1")
  check(registered ~= nil)
  local tracked_shot, tracked_error = watcher:OnEventShot(shot_event(tracked_unit, tracked_raw, "Aerial-1", 20))
  check(tracked_shot ~= nil, tracked_error)
  equal(tracked_shot.asset.status, "known")
  equal(tracked_shot.asset.asset_key, "aerial-1.u1.g1")
  equal(tracked_shot.initiator.asset_key, "aerial-1.u1.g1")

  local untracked_unit, untracked_raw = player_unit(602, "Aerial-2", "Aerial-2-1")
  local untracked_shot, untracked_error = watcher:OnEventShot(shot_event(untracked_unit, untracked_raw, "Aerial-2", 21))
  check(untracked_shot ~= nil, untracked_error)
  equal(untracked_shot.asset.status, "unknown")
  equal(untracked_shot.asset.reason, "instance-identity-unavailable")
  equal(untracked_shot.asset.asset_key, envelope.JSON_NULL)
  equal(untracked_shot.initiator.asset_key, envelope.JSON_NULL)
  equal(count_type(events, "ordnance.fired"), 2)
end)

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  error(string.format("telemetry asset tests failed: %d/%d", #failures, tests_run))
end

io.write(string.format("telemetry asset tests: %d passed\n", tests_run))

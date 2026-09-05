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
  function raw:getGroup()
    return {
      getName = function()
        return options.group_name
      end,
    }
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
  function raw:getDesc()
    if options.category == nil then
      return nil
    end
    return { category = options.category }
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
  function unit:IsAlive()
    return options.alive
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

local function new_asset_adapter(controller, base, options)
  options = options or {}
  local adapter, adapter_error = asset.new({
    controller = controller,
    envelope = envelope,
    BASE = base or new_base(),
    EVENTS = { PlayerEnterAircraft = 20, Dead = 21, Crash = 22 },
    player_group_names = { "Aerial-1", "Aerial-2", "Aerial-3", "Aerial-4" },
    bandit_group_names = { "Bandit-1", "Bandit-2", "Bandit-3" },
    player_coalition = 2,
    bandit_coalition = 1,
    log = options.log,
  })
  check(adapter ~= nil, adapter_error)
  return adapter
end

local function resolution_evidence(time, group_name, name, type_name, coalition)
  return {
    sim_time = time,
    group_name = group_name or "Aerial-1",
    dcs_name = name or "Aerial-1-1",
    dcs_type = type_name or "FA-18C_hornet",
    coalition = coalition == nil and 2 or coalition,
  }
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

local function player_enter_event(raw, options)
  options = options or {}
  local group_name = options.group_name or "Aerial-1"
  local ini_group_name = group_name
  if options.omit_ini_group_name then
    ini_group_name = nil
  end
  return {
    initiator = raw,
    IniDCSUnit = raw,
    IniDCSGroupName = group_name,
    IniGroupName = ini_group_name,
    IniDCSUnitName = options.name or "Aerial-1-1",
    IniTypeName = options.type_name or "FA-18C_hornet",
    IniCoalition = options.coalition == nil and 2 or options.coalition,
    IniCategory = options.category == nil and 0 or options.category,
    IniPlayerName = options.player_name or "Viper",
    IniPlayerUCID = options.player_ucid or "ucid-viper",
    time = options.time or 10,
  }
end

succeeds("asset adapter subscribes to multiplayer aircraft entry and cleans up", function()
  local controller = new_controller("subscription")
  local base = new_base()
  local adapter = new_asset_adapter(controller, base)
  local watcher, start_error = adapter:start()
  check(watcher ~= nil, start_error)
  equal(#watcher.handled, 3)
  equal(watcher.handled[1], 20)
  equal(watcher.handled[2], 21)
  equal(watcher.handled[3], 22)
  check(adapter.watcher == watcher, "adapter did not retain its watcher")
  local stopped, stop_error = adapter:stop()
  check(stopped, stop_error)
  equal(#watcher.unhandled, 3)
  equal(watcher.unhandled[1], 20)
  equal(watcher.unhandled[2], 21)
  equal(watcher.unhandled[3], 22)
  check(adapter.watcher == nil, "adapter retained its stopped watcher")
end)

succeeds("MOOSE entry fields normalize identity, names, category, and UCID", function()
  local controller = new_controller("event-fields")
  local adapter = new_asset_adapter(controller)
  local watcher = adapter:start()
  local raw = new_raw_unit({
    id = 300,
    group_name = "wrong-raw-group",
    name = "wrong-raw-name",
    type_name = "wrong-raw-type",
    coalition = 1,
  })
  local reference, created, instance = watcher:OnEventPlayerEnterAircraft(player_enter_event(raw, {
    omit_ini_group_name = true,
    group_name = "Aerial-2",
    name = "Aerial-2-1",
    type_name = "F-16C_50",
    player_name = "Spikkert",
    player_ucid = "ucid-spikkert",
  }))
  check(reference ~= nil)
  equal(created, true)
  equal(reference.asset_key, "aerial-2.u1.g1")
  equal(reference.dcs_name, "Aerial-2-1")
  equal(reference.dcs_type, "F-16C_50")
  equal(reference.coalition, "blue")
  equal(instance.observation.display_name, "Spikkert")
  equal(instance.observation.participant_id, "ucid-spikkert")
  equal(instance.observation.category, 0)
end)

succeeds("airplane and helicopter entries are accepted while ground is rejected", function()
  local controller, events = new_controller("categories")
  local adapter = new_asset_adapter(controller)
  local watcher = adapter:start()
  for index, category in ipairs({ 0, 1 }) do
    local raw = new_raw_unit({ id = 310 + index })
    local accepted, accept_error = watcher:OnEventPlayerEnterAircraft(player_enter_event(raw, {
      group_name = "Aerial-" .. tostring(index),
      name = "Aerial-" .. tostring(index) .. "-1",
      category = category,
    }))
    check(accepted ~= nil, accept_error)
  end
  local rejected = watcher:OnEventPlayerEnterAircraft(player_enter_event(new_raw_unit({ id = 313 }), {
    group_name = "Aerial-3",
    name = "Aerial-3-1",
    category = 2,
  }))
  equal(rejected, nil)
  equal(count_type(events, "asset.spawned"), 2)
end)

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
  local _, raw = player_unit(301, "Aerial-1", "Aerial-1-1")
  local watcher = adapter:start()
  local first, created = watcher:OnEventPlayerEnterAircraft(player_enter_event(raw, { time = 10 }))
  check(first ~= nil)
  equal(created, true)
  equal(first.asset_key, "aerial-1.u1.g1")

  local again, duplicate_created = watcher:OnEventPlayerEnterAircraft(player_enter_event(raw, { time = 20 }))
  check(again ~= nil)
  equal(duplicate_created, false)
  equal(again.asset_key, first.asset_key)
  equal(count_type(events, "asset.spawned"), 1)
end)

succeeds("an extended player group emits a tracked asset instance", function()
  local controller, events = new_controller("extended-roster")
  local adapter = new_asset_adapter(controller)
  local extended, extend_error = adapter:extend_player_roster({ "TestCombat-Blue" })
  check(extended, extend_error)
  local unit = new_unit({
    id = 350,
    group_name = "TestCombat-Blue",
    name = "TestCombat-Blue-1",
    type_name = "F-16C_50",
    coalition = 2,
    category = 0,
  })
  local reference, register_error =
    adapter:register_player_group(new_group({ name = "TestCombat-Blue", units = { unit } }), 12)
  check(reference ~= nil, register_error)
  equal(reference.asset_key, "testcombat-blue.u1.g1")
  equal(reference.dcs_type, "F-16C_50")
  equal(count_type(events, "asset.spawned"), 1)
end)

succeeds("asset roster extension rejects collisions and duplicate key tokens", function()
  local controller = new_controller("extended-roster-errors")
  local adapter = new_asset_adapter(controller)
  local result, message = adapter:extend_player_roster({ "Bandit-1" })
  equal(result, nil)
  equal(message, "Bandit-1 collides with bandit roster")
  result, message = adapter:extend_player_roster({ "test-blue" })
  check(result, message)
  result, message = adapter:extend_player_roster({ "test blue" })
  equal(result, nil)
  equal(message, "test blue does not produce a distinct asset key token")
end)

succeeds("a confirmed player aircraft replacement advances the generation", function()
  local controller, events = new_controller("player-replacement")
  local adapter = new_asset_adapter(controller)
  local _, first_raw = player_unit(401, "Aerial-1", "Aerial-1-1")
  -- The mission-editor numeric ID may be reused. A distinct raw DCS object is
  -- the replacement confirmation; the reused name and ID are not identity.
  local _, replacement_raw = player_unit(401, "Aerial-1", "Aerial-1-1")
  local watcher = adapter:start()
  local first = watcher:OnEventPlayerEnterAircraft(player_enter_event(first_raw, { time = 10 }))
  local replacement, created = watcher:OnEventPlayerEnterAircraft(player_enter_event(replacement_raw, { time = 20 }))
  check(first ~= nil)
  check(replacement ~= nil)
  equal(created, true)
  equal(first.asset_key, "aerial-1.u1.g1")
  equal(replacement.asset_key, "aerial-1.u1.g2")
  equal(count_type(events, "asset.spawned"), 2)
  -- The retired native object remains a tombstone even after DCS reuses its
  -- numeric ID for the replacement.
  equal(adapter:resolve_unit(first_raw), nil)
  equal(adapter:resolve_unit(replacement_raw).asset_key, replacement.asset_key)
end)

succeeds("a live incarnation is reused but a dead one advances the generation on wrapper reuse", function()
  -- Live 2026-09-05: graceful rejoin re-enters the same live aircraft (keep
  -- g1), then the aircraft crashes while the operator is alt-tabbed and the
  -- rejoin carries the recycled MOOSE wrapper with reused IDs (must emit g2).
  local controller, events = new_controller("player-death-replacement")
  local adapter = new_asset_adapter(controller)
  local watcher = adapter:start()
  local wrapper_options = {
    id = 701,
    group_name = "Aerial-1",
    name = "Aerial-1-1",
    coalition = 2,
    player_name = "Viper",
    callsign = "Aerial 1-1",
    alive = true,
  }
  local wrapper = new_unit(wrapper_options)
  local function enter(time)
    return player_enter_event(wrapper, { time = time })
  end
  local first, created = watcher:OnEventPlayerEnterAircraft(enter(10))
  check(first ~= nil)
  equal(created, true)
  equal(first.asset_key, "aerial-1.u1.g1")

  local again, duplicate_created = watcher:OnEventPlayerEnterAircraft(enter(20))
  check(again ~= nil)
  equal(duplicate_created, false)
  equal(again.asset_key, "aerial-1.u1.g1")
  equal(count_type(events, "asset.spawned"), 1)

  wrapper_options.alive = false
  local replacement, replacement_created = watcher:OnEventPlayerEnterAircraft(enter(30))
  check(replacement ~= nil)
  equal(replacement_created, true)
  equal(replacement.asset_key, "aerial-1.u1.g2")
  equal(count_type(events, "asset.spawned"), 2)
  equal(adapter:resolve_unit(wrapper, resolution_evidence(30)).asset_key, "aerial-1.u1.g2")
end)

succeeds("a dead player incarnation retires so the recycled-wrapper rejoin opens g2", function()
  -- Live 2026-09-05: the rejoin after a crash carries the recycled wrapper
  -- with reused IDs, so entry-time comparison keeps the stale g1. The death
  -- itself retires the incarnation; the next entry then opens g2.
  local controller, events = new_controller("player-death-retirement")
  local adapter = new_asset_adapter(controller)
  local watcher = adapter:start()
  local wrapper_options = {
    id = 801,
    group_name = "Aerial-1",
    name = "Aerial-1-1",
    coalition = 2,
    player_name = "Viper",
    callsign = "Aerial 1-1",
    alive = true,
  }
  local wrapper = new_unit(wrapper_options)
  local first, created = watcher:OnEventPlayerEnterAircraft(player_enter_event(wrapper, { time = 10 }))
  check(first ~= nil)
  equal(created, true)
  equal(first.asset_key, "aerial-1.u1.g1")

  local function death_event()
    return {
      IniGroupName = "Aerial-1",
      IniDCSGroupName = "Aerial-1",
      IniDCSUnitName = "Aerial-1-1",
      IniUnitName = "Aerial-1-1",
      IniDCSUnit = wrapper,
      IniCoalition = 2,
      time = 15,
    }
  end
  local retired = watcher:OnEventDead(death_event())
  equal(retired, true)
  check(adapter:resolve_unit(wrapper) == nil, "dead incarnation still resolves")
  -- A bandit death inside another group retires nothing.
  local bandit_retired = watcher:OnEventCrash({
    IniGroupName = "Bandit-1#001",
    IniDCSGroupName = "Bandit-1#001",
    IniDCSUnitName = "Bandit-1#001-01",
    time = 16,
  })
  equal(bandit_retired, false)

  local replacement, replacement_created =
    watcher:OnEventPlayerEnterAircraft(player_enter_event(wrapper, { time = 20 }))
  check(replacement ~= nil)
  equal(replacement_created, true)
  equal(replacement.asset_key, "aerial-1.u1.g2")
  equal(count_type(events, "asset.spawned"), 2)
  equal(adapter:resolve_unit(wrapper, resolution_evidence(20)).asset_key, "aerial-1.u1.g2")
end)

succeeds("shots resolve across recycled representations through aliases and the reused ID", function()
  -- Live 2026-09-05 seq16-18: the entry carries the stale recycled wrapper
  -- plus the fresh native object in another field, while the shot arrives
  -- on yet another fresh table carrying the reused runtime ID.
  local controller, events = new_controller("identity-aliasing")
  local adapter = new_asset_adapter(controller)
  local watcher = adapter:start()
  local stale_raw = new_raw_unit({
    id = 901,
    group_name = "Aerial-1",
    name = "Aerial-1-1",
    type_name = "FA-18C_hornet",
    coalition = 2,
  })
  local first_native = new_raw_unit({
    id = 901,
    group_name = "Aerial-1",
    name = "Aerial-1-1",
    type_name = "FA-18C_hornet",
    coalition = 2,
  })
  local replacement_native = new_raw_unit({
    id = 901,
    group_name = "Aerial-1",
    name = "Aerial-1-1",
    type_name = "FA-18C_hornet",
    coalition = 2,
  })
  local wrapper = new_unit({
    raw = stale_raw,
    name = "Aerial-1-1",
    coalition = 2,
    player_name = "Viper",
    callsign = "Aerial 1-1",
    alive = true,
  })
  local function enter(native, time)
    return {
      IniDCSUnit = native,
      initiator = native,
      IniUnit = wrapper,
      IniGroupName = "Aerial-1",
      IniDCSGroupName = "Aerial-1",
      IniDCSUnitName = "Aerial-1-1",
      IniTypeName = "FA-18C_hornet",
      IniCoalition = 2,
      IniCategory = 0,
      IniPlayerName = "Viper",
      IniPlayerUCID = "ucid-viper",
      time = time,
    }
  end
  local first, created = watcher:OnEventPlayerEnterAircraft(enter(first_native, 10))
  check(first ~= nil)
  equal(created, true)
  equal(first.asset_key, "aerial-1.u1.g1")
  -- The aliased fresh representation resolves without any ID fallback.
  equal(adapter:resolve_unit(first_native).asset_key, "aerial-1.u1.g1")
  -- The recycled wrapper's stale raw native object was not registered as a
  -- current alias.
  equal(adapter:resolve_unit(stale_raw), nil)
  -- A completely fresh table with only the reused ID still resolves.
  local shot_shape = new_raw_unit({
    id = 901,
    group_name = "Aerial-1",
    name = "Aerial-1-1",
    type_name = "FA-18C_hornet",
    coalition = 2,
  })
  equal(adapter:resolve_unit(shot_shape, resolution_evidence(11)).asset_key, "aerial-1.u1.g1")

  local retired = watcher:OnEventDead({
    initiator = first_native,
    IniDCSUnit = first_native,
    IniGroupName = "Aerial-1",
    IniDCSUnitName = "Aerial-1-1",
    IniTypeName = "FA-18C_hornet",
    IniCoalition = 2,
    time = 15,
  })
  equal(retired, true)
  -- Stale references stay dead even though the ID is still tracked.
  check(adapter:resolve_unit(first_native) == nil, "retired incarnation resolved")

  local replacement, replacement_created = watcher:OnEventPlayerEnterAircraft(enter(replacement_native, 20))
  check(replacement ~= nil)
  equal(replacement_created, true)
  equal(replacement.asset_key, "aerial-1.u1.g2")
  -- The live seq18 shape: fresh shot object, reused ID, live g2.
  equal(adapter:resolve_unit(shot_shape, resolution_evidence(21)).asset_key, "aerial-1.u1.g2")
  equal(adapter:resolve_unit(wrapper, resolution_evidence(21)).asset_key, "aerial-1.u1.g2")
  -- A late event carried by the remapped name-based wrapper is rejected by
  -- its pre-g2 event time and cannot retire the current incarnation.
  equal(
    watcher:OnEventCrash({
      IniDCSUnit = wrapper,
      IniGroupName = "Aerial-1",
      IniDCSUnitName = "Aerial-1-1",
      IniTypeName = "FA-18C_hornet",
      IniCoalition = 2,
      time = 16,
    }),
    false
  )
  equal(adapter:resolve_unit(replacement_native).asset_key, "aerial-1.u1.g2")
  -- The same unknown representation carrying a pre-g2 event time is stale.
  equal(adapter:resolve_unit(shot_shape, resolution_evidence(14)), nil)
  equal(adapter:resolve_unit(shot_shape), nil)
  equal(adapter:resolve_unit(shot_shape, resolution_evidence(21, "Aerial-2")), nil)
  equal(adapter:resolve_unit(shot_shape, resolution_evidence(21, nil, "Aerial-2-1")), nil)
  equal(adapter:resolve_unit(shot_shape, resolution_evidence(21, nil, nil, "F-16C_50")), nil)
  equal(adapter:resolve_unit(shot_shape, resolution_evidence(21, nil, nil, nil, 1)), nil)
  equal(adapter:resolve_unit(first_native), nil)
  equal(adapter:resolve_unit(stale_raw), nil)
  equal(count_type(events, "asset.spawned"), 2)
end)

succeeds("a late g1 death cannot retire g2 after runtime ID and wrapper reuse", function()
  local controller = new_controller("late-player-death")
  local adapter = new_asset_adapter(controller)
  local watcher = adapter:start()
  local first_raw = new_raw_unit({
    id = 951,
    group_name = "Aerial-1",
    name = "Aerial-1-1",
    type_name = "FA-18C_hornet",
    coalition = 2,
  })
  local replacement_raw = new_raw_unit({
    id = 951,
    group_name = "Aerial-1",
    name = "Aerial-1-1",
    type_name = "FA-18C_hornet",
    coalition = 2,
  })
  local first = watcher:OnEventPlayerEnterAircraft(player_enter_event(first_raw, { time = 10 }))
  equal(first.asset_key, "aerial-1.u1.g1")
  equal(
    watcher:OnEventDead({
      IniDCSUnit = first_raw,
      IniGroupName = "Aerial-1",
      IniDCSUnitName = "Aerial-1-1",
      IniTypeName = "FA-18C_hornet",
      IniCoalition = 2,
      time = 15,
    }),
    true
  )

  local replacement = watcher:OnEventPlayerEnterAircraft(player_enter_event(replacement_raw, { time = 20 }))
  equal(replacement.asset_key, "aerial-1.u1.g2")
  -- DCS can report several source loss signals. A delayed g1 crash must stop
  -- at the retired native-object tombstone instead of retiring current g2.
  equal(
    watcher:OnEventCrash({
      IniDCSUnit = first_raw,
      IniGroupName = "Aerial-1",
      IniDCSUnitName = "Aerial-1-1",
      IniTypeName = "FA-18C_hornet",
      IniCoalition = 2,
      time = 16,
    }),
    false
  )
  equal(adapter:resolve_unit(replacement_raw).asset_key, "aerial-1.u1.g2")
  equal(
    watcher:OnEventCrash({
      IniDCSUnit = replacement_raw,
      IniGroupName = "Aerial-1",
      IniDCSUnitName = "Aerial-1-1",
      IniTypeName = "FA-18C_hornet",
      IniCoalition = 2,
      time = 25,
    }),
    true
  )
  equal(adapter:resolve_unit(replacement_raw), nil)
end)

succeeds("group-only death fails closed and warns without retiring the active incarnation", function()
  local controller = new_controller("missing-death-identity")
  local messages = {}
  local adapter = new_asset_adapter(controller, nil, {
    log = function(level, message)
      messages[#messages + 1] = level .. ":" .. message
    end,
  })
  local watcher = adapter:start()
  local raw = new_raw_unit({
    id = 961,
    group_name = "Aerial-1",
    name = "Aerial-1-1",
    type_name = "FA-18C_hornet",
    coalition = 2,
  })
  local current = watcher:OnEventPlayerEnterAircraft(player_enter_event(raw, { time = 10 }))
  equal(current.asset_key, "aerial-1.u1.g1")
  equal(
    watcher:OnEventDead({
      IniGroupName = "Aerial-1",
      IniDCSUnitName = "Aerial-1-1",
      time = 15,
    }),
    false
  )
  equal(adapter:resolve_unit(raw).asset_key, "aerial-1.u1.g1")
  check(
    string.find(table.concat(messages, "\n"), "death identity unavailable", 1, true) ~= nil,
    "missing death identity did not warn"
  )
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

  local asset_watcher = registry:start()
  local _, first_raw = player_unit(601, "Aerial-1", "Aerial-1-1")
  local registered = asset_watcher:OnEventPlayerEnterAircraft(player_enter_event(first_raw, { time = 10 }))
  check(registered ~= nil)
  local replacement_unit, replacement_raw = player_unit(601, "Aerial-1", "Aerial-1-1")
  local replacement = asset_watcher:OnEventPlayerEnterAircraft(player_enter_event(replacement_raw, { time = 15 }))
  check(replacement ~= nil)
  equal(replacement.asset_key, "aerial-1.u1.g2")
  -- The retired native object remains stale after the replacement reuses ID.
  equal(registry:resolve_unit(first_raw), nil)
  local tracked_shot, tracked_error = watcher:OnEventShot(shot_event(replacement_unit, replacement_raw, "Aerial-1", 20))
  check(tracked_shot ~= nil, tracked_error)
  equal(tracked_shot.asset.status, "known")
  equal(tracked_shot.asset.asset_key, "aerial-1.u1.g2")
  equal(tracked_shot.initiator.asset_key, "aerial-1.u1.g2")

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

local event_id = dofile("src/missions/duel-dynamic/telemetry/event_id.lua")
local envelope = dofile("src/missions/duel-dynamic/telemetry/envelope.lua")
local lifecycle = dofile("src/missions/duel-dynamic/telemetry/lifecycle.lua")
local participant = dofile("src/missions/duel-dynamic/telemetry/participant.lua")

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
    local watcher = { handled = {}, unhandled = {} }
    function watcher:HandleEvent(event)
      self.handled[#self.handled + 1] = event
      return self
    end
    function watcher:UnHandleEvent(event)
      self.unhandled[#self.unhandled + 1] = event
      return self
    end
    watchers[#watchers + 1] = watcher
    return watcher
  end

  return base, watchers
end

local function new_controller(label, sim_time)
  local events = {}
  local sink = {}
  function sink:write(event)
    events[#events + 1] = event
    return true
  end

  local producer, producer_error = envelope.new({
    event_id = event_id,
    producer_id = "participant-producer-" .. label,
    run_key = "run-participant-" .. label,
    source_version = "duel-dynamic-telemetry-v1",
  })
  check(producer ~= nil, producer_error)

  local controller, controller_error = lifecycle.new({
    producer = producer,
    sink = sink,
    sim_time = function()
      return sim_time or 99
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
  return controller, events
end

local function new_adapter(controller, base, logs, options)
  options = options or {}
  local adapter, adapter_error = participant.new({
    controller = controller,
    envelope = envelope,
    BASE = base,
    EVENTS = { PlayerEnterAircraft = 20, PlayerLeaveUnit = 21 },
    player_group_names = { "Aerial-1", "Aerial-2", "Aerial-3", "Aerial-4" },
    player_coalition = 2,
    asset_registry = options.asset_registry,
    log = function(level, message)
      logs[#logs + 1] = level .. " " .. message
    end,
  })
  check(adapter ~= nil, adapter_error)
  return adapter
end

local function option(options, name, default)
  if options[name] ~= nil then
    return options[name]
  end
  if options["missing_" .. name] then
    return nil
  end
  return default
end

local function new_unit(options)
  options = options or {}
  local calls = options.calls or {}
  local unit = { _options = options }

  local function result(name, default)
    calls[#calls + 1] = name
    if options["throw_" .. name] then
      error(name .. " unavailable")
    end
    return option(options, name, default)
  end

  function unit:getGroup()
    calls[#calls + 1] = "group"
    if options.missing_group_name then
      return nil
    end
    return {
      getName = function()
        calls[#calls + 1] = "group_name"
        return option(options, "group_name", "Aerial-1")
      end,
    }
  end
  function unit:getName()
    return result("name", "Aerial-1-1")
  end
  function unit:getTypeName()
    return result("type_name", "FA-18C_hornet")
  end
  function unit:getCoalition()
    return result("coalition", 2)
  end
  function unit:getPosition()
    return result("position", { p = { x = 101.5, y = 202.5, z = -303.5 } })
  end
  function unit:getDesc()
    return { category = result("category", 0) }
  end
  function unit:getCallsign()
    return result("callsign", "Aerial 1-1")
  end

  return unit, calls
end

local function event(unit, time)
  local options = unit._options or {}
  local function normalized(name, default)
    return option(options, name, default)
  end
  local dcs_group_name
  if not options.missing_group_name then
    dcs_group_name = normalized("dcs_group_name", "Aerial-1")
  end
  local ini_group_name = normalized("group_name", "Aerial-1")
  if options.omit_ini_group_name then
    ini_group_name = nil
  end
  return {
    initiator = unit,
    IniDCSUnit = unit,
    IniGroupName = ini_group_name,
    IniDCSGroupName = dcs_group_name,
    IniDCSUnitName = normalized("name", "Aerial-1-1"),
    IniTypeName = normalized("type_name", "FA-18C_hornet"),
    IniCoalition = normalized("coalition", 2),
    IniCategory = normalized("category", 0),
    IniPlayerName = normalized("player_name", "Viper"),
    IniPlayerUCID = normalized("player_ucid", "ucid-viper"),
    time = time,
  }
end

local function contains_log(logs, fragment)
  for _, message in ipairs(logs) do
    if string.find(message, fragment, 1, true) then
      return true
    end
  end
  return false
end

succeeds("registration is delayed, subscribes both events, and stop unsubscribes both", function()
  local base, watchers = new_base()
  local controller = new_controller("registration")
  local adapter = new_adapter(controller, base, {})
  equal(#watchers, 0)

  check(controller:start())
  local watcher, start_error = adapter:start()
  check(watcher ~= nil, start_error)
  equal(#watchers, 1)
  equal(watcher.handled[1], 20)
  equal(watcher.handled[2], 21)
  check(adapter.watcher == watcher, "adapter did not retain its watcher")

  local stopped, stop_error = adapter:stop()
  check(stopped, stop_error)
  equal(watcher.unhandled[1], 20)
  equal(watcher.unhandled[2], 21)
  check(adapter.watcher == nil, "adapter retained its stopped watcher")
  check(adapter:stop())
end)

succeeds("MOOSE aircraft enter fields emit a complete participant event", function()
  local logs = {}
  local base = new_base()
  local controller, events = new_controller("known-enter")
  local adapter = new_adapter(controller, base, logs)
  check(controller:start())
  local watcher = adapter:start()
  local unit, calls = new_unit({ omit_ini_group_name = true })

  local entered, enter_error = watcher:OnEventPlayerEnterAircraft(event(unit, 12.5))
  check(entered ~= nil, enter_error)
  equal(#events, 2)
  equal(entered.event_sequence, 2)
  equal(entered.event_type, "participant.entered")
  equal(entered.sim_time, 12.5)
  equal(entered.participant.status, "known")
  equal(entered.participant.participant_id, "ucid-viper")
  equal(entered.participant.display_name, "Viper")
  equal(entered.participant.callsign, "Aerial 1-1")
  equal(entered.participant.coalition, "blue")
  equal(entered.asset.status, "unknown")
  equal(entered.asset.reason, "instance-identity-unavailable")
  equal(entered.asset.asset_key, envelope.JSON_NULL)
  equal(entered.asset.dcs_name, "Aerial-1-1")
  equal(entered.asset.dcs_type, "FA-18C_hornet")
  equal(entered.coalition, "blue")
  equal(entered.location.status, "known")
  equal(entered.location.x, 101.5)
  equal(entered.location.y, 202.5)
  equal(entered.location.z, -303.5)
  equal(entered.initiator, envelope.JSON_NULL)
  equal(entered.target, envelope.JSON_NULL)
  equal(entered.weapon, envelope.JSON_NULL)
  equal(next(entered.payload), nil)
  equal(table.concat(calls, ","), "position,callsign")
  check(contains_log(logs, "info participant capture: emitted participant.entered sequence=2"))
end)

succeeds("leave preserves stable identity from the slot snapshot and prefers live labels", function()
  local base = new_base()
  local controller = new_controller("leave-snapshot")
  local adapter = new_adapter(controller, base, {})
  check(controller:start())
  local watcher = adapter:start()
  local enter_unit = new_unit({
    player_ucid = "ucid-original",
    player_name = "Original Name",
    callsign = "Original Callsign",
    type_name = "Original Type",
  })
  check(watcher:OnEventPlayerEnterAircraft(event(enter_unit, 10)))

  local leave_unit = new_unit({
    missing_player_ucid = true,
    player_name = "Live Name",
    missing_callsign = true,
    name = "Aerial-1-live",
    missing_type_name = true,
    missing_position = true,
  })
  local left, left_error = watcher:OnEventPlayerLeaveUnit(event(leave_unit, 20))
  check(left ~= nil, left_error)
  equal(left.event_type, "participant.left")
  equal(left.participant.status, "known")
  equal(left.participant.participant_id, "ucid-original")
  equal(left.participant.display_name, "Live Name")
  equal(left.participant.callsign, "Original Callsign")
  equal(left.asset.dcs_name, "Aerial-1-live")
  equal(left.asset.dcs_type, "Original Type")
  equal(left.location.status, "unknown")
end)

succeeds("participant leave resolution receives event-time and identity evidence", function()
  local base = new_base()
  local controller = new_controller("leave-asset-evidence")
  local captured_unit
  local captured_evidence
  local registry = {}
  function registry:observe_player_unit()
    return {
      status = "known",
      kind = "aircraft",
      asset_key = "aerial-1.u1.g1",
      dcs_name = "Aerial-1-1",
      dcs_type = "FA-18C_hornet",
      coalition = "blue",
    }
  end
  function registry:resolve_unit(unit, evidence)
    captured_unit = unit
    captured_evidence = evidence
    return {
      status = "known",
      kind = "aircraft",
      asset_key = "aerial-1.u1.g1",
      dcs_name = "Aerial-1-1",
      dcs_type = "FA-18C_hornet",
      coalition = "blue",
    }
  end
  local adapter = new_adapter(controller, base, {}, { asset_registry = registry })
  check(controller:start())
  local watcher = adapter:start()
  local unit = new_unit({
    group_name = "Aerial-1",
    name = "Aerial-1-1",
    type_name = "FA-18C_hornet",
    coalition = 2,
  })
  check(watcher:OnEventPlayerEnterAircraft(event(unit, 10)))
  local left, left_error = watcher:OnEventPlayerLeaveUnit(event(unit, 25))
  check(left ~= nil, left_error)
  equal(left.asset.asset_key, "aerial-1.u1.g1")
  equal(captured_unit, unit)
  equal(captured_evidence.sim_time, 25)
  equal(captured_evidence.group_name, "Aerial-1")
  equal(captured_evidence.dcs_name, "Aerial-1-1")
  equal(captured_evidence.dcs_type, "FA-18C_hornet")
  equal(captured_evidence.coalition, 2)
end)

succeeds("missing UCID emits an explicit unknown participant and warning", function()
  local logs = {}
  local base = new_base()
  local controller = new_controller("unknown-identity")
  local adapter = new_adapter(controller, base, logs)
  check(controller:start())
  local watcher = adapter:start()
  local unit = new_unit({ missing_player_ucid = true, player_name = "Observed Human" })

  local entered, enter_error = watcher:OnEventPlayerEnterAircraft(event(unit, 5))
  check(entered ~= nil, enter_error)
  equal(entered.participant.status, "unknown")
  equal(entered.participant.reason, "stable-identity-unavailable")
  equal(entered.participant.participant_id, envelope.JSON_NULL)
  equal(entered.participant.display_name, "Observed Human")
  check(contains_log(logs, "warning participant capture: stable identity unavailable for slot Aerial-1"))

  local leave_unit = new_unit({ group_name = "Aerial-2", player_name = "Leaving Human", missing_player_ucid = true })
  local left, leave_error = watcher:OnEventPlayerLeaveUnit(event(leave_unit, 6))
  check(left ~= nil, leave_error)
  equal(left.participant.status, "unknown")
  equal(left.participant.reason, "stable-identity-unavailable")
  equal(left.participant.participant_id, envelope.JSON_NULL)
  equal(left.participant.display_name, "Leaving Human")
end)

succeeds("exact roster, coalition, and aircraft categories guard capture", function()
  local base = new_base()
  local controller, events = new_controller("filters")
  local adapter = new_adapter(controller, base, {})
  check(controller:start())
  local watcher = adapter:start()

  for _, options in ipairs({
    { group_name = "Aerial-1#001" },
    { group_name = "Aerial-10" },
    { group_name = "Bandit-1" },
    { group_name = "Aerial-2", coalition = 1 },
    { group_name = "Aerial-3", category = 2 },
    { group_name = "Aerial-4", category = 3 },
  }) do
    local ignored = watcher:OnEventPlayerEnterAircraft(event(new_unit(options), 10))
    equal(ignored, nil, "filtered participant event was emitted")
  end
  equal(#events, 1)
  for _, category in ipairs({ 0, 1 }) do
    local accepted, accept_error = watcher:OnEventPlayerEnterAircraft(event(new_unit({ category = category }), 11))
    check(accepted ~= nil, accept_error)
  end
  equal(#events, 3)
end)

succeeds("unreadable category and coalition proceed with explicit unknown coalition", function()
  local base = new_base()
  local controller = new_controller("unknown-guard")
  local adapter = new_adapter(controller, base, {})
  check(controller:start())
  local watcher = adapter:start()
  local unit =
    new_unit({ missing_category = true, throw_category = true, missing_coalition = true, throw_coalition = true })

  local entered, enter_error = watcher:OnEventPlayerEnterAircraft(event(unit, 8))
  check(entered ~= nil, enter_error)
  equal(entered.coalition, "unknown")
  equal(entered.participant.coalition, "unknown")
  equal(entered.asset.coalition, "unknown")
end)

succeeds("throwing optional raw methods degrade to contract-valid unknown references", function()
  local logs = {}
  local base = new_base()
  local controller = new_controller("throwing", 77.5)
  local adapter = new_adapter(controller, base, logs)
  check(controller:start())
  local watcher = adapter:start()
  local unit = new_unit({
    missing_name = true,
    throw_name = true,
    missing_type_name = true,
    throw_type_name = true,
    missing_coalition = true,
    throw_coalition = true,
    missing_position = true,
    throw_position = true,
    missing_category = true,
    throw_category = true,
    missing_player_name = true,
    throw_player_name = true,
    missing_player_ucid = true,
    throw_player_ucid = true,
    missing_callsign = true,
    throw_callsign = true,
  })

  local entered, enter_error = watcher:OnEventPlayerEnterAircraft(event(unit))
  check(entered ~= nil, enter_error)
  equal(entered.sim_time, 77.5)
  equal(entered.participant.status, "unknown")
  equal(entered.participant.display_name, envelope.JSON_NULL)
  equal(entered.participant.callsign, envelope.JSON_NULL)
  equal(entered.asset.dcs_name, envelope.JSON_NULL)
  equal(entered.asset.dcs_type, envelope.JSON_NULL)
  equal(entered.location.status, "unknown")
  equal(entered.location.reason, "unavailable")
  check(contains_log(logs, "error participant capture: getName raised"))
end)

succeeds("missing raw unit or group is ignored without allocating an event", function()
  local base = new_base()
  local controller, events = new_controller("missing-unit")
  local adapter = new_adapter(controller, base, {})
  check(controller:start())
  local watcher = adapter:start()

  equal(watcher:OnEventPlayerEnterAircraft({ time = 1 }), nil)
  equal(watcher:OnEventPlayerLeaveUnit(event(new_unit({ missing_group_name = true }), 2)), nil)
  equal(#events, 1)
end)

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  error(string.format("telemetry participant tests failed: %d/%d", #failures, tests_run))
end

io.write(string.format("telemetry participant tests: %d passed\n", tests_run))

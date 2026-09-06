local event_id = dofile("src/missions/duel-dynamic/telemetry/event_id.lua")
local envelope = dofile("src/missions/duel-dynamic/telemetry/envelope.lua")
local lifecycle = dofile("src/missions/duel-dynamic/telemetry/lifecycle.lua")
local combat = dofile("src/missions/duel-dynamic/telemetry/combat.lua")

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
    producer_id = "combat-producer-" .. label,
    run_key = "run-combat-" .. label,
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
      return "2026-09-06T12:00:00Z"
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

local function asset_reference(key, name, type_name, side)
  return {
    status = "known",
    kind = "aircraft",
    asset_key = key,
    dcs_name = name,
    dcs_type = type_name,
    coalition = side,
  }
end

local function new_registry()
  local registry = { references = {}, loss_state = { mutations = 0 } }
  function registry:track(unit, reference)
    self.references[unit] = reference
  end
  function registry:resolve_unit(unit)
    return self.references[unit]
  end
  return registry
end

local function new_unit(options)
  options = options or {}
  local unit = {}
  function unit:getName()
    return options.name
  end
  function unit:getTypeName()
    if options.throw_type then
      error("type unavailable")
    end
    return options.type_name
  end
  function unit:getCoalition()
    return options.coalition
  end
  function unit:getPlayerName()
    return options.player_name
  end
  function unit:getCallsign()
    return options.callsign
  end
  function unit:getPosition()
    if options.no_position then
      return nil
    end
    return { p = options.position or { x = 100, y = 200, z = 300 } }
  end
  function unit:getGroup()
    if not options.group_name then
      return nil
    end
    return {
      getName = function()
        return options.group_name
      end,
    }
  end
  return unit
end

local function new_weapon(type_name)
  return {
    getTypeName = function()
      return type_name
    end,
  }
end

local function new_event(attacker, victim, options)
  options = options or {}
  return {
    IniDCSUnit = attacker,
    IniUnitName = options.attacker_name,
    IniGroupName = options.attacker_group,
    IniTypeName = options.attacker_type,
    IniCoalition = options.attacker_coalition,
    IniPlayerName = options.player_name,
    IniPlayerUCID = options.player_ucid,
    TgtDCSUnit = victim,
    TgtUnitName = options.victim_name,
    TgtGroupName = options.victim_group,
    TgtTypeName = options.victim_type,
    TgtCoalition = options.victim_coalition,
    TgtPlayerName = options.victim_player_name,
    TgtPlayerUCID = options.victim_player_ucid,
    Weapon = options.weapon,
    WeaponName = options.weapon_name,
    time = options.time or 10,
  }
end

local function new_adapter(label, options)
  options = options or {}
  local controller, events = new_controller(label)
  local registry = options.registry or new_registry()
  local logs = {}
  local adapter, adapter_error = combat.new({
    controller = options.controller or controller,
    envelope = envelope,
    BASE = options.base or new_base(),
    EVENTS = options.events or { Hit = 2, Kill = 28 },
    asset_registry = registry,
    log = function(level, message)
      logs[#logs + 1] = level .. ":" .. message
    end,
  })
  check(adapter ~= nil, adapter_error)
  return adapter, events, registry, logs
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

local function assert_complete_combat_event(event, event_type)
  equal(event.schema_version, 1)
  equal(event.source, "moose-mission")
  equal(event.event_type, event_type)
  check(type(event.event_id) == "string")
  check(type(event.event_sequence) == "number")
  check(type(event.sim_time) == "number")
  check(event.wall_time ~= nil)
  check(type(event.initiator) == "table")
  check(type(event.target) == "table")
  equal(event.participant, envelope.JSON_NULL)
  check(type(event.asset) == "table")
  check(event.weapon ~= nil)
  check(type(event.coalition) == "string")
  check(type(event.location) == "table")
  check(type(event.payload) == "table")
end

succeeds("Hit and optional Kill subscriptions are retained and removed", function()
  local adapter = new_adapter("registration")
  local watcher, start_error = adapter:start()
  check(watcher ~= nil, start_error)
  equal(#watcher.handled, 2)
  equal(watcher.handled[1], 2)
  equal(watcher.handled[2], 28)
  check(adapter:stop())
  equal(#watcher.unhandled, 2)

  local without_kill = new_adapter("without-kill", { events = { Hit = 2, Kill = -1 } })
  local hit_only = without_kill:start()
  equal(#hit_only.handled, 1)
  equal(hit_only.handled[1], 2)

  local failing_base = {}
  function failing_base:New()
    return {
      HandleEvent = function(self, event)
        if event == 28 then
          error("Kill registration unavailable")
        end
      end,
      UnHandleEvent = function(self, event)
        self.cleaned = event
      end,
    }
  end
  local failing = new_adapter("registration-failure", { base = failing_base })
  local failed_watcher, registration_error = failing:start()
  equal(failed_watcher, nil)
  equal(registration_error, "registering EVENTS.Kill failed")
end)

succeeds("tracked player killer and tracked victim emit contract-shaped Hit and Kill", function()
  local adapter, events, registry = new_adapter("tracked")
  local attacker = new_unit({ name = "Aerial-1-1", type_name = "FA-18C_hornet", coalition = 2 })
  local victim = new_unit({ name = "Bandit-1#001-01", type_name = "MiG-29A", coalition = 1 })
  registry:track(attacker, asset_reference("aerial-1.u1.g1", "Aerial-1-1", "FA-18C_hornet", "blue"))
  registry:track(victim, asset_reference("bandit-1.u1.g1", "Bandit-1#001-01", "MiG-29A", "red"))
  local data = new_event(attacker, victim, {
    attacker_name = "Aerial-1-1",
    attacker_type = "FA-18C_hornet",
    attacker_coalition = 2,
    player_name = "Viper",
    player_ucid = "ucid-viper",
    victim_name = "Bandit-1#001-01",
    victim_type = "MiG-29A",
    victim_coalition = 1,
    weapon = new_weapon("weapons.missiles.AIM_120C"),
  })
  local hit, hit_error = adapter:OnEventHit(data)
  check(hit ~= nil, hit_error)
  local kill, kill_error = adapter:OnEventKill(data)
  check(kill ~= nil, kill_error)
  assert_complete_combat_event(hit, "asset.hit")
  assert_complete_combat_event(kill, "asset.kill-reported")
  equal(hit.initiator.asset_key, "aerial-1.u1.g1")
  equal(hit.initiator.participant_id, "ucid-viper")
  equal(hit.target.asset_key, "bandit-1.u1.g1")
  equal(hit.asset.asset_key, "bandit-1.u1.g1")
  equal(hit.coalition, "blue")
  equal(hit.weapon.dcs_type, "weapons.missiles.AIM_120C")
  equal(hit.payload.dcs_event_name, "hit")
  equal(kill.payload.dcs_event_name, "kill")
  equal(#events, 3)
end)

succeeds("not-reported killer exactly follows the canonical unknown-attacker shape", function()
  local adapter, _, registry = new_adapter("unknown")
  local victim = new_unit({ name = "Bandit-2#001-1", type_name = "MiG-29A", coalition = 1 })
  registry:track(victim, asset_reference("bandit-2.u1.g1", "Bandit-2#001-1", "MiG-29A", "red"))
  local reported, report_error = adapter:OnEventKill(new_event(nil, victim, {
    victim_name = "Bandit-2#001-1",
    victim_type = "MiG-29A",
    victim_coalition = 1,
  }))
  check(reported ~= nil, report_error)
  local actor = reported.initiator
  equal(actor.status, "unknown")
  equal(actor.kind, "unknown")
  equal(actor.reason, "not-reported")
  equal(actor.participant_id, envelope.JSON_NULL)
  equal(actor.asset_key, envelope.JSON_NULL)
  equal(actor.display_name, envelope.JSON_NULL)
  equal(actor.callsign, envelope.JSON_NULL)
  equal(actor.dcs_name, envelope.JSON_NULL)
  equal(actor.dcs_type, envelope.JSON_NULL)
  equal(actor.coalition, "unknown")
  equal(reported.coalition, "unknown")
  equal(reported.weapon, envelope.JSON_NULL)
  equal(reported.payload.dcs_event_name, "kill")
end)

succeeds("untracked victim suppresses combat emission", function()
  local adapter, events, registry = new_adapter("untracked-victim")
  local attacker = new_unit({ name = "Aerial-1-1", type_name = "FA-18C_hornet", coalition = 2 })
  local victim = new_unit({ name = "Civilian-1", type_name = "Yak-40", coalition = 0 })
  registry:track(attacker, asset_reference("aerial-1.u1.g1", "Aerial-1-1", "FA-18C_hornet", "blue"))
  equal(adapter:OnEventHit(new_event(attacker, victim)), nil)
  equal(#events, 1)
end)

succeeds("untracked real AI attacker remains a known aircraft without fabricated identities", function()
  local adapter, _, registry = new_adapter("untracked-attacker")
  local attacker = new_unit({ name = "Untracked-MiG-1", type_name = "MiG-21Bis", coalition = 1 })
  local victim = new_unit({ name = "Aerial-1-1", type_name = "FA-18C_hornet", coalition = 2 })
  registry:track(victim, asset_reference("aerial-1.u1.g1", "Aerial-1-1", "FA-18C_hornet", "blue"))
  local hit = adapter:OnEventHit(new_event(attacker, victim, {
    attacker_name = "Untracked-MiG-1",
    attacker_type = "MiG-21Bis",
    attacker_coalition = 1,
  }))
  equal(hit.initiator.status, "known")
  equal(hit.initiator.kind, "aircraft")
  equal(hit.initiator.asset_key, envelope.JSON_NULL)
  equal(hit.initiator.participant_id, envelope.JSON_NULL)
  equal(hit.initiator.dcs_name, "Untracked-MiG-1")
  equal(hit.initiator.coalition, "red")
  equal(hit.coalition, "red")
end)

succeeds("friendly fire on either coalition is retained with both role coalitions", function()
  local adapter, _, registry = new_adapter("friendly")
  for index, side in ipairs({ { 2, "blue" }, { 1, "red" } }) do
    local attacker = new_unit({ name = "Friendly-A-" .. index, type_name = "Fighter", coalition = side[1] })
    local victim = new_unit({ name = "Friendly-V-" .. index, type_name = "Fighter", coalition = side[1] })
    registry:track(attacker, asset_reference("friendly-a." .. index, "Friendly-A-" .. index, "Fighter", side[2]))
    registry:track(victim, asset_reference("friendly-v." .. index, "Friendly-V-" .. index, "Fighter", side[2]))
    local hit = adapter:OnEventHit(new_event(attacker, victim, {
      attacker_coalition = side[1],
      victim_coalition = side[1],
    }))
    equal(hit.initiator.coalition, side[2])
    equal(hit.target.coalition, side[2])
    equal(hit.coalition, side[2])
  end
end)

succeeds("repeated hits and one kill remain separate source observations", function()
  local adapter, events, registry = new_adapter("repeated")
  local attacker = new_unit({ name = "Aerial-1-1", type_name = "F-16C_50", coalition = 2 })
  local victim = new_unit({ name = "Bandit-1#001-01", type_name = "MiG-29A", coalition = 1 })
  registry:track(victim, asset_reference("bandit-1.u1.g1", "Bandit-1#001-01", "MiG-29A", "red"))
  local data = new_event(attacker, victim, { attacker_coalition = 2 })
  check(adapter:OnEventHit(data))
  check(adapter:OnEventHit(data))
  check(adapter:OnEventHit(data))
  check(adapter:OnEventKill(data))
  equal(count_type(events, "asset.hit"), 3)
  equal(count_type(events, "asset.kill-reported"), 1)
end)

succeeds("Kill emits no loss and does not mutate asset loss state", function()
  local adapter, events, registry = new_adapter("no-loss")
  local victim = new_unit({ name = "Bandit-1#001-01", type_name = "MiG-29A", coalition = 1 })
  registry:track(victim, asset_reference("bandit-1.u1.g1", "Bandit-1#001-01", "MiG-29A", "red"))
  check(adapter:OnEventKill(new_event(nil, victim)))
  equal(count_type(events, "asset.kill-reported"), 1)
  equal(count_type(events, "asset.dead"), 0)
  equal(count_type(events, "asset.crashed"), 0)
  equal(registry.loss_state.mutations, 0)
end)

succeeds("victim name reuse resolves distinct generation keys", function()
  local adapter, _, registry = new_adapter("generations")
  local first = new_unit({ name = "Bandit-Reused", type_name = "MiG-29A", coalition = 1 })
  local second = new_unit({ name = "Bandit-Reused", type_name = "MiG-29A", coalition = 1 })
  registry:track(first, asset_reference("bandit-1.u1.g1", "Bandit-Reused", "MiG-29A", "red"))
  registry:track(second, asset_reference("bandit-1.u1.g2", "Bandit-Reused", "MiG-29A", "red"))
  local first_hit = adapter:OnEventHit(new_event(nil, first))
  local second_hit = adapter:OnEventHit(new_event(nil, second))
  equal(first_hit.asset.asset_key, "bandit-1.u1.g1")
  equal(second_hit.asset.asset_key, "bandit-1.u1.g2")
end)

succeeds("nil and partial attacker or projectile objects degrade without raising", function()
  local adapter, _, registry, logs = new_adapter("partial")
  local victim = new_unit({ name = "Aerial-1-1", type_name = "FA-18C_hornet", coalition = 2, no_position = true })
  registry:track(victim, asset_reference("aerial-1.u1.g1", "Aerial-1-1", "FA-18C_hornet", "blue"))
  local partial = setmetatable({}, {
    __index = function(_, field)
      if field == "getTypeName" then
        return function()
          error("partial object")
        end
      end
      return nil
    end,
  })
  local event, capture_error = adapter:OnEventHit(new_event(partial, victim, { weapon = partial }))
  check(event ~= nil, capture_error)
  equal(event.initiator.status, "unknown")
  equal(event.initiator.reason, "unresolved")
  equal(event.weapon, envelope.JSON_NULL)
  equal(event.location.status, "unknown")
  check(#logs > 0)
end)

succeeds("missing runtime and raised persistence fail closed through pcall isolation", function()
  local missing, missing_error = combat.new({})
  equal(missing, nil)
  check(type(missing_error) == "string")

  local controller = {
    record = function()
      error("runtime absent")
    end,
  }
  local adapter, _, registry, logs = new_adapter("runtime-absent", { controller = controller })
  local victim = new_unit({ name = "Aerial-1-1", type_name = "FA-18C_hornet", coalition = 2 })
  registry:track(victim, asset_reference("aerial-1.u1.g1", "Aerial-1-1", "FA-18C_hornet", "blue"))
  local event, capture_error = adapter:OnEventKill(new_event(nil, victim))
  equal(event, nil)
  equal(capture_error, "active-run persistence raised")
  check(string.find(table.concat(logs, "\n"), "active-run persistence raised", 1, true) ~= nil)
end)

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  error(string.format("telemetry combat tests failed: %d/%d", #failures, tests_run))
end

io.write(string.format("telemetry combat tests: %d passed\n", tests_run))

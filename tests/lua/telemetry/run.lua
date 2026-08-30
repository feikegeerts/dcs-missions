local event_id = dofile("src/missions/duel-dynamic/telemetry/event_id.lua")
local envelope = dofile("src/missions/duel-dynamic/telemetry/envelope.lua")

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

local function fails(callback, expected_fragment)
  local first, second = callback()
  check(first == nil, "expected failure")
  check(type(second) == "string", "failure must include a message")
  if expected_fragment then
    check(string.find(second, expected_fragment, 1, true) ~= nil, "unexpected failure: " .. second)
  end
end

local function new_producer(producer_id, run_key)
  local producer, creation_error = envelope.new({
    event_id = event_id,
    producer_id = producer_id or "dcs-server-alpha",
    run_key = run_key or "run-test-20260830",
    source_version = "duel-dynamic-telemetry-v1",
  })
  check(producer ~= nil, creation_error)
  return producer
end

local function started_input()
  return {
    event_type = "mission.started",
    sim_time = 0,
    payload = {
      mission_name = "duel-dynamic",
      mission_version = "1",
      map_name = "Caucasus",
      run_classification = "test",
    },
  }
end

local function shot_input(coalition, participant)
  return {
    event_type = "ordnance.fired",
    sim_time = 125.5,
    wall_time = "2026-08-30T12:02:05.500Z",
    initiator = {
      status = "known",
      kind = "aircraft",
      participant_id = "ucid-0123456789abcdef",
      asset_key = "aerial-1.1",
      display_name = "Viper",
      callsign = "Aerial 1-1",
      dcs_name = "Aerial-1-1",
      dcs_type = "FA-18C_hornet",
      coalition = coalition,
    },
    participant = participant or {
      status = "known",
      participant_id = "ucid-0123456789abcdef",
      display_name = "Viper",
      callsign = "Aerial 1-1",
      coalition = coalition,
    },
    asset = {
      status = "known",
      kind = "aircraft",
      asset_key = "aerial-1.1",
      dcs_name = "Aerial-1-1",
      dcs_type = "FA-18C_hornet",
      coalition = coalition,
    },
    weapon = {
      status = "known",
      dcs_type = "weapons.missiles.AIM_120C",
      display_name = "AIM-120C",
      category = "missile",
    },
    coalition = coalition,
    location = {
      x = 125000.25,
      y = 7620.5,
      z = -44000.75,
    },
    payload = {
      dcs_event_name = "shot",
    },
  }
end

succeeds("production modules return tables without creating globals", function()
  check(type(event_id) == "table", "event_id module did not return a table")
  check(type(envelope) == "table", "envelope module did not return a table")
  check(_G.telemetry_event_id == nil, "event_id module created a global")
  check(_G.telemetry_envelope == nil, "envelope module created a global")
  check(envelope.JSON_NULL ~= nil, "JSON null sentinel is missing")
end)

succeeds("token and sequence boundaries are exact", function()
  local valid, validation_error = event_id.validate_token("a", "token")
  check(valid, validation_error)
  valid, validation_error = event_id.validate_token(string.rep("a", 128), "token")
  check(valid, validation_error)
  fails(function()
    return event_id.validate_token(string.rep("a", 129), "token")
  end, "1-128")
  fails(function()
    return event_id.validate_token("a:b", "token")
  end, "invalid character")
  fails(function()
    return event_id.validate_token("-a", "token")
  end, "start")

  equal(event_id.decimal_sequence(1), "1")
  equal(event_id.decimal_sequence(10), "10")
  equal(event_id.decimal_sequence(event_id.MAX_SEQUENCE), "9007199254740991")
  equal(event_id.build_event_id("producer-1", "run-1", event_id.MAX_SEQUENCE), "producer-1:run-1:9007199254740991")
  fails(function()
    return event_id.decimal_sequence(0)
  end, "range")
  fails(function()
    return event_id.decimal_sequence(event_id.MAX_SEQUENCE + 1)
  end, "range")
end)

succeeds("sequence one is mission.started and invalid input leaves no gap", function()
  local producer = new_producer()
  fails(function()
    return producer:build({ event_type = "ordnance.fired", sim_time = 1 })
  end, "requires initiator")

  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)
  equal(started.event_sequence, 1)
  equal(started.event_id, "dcs-server-alpha:run-test-20260830:1")

  fails(function()
    return producer:build({ event_type = "mission.started", sim_time = 0, payload = started_input().payload })
  end, "only use sequence 1")
  fails(function()
    return producer:build({ event_type = "mission.heartbeat", sim_time = -1 })
  end, "non-negative")

  local heartbeat, heartbeat_error = producer:build({ event_type = "mission.heartbeat", sim_time = 1 })
  check(heartbeat ~= nil, heartbeat_error)
  equal(heartbeat.event_sequence, 2)
  equal(heartbeat.event_id, "dcs-server-alpha:run-test-20260830:2")
end)

succeeds("two identical same-time shots receive consecutive identities", function()
  local producer = new_producer()
  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)
  local input = shot_input(2)
  local first, first_error = producer:build(input)
  check(first ~= nil, first_error)
  local second, second_error = producer:build(input)
  check(second ~= nil, second_error)
  equal(first.event_sequence, 2)
  equal(second.event_sequence, 3)
  check(first.event_id ~= second.event_id, "same-content shots collided")
  equal(first.event_id, "dcs-server-alpha:run-test-20260830:2")
  equal(second.event_id, "dcs-server-alpha:run-test-20260830:3")
  equal(first.sim_time, second.sim_time)
end)

succeeds("retry returns the already-built envelope and does not allocate", function()
  local producer = new_producer()
  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)
  local built, build_error = producer:build(shot_input(2))
  check(built ~= nil, build_error)
  local retried, retry_error = producer:retry(built)
  check(retry_error == nil, retry_error)
  check(retried == built, "retry rebuilt the envelope")
  equal(retried.event_id, built.event_id)
  equal(retried.event_sequence, 2)

  local next_event, next_error = producer:build(shot_input(2))
  check(next_event ~= nil, next_error)
  equal(next_event.event_sequence, 3)
  equal(next_event.event_id, "dcs-server-alpha:run-test-20260830:3")
end)

succeeds("producer accepts an injected allocator without loading dependencies", function()
  local allocator, allocator_error = event_id.new({ producer_id = "allocator-producer", run_key = "allocator-run" })
  check(allocator ~= nil, allocator_error)
  local producer, producer_error = envelope.new({
    allocator = allocator,
    producer_id = "allocator-producer",
    run_key = "allocator-run",
    source_version = "duel-dynamic-telemetry-v1",
  })
  check(producer ~= nil, producer_error)
  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)
  equal(started.event_sequence, 1)
  equal(started.event_id, "allocator-producer:allocator-run:1")
end)

succeeds("coalition IDs and canonical values normalize exactly", function()
  local expected = { [0] = "neutral", [1] = "red", [2] = "blue" }
  for id = 0, 2 do
    local name = expected[id]
    local producer = new_producer("producer-" .. id, "run-" .. id)
    local started, started_error = producer:build(started_input())
    check(started ~= nil, started_error)
    local event, event_error = producer:build(shot_input(id))
    check(event ~= nil, event_error)
    equal(event.coalition, name)
    equal(event.initiator.coalition, name)
    equal(event.asset.coalition, name)
  end

  local producer = new_producer("producer-canonical", "run-canonical")
  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)
  local canonical, canonical_error = producer:build(shot_input("red"))
  check(canonical ~= nil, canonical_error)
  equal(canonical.coalition, "red")
  local unknown, unknown_error = producer:build(shot_input(77))
  check(unknown ~= nil, unknown_error)
  equal(unknown.coalition, "unknown")
  equal(producer and envelope.map_coalition(nil), envelope.JSON_NULL)
  equal(envelope.map_coalition(envelope.JSON_NULL), envelope.JSON_NULL)
end)

succeeds("simulation time and DCS-local coordinates preserve numeric values", function()
  local producer = new_producer()
  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)
  local input = shot_input(2)
  input.sim_time = 9007199254740990
  input.location.x = -0.125
  input.location.y = 7620.5000001
  input.location.z = 44000.75
  local event, event_error = producer:build(input)
  check(event ~= nil, event_error)
  equal(event.sim_time, input.sim_time)
  equal(event.location.x, input.location.x)
  equal(event.location.y, input.location.y)
  equal(event.location.z, input.location.z)
  equal(event.location.coordinate_system, "dcs-local")
end)

succeeds("all absent nullable envelope fields become the explicit null sentinel", function()
  local producer = new_producer()
  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)
  for _, field_name in ipairs({
    "wall_time",
    "initiator",
    "target",
    "participant",
    "asset",
    "weapon",
    "coalition",
    "location",
  }) do
    equal(started[field_name], envelope.JSON_NULL, "missing " .. field_name .. " was not JSON null")
  end

  local first, first_error = producer:build({ event_type = "mission.heartbeat", sim_time = 1 })
  check(first ~= nil, first_error)
  local second, second_error = producer:build({ event_type = "mission.heartbeat", sim_time = 2 })
  check(second ~= nil, second_error)
  check(first.payload ~= second.payload, "default payload tables are aliased")
  equal(next(first.payload), nil)
  equal(next(second.payload), nil)
end)

succeeds("inapplicable attacker, target, and weapon stay null", function()
  local producer = new_producer()
  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)
  local dead_input = {
    event_type = "asset.dead",
    sim_time = 10,
    asset = {
      status = "known",
      asset_key = "aerial-1.1",
      coalition = 2,
    },
    coalition = 2,
    location = { status = "unknown", reason = "not-reported" },
  }
  local dead, dead_error = producer:build(dead_input)
  check(dead ~= nil, dead_error)
  equal(dead.initiator, envelope.JSON_NULL)
  equal(dead.target, envelope.JSON_NULL)
  equal(dead.weapon, envelope.JSON_NULL)
  equal(dead.participant, envelope.JSON_NULL)
end)

succeeds("unknown references remain unknown and nil player labels stay null", function()
  local producer = new_producer()
  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)
  local participant = {
    status = "unknown",
    reason = "stable-identity-unavailable",
    participant_id = "accidental-id",
    player_name = nil,
    display_name = "Reported Player",
    callsign = "Reported-1",
    coalition = 2,
  }
  local input = shot_input(2, participant)
  input.initiator = {
    status = "unknown",
    reason = "not-reported",
    display_name = nil,
    callsign = nil,
    dcs_name = "Aerial-1-1",
    dcs_type = "FA-18C_hornet",
    coalition = 2,
  }
  input.weapon = {
    status = "unknown",
    reason = "type-not-reported",
    display_name = nil,
  }
  local event, event_error = producer:build(input)
  check(event ~= nil, event_error)
  equal(event.participant.status, "unknown")
  equal(event.participant.participant_id, envelope.JSON_NULL)
  equal(event.participant.display_name, "Reported Player")
  equal(event.participant.callsign, "Reported-1")
  equal(event.participant.coalition, "blue")
  equal(event.initiator.status, "unknown")
  equal(event.initiator.kind, "unknown")
  equal(event.initiator.participant_id, envelope.JSON_NULL)
  equal(event.initiator.display_name, envelope.JSON_NULL)
  equal(event.weapon.status, "unknown")
  equal(event.weapon.dcs_type, envelope.JSON_NULL)
  check(event.participant.display_name ~= "Player", "nil player name became Player")
  check(event.initiator.display_name ~= "Player", "nil actor name became Player")
end)

succeeds("reference snapshots and payload are copied without input aliases", function()
  local producer = new_producer()
  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)
  local payload = { nested = { value = 1 } }
  local input = shot_input(2)
  input.payload = payload
  input.initiator.display_name = nil
  input.initiator.callsign = nil
  input.asset.dcs_name = nil
  input.asset.dcs_type = nil
  input.weapon.display_name = nil
  local event, event_error = producer:build(input)
  check(event ~= nil, event_error)

  check(event.initiator ~= input.initiator, "initiator was aliased")
  check(event.asset ~= input.asset, "asset was aliased")
  check(event.weapon ~= input.weapon, "weapon was aliased")
  check(event.participant ~= input.participant, "participant was aliased")
  check(event.location ~= input.location, "location was aliased")
  check(event.payload ~= input.payload, "payload was aliased")
  check(event.payload.nested ~= input.payload.nested, "nested payload was aliased")
  equal(event.initiator.display_name, envelope.JSON_NULL)
  equal(event.initiator.callsign, envelope.JSON_NULL)
  equal(event.asset.dcs_name, envelope.JSON_NULL)
  equal(event.asset.dcs_type, envelope.JSON_NULL)
  equal(event.weapon.display_name, envelope.JSON_NULL)

  input.initiator.asset_key = "mutated-input"
  input.location.x = 999
  payload.nested.value = 9
  equal(event.initiator.asset_key, "aerial-1.1")
  equal(event.location.x, 125000.25)
  equal(event.payload.nested.value, 1)

  event.participant.display_name = "mutated-output"
  event.payload.nested.value = 3
  equal(input.participant.display_name, "Viper")
  equal(payload.nested.value, 9)
end)

succeeds("wall time validates RFC 3339 values before allocation", function()
  local producer = new_producer("producer-wall-time", "run-wall-time")
  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)

  local offset_input = shot_input(2)
  offset_input.wall_time = "2026-08-30T12:02:05+05:30"
  local offset_event, offset_error = producer:build(offset_input)
  check(offset_event ~= nil, offset_error)
  equal(offset_event.wall_time, offset_input.wall_time)
  equal(offset_event.event_sequence, 2)

  local invalid_wall_times = {
    "2026-02-29T12:02:05Z",
    "2026-13-01T12:02:05Z",
    "2026-08-30T24:02:05Z",
    "2026-08-30T12:02:05",
    "2026-08-30T12:02:05.+00:00",
    "2026-08-30T12:02:05+24:00",
    "2026-08-30T12:02:05." .. string.rep("1", 129) .. "Z",
  }
  for _, wall_time in ipairs(invalid_wall_times) do
    local invalid = shot_input(2)
    invalid.wall_time = wall_time
    fails(function()
      return producer:build(invalid)
    end, "RFC 3339")
  end

  local next_event, next_error = producer:build(shot_input(2))
  check(next_event ~= nil, next_error)
  equal(next_event.event_sequence, 3)
end)

succeeds("payloads enforce JSON object and array shapes", function()
  local producer = new_producer("producer-payload", "run-payload")
  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)

  local input = shot_input(2)
  input.payload = {
    metadata = {
      labels = { "first", envelope.JSON_NULL, { enabled = true } },
    },
  }
  local event, event_error = producer:build(input)
  check(event ~= nil, event_error)
  equal(event.event_sequence, 2)
  check(event.payload ~= input.payload, "payload was aliased")
  check(event.payload.metadata.labels ~= input.payload.metadata.labels, "nested array was aliased")
  equal(event.payload.metadata.labels[1], "first")
  equal(event.payload.metadata.labels[2], envelope.JSON_NULL)
  equal(event.payload.metadata.labels[3].enabled, true)

  local root_key = shot_input(2)
  root_key.payload = { [1] = "root array is not an object" }
  fails(function()
    return producer:build(root_key)
  end, "object keys")

  local mixed = shot_input(2)
  mixed.payload = { nested = { [1] = "array item", named = "mixed" } }
  fails(function()
    return producer:build(mixed)
  end, "mixed")

  local sparse = shot_input(2)
  sparse.payload = { nested = { [1] = "first", [3] = "third" } }
  fails(function()
    return producer:build(sparse)
  end, "contiguous")

  local table_key = {}
  local nested_key = shot_input(2)
  nested_key.payload = { nested = { [table_key] = "table keys are not JSON" } }
  fails(function()
    return producer:build(nested_key)
  end, "payload keys")

  local cyclic = {}
  cyclic.self = cyclic
  local cyclic_input = shot_input(2)
  cyclic_input.payload = { nested = cyclic }
  fails(function()
    return producer:build(cyclic_input)
  end, "cyclic")

  local non_finite = shot_input(2)
  non_finite.payload = { value = math.huge }
  fails(function()
    return producer:build(non_finite)
  end, "non-finite")

  local next_event, next_error = producer:build(shot_input(2))
  check(next_event ~= nil, next_error)
  equal(next_event.event_sequence, 3)
end)

succeeds("invalid producer configuration and input never consume a sequence", function()
  fails(function()
    return event_id.new({ producer_id = "bad:id", run_key = "run-1" })
  end, "invalid character")
  fails(function()
    return envelope.new({
      event_id = event_id,
      producer_id = "producer-1",
      run_key = "run-1",
      source_version = "",
    })
  end, "source_version")

  local producer = new_producer("producer-invalid", "run-invalid")
  fails(function()
    return producer:build({ event_type = "mission.started", sim_time = 0, payload = {} })
  end, "mission_name")
  local started, started_error = producer:build(started_input())
  check(started ~= nil, started_error)
  fails(function()
    return producer:build({ event_type = "mission.heartbeat", sim_time = "not-a-number" })
  end, "sim_time")
  local heartbeat, heartbeat_error = producer:build({ event_type = "mission.heartbeat", sim_time = 1 })
  check(heartbeat ~= nil, heartbeat_error)
  equal(heartbeat.event_sequence, 2)
end)

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  error(string.format("%d of %d telemetry tests failed", #failures, tests_run))
end

io.write(string.format("telemetry Lua tests: %d passed\n", tests_run))

local event_id = dofile("src/missions/duel-dynamic/telemetry/event_id.lua")
local envelope = dofile("src/missions/duel-dynamic/telemetry/envelope.lua")
local json = dofile("src/missions/duel-dynamic/telemetry/json.lua")
local ndjson_sink = dofile("src/missions/duel-dynamic/telemetry/ndjson_sink.lua")
local lifecycle = dofile("src/missions/duel-dynamic/telemetry/lifecycle.lua")
local development = dofile("src/missions/duel-dynamic/telemetry/development.lua")

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

local function new_producer(label)
  local producer, producer_error = envelope.new({
    event_id = event_id,
    producer_id = "lifecycle-producer-" .. label,
    run_key = "run-lifecycle-" .. label,
    source_version = "duel-dynamic-telemetry-v1",
  })
  check(producer ~= nil, producer_error)
  return producer
end

local function started_payload(overrides)
  local payload = {
    mission_name = "duel-dynamic",
    mission_version = "1",
    map_name = "Caucasus",
    run_classification = "test",
  }
  for key, value in pairs(overrides or {}) do
    payload[key] = value
  end
  return payload
end

local function new_memory_sink(fail_calls)
  local events = {}
  local calls = 0
  local sink = {}
  function sink:write(event)
    calls = calls + 1
    if fail_calls and fail_calls[calls] then
      return nil, "simulated sink failure " .. tostring(calls)
    end
    events[#events + 1] = event
    return true
  end
  return sink, events, function()
    return calls
  end
end

local function new_controller(label, sink, options)
  options = options or {}
  local sim_time = options.sim_time or 0
  local controller, creation_error = lifecycle.new({
    producer = new_producer(label),
    sink = sink,
    sim_time = function()
      return sim_time
    end,
    wall_time = options.wall_time or function()
      return "2026-08-31T12:00:00Z"
    end,
    started_payload = options.started_payload or started_payload(),
  })
  check(controller ~= nil, creation_error)
  return controller, function(value)
    sim_time = value
  end
end

local function read_all(path)
  local file, open_error = io.open(path, "rb")
  check(file ~= nil, open_error)
  local content, read_error = file:read("*a")
  local close_ok, close_error = file:close()
  check(content ~= nil, read_error)
  check(close_ok ~= nil, close_error)
  return content
end

local function count_lines(content)
  local count = 0
  for _ in string.gmatch(content, "[^\n]+\n") do
    count = count + 1
  end
  return count
end

succeeds("lifecycle emits one ordered start, heartbeat, and idempotent end", function()
  local sink, events, calls = new_memory_sink()
  local controller, set_sim_time = new_controller("ordered", sink)

  local started, started_error = controller:start()
  check(started ~= nil, started_error)
  equal(controller:state(), "active")
  equal(started.event_sequence, 1)
  equal(started.event_type, "mission.started")
  equal(started.payload.mission_name, "duel-dynamic")
  check(started.initiator == envelope.JSON_NULL, "lifecycle initiator was not JSON null")

  set_sim_time(30)
  local heartbeat, heartbeat_error = controller:heartbeat()
  check(heartbeat ~= nil, heartbeat_error)
  equal(heartbeat.event_sequence, 2)
  equal(heartbeat.event_type, "mission.heartbeat")

  set_sim_time(60)
  local ended, ended_error = controller:finish()
  check(ended ~= nil, ended_error)
  equal(ended.event_sequence, 3)
  equal(ended.event_type, "mission.ended")
  equal(ended.payload.reason, "mission-end-observed")
  equal(controller:state(), "ended")

  local repeated, repeated_error = controller:finish()
  check(repeated ~= nil, repeated_error)
  check(repeated == ended, "repeated finish did not return the original terminal event")
  equal(calls(), 3)
  equal(#events, 3)
  fails(function()
    return controller:heartbeat()
  end, "active lifecycle")
end)

succeeds("pending mission.started retry preserves identity and sequence", function()
  local sink, events, calls = new_memory_sink({ [1] = true })
  local controller = new_controller("start-retry", sink)

  fails(function()
    return controller:start()
  end, "persisting mission.started")
  equal(controller:state(), "faulted")
  local pending = controller:pending_event()
  check(type(pending) == "table", "failed start did not retain its envelope")
  equal(pending.event_sequence, 1)

  local retried, retry_error = controller:retry_pending()
  check(retried ~= nil, retry_error)
  check(retried == pending, "retry replaced the built start envelope")
  equal(controller:state(), "active")
  equal(calls(), 2)
  equal(#events, 1)

  local heartbeat, heartbeat_error = controller:heartbeat()
  check(heartbeat ~= nil, heartbeat_error)
  equal(heartbeat.event_sequence, 2)
end)

succeeds("pending heartbeat retry prevents sequence gaps", function()
  local sink, events = new_memory_sink({ [2] = true })
  local controller = new_controller("heartbeat-retry", sink)
  check(controller:start())

  fails(function()
    return controller:heartbeat()
  end, "persisting mission.heartbeat")
  local pending = controller:pending_event()
  equal(pending.event_sequence, 2)
  equal(pending.event_type, "mission.heartbeat")

  local retried, retry_error = controller:retry_pending()
  check(retried ~= nil, retry_error)
  check(retried == pending, "retry replaced the built heartbeat envelope")
  local ended, end_error = controller:finish()
  check(ended ~= nil, end_error)
  equal(ended.event_sequence, 3)
  equal(#events, 3)
end)

succeeds("lifecycle faults closed without breaking callers", function()
  local sink = new_memory_sink({ [1] = true, [2] = true })
  local controller = new_controller("fault-closed", sink)
  fails(function()
    return controller:start()
  end, "persisting mission.started")
  fails(function()
    return controller:retry_pending()
  end, "pending mission.started")
  equal(controller:state(), "faulted")
  fails(function()
    return controller:heartbeat()
  end, "active lifecycle")
  fails(function()
    return controller:finish()
  end, "active lifecycle")
end)

succeeds("invalid start metadata faults before allocation", function()
  local sink, events, calls = new_memory_sink()
  local controller = new_controller("invalid-start", sink, {
    started_payload = started_payload({ mission_name = "" }),
  })
  fails(function()
    return controller:start()
  end, "building mission.started")
  equal(controller:state(), "faulted")
  check(controller:pending_event() == nil, "validation failure unexpectedly retained an allocated event")
  equal(calls(), 0)
  equal(#events, 0)
end)

succeeds("wall-time provider failure normalizes to JSON null", function()
  local sink, events = new_memory_sink()
  local controller = new_controller("wall-null", sink, {
    wall_time = function()
      error("clock unavailable")
    end,
  })
  local started, start_error = controller:start()
  check(started ~= nil, start_error)
  check(events[1].wall_time == envelope.JSON_NULL, "wall-time failure was not normalized to JSON null")
end)

succeeds("development adapter writes lifecycle NDJSON and creates fresh runs", function()
  local temporary_directory = os.getenv("TEMP") or os.getenv("TMP") or "."
  temporary_directory = string.gsub(temporary_directory, "\\", "/")
  local unique = tostring(os.time()) .. "-" .. tostring(math.floor(os.clock() * 1000000))
  local created_paths = {}
  local schedules = {}
  local watchers = {}
  local logs = {}
  local state = {}
  local model_time = 0

  local fake_lfs = {
    writedir = function()
      return "C:/Users/example/Saved Games/DCS.dcs_serverrelease/"
    end,
    attributes = function(path, attribute)
      if path == temporary_directory and attribute == "mode" then
        return "directory"
      end
      return nil
    end,
    mkdir = function()
      return nil, "unexpected mkdir"
    end,
  }
  local fake_os = {
    date = function(format)
      if format == "!%Y%m%dT%H%M%SZ" then
        return "20260831T120000Z"
      end
      return "2026-08-31T12:00:00Z"
    end,
    time = function()
      return tonumber(string.match(unique, "^(%d+)")) or 1
    end,
    clock = function()
      return tonumber(string.match(unique, "%-(%d+)$")) or 1
    end,
  }
  local fake_timer = {
    getTime = function()
      return model_time
    end,
    getAbsTime = function()
      return 5000
    end,
  }
  local fake_env = {
    mission = { theatre = "Caucasus" },
    info = function(message)
      logs[#logs + 1] = "INFO " .. message
    end,
    error = function(message)
      logs[#logs + 1] = "ERROR " .. message
    end,
  }
  local fake_base = {}
  function fake_base:New()
    local watcher = {}
    function watcher:HandleEvent(event)
      self.handled = event
    end
    function watcher:UnHandleEvent(event)
      self.unhandled = event
    end
    watchers[#watchers + 1] = watcher
    return watcher
  end
  local fake_scheduler = {}
  function fake_scheduler:New(_, callback, _, start_after, repeat_after)
    local schedule = { callback = callback, start_after = start_after, repeat_after = repeat_after }
    function schedule:Remove(id)
      self.removed = id
    end
    schedules[#schedules + 1] = schedule
    return schedule, #schedules
  end
  local dependencies = {
    event_id = event_id,
    envelope = envelope,
    json = json,
    ndjson_sink = ndjson_sink,
    lifecycle = lifecycle,
    io = io,
    lfs = fake_lfs,
    os = fake_os,
    timer = fake_timer,
    env = fake_env,
    BASE = fake_base,
    SCHEDULER = fake_scheduler,
    EVENTS = { MissionEnd = 12 },
    state = state,
    telemetry_directory = temporary_directory,
    heartbeat_interval = 30,
    mission_name = "duel-dynamic",
    mission_version = "1",
    source_version = "duel-dynamic-telemetry-v1",
    run_classification = "test",
  }

  local first, first_error = development.start(dependencies)
  check(first ~= nil, first_error)
  created_paths[#created_paths + 1] = first.path
  equal(first.controller:state(), "active")
  equal(schedules[1].start_after, 30)
  equal(schedules[1].repeat_after, 30)
  equal(count_lines(read_all(first.path)), 1)

  model_time = 30
  check(schedules[1].callback(), "heartbeat callback stopped unexpectedly")
  equal(count_lines(read_all(first.path)), 2)
  model_time = 60
  watchers[1]:OnEventMissionEnd()
  equal(first.controller:state(), "ended")
  equal(schedules[1].removed, 1)
  local first_content = read_all(first.path)
  equal(count_lines(first_content), 3)
  check(string.find(first_content, '"event_type":"mission.started"', 1, true), "start event missing")
  check(string.find(first_content, '"event_type":"mission.heartbeat"', 1, true), "heartbeat event missing")
  check(string.find(first_content, '"event_type":"mission.ended"', 1, true), "end event missing")
  check(string.find(first_content, '"map_name":"Caucasus"', 1, true), "map name missing")

  watchers[1]:OnEventMissionEnd()
  equal(count_lines(read_all(first.path)), 3)

  model_time = 0
  local second, second_error = development.start(dependencies)
  check(second ~= nil, second_error)
  created_paths[#created_paths + 1] = second.path
  check(first.run_key ~= second.run_key, "same-process mission restart reused a run key")
  equal(first.producer_id, second.producer_id)
  check(string.find(first.producer_id, "dcs-dev-", 1, true) == 1, "development producer ID has wrong prefix")
  equal(count_lines(read_all(second.path)), 1)
  watchers[2]:OnEventMissionEnd()

  for _, path in ipairs(created_paths) do
    os.remove(path)
  end
  for _, message in ipairs(logs) do
    check(string.find(message, "ERROR ", 1, true) ~= 1, "development adapter logged an error: " .. message)
  end
end)

if #failures > 0 then
  for _, message in ipairs(failures) do
    io.stderr:write("FAIL: " .. message .. "\n")
  end
  error(string.format("telemetry lifecycle tests failed: %d/%d", #failures, tests_run))
end

io.write(string.format("telemetry lifecycle tests: %d passed\n", tests_run))

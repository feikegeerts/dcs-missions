local event_id = dofile("src/missions/duel-dynamic/telemetry/event_id.lua")
local envelope = dofile("src/missions/duel-dynamic/telemetry/envelope.lua")
local json = dofile("src/missions/duel-dynamic/telemetry/json.lua")
local lifecycle = dofile("src/missions/duel-dynamic/telemetry/lifecycle.lua")
local asset = dofile("src/missions/duel-dynamic/telemetry/asset.lua")
local shot = dofile("src/missions/duel-dynamic/telemetry/shot.lua")
local combat = dofile("src/missions/duel-dynamic/telemetry/combat.lua")
local participant = dofile("src/missions/duel-dynamic/telemetry/participant.lua")
local bridge_queue = dofile("src/missions/duel-dynamic/telemetry/bridge_queue.lua")
local bridge_frame = dofile("src/missions/duel-dynamic/telemetry/bridge_frame.lua")
local bridge = dofile("src/missions/duel-dynamic/telemetry/bridge.lua")

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

local function new_queue(max_lines)
  local queue, queue_error = bridge_queue.new({ max_lines = max_lines or 8 })
  check(queue ~= nil, queue_error)
  return queue
end

local function replace_header_field(frame, field_index, replacement)
  local newline = string.find(frame, "\n", 1, true)
  local header = string.sub(frame, 1, newline - 1)
  local fields = {}
  for field in string.gmatch(header .. "|", "([^|]*)|") do
    fields[#fields + 1] = field
  end
  fields[field_index] = replacement
  return table.concat(fields, "|") .. string.sub(frame, newline)
end

local function exact_size_line(size)
  for payload_length = size, 1, -1 do
    local line = string.rep("x", payload_length)
    local header = "DDBRIDGE1|p|r|1|1|1|" .. tostring(payload_length) .. "\n"
    if string.len(header) + string.len(tostring(payload_length)) + 1 + payload_length == size then
      return line
    end
  end
  error("could not construct exact-size frame")
end

local function new_runtime(options)
  options = options or {}
  local watchers = {}
  local schedules = {}
  local logs = {}
  local model_time = 0
  local fake_base = {}
  function fake_base:New()
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
  local fake_scheduler = {}
  function fake_scheduler:New(_, callback, _, start_after, repeat_after)
    local schedule = { callback = callback, start_after = start_after, repeat_after = repeat_after }
    function schedule:Remove(id)
      self.removed = id
    end
    schedules[#schedules + 1] = schedule
    return schedule, #schedules
  end
  local fake_env = {
    mission = { theatre = "Caucasus" },
    info = function(message)
      logs[#logs + 1] = "INFO " .. message
    end,
    warning = function(message)
      logs[#logs + 1] = "WARNING " .. message
    end,
    error = function(message)
      logs[#logs + 1] = "ERROR " .. message
    end,
  }
  local runtime, runtime_error = bridge.start({
    event_id = event_id,
    envelope = envelope,
    json = json,
    lifecycle = lifecycle,
    bridge_queue = bridge_queue,
    bridge_frame = bridge_frame,
    asset = asset,
    shot = shot,
    combat = combat,
    participant = participant,
    timer = {
      getTime = function()
        return model_time
      end,
    },
    env = fake_env,
    BASE = fake_base,
    SCHEDULER = fake_scheduler,
    EVENTS = {
      MissionEnd = 10,
      PlayerEnterAircraft = 11,
      PlayerLeaveUnit = 12,
      Dead = 13,
      Crash = 14,
      UnitLost = 15,
      PilotDead = 16,
      Ejection = 17,
      Shot = 18,
      Hit = 19,
      Kill = 20,
    },
    state = {},
    player_group_names = { "Aerial-1", "Aerial-2", "Aerial-3", "Aerial-4" },
    bandit_group_names = { "Bandit-1", "Bandit-2", "Bandit-3" },
    player_coalition = 2,
    bandit_coalition = 1,
    heartbeat_interval = 30,
    mission_name = "duel-dynamic",
    mission_version = "1",
    source_version = "duel-dynamic-telemetry-v1",
    run_classification = options.run_classification,
    queue_max_lines = options.queue_max_lines,
  })
  check(runtime ~= nil, runtime_error)
  return runtime, watchers, schedules, logs, function(value)
    model_time = value
  end
end

succeeds("queue appends and peeks lifetime-indexed lines", function()
  local queue = new_queue()
  check(queue:append("one"))
  check(queue:append("two"))
  local lines, first, last = queue:peek(1, 8)
  equal(table.concat(lines, ","), "one,two")
  equal(first, 1)
  equal(last, 2)
end)

succeeds("queue peek is non-destructive and idempotent", function()
  local queue = new_queue()
  check(queue:append("same"))
  local first_lines, first_index, last_index = queue:peek(1, 1)
  local second_lines, repeated_first, repeated_last = queue:peek(1, 1)
  equal(first_lines[1], second_lines[1])
  equal(first_index, repeated_first)
  equal(last_index, repeated_last)
  equal(queue:pending_count(), 1)
end)

succeeds("queue peek honors max_count", function()
  local queue = new_queue()
  for index = 1, 4 do
    check(queue:append(tostring(index)))
  end
  local lines, first, last = queue:peek(2, 2)
  equal(#lines, 2)
  equal(first, 2)
  equal(last, 3)
end)

succeeds("queue contiguous prefix acknowledgement advances first pending index", function()
  local queue = new_queue()
  for index = 1, 5 do
    check(queue:append(tostring(index)))
  end
  check(queue:ack(3))
  equal(queue:acked_count(), 3)
  equal(queue:first_pending_index(), 4)
  local lines, first = queue:peek(4, 10)
  equal(first, 4)
  equal(table.concat(lines, ","), "4,5")
end)

succeeds("queue rejects stale acknowledgement", function()
  local queue = new_queue()
  check(queue:append("one"))
  check(queue:ack(1))
  fails(function()
    return queue:ack(1)
  end, "stale")
end)

succeeds("queue rejects beyond-pending acknowledgement", function()
  local queue = new_queue()
  check(queue:append("one"))
  fails(function()
    return queue:ack(2)
  end, "beyond pending")
end)

succeeds("queue empty operations reject and report empty accessors", function()
  local queue = new_queue()
  equal(queue:pending_count(), 0)
  equal(queue:acked_count(), 0)
  equal(queue:first_pending_index(), nil)
  equal(queue:is_full(), false)
  fails(function()
    return queue:peek(1, 1)
  end, "empty")
  fails(function()
    return queue:ack(1)
  end, "beyond pending")
end)

succeeds("queue overflow is stable and never drops", function()
  local queue = new_queue(2)
  check(queue:append("one"))
  check(queue:append("two"))
  equal(queue:is_full(), true)
  fails(function()
    return queue:append("three")
  end, "bridge queue overflow: maximum pending lines 2 reached")
  equal(queue:pending_count(), 2)
end)

succeeds("queue validates configuration and input", function()
  fails(function()
    return bridge_queue.new({ max_lines = 0 })
  end, "positive integer")
  local queue = new_queue()
  fails(function()
    return queue:append("")
  end, "non-empty")
  fails(function()
    return queue:peek(0, 1)
  end, "positive integer")
end)

succeeds("frame round trip preserves mixed payload lengths and header fields", function()
  local lines = { "{}", '{"long":"value|with delimiter"}', "[]" }
  local frame, frame_error = bridge_frame.encode({
    producer_id = "producer-1",
    run_key = "run-1",
    first_sequence = 4,
    last_sequence = 6,
  }, lines)
  check(frame ~= nil, frame_error)
  local decoded, decode_error = bridge_frame.decode(frame)
  check(decoded ~= nil, decode_error)
  equal(decoded.producer_id, "producer-1")
  equal(decoded.run_key, "run-1")
  equal(decoded.first_sequence, 4)
  equal(decoded.last_sequence, 6)
  equal(decoded.count, 3)
  equal(decoded.payload_bytes, string.len(lines[1]) + string.len(lines[2]) + string.len(lines[3]))
  equal(table.concat(decoded.lines, "\n"), table.concat(lines, "\n"))
end)

succeeds("frame exactly at 65536 bytes encodes", function()
  local line = exact_size_line(65536)
  local frame, frame_error = bridge_frame.encode({
    producer_id = "p",
    run_key = "r",
    first_sequence = 1,
    last_sequence = 1,
  }, { line })
  check(frame ~= nil, frame_error)
  equal(string.len(frame), 65536)
  check(bridge_frame.decode(frame))
end)

succeeds("frame larger than 65536 bytes rejects", function()
  local line = exact_size_line(65536) .. "x"
  fails(function()
    return bridge_frame.encode({ producer_id = "p", run_key = "r", first_sequence = 1, last_sequence = 1 }, { line })
  end, "frame-too-large")
end)

succeeds("frame encode rejects NUL payload", function()
  fails(function()
    return bridge_frame.encode({ producer_id = "p", run_key = "r", first_sequence = 1, last_sequence = 1 }, { "a\0b" })
  end, "contains NUL")
end)

succeeds("frame decode rejects NUL", function()
  fails(function()
    return bridge_frame.decode("DDBRIDGE1|p|r|1|1|1|3\n3|a\0b")
  end, "contains NUL")
end)

succeeds("frame decode rejects bad magic", function()
  fails(function()
    return bridge_frame.decode("WRONG|p|r|1|1|1|2\n2|{}")
  end, "magic")
end)

succeeds("frame decode rejects wrong header field count", function()
  fails(function()
    return bridge_frame.decode("DDBRIDGE1|p|r|1|1|1\n2|{}")
  end, "exactly 7")
end)

succeeds("frame decode rejects wrong payload byte total", function()
  local frame = bridge_frame.encode(
    { producer_id = "p", run_key = "r", first_sequence = 1, last_sequence = 1 },
    { "{}" }
  )
  fails(function()
    return bridge_frame.decode(replace_header_field(frame, 7, "3"))
  end, "payload_bytes")
end)

succeeds("frame decode rejects wrong count", function()
  local frame = bridge_frame.encode(
    { producer_id = "p", run_key = "r", first_sequence = 1, last_sequence = 1 },
    { "{}" }
  )
  fails(function()
    return bridge_frame.decode(replace_header_field(frame, 6, "2"))
  end, "sequence range")
end)

succeeds("frame decode rejects sequence gap", function()
  local frame = bridge_frame.encode(
    { producer_id = "p", run_key = "r", first_sequence = 1, last_sequence = 1 },
    { "{}" }
  )
  fails(function()
    return bridge_frame.decode(replace_header_field(frame, 5, "2"))
  end, "sequence range")
end)

succeeds("frame decode rejects truncation", function()
  local frame = bridge_frame.encode(
    { producer_id = "p", run_key = "r", first_sequence = 1, last_sequence = 1 },
    { "{}" }
  )
  fails(function()
    return bridge_frame.decode(string.sub(frame, 1, -2))
  end, "truncated")
end)

succeeds("frame decode rejects trailing garbage", function()
  local frame = bridge_frame.encode(
    { producer_id = "p", run_key = "r", first_sequence = 1, last_sequence = 1 },
    { "{}" }
  )
  fails(function()
    return bridge_frame.decode(frame .. "x")
  end, "trailing garbage")
end)

succeeds("frame encode rejects empty lines", function()
  fails(function()
    return bridge_frame.encode({ producer_id = "p", run_key = "r", first_sequence = 1, last_sequence = 1 }, {})
  end, "non-empty array")
end)

succeeds("frame codec validates producer and run tokens", function()
  fails(function()
    return bridge_frame.encode(
      { producer_id = "bad producer", run_key = "r", first_sequence = 1, last_sequence = 1 },
      { "{}" }
    )
  end, "invalid character")
  fails(function()
    return bridge_frame.decode("DDBRIDGE1|p|bad run|1|1|1|2\n2|{}")
  end, "invalid character")
  local maximum = event_id.MAX_SEQUENCE
  local frame = bridge_frame.encode({
    producer_id = "p",
    run_key = "r",
    first_sequence = maximum,
    last_sequence = maximum,
  }, { "{}" })
  local decoded = bridge_frame.decode(frame)
  equal(decoded.first_sequence, maximum)
end)

succeeds("bridge starts waiting with no subscriptions or sequence", function()
  local runtime, watchers, schedules = new_runtime()
  local status = runtime:status()
  equal(status.state, "waiting")
  equal(status.pending_count, 0)
  equal(status.producer_id, nil)
  equal(#watchers, 0)
  equal(#schedules, 0)
  fails(function()
    return runtime:peek(1, 1)
  end, "not begun")
  fails(function()
    return runtime:ack(1)
  end, "not begun")
end)

succeeds("bridge invalid handshake has no side effects", function()
  local runtime, watchers, schedules = new_runtime()
  fails(function()
    return runtime:begin("bad producer id!", "run-1")
  end, "invalid character")
  equal(runtime:status().state, "waiting")
  equal(#watchers, 0)
  equal(#schedules, 0)
end)

succeeds("bridge valid handshake emits mission.started and exposes mission surface", function()
  local runtime = new_runtime()
  check(runtime:begin("producer-1", "run-1"))
  equal(runtime:status().state, "active")
  equal(runtime:status().pending_count, 1)
  equal(runtime:status().first_pending_sequence, 1)
  check(_G.duel_telemetry_bridge == runtime)
  check(_G.duel_telemetry_runtime == runtime)
  check(type(runtime.asset.register_bandit_group) == "function")
  check(type(runtime.asset.register_player_group) == "function")
  equal(runtime.path, "run-1")
end)

succeeds("bridge rejects a second begin", function()
  local runtime = new_runtime()
  check(runtime:begin("producer-2", "run-2"))
  fails(function()
    return runtime:begin("producer-2", "run-2")
  end, "already begun")
end)

succeeds("bridge heartbeat becomes sequence two", function()
  local runtime, _, schedules, _, set_time = new_runtime()
  check(runtime:begin("producer-3", "run-3"))
  set_time(30)
  check(schedules[1].callback())
  local frame = runtime:peek(1, 10)
  local decoded = bridge_frame.decode(frame)
  equal(decoded.count, 2)
  check(string.find(decoded.lines[2], '"event_type":"mission.heartbeat"', 1, true))
  check(string.find(decoded.lines[2], '"event_sequence":2', 1, true))
end)

succeeds("bridge peek frame identifies exact pending range", function()
  local runtime, _, schedules = new_runtime()
  check(runtime:begin("producer-4", "run-4"))
  check(schedules[1].callback())
  local decoded = bridge_frame.decode(runtime:peek(1, 10))
  equal(decoded.producer_id, "producer-4")
  equal(decoded.run_key, "run-4")
  equal(decoded.first_sequence, 1)
  equal(decoded.last_sequence, 2)
  equal(decoded.count, 2)
end)

succeeds("bridge bounded peek and acknowledgement enforce stale range", function()
  local runtime, _, schedules = new_runtime()
  check(runtime:begin("producer-5", "run-5"))
  check(schedules[1].callback())
  local decoded = bridge_frame.decode(runtime:peek(1, 1))
  equal(decoded.count, 1)
  check(runtime:ack(1))
  fails(function()
    return runtime:peek(1, 10)
  end, "stale")
  local rest = bridge_frame.decode(runtime:peek(2, 10))
  equal(rest.first_sequence, 2)
end)

succeeds("bridge rejects beyond-pending acknowledgement", function()
  local runtime = new_runtime()
  check(runtime:begin("producer-6", "run-6"))
  fails(function()
    return runtime:ack(2)
  end, "beyond pending")
end)

succeeds("bridge returns empty drained marker", function()
  local runtime = new_runtime()
  check(runtime:begin("producer-7", "run-7"))
  check(runtime:ack(1))
  equal(runtime:peek(2, 10), "")
  fails(function()
    return runtime:peek(2, 0)
  end, "max_frames")
end)

succeeds("bridge queue overflow faults lifecycle and retains pending event", function()
  local runtime, _, schedules, logs = new_runtime({ queue_max_lines = 1 })
  check(runtime:begin("producer-8", "run-8"))
  equal(schedules[1].callback(), false)
  local status = runtime:status()
  equal(status.state, "faulted")
  check(string.find(status.fault_error, "bridge queue overflow", 1, true))
  equal(runtime.controller:pending_event().event_sequence, 2)
  fails(function()
    return runtime.controller:retry_pending()
  end, "bridge queue overflow")
  check(string.find(table.concat(logs, "\n"), "ERROR", 1, true))
end)

succeeds("lifecycle transient sink retry succeeds with exact envelope", function()
  local calls = 0
  local sink = {}
  function sink:write()
    calls = calls + 1
    if calls == 1 then
      return nil, "transient"
    end
    return true
  end
  local producer = envelope.new({
    event_id = event_id,
    producer_id = "transient-producer",
    run_key = "transient-run",
    source_version = "duel-dynamic-telemetry-v1",
  })
  local controller = lifecycle.new({
    producer = producer,
    sink = sink,
    sim_time = function()
      return 0
    end,
    wall_time = function()
      return envelope.JSON_NULL
    end,
    started_payload = {
      mission_name = "duel-dynamic",
      mission_version = "1",
      map_name = "Caucasus",
      run_classification = "historical",
    },
  })
  fails(function()
    return controller:start()
  end, "transient")
  local pending = controller:pending_event()
  local retried, retry_error = controller:retry_pending()
  check(retried ~= nil, retry_error)
  check(retried == pending)
  equal(controller:state(), "active")
end)

succeeds("bridge envelopes always encode null wall_time", function()
  local runtime, _, schedules = new_runtime()
  check(runtime:begin("producer-9", "run-9"))
  check(schedules[1].callback())
  local decoded = bridge_frame.decode(runtime:peek(1, 10))
  for _, line in ipairs(decoded.lines) do
    check(string.find(line, '"wall_time":null', 1, true), "wall_time was not null: " .. line)
  end
end)

succeeds("bridge defaults run classification to historical", function()
  local runtime = new_runtime()
  check(runtime:begin("producer-10", "run-10"))
  local decoded = bridge_frame.decode(runtime:peek(1, 1))
  check(string.find(decoded.lines[1], '"run_classification":"historical"', 1, true))
end)

succeeds("bridge permits explicit test run classification", function()
  local runtime = new_runtime({ run_classification = "test" })
  check(runtime:begin("producer-11", "run-11"))
  local decoded = bridge_frame.decode(runtime:peek(1, 1))
  check(string.find(decoded.lines[1], '"run_classification":"test"', 1, true))
end)

succeeds("MissionEnd finishes with mission.ended last and remains drainable", function()
  local runtime, watchers = new_runtime()
  check(runtime:begin("producer-12", "run-12"))
  watchers[1]:OnEventMissionEnd()
  equal(runtime:status().state, "ended")
  local decoded = bridge_frame.decode(runtime:peek(1, 10))
  equal(decoded.count, 2)
  check(string.find(decoded.lines[2], '"event_type":"mission.ended"', 1, true))
  check(runtime:ack(2))
  equal(runtime:peek(3, 10), "")
end)

succeeds("bridge refuses oversized frames without silently splitting", function()
  local runtime = new_runtime()
  check(runtime:begin("producer-13", "run-13"))
  local original_encode = bridge_frame.encode
  bridge_frame.encode = function()
    return nil, "frame-too-large"
  end
  fails(function()
    return runtime:peek(1, 10)
  end, "frame-too-large")
  bridge_frame.encode = original_encode
  equal(runtime:status().pending_count, 1)
end)

succeeds("production bridge modules contain no sandbox escape references", function()
  local paths = {
    "src/missions/duel-dynamic/telemetry/bridge_queue.lua",
    "src/missions/duel-dynamic/telemetry/bridge_frame.lua",
    "src/missions/duel-dynamic/telemetry/bridge.lua",
  }
  local forbidden = { "io%.", "os%.", "lfs%.", "dofile", "loadfile", "require%s*%(" }
  for _, path in ipairs(paths) do
    local handle, open_error = io.open(path, "rb")
    check(handle ~= nil, open_error)
    local source = handle:read("*a")
    handle:close()
    for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
      if string.match(line, "^%s*%-%-") == nil then
        for _, pattern in ipairs(forbidden) do
          check(string.find(line, pattern) == nil, path .. " contains forbidden source: " .. line)
        end
      end
    end
  end
end)

if #failures > 0 then
  for _, message in ipairs(failures) do
    io.stderr:write("FAIL: " .. message .. "\n")
  end
  error(string.format("telemetry bridge tests failed: %d/%d", #failures, tests_run))
end

io.write(string.format("telemetry bridge tests: %d passed\n", tests_run))

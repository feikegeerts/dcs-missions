local host_io = io
local host_os = os
local module_frame = dofile("src/missions/duel-dynamic/telemetry/bridge_frame.lua")

local total_tests = 0
local total_failures = {}

local function run_mapping(mapping)
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
    total_tests = total_tests + 1
    local ok, message = pcall(callback)
    if not ok then
      failures[#failures + 1] = name .. ": " .. tostring(message)
    end
  end

  local function normalized(path)
    path = string.gsub(path, "\\", "/")
    path = string.gsub(path, "/+", "/")
    return path
  end

  local function new_filesystem()
    local fs = {
      files = {},
      directories = { ["mock-root"] = true, ["mock-root/"] = true },
      fail_write = false,
    }

    function fs:mkdir(path)
      self.directories[normalized(path)] = true
      return true
    end

    function fs:attributes(path, field)
      path = normalized(path)
      local mode
      if self.directories[path] then
        mode = "directory"
      elseif self.files[path] ~= nil then
        mode = "file"
      end
      if field == "mode" then
        return mode
      end
      return mode and { mode = mode } or nil
    end

    function fs:open(path, mode)
      path = normalized(path)
      if mode == "rb" then
        if self.files[path] == nil then
          return nil, "not found"
        end
        local handle = { content = self.files[path], closed = false }
        function handle:read(format)
          assert(not self.closed, "read on closed file")
          assert(format == "*a", "unsupported read")
          return self.content
        end
        function handle:close()
          self.closed = true
          return nil
        end
        return handle
      end
      if mode ~= "wb" and mode ~= "ab" then
        return nil, "unsupported mode"
      end
      local handle = {
        fs = self,
        path = path,
        content = mode == "ab" and (self.files[path] or "") or "",
        closed = false,
      }
      function handle:write(bytes)
        assert(not self.closed, "write on closed file")
        if self.fs.fail_write then
          error("injected write failure")
        end
        self.content = self.content .. bytes
        self.fs.files[self.path] = self.content
        return nil
      end
      function handle:flush()
        assert(not self.closed, "flush on closed file")
        self.fs.files[self.path] = self.content
        return nil
      end
      function handle:close()
        self.fs.files[self.path] = self.content
        self.closed = true
        return nil
      end
      return handle
    end

    return fs
  end

  local function make_io(fs)
    return {
      open = function(path, mode)
        return fs:open(path, mode)
      end,
    }
  end

  local function load_in_environment(path, environment)
    local chunk, load_error = loadfile(path)
    check(chunk ~= nil, load_error)
    setfenv(chunk, environment)
    return chunk()
  end

  local module_paths = {
    event_id = "src/missions/duel-dynamic/telemetry/event_id.lua",
    envelope = "src/missions/duel-dynamic/telemetry/envelope.lua",
    json = "src/missions/duel-dynamic/telemetry/json.lua",
    lifecycle = "src/missions/duel-dynamic/telemetry/lifecycle.lua",
    asset = "src/missions/duel-dynamic/telemetry/asset.lua",
    shot = "src/missions/duel-dynamic/telemetry/shot.lua",
    combat = "src/missions/duel-dynamic/telemetry/combat.lua",
    participant = "src/missions/duel-dynamic/telemetry/participant.lua",
    bridge_queue = "src/missions/duel-dynamic/telemetry/bridge_queue.lua",
    bridge_frame = "src/missions/duel-dynamic/telemetry/bridge_frame.lua",
    bridge = "src/missions/duel-dynamic/telemetry/bridge.lua",
  }

  local function new_mission_environment()
    local denied = { io = true, os = true, lfs = true, package = true, require = true, loadlib = true, dofile = true }
    local mission = {}
    mission._G = mission
    setmetatable(mission, {
      __index = function(_, key)
        if denied[key] then
          return nil
        end
        return _G[key]
      end,
    })
    local modules = {}
    for name, path in pairs(module_paths) do
      modules[name] = load_in_environment(path, mission)
    end
    return mission, modules
  end

  local function start_real_bridge(mission, modules)
    local watchers = {}
    local schedules = {}
    local fake_base = {}
    function fake_base:New()
      local watcher = {}
      function watcher:HandleEvent()
        return self
      end
      function watcher:UnHandleEvent()
        return self
      end
      watchers[#watchers + 1] = watcher
      return watcher
    end
    local fake_scheduler = {}
    function fake_scheduler:New(_, callback)
      local schedule = { callback = callback }
      function schedule:Remove() end
      schedules[#schedules + 1] = schedule
      return schedule, #schedules
    end
    local runtime, bridge_error = modules.bridge.start({
      event_id = modules.event_id,
      envelope = modules.envelope,
      json = modules.json,
      lifecycle = modules.lifecycle,
      bridge_queue = modules.bridge_queue,
      bridge_frame = modules.bridge_frame,
      asset = modules.asset,
      shot = modules.shot,
      combat = modules.combat,
      participant = modules.participant,
      timer = {
        getTime = function()
          return 0
        end,
      },
      env = {
        mission = { theatre = "Caucasus" },
        info = function() end,
        warning = function() end,
        error = function() end,
      },
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
      player_group_names = { "Aerial-1" },
      bandit_group_names = { "Bandit-1" },
      player_coalition = 2,
      bandit_coalition = 1,
      mission_name = "duel-dynamic",
      mission_version = "1",
      source_version = "duel-dynamic-telemetry-v1",
    })
    check(runtime ~= nil, bridge_error)
    check(mission.io == nil and mission.os == nil and mission.lfs == nil, "mission sandbox leaked hook libraries")
    return runtime
  end

  local function truncate_nul(value)
    if type(value) ~= "string" then
      return value
    end
    local position = string.find(value, "\0", 1, true)
    return position and string.sub(value, 1, position - 1) or value
  end

  local function new_system(options)
    options = options or {}
    local fs = options.fs or new_filesystem()
    local messages = {}
    local clock = { now = 0 }
    local topology = {
      round_trips = 0,
      mission_calls = 0,
      boundary_pairs = {},
      cross_state_reads = 0,
    }
    local mission, modules = new_mission_environment()
    local trigger = {}
    trigger._G = trigger
    setmetatable(trigger, { __index = _G })

    trigger.a_do_script = function(source)
      topology.mission_calls = topology.mission_calls + 1
      local chunk, load_error = loadstring(source)
      assert(chunk, load_error)
      setfenv(chunk, mission)
      local function capture(...)
        return { ... }, select("#", ...)
      end
      local values, count = capture(chunk())
      for index = 1, count do
        local before = values[index]
        values[index] = truncate_nul(before)
        if type(before) == "string" then
          topology.boundary_pairs[#topology.boundary_pairs + 1] = { before = before, after = values[index] }
        end
      end
      if mapping == "fixed" then
        return unpack(values, 1, count)
      end
      local shifted = { nil }
      for index = 1, count - 1 do
        shifted[index + 1] = values[index]
      end
      return unpack(shifted, 1, count)
    end

    local fake_net = {}
    function fake_net.dostring_in(target, source)
      topology.round_trips = topology.round_trips + 1
      assert(target == "mission", "unexpected target")
      local chunk, load_error = loadstring(source)
      assert(chunk, load_error)
      setfenv(chunk, trigger)
      local before = chunk()
      local result = truncate_nul(before)
      if type(before) == "string" then
        topology.boundary_pairs[#topology.boundary_pairs + 1] = { before = before, after = result }
      end
      return result, true
    end

    local callbacks = {}
    local exported
    local hook_os = {
      clock = function()
        return clock.now
      end,
      time = function()
        return 1788796800
      end,
      date = function(format)
        check(format == "!%Y%m%dT%H%M%SZ", "unexpected date format")
        return "20260907T000000Z"
      end,
    }
    local hook_env = {}
    hook_env._G = hook_env
    hook_env.io = make_io(fs)
    hook_env.os = hook_os
    hook_env.lfs = {
      writedir = function()
        return "mock-root/"
      end,
      mkdir = function(path)
        return fs:mkdir(path)
      end,
      attributes = function(path, field)
        return fs:attributes(path, field)
      end,
    }
    hook_env.log = {
      INFO = 1,
      write = function(subsystem, _, format, ...)
        messages[#messages + 1] = subsystem .. " " .. string.format(format, ...)
      end,
    }
    hook_env.net = fake_net
    local callback_api = {
      setUserCallbacks = function(value)
        callbacks[#callbacks + 1] = value
      end,
    }
    if options.use_dcs_fallback then
      hook_env.Sim = {
        setUserCallbacks = function()
          error("injected Sim registration failure")
        end,
      }
      hook_env.DCS = callback_api
    else
      hook_env.Sim = callback_api
      hook_env.DCS = nil
    end
    hook_env.TELEMETRY_BRIDGE_HOOK_CONFIG = {
      max_frames = options.max_frames or 32,
      min_frames = 1,
      poll_interval_s = 0.25,
      max_backoff_s = 4,
      test_spool_verify_mutator = function(path)
        if fs.corrupt_verify and string.find(path, ".ndjson", 1, true) then
          fs.files[normalized(path)] = "corrupt"
        end
      end,
      test_export = function(value)
        exported = value
      end,
    }
    setmetatable(hook_env, {
      __index = function(_, key)
        if key == "duel_telemetry_bridge" or key == "duel_telemetry_runtime" then
          topology.cross_state_reads = topology.cross_state_reads + 1
          return nil
        end
        return _G[key]
      end,
    })

    local function load_hook()
      local hook = assert(loadfile("hooks/duel-dynamic-telemetry.lua"))
      setfenv(hook, hook_env)
      hook()
      return callbacks[#callbacks], exported
    end

    local first_callbacks, first_export = load_hook()
    local producer_path = "mock-root/Logs/telemetry-bridge/producer-id"
    local first_producer = fs.files[producer_path]
    local active_callbacks, active_export = load_hook()
    local second_producer = fs.files[producer_path]

    local system = {
      fs = fs,
      messages = messages,
      clock = clock,
      topology = topology,
      mission = mission,
      modules = modules,
      callbacks = active_callbacks,
      export = active_export,
      first_callbacks = first_callbacks,
      first_export = first_export,
      first_producer = first_producer,
      second_producer = second_producer,
      hook_env = hook_env,
      fake_net = fake_net,
      trigger = trigger,
    }

    function system:contains(fragment)
      for _, message in ipairs(self.messages) do
        if string.find(message, fragment, 1, true) then
          return true
        end
      end
      return false
    end

    function system:count(fragment)
      local count = 0
      for _, message in ipairs(self.messages) do
        if string.find(message, fragment, 1, true) then
          count = count + 1
        end
      end
      return count
    end

    function system:advance(seconds, frames)
      frames = frames or 1
      for _ = 1, frames do
        self.clock.now = self.clock.now + seconds
        self.callbacks.onSimulationFrame()
      end
    end

    function system:new_generation(with_bridge)
      self.mission.duel_telemetry_bridge = nil
      self.mission.duel_telemetry_runtime = nil
      self.runtime = nil
      if with_bridge ~= false then
        self.runtime = start_real_bridge(self.mission, self.modules)
      end
      self.callbacks.onMissionLoadBegin()
      self:advance(0.25)
      return self.runtime
    end

    function system:add_line(sequence, payload)
      local state = self.export.state
      local event = {
        schema_version = 1,
        event_id = state.producer_id .. ":" .. state.run_key .. ":" .. tostring(sequence),
        event_sequence = sequence,
        event_type = "participant.entered",
        source = "moose-mission",
        source_version = "duel-dynamic-telemetry-v1",
        producer_id = state.producer_id,
        run_key = state.run_key,
        sim_time = sequence,
        wall_time = self.modules.envelope.JSON_NULL,
        payload = payload,
      }
      check(self.runtime.sink:write(event))
    end

    return system
  end

  succeeds("hook registers and persists a reusable producer", function()
    local system = new_system({ use_dcs_fallback = mapping == "fixed" })
    check(system.callbacks ~= nil, "callbacks not registered")
    check(system.first_producer == system.second_producer, "producer was not reused")
    check(system.export.validate_token(system.second_producer, "producer_id"))
    check(system:contains("LOAD callback-api=" .. (mapping == "fixed" and "DCS" or "Sim")))
  end)

  local happy = new_system()
  succeeds("generation one handshakes through the nested transport", function()
    local runtime = happy:new_generation(true)
    equal(happy.export.state.generation, 1)
    equal(happy.export.state.phase, "draining")
    check(happy.export.validate_token(happy.export.state.run_key, "run_key"))
    equal(runtime:status().state, "active")
    equal(runtime:status().pending_count, 1)
    equal(happy.topology.cross_state_reads, 0)
  end)

  local expected_lines
  local repeated_frame
  succeeds("real mission peek is idempotent before acknowledgement", function()
    happy:add_line(2, { display_name = "SecretPlayerName", callsign = "SecretCallsign" })
    happy:add_line(3, { marker = "third" })
    local first = happy.runtime:peek(1, 32)
    repeated_frame = happy.runtime:peek(1, 32)
    equal(first, repeated_frame)
    local decoded = assert(module_frame.decode(first))
    expected_lines = decoded.lines
    equal(decoded.count, 3)
  end)

  succeeds("full cycle decodes spools and acknowledges three events", function()
    happy:advance(0.25)
    local state = happy.export.state
    equal(state.last_acked_sequence, 3)
    local status = happy.runtime:status()
    equal(status.last_acked_sequence, 3)
    equal(status.pending_count, 0)
    local decoded = assert(happy.export.bridge_frame.decode(repeated_frame))
    equal(decoded.producer_id, state.producer_id)
    equal(decoded.run_key, state.run_key)
    equal(decoded.first_sequence, 1)
    equal(decoded.last_sequence, 3)
    equal(decoded.count, 3)
    equal(happy.fs.files[normalized(state.spool_path)], table.concat(expected_lines, "\n") .. "\n")
  end)

  succeeds("drained marker performs no spool append", function()
    local before = happy.fs.files[normalized(happy.export.state.spool_path)]
    happy:advance(0.25)
    equal(happy.fs.files[normalized(happy.export.state.spool_path)], before)
    equal(happy.export.state.last_acked_sequence, 3)
  end)

  succeeds("privacy keeps event identity fields out of dcs.log", function()
    local log_text = table.concat(happy.messages, "\n")
    local spool = happy.fs.files[normalized(happy.export.state.spool_path)]
    check(not string.find(log_text, "SecretPlayerName", 1, true), "display name leaked to log")
    check(not string.find(log_text, "SecretCallsign", 1, true), "callsign leaked to log")
    check(string.find(spool, "SecretPlayerName", 1, true), "display name missing from ledger")
    check(string.find(spool, "SecretCallsign", 1, true), "callsign missing from ledger")
  end)

  succeeds("all NUL-truncating boundaries preserve NUL-free frames byte-exactly", function()
    local saw_frame = false
    for _, pair in ipairs(happy.topology.boundary_pairs) do
      if string.find(pair.before, "DDBRIDGE1", 1, true) then
        saw_frame = true
        equal(#pair.after, #pair.before)
        equal(pair.after, pair.before)
      end
    end
    check(saw_frame, "no frame crossed the emulated boundary")
  end)

  succeeds("throttle allows exactly one round trip in one interval", function()
    local system = new_system()
    system:new_generation(true)
    system:advance(0.25)
    local before = system.topology.round_trips
    system.clock.now = system.clock.now + 0.25
    for _ = 1, 100 do
      system.callbacks.onSimulationFrame()
    end
    equal(system.topology.round_trips - before, 1)
  end)

  succeeds("frame-too-large halves the requested range and fully drains", function()
    local system = new_system({ max_frames = 2 })
    system:new_generation(true)
    system:add_line(2, { padding = string.rep("x", 65000) })
    system:add_line(3, { marker = "small-after-large" })
    local calls = {}
    local original_peek = system.runtime.peek
    system.runtime.peek = function(runtime, from, maximum)
      calls[#calls + 1] = { from = from, maximum = maximum }
      return original_peek(runtime, from, maximum)
    end
    for _ = 1, 4 do
      system:advance(0.25)
    end
    equal(system.runtime:status().pending_count, 0)
    equal(system.export.state.last_acked_sequence, 3)
    local retried_smaller = false
    for index = 2, #calls do
      if calls[index - 1].from == calls[index].from and calls[index - 1].maximum == 2 and calls[index].maximum == 1 then
        retried_smaller = true
      end
    end
    check(retried_smaller, "oversized range was not retried smaller")
  end)

  succeeds("write failure fails verification without acknowledgement and sticks", function()
    local system = new_system()
    system:new_generation(true)
    system:add_line(2, { marker = "write-failure" })
    system.fs.fail_write = true
    local before_calls = system.topology.round_trips
    system:advance(0.25)
    equal(system.runtime:status().last_acked_sequence, 0)
    equal(system.runtime:status().pending_count, 2)
    check(system.export.state.stuck)
    check(system:contains("spool-verify-failed"))
    system:advance(1, 10)
    equal(system.topology.round_trips, before_calls + 1)
  end)

  succeeds("spool corruption fails exact verification without acknowledgement", function()
    local system = new_system()
    system:new_generation(true)
    system:add_line(2, { marker = "corrupt" })
    system.fs.corrupt_verify = true
    system:advance(0.25)
    equal(system.runtime:status().last_acked_sequence, 0)
    check(system.export.state.stuck)
    check(system:contains("spool-verify-failed"))
  end)

  succeeds("ack failure re-peeks and appends byte-identical duplicates", function()
    local system = new_system()
    system:new_generation(true)
    system:add_line(2, { marker = "retry" })
    local original_ack = system.runtime.ack
    local fail_once = true
    system.runtime.ack = function(runtime, sequence)
      if fail_once then
        fail_once = false
        error("injected mission ack failure")
      end
      return original_ack(runtime, sequence)
    end
    system:advance(0.25)
    equal(system.export.state.last_acked_sequence, 0)
    check(system:contains("ack-failed"))
    local once = system.export.state.spool_content
    system:advance(0.5)
    equal(system.export.state.last_acked_sequence, 2)
    equal(system.export.state.spool_content, once .. once)
    local midpoint = #system.export.state.spool_content / 2
    equal(
      string.sub(system.export.state.spool_content, 1, midpoint),
      string.sub(system.export.state.spool_content, midpoint + 1)
    )
  end)

  succeeds("second mission load gets a fresh isolated run spool", function()
    local system = new_system()
    system:new_generation(true)
    system:add_line(2, { marker = "generation-one" })
    system:advance(0.25)
    local first_run = system.export.state.run_key
    local first_path = normalized(system.export.state.spool_path)
    local first_bytes = system.fs.files[first_path]
    local runtime = system:new_generation(true)
    local second_run = system.export.state.run_key
    check(second_run ~= first_run, "run key was reused")
    equal(runtime:status().run_key, second_run)
    equal(runtime:status().first_pending_sequence, 1)
    system:advance(0.25)
    check(system.fs.files[normalized(system.export.state.spool_path)] ~= nil)
    equal(system.fs.files[first_path], first_bytes)
  end)

  succeeds("missing bridge retries at a bounded cadence without crashing", function()
    local system = new_system()
    system:new_generation(false)
    local after_first = system.topology.round_trips
    system:advance(0.25, 9)
    check(system.topology.round_trips - after_first <= 1, "missing bridge retried too often")
    equal(system.export.state.phase, "idle")
    equal(system:count("bridge-runtime-missing"), 1)
  end)

  succeeds("transport unavailable logs once and never retry-storms", function()
    local system = new_system()
    system.hook_env.net = nil
    system.callbacks.onMissionLoadBegin()
    system:advance(0.25, 20)
    check(system.export.state.stuck)
    equal(system:count("transport-unavailable"), 1)
  end)

  succeeds("stop callback performs one final durable drain", function()
    local system = new_system()
    system:new_generation(true)
    system:advance(0.25)
    equal(system.export.state.last_acked_sequence, 1)
    system:add_line(2, { marker = "stop-event" })
    system.callbacks.onSimulationStop()
    equal(system.runtime:status().last_acked_sequence, 2)
    check(string.find(system.fs.files[normalized(system.export.state.spool_path)], "stop-event", 1, true))
    check(system:contains("STOP generation=1 spooled=2 spool="))
  end)

  succeeds("stop with transport gone is clean and reports unknown loss", function()
    local system = new_system()
    system:new_generation(true)
    system:add_line(2, { marker = "lost-at-stop" })
    system.hook_env.net = nil
    system.callbacks.onSimulationStop()
    equal(system.runtime:status().pending_count, 2)
    check(system:contains("STOP generation=1"))
    check(system:contains("unspooled=unknown"))
  end)

  succeeds("unexpected peek error backs off and the next cycle recovers", function()
    local system = new_system()
    system:new_generation(true)
    system:add_line(2, { marker = "recover" })
    local original_peek = system.runtime.peek
    local fail_once = true
    system.runtime.peek = function(runtime, from, maximum)
      if fail_once then
        fail_once = false
        error("SecretPlayerName must not escape")
      end
      return original_peek(runtime, from, maximum)
    end
    system:advance(0.25)
    equal(system.export.state.last_acked_sequence, 0)
    check(system:contains("hook-error transport"))
    check(not system.export.state.stuck)
    system:advance(0.5)
    equal(system.export.state.last_acked_sequence, 2)
    check(not string.find(table.concat(system.messages, "\n"), "SecretPlayerName", 1, true))
  end)

  local function exact_size_line(size)
    for payload_length = size, 1, -1 do
      local line = string.rep("x", payload_length)
      local header = "DDBRIDGE1|p|r|1|1|1|" .. tostring(payload_length) .. "\n"
      if #header + #tostring(payload_length) + 1 + payload_length == size then
        return line
      end
    end
    error("could not construct exact-size frame")
  end

  succeeds("inlined codec matches module decoding for small frames", function()
    local system = new_system()
    local frame = assert(
      module_frame.encode(
        { producer_id = "producer-1", run_key = "run-1", first_sequence = 1, last_sequence = 2 },
        { "{}", "[]" }
      )
    )
    local expected = assert(module_frame.decode(frame))
    local actual = assert(system.export.bridge_frame.decode(frame))
    equal(actual.producer_id, expected.producer_id)
    equal(actual.run_key, expected.run_key)
    equal(actual.first_sequence, expected.first_sequence)
    equal(actual.last_sequence, expected.last_sequence)
    equal(actual.count, expected.count)
    equal(table.concat(actual.lines), table.concat(expected.lines))
  end)

  succeeds("inlined codec matches module at exactly 65536 bytes", function()
    local system = new_system()
    local frame = assert(
      module_frame.encode(
        { producer_id = "p", run_key = "r", first_sequence = 1, last_sequence = 1 },
        { exact_size_line(65536) }
      )
    )
    equal(#frame, 65536)
    local expected = assert(module_frame.decode(frame))
    local actual = assert(system.export.bridge_frame.decode(frame))
    equal(actual.payload_bytes, expected.payload_bytes)
    equal(actual.lines[1], expected.lines[1])
  end)

  succeeds("inlined codec matches edge tokens and large sequences", function()
    local system = new_system()
    local producer = "A" .. string.rep("a", 124) .. "._-"
    local run = "R" .. string.rep("b", 124) .. "-_."
    local sequence = 9007199254740991
    equal(#producer, 128)
    equal(#run, 128)
    local frame = assert(
      module_frame.encode(
        { producer_id = producer, run_key = run, first_sequence = sequence, last_sequence = sequence },
        { "{}" }
      )
    )
    local expected = assert(module_frame.decode(frame))
    local actual = assert(system.export.bridge_frame.decode(frame))
    equal(actual.producer_id, expected.producer_id)
    equal(actual.run_key, expected.run_key)
    equal(actual.first_sequence, expected.first_sequence)
  end)

  succeeds("inlined codec rejects the same corrupted frame set", function()
    local system = new_system()
    local valid =
      assert(module_frame.encode({ producer_id = "p", run_key = "r", first_sequence = 1, last_sequence = 1 }, { "{}" }))
    local corrupted = {
      "WRONG" .. string.sub(valid, 10),
      string.sub(valid, 1, -2),
      valid .. "x",
      string.gsub(valid, "|2\n", "|3\n", 1),
      valid .. "\0",
    }
    for _, frame in ipairs(corrupted) do
      local module_value = module_frame.decode(frame)
      local hook_value = system.export.bridge_frame.decode(frame)
      equal(hook_value == nil, module_value == nil)
      check(hook_value == nil, "corrupted frame was accepted")
    end
  end)

  succeeds("single returned value is dropped only in shifted mapping", function()
    local system = new_system()
    local function capture(...)
      return { ... }, select("#", ...)
    end
    local values, count = capture(system.trigger.a_do_script([[return "single"]]))
    equal(count, 1)
    equal(values[1], mapping == "fixed" and "single" or nil)
    system:new_generation(true)
    equal(system.export.state.phase, "draining")
  end)

  succeeds("tagged transport accepts both fixed and shifted mapping", function()
    local system = new_system()
    system:new_generation(true)
    check(system:contains("handshake-ok generation=1"))
    equal(system.export.state.phase, "draining")
  end)

  succeeds("hook callback wrapper never raises into the dispatcher", function()
    local system = new_system()
    system:new_generation(true)
    system.export.state.next_poll_at = -1
    system.hook_env.net = setmetatable({}, {
      __index = function()
        error("injected callback error")
      end,
    })
    local ok = pcall(system.callbacks.onSimulationFrame)
    check(ok, "callback raised")
    check(system:contains("hook-error onSimulationFrame"))
    check(not system.export.state.busy, "busy guard was left set")
    system.hook_env.net = system.fake_net
    system:advance(0.25)
    equal(system.export.state.last_acked_sequence, 1)
  end)

  succeeds("logs contain only operational metadata and no decoded payload", function()
    local text = table.concat(happy.messages, "\n")
    check(happy:contains("handshake-ok generation=1 run="))
    check(happy:contains("drained generation=1 from=1..3 count=3"))
    check(not string.find(text, '"event_type"', 1, true), "decoded event payload leaked")
  end)

  if #failures > 0 then
    for _, message in ipairs(failures) do
      total_failures[#total_failures + 1] = mapping .. " " .. message
    end
  end
  host_io.write(
    string.format(
      "telemetry bridge production mock (%s): %d passed, %d failed\n",
      mapping,
      tests_run - #failures,
      #failures
    )
  )
end

run_mapping("shifted")
run_mapping("fixed")

if #total_failures > 0 then
  for _, message in ipairs(total_failures) do
    host_io.stderr:write("FAIL: " .. message .. "\n")
  end
  error(string.format("telemetry bridge production mock failed: %d/%d", #total_failures, total_tests))
end

host_io.write(string.format("telemetry bridge production mock: %d checks passed across both mappings\n", total_tests))

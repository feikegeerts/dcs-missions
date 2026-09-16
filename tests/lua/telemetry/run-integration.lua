local integration = dofile("src/lib/telemetry/integration.lua")
local count = 0
local function test(name, fn)
  local ok, message = pcall(fn)
  assert(ok, name .. ": " .. tostring(message))
  count = count + 1
end

local function fixture(mode, driver)
  local loaded, logs, captured = {}, {}, {}
  local runtime = { asset = {} }
  local options = {
    mode = mode,
    mission_name = "independent-patrol",
    mission_version = "2",
    player_group_names = { "Patrol-Lead" },
    bandit_group_names = {},
    state = {},
    env = {
      warning = function(message)
        logs[#logs + 1] = message
      end,
    },
  }
  local function resolve(name)
    loaded[#loaded + 1] = name
    if name == "development" or name == "bridge" then
      return {
        start = driver or function(config)
          captured.config = config
          return runtime
        end,
      }
    end
    return { name = name }
  end
  return options, resolve, runtime, loaded, logs, captured
end

test("disabled is a silent no-op and never resolves modules", function()
  local options, resolve, _, loaded, logs = fixture("disabled")
  local client = integration.new(options, resolve)
  assert(client:status().state == "disabled")
  assert(client:register_player_group({}) == nil)
  assert(client:register_opposing_group({}, "template") == nil)
  assert(client:despawn_group({}) == nil)
  assert(#loaded == 0 and #logs == 0)
  assert(options.state.duel_telemetry_runtime == nil)
end)

test("development wiring includes combat and file sink with test classification", function()
  local options, resolve, runtime, _, _, captured = fixture("development")
  local client = integration.new(options, resolve)
  assert(client:status().state == "started")
  local config = captured.config
  assert(config.mission_name == "independent-patrol" and config.mission_version == "2")
  assert(config.combat.name == "combat" and config.ndjson_sink.name == "ndjson_sink")
  assert(config.bridge_queue == nil and config.run_classification == "test")
  assert(config.heartbeat_interval == 30)
  assert(options.run_classification == nil, "caller configuration was mutated")
  assert(options.state.duel_telemetry_runtime == runtime)
  assert(options.state.duel_telemetry_bridge == nil)
end)

test("shipping wiring loads only stock-compatible modules and retains hook ABI", function()
  local options, resolve, runtime, loaded, _, captured = fixture("shipping")
  local client = integration.new(options, resolve)
  assert(client:status().state == "started")
  assert(client:status().api_version == 1)
  assert(captured.config.run_classification == "historical")
  assert(captured.config.bridge_queue.name == "bridge_queue")
  for _, name in ipairs(loaded) do
    assert(name ~= "development" and name ~= "ndjson_sink")
  end
  assert(options.state.duel_telemetry_bridge == runtime)
end)

test("conflicting modes start neither driver", function()
  local options, resolve, _, loaded, logs = fixture("conflict")
  local client = integration.new(options, resolve)
  assert(client:status().state == "faulted" and #loaded == 0 and #logs == 1)
end)

test("missing identity faults before module loading", function()
  local options, resolve, _, loaded = fixture("shipping")
  options.mission_name = nil
  assert(integration.new(options, resolve):status().state == "faulted")
  assert(#loaded == 0)
end)

test("loader exceptions are contained and redacted", function()
  local options, _, _, _, logs = fixture("shipping")
  local client = integration.new(options, function()
    error("private participant data")
  end)
  assert(client:status().state == "faulted")
  assert(#logs == 1 and not logs[1]:find("private", 1, true))
  for _ = 1, 20 do
    assert(client:register_player_group({}) == nil)
  end
  assert(#logs == 2, "registration warning was not bounded")
end)

for _, behavior in ipairs({ "throw", "nil", "invalid" }) do
  test("driver " .. behavior .. " is contained", function()
    local options, resolve = fixture("shipping", function()
      if behavior == "throw" then
        error("driver failure")
      elseif behavior == "nil" then
        return nil, "start rejected"
      end
      return true
    end)
    assert(integration.new(options, resolve):status().state == "faulted")
    assert(options.state.duel_telemetry_runtime == nil)
  end)
end

test("registration forwards exact objects and template without gameplay actions", function()
  local options, resolve, runtime = fixture("shipping")
  local group, template, reference = {}, "Enemy-Template", {}
  runtime.asset.register_bandit_group = function(self, actual_group, actual_template)
    assert(self == runtime.asset and actual_group == group and actual_template == template)
    return reference
  end
  runtime.asset.register_player_group = function(self, actual_group)
    assert(self == runtime.asset and actual_group == group)
    return reference
  end
  runtime.asset.despawn_group = function(self, actual_group)
    assert(self == runtime.asset and actual_group == group)
    return true
  end
  local client = integration.new(options, resolve)
  assert(client:register_opposing_group(group, template) == reference)
  assert(client:register_player_group(group) == reference)
  assert(client:despawn_group(group) == true)
end)

test("shipping waiting for handshake can later register through the same client", function()
  local options, resolve, runtime, _, logs = fixture("shipping")
  runtime.asset = nil
  local client = integration.new(options, resolve)
  assert(client:register_player_group({}) == nil)
  runtime.asset = {
    register_player_group = function()
      return "reference"
    end,
  }
  assert(client:register_player_group({}) == "reference")
  assert(#logs == 1)
end)

test("adapter errors, rejection, and logger failure never escape", function()
  local options, resolve, runtime, _, logs = fixture("shipping")
  runtime.asset.register_player_group = function()
    error("private participant data")
  end
  runtime.asset.register_bandit_group = function()
    return nil, "private participant data"
  end
  runtime.asset.despawn_group = function()
    error("cleanup failure")
  end
  local client = integration.new(options, resolve)
  for _ = 1, 20 do
    assert(client:register_player_group({}) == nil)
    assert(client:register_opposing_group({}) == nil)
    assert(client:despawn_group({}) == nil)
  end
  assert(#logs == 3)
  for _, message in ipairs(logs) do
    assert(not message:find("private", 1, true))
  end
  options.env.warning = function()
    error("logger failure")
  end
  runtime.asset = nil
  assert(client:register_player_group({}) == nil)
end)

test("adapter lookup exceptions are contained", function()
  local options, resolve, runtime = fixture("shipping")
  runtime.asset = setmetatable({}, {
    __index = function()
      error("lookup failure")
    end,
  })
  local client = integration.new(options, resolve)
  assert(client:despawn_group({}) == nil)
end)

test("client holds runtime strongly without state aliases", function()
  local options, resolve, runtime = fixture("shipping")
  options.state = nil
  runtime.asset.register_player_group = function()
    return true
  end
  local weak = setmetatable({ runtime }, { __mode = "v" })
  local client = integration.new(options, resolve)
  runtime, resolve = nil, nil
  collectgarbage("collect")
  assert(weak[1] ~= nil)
  assert(client:register_player_group({}) == true)
end)

test("milestones are disabled, unavailable, then recorded through the lifecycle", function()
  local options, resolve, runtime, _, logs, captured = fixture("shipping")
  runtime.controller = {
    record = function(self, input)
      captured.inputs = captured.inputs or {}
      captured.inputs[#captured.inputs + 1] = input
      return { event_type = input.event_type, payload = input.payload }
    end,
  }
  local client = integration.new(options, resolve)
  assert(client:status().state == "started")
  local spawned = client:report_wave_spawned({
    wave_number = 2,
    wave_size = 3,
    donor = "Bandit-4",
    tier = 2,
    reason = "previous package defeated",
    extra = "ignored",
  })
  assert(spawned.event_type == "wave.spawned")
  assert(spawned.payload.wave_number == 2 and spawned.payload.donor == "Bandit-4")
  assert(spawned.payload.extra == nil, "milestone payload leaked unknown keys")
  local cleared = client:report_wave_cleared({ wave_number = 2, wave_size = 3 })
  assert(cleared.event_type == "wave.cleared")
  local over = client:report_gameplay_over({ reason = "all-aircraft-lost" })
  assert(over.event_type == "gameplay.ended")
  assert(#captured.inputs == 3 and #logs == 0)
end)

test("milestones degrade without a controller and never throw", function()
  local options, resolve, runtime, _, logs = fixture("shipping")
  assert(runtime.controller == nil, "fixture unexpectedly provides a controller")
  local client = integration.new(options, resolve)
  for _ = 1, 20 do
    assert(client:report_wave_spawned({ wave_number = 1, wave_size = 1 }) == nil)
    assert(client:report_wave_cleared({ wave_number = 1 }) == nil)
    assert(client:report_gameplay_over({ reason = "all-aircraft-lost" }) == nil)
  end
  assert(#logs == 3, "milestone warnings were not bounded per operation")
end)

test("milestone record failures and logger failure never escape", function()
  local options, resolve, runtime, _, logs = fixture("shipping")
  runtime.controller = {
    record = function()
      return nil, "lifecycle closed"
    end,
  }
  local client = integration.new(options, resolve)
  assert(client:report_wave_spawned({ wave_number = 1, wave_size = 1 }) == nil)
  runtime.controller.record = function()
    error("private participant data")
  end
  assert(client:report_wave_cleared({ wave_number = 1 }) == nil)
  for _, message in ipairs(logs) do
    assert(not message:find("private", 1, true))
  end
  options.env.warning = function()
    error("logger failure")
  end
    assert(client:report_gameplay_over({ reason = "all-aircraft-lost" }) == nil)
end)

test("milestones are silent no-ops while disabled", function()
  local options, resolve, _, loaded, logs = fixture("disabled")
  local client = integration.new(options, resolve)
  assert(client:report_wave_spawned({ wave_number = 1, wave_size = 1 }) == nil)
  assert(client:report_wave_cleared({ wave_number = 1 }) == nil)
    assert(client:report_gameplay_over({ reason = "all-aircraft-lost" }) == nil)
  assert(#loaded == 0 and #logs == 0)
end)

test("capabilities pass through to the driver without mutating the caller", function()
  local options, resolve, _, _, _, captured = fixture("shipping")
  local declared = { wave_milestones = 1, gameplay_outcome = 1 }
  options.capabilities = declared
  local client = integration.new(options, resolve)
  assert(client:status().state == "started")
  assert(captured.config.capabilities.wave_milestones == 1)
  assert(captured.config.capabilities.gameplay_outcome == 1)
  assert(captured.config.capabilities ~= declared, "capabilities table was aliased")
end)

test("invalid capabilities fault initialization and keep gameplay safe", function()
  local options, resolve, _, loaded = fixture("shipping")
  options.capabilities = { wave_milestones = 2 }
  assert(integration.new(options, resolve):status().state == "faulted")
  assert(#loaded == 0, "modules loaded before capabilities validation")
  options.capabilities = { unknown_future_flag = 1 }
  assert(integration.new(options, resolve):status().state == "faulted")
end)

print("telemetry integration tests: " .. count .. " passed")

local messages = {}
local callback_sets = {}
local return_mapping = os.getenv("TELEMETRY_DISCOVERY_MOCK_MAPPING") or "shifted"
assert(return_mapping == "shifted" or return_mapping == "fixed", "unsupported mock return mapping")

log = {
  INFO = 1,
  write = function(subsystem, _, message, ...)
    messages[#messages + 1] = subsystem .. " " .. string.format(message, ...)
  end,
}

Sim = {
  getMissionName = function()
    return "test-flight"
  end,
  isMultiplayer = function()
    return true
  end,
  isServer = function()
    return true
  end,
  setUserCallbacks = function(callbacks)
    callback_sets[#callback_sets + 1] = callbacks
  end,
}

local denied_mission_globals = {
  io = true,
  lfs = true,
  loadlib = true,
  os = true,
  package = true,
  require = true,
}
local mission_environment = {}
mission_environment._G = mission_environment
setmetatable(mission_environment, {
  __index = function(_, key)
    if denied_mission_globals[key] then
      return nil
    end
    return _G[key]
  end,
})

local trigger_environment = {}
trigger_environment._G = trigger_environment
setmetatable(trigger_environment, { __index = _G })
-- Observed on DCS 2.9.29.27278: the return pass-through behaves like a
-- C-style string copy and truncates each returned string at the first NUL.
local function nul_truncate(value)
  if type(value) ~= "string" then
    return value
  end
  return string.match(value, "^[^%z]*") or ""
end

trigger_environment.a_do_script = function(source)
  local chunk, load_error = loadstring(source)
  assert(chunk, load_error)
  setfenv(chunk, mission_environment)
  local first, second, third = chunk()
  first, second, third = nul_truncate(first), nul_truncate(second), nul_truncate(third)
  if return_mapping == "fixed" then
    return first, second, third
  end
  return nil, first, second
end

net = {
  dostring_in = function(state, source)
    assert(state == "mission", "unexpected target state")
    local chunk, load_error = loadstring(source)
    assert(chunk, load_error)
    setfenv(chunk, trigger_environment)
    return chunk(), true
  end,
}

local function contains(fragment)
  for _, message in ipairs(messages) do
    if string.find(message, fragment, 1, true) then
      return true
    end
  end
  return false
end

local function assert_contains(fragment)
  if not contains(fragment) then
    io.stderr:write(table.concat(messages, "\n") .. "\n")
  end
  assert(contains(fragment), "missing discovery evidence: " .. fragment)
end

dofile("tests/dcs/telemetry-bridge-api-discovery.lua")
assert(#callback_sets == 1, "discovery hook did not register callbacks")

callback_sets[1].onSimulationStart()
callback_sets[1].onSimulationFrame()
callback_sets[1].onSimulationStop()

assert_contains("LOAD PASS callback_api=Sim")
assert_contains("LIFECYCLE onSimulationStart mission=test-flight")
assert_contains("CHECK multiplayer_server_mode PASS")
assert_contains("CHECK nested_a_do_script_available PASS")
assert_contains("CHECK return_mapping_known PASS")
assert_contains("OBSERVE return_mapping=" .. return_mapping)
assert_contains("CHECK stock_mission_sandbox PASS")
assert_contains("CHECK nul_truncation_characterized PASS")
assert_contains("CHECK framed_binary_truncates_at_first_nul PASS")
assert_contains("CHECK framed_65536_nul_free_round_trip PASS")
assert_contains("RESULT failures=0")
assert(not contains(" FAIL "), "discovery mock produced a failed check")

io.write("telemetry bridge API discovery mock: passed\n")

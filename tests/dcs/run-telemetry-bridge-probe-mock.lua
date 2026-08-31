local messages = {}
local registered_callback_sets = {}
local real_time = 0
local return_mapping = os.getenv("TELEMETRY_PROBE_MOCK_MAPPING") or "shifted"
local corrupt_spool = os.getenv("TELEMETRY_PROBE_MOCK_CORRUPT_SPOOL") == "1"
assert(return_mapping == "shifted" or return_mapping == "fixed", "unsupported mock return mapping")
local player = {
  id = 1,
  name = "Redacted Test Host",
  side = 0,
  slot = "",
  ping = 0,
  ipaddr = "127.0.0.1",
  ucid = "mock-stable-ucid-not-logged",
}
local remote_player = {
  id = 2,
  name = "Redacted Remote Pilot",
  side = 0,
  slot = "",
  ping = 10,
  ipaddr = "192.0.2.1",
  ucid = "mock-remote-stable-ucid-not-logged",
}

log = {
  INFO = 1,
  write = function(subsystem, _, message, ...)
    messages[#messages + 1] = subsystem .. " " .. string.format(message, ...)
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

-- Emulates the DCS trigger state: full standard libraries plus a_do_script,
-- which evaluates code in the mission scripting state. The return pass-through
-- applies the ED shift defect (nil prepended, last value dropped) for
-- multi-value returns; single-value returns pass through unchanged, matching
-- the discovery observations on DCS 2.9.29.27278.
local trigger_environment = {}
trigger_environment._G = trigger_environment
setmetatable(trigger_environment, { __index = _G })

trigger_environment.a_do_script = function(code)
  local chunk, load_error = loadstring(code)
  assert(chunk, load_error)
  setfenv(chunk, mission_environment)
  local function capture(...)
    local captured = { ... }
    return captured, select("#", ...)
  end
  local values, count = capture(chunk())
  if count == 0 then
    return nil
  end
  if return_mapping == "fixed" then
    return unpack(values, 1, count)
  end
  -- shifted: the ED bug prepends nil and drops the last value, so the output
  -- count equals the input count. For a single value this leaves only nil,
  -- which is exactly why the probe's inner chunk returns a dummy second value.
  local shifted = { nil }
  for index = 1, count - 1 do
    shifted[index + 1] = values[index]
  end
  return unpack(shifted, 1, count)
end

net = {
  get_player_list = function()
    return { 1, 2 }
  end,
  get_player_info = function(player_id)
    if player_id == player.id then
      return player
    elseif player_id == remote_player.id then
      return remote_player
    end
    return nil
  end,
  dostring_in = function(state, source)
    assert(state == "mission", "unexpected dostring_in target state")
    local chunk, load_error = loadstring(source)
    assert(chunk, load_error)
    setfenv(chunk, trigger_environment)
    local result = chunk()
    -- The return boundary truncates strings at the first NUL byte, as proven
    -- in discovery.
    if type(result) == "string" then
      local nul = string.find(result, "\0", 1, true)
      if nul then
        result = string.sub(result, 1, nul - 1)
      end
    end
    return result, true
  end,
}

DCS = {
  getMissionName = function()
    return "telemetry-bridge-mock"
  end,
  getRealTime = function()
    real_time = real_time + 0.25
    return real_time
  end,
  isMultiplayer = function()
    return true
  end,
  isServer = function()
    return true
  end,
  setUserCallbacks = function(callbacks)
    registered_callback_sets[#registered_callback_sets + 1] = callbacks
  end,
}

lfs = {
  writedir = function()
    return "unused-by-mock/"
  end,
}
TELEMETRY_BRIDGE_PROBE_SPOOL_DIRECTORY = string.gsub(assert(os.getenv("TEMP")), "\\", "/") .. "/"
if corrupt_spool then
  TELEMETRY_BRIDGE_PROBE_SPOOL_VERIFY_MUTATOR = function(path)
    local file = assert(io.open(path, "wb"))
    assert(file:write("corrupt"))
    assert(file:close())
  end
end

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
  assert(contains(fragment), "missing probe evidence: " .. fragment)
end

local function count_contains(fragment)
  local count = 0
  for _, message in ipairs(messages) do
    if string.find(message, fragment, 1, true) then
      count = count + 1
    end
  end
  return count
end

local function contains_all(first, second)
  for _, message in ipairs(messages) do
    if string.find(message, first, 1, true) and string.find(message, second, 1, true) then
      return true
    end
  end
  return false
end

local baseline_frames = 0
DCS.setUserCallbacks({
  onSimulationFrame = function()
    baseline_frames = baseline_frames + 1
  end,
})

dofile("tests/dcs/telemetry-bridge-companion.lua")
dofile("tests/dcs/telemetry-bridge-probe.lua")
assert(#registered_callback_sets == 3, "probe and its companion did not register callbacks")

local competing_try_connect_called = false
DCS.setUserCallbacks({
  onPlayerTryConnect = function()
    competing_try_connect_called = true
    return nil
  end,
})

local function dispatch(name, ...)
  for _, callbacks in ipairs(registered_callback_sets) do
    local callback = callbacks[name]
    if callback then
      local result = callback(...)
      if result ~= nil then
        return result
      end
    end
  end
  return nil
end

local remote_connected = false

local function run_generation(with_slot_change)
  dispatch("onMissionLoadBegin")
  dispatch("onMissionLoadEnd")
  dispatch("onSimulationStart")
  if not remote_connected then
    dispatch("onPlayerTryConnect", "192.0.2.1", remote_player.name, remote_player.ucid, remote_player.id)
    dispatch("onPlayerConnect", remote_player.id)
    remote_connected = true
  end
  for _ = 1, 20 do
    dispatch("onSimulationFrame")
  end

  if with_slot_change then
    remote_player.side = 2
    remote_player.slot = "101_1"
    dispatch("onPlayerChangeSlot", remote_player.id)
    for _ = 1, 10 do
      dispatch("onSimulationFrame")
    end
  end
  dispatch("onSimulationStop")
end

run_generation(false)
if not corrupt_spool then
  run_generation(true)
end

assert_contains("LOAD PASS")
assert_contains("CHECK multiplayer_server_mode PASS")
assert_contains("CHECK returns_and_stock_sandbox PASS")
assert_contains("CHECK binary_nul_truncation PASS")
assert_contains("CHECK frame_65536 PASS")
assert_contains("CHECK run_key_fresh PASS")
assert_contains("ucid_fingerprint=")
assert_contains("matches_connect=true")
assert_contains("LIFECYCLE onSimulationStop")
if corrupt_spool then
  assert_contains("CHECK queue_spool_first_batch FAIL")
  assert_contains("verification mismatch")
  assert_contains("RESULT generation=1 failures=1")
  assert_contains("STOP_RESULT generation=1 failures=1")
  assert(not contains("CHECK queue_acknowledge"), "acknowledgement ran after failed spool verification")
  assert(not contains("CHECK queue_remainder_peek"), "probe continued after failed spool verification")
  assert(count_contains(" RESULT generation=") == 1, "expected exactly one failed generation result")
else
  assert_contains("CHECK queue_spool_first_batch PASS")
  assert_contains("CHECK queue_repeat_before_ack PASS")
  assert_contains("CHECK queue_acknowledge PASS")
  assert_contains("beyond_spool_accepted=false")
  assert_contains("CHECK queue_remainder_peek PASS")
  assert_contains("CHECK queue_spool_remainder PASS")
  assert_contains("CHECK queue_acknowledge_remainder PASS")
  assert_contains("CHECK queue_empty_after_ack PASS")
  assert_contains("RESULT generation=1 failures=0")
  assert_contains("STOP_RESULT generation=1 failures=0")
  assert_contains("RESULT generation=2 failures=0")
  assert_contains("STOP_RESULT generation=2 failures=0")
  assert(
    contains_all("PLAYER source=change_slot side=2 slot_present=true", "matches_connect=true"),
    "remote identity correlation was not retained across mission restart"
  )
  assert(count_contains(" RESULT generation=") == 2, "expected exactly two generation results")
  assert(count_contains(" STOP_RESULT generation=") == 2, "expected exactly two stop results")
  assert(
    count_contains("TELEMETRY_BRIDGE_COMPANION FRAME PASS generation=") == 2,
    "controlled companion did not receive frames in both generations"
  )
  assert(not contains(" FAIL "), "probe mock produced a failed check")
end
assert(not contains(" id="), "probe logged a raw DCS player ID")
assert(not contains(player.name), "probe logged a player name")
assert(not contains(remote_player.name), "probe logged a player name")
assert(not contains(player.ipaddr), "probe logged an address")
assert(not contains(remote_player.ipaddr), "probe logged an address")
assert(not contains(player.ucid), "probe logged a raw UCID")
assert(not contains(remote_player.ucid), "probe logged a raw UCID")
assert(baseline_frames > 0, "competing frame callback did not continue")
assert(competing_try_connect_called, "probe stopped the try-connect callback chain")

io.write("telemetry bridge probe mock: passed\n")

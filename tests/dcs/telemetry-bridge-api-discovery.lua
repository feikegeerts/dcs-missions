-- Disposable GameGUI hook that characterizes the real mission-evaluation API.

local SUBSYSTEM = "TELEMETRY_BRIDGE_DISCOVERY"
local callbacks = {}
local callback_api = nil
local active = false
local completed = false
local failures = 0

local function write(message, ...)
  log.write(SUBSYSTEM, log.INFO, message, ...)
end

local function check(label, passed, detail)
  if not passed then
    failures = failures + 1
  end
  write("CHECK %s %s %s", label, passed and "PASS" or "FAIL", detail or "")
end

local function exact_bytes(value, expected)
  if type(value) ~= "string" or string.len(value) ~= #expected then
    return false
  end
  for index = 1, #expected do
    if string.byte(value, index) ~= expected[index] then
      return false
    end
  end
  return true
end

local function exact_string(value, expected)
  if type(value) ~= "string" then
    return false
  end
  local length = string.len(expected)
  if string.len(value) ~= length then
    return false
  end
  for index = 1, length do
    if string.byte(value, index) ~= string.byte(expected, index) then
      return false
    end
  end
  return true
end

local function validate_frame(value, special_bytes)
  if type(value) ~= "string" or string.len(value) ~= 65536 then
    return false, "total length is not 65536"
  end
  local newline = string.find(value, "\n", 1, true)
  if not newline then
    return false, "header newline is missing"
  end
  local payload_length = tonumber(string.match(string.sub(value, 1, newline - 1), "^TLM1|discovery|run|1|1|1|(%d+)$"))
  if not payload_length then
    return false, "header is malformed"
  end
  local payload = string.sub(value, newline + 1)
  if string.len(payload) ~= payload_length then
    return false, "declared payload length disagrees"
  end
  local prefix_length = #special_bytes
  if not exact_bytes(string.sub(payload, 1, prefix_length), special_bytes) then
    return false, "special-byte prefix changed"
  end
  if string.find(string.sub(payload, prefix_length + 1), "[^x]") then
    return false, "payload fill changed"
  end
  return true
end

local function expected_frame_header()
  local target = 65536
  local payload_length = target
  local header
  repeat
    header = "TLM1|discovery|run|1|1|1|" .. payload_length .. "\n"
    local next_length = target - string.len(header)
    if next_length == payload_length then
      break
    end
    payload_length = next_length
  until payload_length < 0
  return header
end

local function dostring_in_mission(source)
  if type(net) ~= "table" or type(net.dostring_in) ~= "function" then
    return nil, false, "net.dostring_in unavailable"
  end
  local call_ok, result, success = pcall(net.dostring_in, "mission", source)
  if not call_ok then
    return nil, false, tostring(result)
  end
  return result, success == true, nil
end

local function run_discovery()
  if completed then
    return
  end
  completed = true

  write(
    "API global=%s Sim=%s DCS=%s net=%s net_dostring_in=%s",
    type(a_do_script),
    type(Sim) == "table" and type(Sim.a_do_script) or "no-table",
    type(DCS) == "table" and type(DCS.a_do_script) or "no-table",
    type(net) == "table" and type(net.a_do_script) or "no-table",
    type(net) == "table" and type(net.dostring_in) or "no-table"
  )

  local nested_type, type_success, type_error = dostring_in_mission([[return type(a_do_script)]])
  check(
    "nested_a_do_script_available",
    type_success and nested_type == "function",
    "success=" .. tostring(type_success) .. " result=" .. tostring(nested_type) .. " error=" .. tostring(type_error)
  )
  if not type_success or nested_type ~= "function" then
    write("RESULT failures=%d", failures)
    active = false
    return
  end

  local mapping, mapping_success, mapping_error = dostring_in_mission([=[
local a, b, c, d = a_do_script([[return "FIRST", "SECOND", "THIRD"]])
local function describe(value)
  return type(value) .. ":" .. tostring(value)
end
return table.concat({ describe(a), describe(b), describe(c), describe(d) }, "|")
]=])
  local fixed_mapping = "string:FIRST|string:SECOND|string:THIRD|nil:nil"
  local shifted_mapping = "nil:nil|string:FIRST|string:SECOND|nil:nil"
  check(
    "return_mapping_known",
    mapping_success and (mapping == fixed_mapping or mapping == shifted_mapping),
    "success=" .. tostring(mapping_success) .. " mapping=" .. tostring(mapping) .. " error=" .. tostring(mapping_error)
  )
  write(
    "OBSERVE return_mapping=%s",
    mapping == fixed_mapping and "fixed" or mapping == shifted_mapping and "shifted" or "unknown"
  )

  local sandbox, sandbox_success, sandbox_error = dostring_in_mission([=[
local a, b, c = a_do_script([==[
local value = table.concat({ type(os), type(io), type(lfs), type(require), type(package), type(loadlib) }, ",")
return value, "TLM_SENTINEL_1", "TLM_SENTINEL_2"
]==])
if b == "TLM_SENTINEL_1" and c == "TLM_SENTINEL_2" then return a end
if c == "TLM_SENTINEL_1" then return b end
return "UNSUPPORTED_MAPPING"
]=])
  check(
    "stock_mission_sandbox",
    sandbox_success and sandbox == "nil,nil,nil,nil,nil,nil",
    "success=" .. tostring(sandbox_success) .. " result=" .. tostring(sandbox) .. " error=" .. tostring(sandbox_error)
  )

  -- Round 1 on DCS 2.9.29.27278 showed the return pass-through behaves like a
  -- C-style string copy: the result is truncated at the first NUL byte. This
  -- check pins that characterization exactly (only "A" survives "A\0...").
  local binary, binary_success, binary_error = dostring_in_mission([=[
 local a, b, c = a_do_script([==[
 local value = "A" .. string.char(0, 10, 13, 124, 92, 34) .. "Z"
 return value, "TLM_SENTINEL_1", "TLM_SENTINEL_2"
 ]==])
 if b == "TLM_SENTINEL_1" and c == "TLM_SENTINEL_2" then return a end
 if c == "TLM_SENTINEL_1" then return b end
 return "UNSUPPORTED_MAPPING"
 ]=])
  check(
    "nul_truncation_characterized",
    binary_success and exact_bytes(binary, { 65 }),
    "success="
      .. tostring(binary_success)
      .. " bytes="
      .. tostring(type(binary) == "string" and string.len(binary) or -1)
      .. " error="
      .. tostring(binary_error)
  )

  local framed, framed_success, framed_error = dostring_in_mission([=[
 local a, b, c = a_do_script([==[
 local target = 65536
 local payload_length = target
 local header
 repeat
   header = "TLM1|discovery|run|1|1|1|" .. payload_length .. "\n"
   local next_length = target - string.len(header)
   if next_length == payload_length then break end
   payload_length = next_length
 until payload_length < 0
 local value = header .. "A" .. string.char(0, 10, 13, 124, 92, 34) .. "Z"
   .. string.rep("x", payload_length - 8)
 return value, "TLM_SENTINEL_1", "TLM_SENTINEL_2"
 ]==])
 if b == "TLM_SENTINEL_1" and c == "TLM_SENTINEL_2" then return a end
 if c == "TLM_SENTINEL_1" then return b end
 return "UNSUPPORTED_MAPPING"
 ]=])
  local expected_truncated = expected_frame_header() .. "A"
  check(
    "framed_binary_truncates_at_first_nul",
    framed_success and exact_string(framed, expected_truncated),
    "success="
      .. tostring(framed_success)
      .. " bytes="
      .. tostring(type(framed) == "string" and string.len(framed) or -1)
      .. " expected="
      .. string.len(expected_truncated)
      .. " error="
      .. tostring(framed_error)
  )

  -- Production frames are NUL-free by construction (text header + JSON).
  -- This check proves a NUL-free 64 KiB frame survives the full round trip.
  local text_special_bytes = { 65, 10, 13, 124, 92, 34, 90 }
  local framed_text, framed_text_success, framed_text_error = dostring_in_mission([=[
 local a, b, c = a_do_script([==[
 local target = 65536
 local payload_length = target
 local header
 repeat
   header = "TLM1|discovery|run|1|1|1|" .. payload_length .. "\n"
   local next_length = target - string.len(header)
   if next_length == payload_length then break end
   payload_length = next_length
 until payload_length < 0
 local value = header .. "A" .. string.char(10, 13, 124, 92, 34) .. "Z"
   .. string.rep("x", payload_length - 7)
 return value, "TLM_SENTINEL_1", "TLM_SENTINEL_2"
 ]==])
 if b == "TLM_SENTINEL_1" and c == "TLM_SENTINEL_2" then return a end
 if c == "TLM_SENTINEL_1" then return b end
 return "UNSUPPORTED_MAPPING"
 ]=])
  local text_frame_valid, text_frame_validation_error = validate_frame(framed_text, text_special_bytes)
  check(
    "framed_65536_nul_free_round_trip",
    framed_text_success and text_frame_valid,
    "success="
      .. tostring(framed_text_success)
      .. " bytes="
      .. tostring(type(framed_text) == "string" and string.len(framed_text) or -1)
      .. " error="
      .. tostring(framed_text_error)
      .. " validation_error="
      .. tostring(text_frame_validation_error)
  )

  write("RESULT failures=%d", failures)
  active = false
end

function callbacks.onSimulationStart()
  active = true
  completed = false
  failures = 0
  local multiplayer = callback_api.isMultiplayer()
  local server = callback_api.isServer()
  local mission_name = type(callback_api.getMissionName) == "function" and callback_api.getMissionName()
    or "unavailable"
  write(
    "LIFECYCLE onSimulationStart mission=%s multiplayer=%s server=%s",
    tostring(mission_name),
    tostring(multiplayer),
    tostring(server)
  )
  check(
    "multiplayer_server_mode",
    multiplayer == true and server == true,
    "multiplayer=" .. tostring(multiplayer) .. " server=" .. tostring(server)
  )
end

function callbacks.onSimulationFrame()
  if active then
    local ok, discovery_error = pcall(run_discovery)
    if not ok then
      check("discovery_callback", false, tostring(discovery_error))
      write("RESULT failures=%d", failures)
      active = false
      completed = true
    end
  end
end

function callbacks.onSimulationStop()
  write("LIFECYCLE onSimulationStop completed=%s failures=%d", tostring(completed), failures)
  active = false
end

local function complete_api(api)
  return type(api) == "table"
    and type(api.setUserCallbacks) == "function"
    and type(api.isMultiplayer) == "function"
    and type(api.isServer) == "function"
end

local api_name = nil
if complete_api(Sim) then
  callback_api = Sim
  api_name = "Sim"
elseif complete_api(DCS) then
  callback_api = DCS
  api_name = "DCS"
end

if callback_api then
  callback_api.setUserCallbacks(callbacks)
  write("LOAD PASS callback_api=%s", api_name)
else
  write("LOAD FAIL complete callback API unavailable")
end

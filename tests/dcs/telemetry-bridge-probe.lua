-- Disposable Slice 3 GameGUI hook probe (nested transport).
-- This is not the production bridge.
--
-- Mission code is evaluated through net.dostring_in("mission", wrapper), where
-- the wrapper invokes the mission scripting state's a_do_script. Discovery on
-- DCS 2.9.29.27278 proved this route works under stock sanitization, that the
-- return pass-through is shifted (nil prepended, last value dropped) for
-- multi-value returns, and that returned strings truncate at the first NUL
-- byte. Therefore every mission evaluation serializes all return values into
-- one NUL-free tagged string before crossing the state boundary:
--   "0"            -> nil
--   "1<len>:<num>" -> number
--   "2<len>:<boo>" -> boolean
--   "3<len>:<str>" -> string
--   "4<len>:<typ>" -> unsupported type (type name recorded)

local SUBSYSTEM = "TELEMETRY_BRIDGE_PROBE"
local sizes = {
  { bytes = 1024, required = true },
  { bytes = 65536, required = true },
}
local STAGE_QUEUE_INITIALIZE = 3 + #sizes
local STAGE_QUEUE_PEEK = STAGE_QUEUE_INITIALIZE + 1
local STAGE_QUEUE_REPEAT = STAGE_QUEUE_INITIALIZE + 2
local STAGE_QUEUE_ACKNOWLEDGE = STAGE_QUEUE_INITIALIZE + 3
local STAGE_QUEUE_REMAINDER = STAGE_QUEUE_INITIALIZE + 4
local STAGE_QUEUE_ACKNOWLEDGE_REMAINDER = STAGE_QUEUE_INITIALIZE + 5
local STAGE_QUEUE_EMPTY = STAGE_QUEUE_INITIALIZE + 6
local callbacks = {}
local callback_api = nil
local active = false
local stage = 0
local failures = 0
local lifecycle_stage = 0
local expected_queue_bytes = nil
local expected_queue_frame = nil
local expected_remainder_frame = nil
local current_run_key = nil
local spooled_through = 0
local spool_content = ""
local spool_path = nil
local generation = 0
local hook_nonce = tostring(os.time()) .. "-" .. tostring(math.floor(os.clock() * 1000000))
local connection_ucid_fingerprints = {}
local last_player_snapshot = -math.huge
local PLAYER_SNAPSHOT_INTERVAL = 2

-- NUL-free special bytes: newline, CR, pipe, backslash, quote. NUL is
-- deliberately excluded because the return pass-through truncates at it.
local SPECIAL_BYTES = { 65, 10, 13, 124, 92, 34, 90 }

local function write(message, ...)
  log.write(SUBSYSTEM, log.INFO, message, ...)
end

local function check(label, passed, detail)
  if not passed then
    failures = failures + 1
  end
  write("CHECK %s %s %s", label, passed and "PASS" or "FAIL", detail or "")
end

local function fingerprint(value)
  if type(value) ~= "string" or string.len(value) == 0 then
    return "none"
  end

  local hash = 0
  for index = 1, string.len(value) do
    hash = (hash * 131 + string.byte(value, index)) % 2147483647
  end
  return string.format("%08x", hash)
end

local function deserialize_values(serialized)
  if type(serialized) ~= "string" then
    return nil, 0, "transport result is not a string: " .. type(serialized)
  end

  local values = {}
  local count = 0
  local cursor = 1
  local total = string.len(serialized)
  while cursor <= total do
    local tag = string.sub(serialized, cursor, cursor)
    if tag == "0" then
      cursor = cursor + 1
      count = count + 1
      values[count] = nil
    else
      local colon = string.find(serialized, ":", cursor, true)
      if not colon then
        return nil, 0, "malformed segment at byte " .. tostring(cursor)
      end
      local length = tonumber(string.sub(serialized, cursor + 1, colon - 1))
      if not length or length < 0 or length > total then
        return nil, 0, "bad segment length at byte " .. tostring(cursor)
      end
      local data = string.sub(serialized, colon + 1, colon + length)
      if string.len(data) ~= length then
        return nil, 0, "segment data truncated at byte " .. tostring(cursor)
      end
      count = count + 1
      if tag == "1" then
        values[count] = tonumber(data)
      elseif tag == "2" then
        values[count] = data == "true"
      elseif tag == "3" then
        values[count] = data
      else
        return nil, 0, "unknown tag " .. tag .. " at byte " .. tostring(cursor)
      end
      cursor = colon + length + 1
    end
  end
  return values, count, nil
end

local function mission_eval(source)
  if type(net) ~= "table" or type(net.dostring_in) ~= "function" then
    return nil, 0, "net.dostring_in unavailable", nil
  end

  -- Build the inner chunk (runs in the mission state) by plain concatenation
  -- so the source is embedded raw as a function body. Avoiding long-string
  -- nesting sidesteps Lua 5.1's "nesting of [[...]] is deprecated" rejection.
  -- The source's return values are captured and serialized into a single
  -- NUL-free tagged string before crossing the state boundary. A dummy second
  -- value is returned because the ED return-shift bug drops a single return
  -- value entirely (1 -> nil); with two values the real string lands at
  -- position 2 under the shift (or position 1 if the bug is fixed), and the
  -- wrapper below checks both positions.
  local inner_code = "local function capture(...)\n"
    .. "  local captured = { ... }\n"
    .. "  return captured, select('#', ...)\n"
    .. "end\n"
    .. "local function source_block()\n"
    .. source
    .. "\nend\n"
    .. "local results, count = capture(source_block())\n"
    .. "local parts = {}\n"
    .. "for index = 1, count do\n"
    .. "  local value = results[index]\n"
    .. '  if value == nil then\n    parts[#parts + 1] = "0"\n'
    .. "  elseif type(value) == 'number' then\n"
    .. '    local text = tostring(value)\n    parts[#parts + 1] = "1" .. #text .. ":" .. text\n'
    .. "  elseif type(value) == 'boolean' then\n"
    .. '    local text = tostring(value)\n    parts[#parts + 1] = "2" .. #text .. ":" .. text\n'
    .. "  elseif type(value) == 'string' then\n"
    .. '    parts[#parts + 1] = "3" .. #value .. ":" .. value\n'
    .. "  else\n"
    .. '    local text = type(value)\n    parts[#parts + 1] = "4" .. #text .. ":" .. text\n'
    .. "  end\n"
    .. "end\n"
    .. 'return table.concat(parts), "TLM_BRIDGE_PROBE_OK"'

  -- Embed the inner chunk as a %q double-quoted literal (never a long string),
  -- so the wrapper carries no long-string nesting either.
  local inner_literal = string.format("%q", inner_code)
  local wrapper = "local values = { a_do_script("
    .. inner_literal
    .. ") }\n"
    .. "if type(values[1]) == 'string' then return values[1] end\n"
    .. "if type(values[2]) == 'string' then return values[2] end\n"
    .. "return 'TLM_TRANSPORT_FAIL|' .. tostring(values[1]) .. '|' .. tostring(values[2])"

  local call_ok, result = pcall(net.dostring_in, "mission", wrapper)
  if not call_ok then
    return nil, 0, "dostring_in error: " .. tostring(result), nil
  end
  if type(result) == "string" and string.sub(result, 1, 19) == "TLM_TRANSPORT_FAIL|" then
    return nil, 0, "transport returned no values: " .. string.sub(result, 20), result
  end
  local values, value_count, parse_error = deserialize_values(result)
  if not values then
    return nil, 0, "deserialize failed: " .. tostring(parse_error), result
  end
  return values, value_count, nil, result
end

local function cleanup_spool()
  if spool_path then
    pcall(os.remove, spool_path)
    spool_path = nil
  end
  spool_content = ""
end

local function spool_frame(mode, frame, through_sequence)
  if type(io) ~= "table" or type(io.open) ~= "function" or not spool_path then
    return false, "hook spool API unavailable"
  end
  local file, open_error = io.open(spool_path, mode)
  if not file then
    return false, tostring(open_error)
  end

  local expected
  if mode == "wb" then
    expected = frame
  elseif mode == "ab" then
    expected = spool_content .. frame
  else
    pcall(file.close, file)
    return false, "unsupported spool mode"
  end

  local write_ok, write_result = pcall(file.write, file, frame)
  if not write_ok then
    pcall(file.close, file)
    return false, "write raised: " .. tostring(write_result)
  end
  local flush_ok, flush_result = pcall(file.flush, file)
  if not flush_ok then
    pcall(file.close, file)
    return false, "flush raised: " .. tostring(flush_result)
  end
  local close_ok, close_result = pcall(file.close, file)
  if not close_ok then
    return false, "close raised: " .. tostring(close_result)
  end

  local verification_mutator = rawget(_G, "TELEMETRY_BRIDGE_PROBE_SPOOL_VERIFY_MUTATOR")
  if type(verification_mutator) == "function" then
    local mutate_ok, mutate_error = pcall(verification_mutator, spool_path, mode)
    if not mutate_ok then
      return false, "verification mutator raised: " .. tostring(mutate_error)
    end
  end

  -- DCS's hook file methods can return nil even after a successful operation.
  -- Do not treat return truthiness as durability evidence. Reopen the closed
  -- spool and compare every byte before allowing acknowledgement.
  local verification, verify_open_error = io.open(spool_path, "rb")
  if not verification then
    return false, "verification open failed: " .. tostring(verify_open_error)
  end
  local read_ok, persisted = pcall(verification.read, verification, "*a")
  local verify_close_ok, verify_close_error = pcall(verification.close, verification)
  if not read_ok then
    return false, "verification read raised: " .. tostring(persisted)
  end
  if not verify_close_ok then
    return false, "verification close raised: " .. tostring(verify_close_error)
  end
  if persisted ~= expected then
    return false,
      "verification mismatch expected=" .. tostring(string.len(expected)) .. " actual=" .. tostring(
        type(persisted) == "string" and string.len(persisted) or -1
      )
  end

  spool_content = expected
  spooled_through = through_sequence
  return true
end

local function snapshot_player(player_id, source)
  if not net or not net.get_player_info then
    check(source .. ".player_api", false, "net.get_player_info unavailable")
    return
  end

  local info = net.get_player_info(player_id)
  if not info then
    write("PLAYER source=%s unavailable", source)
    return
  end

  local ucid = info.ucid
  local ucid_fingerprint = fingerprint(ucid)
  local expected_fingerprint = connection_ucid_fingerprints[player_id]
  write(
    "PLAYER source=%s side=%s slot_present=%s slot_fingerprint=%s ucid_present=%s ucid_length=%d ucid_fingerprint=%s matches_connect=%s",
    source,
    tostring(info.side),
    tostring(type(info.slot) == "string" and string.len(info.slot) > 0),
    fingerprint(tostring(info.slot or "")),
    tostring(type(ucid) == "string" and string.len(ucid) > 0),
    type(ucid) == "string" and string.len(ucid) or 0,
    ucid_fingerprint,
    tostring(expected_fingerprint ~= nil and expected_fingerprint == ucid_fingerprint)
  )
end

local function snapshot_players(source)
  if not net or not net.get_player_list then
    check(source .. ".player_list", false, "net.get_player_list unavailable")
    return
  end

  local players = net.get_player_list() or {}
  write("PLAYERS source=%s count=%d", source, #players)
  for _, player_id in ipairs(players) do
    snapshot_player(player_id, source)
  end
end

local function parse_frames(blob)
  if type(blob) ~= "string" then
    return nil, "frame blob is not a string"
  end

  local parsed = {}
  local cursor = 1
  while cursor <= string.len(blob) do
    local newline = string.find(blob, "\n", cursor, true)
    if not newline then
      return nil, "frame header has no newline"
    end

    local header = string.sub(blob, cursor, newline - 1)
    local producer_id, run_key, first_sequence, last_sequence, event_count, payload_length =
      string.match(header, "^TLM1|([^|]+)|([^|]+)|(%d+)|(%d+)|(%d+)|(%d+)$")
    first_sequence = tonumber(first_sequence)
    last_sequence = tonumber(last_sequence)
    event_count = tonumber(event_count)
    payload_length = tonumber(payload_length)
    if
      not producer_id
      or not run_key
      or not first_sequence
      or not last_sequence
      or not event_count
      or not payload_length
    then
      return nil, "frame header is malformed"
    end
    if first_sequence > last_sequence or event_count ~= last_sequence - first_sequence + 1 then
      return nil, "frame sequence range and event count disagree"
    end

    local payload_start = newline + 1
    local payload_end = payload_start + payload_length - 1
    if payload_end > string.len(blob) then
      return nil, "declared payload length exceeds returned bytes"
    end

    parsed[#parsed + 1] = {
      producer_id = producer_id,
      run_key = run_key,
      first_sequence = first_sequence,
      last_sequence = last_sequence,
      event_count = event_count,
      payload_length = payload_length,
      payload = string.sub(blob, payload_start, payload_end),
    }
    cursor = payload_end + 1
  end

  return parsed
end

local function run_stage()
  if type(net) ~= "table" or type(net.dostring_in) ~= "function" then
    check("transport.available", false, "net_dostring_in=" .. type(net.dostring_in))
    active = false
    return
  end

  stage = stage + 1

  if stage == 1 then
    local values, value_count, error = mission_eval(
      [[return "probe", 42, nil, true, type(os), type(io), type(lfs), type(require), type(package), type(loadlib)]]
    )
    check(
      "returns_and_stock_sandbox",
      value_count == 10
        and values[1] == "probe"
        and values[2] == 42
        and values[3] == nil
        and values[4] == true
        and values[5] == "nil"
        and values[6] == "nil"
        and values[7] == "nil"
        and values[8] == "nil"
        and values[9] == "nil"
        and values[10] == "nil",
      "error="
        .. tostring(error)
        .. " count="
        .. tostring(value_count)
        .. " marker="
        .. tostring(values and values[1])
        .. " number="
        .. tostring(values and values[2])
        .. " os="
        .. tostring(values and values[5])
        .. " io="
        .. tostring(values and values[6])
        .. " lfs="
        .. tostring(values and values[7])
    )
    return
  end

  if stage == 2 then
    -- The pass-through truncates returned strings at the first NUL byte
    -- (proven in discovery). The serialized form of the 8-byte value is
    -- "38:A\0...", so the transport must deliver exactly "38:A".
    local _, _, error, raw = mission_eval([[return "A" .. string.char(0, 10, 13, 124, 92, 34) .. "Z"]])
    check(
      "binary_nul_truncation",
      raw == "38:A",
      "raw_length="
        .. tostring(type(raw) == "string" and string.len(raw) or -1)
        .. " raw_prefix="
        .. tostring(type(raw) == "string" and string.sub(raw, 1, 16) or nil)
        .. " error="
        .. tostring(error)
    )
    return
  end

  local size_index = stage - 2
  if sizes[size_index] then
    local size_probe = sizes[size_index]
    local requested = size_probe.bytes
    local values, _, error = mission_eval(string.format(
      [[
local target = %d
local payload_length = target
local header
local prefix = "A" .. string.char(10, 13, 124, 92, 34) .. "Z"
repeat
  header = "TLM1|probe-producer|probe-size|1|1|1|" .. payload_length .. "\n"
  local next_length = target - string.len(header)
  if next_length == payload_length then break end
  payload_length = next_length
until payload_length < 0
if payload_length < 0 then return nil end
return header .. prefix .. string.rep("x", payload_length - string.len(prefix))
]],
      requested
    ))
    local value = values and values[1]
    local returned = type(value) == "string" and string.len(value) or -1
    local parsed, parse_error = parse_frames(value)
    local frame_valid = parsed
      and #parsed == 1
      and parsed[1].producer_id == "probe-producer"
      and parsed[1].run_key == "probe-size"
      and parsed[1].payload_length == string.len(parsed[1].payload)
      and string.find(parsed[1].payload, "\0", 1, true) == nil
      and string.sub(parsed[1].payload, 1, #SPECIAL_BYTES) == string.char(unpack(SPECIAL_BYTES))
    if size_probe.required then
      check(
        "frame_" .. tostring(requested),
        returned == requested and frame_valid,
        "returned="
          .. tostring(returned)
          .. " framing="
          .. tostring(frame_valid)
          .. " parse_error="
          .. tostring(parse_error)
          .. " error="
          .. tostring(error)
      )
    else
      write(
        "OBSERVE frame_%d %s returned=%d framing=%s",
        requested,
        returned == requested and frame_valid and "PASS" or "LIMIT",
        returned,
        tostring(frame_valid)
      )
    end
    return
  end

  if stage == STAGE_QUEUE_INITIALIZE then
    local mission_code = string.format(
      [=[
local first = '{\n"event_sequence":1,\n"event_type":"mission.started",\n"probe":"pipe|slash\\\\quote\\\""\n}'
local second = '{"event_sequence":2,"event_type":"mission.heartbeat"}'
local third = '{"event_sequence":3,"event_type":"mission.heartbeat","batch":"remainder"}'
local function frame(sequence, payload)
  return "TLM1|probe-producer|%s|" .. sequence .. "|" .. sequence .. "|1|" .. string.len(payload) .. "\n" .. payload
end
_G.__telemetry_bridge_probe = {
  run_key = %q,
  acknowledged = 0,
  last_peeked = 0,
  events = { frame(1, first), frame(2, second), frame(3, third) },
}
function _G.__telemetry_bridge_probe.peek(max_count)
  local queue = _G.__telemetry_bridge_probe
  local pending = {}
  local last = math.min(#queue.events, queue.acknowledged + max_count)
  for index = queue.acknowledged + 1, last do
    pending[#pending + 1] = queue.events[index]
  end
  queue.last_peeked = last
  return queue.run_key, queue.acknowledged, table.concat(pending)
end
function _G.__telemetry_bridge_probe.ack(run_key, sequence)
  local queue = _G.__telemetry_bridge_probe
  if run_key ~= queue.run_key or sequence < queue.acknowledged or sequence > queue.last_peeked then
    return false, queue.acknowledged
  end
  queue.acknowledged = sequence
  return true, queue.acknowledged
end
return __telemetry_bridge_probe.run_key, #__telemetry_bridge_probe.events,
  string.len(__telemetry_bridge_probe.events[1]) + string.len(__telemetry_bridge_probe.events[2])
]=],
      current_run_key,
      current_run_key
    )
    local values, value_count, error = mission_eval(mission_code)
    local run_key = values and values[1]
    local event_count = values and values[2]
    local queue_bytes = values and values[3]
    expected_queue_bytes = queue_bytes
    check(
      "queue_initialize",
      value_count == 3 and run_key == current_run_key and event_count == 3 and type(queue_bytes) == "number",
      "error="
        .. tostring(error)
        .. " run="
        .. tostring(run_key)
        .. " count="
        .. tostring(event_count)
        .. " bytes="
        .. tostring(queue_bytes)
    )
    return
  end

  if stage == STAGE_QUEUE_PEEK then
    local values, value_count, error = mission_eval([[
local queue = _G.__telemetry_bridge_probe
if not queue then return nil, nil, nil end
return queue.peek(2)
]])
    local run_key = values and values[1]
    local acknowledged = values and values[2]
    local frame = values and values[3]
    local parsed, parse_error = parse_frames(frame)
    local framing_valid = parsed
      and #parsed == 2
      and parsed[1].producer_id == "probe-producer"
      and parsed[1].run_key == current_run_key
      and parsed[1].first_sequence == 1
      and parsed[1].last_sequence == 1
      and parsed[1].event_count == 1
      and parsed[2].first_sequence == 2
      and parsed[2].last_sequence == 2
      and parsed[2].payload_length == string.len(parsed[2].payload)
      and string.find(parsed[1].payload, "pipe|", 1, true) ~= nil
      and string.find(parsed[1].payload, "\n", 1, true) ~= nil
    check(
      "queue_peek",
      value_count == 3
        and run_key == current_run_key
        and acknowledged == 0
        and type(frame) == "string"
        and string.len(frame) == expected_queue_bytes
        and framing_valid,
      "error="
        .. tostring(error)
        .. " run="
        .. tostring(run_key)
        .. " acknowledged="
        .. tostring(acknowledged)
        .. " bytes="
        .. tostring(type(frame) == "string" and string.len(frame) or -1)
        .. " framing="
        .. tostring(framing_valid)
        .. " parse_error="
        .. tostring(parse_error)
    )
    expected_queue_frame = frame
    local spooled, spool_error = false, "frame invalid"
    if framing_valid then
      spooled, spool_error = spool_frame("wb", frame, 2)
    end
    check("queue_spool_first_batch", spooled, "through=2 error=" .. tostring(spool_error))
    if not spooled then
      write("RESULT generation=%d failures=%d", generation, failures)
      active = false
    end
    return
  end

  if stage == STAGE_QUEUE_REPEAT then
    local values, value_count, error = mission_eval([[
local queue = _G.__telemetry_bridge_probe
if not queue then return nil, nil, nil end
return queue.peek(2)
]])
    local run_key = values and values[1]
    local acknowledged = values and values[2]
    local frame = values and values[3]
    check(
      "queue_repeat_before_ack",
      value_count == 3 and run_key == current_run_key and acknowledged == 0 and frame == expected_queue_frame,
      "error="
        .. tostring(error)
        .. " run="
        .. tostring(run_key)
        .. " acknowledged="
        .. tostring(acknowledged)
        .. " identical="
        .. tostring(frame == expected_queue_frame)
    )
    return
  end

  if stage == STAGE_QUEUE_ACKNOWLEDGE then
    if spooled_through ~= 2 then
      check("queue_acknowledge_guard", false, "spooled_through=" .. tostring(spooled_through))
      write("RESULT generation=%d failures=%d", generation, failures)
      active = false
      return
    end
    local mission_code = string.format(
      [=[
local queue = _G.__telemetry_bridge_probe
if not queue then return nil, nil, nil, nil, nil, nil end
local invalid_run_accepted, before_ack = queue.ack("wrong-run", 2)
local beyond_spool_accepted, after_beyond = queue.ack(%q, 3)
local accepted, acknowledged = queue.ack(%q, 2)
return invalid_run_accepted, before_ack, beyond_spool_accepted, after_beyond, accepted, acknowledged
]=],
      current_run_key,
      current_run_key
    )
    local values, value_count, error = mission_eval(mission_code)
    local invalid_accepted = values and values[1]
    local before_ack = values and values[2]
    local beyond_spool_accepted = values and values[3]
    local after_beyond = values and values[4]
    local accepted = values and values[5]
    local acknowledged = values and values[6]
    check(
      "queue_acknowledge",
      value_count == 6
        and spooled_through == 2
        and invalid_accepted == false
        and before_ack == 0
        and beyond_spool_accepted == false
        and after_beyond == 0
        and accepted == true
        and acknowledged == 2,
      "error="
        .. tostring(error)
        .. " invalid_accepted="
        .. tostring(invalid_accepted)
        .. " before_ack="
        .. tostring(before_ack)
        .. " beyond_spool_accepted="
        .. tostring(beyond_spool_accepted)
        .. " after_beyond="
        .. tostring(after_beyond)
        .. " accepted="
        .. tostring(accepted)
        .. " acknowledged="
        .. tostring(acknowledged)
    )
    return
  end

  if stage == STAGE_QUEUE_REMAINDER then
    local values, value_count, error = mission_eval([[
local queue = _G.__telemetry_bridge_probe
if not queue then return nil, nil, nil end
return queue.peek(2)
]])
    local run_key = values and values[1]
    local acknowledged = values and values[2]
    local frame = values and values[3]
    local parsed, parse_error = parse_frames(frame)
    local framing_valid = parsed
      and #parsed == 1
      and parsed[1].run_key == current_run_key
      and parsed[1].first_sequence == 3
      and parsed[1].last_sequence == 3
    check(
      "queue_remainder_peek",
      value_count == 3 and run_key == current_run_key and acknowledged == 2 and framing_valid,
      "error="
        .. tostring(error)
        .. " acknowledged="
        .. tostring(acknowledged)
        .. " framing="
        .. tostring(framing_valid)
        .. " parse_error="
        .. tostring(parse_error)
    )
    expected_remainder_frame = frame
    local spooled, spool_error = false, "frame invalid"
    if framing_valid then
      spooled, spool_error = spool_frame("ab", frame, 3)
    end
    check("queue_spool_remainder", spooled, "through=3 error=" .. tostring(spool_error))
    if not spooled then
      write("RESULT generation=%d failures=%d", generation, failures)
      active = false
    end
    return
  end

  if stage == STAGE_QUEUE_ACKNOWLEDGE_REMAINDER then
    if spooled_through ~= 3 then
      check("queue_acknowledge_remainder_guard", false, "spooled_through=" .. tostring(spooled_through))
      write("RESULT generation=%d failures=%d", generation, failures)
      active = false
      return
    end
    local mission_code = string.format(
      [=[
local queue = _G.__telemetry_bridge_probe
if not queue then return nil, nil end
return queue.ack(%q, 3)
]=],
      current_run_key
    )
    local values, value_count, error = mission_eval(mission_code)
    local accepted = values and values[1]
    local acknowledged = values and values[2]
    check(
      "queue_acknowledge_remainder",
      value_count == 2
        and spooled_through == 3
        and expected_remainder_frame ~= nil
        and accepted == true
        and acknowledged == 3,
      "error=" .. tostring(error) .. " accepted=" .. tostring(accepted) .. " acknowledged=" .. tostring(acknowledged)
    )
    return
  end

  if stage == STAGE_QUEUE_EMPTY then
    local values, value_count, error = mission_eval([[
local queue = _G.__telemetry_bridge_probe
if not queue then return nil, nil end
local _, acknowledged, pending = queue.peek(2)
return acknowledged, pending
]])
    local acknowledged = values and values[1]
    local pending = values and values[2]
    check(
      "queue_empty_after_ack",
      value_count == 2 and acknowledged == 3 and type(pending) == "string" and pending == "",
      "error="
        .. tostring(error)
        .. " acknowledged="
        .. tostring(acknowledged)
        .. " type="
        .. type(pending)
        .. " bytes="
        .. tostring(type(pending) == "string" and string.len(pending) or -1)
    )
    mission_eval([[_G.__telemetry_bridge_probe = nil return true]])
    write("RESULT generation=%d failures=%d", generation, failures)
    active = false
  end
end

function callbacks.onMissionLoadBegin()
  cleanup_spool()
  failures = 0
  lifecycle_stage = 1
  active = false
  connection_ucid_fingerprints = {}
  write("LIFECYCLE onMissionLoadBegin")
end

function callbacks.onMissionLoadEnd()
  check("lifecycle.load_end_order", lifecycle_stage == 1, "previous_stage=" .. tostring(lifecycle_stage))
  lifecycle_stage = 2
  write("LIFECYCLE onMissionLoadEnd")
end

function callbacks.onSimulationStart()
  check("lifecycle.simulation_start_order", lifecycle_stage == 2, "previous_stage=" .. tostring(lifecycle_stage))
  lifecycle_stage = 3
  generation = generation + 1
  active = true
  stage = 0
  expected_queue_bytes = nil
  expected_queue_frame = nil
  expected_remainder_frame = nil
  spooled_through = 0
  spool_content = ""
  local previous_run_key = current_run_key
  current_run_key = "probe-" .. hook_nonce .. "-generation-" .. tostring(generation)
  check(
    "run_key_fresh",
    previous_run_key == nil or current_run_key ~= previous_run_key,
    "generation=" .. generation .. " fingerprint=" .. fingerprint(current_run_key)
  )
  last_player_snapshot = -math.huge
  local spool_api_available = type(lfs) == "table"
    and type(lfs.writedir) == "function"
    and type(io) == "table"
    and type(io.open) == "function"
  check("hook_spool_api", spool_api_available, "io=" .. type(io) .. " lfs=" .. type(lfs))
  if spool_api_available then
    local spool_directory = rawget(_G, "TELEMETRY_BRIDGE_PROBE_SPOOL_DIRECTORY") or (lfs.writedir() .. "Logs/")
    spool_path = spool_directory .. "telemetry-bridge-probe-" .. hook_nonce .. "-" .. generation .. ".tmp"
    local existing = io.open(spool_path, "rb")
    if existing then
      existing:close()
      check("spool_path_unused", false, "existing probe spool requires manual cleanup")
      spool_path = nil
    else
      check("spool_path_unused", true, "fresh probe spool path")
    end
  end
  local api = callback_api
  local mission_name = "unavailable"
  if api and api.getMissionName then
    local ok, value = pcall(api.getMissionName)
    if ok then
      mission_name = tostring(value)
    end
  end
  local multiplayer = api and api.isMultiplayer and api.isMultiplayer() or false
  local server = api and api.isServer and api.isServer() or false
  write(
    "LIFECYCLE onSimulationStart generation=%d mission=%s multiplayer=%s server=%s",
    generation,
    mission_name,
    tostring(multiplayer),
    tostring(server)
  )
  check(
    "full_client_host_mode",
    multiplayer == true and server == true,
    "multiplayer=" .. tostring(multiplayer) .. " server=" .. tostring(server)
  )
  snapshot_players("simulation_start")
end

function callbacks.onSimulationFrame()
  local api = callback_api
  local now = api and api.getRealTime and api.getRealTime() or 0
  if now >= last_player_snapshot + PLAYER_SNAPSHOT_INTERVAL then
    last_player_snapshot = now
    snapshot_players("poll")
  end
  if active then
    run_stage()
  end
end

function callbacks.onSimulationStop()
  local values, _, error = mission_eval([[return "stop-visible"]])
  local transport_callable = values and values[1] == "stop-visible" or false
  write("LIFECYCLE onSimulationStop transport_callable=%s error=%s", tostring(transport_callable), tostring(error))
  mission_eval([[_G.__telemetry_bridge_probe = nil return true]])
  check("lifecycle.simulation_stop_order", lifecycle_stage == 3, "previous_stage=" .. tostring(lifecycle_stage))
  lifecycle_stage = 4
  cleanup_spool()
  write("STOP_RESULT generation=%d failures=%d", generation, failures)
  active = false
end

function callbacks.onSimulationPause()
  write("LIFECYCLE onSimulationPause")
end

function callbacks.onSimulationResume()
  write("LIFECYCLE onSimulationResume")
end

function callbacks.onNetMissionChanged(mission_name)
  write("LIFECYCLE onNetMissionChanged mission=%s", tostring(mission_name))
end

function callbacks.onNetMissionEnd()
  write("LIFECYCLE onNetMissionEnd")
end

function callbacks.onPlayerTryConnect(_, _, ucid, player_id)
  connection_ucid_fingerprints[player_id] = fingerprint(ucid)
  write(
    "PLAYER source=try_connect ucid_present=%s ucid_length=%d ucid_fingerprint=%s",
    tostring(type(ucid) == "string" and string.len(ucid) > 0),
    type(ucid) == "string" and string.len(ucid) or 0,
    fingerprint(ucid)
  )
end

function callbacks.onPlayerConnect(player_id)
  snapshot_player(player_id, "connect")
end

function callbacks.onPlayerStart(player_id)
  snapshot_player(player_id, "start")
end

function callbacks.onPlayerChangeSlot(player_id)
  snapshot_player(player_id, "change_slot")
end

function callbacks.onPlayerStop(player_id)
  snapshot_player(player_id, "stop")
end

function callbacks.onPlayerDisconnect(player_id)
  snapshot_player(player_id, "disconnect")
  connection_ucid_fingerprints[player_id] = nil
end

local function protect_callback(name, callback)
  return function(...)
    local argument_count = select("#", ...)
    local arguments = { ... }
    local ok, callback_error = pcall(function()
      callback(unpack(arguments, 1, argument_count))
    end)
    if not ok then
      check("callback." .. name, false, tostring(callback_error))
    end
    return nil
  end
end

for name, callback in pairs(callbacks) do
  callbacks[name] = protect_callback(name, callback)
end

local api_name = nil
local function is_complete_callback_api(api)
  return type(api) == "table"
    and type(api.setUserCallbacks) == "function"
    and type(api.getRealTime) == "function"
    and type(api.getMissionName) == "function"
    and type(api.isMultiplayer) == "function"
    and type(api.isServer) == "function"
end

if is_complete_callback_api(Sim) then
  callback_api = Sim
  api_name = "Sim"
elseif is_complete_callback_api(DCS) then
  callback_api = DCS
  api_name = "DCS"
end
if not callback_api then
  write("LOAD FAIL complete callback API unavailable DCS=%s Sim=%s", type(DCS), type(Sim))
else
  callback_api.setUserCallbacks(callbacks)
  write("LOAD PASS callback_api=%s", api_name)
end

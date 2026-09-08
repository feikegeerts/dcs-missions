-- Production GameGUI telemetry hook for duel-dynamic.
--
-- This hook keeps io/os/lfs outside the stock-sanitized mission state. Every
-- mission call uses net.dostring_in("mission", wrapper), and only that wrapper
-- invokes a_do_script. The inlined bridge_frame block below must remain
-- behavior-identical to telemetry/bridge_frame.lua.
--
-- Acceptance is durable only after append, close, reopen, and bounded exact
-- verification of the append region. Stop draining is bounded and reports zero
-- unspooled events only after a mission-authoritative empty peek.

local config = rawget(_G, "TELEMETRY_BRIDGE_HOOK_CONFIG") or {}
local LOG_TAG = config.log_tag or "TELEMETRY_BRIDGE_HOOK"
local DEFAULT_MAX_FRAMES = config.max_frames or 32
local MIN_FRAMES = config.min_frames or 1
local POLL_INTERVAL = config.poll_interval_s or 0.25
local MAX_BACKOFF = config.max_backoff_s or 4.0
local STOP_MAX_CYCLES = config.stop_max_cycles or 32
local VERIFY_PREFIX_BYTES = config.verify_prefix_bytes or 256
local MAX_SPOOL_BYTES_PER_CYCLE = 65536
local MAX_MISSION_EVALS_PER_CYCLE = 3
local TELEMETRY_DIR_NAME = config.telemetry_dir_name or "telemetry"
local BRIDGE_DIR_NAME = config.bridge_dir_name or "telemetry-bridge"
local PRODUCER_FILE_NAME = config.producer_id_file_name or "producer-id"

local function write_log(message, ...)
  if type(log) == "table" and type(log.write) == "function" then
    pcall(log.write, LOG_TAG, log.INFO, message, ...)
  end
end

if
  not (type(Sim) == "table" and type(Sim.setUserCallbacks) == "function")
  and not (type(DCS) == "table" and type(DCS.setUserCallbacks) == "function")
then
  write_log("fatal category=callback-api-unavailable")
  return
end

local function join_path(left, right)
  left = string.gsub(left, "\\", "/")
  if string.sub(left, -1) ~= "/" then
    left = left .. "/"
  end
  return left .. string.gsub(right, "^[/\\]+", "")
end

local write_directory = config.spool_base_dir
if type(write_directory) ~= "string" and type(lfs) == "table" and type(lfs.writedir) == "function" then
  local ok, result = pcall(lfs.writedir)
  if ok then
    write_directory = result
  end
end
local logs_directory = type(write_directory) == "string" and join_path(write_directory, "Logs") or nil
local telemetry_directory = logs_directory and join_path(logs_directory, TELEMETRY_DIR_NAME) or nil
local bridge_directory = logs_directory and join_path(logs_directory, BRIDGE_DIR_NAME) or nil
local producer_path = bridge_directory and join_path(bridge_directory, PRODUCER_FILE_NAME) or nil

local function ensure_directory(path)
  if type(path) ~= "string" or type(lfs) ~= "table" then
    return nil
  end
  local ok, mode = pcall(lfs.attributes, path, "mode")
  if ok and mode == "directory" then
    return true
  end
  if ok and mode ~= nil then
    return nil
  end
  pcall(lfs.mkdir, path)
  ok, mode = pcall(lfs.attributes, path, "mode")
  return ok and mode == "directory" or nil
end

local function ensure_storage_directories()
  return ensure_directory(logs_directory)
    and ensure_directory(telemetry_directory)
    and ensure_directory(bridge_directory)
end

-- BEGIN inlined bridge_frame.lua (keep behavior-identical to the mission module)
-- DDBRIDGE1 wire codec. This module is self-contained so its implementation
-- can be copied byte-identically into the GameGUI hook.
--
-- Frame bytes are exactly:
--   DDBRIDGE1|producer_id|run_key|first_sequence|last_sequence|count|payload_bytes\n
-- followed by count records, each exactly:
--   decimal_payload_length|payload_bytes
-- There is no separator after a record payload. All complete frames are
-- NUL-free and at most 65536 bytes. This codec validates producer_id and
-- run_key itself using the event_id token grammar.

local bridge_frame = {}

local MAGIC = "DDBRIDGE1"
local MAX_FRAME_BYTES = 65536
local MAX_SEQUENCE = 9007199254740991

bridge_frame.MAGIC = MAGIC
bridge_frame.MAX_FRAME_BYTES = MAX_FRAME_BYTES

local function is_token_character(byte)
  return (byte >= 65 and byte <= 90)
    or (byte >= 97 and byte <= 122)
    or (byte >= 48 and byte <= 57)
    or byte == 46
    or byte == 95
    or byte == 45
end

local function is_alphanumeric(byte)
  return (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or (byte >= 48 and byte <= 57)
end

local function validate_token(value, field_name)
  if type(value) ~= "string" then
    return nil, field_name .. " must be a string"
  end
  local length = string.len(value)
  if length < 1 or length > 128 then
    return nil, field_name .. " must contain 1-128 ASCII token characters"
  end
  if not is_alphanumeric(string.byte(value, 1)) then
    return nil, field_name .. " must start with an ASCII letter or digit"
  end
  for index = 2, length do
    if not is_token_character(string.byte(value, index)) then
      return nil, field_name .. " contains an invalid character"
    end
  end
  return true
end

local function is_integer(value, minimum, maximum)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and math.floor(value) == value
    and value >= minimum
    and value <= maximum
end

local function decimal_integer(value)
  local reversed = {}
  repeat
    local digit = value % 10
    reversed[#reversed + 1] = string.char(48 + digit)
    value = math.floor(value / 10)
  until value == 0
  local digits = {}
  for index = #reversed, 1, -1 do
    digits[#digits + 1] = reversed[index]
  end
  return table.concat(digits)
end

local function parse_decimal(value, field_name, minimum, maximum)
  local canonical = type(value) == "string" and (value == "0" or (string.match(value, "^[1-9][0-9]*$") ~= nil))
  if not canonical then
    return nil, field_name .. " must be canonical decimal digits"
  end
  local number = tonumber(value)
  if not number or not is_integer(number, minimum, maximum) then
    return nil, field_name .. " is out of range"
  end
  if string.format("%.0f", number) ~= value then
    return nil, field_name .. " is not exactly representable"
  end
  return number
end

local function split_header(header)
  local fields = {}
  local start = 1
  while true do
    local separator = string.find(header, "|", start, true)
    if not separator then
      fields[#fields + 1] = string.sub(header, start)
      break
    end
    fields[#fields + 1] = string.sub(header, start, separator - 1)
    start = separator + 1
  end
  return fields
end

function bridge_frame.encode(context, lines)
  if type(context) ~= "table" then
    return nil, "frame context must be a table"
  end
  local valid, validation_error = validate_token(context.producer_id, "producer_id")
  if not valid then
    return nil, validation_error
  end
  valid, validation_error = validate_token(context.run_key, "run_key")
  if not valid then
    return nil, validation_error
  end
  if not is_integer(context.first_sequence, 1, MAX_SEQUENCE) then
    return nil, "first_sequence must be a positive event sequence"
  end
  if not is_integer(context.last_sequence, context.first_sequence, MAX_SEQUENCE) then
    return nil, "last_sequence must not precede first_sequence"
  end
  if type(lines) ~= "table" or #lines == 0 then
    return nil, "frame lines must be a non-empty array"
  end
  if #lines ~= context.last_sequence - context.first_sequence + 1 then
    return nil, "frame line count does not match sequence range"
  end

  local payload_bytes = 0
  local records = {}
  for index = 1, #lines do
    local line = lines[index]
    if type(line) ~= "string" or string.len(line) == 0 then
      return nil, "frame line " .. tostring(index) .. " must be a non-empty string"
    end
    if string.find(line, "\0", 1, true) then
      return nil, "frame line " .. tostring(index) .. " contains NUL"
    end
    local length = string.len(line)
    payload_bytes = payload_bytes + length
    records[#records + 1] = tostring(length) .. "|" .. line
  end

  local header = table.concat({
    MAGIC,
    context.producer_id,
    context.run_key,
    decimal_integer(context.first_sequence),
    decimal_integer(context.last_sequence),
    tostring(#lines),
    tostring(payload_bytes),
  }, "|") .. "\n"
  local frame = header .. table.concat(records)
  if string.len(frame) > MAX_FRAME_BYTES then
    return nil, "frame-too-large"
  end
  if string.find(frame, "\0", 1, true) then
    return nil, "encoded frame contains NUL"
  end
  return frame
end

function bridge_frame.decode(frame)
  if type(frame) ~= "string" or string.len(frame) == 0 then
    return nil, "frame must be a non-empty string"
  end
  if string.len(frame) > MAX_FRAME_BYTES then
    return nil, "frame-too-large"
  end
  if string.find(frame, "\0", 1, true) then
    return nil, "frame contains NUL"
  end

  local newline = string.find(frame, "\n", 1, true)
  if not newline then
    return nil, "frame header terminator is missing"
  end
  local fields = split_header(string.sub(frame, 1, newline - 1))
  if #fields ~= 7 then
    return nil, "frame header must contain exactly 7 fields"
  end
  if fields[1] ~= MAGIC then
    return nil, "frame magic must be DDBRIDGE1"
  end
  local valid, validation_error = validate_token(fields[2], "producer_id")
  if not valid then
    return nil, validation_error
  end
  valid, validation_error = validate_token(fields[3], "run_key")
  if not valid then
    return nil, validation_error
  end

  local first_sequence, numeric_error = parse_decimal(fields[4], "first_sequence", 1, MAX_SEQUENCE)
  if not first_sequence then
    return nil, numeric_error
  end
  local last_sequence
  last_sequence, numeric_error = parse_decimal(fields[5], "last_sequence", 1, MAX_SEQUENCE)
  if not last_sequence then
    return nil, numeric_error
  end
  local count
  count, numeric_error = parse_decimal(fields[6], "count", 1, MAX_SEQUENCE)
  if not count then
    return nil, numeric_error
  end
  local payload_bytes
  payload_bytes, numeric_error = parse_decimal(fields[7], "payload_bytes", 0, MAX_FRAME_BYTES)
  if payload_bytes == nil then
    return nil, numeric_error
  end
  if last_sequence - first_sequence + 1 ~= count then
    return nil, "frame count does not match sequence range"
  end

  local lines = {}
  local position = newline + 1
  local cumulative_payload = 0
  for index = 1, count do
    local separator = string.find(frame, "|", position, true)
    if not separator then
      return nil, "record " .. tostring(index) .. " length separator is missing"
    end
    local length
    length, numeric_error =
      parse_decimal(string.sub(frame, position, separator - 1), "record length", 1, MAX_FRAME_BYTES)
    if not length then
      return nil, "record " .. tostring(index) .. " " .. numeric_error
    end
    local payload_start = separator + 1
    local payload_end = payload_start + length - 1
    if payload_end > string.len(frame) then
      return nil, "record " .. tostring(index) .. " payload is truncated"
    end
    lines[index] = string.sub(frame, payload_start, payload_end)
    cumulative_payload = cumulative_payload + length
    position = payload_end + 1
  end
  if position ~= string.len(frame) + 1 then
    return nil, "frame has trailing garbage"
  end
  if cumulative_payload ~= payload_bytes then
    return nil, "frame payload_bytes does not match record payloads"
  end

  return {
    producer_id = fields[2],
    run_key = fields[3],
    first_sequence = first_sequence,
    last_sequence = last_sequence,
    count = count,
    payload_bytes = payload_bytes,
    lines = lines,
  }
end
-- END inlined bridge_frame.lua

local function fingerprint(value)
  local hash = 0
  for index = 1, string.len(value) do
    hash = (hash * 131 + string.byte(value, index)) % 2147483647
  end
  return string.format("%08x", hash)
end

local function read_all(path)
  if type(io) ~= "table" or type(io.open) ~= "function" then
    return nil
  end
  local open_ok, file = pcall(io.open, path, "rb")
  if not open_ok or not file then
    return nil
  end
  local ok, content = pcall(file.read, file, "*a")
  pcall(file.close, file)
  if not ok then
    return nil
  end
  return content
end

local function write_and_verify(path, mode, bytes, expected)
  if type(io) ~= "table" or type(io.open) ~= "function" then
    return nil
  end
  local open_ok, file = pcall(io.open, path, mode)
  if not open_ok or not file then
    return nil
  end
  local write_ok = pcall(file.write, file, bytes)
  local flush_ok = pcall(file.flush, file)
  local close_ok = pcall(file.close, file)
  if not write_ok or not flush_ok or not close_ok then
    return nil
  end
  local mutator = config.test_spool_verify_mutator
  if type(mutator) == "function" then
    pcall(mutator, path)
  end
  return read_all(path) == expected or nil
end

local function file_size(path)
  if type(lfs) ~= "table" or type(lfs.attributes) ~= "function" then
    return nil
  end
  local ok, size = pcall(lfs.attributes, path, "size")
  return ok and type(size) == "number" and size >= 0 and size or nil
end

local function read_region(path, offset, count)
  if type(io) ~= "table" or type(io.open) ~= "function" then
    return nil
  end
  local open_ok, file = pcall(io.open, path, "rb")
  if not open_ok or not file then
    return nil
  end
  local seek_ok, position = pcall(file.seek, file, "set", offset)
  local read_ok, content = false, nil
  if seek_ok and position == offset then
    read_ok, content = pcall(file.read, file, count)
  end
  pcall(file.close, file)
  return read_ok and content or nil
end

local function append_and_verify(path, bytes, expected_size)
  local pre_size = file_size(path)
  if pre_size == nil and expected_size == 0 then
    pre_size = 0
  end
  if pre_size ~= expected_size then
    return nil, "spool-size-failed"
  end

  local prefix_count = math.min(pre_size, VERIFY_PREFIX_BYTES)
  local prefix_offset = pre_size - prefix_count
  local prefix_before = prefix_count > 0 and read_region(path, prefix_offset, prefix_count) or ""
  if prefix_before == nil then
    return nil, "spool-read-failed"
  end

  if type(io) ~= "table" or type(io.open) ~= "function" then
    return nil, "spool-open-failed"
  end
  local open_ok, file = pcall(io.open, path, "ab")
  if not open_ok or not file then
    return nil, "spool-open-failed"
  end
  local write_ok, write_result = pcall(file.write, file, bytes)
  -- Successful flush/close are gated on pcall success only. DCS may return
  -- nil on a successful close (no return values), so result truthiness is
  -- not a failure signal here; post-write size plus bounded prefix and
  -- appended-byte readback below is the authoritative persistence proof.
  -- A successful Lua 5.1 write returns a truthy value, so a nil write
  -- result still indicates a write failure (for example disk-full short
  -- write) even when no exception was raised.
  local flush_ok = pcall(file.flush, file)
  local close_ok = pcall(file.close, file)
  if not write_ok or write_result == nil or not flush_ok or not close_ok then
    return nil, "spool-write-failed"
  end

  local mutator = config.test_spool_verify_mutator
  if type(mutator) == "function" then
    pcall(mutator, path, pre_size, string.len(bytes))
  end

  local post_size = file_size(path)
  if post_size ~= pre_size + string.len(bytes) then
    return nil, "spool-size-failed"
  end
  if prefix_count > 0 and read_region(path, prefix_offset, prefix_count) ~= prefix_before then
    return nil, "spool-verify-failed"
  end
  local appended = read_region(path, pre_size, string.len(bytes))
  if appended == nil then
    return nil, "spool-read-failed"
  end
  if appended ~= bytes then
    return nil, "spool-verify-failed"
  end
  return post_size
end

local function make_producer_id()
  if not ensure_storage_directories() then
    return nil
  end
  local existing = read_all(producer_path)
  if existing and validate_token(existing, "producer_id") then
    return existing
  end
  local entropy = table.concat({
    tostring(os.time()),
    tostring(os.clock()),
    tostring(math.random()),
    tostring({}),
    tostring(write_directory),
  }, "|")
  local created = "dcs-server-" .. fingerprint(entropy)
  if not validate_token(created, "producer_id") then
    return nil
  end
  if not write_and_verify(producer_path, "wb", created, created) then
    return nil
  end
  return created
end

local producer_id = make_producer_id()
if producer_id then
  write_log("START producer=%s producer-file=%s", producer_id, producer_path)
else
  write_log("fatal category=producer-identity-unavailable")
end

local state = {
  phase = "idle",
  producer_id = producer_id,
  generation = 0,
  last_acked_sequence = 0,
  spool_verified_sequence = 0,
  last_known_unspooled = nil,
  failure_count = 0,
  next_poll_at = 0,
  stuck = false,
  busy = false,
  max_frames = DEFAULT_MAX_FRAMES,
  spool_size = 0,
  queue_empty_verified = false,
  missing_runtime = false,
  transport_logged = false,
}

local function clock_now()
  local ok, value = pcall(os.clock)
  return ok and type(value) == "number" and value or 0
end

local function schedule_failure()
  state.failure_count = state.failure_count + 1
  local interval = POLL_INTERVAL * (2 ^ state.failure_count)
  if interval > MAX_BACKOFF then
    interval = MAX_BACKOFF
  end
  state.next_poll_at = clock_now() + interval
end

local function deserialize_values(serialized)
  if type(serialized) ~= "string" then
    return nil, 0
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
    else
      local colon = string.find(serialized, ":", cursor, true)
      if not colon then
        return nil, 0
      end
      local length = tonumber(string.sub(serialized, cursor + 1, colon - 1))
      if not length or length < 0 or length > total then
        return nil, 0
      end
      local data = string.sub(serialized, colon + 1, colon + length)
      if string.len(data) ~= length then
        return nil, 0
      end
      count = count + 1
      if tag == "1" then
        values[count] = tonumber(data)
      elseif tag == "2" then
        values[count] = data == "true"
      elseif tag == "3" then
        values[count] = data
      elseif tag == "4" then
        values[count] = nil
      else
        return nil, 0
      end
      cursor = colon + length + 1
    end
  end
  return values, count
end

local function mission_eval(source)
  if type(net) ~= "table" or type(net.dostring_in) ~= "function" then
    return nil, "transport-unavailable"
  end
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
    .. 'return table.concat(parts), "TLM_BRIDGE_HOOK_PAD"'
  local wrapper = "local call = { pcall(a_do_script, "
    .. string.format("%q", inner_code)
    .. ") }\n"
    .. "if not call[1] then return 'TLM_MISSION_EVAL_ERROR' end\n"
    .. "if type(call[2]) == 'string' then return call[2] end\n"
    .. "if type(call[3]) == 'string' then return call[3] end\n"
    .. "return 'TLM_TRANSPORT_FAIL'"
  local ok, raw = pcall(net.dostring_in, "mission", wrapper)
  if not ok then
    return nil, "transport-unavailable"
  end
  if raw == "TLM_MISSION_EVAL_ERROR" or raw == "TLM_TRANSPORT_FAIL" then
    return nil, "mission-eval-failed"
  end
  local values, count = deserialize_values(raw)
  if not values then
    return nil, "transport-decode-failed"
  end
  return values, nil, count, raw
end

local function mark_transport_unavailable(reason)
  state.stuck = true
  if not state.transport_logged then
    state.transport_logged = true
    write_log("transport-unavailable generation=%d category=%s", state.generation, reason)
  end
end

local function make_run_key()
  local utc = os.date("!%Y%m%dT%H%M%SZ")
  local entropy = table.concat({
    tostring(os.time()),
    tostring(os.clock()),
    tostring(math.random()),
    tostring({}),
    tostring(state.generation),
  }, "|")
  local run_key = "run-" .. utc .. "-" .. fingerprint(entropy)
  return validate_token(run_key, "run_key") and run_key or nil
end

local function begin_generation()
  state.generation = state.generation + 1
  state.phase = "handshaking"
  state.last_acked_sequence = 0
  state.spool_verified_sequence = 0
  state.last_known_unspooled = nil
  state.failure_count = 0
  state.next_poll_at = clock_now()
  state.stuck = producer_id == nil
  state.busy = false
  state.max_frames = DEFAULT_MAX_FRAMES
  state.spool_size = 0
  state.queue_empty_verified = false
  state.missing_runtime = false
  state.transport_logged = false
  state.run_key = make_run_key()
  state.spool_path = state.run_key and join_path(telemetry_directory, state.run_key .. ".ndjson") or nil
  if not state.run_key or not ensure_storage_directories() then
    state.stuck = true
    write_log("hook-error storage generation=%d", state.generation)
  end
end

local function handshake()
  -- Both interpolated values were token-validated, so they cannot contain a
  -- quote or backslash and are safe inside these Lua string literals.
  local source = 'local bridge = _G.duel_telemetry_bridge; if bridge == nil then return "ERR|bridge-not-present" end; '
    .. 'local ok, err = bridge:begin("'
    .. producer_id
    .. '", "'
    .. state.run_key
    .. '"); if ok then return "OK" else return "ERR|" .. tostring(err) end'
  local values, transport_error = mission_eval(source)
  if not values then
    if transport_error == "transport-unavailable" then
      mark_transport_unavailable(transport_error)
    else
      write_log("hook-error transport generation=%d category=%s", state.generation, transport_error)
      schedule_failure()
    end
    return
  end
  local result = values[1]
  if result == "OK" then
    state.phase = "draining"
    state.failure_count = 0
    state.next_poll_at = clock_now() + POLL_INTERVAL
    state.missing_runtime = false
    write_log("handshake-ok generation=%d run=%s producer=%s", state.generation, state.run_key, producer_id)
  elseif result == "ERR|bridge-not-present" then
    state.phase = "idle"
    state.next_poll_at = clock_now() + POLL_INTERVAL * 8
    if not state.missing_runtime then
      write_log("bridge-runtime-missing generation=%d", state.generation)
    end
    state.missing_runtime = true
  else
    write_log(
      "handshake-failed generation=%d error=redacted bytes=%d",
      state.generation,
      type(result) == "string" and math.min(string.len(result), 120) or 0
    )
    schedule_failure()
  end
end

local function spool_lines(decoded)
  local appended = table.concat(decoded.lines, "\n") .. "\n"
  local verified_size, category = append_and_verify(state.spool_path, appended, state.spool_size)
  if not verified_size then
    state.failure_count = state.failure_count + 1
    state.stuck = true
    write_log(
      "%s generation=%d at-sequence=%d..%d bytes=%d",
      category,
      state.generation,
      decoded.first_sequence,
      decoded.last_sequence,
      string.len(appended)
    )
    return nil
  end
  state.spool_size = verified_size
  state.spool_verified_sequence = math.max(state.spool_verified_sequence, decoded.last_sequence)
  return true
end

local function nonnegative_integer(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value >= 0
    and math.floor(value) == value
end

local function reconciled_cursor(mission_acked, spool_verified)
  if not nonnegative_integer(mission_acked) or not nonnegative_integer(spool_verified) then
    return nil
  end
  return math.min(mission_acked, spool_verified)
end

local function reconcile_ack_frontiers()
  local source = 'local bridge = _G.duel_telemetry_bridge; if bridge == nil then return "ERR|bridge-not-present" end; '
    .. "local status = bridge:status(); return status.last_acked_sequence, status.first_pending_sequence, status.pending_count"
  local values, transport_error, count = mission_eval(source)
  if not values then
    if transport_error == "transport-unavailable" then
      mark_transport_unavailable(transport_error)
    end
    return nil, transport_error
  end

  local mission_acked = values[1]
  local first_pending = values[2]
  local pending_count = values[3]
  if
    count ~= 3
    or not nonnegative_integer(mission_acked)
    or not nonnegative_integer(pending_count)
    or (pending_count == 0 and first_pending ~= nil)
    or (pending_count > 0 and first_pending ~= mission_acked + 1)
  then
    return nil, "status-invalid"
  end

  local cursor = reconciled_cursor(mission_acked, state.spool_verified_sequence)
  state.last_acked_sequence = cursor
  state.last_known_unspooled = math.max(0, mission_acked + pending_count - state.spool_verified_sequence)
  return cursor, nil, mission_acked
end

local function poll_cycle()
  state.queue_empty_verified = false
  local from_sequence = state.last_acked_sequence + 1
  local source = 'local bridge = _G.duel_telemetry_bridge; if bridge == nil then return "ERR|bridge-not-present" end; '
    .. "local value, err = bridge:peek("
    .. tostring(from_sequence)
    .. ", "
    .. tostring(state.max_frames)
    .. '); if value == nil then return "ERR|" .. tostring(err) end; return value'
  local values, transport_error = mission_eval(source)
  if not values then
    if transport_error == "transport-unavailable" then
      mark_transport_unavailable(transport_error)
    else
      write_log("hook-error transport generation=%d category=%s", state.generation, transport_error)
      schedule_failure()
    end
    return "failed"
  end
  local frame = values[1]
  if frame == "ERR|frame-too-large" then
    if state.max_frames <= MIN_FRAMES then
      state.stuck = true
      write_log("frame-stuck generation=%d at-sequence=%d", state.generation, from_sequence)
      return "stuck"
    end
    state.max_frames = math.max(MIN_FRAMES, math.floor(state.max_frames / 2))
    return "retry-smaller"
  end
  if frame == "" then
    state.queue_empty_verified = true
    state.last_known_unspooled = 0
    state.next_poll_at = clock_now() + POLL_INTERVAL
    return "empty"
  end
  if type(frame) ~= "string" or string.sub(frame, 1, 4) == "ERR|" then
    if frame == "ERR|bridge queue overflow" then
      state.failure_count = state.failure_count + 1
      state.stuck = true
      write_log("queue-overflow generation=%d category=bridge-queue-overflow", state.generation)
      return "stuck"
    end
    if frame == "ERR|bridge queue from_index is stale" then
      local previous = state.last_acked_sequence
      local cursor, reconcile_error, mission_acked = reconcile_ack_frontiers()
      if cursor and cursor > previous then
        state.max_frames = DEFAULT_MAX_FRAMES
        state.failure_count = 0
        state.next_poll_at = clock_now() + POLL_INTERVAL
        write_log(
          "ack-reconciled generation=%d cursor=%d mission=%d verified=%d",
          state.generation,
          cursor,
          mission_acked,
          state.spool_verified_sequence
        )
        return "reconciled"
      end
      if reconcile_error == "transport-unavailable" then
        return "stuck"
      end
    end
    write_log(
      "peek-failed generation=%d error=redacted bytes=%d",
      state.generation,
      type(frame) == "string" and math.min(#frame, 120) or 0
    )
    schedule_failure()
    return "failed"
  end
  local decoded = bridge_frame.decode(frame)
  if
    not decoded
    or decoded.producer_id ~= producer_id
    or decoded.run_key ~= state.run_key
    or decoded.first_sequence ~= from_sequence
  then
    schedule_failure()
    write_log(
      "frame-invalid generation=%d from=%d failures=%d bytes=%d",
      state.generation,
      from_sequence,
      state.failure_count,
      #frame
    )
    return "failed"
  end
  if not spool_lines(decoded) then
    return "stuck"
  end
  local ack_source = 'local bridge = _G.duel_telemetry_bridge; if bridge == nil then return "ERR|bridge-not-present" end; '
    .. "local ok, err = bridge:ack("
    .. tostring(decoded.last_sequence)
    .. '); if ok then return "OK" else return "ERR|" .. tostring(err) end'
  local ack_values = mission_eval(ack_source)
  if not ack_values or ack_values[1] ~= "OK" then
    local cursor, reconcile_error, mission_acked = reconcile_ack_frontiers()
    if cursor and cursor >= decoded.last_sequence then
      state.max_frames = DEFAULT_MAX_FRAMES
      state.failure_count = 0
      state.next_poll_at = clock_now() + POLL_INTERVAL
      write_log(
        "ack-reconciled generation=%d cursor=%d mission=%d verified=%d",
        state.generation,
        cursor,
        mission_acked,
        state.spool_verified_sequence
      )
      return "reconciled"
    end
    if reconcile_error ~= "transport-unavailable" then
      write_log("ack-failed generation=%d at-sequence=%d category=redacted", state.generation, decoded.last_sequence)
      schedule_failure()
    end
    return "failed"
  end
  state.last_acked_sequence = decoded.last_sequence
  if state.last_known_unspooled ~= nil then
    state.last_known_unspooled = math.max(0, state.last_known_unspooled - decoded.count)
  end
  state.max_frames = DEFAULT_MAX_FRAMES
  state.failure_count = 0
  state.next_poll_at = clock_now() + POLL_INTERVAL
  write_log(
    "drained generation=%d from=%d..%d count=%d bytes=%d spool=%s",
    state.generation,
    decoded.first_sequence,
    decoded.last_sequence,
    decoded.count,
    decoded.payload_bytes,
    state.spool_path
  )
  return "progress"
end

local function run_ready_cycle(force)
  if state.stuck or state.busy then
    return "skipped"
  end
  local now = clock_now()
  if not force and now < state.next_poll_at then
    return "throttled"
  end
  state.busy = true
  local result
  if state.phase == "handshaking" then
    handshake()
  elseif state.phase == "draining" then
    result = poll_cycle()
  elseif state.phase == "idle" and state.missing_runtime then
    state.phase = "handshaking"
    handshake()
  end
  state.busy = false
  return result
end

local callbacks = {}

function callbacks.onMissionLoadBegin()
  begin_generation()
end

function callbacks.onSimulationFrame()
  run_ready_cycle(false)
end

function callbacks.onSimulationStop()
  local was_draining = state.phase == "draining"
  state.phase = "stopping"
  if was_draining and not state.stuck then
    state.queue_empty_verified = false
    state.last_known_unspooled = nil
    state.phase = "draining"
    local cycles = 0
    while cycles < STOP_MAX_CYCLES and not state.stuck and not state.queue_empty_verified do
      cycles = cycles + 1
      run_ready_cycle(true)
    end
    if not state.stuck and not state.queue_empty_verified then
      reconcile_ack_frontiers()
    end
    state.phase = "stopping"
  end
  local unspooled = "unknown"
  if not state.stuck then
    if state.queue_empty_verified then
      unspooled = "0"
    elseif state.last_known_unspooled ~= nil and state.last_known_unspooled > 0 then
      unspooled = tostring(state.last_known_unspooled)
    end
  end
  write_log(
    "STOP generation=%d spooled=%d spool=%s failures=%d stuck=%s unspooled=%s",
    state.generation,
    state.last_acked_sequence,
    tostring(state.spool_path),
    state.failure_count,
    tostring(state.stuck),
    unspooled
  )
  state.phase = "idle"
end

local function protect_callback(name, callback)
  return function(...)
    local arguments = { ... }
    local argument_count = select("#", ...)
    local ok = pcall(function()
      callback(unpack(arguments, 1, argument_count))
    end)
    if not ok then
      state.busy = false
      state.failure_count = state.failure_count + 1
      write_log("hook-error %s generation=%d", name, state.generation)
    end
    return nil
  end
end

for name, callback in pairs(callbacks) do
  callbacks[name] = protect_callback(name, callback)
end

-- Test-only inspection is injected by the offline mock. Production config is
-- absent, so no extra hook global is created in DCS.
if type(config.test_export) == "function" then
  pcall(config.test_export, {
    bridge_frame = bridge_frame,
    budgets = {
      max_mission_evals_per_cycle = MAX_MISSION_EVALS_PER_CYCLE,
      max_spool_bytes_per_cycle = MAX_SPOOL_BYTES_PER_CYCLE,
      stop_max_cycles = STOP_MAX_CYCLES,
      verify_prefix_bytes = VERIFY_PREFIX_BYTES,
    },
    reconciled_cursor = reconciled_cursor,
    state = state,
    validate_token = validate_token,
  })
end

local callback_api
local callback_api_name
local function try_register(api, name)
  if type(api) ~= "table" or type(api.setUserCallbacks) ~= "function" then
    return nil
  end
  local ok = pcall(api.setUserCallbacks, callbacks)
  if ok then
    callback_api = api
    callback_api_name = name
    return true
  end
  return nil
end

if not try_register(Sim, "Sim") then
  try_register(DCS, "DCS")
end
if callback_api then
  write_log("LOAD callback-api=%s", callback_api_name)
else
  write_log("fatal category=callback-api-unavailable")
end

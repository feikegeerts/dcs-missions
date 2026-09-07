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

local M = {}

local MAGIC = "DDBRIDGE1"
local MAX_FRAME_BYTES = 65536
local MAX_SEQUENCE = 9007199254740991

M.MAGIC = MAGIC
M.MAX_FRAME_BYTES = MAX_FRAME_BYTES

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

function M.encode(context, lines)
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

function M.decode(frame)
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

return M

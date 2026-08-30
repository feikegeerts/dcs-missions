local M = {}

local MAX_SEQUENCE = 9007199254740991

M.MAX_SEQUENCE = MAX_SEQUENCE

local function is_finite_integer(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and math.floor(value) == value
end

local function is_token_character(byte)
  return (byte >= string.byte("A") and byte <= string.byte("Z"))
    or (byte >= string.byte("a") and byte <= string.byte("z"))
    or (byte >= string.byte("0") and byte <= string.byte("9"))
    or byte == string.byte(".")
    or byte == string.byte("_")
    or byte == string.byte("-")
end

local function is_alphanumeric(byte)
  return (byte >= string.byte("A") and byte <= string.byte("Z"))
    or (byte >= string.byte("a") and byte <= string.byte("z"))
    or (byte >= string.byte("0") and byte <= string.byte("9"))
end

local function validate_token(value, field_name)
  field_name = field_name or "token"

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

M.validate_token = validate_token

local function validate_sequence(sequence)
  if not is_finite_integer(sequence) then
    return nil, "event sequence must be a finite integer"
  end

  if sequence < 1 or sequence > MAX_SEQUENCE then
    return nil, "event sequence must be in the range 1-9007199254740991"
  end

  return true
end

M.validate_sequence = validate_sequence

local function decimal_sequence(sequence)
  local valid, validation_error = validate_sequence(sequence)
  if not valid then
    return nil, validation_error
  end

  local reversed_digits = {}
  repeat
    local digit = sequence % 10
    reversed_digits[#reversed_digits + 1] = string.char(48 + digit)
    sequence = math.floor(sequence / 10)
  until sequence == 0

  local digits = {}
  for index = #reversed_digits, 1, -1 do
    digits[#digits + 1] = reversed_digits[index]
  end

  return table.concat(digits)
end

M.decimal_sequence = decimal_sequence

local function build_event_id(producer_id, run_key, sequence)
  local valid, validation_error = validate_token(producer_id, "producer_id")
  if not valid then
    return nil, validation_error
  end

  valid, validation_error = validate_token(run_key, "run_key")
  if not valid then
    return nil, validation_error
  end

  local sequence_digits
  sequence_digits, validation_error = decimal_sequence(sequence)
  if not sequence_digits then
    return nil, validation_error
  end

  return producer_id .. ":" .. run_key .. ":" .. sequence_digits
end

M.build_event_id = build_event_id
M.make_event_id = build_event_id

local function read_allocator_config(config, positional_run_key)
  if type(config) == "table" then
    return config.producer_id, config.run_key
  end

  return config, positional_run_key
end

function M.new(config, positional_run_key)
  local producer_id, run_key = read_allocator_config(config, positional_run_key)

  local valid, validation_error = validate_token(producer_id, "producer_id")
  if not valid then
    return nil, validation_error
  end

  valid, validation_error = validate_token(run_key, "run_key")
  if not valid then
    return nil, validation_error
  end

  local next_sequence = 1
  local allocator = {
    producer_id = producer_id,
    run_key = run_key,
  }

  local function allocate(event_type)
    if type(event_type) ~= "string" or string.len(event_type) == 0 then
      return nil, "event_type is required for sequence allocation"
    end

    if next_sequence == 1 and event_type ~= "mission.started" then
      return nil, "sequence 1 must be mission.started"
    end

    if next_sequence ~= 1 and event_type == "mission.started" then
      return nil, "mission.started can only use sequence 1"
    end

    if next_sequence > MAX_SEQUENCE then
      return nil, "event sequence limit 9007199254740991 has been exhausted"
    end

    local sequence = next_sequence
    local event_id, event_id_error = build_event_id(producer_id, run_key, sequence)
    if not event_id then
      return nil, event_id_error
    end

    next_sequence = sequence + 1
    return sequence, event_id
  end

  function allocator:allocate(event_type)
    return allocate(event_type)
  end

  function allocator:next(event_type)
    return allocate(event_type)
  end

  function allocator:current_sequence()
    return next_sequence - 1
  end

  return allocator
end

M.new_allocator = M.new
M.create = M.new

return M

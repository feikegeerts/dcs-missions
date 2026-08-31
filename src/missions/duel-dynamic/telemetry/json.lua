local M = {}

local CONTROL_ESCAPES = {
  [8] = "\\b",
  [9] = "\\t",
  [10] = "\\n",
  [12] = "\\f",
  [13] = "\\r",
}

local HEX_DIGITS = "0123456789abcdef"

local function is_finite_number(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function is_digit(byte)
  return byte ~= nil and byte >= 48 and byte <= 57
end

local function is_json_number(value)
  local length = string.len(value)
  local index = 1

  if string.sub(value, index, index) == "-" then
    index = index + 1
  end

  local first = string.byte(value, index)
  if first == 48 then
    index = index + 1
    if is_digit(string.byte(value, index)) then
      return false
    end
  elseif first and first >= 49 and first <= 57 then
    index = index + 1
    while is_digit(string.byte(value, index)) do
      index = index + 1
    end
  else
    return false
  end

  if string.sub(value, index, index) == "." then
    index = index + 1
    if not is_digit(string.byte(value, index)) then
      return false
    end
    repeat
      index = index + 1
    until not is_digit(string.byte(value, index))
  end

  local exponent = string.sub(value, index, index)
  if exponent == "e" or exponent == "E" then
    index = index + 1
    local sign = string.sub(value, index, index)
    if sign == "+" or sign == "-" then
      index = index + 1
    end
    if not is_digit(string.byte(value, index)) then
      return false
    end
    repeat
      index = index + 1
    until not is_digit(string.byte(value, index))
  end

  return index > length
end

local function format_number(value)
  local ok, representation = pcall(string.format, "%.17g", value)
  if not ok then
    return nil, "could not format number: " .. tostring(representation)
  end

  -- Lua 5.1 delegates formatting to the C locale. A comma is the usual
  -- locale decimal separator; JSON always requires a period.
  representation = string.gsub(representation, ",", ".")
  if not is_json_number(representation) then
    return nil, "number formatting produced invalid JSON number: " .. tostring(representation)
  end

  return representation
end

local function encode_string(value)
  local chunks = { '"' }
  local length = string.len(value)

  for index = 1, length do
    local byte = string.byte(value, index)
    if byte == 34 then
      chunks[#chunks + 1] = '\\"'
    elseif byte == 92 then
      chunks[#chunks + 1] = "\\\\"
    elseif byte < 32 then
      local standard_escape = CONTROL_ESCAPES[byte]
      if standard_escape then
        chunks[#chunks + 1] = standard_escape
      else
        local high = math.floor(byte / 16)
        local low = byte % 16
        chunks[#chunks + 1] = "\\u00"
          .. string.sub(HEX_DIGITS, high + 1, high + 1)
          .. string.sub(HEX_DIGITS, low + 1, low + 1)
      end
    else
      chunks[#chunks + 1] = string.sub(value, index, index)
    end
  end

  chunks[#chunks + 1] = '"'
  return table.concat(chunks)
end

local function classify_table(value)
  local kind
  local count = 0
  local maximum_index = 0

  for key in pairs(value) do
    local key_type = type(key)
    if key_type == "string" then
      if kind == "array" then
        return nil, "table contains mixed array and object keys"
      end
      kind = "object"
    elseif key_type == "number" then
      if not is_finite_number(key) or math.floor(key) ~= key or key < 1 then
        return nil, "array keys must be contiguous positive integers"
      end
      if kind == "object" then
        return nil, "table contains mixed array and object keys"
      end
      kind = "array"
      count = count + 1
      if key > maximum_index then
        maximum_index = key
      end
    else
      return nil, "object keys must be strings and array keys must be positive integers"
    end
  end

  if kind == "array" and count ~= maximum_index then
    return nil, "array keys must be contiguous positive integers"
  end

  return kind or "object"
end

local function encode_value(value, null, active_tables)
  if rawequal(value, null) then
    return "null"
  end

  local value_type = type(value)
  if value_type == "nil" then
    return nil, "cannot encode nil"
  elseif value_type == "boolean" then
    return value and "true" or "false"
  elseif value_type == "number" then
    if not is_finite_number(value) then
      return nil, "cannot encode a non-finite number"
    end
    return format_number(value)
  elseif value_type == "string" then
    return encode_string(value)
  elseif value_type ~= "table" then
    return nil, "cannot encode value of type " .. value_type
  end

  if getmetatable(value) ~= nil then
    return nil, "cannot encode a table with a metatable"
  end
  if active_tables[value] then
    return nil, "cannot encode cyclic tables"
  end

  local table_kind, shape_error = classify_table(value)
  if not table_kind then
    return nil, shape_error
  end

  active_tables[value] = true
  local chunks = {}
  local encoding_error

  if table_kind == "array" then
    chunks[1] = "["
    local maximum_index = 0
    for key in pairs(value) do
      if key > maximum_index then
        maximum_index = key
      end
    end
    for index = 1, maximum_index do
      local encoded_item, item_error = encode_value(value[index], null, active_tables)
      if not encoded_item then
        encoding_error = item_error
        break
      end
      chunks[#chunks + 1] = encoded_item
      if index ~= maximum_index then
        chunks[#chunks + 1] = ","
      end
    end
    chunks[#chunks + 1] = "]"
  else
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys)

    chunks[1] = "{"
    for index, key in ipairs(keys) do
      local encoded_item, item_error = encode_value(value[key], null, active_tables)
      if not encoded_item then
        encoding_error = item_error
        break
      end
      chunks[#chunks + 1] = encode_string(key)
      chunks[#chunks + 1] = ":"
      chunks[#chunks + 1] = encoded_item
      if index ~= #keys then
        chunks[#chunks + 1] = ","
      end
    end
    chunks[#chunks + 1] = "}"
  end

  active_tables[value] = nil
  if encoding_error then
    return nil, encoding_error
  end

  return table.concat(chunks)
end

function M.new(config)
  if type(config) ~= "table" then
    return nil, "json encoder configuration must be a table"
  end
  if getmetatable(config) ~= nil then
    return nil, "json encoder configuration must not have a metatable"
  end

  local null = rawget(config, "null")
  if type(null) ~= "table" then
    return nil, "json encoder configuration requires a table null sentinel"
  end

  local encoder = {}
  function encoder:encode(value)
    return encode_value(value, null, {})
  end

  return encoder
end

return M

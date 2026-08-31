local M = {}

local function describe_error(prefix, detail)
  if detail == nil or detail == "" then
    return prefix
  end
  return prefix .. ": " .. tostring(detail)
end

local function call_file_method(handle, method_name, ...)
  local lookup_ok, method = pcall(function()
    return handle[method_name]
  end)
  if not lookup_ok then
    return nil, describe_error(method_name .. " lookup failed", method)
  end
  if type(method) ~= "function" then
    return nil, method_name .. " is not available on the file handle"
  end

  local call_ok, result, operation_error = pcall(method, handle, ...)
  if not call_ok then
    return nil, describe_error(method_name .. " failed", result)
  end
  if operation_error ~= nil then
    return nil, describe_error(method_name .. " failed", operation_error)
  end

  -- The first result is deliberately not inspected. DCS file methods can
  -- return nil for a successful operation; pcall success is the signal.
  return true, result
end

local function open_file(io_api, path, mode)
  local call_ok, handle, open_error = pcall(io_api.open, path, mode)
  if not call_ok then
    return nil, describe_error("opening " .. mode .. " failed", handle)
  end
  if handle == nil then
    return nil, describe_error("opening " .. mode .. " failed", open_error)
  end
  if open_error ~= nil then
    return nil, describe_error("opening " .. mode .. " failed", open_error)
  end
  return handle
end

local function verify_append(io_api, path, previous_size, expected_size, expected_tail)
  local reader, open_error = open_file(io_api, path, "rb")
  if not reader then
    return nil, open_error
  end

  local failure
  local seek_lookup_ok, seek_method = pcall(function()
    return reader.seek
  end)
  if seek_lookup_ok and type(seek_method) == "function" then
    local end_ok, end_position = call_file_method(reader, "seek", "end")
    if not end_ok then
      failure = end_position
    elseif type(end_position) ~= "number" or end_position ~= expected_size then
      failure = "readback size mismatch"
    end

    if not failure then
      local seek_ok, seek_position = call_file_method(reader, "seek", "set", previous_size)
      if not seek_ok then
        failure = seek_position
      elseif type(seek_position) ~= "number" or seek_position ~= previous_size then
        failure = "readback seek position mismatch"
      end
    end

    if not failure then
      local read_ok, actual_tail = call_file_method(reader, "read", string.len(expected_tail))
      if not read_ok then
        failure = actual_tail
      elseif actual_tail ~= expected_tail then
        failure = "readback tail mismatch"
      end
    end
  else
    -- DCS mission-side file handles expose read/write/flush/close but no seek.
    -- Slice 4 files are development-only and intentionally small, so verify
    -- the complete file when tail seeking is unavailable.
    local read_ok, content = call_file_method(reader, "read", "*a")
    if not read_ok then
      failure = content
    elseif type(content) ~= "string" or string.len(content) ~= expected_size then
      failure = "readback size mismatch"
    elseif string.sub(content, previous_size + 1) ~= expected_tail then
      failure = "readback tail mismatch"
    end
  end

  local close_ok, close_error = call_file_method(reader, "close")
  if not close_ok and not failure then
    failure = close_error
  end

  if failure then
    return nil, failure
  end
  return true
end

function M.new(config)
  if type(config) ~= "table" then
    return nil, "NDJSON sink configuration must be a table"
  end

  local path = config.path
  if type(path) ~= "string" or string.len(path) == 0 then
    return nil, "NDJSON sink path must be a non-empty string"
  end

  local encoder = config.encoder
  if encoder == nil or (type(encoder) ~= "table" and type(encoder) ~= "userdata") then
    return nil, "NDJSON sink encoder must be an object with encode"
  end
  local encoder_lookup_ok, encode_method = pcall(function()
    return encoder.encode
  end)
  if not encoder_lookup_ok or type(encode_method) ~= "function" then
    return nil, "NDJSON sink encoder must provide encode"
  end

  local io_api = config.io
  if type(io_api) ~= "table" or type(io_api.open) ~= "function" then
    return nil, "NDJSON sink requires an injected io table with open"
  end

  local probe_ok, existing = pcall(io_api.open, path, "rb")
  if not probe_ok then
    return nil, describe_error("checking NDJSON sink target failed", existing)
  end
  if existing then
    -- A close failure does not change the fact that construction must refuse
    -- an existing target, but closing it still avoids leaking the probe handle.
    call_file_method(existing, "close")
    return nil, "NDJSON sink target path already exists"
  end
  -- A failed read-only open is the only portable Lua 5.1 existence probe
  -- available without lfs. The append open below reports any real disk error.

  local sink = {}
  local expected_size = 0
  local fault_error

  function sink:path()
    return path
  end

  function sink:write(event)
    if fault_error then
      return nil, "NDJSON sink is permanently faulted: " .. fault_error
    end

    local encode_ok, encoded, encode_error = pcall(encode_method, encoder, event)
    if not encode_ok then
      return nil, describe_error("encoding event failed", encoded)
    end
    if type(encoded) ~= "string" then
      return nil, describe_error("encoding event failed", encode_error or "encoder must return a JSON string")
    end

    local line = encoded .. "\n"
    local previous_size = expected_size
    local new_size = previous_size + string.len(line)

    local writer, open_error = open_file(io_api, path, "ab")
    if not writer then
      fault_error = open_error
      return nil, "NDJSON sink faulted: " .. fault_error
    end

    local write_ok, write_error = call_file_method(writer, "write", line)
    local flush_ok, flush_error = call_file_method(writer, "flush")
    local close_ok, close_error = call_file_method(writer, "close")

    if not write_ok or not flush_ok or not close_ok then
      fault_error = write_error or flush_error or close_error or "file operation failed"
      return nil, "NDJSON sink faulted: " .. fault_error
    end

    local verified, verification_error = verify_append(io_api, path, previous_size, new_size, line)
    if not verified then
      fault_error = verification_error or "readback verification failed"
      return nil, "NDJSON sink faulted: " .. fault_error
    end

    expected_size = new_size
    return true
  end

  return sink
end

return M

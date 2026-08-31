local json = dofile("src/missions/duel-dynamic/telemetry/json.lua")
local ndjson_sink = dofile("src/missions/duel-dynamic/telemetry/ndjson_sink.lua")
local envelope = dofile("src/missions/duel-dynamic/telemetry/envelope.lua")

local real_io = io
local null = envelope.JSON_NULL
local tests_run = 0
local failures = {}
local temporary_paths = {}

local function check(condition, message)
  if not condition then
    error(message or "assertion failed", 2)
  end
end

local function equal(actual, expected, message)
  check(
    actual == expected,
    (message or "values differ") .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected)
  )
end

local function succeeds(name, callback)
  tests_run = tests_run + 1
  local ok, message = pcall(callback)
  if not ok then
    failures[#failures + 1] = name .. ": " .. tostring(message)
  end
end

local function fails(callback, expected_fragment)
  local first, second = callback()
  check(first == nil, "expected failure")
  check(type(second) == "string", "failure must include a message")
  if expected_fragment then
    check(string.find(second, expected_fragment, 1, true) ~= nil, "unexpected failure: " .. second)
  end
end

local temporary_directory = os.getenv("TEMP") or os.getenv("TMP") or "."
local path_separator = string.find(temporary_directory, "\\", 1, true) and "\\" or "/"
local path_counter = 0

local function new_temporary_path(label)
  path_counter = path_counter + 1
  local path = temporary_directory
    .. path_separator
    .. "dcs-json-sink-"
    .. tostring(os.time())
    .. "-"
    .. tostring(path_counter)
    .. "-"
    .. label
    .. ".tmp"
  temporary_paths[#temporary_paths + 1] = path
  return path
end

local function with_temporary_path(label, callback)
  local path = new_temporary_path(label)
  os.remove(path)
  local ok, first, second = pcall(callback, path)
  os.remove(path)
  if not ok then
    error(first, 0)
  end
  return first, second
end

local function new_encoder()
  local encoder, creation_error = json.new({ null = null })
  check(encoder ~= nil, creation_error)
  return encoder
end

local function read_all(path)
  local file, open_error = real_io.open(path, "rb")
  check(file ~= nil, open_error)
  local content, read_error = file:read("*a")
  local close_ok, close_error = file:close()
  check(content ~= nil, read_error)
  check(close_ok ~= nil, close_error)
  return content
end

local function make_falsey_io()
  local injected_io = {}

  local function wrap(file)
    local wrapper = {}

    function wrapper:write(value)
      local _, write_error = file:write(value)
      if write_error then
        return nil, write_error
      end
      return nil
    end

    function wrapper:flush()
      local _, flush_error = file:flush()
      if flush_error then
        return nil, flush_error
      end
      return nil
    end

    function wrapper:close()
      local _, close_error = file:close()
      if close_error then
        return nil, close_error
      end
      return nil
    end

    function wrapper:seek(...)
      return file:seek(...)
    end

    function wrapper:read(...)
      return file:read(...)
    end

    return wrapper
  end

  function injected_io.open(path, mode)
    local file, open_error = real_io.open(path, mode)
    if not file then
      return nil, open_error
    end
    return wrap(file)
  end

  return injected_io
end

local function make_corrupting_io(state)
  local injected_io = {}

  function injected_io.open(path, mode)
    local file, open_error = real_io.open(path, mode)
    if not file then
      return nil, open_error
    end

    local wrapper = {}
    function wrapper:write(value)
      return file:write(value)
    end

    function wrapper:flush()
      return file:flush()
    end

    function wrapper:close()
      return file:close()
    end

    function wrapper:seek(...)
      return file:seek(...)
    end

    function wrapper:read(...)
      local value, read_error = file:read(...)
      if state.corrupt and value and string.len(value) > 0 then
        value = "!" .. string.sub(value, 2)
      end
      return value, read_error
    end

    return wrapper
  end

  return injected_io
end

local function make_no_seek_io()
  local injected_io = {}

  function injected_io.open(path, mode)
    local file, open_error = real_io.open(path, mode)
    if not file then
      return nil, open_error
    end

    local wrapper = {}
    function wrapper:write(value)
      return file:write(value)
    end
    function wrapper:flush()
      return file:flush()
    end
    function wrapper:close()
      return file:close()
    end
    function wrapper:read(...)
      return file:read(...)
    end
    return wrapper
  end

  return injected_io
end

local function make_failing_write_io(state)
  local injected_io = {}

  function injected_io.open(path, mode)
    local file, open_error = real_io.open(path, mode)
    if not file then
      return nil, open_error
    end

    local wrapper = {}
    function wrapper:write(value)
      if mode == "ab" and state.fail_write then
        state.fail_write = false
        error("simulated write failure")
      end
      return file:write(value)
    end

    function wrapper:flush()
      return file:flush()
    end

    function wrapper:close()
      return file:close()
    end

    function wrapper:seek(...)
      return file:seek(...)
    end

    function wrapper:read(...)
      return file:read(...)
    end

    return wrapper
  end

  return injected_io
end

succeeds("JSON encoder requires the exact null configuration slot", function()
  fails(function()
    return json.new({})
  end, "null sentinel")
  fails(function()
    return json.new({ null = false })
  end, "null sentinel")

  local encoder = new_encoder()
  equal(encoder:encode(null), "null")
  equal(encoder:encode(true), "true")
  equal(encoder:encode(false), "false")
end)

succeeds("JSON strings escape controls and preserve bytes at or above 0x20", function()
  local encoder = new_encoder()
  local controls = string.char(
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
    24,
    25,
    26,
    27,
    28,
    29,
    30,
    31
  )
  local slash = string.char(92)
  local expected_parts = { string.char(34) }
  local expected_escapes = {
    "u0000",
    "u0001",
    "u0002",
    "u0003",
    "u0004",
    "u0005",
    "u0006",
    "u0007",
    "b",
    "t",
    "n",
    "u000b",
    "f",
    "r",
    "u000e",
    "u000f",
    "u0010",
    "u0011",
    "u0012",
    "u0013",
    "u0014",
    "u0015",
    "u0016",
    "u0017",
    "u0018",
    "u0019",
    "u001a",
    "u001b",
    "u001c",
    "u001d",
    "u001e",
    "u001f",
  }
  for _, escape in ipairs(expected_escapes) do
    expected_parts[#expected_parts + 1] = slash .. escape
  end
  expected_parts[#expected_parts + 1] = string.char(34)
  local expected = table.concat(expected_parts)
  local encoded = encoder:encode(controls)
  equal(encoded, expected)
  check(string.find(encoded, string.char(0), 1, true) == nil, "encoded string contains a literal NUL")
  check(string.find(encoded, string.char(10), 1, true) == nil, "encoded string contains a literal LF")
  check(string.find(encoded, string.char(13), 1, true) == nil, "encoded string contains a literal CR")

  local raw = string.char(32, 127, 192, 175)
  equal(encoder:encode(raw), string.char(34) .. raw .. string.char(34))
  local quote_and_slash = "quote" .. string.char(92) .. string.char(34) .. "slash" .. string.char(92) .. string.char(92)
  local expected_quote_and_slash = string.char(34) .. quote_and_slash .. string.char(34)
  equal(encoder:encode('quote"slash\\'), expected_quote_and_slash)
end)

succeeds("JSON tables have deterministic object and strict array shapes", function()
  local encoder = new_encoder()
  equal(encoder:encode({ z = 3, a = 1, middle = null }), '{"a":1,"middle":null,"z":3}')
  equal(encoder:encode({ { value = 1 }, "two", false }), '[{"value":1},"two",false]')
  equal(encoder:encode({}), "{}")

  local valid_array = { [1] = "one", [2] = null, [3] = true }
  equal(encoder:encode(valid_array), '["one",null,true]')

  local mixed = { [1] = "one", name = "mixed" }
  fails(function()
    return encoder:encode(mixed)
  end, "mixed")

  local sparse = { [1] = "one", [3] = "three" }
  fails(function()
    return encoder:encode(sparse)
  end, "contiguous")

  for _, invalid in ipairs({
    { [0] = "zero" },
    { [-1] = "negative" },
    { [1.5] = "fractional" },
    { [true] = "boolean key" },
    { [{}] = "table key" },
  }) do
    fails(function()
      return encoder:encode(invalid)
    end, "keys")
  end
end)

succeeds("JSON rejects nil, non-finite numbers, cycles, unsupported values, and metatables", function()
  local encoder = new_encoder()
  fails(function()
    return encoder:encode(nil)
  end, "nil")
  fails(function()
    return encoder:encode(math.huge)
  end, "non-finite")
  fails(function()
    return encoder:encode(-math.huge)
  end, "non-finite")
  fails(function()
    return encoder:encode(0 / 0)
  end, "non-finite")

  local cyclic = {}
  cyclic.self = cyclic
  fails(function()
    return encoder:encode(cyclic)
  end, "cyclic")

  fails(function()
    return encoder:encode(function() end)
  end, "function")
  fails(function()
    return encoder:encode(coroutine.create(function() end))
  end, "thread")
  fails(function()
    return encoder:encode(newproxy(true))
  end, "userdata")

  local metatable_value = setmetatable({ value = 1 }, {})
  fails(function()
    return encoder:encode(metatable_value)
  end, "metatable")
end)

succeeds("finite numbers use valid JSON number grammar", function()
  local encoder = new_encoder()
  equal(encoder:encode(0), "0")
  equal(encoder:encode(-2), "-2")
  equal(encoder:encode(1.5), "1.5")
  equal(encoder:encode(100000000000000000000), "1e+020")
  equal(encoder:encode(0.000001), "9.9999999999999995e-007")
end)

succeeds("NDJSON construction validates dependencies and refuses existing paths", function()
  local encoder = new_encoder()
  local path = new_temporary_path("existing")
  local file, open_error = real_io.open(path, "wb")
  check(file ~= nil, open_error)
  local close_ok, close_error = file:close()
  check(close_ok ~= nil, close_error)

  fails(function()
    return ndjson_sink.new({ path = path, encoder = encoder, io = real_io })
  end, "already exists")
  os.remove(path)

  fails(function()
    return ndjson_sink.new({ path = path, io = real_io })
  end, "encoder")
  fails(function()
    return ndjson_sink.new({ path = path, encoder = encoder, io = {} })
  end, "injected io")
  fails(function()
    return ndjson_sink.new({ path = path, encoder = encoder })
  end, "injected io")
end)

succeeds("NDJSON performs two exact binary appends with falsey successful I/O returns", function()
  with_temporary_path("falsey", function(path)
    local calls = 0
    local encoder = {
      encode = function(_, event)
        calls = calls + 1
        return new_encoder():encode(event)
      end,
    }
    local sink, creation_error = ndjson_sink.new({
      path = path,
      encoder = encoder,
      io = make_falsey_io(),
    })
    check(sink ~= nil, creation_error)
    equal(sink:path(), path)

    local first, first_error = sink:write({ b = 2, a = "first" })
    check(first, first_error)
    local second, second_error = sink:write({ b = 3, a = "second" })
    check(second, second_error)
    equal(calls, 2)

    equal(read_all(path), '{"a":"first","b":2}' .. string.char(10) .. '{"a":"second","b":3}' .. string.char(10))
  end)
end)

succeeds("NDJSON verifies complete DCS-style files when seek is unavailable", function()
  with_temporary_path("no-seek", function(path)
    local sink, creation_error = ndjson_sink.new({
      path = path,
      encoder = new_encoder(),
      io = make_no_seek_io(),
    })
    check(sink ~= nil, creation_error)

    local first, first_error = sink:write({ sequence = 1 })
    check(first, first_error)
    local second, second_error = sink:write({ sequence = 2 })
    check(second, second_error)
    equal(read_all(path), '{"sequence":1}\n{"sequence":2}\n')
  end)
end)

succeeds("NDJSON readback mismatch permanently faults the sink", function()
  with_temporary_path("corruption", function(path)
    local state = { corrupt = false }
    local sink, creation_error = ndjson_sink.new({
      path = path,
      encoder = new_encoder(),
      io = make_corrupting_io(state),
    })
    check(sink ~= nil, creation_error)
    state.corrupt = true

    local first, first_error = sink:write({ value = "first" })
    check(first == nil, "corrupted readback unexpectedly succeeded")
    check(string.find(first_error, "faulted", 1, true) ~= nil, first_error)
    local second, second_error = sink:write({ value = "second" })
    check(second == nil, "faulted sink accepted a later write")
    check(string.find(second_error, "permanently faulted", 1, true) ~= nil, second_error)
  end)
end)

succeeds("NDJSON I/O failure permanently faults the sink", function()
  with_temporary_path("io-failure", function(path)
    local state = { fail_write = true }
    local sink, creation_error = ndjson_sink.new({
      path = path,
      encoder = new_encoder(),
      io = make_failing_write_io(state),
    })
    check(sink ~= nil, creation_error)

    local first, first_error = sink:write({ value = "first" })
    check(first == nil, "failed write unexpectedly succeeded")
    check(string.find(first_error, "faulted", 1, true) ~= nil, first_error)
    local second, second_error = sink:write({ value = "second" })
    check(second == nil, "faulted sink accepted a later write")
    check(string.find(second_error, "permanently faulted", 1, true) ~= nil, second_error)
  end)
end)

succeeds("NDJSON encode failure happens before disk access and does not fault", function()
  with_temporary_path("encode-failure", function(path)
    local attempts = 0
    local encoder = {
      encode = function(_, event)
        attempts = attempts + 1
        if event.fail then
          return nil, "intentional encode failure"
        end
        return new_encoder():encode(event)
      end,
    }
    local sink, creation_error = ndjson_sink.new({ path = path, encoder = encoder, io = real_io })
    check(sink ~= nil, creation_error)

    local failed, failed_error = sink:write({ fail = true })
    check(failed == nil, "encode failure unexpectedly succeeded")
    check(string.find(failed_error, "intentional encode failure", 1, true) ~= nil, failed_error)
    local file = real_io.open(path, "rb")
    equal(file, nil, "encode failure created the target")

    local succeeded_write, succeeded_error = sink:write({ value = "after failure" })
    check(succeeded_write, succeeded_error)
    equal(attempts, 2)
    equal(read_all(path), '{"value":"after failure"}' .. string.char(10))
  end)
end)

for _, path in ipairs(temporary_paths) do
  os.remove(path)
end

if #failures > 0 then
  real_io.stderr:write(table.concat(failures, "\n") .. "\n")
  error(string.format("%d of %d JSON/sink tests failed", #failures, tests_run))
end

real_io.write(string.format("JSON/sink Lua tests: %d passed\n", tests_run))

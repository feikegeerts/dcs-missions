-- Build-time only: inspect editor data in an empty Lua 5.1 sandbox.
local input, root, output = assert(arg[1]), assert(arg[2]), assert(arg[3])
local sandbox = {}
local chunk = assert(loadfile(input))
setfenv(chunk, sandbox)
debug.sethook(function()
  error("Lua data evaluation budget exceeded")
end, "", 1000000)
local ok, err = pcall(chunk)
debug.sethook()
assert(ok, err)
local function quote(text)
  return '"'
    .. text:gsub('[%z\1-\31\\"]', function(char)
      if char == '"' then
        return '\\"'
      end
      if char == "\\" then
        return "\\\\"
      end
      return string.format("\\u%04x", char:byte())
    end)
    .. '"'
end
local active = {}
local function encode(value, depth)
  depth = depth or 0
  assert(depth < 100, "Data nesting limit exceeded")
  local kind = type(value)
  if kind == "string" then
    return quote(value)
  end
  if kind == "boolean" then
    return tostring(value)
  end
  if kind == "number" then
    assert(value == value and math.abs(value) ~= math.huge, "Non-finite data")
    return string.format("%.17g", value)
  end
  assert(kind == "table", "Only data tables are allowed")
  assert(not active[value], "Cyclic data table")
  active[value] = true
  local count, array = 0, #value > 0
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= "number" or key < 1 or key > #value or key % 1 ~= 0 then
      array = false
    end
  end
  array = array and count == #value
  local parts = {}
  if array then
    for _, item in ipairs(value) do
      parts[#parts + 1] = encode(item, depth + 1)
    end
    active[value] = nil
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local seen = {}
  for key, item in pairs(value) do
    key = tostring(key)
    assert(not seen[key], "Ambiguous JSON key")
    seen[key] = true
    parts[#parts + 1] = quote(key) .. ":" .. encode(item, depth + 1)
  end
  table.sort(parts)
  active[value] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end
-- assert returns all its arguments in Lua 5.1: isolate the root so the error
-- message cannot accidentally become encode's depth argument.
local value = assert(sandbox[root], "Missing data root")
local encoded = encode(value)
local file = assert(io.open(output, "wb"))
file:write(encoded, "\n")
file:close()

-- Exercise the installed editor's actual DTC setData functions without GUI/DCS.
local install, fixture = assert(arg[1]), assert(arg[2])
local supplied = {}
local chunk = assert(loadfile(fixture))
setfenv(chunk, supplied)
chunk()
local function equal(a, b, path)
  path = path or "points"
  if type(a) ~= type(b) then
    print("DTC native mismatch " .. path .. ": " .. tostring(a) .. " / " .. tostring(b))
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for key, value in pairs(a) do
    if not equal(value, b[key], path .. "." .. tostring(key)) then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end
local function json_arrays(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  -- The fixture serializer emits explicit numeric keys. JSON decoding instead
  -- builds sequential array storage; the native Viper importer uses pairs plus
  -- indexed table.insert, so reproduce the actual JSON array representation.
  for index, item in ipairs(value) do
    result[index] = json_arrays(item)
  end
  for key, item in pairs(value) do
    if type(key) ~= "number" or key < 1 or key > #value then
      result[key] = json_arrays(item)
    end
  end
  return result
end
for _, spec in ipairs({
  { key = "hornet", folder = "FA-18C", file = "FA-18C_hornet", partition = "SA", points = "MEZ_THRTS" },
  { key = "viper", folder = "F-16C", file = "F-16C_50", partition = "MPD", points = "THREAT_PTS" },
}) do
  local file =
    assert(io.open(install .. "/CoreMods/aircraft/" .. spec.folder .. "/DTC/" .. spec.file .. "_DTC.lua", "rb"))
  local source = file:read("*a")
  file:close()
  local start = assert(source:find("function setData(tbl)", 1, true))
  local stop = assert(source:find("\nfunction ", start + 1, true))
  local env = {
    pairs = pairs,
    ipairs = ipairs,
    next = next,
    type = type,
    tostring = tostring,
    tonumber = tonumber,
    table = table,
    math = math,
    string = string,
    data = {
      type = spec.file,
      name = "",
      terrain = "Syria",
      SA = { MEZ_THRTS = {}, CAP_PTS = {}, CORRIDORS = {}, FAOR_FLOT = {}, SETTINGS = {} },
      MPD = { THREAT_PTS = {}, NAV_PTS = {}, DEST = {}, GEO_LINES = {}, VIPVRP = {} },
    },
    isDTCVisible = function()
      return false
    end,
    getCurrentTerrainID = function()
      return "Syria"
    end,
  }
  setmetatable(env, {
    __index = function()
      return function() end
    end,
  }) -- GUI-only callbacks.
  local loader = assert(loadstring(source:sub(start, stop - 1)))
  setfenv(loader, env)
  loader()
  local data = json_arrays(assert(supplied.cartridges[spec.key]).data)
  env.setData(data)
  assert(
    equal(env.data[spec.partition][spec.points], data[spec.partition][spec.points]),
    spec.key .. " native point import differs"
  )
  if spec.key == "hornet" then
    assert(env.data.SA.Default_MEZ_THRTS_Level == 1 and env.data.SA.mirror_MEZ_THRTS == false)
    assert(env.data.SA.SETTINGS.DCLTR_SETTINGS.MREJ1.MEZ_Rings)
  else
    assert(env.data.MPD.mirror_THREAT_PTS == false and env.data.MPD.mirror_NAV_PTS == true)
    for _, point in ipairs(env.data.MPD.THREAT_PTS) do
      assert(point.ring and point.elev)
    end
  end
  print(
    spec.key
      .. " installed native DTC importer: "
      .. #env.data[spec.partition][spec.points]
      .. " threat points accepted"
  )
end

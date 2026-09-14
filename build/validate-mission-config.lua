-- Build-only validation. Never execute mission code with the host environment.
local function read_table(path)
  local chunk = assert(loadfile(path))
  local sandbox = {}
  setfenv(chunk, sandbox)
  debug.sethook(function()
    error("table evaluation budget exceeded")
  end, "", 1000000)
  local ok, value = pcall(chunk)
  debug.sethook()
  assert(ok, value)
  return value or sandbox.mission
end
local config = read_table(assert(arg[1]))
assert(config.mission_name == arg[3], "selected mission does not match configuration identity")
local validator = dofile(assert(arg[4]))
assert(validator.validate_templates(config, read_table(assert(arg[2]))))
print("Mission identity and template validation: " .. config.mission_name .. " OK")

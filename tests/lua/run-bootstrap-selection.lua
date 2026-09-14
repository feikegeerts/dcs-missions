local count = 0
local function run(request, current)
  local loaded, errors, reads = {}, {}, {}
  local sandbox = {
    env = {
      info = function() end,
      error = function(message)
        errors[#errors + 1] = message
      end,
    },
  }
  sandbox._G = sandbox
  sandbox.io = {
    open = function(path)
      reads[#reads + 1] = path
      if path:find(".current-mission", 1, true) then
        return {
          read = function()
            return current
          end,
          close = function() end,
        }
      end
    end,
  }
  sandbox.loadfile = function(path)
    loaded[#loaded + 1] = path
    return function() end
  end
  setmetatable(sandbox, { __index = _G })
  local chunk = assert(loadfile("src/bootstrap.lua"))
  setfenv(chunk, sandbox)
  assert(pcall(chunk, request))
  return loaded, errors, reads, sandbox
end
local function test(name, fn)
  local ok, message = pcall(fn)
  assert(ok, name .. ": " .. tostring(message))
  count = count + 1
end

test("named loader ignores stale selector and uses explicit worktree", function()
  local loaded, errors, reads, sandbox =
    run({ mission_name = "duel-dynamic-acm", scripts_root = "C:\\isolated\\src" }, "duel-dynamic-bvr")
  assert(#errors == 0 and #reads == 0)
  assert(loaded[1] == "C:/isolated/src/lib/Moose_.lua")
  assert(loaded[2] == "C:/isolated/src/missions/duel-dynamic-acm/main.lua")
  assert(sandbox.TELEMETRY_SHIPPING_ENABLED == false)
end)
test("named loader without root fails before disk access", function()
  local loaded, errors, reads = run({ mission_name = "duel-dynamic-acm" }, "duel-dynamic-bvr")
  assert(#loaded == 0 and #reads == 0 and #errors == 1)
end)
test("legacy selector remains supported", function()
  local loaded, errors = run(nil, "duel-dynamic")
  assert(#errors == 0 and #loaded == 2)
  assert(loaded[2]:find("missions/duel-dynamic/main.lua", 1, true))
end)
test("expected mission catches stale selector before loading MOOSE", function()
  local loaded, errors =
    run({ scripts_root = "C:/isolated/src", expected_mission = "duel-dynamic-acm" }, "duel-dynamic-bvr")
  assert(#loaded == 0 and #errors == 1)
end)
for _, invalid in ipairs({ "../other", "", "bad/name", "bad\\name", 123 }) do
  test("invalid selection " .. tostring(invalid), function()
    local loaded, errors = run({ mission_name = invalid, scripts_root = "C:/isolated/src" }, "duel-dynamic")
    assert(#loaded == 0 and #errors == 1)
  end)
end
print("bootstrap selection tests: " .. count .. " passed")

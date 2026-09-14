-- Execute the generated shipping payload, not a source facsimile. No DCS launch.
local path = assert(arg[1], "usage: lua5.1 run-shipping-integration.lua <generated main.lua>")
local expected_mission = arg[2] or "duel-dynamic"
local frame_codec = dofile("src/lib/telemetry/bridge_frame.lua")
local chunk = assert(loadfile(path))
local sandbox = {}
for _, name in ipairs({
  "assert",
  "error",
  "ipairs",
  "pairs",
  "next",
  "pcall",
  "select",
  "tonumber",
  "tostring",
  "type",
  "unpack",
  "setmetatable",
  "getmetatable",
  "rawget",
  "rawset",
  "rawequal",
  "math",
  "string",
  "table",
}) do
  sandbox[name] = _G[name]
end
sandbox._G = sandbox
local diagnostics, schedules = {}, {}
local function diagnostic(message)
  diagnostics[#diagnostics + 1] = message
end
sandbox.env = { info = function() end, warning = diagnostic, error = diagnostic, mission = { theatre = "Caucasus" } }
sandbox.timer = {
  getTime = function()
    return 0
  end,
}
sandbox.coalition = { side = { BLUE = 2, RED = 1 } }
sandbox.EVENTS = {}
for index, name in ipairs({
  "MissionEnd",
  "PlayerEnterAircraft",
  "PlayerLeaveUnit",
  "Dead",
  "Crash",
  "UnitLost",
  "PilotDead",
  "Ejection",
  "Shot",
  "Hit",
  "Kill",
}) do
  sandbox.EVENTS[name] = index
end
sandbox.BASE = {
  New = function()
    return {
      HandleEvent = function(self)
        return self
      end,
      UnHandleEvent = function(self)
        return self
      end,
    }
  end,
}
sandbox.SCHEDULER = {
  New = function(_, _, callback)
    schedules[#schedules + 1] = callback
    return { Remove = function() end }, #schedules
  end,
}
sandbox.MENU_COALITION = {
  New = function()
    return {}
  end,
}
sandbox.MENU_COALITION_COMMAND = {
  New = function()
    return {}
  end,
}
-- An inherited dev flag must not accidentally activate file transport.
sandbox.TELEMETRY_DEVELOPMENT_ENABLED = true
setfenv(chunk, sandbox)
assert(pcall(chunk), "shipping startup raised")
assert(sandbox.TELEMETRY_DEVELOPMENT_ENABLED == false)
assert(sandbox.io == nil and sandbox.os == nil and sandbox.lfs == nil and sandbox.dofile == nil)
local runtime = assert(sandbox.duel_telemetry_bridge, "embedded integration did not publish the hook bridge")
assert(runtime:status().state == "waiting")
assert(runtime:begin("shipping-fixture", "shipping-run"))
local frame = assert(frame_codec.decode(runtime:peek(1, 10)))
assert(frame.count == 1)
assert(frame.lines[1]:find('"mission_name":"' .. expected_mission .. '"', 1, true))
assert(frame.lines[1]:find('"run_classification":"historical"', 1, true))
assert(frame.lines[1]:find('"capabilities"', 1, true), "shipping mission.started omits reporting capabilities")
assert(frame.lines[1]:find('"wave_milestones":1', 1, true))
assert(frame.lines[1]:find('"gameplay_outcome":1', 1, true))
assert(runtime:ack(1))
assert(runtime:peek(2, 10) == "")
assert(#diagnostics == 0, table.concat(diagnostics, "\n"))
assert(sandbox.duel_gameplay_watchers ~= nil, "gameplay watchers not retained")
print("shipping integration sandbox: startup, handshake, identity, ACK and no-filesystem checks passed")

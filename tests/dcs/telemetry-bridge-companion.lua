-- Controlled companion hook for the disposable Slice 3 callback-coexistence test.

local SUBSYSTEM = "TELEMETRY_BRIDGE_COMPANION"
local generation = 0
local frames = 0

local function write(message, ...)
  log.write(SUBSYSTEM, log.INFO, message, ...)
end

local callbacks = {
  onSimulationStart = function()
    generation = generation + 1
    frames = 0
    write("START generation=%d", generation)
  end,
  onSimulationFrame = function()
    frames = frames + 1
    if frames == 1 then
      write("FRAME PASS generation=%d", generation)
    end
  end,
  onSimulationStop = function()
    write("STOP generation=%d frames=%d", generation, frames)
  end,
}

local callback_api = nil
local api_name = nil
if type(Sim) == "table" and type(Sim.setUserCallbacks) == "function" then
  callback_api = Sim
  api_name = "Sim"
elseif type(DCS) == "table" and type(DCS.setUserCallbacks) == "function" then
  callback_api = DCS
  api_name = "DCS"
end

if callback_api then
  callback_api.setUserCallbacks(callbacks)
  write("LOAD PASS callback_api=%s", api_name)
else
  write("LOAD FAIL callback API unavailable DCS=%s Sim=%s", type(DCS), type(Sim))
end

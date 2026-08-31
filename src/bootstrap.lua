-- src/bootstrap.lua — dev-mode dispatcher.
-- Loaded by every .miz's MISSION START trigger (one-liner that does
-- assert(loadfile(SRC .. "bootstrap.lua"))() with the project path).
--
-- Reads .current-mission to know which mission is active, then loads:
--   1. lib/Moose_.lua              (framework — always)
--   2. missions/<name>/main.lua    (mission entry)
--
-- The mission's main.lua is responsible for loading any siblings
-- (score.lua, spawn.lua, ...) using _G.MY_SCRIPTS_ROOT.
--
-- To switch missions: edit .current-mission (one line) and restart the
-- mission. No editor, no git branch, no repack.

env.info("[bootstrap] start")

-- Resolve project root. In dev, always the hardcoded project path; the
-- lfs.writedir branch is a courtesy for users who co-locate scripts in
-- Saved Games\DCS\MyMissions\ (the VEAF pattern).
local function resolveRoot()
  if lfs and lfs.writedir then
    local p = lfs.writedir() .. "MyMissions\\"
    local f = io.open(p .. "lib\\Moose_.lua", "r")
    if f then
      f:close()
      return p
    end
  end
  return [[C:\Projects\dcs-missions\src\]]
end

local ROOT = resolveRoot()
_G.MY_SCRIPTS_ROOT = ROOT
_G.TELEMETRY_DEVELOPMENT_ENABLED = true
env.info("[bootstrap] root: " .. ROOT)

-- Read active mission name from .current-mission.
local missionName
do
  local f = io.open(ROOT .. ".current-mission", "r")
  if f then
    local line = f:read("*l")
    f:close()
    if line then
      missionName = line:match("^%s*(.-)%s*$")
    end
  end
end
if not missionName or missionName == "" then
  env.error("[bootstrap] no active mission: write a name to .current-mission")
  return
end
env.info("[bootstrap] mission: " .. missionName)

-- Load a file relative to ROOT, with logging + error trapping.
local function loadRel(rel)
  env.info("[bootstrap] loading " .. rel)
  local path = ROOT .. rel
  local ok, err = pcall(function()
    assert(loadfile(path))()
  end)
  if not ok then
    env.error("[bootstrap] " .. rel .. ": " .. tostring(err))
    return false
  end
  return true
end

-- Framework (always).
if not loadRel("lib/Moose_.lua") then
  return
end

-- Mission entry.
local missionMain = "missions/" .. missionName .. "/main.lua"
if not loadRel(missionMain) then
  env.error("[bootstrap] mission '" .. missionName .. "' has no main.lua at " .. missionMain)
  return
end

env.info("[bootstrap] done")

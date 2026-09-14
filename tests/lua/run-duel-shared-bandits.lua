-- tests/lua/run-duel-shared-bandits.lua
--
-- Standalone Lua 5.1 regression test for the package-wave lifecycle in
-- src/missions/duel-dynamic/main.lua.  The mocks below deliberately expose
-- only the DCS/MOOSE surface used by that file.
--
-- The mission picks a uniform-random donor from the next wave's difficulty
-- tier per wave with a per-wave random altitude/speed/distance profile, and
-- it defers group options to the ME.  Bandit-7 is excluded from waves.  The
-- assertions below cover that design plus the package lifecycle, including
-- graceful degradation when a donor's SPAWN:New returns nil (e.g.
-- uninstalled module).
--
-- Run from the repository root:
--   lua5.1 tests/lua/run-duel-shared-bandits.lua

local tests_run = 0
local failures = {}

local function check(condition, message)
  if not condition then
    error(message or "assertion failed", 2)
  end
end

local function equal(actual, expected, message)
  check(
    actual == expected,
    string.format("%s: got %s, expected %s", message or "values differ", tostring(actual), tostring(expected))
  )
end

local function succeeds(name, callback)
  tests_run = tests_run + 1
  local ok, message = pcall(callback)
  if not ok then
    failures[#failures + 1] = name .. ": " .. tostring(message)
  end
end

local BLUE = 2
local RED = 1
local MIN_SEPARATION_M = 55 * 1609.344
local MAX_SEPARATION_M = 85 * 1609.344
local MIN_SPAWN_ALT_M = 15000 * 0.3048
local MAX_SPAWN_ALT_M = 25000 * 0.3048
local MIN_CAP_ALT_FT = 15000
local MAX_CAP_ALT_FT = 30000
local MIN_CAP_SPEED_KT = 350
local MAX_CAP_SPEED_KT = 550
local FOUR_NM_M = 4 * 1852

local PLAYER_GROUP_NAMES = { "Aerial-1", "Aerial-2", "Aerial-3", "Aerial-4", "Aerial-5" }
-- Active donor/telemetry allow-list. Bandit-7 is excluded from waves, so it
-- must never appear here or in any spawned package.
local BANDIT_GROUP_NAMES = {
  "Bandit-1",
  "Bandit-2",
  "Bandit-3",
  "Bandit-4",
  "Bandit-5",
  "Bandit-6",
  "Bandit-8",
  "Bandit-9",
  "Bandit-10",
}

-- Mirror of WAVE_DONOR_TIERS in src/missions/duel-dynamic/main.lua, keyed
-- by the next wave number (waveNumber + 1) in steps of WAVE_TIER_EVERY = 3.
local WAVE_TIER_EVERY = 3
local WAVE_DONOR_TIERS = {
  { "Bandit-10", "Bandit-3", "Bandit-6" },
  { "Bandit-3", "Bandit-6", "Bandit-4", "Bandit-5" },
  { "Bandit-1", "Bandit-2", "Bandit-4", "Bandit-5", "Bandit-8", "Bandit-9" },
}

local function tierForWave(nextWaveNumber)
  local tier = math.floor((nextWaveNumber - 1) / WAVE_TIER_EVERY) + 1
  if tier < 1 then
    tier = 1
  end
  if tier > #WAVE_DONOR_TIERS then
    tier = #WAVE_DONOR_TIERS
  end
  return tier
end

local function inTier(template, tier)
  for _, donor in ipairs(WAVE_DONOR_TIERS[tier]) do
    if template == donor then
      return true
    end
  end
  return false
end

local function isBanditDonor(name)
  for _, donor in ipairs(BANDIT_GROUP_NAMES) do
    if name == donor then
      return true
    end
  end
  return false
end

-- =====================================================================
-- Bounded DCS/MOOSE mocks
-- =====================================================================

-- The coordinate mock follows DCS's heading convention: heading zero points
-- north (+z), and heading increases clockwise toward +x.  This lets the
-- geometry assertion check the intended anchor-to-centroid direction without
-- relying on a real terrain or world object.
local function newCoordinate(x, y, z)
  local coordinate = { x = x, y = y, z = z }

  function coordinate:Translate(distance, heading)
    local radians = heading * math.pi / 180
    return newCoordinate(self.x + distance * math.sin(radians), self.y, self.z + distance * math.cos(radians))
  end

  function coordinate:SetY(value)
    self.y = value
    return self
  end

  function coordinate:GetVec3()
    return { x = self.x, y = self.y, z = self.z }
  end

  function coordinate:GetVec2()
    return { x = self.x, y = self.z }
  end

  function coordinate:Get2DDistance(other)
    local dx = other.x - self.x
    local dz = other.z - self.z
    return math.sqrt(dx * dx + dz * dz)
  end

  return coordinate
end

local COORDINATE = {}
function COORDINATE:New(x, y, z)
  return newCoordinate(x, y, z)
end

local playerAlive = {
  ["Aerial-1"] = true,
  ["Aerial-2"] = false,
  ["Aerial-3"] = true,
  ["Aerial-4"] = false,
  ["Aerial-5"] = false,
}

local playerCoords = {
  ["Aerial-1"] = newCoordinate(200000, 0, 100000),
  ["Aerial-2"] = newCoordinate(250000, 0, 150000),
  ["Aerial-3"] = newCoordinate(150000, 0, 50000),
  ["Aerial-4"] = newCoordinate(175000, 0, 125000),
  ["Aerial-5"] = newCoordinate(225000, 0, 75000),
}

local playerGroups = {}
for _, name in ipairs(PLAYER_GROUP_NAMES) do
  local dcsUnit = {}
  function dcsUnit:setPosition(_, _)
    -- The mission randomizes player headings during deferred init.  The
    -- position itself is intentionally not changed by this mock.
  end

  local dcsGroup = {}
  function dcsGroup:getUnits()
    return { dcsUnit }
  end

  local group = {}
  function group:GetName()
    return name
  end
  function group:IsAlive()
    return playerAlive[name]
  end
  function group:GetCoordinate()
    if not playerAlive[name] then
      return nil
    end
    return playerCoords[name]
  end
  function group:GetDCSObject()
    return dcsGroup
  end

  playerGroups[name] = group
end

local GROUP = {}
function GROUP:FindByName(name)
  return playerGroups[name]
end

local function copyRelativePositions(positions)
  local copy = {}
  for i, position in ipairs(positions or {}) do
    copy[i] = { x = position.x, y = position.y, heading = position.heading }
  end
  return copy
end

local function copyCoordinate(coordinate)
  return newCoordinate(coordinate.x, coordinate.y, coordinate.z)
end

local function newBanditWrapper(name, spawnCoord, grouping, relativePositions, heading)
  local wrapper = {
    name = name,
    spawnCoord = spawnCoord,
    grouping = grouping,
    unit_count = grouping,
    relative_positions = copyRelativePositions(relativePositions),
    heading = heading,
    options = {},
    destroyed = false,
    destroy_count = 0,
    units = {},
  }

  for i = 1, grouping do
    local relative = relativePositions[i] or { x = 0, y = 0, heading = heading }
    local unit = {
      name = string.format("%s-unit-%02d", name, i),
      alive = true,
      heading = relative.heading or heading,
      coordinate = newCoordinate(spawnCoord.x + relative.x, spawnCoord.y, spawnCoord.z + relative.y),
    }
    function unit:GetName()
      return self.name
    end
    function unit:IsAlive()
      return self.alive
    end
    wrapper.units[i] = unit
  end

  function wrapper:GetName()
    return self.name
  end
  function wrapper:IsAlive()
    if self.destroyed then
      return false
    end
    for _, unit in ipairs(self.units) do
      if unit.alive then
        return true
      end
    end
    return false
  end
  function wrapper:GetCoordinate()
    return self.spawnCoord
  end
  function wrapper:Destroy(_)
    if self.destroyed then
      return
    end
    self.destroyed = true
    self.destroy_count = self.destroy_count + 1
    for _, unit in ipairs(self.units) do
      unit.alive = false
    end
  end
  function wrapper:OptionROEOpenFireWeaponFree()
    self.options.roe = "WEAPON_FREE"
  end
  function wrapper:OptionAlarmStateRed()
    self.options.alarm = "RED"
  end
  function wrapper:OptionROTEvadeFire()
    self.options.rot = "EVADE_FIRE"
  end
  function wrapper:KillUnit(unitName)
    for _, unit in ipairs(self.units) do
      if unit.name == unitName then
        unit.alive = false
        return true
      end
    end
    return false
  end

  return wrapper
end

local spawnRecords = {}
local allWrappers = {}
local spawnersByTemplate = {}
local constructedSpawners = {}

local SPAWN = { failTemplates = {}, newCalls = {} }
function SPAWN:New(templateName)
  SPAWN.newCalls[#SPAWN.newCalls + 1] = templateName
  if SPAWN.failTemplates[templateName] then
    return nil
  end
  local spawner = {
    template = templateName,
    grouping = nil,
    relative_positions = nil,
    heading = nil,
    grouping_calls = {},
    relative_position_calls = {},
    heading_calls = {},
    on_spawn_group = nil,
  }

  function spawner:InitGrouping(grouping)
    self.grouping = grouping
    self.grouping_calls[#self.grouping_calls + 1] = grouping
    return self
  end
  function spawner:InitSetUnitRelativePositions(relativePositions)
    self.relative_positions = copyRelativePositions(relativePositions)
    self.relative_position_calls[#self.relative_position_calls + 1] = copyRelativePositions(relativePositions)
    return self
  end
  function spawner:InitHeading(heading)
    self.heading = heading
    self.heading_calls[#self.heading_calls + 1] = heading
    return self
  end
  function spawner:OnSpawnGroup(callback)
    self.on_spawn_group = callback
    return self
  end
  function spawner:SpawnFromCoordinate(spawnCoord)
    local generation = #spawnRecords + 1
    local name = string.format("%s#%03d", self.template, generation)
    local grouping = self.grouping or 1
    local positions = copyRelativePositions(self.relative_positions or {})
    local wrapper = newBanditWrapper(name, spawnCoord, grouping, positions, self.heading)
    local record = {
      template = self.template,
      grouping = grouping,
      relative_positions = positions,
      heading = self.heading,
      coordinate = copyCoordinate(spawnCoord),
      wrapper = wrapper,
    }
    spawnRecords[#spawnRecords + 1] = record
    allWrappers[#allWrappers + 1] = wrapper
    if self.on_spawn_group then
      self.on_spawn_group(wrapper)
    end
    return wrapper
  end

  spawnersByTemplate[templateName] = spawner
  constructedSpawners[#constructedSpawners + 1] = spawner
  return spawner
end

-- Schedules are never driven automatically.  Tests select them by delay and
-- execution state, then run a callback exactly once with runSchedule().
local schedules = {}
local SCHEDULER = {}
function SCHEDULER:New(_, callback, args, startAfter, repeatInterval, count, stopAfter)
  local schedule = {
    callback = callback,
    args = args or {},
    start_after = startAfter,
    repeat_interval = repeatInterval,
    count = count,
    stop_after = stopAfter,
    executed = false,
  }
  schedules[#schedules + 1] = schedule
  return schedule, #schedules
end

local EVENTS = {
  PlayerEnterAircraft = "PlayerEnterAircraft",
  PlayerLeaveUnit = "PlayerLeaveUnit",
  Dead = "Dead",
  Crash = "Crash",
}

local watchers = {}
local BASE = {}
function BASE:New()
  local watcher = { handled_events = {} }
  function watcher:HandleEvent(event)
    self.handled_events[#self.handled_events + 1] = event
  end
  watchers[#watchers + 1] = watcher
  return watcher
end

local coalition = {
  side = { NEUTRAL = 0, RED = RED, BLUE = BLUE },
}

local menus = {}
local MENU_COALITION = {}
function MENU_COALITION:New(side, title)
  local menu = { side = side, title = title }
  menus[#menus + 1] = menu
  return menu
end

local menuCommands = {}
local MENU_COALITION_COMMAND = {}
function MENU_COALITION_COMMAND:New(side, title, parentMenu, callback)
  local command = { side = side, title = title, parent = parentMenu, callback = callback }
  menuCommands[title] = command
  return command
end

local messages = {}
local MESSAGE = {}
function MESSAGE:New(text, duration)
  local message = { text = text, duration = duration }
  function message:ToCoalition(side)
    messages[#messages + 1] = { text = self.text, duration = self.duration, side = side }
    return self
  end
  return message
end

local flightGroups = {}
local FLIGHTGROUP = {}
function FLIGHTGROUP:New(banditGroup)
  local flightGroup = { bandit_group = banditGroup, missions = {} }
  function flightGroup:AddMission(mission)
    self.missions[#self.missions + 1] = mission
    return self
  end
  flightGroups[#flightGroups + 1] = flightGroup
  return flightGroup
end

local auftrags = {}
local interceptAuftrags = {}
local AUFTRAG = {}
function AUFTRAG:NewCAP(zone, altitude, speed)
  -- Like the real AUFTRAG:NewCAP, bake optionROE + optionROT first.  The
  -- mission must nil them out (defer-to-ME) before handing the mission to
  -- the flight group.
  local mission = {
    kind = "CAP",
    zone = zone,
    altitude = altitude,
    speed = speed,
    optionROE = "BAKED_ROE",
    optionROT = "BAKED_ROT",
  }
  auftrags[#auftrags + 1] = mission
  return mission
end
function AUFTRAG:NewINTERCEPT(targetGroup)
  local mission = { kind = "INTERCEPT", target = targetGroup, optionROE = "BAKED_ROE", optionAlarm = "BAKED_ALARM" }
  interceptAuftrags[#interceptAuftrags + 1] = mission
  return mission
end

local zones = {}
local ZONE_RADIUS = {}
function ZONE_RADIUS:New(name, center, radius)
  local zone = { name = name, center = center, radius = radius }
  zones[#zones + 1] = zone
  return zone
end

local ENUMS = {
  ROE = { OpenFireWeaponFree = "OpenFireWeaponFree" },
  AlarmState = { Red = "Red" },
}

local logs = {}
local env = {}
local function recordLog(level, message)
  logs[#logs + 1] = { level = level, message = tostring(message) }
end
function env.info(message)
  recordLog("INFO", message)
end
function env.warning(message)
  recordLog("WARNING", message)
end
function env.error(message)
  recordLog("ERROR", message)
end

-- Mock telemetry asset adapter: records the configured (donor) name each
-- spawned wave is registered with, so the test can assert the ACTUAL donor
-- name is passed instead of a fixed template name.
local assetRegistrations = {}
local playerRegistrations = {}
local despawnCalls = {}
local mockAssetAdapter = {}
function mockAssetAdapter.register_bandit_group(adapterSelf, group, configured_name, sim_time)
  assetRegistrations[#assetRegistrations + 1] = { group_name = group:GetName(), configured_name = configured_name }
  return { { asset_key = "mock.u1.g1" } }
end
function mockAssetAdapter.register_player_group(adapterSelf, group)
  playerRegistrations[#playerRegistrations + 1] = { group_name = group:GetName() }
  return { asset_key = "mock-player" }
end
function mockAssetAdapter.despawn_group(adapterSelf, group)
  despawnCalls[#despawnCalls + 1] = { group_name = group:GetName() }
  return true
end

-- =====================================================================
-- Install mocks and provide restoration even when assertions fail.
-- =====================================================================

local GLOBAL_NAMES = {
  "env",
  "BASE",
  "SCHEDULER",
  "EVENTS",
  "GROUP",
  "COORDINATE",
  "SPAWN",
  "MENU_COALITION",
  "MENU_COALITION_COMMAND",
  "MESSAGE",
  "FLIGHTGROUP",
  "AUFTRAG",
  "ZONE_RADIUS",
  "ENUMS",
  "coalition",
  "MY_SCRIPTS_ROOT",
  "TELEMETRY_DEVELOPMENT_ENABLED",
  "duel_tracker",
  "duel_telemetry_runtime",
  "duel_gameplay_watchers",
}

local savedGlobals = {}
for _, name in ipairs(GLOBAL_NAMES) do
  savedGlobals[name] = _G[name]
end

_G.env = env
_G.BASE = BASE
_G.SCHEDULER = SCHEDULER
_G.EVENTS = EVENTS
_G.GROUP = GROUP
_G.COORDINATE = COORDINATE
_G.SPAWN = SPAWN
_G.MENU_COALITION = MENU_COALITION
_G.MENU_COALITION_COMMAND = MENU_COALITION_COMMAND
_G.MESSAGE = MESSAGE
_G.FLIGHTGROUP = FLIGHTGROUP
_G.AUFTRAG = AUFTRAG
_G.ZONE_RADIUS = ZONE_RADIUS
_G.ENUMS = ENUMS
_G.coalition = coalition
_G.MY_SCRIPTS_ROOT = "src/"
_G.TELEMETRY_DEVELOPMENT_ENABLED = false
_G.duel_telemetry_runtime = { asset = mockAssetAdapter }

local function restoreGlobals()
  for _, name in ipairs(GLOBAL_NAMES) do
    if savedGlobals[name] == nil then
      _G[name] = nil
    else
      _G[name] = savedGlobals[name]
    end
  end
end

-- =====================================================================
-- Scenario helpers
-- =====================================================================

local function runSchedule(schedule)
  check(schedule ~= nil, "expected a matching scheduler callback")
  check(not schedule.executed, "attempted to execute a scheduler callback twice")
  schedule.executed = true
  return schedule.callback(unpack(schedule.args))
end

local function findPendingSchedule(startAfter, isRepeating)
  local found = nil
  for _, schedule in ipairs(schedules) do
    local repeats = schedule.repeat_interval ~= nil
    if not schedule.executed and schedule.start_after == startAfter and repeats == isRepeating then
      check(found == nil, "more than one matching pending scheduler callback")
      found = schedule
    end
  end
  return found
end

local function pendingOneShotSchedules(startAfter)
  local pending = {}
  for _, schedule in ipairs(schedules) do
    if not schedule.executed and schedule.start_after == startAfter and schedule.repeat_interval == nil then
      pending[#pending + 1] = schedule
    end
  end
  return pending
end

local function countSchedules(startAfter, includeExecuted)
  local count = 0
  for _, schedule in ipairs(schedules) do
    if schedule.start_after == startAfter and (includeExecuted or not schedule.executed) then
      count = count + 1
    end
  end
  return count
end

local function liveWrappers()
  local live = {}
  for _, wrapper in ipairs(allWrappers) do
    if wrapper:IsAlive() then
      live[#live + 1] = wrapper
    end
  end
  return live
end

local function arithmeticCentroid(firstName, secondName)
  local first = playerCoords[firstName]
  local second = playerCoords[secondName]
  return newCoordinate((first.x + second.x) / 2, (first.y + second.y) / 2, (first.z + second.z) / 2)
end

local function findWatcher(event)
  for _, watcher in ipairs(watchers) do
    for _, handledEvent in ipairs(watcher.handled_events) do
      if handledEvent == event then
        return watcher
      end
    end
  end
  return nil
end

local function hasExactlyEvents(watcher, first, second)
  if not watcher or #watcher.handled_events ~= 2 then
    return false
  end
  return watcher.handled_events[1] == first and watcher.handled_events[2] == second
end

local function firePlayerEvent(watcher, method, groupName, playerName, playerUCID)
  playerAlive[groupName] = method == "OnEventPlayerEnterAircraft"
  local eventData = {
    IniGroupName = groupName,
    IniDCSGroupName = groupName,
    IniPlayerName = playerName,
    IniPlayerUCID = playerUCID,
    IniCoalition = BLUE,
  }
  local ok, message = pcall(watcher[method], watcher, eventData)
  check(ok, method .. " raised: " .. tostring(message))
end

local function dispatchCurrentGameplayEvent(method, eventData)
  local retained = _G.duel_gameplay_watchers
  check(type(retained) == "table", "current gameplay watcher retention table is missing")
  for _, watcher in pairs(retained) do
    local callback = watcher[method]
    if callback then
      local ok, message = pcall(callback, watcher, eventData)
      check(ok, method .. " raised: " .. tostring(message))
    end
  end
end

local function firePlayerLoss(method, groupName, unitName, side, objectId)
  local dcsUnit = {}
  function dcsUnit:getID()
    return objectId or unitName
  end
  dispatchCurrentGameplayEvent(method, {
    IniCoalition = side or BLUE,
    IniGroup = playerGroups[groupName],
    IniDCSGroupName = groupName,
    IniDCSUnitName = unitName,
    IniDCSUnit = dcsUnit,
  })
end

local function fireBanditEvent(watcher, method, wrapper, unitName)
  local eventData = {
    IniCoalition = RED,
    IniGroup = wrapper,
    IniDCSUnitName = unitName,
  }
  local ok, message = pcall(function()
    if method == "OnEventDead" then
      wrapper:KillUnit(unitName)
      watcher:OnEventDead(eventData)
    else
      wrapper:KillUnit(unitName)
      watcher:OnEventCrash(eventData)
    end
  end)
  check(ok, method .. " raised: " .. tostring(message))
end

local function latestSpawn()
  return spawnRecords[#spawnRecords]
end

local function logContains(fragment)
  for _, entry in ipairs(logs) do
    if entry.message:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

local function messageContains(fragment)
  for _, message in ipairs(messages) do
    if message.text:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

local function countExactMessages(text, startIndex)
  local count = 0
  for i = startIndex or 1, #messages do
    if messages[i].text == text then
      count = count + 1
    end
  end
  return count
end

local function latestPendingSchedule(startAfter, isRepeating, startIndex)
  for i = #schedules, (startIndex or 0) + 1, -1 do
    local schedule = schedules[i]
    if
      not schedule.executed
      and schedule.start_after == startAfter
      and (schedule.repeat_interval ~= nil) == isRepeating
    then
      return schedule
    end
  end
  return nil
end

local function setAlivePlayers(names)
  for _, playerName in ipairs(PLAYER_GROUP_NAMES) do
    playerAlive[playerName] = false
  end
  for _, playerName in ipairs(names or {}) do
    playerAlive[playerName] = true
  end
end

local function loadInitializedMission(players)
  setAlivePlayers({})
  local schedulesBefore = #schedules
  local spawnsBefore = #spawnRecords
  local watchersBefore = #watchers
  dofile("src/missions/duel-dynamic/main.lua")
  local retained = _G.duel_gameplay_watchers
  for _, player in ipairs(players) do
    firePlayerEvent(retained.player, "OnEventPlayerEnterAircraft", player.slot, player.name, player.ucid)
  end
  local initSchedule = latestPendingSchedule(1, true, schedulesBefore)
  check(initSchedule ~= nil, "fresh mission init poll scheduler was not captured")
  equal(runSchedule(initSchedule), false, "fresh mission init poll did not stop after initialization")
  local assemblySchedule = latestPendingSchedule(3, false, schedulesBefore)
  check(assemblySchedule ~= nil, "fresh mission assembly scheduler was not captured")
  runSchedule(assemblySchedule)
  equal(#spawnRecords, spawnsBefore + 1, "fresh mission did not spawn its initial package")
  return {
    retained = retained,
    package = latestSpawn().wrapper,
    schedulesBefore = schedulesBefore,
    spawnsBefore = spawnsBefore,
    watchersBefore = watchersBefore,
  }
end

local function liveCentroid()
  local sumX, sumY, sumZ, count = 0, 0, 0, 0
  for _, name in ipairs(PLAYER_GROUP_NAMES) do
    if playerAlive[name] then
      local coord = playerCoords[name]
      sumX = sumX + coord.x
      sumY = sumY + coord.y
      sumZ = sumZ + coord.z
      count = count + 1
    end
  end
  if count == 0 then
    return nil
  end
  return newCoordinate(sumX / count, sumY / count, sumZ / count)
end

local function killPackageFully(deadWatcher, wrapper)
  for _, unit in ipairs(wrapper.units) do
    fireBanditEvent(deadWatcher, "OnEventDead", wrapper, unit.name)
  end
end

local currentPackage = nil

-- =====================================================================
-- Assertions follow the package-wave acceptance scenario.
-- =====================================================================

succeeds("1. deferred init builds one spawner per donor and the assembly spawns one package", function()
  local mainPath = "src/missions/duel-dynamic/main.lua"
  dofile(mainPath)

  equal(#schedules, 1, "main.lua did not register the init poll scheduler")
  local initSchedule = findPendingSchedule(1, true)
  check(initSchedule ~= nil, "init poll scheduler was not captured")
  equal(runSchedule(initSchedule), false, "init poll did not stop after initialization")

  equal(#SPAWN.newCalls, 9, "deferred init did not attempt SPAWN:New for all 9 active donors")
  local attempted = {}
  for _, name in ipairs(SPAWN.newCalls) do
    attempted[name] = true
  end
  check(not attempted["Bandit-7"], "SPAWN:New was attempted for excluded Bandit-7")
  for _, donor in ipairs(BANDIT_GROUP_NAMES) do
    check(attempted[donor], "SPAWN:New was not attempted for " .. donor)
    check(spawnersByTemplate[donor] ~= nil, donor .. " spawner was not constructed")
    check(spawnersByTemplate[donor].on_spawn_group ~= nil, donor .. " OnSpawnGroup callback missing")
  end
  equal(#constructedSpawners, 9, "deferred init constructed an unexpected number of SPAWN objects")
  equal(#spawnRecords, 0, "deferred init spawned before the assembly delay")

  local assemblySchedule = findPendingSchedule(3, false)
  check(assemblySchedule ~= nil, "three-second assembly scheduler was not captured")
  runSchedule(assemblySchedule)

  equal(#spawnRecords, 1, "initial assembly did not spawn exactly one group")
  local spawn = latestSpawn()
  check(isBanditDonor(spawn.template), "initial package used a template outside the active donor list")
  check(
    spawn.wrapper:GetName():find("^Bandit%-%d+#%d%d%d$") ~= nil,
    "package wrapper name is not Bandit-N#NNN, got " .. spawn.wrapper:GetName()
  )
  equal(spawn.grouping, 2, "initial package was not configured as a two-ship group")
  equal(spawn.wrapper.unit_count, 2, "initial package wrapper has the wrong unit count")
  equal(#spawn.wrapper.units, 2, "initial package does not contain two units")
  equal(spawnersByTemplate[spawn.template].grouping_calls[1], 2, "InitGrouping(2) was not applied")
  equal(#assetRegistrations, 1, "initial package did not register exactly one bandit asset")
  equal(
    assetRegistrations[1].configured_name,
    spawn.template,
    "bandit asset registration did not pass the actual donor name"
  )
  equal(assetRegistrations[1].group_name, spawn.wrapper:GetName(), "bandit asset registration has the wrong group")
  currentPackage = spawn.wrapper
end)

succeeds("2. package geometry is a close formation at the configured separation", function()
  local spawn = latestSpawn()
  local centroid = arithmeticCentroid("Aerial-1", "Aerial-3")
  local distance = centroid:Get2DDistance(spawn.coordinate)
  check(distance >= MIN_SEPARATION_M - 0.001, "package anchor is inside the 55 statute-mile minimum")
  check(distance <= MAX_SEPARATION_M + 0.001, "package anchor exceeds the 55–85 statute-mile ring maximum")

  for i, unit in ipairs(spawn.wrapper.units) do
    check(
      spawn.coordinate:Get2DDistance(unit.coordinate) <= FOUR_NM_M,
      "package unit is more than four NM from its anchor"
    )
    check(math.abs(unit.heading - spawn.heading) < 0.0001, "package unit headings do not agree")
    for j = i + 1, #spawn.wrapper.units do
      local other = spawn.wrapper.units[j]
      local separation = unit.coordinate:Get2DDistance(other.coordinate)
      check(unit.name ~= other.name, "relative unit names are not unique")
      check(separation > 0, "relative unit positions are not distinct")
      check(separation <= FOUR_NM_M, "relative red units are more than four NM apart")
    end
  end

  -- With the coordinate convention defined by this mock, the heading vector
  -- should point from the red anchor back toward the blue centroid.
  local dx = centroid.x - spawn.coordinate.x
  local dz = centroid.z - spawn.coordinate.z
  local radians = spawn.heading * math.pi / 180
  local headingX = math.sin(radians)
  local headingZ = math.cos(radians)
  local centroidDistance = math.sqrt(dx * dx + dz * dz)
  local alignment = (dx * headingX + dz * headingZ) / centroidDistance
  check(alignment > 0.99, "package heading does not point back toward the blue centroid")
end)

succeeds("3. the initial package receives one CAP mission at the blue centroid", function()
  equal(#auftrags, 1, "initial package did not receive exactly one AUFTRAG")
  equal(auftrags[1].kind, "CAP", "initial package was not assigned a CAP AUFTRAG")
  equal(#interceptAuftrags, 0, "an INTERCEPT AUFTRAG was created for the CAP package")
  equal(#zones, 1, "initial package did not create exactly one CAP zone")

  local centroid = arithmeticCentroid("Aerial-1", "Aerial-3")
  local center = zones[1].center
  equal(center.x, centroid.x, "CAP zone center x is not the blue centroid")
  equal(center.y, centroid.z, "CAP zone center y is not the blue centroid z")
  equal(zones[1].radius, 150000, "CAP zone does not contain the complete package spawn ring")
end)

succeeds("4. a partial leave keeps combat alive and re-entry is deferred to the next wave", function()
  local playerWatcher = findWatcher(EVENTS.PlayerEnterAircraft)
  check(playerWatcher ~= nil, "player enter/leave watcher is missing")
  local beforeSpawns = #spawnRecords
  local beforeDestroy = currentPackage.destroy_count

  firePlayerEvent(playerWatcher, "OnEventPlayerLeaveUnit", "Aerial-1", "PilotOne")
  local cleanup = findPendingSchedule(1, false)
  check(cleanup ~= nil, "partial leave did not schedule cleanup")
  runSchedule(cleanup)

  equal(currentPackage.destroy_count, beforeDestroy, "partial leave destroyed the live package")
  check(currentPackage:IsAlive(), "package stopped being alive after a partial leave")

  firePlayerEvent(playerWatcher, "OnEventPlayerEnterAircraft", "Aerial-1", "PilotOne")
  equal(#spawnRecords, beforeSpawns, "re-entry during combat spawned or resized a package")
  check(logContains("joining player will be matched in the next wave"), "deferred-to-next-wave log is missing")
end)

succeeds("5. the first unit kill scores once and does not schedule a respawn", function()
  local deadWatcher = findWatcher(EVENTS.Dead)
  check(deadWatcher ~= nil, "dead/crash watcher is missing")
  local firstUnit = currentPackage.units[1]
  local secondUnit = currentPackage.units[2]
  check(firstUnit.name ~= secondUnit.name, "bandit unit names are not unique")
  local tracker = _G.duel_tracker
  local scoreBefore = tracker.total
  local teamScoreBefore = tracker.kills.Team or 0
  local schedulesBefore = #schedules
  local messagesBefore = #messages

  fireBanditEvent(deadWatcher, "OnEventDead", currentPackage, firstUnit.name)
  equal(tracker.total, scoreBefore + 1, "first bandit kill did not increment the team score")
  equal(tracker.kills.Team, teamScoreBefore + 1, "first bandit kill was not recorded for Team")
  equal(#schedules, schedulesBefore, "the first bandit kill scheduled a respawn")
  local killMessage = messages[messagesBefore + 1]
  check(killMessage ~= nil, "first bandit kill did not post a message")
  equal(
    killMessage.text,
    string.format("Bandit down — team %d, 1 hostile left", tracker.total),
    "kill message has the wrong team total or package remainder"
  )

  fireBanditEvent(deadWatcher, "OnEventCrash", currentPackage, firstUnit.name)
  equal(tracker.total, scoreBefore + 1, "duplicate crash event changed the team score")
  equal(tracker.kills.Team, teamScoreBefore + 1, "duplicate crash event changed the Team score")
  equal(#schedules, schedulesBefore, "duplicate crash event changed scheduler state")
  equal(#messages, messagesBefore + 1, "duplicate crash event posted another kill message")
end)

succeeds("6. the completed package schedules one delayed replacement", function()
  local deadWatcher = findWatcher(EVENTS.Dead)
  local secondUnit = currentPackage.units[2]
  local tracker = _G.duel_tracker
  local scoreBefore = tracker.total
  local teamScoreBefore = tracker.kills.Team or 0
  local spawnsBefore = #spawnRecords

  check(playerAlive["Aerial-1"] and playerAlive["Aerial-3"], "both blue players are not alive for the next-wave test")
  fireBanditEvent(deadWatcher, "OnEventDead", currentPackage, secondUnit.name)
  equal(tracker.total, scoreBefore + 1, "second bandit kill did not increment the team score")
  equal(tracker.kills.Team, teamScoreBefore + 1, "second bandit kill was not recorded for Team")
  equal(#spawnRecords, spawnsBefore, "completed package spawned immediately")
  equal(countSchedules(30, false), 1, "completed package did not create exactly one 30-second schedule")

  local respawnSchedule = findPendingSchedule(30, false)
  check(respawnSchedule ~= nil, "30-second package scheduler was not captured")
  runSchedule(respawnSchedule)

  equal(#spawnRecords, spawnsBefore + 1, "delayed package scheduler did not spawn exactly one group")
  local spawn = latestSpawn()
  check(isBanditDonor(spawn.template), "delayed package used a template outside the active donor list")
  equal(spawn.grouping, 2, "delayed package did not retain grouping 2")
  equal(#liveWrappers(), 1, "delayed package did not replace the defeated package")
  currentPackage = spawn.wrapper
end)

succeeds("7. the exact F10 command replaces the active package once", function()
  local command = menuCommands["Respawn bandit wave"]
  check(command ~= nil, "Respawn bandit wave command was not registered")
  local oldPackage = currentPackage
  local beforeSpawns = #spawnRecords
  local beforeDestroy = oldPackage.destroy_count

  local ok, message = pcall(command.callback)
  check(ok, "Respawn bandit wave callback raised: " .. tostring(message))
  equal(oldPackage.destroy_count, beforeDestroy + 1, "F10 did not destroy the current package exactly once")
  equal(#spawnRecords, beforeSpawns + 1, "F10 did not create exactly one replacement package")
  local spawn = latestSpawn()
  equal(spawn.grouping, 2, "F10 replacement did not retain grouping 2")
  check(spawn.wrapper ~= oldPackage, "F10 reused the destroyed package wrapper")
  equal(#liveWrappers(), 1, "F10 left more than one live package")
  currentPackage = spawn.wrapper
end)

succeeds("8. empty-server cleanup destroys the package and a later single join assembles one ship", function()
  local playerWatcher = findWatcher(EVENTS.PlayerLeaveUnit)
  check(playerWatcher ~= nil, "player leave watcher is missing")
  local packageBeforeCleanup = currentPackage
  local beforeSpawns = #spawnRecords

  firePlayerEvent(playerWatcher, "OnEventPlayerLeaveUnit", "Aerial-1", "PilotOne")
  firePlayerEvent(playerWatcher, "OnEventPlayerLeaveUnit", "Aerial-3", "PilotThree")
  local cleanups = pendingOneShotSchedules(1)
  equal(#cleanups, 2, "both player leaves did not produce their delayed cleanup callbacks")
  for _, cleanup in ipairs(cleanups) do
    runSchedule(cleanup)
  end

  equal(packageBeforeCleanup.destroy_count, 1, "empty-server cleanup did not destroy the package")
  equal(#liveWrappers(), 0, "a package remained live after empty-server cleanup")

  firePlayerEvent(findWatcher(EVENTS.PlayerEnterAircraft), "OnEventPlayerEnterAircraft", "Aerial-2", "PilotTwo")
  local assembly = findPendingSchedule(3, false)
  check(assembly ~= nil, "single-player re-entry did not schedule three-second assembly")
  runSchedule(assembly)

  equal(#spawnRecords, beforeSpawns + 1, "single-player re-entry did not spawn exactly one new group")
  local spawn = latestSpawn()
  equal(spawn.grouping, 2, "wave four did not add the first escalation bandit")
  equal(spawn.wrapper.unit_count, 2, "escalated single-player wrapper has the wrong unit count")
  equal(#liveWrappers(), 1, "single-player re-entry did not leave exactly one live package")
  currentPackage = spawn.wrapper
end)

succeeds("9. mid-wave joins are included together in the next escalated package", function()
  local playerWatcher = findWatcher(EVENTS.PlayerEnterAircraft)
  local deadWatcher = findWatcher(EVENTS.Dead)
  local spawnsBefore = #spawnRecords

  firePlayerEvent(playerWatcher, "OnEventPlayerEnterAircraft", "Aerial-1", "PilotOne")
  firePlayerEvent(playerWatcher, "OnEventPlayerEnterAircraft", "Aerial-3", "PilotThree")
  firePlayerEvent(playerWatcher, "OnEventPlayerEnterAircraft", "Aerial-4", "PilotFour")
  equal(#spawnRecords, spawnsBefore, "mid-wave joins changed the active one-ship package")

  killPackageFully(deadWatcher, currentPackage)
  local respawnSchedule = findPendingSchedule(30, false)
  check(respawnSchedule ~= nil, "package defeat did not schedule the next wave")
  runSchedule(respawnSchedule)

  equal(#spawnRecords, spawnsBefore + 1, "four-player roster did not produce exactly one package")
  local spawn = latestSpawn()
  equal(spawn.grouping, 5, "wave five did not include four live players plus one escalation bandit")
  equal(#spawn.wrapper.units, 5, "escalated four-player package does not contain five units")
  for i, unit in ipairs(spawn.wrapper.units) do
    for j = i + 1, #spawn.wrapper.units do
      local separation = unit.coordinate:Get2DDistance(spawn.wrapper.units[j].coordinate)
      check(separation > 0, "escalated formation positions are not distinct")
    end
  end
  currentPackage = spawn.wrapper
end)

succeeds("10. the three required event watchers are registered", function()
  equal(#watchers, 3, "unexpected BASE watcher was registered")
  local playerWatcher = findWatcher(EVENTS.PlayerEnterAircraft)
  local banditWatcher = findWatcher(EVENTS.Dead)
  local playerDeathWatcher = _G.duel_gameplay_watchers.playerDeath
  check(playerWatcher ~= nil, "PlayerEnterAircraft watcher is missing")
  check(banditWatcher ~= nil, "Dead watcher is missing")
  check(findWatcher(EVENTS.PlayerLeaveUnit) == playerWatcher, "PlayerLeaveUnit uses a different watcher")
  check(findWatcher(EVENTS.Crash) == banditWatcher, "Crash uses a different watcher")
  check(playerWatcher ~= banditWatcher, "player and bandit events share a watcher")
  check(playerDeathWatcher ~= banditWatcher, "player-death and bandit events share a watcher")
  check(
    hasExactlyEvents(playerWatcher, EVENTS.PlayerEnterAircraft, EVENTS.PlayerLeaveUnit),
    "player watcher handles events other than enter/leave"
  )
  check(
    hasExactlyEvents(banditWatcher, EVENTS.Dead, EVENTS.Crash),
    "bandit watcher handles events other than dead/crash"
  )
  check(
    hasExactlyEvents(playerDeathWatcher, EVENTS.Dead, EVENTS.Crash),
    "player-death watcher handles events other than dead/crash"
  )
end)

succeeds("11. gameplay watchers remain strongly reachable after main returns", function()
  check(type(_G.duel_gameplay_watchers) == "table", "gameplay watcher retention table is missing")
  check(_G.duel_gameplay_watchers.player == findWatcher(EVENTS.PlayerEnterAircraft), "player watcher is not retained")
  check(_G.duel_gameplay_watchers.bandit == findWatcher(EVENTS.Dead), "bandit watcher is not retained")
  check(_G.duel_gameplay_watchers.playerDeath ~= nil, "player-death watcher is not retained")
end)

succeeds("12. the valid scenario logs no environment errors", function()
  for _, entry in ipairs(logs) do
    check(entry.level ~= "ERROR", "error log: " .. entry.message)
  end
end)

succeeds("13. waves vary the donor and stay inside the random profile bounds", function()
  local deadWatcher = findWatcher(EVENTS.Dead)
  check(deadWatcher ~= nil, "dead/crash watcher is missing")
  local spawnsBefore = #spawnRecords
  local auftragsBefore = #auftrags
  local registrationsBefore = #assetRegistrations
  local centroid = liveCentroid()
  check(centroid ~= nil, "no live player centroid for the bounds loop")
  check(
    playerAlive["Aerial-1"] and playerAlive["Aerial-2"] and playerAlive["Aerial-3"] and playerAlive["Aerial-4"],
    "all four blue players are not alive for the bounds loop"
  )

  local wavesToSimulate = 8
  for _ = 1, wavesToSimulate do
    killPackageFully(deadWatcher, currentPackage)
    local respawnSchedule = findPendingSchedule(30, false)
    check(respawnSchedule ~= nil, "bounds-loop wave defeat did not schedule the next wave")
    runSchedule(respawnSchedule)
    currentPackage = latestSpawn().wrapper
  end

  equal(#spawnRecords, spawnsBefore + wavesToSimulate, "bounds loop did not spawn exactly one group per wave")
  equal(#assetRegistrations, registrationsBefore + wavesToSimulate, "bounds loop did not register one asset per wave")

  local donorsSeen = {}
  for i = spawnsBefore + 1, #spawnRecords do
    local spawn = spawnRecords[i]
    check(isBanditDonor(spawn.template), "wave used a template outside the active donor list")
    donorsSeen[spawn.template] = true
    check(
      spawn.coordinate.y >= MIN_SPAWN_ALT_M - 0.001 and spawn.coordinate.y <= MAX_SPAWN_ALT_M + 0.001,
      string.format("wave spawn altitude %.0f m is outside 15000–25000 ft", spawn.coordinate.y)
    )
    local distance = centroid:Get2DDistance(spawn.coordinate)
    check(
      distance >= MIN_SEPARATION_M - 0.001 and distance <= MAX_SEPARATION_M + 0.001,
      string.format("wave spawn distance %.0f m is outside 55–85 statute miles", distance)
    )
    local registration = assetRegistrations[registrationsBefore + (i - spawnsBefore)]
    equal(registration.configured_name, spawn.template, "wave asset registration did not pass the actual donor name")
    equal(registration.group_name, spawn.wrapper:GetName(), "wave asset registration has the wrong group")
  end

  local distinctDonors = 0
  for _ in pairs(donorsSeen) do
    distinctDonors = distinctDonors + 1
  end
  check(distinctDonors >= 2, "bounds loop never varied the donor across " .. wavesToSimulate .. " waves")

  for i = auftragsBefore + 1, #auftrags do
    local mission = auftrags[i]
    check(
      mission.altitude >= MIN_CAP_ALT_FT and mission.altitude <= MAX_CAP_ALT_FT,
      string.format("CAP altitude %s ft is outside 15000–30000 ft", tostring(mission.altitude))
    )
    check(
      mission.speed >= MIN_CAP_SPEED_KT and mission.speed <= MAX_CAP_SPEED_KT,
      string.format("CAP speed %s kt is outside 350–550 kt", tostring(mission.speed))
    )
  end

  check(logContains(", donor Bandit-"), "spawn log does not name the chosen donor")
  check(logContains(" mi from blue centroid"), "spawn log does not report statute miles")
end)

succeeds("14. group options defer to the ME: baked AUFTRAG options are nilled, no live options set", function()
  check(#flightGroups > 0, "no flight groups were tasked")
  for _, flightGroup in ipairs(flightGroups) do
    for _, mission in ipairs(flightGroup.missions) do
      equal(mission.optionROE, nil, "AUFTRAG mission kept a baked optionROE")
      equal(mission.optionROT, nil, "AUFTRAG mission kept a baked optionROT")
      equal(mission.optionAlarm, nil, "AUFTRAG mission kept a baked optionAlarm")
    end
  end
  for _, wrapper in ipairs(allWrappers) do
    check(next(wrapper.options) == nil, "live group options were force-set on " .. wrapper:GetName())
  end
end)

succeeds("15. a missing donor logs once and init completes with the remaining eight", function()
  SPAWN.failTemplates = { ["Bandit-8"] = true }
  local spawnersBefore = #constructedSpawners
  local callsBefore = #SPAWN.newCalls
  local spawnsBefore = #spawnRecords
  local registrationsBefore = #assetRegistrations

  dofile("src/missions/duel-dynamic/main.lua")

  local initSchedule = findPendingSchedule(1, true)
  check(initSchedule ~= nil, "second init poll scheduler was not captured")
  equal(runSchedule(initSchedule), false, "second init poll did not stop after initialization")

  equal(#SPAWN.newCalls, callsBefore + 9, "second init did not attempt SPAWN:New for all 9 active donors")
  local attempted = {}
  for i = callsBefore + 1, #SPAWN.newCalls do
    attempted[SPAWN.newCalls[i]] = true
  end
  for _, donor in ipairs(BANDIT_GROUP_NAMES) do
    check(attempted[donor], "second init did not attempt SPAWN:New for " .. donor)
  end
  equal(#constructedSpawners, spawnersBefore + 8, "second init did not keep exactly the eight surviving donors")
  check(logContains("SPAWN:New('Bandit-8')"), "missing-donor error log is missing")

  local assemblySchedule = findPendingSchedule(3, false)
  check(assemblySchedule ~= nil, "second three-second assembly scheduler was not captured")
  runSchedule(assemblySchedule)

  equal(#spawnRecords, spawnsBefore + 1, "second assembly did not spawn exactly one group")
  local spawn = latestSpawn()
  check(spawn.template ~= "Bandit-8", "second assembly spawned from the missing donor")
  check(isBanditDonor(spawn.template), "second assembly used a template outside the active donor list")
  equal(
    assetRegistrations[#assetRegistrations].configured_name,
    spawn.template,
    "second assembly registration did not pass the actual donor name"
  )
  equal(#assetRegistrations, registrationsBefore + 1, "second assembly did not register exactly one asset")
  _G.duel_missing_donor_package = spawn.wrapper
end)

succeeds("16. spawnWave only ever picks from the surviving donors", function()
  local deadWatcher = _G.duel_gameplay_watchers.bandit
  check(deadWatcher ~= nil, "second dead/crash watcher is missing")
  local spawnsBefore = #spawnRecords
  local wavesToSimulate = 5
  local package = _G.duel_missing_donor_package
  check(package ~= nil, "missing-donor package was not captured")
  for _ = 1, wavesToSimulate do
    killPackageFully(deadWatcher, package)
    local respawnSchedule = findPendingSchedule(30, false)
    check(respawnSchedule ~= nil, "survivor-loop wave defeat did not schedule the next wave")
    runSchedule(respawnSchedule)
    package = latestSpawn().wrapper
  end
  equal(#spawnRecords, spawnsBefore + wavesToSimulate, "survivor loop did not spawn exactly one group per wave")
  for i = spawnsBefore + 1, #spawnRecords do
    local template = spawnRecords[i].template
    check(template ~= "Bandit-8", "survivor loop spawned from the missing donor")
    check(isBanditDonor(template), "survivor loop used a template outside the active donor list")
  end
  _G.duel_missing_donor_package = nil
end)

local livesScenario = nil

succeeds("17. player lives decrement once and follow a UCID across slots", function()
  livesScenario = loadInitializedMission({
    { slot = "Aerial-1", name = "Springfield", ucid = "ucid-springfield" },
  })
  local messagesBefore = #messages
  firePlayerLoss("OnEventDead", "Aerial-1", "Aerial-1-1", nil, 101)
  equal(messages[#messages].text, "Aircraft lost — 2 lives left.", "first player loss message is wrong")
  firePlayerLoss("OnEventCrash", "Aerial-1", "Aerial-1-1", nil, 101)
  equal(#messages, messagesBefore + 1, "duplicate player crash posted another loss message")

  menuCommands["Show lives"].callback()
  equal(messages[#messages].text, "Lives:\n  Springfield: 2", "Show lives did not report two remaining lives")

  firePlayerEvent(
    livesScenario.retained.player,
    "OnEventPlayerLeaveUnit",
    "Aerial-1",
    "Springfield",
    "ucid-springfield"
  )
  firePlayerEvent(
    livesScenario.retained.player,
    "OnEventPlayerEnterAircraft",
    "Aerial-2",
    "Springfield",
    "ucid-springfield"
  )
  menuCommands["Show lives"].callback()
  equal(messages[#messages].text, "Lives:\n  Springfield: 2", "rejoin into another slot reset UCID lives")

  firePlayerEvent(livesScenario.retained.player, "OnEventPlayerEnterAircraft", "Aerial-1", "Colt", "ucid-colt")
  menuCommands["Show lives"].callback()
  equal(messages[#messages].text, "Lives:\n  Colt: 3\n  Springfield: 2", "new UCID did not receive fresh lives")
end)

succeeds("17b. a reused unit name with a new DCS object consumes another life", function()
  firePlayerEvent(livesScenario.retained.player, "OnEventPlayerLeaveUnit", "Aerial-1", "Colt", "ucid-colt")
  firePlayerEvent(livesScenario.retained.player, "OnEventPlayerEnterAircraft", "Aerial-1", "Colt", "ucid-colt")
  firePlayerLoss("OnEventDead", "Aerial-1", "Aerial-1-1", nil, 102)
  equal(messages[#messages].text, "Aircraft lost — 2 lives left.", "reused-name aircraft loss was not counted")
  firePlayerLoss("OnEventCrash", "Aerial-1", "Aerial-1-1", nil, 102)
  menuCommands["Show lives"].callback()
  equal(
    messages[#messages].text,
    "Lives:\n  Colt: 2\n  Springfield: 2",
    "reused-name Dead/Crash lifecycle did not decrement exactly once"
  )
end)

succeeds("18. a zero-life identity is excluded even after DCS-native re-entry", function()
  firePlayerLoss("OnEventDead", "Aerial-2", "springfield-aircraft-2")
  equal(messages[#messages].text, "Aircraft lost — 1 life left.", "singular life message is wrong")
  firePlayerLoss("OnEventDead", "Aerial-2", "springfield-aircraft-3")
  equal(messages[#messages].text, "Aircraft lost — out of lives.", "out-of-lives message is wrong")

  local spawnsBefore = #spawnRecords
  menuCommands["Respawn bandit wave"].callback()
  equal(#spawnRecords, spawnsBefore + 1, "forced spawn did not replace the active package")
  equal(latestSpawn().grouping, 1, "zero-life player was counted in the replacement package")
  livesScenario.package = latestSpawn().wrapper

  firePlayerEvent(
    livesScenario.retained.player,
    "OnEventPlayerEnterAircraft",
    "Aerial-3",
    "Springfield",
    "ucid-springfield"
  )
  equal(messages[#messages].text, "Out of lives — excluded from the package.", "zero-life re-entry message is wrong")
end)

succeeds("19. terminal state fires once and blocks scheduled and forced replacement", function()
  local package = livesScenario.package
  local destroyBefore = package.destroy_count
  local schedulesBeforeDefeat = #schedules
  killPackageFully(livesScenario.retained.bandit, package)
  local pendingReplacement = latestPendingSchedule(30, false, schedulesBeforeDefeat)
  check(pendingReplacement ~= nil, "pre-terminal wave defeat did not leave a scheduled replacement")
  equal(package.destroy_count, destroyBefore, "wave defeat explicitly despawned the package")

  local terminalMessageStart = #messages + 1
  firePlayerLoss("OnEventDead", "Aerial-1", "colt-aircraft-1")
  firePlayerLoss("OnEventDead", "Aerial-1", "colt-aircraft-2")
  firePlayerLoss("OnEventDead", "Aerial-1", "colt-aircraft-3")
  equal(
    countExactMessages("All pilots down — mission over.", terminalMessageStart),
    1,
    "terminal message did not fire exactly once"
  )

  local spawnsBefore = #spawnRecords
  runSchedule(pendingReplacement)
  equal(#spawnRecords, spawnsBefore, "pre-terminal scheduled callback spawned after terminal state")
  equal(package.destroy_count, destroyBefore, "terminal transition despawned the active wave")

  menuCommands["Respawn bandit wave"].callback()
  equal(messages[#messages].text, "Mission over — no more waves.", "terminal F10 refusal message is wrong")
  equal(#spawnRecords, spawnsBefore, "terminal F10 command spawned a wave")
  equal(package.destroy_count, destroyBefore, "terminal F10 command despawned the finished wave wrapper")
  firePlayerLoss("OnEventCrash", "Aerial-1", "colt-aircraft-3")
  equal(
    countExactMessages("All pilots down — mission over.", terminalMessageStart),
    1,
    "duplicate loss repeated the terminal transition"
  )
end)

succeeds("20. two-player package escalation follows 2,2,2,3", function()
  loadInitializedMission({
    { slot = "Aerial-1", name = "One", ucid = "two-player-1" },
    { slot = "Aerial-2", name = "Two", ucid = "two-player-2" },
  })
  local expected = { 2, 2, 2, 3 }
  local firstSpawn = #spawnRecords
  for wave = 1, #expected do
    if wave > 1 then
      menuCommands["Respawn bandit wave"].callback()
    end
    equal(spawnRecords[firstSpawn + wave - 1].grouping, expected[wave], "two-player escalation cadence is wrong")
  end
  check(logContains("escalation +1"), "escalated spawn log does not report its escalation")
end)

succeeds("21. one-player package escalation follows 1,1,1,2", function()
  loadInitializedMission({
    { slot = "Aerial-1", name = "Solo", ucid = "solo-player" },
  })
  local expected = { 1, 1, 1, 2 }
  local firstSpawn = #spawnRecords
  for wave = 1, #expected do
    if wave > 1 then
      menuCommands["Respawn bandit wave"].callback()
    end
    equal(spawnRecords[firstSpawn + wave - 1].grouping, expected[wave], "one-player escalation cadence is wrong")
  end
end)

succeeds("22. escalation caps at eight with eight distinct formation offsets", function()
  loadInitializedMission({
    { slot = "Aerial-1", name = "One", ucid = "cap-player-1" },
    { slot = "Aerial-2", name = "Two", ucid = "cap-player-2" },
    { slot = "Aerial-3", name = "Three", ucid = "cap-player-3" },
    { slot = "Aerial-4", name = "Four", ucid = "cap-player-4" },
  })
  local firstSpawn = #spawnRecords
  local waveCount = 16
  for wave = 1, waveCount do
    if wave > 1 then
      menuCommands["Respawn bandit wave"].callback()
    end
    local expected = math.min(4 + math.floor((wave - 1) / 3), 8)
    equal(spawnRecords[firstSpawn + wave - 1].grouping, expected, "capped escalation sequence is wrong")
  end
  local finalSpawn = spawnRecords[firstSpawn + waveCount - 1]
  equal(finalSpawn.grouping, 8, "late escalation wave did not cap at eight")
  equal(#finalSpawn.relative_positions, 8, "eight-ship formation did not produce eight offsets")
  for i, position in ipairs(finalSpawn.relative_positions) do
    for j = i + 1, #finalSpawn.relative_positions do
      local other = finalSpawn.relative_positions[j]
      check(position.x ~= other.x or position.y ~= other.y, "eight-ship formation contains duplicate offsets")
    end
  end
end)

succeeds("23. player-facing messages use the approved concise voice", function()
  setAlivePlayers({})
  local schedulesBefore = #schedules
  dofile("src/missions/duel-dynamic/main.lua")
  local retained = _G.duel_gameplay_watchers

  menuCommands["Respawn bandit wave"].callback()
  equal(messages[#messages].text, "Not ready yet — try again in a second.", "pre-init F10 message is wrong")
  menuCommands["Show kills"].callback()
  equal(messages[#messages].text, "Team kills: 0", "Show kills zero-state header is wrong")
  menuCommands["Show lives"].callback()
  equal(messages[#messages].text, "No players yet.", "Show lives empty-state message is wrong")

  firePlayerEvent(retained.player, "OnEventPlayerEnterAircraft", "Aerial-1", "Viper", "message-player")
  local initSchedule = latestPendingSchedule(1, true, schedulesBefore)
  equal(runSchedule(initSchedule), false, "message scenario init did not complete")
  runSchedule(latestPendingSchedule(3, false, schedulesBefore))
  equal(messages[#messages].text, "Wave 1 — 1 hostile inbound", "inbound message is wrong")

  menuCommands["Respawn bandit wave"].callback()
  equal(messages[#messages].text, "New bandit wave inbound.", "forced-wave success message is wrong")
  local activePackage = latestSpawn().wrapper
  fireBanditEvent(retained.bandit, "OnEventDead", activePackage, activePackage.units[1].name)
  equal(messages[#messages].text, "Bandit down — team 1, 0 hostiles left", "bandit kill message is wrong")
  menuCommands["Show kills"].callback()
  equal(messages[#messages].text, "Team kills: 1\n  Team: 1", "Show kills scored header is wrong")
  menuCommands["Reset kills"].callback()
  equal(messages[#messages].text, "Kills reset.", "reset-kills message is wrong")

  firePlayerEvent(retained.player, "OnEventPlayerLeaveUnit", "Aerial-1", "Viper", "message-player")
  menuCommands["Respawn bandit wave"].callback()
  equal(messages[#messages].text, "No players in the air.", "no-player forced-wave message is wrong")

  local oldFragments = {
    " bandit inbound",
    "Bandit down!",
    "Kill counter reset",
    "Init not done yet",
    "force-reset",
    "No live player aircraft",
    "red package remaining",
  }
  for _, fragment in ipairs(oldFragments) do
    check(not messageContains(fragment), "obsolete player-facing jargon remains: " .. fragment)
  end
end)

succeeds("24. player-death watcher is retained, shares Dead/Crash, and ignores red losses", function()
  local context = loadInitializedMission({
    { slot = "Aerial-1", name = "Hygiene", ucid = "watcher-player" },
  })
  equal(#watchers, context.watchersBefore + 3, "fresh mission did not register exactly three gameplay watchers")
  check(context.retained.playerDeath ~= nil, "player-death watcher is not strongly retained")
  check(
    hasExactlyEvents(context.retained.playerDeath, EVENTS.Dead, EVENTS.Crash),
    "player-death watcher does not handle exactly Dead and Crash"
  )
  menuCommands["Show lives"].callback()
  local livesBefore = messages[#messages].text
  firePlayerLoss("OnEventDead", "Aerial-1", "red-loss-must-not-count", RED)
  menuCommands["Show lives"].callback()
  equal(messages[#messages].text, livesBefore, "red-coalition death changed player lives")
end)

succeeds("25. slot fallback initializes missing lives and warns once per mission run", function()
  setAlivePlayers({})
  local schedulesBefore = #schedules
  local warningsBefore = 0
  for _, entry in ipairs(logs) do
    if entry.level == "WARNING" and entry.message:find("player UCID unavailable", 1, true) then
      warningsBefore = warningsBefore + 1
    end
  end
  dofile("src/missions/duel-dynamic/main.lua")
  local retained = _G.duel_gameplay_watchers
  firePlayerEvent(retained.player, "OnEventPlayerEnterAircraft", "Aerial-1", nil, nil)
  firePlayerEvent(retained.player, "OnEventPlayerEnterAircraft", "Aerial-2", nil, nil)
  equal(runSchedule(latestPendingSchedule(1, true, schedulesBefore)), false, "fallback scenario init did not complete")
  runSchedule(latestPendingSchedule(3, false, schedulesBefore))
  menuCommands["Show lives"].callback()
  equal(
    messages[#messages].text,
    "Lives:\n  Player: 3\n  Player: 3",
    "slot fallback did not initialize both identities"
  )
  local warningsAfter = 0
  for _, entry in ipairs(logs) do
    if entry.level == "WARNING" and entry.message:find("player UCID unavailable", 1, true) then
      warningsAfter = warningsAfter + 1
    end
  end
  equal(warningsAfter, warningsBefore + 1, "slot fallback warning was not emitted exactly once")
end)

succeeds("26. the blue F10 root menu uses the Air Superiority Survival title", function()
  check(#menus > 0, "no coalition menu was registered")
  local found = false
  for _, menu in ipairs(menus) do
    if menu.side == BLUE and menu.title == "Air Superiority Survival" then
      found = true
    end
    check(menu.title ~= "Duel Dynamic", "stale Duel Dynamic menu title is still registered")
  end
  check(found, "Air Superiority Survival coalition menu was not registered")
end)

succeeds("27. Bandit-7 is excluded from the allow-list, init, and every spawned wave", function()
  equal(#BANDIT_GROUP_NAMES, 9, "active donor allow-list does not contain exactly nine donors")
  check(not isBanditDonor("Bandit-7"), "Bandit-7 is still in the active donor allow-list")
  for _, name in ipairs(SPAWN.newCalls) do
    check(name ~= "Bandit-7", "SPAWN:New was attempted for excluded Bandit-7")
  end
  for i, record in ipairs(spawnRecords) do
    check(record.template ~= "Bandit-7", "spawn record " .. i .. " used excluded Bandit-7")
  end
  for _, registration in ipairs(assetRegistrations) do
    check(registration.configured_name ~= "Bandit-7", "telemetry registered excluded Bandit-7")
  end
end)

succeeds("28. tiered donor selection follows waves 1-3, 4-6, and 7+ with unchanged size escalation", function()
  SPAWN.failTemplates = {}
  local context = loadInitializedMission({
    { slot = "Aerial-1", name = "TierSolo", ucid = "tier-solo" },
  })
  local firstSpawn = context.spawnsBefore + 1
  local wavesToSimulate = 9
  for wave = 2, wavesToSimulate do
    killPackageFully(context.retained.bandit, latestSpawn().wrapper)
    -- Scoped to this scenario: earlier scenarios may have left their own
    -- unexecuted 30-second schedules behind.
    local respawnSchedule = latestPendingSchedule(30, false, context.schedulesBefore)
    check(respawnSchedule ~= nil, "tier-loop wave defeat did not schedule the next wave")
    runSchedule(respawnSchedule)
  end
  equal(#spawnRecords, context.spawnsBefore + wavesToSimulate, "tier loop did not spawn exactly one group per wave")
  for wave = 1, wavesToSimulate do
    local spawn = spawnRecords[firstSpawn + wave - 1]
    local expectedTier = tierForWave(wave)
    check(
      inTier(spawn.template, expectedTier),
      string.format("wave %d used %s, outside tier %d", wave, spawn.template, expectedTier)
    )
    check(spawn.template ~= "Bandit-7", "tier loop spawned excluded Bandit-7 at wave " .. wave)
    local expectedSize = math.min(1 + math.floor((wave - 1) / 3), 8)
    equal(spawn.grouping, expectedSize, "tier loop changed the size escalation at wave " .. wave)
  end
  check(logContains("donor Bandit-") and logContains("tier 1"), "spawn log does not name the tier-1 donor selection")
  check(logContains("tier 2"), "spawn log does not name the tier-2 donor selection")
  check(logContains("tier 3"), "spawn log does not name the tier-3 donor selection")
end)

succeeds("29. an unavailable tier degrades to surviving donors without reintroducing Bandit-7", function()
  SPAWN.failTemplates = { ["Bandit-10"] = true, ["Bandit-3"] = true, ["Bandit-6"] = true }
  local context = loadInitializedMission({
    { slot = "Aerial-1", name = "FallbackSolo", ucid = "fallback-solo" },
  })
  local spawn = spawnRecords[context.spawnsBefore + 1]
  check(spawn.template ~= "Bandit-10", "fallback spawned from unavailable Bandit-10")
  check(spawn.template ~= "Bandit-3", "fallback spawned from unavailable Bandit-3")
  check(spawn.template ~= "Bandit-6", "fallback spawned from unavailable Bandit-6")
  check(spawn.template ~= "Bandit-7", "fallback reintroduced excluded Bandit-7")
  check(isBanditDonor(spawn.template), "fallback used a template outside the active donor list")

  SPAWN.failTemplates = { ["Bandit-8"] = true, ["Bandit-9"] = true }
  local suContext = loadInitializedMission({
    { slot = "Aerial-1", name = "NoSu", ucid = "no-su" },
  })
  for wave = 2, 8 do
    killPackageFully(suContext.retained.bandit, latestSpawn().wrapper)
    -- Scoped to this scenario: earlier scenarios may have left their own
    -- unexecuted 30-second schedules behind.
    local respawnSchedule = latestPendingSchedule(30, false, suContext.schedulesBefore)
    check(respawnSchedule ~= nil, "no-Su-33 loop wave defeat did not schedule the next wave")
    runSchedule(respawnSchedule)
    local waveSpawn = latestSpawn()
    check(waveSpawn.template ~= "Bandit-8", "no-Su-33 loop spawned unavailable Bandit-8 at wave " .. wave)
    check(waveSpawn.template ~= "Bandit-9", "no-Su-33 loop spawned unavailable Bandit-9 at wave " .. wave)
    check(waveSpawn.template ~= "Bandit-7", "no-Su-33 loop reintroduced excluded Bandit-7 at wave " .. wave)
    check(isBanditDonor(waveSpawn.template), "no-Su-33 loop used a template outside the active donor list")
  end
  SPAWN.failTemplates = {}
end)

succeeds("30. Aerial-5 is accepted as a live player and contributes to a package", function()
  SPAWN.failTemplates = {}
  local context = loadInitializedMission({
    { slot = "Aerial-5", name = "Five", ucid = "fifth-slot-solo" },
  })
  local spawn = spawnRecords[context.spawnsBefore + 1]
  equal(spawn.grouping, 1, "solo Aerial-5 occupant did not produce a one-ship package")
  equal(#spawn.wrapper.units, 1, "solo Aerial-5 package does not contain one unit")
  check(isBanditDonor(spawn.template), "solo Aerial-5 package used a template outside the active donor list")

  local second = loadInitializedMission({
    { slot = "Aerial-1", name = "One", ucid = "fifth-slot-1" },
    { slot = "Aerial-2", name = "Two", ucid = "fifth-slot-2" },
    { slot = "Aerial-3", name = "Three", ucid = "fifth-slot-3" },
    { slot = "Aerial-4", name = "Four", ucid = "fifth-slot-4" },
    { slot = "Aerial-5", name = "Five", ucid = "fifth-slot-5" },
  })
  local fullSpawn = spawnRecords[second.spawnsBefore + 1]
  equal(fullSpawn.grouping, 5, "five-player roster did not size its first package to five")
  equal(#fullSpawn.wrapper.units, 5, "five-player package does not contain five units")
end)

succeeds("31. five-player escalation follows 5,5,5,6 and caps at eight", function()
  loadInitializedMission({
    { slot = "Aerial-1", name = "One", ucid = "five-cap-1" },
    { slot = "Aerial-2", name = "Two", ucid = "five-cap-2" },
    { slot = "Aerial-3", name = "Three", ucid = "five-cap-3" },
    { slot = "Aerial-4", name = "Four", ucid = "five-cap-4" },
    { slot = "Aerial-5", name = "Five", ucid = "five-cap-5" },
  })
  local firstSpawn = #spawnRecords
  local waveCount = 10
  for wave = 1, waveCount do
    if wave > 1 then
      menuCommands["Respawn bandit wave"].callback()
    end
    local expected = math.min(5 + math.floor((wave - 1) / 3), 8)
    equal(spawnRecords[firstSpawn + wave - 1].grouping, expected, "five-player escalation sequence is wrong")
    check(spawnRecords[firstSpawn + wave - 1].grouping <= 8, "five-player package exceeded the eight-aircraft cap")
  end
  local finalSpawn = spawnRecords[firstSpawn + waveCount - 1]
  equal(finalSpawn.grouping, 8, "five-player escalation did not cap at eight by wave 10")
  equal(#finalSpawn.relative_positions, 8, "capped five-player formation did not produce eight offsets")
  for i, position in ipairs(finalSpawn.relative_positions) do
    for j = i + 1, #finalSpawn.relative_positions do
      local other = finalSpawn.relative_positions[j]
      check(position.x ~= other.x or position.y ~= other.y, "capped five-player formation contains duplicate offsets")
    end
  end
end)

restoreGlobals()

if #failures > 0 then
  for _, message in ipairs(failures) do
    io.stderr:write("FAIL: " .. message .. "\n")
  end
  error(string.format("duel-dynamic package-wave tests failed: %d of %d", #failures, tests_run))
end

io.write(string.format("duel-dynamic package-wave tests: %d passed\n", tests_run))

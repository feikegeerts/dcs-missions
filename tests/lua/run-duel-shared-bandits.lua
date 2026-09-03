-- tests/lua/run-duel-shared-bandits.lua
--
-- Standalone Lua 5.1 regression test for the package-wave lifecycle in
-- src/missions/duel-dynamic/main.lua.  The mocks below deliberately expose
-- only the DCS/MOOSE surface used by that file.
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
local MIN_SEPARATION_M = 60 * 1609.344
local MAX_SEPARATION_M = MIN_SEPARATION_M + 20000
local FOUR_NM_M = 4 * 1852

local PLAYER_GROUP_NAMES = { "Aerial-1", "Aerial-2", "Aerial-3", "Aerial-4" }

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
}

local playerCoords = {
  ["Aerial-1"] = newCoordinate(200000, 0, 100000),
  ["Aerial-2"] = newCoordinate(250000, 0, 150000),
  ["Aerial-3"] = newCoordinate(150000, 0, 50000),
  ["Aerial-4"] = newCoordinate(175000, 0, 125000),
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

local SPAWN = {}
function SPAWN:New(templateName)
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
  local mission = { kind = "CAP", zone = zone, altitude = altitude, speed = speed }
  auftrags[#auftrags + 1] = mission
  return mission
end
function AUFTRAG:NewINTERCEPT(targetGroup)
  local mission = { kind = "INTERCEPT", target = targetGroup }
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

local function firePlayerEvent(watcher, method, groupName, playerName)
  playerAlive[groupName] = method == "OnEventPlayerEnterAircraft"
  local eventData = {
    IniGroupName = groupName,
    IniDCSGroupName = groupName,
    IniPlayerName = playerName,
    IniCoalition = BLUE,
  }
  local ok, message = pcall(watcher[method], watcher, eventData)
  check(ok, method .. " raised: " .. tostring(message))
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

local currentPackage = nil

-- =====================================================================
-- Assertions follow the package-wave acceptance scenario.
-- =====================================================================

succeeds("1. deferred init and the distinct three-second assembly spawn one package", function()
  local mainPath = "src/missions/duel-dynamic/main.lua"
  dofile(mainPath)

  equal(#schedules, 1, "main.lua did not register the init poll scheduler")
  local initSchedule = findPendingSchedule(1, true)
  check(initSchedule ~= nil, "init poll scheduler was not captured")
  equal(runSchedule(initSchedule), false, "init poll did not stop after initialization")

  equal(#constructedSpawners, 1, "deferred init constructed an unexpected number of SPAWN objects")
  check(spawnersByTemplate["Bandit-1"] ~= nil, "Bandit-1 spawner was not constructed")
  check(spawnersByTemplate["Bandit-2"] == nil, "Bandit-2 spawner was constructed")
  check(spawnersByTemplate["Bandit-3"] == nil, "Bandit-3 spawner was constructed")
  check(spawnersByTemplate["Bandit-1"].on_spawn_group ~= nil, "Bandit-1 OnSpawnGroup callback missing")
  equal(#spawnRecords, 0, "deferred init spawned before the assembly delay")

  local assemblySchedule = findPendingSchedule(3, false)
  check(assemblySchedule ~= nil, "three-second assembly scheduler was not captured")
  runSchedule(assemblySchedule)

  equal(#spawnRecords, 1, "initial assembly did not spawn exactly one group")
  local spawn = latestSpawn()
  equal(spawn.template, "Bandit-1", "initial package used the wrong template")
  check(spawn.wrapper:GetName():find("^Bandit%-1#%d%d%d$") ~= nil, "package wrapper name is not Bandit-1#NNN")
  equal(spawn.grouping, 2, "initial package was not configured as a two-ship group")
  equal(spawn.wrapper.unit_count, 2, "initial package wrapper has the wrong unit count")
  equal(#spawn.wrapper.units, 2, "initial package does not contain two units")
  equal(spawnersByTemplate["Bandit-1"].grouping_calls[1], 2, "InitGrouping(2) was not applied")
  currentPackage = spawn.wrapper
end)

succeeds("2. package geometry is a close formation at the configured separation", function()
  local spawn = latestSpawn()
  local centroid = arithmeticCentroid("Aerial-1", "Aerial-3")
  local distance = centroid:Get2DDistance(spawn.coordinate)
  check(distance >= MIN_SEPARATION_M - 0.001, "package anchor is inside the 60 statute-mile minimum")
  check(
    distance <= MAX_SEPARATION_M + 0.001,
    "package anchor exceeds the configured 60 statute-mile plus 20 km maximum"
  )

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
  check(killMessage.text:find("Team kills", 1, true) ~= nil, "kill message is not team-labelled")
  check(
    killMessage.text:find("red package remaining: 1", 1, true) ~= nil,
    "kill message has the wrong package remainder"
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
  equal(spawn.template, "Bandit-1", "delayed package used the wrong template")
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
  equal(spawn.grouping, 1, "single-player re-entry did not configure grouping 1")
  equal(spawn.wrapper.unit_count, 1, "single-player re-entry wrapper has the wrong unit count")
  equal(#liveWrappers(), 1, "single-player re-entry did not leave exactly one live package")
  currentPackage = spawn.wrapper
end)

succeeds("9. mid-wave joins are included together in the next four-ship package", function()
  local playerWatcher = findWatcher(EVENTS.PlayerEnterAircraft)
  local deadWatcher = findWatcher(EVENTS.Dead)
  local spawnsBefore = #spawnRecords

  firePlayerEvent(playerWatcher, "OnEventPlayerEnterAircraft", "Aerial-1", "PilotOne")
  firePlayerEvent(playerWatcher, "OnEventPlayerEnterAircraft", "Aerial-3", "PilotThree")
  firePlayerEvent(playerWatcher, "OnEventPlayerEnterAircraft", "Aerial-4", "PilotFour")
  equal(#spawnRecords, spawnsBefore, "mid-wave joins changed the active one-ship package")

  fireBanditEvent(deadWatcher, "OnEventDead", currentPackage, currentPackage.units[1].name)
  local respawnSchedule = findPendingSchedule(30, false)
  check(respawnSchedule ~= nil, "one-ship package defeat did not schedule the next wave")
  runSchedule(respawnSchedule)

  equal(#spawnRecords, spawnsBefore + 1, "four-player roster did not produce exactly one package")
  local spawn = latestSpawn()
  equal(spawn.grouping, 4, "next package did not include all four live players")
  equal(#spawn.wrapper.units, 4, "four-player package does not contain four units")
  for i, unit in ipairs(spawn.wrapper.units) do
    check(spawn.coordinate:Get2DDistance(unit.coordinate) <= FOUR_NM_M, "four-ship unit is too far from the lead")
    for j = i + 1, #spawn.wrapper.units do
      local separation = unit.coordinate:Get2DDistance(spawn.wrapper.units[j].coordinate)
      check(separation > 0 and separation <= FOUR_NM_M, "four-ship formation spacing is invalid")
    end
  end
  currentPackage = spawn.wrapper
end)

succeeds("10. only the two required event watchers are registered", function()
  equal(#watchers, 2, "unexpected BASE watcher was registered")
  local playerWatcher = findWatcher(EVENTS.PlayerEnterAircraft)
  local banditWatcher = findWatcher(EVENTS.Dead)
  check(playerWatcher ~= nil, "PlayerEnterAircraft watcher is missing")
  check(banditWatcher ~= nil, "Dead watcher is missing")
  check(findWatcher(EVENTS.PlayerLeaveUnit) == playerWatcher, "PlayerLeaveUnit uses a different watcher")
  check(findWatcher(EVENTS.Crash) == banditWatcher, "Crash uses a different watcher")
  check(playerWatcher ~= banditWatcher, "player and bandit events share a watcher")
  check(
    hasExactlyEvents(playerWatcher, EVENTS.PlayerEnterAircraft, EVENTS.PlayerLeaveUnit),
    "player watcher handles events other than enter/leave"
  )
  check(
    hasExactlyEvents(banditWatcher, EVENTS.Dead, EVENTS.Crash),
    "bandit watcher handles events other than dead/crash"
  )
end)

succeeds("11. gameplay watchers remain strongly reachable after main returns", function()
  check(type(_G.duel_gameplay_watchers) == "table", "gameplay watcher retention table is missing")
  check(_G.duel_gameplay_watchers.player == findWatcher(EVENTS.PlayerEnterAircraft), "player watcher is not retained")
  check(_G.duel_gameplay_watchers.bandit == findWatcher(EVENTS.Dead), "bandit watcher is not retained")
end)

succeeds("12. the valid scenario logs no environment errors", function()
  for _, entry in ipairs(logs) do
    check(entry.level ~= "ERROR", "error log: " .. entry.message)
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

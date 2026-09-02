-- src/missions/duel-dynamic/main.lua — 1–3 vs 1–3 dynamic spawn.
-- Player slots: Aerial-1, Aerial-2, Aerial-3.
-- Red template: Bandit-1 (one late-activated aircraft, cloned to wave size).
-- Event-driven package waves: one red aircraft per live blue player, cloned
-- into a single DCS group so the AI fights as a package rather than as isolated
-- duels. A wave spawns in close formation 60+ mi from the blue centroid. Losses
-- do not respawn individually; the next complete package launches only after
-- every aircraft in the current wave is dead. Bandits are cleaned up when every
-- player leaves.
--
-- The whole "world-touching" setup (find player groups, create bandit
-- SPAWN objects, first-round scatter of player planes) is deferred by 1 s
-- because at MISSION START the DCS world is still being populated and
-- GROUP:FindByName / SPAWN:New can return nil even though the slots and
-- templates exist in the ME. Players typically join seconds to minutes
-- after mission start, so the player enter/leave handlers fire well after
-- the deferred init.

env.info("[duel-dynamic] main start")

if not _G.BASE then
  env.error("[duel-dynamic] MOOSE not loaded — check src/lib/Moose_.lua")
  return
end

env.info("[duel-dynamic] MOOSE loaded")

-- =====================================================================
-- Player roster and red template allow-list
-- =====================================================================
-- ME player-slot names are normal player slots. Red names remain the telemetry
-- allow-list; Bandit-1 is the active one-aircraft template and must be late activated.
local PLAYER_GROUP_NAMES = { "Aerial-1", "Aerial-2", "Aerial-3" }
local BANDIT_GROUP_NAMES = { "Bandit-1", "Bandit-2", "Bandit-3" }

-- Load siblings. Bootstrap set _G.MY_SCRIPTS_ROOT to the project src/ path.
local ROOT = _G.MY_SCRIPTS_ROOT
if not ROOT then
  env.error("[duel-dynamic] MY_SCRIPTS_ROOT not set — bootstrap.lua must run first")
  return
end
local DIR = ROOT .. "missions/duel-dynamic/"

local function initDevelopmentTelemetry()
  if _G.TELEMETRY_DEVELOPMENT_ENABLED ~= true then
    return
  end

  local ok, runtime, startError = pcall(function()
    local eventId = dofile(DIR .. "telemetry/event_id.lua")
    local envelope = dofile(DIR .. "telemetry/envelope.lua")
    local json = dofile(DIR .. "telemetry/json.lua")
    local ndjsonSink = dofile(DIR .. "telemetry/ndjson_sink.lua")
    local lifecycle = dofile(DIR .. "telemetry/lifecycle.lua")
    local development = dofile(DIR .. "telemetry/development.lua")
    local shot = dofile(DIR .. "telemetry/shot.lua")

    return development.start({
      event_id = eventId,
      envelope = envelope,
      json = json,
      ndjson_sink = ndjsonSink,
      lifecycle = lifecycle,
      shot = shot,
      io = io,
      lfs = lfs,
      os = os,
      timer = timer,
      env = env,
      BASE = BASE,
      SCHEDULER = SCHEDULER,
      EVENTS = EVENTS,
      player_group_names = PLAYER_GROUP_NAMES,
      bandit_group_names = BANDIT_GROUP_NAMES,
      player_coalition = coalition.side.BLUE,
      bandit_coalition = coalition.side.RED,
      state = _G,
      heartbeat_interval = 30,
      mission_name = "duel-dynamic",
      mission_version = "1",
      source_version = "duel-dynamic-telemetry-v1",
      run_classification = "test",
    })
  end)

  if not ok then
    env.error("[duel-dynamic][telemetry] initialization raised: " .. tostring(runtime))
    return
  end
  if not runtime then
    env.error("[duel-dynamic][telemetry] initialization failed: " .. tostring(startError))
    return
  end

  -- MOOSE event subscriptions use weak subscriber keys. Keep the complete
  -- runtime strongly reachable for the life of this mission run.
  _G.duel_telemetry_runtime = runtime
end

initDevelopmentTelemetry()
dofile(DIR .. "score.lua")

local Tracker = _G.duel_tracker
if not Tracker then
  env.error("[duel-dynamic] duel_tracker missing — check score.lua")
  return
end

-- =====================================================================
-- Spawn / distance config
-- =====================================================================
local MIN_SEPARATION_M = 60 * 1609.344
local RANDOM_DIST_MIN_M = MIN_SEPARATION_M
local RANDOM_DIST_MAX_M = MIN_SEPARATION_M + 20000
local SPAWN_ALTITUDE_M = 15000 * 0.3048
local RESPAWN_DELAY = 30
local WAVE_ASSEMBLY_DELAY = 3
local EMPTY_SERVER_CLEANUP_DELAY = 1
local FORMATION_LATERAL_M = 1.5 * 1852
local FORMATION_TRAIL_M = 0.5 * 1852
local INIT_DELAY = 1 -- first attempt delay (seconds) before the world-touching setup
local INIT_POLL_INTERVAL = 1 -- how often to retry the init poll
-- 0 = wait indefinitely (SCHEDULER Stop=0 repeats forever). A headless
-- dedicated server can run for many minutes before the first player joins;
-- init must keep polling so a late joiner still gets their paired bandit
-- (doInit's catch pass spawns it the moment a player group becomes alive).
local INIT_TIMEOUT = 0

-- =====================================================================
-- Bandit AI tasking (aggression knobs)
-- =====================================================================
-- BANDIT_TASK    : "INTERCEPT" → package flies straight at the first live
--                  player group. Useful for focused testing.
--                  "CAP"       → bandit orbits a zone and engages
--                  all detected air targets inside it. This is the default
--                  for package-vs-package fights.
-- BANDIT_ROE     : "WEAPON_FREE" → fire on any detected (most aggressive).
--                  "OPEN_FIRE"   → fire only on identified hostiles.
--                  "HOLD"        → hold fire unless fired upon.
-- BANDIT_ROT     : "EVADE_FIRE"  → break off when fired on (default).
--                  "NO_EVADE"    → never evade.
-- BANDIT_ALARM   : "RED"   → engage on detection (most aggressive).
--                  "AUTO"  → auto switch.
--                  "GREEN" → manual, only fires when told.
-- BANDIT_ALT_FT  : working altitude in feet (energy advantage).
-- BANDIT_SPEED_KT: cruise speed in knots.
-- BANDIT_CAP_RADIUS_M: CAP zone radius in metres (only used by "CAP").
local BANDIT_TASK = "CAP"
local BANDIT_ROE = "WEAPON_FREE"
local BANDIT_ROT = "EVADE_FIRE"
local BANDIT_ALARM = "RED"
local BANDIT_ALT_FT = 25000
local BANDIT_SPEED_KT = 450
local BANDIT_CAP_RADIUS_M = 150000 -- 150 km — contains the complete spawn ring around the blue centroid

-- =====================================================================
-- Custom RNG (DCS sandbox disables math.randomseed).
-- =====================================================================
local _rngState = (os.time() % 2147483648)
local function randInt(min, max)
  _rngState = (_rngState * 1103515245 + 12345) % 2147483648
  return min + (_rngState % (max - min + 1))
end

-- =====================================================================
-- Helpers
-- =====================================================================

local function randomOffsetCoord(refCoord, minDistM, maxDistM)
  local dist = randInt(minDistM, maxDistM)
  local angle = randInt(0, 359)
  local newCoord = refCoord:Translate(dist, angle)
  newCoord:SetY(SPAWN_ALTITUDE_M)
  return newCoord, angle
end

local function moveGroup(group, coord, headingDeg)
  local dcsGroup = group:GetDCSObject()
  if not dcsGroup then
    return false
  end
  -- DCS Unit:setPosition(Vec3[, Heading]) — Heading is in radians,
  -- 0 = north, increases clockwise.
  local headingRad = nil
  if headingDeg then
    headingRad = headingDeg * math.pi / 180
  end
  local dcsUnits = dcsGroup:getUnits() or {}
  for _, dcsUnit in pairs(dcsUnits) do
    if dcsUnit and dcsUnit.setPosition then
      dcsUnit:setPosition(coord:GetVec3(), headingRad)
    end
  end
  return true
end

local function coordStr(coord)
  if not coord then
    return "?"
  end
  return string.format("x=%.0f z=%.0f alt=%.0fm", coord.x, coord.z, coord.y)
end

local function namePattern(name)
  return "^" .. name:gsub("%-", "%%-")
end

local function findIdxByName(name, list)
  for i, n in ipairs(list) do
    if name:find(namePattern(n)) then
      return i
    end
  end
  return nil
end

local function getPlayerCoord(pname)
  local pg = GROUP:FindByName(pname)
  if not pg or not pg:IsAlive() then
    return nil
  end
  return pg:GetCoordinate()
end

-- =====================================================================
-- Package-wave state (filled in by the deferred init below).
-- =====================================================================
local WAVE_TEMPLATE_NAME = BANDIT_GROUP_NAMES[1]
local waveSpawner = nil
local currentWaveGroup = nil
local currentWaveGroupName = nil
local currentWaveAlive = 0
local waveNumber = 0
local waveSpawnPending = false
local waveScheduleToken = 0
local occupiedPlayerSlots = {}
local countedBanditUnits = {}
local initDone = false

local spawnWave
local scheduleWave

local function anyPlayerSlotOccupied()
  return next(occupiedPlayerSlots) ~= nil
end

local function livePlayerPackage()
  local players = {}
  local sumX, sumY, sumZ = 0, 0, 0
  for idx, pname in ipairs(PLAYER_GROUP_NAMES) do
    if occupiedPlayerSlots[idx] then
      local coord = getPlayerCoord(pname)
      if coord then
        players[#players + 1] = { name = pname, group = GROUP:FindByName(pname), coord = coord }
        sumX = sumX + coord.x
        sumY = sumY + coord.y
        sumZ = sumZ + coord.z
      end
    end
  end
  if #players == 0 then
    return players, nil
  end
  return players, COORDINATE:New(sumX / #players, sumY / #players, sumZ / #players)
end

local function formationPositions(size, headingDeg)
  local positions = {}
  local headingRad = headingDeg * math.pi / 180
  local forwardX = math.sin(headingRad)
  local forwardY = math.cos(headingRad)
  local rightX = math.cos(headingRad)
  local rightY = -math.sin(headingRad)

  positions[1] = { x = 0, y = 0, heading = headingDeg }
  for i = 2, size do
    local side = (i % 2 == 0) and 1 or -1
    local rank = math.floor(i / 2)
    local lateral = side * FORMATION_LATERAL_M * rank
    local trail = FORMATION_TRAIL_M * rank
    positions[i] = {
      x = rightX * lateral - forwardX * trail,
      y = rightY * lateral - forwardY * trail,
      heading = headingDeg,
    }
  end
  return positions
end

local function cancelScheduledWave()
  waveScheduleToken = waveScheduleToken + 1
  waveSpawnPending = false
end

local function despawnCurrentWave()
  local grp = currentWaveGroup
  local name = currentWaveGroupName
  currentWaveGroup = nil
  currentWaveGroupName = nil
  currentWaveAlive = 0
  if grp then
    pcall(function()
      grp:Destroy(false)
    end)
    env.info(string.format("[duel-dynamic] wave group %s despawned", tostring(name)))
  end
end

local function taskBanditPackage(bgrp, players, playerCentroid)
  if not bgrp or #players == 0 then
    return
  end

  if BANDIT_ROE == "WEAPON_FREE" then
    pcall(function()
      bgrp:OptionROEOpenFireWeaponFree()
    end)
  elseif BANDIT_ROE == "OPEN_FIRE" then
    pcall(function()
      bgrp:OptionROEOpenFire()
    end)
  end
  if BANDIT_ALARM == "RED" then
    pcall(function()
      bgrp:OptionAlarmStateRed()
    end)
  end
  if BANDIT_ROT == "EVADE_FIRE" then
    pcall(function()
      bgrp:OptionROTEvadeFire()
    end)
  end

  local fg = FLIGHTGROUP:New(bgrp)
  local mission
  local targetDescription
  if BANDIT_TASK == "CAP" then
    local capZone =
      ZONE_RADIUS:New(string.format("BanditWaveCap-%d", waveNumber), playerCentroid:GetVec2(), BANDIT_CAP_RADIUS_M)
    mission = AUFTRAG:NewCAP(capZone, BANDIT_ALT_FT, BANDIT_SPEED_KT)
    targetDescription = string.format("blue package centroid (%d players)", #players)
  else
    mission = AUFTRAG:NewINTERCEPT(players[1].group)
    mission.optionROE = ENUMS.ROE.OpenFireWeaponFree
    mission.optionAlarm = ENUMS.AlarmState.Red
    targetDescription = players[1].name
  end
  fg:AddMission(mission)
  env.info(
    string.format(
      "[duel-dynamic] tasked %s → %s on %s (ROE=%s, ROT=%s, alarm=%s)",
      bgrp:GetName(),
      BANDIT_TASK,
      targetDescription,
      BANDIT_ROE,
      BANDIT_ROT,
      BANDIT_ALARM
    )
  )
end

spawnWave = function(reason)
  if currentWaveGroup and currentWaveAlive > 0 then
    env.info(string.format("[duel-dynamic] wave %d still active — spawn request ignored", waveNumber))
    return currentWaveGroup
  end
  if not waveSpawner then
    env.error("[duel-dynamic] cannot spawn wave: SPAWN template is not initialized")
    return nil
  end

  local players, playerCentroid = livePlayerPackage()
  if #players == 0 or not playerCentroid then
    env.info("[duel-dynamic] cannot spawn wave yet: no occupied player aircraft is alive")
    return nil
  end

  local spawnCoord, bearing = randomOffsetCoord(playerCentroid, RANDOM_DIST_MIN_M, RANDOM_DIST_MAX_M)
  local heading = (bearing + 180) % 360
  local distNm = playerCentroid:Get2DDistance(spawnCoord) / 1852
  local size = #players

  waveSpawner:InitGrouping(size)
  waveSpawner:InitSetUnitRelativePositions(formationPositions(size, heading))
  waveSpawner:InitHeading(heading)

  env.info(
    string.format(
      "[duel-dynamic] spawning %d-ship package %.1f nm from blue centroid, heading %03d (%s)",
      size,
      distNm,
      heading,
      tostring(reason or "requested")
    )
  )
  local grp = waveSpawner:SpawnFromCoordinate(spawnCoord)
  if not grp then
    env.error("[duel-dynamic] package wave spawn FAILED")
    return nil
  end

  waveNumber = waveNumber + 1
  currentWaveGroup = grp
  currentWaveGroupName = grp:GetName()
  currentWaveAlive = size
  taskBanditPackage(grp, players, playerCentroid)
  MESSAGE:New(string.format("Wave %d: %d bandit%s inbound", waveNumber, size, size == 1 and "" or "s"), 8)
    :ToCoalition(coalition.side.BLUE)
  return grp
end

scheduleWave = function(delay, reason)
  if waveSpawnPending then
    env.info(
      string.format("[duel-dynamic] wave spawn already pending — keeping existing timer (%s)", tostring(reason))
    )
    return
  end
  waveScheduleToken = waveScheduleToken + 1
  local token = waveScheduleToken
  waveSpawnPending = true
  env.info(string.format("[duel-dynamic] package wave scheduled in %ds (%s)", delay, tostring(reason)))
  SCHEDULER:New(nil, function()
    if token ~= waveScheduleToken then
      return
    end
    waveSpawnPending = false
    if not initDone or not anyPlayerSlotOccupied() then
      return
    end
    local ok, result = pcall(spawnWave, reason)
    if not ok then
      env.error("[duel-dynamic] scheduled wave spawn raised: " .. tostring(result))
    end
  end, {}, delay)
end

-- =====================================================================
-- F10 menu (commands can fire before init — they handle nil state).
-- =====================================================================
local menu = MENU_COALITION:New(coalition.side.BLUE, "Duel Dynamic")

MENU_COALITION_COMMAND:New(coalition.side.BLUE, "Show kills", menu, function()
  MESSAGE:New(Tracker:format(), 10):ToCoalition(coalition.side.BLUE)
end)

MENU_COALITION_COMMAND:New(coalition.side.BLUE, "Reset kills", menu, function()
  Tracker:reset()
  MESSAGE:New("Kill counter reset", 5):ToCoalition(coalition.side.BLUE)
end)

MENU_COALITION_COMMAND:New(coalition.side.BLUE, "Respawn bandit wave", menu, function()
  if not initDone then
    MESSAGE:New("Init not done yet — try again in a second", 5):ToCoalition(coalition.side.BLUE)
    return
  end
  cancelScheduledWave()
  despawnCurrentWave()
  local grp = spawnWave("F10 forced reset")
  if grp then
    MESSAGE:New("Bandit wave force-reset", 5):ToCoalition(coalition.side.BLUE)
  else
    MESSAGE:New("No live player aircraft — wave not spawned", 5):ToCoalition(coalition.side.BLUE)
  end
end)

-- =====================================================================
-- Player enter / leave. The assembly delay groups near-simultaneous slot
-- joins into one multi-aircraft DCS group. A join during combat is included
-- in the next wave; DCS cannot add a unit to an already spawned group.
-- =====================================================================
local playerWatcher = BASE:New()
playerWatcher:HandleEvent(EVENTS.PlayerEnterUnit)
playerWatcher:HandleEvent(EVENTS.PlayerLeaveUnit)

local function onPlayerEnter(EventData)
  if not EventData or not EventData.IniGroup then
    return
  end
  local gname = EventData.IniGroup:GetName()
  local idx = gname and findIdxByName(gname, PLAYER_GROUP_NAMES) or nil
  if not idx then
    return
  end
  occupiedPlayerSlots[idx] = true
  env.info(
    string.format("[duel-dynamic] player '%s' entered %s", EventData.IniPlayerName or "Player", PLAYER_GROUP_NAMES[idx])
  )
  if not initDone then
    return
  end
  if currentWaveGroup and currentWaveAlive > 0 then
    env.info("[duel-dynamic] active package unchanged; joining player will be matched in the next wave")
    return
  end
  scheduleWave(WAVE_ASSEMBLY_DELAY, "player package assembled")
end

local function onPlayerLeave(EventData)
  if not EventData or not EventData.IniGroup then
    return
  end
  local gname = EventData.IniGroup:GetName()
  local idx = gname and findIdxByName(gname, PLAYER_GROUP_NAMES) or nil
  if not idx then
    return
  end
  occupiedPlayerSlots[idx] = nil
  env.info(
    string.format("[duel-dynamic] player left %s — current red package remains active", PLAYER_GROUP_NAMES[idx])
  )

  SCHEDULER:New(nil, function()
    if anyPlayerSlotOccupied() then
      return
    end
    env.info("[duel-dynamic] no player slots occupied — cleaning up the bandit wave")
    cancelScheduledWave()
    despawnCurrentWave()
  end, {}, EMPTY_SERVER_CLEANUP_DELAY)
end

function playerWatcher:OnEventPlayerEnterUnit(EventData)
  onPlayerEnter(EventData)
end
function playerWatcher:OnEventPlayerLeaveUnit(EventData)
  onPlayerLeave(EventData)
end

-- =====================================================================
-- Bandit kill handler. Count each unit in the multi-aircraft group, but do
-- not launch replacements until the complete current wave has been killed.
-- =====================================================================
local banditWatcher = BASE:New()
banditWatcher:HandleEvent(EVENTS.Dead)
banditWatcher:HandleEvent(EVENTS.Crash)

local function eventUnitName(EventData)
  if EventData.IniDCSUnitName then
    return EventData.IniDCSUnitName
  end
  if EventData.IniUnitName then
    return EventData.IniUnitName
  end
  if EventData.IniUnit then
    local ok, name = pcall(function()
      return EventData.IniUnit:GetName()
    end)
    if ok then
      return name
    end
  end
  return nil
end

local function handleBanditKill(EventData)
  if not EventData or not EventData.IniGroup or EventData.IniCoalition ~= coalition.side.RED then
    return
  end
  local gname = EventData.IniGroup:GetName()
  if not gname or gname ~= currentWaveGroupName or currentWaveAlive <= 0 then
    return
  end
  local unitName = eventUnitName(EventData)
  if not unitName then
    env.warning("[duel-dynamic] bandit death had no unit name — ignoring ambiguous duplicate-prone event")
    return
  end
  if countedBanditUnits[unitName] then
    return
  end
  countedBanditUnits[unitName] = true

  currentWaveAlive = math.max(0, currentWaveAlive - 1)
  Tracker:record("Team")
  MESSAGE
    :New(string.format("Bandit down! Team kills: %d — red package remaining: %d", Tracker.total, currentWaveAlive), 8)
    :ToCoalition(coalition.side.BLUE)

  if currentWaveAlive > 0 then
    env.info(
      string.format(
        "[duel-dynamic] %s killed — holding respawn until the remaining %d of wave %d are down",
        unitName,
        currentWaveAlive,
        waveNumber
      )
    )
    return
  end

  env.info(string.format("[duel-dynamic] wave %d defeated — next package in %ds", waveNumber, RESPAWN_DELAY))
  currentWaveGroup = nil
  currentWaveGroupName = nil
  scheduleWave(RESPAWN_DELAY, "previous package defeated")
end

function banditWatcher:OnEventDead(EventData)
  handleBanditKill(EventData)
end
function banditWatcher:OnEventCrash(EventData)
  handleBanditKill(EventData)
end

-- =====================================================================
-- Deferred init: build the bandit SPAWN objects, randomize player
-- headings, and catch any player already in a slot, after the DCS
-- world has finished populating.
--
-- Poll loop because the player-join race is unreliable: sometimes the
-- player has fully populated a slot by simResume, sometimes the
-- DATABASE.AddPlayer event fires 2-3 s *after* simResume, and on a
-- headless dedicated server the first join can be minutes away. We retry
-- every INIT_POLL_INTERVAL until ANY player group becomes alive (no
-- timeout) and then run doInit, whose catch pass spawns bandits for any
-- already-occupied slot.
-- =====================================================================
local function doInit()
  -- Bandit-1 is a one-aircraft ME template. InitGrouping clones it into a
  -- true 1/2/3-aircraft DCS group for each package wave.
  waveSpawner = SPAWN:New(WAVE_TEMPLATE_NAME)
  if not waveSpawner then
    env.error(
      string.format(
        "[duel-dynamic] SPAWN:New('%s') returned nil — check ME group + Late Activation ON",
        WAVE_TEMPLATE_NAME
      )
    )
    return
  end
  waveSpawner:OnSpawnGroup(function(grp)
    env.info(string.format("[duel-dynamic] package spawned: %s at %s", grp:GetName(), coordStr(grp:GetCoordinate())))
  end)

  -- First-round: randomize the player-slot heading. setPosition with
  -- a heading arg *does* take effect on the client. The position
  -- arg is a no-op for client-controlled player slots in MP (DCS
  -- limitation — confirmed by ED forums) so we pass the current
  -- coord to leave the ME position alone. Player positions remain controlled
  -- by their fixed MP slots; only red package positions change between waves.
  for _, pname in ipairs(PLAYER_GROUP_NAMES) do
    local pg = GROUP:FindByName(pname)
    if pg then
      local currentPos = pg:GetCoordinate()
      if currentPos then
        local headingDeg = randInt(0, 359)
        if moveGroup(pg, currentPos, headingDeg) then
          env.info(string.format("[duel-dynamic] %s heading randomized to %03d (pos kept at ME)", pname, headingDeg))
        end
      end
    end
  end

  -- Catch every player already in a slot. Their PlayerEnterUnit events may
  -- have fired before initDone. One delayed spawn then uses the full roster.
  for i, pname in ipairs(PLAYER_GROUP_NAMES) do
    if getPlayerCoord(pname) then
      occupiedPlayerSlots[i] = true
      env.info(string.format("[duel-dynamic] %s already occupied at init — adding to first package roster", pname))
    end
  end

  initDone = true
  scheduleWave(WAVE_ASSEMBLY_DELAY, "initial player package assembled")
  env.info("[duel-dynamic] init done — package-wave lifecycle active")
end

-- A player group becomes alive the moment a client occupies its slot. On a
-- headless dedicated server that can be minutes after mission start, and the
-- first joiner may pick any of the three slots — so poll until ANY player
-- group is alive rather than only Aerial-1.
local function anyPlayerGroupAlive()
  for _, pname in ipairs(PLAYER_GROUP_NAMES) do
    local pg = GROUP:FindByName(pname)
    if pg and pg:IsAlive() then
      return true
    end
  end
  return false
end

SCHEDULER:New(nil, function()
  if initDone then
    return false
  end
  if not anyPlayerGroupAlive() then
    env.info("[duel-dynamic] init: no player group alive yet, retrying...")
    return nil -- keep polling
  end
  doInit()
  -- Returning false makes the SCHEDULEDISPATCHER stop the timer cleanly
  -- instead of rescheduling; the initDone guard above is the safety net.
  return false
end, {}, INIT_DELAY, INIT_POLL_INTERVAL, 0, INIT_TIMEOUT)

env.info("[duel-dynamic] main done (init pending)")

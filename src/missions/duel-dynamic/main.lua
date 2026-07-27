-- src/missions/duel-dynamic/main.lua — 1–3 vs 1–3 dynamic spawn.
-- Player slots: Aerial-1, Aerial-2, Aerial-3 (paired 1:1 with bandits).
-- Bandit groups: Bandit-1, Bandit-2, Bandit-3 (Late Activation in the ME).
-- Event-driven: a player entering spawns their paired bandit 60+ mi away;
-- a player leaving despawns it. Bandit / player respawns keep the 60+ mi
-- rule using a tiny custom LCG (DCS sandbox disables math.randomseed).
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

-- Load siblings. Bootstrap set _G.MY_SCRIPTS_ROOT to the project src/ path.
local ROOT = _G.MY_SCRIPTS_ROOT
if not ROOT then
  env.error("[duel-dynamic] MY_SCRIPTS_ROOT not set — bootstrap.lua must run first")
  return
end
local DIR = ROOT .. "missions/duel-dynamic/"
dofile(DIR .. "score.lua")

local Tracker = _G.duel_tracker
if not Tracker then
  env.error("[duel-dynamic] duel_tracker missing — check score.lua")
  return
end

-- =====================================================================
-- Pairing config
-- =====================================================================
-- ME player-slot names (normal player slots, NOT late-activated). ME
-- bandit names must match and have Late Activation ✓.
local PLAYER_GROUP_NAMES = { "Aerial-1", "Aerial-2", "Aerial-3" }
local BANDIT_GROUP_NAMES = { "Bandit-1", "Bandit-2", "Bandit-3" }

-- =====================================================================
-- Spawn / distance config
-- =====================================================================
local MIN_SEPARATION_M = 60 * 1609.344
local RANDOM_DIST_MIN_M = MIN_SEPARATION_M
local RANDOM_DIST_MAX_M = MIN_SEPARATION_M + 20000
local SPAWN_ALTITUDE_M = 15000 * 0.3048
local RESPAWN_DELAY = 30
local PLAYER_RESPAWN_DELAY = 30
local INIT_DELAY = 1 -- first attempt delay (seconds) before the world-touching setup
local INIT_POLL_INTERVAL = 1 -- how often to retry the init poll
local INIT_TIMEOUT = 30 -- give up after this many seconds if the world never populates

-- =====================================================================
-- Bandit AI tasking (aggression knobs)
-- =====================================================================
-- BANDIT_TASK    : "INTERCEPT" → bandit flies straight at the player and
--                  engages as soon as in range. Best for 1v1 duels.
--                  "CAP"       → bandit orbits a zone and engages
--                  detected targets inside it. Use BANDIT_CAP_RADIUS_M
--                  to size the engage zone.
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
local BANDIT_TASK = "INTERCEPT"
local BANDIT_ROE = "WEAPON_FREE"
local BANDIT_ROT = "EVADE_FIRE"
local BANDIT_ALARM = "RED"
local BANDIT_ALT_FT = 25000
local BANDIT_SPEED_KT = 450
local BANDIT_CAP_RADIUS_M = 100000 -- 100 km — large enough to cover the 60+ mi player gap

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
-- State (filled in by the deferred init below).
-- =====================================================================
local banditSpawners = {}
local latestBanditGroups = {}
local initDone = false

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

MENU_COALITION_COMMAND:New(coalition.side.BLUE, "Respawn all bandits", menu, function()
  if not initDone then
    MESSAGE:New("Init not done yet — try again in a second", 5):ToCoalition(coalition.side.BLUE)
    return
  end
  for i = 1, #BANDIT_GROUP_NAMES do
    spawnBanditFor(i)
  end
  MESSAGE:New("All bandits respawned", 5):ToCoalition(coalition.side.BLUE)
end)

-- Forward declaration so the F10 menu can call it (defined further down).
local function taskBandit(bgrp, pname)
  if not bgrp then
    return
  end
  -- Aggression knobs applied directly to the DCS group first — these
  -- take effect immediately, before the AUFTRAG task is even built.
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
  -- Task: INTERCEPT on the player, or CAP over a zone around the player.
  local playerGroup = GROUP:FindByName(pname)
  if not playerGroup then
    env.error(string.format("[duel-dynamic] taskBandit: player group %s not found", pname))
    return
  end
  local fg = FLIGHTGROUP:New(bgrp)
  local mission
  if BANDIT_TASK == "CAP" then
    local capZone =
      ZONE_RADIUS:New(string.format("CapZone-%s", pname), playerGroup:GetCoordinate(), BANDIT_CAP_RADIUS_M)
    mission = AUFTRAG:NewCAP(capZone, BANDIT_ALT_FT, BANDIT_SPEED_KT)
  else
    mission = AUFTRAG:NewINTERCEPT(playerGroup)
    -- INTERCEPT defaults to OpenFire/EvadeFire; bump to weapon-free
    -- and Red alarm on the AUFTRAG too so the mission task matches
    -- what we set on the live group above.
    mission.optionROE = ENUMS.ROE.OpenFireWeaponFree
    mission.optionAlarm = ENUMS.AlarmState.Red
  end
  fg:AddMission(mission)
  env.info(
    string.format(
      "[duel-dynamic] tasked %s → %s on %s (ROE=%s, ROT=%s, alarm=%s)",
      bgrp:GetName(),
      BANDIT_TASK,
      pname,
      BANDIT_ROE,
      BANDIT_ROT,
      BANDIT_ALARM
    )
  )
end

local function spawnBanditAt(banditIdx, refCoord)
  local bname = BANDIT_GROUP_NAMES[banditIdx]
  local pname = PLAYER_GROUP_NAMES[banditIdx]
  local spawner = banditSpawners[bname]
  if not spawner then
    return nil
  end
  local newPos, _ = randomOffsetCoord(refCoord, RANDOM_DIST_MIN_M, RANDOM_DIST_MAX_M)
  local distNm = refCoord:Get2DDistance(newPos) / 1852
  env.info(string.format("[duel-dynamic] spawning %s %.1f nm from %s", bname, distNm, pname))
  local grp = spawner:SpawnFromCoordinate(newPos)
  if not grp then
    env.error(string.format("[duel-dynamic] %s spawn FAILED", bname))
    return nil
  end
  taskBandit(grp, pname)
  return grp
end

local function spawnBanditFor(banditIdx)
  local pname = PLAYER_GROUP_NAMES[banditIdx]
  local playerCoord = getPlayerCoord(pname)
  if not playerCoord then
    env.error(
      string.format("[duel-dynamic] cannot spawn %s: no alive player in %s", BANDIT_GROUP_NAMES[banditIdx], pname)
    )
    return nil
  end
  return spawnBanditAt(banditIdx, playerCoord)
end

local function despawnBandit(banditIdx)
  local bname = BANDIT_GROUP_NAMES[banditIdx]
  local grp = latestBanditGroups[bname]
  if not grp then
    return
  end
  pcall(function()
    grp:Destroy(false)
  end)
  latestBanditGroups[bname] = nil
  env.info(string.format("[duel-dynamic] %s despawned", bname))
end

-- =====================================================================
-- Player enter / leave — drives bandit spawn / despawn.
-- Safe to register at mission start; the handlers check `initDone`
-- and queue a retry if the world isn't ready yet.
-- =====================================================================
local playerWatcher = BASE:New()
playerWatcher:HandleEvent(EVENTS.PlayerEnterUnit)
playerWatcher:HandleEvent(EVENTS.PlayerLeaveUnit)

local function onPlayerEnter(EventData)
  if not EventData or not EventData.IniGroup then
    return
  end
  local gname = EventData.IniGroup:GetName()
  if not gname then
    return
  end
  local idx = findIdxByName(gname, PLAYER_GROUP_NAMES)
  if not idx then
    return
  end
  local pname = PLAYER_GROUP_NAMES[idx]
  local playerName = EventData.IniPlayerName or "Player"
  env.info(string.format("[duel-dynamic] player '%s' entered %s", playerName, pname))
  if not initDone then
    env.info(
      "[duel-dynamic] init not done yet; player-enter spawn will happen via the deferred init's first-round pass"
    )
    return
  end
  spawnBanditFor(idx)
end

local function onPlayerLeave(EventData)
  if not EventData or not EventData.IniGroup then
    return
  end
  local gname = EventData.IniGroup:GetName()
  if not gname then
    return
  end
  local idx = findIdxByName(gname, PLAYER_GROUP_NAMES)
  if not idx then
    return
  end
  local pname = PLAYER_GROUP_NAMES[idx]
  env.info(string.format("[duel-dynamic] player left %s — despawning paired bandit", pname))
  if not initDone then
    return
  end
  despawnBandit(idx)
end

function playerWatcher:OnEventPlayerEnterUnit(EventData)
  onPlayerEnter(EventData)
end
function playerWatcher:OnEventPlayerLeaveUnit(EventData)
  onPlayerLeave(EventData)
end

-- =====================================================================
-- Bandit kill handler — counts and respawns after RESPAWN_DELAY.
-- Only respawns if the paired player slot is still occupied.
-- =====================================================================
local countedGroups = {}
local banditWatcher = BASE:New()
banditWatcher:HandleEvent(EVENTS.Dead)
banditWatcher:HandleEvent(EVENTS.Crash)

local function handleBanditKill(EventData)
  if not EventData or not EventData.IniGroup then
    return
  end
  local gname = EventData.IniGroup:GetName()
  if not gname then
    return
  end
  if EventData.IniCoalition ~= coalition.side.RED then
    return
  end
  if countedGroups[gname] then
    return
  end
  local idx = findIdxByName(gname, BANDIT_GROUP_NAMES)
  if not idx then
    return
  end
  countedGroups[gname] = true

  local playerName = EventData.IniPlayerName or "Player"
  local bname = BANDIT_GROUP_NAMES[idx]
  Tracker:record(playerName)
  MESSAGE:New(string.format("%s down! Kills: %d", playerName, Tracker.total), 8):ToCoalition(coalition.side.BLUE)
  env.info(string.format("[duel-dynamic] %s killed — respawn scheduled in %ds after %s", bname, RESPAWN_DELAY, gname))

  SCHEDULER:New(nil, function()
    if not initDone then
      return
    end
    local pname = PLAYER_GROUP_NAMES[idx]
    local playerCoord = getPlayerCoord(pname)
    if not playerCoord then
      env.info(string.format("[duel-dynamic] paired player %s gone — skipping %s respawn", pname, bname))
      return
    end
    spawnBanditFor(idx)
  end, {}, RESPAWN_DELAY)
end

function banditWatcher:OnEventDead(EventData)
  handleBanditKill(EventData)
end
function banditWatcher:OnEventCrash(EventData)
  handleBanditKill(EventData)
end

-- =====================================================================
-- Player death handler — after PLAYER_RESPAWN_DELAY, despawn the old
-- bandit and spawn a fresh one 60+ mi from the player's position, so
-- each round has a new bandit location. We do NOT Teleport the player
-- group (see the comment in handlePlayerDeath for why). Player rejoin
-- of the same slot puts them back where they died.
-- =====================================================================
local playerDeathWatcher = BASE:New()
playerDeathWatcher:HandleEvent(EVENTS.Dead)
playerDeathWatcher:HandleEvent(EVENTS.Crash)
playerDeathWatcher:HandleEvent(EVENTS.PilotDead)

local function handlePlayerDeath(EventData)
  if not EventData or not EventData.IniGroup then
    return
  end
  local gname = EventData.IniGroup:GetName()
  if not gname then
    return
  end
  if EventData.IniCoalition ~= coalition.side.BLUE then
    return
  end
  if countedGroups[gname] then
    return
  end
  local idx = findIdxByName(gname, PLAYER_GROUP_NAMES)
  if not idx then
    return
  end
  countedGroups[gname] = true

  local pname = PLAYER_GROUP_NAMES[idx]
  local bname = BANDIT_GROUP_NAMES[idx]
  local dyingGroup = EventData.IniGroup

  MESSAGE:New(string.format("You died! Respawning in %ds — rejoin your slot", PLAYER_RESPAWN_DELAY), 10)
    :ToCoalition(coalition.side.BLUE)
  env.info(string.format("[duel-dynamic] %s died — respawn in %ds", pname, PLAYER_RESPAWN_DELAY))

  SCHEDULER:New(nil, function()
    if not initDone then
      return
    end
    -- Compute a player-relative anchor for the new bandit. We use the
    -- last known *player* position (not the dying group) so the bandit
    -- distance holds even after the player group has been destroyed.
    local playerAnchor = nil
    local pg = GROUP:FindByName(pname)
    if pg and pg:IsAlive() then
      playerAnchor = pg:GetCoordinate()
    end
    if not playerAnchor then
      -- Player group gone too (e.g. early death). Fall back to the
      -- dying group wrapper, or to the last known bandit position.
      local bgrp = latestBanditGroups[bname]
      if bgrp then
        local ok, pos = pcall(function()
          return bgrp:GetCoordinate()
        end)
        if ok then
          playerAnchor = pos
        end
      end
    end
    if not playerAnchor then
      env.error(string.format("[duel-dynamic] no anchor for %s respawn — aborting", bname))
      MESSAGE:New("Respawn failed: no position reference — restart mission", 10):ToCoalition(coalition.side.BLUE)
      return
    end
    -- NOTE: we deliberately do NOT Teleport the player group. MOOSE's
    -- GROUP:Teleport on a dead group ignores the new zone and respawns
    -- at the ME template position (see Wrapper/Group.lua Respawn
    -- `if self:IsAlive() then` guard), which leaves the player at the
    -- original airbase with a "ghost" new group elsewhere. Player
    -- rejoin of the same slot already puts the player back at the
    -- death location, so we leave the slot alone.
    MESSAGE:New("Respawn ready — rejoin your slot", 10):ToCoalition(coalition.side.BLUE)
    despawnBandit(idx)
    env.info(string.format("[duel-dynamic] resetting %s for new round", bname))
    spawnBanditAt(idx, playerAnchor)
  end, {}, PLAYER_RESPAWN_DELAY)
end

function playerDeathWatcher:OnEventDead(EventData)
  handlePlayerDeath(EventData)
end
function playerDeathWatcher:OnEventCrash(EventData)
  handlePlayerDeath(EventData)
end
function playerDeathWatcher:OnEventPilotDead(EventData)
  handlePlayerDeath(EventData)
end

-- =====================================================================
-- Deferred init: build the bandit SPAWN objects, randomize player
-- headings, and catch any player already in a slot, after the DCS
-- world has finished populating.
--
-- Poll loop because the player-join race is unreliable: sometimes the
-- player has fully populated Aerial-1 by simResume, sometimes the
-- DATABASE.AddPlayer event fires 2-3 s *after* simResume. We retry
-- every INIT_POLL_INTERVAL until the first player group is findable,
-- up to INIT_TIMEOUT seconds.
-- =====================================================================
local function doInit()
  -- Build bandit SPAWN objects.
  for _, bname in ipairs(BANDIT_GROUP_NAMES) do
    local spawner = SPAWN:New(bname)
    if not spawner then
      env.error(
        string.format("[duel-dynamic] SPAWN:New('%s') returned nil — check ME group + Late Activation ON", bname)
      )
    else
      spawner:OnSpawnGroup(function(grp)
        latestBanditGroups[bname] = grp
        env.info(
          string.format("[duel-dynamic] %s spawned: %s at %s", bname, grp:GetName(), coordStr(grp:GetCoordinate()))
        )
      end)
      banditSpawners[bname] = spawner
    end
  end

  -- First-round: randomize the player-slot heading. setPosition with
  -- a heading arg *does* take effect on the client. The position
  -- arg is a no-op for client-controlled player slots in MP (DCS
  -- limitation — confirmed by ED forums) so we pass the current
  -- coord to leave the ME position alone. Round 1 always starts at
  -- the ME position; round N+1 randomizes position via the death
  -- respawn (GROUP:Teleport), which forces the client to refresh.
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

  -- Catch any player already in a slot at init time. Their
  -- PlayerEnterUnit event may have fired before initDone and was
  -- dropped, so we spawn the paired bandit here if the slot is
  -- currently occupied.
  for i, pname in ipairs(PLAYER_GROUP_NAMES) do
    if getPlayerCoord(pname) then
      env.info(string.format("[duel-dynamic] %s already occupied at init — spawning paired bandit now", pname))
      spawnBanditFor(i)
    end
  end

  initDone = true
  env.info("[duel-dynamic] init done — player-enter events will now spawn bandits")
end

local initMaster, initScheduleID = SCHEDULER:New(nil, function()
  if initDone then
    return
  end
  local firstPlayerGroup = GROUP:FindByName(PLAYER_GROUP_NAMES[1])
  if not firstPlayerGroup or not firstPlayerGroup:IsAlive() then
    env.info("[duel-dynamic] init: world not ready, retrying...")
    return
  end
  doInit()
  initMaster:Stop(initScheduleID)
end, {}, INIT_DELAY, INIT_POLL_INTERVAL, 0, INIT_TIMEOUT)

env.info("[duel-dynamic] main done (init pending)")

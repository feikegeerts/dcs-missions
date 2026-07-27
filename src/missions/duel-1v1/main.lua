-- src/missions/duel-1v1/main.lua — single player vs single bandit.
-- Runs after bootstrap.lua has loaded MOOSE.

env.info("[duel-1v1] main start")

if not _G.BASE then
  env.error("[duel-1v1] MOOSE not loaded — check src/lib/Moose_.lua")
  return
end

env.info("[duel-1v1] MOOSE loaded")

-- Load siblings. Bootstrap set _G.MY_SCRIPTS_ROOT to the project src/ path.
local ROOT = _G.MY_SCRIPTS_ROOT
if not ROOT then
  env.error("[duel-1v1] MY_SCRIPTS_ROOT not set — bootstrap.lua must run first")
  return
end
local DIR = ROOT .. "missions/duel-1v1/"
dofile(DIR .. "score.lua")

local Tracker = _G.duel_tracker
if not Tracker then
  env.error("[duel-1v1] duel_tracker missing — check score.lua")
  return
end

-- =====================================================================
-- Dynamic spawn config
-- =====================================================================
local PLAYER_GROUP_NAME = "Aerial-1"

-- 60 statute miles in meters.
local MIN_SEPARATION_M = 60 * 1609.344
-- Respawn / first-spawn distance range: 60 – ~73 mi from the reference.
local RANDOM_DIST_MIN_M = MIN_SEPARATION_M
local RANDOM_DIST_MAX_M = MIN_SEPARATION_M + 20000
-- 15 000 ft in meters.
local SPAWN_ALTITUDE_M = 15000 * 0.3048
-- First-round player offset from ME center.
local FIRST_BLUE_MIN_M = 5000
local FIRST_BLUE_MAX_M = 60000
-- Respawn delays.
local RESPAWN_DELAY = 30
local PLAYER_RESPAWN_DELAY = 30

-- =====================================================================
-- Custom RNG (DCS sandbox disables math.randomseed, so we use a tiny
-- LCG seeded by os.time(). Different on every mission start, same call
-- shape as math.random(min, max).)
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
  return newCoord
end

local function moveGroup(group, coord)
  local dcsGroup = group:GetDCSObject()
  if not dcsGroup then
    return false
  end
  local dcsUnits = dcsGroup:getUnits() or {}
  for _, dcsUnit in pairs(dcsUnits) do
    if dcsUnit and dcsUnit.setPosition then
      dcsUnit:setPosition(coord:GetVec3())
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

-- =====================================================================
-- Locate the player group (the "alive" reference for distance checks).
-- Deferred by 1 s — at MISSION START the DCS world is still being
-- populated and GROUP:FindByName can return nil even though the slot
-- exists. A small SCHEDULER delay lets the world finish loading.
-- =====================================================================
local playerGroup = nil
SCHEDULER:New(nil, function()
  playerGroup = GROUP:FindByName(PLAYER_GROUP_NAME)
  if not playerGroup then
    env.error(string.format("[duel-1v1] player group '%s' still not found in ME after 1 s — check the group name and ME setup", PLAYER_GROUP_NAME))
    return
  end

  -- =====================================================================
  -- Bandit spawner (ME template "Bandit-1" with Late Activation = true).
  -- Respawn is triggered manually in the kill handler below — MOOSE's
  -- InitRepeat only fires on landing / engine shutdown, not destruction.
  -- `latestBanditGroup` is updated on every spawn so the player-respawn
  -- handler has a live reference to the alive bandit.
  -- =====================================================================
  latestBanditGroup = nil
  BanditSpawner = SPAWN:New("Bandit-1")
  if not BanditSpawner then
    env.error("[duel-1v1] SPAWN:New('Bandit-1') returned nil — check the ME has a group named exactly 'Bandit-1' with Late Activation ON")
  else
    BanditSpawner:OnSpawnGroup(function(grp)
      latestBanditGroup = grp
      env.info(string.format("[duel-1v1] bandit spawned: %s at %s", grp:GetName(), coordStr(grp:GetCoordinate())))
    end)
  end

  -- =====================================================================
  -- First-round dynamic placement
  -- =====================================================================
  local meCenter = playerGroup:GetCoordinate()
  if not meCenter then
    env.error("[duel-1v1] player group has no coordinate — skipping first-round placement")
    return
  end
  local firstBlue = randomOffsetCoord(meCenter, FIRST_BLUE_MIN_M, FIRST_BLUE_MAX_M)
  local firstRed = randomOffsetCoord(firstBlue, RANDOM_DIST_MIN_M, RANDOM_DIST_MAX_M)
  local sepM = firstBlue:Get2DDistance(firstRed)
  env.info(string.format("[duel-1v1] first-round separation: %.1f nm (%.1f mi)", sepM / 1852, sepM / 1609.344))

  if moveGroup(playerGroup, firstBlue) then
    env.info(string.format("[duel-1v1] player moved to %s", coordStr(firstBlue)))
  else
    env.error("[duel-1v1] failed to move player group")
  end

  if BanditSpawner then
    local firstGroup = BanditSpawner:SpawnFromCoordinate(firstRed)
    if firstGroup then
      env.info(string.format("[duel-1v1] bandit first spawn OK: %s at %s", firstGroup:GetName(), coordStr(firstRed)))
    else
      env.error("[duel-1v1] bandit first spawn FAILED — SpawnFromCoordinate returned nil")
    end
  end
end, {}, 1)

-- =====================================================================
-- Bandit spawner (ME template "Bandit-1" with Late Activation = true).
-- Respawn is triggered manually in the kill handler below — MOOSE's
-- InitRepeat only fires on landing / engine shutdown, not destruction.
-- `latestBanditGroup` is updated on every spawn so the player-respawn
-- handler has a live reference to the alive bandit.
-- =====================================================================
local latestBanditGroup = nil
local BanditSpawner = SPAWN:New("Bandit-1")
if not BanditSpawner then
  env.error("[duel-1v1] SPAWN:New('Bandit-1') returned nil — check the ME has a group named exactly 'Bandit-1' with Late Activation ON")
else
  BanditSpawner:OnSpawnGroup(function(grp)
    latestBanditGroup = grp
    env.info(string.format("[duel-1v1] bandit spawned: %s at %s", grp:GetName(), coordStr(grp:GetCoordinate())))
  end)
end

-- =====================================================================
-- F10 menu
-- =====================================================================
local menu = MENU_COALITION:New(coalition.side.BLUE, "Duel 1v1")

MENU_COALITION_COMMAND:New(coalition.side.BLUE, "Show kills", menu, function()
  MESSAGE:New(Tracker:format(), 10):ToCoalition(coalition.side.BLUE)
end)

MENU_COALITION_COMMAND:New(coalition.side.BLUE, "Reset kills", menu, function()
  Tracker:reset()
  MESSAGE:New("Kill counter reset", 5):ToCoalition(coalition.side.BLUE)
end)

MENU_COALITION_COMMAND:New(coalition.side.BLUE, "Respawn bandit", menu, function()
  if not BanditSpawner or not playerGroup then
    MESSAGE:New("Spawner / player group not ready", 5):ToCoalition(coalition.side.BLUE)
    return
  end
  local ref = playerGroup:GetCoordinate()
  if not ref then
    MESSAGE:New("No player position — restart mission", 5):ToCoalition(coalition.side.BLUE)
    return
  end
  local newPos = randomOffsetCoord(ref, RANDOM_DIST_MIN_M, RANDOM_DIST_MAX_M)
  local grp = BanditSpawner:SpawnFromCoordinate(newPos)
  if grp then
    MESSAGE:New("Bandit respawned", 5):ToCoalition(coalition.side.BLUE)
  else
    MESSAGE:New("Bandit respawn FAILED", 5):ToCoalition(coalition.side.BLUE)
  end
end)

-- =====================================================================
-- First-round dynamic placement
-- =====================================================================
local meCenter = playerGroup:GetCoordinate()
local firstBlue = randomOffsetCoord(meCenter, FIRST_BLUE_MIN_M, FIRST_BLUE_MAX_M)
local firstRed = randomOffsetCoord(firstBlue, RANDOM_DIST_MIN_M, RANDOM_DIST_MAX_M)
local sepM = firstBlue:Get2DDistance(firstRed)
env.info(string.format("[duel-1v1] first-round separation: %.1f nm (%.1f mi)", sepM / 1852, sepM / 1609.344))

if moveGroup(playerGroup, firstBlue) then
  env.info(string.format("[duel-1v1] player moved to %s", coordStr(firstBlue)))
else
  env.error("[duel-1v1] failed to move player group")
end

if BanditSpawner then
  local firstGroup = BanditSpawner:SpawnFromCoordinate(firstRed)
  if firstGroup then
    env.info(string.format("[duel-1v1] bandit first spawn OK: %s at %s", firstGroup:GetName(), coordStr(firstRed)))
  else
    env.error("[duel-1v1] bandit first spawn FAILED — SpawnFromCoordinate returned nil")
  end
end

-- =====================================================================
-- Kill handler: counts red-side bandit kills AND triggers respawn in one
-- go. Listens for DEAD (in-air destruction) and CRASH (post-eject wreck
-- hits ground); dedups by group name so a single kill doesn't double-
-- count or double-respawn. Respawned bandits (Bandit-1#001, #002, ...)
-- all match the "^Bandit-1" prefix.
-- =====================================================================
local countedGroups = {}
local watcher = BASE:New()
watcher:HandleEvent(EVENTS.Dead)
watcher:HandleEvent(EVENTS.Crash)

local function handleBanditKill(EventData)
  if not EventData or not EventData.IniGroup then
    return
  end
  local gname = EventData.IniGroup:GetName()
  if not gname or not gname:find("^Bandit%-1") then
    return
  end
  if EventData.IniCoalition ~= coalition.side.RED then
    return
  end
  if countedGroups[gname] then
    return
  end
  countedGroups[gname] = true
  local playerName = EventData.IniPlayerName or "Player"
  Tracker:record(playerName)
  MESSAGE:New(string.format("%s down! Kills: %d", playerName, Tracker.total), 8):ToCoalition(coalition.side.BLUE)
  if BanditSpawner and playerGroup then
    env.info(string.format("[duel-1v1] respawn scheduled in %ds after %s", RESPAWN_DELAY, gname))
    SCHEDULER:New(nil, function()
      if not BanditSpawner or not playerGroup then
        return
      end
      local ref = playerGroup:GetCoordinate()
      if not ref then
        env.error("[duel-1v1] respawn aborted: player has no coordinate")
        return
      end
      local newPos = randomOffsetCoord(ref, RANDOM_DIST_MIN_M, RANDOM_DIST_MAX_M)
      local distFromPlayer = ref:Get2DDistance(newPos)
      env.info(string.format("[duel-1v1] respawning %.1f nm from alive player", distFromPlayer / 1852))
      local grp = BanditSpawner:SpawnFromCoordinate(newPos)
      if not grp then
        env.error("[duel-1v1] bandit respawn FAILED — SpawnFromCoordinate returned nil")
      end
    end, {}, RESPAWN_DELAY)
  end
end

function watcher:OnEventDead(EventData)
  handleBanditKill(EventData)
end
function watcher:OnEventCrash(EventData)
  handleBanditKill(EventData)
end

-- =====================================================================
-- Player death handler: Teleport respawn 60+ mi from the alive bandit.
-- After Teleport, the slot reappears at the new position — the client
-- must rejoin.
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
  if not gname or not gname:find("^Aerial%-1") then
    return
  end
  if EventData.IniCoalition ~= coalition.side.BLUE then
    return
  end
  if countedGroups[gname] then
    return
  end
  countedGroups[gname] = true
  local dyingGroup = EventData.IniGroup
  MESSAGE:New(string.format("You died! Respawning in %ds — rejoin your slot", PLAYER_RESPAWN_DELAY), 10):ToCoalition(coalition.side.BLUE)
  env.info(string.format("[duel-1v1] player died (%s) — respawn in %ds", gname, PLAYER_RESPAWN_DELAY))

  SCHEDULER:New(nil, function()
    if not dyingGroup then
      return
    end
    if not latestBanditGroup then
      env.error("[duel-1v1] no alive bandit for player respawn — aborting")
      MESSAGE:New("Respawn failed: no alive bandit — restart mission", 10):ToCoalition(coalition.side.BLUE)
      return
    end
    local ok, banditPos = pcall(function()
      return latestBanditGroup:GetCoordinate()
    end)
    if not ok or not banditPos then
      env.error("[duel-1v1] could not get bandit position for player respawn")
      MESSAGE:New("Respawn failed — restart mission", 10):ToCoalition(coalition.side.BLUE)
      return
    end
    local newPos = randomOffsetCoord(banditPos, RANDOM_DIST_MIN_M, RANDOM_DIST_MAX_M)
    local distNm = banditPos:Get2DDistance(newPos) / 1852
    env.info(string.format("[duel-1v1] player respawn %.1f nm from alive bandit", distNm))
    local okTeleport, result = pcall(function()
      return dyingGroup:Teleport(newPos)
    end)
    if okTeleport and result then
      MESSAGE:New("Respawn ready — rejoin your slot", 10):ToCoalition(coalition.side.BLUE)
    else
      env.error(string.format("[duel-1v1] player respawn Teleport failed: %s", tostring(result)))
      MESSAGE:New("Respawn failed — restart mission", 10):ToCoalition(coalition.side.BLUE)
    end
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

env.info("[duel-1v1] main done")

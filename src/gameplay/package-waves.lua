-- Shared package-wave gameplay. Each mission entry supplies its own configuration.
local MISSION_CONFIG = assert(..., "package-wave mission configuration required")
-- Player slots: Aerial-1, Aerial-2, Aerial-3, Aerial-4, Aerial-5.
-- Red donors: Bandit-1 .. Bandit-6 plus Bandit-8 .. Bandit-9
-- (late-activated ME aircraft, one per donor group). Bandit-7 (F-5E-3) and
-- Bandit-10 (MiG-21) remain in the ME template but are excluded from waves. Each wave picks
-- one donor from a randomized, without-replacement difficulty-tier bag and clones it
-- to wave size, so airframe, payload, skill, chaff/flare, and ME group
-- options vary per wave.
-- Event-driven package waves: one red aircraft per live blue player, cloned
-- into a single DCS group so the AI fights as a package rather than as isolated
-- duels. A wave spawns in close formation 55–85 statute mi from the blue
-- centroid at a per-wave random altitude (15,000–25,000 ft). The package gets
-- a per-wave random CAP profile (15,000–30,000 ft, 350–550 kt). Losses
-- do not respawn individually; the next complete package launches only after
-- every aircraft in the current wave is dead. Bandits are cleaned up when every
-- player leaves.
--
-- Group options defer to the ME: the script never force-sets ROE, alarm
-- state, or reaction-on-threat on the spawned wave (or on its AUFTRAG), so
-- the per-donor ME settings carry through untouched.
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
-- allow-list; the 9 Bandit-N groups below are the active wave donors and
-- must be late activated in the ME. Bandit-7 (F-5E-3) is intentionally
-- excluded from waves but its ME template is left untouched.
local PLAYER_GROUP_NAMES = assert(MISSION_CONFIG.player_group_names, "player roster required")
local BANDIT_GROUP_NAMES = assert(MISSION_CONFIG.bandit_group_names, "opposing roster required")
local SETTINGS = MISSION_CONFIG.gameplay or {}

-- Intentional difficulty tiers, keyed by the next wave number
-- (waveNumber + 1). WAVE_TIER_EVERY = 3 steps the tier every three waves:
-- waves 1-3 (MiG-29), waves 4-6 (MiG-29/F-16), waves 7+ (modern BVR; Su-33 only when its SPAWN
-- initializes — the module may be absent on the test server).
local WAVE_TIER_EVERY = SETTINGS.wave_tier_every or 3
local WAVE_DONOR_TIERS

-- Load siblings. Bootstrap set _G.MY_SCRIPTS_ROOT to the project src/ path.
local ROOT = _G.MY_SCRIPTS_ROOT
if not ROOT then
  env.error("[duel-dynamic] MY_SCRIPTS_ROOT not set — bootstrap.lua must run first")
  return
end
local DIR = ROOT .. "gameplay/"
local Config = dofile(DIR .. "package-wave-config.lua")
assert(Config.validate(MISSION_CONFIG))
env.info("[mission] " .. MISSION_CONFIG.mission_name .. " version " .. MISSION_CONFIG.mission_version)
WAVE_DONOR_TIERS = SETTINGS.wave_donor_tiers or Config.DEFAULT_DONOR_TIERS
if env.mission and env.mission.coalition then
  assert(Config.validate_templates(MISSION_CONFIG, env.mission))
end

-- The shipping packager replaces only this resolver with an embedded table.
local function loadTelemetryModule(name)
  return dofile(ROOT .. "lib/telemetry/" .. name .. ".lua")
end

local telemetry
local function initTelemetry()
  local development = _G.TELEMETRY_DEVELOPMENT_ENABLED == true
  local shipping = _G.TELEMETRY_SHIPPING_ENABLED == true
  if not development and not shipping then
    return
  end
  -- Protect even a missing/broken integration module. Gameplay still starts.
  local ok, client = pcall(function()
    local integration = loadTelemetryModule("integration")
    return integration.new({
      mode = development and shipping and "conflict" or (development and "development" or "shipping"),
      mission_name = MISSION_CONFIG.mission_name,
      mission_version = MISSION_CONFIG.mission_version,
      -- Explicit milestone reporting: wave spawn/clear facts plus a gameplay
      -- outcome distinct from DCS session termination. Legacy runs without
      -- these capabilities keep the derived wave summary.
      capabilities = { wave_milestones = 1, gameplay_outcome = 1 },
      player_group_names = PLAYER_GROUP_NAMES,
      bandit_group_names = BANDIT_GROUP_NAMES,
      player_coalition = coalition.side.BLUE,
      bandit_coalition = coalition.side.RED,
      timer = timer,
      env = env,
      BASE = BASE,
      SCHEDULER = SCHEDULER,
      EVENTS = EVENTS,
      state = _G,
      -- <<TELEMETRY_DEV_IO_BEGIN>>
      io = io,
      lfs = lfs,
      os = os,
      -- <<TELEMETRY_DEV_IO_END>>
    }, loadTelemetryModule)
  end)
  if ok then
    telemetry = client -- Retains the complete runtime and MOOSE subscriptions.
  else
    env.warning("[telemetry] integration unavailable; gameplay continues")
  end
end

initTelemetry()
dofile(DIR .. "score.lua")

local Tracker = _G.duel_tracker
if not Tracker then
  env.error("[duel-dynamic] duel_tracker missing — check score.lua")
  return
end

-- =====================================================================
-- Spawn / distance config
-- =====================================================================
-- Distances are STATUTE miles (1609.344 m per mile). Each wave picks a
-- uniform-random donor from its difficulty tier (see WAVE_DONOR_TIERS)
-- plus a uniform-random profile:
--   spawn distance  55–85 statute mi from the blue centroid
--   spawn altitude  15,000–25,000 ft (15,000 ft floor)
--   CAP altitude    15,000–30,000 ft (AUFTRAG:NewCAP altitude, feet)
--   CAP speed       350–550 kt (AUFTRAG:NewCAP speed, knots)
local RANDOM_DIST_MIN_M = (SETTINGS.spawn_distance_min_sm or 55) * 1609.344
local RANDOM_DIST_MAX_M = (SETTINGS.spawn_distance_max_sm or 85) * 1609.344
local SPAWN_ALTITUDE_M = 15000 * 0.3048
local SPAWN_ALT_MIN_FT = SETTINGS.spawn_alt_min_ft or 15000
local SPAWN_ALT_MAX_FT = SETTINGS.spawn_alt_max_ft or 25000
local CAP_ALT_MIN_FT = SETTINGS.cap_alt_min_ft or 15000
local CAP_ALT_MAX_FT = SETTINGS.cap_alt_max_ft or 30000
local CAP_SPEED_MIN_KT = SETTINGS.cap_speed_min_kt or 350
local CAP_SPEED_MAX_KT = SETTINGS.cap_speed_max_kt or 550
-- Keep the legacy configuration key compatible with existing mission configs.
local LIVES_PER_PLAYER = SETTINGS.lives_per_player or SETTINGS.aircraft_per_player or 2
local WAVE_ESCALATION_EVERY = SETTINGS.wave_escalation_every or 3
local MAX_PACKAGE_SIZE = SETTINGS.max_package_size or 8
local RESPAWN_DELAY = SETTINGS.respawn_delay_s or 20
local WAVE_ASSEMBLY_DELAY = 3
local EMPTY_SERVER_CLEANUP_DELAY = 1
local TERMINAL_END_DELAY = 10
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
-- BANDIT_CAP_RADIUS_M: CAP zone radius in metres (only used by "CAP").
-- Code owns only the task plus the CAP radius. ROE, alarm state,
-- reaction-on-threat, and missile launch mode are per-donor ME settings the
-- user varies in the mission editor (all donors ROE=WEAPON_FREE;
-- MISSILE_ATTACK max-range on Bandit-1/5/6/8/9 vs threat-estimate on
-- Bandit-2/3/4/10; Bandit-7 is likewise threat-estimate but excluded from
-- waves). The script never force-sets group options, and it
-- nils out the options AUFTRAG:NewCAP bakes onto the mission object, so the
-- spawned group keeps its donor ME values.
local BANDIT_TASK = SETTINGS.bandit_task or "CAP"
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

local function randomOffsetCoord(refCoord, minDistM, maxDistM, spawnAltM)
  spawnAltM = spawnAltM or SPAWN_ALTITUDE_M
  local dist = randInt(minDistM, maxDistM)
  local angle = randInt(0, 359)
  local newCoord = refCoord:Translate(dist, angle)
  newCoord:SetY(spawnAltM)
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
local waveSpawners = {}
local waveSpawner = nil
local currentWaveGroup = nil
local currentWaveGroupName = nil
local currentWaveAlive = 0
local currentWaveSize = 0
local waveNumber = 0
local waveSpawnPending = false
local waveScheduleToken = 0
local occupiedPlayerSlots = {}
local countedBanditUnits = {}
local sharedAircraftRemaining = nil
local sharedPlayerCount = nil
local slotIdentity = {}
local playerIdentityName = {}
local playerAircraftByKey = {}
local playerAircraftByObject = {}
local missionTerminal = false
local warnedMissingPlayerUCID = false
local initDone = false
-- Seat -> runtime DCS unit ID. The server hook passes the raw slot ID with
-- every Blue slot request; resolving it lets the gate enforce the requested
-- seat's allowance even when the hook-side UCID string differs from the
-- mission event identity keys.
local slotGateLogged = false

local spawnWave
local scheduleWave

local function registerBanditAssets(group, donorName)
  if telemetry then
    telemetry:register_opposing_group(group, donorName)
  end
end

local function registerPlayerAssets(group)
  if telemetry then
    telemetry:register_player_group(group)
  end
end

local function anyPlayerSlotOccupied()
  return next(occupiedPlayerSlots) ~= nil
end

local function warnMissingPlayerUCID()
  if warnedMissingPlayerUCID then
    return
  end
  warnedMissingPlayerUCID = true
  env.warning("[duel-dynamic] player UCID unavailable — using the slot group name as the per-run identity")
end

local function fallbackIdentity(idx)
  warnMissingPlayerUCID()
  return PLAYER_GROUP_NAMES[idx]
end

local function identityForSlot(idx)
  return slotIdentity[idx] or fallbackIdentity(idx)
end

local function setSlotIdentity(idx, identity)
  local previous = slotIdentity[idx] or PLAYER_GROUP_NAMES[idx]
  -- Only a slot fallback is an alias; different UCIDs are different people.
  if previous ~= PLAYER_GROUP_NAMES[idx] then
    slotIdentity[idx] = identity
    return identity
  end
  if previous and previous ~= identity then
    -- A MOOSE PlayerEnterAircraft event can initially lack UCID even though
    -- the telemetry subscriber receives it. Do not let the same human split
    -- into a fallback allowance and a UCID allowance across respawns. Merge
    -- conservatively: the lower balance can only preserve recorded losses,
    -- never grant an extra aircraft.
    for _, aircraft in pairs(playerAircraftByKey) do
      if aircraft.identity == previous then
        aircraft.identity = identity
      end
    end
    if not playerIdentityName[identity] and playerIdentityName[previous] then
      playerIdentityName[identity] = playerIdentityName[previous]
    end
    playerIdentityName[previous] = nil
    env.info(
      string.format(
        "[duel-dynamic] reconciled slot identity %s from %s to %s",
        PLAYER_GROUP_NAMES[idx],
        tostring(previous),
        tostring(identity)
      )
    )
  end
  slotIdentity[idx] = identity
  return identity
end

-- Read-only slot gate. The dedicated-server hook queries this synchronously
-- on every Blue slot request (net.dostring_in -> a_do_script). All players
-- draw from the same mission-wide aircraft pool, so UCID and seat identity do
-- not affect the decision. Before the first package is assembled the gate
-- fails open because the pool has not been sized yet.
_G.duel_can_enter_blue_slot = function(ucid, slotID)
  local decision
  if missionTerminal then
    decision = false
  elseif sharedAircraftRemaining ~= nil then
    decision = sharedAircraftRemaining > 0
  end
  if decision == nil then
    decision = true
  end
  if not slotGateLogged then
    slotGateLogged = true
    env.info(
      string.format(
        "[duel-dynamic] slot gate: slotID=%s ucid_keyed=%s decision=%s",
        tostring(slotID),
        tostring(type(ucid) == "string" and ucid ~= ""),
        tostring(decision)
      )
    )
  end
  return decision
end

local function formatAircraftRemaining()
  if sharedAircraftRemaining == nil then
    return "No players yet."
  end
  return string.format("Aircraft remaining (shared pool): %d", sharedAircraftRemaining)
end

local function initializeSharedAircraftPool(playerCount)
  if sharedAircraftRemaining ~= nil then
    return
  end
  local count = playerCount or 0
  if count < 1 then
    for idx in pairs(occupiedPlayerSlots) do
      if idx then
        count = count + 1
      end
    end
  end
  count = math.max(1, count)
  sharedPlayerCount = count
  sharedAircraftRemaining = count * LIVES_PER_PLAYER
  env.info(
    string.format(
      "[duel-dynamic] initialized shared lives pool: %d joined players x %d = %d lives",
      sharedPlayerCount,
      LIVES_PER_PLAYER,
      sharedAircraftRemaining
    )
  )
end

local function enterTerminalStateIfAllAircraftLost()
  if missionTerminal or sharedAircraftRemaining == nil or sharedAircraftRemaining > 0 then
    return
  end
  missionTerminal = true
  MESSAGE:New(
    string.format(
      "MISSION COMPLETE\nAir Superiority Survival\nAll aircraft lost.\nReturning to the mission screen in %d seconds.",
      TERMINAL_END_DELAY
    ),
    TERMINAL_END_DELAY
  ):ToCoalition(coalition.side.BLUE)
  env.info(
    string.format(
      "[duel-dynamic] shared aircraft pool depleted — ending DCS mission in %d seconds",
      TERMINAL_END_DELAY
    )
  )
  if telemetry then
    telemetry:report_gameplay_over({ reason = "all-aircraft-lost" })
  end
  -- Blue remains the mission winner: this is a high-score survival mission,
  -- not a red-versus-blue victory assessment.
  -- The native shipping trigger turns this flag into a_end_mission on the
  -- next trigger evaluation; there is deliberately no missile grace period.
  if trigger and trigger.action and type(trigger.action.setUserFlag) == "function" then
    local ok, error_message = pcall(trigger.action.setUserFlag, "DUEL_SURVIVAL_END", 1)
    if not ok then
      env.error("[duel-dynamic] failed to end DCS mission: " .. tostring(error_message))
    end
  else
    env.error("[duel-dynamic] DCS mission-end flag action is unavailable")
  end
end

local function livePlayerPackage()
  local players = {}
  local sumX, sumY, sumZ = 0, 0, 0
  for idx, pname in ipairs(PLAYER_GROUP_NAMES) do
    local identity = occupiedPlayerSlots[idx] and identityForSlot(idx) or nil
    if identity and (sharedAircraftRemaining == nil or sharedAircraftRemaining > 0) then
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
    local lateral
    local trail
    if i == 4 then
      -- Complete the four-ship as a compact diamond instead of placing the
      -- fourth aircraft on a second, widely separated lateral rank.
      lateral = 0
      trail = FORMATION_TRAIL_M * 2
    else
      local side = (i % 2 == 0) and 1 or -1
      local rank = math.floor(i / 2)
      lateral = side * FORMATION_LATERAL_M * rank
      trail = FORMATION_TRAIL_M * rank
    end
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
  if grp and telemetry then
    telemetry:despawn_group(grp)
  end
  currentWaveGroup = nil
  currentWaveGroupName = nil
  currentWaveAlive = 0
  currentWaveSize = 0
  if grp then
    pcall(function()
      grp:Destroy(false)
    end)
    env.info(string.format("[duel-dynamic] wave group %s despawned", tostring(name)))
  end
end

local function taskBanditPackage(bgrp, players, playerCentroid, capAltFt, capSpeedKt)
  if not bgrp or #players == 0 then
    return
  end

  -- Defer to the ME: never force-set ROE, alarm state, or
  -- reaction-on-threat on the spawned group. AUFTRAG:NewCAP bakes
  -- optionROE/optionROT onto the mission object, and OPSGROUP only applies
  -- truthy options, so nil them out to leave the donor ME values alone.
  local fg = FLIGHTGROUP:New(bgrp)
  local mission
  local targetDescription
  if BANDIT_TASK == "CAP" then
    local capZone =
      ZONE_RADIUS:New(string.format("BanditWaveCap-%d", waveNumber), playerCentroid:GetVec2(), BANDIT_CAP_RADIUS_M)
    mission = AUFTRAG:NewCAP(capZone, capAltFt, capSpeedKt)
    mission.optionROE = nil
    mission.optionROT = nil
    mission.optionAlarm = nil
    targetDescription = string.format("blue package centroid (%d players)", #players)
  else
    mission = AUFTRAG:NewINTERCEPT(players[1].group)
    mission.optionROE = nil
    mission.optionROT = nil
    mission.optionAlarm = nil
    targetDescription = players[1].name
  end
  fg:AddMission(mission)
  env.info(
    string.format(
      "[duel-dynamic] tasked %s → %s on %s (group options defer to the ME donor settings)",
      bgrp:GetName(),
      BANDIT_TASK,
      targetDescription
    )
  )
end

local function donorTierForWave(nextWaveNumber)
  local tier = math.floor((nextWaveNumber - 1) / WAVE_TIER_EVERY) + 1
  if tier < 1 then
    tier = 1
  end
  if tier > #WAVE_DONOR_TIERS then
    tier = #WAVE_DONOR_TIERS
  end
  return tier
end

local donorBag, donorBagTier = {}, nil
local function selectWaveDonor(nextWaveNumber)
  local tier = donorTierForWave(nextWaveNumber)
  local candidates = {}
  for _, donorName in ipairs(WAVE_DONOR_TIERS[tier]) do
    if waveSpawners[donorName] then
      candidates[#candidates + 1] = donorName
    end
  end
  if #candidates == 0 then
    -- Graceful degrade: the tier has no initialized donor here (e.g. the
    -- Su-33 module is absent). Fall back to any initialized active donor.
    -- BANDIT_GROUP_NAMES excludes Bandit-7, so the fallback can never
    -- reintroduce it.
    for _, donorName in ipairs(BANDIT_GROUP_NAMES) do
      if waveSpawners[donorName] then
        candidates[#candidates + 1] = donorName
      end
    end
  end
  if #candidates == 0 then
    return nil, tier
  end
  -- Draw without replacement within each tier. Independent random draws
  -- over-weight airframes with multiple donor variants and permit long runs
  -- of identical opponents (the live run drew six MiG-29 waves).
  if donorBagTier ~= tier or #donorBag == 0 then
    donorBag, donorBagTier = candidates, tier
  end
  return table.remove(donorBag, randInt(1, #donorBag)), tier
end

spawnWave = function(reason)
  if missionTerminal then
    env.info(string.format("[duel-dynamic] mission terminal — spawn request ignored (%s)", tostring(reason)))
    return nil
  end
  if currentWaveGroup and currentWaveAlive > 0 then
    env.info(string.format("[duel-dynamic] wave %d still active — spawn request ignored", waveNumber))
    return currentWaveGroup
  end
  local nextWaveNumber = waveNumber + 1
  local donorName, tier = selectWaveDonor(nextWaveNumber)
  if not donorName then
    env.error("[duel-dynamic] cannot spawn wave: no bandit SPAWN donor is initialized")
    return nil
  end
  local spawner = waveSpawners[donorName]

  local players, playerCentroid = livePlayerPackage()
  if #players == 0 or not playerCentroid then
    env.info("[duel-dynamic] cannot spawn wave yet: no occupied player aircraft is alive")
    return nil
  end
  initializeSharedAircraftPool(#players)

  local spawnAltFt = randInt(SPAWN_ALT_MIN_FT, SPAWN_ALT_MAX_FT)
  local capAltFt = randInt(CAP_ALT_MIN_FT, CAP_ALT_MAX_FT)
  local capSpeedKt = randInt(CAP_SPEED_MIN_KT, CAP_SPEED_MAX_KT)
  local spawnCoord, bearing =
    randomOffsetCoord(playerCentroid, RANDOM_DIST_MIN_M, RANDOM_DIST_MAX_M, spawnAltFt * 0.3048)
  local heading = (bearing + 180) % 360
  local distMi = playerCentroid:Get2DDistance(spawnCoord) / 1609.344
  local extra = math.floor(waveNumber / WAVE_ESCALATION_EVERY)
  local size = math.min(#players + extra, MAX_PACKAGE_SIZE)

  spawner:InitGrouping(size)
  spawner:InitSetUnitRelativePositions(formationPositions(size, heading))
  spawner:InitHeading(heading)

  env.info(
    string.format(
      "[duel-dynamic] spawning %d-ship package %.1f mi from blue centroid, heading %03d (%s, donor %s tier %d, alt %d ft, speed %d kt%s)",
      size,
      distMi,
      heading,
      tostring(reason or "requested"),
      donorName,
      tier,
      spawnAltFt,
      capSpeedKt,
      extra > 0 and string.format(", escalation +%d", extra) or ""
    )
  )
  local grp = spawner:SpawnFromCoordinate(spawnCoord)
  if not grp then
    env.error("[duel-dynamic] package wave spawn FAILED")
    return nil
  end

  waveNumber = waveNumber + 1
  currentWaveGroup = grp
  currentWaveGroupName = grp:GetName()
  currentWaveAlive = size
  currentWaveSize = size
  taskBanditPackage(grp, players, playerCentroid, capAltFt, capSpeedKt)
  MESSAGE:New(string.format("Wave %d — hostiles inbound", waveNumber), 8)
    :ToCoalition(coalition.side.BLUE)
  -- Explicit wave milestone; intentional despawns (F10 reset, empty-server
  -- cleanup) never emit a cleared fact. Reporting never blocks gameplay.
  if telemetry then
    telemetry:report_wave_spawned({
      wave_number = waveNumber,
      wave_size = size,
      donor = donorName,
      tier = tier,
      reason = reason,
    })
  end
  return grp
end

scheduleWave = function(delay, reason)
  if missionTerminal then
    env.info(string.format("[duel-dynamic] mission terminal — wave schedule ignored (%s)", tostring(reason)))
    return
  end
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
local menu = MENU_COALITION:New(coalition.side.BLUE, MISSION_CONFIG.title)

MENU_COALITION_COMMAND:New(coalition.side.BLUE, "Show kills", menu, function()
  MESSAGE:New(Tracker:format(), 10):ToCoalition(coalition.side.BLUE)
end)

MENU_COALITION_COMMAND:New(coalition.side.BLUE, "Reset kills", menu, function()
  Tracker:reset()
  MESSAGE:New("Kills reset.", 5):ToCoalition(coalition.side.BLUE)
end)

MENU_COALITION_COMMAND:New(coalition.side.BLUE, "Respawn bandit wave", menu, function()
  if missionTerminal then
    MESSAGE:New("Mission over — no more waves.", 5):ToCoalition(coalition.side.BLUE)
    return
  end
  if not initDone then
    MESSAGE:New("Not ready yet — try again in a second.", 5):ToCoalition(coalition.side.BLUE)
    return
  end
  cancelScheduledWave()
  despawnCurrentWave()
  local grp = spawnWave("F10 forced reset")
  if grp then
    MESSAGE:New("New bandit wave inbound.", 5):ToCoalition(coalition.side.BLUE)
  else
    MESSAGE:New("No players in the air.", 5):ToCoalition(coalition.side.BLUE)
  end
end)

MENU_COALITION_COMMAND:New(coalition.side.BLUE, "Show aircraft remaining", menu, function()
  MESSAGE:New(formatAircraftRemaining(), 10):ToCoalition(coalition.side.BLUE)
end)

-- =====================================================================
-- Player enter / leave. The assembly delay groups near-simultaneous slot
-- joins into one multi-aircraft DCS group. A join during combat is included
-- in the next wave; DCS cannot add a unit to an already spawned group.
-- =====================================================================
local playerWatcher = BASE:New()
playerWatcher:HandleEvent(EVENTS.PlayerEnterAircraft)
playerWatcher:HandleEvent(EVENTS.PlayerLeaveUnit)

local function playerEventGroupName(EventData)
  if not EventData then
    return nil
  end
  if EventData.IniGroupName and EventData.IniGroupName ~= "" then
    return EventData.IniGroupName
  end
  if EventData.IniDCSGroupName and EventData.IniDCSGroupName ~= "" then
    return EventData.IniDCSGroupName
  end
  if EventData.IniGroup then
    local ok, name = pcall(function()
      return EventData.IniGroup:GetName()
    end)
    if ok then
      return name
    end
  end
  return nil
end

local function exactPlayerSlotIndex(groupName)
  for idx, playerGroupName in ipairs(PLAYER_GROUP_NAMES) do
    if groupName == playerGroupName then
      return idx
    end
  end
  return nil
end

local registerPlayerAircraft

local function onPlayerEnter(EventData)
  local gname = playerEventGroupName(EventData)
  local idx = gname and findIdxByName(gname, PLAYER_GROUP_NAMES) or nil
  if not idx then
    return
  end
  if missionTerminal then
    MESSAGE:New("Mission ending — no aircraft remaining.", 8):ToCoalition(coalition.side.BLUE)
    return
  end
  if sharedAircraftRemaining ~= nil and sharedAircraftRemaining <= 0 then
    MESSAGE:New("No aircraft remaining in the shared pool.", 8):ToCoalition(coalition.side.BLUE)
    return
  end
  occupiedPlayerSlots[idx] = true
  local ucid = EventData.IniPlayerUCID
  local identity
  if type(ucid) == "string" and ucid ~= "" then
    identity = ucid
  else
    identity = slotIdentity[idx] or fallbackIdentity(idx)
  end
  local displayName = EventData.IniPlayerName
  if type(displayName) ~= "string" or displayName == "" then
    displayName = "Player"
  end
  setSlotIdentity(idx, identity)
  playerIdentityName[identity] = displayName
  registerPlayerAircraft(EventData, false, identity)
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
  local gname = playerEventGroupName(EventData)
  local idx = gname and findIdxByName(gname, PLAYER_GROUP_NAMES) or nil
  if not idx then
    return
  end
  occupiedPlayerSlots[idx] = nil
  slotIdentity[idx] = nil
  env.info(
    string.format("[duel-dynamic] player left %s — current red package remains active", PLAYER_GROUP_NAMES[idx])
  )

  SCHEDULER:New(nil, function()
    if missionTerminal or anyPlayerSlotOccupied() then
      return
    end
    env.info("[duel-dynamic] no player slots occupied — cleaning up the bandit wave")
    cancelScheduledWave()
    despawnCurrentWave()
  end, {}, EMPTY_SERVER_CLEANUP_DELAY)
end

function playerWatcher:OnEventPlayerEnterAircraft(EventData)
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

local function eventUnitObjectId(EventData)
  local dcsUnit = EventData and EventData.IniDCSUnit or nil
  if not dcsUnit or type(dcsUnit.getID) ~= "function" then
    return nil
  end
  local ok, objectId = pcall(function()
    return dcsUnit:getID()
  end)
  if not ok or objectId == nil then
    return nil
  end
  return tostring(objectId)
end

-- Player aircraft losses consume the shared mission-wide aircraft pool. This
-- watcher is separate from the bandit watcher because both subscribe to Dead,
-- Crash, and Ejection.
local playerDeathWatcher = BASE:New()
playerDeathWatcher:HandleEvent(EVENTS.Dead)
playerDeathWatcher:HandleEvent(EVENTS.Crash)
if EVENTS.Ejection then
  playerDeathWatcher:HandleEvent(EVENTS.Ejection)
end
playerDeathWatcher:HandleEvent(EVENTS.Birth)

-- A client slot can reuse both its name and its numeric DCS ID after respawn.
-- Birth establishes a fresh incarnation; enter/rejoin alone never resets a
-- counted aircraft. Retain raw-object associations to reject late old losses.
registerPlayerAircraft = function(EventData, isBirth, identity)
  local unitName = eventUnitName(EventData)
  local objectId = eventUnitObjectId(EventData)
  if not unitName or not objectId then
    return nil
  end
  local key = unitName .. ":" .. objectId
  local raw = EventData.IniDCSUnit
  local observedTime = EventData.time
  local aircraft = playerAircraftByKey[key]
  if isBirth then
    if aircraft and aircraft.birthTime and observedTime and observedTime <= aircraft.birthTime then
      return aircraft -- repeated or out-of-order Birth
    end
    if aircraft and not observedTime and playerAircraftByObject[raw] == aircraft then
      return aircraft -- ambiguous duplicate Birth without event time
    end
    if aircraft and not aircraft.counted and not aircraft.birthTime then
      -- PlayerEnterAircraft can arrive before Birth. Complete that pending
      -- record instead of creating an orphan record for the same incarnation.
      aircraft.birthTime = observedTime
    else
      aircraft = nil
    end
  end
  if not aircraft then
    aircraft = { birthTime = isBirth and observedTime or nil, counted = false }
    playerAircraftByKey[key] = aircraft
  end
  -- Entry supplies UCID after Birth. Never attribute an old aircraft to a new
  -- occupant merely because its delayed loss arrives after a slot change.
  if identity then
    aircraft.identity = identity
  elseif isBirth then
    local ucid = EventData.IniPlayerUCID
    aircraft.identity = type(ucid) == "string" and ucid ~= "" and ucid or nil
  end
  playerAircraftByObject[raw] = aircraft
  return aircraft
end

function playerDeathWatcher:OnEventBirth(EventData)
  if not EventData or EventData.IniCoalition ~= coalition.side.BLUE then
    return
  end
  local idx = exactPlayerSlotIndex(playerEventGroupName(EventData))
  if idx then
    registerPlayerAircraft(EventData, true, identityForSlot(idx))
  end
end

local function handlePlayerLoss(EventData)
  if not EventData or EventData.IniCoalition ~= coalition.side.BLUE then
    return
  end
  local gname = playerEventGroupName(EventData)
  local idx = gname and exactPlayerSlotIndex(gname) or nil
  if not idx then
    return
  end
  local unitName = eventUnitName(EventData)
  if not unitName then
    env.warning("[duel-dynamic] player loss had no unit name — ignoring ambiguous duplicate-prone event")
    return
  end
  local objectId = eventUnitObjectId(EventData)
  if not objectId then
    env.warning("[duel-dynamic] player loss had no DCS object ID — ignoring ambiguous duplicate-prone event")
    return
  end
  local aircraftKey = unitName .. ":" .. objectId
  local aircraft = playerAircraftByObject[EventData.IniDCSUnit] or playerAircraftByKey[aircraftKey]
  if not aircraft then
    -- A loss callback is not a new slot entry. In particular, the same
    -- MOOSE/DCS object ID may be reused, so keep a counted latest record as
    -- the duplicate guard instead of creating a replacement incarnation here.
    aircraft = registerPlayerAircraft(EventData, false)
  end
  if aircraft.birthTime and EventData.time and EventData.time < aircraft.birthTime then
    return -- stale loss predating this incarnation, even if its ID was reused
  end
  if aircraft.counted then
    return
  end
  aircraft.counted = true
  playerAircraftByObject[EventData.IniDCSUnit] = aircraft

  initializeSharedAircraftPool()
  sharedAircraftRemaining = math.max(0, sharedAircraftRemaining - 1)
  local remaining = sharedAircraftRemaining
  env.info(string.format("[duel-dynamic] aircraft loss slot=%s object=%s birth=%s remaining=%d",
    PLAYER_GROUP_NAMES[idx], objectId, tostring(aircraft.birthTime), remaining))
  local text
  if remaining == 0 then
    text = "Aircraft lost — shared pool depleted."
  else
    text = string.format("Aircraft lost — %d shared aircraft remaining.", remaining)
  end
  MESSAGE:New(text, 8):ToCoalition(coalition.side.BLUE)
  enterTerminalStateIfAllAircraftLost()
end

function playerDeathWatcher:OnEventDead(EventData)
  handlePlayerLoss(EventData)
end
function playerDeathWatcher:OnEventCrash(EventData)
  handlePlayerLoss(EventData)
end
function playerDeathWatcher:OnEventEjection(EventData)
  handlePlayerLoss(EventData)
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
  MESSAGE:New(
    string.format(
      "Bandit down — team %d",
      Tracker.total
    ),
    8
  ):ToCoalition(coalition.side.BLUE)

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
  if telemetry then
    telemetry:report_wave_cleared({
      wave_number = waveNumber,
      wave_size = currentWaveSize,
      reason = "previous package defeated",
    })
  end
  currentWaveGroup = nil
  currentWaveGroupName = nil
  currentWaveSize = 0
  scheduleWave(RESPAWN_DELAY, "previous package defeated")
end

function banditWatcher:OnEventDead(EventData)
  handleBanditKill(EventData)
end
function banditWatcher:OnEventCrash(EventData)
  handleBanditKill(EventData)
end

-- MOOSE stores event subscribers as weak keys. Top-level locals can otherwise
-- be collected after this chunk returns, silently removing gameplay callbacks.
_G.duel_gameplay_watchers = { player = playerWatcher, bandit = banditWatcher, playerDeath = playerDeathWatcher }

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
  -- Each Bandit-N donor is a one-aircraft ME template. InitGrouping clones
  -- the chosen donor into a true multi-aircraft DCS group sized to the live
  -- blue package plus escalation (capped at eight) for each wave.
  waveSpawners = {}
  for _, donorName in ipairs(BANDIT_GROUP_NAMES) do
    local name = donorName
    local ok, spawner = pcall(function()
      return SPAWN:New(name)
    end)
    if not ok or not spawner then
      env.error(
        string.format(
          "[duel-dynamic] SPAWN:New('%s') failed (%s) — check ME group + Late Activation ON",
          name,
          tostring(spawner)
        )
      )
    else
      local donor = name
      spawner:OnSpawnGroup(function(grp)
        registerBanditAssets(grp, donor)
        env.info(
          string.format(
            "[duel-dynamic] package spawned: %s (donor %s) at %s",
            grp:GetName(),
            donor,
            coordStr(grp:GetCoordinate())
          )
        )
      end)
      waveSpawners[name] = spawner
    end
  end
  if next(waveSpawners) == nil then
    env.error("[duel-dynamic] no bandit SPAWN donor could be created — init not done, will retry")
    return
  end
  waveSpawner = waveSpawners["Bandit-1"]

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

  -- Catch every player already in a slot. Their PlayerEnterAircraft events may
  -- have fired before initDone. One delayed spawn then uses the full roster.
  for i, pname in ipairs(PLAYER_GROUP_NAMES) do
    if getPlayerCoord(pname) then
      occupiedPlayerSlots[i] = true
      registerPlayerAssets(GROUP:FindByName(pname))
      env.info(string.format("[duel-dynamic] %s already occupied at init — adding to first package roster", pname))
    end
  end
  local initialPlayerCount = 0
  for _ in pairs(occupiedPlayerSlots) do
    initialPlayerCount = initialPlayerCount + 1
  end
  initializeSharedAircraftPool(initialPlayerCount)

  initDone = true
  scheduleWave(WAVE_ASSEMBLY_DELAY, "initial player package assembled")
  env.info("[duel-dynamic] init done — package-wave lifecycle active")
end

-- A player group becomes alive the moment a client occupies its slot. On a
-- headless dedicated server that can be minutes after mission start, and the
-- first joiner may pick any of the five slots — so poll until ANY player
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
  -- [TEST_COMBAT] dev-only: skip the player wait for unattended runs (packager strips this comment + the clause below for shipping).
  if not anyPlayerGroupAlive() and not _G.TEST_COMBAT_ENABLED then
    env.info("[duel-dynamic] init: no player group alive yet, retrying...")
    return nil -- keep polling
  end
  doInit()
  -- Returning false makes the SCHEDULEDISPATCHER stop the timer cleanly
  -- instead of rescheduling; the initDone guard above is the safety net.
  return false
end, {}, INIT_DELAY, INIT_POLL_INTERVAL, 0, INIT_TIMEOUT)

-- =====================================================================
-- Dev-only unattended test combat (ordnance evidence). Gated by
-- _G.TEST_COMBAT_ENABLED (set by bootstrap). The packager strips this
-- entire block (from this header to the matching end marker) and asserts
-- no TEST_COMBAT strings survive in the shipping build.
-- =====================================================================
if _G.TEST_COMBAT_ENABLED then
  -- Deterministic single-shot loadout for unattended ordnance verification.
  -- The bandit template copy carries exactly ONE AAM and no guns; the blue
  -- target copy carries no weapons at all. A successful engagement then
  -- yields exactly one ordnance.fired event, so the count is assertable.
  -- Matrix knobs. Keep the defaults identical to the live-proven red cell.
  local TEST_COMBAT_MISSILE = "AIM-120C"
  local TEST_COMBAT_BLUE_MISSILE = nil
  local TEST_COMBAT_BANDIT_AIRFRAME = nil
  local TEST_COMBAT_BLUE_AIRFRAME = nil
  local TEST_COMBAT_GUN_TEST = false
  local TEST_COMBAT_PYLONS = {
    ["FA-18C_hornet"] = {
      ["AIM-120C"] = { index = 2, pylon = { CLSID = "LAU-115_2*LAU-127_AIM-120C" } },
      ["AIM-9L"] = { index = 1, pylon = { CLSID = "{AIM-9L}" } },
      ["AIM-9M"] = { index = 1, pylon = { CLSID = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}" } },
      ["AIM-9P"] = { index = 1, pylon = { CLSID = "{9BFD8C90-F7AE-4e90-833B-BFD0CED0E536}" } },
      ["AIM-9X"] = {
        index = 1,
        pylon = {
          CLSID = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}",
          settings = { NFP_VIS_DrawArgNo_57 = 0.1, NFP_PRESID = "MDRN_M_A_AIM9" },
        },
      },
    },
    ["F-16C_50"] = {
      ["AIM-120B"] = { index = 1, pylon = { CLSID = "{C8E06185-7CD6-4C90-959F-044679E90751}" } },
      ["AIM-120C"] = { index = 1, pylon = { CLSID = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" } },
      ["AIM-9X"] = { index = 2, pylon = { CLSID = "{5CE2FF2A-645A-4197-B48D-8720AC69394F}" } },
    },
    ["F-15ESE"] = {
      ["AIM-9M"] = { index = 13, pylon = { CLSID = "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}" } },
      ["AIM-120B"] = { index = 15, pylon = { CLSID = "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}" } },
      ["AIM-7M"] = { index = 11, pylon = { CLSID = "{AIM-7H}" } },
    },
    ["A-10C_2"] = {
      ["AIM-9M"] = { index = 11, pylon = { CLSID = "{DB434044-F5D0-4F1F-9BA9-B73027E18DD3}" } },
    },
    ["MiG-21Bis"] = {
      ["R-3S"] = { index = 1, pylon = { CLSID = "{R-3S}" } },
      ["R-60"] = { index = 1, pylon = { CLSID = "{R-60 2L}" } },
    },
    ["MiG-29 Fulcrum"] = {
      ["R-60"] = { index = 1, pylon = { CLSID = "{MISSILE_R-60_APU-60}" } },
      ["R-73"] = { index = 1, pylon = { CLSID = "{MISSILE_R-73_APU-73}" } },
    },
    ["Su-34"] = {
      ["R-73"] = { index = 1, pylon = { CLSID = "{FBC29BFE-3D24-4C64-B81D-941239D12249}" } },
      ["R-77"] = { index = 2, pylon = { CLSID = "{B4C01D60-A8A3-4237-BD72-CA7655BC0FE9}" } },
    },
  }
  local TEST_COMBAT_LIVERIES = {
    ["FA-18C_hornet"] = "Australia 75 Sqn RAAF",
    ["F-16C_50"] = "default",
    ["A-10C_2"] = "104th FS Maryland ANG, Baltimore (MD)",
    ["MiG-29 Fulcrum"] = "Air Force Standard",
    ["Su-34"] = "Russian Air Force",
  }
  -- Mission-file payload shape (see the dev .miz `mission` table): pylons by
  -- index plus fuel/countermeasures. gun = 0 removes the M61 entirely so the
  -- bandit cannot add gun shots to the ordnance count.
  local function testCombatPayload(pylonIndex, pylonTable, gun)
    local pylons = pylonIndex and { [pylonIndex] = pylonTable } or {}
    return {
      pylons = pylons,
      fuel = 4900,
      flare = 60,
      ammo_type = 1,
      chaff = 60,
      gun = gun or 0,
    }
  end
  -- SPAWN hands the spawner's SpawnTemplate table straight to
  -- coalition.addGroup via DATABASE:Spawn -- but only when TweakedTemplate
  -- is true (NewFromTemplate sets it). SPAWN:New-based spawners keep it
  -- false, in which case SPAWN:_Prepare re-fetches a fresh copy from the
  -- shared _DATABASE template on every spawn and silently ignores the
  -- spawner's own SpawnTemplate. The block below flips the flag on
  -- waveSpawner so the payload overwrites control the spawned units'
  -- weapons without touching the shared _DATABASE template.
  local function setTemplatePayload(spawner, payload)
    local units = spawner and spawner.SpawnTemplate and spawner.SpawnTemplate.units
    if type(units) ~= "table" then
      return false
    end
    local applied = false
    for _, unit in pairs(units) do
      if type(unit) == "table" then
        unit.payload = payload
        applied = true
      end
    end
    return applied
  end

  local function setTemplateType(spawner, airframe_type, livery_id)
    local units = spawner and spawner.SpawnTemplate and spawner.SpawnTemplate.units
    if type(units) ~= "table" then
      return false
    end
    local applied = false
    for _, unit in pairs(units) do
      if type(unit) == "table" then
        unit.type = airframe_type
        if livery_id then
          unit.livery_id = livery_id
        end
        applied = true
      end
    end
    return applied
  end

  SCHEDULER:New(nil, function()
    if not initDone then
      return nil -- wait for doInit (runs early when TEST_COMBAT skips the player-wait)
    end
    if currentWaveGroup and currentWaveAlive > 0 then
      return false -- a wave is already active; do not double-spawn
    end

    -- 1. Blue AI reference position: the Aerial-1 player-slot location (a
    --    sensible blue-side coordinate). Aerial-1..5 are player/client slots,
    --    which DCS refuses to materialize via coalition.addGroup, so the blue
    --    ME template cannot be spawned directly. We only need its position +
    --    blue country id here (both are registered in the _DATABASE).
    local aerialTemplate = _DATABASE
      and _DATABASE.Templates
      and _DATABASE.Templates.Groups
      and _DATABASE.Templates.Groups["Aerial-1"]
      and _DATABASE.Templates.Groups["Aerial-1"].Template
    local blueX = aerialTemplate and aerialTemplate.x
    local blueY = aerialTemplate and aerialTemplate.y
    local blueCountryID = aerialTemplate and aerialTemplate.CountryID
    if not blueX or not blueY or not blueCountryID then
      env.error("[duel-dynamic][test-combat] Aerial-1 template position/country unavailable")
      return false
    end
    local blueRefCoord = COORDINATE:New(blueX, SPAWN_ALTITUDE_M, blueY)

    -- 2. Blue AI fighter: reuse the Bandit-1 template (a spawnable AI F/A-18C
    --    with real A/A weapons: AIM-120C, AIM-9) and recolor it blue via the
    --    proven MOOSE SPAWN path (InitCoalition + InitCountry). The custom
    --    "TestCombat-Blue" prefix keeps its name distinct from the real bandit
    --    so the two do not collide in MOOSE bookkeeping or the telemetry
    --    roster; _Prepare reassigns the STN so there is no datalink clash.
    local blueTemplate = _DATABASE
      and _DATABASE.Templates
      and _DATABASE.Templates.Groups
      and _DATABASE.Templates.Groups["Bandit-1"]
      and _DATABASE.Templates.Groups["Bandit-1"].Template
    if not blueTemplate then
      env.error("[duel-dynamic][test-combat] Bandit-1 template not found in _DATABASE")
      return false
    end
    local blueSpawner
    local okNew, newErr = pcall(function()
      blueSpawner = SPAWN:NewFromTemplate(blueTemplate, "TestCombat-Blue")
    end)
    if not okNew or not blueSpawner then
      env.error("[duel-dynamic][test-combat] failed to create blue SPAWN: " .. tostring(newErr))
      return false
    end
    blueSpawner:InitCoalition(coalition.side.BLUE)
    blueSpawner:InitCountry(blueCountryID) -- blue country (CJTF Blue) from the Aerial-1 template
    blueSpawner:InitGrouping(1)

    -- 3. Spawn a 1-ship bandit wave a SHORT distance from the blue AI. The
    --    normal wave distance (60+ nm) would take many minutes to close, far
    --    beyond the unattended hook's auto-stop budget; 15 nm lets the two
    --    INTERCEPT-tasked, WEAPON_FREE aircraft merge and launch within the
    --    run window.
    local tcDistM = 15 * 1609.344 -- 15 nm test-combat engagement distance
    local banditCoord, bearing = randomOffsetCoord(blueRefCoord, tcDistM, tcDistM)
    local banditHeading = (bearing + 180) % 360 -- bandit heads toward the blue
    local blueHeading = bearing % 360 -- blue heads toward the bandit
    blueSpawner:InitHeading(blueHeading)
    waveSpawner:InitGrouping(1)
    waveSpawner:InitSetUnitRelativePositions(formationPositions(1, banditHeading))
    waveSpawner:InitHeading(banditHeading)
    -- 3b. Apply the deterministic single-shot loadouts to this spawner's
    --     template copies (bandit: exactly one AAM; blue: no weapons).
    -- waveSpawner was built with SPAWN:New (TweakedTemplate=false), which
    -- makes SPAWN:_Prepare re-fetch a fresh template copy from the shared
    -- _DATABASE on every spawn and silently ignore the spawner's own
    -- SpawnTemplate. Flipping the flag routes _Prepare to the spawner's
    -- own template table (the documented "user made template" path), so
    -- the payload overwrites below reach coalition.addGroup via
    -- DATABASE:Spawn. blueSpawner (SPAWN:NewFromTemplate) already has
    -- TweakedTemplate=true.
    waveSpawner.TweakedTemplate = true
    local bandit_airframe = TEST_COMBAT_BANDIT_AIRFRAME or "FA-18C_hornet"
    local blue_airframe = TEST_COMBAT_BLUE_AIRFRAME or "FA-18C_hornet"
    local type_ok, type_result = pcall(function()
      return setTemplateType(waveSpawner, bandit_airframe, TEST_COMBAT_LIVERIES[bandit_airframe])
        and setTemplateType(blueSpawner, blue_airframe, TEST_COMBAT_LIVERIES[blue_airframe])
    end)
    if not type_ok or not type_result then
      env.error("[duel-dynamic][test-combat] template type not settable on both spawners")
      return false
    end

    local bandit_missile
    local blue_missile
    if TEST_COMBAT_GUN_TEST then
      -- Both aircraft use their guns; no AAM pylon is armed.
    elseif TEST_COMBAT_BLUE_MISSILE ~= nil then
      blue_missile = TEST_COMBAT_PYLONS[blue_airframe] and TEST_COMBAT_PYLONS[blue_airframe][TEST_COMBAT_BLUE_MISSILE]
      if not blue_missile then
        env.error(
          "[duel-dynamic][test-combat] missing pylon cell: airframe="
            .. tostring(blue_airframe)
            .. " weapon="
            .. tostring(TEST_COMBAT_BLUE_MISSILE)
        )
        return false
      end
    else
      bandit_missile = TEST_COMBAT_PYLONS[bandit_airframe] and TEST_COMBAT_PYLONS[bandit_airframe][TEST_COMBAT_MISSILE]
      if not bandit_missile then
        env.error(
          "[duel-dynamic][test-combat] missing pylon cell: airframe="
            .. tostring(bandit_airframe)
            .. " weapon="
            .. tostring(TEST_COMBAT_MISSILE)
        )
        return false
      end
    end

    local payload_ok, payload_result = pcall(function()
      local bandit_payload = bandit_missile and testCombatPayload(bandit_missile.index, bandit_missile.pylon, 0)
        or testCombatPayload(nil, nil, TEST_COMBAT_GUN_TEST and 100 or 0)
      local blue_payload = blue_missile and testCombatPayload(blue_missile.index, blue_missile.pylon, 0)
        or testCombatPayload(nil, nil, TEST_COMBAT_GUN_TEST and 100 or 0)
      return setTemplatePayload(waveSpawner, bandit_payload) and setTemplatePayload(blueSpawner, blue_payload)
    end)
    if not payload_ok or not payload_result then
      env.error("[duel-dynamic][test-combat] template payload not settable on both spawners")
      return false
    end
    env.info(
      string.format(
        "[duel-dynamic][test-combat] matrix cell: bandit=%s %s blue=%s %s gun_test=%s",
        bandit_airframe,
        bandit_missile and TEST_COMBAT_MISSILE or "no AAM",
        blue_airframe,
        blue_missile and TEST_COMBAT_BLUE_MISSILE or "no AAM",
        tostring(TEST_COMBAT_GUN_TEST)
      )
    )
    local banditGrp = waveSpawner:SpawnFromCoordinate(banditCoord)
    if not banditGrp then
      env.error("[duel-dynamic][test-combat] failed to spawn bandit wave")
      return false
    end
    waveNumber = waveNumber + 1
    currentWaveGroup = banditGrp
    currentWaveGroupName = banditGrp:GetName()
    currentWaveAlive = 1
    currentWaveSize = 1
    env.info(
      string.format("[duel-dynamic][test-combat] bandit wave %d spawned at %s", waveNumber, coordStr(banditCoord))
    )
    if telemetry then
      telemetry:report_wave_spawned({ wave_number = waveNumber, wave_size = 1, reason = "test-combat" })
    end

    -- 4. Spawn the blue AI at the reference position, headed toward the bandit.
    local okSpawn, blueGrp = pcall(function()
      return blueSpawner:SpawnFromCoordinate(blueRefCoord)
    end)
    if not okSpawn or not blueGrp then
      env.error("[duel-dynamic][test-combat] failed to spawn blue AI: " .. tostring(blueGrp))
      return false
    end
    local name_ok, blue_group_name = pcall(function()
      return blueGrp:GetName()
    end)
    if not name_ok or type(blue_group_name) ~= "string" or blue_group_name == "" then
      env.error("[duel-dynamic][test-combat] failed to read blue AI group name: " .. tostring(blue_group_name))
      return false
    end
    env.info("[duel-dynamic][test-combat] blue AI spawned: " .. blue_group_name)

    local runtime = _G.duel_telemetry_runtime
    if runtime and type(runtime.shot) == "table" and type(runtime.asset) == "table" then
      local shot_ok, shot_result, shot_error = pcall(function()
        return runtime.shot:extend_player_roster({ blue_group_name })
      end)
      if not shot_ok or shot_result ~= true then
        env.error(
          "[duel-dynamic][test-combat] failed to extend shot player roster: " .. tostring(shot_error or shot_result)
        )
      end

      local asset_ok, asset_result, asset_error = pcall(function()
        return runtime.asset:extend_player_roster({ blue_group_name })
      end)
      if not asset_ok or asset_result ~= true then
        env.error(
          "[duel-dynamic][test-combat] failed to extend asset player roster: " .. tostring(asset_error or asset_result)
        )
      else
        local register_ok, register_result, register_error = pcall(function()
          return runtime.asset:register_player_group(blueGrp)
        end)
        if not register_ok or register_result == nil then
          env.error(
            "[duel-dynamic][test-combat] failed to register blue AI asset: "
              .. tostring(register_error or register_result)
          )
        end
      end
    end

    -- 5. Task both sides: INTERCEPT + WEAPON_FREE + RED alarm.
    local function taskIntercept(grp, targetGrp, label)
      if not grp or not targetGrp then
        return
      end
      pcall(function()
        grp:OptionROEOpenFireWeaponFree()
      end)
      pcall(function()
        grp:OptionAlarmStateRed()
      end)
      local fg = FLIGHTGROUP:New(grp)
      local mission = AUFTRAG:NewINTERCEPT(targetGrp)
      mission.optionROE = ENUMS.ROE.OpenFireWeaponFree
      mission.optionAlarm = ENUMS.AlarmState.Red
      fg:AddMission(mission)
      env.info(string.format("[duel-dynamic][test-combat] %s tasked INTERCEPT -> %s", label, targetGrp:GetName()))
    end
    taskIntercept(banditGrp, blueGrp, "bandit")
    taskIntercept(blueGrp, banditGrp, "blue AI")

    -- 6. Stop the SCHEDULER (one-shot).
    return false
  end, {}, 5, 1) -- wait for initDone, then poll every 1 s
end
-- <<TEST_COMBAT_BLOCK_END>>

env.info("[duel-dynamic] main done (init pending)")

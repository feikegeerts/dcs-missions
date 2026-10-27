-- Chinook / UH-60L extraction using the repository's pinned MOOSE CTLD.
-- No telemetry, disk access, MIST, persistence, or native mission end.
local config, Operation, Voice = ...
assert(not _G.OHP_TRANSPORT_TEST, "Hidden Passage is already initialized")
local runtime = { config = config }
_G.OHP_TRANSPORT_TEST = runtime -- Retain menus, CTLD, and timers strongly.
local voice = Voice.new(config)
runtime.voice = voice
local transports = {
  { name = config.player_unit, group = config.player_group, type = "CH-47Fbl1", callsign = "Mule One" },
  { name = config.support_unit, group = config.support_group, type = "UH-60L", callsign = "Raven One" },
}
local transport_by_name = {}
for _, spec in ipairs(transports) do
  transport_by_name[spec.name] = spec
end
runtime.menus, runtime.auto_pickup = {}, {}

local function log(text)
  env.info("[hidden-passage] " .. text)
end

local function say(text, unit)
  local message = MESSAGE:New(text, 20, config.title)
  if unit then
    message:ToUnit(unit)
  else
    message:ToCoalition(coalition.side.BLUE)
  end
  log(text)
end

local function radio_active()
  local objective = runtime.objective
  return not objective or (objective.phase ~= "failed" and objective.phase ~= "complete")
end

local function radio(id, valid, announcement)
  voice:radio(id, function()
    return radio_active() and (not valid or valid())
  end, announcement)
end

local function configured_slot(unit, slots)
  if not unit then
    return
  end
  local ok, group_name, type_name, player_name = pcall(function()
    if unit.isExist and not unit:isExist() then
      return
    end
    local group = unit:getGroup()
    return group and group:getName(), unit:getTypeName(), unit:getPlayerName()
  end)
  if ok and player_name and player_name ~= "" and group_name and slots[group_name] == type_name then
    return group_name
  end
end

local function role_occupied(slots)
  local ok, players = pcall(coalition.getPlayers, coalition.side.BLUE)
  if ok and type(players) == "table" then
    for _, unit in pairs(players) do
      if configured_slot(unit, slots) then
        return true
      end
    end
  end
  return false
end

-- Snapshot only successfully spawned threat units. Disappearance alone is not
-- proof of destruction: RTB/despawn must not produce a false victory report.
runtime.threat_reports, runtime.threat_deaths = {}, {}
local function track_report(branch, id, slots)
  local ok, units = pcall(function()
    local found = {}
    for _, unit in pairs(assert(branch.group:GetUnits(), "spawned units unavailable")) do
      found[#found + 1] = { unit = unit, name = unit:GetName() }
    end
    assert(#found > 0, "no spawned units to track")
    return found
  end)
  if not ok then
    env.error("[hidden-passage] report tracking " .. id .. ": " .. tostring(units))
    return
  end
  runtime.threat_reports[#runtime.threat_reports + 1] = {
    branch = branch,
    units = units,
    id = id,
    slots = slots,
  }
end

local function update_threat_reports()
  if not radio_active() then
    return
  end
  for _, report in ipairs(runtime.threat_reports) do
    if not report.done then
      local ok, destroyed = pcall(function()
        for _, record in ipairs(report.units) do
          if not runtime.threat_deaths[record.name] then
            local life = record.unit:GetLife()
            -- GetLife == -1 means the wrapper cannot find the unit. Require a
            -- destruction event in that case, or a known life value below 1.
            if not life or life < 0 or life >= 1 then
              return false
            end
          end
        end
        return true
      end)
      if ok and destroyed then
        report.done, report.branch.destroyed = true, true
        report.branch.destroyed_at = timer.getTime()
        log("Threat destroyed: " .. report.id)
        local slots = report.slots
        if role_occupied(slots) then
          radio(report.id, function()
            return role_occupied(slots)
          end)
        end
      elseif not ok and not report.observation_error then
        report.observation_error = true
        env.error("[hidden-passage] threat report observation (will retry): " .. tostring(destroyed))
      elseif ok then
        report.observation_error = false
      end
    end
  end
end

-- Freeze both optional branches from ONE roster at the first human Blue takeoff.
-- Register before setup's delayed timer so a very early departure is not missed.
runtime.cas_convoy = { state = "waiting_for_first_blue_takeoff" }
runtime.cas_checkpoint = { state = "waiting_for_first_blue_takeoff" }
local function spawn_cas_checkpoint(reason)
  local checkpoint = runtime.cas_checkpoint
  if checkpoint.state ~= "waiting_for_pickup" or not radio_active() then
    return
  end
  local objective = runtime.objective
  if not objective or (objective.phase ~= "aboard" and reason ~= "solo_test") then
    return
  end
  checkpoint.release_reason = reason or "pickup_confirmed"
  checkpoint.state = "spawning"
  if not GROUP:FindByName(config.cas.checkpoint_template) then
    checkpoint.state = "unavailable"
    log("CAS checkpoint unavailable: missing template " .. config.cas.checkpoint_template)
    return
  end
  local ok, spawned = pcall(function()
    local spawner = SPAWN:New(config.cas.checkpoint_template):InitLimit(0, 1)
    local group = assert(spawner:Spawn(), "MOOSE did not spawn the RPG checkpoint")
    assert(group:IsAlive(), "RPG checkpoint spawned without live units")
    return { spawner = spawner, group = group }
  end)
  if not ok then
    checkpoint.state = "unavailable"
    env.error("[hidden-passage] CAS checkpoint spawn: " .. tostring(spawned))
    return
  end
  checkpoint.state = "active"
  checkpoint.spawner, checkpoint.group = spawned.spawner, spawned.group
  track_report(checkpoint, "cas_checkpoint_cleared", config.cas.slots)
  radio(
    "cas_checkpoint_tasking",
    function()
      return not checkpoint.destroyed
        and checkpoint.group:IsAlive()
        and (runtime.objective.phase == "aboard" or checkpoint.release_reason == "solo_test")
    end,
    "CAS: the package is aboard. RPG infantry are holding the north-road checkpoint. Clear that position and cover the helicopters' departure."
  )
  log(
    "CAS RPG checkpoint spawned once: " .. config.cas.checkpoint_template .. "; release=" .. checkpoint.release_reason
  )
end
local function start_cas(occupied_slot)
  local branch = runtime.cas_convoy
  branch.state = "deciding"
  if not occupied_slot then
    branch.state = "disabled"
    runtime.cas_checkpoint.state = "disabled"
    log("CAS branch disabled at first Blue takeoff: no configured CAS slot occupied")
    return
  end

  -- Freeze eligibility now, but do not activate or brief the checkpoint until
  -- a validated extraction receipt confirms all three aboard either carrier.
  -- A missing convoy still must not prevent the later checkpoint stage.
  runtime.cas_checkpoint.state = "waiting_for_pickup"
  local template = GROUP:FindByName(config.cas.convoy_template)
  if not template then
    branch.state = "unavailable"
    log("CAS branch unavailable: missing convoy template " .. config.cas.convoy_template)
    return
  end
  branch.state = "spawning"
  local spawn_ok, spawned = pcall(function()
    local spawner = SPAWN:New(config.cas.convoy_template):InitLimit(0, 1)
    local group = assert(spawner:Spawn(), "MOOSE did not spawn the CAS convoy")
    assert(group:IsAlive(), "CAS convoy spawned without live units")
    -- Keep the surviving vehicles on their authored route under attack. This
    -- disables DCS's automatic dispersal, not physical wreck/pathfinding jams.
    group:OptionDisperseOnAttack(0)
    return { spawner = spawner, group = group }
  end)
  if not spawn_ok then
    branch.state = "unavailable"
    env.error("[hidden-passage] CAS convoy spawn: " .. tostring(spawned))
    log("CAS branch unavailable: convoy spawn failed")
    return
  end
  branch.state = "active"
  branch.slot = occupied_slot
  branch.spawner = spawned.spawner
  branch.group = spawned.group
  track_report(branch, "cas_convoy_destroyed", config.cas.slots)
  say(
    "Ground intel: an enemy convoy is advancing toward the pickup. CAS, intercept it along the road; keep attacks clear of the extraction party."
  )
  radio("cas_convoy_tasking", function()
    return runtime.cas_checkpoint.state == "waiting_for_pickup" and not branch.destroyed and branch.group:IsAlive()
  end)
  log("CAS convoy spawned once; first-takeoff snapshot found " .. occupied_slot)
  log("CAS convoy automatic dispersal disabled; survivors retain the editor route")
end

runtime.cap = {
  state = "waiting_for_first_blue_takeoff",
  sam = { state = "waiting_for_first_blue_takeoff" },
  fighters = { state = "waiting_for_first_blue_takeoff" },
  hind = { state = "waiting_for_first_blue_takeoff" },
}
local function cap_inactive(state)
  local cap = runtime.cap
  cap.state, cap.sam.state, cap.fighters.state, cap.hind.state = state, state, state, state
end

local function update_hind_tasking()
  local cap = runtime.cap
  local hind = cap.hind
  if
    not radio_active()
    or not cap.fighters.destroyed
    or hind.state ~= "active"
    or hind.destroyed
    or hind.tasking_queued
  then
    return
  end
  local alive_ok, alive = pcall(function()
    return hind.group:IsAlive()
  end)
  if not alive_ok or not alive then
    return -- A transient DCS lookup cannot fail extraction or invent a task.
  end
  -- The Hind already spawned with the fighters. Only its tasking waits for
  -- confirmed destruction of every fighter, then the normal reporting pause.
  hind.tasking_queued = true
  radio("hind_launching", function()
    return not hind.destroyed and hind.group:IsAlive()
  end, "CAP: an enemy Hind is preparing to launch. Watch for a low-level threat along the extraction corridor.")
  log("CAP Hind tasking released after confirmed fighter destruction")
end

local function spawn_cap_group(branch, template, on_ready, runway)
  branch.state = "spawning"
  local ok, result = pcall(function()
    local authored = assert(GROUP:FindByName(template), "missing template " .. template)
    local expected_units = on_ready and #assert(authored:GetTemplate(), "missing aircraft template").units
    if on_ready then
      assert(expected_units > 0, "empty aircraft template")
    end
    local spawner = SPAWN:New(template):InitLimit(0, 1)
    local group
    if runway then
      local first = assert(authored:GetTemplateRoutePoints()[1], "missing departure waypoint")
      local airbase = assert(AIRBASE:FindByID(first.airdromeId), "missing authored airfield")
      -- Only the approved MiG departure is changed. The pinned MOOSE method
      -- replaces the departure point/parking, not the subsequent route/tasks.
      -- Never silently fall back to an airborne spawn if the runway is blocked.
      group = spawner:SpawnAtAirbase(airbase, SPAWN.Takeoff.Runway, nil, nil, false)
    else
      group = spawner:Spawn()
    end
    assert(group, "MOOSE did not spawn " .. template)
    if not on_ready then
      assert(group:IsAlive(), template .. " spawned without live units")
    end
    return { spawner = spawner, group = group, expected_units = expected_units }
  end)
  if not ok then
    branch.state = "unavailable"
    env.error("[hidden-passage] CAP spawn " .. template .. ": " .. tostring(result))
    return
  end
  branch.spawner, branch.group = result.spawner, result.group
  if on_ready then
    local deadline = timer.getTime() + config.cap.spawn_ready_timeout_s
    local function confirm_ready()
      if branch.state ~= "spawning" then
        return
      end
      local ready_ok, ready = pcall(function()
        return branch.group:IsAlive() and #branch.group:GetUnits() == result.expected_units
      end)
      if ready_ok and ready then
        branch.state = "active"
        log(string.format("CAP group spawned once: %s; ready t=%.1f", template, timer.getTime()))
        local callback_ok, err = pcall(on_ready)
        if not callback_ok then
          env.error("[hidden-passage] CAP ready callback " .. template .. ": " .. tostring(err))
        end
      elseif timer.getTime() < deadline then
        -- Aircraft birth can be asynchronous even though Spawn returned a
        -- wrapper. Retain it and retry observation, never the actual spawn.
        branch.readiness_timer = TIMER:New(confirm_ready)
        branch.readiness_timer:Start(1)
      else
        branch.state = "unavailable"
        env.error("[hidden-passage] CAP spawn readiness timed out: " .. template)
      end
    end
    confirm_ready()
  else
    branch.state = "active"
    log("CAP group spawned once: " .. template)
  end
  return result.group
end

local function observe_cap_sam()
  local cap = runtime.cap
  if cap.state ~= "sam_active" then
    return
  end
  local ok, destroyed = pcall(function()
    for _, radar in ipairs(cap.radars) do
      -- IsAlive alone tests existence/activation in the pinned MOOSE build.
      -- DCS can retain a cooking-off wreck: life < 1 is also destroyed.
      if radar:IsAlive() and radar:GetLife() >= 1 then
        return false
      end
    end
    return true
  end)
  if not ok then
    if not cap.observation_error then
      env.error("[hidden-passage] CAP radar observation (will retry): " .. tostring(destroyed))
    end
    cap.observation_error = true
  else
    cap.observation_error = false
    if destroyed then
      -- Latch BEFORE spawning either group. No later takeoff/poll can duplicate
      -- the response; failure of one aircraft template must not block the other.
      cap.state, cap.sam.state = "air_response", "neutralised"
      cap.sam_destroyed_at = timer.getTime()
      log("CAP SAM neutralised: all tracked Kub radars destroyed; releasing air response")
      radio(
        "kub_neutralised",
        nil,
        "SEAD: the Kub tracking radar is destroyed. CAP, cover the extraction corridor; helicopter crews, remain alert for other threats."
      )
      spawn_cap_group(cap.fighters, config.cap.fighters_template, function()
        track_report(cap.fighters, "cap_fighters_destroyed", config.cap.slots)
        radio("fighters_launching", function()
          return not cap.fighters.destroyed and cap.fighters.group:IsAlive()
        end, "CAP: enemy fighters are preparing to launch. Expect an interception; protect the extraction package.")
      end, config.cap.fighters_runway_start)
      spawn_cap_group(cap.hind, config.cap.hind_template, function()
        track_report(cap.hind, "cap_hind_destroyed", config.cap.slots)
        update_hind_tasking() -- Also handles a delayed Hind birth after the fighters are already down.
      end)
      return
    end
  end
  -- One-shot re-arming: no persistent polling after completion, and errors do
  -- not silently kill the watch. Keep the latest MOOSE timer strongly held.
  cap.observer = TIMER:New(observe_cap_sam)
  cap.observer:Start(config.cap.radar_check_interval_s)
end

local function start_cap(occupied_slot)
  local cap = runtime.cap
  if not occupied_slot then
    cap_inactive("disabled")
    log("CAP branch disabled at first Blue takeoff: no configured CAP slot occupied")
    return
  end
  cap.slot = occupied_slot
  cap.fighters.state, cap.hind.state = "waiting_for_sam", "waiting_for_sam"
  local sam = spawn_cap_group(cap.sam, config.cap.sam_template)
  if not sam then
    cap.state = "unavailable"
    return
  end
  local ok, radars = pcall(function()
    local found = {}
    for _, unit in pairs(assert(sam:GetUnits(), "SAM units unavailable")) do
      if unit:GetTypeName() == config.cap.radar_type then
        found[#found + 1] = unit
      end
    end
    assert(#found > 0, "spawned SAM has no " .. config.cap.radar_type)
    return found
  end)
  if not ok then
    cap.state = "unavailable"
    env.error("[hidden-passage] CAP radar tracking unavailable; air response held: " .. tostring(radars))
    return
  end
  cap.state, cap.radars = "sam_active", radars
  log("CAP first-takeoff snapshot found " .. occupied_slot .. "; tracking " .. #radars .. " Kub radar(s)")
  say(
    "SEAD: a Kub SAM site is active near the pickup. Destroy its tracking radar before helicopter approach; CAP, then cover the extraction corridor."
  )
  radio("sead_tasking", function()
    return cap.state == "sam_active"
  end)
  cap.observer = TIMER:New(observe_cap_sam)
  cap.observer:Start(config.cap.radar_check_interval_s)
end

local destruction_events = {}
for _, id in pairs({ world.event.S_EVENT_DEAD, world.event.S_EVENT_CRASH, world.event.S_EVENT_UNIT_LOST }) do
  destruction_events[id] = true
end

-- Retain the existing handler name for inspection; it owns participation
-- decisions and the narrow native-DCS destruction-event bridge, without pilot departure calls.
runtime.cas_decision_handler = {
  onEvent = function(_, event)
    if not event then
      return
    end
    if event.id and destruction_events[event.id] then
      local ok, name = pcall(function()
        return event.initiator:getName()
      end)
      if ok and name then
        runtime.threat_deaths[name] = true
      end
      return
    end
    if event.id ~= world.event.S_EVENT_TAKEOFF then
      return
    end
    local aircraft = event.initiator
    local ok, side, player_name = pcall(function()
      return aircraft:getCoalition(), aircraft:getPlayerName()
    end)
    if not ok or side ~= coalition.side.BLUE or not player_name or player_name == "" then
      return
    end
    if runtime.package_decided then
      return
    end
    runtime.package_decided = true
    local roster_ok, blue_players = pcall(coalition.getPlayers, coalition.side.BLUE)
    if not roster_ok or type(blue_players) ~= "table" then
      runtime.cas_convoy.state, runtime.cas_checkpoint.state = "unavailable", "unavailable"
      cap_inactive("unavailable")
      log("CAS/CAP branches unavailable: could not snapshot Blue player slots at first takeoff")
      return
    end
    local cas_slot = configured_slot(aircraft, config.cas.slots)
    local cap_slot = configured_slot(aircraft, config.cap.slots)
    for _, unit in pairs(blue_players) do
      cas_slot = cas_slot or configured_slot(unit, config.cas.slots)
      cap_slot = cap_slot or configured_slot(unit, config.cap.slots)
    end
    -- Freeze both selections before invoking any spawn code.
    runtime.package_slots = { cas = cas_slot, cap = cap_slot }
    start_cap(cap_slot)
    start_cas(cas_slot)
  end,
}
world.addEventHandler(runtime.cas_decision_handler)

local function is_party(group_name)
  return type(group_name) == "string" and group_name:sub(1, #config.party_template + 1) == config.party_template .. "-"
end

local function carrier(name)
  name = name or runtime.carrier_name
  local spec = name and transport_by_name[name]
  if not spec then
    return
  end
  local unit = UNIT:FindByName(name)
  if unit and unit:IsAlive() and unit:GetTypeName() == spec.type then
    return unit, unit:GetID()
  end
end

local function loaded_count(ctld, name)
  -- Narrow read of the pinned CTLD ledger: extraction reserves cargo before
  -- its delayed TroopsExtracted callback. Observe that to distinguish boarding
  -- from destruction of an uncollected ground party. No CTLD internals changed.
  if name then
    local loaded = ctld.Loaded_Cargo[name]
    return loaded and loaded.Troopsloaded or 0
  end
  local count = 0
  for _, spec in ipairs(transports) do
    count = count + loaded_count(ctld, spec.name)
  end
  return count
end

local function report_failure()
  local objective = runtime.objective
  if not objective or objective.phase ~= "failed" or runtime.failure_reported then
    return
  end
  if not runtime.failure_report_at then
    -- Lock the deadline on first detection. The regular observer publishes
    -- the text after the same pause; repeated checks cannot postpone it.
    local delay = config.overlord_confirmation_delay_s
    runtime.failure_report_at = timer.getTime() + delay
    voice:abort(delay) -- Invalidate pending crew/success/intel calls right now.
  end
  if timer.getTime() < runtime.failure_report_at then
    return
  end
  runtime.failure_reported = true
  say(
    "Operation failed: "
      .. tostring(objective.reason)
      .. " Restart the mission to retry; re-slotting does not reset the operation."
  )
end

local stop_firefight
local stop_pickup_opposition

local function fail(reason)
  runtime.objective:fail(reason)
  if stop_firefight then
    stop_firefight("objective failed")
  end
  if stop_pickup_opposition then
    stop_pickup_opposition("objective failed")
  end
  report_failure()
end

local function status(name)
  local recipient = carrier(name)
  local objective = runtime.objective
  if not objective then
    say("Extraction is not ready. Check the DCS log for the setup error.", recipient)
    return
  end
  local messages = {
    waiting = string.format(
      "Pickup is %.1f NM from Hatay. Land near green smoke within %d m of the party, 35 m clear of personnel, and stop for 2 seconds.",
      runtime.distance_nm,
      config.extraction_distance_m
    ),
    boarding = "Boarding. Remain landed until all three are aboard.",
    aboard = "Three aboard. Return to Hatay and unload at " .. config.return_zone .. ".",
    complete = "Operation complete.",
    failed = "Operation failed: " .. tostring(objective.reason) .. " Restart the mission.",
  }
  local text = messages[objective.phase]
  if runtime.carrier_name then
    text = "Package carrier: " .. transport_by_name[runtime.carrier_name].callsign .. ". " .. text
  end
  say(text, recipient)
end

local function safe(label, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      env.error("[hidden-passage] " .. label .. ": " .. tostring(err))
      if runtime.objective then
        fail("Transport adapter error; see dcs.log.")
      end
      say("Extraction stopped after a script error. Check dcs.log and restart.")
    end
  end
end

local function setup()
  -- Suppress only the aircraft's built-in "passing waypoint" calls. Keep its
  -- AWACS task, contact responses, datalink and our recorded Overlord cues.
  local awacs = GROUP:FindByName(config.awacs_group)
  if awacs and awacs:IsAlive() then
    local ok, err = pcall(function()
      awacs:SetOptionWaypointPassReport(false)
    end)
    if ok then
      log("AWACS waypoint reports disabled: " .. config.awacs_group)
    else
      -- Radio housekeeping must not stop extraction if the controller is lost.
      env.error("[hidden-passage] AWACS waypoint report option: " .. tostring(err))
    end
  end
  local pickup = assert(ZONE:New(config.pickup_zone), "Missing pickup zone")
  local personnel = assert(ZONE:New(config.personnel_zone), "Missing personnel zone")
  local receiving = assert(ZONE:New(config.return_zone), "Missing return zone")
  -- This catches water and obvious slopes, not buildings/trees or rotor clearance.
  -- The exact landing area still requires an in-DCS visual acceptance flight.
  for _, zone in ipairs({ pickup, personnel }) do
    local point = zone:GetVec2()
    assert(
      land.getSurfaceType(point) == land.SurfaceType.LAND,
      "Landing/personnel area must be on land; adjust the named zones in the editor"
    )
    local min_height, max_height = math.huge, -math.huge
    for _, offset in ipairs({ { 0, 0 }, { 30, 0 }, { -30, 0 }, { 0, 30 }, { 0, -30 } }) do
      local height = land.getHeight({ x = point.x + offset[1], y = point.y + offset[2] })
      min_height, max_height = math.min(min_height, height), math.max(max_height, height)
    end
    assert(max_height - min_height <= 4, "Landing/personnel area is too steep; adjust the named zones in the editor")
  end
  local landing_point, waiting_point = pickup:GetVec2(), personnel:GetVec2()
  local separation = math.sqrt((landing_point.x - waiting_point.x) ^ 2 + (landing_point.y - waiting_point.y) ^ 2)
  assert(
    separation >= config.minimum_personnel_clearance_m and separation <= config.extraction_distance_m,
    string.format("Landing/personnel zones must be 35-%d m apart for extraction", config.extraction_distance_m)
  )
  local landing_bearing = math.deg(math.atan2(landing_point.y - waiting_point.y, landing_point.x - waiting_point.x))
  local return_point = receiving:GetVec2()
  runtime.distance_nm = math.sqrt((landing_point.x - return_point.x) ^ 2 + (landing_point.y - return_point.y) ^ 2)
    / 1852

  local ctld = CTLD:New(coalition.side.BLUE, { config.player_group, config.support_group }, config.title)
  runtime.ctld, runtime.pickup, runtime.receiving = ctld, pickup, receiving
  -- Supported public hook: an empty pilot set prevents CTLD's generic menus.
  -- Only the two pinned CTLD transport methods below are exposed to the crew.
  ctld:SetOwnSetPilotGroups(SET_GROUP:New())
  ctld.useprefix = true
  ctld.movetroopstowpzone = false
  ctld.returntroopstobase = false -- Receiving uses deployment, not stock refunds.
  ctld.eventoninject = false
  ctld.keeploadtable = false
  ctld.enableLoadSave = false
  ctld.hoverautoloading = false
  ctld.pilotmustopendoors = false -- Preserve the user's rear gun; no ramp interlock.
  ctld.nobuildmenu = true
  ctld.CrateDistance, ctld.ExtractFactor = 35, config.extraction_distance_m / 35
  ctld:SetUnitCapabilities("CH-47Fbl1", false, true, 0, 31, 20, 8000)
  ctld:SetUnitCapabilities("UH-60L", false, true, 0, 20, 16, 3500)
  -- Restrict this instance to landed troop handling. Hoist is a separate probe.
  function ctld:IsCorrectHover()
    return false
  end
  function ctld:CanHoverLoad()
    return false
  end
  function ctld:IsUnitInAir(unit)
    -- MOOSE's default helicopter InAir correction can treat a stationary hover
    -- as landed. This probe requires DCS's actual ground contact instead.
    return unit:InAir(true)
  end

  -- One injected, recoverable party. Zero stock + hidden catalogue entry avoids
  -- the ordinary CTLD Load troops menu manufacturing extra objective parties.
  local cargo = CTLD_CARGO:New(
    nil,
    "Extraction party",
    { config.party_template },
    CTLD_CARGO.Enum.TROOPS,
    true,
    true,
    config.party_size,
    nil,
    false,
    80,
    0,
    nil,
    true
  )
  ctld:InjectTroops(personnel, cargo, { land.SurfaceType.LAND }, true)
  local party = assert(ctld.DroppedTroops[ctld.TroopCounter], "CTLD did not spawn the extraction party")
  runtime.objective = Operation.new(party:GetName(), config.party_size)
  local initial_party_key = party:GetName()

  -- Older archives use the unsuffixed name; the current editor archive has
  -- auto-suffixed the original group after a second template was added.
  local opposition_template_name
  for _, candidate in ipairs({ config.firefight.template, config.firefight.template_alias }) do
    if candidate and GROUP:FindByName(candidate) then
      opposition_template_name = candidate
      break
    end
  end
  -- This concealed reinforcement remains a late-activated editor template. It
  -- spawns and advances only when CTLD confirms that pickup/boarding has begun.
  if GROUP:FindByName(config.firefight.pickup_template) then
    runtime.pickup_opposition = { state = "staged" }
    log("FIREFIGHT pickup reinforcement armed: " .. config.firefight.pickup_template)
  end

  local function nearest_enemy_distance(enemy)
    local hvt_position = party:GetVec2()
    local nearest = math.huge
    for _, unit in pairs(enemy:GetUnits()) do
      local life = unit:GetLife()
      if life and life >= 1 then
        local point = unit:GetVec2()
        if point then
          nearest = math.min(nearest, math.sqrt((point.x - hvt_position.x) ^ 2 + (point.y - hvt_position.y) ^ 2))
        end
      end
    end
    return nearest
  end

  -- The primary Red template spawns at setup, held until the contact trigger. It
  -- begins its approach when a Blue helicopter reaches the outbound contact point.
  if opposition_template_name then
    -- CTLD's injected HVTs otherwise retain autonomous/default ROE and can
    -- engage a visible enemy immediately, before any aircraft departs.
    party:OptionROEHoldFire()
    party:SetTask(party:TaskHold())
    runtime.firefight = {
      state = "unavailable",
      started_at = nil,
      enemy_group = nil,
    }
    local ok, spawned = pcall(function()
      -- One group is spawned by this one-shot setup; a zero unit cap preserves
      -- the editor template's full strength (which can differ by archive).
      local spawner = SPAWN:New(opposition_template_name):InitLimit(0, 1)
      local group = spawner:Spawn()
      return { spawner = spawner, group = group }
    end)
    if ok and spawned and spawned.group and spawned.group:IsAlive() then
      runtime.firefight.state = "staged"
      runtime.firefight.spawner = spawned.spawner
      runtime.firefight.enemy_group = spawned.group
      spawned.group:OptionROEHoldFire()
      spawned.group:SetTask(spawned.group:TaskHold())
      log(
        string.format(
          "FIREFIGHT enemies staged %.0f m from the HVT site, held until the outbound contact point",
          nearest_enemy_distance(spawned.group)
        )
      )
    else
      log("FIREFIGHT unavailable: could not spawn the opposition template")
      if not ok then
        env.error("[hidden-passage] firefight spawn: " .. tostring(spawned))
      end
    end
  end

  local function hold_group(group)
    if group and group:IsAlive() then
      group:SetTask(group:TaskHold())
    end
  end

  stop_firefight = function(reason)
    local fight = runtime.firefight
    if not fight or (fight.state ~= "staged" and fight.state ~= "approaching" and fight.state ~= "active") then
      return
    end
    fight.state = "stopped"
    hold_group(fight.enemy_group)
    if fight.enemy_group and fight.enemy_group:IsAlive() then
      fight.enemy_group:OptionROEHoldFire()
    end
    hold_group(party)
    if party:IsAlive() then
      party:OptionROEHoldFire()
    end
    if fight.protected_party then
      party:SetCommandImmortal(false)
      fight.protected_party = false
    end
    log("FIREFIGHT stopped: " .. reason)
  end

  local function position_from_hvt(center, offset)
    return { x = center.x + offset, y = center.y - offset }
  end

  local function start_pickup_opposition()
    local reinforcement = runtime.pickup_opposition
    if not reinforcement or reinforcement.state ~= "staged" then
      return
    end
    reinforcement.state = "spawning"
    local ok, spawned = pcall(function()
      local spawner = SPAWN:New(config.firefight.pickup_template):InitLimit(0, 1)
      local group = assert(spawner:Spawn(), "MOOSE did not spawn the pickup reinforcement")
      assert(group:IsAlive(), "Pickup reinforcement spawned without live units")
      local hvt_position = party:GetVec2()
      group:RouteToVec2({ x = hvt_position.x, y = hvt_position.y }, config.firefight.approach_speed_mps)
      return { spawner = spawner, group = group }
    end)
    if not ok then
      reinforcement.state = "unavailable"
      env.error("[hidden-passage] pickup opposition: " .. tostring(spawned))
      log("FIREFIGHT pickup reinforcement unavailable: spawn or route failed")
      return
    end
    reinforcement.state = "approaching"
    reinforcement.spawner = spawned.spawner
    reinforcement.group = spawned.group
    log("FIREFIGHT pickup reinforcement moving toward the HVTs at boarding start")
  end

  stop_pickup_opposition = function(reason)
    local reinforcement = runtime.pickup_opposition
    if not reinforcement or reinforcement.state ~= "approaching" then
      return
    end
    reinforcement.state = "stopped"
    if reinforcement.group and reinforcement.group:IsAlive() then
      reinforcement.group:SetTask(reinforcement.group:TaskHold())
      reinforcement.group:OptionROEHoldFire()
    end
    log("FIREFIGHT pickup reinforcement stopped: " .. reason)
  end

  local function start_firefight()
    local fight = runtime.firefight
    if not fight or fight.state ~= "approaching" then
      return
    end
    local enemy = fight.enemy_group
    if not enemy or not enemy:IsAlive() then
      stop_firefight("enemy force eliminated while advancing")
      return
    end
    -- SetImmortal applies only to the Blue HVT party. The Red group receives no
    -- protection and remains a valid target for either helicopter's door guns.
    fight.state = "active"
    fight.started_at = timer.getTime()
    local ok, err = pcall(function()
      party:SetCommandImmortal(true)
      fight.protected_party = true
      enemy:SetTask(enemy:TaskFireAtPoint(party:GetVec2(), config.firefight.fire_radius_m))
      enemy:OptionROEOpenFire()
      party:SetTask(party:TaskFireAtPoint(enemy:GetVec2(), config.firefight.fire_radius_m))
      party:OptionROEOpenFire()
    end)
    if not ok then
      stop_firefight("task setup error")
      env.error("[hidden-passage] firefight setup: " .. tostring(err))
      return
    end
    fight.hvt_fire_stopped = false
    say("Enemy contact. HVT under fire.")
    radio("taking_fire", function()
      return fight.state == "active" and (runtime.objective.phase == "waiting" or runtime.objective.phase == "boarding")
    end)
    log("FIREFIGHT started enemy=" .. enemy:GetName() .. " HVT=" .. party:GetName())
  end

  local function advance_firefight(name)
    local fight = runtime.firefight
    if not fight or fight.state ~= "staged" then
      return
    end
    local enemy = fight.enemy_group
    if not enemy or not enemy:IsAlive() then
      fight.state = "unavailable"
      log("FIREFIGHT unavailable: staged enemy force was lost before the outbound trigger")
      return
    end
    local destination = position_from_hvt(party:GetVec2(), config.firefight.fire_position_offset_m)
    local ok, err = pcall(function()
      enemy:RouteToVec2(destination, config.firefight.approach_speed_mps)
    end)
    if not ok then
      fight.state = "unavailable"
      env.error("[hidden-passage] firefight approach: " .. tostring(err))
      return
    end
    fight.fire_position = destination
    fight.state = "approaching"
    log(
      string.format(
        "FIREFIGHT opposition moving in after %s reached the outbound contact point; nearest enemy %.1f m, firing gate %d m, t=%.1f",
        name,
        nearest_enemy_distance(enemy),
        config.firefight.fire_start_distance_m,
        timer.getTime()
      )
    )
  end

  local function update_firefight()
    local fight = runtime.firefight
    if not fight then
      return
    end
    local objective = runtime.objective
    if fight.state == "active" then
      if objective.phase == "aboard" or objective.phase == "complete" then
        stop_firefight("HVT confirmed aboard")
      elseif objective.phase == "failed" then
        stop_firefight("objective failed")
      elseif timer.getTime() - fight.started_at >= config.firefight.maximum_duration_s then
        stop_firefight("10-minute limit")
      elseif not fight.enemy_group:IsAlive() then
        stop_firefight("enemy force eliminated")
      elseif
        not fight.hvt_fire_stopped
        and timer.getTime() - fight.started_at >= config.firefight.hvt_return_fire_duration_s
      then
        hold_group(party)
        party:OptionROEHoldFire()
        fight.hvt_fire_stopped = true
        log("FIREFIGHT HVT return fire ended; party remains protected")
      end
      return
    end
    if fight.state == "staged" then
      if objective.phase == "aboard" or objective.phase == "complete" then
        stop_firefight("HVT confirmed aboard")
      elseif objective.phase == "failed" then
        stop_firefight("objective failed")
      elseif not fight.enemy_group:IsAlive() then
        fight.state = "unavailable"
        log("FIREFIGHT unavailable: staged enemy force was eliminated")
      end
      return
    end
    if fight.state == "approaching" then
      if objective.phase == "aboard" or objective.phase == "complete" then
        stop_firefight("HVT confirmed aboard")
      elseif objective.phase == "failed" then
        stop_firefight("objective failed")
      elseif not fight.enemy_group:IsAlive() then
        stop_firefight("enemy force eliminated while advancing")
      else
        -- A dispersed group leader can stay outside the gate even while another
        -- surviving soldier closes in. Never count a dead/missing wrapper.
        local distance = nearest_enemy_distance(fight.enemy_group)
        if distance <= config.firefight.fire_start_distance_m then
          log(string.format("FIREFIGHT contact range %.1f m at t=%.1f", distance, timer.getTime()))
          start_firefight()
        end
      end
      return
    end
    if objective.party_key ~= initial_party_key then
      return
    end
  end

  -- Boarding begins once. The crew chief calls the package in at that moment.
  local function claim_carrier(unit)
    local name = unit:GetName()
    if runtime.carrier_name and runtime.carrier_name ~= name then
      return false
    end
    if not runtime.objective:lock_carrier(unit:GetID()) then
      report_failure()
      return false
    end
    runtime.carrier_name = name
    return true
  end
  local function begin_boarding(unit)
    if claim_carrier(unit) and runtime.objective:begin_boarding(unit:GetID()) then
      runtime.auto_pickup = {}
      voice:boarding_start(unit)
      start_pickup_opposition()
      return true
    end
    return false
  end

  ctld.OnAfterTroopsExtracted = safe("boarding", function(_, _, _, _, _, unit, troops, group_name)
    local objective = runtime.objective
    if objective.phase == "failed" or objective.phase == "complete" then
      report_failure()
      return
    end
    if not unit or not transport_by_name[unit:GetName()] or group_name ~= objective.party_key then
      return
    end
    if objective.phase == "aboard" then
      return
    end -- Ignore duplicate receipts.
    if runtime.carrier_name and unit:GetName() ~= runtime.carrier_name then
      return
    end
    local live, id = carrier(unit:GetName())
    if not live or unit:GetID() ~= id or (objective.carrier_id and id ~= objective.carrier_id) then
      fail("Aircraft lost or replaced during boarding.")
      return
    end
    -- A native extraction receipt can arrive between observer ticks.
    begin_boarding(live)
    if live:InAir(true) then
      fail("Took off before boarding completed.")
      return
    end
    if
      not troops
      or troops:GetName() ~= group_name
      or not troops:IsAlive()
      or troops:GetSize() ~= config.party_size
    then
      fail("Extraction party lost personnel during boarding.")
      return
    end
    if not objective:boarded(id, group_name, loaded_count(ctld, unit:GetName())) then
      report_failure()
      return
    end
    if stop_firefight then
      stop_firefight("HVT confirmed aboard")
    end
    if stop_pickup_opposition then
      stop_pickup_opposition("HVT confirmed aboard")
    end
    -- The receipt, disappearance, and clearance happen in this one callback.
    -- CTLD's separate 10-20 s removal was suppressed only during extraction.
    troops:Destroy(false)
    voice:boarding_complete(live)
    spawn_cas_checkpoint("pickup_confirmed")
  end)

  ctld.OnAfterTroopsDeployed = safe("delivery", function(_, _, _, _, _, unit, troops)
    if not unit or unit:GetName() ~= runtime.carrier_name or not troops or not is_party(troops:GetName()) then
      return
    end
    if runtime.objective.phase == "failed" or runtime.objective.phase == "complete" then
      report_failure()
      return
    end
    local live, id = carrier()
    if not live or unit:GetID() ~= id or id ~= runtime.objective.carrier_id then
      fail("Aircraft lost or replaced during unloading.")
      return
    end
    local inside = receiving:IsVec2InZone(live:GetVec2()) and receiving:IsVec2InZone(troops:GetVec2())
    local complete, message =
      runtime.objective:deployed(id, troops:GetName(), troops:GetSize(), inside, not live:InAir(true))
    if runtime.objective.phase == "boarding" then
      fail("Unloaded before boarding confirmation.")
      return
    end
    report_failure()
    if message and not complete and runtime.objective.phase ~= "failed" then
      say(message)
    end
    if complete then
      -- No forced mission end: leave the prototype available for inspection.
      log("PASS delivered " .. troops:GetName())
      voice:play("mission_success", nil, nil, nil, function()
        return runtime.objective.phase == "complete"
      end, message) -- Delay Overlord's text and recording, not actual delivery.
    end
  end)

  ctld:__Start(2)
  pickup
    :GetCoordinate()
    :MarkToCoalition(config.pickup_zone .. " - LANDING AREA; do not land on personnel", coalition.side.BLUE)
  personnel
    :GetCoordinate()
    :MarkToCoalition(config.personnel_zone .. " - WAITING PERSONNEL; do NOT land here", coalition.side.BLUE)
  receiving:GetCoordinate():MarkToCoalition(config.return_zone .. " - land and unload here", coalition.side.BLUE)

  local function ready_to_handle(name)
    local objective = runtime.objective
    if objective.phase == "failed" or objective.phase == "complete" then
      status(name)
      return
    end
    local unit, id = carrier(name)
    if not unit then
      say("Enter an available extraction helicopter before using the transport commands.")
      return
    end
    if runtime.carrier_name and runtime.carrier_name ~= name then
      say(
        "The package is assigned to " .. transport_by_name[runtime.carrier_name].callsign .. ". Remain in support.",
        unit
      )
      return
    end
    if objective.carrier_id and not objective:lock_carrier(id) then
      report_failure()
      return
    end
    if unit:InAir(true) or unit:GetVelocityMPS() > 1 then
      say("Land and stop before boarding or unloading personnel.", unit)
      return
    end
    return unit, id
  end

  local function personnel_clearance(unit, current)
    local position = unit:GetVec2()
    for _, person in ipairs(current:GetUnits()) do
      local point = person:GetVec2()
      local distance = math.sqrt((point.x - position.x) ^ 2 + (point.y - position.y) ^ 2)
      if distance < config.minimum_personnel_clearance_m then
        return false
      end
    end
    return true
  end

  local function extract(name)
    local unit = ready_to_handle(name)
    if not unit then
      return
    end
    local objective = runtime.objective
    if objective.phase ~= "waiting" then
      status(name)
      return
    end
    local current = GROUP:FindByName(objective.party_key)
    if not current or not current:IsAlive() or current:GetSize() ~= config.party_size then
      fail("Extraction party lost personnel before pickup.")
      return
    end
    if not personnel_clearance(unit, current) then
      say("Too close to personnel. Reposition to green smoke, 35 m clear.", unit)
      return
    end
    -- Pinned CTLD adapter boundary; this is the same method used by its native
    -- Extract troops menu, not a second transport implementation.
    -- Pinned CTLD otherwise removes the visible group after a random 10-20 s,
    -- before its distance-based boarding receipt. Defer only that removal to
    -- OnAfterTroopsExtracted; retain native routing, cargo and receipt timing.
    -- Restore the group's method even if native extraction throws. No shared
    -- GROUP/CTLD class or embedded MOOSE source is modified.
    local destroy, removal_deferred = current.Destroy, false
    current.Destroy = function(_, generate_event, delay)
      assert(generate_event == false and type(delay) == "number" and delay > 0, "Unexpected CTLD removal contract")
      removal_deferred = true
    end
    local ok, err = pcall(function()
      ctld:_ExtractTroops(unit:GetGroup(), unit)
    end)
    current.Destroy = destroy
    assert(ok, err)
    if loaded_count(ctld, name) == config.party_size then
      assert(removal_deferred, "CTLD reserved personnel without deferring their removal")
      begin_boarding(unit)
    end
  end

  local function automatic_pickup(unit, current)
    local name = unit:GetName()
    local state = runtime.auto_pickup[name] or {}
    if state.id ~= unit:GetID() then
      state = { id = unit:GetID() }
    end
    runtime.auto_pickup[name] = state
    local position, party_position = unit:GetVec2(), current:GetVec2()
    local distance = math.sqrt((position.x - party_position.x) ^ 2 + (position.y - party_position.y) ^ 2)
    if unit:InAir(true) or unit:GetVelocityMPS() > 1 or distance > config.extraction_distance_m then
      state.since, state.blocked = nil, nil
      return
    end
    if not personnel_clearance(unit, current) then
      state.since = nil
      if not state.blocked then
        local text = "Too close for boarding. Reposition to green smoke, 35 m clear of personnel."
        MESSAGE:New(text, 20, config.title):ToUnit(unit)
        log(text)
        state.blocked = true
      end
      return
    end
    state.blocked = nil
    local now = timer.getTime()
    state.since = state.since or now
    if now - state.since >= config.automatic_pickup_settle_s then
      -- Retry at the settle interval if native CTLD temporarily refuses a load.
      -- Manual and automatic entry use the same checks, routing and receipt.
      state.since = now
      extract(name)
    end
  end

  local function unload(name)
    local unit = ready_to_handle(name)
    if not unit then
      return
    end
    if runtime.objective.phase ~= "aboard" then
      status(name)
      return
    end
    ctld:_UnloadTroops(unit:GetGroup(), unit)
  end

  local function smoke(name)
    local objective = runtime.objective
    if objective.phase ~= "waiting" then
      status(name)
      return
    end
    local current = GROUP:FindByName(objective.party_key)
    if not current or not current:IsAlive() then
      return
    end
    -- Use the editor's LZ for the initial pickup. For off-site recovery, preserve
    -- its direction/distance relative to the party instead of assuming south.
    local mark = pickup:GetCoordinate()
    if objective.party_key ~= initial_party_key then
      mark = current:GetCoordinate():Translate(separation, landing_bearing)
    end
    local unit = carrier(name)
    if not unit then
      return
    end
    local under_fire = runtime.firefight and runtime.firefight.state == "active"
    voice:request_smoke(unit, under_fire)
    mark:SmokeGreen()
    log("Green smoke requested by " .. transport_by_name[name].callsign .. (under_fire and " under fire" or ""))
  end

  runtime.cas_test_menus = {}
  local function update_cas_test_menus()
    for name in pairs(config.cas.slots) do
      local name = name -- Bind each callback to its own CAS group in Lua 5.1.
      local group = GROUP:FindByName(name)
      local available = config.cas.enable_pickup_test_menu and group and group:IsAlive()
      local existing = runtime.cas_test_menus[name]
      if existing and (not available or existing.group ~= group) then
        existing.menu:Remove()
        runtime.cas_test_menus[name] = nil
      end
      if available and not runtime.cas_test_menus[name] then
        local menu = MENU_GROUP:New(group, config.title .. " - TEMP TEST")
        runtime.cas_test_menus[name] = { group = group, menu = menu }
        MENU_GROUP_COMMAND:New(
          group,
          "TEST: Simulate pickup complete (CAS stage only)",
          menu,
          safe("CAS test pickup", function()
            if not config.cas.enable_pickup_test_menu or not radio_active() then
              return
            end
            -- Only one human Blue pilot, in the invoking CAS group. Never enable a
            -- late/disabled CAS branch or let this become an accidental MP cheat.
            local ok, players = pcall(coalition.getPlayers, coalition.side.BLUE)
            local count, matching = 0, false
            if ok and type(players) == "table" then
              for _, player in pairs(players) do
                count = count + 1
                matching = matching or configured_slot(player, config.cas.slots) == name
              end
            end
            if count ~= 1 or not matching then
              say("TEST denied: use this only with one human Blue pilot, in this CAS slot.")
              return
            end
            if runtime.cas_checkpoint.state ~= "waiting_for_pickup" or runtime.objective.phase ~= "waiting" then
              say(
                "TEST unavailable: take off in an enabled CAS role first; do not use during boarding or after stage release."
              )
              return
            end
            say(
              "TEST ONLY: simulating pickup completion for the CAS checkpoint stage. Actual extraction, carrier and mission success are unchanged."
            )
            log(string.format("TEST CAS pickup override by %s at t=%.1f", name, timer.getTime()))
            spawn_cas_checkpoint("solo_test")
          end)
        )
      end
    end
  end

  runtime.observer = TIMER:New(safe("observer", function()
    local objective = runtime.objective
    update_cas_test_menus()
    update_threat_reports()
    update_hind_tasking() -- Observe both destruction reports before deciding whether the Hind still needs tasking.
    update_firefight()
    spawn_cas_checkpoint() -- Also handles a first takeoff after a confirmed pickup.
    -- Independent menus and settling clocks; merely occupying a slot claims nothing.
    for _, spec in ipairs(transports) do
      local name = spec.name
      local unit, id = carrier(name)
      local existing = runtime.menus[name]
      if existing and (not unit or existing.id ~= id) then
        existing.menu:Remove()
        runtime.menus[name] = nil
      end
      if not unit then
        runtime.auto_pickup[name] = nil
      end
      if unit and not runtime.menus[name] then
        local group = unit:GetGroup()
        local menu = MENU_GROUP:New(group, config.title)
        runtime.menus[name] = { id = id, menu = menu }
        MENU_GROUP_COMMAND:New(group, "Instructions / status", menu, function()
          status(name)
        end)
        MENU_GROUP_COMMAND:New(
          group,
          "Request green smoke",
          menu,
          safe("smoke", function()
            smoke(name)
          end)
        )
        MENU_GROUP_COMMAND:New(
          group,
          "Extract waiting personnel",
          menu,
          safe("extract", function()
            extract(name)
          end)
        )
        MENU_GROUP_COMMAND:New(
          group,
          "Unload personnel",
          menu,
          safe("unload", function()
            unload(name)
          end)
        )
        status(name)
      end
    end
    if objective.phase == "complete" or objective.phase == "failed" then
      report_failure()
      return
    end
    if runtime.carrier_name then
      local unit, id = carrier()
      if not unit then
        fail("Package carrier lost or removed.")
        return
      end
      if not objective:lock_carrier(id) then
        report_failure()
        return
      end
      if objective.phase == "boarding" and unit:InAir(true) then
        fail("Took off before boarding completed.")
        return
      end
    end
    if objective.phase == "waiting" or objective.phase == "boarding" then
      -- Native CTLD can reserve troops before its receipt. Observe any reservation
      -- before interpreting a disappearing party as a casualty.
      if objective.phase == "waiting" then
        for _, spec in ipairs(transports) do
          local unit = carrier(spec.name)
          if
            unit
            and (not runtime.carrier_name or runtime.carrier_name == spec.name)
            and loaded_count(ctld, spec.name) == config.party_size
          then
            begin_boarding(unit)
            break
          end
        end
      end
      local current = GROUP:FindByName(objective.party_key)
      if not current or not current:IsAlive() or current:GetSize() ~= config.party_size then
        fail(
          "Extraction party lost personnel "
            .. (objective.phase == "boarding" and "during boarding." or "before pickup.")
        )
        return
      end
      if objective.phase == "waiting" then
        for _, spec in ipairs(transports) do
          local unit = carrier(spec.name)
          if unit and (not runtime.carrier_name or runtime.carrier_name == spec.name) then
            automatic_pickup(unit, current)
            if objective.phase ~= "waiting" then
              break
            end
          end
        end
      end
    end
  end))
  runtime.observer:Start(1, 1)

  -- Independent one-shot calls for the two named aircraft, not the first Blue
  -- takeoff globally. Match names AND types; unrelated aircraft stay silent.
  -- DCS calls handler:onEvent(event), so this must be a table, not a function.
  local takeoff_calls = {
    [config.player_unit] = { type = "CH-47Fbl1", line = "mule_one_cleared_for_pickup" },
    [config.support_unit] = { type = "UH-60L", line = "raven_one_cleared_for_support" },
  }
  runtime.takeoff_announced = {}
  local leg_length = runtime.distance_nm * 1852
  local absolute_contact_distance_m = config.firefight.start_distance_from_pickup_nm * 1852
  -- The operational leg is long enough to use a fixed 3 NM contact point. On
  -- the ~3.06 NM Testing leg, that would trigger almost immediately after takeoff,
  -- so keep the already-tested halfway timing there.
  local contact_distance_m = leg_length > absolute_contact_distance_m * 2 and absolute_contact_distance_m
    or leg_length / 2
  runtime.hvt_under_fire_trigger_distance_nm = contact_distance_m / 1852
  runtime.hvt_under_fire_departures = {}
  local function distance_to_pickup(unit)
    local point = unit:GetVec2()
    return math.sqrt((point.x - landing_point.x) ^ 2 + (point.y - landing_point.y) ^ 2)
  end
  runtime.takeoff_handler = {
    onEvent = function(_, event)
      if event.id ~= world.event.S_EVENT_TAKEOFF then
        return
      end
      local unit = event.initiator
      if not unit then
        return
      end
      local ok, side, name, type_name, id = pcall(function()
        return unit:getCoalition(), unit:getName(), unit:getTypeName(), unit:getID()
      end)
      if not ok or side ~= coalition.side.BLUE then
        return
      end
      local call = takeoff_calls[name]
      if not call or call.type ~= type_name or runtime.takeoff_announced[name] then
        return
      end
      local recipient = UNIT:FindByName(name)
      if not recipient or not recipient:IsAlive() or recipient:GetID() ~= id then
        return
      end
      runtime.takeoff_announced[name] = true
      log("DEPARTURE " .. name .. " - " .. call.line)
      -- Arm only before the contact point on the initial outbound leg, never a
      -- takeoff already at the LZ. Distance remaining, not distance flown,
      -- ignores detours.
      local distance = distance_to_pickup(recipient)
      if distance > contact_distance_m then
        runtime.hvt_under_fire_departures[name] = { id = id, previous_distance = distance }
      end
      voice:play(call.line, nil, recipient)
    end,
  }
  world.addEventHandler(runtime.takeoff_handler)

  -- Separate from transport ownership: Raven can trigger this while Mule is
  -- still on the ground, or even before anyone occupies the Chinook slot.
  runtime.hvt_under_fire_observer = TIMER:New(safe("hvt-under-fire", function()
    local objective = runtime.objective
    if runtime.hvt_under_fire_announced or objective.phase ~= "waiting" or objective.party_key ~= initial_party_key then
      return
    end
    local current = GROUP:FindByName(initial_party_key)
    if not current or not current:IsAlive() or current:GetSize() ~= config.party_size or loaded_count(ctld) > 0 then
      return
    end
    for name, departure in pairs(runtime.hvt_under_fire_departures) do
      local aircraft = UNIT:FindByName(name)
      if not aircraft or not aircraft:IsAlive() or aircraft:GetID() ~= departure.id then
        runtime.hvt_under_fire_departures[name] = nil
      else
        local distance = distance_to_pickup(aircraft)
        if
          aircraft:InAir(true)
          and departure.previous_distance > contact_distance_m
          and distance <= contact_distance_m
        then
          runtime.hvt_under_fire_announced = name
          advance_firefight(name)
          log(string.format("HVT under fire trigger %s at %.2f NM from pickup", name, contact_distance_m / 1852))
          radio("hvt_under_fire", function()
            return objective.phase == "waiting" and (not runtime.firefight or runtime.firefight.state == "approaching")
          end) -- Explicit Blue-wide radio call, not crew-only.
          return
        end
        departure.previous_distance = distance
      end
    end
  end))
  runtime.hvt_under_fire_observer:Start(1, 1)

  log("READY " .. config.mission_version .. " party=" .. party:GetName())
end

runtime.startup = TIMER:New(safe("setup", setup))
runtime.startup:Start(2)
log("Extraction armed")
return runtime

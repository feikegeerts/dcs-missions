-- Chinook / UH-60L extraction using the repository's pinned MOOSE CTLD.
-- No telemetry, disk access, MIST, enemies, persistence, or native mission end.
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
  if objective and objective.phase == "failed" and not runtime.failure_reported then
    runtime.failure_reported = true
    say(
      "Operation failed: "
        .. tostring(objective.reason)
        .. " Restart the mission to retry; re-slotting does not reset the operation."
    )
  end
end

local function fail(reason)
  runtime.objective:fail(reason)
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
      "Fly to %s, about %.1f NM from Hatay (straight line). Mark the landing area with green smoke; do NOT land on %s. Either helicopter can extract: land within 105 m of the party, keep at least 35 m clear of every person, and stop for 2 seconds. Boarding starts automatically; F10 > Extract waiting personnel remains a fallback.",
      config.pickup_zone,
      runtime.distance_nm,
      config.personnel_zone
    ),
    boarding = "Personnel boarding. Remain landed until the party disappears and 'Three personnel aboard' appears (allow about 20-45 seconds).",
    aboard = "Three personnel aboard. Return to "
      .. config.return_zone
      .. ". Land and stop, then F10 > Operation Hidden Passage > Unload personnel.",
    complete = "Operation complete. Restart the mission to fly again.",
    failed = "Operation failed: "
      .. tostring(objective.reason)
      .. " Restart the mission to retry; re-slotting does not reset the operation.",
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
    "Landing/personnel zones must be 35-105 m apart for extraction"
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
    -- The receipt, disappearance, and clearance happen in this one callback.
    -- CTLD's separate 10-20 s removal was suppressed only during extraction.
    troops:Destroy(false)
    voice:boarding_complete(live)
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
    if message and runtime.objective.phase ~= "failed" then
      say(message)
    end
    if complete then
      -- No forced mission end: leave the prototype available for inspection.
      log("PASS delivered " .. troops:GetName())
      voice:play("mission_success") -- Mission-wide success, heard by all Blue crews.
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
      say("Too close to the personnel. Reposition to the green landing smoke, at least 35 m from every person.", unit)
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
        local text =
          "Too close for automatic boarding. Reposition to the green landing area, at least 35 m clear of every person, then stop."
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
    mark:SmokeGreen()
    say(
      string.format(
        "Green smoke marks the landing area, about %.0f m from the waiting party. Check obstacles and keep at least 35 m clear of every person.",
        separation
      ),
      carrier(name)
    )
  end

  runtime.observer = TIMER:New(safe("observer", function()
    local objective = runtime.objective
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
          "Mark landing area (green smoke)",
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
  runtime.midpoint_departures = {}
  local leg_length = runtime.distance_nm * 1852
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
      -- Arm only before halfway on the initial outbound leg, never a takeoff
      -- already at the LZ. Distance remaining, not distance flown, ignores detours.
      local distance = distance_to_pickup(recipient)
      if distance > leg_length / 2 then
        runtime.midpoint_departures[name] = { id = id, previous_distance = distance }
      end
      voice:play(call.line, nil, recipient)
    end,
  }
  world.addEventHandler(runtime.takeoff_handler)

  -- Separate from transport ownership: Raven can trigger this while Mule is
  -- still on the ground, or even before anyone occupies the Chinook slot.
  runtime.midpoint_observer = TIMER:New(safe("midpoint", function()
    local objective = runtime.objective
    if runtime.midpoint_announced or objective.phase ~= "waiting" or objective.party_key ~= initial_party_key then
      return
    end
    local current = GROUP:FindByName(initial_party_key)
    if not current or not current:IsAlive() or current:GetSize() ~= config.party_size or loaded_count(ctld) > 0 then
      return
    end
    for name, departure in pairs(runtime.midpoint_departures) do
      local aircraft = UNIT:FindByName(name)
      if not aircraft or not aircraft:IsAlive() or aircraft:GetID() ~= departure.id then
        runtime.midpoint_departures[name] = nil
      else
        local distance = distance_to_pickup(aircraft)
        if aircraft:InAir(true) and departure.previous_distance > leg_length / 2 and distance <= leg_length / 2 then
          runtime.midpoint_announced = name
          log("MIDPOINT " .. name .. " - broadcasting HVT under fire")
          voice:play("hvt_under_fire") -- Explicit Blue-wide radio call, not crew-only.
          return
        end
        departure.previous_distance = distance
      end
    end
  end))
  runtime.midpoint_observer:Start(1, 1)

  log("READY " .. config.mission_version .. " party=" .. party:GetName())
end

runtime.startup = TIMER:New(safe("setup", setup))
runtime.startup:Start(2)
log("Extraction armed")
return runtime

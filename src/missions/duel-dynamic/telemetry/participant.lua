local M = {}

local AIR_CATEGORY = 2

local function is_finite_number(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function non_empty_string(value)
  if type(value) == "string" and string.len(value) > 0 then
    return value
  end
  return nil
end

local function log_message(config, level, message)
  local logger = config.log
  if type(logger) == "function" then
    pcall(logger, level, "participant capture: " .. message)
  end
end

local function log_error(config, message)
  log_message(config, "error", message)
end

local function read_field(config, object, field_name)
  if object == nil then
    return nil
  end

  local ok, value = pcall(function()
    return object[field_name]
  end)
  if not ok then
    log_error(config, field_name .. " access raised: " .. tostring(value))
    return nil
  end
  return value
end

local function call_method(config, receiver, method_name)
  if receiver == nil then
    return nil
  end

  local method = read_field(config, receiver, method_name)
  if type(method) ~= "function" then
    return nil
  end

  local ok, value = pcall(method, receiver)
  if not ok then
    log_error(config, method_name .. " raised: " .. tostring(value))
    return nil
  end
  return value
end

local function map_coalition(value)
  if value == 0 then
    return "neutral"
  elseif value == 1 then
    return "red"
  elseif value == 2 then
    return "blue"
  elseif value == "neutral" or value == "red" or value == "blue" or value == "unknown" then
    return value
  end
  return "unknown"
end

local function read_unit(config, event_data)
  -- EVENT:CreateEventPlayerEnterUnit/PlayerLeaveUnit place the raw DCS unit in
  -- Event.initiator. IniDCSUnit is only the MOOSE-normalized fallback because
  -- leave callbacks can arrive after the original event has been enriched.
  local unit = read_field(config, event_data, "initiator")
  if unit == nil then
    unit = read_field(config, event_data, "IniDCSUnit")
  end
  return unit
end

local function read_observation(config, unit)
  local observation = {}

  -- Core.Event does not guarantee IniGroupName for synthetic player events;
  -- use the raw DCS unit capability and keep an unreadable group unresolved.
  observation.group_name = non_empty_string(call_method(config, unit, "getGroupName"))

  -- Core.Event derives IniUnitName by calling the raw unit without protection;
  -- repeat that capability here defensively so adapter failures stay isolated.
  observation.dcs_name = non_empty_string(call_method(config, unit, "getName"))

  -- Core.Event may omit IniTypeName when a leaving unit is already invalid;
  -- the raw unit type is the only source label available to this adapter.
  observation.dcs_type = non_empty_string(call_method(config, unit, "getTypeName"))

  -- MOOSE event normalization may not retain IniCoalition on a late leave;
  -- query the raw unit and degrade an unreadable value to unknown.
  observation.raw_coalition = call_method(config, unit, "getCoalition")

  -- MOOSE has no reliable wrapper position for an invalidating leave event;
  -- getPosition is the isolated raw-DCS fallback required for the observation.
  observation.position = call_method(config, unit, "getPosition")

  -- Core.Event's category enrichment is not guaranteed for synthetic events;
  -- query the raw unit so non-air roster collisions can be rejected.
  observation.category = call_method(config, unit, "getCategory")

  -- Player enter/leave event tables contain no participant name of their own;
  -- getPlayerName is the checked raw-DCS capability for the display snapshot.
  observation.display_name = non_empty_string(call_method(config, unit, "getPlayerName"))

  -- MOOSE cannot guarantee IniPlayerUCID for these multiplayer lifecycle
  -- events; use the raw unit capability and preserve an explicit unknown if nil.
  observation.participant_id = non_empty_string(call_method(config, unit, "getPlayerUCID"))

  -- UNIT:GetCallsign substitutes the unit name for an empty raw callsign, so
  -- query getCallsign directly to avoid inventing a reported callsign label.
  observation.callsign = non_empty_string(call_method(config, unit, "getCallsign"))

  return observation
end

local function read_location(config, position)
  if position == nil then
    return nil
  end

  -- DCS getPosition normally returns Position3.p; test doubles and some event
  -- adapters expose the Vec3 directly. Both raw table shapes are protected.
  local vector = read_field(config, position, "p") or position
  local x = read_field(config, vector, "x")
  local y = read_field(config, vector, "y")
  local z = read_field(config, vector, "z")
  if not is_finite_number(x) or not is_finite_number(y) or not is_finite_number(z) then
    return nil
  end

  return {
    status = "known",
    coordinate_system = "dcs-local",
    x = x,
    y = y,
    z = z,
  }
end

local function build_roster(names)
  if type(names) ~= "table" or #names == 0 then
    return nil, "player group names are required"
  end

  local roster = {}
  for index, name in ipairs(names) do
    if type(name) ~= "string" or string.len(name) == 0 then
      return nil, "player group name " .. tostring(index) .. " is invalid"
    end
    if roster[name] then
      return nil, "player group names contain a duplicate"
    end
    roster[name] = true
  end
  return roster
end

local function make_participant(observation, coalition)
  if observation.participant_id then
    return {
      status = "known",
      kind = "participant",
      participant_id = observation.participant_id,
      display_name = observation.display_name,
      callsign = observation.callsign,
      coalition = coalition,
    }
  end

  return {
    status = "unknown",
    kind = "participant",
    reason = "stable-identity-unavailable",
    display_name = observation.display_name,
    callsign = observation.callsign,
    coalition = coalition,
  }
end

local function prefer_live(live_value, snapshot, field_name)
  if live_value ~= nil then
    return live_value
  end
  return snapshot and snapshot[field_name] or nil
end

local function merge_leave_snapshot(observation, snapshot)
  if not snapshot then
    return observation
  end

  return {
    group_name = observation.group_name,
    dcs_name = prefer_live(observation.dcs_name, snapshot, "dcs_name"),
    dcs_type = prefer_live(observation.dcs_type, snapshot, "dcs_type"),
    raw_coalition = observation.raw_coalition,
    coalition = prefer_live(
      observation.raw_coalition == nil and nil or map_coalition(observation.raw_coalition),
      snapshot,
      "coalition"
    ),
    position = observation.position,
    category = observation.category,
    display_name = prefer_live(observation.display_name, snapshot, "display_name"),
    participant_id = prefer_live(observation.participant_id, snapshot, "participant_id"),
    callsign = prefer_live(observation.callsign, snapshot, "callsign"),
  }
end

local function resolve_entered_asset(config, unit, group_name, event_time)
  local registry = config.asset_registry
  if type(registry) ~= "table" or type(registry.observe_player_unit) ~= "function" then
    return nil
  end
  local ok, asset, observe_error = pcall(registry.observe_player_unit, registry, unit, event_time, group_name)
  if not ok then
    log_error(config, "tracked asset observation raised: " .. tostring(asset))
    return nil
  end
  if not asset then
    log_error(config, "tracked asset observation failed: " .. tostring(observe_error))
    return nil
  end
  return asset
end

local function resolve_existing_asset(config, unit)
  local registry = config.asset_registry
  if type(registry) ~= "table" or type(registry.resolve_unit) ~= "function" then
    return nil
  end
  local ok, asset = pcall(registry.resolve_unit, registry, unit)
  if ok then
    return asset
  end
  log_error(config, "tracked asset resolution raised: " .. tostring(asset))
  return nil
end

local function capture(adapter, event_type, event_data)
  local config = adapter.config
  if type(event_data) ~= "table" then
    log_error(config, "player lifecycle callback received no event table")
    return nil, "participant event data is unavailable"
  end

  local unit = read_unit(config, event_data)
  local observation = read_observation(config, unit)
  local group_name = observation.group_name
  if not group_name or not adapter.roster[group_name] then
    return nil, "participant group is outside the tracked roster"
  end

  if observation.category ~= nil and observation.category ~= AIR_CATEGORY then
    return nil, "participant unit is not an aircraft"
  end
  if
    config.player_coalition ~= nil
    and observation.raw_coalition ~= nil
    and observation.raw_coalition ~= config.player_coalition
  then
    return nil, "participant coalition does not match the tracked roster"
  end

  if event_type == "participant.left" then
    observation = merge_leave_snapshot(observation, adapter.snapshots[group_name])
  end

  local coalition = observation.coalition
    or (observation.raw_coalition == nil and "unknown" or map_coalition(observation.raw_coalition))
  local participant = make_participant(observation, coalition)
  local event_time = read_field(config, event_data, "time")
  local asset
  if event_type == "participant.entered" then
    asset = resolve_entered_asset(config, unit, group_name, event_time)
  else
    asset = resolve_existing_asset(config, unit)
  end
  local input = {
    event_type = event_type,
    initiator = config.envelope.JSON_NULL,
    target = config.envelope.JSON_NULL,
    participant = participant,
    asset = asset or {
      status = "unknown",
      kind = "aircraft",
      reason = "instance-identity-unavailable",
      dcs_name = observation.dcs_name,
      dcs_type = observation.dcs_type,
      coalition = coalition,
    },
    weapon = config.envelope.JSON_NULL,
    coalition = coalition,
    location = read_location(config, observation.position) or { status = "unknown", reason = "unavailable" },
    payload = {},
  }

  -- Core.Event owns the callback's simulation timestamp. Access remains
  -- protected because synthetic MOOSE events may omit or invalidate the field.
  if is_finite_number(event_time) and event_time >= 0 then
    input.sim_time = event_time
  end

  local ok, event, persist_error = pcall(function()
    return config.controller:record(input)
  end)
  if not ok then
    log_error(config, "active-run persistence raised: " .. tostring(event))
    return nil, "active-run persistence raised"
  end
  if not event then
    log_error(config, "active-run persistence failed: " .. tostring(persist_error))
    return nil, persist_error
  end

  adapter.snapshots[group_name] = {
    participant_id = observation.participant_id,
    display_name = observation.display_name,
    callsign = observation.callsign,
    dcs_name = observation.dcs_name,
    dcs_type = observation.dcs_type,
    coalition = coalition,
  }

  if not observation.participant_id then
    log_message(config, "warning", "stable identity unavailable for slot " .. group_name)
  end
  log_message(config, "info", "emitted " .. event_type .. " sequence=" .. tostring(event.event_sequence))
  return event
end

function M.new(config)
  if type(config) ~= "table" then
    return nil, "participant configuration must be a table"
  end
  if type(config.controller) ~= "table" or type(config.controller.record) ~= "function" then
    return nil, "participant requires a lifecycle controller with record"
  end
  if type(config.envelope) ~= "table" or config.envelope.JSON_NULL == nil then
    return nil, "participant requires the envelope JSON null sentinel"
  end
  if type(config.BASE) ~= "table" or type(config.BASE.New) ~= "function" then
    return nil, "participant requires MOOSE BASE"
  end
  if type(config.EVENTS) ~= "table" or config.EVENTS.PlayerEnterUnit == nil or config.EVENTS.PlayerLeaveUnit == nil then
    return nil, "participant requires EVENTS.PlayerEnterUnit and EVENTS.PlayerLeaveUnit"
  end

  local roster, roster_error = build_roster(config.player_group_names)
  if not roster then
    return nil, roster_error
  end

  local adapter = {
    config = config,
    roster = roster,
    snapshots = {},
    watcher = nil,
  }

  function adapter:capture(event_type, event_data)
    if event_type ~= "participant.entered" and event_type ~= "participant.left" then
      return nil, "unsupported participant event type"
    end
    local ok, event, capture_error = pcall(capture, self, event_type, event_data)
    if not ok then
      log_error(self.config, "normalization raised: " .. tostring(event))
      return nil, "participant normalization raised"
    end
    return event, capture_error
  end

  function adapter:OnEventPlayerEnterUnit(event_data)
    return self:capture("participant.entered", event_data)
  end

  function adapter:OnEventPlayerLeaveUnit(event_data)
    return self:capture("participant.left", event_data)
  end

  function adapter:start()
    if self.watcher then
      return self.watcher
    end

    local ok, watcher = pcall(function()
      return self.config.BASE:New()
    end)
    if not ok or type(watcher) ~= "table" then
      log_error(self.config, "creating MOOSE participant watcher failed: " .. tostring(watcher))
      return nil, "creating MOOSE participant watcher failed"
    end

    function watcher:OnEventPlayerEnterUnit(event_data)
      return adapter:OnEventPlayerEnterUnit(event_data)
    end

    function watcher:OnEventPlayerLeaveUnit(event_data)
      return adapter:OnEventPlayerLeaveUnit(event_data)
    end

    local enter_handled, enter_error = pcall(function()
      watcher:HandleEvent(self.config.EVENTS.PlayerEnterUnit)
    end)
    if not enter_handled then
      log_error(self.config, "registering EVENTS.PlayerEnterUnit failed: " .. tostring(enter_error))
      return nil, "registering EVENTS.PlayerEnterUnit failed"
    end

    local leave_handled, leave_error = pcall(function()
      watcher:HandleEvent(self.config.EVENTS.PlayerLeaveUnit)
    end)
    if not leave_handled then
      pcall(function()
        watcher:UnHandleEvent(self.config.EVENTS.PlayerEnterUnit)
      end)
      log_error(self.config, "registering EVENTS.PlayerLeaveUnit failed: " .. tostring(leave_error))
      return nil, "registering EVENTS.PlayerLeaveUnit failed"
    end

    self.watcher = watcher
    return watcher
  end

  function adapter:stop()
    local watcher = self.watcher
    if not watcher then
      return true
    end

    local enter_ok, enter_error = pcall(function()
      watcher:UnHandleEvent(self.config.EVENTS.PlayerEnterUnit)
    end)
    local leave_ok, leave_error = pcall(function()
      watcher:UnHandleEvent(self.config.EVENTS.PlayerLeaveUnit)
    end)
    self.watcher = nil

    if not enter_ok then
      log_error(self.config, "unregistering EVENTS.PlayerEnterUnit failed: " .. tostring(enter_error))
      return nil, "unregistering EVENTS.PlayerEnterUnit failed"
    end
    if not leave_ok then
      log_error(self.config, "unregistering EVENTS.PlayerLeaveUnit failed: " .. tostring(leave_error))
      return nil, "unregistering EVENTS.PlayerLeaveUnit failed"
    end
    return true
  end

  return adapter
end

return M

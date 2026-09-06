local M = {}

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
  if type(config.log) == "function" then
    pcall(config.log, level, "combat capture: " .. message)
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

local function first_method(config, receiver, first_name, second_name)
  local value = call_method(config, receiver, first_name)
  if value ~= nil then
    return value
  end
  return call_method(config, receiver, second_name)
end

local function first_field(config, event_data, names)
  for _, name in ipairs(names) do
    local value = read_field(config, event_data, name)
    if value ~= nil then
      return value
    end
  end
  return nil
end

local function observed_unit(config, event_data, prefix)
  if prefix == "Ini" then
    return first_field(config, event_data, { "IniDCSUnit", "initiator", "IniUnit" })
  end
  return first_field(config, event_data, { "TgtDCSUnit", "target", "TgtUnit" })
end

local function group_name(config, event_data, prefix, unit)
  local name = non_empty_string(read_field(config, event_data, prefix .. "GroupName"))
    or non_empty_string(read_field(config, event_data, prefix .. "DCSGroupName"))
  if name then
    return name
  end
  local group = first_method(config, unit, "getGroup", "GetGroup")
  return non_empty_string(first_method(config, group, "getName", "GetName"))
end

local function unit_name(config, event_data, prefix, unit)
  return non_empty_string(read_field(config, event_data, prefix .. "UnitName"))
    or non_empty_string(read_field(config, event_data, prefix .. "DCSUnitName"))
    or non_empty_string(first_method(config, unit, "getName", "GetName"))
end

local function type_name(config, event_data, prefix, unit)
  return non_empty_string(read_field(config, event_data, prefix .. "TypeName"))
    or non_empty_string(first_method(config, unit, "getTypeName", "GetTypeName"))
end

local function coalition(config, event_data, prefix, unit)
  local value = read_field(config, event_data, prefix .. "Coalition")
  if value ~= nil then
    return value
  end
  return first_method(config, unit, "getCoalition", "GetCoalition")
end

local function player_name(config, event_data, prefix, unit)
  return non_empty_string(read_field(config, event_data, prefix .. "PlayerName"))
    or non_empty_string(first_method(config, unit, "getPlayerName", "GetPlayerName"))
end

local function callsign(config, unit)
  local raw = call_method(config, unit, "GetDCSObject") or unit
  return non_empty_string(first_method(config, raw, "getCallsign", "GetCallsign"))
end

local function observation(config, event_data, prefix)
  local unit = observed_unit(config, event_data, prefix)
  return {
    unit = unit,
    group_name = group_name(config, event_data, prefix, unit),
    dcs_name = unit_name(config, event_data, prefix, unit),
    dcs_type = type_name(config, event_data, prefix, unit),
    coalition = coalition(config, event_data, prefix, unit),
    category = read_field(config, event_data, prefix .. "Category"),
    display_name = player_name(config, event_data, prefix, unit),
    participant_id = non_empty_string(read_field(config, event_data, prefix .. "PlayerUCID")),
    callsign = callsign(config, unit),
  }
end

local function resolve_tracked(config, event_data, prefix, observed, sim_time)
  local registry = config.asset_registry
  if type(registry) ~= "table" or type(registry.resolve_unit) ~= "function" then
    return nil
  end
  local evidence = {
    sim_time = sim_time,
    group_name = observed.group_name,
    dcs_name = observed.dcs_name,
    dcs_type = observed.dcs_type,
    coalition = observed.coalition,
  }
  local candidates
  if prefix == "Ini" then
    candidates = { "IniDCSUnit", "initiator", "IniUnit" }
  else
    candidates = { "TgtDCSUnit", "target", "TgtUnit" }
  end
  local seen = {}
  for _, field_name in ipairs(candidates) do
    local candidate = read_field(config, event_data, field_name)
    if candidate ~= nil and not seen[candidate] then
      seen[candidate] = true
      local ok, reference = pcall(registry.resolve_unit, registry, candidate, evidence)
      if ok and type(reference) == "table" and reference.status == "known" then
        return reference
      elseif not ok then
        log_error(config, prefix .. " tracked asset resolution raised: " .. tostring(reference))
      end
    end
  end
  if observed.unit ~= nil and not seen[observed.unit] then
    local ok, reference = pcall(registry.resolve_unit, registry, observed.unit, evidence)
    if ok and type(reference) == "table" and reference.status == "known" then
      return reference
    elseif not ok then
      log_error(config, prefix .. " tracked asset resolution raised: " .. tostring(reference))
    end
  end
  return nil
end

local function known_actor(observed, asset)
  if
    not observed.unit
    and not observed.dcs_name
    and not observed.dcs_type
    and not observed.participant_id
    and not observed.display_name
  then
    return nil
  end
  if observed.participant_id and not observed.dcs_name and not observed.dcs_type and not asset then
    return {
      status = "known",
      kind = "participant",
      participant_id = observed.participant_id,
      display_name = observed.display_name,
      callsign = observed.callsign,
      coalition = observed.coalition,
    }
  end
  -- DCS Unit.Category uses 0/1 for airplanes/helicopters. Actor references in
  -- contract v1 do not claim ground units or ships are aircraft.
  if not asset and type(observed.category) == "number" and observed.category ~= 0 and observed.category ~= 1 then
    return nil
  end
  if not asset and not observed.dcs_name and not observed.dcs_type then
    return nil
  end
  return {
    status = "known",
    kind = "aircraft",
    participant_id = observed.participant_id,
    asset_key = asset and asset.asset_key or nil,
    display_name = observed.display_name,
    callsign = observed.callsign,
    dcs_name = observed.dcs_name or (asset and asset.dcs_name),
    dcs_type = observed.dcs_type or (asset and asset.dcs_type),
    coalition = observed.coalition == nil and asset and asset.coalition or observed.coalition,
  }
end

local function unknown_actor(observed, reason)
  return {
    status = "unknown",
    kind = "unknown",
    reason = reason,
    display_name = observed.display_name,
    callsign = observed.callsign,
    dcs_name = observed.dcs_name,
    dcs_type = observed.dcs_type,
    coalition = observed.coalition,
  }
end

local function actor_reference(observed, asset)
  local actor = known_actor(observed, asset)
  if actor then
    return actor
  end
  local reported = observed.unit ~= nil
    or observed.dcs_name ~= nil
    or observed.dcs_type ~= nil
    or observed.display_name ~= nil
    or observed.participant_id ~= nil
    or observed.coalition ~= nil
  return unknown_actor(observed, reported and "unresolved" or "not-reported")
end

local function target_reference(observed, asset)
  return {
    status = "known",
    kind = "aircraft",
    participant_id = observed.participant_id,
    asset_key = asset.asset_key,
    display_name = observed.display_name,
    callsign = observed.callsign,
    dcs_name = asset.dcs_name or observed.dcs_name,
    dcs_type = asset.dcs_type or observed.dcs_type,
    coalition = asset.coalition,
  }
end

local function read_location(config, unit)
  local coordinate = call_method(config, unit, "GetCoordinate")
  local vector = call_method(config, coordinate, "GetVec3")
  if not vector then
    local raw = call_method(config, unit, "GetDCSObject") or unit
    local position = first_method(config, raw, "getPosition", "GetPosition")
    vector = read_field(config, position, "p") or position
  end
  local x = read_field(config, vector, "x")
  local y = read_field(config, vector, "y")
  local z = read_field(config, vector, "z")
  if not is_finite_number(x) or not is_finite_number(y) or not is_finite_number(z) then
    return { status = "unknown", reason = "unavailable" }
  end
  return { status = "known", coordinate_system = "dcs-local", x = x, y = y, z = z }
end

local function weapon_reference(config, event_data)
  local weapon = first_field(config, event_data, { "Weapon", "weapon", "projectile" })
  local name = non_empty_string(read_field(config, event_data, "WeaponName"))
    or non_empty_string(read_field(config, event_data, "weapon_name"))
    or non_empty_string(first_method(config, weapon, "getTypeName", "GetTypeName"))
  if name == "Unknown Weapon" or name == "Unknown Type" then
    name = nil
  end
  if not name then
    return config.envelope.JSON_NULL
  end
  return { status = "known", dcs_type = name, display_name = name, category = "unknown" }
end

local function capture(adapter, event_data, event_type, dcs_event_name)
  local config = adapter.config
  if type(event_data) ~= "table" then
    log_error(config, "OnEvent" .. dcs_event_name .. " received no event table")
    return nil, "combat event data is unavailable"
  end
  local sim_time = read_field(config, event_data, "time")
  if not is_finite_number(sim_time) or sim_time < 0 then
    log_error(config, "event time is unavailable; lifecycle time provider will be used")
    sim_time = nil
  end
  local victim = observation(config, event_data, "Tgt")
  local victim_asset = resolve_tracked(config, event_data, "Tgt", victim, sim_time)
  if not victim_asset then
    return nil, "target is outside the tracked asset registry"
  end
  local attacker = observation(config, event_data, "Ini")
  local attacker_asset = resolve_tracked(config, event_data, "Ini", attacker, sim_time)
  local initiator = actor_reference(attacker, attacker_asset)
  local input = {
    event_type = event_type,
    sim_time = sim_time,
    initiator = initiator,
    target = target_reference(victim, victim_asset),
    participant = config.envelope.JSON_NULL,
    asset = victim_asset,
    weapon = weapon_reference(config, event_data),
    coalition = initiator.coalition == nil and "unknown" or initiator.coalition,
    location = read_location(config, victim.unit),
    payload = { dcs_event_name = dcs_event_name },
  }
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
  log_message(config, "info", "emitted " .. event_type .. " asset=" .. victim_asset.asset_key)
  return event
end

local function usable_event(value)
  return type(value) == "number" and value ~= -1
end

function M.new(config)
  if type(config) ~= "table" then
    return nil, "combat configuration must be a table"
  end
  if type(config.controller) ~= "table" or type(config.controller.record) ~= "function" then
    return nil, "combat requires a lifecycle controller with record"
  end
  if type(config.envelope) ~= "table" or config.envelope.JSON_NULL == nil then
    return nil, "combat requires the envelope JSON null sentinel"
  end
  if type(config.asset_registry) ~= "table" or type(config.asset_registry.resolve_unit) ~= "function" then
    return nil, "combat requires the tracked asset registry"
  end
  if type(config.BASE) ~= "table" or type(config.BASE.New) ~= "function" then
    return nil, "combat requires MOOSE BASE"
  end
  if type(config.EVENTS) ~= "table" or not usable_event(config.EVENTS.Hit) then
    return nil, "combat requires EVENTS.Hit"
  end

  local adapter = { config = config, watcher = nil }

  function adapter:capture_hit(event_data)
    local ok, event, capture_error = pcall(capture, self, event_data, "asset.hit", "hit")
    if not ok then
      log_error(self.config, "Hit normalization raised: " .. tostring(event))
      return nil, "Hit normalization raised"
    end
    return event, capture_error
  end

  function adapter:capture_kill(event_data)
    local ok, event, capture_error = pcall(capture, self, event_data, "asset.kill-reported", "kill")
    if not ok then
      log_error(self.config, "Kill normalization raised: " .. tostring(event))
      return nil, "Kill normalization raised"
    end
    return event, capture_error
  end

  function adapter:OnEventHit(event_data)
    return self:capture_hit(event_data)
  end

  function adapter:OnEventKill(event_data)
    return self:capture_kill(event_data)
  end

  function adapter:start()
    if self.watcher then
      return self.watcher
    end
    local ok, watcher = pcall(function()
      return self.config.BASE:New()
    end)
    if not ok or type(watcher) ~= "table" then
      log_error(self.config, "creating MOOSE combat watcher failed: " .. tostring(watcher))
      return nil, "creating MOOSE combat watcher failed"
    end
    function watcher:OnEventHit(event_data)
      return adapter:OnEventHit(event_data)
    end
    function watcher:OnEventKill(event_data)
      return adapter:OnEventKill(event_data)
    end
    local handled, handle_error = pcall(function()
      watcher:HandleEvent(self.config.EVENTS.Hit)
    end)
    if not handled then
      log_error(self.config, "registering combat events failed: " .. tostring(handle_error))
      return nil, "registering combat events failed"
    end
    if usable_event(self.config.EVENTS.Kill) then
      handled, handle_error = pcall(function()
        watcher:HandleEvent(self.config.EVENTS.Kill)
      end)
      if not handled then
        pcall(function()
          watcher:UnHandleEvent(self.config.EVENTS.Hit)
        end)
        log_error(self.config, "registering EVENTS.Kill failed: " .. tostring(handle_error))
        return nil, "registering EVENTS.Kill failed"
      end
    end
    self.watcher = watcher
    return watcher
  end

  function adapter:stop()
    if not self.watcher then
      return true
    end
    local watcher = self.watcher
    self.watcher = nil
    local hit_ok, hit_error = pcall(function()
      watcher:UnHandleEvent(self.config.EVENTS.Hit)
    end)
    local kill_ok, kill_error = true, nil
    if usable_event(self.config.EVENTS.Kill) then
      kill_ok, kill_error = pcall(function()
        watcher:UnHandleEvent(self.config.EVENTS.Kill)
      end)
    end
    if not hit_ok or not kill_ok then
      log_error(self.config, "unregistering combat events failed: " .. tostring(hit_error or kill_error))
      return nil, "unregistering combat events failed"
    end
    return true
  end

  return adapter
end

return M

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
    pcall(config.log, level, "asset capture: " .. message)
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

local function token_part(value)
  local result = string.lower(value)
  result = string.gsub(result, "[^a-z0-9._-]", "-")
  result = string.gsub(result, "^[-._]+", "")
  if result == "" then
    return nil
  end
  return result
end

local function build_roster(names, role)
  if type(names) ~= "table" or #names == 0 then
    return nil, role .. " group names are required"
  end

  local roster = { names = names, lookup = {}, token_lookup = {} }
  for index, name in ipairs(names) do
    if type(name) ~= "string" or string.len(name) == 0 then
      return nil, role .. " group name " .. tostring(index) .. " is invalid"
    end
    if roster.lookup[name] then
      return nil, role .. " group names contain a duplicate"
    end
    local key_part = token_part(name)
    if not key_part or roster.token_lookup[key_part] then
      return nil, role .. " group names do not produce distinct asset key tokens"
    end
    roster.lookup[name] = { index = index, key_part = key_part }
    roster.token_lookup[key_part] = true
  end
  return roster
end

local function matches_spawned_group(group_name, configured_name)
  if group_name == configured_name then
    return true
  end
  local prefix_length = string.len(configured_name)
  if string.len(group_name) ~= prefix_length + 4 then
    return false
  end
  return string.sub(group_name, 1, prefix_length + 1) == configured_name .. "#"
    and string.match(string.sub(group_name, prefix_length + 2), "^%d%d%d$") ~= nil
end

local function find_bandit_entry(roster, group_name)
  if not group_name then
    return nil
  end
  for _, configured_name in ipairs(roster.names) do
    if matches_spawned_group(group_name, configured_name) then
      return configured_name, roster.lookup[configured_name]
    end
  end
  return nil
end

local function raw_unit(config, unit)
  return call_method(config, unit, "GetDCSObject") or unit
end

local function read_identity(config, unit)
  local raw = raw_unit(config, unit)
  local id = first_method(config, raw, "getID", "GetID")
  if id == nil and raw ~= unit then
    id = first_method(config, unit, "GetID", "getID")
  end
  if type(id) ~= "number" and type(id) ~= "string" then
    id = nil
  end
  return raw, id
end

local function read_group_name(config, unit)
  local name = non_empty_string(first_method(config, unit, "getGroupName", "GetGroupName"))
  if name then
    return name
  end
  local group = first_method(config, unit, "getGroup", "GetGroup")
  return non_empty_string(first_method(config, group, "getName", "GetName"))
end

local function read_observation(config, unit, group_name)
  local raw, identity_id = read_identity(config, unit)
  local dcs_name = non_empty_string(first_method(config, unit, "GetName", "getName"))
  if not dcs_name and raw ~= unit then
    dcs_name = non_empty_string(first_method(config, raw, "getName", "GetName"))
  end
  local dcs_type = non_empty_string(first_method(config, unit, "GetTypeName", "getTypeName"))
  if not dcs_type and raw ~= unit then
    dcs_type = non_empty_string(first_method(config, raw, "getTypeName", "GetTypeName"))
  end
  local coalition = first_method(config, unit, "GetCoalition", "getCoalition")
  if coalition == nil and raw ~= unit then
    coalition = first_method(config, raw, "getCoalition", "GetCoalition")
  end
  return {
    unit = unit,
    raw = raw,
    identity_id = identity_id,
    group_name = group_name or read_group_name(config, raw),
    dcs_name = dcs_name,
    dcs_type = dcs_type,
    coalition = coalition,
  }
end

local function read_location(config, observation)
  local coordinate = call_method(config, observation.unit, "GetCoordinate")
  local vector = call_method(config, coordinate, "GetVec3")
  if not vector then
    local position = first_method(config, observation.raw, "getPosition", "GetPosition")
    vector = read_field(config, position, "p") or position
  end
  local x = read_field(config, vector, "x")
  local y = read_field(config, vector, "y")
  local z = read_field(config, vector, "z")
  if not is_finite_number(x) or not is_finite_number(y) or not is_finite_number(z) then
    return { status = "unknown", reason = "unavailable" }
  end
  return {
    status = "known",
    coordinate_system = "dcs-local",
    x = x,
    y = y,
    z = z,
  }
end

local function reference(instance)
  return {
    status = "known",
    kind = "aircraft",
    asset_key = instance.asset_key,
    dcs_name = instance.dcs_name,
    dcs_type = instance.dcs_type,
    coalition = instance.coalition,
  }
end

local function unknown_reference(config, unit, group_name)
  local observation = read_observation(config, unit, group_name)
  return {
    status = "unknown",
    kind = "aircraft",
    reason = "instance-identity-unavailable",
    dcs_name = observation.dcs_name or observation.group_name,
    dcs_type = observation.dcs_type,
    coalition = observation.coalition,
  }
end

local function same_identity(active, observation)
  if active.identity_object ~= nil and observation.raw ~= nil then
    return active.identity_object == observation.raw
  end
  return active.identity_id ~= nil
    and observation.identity_id ~= nil
    and type(active.identity_id) == type(observation.identity_id)
    and active.identity_id == observation.identity_id
end

local function confirms_replacement(active, observation)
  if active.identity_object ~= nil and observation.raw ~= nil then
    return active.identity_object ~= observation.raw
  end
  return active.identity_id ~= nil
    and observation.identity_id ~= nil
    and (type(active.identity_id) ~= type(observation.identity_id) or active.identity_id ~= observation.identity_id)
end

local function event_time(config, value)
  if is_finite_number(value) and value >= 0 then
    return value
  end
  return nil
end

function M.new(config)
  if type(config) ~= "table" then
    return nil, "asset configuration must be a table"
  end
  if type(config.controller) ~= "table" or type(config.controller.record) ~= "function" then
    return nil, "asset requires a lifecycle controller with record"
  end
  if type(config.envelope) ~= "table" or config.envelope.JSON_NULL == nil then
    return nil, "asset requires the envelope JSON null sentinel"
  end
  if type(config.BASE) ~= "table" or type(config.BASE.New) ~= "function" then
    return nil, "asset requires MOOSE BASE"
  end
  if type(config.EVENTS) ~= "table" or config.EVENTS.PlayerEnterUnit == nil then
    return nil, "asset requires EVENTS.PlayerEnterUnit"
  end

  local player_roster, player_error = build_roster(config.player_group_names, "player")
  if not player_roster then
    return nil, player_error
  end
  local bandit_roster, bandit_error = build_roster(config.bandit_group_names, "bandit")
  if not bandit_roster then
    return nil, bandit_error
  end

  local adapter = {
    config = config,
    player_roster = player_roster,
    bandit_roster = bandit_roster,
    generations = {},
    active_players = {},
    instances_by_object = {},
    instances_by_id = {},
    bandit_groups = {},
    watcher = nil,
  }

  local function identity_map_key(id)
    if id == nil then
      return nil
    end
    return type(id) .. ":" .. tostring(id)
  end

  local function add_identity(instance, observation)
    if observation.unit ~= nil then
      adapter.instances_by_object[observation.unit] = instance
    end
    if observation.raw ~= nil then
      adapter.instances_by_object[observation.raw] = instance
    end
    local id_key = identity_map_key(observation.identity_id)
    if id_key then
      adapter.instances_by_id[id_key] = instance
    end
  end

  local function remove_identity(instance)
    if instance.unit_object and adapter.instances_by_object[instance.unit_object] == instance then
      adapter.instances_by_object[instance.unit_object] = nil
    end
    if instance.identity_object and adapter.instances_by_object[instance.identity_object] == instance then
      adapter.instances_by_object[instance.identity_object] = nil
    end
    local id_key = identity_map_key(instance.identity_id)
    if id_key and adapter.instances_by_id[id_key] == instance then
      adapter.instances_by_id[id_key] = nil
    end
  end

  local function persist(event_type, instance, observation, sim_time, payload)
    local input = {
      event_type = event_type,
      initiator = config.envelope.JSON_NULL,
      target = config.envelope.JSON_NULL,
      participant = config.envelope.JSON_NULL,
      asset = reference(instance),
      weapon = config.envelope.JSON_NULL,
      coalition = instance.coalition,
      location = read_location(config, observation),
      payload = payload or {},
    }
    input.sim_time = event_time(config, sim_time)

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
    log_message(config, "info", "emitted " .. event_type .. " asset=" .. instance.asset_key)
    return event
  end

  local function new_instance(configured_name, unit_index, observation, sim_time)
    local roster_entry = player_roster.lookup[configured_name] or bandit_roster.lookup[configured_name]
    local generation_key = roster_entry.key_part .. ".u" .. tostring(unit_index)
    local generation = (adapter.generations[generation_key] or 0) + 1
    local instance = {
      asset_key = generation_key .. ".g" .. tostring(generation),
      configured_name = configured_name,
      unit_index = unit_index,
      generation = generation,
      unit_object = observation.unit,
      identity_object = observation.raw,
      identity_id = observation.identity_id,
      dcs_name = observation.dcs_name or observation.group_name,
      dcs_type = observation.dcs_type,
      coalition = map_coalition(observation.coalition),
      active = true,
      observation = observation,
    }
    local spawned, spawn_error = persist("asset.spawned", instance, observation, sim_time, {})
    if not spawned then
      return nil, spawn_error
    end
    adapter.generations[generation_key] = generation
    add_identity(instance, observation)
    return instance, spawned
  end

  function adapter:observe_player_unit(unit, sim_time, known_group_name)
    local observation = read_observation(self.config, unit, known_group_name)
    local entry = observation.group_name and self.player_roster.lookup[observation.group_name]
    if not entry then
      return nil, "player aircraft is outside the tracked roster"
    end
    if
      self.config.player_coalition ~= nil
      and observation.coalition ~= nil
      and observation.coalition ~= self.config.player_coalition
    then
      return nil, "player aircraft coalition does not match the tracked roster"
    end

    local active = self.active_players[observation.group_name]
    if active and active.active and same_identity(active, observation) then
      return reference(active), false, active
    end
    if active and active.active and not confirms_replacement(active, observation) then
      return nil, "player aircraft replacement identity is unavailable"
    end
    if active and active.active then
      active.active = false
      remove_identity(active)
    end

    local instance, spawned_or_error = new_instance(observation.group_name, 1, observation, sim_time)
    if not instance then
      return nil, spawned_or_error
    end
    self.active_players[observation.group_name] = instance
    return reference(instance), true, instance, spawned_or_error
  end

  function adapter:register_player_group(group, sim_time)
    local group_name = non_empty_string(first_method(self.config, group, "GetName", "getName"))
    if not group_name or not self.player_roster.lookup[group_name] then
      return nil, "player group is outside the tracked roster"
    end
    local units = first_method(self.config, group, "GetUnits", "getUnits")
    if type(units) ~= "table" then
      return nil, "player group units are unavailable"
    end
    local first_reference
    for _, unit in ipairs(units) do
      local resolved = self:observe_player_unit(unit, sim_time, group_name)
      first_reference = first_reference or resolved
    end
    return first_reference
  end

  function adapter:register_bandit_group(group, configured_name, sim_time)
    local runtime_name = non_empty_string(first_method(self.config, group, "GetName", "getName"))
    local canonical, roster_entry
    if configured_name and self.bandit_roster.lookup[configured_name] then
      canonical = configured_name
      roster_entry = self.bandit_roster.lookup[configured_name]
    else
      canonical, roster_entry = find_bandit_entry(self.bandit_roster, runtime_name)
    end
    if not canonical or not roster_entry then
      return nil, "bandit group is outside the tracked roster"
    end

    local group_raw = call_method(self.config, group, "GetDCSObject") or group
    local group_id = first_method(self.config, group_raw, "getID", "GetID")
    local group_key = identity_map_key(group_id) or group_raw
    if self.bandit_groups[group_key] then
      return self.bandit_groups[group_key], false
    end

    local units = first_method(self.config, group, "GetUnits", "getUnits")
    if type(units) ~= "table" then
      return nil, "bandit group units are unavailable"
    end
    local instances = {}
    for index, unit in ipairs(units) do
      local observation = read_observation(self.config, unit, runtime_name or canonical)
      if
        self.config.bandit_coalition ~= nil
        and observation.coalition ~= nil
        and observation.coalition ~= self.config.bandit_coalition
      then
        return nil, "bandit aircraft coalition does not match the tracked roster"
      end
      local instance, spawn_error = new_instance(canonical, index, observation, sim_time)
      if not instance then
        return nil, spawn_error
      end
      instances[#instances + 1] = instance
    end
    if #instances == 0 then
      return nil, "bandit group contains no aircraft"
    end
    self.bandit_groups[group_key] = instances
    return instances, true
  end

  function adapter:resolve_unit(unit)
    if unit == nil then
      return nil
    end
    local raw, id = read_identity(self.config, unit)
    local instance = self.instances_by_object[unit] or self.instances_by_object[raw]
    if not instance and raw == nil then
      local id_key = identity_map_key(id)
      instance = id_key and self.instances_by_id[id_key] or nil
    end
    if not instance or not instance.active then
      return nil
    end
    return reference(instance), instance
  end

  function adapter:unknown_reference(unit, group_name)
    return unknown_reference(self.config, unit, group_name)
  end

  function adapter:despawn_group(group, sim_time)
    local group_raw = call_method(self.config, group, "GetDCSObject") or group
    local group_id = first_method(self.config, group_raw, "getID", "GetID")
    local group_key = identity_map_key(group_id) or group_raw
    local instances = self.bandit_groups[group_key]
    if not instances then
      return nil, "bandit group has no tracked asset instances"
    end

    local all_emitted = true
    local first_error
    for _, instance in ipairs(instances) do
      if instance.active then
        local event, despawn_error =
          persist("asset.despawned", instance, instance.observation, sim_time, { reason = "intentional" })
        if not event then
          all_emitted = false
          first_error = first_error or despawn_error
        end
        instance.active = false
        remove_identity(instance)
      end
    end
    self.bandit_groups[group_key] = nil
    if not all_emitted then
      return nil, first_error
    end
    return true
  end

  function adapter:OnEventPlayerEnterUnit(event_data)
    if type(event_data) ~= "table" then
      return nil, "player lifecycle event data is unavailable"
    end
    local unit = read_field(self.config, event_data, "initiator")
      or read_field(self.config, event_data, "IniDCSUnit")
      or read_field(self.config, event_data, "IniUnit")
    local group_name = read_field(self.config, event_data, "IniGroupName")
    return self:observe_player_unit(unit, read_field(self.config, event_data, "time"), group_name)
  end

  function adapter:start()
    if self.watcher then
      return self.watcher
    end
    local ok, watcher = pcall(function()
      return self.config.BASE:New()
    end)
    if not ok or type(watcher) ~= "table" then
      return nil, "creating MOOSE asset watcher failed"
    end
    function watcher:OnEventPlayerEnterUnit(event_data)
      return adapter:OnEventPlayerEnterUnit(event_data)
    end
    local handled, handle_error = pcall(function()
      watcher:HandleEvent(self.config.EVENTS.PlayerEnterUnit)
    end)
    if not handled then
      log_error(self.config, "registering EVENTS.PlayerEnterUnit failed: " .. tostring(handle_error))
      return nil, "registering EVENTS.PlayerEnterUnit failed"
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
    local ok, stop_error = pcall(function()
      watcher:UnHandleEvent(self.config.EVENTS.PlayerEnterUnit)
    end)
    if not ok then
      log_error(self.config, "unregistering EVENTS.PlayerEnterUnit failed: " .. tostring(stop_error))
      return nil, "unregistering EVENTS.PlayerEnterUnit failed"
    end
    return true
  end

  return adapter
end

return M

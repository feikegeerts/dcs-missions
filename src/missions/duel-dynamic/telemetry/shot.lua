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
  local logger = config.log
  if type(logger) == "function" then
    pcall(logger, level, message)
  end
end

local function log_error(config, message)
  log_message(config, "error", "shot capture: " .. message)
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

local function first_field(config, object, first_name, second_name)
  local value = read_field(config, object, first_name)
  if value ~= nil then
    return value
  end
  if second_name then
    return read_field(config, object, second_name)
  end
  return nil
end

local function read_group_name(config, event_data)
  local group_name = non_empty_string(read_field(config, event_data, "IniGroupName"))
  if group_name then
    return group_name
  end

  local group = read_field(config, event_data, "IniGroup")
  return non_empty_string(call_method(config, group, "GetName"))
end

local function matches_spawned_bandit(group_name, configured_name)
  if group_name == configured_name then
    return true
  end

  -- SPAWN appends exactly #NNN to the configured group name. Comparing the
  -- complete suffix avoids accepting names such as Bandit-10 for Bandit-1.
  local prefix_length = string.len(configured_name)
  if string.len(group_name) ~= prefix_length + 4 then
    return false
  end
  if string.sub(group_name, 1, prefix_length) ~= configured_name then
    return false
  end
  if string.sub(group_name, prefix_length + 1, prefix_length + 1) ~= "#" then
    return false
  end
  return string.match(string.sub(group_name, prefix_length + 2), "^%d%d%d$") ~= nil
end

local function build_roster(config, names, role, allow_spawn_suffix)
  if type(names) ~= "table" or #names == 0 then
    return nil, role .. " group names are required"
  end

  local roster = {}
  for index, name in ipairs(names) do
    if type(name) ~= "string" or string.len(name) == 0 then
      return nil, role .. " group name " .. tostring(index) .. " is invalid"
    end
    if roster[name] then
      return nil, role .. " group names contain a duplicate"
    end
    roster[name] = index
  end

  return {
    names = names,
    lookup = roster,
    role = role,
    allow_spawn_suffix = allow_spawn_suffix,
  }
end

local function find_roster_entry(player_roster, bandit_roster, group_name)
  if player_roster.lookup[group_name] then
    return "player", player_roster.lookup[group_name]
  end

  for index, configured_name in ipairs(bandit_roster.names) do
    if bandit_roster.allow_spawn_suffix and matches_spawned_bandit(group_name, configured_name) then
      return "bandit", index
    end
  end

  return nil
end

local function is_aircraft_category(config, category)
  if category == nil then
    return true
  end

  if type(category) == "string" then
    local lowered = string.lower(category)
    if lowered == "airplane" or lowered == "helicopter" or lowered == "aircraft" then
      return true
    end
    if lowered == "ground" or lowered == "ship" or lowered == "structure" or lowered == "static" then
      return false
    end
    return true
  end

  local categories = config.unit_categories
  if type(categories) ~= "table" then
    local unit_api = rawget(_G, "Unit")
    categories = unit_api and unit_api.Category
  end
  if type(categories) ~= "table" then
    return true
  end

  if category == categories.AIRPLANE or category == categories.HELICOPTER then
    return true
  end

  for _, known_category in pairs(categories) do
    if category == known_category then
      return false
    end
  end
  return true
end

local function read_unit(config, event_data)
  return read_field(config, event_data, "IniUnit")
end

local function read_unit_name(config, event_data, unit)
  local name = non_empty_string(read_field(config, event_data, "IniUnitName"))
  if name then
    return name
  end
  return non_empty_string(call_method(config, unit, "GetName"))
end

local function read_type_name(config, event_data, unit, group)
  local type_name = non_empty_string(read_field(config, event_data, "IniTypeName"))
  if type_name then
    return type_name
  end

  type_name = non_empty_string(call_method(config, unit, "GetTypeName"))
  if type_name then
    return type_name
  end
  return non_empty_string(call_method(config, group, "GetTypeName"))
end

local function read_player_name(config, event_data, unit)
  local player_name = non_empty_string(read_field(config, event_data, "IniPlayerName"))
  if player_name then
    return player_name
  end
  return non_empty_string(call_method(config, unit, "GetPlayerName"))
end

local function read_callsign(config, event_data, unit)
  -- MOOSE UNIT:GetCallsign substitutes the unit name when DCS reports an
  -- empty callsign. Read only the raw DCS value so that fallback is not
  -- serialized as if it were a reported callsign.
  local dcs_unit = read_field(config, event_data, "IniDCSUnit")
  if dcs_unit == nil then
    -- MOOSE's UNIT wrapper exposes the underlying DCS unit for this narrow
    -- normalization fallback; no wrapper callsign method is used here.
    dcs_unit = call_method(config, unit, "GetDCSObject")
  end
  return non_empty_string(call_method(config, dcs_unit, "getCallsign"))
end

local function read_coalition(config, event_data, unit, group)
  local value = read_field(config, event_data, "IniCoalition")
  if value ~= nil then
    return value
  end

  value = call_method(config, unit, "GetCoalition")
  if value ~= nil then
    return value
  end
  return call_method(config, group, "GetCoalition")
end

local function read_location(config, unit)
  if unit == nil then
    return nil
  end

  -- POSITIONABLE:GetCoordinate and COORDINATE:GetVec3 are the MOOSE path.
  -- GetVec3 on the unit is retained as a wrapper-level fallback for older or
  -- partially populated MOOSE wrappers during a shot callback.
  local coordinate = call_method(config, unit, "GetCoordinate")
  local vector = call_method(config, coordinate, "GetVec3")
  if not vector and coordinate then
    local coordinate_x = read_field(config, coordinate, "x")
    local coordinate_y = read_field(config, coordinate, "y")
    local coordinate_z = read_field(config, coordinate, "z")
    if is_finite_number(coordinate_x) and is_finite_number(coordinate_y) and is_finite_number(coordinate_z) then
      vector = coordinate
    end
  end
  if not vector then
    vector = call_method(config, unit, "GetVec3")
  end
  if not vector then
    return nil
  end

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

local function is_runtime_weapon_type(value)
  value = non_empty_string(value)
  if not value then
    return nil
  end

  if value == "Unknown Weapon" or value == "Unknown Type" then
    return nil
  end
  return value
end

local function read_weapon_object(config, event_data)
  return first_field(config, event_data, "Weapon", "weapon")
end

local function read_weapon_type(config, event_data, weapon)
  local weapon_type = is_runtime_weapon_type(read_field(config, event_data, "WeaponName"))
  if weapon_type then
    return weapon_type
  end

  -- Core.Event documents WeaponName, but the pinned MOOSE event adapter does
  -- not guarantee that it is promoted for every weapon. Prefer a MOOSE
  -- wrapper method if a caller supplied a WEAPON wrapper.
  weapon_type = is_runtime_weapon_type(call_method(config, weapon, "GetTypeName"))
  if weapon_type then
    return weapon_type
  end

  -- The pinned Core.Event implementation stores the launch object in
  -- EventData.weapon/EventData.Weapon as the raw DCS object. This is the
  -- isolated, pcall-protected fallback for a missing MOOSE WeaponName.
  weapon_type = is_runtime_weapon_type(call_method(config, weapon, "getTypeName"))
  return weapon_type
end

local function category_from_value(value)
  if type(value) == "string" then
    local lowered = string.lower(value)
    if lowered == "missile" or lowered == "bomb" or lowered == "rocket" then
      return lowered
    end
    if lowered == "shell" or lowered == "torpedo" or lowered == "fuel_tank" or lowered == "container" then
      return "other-discrete"
    end
  end
  return nil
end

local function category_from_dcs_constants(config, value)
  if value == nil then
    return nil
  end

  local categories = config.weapon_categories
  if type(categories) ~= "table" then
    local weapon_api = rawget(_G, "Weapon")
    categories = weapon_api and weapon_api.Category
  end
  if type(categories) ~= "table" then
    return nil
  end

  if value == categories.MISSILE then
    return "missile"
  elseif value == categories.BOMB then
    return "bomb"
  elseif value == categories.ROCKET then
    return "rocket"
  elseif value == categories.SHELL or value == categories.TORPEDO then
    return "other-discrete"
  end
  return nil
end

local function category_from_wrapper(config, weapon)
  local category = category_from_value(read_field(config, weapon, "category"))
  if category then
    return category
  end

  category = category_from_dcs_constants(config, read_field(config, weapon, "category"))
  if category then
    return category
  end

  local methods = {
    { "IsMissile", "missile" },
    { "IsBomb", "bomb" },
    { "IsRocket", "rocket" },
    { "IsShell", "other-discrete" },
    { "IsTorpedo", "other-discrete" },
  }
  for _, method in ipairs(methods) do
    if call_method(config, weapon, method[1]) == true then
      return method[2]
    end
  end
  return nil
end

local function read_weapon_category(config, event_data, weapon)
  -- Core.Event may expose WeaponCategory when it can resolve WeaponUNIT. Use
  -- that documented MOOSE observation before consulting wrapper/raw fallbacks.
  local category_value = read_field(config, event_data, "WeaponCategory")
  local category = category_from_value(category_value) or category_from_dcs_constants(config, category_value)
  if category then
    return category
  end

  category = category_from_wrapper(config, weapon)
  if category then
    return category
  end

  -- MOOSE Core.Event does not promote the raw weapon descriptor category for
  -- ordinary S_EVENT_SHOT callbacks. The raw DCS access is isolated here and
  -- protected by call_method/read_field; an unavailable descriptor remains
  -- explicitly unknown instead of being inferred from a weapon name.
  local descriptor = call_method(config, weapon, "getDesc")
  category_value = read_field(config, descriptor, "category")
  return category_from_value(category_value) or category_from_dcs_constants(config, category_value)
end

local function is_human_player_name(player_name)
  return non_empty_string(player_name) ~= nil
end

local function make_participant(config, player_name, player_ucid, callsign, coalition)
  if not is_human_player_name(player_name) and non_empty_string(player_ucid) == nil then
    return config.envelope.JSON_NULL
  end

  local stable_id = non_empty_string(player_ucid)
  if stable_id then
    return {
      status = "known",
      kind = "participant",
      participant_id = stable_id,
      display_name = player_name,
      callsign = callsign,
      coalition = coalition,
    }
  end

  return {
    status = "unknown",
    kind = "participant",
    reason = "stable-identity-unavailable",
    display_name = player_name,
    callsign = callsign,
    coalition = coalition,
  }
end

local function resolve_asset(config, unit, group_name, dcs_name, dcs_type, coalition, sim_time)
  local registry = config.asset_registry
  if type(registry) == "table" and type(registry.resolve_unit) == "function" then
    local ok, resolved = pcall(registry.resolve_unit, registry, unit, {
      sim_time = sim_time,
      group_name = group_name,
      dcs_name = dcs_name,
      dcs_type = dcs_type,
      coalition = coalition,
    })
    if ok and type(resolved) == "table" and resolved.status == "known" then
      return resolved
    end
    if not ok then
      log_error(config, "tracked asset resolution raised: " .. tostring(resolved))
    end
  end

  return {
    status = "unknown",
    kind = "aircraft",
    reason = "instance-identity-unavailable",
    dcs_name = dcs_name or group_name,
    dcs_type = dcs_type,
    coalition = coalition,
  }
end

local function capture(adapter, event_data)
  local config = adapter.config
  if type(event_data) ~= "table" then
    log_error(config, "OnEventShot received no event table")
    return nil, "shot event data is unavailable"
  end

  local group_name = read_group_name(config, event_data)
  if not group_name then
    log_error(config, "initiator group name is unavailable")
    return nil, "initiator group name is unavailable"
  end

  local role, roster_index = find_roster_entry(adapter.player_roster, adapter.bandit_roster, group_name)
  if not role then
    return nil, "initiator group is outside the tracked roster"
  end

  local unit = read_unit(config, event_data)
  local group = read_field(config, event_data, "IniGroup")
  local unit_category = read_field(config, event_data, "IniCategory")
  if not is_aircraft_category(config, unit_category) then
    return nil, "initiator is not an aircraft"
  end

  local coalition = read_coalition(config, event_data, unit, group)
  local expected_coalition = role == "player" and config.player_coalition or config.bandit_coalition
  if expected_coalition ~= nil and coalition ~= nil and coalition ~= expected_coalition then
    return nil, "initiator coalition does not match the tracked roster"
  end

  local unit_name = read_unit_name(config, event_data, unit)
  local type_name = read_type_name(config, event_data, unit, group)
  local player_name = read_player_name(config, event_data, unit)
  local player_ucid = read_field(config, event_data, "IniPlayerUCID")
  local stable_player_ucid = non_empty_string(player_ucid)
  local callsign = read_callsign(config, event_data, unit)
  local weapon = read_weapon_object(config, event_data)
  local weapon_type = read_weapon_type(config, event_data, weapon)
  local weapon_category = read_weapon_category(config, event_data, weapon) or "unknown"
  local location = read_location(config, unit)
  local event_time = read_field(config, event_data, "time")

  if not is_finite_number(event_time) or event_time < 0 then
    log_error(config, "event time is unavailable; lifecycle time provider will be used")
    event_time = nil
  end

  local dcs_name = unit_name or group_name
  local asset = resolve_asset(config, unit, group_name, dcs_name, type_name, coalition, event_time)
  local actor = {
    status = "known",
    kind = "aircraft",
    participant_id = stable_player_ucid,
    asset_key = asset.status == "known" and asset.asset_key or nil,
    display_name = player_name,
    callsign = callsign,
    dcs_name = dcs_name,
    dcs_type = type_name,
    coalition = coalition,
  }
  local weapon_reference
  if weapon_type then
    weapon_reference = {
      status = "known",
      dcs_type = weapon_type,
      display_name = weapon_type,
      category = weapon_category,
    }
  else
    weapon_reference = {
      status = "unknown",
      reason = "type-not-reported",
      category = "unknown",
    }
  end

  local input = {
    event_type = "ordnance.fired",
    sim_time = event_time,
    initiator = actor,
    target = config.envelope.JSON_NULL,
    participant = make_participant(config, player_name, player_ucid, callsign, coalition),
    asset = asset,
    weapon = weapon_reference,
    coalition = coalition == nil and "unknown" or coalition,
    location = location or { status = "unknown", reason = "unavailable" },
    payload = { dcs_event_name = "shot" },
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

  return event, role, roster_index
end

function M.new(config)
  if type(config) ~= "table" then
    return nil, "shot configuration must be a table"
  end
  if type(config.controller) ~= "table" or type(config.controller.record) ~= "function" then
    return nil, "shot requires a lifecycle controller with record"
  end
  if type(config.envelope) ~= "table" or config.envelope.JSON_NULL == nil then
    return nil, "shot requires the envelope JSON null sentinel"
  end
  if type(config.BASE) ~= "table" or type(config.BASE.New) ~= "function" then
    return nil, "shot requires MOOSE BASE"
  end
  if type(config.EVENTS) ~= "table" or config.EVENTS.Shot == nil then
    return nil, "shot requires EVENTS.Shot"
  end

  local player_roster, player_error = build_roster(config, config.player_group_names, "player", false)
  if not player_roster then
    return nil, player_error
  end
  local bandit_roster, bandit_error = build_roster(config, config.bandit_group_names, "bandit", true)
  if not bandit_roster then
    return nil, bandit_error
  end

  for player_name in pairs(player_roster.lookup) do
    for bandit_name in pairs(bandit_roster.lookup) do
      if player_name == bandit_name then
        return nil, "player and bandit group names must be distinct"
      end
    end
  end

  local adapter = {
    config = config,
    player_roster = player_roster,
    bandit_roster = bandit_roster,
    watcher = nil,
  }

  function adapter:capture(event_data)
    local ok, event, first_error, second_error = pcall(capture, self, event_data)
    if not ok then
      log_error(self.config, "normalization raised: " .. tostring(event))
      return nil, "shot normalization raised"
    end
    return event, first_error, second_error
  end

  function adapter:OnEventShot(event_data)
    return self:capture(event_data)
  end

  function adapter:extend_player_roster(names)
    if type(names) ~= "table" or #names == 0 then
      return nil, "player group names are required"
    end

    local additions = {}
    for index, name in ipairs(names) do
      if type(name) ~= "string" or string.len(name) == 0 then
        return nil, "player group name " .. tostring(index) .. " is invalid"
      end
      if self.player_roster.lookup[name] or additions[name] then
        return nil, name .. " already tracked"
      end
      if self.bandit_roster.lookup[name] then
        return nil, name .. " collides with bandit roster"
      end
      additions[name] = true
    end

    for _, name in ipairs(names) do
      local index = #self.player_roster.names + 1
      self.player_roster.names[index] = name
      self.player_roster.lookup[name] = index
    end
    return true
  end

  function adapter:start()
    if self.watcher then
      return self.watcher
    end

    local ok, watcher = pcall(function()
      return self.config.BASE:New()
    end)
    if not ok or type(watcher) ~= "table" then
      log_error(self.config, "creating MOOSE Shot watcher failed: " .. tostring(watcher))
      return nil, "creating MOOSE Shot watcher failed"
    end

    function watcher:OnEventShot(event_data)
      return adapter:OnEventShot(event_data)
    end

    local handled, handle_error = pcall(function()
      watcher:HandleEvent(self.config.EVENTS.Shot)
    end)
    if not handled then
      log_error(self.config, "registering EVENTS.Shot failed: " .. tostring(handle_error))
      return nil, "registering EVENTS.Shot failed"
    end

    self.watcher = watcher
    return watcher
  end

  function adapter:stop()
    local watcher = self.watcher
    if not watcher then
      return true
    end

    local ok, stop_error = pcall(function()
      watcher:UnHandleEvent(self.config.EVENTS.Shot)
    end)
    if not ok then
      log_error(self.config, "unregistering EVENTS.Shot failed: " .. tostring(stop_error))
      return nil, "unregistering EVENTS.Shot failed"
    end

    self.watcher = nil
    return true
  end

  return adapter
end

return M

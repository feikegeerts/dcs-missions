local M = {}

local AIRPLANE_CATEGORY = 0
local HELICOPTER_CATEGORY = 1

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
  local raw = call_method(config, unit, "GetDCSObject")
  if raw ~= nil then
    return raw, raw ~= unit
  end
  return unit, false
end

local function read_identity(config, unit)
  local raw, is_wrapper = raw_unit(config, unit)
  local id = first_method(config, raw, "getID", "GetID")
  if id == nil and raw ~= unit then
    id = first_method(config, unit, "GetID", "getID")
  end
  if type(id) ~= "number" and type(id) ~= "string" then
    id = nil
  end
  return raw, id, is_wrapper
end

local function read_group_name(config, unit)
  local name = non_empty_string(first_method(config, unit, "getGroupName", "GetGroupName"))
  if name then
    return name
  end
  local group = first_method(config, unit, "getGroup", "GetGroup")
  return non_empty_string(first_method(config, group, "getName", "GetName"))
end

local function read_observation(config, unit, group_name, event_data)
  local raw, identity_id, identity_is_wrapper = read_identity(config, unit)
  local event_group_name = non_empty_string(read_field(config, event_data, "IniGroupName"))
    or non_empty_string(read_field(config, event_data, "IniDCSGroupName"))
  local dcs_name = non_empty_string(read_field(config, event_data, "IniDCSUnitName"))
    or non_empty_string(read_field(config, event_data, "IniUnitName"))
    or non_empty_string(first_method(config, unit, "GetName", "getName"))
  if not dcs_name and raw ~= unit then
    dcs_name = non_empty_string(first_method(config, raw, "getName", "GetName"))
  end
  local dcs_type = non_empty_string(read_field(config, event_data, "IniTypeName"))
    or non_empty_string(first_method(config, unit, "GetTypeName", "getTypeName"))
  if not dcs_type and raw ~= unit then
    dcs_type = non_empty_string(first_method(config, raw, "getTypeName", "GetTypeName"))
  end
  local coalition = read_field(config, event_data, "IniCoalition")
  if coalition == nil then
    coalition = first_method(config, unit, "GetCoalition", "getCoalition")
  end
  if coalition == nil and raw ~= unit then
    coalition = first_method(config, raw, "getCoalition", "GetCoalition")
  end
  local category = read_field(config, event_data, "IniCategory")
  if category == nil then
    local descriptor = first_method(config, raw, "getDesc", "GetDesc")
    category = read_field(config, descriptor, "category")
  end
  -- Live 2026-09-05: entry and ordnance events can carry different
  -- representations of the same aircraft (recycled MOOSE wrapper in one
  -- field, fresh native object in another) while DCS reuses the runtime
  -- ID. Collect every representation so resolution hits whichever one a
  -- later event carries.
  local aliases = {}
  local seen_alias = {}
  if unit ~= nil then
    seen_alias[unit] = true
  end
  for _, field_name in ipairs({ "IniDCSUnit", "initiator", "IniUnit" }) do
    local candidate = read_field(config, event_data, field_name)
    if type(candidate) == "table" and not seen_alias[candidate] then
      seen_alias[candidate] = true
      local candidate_raw, candidate_is_wrapper = raw_unit(config, candidate)
      local candidate_id = first_method(config, candidate_raw, "getID", "GetID")
      if candidate_id == nil and candidate_raw ~= candidate then
        candidate_id = first_method(config, candidate, "GetID", "getID")
      end
      if type(candidate_id) ~= "number" and type(candidate_id) ~= "string" then
        candidate_id = nil
      end
      aliases[#aliases + 1] = {
        object = candidate,
        raw = candidate_raw,
        id = candidate_id,
        is_wrapper = candidate_is_wrapper,
      }
    end
  end
  return {
    unit = unit,
    raw = raw,
    identity_id = identity_id,
    identity_is_wrapper = identity_is_wrapper,
    aliases = aliases,
    group_name = group_name or event_group_name or read_group_name(config, raw),
    dcs_name = dcs_name,
    dcs_type = dcs_type,
    coalition = coalition,
    category = category,
    display_name = non_empty_string(read_field(config, event_data, "IniPlayerName")),
    participant_id = non_empty_string(read_field(config, event_data, "IniPlayerUCID")),
    callsign = non_empty_string(first_method(config, raw, "getCallsign", "GetCallsign")),
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

-- Live 2026-09-05: MOOSE recycles the unit wrapper per unit name and the
-- runtime IDs are reused across a death + rejoin, so object/id comparison
-- alone can mistake a recreated aircraft for the same incarnation (the
-- rejoin then emits no asset.spawned and later ordnance resolves unknown).
-- A dead previous incarnation is always a replacement, whatever the
-- recycled wrapper claims. Missing liveness methods mean "unknown", which
-- defaults to alive so long-lived mock-only paths keep their behavior.
local function instance_alive(config, instance)
  if instance == nil then
    return true
  end
  local candidates = {}
  if instance.observation then
    candidates[#candidates + 1] = instance.observation.unit
    candidates[#candidates + 1] = instance.observation.raw
  end
  candidates[#candidates + 1] = instance.unit_object
  candidates[#candidates + 1] = instance.identity_object
  for _, candidate in ipairs(candidates) do
    if candidate ~= nil then
      local alive = first_method(config, candidate, "IsAlive", "isExist")
      if alive == false then
        return false
      end
    end
  end
  return true
end

local function event_time(config, value)
  if is_finite_number(value) and value >= 0 then
    return value
  end
  return nil
end

local function usable_optional_event(value)
  return type(value) == "number" and value ~= -1
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
  if type(config.EVENTS) ~= "table" or config.EVENTS.PlayerEnterAircraft == nil then
    return nil, "asset requires EVENTS.PlayerEnterAircraft"
  end
  if config.EVENTS.Dead == nil or config.EVENTS.Crash == nil then
    return nil, "asset requires EVENTS.Dead and EVENTS.Crash for player incarnation retirement"
  end

  local player_roster, player_error = build_roster(config.player_group_names, "player")
  if not player_roster then
    return nil, player_error
  end
  local bandit_roster, bandit_error = build_roster(config.bandit_group_names, "bandit")
  if not bandit_roster then
    return nil, bandit_error
  end

  local retired_identity = {}
  local adapter = {
    config = config,
    player_roster = player_roster,
    bandit_roster = bandit_roster,
    generations = {},
    active_players = {},
    instances_by_object = {},
    identity_kind_by_object = {},
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
    instance.identity_id_keys = {}
    instance.identity_objects = {}
    local seen_id_key = {}
    local seen_object = {}
    local function map_object(object, kind)
      if object ~= nil then
        adapter.instances_by_object[object] = instance
        adapter.identity_kind_by_object[object] = kind
        if not seen_object[object] then
          seen_object[object] = true
          instance.identity_objects[#instance.identity_objects + 1] = object
        end
      end
    end
    local function map_id(id)
      local id_key = identity_map_key(id)
      if id_key then
        adapter.instances_by_id[id_key] = instance
        if not seen_id_key[id_key] then
          seen_id_key[id_key] = true
          instance.identity_id_keys[#instance.identity_id_keys + 1] = id_key
        end
      end
    end

    if observation.unit ~= nil then
      map_object(observation.unit, observation.identity_is_wrapper and "wrapper" or "native")
    end
    if observation.raw ~= nil then
      map_object(observation.raw, "native")
    end
    map_id(observation.identity_id)
    for _, alias in ipairs(observation.aliases or {}) do
      if alias.object ~= nil then
        map_object(alias.object, alias.is_wrapper and "wrapper" or "native")
      end
      -- A recycled MOOSE wrapper can still return the previous native DCS
      -- object. The wrapper itself follows the current name-based MOOSE
      -- lifetime, but that stale native object must remain a tombstone for
      -- its retired incarnation. Only trust an alias raw object when the
      -- alias is itself native or agrees with the primary native identity.
      if not alias.is_wrapper or alias.raw == observation.raw then
        if alias.raw ~= nil then
          map_object(alias.raw, "native")
        end
        map_id(alias.id)
      end
    end
  end

  local function remove_identity(instance)
    -- Keep object mappings as per-run tombstones. A late event carrying a
    -- retired native object must stop at that inactive incarnation instead
    -- of falling through to a runtime ID that DCS has reused for g2. MOOSE
    -- wrappers are deliberately remapped by add_identity when a later entry
    -- proves that the name-based wrapper now represents the new generation.
    for _, object in ipairs(instance.identity_objects or {}) do
      if adapter.instances_by_object[object] == instance then
        adapter.instances_by_object[object] = retired_identity
      end
    end
    for _, id_key in ipairs(instance.identity_id_keys or {}) do
      if adapter.instances_by_id[id_key] == instance then
        adapter.instances_by_id[id_key] = nil
      end
    end
  end

  local function evidence_matches(instance, evidence, require_time, require_snapshot)
    if type(evidence) ~= "table" then
      if require_time or require_snapshot then
        return false, "identity evidence is unavailable"
      end
      return true
    end

    local observed_time = event_time(config, evidence.sim_time)
    if require_time and (observed_time == nil or instance.spawn_sim_time == nil) then
      return false, "event time is unavailable"
    end
    if observed_time ~= nil and instance.spawn_sim_time ~= nil and observed_time < instance.spawn_sim_time then
      return false, "event predates the active incarnation"
    end

    local snapshot_matches = 0
    local function compare_snapshot(label, observed, expected)
      observed = non_empty_string(observed)
      expected = non_empty_string(expected)
      if observed == nil then
        return true
      end
      if expected == nil or observed ~= expected then
        return false, label .. " does not match the active incarnation"
      end
      snapshot_matches = snapshot_matches + 1
      return true
    end

    local matches, mismatch = compare_snapshot("unit name", evidence.dcs_name, instance.dcs_name)
    if not matches then
      return false, mismatch
    end
    matches, mismatch = compare_snapshot(
      "group name",
      evidence.group_name,
      instance.observation and instance.observation.group_name or nil
    )
    if not matches then
      return false, mismatch
    end
    matches, mismatch = compare_snapshot("unit type", evidence.dcs_type, instance.dcs_type)
    if not matches then
      return false, mismatch
    end

    if evidence.coalition ~= nil then
      local observed_coalition = map_coalition(evidence.coalition)
      if observed_coalition ~= "unknown" then
        if instance.coalition ~= observed_coalition then
          return false, "coalition does not match the active incarnation"
        end
        snapshot_matches = snapshot_matches + 1
      end
    end

    if require_snapshot and snapshot_matches == 0 then
      return false, "identity snapshot is unavailable"
    end
    return true
  end

  local function resolve_instance(unit, evidence)
    if unit == nil then
      return nil, "unit identity is unavailable"
    end
    local raw, id, unit_is_wrapper = read_identity(config, unit)
    local function active_object_instance(object)
      local instance = adapter.instances_by_object[object]
      if instance == retired_identity then
        return nil, "retired"
      end
      if instance == nil then
        return nil, "untracked"
      end
      if not instance.active then
        return nil, "retired"
      end
      return instance
    end

    local instance, object_status = active_object_instance(unit)
    if instance then
      local kind = adapter.identity_kind_by_object[unit]
      local matches, mismatch = evidence_matches(instance, evidence, kind == "wrapper", kind == "wrapper")
      if not matches then
        return nil, mismatch
      end
      return instance
    end
    if object_status == "retired" and not unit_is_wrapper then
      return nil, "unit identity belongs to a retired incarnation"
    end

    if raw ~= unit then
      instance, object_status = active_object_instance(raw)
      if instance then
        local matches, mismatch = evidence_matches(instance, evidence, false, false)
        if not matches then
          return nil, mismatch
        end
        return instance
      end
      -- A wrapper can retain its old native object after its name is reused.
      -- The wrapper is therefore allowed to continue to the guarded ID path;
      -- a native object tombstone itself is never bypassed.
      if object_status == "retired" and not unit_is_wrapper then
        return nil, "unit identity belongs to a retired incarnation"
      end
    end

    local id_key = identity_map_key(id)
    instance = (id_key and adapter.instances_by_id[id_key]) or nil
    if not instance or not instance.active then
      return nil, "runtime ID is not tracked"
    end
    local matches, mismatch = evidence_matches(instance, evidence, true, true)
    if not matches then
      return nil, mismatch
    end
    return instance
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
      aliases = observation.aliases or {},
      dcs_name = observation.dcs_name or observation.group_name,
      dcs_type = observation.dcs_type,
      coalition = map_coalition(observation.coalition),
      is_player = player_roster.lookup[configured_name] ~= nil,
      active = true,
      observation = observation,
    }
    local spawned, spawn_error = persist("asset.spawned", instance, observation, sim_time, {})
    if not spawned then
      return nil, spawn_error
    end
    adapter.generations[generation_key] = generation
    instance.spawn_sim_time = event_time(config, spawned.sim_time)
    add_identity(instance, observation)
    return instance, spawned
  end

  function adapter:observe_player_unit(unit, sim_time, known_group_name, event_data)
    local observation = read_observation(self.config, unit, known_group_name, event_data)
    local entry = observation.group_name and self.player_roster.lookup[observation.group_name]
    if not entry then
      return nil, "player aircraft is outside the tracked roster"
    end
    if
      observation.category ~= nil
      and observation.category ~= AIRPLANE_CATEGORY
      and observation.category ~= HELICOPTER_CATEGORY
    then
      return nil, "player unit is not an aircraft"
    end
    if
      self.config.player_coalition ~= nil
      and observation.coalition ~= nil
      and observation.coalition ~= self.config.player_coalition
    then
      return nil, "player aircraft coalition does not match the tracked roster"
    end

    local active = self.active_players[observation.group_name]
    if active and active.active and not instance_alive(self.config, active) then
      log_message(
        self.config,
        "warning",
        "previous " .. observation.group_name .. " incarnation no longer alive — advancing generation"
      )
      active.active = false
      remove_identity(active)
      active = nil
    end
    if active and active.active and same_identity(active, observation) then
      return reference(active), false, active
    end
    if active and active.active and not confirms_replacement(active, observation) then
      log_message(self.config, "warning", "player aircraft replacement identity is unavailable")
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

  function adapter:extend_player_roster(names)
    if type(names) ~= "table" or #names == 0 then
      return nil, "player group names are required"
    end

    local additions = {}
    local addition_tokens = {}
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
      local key_part = token_part(name)
      if
        not key_part
        or self.player_roster.token_lookup[key_part]
        or self.bandit_roster.token_lookup[key_part]
        or addition_tokens[key_part]
      then
        return nil, name .. " does not produce a distinct asset key token"
      end
      additions[name] = key_part
      addition_tokens[key_part] = true
    end

    for _, name in ipairs(names) do
      local index = #self.player_roster.names + 1
      local key_part = additions[name]
      self.player_roster.names[index] = name
      self.player_roster.lookup[name] = { index = index, key_part = key_part }
      self.player_roster.token_lookup[key_part] = true
    end
    return true
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

  function adapter:resolve_unit(unit, evidence)
    local instance, resolution_error = resolve_instance(unit, evidence)
    if not instance then
      if resolution_error and string.find(resolution_error, "runtime ID", 1, true) == nil then
        log_message(self.config, "warning", "unit resolution rejected: " .. resolution_error)
      end
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

  function adapter:OnEventPlayerEnterAircraft(event_data)
    if type(event_data) ~= "table" then
      return nil, "player lifecycle event data is unavailable"
    end
    local unit = read_field(self.config, event_data, "IniDCSUnit")
      or read_field(self.config, event_data, "initiator")
      or read_field(self.config, event_data, "IniUnit")
    local group_name = non_empty_string(read_field(self.config, event_data, "IniGroupName"))
      or non_empty_string(read_field(self.config, event_data, "IniDCSGroupName"))
    return self:observe_player_unit(unit, read_field(self.config, event_data, "time"), group_name, event_data)
  end

  -- Live 2026-09-05: neither the recycled MOOSE wrapper nor the reused
  -- runtime IDs distinguish a recreated player aircraft from the same
  -- incarnation, so entry-time comparison alone keeps a stale g1 and later
  -- ordnance resolves unknown. In the validated rejoin path, Dead/Crash is
  -- the reliable signal, so the tracked incarnation retires here and the
  -- next entry opens g2. Runtime IDs and MOOSE wrappers can be reused, so group name
  -- alone is not sufficient: the death event must resolve to the active
  -- incarnation with its event-time and identity snapshots.
  -- No asset.despawned is emitted: death is not scripted cleanup, and the
  -- web sortie derivation pairs control periods from participant events.
  local function event_unit(event_data)
    return read_field(config, event_data, "IniDCSUnit")
      or read_field(config, event_data, "initiator")
      or read_field(config, event_data, "IniUnit")
  end

  local function event_group_name(event_data)
    return non_empty_string(read_field(config, event_data, "IniGroupName"))
      or non_empty_string(read_field(config, event_data, "IniDCSGroupName"))
  end

  local function resolve_event_instance(event_data, warning_label)
    if type(event_data) ~= "table" then
      return nil, "player lifecycle event data is unavailable"
    end
    local group_name = event_group_name(event_data)
    local active = group_name and adapter.active_players[group_name] or nil
    local unit = event_unit(event_data)
    if unit == nil then
      if active and active.active then
        log_message(
          config,
          "warning",
          warning_label .. " identity unavailable for " .. group_name .. "; active incarnation retained"
        )
      end
      return nil
    end
    local observation = read_observation(config, unit, group_name, event_data)
    local resolved, resolution_error = resolve_instance(unit, {
      sim_time = read_field(config, event_data, "time"),
      group_name = observation.group_name,
      dcs_name = observation.dcs_name,
      dcs_type = observation.dcs_type,
      coalition = observation.coalition,
    })
    if not resolved then
      if active and active.active then
        log_message(
          config,
          "warning",
          warning_label
            .. " identity rejected for "
            .. group_name
            .. "; active incarnation retained ("
            .. tostring(resolution_error)
            .. ")"
        )
      end
      return nil
    end
    if active and resolved ~= active then
      log_message(
        config,
        "warning",
        warning_label
          .. " identity rejected for "
          .. group_name
          .. "; active incarnation retained ("
          .. "different incarnation"
          .. ")"
      )
      return nil
    end
    return resolved, observation
  end

  local function capture_aircraft_loss(event_data, event_type, reason)
    local instance, observation = resolve_event_instance(event_data, "death")
    if not instance then
      return false
    end
    persist(event_type, instance, observation, read_field(config, event_data, "time"), {})
    instance.active = false
    remove_identity(instance)
    log_message(config, "info", "retired " .. instance.asset_key .. " (" .. reason .. ")")
    return true
  end

  local function capture_pilot_outcome(event_data, event_type)
    local instance, observation = resolve_event_instance(event_data, "pilot outcome")
    if not instance or not instance.is_player then
      return false
    end
    local event = persist(event_type, instance, observation, read_field(config, event_data, "time"), {})
    return event ~= nil
  end

  function adapter:OnEventDead(event_data)
    return capture_aircraft_loss(event_data, "asset.dead", "dead")
  end

  function adapter:OnEventCrash(event_data)
    return capture_aircraft_loss(event_data, "asset.crashed", "crashed")
  end

  function adapter:OnEventUnitLost(event_data)
    return capture_aircraft_loss(event_data, "asset.dead", "unit-lost")
  end

  function adapter:OnEventPilotDead(event_data)
    return capture_pilot_outcome(event_data, "pilot.dead")
  end

  function adapter:OnEventEjection(event_data)
    return capture_pilot_outcome(event_data, "pilot.ejected")
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
    function watcher:OnEventPlayerEnterAircraft(event_data)
      return adapter:OnEventPlayerEnterAircraft(event_data)
    end
    function watcher:OnEventDead(event_data)
      return adapter:OnEventDead(event_data)
    end
    function watcher:OnEventCrash(event_data)
      return adapter:OnEventCrash(event_data)
    end
    function watcher:OnEventUnitLost(event_data)
      return adapter:OnEventUnitLost(event_data)
    end
    function watcher:OnEventPilotDead(event_data)
      return adapter:OnEventPilotDead(event_data)
    end
    function watcher:OnEventEjection(event_data)
      return adapter:OnEventEjection(event_data)
    end
    local handled, handle_error = pcall(function()
      watcher:HandleEvent(self.config.EVENTS.PlayerEnterAircraft)
      watcher:HandleEvent(self.config.EVENTS.Dead)
      watcher:HandleEvent(self.config.EVENTS.Crash)
      if usable_optional_event(self.config.EVENTS.UnitLost) then
        watcher:HandleEvent(self.config.EVENTS.UnitLost)
      end
      if usable_optional_event(self.config.EVENTS.PilotDead) then
        watcher:HandleEvent(self.config.EVENTS.PilotDead)
      end
      if usable_optional_event(self.config.EVENTS.Ejection) then
        watcher:HandleEvent(self.config.EVENTS.Ejection)
      end
    end)
    if not handled then
      log_error(self.config, "registering player lifecycle events failed: " .. tostring(handle_error))
      return nil, "registering player lifecycle events failed"
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
      watcher:UnHandleEvent(self.config.EVENTS.PlayerEnterAircraft)
      watcher:UnHandleEvent(self.config.EVENTS.Dead)
      watcher:UnHandleEvent(self.config.EVENTS.Crash)
      if usable_optional_event(self.config.EVENTS.UnitLost) then
        watcher:UnHandleEvent(self.config.EVENTS.UnitLost)
      end
      if usable_optional_event(self.config.EVENTS.PilotDead) then
        watcher:UnHandleEvent(self.config.EVENTS.PilotDead)
      end
      if usable_optional_event(self.config.EVENTS.Ejection) then
        watcher:UnHandleEvent(self.config.EVENTS.Ejection)
      end
    end)
    if not ok then
      log_error(self.config, "unregistering player lifecycle events failed: " .. tostring(stop_error))
      return nil, "unregistering player lifecycle events failed"
    end
    return true
  end

  return adapter
end

return M

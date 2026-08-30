local M = {}

local JSON_NULL = {}
local SCHEMA_VERSION = 1
local SOURCE = "moose-mission"
local MAX_SEQUENCE = 9007199254740991

local EVENT_TYPES = {
  ["mission.started"] = true,
  ["mission.ended"] = true,
  ["mission.heartbeat"] = true,
  ["participant.entered"] = true,
  ["participant.left"] = true,
  ["asset.spawned"] = true,
  ["asset.despawned"] = true,
  ["ordnance.fired"] = true,
  ["asset.hit"] = true,
  ["asset.kill-reported"] = true,
  ["asset.dead"] = true,
  ["asset.crashed"] = true,
  ["pilot.dead"] = true,
  ["pilot.ejected"] = true,
}

local KNOWN_WEAPON_CATEGORIES = {
  missile = true,
  bomb = true,
  rocket = true,
  ["other-discrete"] = true,
  unknown = true,
}

local ACTOR_REASONS = {
  ["not-reported"] = true,
  unresolved = true,
}

local PARTICIPANT_REASONS = {
  ["stable-identity-unavailable"] = true,
  unresolved = true,
}

local ASSET_REASONS = {
  ["instance-identity-unavailable"] = true,
  unresolved = true,
}

local WEAPON_REASONS = {
  ["type-not-reported"] = true,
  unresolved = true,
}

local LOCATION_REASONS = {
  ["not-reported"] = true,
  unavailable = true,
}

M.JSON_NULL = JSON_NULL
M.null = JSON_NULL
M.SCHEMA_VERSION = SCHEMA_VERSION
M.SOURCE = SOURCE
M.EVENT_TYPES = EVENT_TYPES

local function is_null(value)
  return value == nil or value == JSON_NULL
end

local function is_finite_number(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function is_finite_integer(value)
  return is_finite_number(value) and math.floor(value) == value
end

local MAX_WALL_TIME_LENGTH = 128
local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function read_digits(value, start, count)
  local number = 0
  for index = start, start + count - 1 do
    local byte = string.byte(value, index)
    if not byte or byte < 48 or byte > 57 then
      return nil
    end
    number = number * 10 + byte - 48
  end
  return number
end

local function is_leap_year(year)
  return year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0)
end

local function is_wall_time(value)
  if type(value) ~= "string" then
    return false
  end

  local length = string.len(value)
  if length < 20 or length > MAX_WALL_TIME_LENGTH then
    return false
  end

  if
    string.sub(value, 5, 5) ~= "-"
    or string.sub(value, 8, 8) ~= "-"
    or (string.sub(value, 11, 11) ~= "T" and string.sub(value, 11, 11) ~= "t")
    or string.sub(value, 14, 14) ~= ":"
    or string.sub(value, 17, 17) ~= ":"
  then
    return false
  end

  local year = read_digits(value, 1, 4)
  local month = read_digits(value, 6, 2)
  local day = read_digits(value, 9, 2)
  local hour = read_digits(value, 12, 2)
  local minute = read_digits(value, 15, 2)
  local second = read_digits(value, 18, 2)
  if not year or not month or not day or not hour or not minute or not second then
    return false
  end

  local month_days = DAYS_IN_MONTH[month]
  if not month_days then
    return false
  end
  if month == 2 and is_leap_year(year) then
    month_days = 29
  end
  if day < 1 or day > month_days or hour > 23 or minute > 59 or second > 60 then
    return false
  end
  if second == 60 and (hour ~= 23 or minute ~= 59) then
    return false
  end

  local zone_start = 20
  if string.sub(value, zone_start, zone_start) == "." then
    zone_start = zone_start + 1
    local fraction_start = zone_start
    while zone_start <= length do
      local byte = string.byte(value, zone_start)
      if not byte or byte < 48 or byte > 57 then
        break
      end
      zone_start = zone_start + 1
    end
    if zone_start == fraction_start then
      return false
    end
  end

  local zone = string.sub(value, zone_start, zone_start)
  if zone == "Z" or zone == "z" then
    return zone_start == length
  end
  if zone ~= "+" and zone ~= "-" then
    return false
  end
  if length - zone_start + 1 ~= 6 or string.sub(value, zone_start + 3, zone_start + 3) ~= ":" then
    return false
  end

  local offset_hour = read_digits(value, zone_start + 1, 2)
  local offset_minute = read_digits(value, zone_start + 4, 2)
  return offset_hour ~= nil and offset_minute ~= nil and offset_hour <= 23 and offset_minute <= 59
end

local function validate_basic_token(value, field_name)
  if type(value) ~= "string" then
    return nil, field_name .. " must be a string"
  end

  local length = string.len(value)
  if length < 1 or length > 128 then
    return nil, field_name .. " must contain 1-128 ASCII token characters"
  end

  local first = string.byte(value, 1)
  local first_is_alphanumeric = (first >= string.byte("A") and first <= string.byte("Z"))
    or (first >= string.byte("a") and first <= string.byte("z"))
    or (first >= string.byte("0") and first <= string.byte("9"))
  if not first_is_alphanumeric then
    return nil, field_name .. " must start with an ASCII letter or digit"
  end

  for index = 2, length do
    local byte = string.byte(value, index)
    local valid = (byte >= string.byte("A") and byte <= string.byte("Z"))
      or (byte >= string.byte("a") and byte <= string.byte("z"))
      or (byte >= string.byte("0") and byte <= string.byte("9"))
      or byte == string.byte(".")
      or byte == string.byte("_")
      or byte == string.byte("-")
    if not valid then
      return nil, field_name .. " contains an invalid character"
    end
  end

  return true
end

local function validate_source_version(value)
  if type(value) ~= "string" then
    return nil, "source_version must be a string"
  end

  local length = string.len(value)
  if length < 1 or length > 128 then
    return nil, "source_version must contain 1-128 characters"
  end

  return true
end

local function validate_nullable_string(value, field_name, maximum_length)
  if is_null(value) then
    return JSON_NULL
  end

  if type(value) ~= "string" then
    return nil, field_name .. " must be a string or null"
  end

  local length = string.len(value)
  if length < 1 or length > maximum_length then
    return nil, field_name .. " must contain 1-" .. maximum_length .. " characters or be null"
  end

  return value
end

local function validate_nullable_token(value, field_name, token_validator)
  if is_null(value) then
    return JSON_NULL
  end

  if token_validator then
    local valid, validation_error = token_validator(value, field_name)
    if not valid then
      return nil, validation_error
    end
  else
    local valid, validation_error = validate_basic_token(value, field_name)
    if not valid then
      return nil, validation_error
    end
  end

  return value
end

local function input_value(input, primary, secondary, tertiary)
  local value = input[primary]
  if value ~= nil then
    return value
  end

  if secondary then
    value = input[secondary]
    if value ~= nil then
      return value
    end
  end

  if tertiary then
    value = input[tertiary]
    if value ~= nil then
      return value
    end
  end

  return nil
end

local function normalize_snapshot_string(input, field_name, alias, second_alias)
  return validate_nullable_string(input_value(input, field_name, alias, second_alias), field_name, 256)
end

local function normalize_reason(input, reasons, default_reason, field_name)
  local reason = input.reason
  if is_null(reason) then
    return default_reason
  end

  if type(reason) ~= "string" or not reasons[reason] then
    return nil, field_name .. " has an invalid reason"
  end

  return reason
end

local function map_coalition(value, nullable)
  if is_null(value) then
    if nullable then
      return JSON_NULL
    end
    return "unknown"
  end

  if value == 0 then
    return "neutral"
  elseif value == 1 then
    return "red"
  elseif value == 2 then
    return "blue"
  elseif
    type(value) == "string" and (value == "blue" or value == "red" or value == "neutral" or value == "unknown")
  then
    return value
  end

  return "unknown"
end

M.map_coalition = function(value)
  return map_coalition(value, true)
end

local function normalize_actor(input, token_validator)
  if is_null(input) then
    return JSON_NULL
  end
  if type(input) ~= "table" then
    return nil, "initiator/target must be a reference table or null"
  end

  local status = input.status
  if status == JSON_NULL then
    status = nil
  elseif status ~= nil and status ~= "known" and status ~= "unknown" then
    return nil, "actor status must be known or unknown"
  end

  local participant_id, validation_error =
    validate_nullable_token(input.participant_id, "participant_id", token_validator)
  if not participant_id then
    return nil, validation_error
  end

  local asset_key
  asset_key, validation_error = validate_nullable_token(input.asset_key, "asset_key", token_validator)
  if not asset_key then
    return nil, validation_error
  end

  local display_name
  display_name, validation_error = normalize_snapshot_string(input, "display_name", "player_name", "name")
  if not display_name then
    return nil, validation_error
  end

  local callsign
  callsign, validation_error = normalize_snapshot_string(input, "callsign")
  if not callsign then
    return nil, validation_error
  end

  local dcs_name
  dcs_name, validation_error = normalize_snapshot_string(input, "dcs_name")
  if not dcs_name then
    return nil, validation_error
  end

  local dcs_type
  dcs_type, validation_error = normalize_snapshot_string(input, "dcs_type")
  if not dcs_type then
    return nil, validation_error
  end

  if status == "unknown" or input.kind == "unknown" then
    local reason
    reason, validation_error = normalize_reason(input, ACTOR_REASONS, "unresolved", "actor")
    if not reason then
      return nil, validation_error
    end

    return {
      status = "unknown",
      kind = "unknown",
      reason = reason,
      participant_id = JSON_NULL,
      asset_key = JSON_NULL,
      display_name = display_name,
      callsign = callsign,
      dcs_name = dcs_name,
      dcs_type = dcs_type,
      coalition = map_coalition(input.coalition, false),
    }
  end

  local kind = input.kind
  if kind == JSON_NULL then
    kind = nil
  end
  if kind == nil then
    if not is_null(participant_id) then
      kind = "participant"
    elseif not is_null(asset_key) or not is_null(dcs_name) or not is_null(dcs_type) then
      kind = "aircraft"
    end
  end

  if kind ~= "participant" and kind ~= "aircraft" then
    if status == "known" then
      return nil, "known actor must have kind participant or aircraft"
    end

    return {
      status = "unknown",
      kind = "unknown",
      reason = "unresolved",
      participant_id = JSON_NULL,
      asset_key = JSON_NULL,
      display_name = display_name,
      callsign = callsign,
      dcs_name = dcs_name,
      dcs_type = dcs_type,
      coalition = map_coalition(input.coalition, false),
    }
  end

  if kind == "participant" and is_null(participant_id) then
    if status == "known" then
      return nil, "known participant actor requires participant_id"
    end

    return {
      status = "unknown",
      kind = "unknown",
      reason = "unresolved",
      participant_id = JSON_NULL,
      asset_key = JSON_NULL,
      display_name = display_name,
      callsign = callsign,
      dcs_name = dcs_name,
      dcs_type = dcs_type,
      coalition = map_coalition(input.coalition, false),
    }
  end

  if kind == "aircraft" and is_null(asset_key) and is_null(dcs_name) and is_null(dcs_type) then
    if status == "known" then
      return nil, "known aircraft actor requires asset_key, dcs_name, or dcs_type"
    end

    return {
      status = "unknown",
      kind = "unknown",
      reason = "unresolved",
      participant_id = JSON_NULL,
      asset_key = JSON_NULL,
      display_name = display_name,
      callsign = callsign,
      dcs_name = dcs_name,
      dcs_type = dcs_type,
      coalition = map_coalition(input.coalition, false),
    }
  end

  return {
    status = "known",
    kind = kind,
    participant_id = participant_id,
    asset_key = asset_key,
    display_name = display_name,
    callsign = callsign,
    dcs_name = dcs_name,
    dcs_type = dcs_type,
    coalition = map_coalition(input.coalition, false),
  }
end

local function normalize_participant(input, token_validator)
  if is_null(input) then
    return JSON_NULL
  end
  if type(input) ~= "table" then
    return nil, "participant must be a reference table or null"
  end

  local status = input.status
  if status == JSON_NULL then
    status = nil
  elseif status ~= nil and status ~= "known" and status ~= "unknown" then
    return nil, "participant status must be known or unknown"
  end

  local participant_id
  local validation_error

  local display_name
  display_name, validation_error = normalize_snapshot_string(input, "display_name", "player_name", "name")
  if not display_name then
    return nil, validation_error
  end

  local callsign
  callsign, validation_error = normalize_snapshot_string(input, "callsign")
  if not callsign then
    return nil, validation_error
  end

  if status == "unknown" then
    local reason
    reason, validation_error =
      normalize_reason(input, PARTICIPANT_REASONS, "stable-identity-unavailable", "participant")
    if not reason then
      return nil, validation_error
    end

    return {
      status = "unknown",
      kind = "participant",
      reason = reason,
      participant_id = JSON_NULL,
      display_name = display_name,
      callsign = callsign,
      coalition = map_coalition(input.coalition, false),
    }
  end

  participant_id, validation_error = validate_nullable_token(input.participant_id, "participant_id", token_validator)
  if not participant_id then
    return nil, validation_error
  end

  if is_null(participant_id) then
    if status == "known" then
      return nil, "known participant requires participant_id"
    end

    local reason
    reason, validation_error =
      normalize_reason(input, PARTICIPANT_REASONS, "stable-identity-unavailable", "participant")
    if not reason then
      return nil, validation_error
    end

    return {
      status = "unknown",
      kind = "participant",
      reason = reason,
      participant_id = JSON_NULL,
      display_name = display_name,
      callsign = callsign,
      coalition = map_coalition(input.coalition, false),
    }
  end

  if status == "known" or not is_null(participant_id) then
    return {
      status = "known",
      kind = "participant",
      participant_id = participant_id,
      display_name = display_name,
      callsign = callsign,
      coalition = map_coalition(input.coalition, false),
    }
  end

  return nil, "participant could not be normalized"
end

local function normalize_asset(input, token_validator)
  if is_null(input) then
    return JSON_NULL
  end
  if type(input) ~= "table" then
    return nil, "asset must be a reference table or null"
  end

  local status = input.status
  if status == JSON_NULL then
    status = nil
  elseif status ~= nil and status ~= "known" and status ~= "unknown" then
    return nil, "asset status must be known or unknown"
  end

  if input.kind ~= nil and input.kind ~= JSON_NULL and input.kind ~= "aircraft" then
    return nil, "asset kind must be aircraft"
  end

  local asset_key, validation_error = validate_nullable_token(input.asset_key, "asset_key", token_validator)
  if not asset_key then
    return nil, validation_error
  end

  local dcs_name
  dcs_name, validation_error = normalize_snapshot_string(input, "dcs_name")
  if not dcs_name then
    return nil, validation_error
  end

  local dcs_type
  dcs_type, validation_error = normalize_snapshot_string(input, "dcs_type")
  if not dcs_type then
    return nil, validation_error
  end

  if status == "unknown" then
    local reason
    reason, validation_error = normalize_reason(input, ASSET_REASONS, "unresolved", "asset")
    if not reason then
      return nil, validation_error
    end

    return {
      status = "unknown",
      kind = "aircraft",
      reason = reason,
      asset_key = JSON_NULL,
      dcs_name = dcs_name,
      dcs_type = dcs_type,
      coalition = map_coalition(input.coalition, false),
    }
  end

  if is_null(asset_key) then
    if status == "known" then
      return nil, "known asset requires asset_key"
    end

    return {
      status = "unknown",
      kind = "aircraft",
      reason = "instance-identity-unavailable",
      asset_key = JSON_NULL,
      dcs_name = dcs_name,
      dcs_type = dcs_type,
      coalition = map_coalition(input.coalition, false),
    }
  end

  return {
    status = "known",
    kind = "aircraft",
    asset_key = asset_key,
    dcs_name = dcs_name,
    dcs_type = dcs_type,
    coalition = map_coalition(input.coalition, false),
  }
end

local function normalize_weapon(input)
  if is_null(input) then
    return JSON_NULL
  end
  if type(input) ~= "table" then
    return nil, "weapon must be a reference table or null"
  end

  local status = input.status
  if status == JSON_NULL then
    status = nil
  elseif status ~= nil and status ~= "known" and status ~= "unknown" then
    return nil, "weapon status must be known or unknown"
  end

  local display_name, validation_error = normalize_snapshot_string(input, "display_name", "name")
  if not display_name then
    return nil, validation_error
  end

  if status == "unknown" then
    local reason
    reason, validation_error = normalize_reason(input, WEAPON_REASONS, "unresolved", "weapon")
    if not reason then
      return nil, validation_error
    end

    return {
      status = "unknown",
      reason = reason,
      dcs_type = JSON_NULL,
      display_name = display_name,
      category = "unknown",
    }
  end

  local dcs_type = input.dcs_type
  if is_null(dcs_type) then
    if status == "known" then
      return nil, "known weapon requires dcs_type"
    end

    return {
      status = "unknown",
      reason = "type-not-reported",
      dcs_type = JSON_NULL,
      display_name = display_name,
      category = "unknown",
    }
  end
  if type(dcs_type) ~= "string" or string.len(dcs_type) < 1 or string.len(dcs_type) > 256 then
    return nil, "weapon dcs_type must contain 1-256 characters"
  end

  local category = input.category
  if is_null(category) then
    category = "unknown"
  elseif type(category) ~= "string" or not KNOWN_WEAPON_CATEGORIES[category] then
    category = "unknown"
  end

  return {
    status = "known",
    dcs_type = dcs_type,
    display_name = display_name,
    category = category,
  }
end

local function normalize_location(input)
  if is_null(input) then
    return JSON_NULL
  end
  if type(input) ~= "table" then
    return nil, "location must be a reference table or null"
  end

  local status = input.status
  if status == JSON_NULL then
    status = nil
  elseif status ~= nil and status ~= "known" and status ~= "unknown" then
    return nil, "location status must be known or unknown"
  end

  if status == "unknown" then
    local reason, validation_error = normalize_reason(input, LOCATION_REASONS, "unavailable", "location")
    if not reason then
      return nil, validation_error
    end

    return {
      status = "unknown",
      reason = reason,
    }
  end

  local coordinate_system = input.coordinate_system
  if is_null(coordinate_system) then
    coordinate_system = "dcs-local"
  elseif coordinate_system ~= "dcs-local" then
    if status == "known" then
      return nil, "location coordinate_system must be dcs-local"
    end
    return {
      status = "unknown",
      reason = "unavailable",
    }
  end

  local x = input.x
  local y = input.y
  local z = input.z
  if is_finite_number(x) and is_finite_number(y) and is_finite_number(z) then
    return {
      status = "known",
      coordinate_system = coordinate_system,
      x = x,
      y = y,
      z = z,
    }
  end

  if status == "known" then
    return nil, "known location requires numeric x, y, and z"
  end

  return {
    status = "unknown",
    reason = "unavailable",
  }
end

local function classify_payload_table(value, is_root)
  local kind
  local count = 0
  local maximum_index = 0

  for key in pairs(value) do
    local key_type = type(key)
    if is_root and key_type ~= "string" then
      return nil, "payload object keys must be strings"
    elseif key_type == "string" then
      if kind == "array" then
        return nil, "payload object and array keys must not be mixed"
      end
      kind = "object"
    elseif key_type == "number" then
      if not is_finite_integer(key) or key < 1 then
        return nil, "payload arrays require contiguous positive integer keys"
      end
      if kind == "object" then
        return nil, "payload object and array keys must not be mixed"
      end
      kind = "array"
      count = count + 1
      if key > maximum_index then
        maximum_index = key
      end
    else
      return nil, "payload keys must be strings or array indices"
    end
  end

  if kind == "array" and count ~= maximum_index then
    return nil, "payload arrays must use contiguous indices starting at 1"
  end

  return kind or "object"
end

local function copy_value(value, active_tables, is_root)
  if value == JSON_NULL then
    return JSON_NULL
  end

  local value_type = type(value)
  if value_type == "nil" or value_type == "string" or value_type == "boolean" then
    return value
  end
  if value_type == "number" then
    if not is_finite_number(value) then
      return nil, "payload contains a non-finite number"
    end
    return value
  end
  if value_type ~= "table" then
    return nil, "payload contains a value that is not JSON-compatible"
  end

  active_tables = active_tables or {}
  if active_tables[value] then
    return nil, "payload must not contain cyclic tables"
  end

  local table_kind, key_error = classify_payload_table(value, is_root)
  if not table_kind then
    return nil, key_error
  end

  local copy = {}
  active_tables[value] = true
  for key, item in pairs(value) do
    local copied_item, item_error = copy_value(item, active_tables, false)
    if copied_item == nil and item_error then
      active_tables[value] = nil
      return nil, item_error
    end

    copy[key] = copied_item
  end
  active_tables[value] = nil

  return copy
end

local function normalize_payload(input, event_type)
  local payload = input.payload
  if payload == nil then
    payload = {}
  elseif payload == JSON_NULL or type(payload) ~= "table" then
    return nil, "payload must be a table"
  else
    local copied_payload, copy_error = copy_value(payload, nil, true)
    if not copied_payload then
      return nil, copy_error
    end
    payload = copied_payload
  end

  if event_type == "mission.started" then
    local mission_name = payload.mission_name
    if type(mission_name) ~= "string" or string.len(mission_name) < 1 then
      return nil, "mission.started payload requires mission_name"
    end

    local mission_version = payload.mission_version
    if type(mission_version) ~= "string" or string.len(mission_version) < 1 then
      return nil, "mission.started payload requires mission_version"
    end

    local map_name = payload.map_name
    if is_null(map_name) then
      payload.map_name = JSON_NULL
    elseif type(map_name) ~= "string" or string.len(map_name) < 1 then
      return nil, "mission.started payload map_name must be a non-empty string or null"
    end

    if payload.run_classification ~= "test" and payload.run_classification ~= "historical" then
      return nil, "mission.started payload requires run_classification test or historical"
    end
  elseif event_type == "mission.ended" then
    if payload.reason ~= "mission-end-observed" then
      return nil, "mission.ended payload requires reason mission-end-observed"
    end
  elseif event_type == "asset.despawned" then
    if payload.reason ~= "intentional" and payload.reason ~= "unknown" then
      return nil, "asset.despawned payload requires reason intentional or unknown"
    end
  end

  return payload
end

local function require_reference(value, event_type, field_name)
  if value == JSON_NULL then
    return nil, event_type .. " requires " .. field_name
  end
  return true
end

local function require_null(value, event_type, field_name)
  if value ~= JSON_NULL then
    return nil, event_type .. " does not allow " .. field_name
  end
  return true
end

local function validate_event_roles(event_type, fields)
  if event_type == "mission.started" or event_type == "mission.ended" or event_type == "mission.heartbeat" then
    for _, field_name in ipairs({ "initiator", "target", "participant", "asset", "weapon", "coalition", "location" }) do
      local valid, validation_error = require_null(fields[field_name], event_type, field_name)
      if not valid then
        return nil, validation_error
      end
    end
  elseif event_type == "participant.entered" or event_type == "participant.left" then
    for _, field_name in ipairs({ "participant", "asset", "coalition", "location" }) do
      local valid, validation_error = require_reference(fields[field_name], event_type, field_name)
      if not valid then
        return nil, validation_error
      end
    end
    for _, field_name in ipairs({ "initiator", "target", "weapon" }) do
      local valid, validation_error = require_null(fields[field_name], event_type, field_name)
      if not valid then
        return nil, validation_error
      end
    end
  elseif event_type == "asset.spawned" or event_type == "asset.despawned" then
    for _, field_name in ipairs({ "asset", "coalition", "location" }) do
      local valid, validation_error = require_reference(fields[field_name], event_type, field_name)
      if not valid then
        return nil, validation_error
      end
    end
    for _, field_name in ipairs({ "initiator", "target", "weapon" }) do
      local valid, validation_error = require_null(fields[field_name], event_type, field_name)
      if not valid then
        return nil, validation_error
      end
    end
  elseif event_type == "ordnance.fired" then
    for _, field_name in ipairs({ "initiator", "asset", "weapon", "coalition", "location" }) do
      local valid, validation_error = require_reference(fields[field_name], event_type, field_name)
      if not valid then
        return nil, validation_error
      end
    end
    local valid, validation_error = require_null(fields.target, event_type, "target")
    if not valid then
      return nil, validation_error
    end
  elseif event_type == "asset.hit" or event_type == "asset.kill-reported" then
    for _, field_name in ipairs({ "initiator", "target", "asset", "coalition", "location" }) do
      local valid, validation_error = require_reference(fields[field_name], event_type, field_name)
      if not valid then
        return nil, validation_error
      end
    end
  elseif
    event_type == "asset.dead"
    or event_type == "asset.crashed"
    or event_type == "pilot.dead"
    or event_type == "pilot.ejected"
  then
    for _, field_name in ipairs({ "asset", "coalition", "location" }) do
      local valid, validation_error = require_reference(fields[field_name], event_type, field_name)
      if not valid then
        return nil, validation_error
      end
    end
    for _, field_name in ipairs({ "initiator", "target", "weapon" }) do
      local valid, validation_error = require_null(fields[field_name], event_type, field_name)
      if not valid then
        return nil, validation_error
      end
    end
  end

  return true
end

local function shallow_copy(input)
  local copy = {}
  for key, value in pairs(input) do
    copy[key] = value
  end
  return copy
end

local function make_factory_options(first, second)
  if second == nil then
    return first
  end

  if type(second) ~= "table" then
    return nil, "producer configuration must be a table"
  end

  local options = shallow_copy(second)
  if options.event_id == nil and options.event_id_module == nil and options.allocator == nil then
    options.event_id = first
  end
  return options
end

local function get_allocator(dependency, config, producer_id, run_key)
  local token_validator
  local identity_builder
  local sequence_validator
  local allocator

  if type(config.allocator) == "table" or type(config.allocator) == "function" then
    allocator = config.allocator
  elseif
    type(dependency) == "table"
    and type(dependency.allocate) ~= "function"
    and type(dependency.next) ~= "function"
  then
    local constructor = dependency.new_allocator or dependency.new
    if type(constructor) ~= "function" then
      return nil, "event_id dependency must be an allocator or module with new"
    end

    local ok, created_allocator, creation_error = pcall(constructor, {
      producer_id = producer_id,
      run_key = run_key,
    })
    if not ok then
      return nil, "event_id module failed while creating allocator: " .. tostring(created_allocator)
    end
    if not created_allocator then
      return nil, creation_error or "event_id module did not create an allocator"
    end
    allocator = created_allocator
  else
    allocator = dependency
  end

  if type(allocator) ~= "table" and type(allocator) ~= "function" then
    return nil, "event_id dependency did not provide an allocator"
  end

  if type(dependency) == "table" then
    token_validator = dependency.validate_token
    identity_builder = dependency.build_event_id
    sequence_validator = dependency.validate_sequence
  end
  if type(config.token_validator) == "function" then
    token_validator = config.token_validator
  end

  if type(allocator) == "table" and type(allocator.allocate) ~= "function" and type(allocator.next) ~= "function" then
    return nil, "event_id allocator must expose allocate or next"
  end

  return allocator, token_validator, identity_builder, sequence_validator
end

local function allocate(allocator, event_type)
  local method
  local receiver
  if type(allocator) == "function" then
    method = allocator
  elseif type(allocator.allocate) == "function" then
    method = allocator.allocate
    receiver = allocator
  else
    method = allocator.next
    receiver = allocator
  end

  local ok, sequence, event_id
  if receiver then
    ok, sequence, event_id = pcall(method, receiver, event_type)
  else
    ok, sequence, event_id = pcall(method, event_type)
  end
  if not ok then
    return nil, "event_id allocator failed: " .. tostring(sequence)
  end
  if not sequence then
    return nil, event_id or "event_id allocator rejected the event"
  end
  if not event_id then
    return nil, "event_id allocator must return sequence and event_id"
  end

  return sequence, event_id
end

function M.new(first, second)
  local config, configuration_error = make_factory_options(first, second)
  if not config then
    return nil, configuration_error
  end
  if type(config) ~= "table" then
    return nil, "producer configuration must be a table"
  end

  local producer_id = config.producer_id
  local run_key = config.run_key
  local source_version = config.source_version
  local dependency = config.event_id or config.event_id_module

  if not dependency and not config.allocator then
    return nil, "producer requires an injected event_id module or allocator"
  end

  local allocator, token_validator, identity_builder, sequence_validator =
    get_allocator(dependency, config, producer_id, run_key)
  if not allocator then
    return nil, token_validator
  end

  local valid, validation_error
  if token_validator then
    valid, validation_error = token_validator(producer_id, "producer_id")
  else
    valid, validation_error = validate_basic_token(producer_id, "producer_id")
  end
  if not valid then
    return nil, validation_error
  end

  if token_validator then
    valid, validation_error = token_validator(run_key, "run_key")
  else
    valid, validation_error = validate_basic_token(run_key, "run_key")
  end
  if not valid then
    return nil, validation_error
  end

  valid, validation_error = validate_source_version(source_version)
  if not valid then
    return nil, validation_error
  end

  local producer = {
    producer_id = producer_id,
    run_key = run_key,
    source_version = source_version,
  }

  local function build(input)
    if type(input) ~= "table" then
      return nil, "event input must be a table"
    end

    local event_type = input.event_type
    if type(event_type) ~= "string" or not EVENT_TYPES[event_type] then
      return nil, "event_type must be a supported telemetry event"
    end

    local sim_time = input.sim_time
    if not is_finite_number(sim_time) or sim_time < 0 then
      return nil, "sim_time must be a non-negative finite number"
    end

    local wall_time = input.wall_time
    if is_null(wall_time) then
      wall_time = JSON_NULL
    elseif not is_wall_time(wall_time) then
      return nil, "wall_time must be an RFC 3339 date-time or null"
    end

    local initiator
    initiator, validation_error = normalize_actor(input.initiator, token_validator)
    if not initiator then
      return nil, validation_error
    end

    local target
    target, validation_error = normalize_actor(input.target, token_validator)
    if not target then
      return nil, validation_error
    end

    local participant
    participant, validation_error = normalize_participant(input.participant, token_validator)
    if not participant then
      return nil, validation_error
    end

    local asset
    asset, validation_error = normalize_asset(input.asset, token_validator)
    if not asset then
      return nil, validation_error
    end

    local weapon
    weapon, validation_error = normalize_weapon(input.weapon)
    if not weapon then
      return nil, validation_error
    end

    local coalition = map_coalition(input.coalition, true)

    local location
    location, validation_error = normalize_location(input.location)
    if not location then
      return nil, validation_error
    end

    local payload
    payload, validation_error = normalize_payload(input, event_type)
    if not payload then
      return nil, validation_error
    end

    local normalized_fields = {
      initiator = initiator,
      target = target,
      participant = participant,
      asset = asset,
      weapon = weapon,
      coalition = coalition,
      location = location,
    }
    valid, validation_error = validate_event_roles(event_type, normalized_fields)
    if not valid then
      return nil, validation_error
    end

    local event_sequence, event_id = allocate(allocator, event_type)
    if not event_sequence then
      return nil, event_id
    end

    if sequence_validator then
      valid, validation_error = sequence_validator(event_sequence)
    else
      valid = is_finite_integer(event_sequence) and event_sequence >= 1 and event_sequence <= MAX_SEQUENCE
      validation_error = "allocator returned an invalid event sequence"
    end
    if not valid then
      return nil, validation_error
    end
    if type(event_id) ~= "string" or string.len(event_id) == 0 then
      return nil, "allocator returned an invalid event_id"
    end

    if identity_builder then
      local expected_event_id, identity_error = identity_builder(producer_id, run_key, event_sequence)
      if not expected_event_id then
        return nil, identity_error
      end
      if event_id ~= expected_event_id then
        return nil, "allocator event_id does not match producer, run, and sequence"
      end
    end

    return {
      schema_version = SCHEMA_VERSION,
      event_id = event_id,
      source = SOURCE,
      producer_id = producer_id,
      source_version = source_version,
      run_key = run_key,
      event_sequence = event_sequence,
      event_type = event_type,
      sim_time = sim_time,
      wall_time = wall_time,
      initiator = initiator,
      target = target,
      participant = participant,
      asset = asset,
      weapon = weapon,
      coalition = coalition,
      location = location,
      payload = payload,
    }
  end

  function producer:build(input)
    return build(input)
  end

  function producer:emit(input)
    return build(input)
  end

  -- A retry reuses the exact table returned by build. It deliberately does no
  -- normalization or allocation; the caller retains the already-built event.
  function producer:retry(built_envelope)
    if type(built_envelope) ~= "table" then
      return nil, "retry requires an already-built envelope"
    end
    return built_envelope
  end

  return producer
end

M.create = M.new

return M

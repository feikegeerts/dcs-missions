-- Bounded mission-owned queue for encoded telemetry event lines.
--
-- Queue indexes are lifetime-contiguous and one-based: index 1 is the first
-- line ever appended. The bridge maps line index N directly to
-- event_sequence N; this queue deliberately knows nothing about runs,
-- producers, or envelope contents.

local M = {}

local function is_positive_integer(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value >= 1
    and math.floor(value) == value
end

function M.new(config)
  config = config or {}
  if type(config) ~= "table" then
    return nil, "bridge queue configuration must be a table"
  end

  local max_lines = config.max_lines or 8192
  if not is_positive_integer(max_lines) then
    return nil, "bridge queue max_lines must be a positive integer"
  end

  local entries = {}
  local acknowledged = 0
  local appended = 0
  local queue = {}

  function queue:append(line)
    if type(line) ~= "string" or string.len(line) == 0 then
      return nil, "bridge queue line must be a non-empty string"
    end
    if appended - acknowledged >= max_lines then
      return nil, "bridge queue overflow: maximum pending lines " .. tostring(max_lines) .. " reached"
    end

    appended = appended + 1
    entries[appended] = line
    return true
  end

  function queue:peek(from_index, max_count)
    if not is_positive_integer(from_index) then
      return nil, "bridge queue from_index must be a positive integer"
    end
    if not is_positive_integer(max_count) then
      return nil, "bridge queue max_count must be a positive integer"
    end
    if appended == acknowledged then
      return nil, "bridge queue is empty"
    end
    if from_index < acknowledged + 1 then
      return nil, "bridge queue from_index is stale"
    end
    if from_index > appended + 1 then
      return nil, "bridge queue from_index is beyond pending"
    end
    if from_index == appended + 1 then
      return {}, nil, nil
    end

    local last_index = math.min(appended, from_index + max_count - 1)
    local lines = {}
    for index = from_index, last_index do
      lines[#lines + 1] = entries[index]
    end
    return lines, from_index, last_index
  end

  function queue:ack(through_index)
    if not is_positive_integer(through_index) then
      return nil, "bridge queue acknowledgement must be a positive integer"
    end
    if through_index <= acknowledged then
      return nil, "bridge queue acknowledgement is stale"
    end
    if through_index > appended then
      return nil, "bridge queue acknowledgement is beyond pending"
    end

    for index = acknowledged + 1, through_index do
      entries[index] = nil
    end
    acknowledged = through_index
    return true
  end

  function queue:pending_count()
    return appended - acknowledged
  end

  function queue:acked_count()
    return acknowledged
  end

  function queue:first_pending_index()
    if appended == acknowledged then
      return nil
    end
    return acknowledged + 1
  end

  function queue:is_full()
    return appended - acknowledged >= max_lines
  end

  return queue
end

return M

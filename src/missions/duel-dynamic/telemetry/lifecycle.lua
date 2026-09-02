local M = {}

local LIFECYCLE_EVENT_TYPES = {
  ["mission.started"] = true,
  ["mission.heartbeat"] = true,
  ["mission.ended"] = true,
}

local function call_method(receiver, method_name, ...)
  local method = receiver and receiver[method_name]
  if type(method) ~= "function" then
    return nil, method_name .. " is unavailable"
  end

  local ok, first, second = pcall(method, receiver, ...)
  if not ok then
    return nil, method_name .. " raised: " .. tostring(first)
  end
  return first, second
end

local function call_provider(provider, name, optional)
  local ok, value, provider_error = pcall(provider)
  if not ok then
    if optional then
      return nil
    end
    return nil, name .. " provider raised: " .. tostring(value)
  end
  if value == nil and not optional then
    return nil, name .. " provider failed: " .. tostring(provider_error or "no value")
  end
  return value
end

function M.new(config)
  if type(config) ~= "table" then
    return nil, "lifecycle configuration must be a table"
  end

  local producer = config.producer
  if type(producer) ~= "table" or type(producer.build) ~= "function" or type(producer.retry) ~= "function" then
    return nil, "lifecycle requires a producer with build and retry"
  end

  local sink = config.sink
  if type(sink) ~= "table" or type(sink.write) ~= "function" then
    return nil, "lifecycle requires a sink with write"
  end

  if type(config.sim_time) ~= "function" then
    return nil, "lifecycle requires a sim_time provider"
  end
  if config.wall_time ~= nil and type(config.wall_time) ~= "function" then
    return nil, "lifecycle wall_time provider must be a function"
  end
  if type(config.started_payload) ~= "table" then
    return nil, "lifecycle requires a mission.started payload"
  end

  local state = "new"
  local fault_error
  local pending_event
  local pending_success_state
  local last_event
  local ended_event
  local controller = {}

  local function fault(message, event, success_state)
    state = "faulted"
    fault_error = tostring(message or "unknown lifecycle failure")
    pending_event = event
    pending_success_state = success_state
    return nil, fault_error
  end

  local function prepare_input(input)
    if type(input) ~= "table" then
      return nil, "event input must be a table"
    end

    local prepared = {}
    for key, value in pairs(input) do
      prepared[key] = value
    end

    if prepared.sim_time == nil then
      local sim_time, sim_error = call_provider(config.sim_time, "sim_time", false)
      if sim_time == nil then
        return nil, sim_error
      end
      prepared.sim_time = sim_time
    end

    if prepared.wall_time == nil and config.wall_time then
      prepared.wall_time = call_provider(config.wall_time, "wall_time", true)
    end

    return prepared
  end

  local function persist_input(input, success_state)
    local event, build_error = call_method(producer, "build", input)
    if not event then
      return fault("building " .. tostring(input.event_type) .. " failed: " .. tostring(build_error))
    end

    local written, write_error = call_method(sink, "write", event)
    if not written then
      return fault(
        "persisting " .. tostring(input.event_type) .. " failed: " .. tostring(write_error),
        event,
        success_state
      )
    end

    state = success_state
    last_event = event
    if success_state == "ended" then
      ended_event = event
    end
    return event
  end

  local function build_and_persist(event_type, payload, success_state)
    local input, input_error = prepare_input({
      event_type = event_type,
      payload = payload,
    })
    if not input then
      return fault(input_error)
    end

    return persist_input(input, success_state)
  end

  function controller:start()
    if state ~= "new" then
      return nil, "mission lifecycle can only start once"
    end
    return build_and_persist("mission.started", config.started_payload, "active")
  end

  function controller:heartbeat()
    if state ~= "active" then
      return nil, "mission heartbeat requires an active lifecycle"
    end
    return build_and_persist("mission.heartbeat", {}, "active")
  end

  -- Persist an already-normalized source-event input while the run is active.
  -- The producer is still the only allocator: a failed sink write therefore
  -- retains the exact envelope in pending_event and closes the lifecycle until
  -- retry_pending succeeds.
  function controller:record(input)
    if type(input) == "table" and LIFECYCLE_EVENT_TYPES[input.event_type] then
      return nil, "lifecycle event types must use start, heartbeat, or finish"
    end
    if state ~= "active" then
      return nil, "active lifecycle is required to record an event"
    end

    local prepared, preparation_error = prepare_input(input)
    if not prepared then
      return fault(preparation_error)
    end

    return persist_input(prepared, "active")
  end

  function controller:finish()
    if state == "ended" then
      return ended_event
    end
    if state ~= "active" then
      return nil, "mission end requires an active lifecycle"
    end

    state = "ending"
    return build_and_persist("mission.ended", { reason = "mission-end-observed" }, "ended")
  end

  function controller:retry_pending()
    if state ~= "faulted" or not pending_event then
      return nil, "lifecycle has no pending event to retry"
    end

    local event, retry_error = call_method(producer, "retry", pending_event)
    if not event then
      return nil, "preparing pending event retry failed: " .. tostring(retry_error)
    end
    if event ~= pending_event then
      return nil, "producer retry did not preserve the pending envelope"
    end

    local written, write_error = call_method(sink, "write", event)
    if not written then
      fault_error = "persisting pending " .. tostring(event.event_type) .. " failed: " .. tostring(write_error)
      return nil, fault_error
    end

    state = pending_success_state
    last_event = event
    if state == "ended" then
      ended_event = event
    end
    pending_event = nil
    pending_success_state = nil
    fault_error = nil
    return event
  end

  function controller:state()
    return state
  end

  function controller:fault_error()
    return fault_error
  end

  function controller:pending_event()
    return pending_event
  end

  function controller:last_event()
    return last_event
  end

  return controller
end

return M

-- Mission-facing interface, API version 1. No filesystem or gameplay knowledge.
-- Module resolution is injected: disk in development, embedded table in shipping.
local M = { API_VERSION = 1 }

local COMMON = { "event_id", "envelope", "json", "lifecycle", "asset", "shot", "combat", "participant" }

function M.new(options, resolve)
  options = options or {}
  local runtime
  local state = "disabled"
  local mode = options.mode or "disabled"
  local reported = {}
  local client = {}

  local function report(key)
    if reported[key] then
      return
    end
    reported[key] = true
    -- Never log adapter exception text: it may contain participant data.
    pcall(function()
      if options.env and type(options.env.warning) == "function" then
        options.env.warning("[telemetry] " .. key)
      end
    end)
  end

  local function invoke(operation, ...)
    if state == "disabled" then
      return nil, "disabled"
    end
    if not runtime then
      report(operation .. " unavailable")
      return nil, "unavailable"
    end
    local ok, result, detail = pcall(function(...)
      local adapter = runtime.asset
      if not adapter then
        return nil, "unavailable"
      end
      return adapter[operation](adapter, ...)
    end, ...)
    if not ok or not result then
      local reason = ok and detail == "unavailable" and "unavailable" or "failed"
      report(operation .. " " .. reason)
      return nil, reason
    end
    return result, detail
  end

  -- Explicit scenario milestones ride the run lifecycle as ordinary sequenced
  -- source events. They never throw: a missing controller, a closed lifecycle,
  -- or a malformed payload degrades to a bounded category and gameplay continues.
  local function record_milestone(operation, event_type, payload)
    if state == "disabled" then
      return nil, "disabled"
    end
    if not runtime then
      report(operation .. " unavailable")
      return nil, "unavailable"
    end
    local controller = runtime.controller
    if type(controller) ~= "table" or type(controller.record) ~= "function" then
      report(operation .. " unavailable")
      return nil, "unavailable"
    end
    local ok, event = pcall(controller.record, controller, { event_type = event_type, payload = payload })
    if not ok or not event then
      report(operation .. " failed")
      return nil, "failed"
    end
    return event
  end

  local function milestone_payload(info, keys)
    local payload = {}
    if type(info) == "table" then
      for _, key in ipairs(keys) do
        if info[key] ~= nil then
          payload[key] = info[key]
        end
      end
    end
    return payload
  end

  function client:register_player_group(group)
    return invoke("register_player_group", group)
  end

  function client:register_opposing_group(group, template_name)
    return invoke("register_bandit_group", group, template_name)
  end

  -- Reporting only: destruction stays in gameplay, after this call.
  function client:despawn_group(group)
    return invoke("despawn_group", group)
  end

  -- Opt-in scenario milestones. Non-wave missions simply never call the wave
  -- methods; they link no wave code through this interface.
  function client:report_wave_spawned(info)
    return record_milestone(
      "report_wave_spawned",
      "wave.spawned",
      milestone_payload(info, { "wave_number", "wave_size", "donor", "tier", "reason" })
    )
  end

  function client:report_wave_cleared(info)
    return record_milestone(
      "report_wave_cleared",
      "wave.cleared",
      milestone_payload(info, { "wave_number", "wave_size", "reason" })
    )
  end

  -- Gameplay outcome is recorded immediately before a terminal mission action.
  function client:report_gameplay_over(info)
    return record_milestone(
      "report_gameplay_over",
      "gameplay.ended",
      milestone_payload(info, { "reason", "detail" })
    )
  end

  function client:status()
    return { state = state, mode = mode, api_version = M.API_VERSION }
  end

  if mode == "disabled" then
    return client
  end
  state = "faulted"
  if mode ~= "development" and mode ~= "shipping" then
    report("invalid or conflicting transport selection")
    return client
  end

  local ok, result = pcall(function()
    assert(type(options.mission_name) == "string" and options.mission_name ~= "", "mission identity required")
    assert(type(options.mission_version) == "string" and options.mission_version ~= "", "mission version required")
    local config = {}
    for key, value in pairs(options) do
      config[key] = value
    end
    -- Optional reporting capabilities; missing means a legacy producer.
    if config.capabilities ~= nil then
      assert(type(config.capabilities) == "table", "capabilities must be a table")
      local copied = {}
      for key, value in pairs(config.capabilities) do
        assert(key == "wave_milestones" or key == "gameplay_outcome", "unknown capability")
        assert(value == 1, "capability version must be 1")
        copied[key] = value
      end
      config.capabilities = copied
    end
    config.heartbeat_interval = config.heartbeat_interval or 30
    -- Preserve the existing producer implementation version during extraction.
    config.source_version = config.source_version or "duel-dynamic-telemetry-v1"
    config.run_classification = config.run_classification or (mode == "development" and "test" or "historical")
    for _, name in ipairs(COMMON) do
      config[name] = assert(resolve(name), "missing module")
    end
    local driver
    if mode == "development" then
      config.ndjson_sink = assert(resolve("ndjson_sink"), "missing sink")
      driver = resolve("development")
    else
      config.bridge_frame = assert(resolve("bridge_frame"), "missing frame codec")
      config.bridge_queue = assert(resolve("bridge_queue"), "missing queue")
      driver = resolve("bridge")
    end
    local started, start_error = driver.start(config)
    assert(type(started) == "table", start_error or "runtime start failed")
    return started
  end)
  if not ok then
    report("initialization failed")
    return client
  end
  runtime = result -- Strong reference: MOOSE event subscribers are weak-keyed.
  state = "started" -- Shipping is armed, not necessarily handshaken/delivering.
  -- Compatibility with the installed hook and the dev-only combat harness.
  -- These names are transport ABI aliases, not scenario identity.
  if type(options.state) == "table" then
    rawset(options.state, "duel_telemetry_runtime", runtime)
    if mode == "shipping" then
      rawset(options.state, "duel_telemetry_bridge", runtime)
    end
  end
  return client
end

return M

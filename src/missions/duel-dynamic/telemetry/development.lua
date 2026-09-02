local M = {}

local RUN_COUNTER_KEY = "__duel_dynamic_telemetry_run_counter"

local function fingerprint(value)
  local hash = 0
  for index = 1, string.len(value) do
    hash = (hash * 131 + string.byte(value, index)) % 2147483647
  end
  return string.format("%08x", hash)
end

local function protected_call(name, callback, ...)
  local ok, first, second = pcall(callback, ...)
  if not ok then
    return nil, name .. " raised: " .. tostring(first)
  end
  return first, second
end

local function log(env_api, level, message)
  local writer = env_api and env_api[level]
  if type(writer) == "function" then
    pcall(writer, "[duel-dynamic][telemetry] " .. message)
  end
end

local function require_dependency(config, name, member)
  local dependency = config[name]
  if type(dependency) ~= "table" or (member and type(dependency[member]) ~= "function") then
    return nil, "development telemetry requires " .. name .. (member and "." .. member or "")
  end
  return dependency
end

local function ensure_directory(lfs_api, path)
  local mode = protected_call("lfs.attributes", lfs_api.attributes, path, "mode")
  if mode == "directory" then
    return true
  end
  if mode ~= nil then
    return nil, "telemetry path exists and is not a directory: " .. path
  end

  local _, mkdir_error = protected_call("lfs.mkdir", lfs_api.mkdir, path)
  local verified_mode = protected_call("lfs.attributes", lfs_api.attributes, path, "mode")
  if verified_mode ~= "directory" then
    return nil, "could not create telemetry directory: " .. tostring(mkdir_error or path)
  end
  return true
end

local function make_context(config, write_directory)
  local state_store = config.state
  local previous_counter = rawget(state_store, RUN_COUNTER_KEY)
  if type(previous_counter) ~= "number" or previous_counter < 0 or math.floor(previous_counter) ~= previous_counter then
    previous_counter = 0
  end
  local counter = previous_counter + 1
  rawset(state_store, RUN_COUNTER_KEY, counter)

  local utc, utc_error = protected_call("os.date", config.os.date, "!%Y%m%dT%H%M%SZ")
  if type(utc) ~= "string" or string.len(utc) == 0 then
    return nil, utc_error or "os.date did not return a UTC timestamp"
  end

  local epoch = protected_call("os.time", config.os.time) or 0
  local cpu_time = protected_call("os.clock", config.os.clock) or 0
  local absolute_time = protected_call("timer.getAbsTime", config.timer.getAbsTime) or 0
  local entropy =
    table.concat({ write_directory, tostring(epoch), tostring(cpu_time), tostring(absolute_time), counter }, "|")

  return {
    producer_id = "dcs-dev-" .. fingerprint(string.lower(string.gsub(write_directory, "\\", "/"))),
    run_key = "run-" .. utc .. "-" .. fingerprint(entropy),
  }
end

function M.start(config)
  if type(config) ~= "table" then
    return nil, "development telemetry configuration must be a table"
  end

  local event_id, dependency_error = require_dependency(config, "event_id", "new")
  if not event_id then
    return nil, dependency_error
  end
  local envelope
  envelope, dependency_error = require_dependency(config, "envelope", "new")
  if not envelope then
    return nil, dependency_error
  end
  local json
  json, dependency_error = require_dependency(config, "json", "new")
  if not json then
    return nil, dependency_error
  end
  local ndjson_sink
  ndjson_sink, dependency_error = require_dependency(config, "ndjson_sink", "new")
  if not ndjson_sink then
    return nil, dependency_error
  end
  local lifecycle
  lifecycle, dependency_error = require_dependency(config, "lifecycle", "new")
  if not lifecycle then
    return nil, dependency_error
  end
  local shot
  shot, dependency_error = require_dependency(config, "shot", "new")
  if not shot then
    return nil, dependency_error
  end
  local lfs_api
  lfs_api, dependency_error = require_dependency(config, "lfs", "writedir")
  if not lfs_api or type(lfs_api.attributes) ~= "function" or type(lfs_api.mkdir) ~= "function" then
    return nil, dependency_error or "development telemetry requires lfs attributes and mkdir"
  end
  if type(config.io) ~= "table" or type(config.io.open) ~= "function" then
    return nil, "development telemetry requires io.open"
  end
  if
    type(config.os) ~= "table"
    or type(config.os.date) ~= "function"
    or type(config.os.time) ~= "function"
    or type(config.os.clock) ~= "function"
  then
    return nil, "development telemetry requires os date, time, and clock"
  end
  if
    type(config.timer) ~= "table"
    or type(config.timer.getTime) ~= "function"
    or type(config.timer.getAbsTime) ~= "function"
  then
    return nil, "development telemetry requires timer getTime and getAbsTime"
  end
  if type(config.BASE) ~= "table" or type(config.BASE.New) ~= "function" then
    return nil, "development telemetry requires MOOSE BASE"
  end
  if type(config.SCHEDULER) ~= "table" or type(config.SCHEDULER.New) ~= "function" then
    return nil, "development telemetry requires MOOSE SCHEDULER"
  end
  if type(config.EVENTS) ~= "table" or config.EVENTS.MissionEnd == nil then
    return nil, "development telemetry requires EVENTS.MissionEnd"
  end
  if type(config.state) ~= "table" then
    return nil, "development telemetry requires a state table"
  end

  local heartbeat_interval = config.heartbeat_interval or 30
  if type(heartbeat_interval) ~= "number" or heartbeat_interval <= 0 then
    return nil, "heartbeat_interval must be a positive number"
  end

  local write_directory, write_error = protected_call("lfs.writedir", lfs_api.writedir)
  if type(write_directory) ~= "string" or string.len(write_directory) == 0 then
    return nil, write_error or "lfs.writedir did not return a path"
  end

  local telemetry_directory = config.telemetry_directory or (write_directory .. "Logs/telemetry")
  local directory_ready, directory_error = ensure_directory(lfs_api, telemetry_directory)
  if not directory_ready then
    return nil, directory_error
  end

  local context, context_error = make_context(config, write_directory)
  if not context then
    return nil, context_error
  end

  local encoder, encoder_error = json.new({ null = envelope.JSON_NULL })
  if not encoder then
    return nil, encoder_error
  end
  local path = telemetry_directory .. "/" .. context.run_key .. ".ndjson"
  local sink, sink_error = ndjson_sink.new({ path = path, encoder = encoder, io = config.io })
  if not sink then
    return nil, sink_error
  end
  local producer, producer_error = envelope.new({
    event_id = event_id,
    producer_id = context.producer_id,
    run_key = context.run_key,
    source_version = config.source_version,
  })
  if not producer then
    return nil, producer_error
  end

  local function sim_time()
    return config.timer.getTime()
  end
  local function wall_time()
    local value = protected_call("os.date", config.os.date, "!%Y-%m-%dT%H:%M:%SZ")
    return value
  end

  local map_name = envelope.JSON_NULL
  if config.env and config.env.mission and type(config.env.mission.theatre) == "string" then
    map_name = config.env.mission.theatre
  end

  local controller, lifecycle_error = lifecycle.new({
    producer = producer,
    sink = sink,
    sim_time = sim_time,
    wall_time = wall_time,
    started_payload = {
      mission_name = config.mission_name,
      mission_version = config.mission_version,
      map_name = map_name,
      run_classification = config.run_classification,
    },
  })
  if not controller then
    return nil, lifecycle_error
  end

  -- Constructing the adapter does not subscribe it. Registration is delayed
  -- until after mission.started has been persisted below.
  local shot_adapter, shot_creation_error
  local shot_created, shot_result, shot_error = pcall(function()
    return shot.new({
      controller = controller,
      envelope = envelope,
      BASE = config.BASE,
      EVENTS = config.EVENTS,
      player_group_names = config.player_group_names,
      bandit_group_names = config.bandit_group_names,
      player_coalition = config.player_coalition,
      bandit_coalition = config.bandit_coalition,
      log = function(level, message)
        log(config.env, level, message)
      end,
    })
  end)
  if not shot_created then
    return nil, "creating Shot adapter failed: " .. tostring(shot_result)
  end
  shot_adapter = shot_result
  shot_creation_error = shot_error
  if not shot_adapter then
    return nil, "creating Shot adapter failed: " .. tostring(shot_creation_error)
  end

  local runtime = {
    controller = controller,
    path = path,
    producer_id = context.producer_id,
    run_key = context.run_key,
  }
  local scheduler
  local schedule_id
  local watcher

  local function stop_heartbeat()
    if scheduler and schedule_id then
      local id = schedule_id
      schedule_id = nil
      local ok, remove_error = pcall(function()
        scheduler:Remove(id)
      end)
      if not ok then
        log(config.env, "error", "heartbeat removal failed: " .. tostring(remove_error))
      end
    end
  end

  local function stop_shot()
    local stopped, stop_result, stop_error = pcall(function()
      return shot_adapter:stop()
    end)
    if not stopped then
      log(config.env, "error", "Shot subscription removal raised: " .. tostring(stop_result))
    elseif not stop_result then
      log(config.env, "error", "Shot subscription removal failed: " .. tostring(stop_error))
    end
  end

  local function finish()
    stop_heartbeat()
    stop_shot()
    local event, finish_error = controller:finish()
    if not event then
      log(config.env, "error", "mission end persistence failed: " .. tostring(finish_error))
      return nil, finish_error
    end
    log(config.env, "info", "persisted mission.ended sequence=" .. tostring(event.event_sequence))
    return event
  end

  local watcher_ok, watcher_or_error = pcall(function()
    return config.BASE:New()
  end)
  if not watcher_ok or type(watcher_or_error) ~= "table" then
    return nil, "creating MissionEnd watcher failed: " .. tostring(watcher_or_error)
  end
  watcher = watcher_or_error
  function watcher:OnEventMissionEnd()
    finish()
    pcall(function()
      self:UnHandleEvent(config.EVENTS.MissionEnd)
    end)
  end
  local handled, handle_error = pcall(function()
    watcher:HandleEvent(config.EVENTS.MissionEnd)
  end)
  if not handled then
    return nil, "registering MissionEnd failed: " .. tostring(handle_error)
  end

  local scheduler_ok, scheduler_result, scheduler_id_or_error = pcall(function()
    return config.SCHEDULER:New(nil, function()
      local event, heartbeat_error = controller:heartbeat()
      if not event then
        log(config.env, "error", "heartbeat persistence failed: " .. tostring(heartbeat_error))
        stop_heartbeat()
        return false
      end
      log(config.env, "info", "persisted mission.heartbeat sequence=" .. tostring(event.event_sequence))
      return true
    end, {}, heartbeat_interval, heartbeat_interval)
  end)
  if not scheduler_ok or not scheduler_result or scheduler_id_or_error == nil then
    pcall(function()
      watcher:UnHandleEvent(config.EVENTS.MissionEnd)
    end)
    return nil, "creating heartbeat scheduler failed: " .. tostring(scheduler_id_or_error or scheduler_result)
  end
  scheduler = scheduler_result
  schedule_id = scheduler_id_or_error

  local started, start_error = controller:start()
  if not started then
    stop_heartbeat()
    pcall(function()
      watcher:UnHandleEvent(config.EVENTS.MissionEnd)
    end)
    return nil, start_error
  end

  local shot_started, shot_start_result, shot_start_error = pcall(function()
    return shot_adapter:start()
  end)
  if not shot_started or not shot_start_result then
    stop_heartbeat()
    pcall(function()
      watcher:UnHandleEvent(config.EVENTS.MissionEnd)
    end)
    pcall(function()
      shot_adapter:stop()
    end)
    return nil, "registering Shot adapter failed: " .. tostring(shot_start_error or shot_start_result)
  end

  runtime.scheduler = scheduler
  runtime.watcher = watcher
  runtime.shot = shot_adapter
  runtime.shot_watcher = shot_adapter.watcher
  runtime.finish = finish
  log(
    config.env,
    "info",
    "started producer="
      .. context.producer_id
      .. " run="
      .. context.run_key
      .. " sequence="
      .. tostring(started.event_sequence)
      .. " path="
      .. path
  )
  return runtime
end

return M

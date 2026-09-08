-- Mission-side production telemetry bridge.
--
-- The GameGUI hook calls the _G.duel_telemetry_bridge runtime through
-- a_do_script using this protocol:
--   begin(producer_id, run_key) -> true or nil, error
--   peek(from_sequence, max_frames) -> DDBRIDGE1 frame, "" when drained,
--     or nil, error; frame-too-large means retry with a smaller max_frames
--   ack(sequence) -> true or nil, error after the hook durably spools the
--     highest contiguous sequence
--   status() -> a flat scalar-only status table
-- Queue line index N maps directly to event_sequence N. The runtime is also
-- rooted at _G.duel_telemetry_runtime for mission adapter access. Its path
-- field is the hook-injected run_key because production has no mission file.

local M = {}

local function log(env_api, level, message)
  local writer = env_api and env_api[level]
  if type(writer) == "function" then
    pcall(writer, "[duel-dynamic][telemetry] " .. message)
  end
end

local function require_dependency(config, name, member)
  local dependency = config[name]
  if type(dependency) ~= "table" or (member and type(dependency[member]) ~= "function") then
    return nil, "bridge telemetry requires " .. name .. (member and "." .. member or "")
  end
  return dependency
end

local function positive_number(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value > 0
end

local function positive_integer(value)
  return positive_number(value) and math.floor(value) == value
end

local function stop_adapter(config, adapter, label)
  if not adapter then
    return
  end
  local ok, result, stop_error = pcall(function()
    return adapter:stop()
  end)
  if not ok then
    log(config.env, "error", label .. " subscription removal raised: " .. tostring(result))
  elseif not result then
    log(config.env, "error", label .. " subscription removal failed: " .. tostring(stop_error))
  end
end

function M.start(config)
  if type(config) ~= "table" then
    return nil, "bridge telemetry configuration must be a table"
  end

  local required = {
    { "event_id", "new" },
    { "envelope", "new" },
    { "json", "new" },
    { "lifecycle", "new" },
    { "bridge_queue", "new" },
    { "bridge_frame", "encode" },
    { "asset", "new" },
    { "shot", "new" },
    { "participant", "new" },
  }
  for _, item in ipairs(required) do
    local dependency, dependency_error = require_dependency(config, item[1], item[2])
    if not dependency then
      return nil, dependency_error
    end
  end
  if type(config.bridge_frame.decode) ~= "function" then
    return nil, "bridge telemetry requires bridge_frame.decode"
  end
  if type(config.timer) ~= "table" or type(config.timer.getTime) ~= "function" then
    return nil, "bridge telemetry requires timer.getTime"
  end
  if type(config.BASE) ~= "table" or type(config.BASE.New) ~= "function" then
    return nil, "bridge telemetry requires MOOSE BASE"
  end
  if type(config.SCHEDULER) ~= "table" or type(config.SCHEDULER.New) ~= "function" then
    return nil, "bridge telemetry requires MOOSE SCHEDULER"
  end
  if type(config.EVENTS) ~= "table" or config.EVENTS.MissionEnd == nil then
    return nil, "bridge telemetry requires EVENTS.MissionEnd"
  end
  if type(config.state) ~= "table" then
    return nil, "bridge telemetry requires a state table"
  end

  local heartbeat_interval = config.heartbeat_interval or 30
  if not positive_number(heartbeat_interval) then
    return nil, "heartbeat_interval must be a positive number"
  end
  local run_classification = config.run_classification or "historical"
  if run_classification ~= "test" and run_classification ~= "historical" then
    return nil, "run_classification must be test or historical"
  end
  local queue_max_lines = config.queue_max_lines or 8192
  if not positive_integer(queue_max_lines) then
    return nil, "bridge queue max_lines must be a positive integer"
  end

  local runtime = {
    state = "waiting",
  }
  local queue
  local scheduler
  local schedule_id
  local watcher
  local asset_adapter
  local shot_adapter
  local combat_adapter
  local participant_adapter

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

  local function remove_watcher()
    if watcher then
      pcall(function()
        watcher:UnHandleEvent(config.EVENTS.MissionEnd)
      end)
    end
  end

  local function stop_all()
    stop_heartbeat()
    stop_adapter(config, participant_adapter, "participant")
    stop_adapter(config, shot_adapter, "Shot")
    stop_adapter(config, combat_adapter, "combat")
    stop_adapter(config, asset_adapter, "asset")
  end

  local function synchronize_state()
    if runtime.controller then
      local controller_state = runtime.controller:state()
      if controller_state == "faulted" or controller_state == "ending" or controller_state == "ended" then
        runtime.state = controller_state
      end
    end
    return runtime.state
  end

  function runtime:status()
    local current_state = synchronize_state()
    local pending_count = queue and queue:pending_count() or 0
    return {
      state = current_state,
      producer_id = self.producer_id,
      run_key = self.run_key,
      pending_count = pending_count,
      first_pending_sequence = queue and queue:first_pending_index() or nil,
      last_acked_sequence = queue and queue:acked_count() or nil,
      fault_error = self.controller and self.controller:fault_error() or self.start_error,
    }
  end

  function runtime:peek(from_sequence, max_frames)
    if self.state == "waiting" then
      return nil, "not begun"
    end
    if not queue then
      return nil, self.start_error or "bridge start faulted"
    end
    if self.queue_overflow_error then
      return nil, "bridge queue overflow"
    end
    if not positive_integer(from_sequence) then
      return nil, "from_sequence must be a positive integer"
    end
    if not positive_integer(max_frames) then
      return nil, "max_frames must be a positive integer"
    end
    if queue:pending_count() == 0 then
      return ""
    end
    local lines, first_sequence, last_sequence = queue:peek(from_sequence, max_frames)
    if not lines then
      return nil, first_sequence
    end
    if #lines == 0 then
      return ""
    end
    return config.bridge_frame.encode({
      producer_id = self.producer_id,
      run_key = self.run_key,
      first_sequence = first_sequence,
      last_sequence = last_sequence,
    }, lines)
  end

  function runtime:ack(sequence)
    if self.state == "waiting" then
      return nil, "not begun"
    end
    if not queue then
      return nil, self.start_error or "bridge start faulted"
    end
    -- ACK is idempotent at the transport boundary. A hook may retry after the
    -- mission applied an ACK but its response was lost. Only an already-covered
    -- positive sequence is accepted here; the queue still rejects stale ACKs.
    if positive_integer(sequence) and sequence <= queue:acked_count() then
      return true, "already-applied"
    end
    return queue:ack(sequence)
  end

  function runtime:begin(producer_id, run_key)
    if self.state ~= "waiting" then
      return nil, self.state == "faulted" and "bridge start already faulted" or "bridge already begun"
    end
    local valid, validation_error = config.event_id.validate_token(producer_id, "producer_id")
    if not valid then
      return nil, validation_error
    end
    valid, validation_error = config.event_id.validate_token(run_key, "run_key")
    if not valid then
      return nil, validation_error
    end

    local function fail_start(message)
      stop_all()
      remove_watcher()
      self.state = "faulted"
      self.start_error = tostring(message)
      log(config.env, "error", "bridge start failed: " .. self.start_error)
      return nil, self.start_error
    end

    local queue_error
    queue, queue_error = config.bridge_queue.new({ max_lines = queue_max_lines })
    if not queue then
      return fail_start(queue_error)
    end
    local encoder, encoder_error = config.json.new({ null = config.envelope.JSON_NULL })
    if not encoder then
      return fail_start(encoder_error)
    end
    local sink = {}
    function sink:write(event)
      local ok, line, encode_error = pcall(encoder.encode, encoder, event)
      if not ok then
        local message = "encoding event failed: " .. tostring(line)
        log(config.env, "error", message)
        return nil, message
      end
      if type(line) ~= "string" then
        local message = "encoding event failed: " .. tostring(encode_error or "encoder returned no string")
        log(config.env, "error", message)
        return nil, message
      end
      local appended, append_error = queue:append(line)
      if not appended then
        if type(append_error) == "string" and string.find(append_error, "bridge queue overflow:", 1, true) == 1 then
          runtime.queue_overflow_error = append_error
        end
        log(config.env, "error", "bridge queue write failed: " .. tostring(append_error))
        return nil, append_error
      end
      return true
    end

    local producer, producer_error = config.envelope.new({
      event_id = config.event_id,
      producer_id = producer_id,
      run_key = run_key,
      source_version = config.source_version,
    })
    if not producer then
      return fail_start(producer_error)
    end
    local map_name = config.envelope.JSON_NULL
    if config.env and config.env.mission and type(config.env.mission.theatre) == "string" then
      map_name = config.env.mission.theatre
    end
    local controller, lifecycle_error = config.lifecycle.new({
      producer = producer,
      sink = sink,
      sim_time = function()
        return config.timer.getTime()
      end,
      wall_time = function()
        return config.envelope.JSON_NULL
      end,
      started_payload = {
        mission_name = config.mission_name,
        mission_version = config.mission_version,
        map_name = map_name,
        run_classification = run_classification,
      },
    })
    if not controller then
      return fail_start(lifecycle_error)
    end

    local function adapter_log(level, message)
      log(config.env, level, message)
    end
    local ok, result, creation_error = pcall(config.asset.new, {
      controller = controller,
      envelope = config.envelope,
      BASE = config.BASE,
      EVENTS = config.EVENTS,
      player_group_names = config.player_group_names,
      bandit_group_names = config.bandit_group_names,
      player_coalition = config.player_coalition,
      bandit_coalition = config.bandit_coalition,
      log = adapter_log,
    })
    if not ok or not result then
      return fail_start("creating asset adapter failed: " .. tostring(creation_error or result))
    end
    asset_adapter = result

    ok, result, creation_error = pcall(config.shot.new, {
      controller = controller,
      envelope = config.envelope,
      BASE = config.BASE,
      EVENTS = config.EVENTS,
      player_group_names = config.player_group_names,
      bandit_group_names = config.bandit_group_names,
      player_coalition = config.player_coalition,
      bandit_coalition = config.bandit_coalition,
      asset_registry = asset_adapter,
      log = adapter_log,
    })
    if not ok or not result then
      return fail_start("creating Shot adapter failed: " .. tostring(creation_error or result))
    end
    shot_adapter = result

    if type(config.combat) == "table" and type(config.combat.new) == "function" then
      ok, result, creation_error = pcall(config.combat.new, {
        controller = controller,
        envelope = config.envelope,
        BASE = config.BASE,
        EVENTS = config.EVENTS,
        asset_registry = asset_adapter,
        log = adapter_log,
      })
      if ok and result then
        combat_adapter = result
      else
        log(
          config.env,
          "warning",
          "creating combat adapter failed; Hit/Kill telemetry disabled: " .. tostring(creation_error or result)
        )
      end
    else
      log(config.env, "warning", "combat adapter missing; Hit/Kill telemetry disabled")
    end

    ok, result, creation_error = pcall(config.participant.new, {
      controller = controller,
      envelope = config.envelope,
      BASE = config.BASE,
      EVENTS = config.EVENTS,
      player_group_names = config.player_group_names,
      player_coalition = config.player_coalition,
      asset_registry = asset_adapter,
      log = adapter_log,
    })
    if not ok or not result then
      return fail_start("creating participant adapter failed: " .. tostring(creation_error or result))
    end
    participant_adapter = result

    ok, result = pcall(function()
      return config.BASE:New()
    end)
    if not ok or type(result) ~= "table" then
      return fail_start("creating MissionEnd watcher failed: " .. tostring(result))
    end
    watcher = result

    local function finish()
      stop_all()
      local event, finish_error = controller:finish()
      synchronize_state()
      if not event then
        log(config.env, "error", "mission end persistence failed: " .. tostring(finish_error))
        return nil, finish_error
      end
      log(config.env, "info", "persisted mission.ended sequence=" .. tostring(event.event_sequence))
      return event
    end
    function watcher:OnEventMissionEnd()
      finish()
      remove_watcher()
    end
    ok, result = pcall(function()
      return watcher:HandleEvent(config.EVENTS.MissionEnd)
    end)
    if not ok then
      return fail_start("registering MissionEnd failed: " .. tostring(result))
    end

    local scheduler_id_or_error
    ok, result, scheduler_id_or_error = pcall(function()
      return config.SCHEDULER:New(nil, function()
        local event, heartbeat_error = controller:heartbeat()
        synchronize_state()
        if not event then
          log(config.env, "error", "heartbeat persistence failed: " .. tostring(heartbeat_error))
          stop_heartbeat()
          return false
        end
        log(config.env, "info", "persisted mission.heartbeat sequence=" .. tostring(event.event_sequence))
        return true
      end, {}, heartbeat_interval, heartbeat_interval)
    end)
    if not ok or not result or scheduler_id_or_error == nil then
      return fail_start("creating heartbeat scheduler failed: " .. tostring(scheduler_id_or_error or result))
    end
    scheduler = result
    schedule_id = scheduler_id_or_error

    local started, start_error = controller:start()
    if not started then
      return fail_start(start_error)
    end
    local function start_adapter(adapter, label)
      local started_ok, started_result, started_error = pcall(function()
        return adapter:start()
      end)
      if not started_ok or not started_result then
        return nil, "registering " .. label .. " adapter failed: " .. tostring(started_error or started_result)
      end
      return true
    end
    local adapter_started, adapter_error = start_adapter(asset_adapter, "asset")
    if not adapter_started then
      return fail_start(adapter_error)
    end
    adapter_started, adapter_error = start_adapter(participant_adapter, "participant")
    if not adapter_started then
      return fail_start(adapter_error)
    end
    adapter_started, adapter_error = start_adapter(shot_adapter, "Shot")
    if not adapter_started then
      return fail_start(adapter_error)
    end
    if combat_adapter then
      adapter_started, adapter_error = start_adapter(combat_adapter, "combat")
      if not adapter_started then
        log(config.env, "warning", adapter_error .. "; Hit/Kill telemetry disabled")
        stop_adapter(config, combat_adapter, "combat")
        combat_adapter = nil
      end
    end

    self.controller = controller
    self.sink = sink
    self.queue = queue
    self.path = run_key
    self.producer_id = producer_id
    self.run_key = run_key
    self.scheduler = scheduler
    self.watcher = watcher
    self.asset = asset_adapter
    self.asset_watcher = asset_adapter.watcher
    self.shot = shot_adapter
    self.shot_watcher = shot_adapter.watcher
    self.combat = combat_adapter
    self.combat_watcher = combat_adapter and combat_adapter.watcher or nil
    self.participant = participant_adapter
    self.participant_watcher = participant_adapter.watcher
    self.finish = finish
    self.state = "active"
    log(config.env, "info", "started producer=" .. producer_id .. " run=" .. run_key .. " sequence=1")
    return true
  end

  -- MOOSE event subscriptions use weak subscriber keys. Keep the complete
  -- runtime strongly reachable for the life of this mission run.
  _G.duel_telemetry_bridge = runtime
  _G.duel_telemetry_runtime = runtime
  return runtime
end

return M

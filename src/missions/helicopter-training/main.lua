-- Helicopter Training Grounds - range entry point.
--
-- Loaded by src/bootstrap.lua in development (named loader: mission_name =
-- "helicopter-training"). Deliberately plain DCS scripting API plus the small
-- modules beside this file - no MOOSE dependency - so the range can later be
-- shipped as one self-contained script.
--
-- Responsibilities, in order: resolve the configured sites against real
-- terrain, build the world, install a 1 Hz evaluation loop, install per-pilot
-- F10 menus, and report.

-- Modules come either from disk (development, via src/bootstrap.lua) or from the
-- pre-assembled table the shipping build installs at _G.HTG_PRELOADED
-- (see build/pack-helicopter-training-miz.ps1). The dev-only branch below is
-- stripped from the shipped payload, which is why it sits between markers.
local function load_module(name)
  local preloaded = rawget(_G, "HTG_PRELOADED")
  if preloaded and preloaded[name] then
    return preloaded[name]
  end
  -- HTG:DEV-ONLY-BEGIN
  local root = _G.MY_SCRIPTS_ROOT
  assert(root, "bootstrap must supply the source root, or the shipping build must preload the modules")
  local chunk = assert(loadfile(root .. "missions/helicopter-training/" .. name), "cannot load " .. name)
  return chunk()
  -- HTG:DEV-ONLY-END
end

local cfg = load_module("config.lua")
local Geo = load_module("geo.lua")
local Notify = load_module("notify.lua")
local Range = load_module("range.lua")
local Terrain = load_module("terrain.lua")
local Troops = load_module("troops.lua")
local Progress = load_module("progress.lua")
local Exercises = load_module("exercises.lua")

local notify = Notify.new(cfg.mission_name, cfg.coalition)
notify:log(string.format("%s v%s loading", cfg.title, cfg.mission_version))

-- ----------------------------------------------------------- site resolution

local terrain = Terrain.new()
local sites = {}
local site_order = {}

local function resolve_sites()
  local reference = cfg.base
  for key, site in pairs(cfg.sites) do
    local resolved = terrain:resolve_site(site, cfg.probe)
    resolved.key = key
    resolved.label = site.label
    resolved.radius = site.radius
    resolved.height = resolved.height or 0
    sites[key] = resolved
    site_order[#site_order + 1] = key
    local note = ""
    if not resolved.ok then
      note = string.format("  ** UNUSABLE (%s) - exercise will not resolve", tostring(resolved.reason))
    elseif resolved.moved_m and resolved.moved_m > 0 then
      note = string.format("  moved %.0f m (%s)", resolved.moved_m, tostring(resolved.reason))
    end
    notify:log(
      string.format(
        "site %-13s %s  h=%.1f m relief=%.1f m%s",
        key,
        Geo.coord(resolved.x, resolved.y),
        resolved.height,
        resolved.relief or 0,
        note
      )
    )
  end
  table.sort(site_order)
end

-- --------------------------------------------------------------- world build

local range = Range.new(cfg)
local troops = Troops.new(cfg, range)
local progress = Progress.new()
local exercises = Exercises.new({
  cfg = cfg,
  range = range,
  troops = troops,
  progress = progress,
  notify = notify,
  sites = sites,
})

-- ------------------------------------------------------------------ sampling

local function unit_heading(unit)
  local ok, position = pcall(function()
    return unit:getPosition()
  end)
  if not ok or not position or not position.x then
    return 0
  end
  local forward = position.x
  return (math.deg(math.atan2(forward.x, forward.z)) + 360) % 360
end

local function sample_for(unit)
  local ok, point = pcall(function()
    return unit:getPoint()
  end)
  if not ok or not point then
    return nil
  end
  local ok_ground, ground = pcall(land.getHeight, { x = point.x, y = point.z })
  ground = (ok_ground and type(ground) == "number") and ground or 0

  local ok_velocity, velocity = pcall(function()
    return unit:getVelocity()
  end)
  local speed = 0
  if ok_velocity and velocity then
    speed = math.sqrt(velocity.x ^ 2 + velocity.y ^ 2 + velocity.z ^ 2)
  end

  local ok_air, in_air = pcall(function()
    return unit:inAir()
  end)
  in_air = ok_air and in_air or false

  local ok_name, player = pcall(function()
    return unit:getPlayerName()
  end)

  return {
    unit_name = unit:getName(),
    player = (ok_name and player) or unit:getName(),
    type_name = unit:getTypeName(),
    x = point.x,
    y = point.z,
    alt = point.y,
    agl = point.y - ground,
    speed_ms = speed,
    speed_kmh = speed * 3.6,
    heading = unit_heading(unit),
    in_air = in_air,
    on_ground = (not in_air) or (point.y - ground) <= cfg.landing.agl_max_m,
  }
end

--- Every player-controlled helicopter on the range.
local function player_samples()
  local samples = {}
  local ok, groups = pcall(coalition.getGroups, cfg.coalition, Group.Category.HELICOPTER)
  if not ok or not groups then
    return samples
  end
  for _, group in pairs(groups) do
    local ok_units, units = pcall(function()
      return group:getUnits()
    end)
    if ok_units and units then
      for _, unit in pairs(units) do
        local ok_player, player = pcall(function()
          return unit:getPlayerName()
        end)
        if ok_player and player and player ~= "" then
          local sample = sample_for(unit)
          if sample then
            samples[#samples + 1] = sample
          end
        end
      end
    end
  end
  return samples
end

-- -------------------------------------------------------------------- menus

local menus_built = {}

local function build_menu(group_id)
  if menus_built[group_id] then
    return
  end
  menus_built[group_id] = true

  local root = missionCommands.addSubMenuForGroup(group_id, "RANGE")
  missionCommands.addCommandForGroup(group_id, "Status", root, function()
    trigger.action.outTextForGroup(group_id, exercises:status_text(), 20, true)
  end)
  missionCommands.addCommandForGroup(group_id, "Briefing", root, function()
    trigger.action.outTextForGroup(group_id, exercises:brief_text(), 30, true)
  end)
  missionCommands.addCommandForGroup(group_id, "Reset range", root, function()
    exercises:reset_world()
  end)
  missionCommands.addCommandForGroup(group_id, "Clear scores", root, function()
    progress:reset()
    trigger.action.outTextForGroup(group_id, "Scores cleared.", 10, false)
  end)
  missionCommands.addCommandForGroup(group_id, "Terrain scan", root, function()
    trigger.action.outTextForGroup(group_id, "Scanning terrain for landing zones...", 10, false)
    timer.scheduleFunction(function()
      local result = terrain:scan(cfg.base, cfg.probe)
      local lines = { "TERRAIN SCAN" }
      for _, candidate in ipairs(result.hill) do
        lines[#lines + 1] = string.format(
          "hill  %s  elev %.0f m relief %.0f m",
          Geo.coord(candidate.x, candidate.y),
          candidate.elevation,
          candidate.wide_relief
        )
      end
      for _, candidate in ipairs(result.flat) do
        lines[#lines + 1] =
          string.format("flat  %s  relief %.1f m", Geo.coord(candidate.x, candidate.y), candidate.relief)
      end
      lines[#lines + 1] = string.format("%d candidates sampled", result.candidates)
      local text = table.concat(lines, "\n")
      trigger.action.outTextForGroup(group_id, text, 40, true)
      notify:log("terrain scan: " .. text:gsub("\n", " | "))
      return nil
    end, nil, timer.getTime() + 1)
  end)

  local smoke_root = missionCommands.addSubMenuForGroup(group_id, "Smoke one location", root)
  if #exercises.smoke_sites > 0 then
    local site_menu = missionCommands.addSubMenuForGroup(group_id, "Training sites", smoke_root)
    for _, option in ipairs(exercises.smoke_sites) do
      local site_key, label, color = option.key, option.label, option.color
      missionCommands.addCommandForGroup(group_id, "Site: " .. label, site_menu, function()
        local site = sites[site_key]
        local ok = site and range:smoke_at(site.x, site.y, site.height, color)
        local message = ok and ("Smoke marks " .. label .. ".") or ("Could not mark " .. label .. ".")
        trigger.action.outTextForGroup(group_id, message, 8, false)
      end)
    end
  end

  if #exercises.cargo > 0 then
    local cargo_menu = missionCommands.addSubMenuForGroup(group_id, "Cargo loads", smoke_root)
    for _, load in ipairs(exercises.cargo) do
      local index, label = load.index, load.menu_label
      missionCommands.addCommandForGroup(group_id, "Load: " .. label, cargo_menu, function()
        local ok = exercises:smoke_cargo(index)
        local message = ok and ("White smoke marks load " .. label .. ".")
          or ("Load " .. label .. " is no longer available.")
        trigger.action.outTextForGroup(group_id, message, 8, false)
      end)
    end
  end
end

local function build_menus_for_players()
  local samples = player_samples()
  for _, sample in ipairs(samples) do
    local ok, unit = pcall(Unit.getByName, sample.unit_name)
    if ok and unit then
      local ok_group, group = pcall(function()
        return unit:getGroup()
      end)
      if ok_group and group then
        build_menu(group:getID())
      end
    end
  end
end

-- --------------------------------------------------------------- evaluation

local function evaluate()
  local samples = player_samples()
  for _, sample in ipairs(samples) do
    exercises:tick(sample)
  end
  local positions = {}
  for _, sample in ipairs(samples) do
    positions[#positions + 1] = { unit_name = sample.unit_name, player = sample.player, x = sample.x, y = sample.y }
  end
  local now = timer.getAbsTime()
  exercises:update_cargo(positions, now)
  exercises:check_target_respawn(now)
  build_menus_for_players()
end

local function start_loop()
  timer.scheduleFunction(function()
    local ok, err = pcall(evaluate)
    if not ok then
      notify:warn("evaluation tick failed: " .. tostring(err))
    end
    return timer.getTime() + 1
  end, nil, timer.getTime() + 2)
end

-- ------------------------------------------------------------------ events

local function on_event(event)
  if event.id == world.event.S_EVENT_KILL then
    local initiator, target = event.initiator, event.target
    if
      initiator
      and target
      and Object.getCategory(initiator) == Object.Category.UNIT
      and Object.getCategory(target) == Object.Category.UNIT
    then
      local ok_name, player = pcall(function()
        return initiator:getPlayerName()
      end)
      if ok_name and player and player ~= "" then
        exercises:on_kill(player, initiator:getName(), target:getName())
      end
    end
    return
  end

  if event.id == world.event.S_EVENT_PLAYER_ENTER_UNIT or event.id == world.event.S_EVENT_BIRTH then
    timer.scheduleFunction(function()
      build_menus_for_players()
      return nil
    end, nil, timer.getTime() + 1)
    return
  end

  if event.id == world.event.S_EVENT_DEAD then
    local initiator = event.initiator
    if initiator and Object.getCategory(initiator) == Object.Category.UNIT then
      local ok_name, player = pcall(function()
        return initiator:getPlayerName()
      end)
      if ok_name and player and player ~= "" then
        troops:abort(initiator:getName())
      end
    end
  end
end

-- -------------------------------------------------------------------- start

resolve_sites()
exercises:register()
exercises:setup()

-- Handle for the offline simulation tests and for in-mission inspection
-- (dcs-fiddle, DCS-gRPC). Read-only from outside; nothing depends on it.
_G.helicopter_training = {
  config = cfg,
  sites = sites,
  progress = progress,
  exercises = exercises,
  terrain = terrain,
  range = range,
  troops = troops,
}

local ok_handler, handler = pcall(world.addEventHandler, { onEvent = on_event })
if not ok_handler then
  notify:warn("event handler registration failed: " .. tostring(handler))
end

start_loop()

notify:all(exercises:brief_text(), cfg.messages.boot_seconds)
notify:log(string.format("ready - %d sites resolved, %d terrain samples", #site_order, terrain.calls))

if cfg.probe.enabled then
  timer.scheduleFunction(function()
    local ok, result = pcall(function()
      return terrain:scan(cfg.base, cfg.probe)
    end)
    if ok and result then
      for _, candidate in ipairs(result.hill) do
        notify:log(
          string.format(
            "probe hill %s elev %.0f m relief %.0f m",
            Geo.coord(candidate.x, candidate.y),
            candidate.elevation,
            candidate.wide_relief
          )
        )
      end
      for _, candidate in ipairs(result.flat) do
        notify:log(string.format("probe flat %s relief %.1f m", Geo.coord(candidate.x, candidate.y), candidate.relief))
      end
      notify:log(string.format("probe done: %d candidates", result.candidates))
    else
      notify:warn("terrain probe failed: " .. tostring(result))
    end
    return nil
  end, nil, timer.getTime() + 8)
end

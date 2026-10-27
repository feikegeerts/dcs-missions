-- Execute source OR generated shipping payload with no filesystem in its env.
-- This checks our adapter contract, not actual DCS terrain/CTLD simulation.
local shipping = arg[1]
local config = dofile("src/missions/operation-hidden-passage/config.lua")
local archive_mission
-- Optional real archive layout: exercise the same adapter at relocated zones,
-- while retaining the packaged script/config unchanged (runtime reads zones).
if arg[2] then
  local sandbox = {}
  local chunk = assert(loadfile(arg[2]))
  setfenv(chunk, sandbox)
  chunk()
  archive_mission = sandbox.mission
  local fields = {
    [config.pickup_zone] = "pickup",
    [config.personnel_zone] = "personnel",
    [config.return_zone] = "receiving",
  }
  local found = 0
  for _, zone in pairs(assert(sandbox.mission).triggers.zones) do
    local field = fields[zone.name]
    if field then
      config[field] = { x = zone.x, y = zone.y, radius = zone.radius }
      found = found + 1
    end
  end
  assert(found == 3, "Expected all three transport zones in archive layout")
end
local Operation = dofile("src/missions/operation-hidden-passage/operation.lua")
local moose_file = assert(io.open("src/lib/Moose_.lua", "rb"))
local moose = moose_file:read("*a")
moose_file:close()
local function pinned_method(name, env, class)
  class = class or "CTLD"
  local first = assert(moose:find("function " .. class .. ":" .. name .. "(", 1, true))
  local last = assert(moose:find("\nfunction " .. class .. ":", first + 1, true))
  local chunk = assert(loadstring(moose:sub(first, last - 1)))
  setfenv(chunk, env)
  chunk()
end
local count = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  assert(ok, name .. ": " .. tostring(err))
  count = count + 1
end
local function harness(options)
  options = options or {}
  local env = {}
  for _, key in ipairs({
    "assert",
    "error",
    "ipairs",
    "pairs",
    "next",
    "pcall",
    "tostring",
    "type",
    "math",
    "string",
    "table",
  }) do
    env[key] = _G[key]
  end
  env._G = env
  env.coalition = { side = { BLUE = 2 } }
  env.land = {
    SurfaceType = { LAND = 1 },
    getSurfaceType = function()
      return options.water and 3 or 1
    end,
    getHeight = function(point)
      return options.steep and point.x or 60
    end,
  }
  local h = {
    timers = {},
    groups = {},
    notices = {},
    notice_times = {},
    sounds = {},
    sound_times = {},
    sound_targets = {},
    notice_targets = {},
    errors = {},
    deferred = {},
    commands = {},
    smokes = {},
    roots = {},
    commands_by_group = {},
    marks = {},
    event_handlers = {},
    blue_players = {},
    now = 100,
  }
  env.coalition.getPlayers = function(side)
    assert(side == env.coalition.side.BLUE)
    h.roster_reads = (h.roster_reads or 0) + 1
    if options.roster_error then
      error("simulated roster read failure")
    end
    if options.roster_invalid then
      return nil
    end
    return h.blue_players
  end
  function h:schedule(delay, fn)
    self.deferred[#self.deferred + 1] = { at = self.now + delay, run = fn }
  end
  function h:advance(seconds)
    local until_time = self.now + seconds
    while true do
      table.sort(self.deferred, function(a, b)
        return a.at < b.at
      end)
      local event = self.deferred[1]
      if not event or event.at > until_time then
        break
      end
      table.remove(self.deferred, 1)
      self.now = event.at
      event.run()
    end
    self.now = until_time
  end
  env.timer = {
    getTime = function()
      return h.now
    end,
  }
  env.timer.scheduleFunction = function(fn, arg, at)
    h:schedule(math.max(0, at - h.now), function()
      local next_at = fn(arg)
      if next_at then
        env.timer.scheduleFunction(fn, arg, next_at)
      end
    end)
    return at
  end
  env.trigger = {
    action = {
      outSoundForCoalition = function(side, path)
        assert(side == 2, "Voice must play to Blue")
        h.sounds[#h.sounds + 1] = path
        h.sound_times[#h.sounds] = h.now
        h.sound_targets[#h.sounds] = "coalition"
      end,
    },
  }
  env.USERSOUND = {
    New = function(_, path)
      return {
        ToUnit = function(_, unit)
          h.sounds[#h.sounds + 1] = path
          h.sound_times[#h.sounds] = h.now
          h.sound_targets[#h.sounds] = unit:GetID()
        end,
      }
    end,
  }
  env.world = {
    event = { S_EVENT_TAKEOFF = 3, S_EVENT_DEAD = 8, S_EVENT_CRASH = 5, S_EVENT_UNIT_LOST = 30 },
    addEventHandler = function(handler)
      h.event_handlers[#h.event_handlers + 1] = handler
    end,
  }
  env.env = {
    info = function() end,
    error = function(message)
      h.errors[#h.errors + 1] = message
    end,
  }
  env.MESSAGE = {
    New = function(_, text)
      return {
        ToCoalition = function()
          h.notices[#h.notices + 1] = text
          h.notice_times[#h.notices] = h.now
          h.notice_targets[#h.notices] = "coalition"
        end,
        ToUnit = function(_, unit)
          h.notices[#h.notices + 1] = text
          h.notice_times[#h.notices] = h.now
          h.notice_targets[#h.notices] = unit:GetID()
        end,
      }
    end,
  }
  local function coordinate(point)
    point = { x = point.x, y = point.y }
    return {
      MarkToCoalition = function(_, text)
        h.marks[#h.marks + 1] = text
      end,
      SmokeGreen = function()
        h.smokes[#h.smokes + 1] = point
      end,
      Translate = function(self, distance, angle, _, keep)
        local radians = math.rad(angle)
        local translated = { x = point.x + distance * math.cos(radians), y = point.y + distance * math.sin(radians) }
        if keep then
          point = translated
          return self
        end
        return coordinate(translated)
      end,
      GetVec2 = function()
        return point
      end,
    }
  end
  env.ZONE = {
    New = function(_, name)
      if options.missing_zone == name then
        return nil
      end
      local points = {
        [config.pickup_zone] = config.pickup,
        [config.return_zone] = config.receiving,
        [config.personnel_zone] = config.personnel,
      }
      for key, value in pairs(options.zone_points or {}) do
        points[key] = value
      end
      local point = assert(points[name])
      return {
        GetVec2 = function()
          return point
        end,
        GetCoordinate = function()
          return coordinate(point)
        end,
        IsVec2InZone = function(_, pos)
          return (pos.x - point.x) ^ 2 + (pos.y - point.y) ^ 2 <= point.radius ^ 2
        end,
      }
    end,
  }
  local function group(name, point, size)
    local g = {
      name = name,
      size = size or 3,
      point = point,
      GetName = function(self)
        return self.name
      end,
      GetSize = function(self)
        return self.size
      end,
      GetUnits = function(self)
        if self.units_override then
          return self.units_override
        end
        local units = {}
        for i = 1, self.size do
          local index = i
          local point = { x = self.point.x + (i - 1) * 12, y = self.point.y }
          units[i] = {
            GetName = function()
              return self.name .. "-" .. index
            end,
            GetLife = function()
              if self.unit_observation_error then
                error("simulated unit query error")
              end
              if self.units_removed then
                return -1
              end
              return self.unit_life and self.unit_life[index] or (index <= self.size and 100 or 0)
            end,
            GetVec2 = function()
              return point
            end,
          }
        end
        return units
      end,
      GetUnit = function(self, index)
        return self:GetUnits()[index]
      end,
      IsAlive = function(self)
        return self.size > 0
      end,
      GetVec2 = function(self)
        return self.point
      end,
      GetCoordinate = function(self)
        return coordinate(self.point)
      end,
      GetHeading = function()
        return 0
      end,
      RouteToVec2 = function(self, point, speed)
        self.route_target = point
        self.route_speed = speed
      end,
      OptionROEHoldFire = function(self)
        self.roe = "hold"
      end,
      OptionROEOpenFire = function(self)
        self.roe = "open"
      end,
      OptionDisperseOnAttack = function(self, seconds)
        self.disperse_on_attack_s = seconds
        return self
      end,
      SetCommand = function(self, command)
        h.group_commands = h.group_commands or {}
        h.group_commands[#h.group_commands + 1] = { group = self, command = command }
      end,
      SetCommandImmortal = function(self, value)
        h.group_commands = h.group_commands or {}
        h.group_commands[#h.group_commands + 1] = {
          group = self,
          command = { id = "SetImmortal", params = { value = value } },
        }
      end,
      TaskFireAtPoint = function(_, point, radius, ammunition)
        return { id = "FireAtPoint", point = point, radius = radius, ammunition = ammunition }
      end,
      TaskHold = function()
        return { id = "Hold", params = {} }
      end,
      SetTask = function(self, task)
        self.assigned_task = task
        h.group_tasks = h.group_tasks or {}
        h.group_tasks[#h.group_tasks + 1] = { group = self, task = task }
      end,
      Destroy = function(self, generate_event, delay)
        assert(generate_event == false)
        if delay and delay > 0 then
          h:schedule(delay, function()
            self.size = 0
            self.disappeared_at = h.now
          end)
        else
          self.size = 0
          self.disappeared_at = h.now
        end
      end,
    }
    h.groups[name] = g
    return g
  end
  if options.awacs then
    env.AI = { Option = { Air = { id = { PROHIBIT_WP_PASS_REPORT = 19 } } } }
    env.CONTROLLABLE = {}
    pinned_method("SetOptionWaypointPassReport", env, "CONTROLLABLE")
    h.awacs = group(config.awacs_group, config.receiving, 1)
    h.awacs.F2 = function() end
    h.awacs.IsAir = function()
      return true
    end
    h.awacs.SetOptionWaypointPassReport = env.CONTROLLABLE.SetOptionWaypointPassReport
    h.awacs.options = {}
    h.awacs.SetOption = function(self, id, value)
      if options.awacs_option_error then
        error("simulated AWACS controller loss")
      end
      self.options[id] = value
    end
    if options.awacs_dead then
      h.awacs.size = 0
    end
  end
  h.player = {
    id = 101,
    name = config.player_unit,
    group_name = config.player_group,
    player_name = "Mule Pilot",
    type_name = "CH-47Fbl1",
    alive = true,
    airborne = false,
    point = options.player_far and config.receiving or config.pickup,
    IsAlive = function(self)
      return self.alive
    end,
    GetName = function(self)
      return self.name
    end,
    GetID = function(self)
      return self.id
    end,
    InAir = function(self, raw)
      assert(raw == true, "Must bypass MOOSE's stationary-hover correction")
      return self.airborne
    end,
    GetVec2 = function(self)
      return self.point
    end,
    GetGroup = function(self)
      return group(self.name == config.player_unit and config.player_group or config.support_group, self.point, 1)
    end,
    GetCoordinate = function(self)
      return coordinate(self.point)
    end,
    GetHeading = function()
      return 0
    end,
    GetTypeName = function(self)
      return self.type_name
    end,
    GetVelocityMPS = function(self)
      return self.speed or 0
    end,
    getCoalition = function()
      return 2
    end,
    getPlayerName = function(self)
      return self.player_name
    end,
    getGroup = function(self)
      local group_name = self.group_name
      return {
        getName = function()
          return group_name
        end,
      }
    end,
  }
  h.player.getName = h.player.GetName
  h.player.getTypeName = h.player.GetTypeName
  h.player.getID = h.player.GetID
  h.raven = {}
  for key, value in pairs(h.player) do
    h.raven[key] = value
  end
  h.raven.id, h.raven.name, h.raven.type_name = 202, config.support_unit, "UH-60L"
  h.raven.group_name, h.raven.player_name = config.support_group, "Raven Pilot"
  h.raven.point = config.receiving
  local function cas_player(group_name, type_name, player_name)
    local wrapper = group(group_name, config.receiving, 1)
    local original_alive = wrapper.IsAlive
    wrapper.IsAlive = function(self)
      return original_alive(self) and options.cas_test_menus == true
    end
    return {
      group_name = group_name,
      type_name = type_name,
      player_name = player_name,
      GetGroup = function()
        return wrapper
      end,
      inAir = function(self)
        return self.airborne ~= false
      end,
      getCoalition = function()
        return env.coalition.side.BLUE
      end,
      getPlayerName = function(self)
        return self.player_name
      end,
      getTypeName = function(self)
        return self.type_name
      end,
      getGroup = function(self)
        local name = self.group_name
        return {
          getName = function()
            return name
          end,
        }
      end,
    }
  end
  h.cas_hornet = cas_player("CAS-Hornet", "FA-18C_hornet", "Hornet Pilot")
  h.cas_warthog = cas_player("CAS-Warthog", "A-10C_2", "Warthog Pilot")
  h.cap_hornet = cas_player("CAP-Hornet", "FA-18C_hornet", "CAP Hornet Pilot")
  h.cap_viper = cas_player("CAP-Viper", "F-16C_50", "CAP Viper Pilot")
  env.UNIT = {
    FindByName = function(_, name)
      if name == config.support_unit then
        return not options.missing_support and h.raven or nil
      end
      assert(name == config.player_unit, "Unexpected transport unit lookup")
      if options.only_uh60 then
        return nil
      end
      return h.player
    end,
  }
  env.GROUP = {
    FindByName = function(_, name)
      if options.cas_checkpoint and name == config.cas.checkpoint_template then
        return h.cas_checkpoint_template
      end
      if options.cas_convoy and name == config.cas.convoy_template then
        return h.cas_convoy_template
      end
      if options.firefight and name == h.opposition_template_name then
        return h.opposition_template
      end
      if options.pickup_opposition and name == config.firefight.pickup_template then
        return h.pickup_opposition_template
      end
      return h.groups[name]
    end,
  }
  env.TIMER = {
    New = function(_, fn)
      local timer = {
        run = fn,
        Start = function(self, delay, interval)
          self.delay, self.interval = delay, interval
          return self
        end,
      }
      h.timers[#h.timers + 1] = timer
      return timer
    end,
  }
  env.MENU_GROUP = {
    New = function(_, group, name)
      h.roots[#h.roots + 1] = name
      return {
        Remove = function()
          h.removed_menu = true
        end,
      }
    end,
  }
  env.MENU_GROUP_COMMAND = {
    New = function(_, group, name, menu, fn)
      local commands = h.commands_by_group[group:GetName()] or {}
      h.commands_by_group[group:GetName()] = commands
      commands[name] = function()
        h.menu_invocations = (h.menu_invocations or 0) + 1
        return fn()
      end
      if group:GetName() == (options.only_uh60 and config.support_group or config.player_group) then
        h.commands = commands
      end
    end,
  }
  env.SET_GROUP = {
    New = function()
      return {
        GetSetObjects = function()
          return {}
        end,
      }
    end,
  }
  h.opposition_spawns, h.pickup_opposition_spawns, h.cas_convoy_spawns = 0, 0, 0
  h.cas_checkpoint_spawns = 0
  if options.firefight then
    local point = {
      x = config.personnel.x + config.firefight.staging_offset_m,
      y = config.personnel.y - config.firefight.staging_offset_m,
    }
    h.opposition_template_name = options.firefight_alias and config.firefight.template_alias
      or config.firefight.template
    h.opposition_template =
      group(h.opposition_template_name, point, options.firefight_unit_count or config.firefight.enemy_unit_count)
  end
  if options.pickup_opposition then
    h.pickup_opposition_template = group(config.firefight.pickup_template, config.personnel, 8)
  end
  if options.cas_convoy then
    h.cas_convoy_template = group(config.cas.convoy_template, config.personnel, options.cas_convoy_size or 6)
  end
  if options.cas_checkpoint then
    h.cas_checkpoint_template = group(config.cas.checkpoint_template, config.personnel, 8)
  end
  h.cap_spawns = { sam = 0, fighters = 0, hind = 0 }
  h.cap_runway_starts = {}
  env.AIRBASE = {
    FindByID = function(_, id)
      assert(id == 1, "Use the authored fighter airfield")
      if not options.cap_airbase_missing then
        return { id = id }
      end
    end,
  }
  local cap_templates = {
    [config.cap.sam_template] = "sam",
    [config.cap.fighters_template] = "fighters",
    [config.cap.hind_template] = "hind",
  }
  for name, role in pairs(cap_templates) do
    if options["cap_" .. role] then
      local authored = group(name, config.personnel, role == "sam" and 9 or role == "fighters" and 2 or 1)
      authored.GetTemplateRoutePoints = function()
        return { { airdromeId = 1 } }
      end
      authored.GetTemplate = function()
        local units = {}
        for i = 1, authored.size do
          units[i] = { name = name .. "-" .. i }
        end
        return { units = units }
      end
    end
  end
  if
    options.firefight
    or options.pickup_opposition
    or options.cas_convoy
    or options.cas_checkpoint
    or options.cap_sam
    or options.cap_fighters
    or options.cap_hind
  then
    env.SPAWN = {
      Takeoff = { Runway = 2 },
      New = function(_, template)
        local role = cap_templates[template]
        if role then
          assert(options["cap_" .. role], "Unavailable CAP template must not be spawned")
          local spawner = {}
          function spawner:InitLimit(maximum_units, maximum_groups)
            assert(maximum_units == 0 and maximum_groups == 1)
            return self
          end
          function spawner:SpawnAtAirbase(airbase, takeoff, altitude, terminal, emergency)
            assert(role == "fighters" and airbase.id == 1 and takeoff == env.SPAWN.Takeoff.Runway)
            assert(altitude == nil and terminal == nil and emergency == false, "No airborne fallback")
            h.cap_runway_starts[role] = (h.cap_runway_starts[role] or 0) + 1
            if options.cap_runway_blocked then
              return nil
            end
            return self:Spawn()
          end
          function spawner:Spawn()
            h.cap_spawns[role] = h.cap_spawns[role] + 1
            if options["cap_" .. role .. "_spawn_error"] then
              error("simulated " .. role .. " spawn failure")
            end
            if options["cap_" .. role .. "_spawn_nil"] then
              return nil
            end
            local g = group(template .. "#001", config.personnel, role == "sam" and 9 or role == "fighters" and 2 or 1)
            if role == "sam" then
              h.radars = {}
              g.units_override = {}
              for i = 1, options.cap_radar_count or 1 do
                local radar = {
                  alive = true,
                  life = 100,
                  emitting = true,
                  GetTypeName = function()
                    return config.cap.radar_type
                  end,
                  IsAlive = function(self)
                    if h.radar_observation_error then
                      error("transient radar observation error")
                    end
                    return self.alive
                  end,
                  GetLife = function(self)
                    return self.life
                  end,
                }
                h.radars[i] = radar
                g.units_override[#g.units_override + 1] = radar
              end
              -- Launchers and trucks remain alive when only the radar is killed.
              g.units_override[#g.units_override + 1] = {
                GetTypeName = function()
                  return "Kub 2P25 ln"
                end,
                IsAlive = function()
                  return true
                end,
                GetLife = function()
                  return 100
                end,
              }
              if options.cap_units_unavailable then
                g.GetUnits = function()
                  return nil
                end
              end
            end
            if options["cap_" .. role .. "_spawn_dead"] then
              g.size = 0
            end
            if options["cap_" .. role .. "_birth_delay"] then
              local size = g.size
              g.size = 0
              h:schedule(options["cap_" .. role .. "_birth_delay"], function()
                g.size = size
              end)
            end
            if role == "fighters" and options.cap_fighters_partial_birth then
              g.size = 1
              h:schedule(0.8, function()
                g.size = 2
              end)
            end
            h["cap_" .. role] = g
            return g
          end
          return spawner
        end
        if options.cas_checkpoint and template == config.cas.checkpoint_template then
          local spawner = {}
          function spawner:InitLimit(maximum_units, maximum_groups)
            assert(maximum_units == 0 and maximum_groups == 1)
            return self
          end
          function spawner:Spawn()
            h.cas_checkpoint_spawns = h.cas_checkpoint_spawns + 1
            if options.checkpoint_spawn_error then
              error("simulated checkpoint failure")
            end
            h.cas_checkpoint =
              group(template .. "#001", h.cas_checkpoint_template.point, h.cas_checkpoint_template.size)
            return h.cas_checkpoint
          end
          return spawner
        end
        if options.cas_convoy and template == config.cas.convoy_template then
          local spawner = {}
          function spawner:InitLimit(maximum_units, maximum_groups)
            assert(maximum_units == 0 and maximum_groups == 1)
            return self
          end
          function spawner:Spawn()
            h.cas_convoy_spawns = h.cas_convoy_spawns + 1
            h.cas_convoy =
              group(config.cas.convoy_template .. "#001", h.cas_convoy_template.point, h.cas_convoy_template.size)
            return h.cas_convoy
          end
          return spawner
        end
        assert(
          template == h.opposition_template_name
            or (options.pickup_opposition and template == config.firefight.pickup_template),
          "Unexpected opposition template " .. tostring(template)
        )
        local spawner = {}
        function spawner:InitLimit(maximum_units, maximum_groups)
          assert(maximum_units == 0 and maximum_groups == 1)
          return self
        end
        function spawner:Spawn()
          if template == h.opposition_template_name then
            h.opposition_spawns = h.opposition_spawns + 1
            h.opposition = group(template .. "#001", h.opposition_template.point, h.opposition_template.size)
            return h.opposition
          end
          h.pickup_opposition_spawns = h.pickup_opposition_spawns + 1
          h.pickup_opposition = group(template .. "#001", config.personnel, 8)
          return h.pickup_opposition
        end
        return spawner
      end,
    }
  end
  env.CTLD_CARGO = {
    Enum = { TROOPS = "Troops", ENGINEERS = "Engineers" },
    New = function(_, id, name, templates, kind, moved, direct, size, pos, dropped, mass, stock, sub, hidden)
      assert(templates[1] == config.party_template and size == 3)
      if id == nil then
        assert(stock == 0 and hidden)
      end
      return {
        Name = name,
        Templates = templates,
        CargoType = kind,
        CratesNeeded = size,
        PerCrateMass = mass,
        GetCratesNeeded = function()
          return size
        end,
        GetType = function()
          return kind
        end,
        GetName = function()
          return name
        end,
        GetTemplates = function()
          return templates
        end,
        WasDropped = function(self)
          return self.dropped or false
        end,
        SetWasDropped = function(self, value)
          self.dropped = value
        end,
      }
    end,
  }
  env.CTLD = {
    TroopUnloadDistGround = 5,
    TroopUnloadDistHover = 1.5,
    CargoZoneType = { LOAD = "load", SHIP = "ship" },
    New = function(_, side, prefixes)
      assert(side == 2 and prefixes[1] == config.player_group and prefixes[2] == config.support_group)
      local instance = {
        lid = "test",
        CargoCounter = 0,
        Loaded_Cargo = {},
        T = function() end,
        _SendMessage = function() end,
        _GetUnitCapabilities = function(self, unit)
          return assert(self.capabilities[unit:GetTypeName()])
        end,
        _GetDistance = function(_, a, b)
          a, b = a:GetVec2(), b:GetVec2()
          return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
        end,
        ScheduleOnce = function() end,
        _RefreshDropTroopsMenu = function() end,
        _RefreshTroopQuantityMenus = function() end,
        _UpdateUnitCargoMass = function() end,
        CleanDroppedTroops = function() end,
        IsUnitInZone = function()
          return false
        end,
        IsFixedWing = function()
          return false
        end,
        _GetUnitPositions = function()
          return {}
        end,
        __TroopsExtracted = function(self, delay, player_group, unit, troops, name)
          assert(delay >= 20)
          h.boarding_due = h.now + delay
          h:schedule(delay, function()
            self:OnAfterTroopsExtracted("Running", "TroopsExtracted", "Running", player_group, unit, troops, name)
          end)
        end,
        __TroopsDeployed = function(self, delay, player_group, unit, troops)
          h:schedule(delay, function()
            self:OnAfterTroopsDeployed("Running", "TroopsDeployed", "Running", player_group, unit, troops)
          end)
        end,
        capabilities = {},
        SetUnitCapabilities = function(self, type_name, crates, troops, cratelimit, trooplimit)
          self.capabilities[type_name] = { troops = troops, trooplimit = trooplimit }
        end,
        SetOwnSetPilotGroups = function(self, groups)
          self.UserSetGroup = groups
        end,
        InjectTroops = function(self, zone, cargo)
          assert(self.eventoninject == false and self.enableLoadSave == false)
          self.TroopCounter = 1
          self.Cargo_Troops = { cargo }
          self.DroppedTroops = { group("OHP-TestParty-123", zone:GetVec2()) }
        end,
        __Start = function(self)
          self.PilotGroups = assert(self.UserSetGroup)
        end,
      }
      return setmetatable(instance, { __index = env.CTLD })
    end,
  }
  if options.pinned then
    pinned_method("IsHook", env)
    pinned_method("_ExtractTroops", env)
    pinned_method("_UnloadTroops", env)
    pinned_method("_RefreshF10Menus", env)
    env.ZONE_GROUP = {
      New = function(_, name, player_group)
        return {
          GetRandomCoordinate = function()
            return player_group:GetCoordinate()
          end,
        }
      end,
    }
    env.SPAWN = {
      Takeoff = env.SPAWN and env.SPAWN.Takeoff,
      New = env.SPAWN and env.SPAWN.New,
      NewWithAlias = function(_, template, alias)
        assert(template == config.party_template)
        local spawn = {}
        for _, name in ipairs({
          "InitDelayOff",
          "InitSetUnitAbsolutePositions",
          "InitValidateAndRepositionGroundUnits",
          "OnSpawnGroup",
        }) do
          spawn[name] = function(self)
            return self
          end
        end
        function spawn:SpawnFromVec2(point)
          return group(alias .. "#001", point)
        end
        return spawn
      end,
    }
  end
  local voice_chunk = assert(loadfile("src/missions/operation-hidden-passage/voice.lua"))
  setfenv(voice_chunk, env)
  local Voice = voice_chunk()
  local chunk = assert(loadfile(shipping or "src/missions/operation-hidden-passage/transport-test.lua"))
  setfenv(chunk, env)
  chunk(config, Operation, Voice)
  h.runtime = assert(env.OHP_TRANSPORT_TEST)
  h.timers[1].run()
  function h:tick()
    self.runtime.observer.run()
  end
  function h:cap_tick()
    local observer = assert(self.runtime.cap.observer)
    assert(observer.delay == config.cap.radar_check_interval_s and observer.interval == nil)
    observer.run()
  end
  function h:observe_for(seconds)
    self:tick()
    for _ = 1, seconds do
      self:advance(1)
      self:tick()
    end
  end
  function h:flush()
    while #self.deferred > 0 do
      local latest = self.now
      for _, event in ipairs(self.deferred) do
        latest = math.max(latest, event.at)
      end
      self:advance(latest - self.now)
    end
  end
  function h:command(name, unit)
    self:tick()
    unit = unit or (options.only_uh60 and self.raven or self.player)
    local commands = self.commands_by_group[unit:GetGroup():GetName()] or {}
    assert(commands[name], "Missing command " .. name)()
  end
  function h:extract()
    self:tick()
    local ctld = self.runtime.ctld
    ctld.Loaded_Cargo[config.player_unit] = { Troopsloaded = 3 }
    self:tick()
    ctld:OnAfterTroopsExtracted(
      "Running",
      "TroopsExtracted",
      "Running",
      {},
      self.player,
      self.groups[self.runtime.objective.party_key],
      self.runtime.objective.party_key
    )
  end
  function h:drop(point, size, unit)
    unit = unit or self.player
    unit.point = point
    local troops = group("OHP-TestParty-456", point, size)
    self.runtime.ctld.Loaded_Cargo[unit:GetName()] = nil
    self.runtime.ctld:OnAfterTroopsDeployed("Running", "TroopsDeployed", "Running", {}, unit, troops)
  end
  return h
end
local function transport_takeoff_handler(h)
  return assert(h.runtime.takeoff_handler, "Transport takeoff handler was not registered")
end
test("Overlord waypoint calls are prohibited through the pinned MOOSE option, without replacing its task", function()
  local h = harness({ awacs = true })
  assert(h.awacs.options[19] == true, "PROHIBIT_WP_PASS_REPORT must be true")
  local count = 0
  for _ in pairs(h.awacs.options) do
    count = count + 1
  end
  assert(count == 1, "Do not silence AWACS generally or change unrelated options")
  assert(h.awacs.assigned_task == nil and h.awacs.route_target == nil)
  assert(h.runtime.objective.phase == "waiting" and #h.errors == 0)
  h.runtime.voice:radio("kub_neutralised")
  assert(#h.sounds == 0, "Outcome confirmations retain reporting latency")
  h:flush()
  assert(h.sounds[1] == "Sounds/OHP/overlord-kub-neutralised.ogg", "Recorded Overlord cues must still play")
end)
test("absent or destroyed Overlord cannot block extraction setup", function()
  for _, options in ipairs({ {}, { awacs = true, awacs_dead = true } }) do
    local h = harness(options)
    assert(h.runtime.objective.phase == "waiting" and #h.errors == 0)
    if h.awacs then
      assert(next(h.awacs.options) == nil)
    end
  end
end)
test("AWACS option errors are logged without failing extraction", function()
  local h = harness({ awacs = true, awacs_option_error = true })
  assert(h.runtime.objective.phase == "waiting" and #h.errors == 1)
  h:extract()
  assert(h.runtime.objective.phase == "aboard")
end)
test("landed pickup and correct delivery", function()
  local h = harness()
  h:extract()
  assert(h.runtime.objective.phase == "aboard")
  assert(h.sounds[1] == "Sounds/OHP/boarding-start.ogg", "sounds=" .. #h.sounds .. " errors=" .. tostring(h.errors[1]))
  h:advance(11)
  assert(h.sounds[2] == "Sounds/OHP/boarding-hvt-aboard.ogg")
  assert(h.sounds[3] == "Sounds/OHP/boarding-confirm.ogg")
  h:drop(config.receiving)
  assert(h.runtime.objective.phase == "complete" and #h.errors == 0)
  h:drop(config.receiving)
  assert(h.runtime.objective.phase == "complete")
  h:flush()
  assert(#h.sounds == 4 and h.sounds[4] == "Sounds/OHP/hidden-passage-success.ogg")
  assert(h.sound_targets[4] == "coalition" and h.notice_targets[#h.notices] == "coalition")
end)
test("mission success waits behind existing voice calls and plays once", function()
  local h = harness()
  h:extract()
  h:drop(config.receiving)
  assert(h.runtime.objective.phase == "complete" and #h.sounds == 1)
  h:drop(config.receiving)
  h:tick()
  h:flush()
  assert(#h.sounds == 4 and h.sounds[4] == "Sounds/OHP/hidden-passage-success.ogg")
  assert(h.sound_targets[4] == "coalition" and #h.errors == 0)
end)
test("uncollected, airborne, off-site, partial and failed delivery cannot play success", function()
  for _, invalid in ipairs({ "uncollected", "airborne", "off-site", "partial", "failed" }) do
    local h = harness()
    if invalid ~= "uncollected" then
      h:extract()
    end
    if invalid == "airborne" then
      h.player.airborne = true
    end
    if invalid == "failed" then
      h.runtime.objective:fail("Test failure")
    end
    h:drop(invalid == "off-site" and config.pickup or config.receiving, invalid == "partial" and 2 or 3)
    h:flush()
    assert(h.runtime.objective.phase ~= "complete", invalid)
    for _, sound in ipairs(h.sounds) do
      assert(sound ~= "Sounds/OHP/hidden-passage-success.ogg", invalid)
    end
  end
end)
test("unrelated troop deployments cannot announce mission success", function()
  local h = harness()
  h:extract()
  h.player.point = config.receiving
  h.runtime.ctld:OnAfterTroopsDeployed("Running", "TroopsDeployed", "Running", {}, h.player, {
    GetName = function()
      return "Unrelated-party"
    end,
  })
  h:flush()
  assert(h.runtime.objective.phase == "aboard")
  for _, sound in ipairs(h.sounds) do
    assert(sound ~= "Sounds/OHP/hidden-passage-success.ogg")
  end
end)
test("voice queue serializes overlapping calls", function()
  local h = harness()
  h.runtime.voice:play("boarding_start")
  h.runtime.voice:play("boarding_start")
  assert(#h.sounds == 1)
  h:advance(7)
  assert(#h.sounds == 2)
  assert(#h.errors == 0)
end)
test("prepared UH-60 recordings play in order without overlapping", function()
  local h = harness()
  assert(#h.sounds == 0, "Preparing UH-60 assets must not trigger playback")
  h.runtime.voice:play("uh60_boarding_start")
  h.runtime.voice:play("uh60_boarding_complete")
  assert(#h.sounds == 1 and h.sounds[1] == "Sounds/OHP/uh60-boarding-start.ogg")
  h:advance(4.4)
  assert(#h.sounds == 1, "First recording is still playing")
  h:advance(0.6)
  assert(#h.sounds == 2 and h.sounds[2] == "Sounds/OHP/uh60-boarding-complete.ogg")
  assert(h.runtime.objective.phase == "waiting" and #h.errors == 0)
end)
test("Mule takeoff plays only its own clearance once and only to its crew", function()
  local h = harness()
  assert(#h.event_handlers == 2, "Early CAS snapshot and transport handlers were not registered")
  local handler = transport_takeoff_handler(h)
  assert(
    type(handler) == "table" and type(handler.onEvent) == "function",
    "DCS calls handler:onEvent, so a table is required"
  )
  handler:onEvent({ id = 3, initiator = h.player })
  assert(h.sounds[1] == "Sounds/OHP/mule-one-cleared-for-pickup.ogg")
  assert(h.sound_targets[1] == h.player.id and #h.notices == 0)
  handler:onEvent({ id = 3, initiator = h.player })
  assert(#h.sounds == 1, "Takeoff call repeated")
end)
test("Raven takeoff plays only its support call once and only to its crew", function()
  local h = harness({ only_uh60 = true })
  local handler = transport_takeoff_handler(h)
  handler:onEvent({ id = 3, initiator = h.raven })
  assert(h.sounds[1] == "Sounds/OHP/raven-one-cleared-for-support.ogg")
  assert(h.sound_targets[1] == h.raven.id and #h.notices == 0)
  handler:onEvent({ id = 3, initiator = h.raven })
  assert(#h.sounds == 1)
  assert(h.runtime.objective.carrier_id == nil, "Raven's call must not claim the extraction")
end)
test("both departure orders retain independent once-only calls and recipients", function()
  for _, raven_first in ipairs({ true, false }) do
    local h = harness()
    local first, second = h.player, h.raven
    if raven_first then
      first, second = second, first
    end
    local handler = transport_takeoff_handler(h)
    handler:onEvent({ id = 3, initiator = first })
    handler:onEvent({ id = 3, initiator = second })
    handler:onEvent({ id = 3, initiator = first })
    handler:onEvent({ id = 3, initiator = second })
    h:flush()
    assert(#h.sounds == 2 and h.sound_targets[1] == first.id and h.sound_targets[2] == second.id)
    assert(h.sounds[1] ~= h.sounds[2] and #h.errors == 0)
  end
end)
test("unrelated Blue aircraft and wrong airframe types cannot trigger either clearance", function()
  local h = harness()
  local handler = transport_takeoff_handler(h)
  h.player.name = "Unrelated-1-1"
  handler:onEvent({ id = 3, initiator = h.player })
  h.player.name, h.player.type_name = config.player_unit, "UH-60L"
  handler:onEvent({ id = 3, initiator = h.player })
  h.raven.type_name = "CH-47Fbl1"
  handler:onEvent({ id = 3, initiator = h.raven })
  handler:onEvent({ id = 3 })
  handler:onEvent({ id = 3, initiator = {} })
  assert(#h.sounds == 0 and next(h.runtime.takeoff_announced) == nil)
end)
test("unavailable support aircraft does not consume its takeoff call", function()
  local h = harness({ missing_support = true })
  transport_takeoff_handler(h):onEvent({ id = 3, initiator = h.raven })
  assert(#h.sounds == 0 and not h.runtime.takeoff_announced[config.support_unit])
end)
test("queued takeoff calls do not follow a destroyed or replaced recipient", function()
  for _, replaced in ipairs({ true, false }) do
    local h = harness()
    transport_takeoff_handler(h):onEvent({ id = 3, initiator = h.player })
    transport_takeoff_handler(h):onEvent({ id = 3, initiator = h.raven })
    if replaced then
      h.raven.id = 303
    else
      h.raven.alive = false
    end
    h:flush()
    assert(#h.sounds == 1 and #h.errors == 0)
  end
end)
test("UH-60 boarding helper reuses HVT aboard and targets all lines to Raven", function()
  local h = harness()
  h.runtime.voice:boarding_start(h.raven)
  h.runtime.voice:boarding_complete(h.raven)
  h:flush()
  assert(#h.sounds == 3)
  assert(h.sounds[1] == "Sounds/OHP/uh60-boarding-start.ogg")
  assert(h.sounds[2] == "Sounds/OHP/boarding-hvt-aboard.ogg")
  assert(h.sounds[3] == "Sounds/OHP/uh60-boarding-complete.ogg")
  for i = 1, 3 do
    assert(h.sound_targets[i] == h.raven.id)
  end
  assert(#h.notices == 2 and h.notice_targets[1] == h.raven.id and h.notice_targets[2] == h.raven.id)
  assert(h.notices[1] == "Boarding. Remain landed until all three are aboard.")
  assert(h.notices[2] == "Three personnel aboard.")
  assert(h.runtime.objective.phase == "waiting", "Audio helpers must not implement UH-60 extraction")
end)
test("non-blue or non-takeoff events stay silent", function()
  local h = harness()
  h.player.getCoalition = function()
    return 1
  end
  transport_takeoff_handler(h):onEvent({ id = 3, initiator = h.player })
  assert(#h.sounds == 0)
  h.player.getCoalition = function()
    return 2
  end
  transport_takeoff_handler(h):onEvent({ id = 4, initiator = h.player })
  assert(#h.sounds == 0)
end)
test("first human Blue takeoff snapshots either configured CAS slot and spawns one convoy", function()
  for _, slot in ipairs({ "hornet", "warthog" }) do
    local h = harness({ cas_convoy = true })
    local cas_player = slot == "hornet" and h.cas_hornet or h.cas_warthog
    h.blue_players = { h.player, cas_player }
    h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.player })
    assert(h.runtime.cas_convoy.state == "active")
    assert(h.runtime.cas_convoy.slot == cas_player.group_name)
    assert(h.cas_convoy_spawns == 1 and h.cas_convoy:IsAlive())
    assert(#h.notices == 1 and h.notices[1]:find("enemy convoy is advancing", 1, true))
    h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = cas_player })
    assert(h.cas_convoy_spawns == 1, "A later CAS takeoff must not spawn a duplicate convoy")
  end
end)
test("both CAS slots occupied at the snapshot still spawn only one convoy", function()
  local h = harness({ cas_convoy = true })
  h.blue_players = { h.player, h.cas_hornet, h.cas_warthog }
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.player })
  assert(h.runtime.cas_convoy.state == "active" and h.cas_convoy_spawns == 1)
end)
test("only the spawned CAS convoy disables dispersal without replacing its route or protecting vehicles", function()
  local h = harness({ cas_convoy = true, firefight = true, pickup_opposition = true })
  h.blue_players = { h.player, h.cas_hornet }
  assert(h.cas_convoy_template.disperse_on_attack_s == nil)
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.player })
  assert(h.cas_convoy.disperse_on_attack_s == 0, "Survivors must not automatically disperse under attack")
  assert(h.cas_convoy.assigned_task == nil and h.cas_convoy.route_target == nil, "Preserve the editor route")
  assert(h.opposition.disperse_on_attack_s == nil, "Do not change the helicopter infantry fight")
  assert(h.pickup_opposition_template.disperse_on_attack_s == nil)
  assert(h.cas_convoy_template.disperse_on_attack_s == nil, "Change the spawned group, not the template")
  assert(#(h.group_commands or {}) == 0, "Do not make the convoy invulnerable")
  h.cas_convoy.size = h.cas_convoy.size - 1 -- Simulated lead vehicle loss.
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.cas_hornet })
  assert(h.cas_convoy_spawns == 1 and h.cas_convoy:GetSize() == 5, "Casualties must not be replaced")
end)
test("the pinned MOOSE dispersal method sends zero to the DCS ground controller option", function()
  local first = assert(moose:find("function CONTROLLABLE:OptionDisperseOnAttack(", 1, true))
  local last = assert(moose:find("\nfunction CONTROLLABLE:", first + 1, true))
  local sandbox = {
    CONTROLLABLE = {},
    AI = { Option = { Ground = { id = { DISPERSE_ON_ATTACK = 987 } } } },
  }
  local chunk = assert(loadstring(moose:sub(first, last - 1)))
  setfenv(chunk, sandbox)
  chunk()
  local sent_option, sent_value
  local group = {
    F2 = function() end,
    GetDCSObject = function()
      return {}
    end,
    _GetController = function()
      return {}
    end,
    IsGround = function()
      return true
    end,
    SetOption = function(_, option, value)
      sent_option, sent_value = option, value
    end,
  }
  assert(sandbox.CONTROLLABLE.OptionDisperseOnAttack(group, 0) == group)
  assert(sent_option == 987 and sent_value == 0)
end)
test("CAS slot changes before first Blue takeoff are honored; late CAS joins do not change the decision", function()
  local h = harness({ cas_convoy = true })
  -- The pilot has switched out of CAS before the first aircraft departs.
  h.blue_players = { h.player }
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.player })
  assert(h.runtime.cas_convoy.state == "disabled" and h.cas_convoy_spawns == 0)
  -- A later slot change cannot reverse the frozen no-CAS decision.
  h.blue_players = { h.raven, h.cas_hornet }
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.raven })
  assert(h.runtime.cas_convoy.state == "disabled" and h.cas_convoy_spawns == 0)
end)
test("non-player Blue takeoff does not freeze the CAS decision", function()
  local h = harness({ cas_convoy = true })
  h.player.player_name = nil
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.player })
  assert(h.runtime.cas_convoy.state == "waiting_for_first_blue_takeoff")
  h.player.player_name = "Mule Pilot"
  h.blue_players = { h.player, h.cas_warthog }
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.player })
  assert(h.runtime.cas_convoy.state == "active" and h.cas_convoy_spawns == 1)
end)
test("CAS branch fails closed when its convoy template is absent", function()
  local h = harness()
  h.blue_players = { h.player, h.cas_hornet }
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.player })
  assert(h.runtime.cas_convoy.state == "unavailable")
  assert(h.cas_convoy_spawns == 0 and #h.errors == 0)
end)
test("either CAS role starts the convoy first and releases the authored checkpoint only after pickup", function()
  for _, role in ipairs({ "hornet", "warthog" }) do
    local h = harness({ cas_convoy = true, cas_checkpoint = true })
    local pilot = role == "hornet" and h.cas_hornet or h.cas_warthog
    h.blue_players = { pilot }
    assert(h.cas_checkpoint_spawns == 0 and h.cas_convoy_spawns == 0)
    h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = pilot })
    assert(h.cas_checkpoint_spawns == 0 and h.cas_convoy_spawns == 1)
    assert(h.runtime.cas_checkpoint.state == "waiting_for_pickup")
    assert(h.runtime.objective.phase == "waiting" and h.runtime.objective.carrier_id == nil)
    assert(#h.notices == 1 and not h.notices[1]:find("RPG infantry", 1, true))
    h:extract()
    assert(h.runtime.cas_checkpoint.state == "active" and h.cas_checkpoint:GetSize() == 8)
    assert(h.cas_checkpoint.assigned_task == nil and h.cas_checkpoint.route_target == nil, "Keep the authored patrol")
    assert(h.cas_checkpoint.disperse_on_attack_s == nil, "Do not apply the vehicle-only dispersal change")
    assert(h.runtime.objective.phase == "aboard")
    h.blue_players = { h.cas_hornet, h.cas_warthog }
    h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.player })
    assert(h.cas_checkpoint_spawns == 1 and h.cas_convoy_spawns == 1)
  end
end)
test("checkpoint stays absent without CAS at first takeoff, including after a late CAS join", function()
  local h = harness({ cas_convoy = true, cas_checkpoint = true })
  h.blue_players = { h.player }
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.player })
  assert(h.runtime.cas_checkpoint.state == "disabled")
  h.blue_players = { h.cas_hornet }
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.cas_hornet })
  h:extract()
  assert(h.cas_checkpoint_spawns == 0 and h.cas_convoy_spawns == 0)
end)
test("slot selection, AI and Red takeoff cannot launch the checkpoint", function()
  local h = harness({ cas_checkpoint = true })
  h.blue_players = { h.cas_hornet }
  h.runtime.cas_decision_handler:onEvent({ id = 15, initiator = h.cas_hornet })
  h.player.player_name = nil
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.player })
  h.raven.getCoalition = function()
    return 1
  end
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.raven })
  assert(h.runtime.cas_checkpoint.state == "waiting_for_first_blue_takeoff" and h.cas_checkpoint_spawns == 0)
end)
test("checkpoint spawns independently when the convoy template is absent", function()
  local h = harness({ cas_checkpoint = true })
  h.blue_players = { h.cas_warthog }
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.player })
  assert(h.runtime.cas_convoy.state == "unavailable")
  assert(h.cas_checkpoint_spawns == 0)
  h:extract()
  assert(h.runtime.cas_checkpoint.state == "active" and h.cas_checkpoint_spawns == 1 and #h.errors == 0)
end)
test("a checkpoint spawn failure does not prevent the convoy or retry on another takeoff", function()
  local h = harness({ cas_convoy = true, cas_checkpoint = true, checkpoint_spawn_error = true })
  h.blue_players = { h.cas_hornet }
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.player })
  assert(h.cas_checkpoint_spawns == 0 and #h.errors == 0)
  h:extract()
  assert(h.runtime.cas_checkpoint.state == "unavailable" and #h.errors == 1)
  assert(h.runtime.cas_convoy.state == "active" and h.cas_convoy_spawns == 1)
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = h.cas_hornet })
  assert(h.cas_checkpoint_spawns == 1 and h.cas_convoy_spawns == 1)
end)
local function cap_options(extra)
  local options = { cap_sam = true, cap_fighters = true, cap_hind = true, player_far = true }
  for key, value in pairs(extra or {}) do
    options[key] = value
  end
  return options
end
local function first_takeoff(h, aircraft)
  h.runtime.cas_decision_handler:onEvent({ id = 3, initiator = aircraft or h.player })
end
local TEST_PICKUP = "TEST: Simulate pickup complete (CAS stage only)"
test("both real carriers release the checkpoint once only after pinned CTLD confirms the complete party", function()
  for _, raven in ipairs({ false, true }) do
    local h = harness({ pinned = true, only_uh60 = raven, cas_convoy = true, cas_checkpoint = true })
    local unit = raven and h.raven or h.player
    unit.point = config.pickup
    h.blue_players = { h.cas_hornet, unit }
    first_takeoff(h, h.cas_hornet)
    h:command("Extract waiting personnel", unit)
    assert(h.runtime.objective.phase == "boarding" and h.cas_checkpoint_spawns == 0)
    local party = h.groups[h.runtime.objective.party_key]
    h:flush()
    assert(h.runtime.objective.phase == "aboard" and h.cas_checkpoint_spawns == 1)
    assert(h.runtime.cas_checkpoint.release_reason == "pickup_confirmed")
    assert(not h.runtime.cas_convoy.destroyed, "Convoy clearance must not become an extraction prerequisite")
    h.runtime.ctld:OnAfterTroopsExtracted("Running", "TroopsExtracted", "Running", {}, unit, party, party.name)
    h:tick()
    assert(h.cas_checkpoint_spawns == 1 and #h.errors == 0)
    local crew_complete, checkpoint
    for index, path in ipairs(h.sounds) do
      if path == "Sounds/OHP/boarding-confirm.ogg" or path == "Sounds/OHP/uh60-boarding-complete.ogg" then
        crew_complete = index
      elseif path == "Sounds/OHP/overlord-cas-checkpoint-tasking.ogg" then
        checkpoint = index
      end
    end
    assert(
      crew_complete and checkpoint and checkpoint > crew_complete,
      "Crew confirmation must precede checkpoint tasking"
    )
  end
end)
test("failed boarding never releases or briefs the checkpoint", function()
  for _, fault in ipairs({ "casualty", "takeoff" }) do
    local h = harness({ pinned = true, cas_convoy = true, cas_checkpoint = true })
    h.blue_players = { h.cas_hornet, h.player }
    first_takeoff(h, h.cas_hornet)
    h:command("Extract waiting personnel")
    assert(h.runtime.objective.phase == "boarding" and h.cas_checkpoint_spawns == 0)
    if fault == "casualty" then
      h.groups[h.runtime.objective.party_key].size = 2
    else
      h.player.airborne = true
    end
    h:tick()
    h:flush()
    assert(h.runtime.objective.phase == "failed" and h.cas_checkpoint_spawns == 0)
    for _, path in ipairs(h.sounds) do
      assert(path ~= "Sounds/OHP/overlord-cas-checkpoint-tasking.ogg")
    end
  end
end)
test("convoy destruction alone does not release the checkpoint before pickup", function()
  local h = harness({ cas_convoy = true, cas_checkpoint = true })
  h.blue_players = { h.cas_hornet }
  first_takeoff(h, h.cas_hornet)
  h.cas_convoy.size = 0
  h:tick()
  h:flush()
  assert(h.runtime.cas_convoy.destroyed and h.cas_checkpoint_spawns == 0)
  assert(h.runtime.cas_checkpoint.state == "waiting_for_pickup")
end)
test("solo F10 pickup simulation releases only the checkpoint, without faking cargo, carrier or success", function()
  for _, pilot_name in ipairs({ "cas_hornet", "cas_warthog" }) do
    local h = harness({ cas_convoy = true, cas_checkpoint = true, cas_test_menus = true, player_far = true })
    local pilot = h[pilot_name]
    h.blue_players = { pilot }
    first_takeoff(h, pilot)
    h:command(TEST_PICKUP, pilot)
    h:flush()
    assert(h.cas_checkpoint_spawns == 1 and h.runtime.cas_checkpoint.release_reason == "solo_test")
    assert(h.runtime.objective.phase == "waiting" and h.runtime.objective.carrier_id == nil)
    assert(h.runtime.carrier_name == nil and next(h.runtime.ctld.Loaded_Cargo) == nil)
    assert(h.groups[h.runtime.objective.party_key]:GetSize() == 3)
    h:command(TEST_PICKUP, pilot)
    assert(h.cas_checkpoint_spawns == 1 and #h.errors == 0)
    local checkpoint_calls = 0
    for _, path in ipairs(h.sounds) do
      if path == "Sounds/OHP/overlord-cas-checkpoint-tasking.ogg" then
        checkpoint_calls = checkpoint_calls + 1
      end
      assert(path ~= "Sounds/OHP/hidden-passage-success.ogg" and not path:find("/boarding-", 1, true))
    end
    assert(checkpoint_calls == 1)
    h:extract() -- A later real extraction still works and cannot duplicate the test stage.
    h:flush()
    assert(h.runtime.objective.phase == "aboard" and h.cas_checkpoint_spawns == 1)
  end
end)
test("temporary F10 bypass cannot change a pre-takeoff or frozen no-CAS decision", function()
  local h = harness({ cas_convoy = true, cas_checkpoint = true, cas_test_menus = true })
  h.blue_players = { h.cas_hornet }
  h:command(TEST_PICKUP, h.cas_hornet)
  assert(h.cas_checkpoint_spawns == 0 and not h.runtime.package_decided)
  h.blue_players = { h.player }
  first_takeoff(h)
  h.blue_players = { h.cas_hornet }
  h:command(TEST_PICKUP, h.cas_hornet)
  assert(h.cas_checkpoint_spawns == 0 and h.runtime.cas_checkpoint.state == "disabled")
end)
test("temporary F10 bypass rejects multiplayer, wrong CAS group, unreadable roster and terminal missions", function()
  local options = { cas_convoy = true, cas_checkpoint = true, cas_test_menus = true }
  local h = harness(options)
  h.blue_players = { h.cas_hornet }
  first_takeoff(h, h.cas_hornet)
  h.blue_players = { h.cas_hornet, h.player }
  h:command(TEST_PICKUP, h.cas_hornet)
  h.blue_players = { h.cas_warthog }
  h:command(TEST_PICKUP, h.cas_hornet)
  h.blue_players = { h.cas_hornet }
  options.roster_error = true
  h:command(TEST_PICKUP, h.cas_hornet)
  options.roster_error = false
  h.runtime.objective:fail("test failure")
  h:command(TEST_PICKUP, h.cas_hornet)
  assert(h.cas_checkpoint_spawns == 0)
end)
test("temporary F10 bypass refuses in-progress boarding and can be disabled cleanly", function()
  local h = harness({ pinned = true, cas_convoy = true, cas_checkpoint = true, cas_test_menus = true })
  h.blue_players = { h.cas_hornet }
  first_takeoff(h, h.cas_hornet)
  h:command("Extract waiting personnel")
  h:command(TEST_PICKUP, h.cas_hornet)
  assert(h.runtime.objective.phase == "boarding" and h.cas_checkpoint_spawns == 0)
  h.runtime.config.cas.enable_pickup_test_menu = false
  h:tick()
  assert(next(h.runtime.cas_test_menus) == nil)
  h:command(TEST_PICKUP, h.cas_hornet) -- Simulate an already delivered stale callback.
  assert(h.cas_checkpoint_spawns == 0)
  h.runtime.config.cas.enable_pickup_test_menu = true
end)
test("either CAP role enables only the SAM at the first human Blue takeoff", function()
  for _, role in ipairs({ "hornet", "viper" }) do
    local h = harness(cap_options())
    h.blue_players = { h["cap_" .. role] }
    assert(h.runtime.cap.state == "waiting_for_first_blue_takeoff" and h.cap_spawns.sam == 0)
    first_takeoff(h)
    assert(h.runtime.cap.state == "sam_active" and h.runtime.cap.slot == h["cap_" .. role].group_name)
    assert(h.cap_spawns.sam == 1 and h.cap_spawns.fighters == 0 and h.cap_spawns.hind == 0)
    assert(h.runtime.cap.fighters.state == "waiting_for_sam" and h.runtime.cap.hind.state == "waiting_for_sam")
    assert(h.runtime.cas_convoy.state == "disabled" and h.runtime.cas_checkpoint.state == "disabled")
    assert(#h.notices == 1 and h.notices[1]:find("Destroy its tracking radar", 1, true))
    first_takeoff(h, h["cap_" .. role])
    assert(h.cap_spawns.sam == 1 and h.roster_reads == 1)
  end
end)
test("both CAP seats produce one SAM and one air response with no respawn on later takeoffs", function()
  local h = harness(cap_options())
  h.blue_players = { h.cap_hornet, h.cap_viper }
  first_takeoff(h)
  h.radars[1].life = 0
  h:cap_tick()
  assert(h.runtime.cap.state == "air_response" and h.runtime.cap.sam.state == "neutralised")
  assert(h.cap_spawns.sam == 1 and h.cap_spawns.fighters == 1 and h.cap_spawns.hind == 1)
  assert(h.cap_fighters:GetSize() == 2 and h.cap_hind:GetSize() == 1)
  assert(h.cap_sam:GetSize() == 9, "Live launchers and trucks must not delay the response")
  assert(#h.notices == 1, "Outcome texts must not bypass Overlord's pause")
  h:flush()
  assert(#h.notices == 3, "Hind tasking waits for both fighters to be destroyed")
  local observer = h.runtime.cap.observer
  for _ = 1, 3 do
    h:cap_tick()
    first_takeoff(h, h.cap_viper)
  end
  assert(h.runtime.cap.observer == observer, "Do not re-arm the watch after radar destruction")
  assert(h.cap_spawns.sam == 1 and h.cap_spawns.fighters == 1 and h.cap_spawns.hind == 1)
  h.cap_fighters.size, h.cap_hind.size = 0, 0
  first_takeoff(h)
  assert(h.cap_spawns.fighters == 1 and h.cap_spawns.hind == 1, "Never replace aircraft losses")
end)
test("SAM damage, radar silence and support-vehicle losses do not release the air response", function()
  local h = harness(cap_options())
  h.blue_players = { h.cap_hornet }
  first_takeoff(h)
  local previous = h.runtime.cap.observer
  h.radars[1].life, h.radars[1].emitting = 1, false
  h.cap_sam.size = 1 -- Only the tracking radar remains.
  h:cap_tick()
  assert(h.runtime.cap.state == "sam_active" and h.cap_spawns.fighters == 0 and h.cap_spawns.hind == 0)
  assert(h.runtime.cap.observer ~= previous, "An intact radar needs another observation")
  h.radars[1].life = 0.5 -- DCS considers life < 1 destroyed, even before wreck removal.
  h:cap_tick()
  assert(h.cap_spawns.fighters == 1 and h.cap_spawns.hind == 1)
end)
test("a despawned radar wrapper also releases the response without querying a stale life object", function()
  local h = harness(cap_options())
  h.blue_players = { h.cap_viper }
  first_takeoff(h)
  h.radars[1].alive = false
  h.radars[1].GetLife = function()
    error("Removed unit must not be queried")
  end
  h:cap_tick()
  assert(h.cap_spawns.fighters == 1 and h.cap_spawns.hind == 1 and #h.errors == 0)
end)
test("all tracked radars must be destroyed when the SAM template contains more than one", function()
  local h = harness(cap_options({ cap_radar_count = 2 }))
  h.blue_players = { h.cap_hornet }
  first_takeoff(h)
  assert(#h.runtime.cap.radars == 2)
  h.radars[1].life = 0
  h:cap_tick()
  assert(h.cap_spawns.fighters == 0 and h.cap_spawns.hind == 0)
  h.radars[2].life = 0
  h:cap_tick()
  assert(h.cap_spawns.fighters == 1 and h.cap_spawns.hind == 1)
end)
test("no CAP at the snapshot leaves every CAP threat inactive even after a late join", function()
  local h = harness(cap_options())
  h.blue_players = { h.player }
  first_takeoff(h)
  h.blue_players = { h.cap_hornet }
  first_takeoff(h, h.cap_hornet)
  assert(h.runtime.cap.state == "disabled" and h.runtime.cap.sam.state == "disabled")
  assert(h.runtime.cap.fighters.state == "disabled" and h.runtime.cap.hind.state == "disabled")
  assert(h.cap_spawns.sam == 0 and h.cap_spawns.fighters == 0 and h.cap_spawns.hind == 0)
  assert(h.runtime.cap.observer == nil and h.roster_reads == 1)
end)
test(
  "CAP slot switching before takeoff is honored and the departing CAP pilot counts even if absent from roster",
  function()
    local h = harness(cap_options())
    h.blue_players = { h.cap_hornet }
    h.runtime.cas_decision_handler:onEvent({ id = 15, initiator = h.cap_hornet })
    h.blue_players = { h.player }
    first_takeoff(h)
    assert(h.cap_spawns.sam == 0)
    h = harness(cap_options())
    h.blue_players = {}
    first_takeoff(h, h.cap_viper)
    assert(h.cap_spawns.sam == 1 and h.runtime.cap.slot == "CAP-Viper")
  end
)
test("wrong type, empty CAP seat, AI, Red and malformed events cannot enable CAP", function()
  local h = harness(cap_options())
  h.blue_players = { h.cap_hornet }
  for _, event in ipairs({ {}, { id = 3 }, { id = 15, initiator = h.cap_hornet } }) do
    h.runtime.cas_decision_handler:onEvent(event)
  end
  h.cap_hornet.player_name = ""
  first_takeoff(h, h.cap_hornet)
  h.cap_hornet.player_name = "CAP Pilot"
  h.cap_hornet.getCoalition = function()
    return 1
  end
  first_takeoff(h, h.cap_hornet)
  assert(not h.runtime.package_decided and h.cap_spawns.sam == 0)
  h.blue_players = { h.cap_viper }
  h.cap_viper.type_name = "F-5E-3"
  first_takeoff(h)
  assert(h.runtime.cap.state == "disabled")
end)
test("CAS and CAP share exactly one frozen roster and both CAS ground threats remain operational", function()
  local h = harness(cap_options({ cas_convoy = true, cas_checkpoint = true }))
  h.blue_players = { h.cas_warthog, h.cap_viper }
  first_takeoff(h)
  assert(
    h.roster_reads == 1 and h.runtime.package_slots.cas == "CAS-Warthog" and h.runtime.package_slots.cap == "CAP-Viper"
  )
  assert(h.cas_convoy_spawns == 1 and h.cas_checkpoint_spawns == 0 and h.cap_spawns.sam == 1)
  h.blue_players = {}
  h.radars[1].life = 0
  h:cap_tick()
  assert(h.cap_spawns.fighters == 1 and h.cap_spawns.hind == 1, "Slot departure does not undo the frozen decision")
  assert(h.cas_convoy_spawns == 1 and h.cas_checkpoint_spawns == 0 and h.cas_convoy.disperse_on_attack_s == 0)
  assert(h.runtime.objective.phase == "waiting", "CAP must not introduce an extraction gate")
  h:extract()
  assert(h.cas_checkpoint_spawns == 1, "Frozen CAS eligibility survives its pilot leaving")
end)
test("missing CAS templates cannot prevent the independently selected CAP branch", function()
  local h = harness(cap_options())
  h.blue_players = { h.cas_hornet, h.cap_hornet }
  first_takeoff(h)
  assert(h.runtime.cas_convoy.state == "unavailable" and h.runtime.cas_checkpoint.state == "waiting_for_pickup")
  assert(h.runtime.cap.state == "sam_active" and h.cap_spawns.sam == 1)
  h.radars[1].life = 0
  h:cap_tick()
  assert(h.cap_spawns.fighters == 1 and h.cap_spawns.hind == 1)
end)
test("CAS-only participation leaves CAP threats inactive", function()
  local h = harness(cap_options({ cas_convoy = true, cas_checkpoint = true }))
  h.blue_players = { h.cas_hornet }
  first_takeoff(h)
  assert(h.cas_convoy_spawns == 1 and h.cas_checkpoint_spawns == 0)
  assert(h.runtime.cap.state == "disabled" and h.cap_spawns.sam == 0)
end)
test("unreadable or invalid roster fails both branches closed and never retries the snapshot", function()
  for _, fault in ipairs({ "roster_error", "roster_invalid" }) do
    local options = cap_options({ cas_convoy = true, cas_checkpoint = true })
    options[fault] = true
    local h = harness(options)
    h.blue_players = { h.cap_hornet, h.cas_hornet }
    first_takeoff(h)
    first_takeoff(h, h.cap_hornet)
    assert(h.roster_reads == 1 and h.runtime.cap.state == "unavailable" and h.runtime.cas_convoy.state == "unavailable")
    assert(h.cas_convoy_spawns == 0 and h.cas_checkpoint_spawns == 0 and h.cap_spawns.sam == 0)
  end
end)
test("missing or failed SAM holds aircraft back without blocking the CAS branch", function()
  for _, fault in ipairs({ "missing", "cap_sam_spawn_error", "cap_sam_spawn_nil", "cap_sam_spawn_dead" }) do
    local options = cap_options({ cas_convoy = true, cas_checkpoint = true })
    if fault == "missing" then
      options.cap_sam = false
    else
      options[fault] = true
    end
    local h = harness(options)
    h.blue_players = { h.cap_hornet, h.cas_hornet }
    first_takeoff(h)
    assert(h.runtime.cap.state == "unavailable" and h.runtime.cap.observer == nil)
    assert(h.cap_spawns.fighters == 0 and h.cap_spawns.hind == 0)
    assert(h.cas_convoy_spawns == 1 and h.cas_checkpoint_spawns == 0)
  end
end)
test("missing radar or unavailable SAM units cannot falsely release the air response", function()
  for _, extra in ipairs({ { cap_radar_count = 0 }, { cap_units_unavailable = true } }) do
    local h = harness(cap_options(extra))
    h.blue_players = { h.cap_viper }
    first_takeoff(h)
    assert(h.runtime.cap.state == "unavailable" and h.runtime.cap.observer == nil and #h.errors == 1)
    assert(h.cap_spawns.fighters == 0 and h.cap_spawns.hind == 0)
  end
end)
test("a transient radar API error fails closed, logs once per episode and recovers", function()
  local h = harness(cap_options())
  h.blue_players = { h.cap_hornet }
  first_takeoff(h)
  h.radar_observation_error = true
  h:cap_tick()
  h:cap_tick()
  assert(#h.errors == 1 and h.runtime.cap.state == "sam_active" and h.cap_spawns.fighters == 0)
  h.radar_observation_error = false
  h.radars[1].life = 0
  h:cap_tick()
  assert(h.cap_spawns.fighters == 1 and h.cap_spawns.hind == 1)
end)
test("either air template can fail independently and never be retried", function()
  for _, role in ipairs({ "fighters", "hind" }) do
    for _, fault in ipairs({ "missing", "spawn_error", "spawn_nil", "spawn_dead" }) do
      local options = cap_options()
      if fault == "missing" then
        options["cap_" .. role] = false
      else
        options["cap_" .. role .. "_" .. fault] = true
      end
      local h = harness(options)
      h.blue_players = { h.cap_viper }
      first_takeoff(h)
      h.radars[1].life = 0
      h:cap_tick()
      local other = role == "fighters" and "hind" or "fighters"
      if fault == "spawn_dead" then
        assert(h.runtime.cap[role].state == "spawning", "Do not reject an asynchronous aircraft birth")
        h:advance(config.cap.spawn_ready_timeout_s)
        h.runtime.cap[role].readiness_timer.run()
      end
      assert(h.runtime.cap[role].state == "unavailable" and h.runtime.cap[other].state == "active")
      assert(h.cap_spawns[other] == 1)
      local attempts = h.cap_spawns[role]
      h:cap_tick()
      first_takeoff(h)
      assert(h.cap_spawns[role] == attempts and h.cap_spawns[other] == 1)
    end
  end
end)
test("CAP keeps authored tasks, skills, dispersal and vulnerability unchanged", function()
  local h = harness(cap_options())
  h.blue_players = { h.cap_hornet }
  first_takeoff(h)
  h.radars[1].life = 0
  h:cap_tick()
  for _, g in ipairs({ h.cap_sam, h.cap_fighters, h.cap_hind }) do
    assert(g.assigned_task == nil and g.route_target == nil and g.disperse_on_attack_s == nil)
  end
  assert(#(h.group_commands or {}) == 0, "Do not add immortality or forced AI commands")
end)
test("pinned MOOSE radar wrappers distinguish live, cooking-off and removed DCS units", function()
  local sandbox = { UNIT = {} }
  for _, name in ipairs({ "IsAlive", "GetLife" }) do
    local first = assert(moose:find("function UNIT:" .. name .. "(", 1, true))
    local last = assert(moose:find("\nfunction UNIT:", first + 1, true))
    local chunk = assert(loadstring(moose:sub(first, last - 1)))
    setfenv(chunk, sandbox)
    chunk()
  end
  local exists, active, life = true, true, 100
  local dcs = {
    isExist = function()
      return exists
    end,
    isActive = function()
      return active
    end,
    getLife = function()
      return life
    end,
  }
  local wrapper = {
    GetDCSObject = function()
      return exists and dcs or nil
    end,
  }
  assert(sandbox.UNIT.IsAlive(wrapper) and sandbox.UNIT.GetLife(wrapper) == 100)
  life = 0
  assert(
    sandbox.UNIT.IsAlive(wrapper) and sandbox.UNIT.GetLife(wrapper) == 0,
    "A retained wreck can still appear active"
  )
  exists = false
  assert(not sandbox.UNIT.IsAlive(wrapper) and sandbox.UNIT.GetLife(wrapper) == -1)
end)
test(
  "pinned MOOSE spawning changes only approved fighter departure while preserving airborne routes and payloads",
  function()
    local function copy(value)
      if type(value) ~= "table" then
        return value
      end
      local result = {}
      for key, item in pairs(value) do
        result[key] = copy(item)
      end
      return result
    end
    local function equal(a, b)
      if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
      end
      for key, item in pairs(a) do
        if not equal(item, b[key]) then
          return false
        end
      end
      for key in pairs(b) do
        if a[key] == nil then
          return false
        end
      end
      return true
    end
    local templates = {}
    for _, country in pairs(archive_mission and archive_mission.coalition.red.country or {}) do
      for _, category in ipairs({ "plane", "helicopter" }) do
        for _, g in pairs(country[category] and country[category].group or {}) do
          if g.name == config.cap.fighters_template or g.name == config.cap.hind_template then
            templates[#templates + 1] = g
          end
        end
      end
    end
    if #templates == 0 then
      templates = {
        {
          name = "pin-aircraft",
          groupId = 44,
          lateActivation = true,
          x = 10,
          y = 20,
          units = {
            {
              name = "pin-unit",
              unitId = 45,
              type = "Mi-24V",
              skill = "High",
              parking = 4,
              payload = { pylons = { { CLSID = "test-rocket" } }, fuel = 100 },
            },
          },
          route = {
            points = {
              {
                type = "TakeOffParkingHot",
                action = "From Parking Area Hot",
                airdromeId = 3,
                x = 10,
                y = 20,
                alt = 50,
              },
              { type = "Turning Point", x = 1000, y = 2000, task = { id = "ComboTask", params = { tasks = {} } } },
            },
          },
        },
      }
      local fighter = copy(templates[1])
      fighter.name = config.cap.fighters_template
      fighter.units[1].type = "MiG-29 Fulcrum"
      fighter.units[1].x, fighter.units[1].y = 10, 20
      fighter.units[2] = copy(fighter.units[1])
      fighter.units[2].name, fighter.units[2].unitId = "pin-wingman", 46
      fighter.units[2].x, fighter.units[2].y = 12, 22
      templates[#templates + 1] = fighter
    end
    local sandbox = {
      SPAWN = { Takeoff = { Air = 1, Runway = 2, Hot = 3 } },
      GROUP = { Takeoff = { Air = 1 } },
      GROUPTEMPLATE = { Takeoff = { [2] = { "TakeOff", "From Runway" } } },
      Airbase = { Category = { SHIP = 2, HELIPAD = 1 } },
      AIRBASE = { TerminalType = { Runway = 16 } },
      table = table,
      Group = { Category = { GROUND = 2 } },
      string = string,
      pairs = pairs,
      ipairs = ipairs,
      math = math,
      type = type,
      tostring = tostring,
      COORDINATE = {
        New = function()
          return {}
        end,
      },
      EVENTS = { Birth = 1, Crash = 2, UnitLost = 3, RemoveUnit = 4 },
    }
    for _, name in ipairs({ "_Prepare", "Spawn", "SpawnWithIndex", "SpawnAtAirbase" }) do
      local first = assert(moose:find("function SPAWN:" .. name .. "(", 1, true))
      local last = assert(moose:find("\nfunction SPAWN:", first + 1, true))
      local chunk = assert(loadstring(moose:sub(first, last - 1)))
      setfenv(chunk, sandbox)
      chunk()
    end
    for _, authored in ipairs(templates) do
      local original = copy(authored)
      local self = setmetatable({
        SpawnInitKeepUnitNames = false,
        SpawnTemplatePrefix = authored.name,
        SpawnIndex = 0,
        AIOnOff = true,
        _GetTemplate = function()
          return copy(authored)
        end,
        SpawnGroupName = function()
          return authored.name .. "#001"
        end,
        T3 = function() end,
        HandleEvent = function() end,
        _GetSpawnIndex = function(self, index)
          self.SpawnIndex = index
          return true
        end,
      }, { __index = sandbox.SPAWN })
      local prepared = self:_Prepare(authored.name, 1)
      self.SpawnGroups = { { SpawnTemplate = prepared } }
      local sent
      local wrapper = {
        SetAIOnOff = function(_, value)
          assert(value == true)
        end,
      }
      sandbox._DATABASE = {
        Spawn = function(_, template)
          sent = template
          return wrapper
        end,
      }
      local runway = authored.name == config.cap.fighters_template and config.cap.fighters_runway_start
      if runway then
        local unit = {
          HasAttribute = function()
            return false
          end,
        }
        sandbox.GROUP.FindByName = function(_, name)
          assert(name == authored.name)
          return {
            GetUnit = function()
              return unit
            end,
            HasAttribute = function(_, attribute)
              return attribute == "Fighters"
            end,
          }
        end
        local first = original.route.points[1]
        local airbase = {
          isAirdrome = true,
          GetCoordinate = function()
            return { x = 110, z = 220, y = 50 }
          end,
          GetID = function()
            return first.airdromeId
          end,
          GetAirbaseCategory = function()
            return 0
          end,
          FindFreeParkingSpotForAircraft = function(_, _, terminal, _, _, _, _, _, nunits)
            assert(terminal == sandbox.AIRBASE.TerminalType.Runway and nunits == #original.units)
            local spots = {}
            for i = 1, nunits do
              spots[i] = { Coordinate = { x = 110 + i * 20, z = 220, y = 50 }, TerminalID = 900 + i }
            end
            return spots
          end,
        }
        assert(self:SpawnAtAirbase(airbase, sandbox.SPAWN.Takeoff.Runway, nil, nil, false) == wrapper)
      else
        assert(self:Spawn() == wrapper)
      end
      assert(sent == prepared)
      assert(sent.lateActivation == false and sent.groupId == nil)
      local expected_route = copy(original.route)
      if runway then
        assert(sent.route.points[1].type == "TakeOff" and sent.route.points[1].action == "From Runway")
        assert(sent.route.points[1].airdromeId == original.route.points[1].airdromeId)
        for _, field in ipairs({ "type", "action", "x", "y", "alt" }) do
          expected_route.points[1][field] = sent.route.points[1][field]
        end
      else
        assert(sent.x == original.x and sent.y == original.y)
      end
      assert(equal(sent.route, expected_route), "Preserve airborne waypoints, departure tasks and airfield")
      for i, unit in ipairs(sent.units) do
        local expected = original.units[i]
        assert(equal(unit.payload, expected.payload) and unit.skill == expected.skill and unit.type == expected.type)
        if runway then
          assert(unit.parking == 900 + i and unit.parking_id == nil)
        else
          assert(unit.parking == expected.parking and unit.parking_id == expected.parking_id)
          assert(unit.x == expected.x and unit.y == expected.y)
        end
      end
      assert(equal(authored, original), "Leave the dormant editor template untouched")
    end
  end
)
local function outbound_position(unit, fraction, sideways)
  unit.point = {
    x = config.receiving.x + fraction * (config.pickup.x - config.receiving.x) + (sideways or 0),
    y = config.receiving.y + fraction * (config.pickup.y - config.receiving.y),
  }
end
local route_length_m =
  math.sqrt((config.pickup.x - config.receiving.x) ^ 2 + (config.pickup.y - config.receiving.y) ^ 2)
local function outbound_position_remaining(unit, remaining_m)
  outbound_position(unit, (route_length_m - remaining_m) / route_length_m)
end
local function depart(h, unit)
  outbound_position(unit, 0)
  unit.airborne = true
  transport_takeoff_handler(h):onEvent({ id = 3, initiator = unit })
end
local function warning_count(h)
  local count = 0
  for _, sound in ipairs(h.sounds) do
    if sound == "Sounds/OHP/mule-one-hvt-under-fire.ogg" then
      count = count + 1
    end
  end
  return count
end
local function approach_firefight(h)
  depart(h, h.player)
  outbound_position_remaining(h.player, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 + 1)
  h.runtime.hvt_under_fire_observer.run()
  assert(h.runtime.firefight.state == "staged")
  outbound_position_remaining(h.player, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 - 1)
  h.runtime.hvt_under_fire_observer.run()
  assert(h.runtime.firefight.state == "approaching")
end
local function start_firefight(h, distance_m)
  distance_m = distance_m or config.firefight.fire_start_distance_m - 1
  local scale = distance_m / math.sqrt(2)
  h.opposition.point = {
    x = config.personnel.x + scale,
    y = config.personnel.y - scale,
  }
  h:tick()
end
test("either helicopter crossing the configured pre-pickup point broadcasts once to Blue", function()
  for _, raven_first in ipairs({ true, false }) do
    local h = harness()
    depart(h, h.player)
    depart(h, h.raven)
    local first, second = h.player, h.raven
    if raven_first then
      first, second = second, first
    end
    outbound_position_remaining(first, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 + 1)
    h.runtime.hvt_under_fire_observer.run()
    assert(not h.runtime.hvt_under_fire_announced)
    outbound_position_remaining(first, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 - 1)
    h.runtime.hvt_under_fire_observer.run()
    assert(h.runtime.hvt_under_fire_announced == first.name)
    outbound_position_remaining(second, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 - 1)
    h.runtime.hvt_under_fire_observer.run()
    outbound_position_remaining(first, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 + 1000)
    h.runtime.hvt_under_fire_observer.run()
    h:flush()
    assert(warning_count(h) == 1 and #h.errors == 0)
    for i, path in ipairs(h.sounds) do
      if path == "Sounds/OHP/mule-one-hvt-under-fire.ogg" then
        assert(h.sound_targets[i] == "coalition")
      end
    end
    assert(h.notice_targets[#h.notices] == "coalition")
  end
end)
test("long routes use 3 NM while the short Testing route retains its halfway trigger", function()
  local h = harness()
  local route_nm = route_length_m / 1852
  local expected_nm = route_nm > config.firefight.start_distance_from_pickup_nm * 2
      and config.firefight.start_distance_from_pickup_nm
    or route_nm / 2
  assert(math.abs(h.runtime.hvt_under_fire_trigger_distance_nm - expected_nm) < 0.001)
end)
test("Enemies stage at mission start, move at the pre-pickup trigger, then enter firing range", function()
  local h = harness({ firefight = true })
  local party = h.groups[h.runtime.objective.party_key]
  local fight = h.runtime.firefight
  assert(fight.state == "staged" and h.opposition_spawns == 1)
  assert(
    party.roe == "hold" and party.assigned_task.id == "Hold",
    "HVTs must not fire before the configured contact trigger"
  )
  assert(h.opposition.roe == "hold")
  assert(h.opposition:IsAlive() and h.opposition.assigned_task.id == "Hold")
  local staged_distance =
    math.sqrt((h.opposition:GetVec2().x - party:GetVec2().x) ^ 2 + (h.opposition:GetVec2().y - party:GetVec2().y) ^ 2)
  assert(staged_distance > 0)
  h:tick()
  assert(fight.state == "staged", "Even a nearby staged group must wait for the inbound trigger")

  approach_firefight(h)
  assert(h.opposition.route_target.x == fight.fire_position.x and h.opposition.route_target.y == fight.fire_position.y)
  assert(h.opposition.route_speed == config.firefight.approach_speed_mps)
  assert(h.opposition.roe == "hold", "Enemies must not fire before reaching the exchange range")
  start_firefight(h, config.firefight.fire_start_distance_m + 1)
  assert(fight.state == "approaching", "The exchange must wait until the enemy reaches firing range")
  start_firefight(h)
  h:tick()
  assert(fight.state == "active")
  assert(h.opposition:IsAlive() and h.opposition.assigned_task.id == "FireAtPoint")
  assert(h.opposition.roe == "open")
  assert(party.assigned_task.id == "FireAtPoint")
  assert(party.roe == "open")
  assert(party.assigned_task.point.x == h.opposition:GetVec2().x)
  assert(h.group_commands[1].group == party)
  assert(h.group_commands[1].command.id == "SetImmortal" and h.group_commands[1].command.params.value)
  for _, command in ipairs(h.group_commands) do
    assert(command.group ~= h.opposition, "Enemy must not be made immortal")
  end
  assert(h.opposition.assigned_task.radius == config.firefight.fire_radius_m)
  assert(h.runtime.firefight.started_at == h.now)

  h.now = h.runtime.firefight.started_at + config.firefight.hvt_return_fire_duration_s
  h:tick()
  assert(party.assigned_task.id == "Hold", "HVT return fire must end after its brief opening burst")
  assert(party.roe == "hold")
  assert(h.runtime.firefight.state == "active" and h.opposition:IsAlive())
  assert(h.group_commands[#h.group_commands].group == party)
  assert(h.group_commands[#h.group_commands].command.params.value, "HVTs must remain protected after they stop firing")
end)
test("live-run infantry stalled outside 300 m now start contact without needing to close further", function()
  local h = harness({ firefight = true })
  approach_firefight(h)
  h.opposition.point = { x = config.personnel.x + 166.83, y = config.personnel.y - 313.66 } -- Live lead offset.
  h:tick()
  h:flush()
  assert(h.runtime.firefight.state == "active" and h.opposition.roe == "open")
  local calls = 0
  for _, path in ipairs(h.sounds) do
    if path == "Sounds/OHP/hvt-taking-fire.ogg" then
      calls = calls + 1
    end
  end
  assert(calls == 1 and #h.errors == 0)
end)
test("nearest surviving soldier starts contact even if the group leader remains outside 400 m", function()
  local h = harness({ firefight = true })
  approach_firefight(h)
  local function soldier(distance, life)
    return {
      GetLife = function()
        return life
      end,
      GetVec2 = function()
        return { x = config.personnel.x + distance, y = config.personnel.y }
      end,
    }
  end
  h.opposition.point = { x = config.personnel.x + 450, y = config.personnel.y }
  h.opposition.units_override = { soldier(450, 100), soldier(200, 0), soldier(100, -1) }
  h:tick()
  assert(h.runtime.firefight.state == "approaching", "Dead/missing soldiers must not trigger contact")
  h.opposition.units_override[4] = soldier(400, 100)
  h:tick()
  assert(h.runtime.firefight.state == "active")
  h:tick()
  assert(h.runtime.firefight.started_at == h.now and #h.errors == 0)
end)
test("The auto-suffixed primary template is selected with its full editor unit count", function()
  local h = harness({ firefight = true, firefight_alias = true, firefight_unit_count = 8 })
  assert(h.runtime.firefight.state == "staged")
  assert(h.opposition_spawns == 1 and h.opposition:IsAlive() and h.opposition:GetSize() == 8)
  assert(h.runtime.firefight.enemy_group == h.opposition)
end)
test("The concealed reinforcement spawns and moves when boarding begins, then holds when aboard", function()
  local h = harness({ firefight = true, pickup_opposition = true })
  local party = h.groups[h.runtime.objective.party_key]
  local target = { x = party.point.x, y = party.point.y }
  assert(h.runtime.pickup_opposition.state == "staged" and h.pickup_opposition_spawns == 0)

  approach_firefight(h)
  assert(h.pickup_opposition_spawns == 0, "The pickup group must not spawn at the outbound contact point")

  h.player.point = config.pickup
  h.player.airborne = false
  h:extract()
  assert(
    h.runtime.objective.phase == "aboard",
    "phase=" .. tostring(h.runtime.objective.phase) .. " reason=" .. tostring(h.runtime.objective.reason)
  )
  assert(h.pickup_opposition_spawns == 1 and h.pickup_opposition:IsAlive())
  assert(h.pickup_opposition.route_target.x == target.x and h.pickup_opposition.route_target.y == target.y)
  assert(h.pickup_opposition.route_speed == config.firefight.approach_speed_mps)
  assert(h.runtime.pickup_opposition.state == "stopped")
  assert(h.pickup_opposition.assigned_task.id == "Hold" and h.pickup_opposition.roe == "hold")
  h:extract()
  assert(h.pickup_opposition_spawns == 1, "The pickup trigger must be one-shot")
  assert(#h.errors == 0)
end)
test("Testing firefight stops when the party is confirmed aboard", function()
  local h = harness({ firefight = true })
  local party = h.groups[h.runtime.objective.party_key]
  approach_firefight(h)
  start_firefight(h)
  h.player.point = config.pickup
  h.player.airborne = false
  assert(h.runtime.firefight.state == "active")
  h:extract()
  assert(h.runtime.objective.phase == "aboard")
  assert(h.runtime.firefight.state == "stopped")
  assert(h.opposition.assigned_task.id == "Hold")
  assert(h.opposition.roe == "hold")
  assert(party.roe == "hold")
  assert(h.group_commands[#h.group_commands].group == party)
  assert(h.group_commands[#h.group_commands].command.params.value == false, "HVT protection must end with the exchange")
end)
test("Testing firefight has a ten-minute hard cap and stops if the enemies are killed", function()
  local timed = harness({ firefight = true })
  approach_firefight(timed)
  start_firefight(timed)
  timed.player.point = config.pickup
  timed.now = timed.runtime.firefight.started_at + config.firefight.maximum_duration_s
  timed:tick()
  assert(timed.runtime.firefight.state == "stopped")
  assert(timed.opposition.assigned_task.id == "Hold")

  local killed = harness({ firefight = true })
  approach_firefight(killed)
  start_firefight(killed)
  killed.player.point = config.pickup
  killed.opposition.size = 0 -- Simulate the helicopter gunner killing the entire group.
  killed:tick()
  assert(killed.runtime.firefight.state == "stopped")
  assert(killed.groups[killed.runtime.objective.party_key].assigned_task.id == "Hold")
end)
test("Raven alone can trigger contact without Chinook occupancy or objective ownership", function()
  local h = harness({ only_uh60 = true })
  depart(h, h.raven)
  outbound_position_remaining(h.raven, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 - 1)
  h.runtime.hvt_under_fire_observer.run()
  h:flush()
  assert(warning_count(h) == 1 and h.runtime.objective.carrier_id == nil)
end)
test("contact requires a recognized departure, not merely appearing near the LZ", function()
  local h = harness()
  h.player.airborne = true
  outbound_position_remaining(h.player, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 - 1)
  h.runtime.hvt_under_fire_observer.run()
  assert(not h.runtime.hvt_under_fire_announced and warning_count(h) == 0)
end)
test("detours and flying away cannot count as contact progress", function()
  local h = harness()
  depart(h, h.player)
  outbound_position(h.player, -0.8)
  h.runtime.hvt_under_fire_observer.run()
  outbound_position(h.player, 0.5, 100000)
  h.runtime.hvt_under_fire_observer.run()
  assert(not h.runtime.hvt_under_fire_announced)
  outbound_position_remaining(h.player, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 - 1)
  h.runtime.hvt_under_fire_observer.run()
  h:flush()
  assert(warning_count(h) == 1)
end)
test("ground movement across contact does not trigger a radio call", function()
  local h = harness()
  depart(h, h.player)
  h.player.airborne = false
  outbound_position_remaining(h.player, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 - 1)
  h.runtime.hvt_under_fire_observer.run()
  h.player.airborne = true
  outbound_position_remaining(h.player, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 - 100)
  h.runtime.hvt_under_fire_observer.run()
  assert(not h.runtime.hvt_under_fire_announced)
end)
test("pickup/return takeoffs cannot arm the contact warning", function()
  local h = harness()
  h.player.airborne = true
  outbound_position(h.player, 1)
  transport_takeoff_handler(h):onEvent({ id = 3, initiator = h.player })
  outbound_position(h.player, 0.9)
  h.runtime.hvt_under_fire_observer.run()
  outbound_position(h.player, 0.8)
  h.runtime.hvt_under_fire_observer.run()
  assert(not h.runtime.hvt_under_fire_announced)
end)
test("failed/completed/boarded/recovered parties suppress the contact warning", function()
  for _, phase in ipairs({ "failed", "complete", "boarding", "aboard", "recovered", "reserved", "lost" }) do
    local h = harness()
    depart(h, h.raven)
    if phase == "recovered" then
      h.runtime.objective.party_key = "OHP-TestParty-recovered"
    elseif phase == "reserved" then
      h.runtime.ctld.Loaded_Cargo[config.player_unit] = { Troopsloaded = 3 }
    elseif phase == "lost" then
      h.groups[h.runtime.objective.party_key].size = 2
    else
      h.runtime.objective.phase = phase
    end
    outbound_position_remaining(h.raven, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 - 1)
    h.runtime.hvt_under_fire_observer.run()
    assert(not h.runtime.hvt_under_fire_announced, phase)
  end
end)
test("dead or replaced departures cannot trigger the contact warning", function()
  for _, replaced in ipairs({ true, false }) do
    local h = harness()
    depart(h, h.raven)
    if replaced then
      h.raven.id = 303
    else
      h.raven.alive = false
    end
    outbound_position_remaining(h.raven, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 - 1)
    h.runtime.hvt_under_fire_observer.run()
    assert(not h.runtime.hvt_under_fire_announced and next(h.runtime.hvt_under_fire_departures) == nil)
  end
end)
test("wrong-location delivery and recovery", function()
  local h = harness()
  h:extract()
  h:drop(config.pickup)
  assert(h.runtime.objective.phase == "waiting")
  h:extract()
  h:drop(config.receiving)
  assert(h.runtime.objective.phase == "complete")
end)
test("hover cannot qualify as landed", function()
  local h = harness()
  h.player.airborne = true
  assert(h.runtime.ctld:IsUnitInAir(h.player))
  assert(not h.runtime.ctld:IsCorrectHover(h.player))
  assert(not h.runtime.ctld:CanHoverLoad(h.player))
end)
test("early departure during boarding fails", function()
  local h = harness()
  h:tick()
  h.runtime.ctld.Loaded_Cargo[config.player_unit] = { Troopsloaded = 3 }
  h:tick()
  assert(h.runtime.objective.phase == "boarding")
  h.player.airborne = true
  h:tick()
  assert(h.runtime.objective.phase == "failed")
  h:drop(config.receiving)
  assert(h.runtime.objective.phase == "failed")
end)
test("loss then delayed receipt cannot succeed", function()
  local h = harness()
  h:extract()
  h.player.alive = false
  h:tick()
  h.player.alive = true
  h.player.id = 102
  h:drop(config.receiving)
  assert(h.runtime.objective.phase == "failed")
end)
test("replacement before observer tick rejects late receipt", function()
  local h = harness()
  h:extract()
  h.player.id = 102
  h:drop(config.receiving)
  assert(h.runtime.objective.phase == "failed")
end)
test("partial party cannot complete", function()
  local h = harness()
  h:extract()
  h:drop(config.receiving, 2)
  assert(h.runtime.objective.phase == "failed")
end)
test("ground party loss fails", function()
  local h = harness()
  h.groups[h.runtime.objective.party_key].size = 2
  h:tick()
  assert(h.runtime.objective.phase == "failed")
end)
test("setup errors are logged and surfaced", function()
  for _, opts in ipairs({
    { water = true },
    { steep = true },
    { missing_zone = config.pickup_zone },
    { missing_zone = config.personnel_zone },
    {
      zone_points = {
        [config.personnel_zone] = { x = config.pickup.x + config.extraction_distance_m + 5, y = config.pickup.y },
      },
    },
    { zone_points = { [config.personnel_zone] = { x = config.pickup.x + 20, y = config.pickup.y } } },
  }) do
    local h = harness(opts)
    assert(not h.runtime.objective and #h.errors == 1 and #h.notices == 1)
  end
end)
test("landed and stopped Chinook automatically starts native boarding without a menu press", function()
  local h = harness({ pinned = true })
  local party = h.groups[h.runtime.objective.party_key]
  h:observe_for(1)
  assert(h.runtime.objective.phase == "waiting" and not h.boarding_due)
  h:advance(1)
  h:tick()
  assert(h.runtime.objective.phase == "boarding" and h.runtime.ctld.CargoCounter == 1)
  assert(h.sounds[1] == "Sounds/OHP/boarding-start.ogg" and h.sound_targets[1] == h.player.id)
  assert((h.menu_invocations or 0) == 0 and party:IsAlive())
  h:observe_for(5)
  assert(h.runtime.ctld.CargoCounter == 1 and #h.sounds == 1)
  h:advance(h.boarding_due - h.now)
  assert(h.runtime.objective.phase == "aboard" and not party:IsAlive())
  assert(party.disappeared_at == h.boarding_due)
  assert(h.sounds[2] == "Sounds/OHP/boarding-hvt-aboard.ogg" and #h.errors == 0)
end)
test("automatic pickup rejects hovering, moving and out-of-range aircraft", function()
  for _, mode in ipairs({ "hovering", "moving", "out-of-range" }) do
    local h = harness({ pinned = true })
    h.player.airborne = mode == "hovering"
    h.player.speed = mode == "moving" and 3 or 0
    if mode == "out-of-range" then
      h.player.point = config.receiving
    end
    h:observe_for(5)
    assert(h.runtime.objective.phase == "waiting" and not h.boarding_due, mode)
    assert(not h.runtime.auto_pickup[config.player_unit].since and #h.sounds == 0 and #h.errors == 0, mode)
  end
end)
test("airborne, motion or range interruptions restart the full settling period", function()
  for _, mode in ipairs({ "airborne", "moving", "range" }) do
    local h = harness({ pinned = true })
    h:observe_for(1)
    h.player.airborne = mode == "airborne"
    h.player.speed = mode == "moving" and 3 or 0
    if mode == "range" then
      h.player.point = config.receiving
    end
    h:observe_for(1)
    assert(not h.runtime.auto_pickup[config.player_unit].since and not h.boarding_due, mode)
    h.player.airborne, h.player.speed, h.player.point = false, 0, config.pickup
    h:observe_for(1)
    assert(h.runtime.objective.phase == "waiting", mode)
    h:advance(1)
    h:tick()
    assert(h.runtime.objective.phase == "boarding" and #h.errors == 0, mode)
  end
end)
test("too-close automatic pickup gives one crew-only warning and resumes after repositioning", function()
  local h = harness({ pinned = true })
  h.player.point = { x = config.personnel.x + 24, y = config.personnel.y }
  h:observe_for(5)
  local warnings = 0
  for i, text in ipairs(h.notices) do
    if text:find("Too close for boarding", 1, true) then
      warnings = warnings + 1
      assert(h.notice_targets[i] == h.player.id)
    end
  end
  assert(warnings == 1 and h.runtime.objective.phase == "waiting" and not h.boarding_due)
  h.player.point = { x = config.personnel.x - 60, y = config.personnel.y }
  h:observe_for(2)
  assert(h.runtime.objective.phase == "boarding" and #h.errors == 0)
end)
test("manual extraction during settling cannot duplicate automatic boarding", function()
  local h = harness({ pinned = true })
  h:observe_for(1)
  h:command("Extract waiting personnel")
  h:observe_for(5)
  assert(h.runtime.ctld.CargoCounter == 1 and h.runtime.objective.phase == "boarding")
  assert(#h.sounds == 1 and #h.errors == 0)
end)
test("off-site recovery can restart synchronized boarding automatically", function()
  local h = harness({ pinned = true })
  h:observe_for(2)
  h:flush()
  h:command("Unload personnel")
  h:flush()
  assert(h.runtime.objective.phase == "waiting")
  local party = h.groups[h.runtime.objective.party_key]
  h.player.point = { x = party.point.x - 60, y = party.point.y }
  h:observe_for(2)
  assert(h.runtime.objective.phase == "boarding" and party:IsAlive())
  h:advance(h.boarding_due - h.now)
  assert(h.runtime.objective.phase == "aboard" and not party:IsAlive() and #h.errors == 0)
end)
test("automatic pickup does not automatically unload or announce success at Hatay", function()
  local h = harness({ pinned = true })
  h:observe_for(2)
  h:flush()
  h.player.point = config.receiving
  h:observe_for(5)
  assert(h.runtime.objective.phase == "aboard" and (h.menu_invocations or 0) == 0)
  h:command("Unload personnel")
  h:flush()
  assert(h.runtime.objective.phase == "complete" and #h.errors == 0)
end)
test("terminal or injured attempts cannot auto-board", function()
  for _, mode in ipairs({ "failed", "complete", "injured" }) do
    local h = harness({ pinned = true })
    if mode == "injured" then
      h.groups[h.runtime.objective.party_key].size = 2
    else
      h.runtime.objective.phase = mode
    end
    h:observe_for(5)
    assert(not h.boarding_due and #h.errors == 0, mode)
    if mode == "complete" then
      assert(#h.sounds == 0)
    else
      assert(#h.sounds == 0, "Failure report must wait; failure itself must not")
      h:advance(config.overlord_confirmation_delay_s)
      h:tick()
      assert(#h.sounds == 1 and h.sounds[1] == "Sounds/OHP/overlord-extraction-failed.ogg")
    end
  end
end)
test("automatic pickup follows relocated runtime zones, not embedded coordinate snapshots", function()
  local pickup = { x = config.pickup.x + 10000, y = config.pickup.y - 2000 }
  local personnel =
    { x = pickup.x + config.personnel.x - config.pickup.x, y = pickup.y + config.personnel.y - config.pickup.y }
  local h =
    harness({ pinned = true, zone_points = { [config.pickup_zone] = pickup, [config.personnel_zone] = personnel } })
  h.player.point = pickup
  h:observe_for(2)
  assert(h.runtime.objective.phase == "boarding" and #h.errors == 0)
end)
test("pinned CTLD extraction/unloading drive the adapter", function()
  local h = harness({ pinned = true })
  h:tick()
  local ctld = h.runtime.ctld
  h:command("Extract waiting personnel")
  assert(ctld.Loaded_Cargo[config.player_unit].Troopsloaded == 3)
  h:tick()
  assert(h.runtime.objective.phase == "boarding")
  h:flush()
  assert(h.runtime.objective.phase == "aboard")
  h.player.point = config.receiving
  ctld:_UnloadTroops(h.player:GetGroup(), h.player)
  h:flush()
  assert(h.runtime.objective.phase == "complete" and #h.errors == 0)
end)
test("troops remain visible until boarding receipt, then disappear and takeoff is allowed", function()
  for _, distance in ipairs({ 40, 60, 100 }) do
    local h = harness({ pinned = true })
    h.player.point = { x = config.personnel.x - distance, y = config.personnel.y }
    local party = h.groups[h.runtime.objective.party_key]
    local original_destroy = party.Destroy
    h:command("Extract waiting personnel")
    assert(party.Destroy == original_destroy, "Temporary extraction hook must be restored")
    h:advance(h.boarding_due - h.now - 0.01)
    h:tick()
    assert(party:IsAlive() and party:GetSize() == 3, "No early disappearance before boarding completion")
    assert(h.runtime.objective.phase == "boarding")
    h:advance(0.01)
    assert(h.runtime.objective.phase == "aboard" and not party:IsAlive())
    assert(party.disappeared_at == h.boarding_due)
    assert(h.notices[#h.notices] == "Three personnel aboard.")
    local notices = #h.notices
    h:advance(4)
    assert(#h.notices == notices, "Routine voice lines should not create duplicate subtitles")
    h.player.airborne = true
    h:tick()
    assert(h.runtime.objective.phase == "aboard" and #h.errors == 0)
  end
end)
test("early takeoff still fails without disappearing troops or accepting a late receipt", function()
  for _, observe in ipairs({ true, false }) do
    local h = harness({ pinned = true })
    local party = h.groups[h.runtime.objective.party_key]
    h:command("Extract waiting personnel")
    h:advance(10)
    h.player.airborne = true
    if observe then
      h:tick()
    end
    h:flush()
    assert(h.runtime.objective.phase == "failed" and party:IsAlive())
    assert(not party.disappeared_at and #h.errors == 0)
  end
end)
test("casualty during boarding fails both observer and receipt checks", function()
  for _, observe in ipairs({ true, false }) do
    local h = harness({ pinned = true })
    local party = h.groups[h.runtime.objective.party_key]
    h:command("Extract waiting personnel")
    party.size = 2
    if observe then
      h:tick()
    end
    h:flush()
    assert(h.runtime.objective.phase == "failed" and party:GetSize() == 2)
    assert(h.runtime.objective.reason:find("lost personnel during boarding", 1, true))
    assert(not party.disappeared_at and #h.errors == 0)
  end
end)
test("out of range and script errors always restore the group's removal method", function()
  for _, mode in ipairs({ "out of range", "script error" }) do
    local h = harness({ pinned = true })
    local party = h.groups[h.runtime.objective.party_key]
    local original_destroy = party.Destroy
    if mode == "out of range" then
      h.player.point = config.receiving
    else
      h.runtime.ctld._ExtractTroops = function()
        error("injected native failure")
      end
    end
    h:command("Extract waiting personnel")
    assert(party.Destroy == original_destroy and party:IsAlive())
    assert(h.runtime.ctld.Loaded_Cargo[config.player_unit] == nil)
    assert(h.runtime.objective.phase == (mode == "out of range" and "waiting" or "failed"))
    assert(#h.errors == (mode == "out of range" and 0 or 1))
  end
end)
test("duplicate boarding receipt cannot fail an already aboard party", function()
  local h = harness({ pinned = true })
  local party = h.groups[h.runtime.objective.party_key]
  h:command("Extract waiting personnel")
  h:flush()
  local notices = #h.notices
  h.player.airborne = true
  h.runtime.ctld:OnAfterTroopsExtracted("Running", "TroopsExtracted", "Running", {}, h.player, party, party:GetName())
  assert(h.runtime.objective.phase == "aboard" and #h.notices == notices and #h.errors == 0)
end)
test("recovered off-site unload uses synchronized boarding again", function()
  local h = harness({ pinned = true })
  h:command("Extract waiting personnel")
  h:flush()
  h:command("Unload personnel")
  h:flush()
  assert(h.runtime.objective.phase == "waiting")
  local party = h.groups[h.runtime.objective.party_key]
  h.player.point = { x = party.point.x - 60, y = party.point.y }
  h:command("Extract waiting personnel")
  h:advance(h.boarding_due - h.now - 0.01)
  assert(party:IsAlive() and h.runtime.objective.phase == "boarding")
  h:advance(0.01)
  assert(not party:IsAlive() and h.runtime.objective.phase == "aboard")
  h.player.point = config.receiving
  h:command("Unload personnel")
  h:flush()
  assert(h.runtime.objective.phase == "complete" and #h.errors == 0)
end)
test("pinned CTLD refuses airborne extraction", function()
  local h = harness({ pinned = true })
  h.player.airborne = true
  h:tick()
  h.runtime.ctld:_ExtractTroops(h.player:GetGroup(), h.player)
  assert(h.runtime.ctld.Loaded_Cargo[config.player_unit] == nil)
  assert(h.runtime.objective.phase == "waiting")
end)
test("only four focused commands and no CTLD logistics/reset menu", function()
  local h = harness({ pinned = true })
  h:tick()
  h.runtime.ctld:_RefreshF10Menus()
  assert(#h.roots == 2 and h.roots[1] == config.title and h.roots[2] == config.title)
  local total = 0
  for name in pairs(h.commands) do
    assert(not name:lower():find("reset", 1, true))
    assert(not name:lower():find("load troops", 1, true))
    total = total + 1
  end
  assert(total == 4 and next(h.runtime.ctld.CtldUnits) == nil)
end)
test("green smoke request marks editor LZ rather than a fixed southern offset, with no range gate", function()
  local h = harness()
  h.player.point = config.receiving -- Still at Hatay, away from the pickup.
  h:command("Request green smoke")
  assert(#h.smokes == 1)
  local smoke = h.smokes[1]
  assert(math.abs(smoke.x - config.pickup.x) < 0.01 and math.abs(smoke.y - config.pickup.y) < 0.01)
end)
test("green smoke request plays Mule audio and calm HVT response before contact", function()
  local h = harness({ firefight = true })
  assert(h.runtime.firefight.state == "staged")
  local previous_notices = #h.notices
  h:command("Request green smoke")
  assert(#h.smokes == 1 and #h.sounds == 1, "HVT response must not play immediately")
  assert(h.sounds[1] == "Sounds/OHP/mule1-smoke-request.ogg")
  local minimum_response_delay = 5.3 + 0.35 + 5 -- request duration, safety tail, deliberate pause
  h:advance(minimum_response_delay - 0.01)
  assert(#h.sounds == 1, "HVT response started before the request and pause finished")
  h:advance(0.02)
  assert(
    #h.sounds == 2 and h.sound_times[2] - h.sound_times[1] >= minimum_response_delay - 0.000001,
    "HVT response did not wait through the request, safety tail, and 5-second pause"
  )
  assert(h.sounds[2] == "Sounds/OHP/popping-green-smoke-normal.ogg")
  assert(h.sound_targets[1] == h.player.id and h.sound_targets[2] == h.player.id)
  for index = previous_notices + 1, #h.notices do
    assert(not h.notices[index]:find("Requesting green smoke", 1, true))
    assert(not h.notices[index]:find("Popping green smoke", 1, true))
  end
end)
test("green smoke request uses under-fire HVT response only after the firefight starts", function()
  local h = harness({ firefight = true })
  approach_firefight(h)
  h:flush()
  start_firefight(h)
  assert(h.runtime.firefight.state == "active")
  h:flush()
  local previous_sounds = #h.sounds
  local previous_notices = #h.notices
  h:command("Request green smoke")
  local wait_for_request = 0
  while #h.sounds == previous_sounds and wait_for_request < 15 do
    h:advance(1)
    wait_for_request = wait_for_request + 1
  end
  assert(#h.sounds == previous_sounds + 1, "Queued pilot request did not play after the earlier firefight call")
  assert(h.sounds[previous_sounds + 1] == "Sounds/OHP/mule1-smoke-request.ogg")
  local minimum_response_delay = 5.3 + 0.35 + 5 -- request duration, safety tail, deliberate pause
  local remaining = h.sound_times[previous_sounds + 1] + minimum_response_delay - h.now
  assert(remaining > 0, "Test advanced beyond the expected response time")
  h:advance(remaining - 0.01)
  assert(#h.sounds == previous_sounds + 1, "Under-fire response started before the 5-second pause finished")
  h:advance(0.02)
  assert(
    #h.sounds == previous_sounds + 2
      and h.sound_times[previous_sounds + 2] - h.sound_times[previous_sounds + 1] >= minimum_response_delay - 0.000001,
    "Under-fire response did not wait through the request, safety tail, and 5-second pause"
  )
  assert(h.sounds[previous_sounds + 2] == "Sounds/OHP/popping-green-smoke-under-fire.ogg")
  assert(h.sound_targets[previous_sounds + 1] == h.player.id)
  assert(h.sound_targets[previous_sounds + 2] == h.player.id)
  assert(#h.smokes == 1)
  for index = previous_notices + 1, #h.notices do
    assert(not h.notices[index]:find("Requesting green smoke", 1, true))
    assert(not h.notices[index]:find("Popping green smoke", 1, true))
  end
end)
test("Raven smoke request uses Raven request audio and normal HVT response", function()
  local h = harness({ only_uh60 = true })
  local previous_notices = #h.notices
  h:command("Request green smoke", h.raven)
  assert(#h.sounds == 1, "HVT response must not play immediately")
  assert(h.sounds[1] == "Sounds/OHP/raven-smoke-request.ogg")
  local minimum_response_delay = 4.6 + 0.35 + 5 -- request duration, safety tail, deliberate pause
  h:advance(minimum_response_delay - 0.01)
  assert(#h.sounds == 1, "HVT response started before the request and pause finished")
  h:advance(0.02)
  assert(
    #h.sounds == 2 and h.sound_times[2] - h.sound_times[1] >= minimum_response_delay - 0.000001,
    "HVT response did not wait through the request, safety tail, and 5-second pause"
  )
  assert(h.sounds[2] == "Sounds/OHP/popping-green-smoke-normal.ogg")
  assert(h.sound_targets[1] == h.raven.id and h.sound_targets[2] == h.raven.id)
  assert(#h.smokes == 1)
  for index = previous_notices + 1, #h.notices do
    assert(not h.notices[index]:find("Requesting green smoke", 1, true))
    assert(not h.notices[index]:find("Popping green smoke", 1, true))
  end
end)
test("status and map labels use operational names and runtime distance", function()
  local h = harness()
  h:command("Instructions / status")
  local text = h.notices[#h.notices]
  local distance = math.sqrt((config.pickup.x - config.receiving.x) ^ 2 + (config.pickup.y - config.receiving.y) ^ 2)
    / 1852
  assert(text:find(string.format("%.1f NM", distance), 1, true))
  assert(text:find("125 m", 1, true) and text:find("35 m clear", 1, true))
  assert(#h.marks == 3)
  for _, mark in ipairs(h.marks) do
    assert(not mark:find("TEST", 1, true) and not mark:find("north", 1, true))
  end
  assert(h.commands["Instructions / status"] and not h.commands["Test instructions / status"])
end)
test("UH-60L-only occupancy gets its own menu without prematurely claiming the objective", function()
  local h = harness({ only_uh60 = true })
  h:tick()
  assert(h.commands["Request green smoke"] and h.runtime.objective.phase == "waiting")
  assert(h.runtime.objective.carrier_id == nil and #h.errors == 0)
end)
test("runtime zones override build coordinate snapshots for smoke and navigation distance", function()
  local moved = { x = config.pickup.x - 10000, y = config.pickup.y + 2000 }
  local people =
    { x = moved.x + config.personnel.x - config.pickup.x, y = moved.y + config.personnel.y - config.pickup.y }
  local h = harness({ zone_points = { [config.pickup_zone] = moved, [config.personnel_zone] = people } })
  h:command("Request green smoke")
  assert(h.smokes[1].x == moved.x and h.smokes[1].y == moved.y)
  local expected = math.sqrt((moved.x - config.receiving.x) ^ 2 + (moved.y - config.receiving.y) ^ 2) / 1852
  assert(math.abs(h.runtime.distance_nm - expected) < 0.001)
end)
test("off-site recovery smoke preserves editor LZ direction and separation", function()
  local h = harness()
  h:extract()
  local drop = { x = config.pickup.x + 300, y = config.pickup.y - 900 }
  h:drop(drop)
  h:command("Request green smoke")
  local smoke = h.smokes[1]
  assert(math.abs(smoke.x - (drop.x + config.pickup.x - config.personnel.x)) < 0.01)
  assert(math.abs(smoke.y - (drop.y + config.pickup.y - config.personnel.y)) < 0.01)
end)
test("focused menu uses pinned CTLD for the complete loop", function()
  local h = harness({ pinned = true })
  h:command("Extract waiting personnel")
  assert(h.runtime.objective.phase == "boarding")
  h:flush()
  assert(h.runtime.objective.phase == "aboard")
  h.player.point = config.receiving
  h:command("Unload personnel")
  h:flush()
  assert(h.runtime.objective.phase == "complete" and #h.errors == 0)
end)
test("live touchdown and widened LZ edge board through pinned CTLD in either helicopter", function()
  for _, raven in ipairs({ false, true }) do
    for _, point in ipairs({
      { x = config.personnel.x + 80.68, y = config.personnel.y + 71.13 }, -- Live touchdown offset: 107.6 m.
      { x = config.personnel.x, y = config.personnel.y + 124.9 },
    }) do
      local h = harness({ pinned = true, only_uh60 = raven })
      local unit = raven and h.raven or h.player
      unit.point = point
      h:observe_for(2)
      assert(h.runtime.objective.phase == "boarding")
      assert(h.runtime.ctld.CrateDistance * h.runtime.ctld.ExtractFactor == 125)
      h:flush()
      assert(h.runtime.objective.phase == "aboard" and #h.errors == 0)
    end
  end
end)
test("widened pickup still rejects just outside 125 m through both automatic and manual entry", function()
  for _, raven in ipairs({ false, true }) do
    local h = harness({ pinned = true, only_uh60 = raven })
    local unit = raven and h.raven or h.player
    unit.point = { x = config.personnel.x, y = config.personnel.y + 125.1 }
    h:observe_for(3)
    h:command("Extract waiting personnel", unit)
    assert(h.runtime.objective.phase == "waiting" and not h.boarding_due and #h.errors == 0)
  end
end)
test("extraction too close to any person is blocked", function()
  local h = harness({ pinned = true })
  h.player.point = { x = config.personnel.x + 24, y = config.personnel.y }
  h:command("Extract waiting personnel")
  assert(h.runtime.objective.phase == "waiting")
  assert(h.runtime.ctld.Loaded_Cargo[config.player_unit] == nil)
  assert(h.notices[#h.notices]:find("Too close", 1, true))
end)
test("airborne and rolling menu requests are refused", function()
  for _, mode in ipairs({ "airborne", "rolling" }) do
    local h = harness({ pinned = true })
    h.player.airborne = mode == "airborne"
    h.player.speed = mode == "rolling" and 3 or 0
    h:command("Extract waiting personnel")
    assert(h.runtime.ctld.Loaded_Cargo[config.player_unit] == nil)
  end
end)
test("both helicopters have independent smoke/status/transport menus", function()
  local h = harness({ pinned = true })
  local previous_notices = #h.notices
  h:command("Request green smoke", h.raven)
  assert(#h.smokes == 1 and h.sound_targets[1] == h.raven.id)
  for index = previous_notices + 1, #h.notices do
    assert(not h.notices[index]:find("Requesting green smoke", 1, true))
    assert(not h.notices[index]:find("Popping green smoke", 1, true))
  end
  h:command("Instructions / status", h.player)
  assert(h.notice_targets[#h.notices] == h.player.id)
  for _, unit in ipairs({ h.player, h.raven }) do
    local commands = h.commands_by_group[unit:GetGroup():GetName()]
    local total = 0
    for _ in pairs(commands) do
      total = total + 1
    end
    assert(total == 4 and commands["Unload personnel"] and commands["Extract waiting personnel"])
  end
  assert(not h.runtime.objective.carrier_id and not h.runtime.carrier_name)
end)
test("UH-60-only flight triggers departure, pre-pickup contact, boarding and mission success", function()
  local h = harness({ pinned = true, only_uh60 = true })
  depart(h, h.raven)
  h:observe_for(2)
  assert(not h.runtime.objective.carrier_id)
  outbound_position_remaining(h.raven, h.runtime.hvt_under_fire_trigger_distance_nm * 1852 - 1)
  h.runtime.hvt_under_fire_observer.run()
  h:flush()
  assert(h.sounds[1] == "Sounds/OHP/raven-one-cleared-for-support.ogg" and h.sound_targets[1] == h.raven.id)
  assert(h.sounds[2] == "Sounds/OHP/mule-one-hvt-under-fire.ogg" and h.sound_targets[2] == "coalition")
  h.raven.airborne, h.raven.point = false, config.pickup
  h:observe_for(2)
  h:flush()
  assert(h.sounds[3] == "Sounds/OHP/uh60-boarding-start.ogg")
  assert(h.sounds[4] == "Sounds/OHP/boarding-hvt-aboard.ogg")
  assert(h.sounds[5] == "Sounds/OHP/uh60-boarding-complete.ogg")
  assert(h.runtime.objective.phase == "aboard")
  h.raven.point = config.receiving
  h:command("Unload personnel", h.raven)
  h:flush()
  assert(h.runtime.objective.phase == "complete" and #h.sounds == 6 and #h.errors == 0)
  assert(h.sounds[6] == "Sounds/OHP/hidden-passage-success.ogg" and h.sound_targets[6] == "coalition")
end)
test("UH-60L alone completes automatic pickup and landed Hatay delivery with its own audio", function()
  local h = harness({ pinned = true, only_uh60 = true })
  h.raven.point = config.pickup
  h:observe_for(2)
  assert(h.runtime.objective.phase == "boarding" and h.runtime.carrier_name == config.support_unit)
  assert(h.runtime.objective.carrier_id == h.raven.id and not h.runtime.ctld.Loaded_Cargo[config.player_unit])
  assert(h.runtime.ctld.Loaded_Cargo[config.support_unit].Troopsloaded == 3)
  assert(h.runtime.ctld.pilotmustopendoors == false)
  assert(h.runtime.ctld.capabilities["UH-60L"].trooplimit == 20)
  assert(not h.runtime.ctld:IsHook(h.raven) and h.runtime.ctld:IsHook(h.player))
  local party = h.groups[h.runtime.objective.party_key]
  h:advance(h.boarding_due - h.now - 0.01)
  assert(party:IsAlive() and h.runtime.objective.phase == "boarding")
  h:advance(0.01)
  assert(not party:IsAlive() and h.runtime.objective.phase == "aboard")
  h:flush()
  assert(h.sounds[1] == "Sounds/OHP/uh60-boarding-start.ogg")
  assert(h.sounds[2] == "Sounds/OHP/boarding-hvt-aboard.ogg")
  assert(h.sounds[3] == "Sounds/OHP/uh60-boarding-complete.ogg")
  for i = 1, 3 do
    assert(h.sound_targets[i] == h.raven.id)
  end
  h.raven.point = config.receiving
  h:command("Unload personnel", h.raven)
  h:flush()
  assert(h.runtime.objective.phase == "complete" and #h.errors == 0)
  assert(h.sounds[4] == "Sounds/OHP/hidden-passage-success.ogg" and h.sound_targets[4] == "coalition")
  local delivered = h.groups[h.runtime.objective.party_key]:GetVec2()
  assert(math.abs(delivered.x - config.receiving.x) < 0.01 and math.abs(delivered.y - config.receiving.y + 5) < 0.01)
end)
test("entering Chinook first then switching before pickup does not fail or claim the mission", function()
  local h = harness({ pinned = true })
  h.player.point = config.receiving
  h:observe_for(3)
  assert(not h.runtime.objective.carrier_id)
  h.player.alive = false
  h:tick()
  assert(h.runtime.objective.phase == "waiting")
  h:command("Request green smoke", h.raven)
  h.raven.point = config.pickup
  h:observe_for(2)
  assert(h.runtime.objective.phase == "boarding" and h.runtime.objective.carrier_id == h.raven.id)
  h:flush()
  assert(h.runtime.objective.phase == "aboard" and #h.errors == 0)
end)
test("first boarding helicopter owns the package and the other cannot steal or duplicate it", function()
  for _, raven_first in ipairs({ true, false }) do
    local h = harness({ pinned = true })
    local first, second = h.player, h.raven
    if raven_first then
      first, second = second, first
    end
    first.point, second.point = config.pickup, config.receiving
    h:observe_for(2)
    assert(h.runtime.carrier_name == first:GetName())
    second.point = config.pickup
    h:command("Extract waiting personnel", second)
    h:command("Unload personnel", second)
    h:observe_for(4)
    assert(h.runtime.ctld.CargoCounter == 1 and h.runtime.objective.phase == "boarding")
    assert(not h.runtime.ctld.Loaded_Cargo[second:GetName()])
    h:flush()
    assert(h.runtime.objective.phase == "aboard" and #h.errors == 0)
    assert(h.runtime.objective.carrier_id == first:GetID())
  end
end)
test("simultaneous pickup candidates still reserve only one party", function()
  local h = harness({ pinned = true })
  h.raven.point = config.pickup
  h:observe_for(2)
  assert(h.runtime.ctld.CargoCounter == 1)
  assert(h.runtime.objective.carrier_id == h.player.id and not h.runtime.ctld.Loaded_Cargo[config.support_unit])
end)
test("automatic settling clocks are independent for each helicopter", function()
  local h = harness({ pinned = true })
  h:observe_for(1)
  h.player.airborne, h.raven.point = true, config.pickup
  h:tick()
  h:advance(1)
  h:tick()
  assert(h.runtime.objective.phase == "waiting")
  h:advance(1)
  h:tick()
  assert(h.runtime.carrier_name == config.support_unit and h.runtime.objective.phase == "boarding")
end)
test("UH-60 hover, motion and unsafe proximity cannot start boarding", function()
  for _, mode in ipairs({ "hover", "motion", "too close", "range" }) do
    local h = harness({ pinned = true, only_uh60 = true })
    h.raven.point = mode == "range" and config.receiving or config.pickup
    h.raven.airborne = mode == "hover"
    h.raven.speed = mode == "motion" and 3 or 0
    if mode == "too close" then
      h.raven.point = config.personnel
    end
    h:observe_for(4)
    assert(h.runtime.objective.phase == "waiting" and not h.boarding_due and not h.runtime.objective.carrier_id, mode)
    assert(#h.errors == 0)
  end
end)
test("claimed UH-60 loss, replacement or early takeoff remains terminal", function()
  for _, mode in ipairs({ "loss", "replacement", "takeoff" }) do
    local h = harness({ pinned = true, only_uh60 = true })
    h.raven.point = config.pickup
    h:observe_for(2)
    if mode == "loss" then
      h.raven.alive = false
    elseif mode == "replacement" then
      h.raven.id = 303
    else
      h.raven.airborne = true
    end
    h:tick()
    assert(h.runtime.objective.phase == "failed", mode)
    h:flush()
    assert(h.runtime.objective.phase == "failed" and h.groups[h.runtime.objective.party_key]:IsAlive())
    assert(#h.errors == 0)
  end
end)
test("UH-60 off-site unloading and automatic recovery preserve cargo and ownership", function()
  local h = harness({ pinned = true, only_uh60 = true })
  h.raven.point = config.pickup
  h:observe_for(2)
  h:flush()
  h:command("Unload personnel", h.raven)
  h:flush()
  assert(h.runtime.objective.phase == "waiting")
  local party = h.groups[h.runtime.objective.party_key]
  h.raven.point = { x = party.point.x - 60, y = party.point.y }
  h:observe_for(2)
  h:flush()
  assert(h.runtime.objective.phase == "aboard" and h.runtime.carrier_name == config.support_unit)
  h.raven.point = config.receiving
  h:command("Unload personnel", h.raven)
  h:flush()
  assert(h.runtime.objective.phase == "complete" and #h.errors == 0)
end)
test("wrong-aircraft callbacks cannot disrupt the claimed UH-60 party", function()
  local h = harness({ pinned = true })
  h.player.point, h.raven.point = config.receiving, config.pickup
  h:observe_for(2)
  local party = h.groups[h.runtime.objective.party_key]
  h.runtime.ctld:OnAfterTroopsExtracted("Running", "TroopsExtracted", "Running", {}, h.player, party, party:GetName())
  h.runtime.ctld:OnAfterTroopsDeployed("Running", "TroopsDeployed", "Running", {}, h.player, party)
  assert(h.runtime.objective.phase == "boarding")
  h:flush()
  assert(h.runtime.objective.phase == "aboard" and #h.errors == 0)
end)
test("re-slot after failure has usable status but cannot resume or reset", function()
  local h = harness({ pinned = true })
  h:command("Extract waiting personnel")
  h.player.alive = false
  h:tick()
  assert(h.runtime.objective.phase == "failed")
  h.player.alive, h.player.id = true, 102
  h:command("Extract waiting personnel")
  assert(h.removed_menu and h.runtime.objective.phase == "failed")
  assert(h.runtime.ctld.Loaded_Cargo[config.player_unit].Troopsloaded == 3)
  assert(h.notices[#h.notices]:find("Restart the mission", 1, true))
  h:command("Unload personnel")
  assert(h.notices[#h.notices]:find("Restart the mission", 1, true))
  assert(not h.notices[#h.notices]:find("Not confirmed aboard", 1, true))
end)
local function sound_count(h, basename)
  local total = 0
  for _, path in ipairs(h.sounds) do
    if path == "Sounds/OHP/" .. basename .. ".ogg" then
      total = total + 1
    end
  end
  return total
end
local function report_for(h, id)
  for _, report in ipairs(h.runtime.threat_reports) do
    if report.id == id then
      return report
    end
  end
  error("Missing report " .. id)
end
local duration_by_file = {}
do
  local f = assert(io.open("src/missions/operation-hidden-passage/voice.lua", "rb"))
  local source = f:read("*a")
  f:close()
  for file, duration in source:gmatch('file%s*=%s*"([^"]+)".-duration%s*=%s*([%d%.]+)') do
    duration_by_file[file] = tonumber(duration)
  end
end
local function no_overlap(h)
  for i = 2, #h.sounds do
    assert(
      h.sound_times[i] + 0.001 >= h.sound_times[i - 1] + assert(duration_by_file[h.sounds[i - 1]]) + 0.35,
      "Overlapping clips: " .. h.sounds[i - 1] .. " / " .. h.sounds[i]
    )
  end
end
test("combined participation voices taskings and destruction reports without speaking for departing pilots", function()
  local h = harness(cap_options({ cas_convoy = true, cas_checkpoint = true }))
  h.blue_players = { h.cap_hornet, h.cas_hornet, h.cap_viper, h.cas_warthog }
  first_takeoff(h, h.cap_hornet)
  h:flush()
  first_takeoff(h, h.cas_hornet)
  h:flush()
  first_takeoff(h, h.cas_warthog)
  first_takeoff(h, h.cap_viper)
  h.radars[1].life = 0
  h:cap_tick()
  h:flush()
  assert(h.cas_checkpoint_spawns == 0)
  h:extract()
  h:flush()
  h.cas_convoy.size, h.cas_checkpoint.size, h.cap_fighters.size = 0, 0, 0
  h:tick()
  h:flush() -- Fighters cleared; the already-active Hind now gets its existing tasking.
  h.cap_hind.size = 0
  h:tick()
  h:flush()
  h:tick()
  h:flush()
  for _, name in ipairs({
    "overlord-cas-convoy-tasking",
    "overlord-cas-checkpoint-tasking",
    "overlord-sead-tasking",
    "overlord-kub-neutralised",
    "overlord-fighters-launching",
    "overlord-hind-launching",
    "cas-convoy-destroyed",
    "cas-checkpoint-cleared",
    "cap-fighters-destroyed",
    "cap-hind-destroyed",
  }) do
    assert(sound_count(h, name) == 1, name)
  end
  assert(#h.sounds == 13 and #h.errors == 0)
  assert(sound_count(h, "cas-departure") == 0 and sound_count(h, "cap-departure") == 0)
  for index, target in ipairs(h.sound_targets) do
    local crew = h.sounds[index]:find("/boarding-", 1, true)
    assert(target == (crew and h.player.id or "coalition"))
  end
  assert(h.runtime.objective.phase == "aboard", "Reports must not complete or gate delivery")
  no_overlap(h)
end)
test("helicopter-only and late fighter joins produce no optional-role voice traffic", function()
  local h = harness(cap_options({ cas_convoy = true, cas_checkpoint = true }))
  h.blue_players = { h.player }
  first_takeoff(h)
  h.blue_players = { h.cap_hornet, h.cas_hornet }
  first_takeoff(h, h.cap_hornet)
  first_takeoff(h, h.cas_hornet)
  h:tick()
  h:flush()
  assert(#h.sounds == 0 and #h.runtime.threat_reports == 0)
end)
test("CAS-only and CAP-only calls remain independent", function()
  local h = harness(cap_options({ cas_convoy = true, cas_checkpoint = true }))
  h.blue_players = { h.cas_warthog }
  first_takeoff(h, h.cas_warthog)
  h:flush()
  assert(sound_count(h, "cas-departure") == 0 and sound_count(h, "cap-departure") == 0)
  assert(sound_count(h, "overlord-cas-convoy-tasking") == 1)
  assert(sound_count(h, "overlord-sead-tasking") == 0)
  h = harness(cap_options({ cas_convoy = true, cas_checkpoint = true }))
  h.blue_players = { h.cap_viper }
  first_takeoff(h, h.cap_viper)
  h:flush()
  assert(sound_count(h, "cap-departure") == 0 and sound_count(h, "cas-departure") == 0)
  assert(sound_count(h, "overlord-sead-tasking") == 1)
  assert(sound_count(h, "overlord-cas-convoy-tasking") == 0)
end)
test("failed enemy spawns never announce a successful launch", function()
  local h = harness(cap_options({ cap_fighters_spawn_error = true }))
  h.blue_players = { h.cap_hornet }
  first_takeoff(h)
  h:flush()
  h.radars[1].life = 0
  h:cap_tick()
  h:flush()
  assert(sound_count(h, "overlord-kub-neutralised") == 1)
  assert(sound_count(h, "overlord-fighters-launching") == 0 and sound_count(h, "overlord-hind-launching") == 0)
  assert(h.runtime.cap.hind.state == "active", "Hind still spawns, but missing fighters are not confirmed destroyed")
end)
test("CAP tasking and radar transition remain voiced with pilot departure removed", function()
  local h = harness(cap_options())
  h.blue_players = { h.cap_hornet }
  first_takeoff(h, h.cap_hornet)
  h.radars[1].life = 0
  h:cap_tick()
  h:flush()
  assert(sound_count(h, "cap-departure") == 0 and sound_count(h, "overlord-kub-neutralised") == 1)
  no_overlap(h)
end)
test(
  "first and repeated CAS/CAP takeoffs never play pilot departure clips, including before re-slot or landing",
  function()
    for _, mode in ipairs({ "airborne", "left", "landed" }) do
      local h = harness(cap_options({ cas_convoy = true, cas_checkpoint = true }))
      h.blue_players = { h.cap_hornet, h.cas_hornet }
      first_takeoff(h, h.cap_hornet)
      first_takeoff(h, h.cas_hornet)
      first_takeoff(h, h.cap_hornet)
      first_takeoff(h, h.cas_hornet)
      if mode == "left" then
        h.cap_hornet.player_name, h.cas_hornet.player_name = nil, nil
      elseif mode == "landed" then
        h.cap_hornet.airborne, h.cas_hornet.airborne = false, false
      end
      h:flush()
      assert(sound_count(h, "cap-departure") == 0 and sound_count(h, "cas-departure") == 0, mode)
      assert(sound_count(h, "overlord-sead-tasking") == 1 and sound_count(h, "overlord-cas-convoy-tasking") == 1)
    end
  end
)
test("removed departure cues are blocked even if a stale caller requests them directly", function()
  local h = harness()
  h.runtime.voice:play("cas_departure")
  h.runtime.voice:radio("cap_departure")
  h:flush()
  assert(#h.sounds == 0)
  h.runtime.voice:radio("cas_convoy_tasking")
  h:flush()
  assert(#h.sounds == 1 and sound_count(h, "overlord-cas-convoy-tasking") == 1)
end)
test("partial losses and live aircraft at base never produce all-destroyed reports", function()
  local h = harness(cap_options({ cas_convoy = true, cas_checkpoint = true }))
  h.blue_players = { h.cas_hornet, h.cap_hornet }
  first_takeoff(h)
  h:flush()
  h.radars[1].life = 0
  h:cap_tick()
  h:flush()
  h:extract()
  h:flush()
  h.cas_convoy.size, h.cas_checkpoint.size, h.cap_fighters.size = 1, 1, 1
  h.cap_hind.point = config.receiving
  h:tick()
  h:flush()
  for _, id in ipairs({
    "cas_convoy_destroyed",
    "cas_checkpoint_cleared",
    "cap_fighters_destroyed",
    "cap_hind_destroyed",
  }) do
    assert(not report_for(h, id).done)
  end
  assert(sound_count(h, "cas-convoy-destroyed") == 0 and sound_count(h, "cap-hind-destroyed") == 0)
end)
test("missing units are not declared destroyed without matching death, crash or unit-lost events", function()
  for _, event_id in ipairs({ 8, 5, 30 }) do
    local h = harness(cap_options())
    h.blue_players = { h.cap_hornet }
    first_takeoff(h)
    h:flush()
    h.radars[1].life = 0
    h:cap_tick()
    h:flush()
    local report = report_for(h, "cap_fighters_destroyed")
    h.cap_fighters.units_removed = true
    h:tick()
    h:flush()
    assert(not report.done and sound_count(h, "cap-fighters-destroyed") == 0)
    for _, record in ipairs(report.units) do
      local name = record.name
      h.runtime.cas_decision_handler:onEvent({
        id = event_id,
        initiator = {
          getName = function()
            return name
          end,
        },
      })
    end
    h:tick()
    h:flush()
    h:tick()
    h:flush()
    assert(report.done and sound_count(h, "cap-fighters-destroyed") == 1)
  end
end)
test("death events from dormant templates or unrelated units cannot clear a spawned threat", function()
  local h = harness({ cas_convoy = true })
  h.blue_players = { h.cas_hornet }
  first_takeoff(h)
  h:flush()
  h.runtime.cas_decision_handler:onEvent({
    id = 8,
    initiator = {
      getName = function()
        return "CAS-Convoy-1"
      end,
    },
  })
  h.runtime.cas_decision_handler:onEvent({ id = 8, initiator = {} })
  h:tick()
  h:flush()
  assert(not report_for(h, "cas_convoy_destroyed").done and sound_count(h, "cas-convoy-destroyed") == 0)
end)
test("destroyed-target pilot reports require a human in the role at detection and playback", function()
  for _, mode in ipairs({ "left_before", "left_queued" }) do
    local h = harness({ cas_convoy = true })
    h.blue_players = { h.cas_hornet }
    first_takeoff(h)
    h:flush()
    if mode == "left_queued" then
      h.runtime.voice:radio("kub_neutralised")
    else
      h.blue_players = {}
    end
    h.cas_convoy.size = 0
    h:tick()
    h.blue_players = {}
    h:flush()
    assert(sound_count(h, "cas-convoy-destroyed") == 0)
    h.blue_players = { h.cas_hornet }
    h:tick()
    h:flush()
    assert(sound_count(h, "cas-convoy-destroyed") == 0, "Do not replay old reports to a late return")
  end
end)
test("target-query errors fail closed and recover without failing the extraction", function()
  local h = harness({ cas_convoy = true })
  h.blue_players = { h.cas_hornet }
  first_takeoff(h)
  h:flush()
  h.cas_convoy.unit_observation_error = true
  h:tick()
  h:tick()
  assert(#h.errors == 1 and h.runtime.objective.phase == "waiting")
  assert(sound_count(h, "cas-convoy-destroyed") == 0)
  h.cas_convoy.unit_observation_error = false
  h.cas_convoy.size = 0
  h:tick()
  h:flush()
  assert(sound_count(h, "cas-convoy-destroyed") == 1)
end)
test("actual firing audio starts only at the combat gate, and stale approach warnings are dropped", function()
  local h = harness({ firefight = true })
  approach_firefight(h)
  assert(sound_count(h, "hvt-taking-fire") == 0)
  start_firefight(h)
  h:flush()
  h:tick()
  h:flush()
  assert(sound_count(h, "hvt-taking-fire") == 1 and warning_count(h) == 0)
  assert(h.runtime.firefight.state == "active")
  no_overlap(h)
end)
test("queued taking-fire audio is suppressed after the party is safely aboard", function()
  local h = harness({ firefight = true })
  approach_firefight(h)
  start_firefight(h)
  h.player.airborne, h.player.point = false, config.pickup
  h:extract()
  h:flush()
  assert(h.runtime.objective.phase == "aboard" and sound_count(h, "hvt-taking-fire") == 0)
end)
test("urgent pickup calls jump routine intelligence without overlapping the active clip", function()
  local h = harness()
  h.runtime.voice:radio("cas_convoy_tasking")
  h.runtime.voice:radio("sead_tasking")
  h.runtime.voice:radio("hind_launching")
  h.runtime.voice:radio("taking_fire")
  h:flush()
  assert(h.sounds[1] == "Sounds/OHP/overlord-cas-convoy-tasking.ogg")
  assert(h.sounds[2] == "Sounds/OHP/hvt-taking-fire.ogg")
  assert(h.sounds[3] == "Sounds/OHP/overlord-sead-tasking.ogg")
  no_overlap(h)
end)
test("urgent insertion wakes a queue previously waiting on a long delayed routine call", function()
  local h = harness()
  h.runtime.voice:play("sead_tasking", 100)
  h.runtime.voice:radio("taking_fire")
  h:advance(0.1)
  assert(#h.sounds == 1 and h.sounds[1] == "Sounds/OHP/hvt-taking-fire.ogg")
  h:flush()
  assert(#h.sounds == 2 and h.sounds[2] == "Sounds/OHP/overlord-sead-tasking.ogg")
  no_overlap(h)
end)
test("stale intel is dropped without reserving its nominal playback duration", function()
  local h = harness()
  h.runtime.voice:radio("cas_convoy_tasking")
  h.runtime.voice:radio("sead_tasking", function()
    return false
  end)
  h.runtime.voice:radio("hind_launching")
  h:flush()
  assert(#h.sounds == 2 and sound_count(h, "overlord-sead-tasking") == 0)
  local next_delay = math.max(config.overlord_confirmation_delay_s, duration_by_file[h.sounds[1]] + 0.35)
  assert(math.abs(h.sound_times[2] - h.sound_times[1] - next_delay) < 0.001)
  no_overlap(h)
end)
test("failure cancels pending crew, success and routine calls; old pumps cannot restart them", function()
  local h = harness()
  h.runtime.voice:radio("cas_convoy_tasking")
  h.runtime.voice:boarding_start(h.player)
  h.runtime.voice:boarding_complete(h.player)
  h.runtime.voice:play("mission_success", 30)
  h.runtime.objective:fail("test failure")
  h:tick()
  h:tick()
  h.runtime.voice:radio("hind_launching")
  h:flush()
  h:advance(100)
  assert(#h.sounds == 2 and h.sounds[2] == "Sounds/OHP/overlord-extraction-failed.ogg")
  assert(sound_count(h, "overlord-extraction-failed") == 1 and sound_count(h, "hidden-passage-success") == 0)
  no_overlap(h)
end)
test("failure waits for an already playing crew clip rather than overlapping it", function()
  local h = harness()
  h.runtime.voice:boarding_start(h.raven)
  h.runtime.objective:fail("test failure")
  h:tick()
  h:flush()
  assert(h.sound_targets[1] == h.raven.id and h.sound_targets[2] == "coalition")
  assert(h.sounds[2] == "Sounds/OHP/overlord-extraction-failed.ogg")
  no_overlap(h)
end)
local function failure_notice_count(h)
  local total = 0
  for _, text in ipairs(h.notices) do
    if text:find("^Operation failed:") then
      total = total + 1
    end
  end
  return total
end
test("HVT casualties fail immediately but automatic text and Overlord wait twenty seconds", function()
  assert(config.overlord_confirmation_delay_s == 20)
  for _, boarding in ipairs({ false, true }) do
    local h = harness()
    h:tick()
    if boarding then
      h.runtime.ctld.Loaded_Cargo[config.player_unit] = { Troopsloaded = 3 }
      h:tick()
      assert(h.runtime.objective.phase == "boarding")
    end
    h.groups[h.runtime.objective.party_key].size = 2
    local failed_at = h.now
    h:tick()
    assert(h.runtime.objective.phase == "failed" and h.runtime.voice.aborted)
    assert(h.runtime.failure_report_at == failed_at + 20)
    assert(sound_count(h, "overlord-extraction-failed") == 0 and failure_notice_count(h) == 0)
    h:advance(19.99)
    h:tick()
    assert(sound_count(h, "overlord-extraction-failed") == 0 and failure_notice_count(h) == 0)
    h:advance(0.01)
    h:tick()
    assert(sound_count(h, "overlord-extraction-failed") == 1 and failure_notice_count(h) == 1)
    assert(math.abs(h.sound_times[#h.sounds] - failed_at - 20) < 0.001)
    assert(h.runtime.objective.phase == "failed" and #h.errors == 0)
  end
end)
test("repeated failure observations neither postpone nor duplicate the delayed report", function()
  local h = harness()
  h:tick()
  h.groups[h.runtime.objective.party_key].size = 2
  h:tick()
  local deadline = h.runtime.failure_report_at
  h:observe_for(19)
  assert(h.runtime.failure_report_at == deadline and not h.runtime.failure_reported)
  assert(sound_count(h, "overlord-extraction-failed") == 0 and failure_notice_count(h) == 0)
  h:observe_for(1)
  h:observe_for(60)
  assert(sound_count(h, "overlord-extraction-failed") == 1 and failure_notice_count(h) == 1)
  assert(h.runtime.failure_report_at == deadline and #h.errors == 0)
end)
test("failure pause cancels queued and newly requested chatter immediately", function()
  local h = harness()
  h:tick()
  h.runtime.voice:play("mission_success", 5)
  h.runtime.voice:play("boarding_confirm", 6, h.player)
  h.runtime.voice:play("sead_tasking", 7)
  h.groups[h.runtime.objective.party_key].size = 2
  h:tick()
  h.runtime.voice:radio("hind_launching")
  h:observe_for(19)
  assert(#h.sounds == 0 and failure_notice_count(h) == 0)
  h:observe_for(1)
  h:flush()
  assert(#h.sounds == 1 and sound_count(h, "overlord-extraction-failed") == 1)
  assert(h.runtime.objective.phase == "failed" and #h.errors == 0)
end)
test("delayed abort retains a longer occupied audio slot and cannot be queued twice", function()
  local h = harness()
  h:tick()
  local started = h.now
  h.runtime.voice.busy_until = started + 25
  h.runtime.objective:fail("test failure")
  h:tick()
  h.runtime.voice:abort(0)
  h:observe_for(20)
  assert(#h.sounds == 0 and failure_notice_count(h) == 1)
  h:advance(5)
  assert(sound_count(h, "overlord-extraction-failed") == 1)
  assert(h.sound_times[1] == started + 25)
  h:flush()
  assert(#h.sounds == 1 and #h.errors == 0)
end)
test(
  "Overlord outcome cues enforce twenty seconds except five-second checkpoint tasking, even through direct callers",
  function()
    for _, id in ipairs({
      "kub_neutralised",
      "fighters_launching",
      "hind_launching",
      "cas_checkpoint_tasking",
      "mission_success",
      "mission_failed",
    }) do
      local h = harness()
      local delay = id == "cas_checkpoint_tasking" and 5 or 20
      h.runtime.voice:play(id, nil, nil, nil, nil, "Observed outcome")
      h:advance(delay - 0.01)
      assert(#h.sounds == 0 and #h.notices == 0, id)
      h:advance(0.01)
      assert(#h.sounds == 1 and h.notices[1] == "Observed outcome", id)
      assert(h.sound_times[1] == h.notice_times[1] and #h.errors == 0)
    end
  end
)
test("Kub kill releases runway fighters immediately but its text and recording wait twenty seconds", function()
  local h = harness(cap_options())
  h.blue_players = { h.cap_hornet }
  first_takeoff(h)
  local killed = h.now
  h.radars[1].life = 0
  h:cap_tick()
  assert(h.cap_spawns.fighters == 1 and h.cap_runway_starts.fighters == 1 and h.cap_spawns.hind == 1)
  assert(h.runtime.cap.sam_destroyed_at == killed and #h.notices == 1)
  h:advance(19.99)
  assert(#h.notices == 1 and sound_count(h, "overlord-kub-neutralised") == 0)
  h:advance(0.01)
  assert(h.notices[2]:find("tracking radar is destroyed", 1, true))
  assert(sound_count(h, "overlord-kub-neutralised") == 1 and h.notice_times[2] == killed + 20)
  h:flush()
  assert(#h.notices == 3 and #h.errors == 0)
  no_overlap(h)
end)
test("a failed mission cancels delayed Overlord outcome text as well as audio", function()
  local h = harness(cap_options())
  h:tick()
  h.blue_players = { h.cap_hornet }
  first_takeoff(h)
  h.radars[1].life = 0
  h:cap_tick()
  local notices = #h.notices
  h:advance(5)
  h.runtime.objective:fail("test failure")
  h:tick()
  h:observe_for(20)
  h:flush()
  assert(#h.notices == notices + 1 and failure_notice_count(h) == 1)
  assert(sound_count(h, "overlord-kub-neutralised") == 0 and sound_count(h, "overlord-fighters-launching") == 0)
  assert(sound_count(h, "overlord-extraction-failed") == 1 and #h.errors == 0)
end)
test("actual delivery succeeds immediately while Overlord's completion confirmation waits", function()
  local h = harness()
  h:extract()
  h:flush()
  local delivered, notices = h.now, #h.notices
  h:drop(config.receiving)
  assert(h.runtime.objective.phase == "complete" and #h.notices == notices)
  h:advance(19.99)
  assert(sound_count(h, "hidden-passage-success") == 0 and #h.notices == notices)
  h:advance(0.02)
  assert(sound_count(h, "hidden-passage-success") == 1 and h.sound_times[#h.sounds] == delivered + 20)
  assert(#h.notices > notices and #h.errors == 0)
end)
test("validated pickup releases checkpoint immediately with a five-second tasking minimum", function()
  local h = harness({ cas_convoy = true, cas_checkpoint = true })
  h.blue_players = { h.cas_hornet }
  first_takeoff(h, h.cas_hornet)
  h:flush()
  h:advance(10) -- Let the initial convoy assignment finish before the pickup receipt.
  h:extract()
  local picked_up = h.now
  assert(h.runtime.objective.phase == "aboard" and h.cas_checkpoint_spawns == 1)
  local notices = #h.notices
  assert(config.cas.checkpoint_tasking_delay_s == 5)
  h:advance(4.99)
  assert(sound_count(h, "overlord-cas-checkpoint-tasking") == 0)
  for i = notices + 1, #h.notices do
    assert(not h.notices[i]:find("north-road checkpoint", 1, true))
  end
  h:advance(0.02)
  h:flush() -- The remaining crew boarding clips can extend the minimum pause.
  assert(sound_count(h, "overlord-cas-checkpoint-tasking") == 1)
  assert(h.sound_times[#h.sounds] >= picked_up + 5 and h.sound_times[#h.sounds] < picked_up + 20 and #h.errors == 0)
  no_overlap(h)
end)
test("five-second checkpoint tasking does not wait behind a routine twenty-second report", function()
  local h = harness()
  h.runtime.voice:radio("kub_neutralised")
  h.runtime.voice:radio("cas_checkpoint_tasking", nil, "Checkpoint task")
  h:advance(4.99)
  assert(#h.sounds == 0 and #h.notices == 0)
  h:advance(0.01)
  assert(h.sounds[1] == "Sounds/OHP/overlord-cas-checkpoint-tasking.ogg" and h.notices[1] == "Checkpoint task")
  h:flush()
  assert(sound_count(h, "overlord-kub-neutralised") == 1 and h.sound_times[2] >= 120)
  no_overlap(h)
end)
test("asynchronous aircraft births recover warnings and destruction tracking without respawning", function()
  local h = harness(cap_options({ cap_fighters_birth_delay = 0.8, cap_hind_birth_delay = 0.8 }))
  h.blue_players = { h.cap_hornet }
  first_takeoff(h)
  h.radars[1].life = 0
  h:cap_tick()
  assert(h.runtime.cap.fighters.state == "spawning" and h.runtime.cap.hind.state == "spawning")
  assert(#h.runtime.threat_reports == 0 and #h.errors == 0)
  h:advance(1)
  for _, role in ipairs({ "fighters", "hind" }) do
    local pending = h.runtime.cap[role].readiness_timer
    pending.run()
    pending.run() -- A late duplicate callback must not duplicate tracking/warnings.
    assert(h.runtime.cap[role].state == "active" and h.cap_spawns[role] == 1)
  end
  assert(#h.runtime.threat_reports == 2)
  h:flush()
  assert(sound_count(h, "overlord-fighters-launching") == 1 and sound_count(h, "overlord-hind-launching") == 0)
  assert(#h.errors == 0)
end)
test("an aircraft that never appears times out without blocking its sibling or spawning again", function()
  local h = harness(cap_options({ cap_fighters_spawn_dead = true }))
  h.blue_players = { h.cap_hornet }
  first_takeoff(h)
  h.radars[1].life = 0
  h:cap_tick()
  for _ = 1, config.cap.spawn_ready_timeout_s do
    h:advance(1)
    h.runtime.cap.fighters.readiness_timer.run()
  end
  assert(h.runtime.cap.fighters.state == "unavailable" and h.runtime.cap.hind.state == "active")
  h.runtime.cap.fighters.readiness_timer.run()
  h:cap_tick()
  h:flush()
  assert(h.cap_spawns.fighters == 1 and sound_count(h, "overlord-fighters-launching") == 0)
  assert(sound_count(h, "overlord-hind-launching") == 0 and #h.errors == 1)
end)
test("a blocked runway or missing airfield cannot silently fall back to an airborne or parking start", function()
  for _, fault in ipairs({ "cap_runway_blocked", "cap_airbase_missing" }) do
    local h = harness(cap_options({ [fault] = true }))
    h.blue_players = { h.cap_hornet }
    first_takeoff(h)
    h.radars[1].life = 0
    h:cap_tick()
    h:flush()
    assert(h.runtime.cap.fighters.state == "unavailable" and h.runtime.cap.hind.state == "active")
    assert(h.cap_spawns.fighters == 0 and sound_count(h, "overlord-fighters-launching") == 0)
    assert(h.cap_runway_starts.hind == nil and #h.errors == 1)
  end
end)
local function hind_task_notice_count(h)
  local total = 0
  for _, text in ipairs(h.notices) do
    if text:find("an enemy Hind is preparing to launch", 1, true) then
      total = total + 1
    end
  end
  return total
end
test("Hind spawns with MiGs but its unchanged call waits for both confirmed kills and twenty seconds", function()
  local h = harness(cap_options())
  h.blue_players = { h.cap_hornet }
  first_takeoff(h)
  h.radars[1].life = 0
  h:cap_tick()
  assert(h.cap_spawns.fighters == 1 and h.cap_spawns.hind == 1)
  assert(h.runtime.cap.hind.state == "active" and not h.runtime.cap.hind.tasking_queued)
  h:flush()
  h.cap_fighters.unit_life = { 0, 100 }
  h:tick()
  h:advance(100)
  h:tick()
  assert(not h.runtime.cap.fighters.destroyed and not h.runtime.cap.hind.tasking_queued)
  assert(sound_count(h, "overlord-hind-launching") == 0 and hind_task_notice_count(h) == 0)
  local killed = h.now
  h.cap_fighters.unit_life[2] = 0
  h:tick()
  assert(h.runtime.cap.fighters.destroyed and h.runtime.cap.hind.tasking_queued)
  assert(h.runtime.cap.fighters.destroyed_at == killed)
  h:advance(19.99)
  h:tick()
  assert(sound_count(h, "overlord-hind-launching") == 0 and hind_task_notice_count(h) == 0)
  h:advance(0.02)
  h:tick()
  h:flush()
  assert(sound_count(h, "overlord-hind-launching") == 1 and hind_task_notice_count(h) == 1)
  for index, sound in ipairs(h.sounds) do
    if sound == "Sounds/OHP/overlord-hind-launching.ogg" then
      assert(h.sound_times[index] >= killed + 20)
    end
  end
  h:observe_for(50)
  h:flush()
  assert(sound_count(h, "overlord-hind-launching") == 1 and h.cap_spawns.hind == 1 and #h.errors == 0)
  no_overlap(h)
end)
test("Hind handoff requires confirmed fighter deaths, not disappearance or observation errors", function()
  local h = harness(cap_options())
  h.blue_players = { h.cap_viper }
  first_takeoff(h)
  h.radars[1].life = 0
  h:cap_tick()
  h.cap_fighters.units_removed = true
  h:tick()
  h:flush()
  assert(not h.runtime.cap.hind.tasking_queued and sound_count(h, "overlord-hind-launching") == 0)
  local report = report_for(h, "cap_fighters_destroyed")
  h.cap_fighters.unit_observation_error = true
  h:tick()
  assert(not h.runtime.cap.hind.tasking_queued)
  h.cap_fighters.unit_observation_error = false
  for _, record in ipairs(report.units) do
    local name = record.name
    h.runtime.cas_decision_handler:onEvent({
      id = 8,
      initiator = {
        getName = function()
          return name
        end,
      },
    })
  end
  h:tick()
  h:flush()
  assert(sound_count(h, "overlord-hind-launching") == 1 and hind_task_notice_count(h) == 1)
end)
test("a Hind lost before handoff or during its reporting pause cannot receive stale tasking", function()
  for _, when in ipairs({ "before", "during" }) do
    local h = harness(cap_options())
    h.blue_players = { h.cap_hornet }
    first_takeoff(h)
    h.radars[1].life = 0
    h:cap_tick()
    h:flush()
    if when == "before" then
      h.cap_hind.size = 0
    end
    h.cap_fighters.size = 0
    h:tick()
    if when == "during" then
      assert(h.runtime.cap.hind.tasking_queued)
      h:advance(5)
      h.cap_hind.size = 0
      h:tick()
    end
    h:flush()
    assert(sound_count(h, "overlord-hind-launching") == 0 and hind_task_notice_count(h) == 0)
    assert(h.cap_spawns.hind == 1 and #h.errors == 0)
  end
end)
test("terminal mission states suppress Hind handoff before release and during its pause", function()
  for _, phase in ipairs({ "failed", "complete" }) do
    for _, when in ipairs({ "before", "during" }) do
      local h = harness(cap_options())
      h.blue_players = { h.cap_hornet }
      first_takeoff(h)
      h.radars[1].life = 0
      h:cap_tick()
      h:flush()
      if when == "before" then
        h.runtime.objective.phase = phase
      end
      h.cap_fighters.size = 0
      h:tick()
      if when == "during" then
        h.runtime.objective.phase = phase
        h:tick()
      end
      h:flush()
      assert(sound_count(h, "overlord-hind-launching") == 0 and hind_task_notice_count(h) == 0)
      assert(#h.errors == 0)
    end
  end
end)
test("late Hind birth after fighter destruction releases tasking once, without another spawn", function()
  local h = harness(cap_options({ cap_hind_birth_delay = 0.8 }))
  h.blue_players = { h.cap_hornet }
  first_takeoff(h)
  h.radars[1].life = 0
  h:cap_tick()
  assert(h.runtime.cap.hind.state == "spawning")
  h.cap_fighters.size = 0
  h:tick()
  assert(h.runtime.cap.fighters.destroyed and not h.runtime.cap.hind.tasking_queued)
  h:advance(1)
  h.runtime.cap.hind.readiness_timer.run()
  assert(h.runtime.cap.hind.tasking_queued and h.cap_spawns.hind == 1)
  h:flush()
  assert(sound_count(h, "overlord-hind-launching") == 1 and hind_task_notice_count(h) == 1 and #h.errors == 0)
end)
test("partial fighter birth cannot snapshot one MiG as the entire fighter objective", function()
  local h = harness(cap_options({ cap_fighters_partial_birth = true }))
  h.blue_players = { h.cap_hornet }
  first_takeoff(h)
  h.radars[1].life = 0
  h:cap_tick()
  assert(h.runtime.cap.fighters.state == "spawning" and #h.runtime.threat_reports == 1)
  h:advance(1)
  h.runtime.cap.fighters.readiness_timer.run()
  assert(h.runtime.cap.fighters.state == "active" and #report_for(h, "cap_fighters_destroyed").units == 2)
  h.cap_fighters.unit_life = { 0, 100 }
  h:tick()
  h:flush()
  assert(not h.runtime.cap.hind.tasking_queued and sound_count(h, "overlord-hind-launching") == 0)
  assert(h.cap_spawns.fighters == 1 and #h.errors == 0)
end)
print(
  "Hidden Passage "
    .. (shipping and "shipping" or "source")
    .. " adapter: "
    .. count
    .. " mocked checks passed (including pinned CTLD methods)"
)

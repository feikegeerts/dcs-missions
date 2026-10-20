-- Execute source OR generated shipping payload with no filesystem in its env.
-- This checks our adapter contract, not actual DCS terrain/CTLD simulation.
local shipping = arg[1]
local config = dofile("src/missions/operation-hidden-passage/config.lua")
-- Optional real archive layout: exercise the same adapter at relocated zones,
-- while retaining the packaged script/config unchanged (runtime reads zones).
if arg[2] then
  local sandbox = {}
  local chunk = assert(loadfile(arg[2]))
  setfenv(chunk, sandbox)
  chunk()
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
local function pinned_method(name, env)
  local first = assert(moose:find("function CTLD:" .. name .. "(", 1, true))
  local last = assert(moose:find("\nfunction CTLD:", first + 1, true))
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
    sounds = {},
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
    now = 100,
  }
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
        h.sound_targets[#h.sounds] = "coalition"
      end,
    },
  }
  env.USERSOUND = {
    New = function(_, path)
      return {
        ToUnit = function(_, unit)
          h.sounds[#h.sounds + 1] = path
          h.sound_targets[#h.sounds] = unit:GetID()
        end,
      }
    end,
  }
  env.world = {
    event = { S_EVENT_TAKEOFF = 3 },
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
          h.notice_targets[#h.notices] = "coalition"
        end,
        ToUnit = function(_, unit)
          h.notices[#h.notices + 1] = text
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
        local units = {}
        for i = 1, self.size do
          local point = { x = self.point.x + (i - 1) * 12, y = self.point.y }
          units[i] = {
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
  h.player = {
    id = 101,
    name = config.player_unit,
    type_name = "CH-47Fbl1",
    alive = true,
    airborne = false,
    point = config.pickup,
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
  }
  h.player.getName = h.player.GetName
  h.player.getTypeName = h.player.GetTypeName
  h.player.getID = h.player.GetID
  h.raven = {}
  for key, value in pairs(h.player) do
    h.raven[key] = value
  end
  h.raven.id, h.raven.name, h.raven.type_name = 202, config.support_unit, "UH-60L"
  h.raven.point = config.receiving
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
      if options.firefight and name == config.firefight.template then
        return h.opposition_template
      end
      return h.groups[name]
    end,
  }
  env.TIMER = {
    New = function(_, fn)
      local timer = { run = fn, Start = function() end }
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
  if options.firefight then
    local point = {
      x = config.personnel.x + config.firefight.staging_offset_m,
      y = config.personnel.y - config.firefight.staging_offset_m,
    }
    h.opposition_template = group(config.firefight.template, point, config.firefight.enemy_unit_count)
    h.opposition_spawns = 0
    env.SPAWN = {
      New = function(_, template)
        assert(template == config.firefight.template)
        local spawner = {}
        function spawner:InitLimit(maximum_units, maximum_groups)
          assert(maximum_units == config.firefight.enemy_unit_count and maximum_groups == 1)
          return self
        end
        function spawner:Spawn()
          h.opposition_spawns = h.opposition_spawns + 1
          h.opposition = group(template .. "#001", point, config.firefight.enemy_unit_count)
          return h.opposition
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
  assert(#h.event_handlers == 1, "Takeoff handler was not registered")
  local handler = h.event_handlers[1]
  assert(
    type(handler) == "table" and type(handler.onEvent) == "function",
    "DCS calls handler:onEvent, so a table is required"
  )
  handler:onEvent({ id = 3, initiator = h.player })
  assert(h.sounds[1] == "Sounds/OHP/mule-one-cleared-for-pickup.ogg")
  assert(h.sound_targets[1] == h.player.id and h.notice_targets[1] == h.player.id)
  handler:onEvent({ id = 3, initiator = h.player })
  assert(#h.sounds == 1, "Takeoff call repeated")
end)
test("Raven takeoff plays only its support call once and only to its crew", function()
  local h = harness({ only_uh60 = true })
  local handler = h.event_handlers[1]
  handler:onEvent({ id = 3, initiator = h.raven })
  assert(h.sounds[1] == "Sounds/OHP/raven-one-cleared-for-support.ogg")
  assert(h.sound_targets[1] == h.raven.id and h.notice_targets[1] == h.raven.id)
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
    local handler = h.event_handlers[1]
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
  local handler = h.event_handlers[1]
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
  h.event_handlers[1]:onEvent({ id = 3, initiator = h.raven })
  assert(#h.sounds == 0 and not h.runtime.takeoff_announced[config.support_unit])
end)
test("queued takeoff calls do not follow a destroyed or replaced recipient", function()
  for _, replaced in ipairs({ true, false }) do
    local h = harness()
    h.event_handlers[1]:onEvent({ id = 3, initiator = h.player })
    h.event_handlers[1]:onEvent({ id = 3, initiator = h.raven })
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
    assert(h.sound_targets[i] == h.raven.id and h.notice_targets[i] == h.raven.id)
  end
  assert(h.runtime.objective.phase == "waiting", "Audio helpers must not implement UH-60 extraction")
end)
test("non-blue or non-takeoff events stay silent", function()
  local h = harness()
  h.player.getCoalition = function()
    return 1
  end
  h.event_handlers[1]:onEvent({ id = 3, initiator = h.player })
  assert(#h.sounds == 0)
  h.player.getCoalition = function()
    return 2
  end
  h.event_handlers[1]:onEvent({ id = 4, initiator = h.player })
  assert(#h.sounds == 0)
end)
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
  h.event_handlers[1]:onEvent({ id = 3, initiator = unit })
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
    assert(h.sound_targets[#h.sounds] == "coalition" and h.notice_targets[#h.notices] == "coalition")
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
  assert(staged_distance > config.firefight.fire_start_distance_m)

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
  h.event_handlers[1]:onEvent({ id = 3, initiator = h.player })
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
    { zone_points = { [config.personnel_zone] = { x = config.pickup.x + 110, y = config.pickup.y } } },
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
    if text:find("Too close for automatic boarding", 1, true) then
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
    assert(not h.boarding_due and #h.sounds == 0 and #h.errors == 0, mode)
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
    assert(h.notices[#h.notices]:find("All three aboard", 1, true))
    h:advance(4)
    assert(h.notices[#h.notices]:find("Three personnel aboard", 1, true))
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
test("green smoke marks editor LZ rather than a fixed southern offset, with no range gate", function()
  local h = harness()
  h.player.point = config.receiving -- Still at Hatay, away from the pickup.
  h:command("Mark landing area (green smoke)")
  assert(#h.smokes == 1)
  local smoke = h.smokes[1]
  assert(math.abs(smoke.x - config.pickup.x) < 0.01 and math.abs(smoke.y - config.pickup.y) < 0.01)
end)
test("status and map labels use operational names and runtime distance", function()
  local h = harness()
  h:command("Instructions / status")
  local text = h.notices[#h.notices]
  local distance = math.sqrt((config.pickup.x - config.receiving.x) ^ 2 + (config.pickup.y - config.receiving.y) ^ 2)
    / 1852
  assert(text:find("OHP-Pickup", 1, true) and text:find(string.format("%.1f NM", distance), 1, true))
  assert(text:find("OHP-HVTs", 1, true) and text:find("Either helicopter can extract", 1, true))
  assert(#h.marks == 3)
  for _, mark in ipairs(h.marks) do
    assert(not mark:find("TEST", 1, true) and not mark:find("north", 1, true))
  end
  assert(h.commands["Instructions / status"] and not h.commands["Test instructions / status"])
end)
test("UH-60L-only occupancy gets its own menu without prematurely claiming the objective", function()
  local h = harness({ only_uh60 = true })
  h:tick()
  assert(h.commands["Mark landing area (green smoke)"] and h.runtime.objective.phase == "waiting")
  assert(h.runtime.objective.carrier_id == nil and #h.errors == 0)
end)
test("runtime zones override build coordinate snapshots for smoke and navigation distance", function()
  local moved = { x = config.pickup.x - 10000, y = config.pickup.y + 2000 }
  local people =
    { x = moved.x + config.personnel.x - config.pickup.x, y = moved.y + config.personnel.y - config.pickup.y }
  local h = harness({ zone_points = { [config.pickup_zone] = moved, [config.personnel_zone] = people } })
  h:command("Mark landing area (green smoke)")
  assert(h.smokes[1].x == moved.x and h.smokes[1].y == moved.y)
  local expected = math.sqrt((moved.x - config.receiving.x) ^ 2 + (moved.y - config.receiving.y) ^ 2) / 1852
  assert(math.abs(h.runtime.distance_nm - expected) < 0.001)
end)
test("off-site recovery smoke preserves editor LZ direction and separation", function()
  local h = harness()
  h:extract()
  local drop = { x = config.pickup.x + 300, y = config.pickup.y - 900 }
  h:drop(drop)
  h:command("Mark landing area (green smoke)")
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
  h:command("Mark landing area (green smoke)", h.raven)
  assert(#h.smokes == 1 and h.notice_targets[#h.notices] == h.raven.id)
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
  h:command("Mark landing area (green smoke)", h.raven)
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
print(
  "Hidden Passage "
    .. (shipping and "shipping" or "source")
    .. " adapter: "
    .. count
    .. " mocked checks passed (including pinned CTLD methods)"
)

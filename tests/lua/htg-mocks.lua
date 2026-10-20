-- Minimal DCS scripting API mocks for the helicopter training range tests.
--
-- Just enough to load the range and drive its 1 Hz evaluation loop against a
-- scripted aircraft. Used by:
--   * tests/lua/run-helicopter-training-sim.lua      (source modules, dev mode)
--   * tests/lua/run-helicopter-training-shipped.lua  (generated shipping payload)
--
-- Deliberately not a general DCS emulator: only what the range touches.

local Mocks = {}

local function stub_object(record)
  return {
    getName = function()
      return record.name
    end,
    getTypeName = function()
      return record.unit_type
    end,
    getPoint = function()
      return { x = record.pos.x, y = record.pos.y, z = record.pos.z }
    end,
    getVelocity = function()
      return { x = 0, y = 0, z = record.speed }
    end,
    inAir = function()
      return record.in_air
    end,
    getPosition = function()
      return { x = { x = 0, y = 0, z = 1 }, y = { x = 0, y = 1, z = 0 }, z = { x = 1, y = 0, z = 0 } }
    end,
    getPlayerName = function()
      return record.player
    end,
    getCountry = function()
      return 2
    end,
    getGroup = function()
      return {
        getID = function()
          return 1
        end,
      }
    end,
    destroy = function()
      record.destroyed = true
    end,
  }
end

--- Install the mocks and return a context for driving them.
function Mocks.install()
  local ctx = {
    now = 0,
    scheduled = {},
    logs = {},
    units = {},
    groups = {},
    statics = {},
    statics_created = 0,
    groups_created = 0,
    player_groups = {},
    tick_entry = nil,
  }

  ctx.make_unit = function(name, unit_type)
    local record = {
      name = name,
      unit_type = unit_type,
      destroyed = false,
      pos = { x = 0, y = 10, z = 0 },
      speed = 0,
      player = nil,
      in_air = false,
    }
    ctx.units[name] = record
    return record
  end

  ctx.make_player = function(unit_name, unit_type)
    local record = ctx.make_unit(unit_name, unit_type)
    record.player = "Feike"
    ctx.player_groups = {
      {
        getID = function()
          return 1
        end,
        getUnits = function()
          return { stub_object(record) }
        end,
      },
    }
    return record
  end

  ctx.stub_object = stub_object

  env = {
    info = function(message)
      ctx.logs[#ctx.logs + 1] = message
    end,
    warning = function(message)
      ctx.logs[#ctx.logs + 1] = "WARN " .. message
    end,
    error = function(message)
      ctx.logs[#ctx.logs + 1] = "ERROR " .. message
    end,
  }

  timer = {
    getTime = function()
      return ctx.now
    end,
    getAbsTime = function()
      return ctx.now
    end,
    scheduleFunction = function(fn, arg, at)
      ctx.scheduled[#ctx.scheduled + 1] = { fn = fn, arg = arg, at = at, done = false }
      return #ctx.scheduled
    end,
  }

  trigger = {
    smokeColor = { Green = 1, Red = 2, White = 3, Orange = 4, Blue = 5 },
    action = {
      outTextForCoalition = function() end,
      outTextForUnit = function() end,
      outTextForGroup = function() end,
      markToAll = function()
        return true
      end,
      removeMark = function() end,
      smoke = function() end,
      setUnitInternalCargo = function(name, mass)
        local unit = ctx.units[name]
        if unit then
          unit.internal_cargo = mass
        end
      end,
    },
  }

  land = {
    SurfaceType = { LAND = 0, WATER = 1 },
    getHeight = function()
      return 10
    end,
    getSurfaceType = function()
      return 0
    end,
  }

  Object = {
    Category = { UNIT = 1, STATIC = 2 },
    getCategory = function()
      return 1 -- every stubbed object is a unit
    end,
  }

  Group = {
    Category = { GROUND = 2, HELICOPTER = 4 },
    getByName = function(name)
      local record = ctx.groups[name]
      if not record then
        return nil
      end
      local alive = {}
      for _, unit_name in ipairs(record.unit_names) do
        local unit = ctx.units[unit_name]
        if unit and not unit.destroyed then
          alive[#alive + 1] = stub_object(unit)
        end
      end
      if #alive == 0 then
        return nil
      end
      return {
        getName = function()
          return name
        end,
        getUnits = function()
          return alive
        end,
        getController = function()
          return {}
        end,
        destroy = function()
          for _, unit_name in ipairs(record.unit_names) do
            if ctx.units[unit_name] then
              ctx.units[unit_name].destroyed = true
            end
          end
        end,
      }
    end,
  }

  Unit = {
    getByName = function(name)
      local record = ctx.units[name]
      if not record or record.destroyed then
        return nil
      end
      return stub_object(record)
    end,
  }

  StaticObject = {
    getByName = function(name)
      local record = ctx.statics[name]
      if not record or record.destroyed then
        return nil
      end
      return {
        getPoint = function()
          return { x = record.pos.x, y = record.pos.y, z = record.pos.z }
        end,
        destroy = function()
          record.destroyed = true
        end,
      }
    end,
  }

  Controller = { setOption = function() end }
  AI = {
    Option = {
      Ground = {
        id = { ALARM_STATE = 1, ROE = 2, DISPERSAL = 3 },
        val = { ALARM_STATE = { GREEN = 1 }, ROE = { WEAPON_HOLD = 1 }, DISPERSAL = { OFF = 1 } },
      },
    },
  }

  world = {
    event = {
      S_EVENT_KILL = 8,
      S_EVENT_DEAD = 9,
      S_EVENT_BIRTH = 15,
      S_EVENT_PLAYER_ENTER_UNIT = 16,
    },
    addEventHandler = function(handler)
      ctx.handler = handler
      return true
    end,
  }

  missionCommands = {
    addSubMenuForGroup = function()
      return {}
    end,
    addCommandForGroup = function() end,
  }

  coalition = {
    addStaticObject = function(_, object)
      ctx.statics_created = ctx.statics_created + 1
      ctx.statics[object.name] = { name = object.name, pos = { x = object.x, y = 10, z = object.y } }
      return true
    end,
    addGroup = function(_, _, group)
      ctx.groups_created = ctx.groups_created + 1
      local unit_names = {}
      for _, unit in ipairs(group.units) do
        local record = ctx.make_unit(unit.name, unit.type)
        record.pos = { x = unit.x, y = 10, z = unit.y }
        unit_names[#unit_names + 1] = unit.name
      end
      ctx.groups[group.name] = { name = group.name, unit_names = unit_names }
      return true
    end,
    getGroups = function(_, category)
      if category ~= Group.Category.HELICOPTER then
        return {}
      end
      return ctx.player_groups
    end,
  }

  --- Advance one second and run every due schedule once. Only the recurring
  --- evaluation loop is re-armed; one-shot schedules stay spent.
  ctx.step = function()
    ctx.now = ctx.now + 1
    if ctx.tick_entry then
      ctx.tick_entry.done = false
    end
    for _, entry in ipairs(ctx.scheduled) do
      if not entry.done and entry.at <= ctx.now then
        entry.done = true
        entry.fn(entry.arg)
      end
    end
  end

  --- Place the fake aircraft and run `steps` evaluation ticks.
  ctx.fly = function(record, x, y, altitude, speed, steps)
    record.pos.x = x
    record.pos.z = y
    record.pos.y = altitude
    record.speed = speed
    for _ = 1, steps or 1 do
      ctx.step()
    end
  end

  --- The evaluation loop is the second schedule created during boot (setup()
  --- schedules the target hold first, then start_loop schedules the tick).
  ctx.capture_tick = function()
    assert(#ctx.scheduled >= 2, "expected the evaluation loop to be scheduled")
    ctx.tick_entry = ctx.scheduled[2]
    return ctx.tick_entry
  end

  ctx.log_contains = function(fragment)
    for _, line in ipairs(ctx.logs) do
      if line:find(fragment, 1, true) then
        return true
      end
    end
    return false
  end

  return ctx
end

return Mocks

-- World objects: cargo, obstacles, markers, infantry. Everything the range
-- spawns goes through here so it can be found, measured and cleaned up again.

local Range = {}
Range.__index = Range

-- Modules resolve through _G.HTG_PRELOADED when the shipping build has
-- pre-assembled them, and from disk otherwise. The dev-only branch is stripped
-- by build/pack-helicopter-training-miz.ps1.
local function load_relative(name)
  local preloaded = rawget(_G, "HTG_PRELOADED")
  if preloaded and preloaded[name] then
    return preloaded[name]
  end
  -- HTG:DEV-ONLY-BEGIN
  local root = rawget(_G, "MY_SCRIPTS_ROOT") or ""
  local chunk = loadfile(root .. "missions/helicopter-training/" .. name)
  assert(chunk, "cannot load " .. name)
  return chunk()
  -- HTG:DEV-ONLY-END
end

local Notify
local function notify_for(cfg)
  if not Notify then
    Notify = load_relative("notify.lua")
  end
  return Notify.new(cfg.mission_name, cfg.coalition)
end

function Range.new(cfg)
  local self = setmetatable({}, Range)
  self.cfg = cfg
  self.log = notify_for(cfg)
  self.seq = 0
  self.mark_id = 5000
  self.statics = {} -- [name] = { key, class, type, home_x, home_y, home_heading, site }
  self.groups = {} -- [name] = { kind = "troops"|"targets", ... }
  return self
end

function Range.radians(degrees)
  return (degrees or 0) * math.pi / 180
end

function Range:unique(prefix)
  self.seq = self.seq + 1
  return string.format("HTG_%s_%03d", prefix, self.seq)
end

-- ------------------------------------------------------------------ statics

--- Spawn one static object. `spec.heading` is in degrees.
-- Returns the object name, or nil plus a reason.
function Range:spawn_static(spec)
  local name = spec.name or self:unique(spec.prefix or "static")
  local object = {
    name = name,
    type = spec.type,
    shape_name = spec.shape_name,
    category = spec.category or "Cargos",
    canCargo = spec.can_cargo ~= false,
    x = spec.x,
    y = spec.y,
    heading = Range.radians(spec.heading or 0),
  }
  local ok, err = pcall(coalition.addStaticObject, self.cfg.country_id, object)
  if not ok then
    self.log:warn(string.format("static %s (%s) failed: %s", name, tostring(spec.type), tostring(err)))
    return nil, tostring(err)
  end
  return name
end

--- Spawn one entry from config.cargo at the cargo yard.
function Range:spawn_cargo(entry, x, y, heading, index)
  local unique_name = self:unique("CARGO")
  local sequence = unique_name:match("(%d+)$")
  index = index or 0
  local label =
    tostring(entry.label or entry.key or "LOAD"):upper():gsub("[^A-Z0-9]+", "_"):gsub("^_", ""):gsub("_$", "")
  local class = tostring(entry.class or "LOAD"):upper():gsub("[^A-Z0-9]+", "_"):gsub("^_", ""):gsub("_$", "")
  local name = string.format("HTG_LOAD_%02d_%s_%s_%s", index, label, class, sequence)
  local ok = self:spawn_static({
    name = name,
    type = entry.type,
    shape_name = entry.shape_name,
    x = x,
    y = y,
    heading = heading or 0,
  })
  if not ok then
    return nil
  end
  self.statics[name] = {
    key = entry.key,
    label = entry.label,
    class = entry.class,
    type = entry.type,
    home_x = x,
    home_y = y,
    home_heading = heading or 0,
  }
  return name
end

--- Ring of solid obstacles with a deliberate gap, to make a confined pad.
function Range:spawn_obstacle_ring(site, ring)
  ring = ring or {}
  local radius = ring.radius or 16
  local count = ring.count or 8
  local gap = ring.gap_deg or 60
  local types = ring.types
    or {
      { type = "f_bar_cargo", shape_name = "f_bar_cargo" },
      { type = "iso_container_small", shape_name = "iso_container_small_cargo" },
    }
  local span = 360 - gap
  local names = {}
  for i = 0, count - 1 do
    local bearing = -span / 2 + (i / math.max(count - 1, 1)) * span
    local x = site.x + radius * math.sin(Range.radians(bearing))
    local y = site.y + radius * math.cos(Range.radians(bearing))
    local pick = types[(i % #types) + 1]
    local name = self:spawn_static({
      prefix = "OBST",
      type = pick.type,
      shape_name = pick.shape_name,
      x = x,
      y = y,
      heading = bearing + 90,
    })
    if name then
      names[#names + 1] = name
      self.statics[name] = { key = "obstacle", label = "obstacle", class = "obstacle", type = pick.type }
    end
  end
  return names
end

function Range:static_object(name)
  local ok, object = pcall(StaticObject.getByName, name)
  if not ok or not object then
    return nil
  end
  return object
end

function Range:static_position(name)
  local object = self:static_object(name)
  if not object then
    return nil
  end
  local ok, point = pcall(function()
    return object:getPoint()
  end)
  if not ok or not point then
    return nil
  end
  return point.x, point.z, point.y -- x, north, altitude
end

function Range:destroy_static(name)
  local object = self:static_object(name)
  if object then
    pcall(function()
      object:destroy()
    end)
  end
  self.statics[name] = nil
end

-- ------------------------------------------------------------------- groups

--- Spawn a stationary infantry group on the ground.
-- spec: name, prefix, unit_type, count, x, y, country_id, skill, spread, heading
function Range:spawn_infantry(spec)
  local name = spec.name or self:unique(spec.prefix or "GRP")
  local count = spec.count or 8
  local spread = spec.spread or 18
  local unit_type = spec.unit_type or "Soldier M4"
  local country_id = spec.country_id or self.cfg.country_id
  local heading = spec.heading or 0

  local units = {}
  for i = 1, count do
    local bearing = (i - 1) * (360 / count)
    local ring = spread * (0.4 + 0.6 * (i % 2))
    local x = spec.x + ring * math.sin(Range.radians(bearing))
    local y = spec.y + ring * math.cos(Range.radians(bearing))
    units[i] = {
      name = string.format("%s-%d", name, i),
      type = unit_type,
      x = x,
      y = y,
      alt = spec.alt or 0,
      alt_type = "BARO",
      heading = Range.radians(heading),
      skill = spec.skill or "Average",
      playerCanDrive = false,
    }
  end

  local waypoint = {
    x = spec.x,
    y = spec.y,
    alt = spec.alt or 0,
    alt_type = "BARO",
    type = "Turning Point",
    action = "Off Road",
    speed = spec.speed or 0,
    ETA = 0,
    ETA_locked = true,
    formation_template = "",
    speed_locked = true,
    task = { id = "ComboTask", params = { tasks = {} } },
  }
  local group = {
    name = name,
    task = "Ground Nothing",
    hidden = false,
    uncontrolled = false,
    visible = true,
    units = units,
    route = { points = { waypoint } },
  }

  local ok, err = pcall(coalition.addGroup, country_id, Group.Category.GROUND, group)
  if not ok then
    self.log:warn(string.format("group %s failed: %s", name, tostring(err)))
    return nil, tostring(err)
  end
  self.groups[name] = {
    kind = spec.kind or "infantry",
    unit_type = unit_type,
    count = count,
    country_id = country_id,
    x = spec.x,
    y = spec.y,
    unit_names = (function()
      local names = {}
      for _, unit in ipairs(units) do
        names[#names + 1] = unit.name
      end
      return names
    end)(),
  }
  if spec.passive then
    self:make_passive(name)
  end
  return name
end

--- Keep a spawned group from shooting or manoeuvring (target practice).
function Range:make_passive(group_name)
  timer.scheduleFunction(function(arg)
    local group = Group.getByName(arg)
    if not group then
      return nil
    end
    local controller = group:getController()
    if controller then
      pcall(function()
        Controller.setOption(controller, AI.Option.Ground.id.ALARM_STATE, AI.Option.Ground.val.ALARM_STATE.GREEN)
        Controller.setOption(controller, AI.Option.Ground.id.ROE, AI.Option.Ground.val.ROE.WEAPON_HOLD)
        Controller.setOption(controller, AI.Option.Ground.id.DISPERSAL, AI.Option.Ground.val.DISPERSAL.OFF)
      end)
    end
    return nil
  end, group_name, timer.getTime() + 2)
end

function Range:group_object(name)
  local ok, group = pcall(Group.getByName, name)
  if not ok or not group then
    return nil
  end
  return group
end

function Range:group_alive(name)
  local group = self:group_object(name)
  if not group then
    return false
  end
  local ok, units = pcall(function()
    return group:getUnits()
  end)
  return ok and units ~= nil and #units > 0
end

function Range:destroy_group(name)
  local group = self:group_object(name)
  if group then
    pcall(function()
      group:destroy()
    end)
  end
  self.groups[name] = nil
end

--- Centre of a live group, or nil.
function Range:group_position(name)
  local group = self:group_object(name)
  if not group then
    return nil
  end
  local ok, units = pcall(function()
    return group:getUnits()
  end)
  if not ok or not units or #units == 0 then
    return nil
  end
  local point = units[1]:getPoint()
  return point.x, point.z, point.y
end

-- ------------------------------------------------------------------ markers

--- Add a persistent F10 map marker. Smoke is emitted only when explicitly asked.
function Range:mark_site(site, color, text, smoke)
  self.mark_id = self.mark_id + 1
  local height = site.height or 0
  local point = { x = site.x, y = height + 1, z = site.y }
  local ok = pcall(trigger.action.markToAll, self.mark_id, text or site.label or "SITE", point, false, "")
  if not ok then
    self.log:warn("markToAll failed for " .. tostring(text))
  end
  if smoke == true then
    self:smoke_at(site.x, site.y, height, color or trigger.smokeColor.Green)
  end
  return self.mark_id
end

--- Drop a single smoke grenade at a world position.
function Range:smoke_at(x, y, height, color)
  local point = { x = x, y = (height or 0) + 1, z = y }
  local ok, err = pcall(trigger.action.smoke, point, color or trigger.smokeColor.White)
  if not ok then
    self.log:warn("smoke failed: " .. tostring(err))
  end
  return ok
end

function Range:remove_mark(mark_id)
  pcall(trigger.action.removeMark, mark_id)
end

return Range

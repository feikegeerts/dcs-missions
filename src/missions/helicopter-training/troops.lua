-- Troop lift: embark at the staging area, disembark at the field landing zone.
--
-- Neither the UH-60L mod nor DCS itself gives a scriptable, scoreable troop
-- flow that covers both airframes the same way (the CH-47F has its own native
-- system, which needs mission-editor infantry setup and reports nothing back).
-- So the range runs its own: troops are removed from the world while aboard,
-- their mass is fed to the aircraft through setUnitInternalCargo so the flight
-- model feels the load, and they are re-created where you put them down.

local Troops = {}
Troops.__index = Troops

function Troops.new(cfg, range)
  local self = setmetatable({}, Troops)
  self.cfg = cfg
  self.range = range
  self.log = range.log
  self.rosters = {} -- [unit_name] = { pax = { {type, name, country} }, capacity = n }
  self.squad_group = nil
  self.delivered = 0
  return self
end

--- Capacity for an airframe type name.
function Troops:capacity_for(type_name)
  return self.cfg.troop_capacity[type_name] or self.cfg.troop_capacity_default
end

--- Spawn (or respawn) the squad at the staging site.
function Troops:spawn_squad(site)
  if self.squad_group then
    self.range:destroy_group(self.squad_group)
  end
  local group = self.range:spawn_infantry({
    name = "HTG_SQUAD",
    unit_type = "Soldier M4",
    count = 12,
    x = site.x,
    y = site.y,
    alt = site.height or 0,
    spread = 22,
    skill = "Average",
    kind = "squad",
  })
  self.squad_group = group
  return group
end

--- Live, still-in-the-world members of the squad.
function Troops:squad_remaining()
  local record = self.squad_group and self.range.groups[self.squad_group]
  if not record then
    return {}
  end
  local remaining = {}
  for _, unit_name in ipairs(record.unit_names or {}) do
    local ok, unit = pcall(Unit.getByName, unit_name)
    if ok and unit then
      remaining[#remaining + 1] = unit_name
    end
  end
  return remaining
end

function Troops:roster(unit_name)
  local roster = self.rosters[unit_name]
  if not roster then
    roster = { pax = {}, capacity = self.cfg.troop_capacity_default }
    self.rosters[unit_name] = roster
  end
  return roster
end

function Troops:count(unit_name)
  return #self:roster(unit_name).pax
end

--- Move up to `capacity` squad members aboard the aircraft.
-- Returns the number taken.
function Troops:load(unit_name, type_name)
  local roster = self:roster(unit_name)
  roster.capacity = self:capacity_for(type_name)
  local room = roster.capacity - #roster.pax
  if room <= 0 then
    return 0
  end

  local taken = 0
  for _, unit_name_in_squad in ipairs(self:squad_remaining()) do
    if taken >= room then
      break
    end
    local ok, unit = pcall(Unit.getByName, unit_name_in_squad)
    if ok and unit then
      local unit_type = unit:getTypeName()
      local country = unit:getCountry()
      roster.pax[#roster.pax + 1] = { type = unit_type, name = unit_name_in_squad, country = country }
      pcall(function()
        unit:destroy()
      end)
      taken = taken + 1
    end
  end

  if taken > 0 then
    self:apply_load(unit_name)
  end
  return taken
end

--- Feed the load into the flight model.
function Troops:apply_load(unit_name)
  local mass = self:count(unit_name) * self.cfg.troop_mass_kg
  pcall(trigger.action.setUnitInternalCargo, unit_name, mass)
  return mass
end

--- Put everyone down at (x, y) and empty the aircraft.
-- Returns the number disembarked.
function Troops:unload(unit_name, x, y, height)
  local roster = self:roster(unit_name)
  local pax = roster.pax
  if #pax == 0 then
    return 0
  end

  local group_name = string.format("HTG_LANDED_%d", math.floor(timer.getAbsTime()))
  local count = #pax
  local units = {}
  for index, person in ipairs(pax) do
    local bearing = (index - 1) * (360 / count)
    local radius = 12 + (index % 3) * 9
    units[index] = {
      name = string.format("%s-%d", group_name, index),
      type = person.type,
      x = x + radius * math.sin(bearing * math.pi / 180),
      y = y + radius * math.cos(bearing * math.pi / 180),
      alt = height or 0,
      alt_type = "BARO",
      heading = 0,
      skill = "Average",
      playerCanDrive = false,
    }
  end
  local waypoint = {
    x = x,
    y = y,
    alt = height or 0,
    alt_type = "BARO",
    type = "Turning Point",
    action = "Off Road",
    speed = 0,
    ETA = 0,
    ETA_locked = true,
    formation_template = "",
    speed_locked = true,
    task = { id = "ComboTask", params = { tasks = {} } },
  }
  local ok, err = pcall(coalition.addGroup, self.cfg.country_id, Group.Category.GROUND, {
    name = group_name,
    task = "Ground Nothing",
    hidden = false,
    uncontrolled = false,
    visible = true,
    units = units,
    route = { points = { waypoint } },
  })
  if not ok then
    self.log:warn("unload failed: " .. tostring(err))
    return 0
  end

  roster.pax = {}
  pcall(trigger.action.setUnitInternalCargo, unit_name, 0)
  self.delivered = self.delivered + count
  return count
end

--- Clear the roster without spawning anyone (aircraft lost, range reset).
function Troops:abort(unit_name)
  local roster = self.rosters[unit_name]
  if roster then
    roster.pax = {}
  end
  pcall(trigger.action.setUnitInternalCargo, unit_name, 0)
end

function Troops:reset()
  self.rosters = {}
  self.delivered = 0
end

return Troops

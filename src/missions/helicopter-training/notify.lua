-- Messaging helpers. Every range message goes out through here so the log and
-- the in-cockpit text stay in step.

local Notify = {}
Notify.__index = Notify

function Notify.new(prefix, coalition)
  local self = setmetatable({}, Notify)
  self.prefix = prefix or "range"
  self.coalition = coalition or 2
  return self
end

--- Always-visible breadcrumb in dcs.log.
function Notify:log(message)
  env.info(string.format("[%s] %s", self.prefix, message))
end

function Notify:warn(message)
  env.warning(string.format("[%s] %s", self.prefix, message))
end

--- Range-wide text.
function Notify:all(message, seconds)
  trigger.action.outTextForCoalition(self.coalition, message, seconds or 12)
  self:log(message:gsub("\n", " | "))
end

--- Text to one aircraft, by unit name.
function Notify:unit(unit_name, message, seconds)
  if not unit_name then
    return
  end
  trigger.action.outTextForUnit(unit_name, message, seconds or 12, false)
end

--- Text to one group, by group id.
function Notify:group(group_id, message, seconds)
  if not group_id then
    return
  end
  trigger.action.outTextForGroup(group_id, message, seconds or 12, false)
end

return Notify

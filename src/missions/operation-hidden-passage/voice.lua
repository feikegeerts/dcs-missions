-- Pre-rendered voice lines for Operation Hidden Passage.
-- Keep Ogg Vorbis assets in Sounds/OHP/ inside the .miz. The build copies
-- src/missions/operation-hidden-passage/sounds/*.ogg into that folder.
local M = {}

-- Durations are the encoded file length plus a small tail. DCS does not report
-- outSound duration, so the queue relies on these values to avoid overlap.
local LINES = {
  -- Crew-chief recordings are selected by the actual carrier's aircraft type.
  -- Transport eligibility and objective ownership remain in the mission adapter.
  uh60_boarding_start = {
    file = "Sounds/OHP/uh60-boarding-start.ogg",
    duration = 4.6,
    text = "Package, move to the helicopter! You're clear to board - go, go, go!",
  },
  uh60_boarding_complete = {
    file = "Sounds/OHP/uh60-boarding-complete.ogg",
    duration = 4.4,
    text = "All three aboard! Doors closing. Let's get out of here!",
  },
  boarding_start = {
    file = "Sounds/OHP/boarding-start.ogg",
    duration = 5.4,
    text = "Personnel boarding. Remain landed until the party disappears and 'Three personnel aboard' appears.",
  },
  boarding_hvt_aboard = {
    -- Shared package confirmation: valid for either transport aircraft.
    file = "Sounds/OHP/boarding-hvt-aboard.ogg",
    duration = 3.2,
    text = "All three aboard.",
  },
  boarding_confirm = {
    file = "Sounds/OHP/boarding-confirm.ogg",
    duration = 4.5,
    text = "Three personnel aboard. Return to Hatay and unload inside OHP-Hatay-Return.",
  },
  mule_one_cleared_for_pickup = {
    file = "Sounds/OHP/mule-one-cleared-for-pickup.ogg",
    duration = 10.1,
    text = "Mule One, cleared inbound to the pickup. Package is ready for extraction. Report established on station.",
  },
  raven_one_cleared_for_support = {
    file = "Sounds/OHP/raven-one-cleared-for-support.ogg",
    duration = 11.3,
    text = "Raven One, cleared to support Mule One's extraction. Cover the approach and departure, and stand by for backup pickup.",
  },
  hvt_under_fire = {
    file = "Sounds/OHP/mule-one-hvt-under-fire.ogg",
    duration = 12.6,
    text = "Mule One, HVT under fire.",
  },
  mission_success = {
    file = "Sounds/OHP/hidden-passage-success.ogg",
    duration = 10.6,
    text = "Operation Hidden Passage complete. All three personnel delivered safely to Hatay.",
  },
}

local function line_for(id)
  local line = LINES[id]
  assert(line, "Unknown voice line: " .. tostring(id))
  return line
end

function M.new(config)
  local self = { config = config, queue = {}, busy_until = 0, pumping = false }

  local function play_line(line, recipient)
    -- Do not deliver a queued call to a replacement aircraft after a re-slot.
    if recipient and (not recipient.unit:IsAlive() or recipient.unit:GetID() ~= recipient.id) then
      return
    end
    local now = timer.getTime()
    local message = MESSAGE:New(line.text, math.max(20, line.duration + 2), config.title)
    if recipient then
      USERSOUND:New(line.file):ToUnit(recipient.unit)
      message:ToUnit(recipient.unit)
    else
      -- Retained for explicit mission-wide calls; crew calls always pass a unit.
      trigger.action.outSoundForCoalition(coalition.side.BLUE, line.file)
      message:ToCoalition(coalition.side.BLUE)
    end
    self.busy_until = now + line.duration + 0.35
    env.info(string.format("[hidden-passage] voice %s (%.1fs)", line.file, line.duration))
  end

  local function pump()
    local now = timer.getTime()
    if #self.queue == 0 then
      self.pumping = false
      return nil
    end
    local next_at = math.max(self.busy_until, self.queue[1].at)
    if now < next_at then
      return next_at
    end
    local item = table.remove(self.queue, 1)
    local ok, err = pcall(play_line, item.line, item.recipient)
    if not ok then
      env.error("[hidden-passage] voice: " .. tostring(err))
      self.busy_until = math.max(self.busy_until, now + 0.1)
    end
    if #self.queue == 0 then
      self.pumping = false
      return nil
    end
    return math.max(timer.getTime() + 0.05, self.busy_until)
  end

  function self:play(id, delay, unit)
    local line = line_for(id)
    local recipient = unit and { unit = unit, id = unit:GetID() } or nil
    local now = timer.getTime()
    if (not delay or delay <= 0) and not self.pumping and #self.queue == 0 and now >= self.busy_until then
      local ok, err = pcall(play_line, line, recipient)
      if not ok then
        env.error("[hidden-passage] voice: " .. tostring(err))
      end
      return
    end
    self.queue[#self.queue + 1] = { line = line, at = now + (delay or 0), recipient = recipient }
    if not self.pumping then
      self.pumping = true
      timer.scheduleFunction(pump, nil, math.max(now + 0.05, self.busy_until, self.queue[1].at))
    end
  end

  function self:boarding_start(unit)
    local id = unit:GetTypeName() == "UH-60L" and "uh60_boarding_start" or "boarding_start"
    self:play(id, nil, unit)
  end

  function self:boarding_complete(unit)
    self:play("boarding_hvt_aboard", nil, unit)
    local id = unit:GetTypeName() == "UH-60L" and "uh60_boarding_complete" or "boarding_confirm"
    self:play(id, nil, unit)
  end

  function self:stop()
    self.queue = {}
    self.busy_until = 0
    self.pumping = false
  end

  return self
end

return M

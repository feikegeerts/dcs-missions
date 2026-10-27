-- Pre-rendered voice lines for Operation Hidden Passage.
-- Keep Ogg Vorbis assets in Sounds/OHP/ inside the .miz. The build copies
-- src/missions/operation-hidden-passage/sounds/*.ogg into that folder.
-- All 27 clips have the approved 0.9 volume render; see voice-gain.json.
-- Queue timing and dialogue are unchanged. Do not apply gain a second time.
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
    caption = "Boarding. Remain landed until all three are aboard.",
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
    caption = "Boarding. Remain landed until all three are aboard.",
  },
  boarding_hvt_aboard = {
    -- Shared package confirmation: valid for either transport aircraft.
    file = "Sounds/OHP/boarding-hvt-aboard.ogg",
    duration = 3.2,
    text = "All three aboard.",
    caption = "Three personnel aboard.",
  },
  boarding_confirm = {
    file = "Sounds/OHP/boarding-confirm.ogg",
    duration = 4.5,
    text = "Three personnel aboard. Return to Hatay and unload inside OHP-Hatay-Return.",
  },
  mule_one_cleared_for_pickup = {
    file = "Sounds/OHP/mule-one-cleared-for-pickup.ogg",
    duration = 6.8,
    text = "Mule One, Overlord. The package is standing by at the pickup. Coordinate your approach with the flight.",
  },
  raven_one_cleared_for_support = {
    file = "Sounds/OHP/raven-one-cleared-for-support.ogg",
    duration = 7.5,
    text = "Raven One, Overlord. You're assigned to the extraction package. Cover the approach and departure, and stand by for pickup.",
  },
  hvt_under_fire = {
    file = "Sounds/OHP/mule-one-hvt-under-fire.ogg",
    duration = 6.1,
    text = "Overlord, they're closing in on us! All three of us are still here. We need that helicopter!",
    caption = "Enemy closing on the pickup.",
  },
  mule_one_smoke_request = {
    file = "Sounds/OHP/mule1-smoke-request.ogg",
    duration = 5.3,
    text = "Ground, Mule One on final. Requesting green smoke at the pickup.",
  },
  raven_one_smoke_request = {
    file = "Sounds/OHP/raven-smoke-request.ogg",
    duration = 4.6,
    text = "Ground, Raven One on final. Requesting green smoke at the pickup.",
  },
  popping_green_smoke_normal = {
    file = "Sounds/OHP/popping-green-smoke-normal.ogg",
    duration = 2.6,
    text = "Copy. Popping green smoke now.",
  },
  popping_green_smoke_under_fire = {
    file = "Sounds/OHP/popping-green-smoke-under-fire.ogg",
    duration = 3.7,
    text = "Copy. Popping green smoke now.",
  },
  mission_success = {
    overlord_confirmation = true,
    file = "Sounds/OHP/hidden-passage-success.ogg",
    duration = 10.6,
    text = "Operation Hidden Passage complete. All three personnel delivered safely to Hatay.",
    caption = "Operation complete.",
  },
  cas_convoy_tasking = {
    file = "Sounds/OHP/overlord-cas-convoy-tasking.ogg",
    duration = 9.6,
    text = "CAS, Overlord. An armed convoy is moving toward the pickup. Intercept it along the road. Keep your attacks clear of the extraction party.",
  },
  cas_checkpoint_tasking = {
    overlord_confirmation = true, -- Includes confirmation that the package is aboard.
    file = "Sounds/OHP/overlord-cas-checkpoint-tasking.ogg",
    duration = 9.5,
    text = "CAS, Overlord. The package is aboard. RPG infantry are holding the north-road checkpoint. Clear that position and cover the helicopters' departure.",
  },
  sead_tasking = {
    file = "Sounds/OHP/overlord-sead-tasking.ogg",
    duration = 9.7,
    text = "CAP, Overlord. A Kub SAM site is active near the pickup. Destroy its tracking radar before the helicopters approach, then cover the extraction corridor.",
  },
  kub_neutralised = {
    overlord_confirmation = true,
    file = "Sounds/OHP/overlord-kub-neutralised.ogg",
    duration = 10.7,
    text = "All stations, Overlord. The Kub tracking radar is down. CAP, cover the extraction corridor. Helicopter crews, remain alert for other threats.",
  },
  fighters_launching = {
    overlord_confirmation = true,
    file = "Sounds/OHP/overlord-fighters-launching.ogg",
    duration = 7.4,
    text = "CAP, Overlord. Enemy fighters are preparing to launch. Expect an interception. Protect the extraction package.",
  },
  hind_launching = {
    overlord_confirmation = true,
    file = "Sounds/OHP/overlord-hind-launching.ogg",
    duration = 7.4,
    text = "All stations, Overlord. An enemy Hind is preparing to launch. Watch for a low-level threat along the extraction corridor.",
  },
  taking_fire = {
    file = "Sounds/OHP/hvt-taking-fire.ogg",
    duration = 4.2,
    text = "They're firing on us! We're keeping our heads down. Get us out of here!",
  },
  mission_failed = {
    overlord_confirmation = true,
    file = "Sounds/OHP/overlord-extraction-failed.ogg",
    duration = 6.1,
    text = "All stations, Overlord. The extraction has failed. Abort the operation.",
  },
  cas_departure = {
    disabled = true, -- Retain the asset, but never speak for a departing human pilot.
    file = "Sounds/OHP/cas-departure.ogg",
    duration = 3.4,
    text = "Overlord, CAS airborne. Moving to intercept the convoy.",
  },
  cap_departure = {
    disabled = true,
    file = "Sounds/OHP/cap-departure.ogg",
    duration = 4.8,
    text = "Overlord, CAP airborne. We'll deal with the Kub, then cover the extraction corridor.",
  },
  cas_convoy_destroyed = {
    file = "Sounds/OHP/cas-convoy-destroyed.ogg",
    duration = 2.8,
    text = "Overlord, CAS. The convoy is destroyed.",
  },
  cas_checkpoint_cleared = {
    file = "Sounds/OHP/cas-checkpoint-cleared.ogg",
    duration = 5.1,
    text = "Overlord, CAS. The north-road checkpoint is clear. Keep watching for other threats on the approach.",
  },
  cap_fighters_destroyed = {
    file = "Sounds/OHP/cap-fighters-destroyed.ogg",
    duration = 4.8,
    text = "Overlord, CAP. Both enemy fighters are down. Continuing cover for the extraction.",
  },
  cap_hind_destroyed = {
    file = "Sounds/OHP/cap-hind-destroyed.ogg",
    duration = 4.3,
    text = "Overlord, CAP. The Hind is down. Continuing cover for the helicopters.",
  },
}

-- Urgent pickup/crew calls jump queued routine intelligence, never interrupting
-- an already playing clip. Equal priority remains FIFO (including smoke pairs).
local PRIORITY = {
  boarding_start = 100,
  uh60_boarding_start = 100,
  boarding_hvt_aboard = 100,
  boarding_confirm = 100,
  uh60_boarding_complete = 100,
  taking_fire = 90,
  hvt_under_fire = 90,
  mule_one_smoke_request = 80,
  raven_one_smoke_request = 80,
  popping_green_smoke_normal = 80,
  popping_green_smoke_under_fire = 80,
  mission_failed = 1000,
  cas_checkpoint_tasking = 70, -- Do not strand the 5 s task behind routine 20 s intelligence; crew calls still lead.
}

local function line_for(id)
  local line = LINES[id]
  assert(line, "Unknown voice line: " .. tostring(id))
  return line
end

function M.new(config)
  local self = { config = config, queue = {}, busy_until = 0, pumping = false, epoch = 0 }

  local function eligible(item)
    local ok, valid = pcall(function()
      local recipient = item.recipient
      if recipient and (not recipient.unit:IsAlive() or recipient.unit:GetID() ~= recipient.id) then
        return false
      end
      return not item.valid or item.valid()
    end)
    if not ok then
      env.error("[hidden-passage] voice eligibility: " .. tostring(valid))
    end
    return ok and valid
  end

  local function play_line(item)
    if not eligible(item) then
      return
    end
    local line, recipient = item.line, item.recipient
    local now = timer.getTime()
    if recipient then
      USERSOUND:New(line.file):ToUnit(recipient.unit)
    else
      -- Retained for explicit mission-wide calls; crew calls always pass a unit.
      trigger.action.outSoundForCoalition(coalition.side.BLUE, line.file)
    end
    if item.announcement then
      MESSAGE:New(item.announcement, 20, config.title):ToCoalition(coalition.side.BLUE)
      env.info("[hidden-passage] " .. item.announcement)
    end
    if line.caption then
      local message = MESSAGE:New(line.caption, 10, config.title)
      if recipient then
        message:ToUnit(recipient.unit)
      else
        message:ToCoalition(coalition.side.BLUE)
      end
    end
    self.busy_until = now + line.duration + 0.35
    env.info(string.format("[hidden-passage] voice %s (%.1fs)", line.file, line.duration))
  end

  local function pump(epoch)
    if epoch ~= self.epoch then
      return nil -- A rescheduled/cleared queue invalidates old DCS callbacks.
    end
    local now = timer.getTime()
    while #self.queue > 0 and not eligible(self.queue[1]) do
      table.remove(self.queue, 1)
    end
    if #self.queue == 0 then
      self.pumping = false
      return nil
    end
    local next_item = self.queue[1]
    local next_at = math.max(self.busy_until + (next_item.gap_after_previous or 0), next_item.at)
    if now < next_at then
      return next_at
    end
    local item = table.remove(self.queue, 1)
    local ok, err = pcall(play_line, item)
    if not ok then
      env.error("[hidden-passage] voice: " .. tostring(err))
      self.busy_until = math.max(self.busy_until, now + 0.1)
    end
    if #self.queue == 0 then
      self.pumping = false
      return nil
    end
    next_item = self.queue[1]
    return math.max(timer.getTime() + 0.05, self.busy_until + (next_item.gap_after_previous or 0), next_item.at)
  end

  function self:play(id, delay, unit, gap_after_previous, valid, announcement)
    if self.aborted and id ~= "mission_failed" then
      return
    end
    local line = line_for(id)
    if line.disabled then
      return
    end
    -- Minimum reporting latency from the observed event, not another pause
    -- after queueing. Explicit delays and existing audio can extend it.
    if line.overlord_confirmation then
      local minimum = id == "cas_checkpoint_tasking" and config.cas.checkpoint_tasking_delay_s
        or config.overlord_confirmation_delay_s
      delay = math.max(delay or 0, minimum)
    end
    local recipient = unit and { unit = unit, id = unit:GetID() } or nil
    local now = timer.getTime()
    local item = {
      line = line,
      at = now + (delay or 0),
      recipient = recipient,
      gap_after_previous = gap_after_previous,
      valid = valid,
      announcement = announcement,
      priority = PRIORITY[id] or 0,
    }
    if
      (not delay or delay <= 0)
      and (not gap_after_previous or gap_after_previous <= 0)
      and not self.pumping
      and #self.queue == 0
      and now >= self.busy_until
    then
      local ok, err = pcall(play_line, item)
      if not ok then
        env.error("[hidden-passage] voice: " .. tostring(err))
      end
      return
    end
    local index = #self.queue + 1
    for i, queued in ipairs(self.queue) do
      if item.priority > queued.priority then
        index = i
        break
      end
    end
    table.insert(self.queue, index, item)
    -- Re-arm even if a lower-priority head was waiting on a long delay/gap.
    -- Epoch guards make the old scheduled pump harmless.
    self.pumping = true
    self.epoch = self.epoch + 1
    local first = self.queue[1]
    timer.scheduleFunction(
      pump,
      self.epoch,
      math.max(now + 0.05, self.busy_until + (first.gap_after_previous or 0), first.at)
    )
  end

  function self:radio(id, valid, announcement)
    self:play(id, nil, nil, nil, valid, announcement)
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

  function self:request_smoke(unit, under_fire)
    local request = unit:GetTypeName() == "UH-60L" and "raven_one_smoke_request" or "mule_one_smoke_request"
    self:play(request, nil, unit)
    self:play(under_fire and "popping_green_smoke_under_fire" or "popping_green_smoke_normal", nil, unit, 5)
  end

  function self:stop()
    self.queue = {}
    self.epoch = self.epoch + 1
    self.pumping = false
    -- DCS cannot stop an outSound already playing: retain its occupied time.
  end

  function self:abort(delay)
    if self.aborted then
      return
    end
    self:stop()
    self.aborted = true
    -- Cancel stale chatter immediately, but give Overlord time to learn what
    -- happened. Playback still waits for any clip already in progress.
    self:play("mission_failed", delay)
  end

  return self
end

return M

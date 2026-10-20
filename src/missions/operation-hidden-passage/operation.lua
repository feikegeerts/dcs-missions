-- Pure objective accounting: one party, one carrier claimed at boarding start.
-- Losing/replacing the claimed carrier or party requires a mission restart.
local M = {}

function M.new(party_key, party_size)
  local self = { phase = "waiting", party_key = party_key, party_size = party_size }

  function self:fail(reason)
    if self.phase == "complete" or self.phase == "failed" then
      return false
    end
    self.phase, self.reason = "failed", reason
    return true
  end

  function self:lock_carrier(id)
    if self.phase == "complete" or self.phase == "failed" then
      return false
    end
    if not id then
      return false
    end
    if self.carrier_id and self.carrier_id ~= id then
      self:fail("Aircraft replaced; restart the mission.")
      return false
    end
    self.carrier_id = id
    return true
  end

  function self:begin_boarding(id)
    if self.phase ~= "waiting" or self.carrier_id ~= id then
      return false
    end
    self.phase = "boarding"
    return true
  end

  function self:boarded(id, party, count)
    if self.phase ~= "boarding" or self.carrier_id ~= id or party ~= self.party_key then
      return false
    end
    if count ~= self.party_size then
      self:fail("Objective party is no longer intact.")
      return false
    end
    self.phase = "aboard"
    return true
  end

  function self:deployed(id, party, count, inside_return, landed)
    if self.phase ~= "aboard" or self.carrier_id ~= id then
      return false, "Not confirmed aboard. Wait for boarding confirmation before unloading."
    end
    if count ~= self.party_size then
      self:fail("Objective party is no longer intact.")
      return false, self.reason
    end
    self.party_key = party
    if inside_return and landed then
      self.phase = "complete"
      return true, "Operation complete: all three personnel delivered to Hatay."
    end
    self.phase = "waiting"
    return false, "Not delivered: recover the party and unload inside the Hatay return area while landed."
  end

  return self
end

return M

-- bvr_cost_tracker.lua
-- Standalone cost tracking module for DCS missions
-- Usage: local CostTracker = dofile("bvr_cost_tracker.lua")
local CostTracker = {}
CostTracker.__index = CostTracker

function CostTracker:New()
    local self = setmetatable({}, CostTracker)
    self.stats = {
        blue = {
            aircraftLost = 0,
            missilesFired = 0,
            totalCost = 0
        },
        red = {
            aircraftLost = 0,
            missilesFired = 0,
            totalCost = 0
        }
    }
    return self
end

function CostTracker:Reset()
    self.stats = {
        blue = {
            aircraftLost = 0,
            missilesFired = 0,
            totalCost = 0
        },
        red = {
            aircraftLost = 0,
            missilesFired = 0,
            totalCost = 0
        }
    }
end

function CostTracker:OnAircraftLost(coalition, typeName, costTable)
    if not (coalition and typeName and costTable) then
        env.info("[BVR DEBUG] OnAircraftLost called with missing parameters: coalition=" .. tostring(coalition) ..
                     ", typeName=" .. tostring(typeName))
        return
    end
    env.info("[BVR DEBUG] OnAircraftLost: coalition param value=" .. tostring(coalition) .. ", type=" .. type(coalition))
    env.info("[BVR DEBUG] OnAircraftLost: self instance=" .. tostring(self))
    local c = self.stats[coalition]
    if not c then
        env.info("[BVR DEBUG] OnAircraftLost: No stats table for coalition " .. tostring(coalition))
        return
    end
    env.info("[BVR DEBUG] OnAircraftLost: aircraftLost before increment=" .. tostring(c.aircraftLost))
    c.aircraftLost = c.aircraftLost + 1
    env.info("[BVR DEBUG] OnAircraftLost: aircraftLost after increment=" .. tostring(c.aircraftLost))
    local cost = costTable[typeName] or 0
    env.info("[BVR DEBUG] Aircraft cost lookup: typeName=" .. tostring(typeName) .. ", cost=$" .. tostring(cost) .. "M")
    c.totalCost = c.totalCost + cost
    env.info("[BVR DEBUG] Aircraft lost: coalition=" .. tostring(coalition) .. ", typeName=" .. tostring(typeName) ..
                 ", cost=$" .. tostring(cost) .. "M, totalCost=$" .. tostring(c.totalCost) .. "M")
end

function CostTracker:OnMissileFired(coalition, typeName, costTable)
    if not (coalition and typeName and costTable) then
        env.info("[BVR DEBUG] OnMissileFired called with missing parameters: coalition=" .. tostring(coalition) ..
                     ", typeName=" .. tostring(typeName))
        return
    end
    local c = self.stats[coalition]
    if not c then
        env.info("[BVR DEBUG] OnMissileFired: No stats table for coalition " .. tostring(coalition))
        return
    end
    c.missilesFired = c.missilesFired + 1
    local cost = costTable[typeName] or 0
    env.info("[BVR DEBUG] Missile cost lookup: typeName=" .. tostring(typeName) .. ", cost=$" .. tostring(cost) .. "M")
    c.totalCost = c.totalCost + cost
    env.info("[BVR DEBUG] Missile fired: coalition=" .. tostring(coalition) .. ", typeName=" .. tostring(typeName) ..
                 ", cost=$" .. tostring(cost) .. "M, totalCost=$" .. tostring(c.totalCost) .. "M")
end

function CostTracker:GetStats()
    return self.stats
end

return CostTracker

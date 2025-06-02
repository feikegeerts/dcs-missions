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
        env.info("OnAircraftLost: Missing parameters")
        return
    end

    local stats = self.stats[coalition]
    if not stats then
        env.info("OnAircraftLost: Invalid coalition " .. tostring(coalition))
        return
    end

    stats.aircraftLost = stats.aircraftLost + 1
    local cost = costTable[typeName] or 0
    stats.totalCost = stats.totalCost + cost

    env.info(string.format("Aircraft lost: %s %s ($%.1fM) - Total: $%.2fM", coalition:upper(), typeName, cost,
        stats.totalCost))
end

function CostTracker:OnMissileFired(coalition, typeName, costTable)
    if not (coalition and typeName and costTable) then
        env.info("OnMissileFired: Missing parameters")
        return
    end

    local stats = self.stats[coalition]
    if not stats then
        env.info("OnMissileFired: Invalid coalition " .. tostring(coalition))
        return
    end

    stats.missilesFired = stats.missilesFired + 1
    local cost = costTable[typeName] or 0
    stats.totalCost = stats.totalCost + cost

    env.info(string.format("Missile fired: %s %s ($%.2fM) - Total: $%.2fM", coalition:upper(), typeName, cost,
        stats.totalCost))
end

function CostTracker:GetStats()
    return self.stats
end

return CostTracker

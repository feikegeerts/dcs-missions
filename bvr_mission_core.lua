DynamicBVRMission = {}
DynamicBVRMission.__index = DynamicBVRMission

-- Add this to the DynamicBVRMission:New() function
function DynamicBVRMission:New()
    local self = setmetatable({}, DynamicBVRMission)

    -- MOOSE Set to track blue players
    self.BluePlayerSet = SET_CLIENT:New():FilterCoalitions("blue"):FilterStart()

    -- MOOSE Set to track spawned RED groups
    self.SpawnedRedGroups = SET_GROUP:New()

    -- Scheduler for periodic checks
    self.PlayerCheckScheduler = nil
    self.CostDisplayScheduler = nil

    -- Initialize loss tracking
    self:InitializeLossTracking()

    return self
end

function DynamicBVRMission:CountAirborneBluePlayers()
    local count = 0

    -- Use MOOSE SET to count airborne blue players
    self.BluePlayerSet:ForEachClient(function(client)
        if client:IsAlive() and client:GetPlayerName() and client:InAir() then
            count = count + 1
        end
    end)

    return count
end

function DynamicBVRMission:CountBluePlayers()
    local count = 0

    -- Use MOOSE SET to count active blue players (alive and spawned in)
    self.BluePlayerSet:ForEachClient(function(client)
        if client:IsAlive() and client:GetPlayerName() then
            count = count + 1
        end
    end)

    return count
end

function DynamicBVRMission:CleanupSpawnedGroups()
    env.info("Cleaning up spawned RED groups...")

    -- Use SPAWN's built-in cleanup if available
    if self.RandomSpawner then
        self.RandomSpawner:CleanUpSpawnedGroups()
        env.info("Used SPAWN built-in cleanup")
    end

    -- Also clean our SET
    self.SpawnedRedGroups:RemoveGroupsByName(".*") -- Remove all groups

    -- Update display
    self:UpdatePermanentCostDisplay()
end

function DynamicBVRMission:UpdatePermanentCostDisplay()
    -- Count active RED aircraft units (not groups)
    local activeRedAircraft = 0
    local activeRedGroups = 0

    if self.RandomSpawner then
        activeRedGroups = self.RandomSpawner:GetAliveGroupsCount()

        -- Count individual units in active groups
        self.SpawnedRedGroups:ForEachGroup(function(group)
            if group:IsAlive() then
                activeRedAircraft = activeRedAircraft + group:GetSize()
            end
        end)
    end

    -- Get cost overview from BVR_CostTracker
    local costStats = BVR_CostTracker:GetStats()

    -- Determine who's winning based on cost efficiency
    local winner = ""
    local costDiff = math.abs(costStats.blue.totalCost - costStats.red.totalCost)
    if costStats.blue.totalCost > costStats.red.totalCost then
        winner = string.format("RED WINNING (+$%.1fM)", costDiff)
    elseif costStats.red.totalCost > costStats.blue.totalCost then
        winner = string.format("BLUE WINNING (+$%.1fM)", costDiff)
    else
        winner = "TIED"
    end

    local messageText = string.format("═══ BVR MISSION STATUS ═══\n" ..
                                          "ACTIVE RED: %d aircraft in %d groups\n\n" .. "COST BATTLE:\n" ..
                                          "BLUE: %d lost, %d missiles = $%.1fM\n" ..
                                          "RED:  %d lost, %d missiles = $%.1fM\n\n" .. "%s", activeRedAircraft,
        activeRedGroups, costStats.blue.aircraftLost, costStats.blue.missilesFired, costStats.blue.totalCost,
        costStats.red.aircraftLost, costStats.red.missilesFired, costStats.red.totalCost, winner)

    -- Use MOOSE MESSAGE with ClearScreen parameter to prevent stacking
    MESSAGE:New(messageText, 999, "BVR Status", true):ToAll()

    env.info("Cost display updated: Active aircraft: " .. activeRedAircraft .. " in " .. activeRedGroups .. " groups")
end

-- Start player monitoring system
function DynamicBVRMission:StartPlayerMonitoring()
    env.info("Starting player monitoring with MOOSE Scheduler...")

    -- Use MOOSE SCHEDULER for periodic checks
    self.PlayerCheckScheduler = SCHEDULER:New(nil, function()
        local currentBluePlayers = self:CountBluePlayers()
        local airborneBluePlayers = self:CountAirborneBluePlayers()

        -- Clean up dead groups first
        self:CleanupDeadGroups()

        local activeGroups = 0
        if self.RandomSpawner then
            activeGroups = self.RandomSpawner:GetAliveGroupsCount()
        end

        env.info("Scheduler check - Blue Players: " .. currentBluePlayers .. ", Airborne: " .. airborneBluePlayers ..
                     ", Active RED groups: " .. activeGroups)

        -- Only spawn if we have airborne players and no RED fighters currently active
        if airborneBluePlayers > 0 and activeGroups == 0 then
            env.info("Conditions met - airborne players detected, spawning fighters!")
            self:SpawnRedFighters()
        elseif currentBluePlayers == 0 then
            env.info("No blue players detected")
        elseif airborneBluePlayers == 0 and currentBluePlayers > 0 then
            env.info("Blue players online (" .. currentBluePlayers .. ") but none airborne yet")
        elseif activeGroups > 0 then
            env.info("RED fighters already active (" .. activeGroups .. " groups) - waiting for combat")
        end
    end, {}, 0, 15) -- Start immediately, repeat every 15 seconds

    -- Separate scheduler for cost display updates (once per minute)
    self.CostDisplayScheduler = SCHEDULER:New(nil, function()
        self:UpdatePermanentCostDisplay()
    end, {}, 10, 60) -- Start after 10 seconds, repeat every 60 seconds
end

-- Clean up dead groups using SPAWN's built-in tracking
function DynamicBVRMission:CleanupDeadGroups()
    local removedGroups = 0
    local groupsToRemove = {}

    -- Find dead groups that need to be removed from our SET
    self.SpawnedRedGroups:ForEachGroup(function(group)
        if not group:IsAlive() or group:GetSize() == 0 then
            table.insert(groupsToRemove, group:GetName())
            env.info("Found dead group to remove: " .. group:GetName())
        end
    end)

    -- Remove dead groups from our tracking SET
    for _, groupName in pairs(groupsToRemove) do
        self.SpawnedRedGroups:Remove(groupName, true)
        removedGroups = removedGroups + 1
        env.info("Removed dead group from tracking: " .. groupName)
    end

    if removedGroups > 0 then
        env.info("Cleanup complete - removed " .. removedGroups .. " dead groups")
        self:UpdatePermanentCostDisplay()
    end

    return removedGroups
end

-- Initialize the mission
function DynamicBVRMission:Initialize()
    env.info("Initializing Dynamic BVR Mission with Random Fighter Pools...")

    -- Initialize spawners (from bvr_spawner.lua)
    self:InitializeSpawners()

    -- Show initial cost display
    self:UpdatePermanentCostDisplay()

    TIMER:New(function()
        self:StartPlayerMonitoring()
        self:SetupMissileEventHandler() -- Start missile event tracking
        self:SetupGlobalEventHandlers() -- Start global aircraft destruction tracking
        env.info("Dynamic BVR Mission fully initialized!")
    end):Start(5)
end

-- Initialize loss tracking
function DynamicBVRMission:InitializeLossTracking()
    if not self.ProcessedAircraft then
        self.ProcessedAircraft = {}
    end
    if not self.UnitBirthTimes then
        self.UnitBirthTimes = {}
    end
    if not self.GroupAircraftTypes then
        self.GroupAircraftTypes = {}
    end
end

-- Function to clear processed aircraft tracking (call when mission resets)
function DynamicBVRMission:ClearProcessedAircraft()
    env.info("Clearing processed aircraft tracking for fresh mission start")
    self.ProcessedAircraft = {}
    self.UnitBirthTimes = {}
end

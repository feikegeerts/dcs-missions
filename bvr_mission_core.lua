-- BVR Mission Core Module
-- Contains the main DynamicBVRMission class definition and core functionality
-- Mission Controller using MOOSE patterns
DynamicBVRMission = {}
DynamicBVRMission.__index = DynamicBVRMission

function DynamicBVRMission:New()
    local self = setmetatable({}, DynamicBVRMission)

    -- MOOSE Spawn objects for each direction
    self.Spawners = {
        North = {},
        Northeast = {},
        East = {},
        Southeast = {},
        South = {}
    }

    -- MOOSE Set to track blue players
    self.BluePlayerSet = SET_CLIENT:New():FilterCoalitions("blue"):FilterStart()

    -- MOOSE Set to track spawned RED groups
    self.SpawnedRedGroups = SET_GROUP:New()

    -- Available spawn directions
    self.AvailableDirections = {"North", "Northeast", "East", "Southeast", "South"}

    -- Scheduler for periodic checks
    self.PlayerCheckScheduler = nil
    self.WaveMessageScheduler = nil

    -- Wave tracking
    self.CurrentWave = 0
    self.TotalWaves = 5
    self.WaveStatusMessage = nil -- For permanent message display

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

function DynamicBVRMission:UpdateWaveMessage()
    local remainingGroups = self.SpawnedRedGroups:Count()
    local remainingWaves = #self.AvailableDirections
    local currentWave = self.TotalWaves - remainingWaves

    -- If no RED groups have ever spawned and all directions are available, show 0
    if currentWave == 0 and remainingGroups == 0 and remainingWaves == self.TotalWaves then
        currentWave = 0
    end

    -- Cost overview (from BVR_CostTracker)
    local costStats = BVR_CostTracker:GetStats()
    local function fmt(val)
        return string.format("%d", val or 0)
    end
    local function fmtCost(val)
        return string.format("$%.2fM", val or 0)
    end
    local costText = string.format(
        "\nCOST OVERVIEW:\n" .. "BLUE  | Planes Lost: %s | Missiles Fired: %s | Total: %s\n" ..
            "RED   | Planes Lost: %s | Missiles Fired: %s | Total: %s", fmt(costStats.blue.aircraftLost),
        fmt(costStats.blue.missilesFired), fmtCost(costStats.blue.totalCost), fmt(costStats.red.aircraftLost),
        fmt(costStats.red.missilesFired), fmtCost(costStats.red.totalCost))

    local messageText = string.format("WAVE STATUS: %d/%d | ACTIVE: %d | REMAINING: %d%s", currentWave, self.TotalWaves,
        remainingGroups, remainingWaves, costText)

    -- Display message for 15 seconds (not permanent)
    MESSAGE:New(messageText, 15):ToAll()

    env.info("Wave status updated: " .. messageText)
end

function DynamicBVRMission:CleanupDeadGroups()
    local removedGroups = 0
    local groupsToRemove = {}

    -- Find dead groups that need to be removed
    self.SpawnedRedGroups:ForEachGroup(function(group)
        if not group:IsAlive() or group:GetSize() == 0 then
            table.insert(groupsToRemove, group:GetName())
            env.info("Found dead group to remove: " .. group:GetName())
        end
    end)

    -- Remove dead groups from tracking
    for _, groupName in pairs(groupsToRemove) do
        self.SpawnedRedGroups:Remove(groupName, true)
        removedGroups = removedGroups + 1
        env.info("Removed dead group from tracking: " .. groupName)
    end

    if removedGroups > 0 then
        env.info("Cleanup complete - removed " .. removedGroups .. " dead groups")
        self:UpdateWaveMessage()
    end

    return removedGroups
end

function DynamicBVRMission:CleanupSpawnedGroups()
    env.info("Cleaning up spawned RED groups using MOOSE...")

    -- Use MOOSE SET to destroy all spawned groups
    self.SpawnedRedGroups:ForEachGroup(function(group)
        if group:IsAlive() then
            group:Destroy()
            env.info("Destroyed: " .. group:GetName())
        end
    end)

    -- Clear the set
    self.SpawnedRedGroups:RemoveGroupsByName(".*") -- Remove all groups

    -- Reset available directions and wave counter
    self.AvailableDirections = {"North", "Northeast", "East", "Southeast", "South"}
    self.CurrentWave = 0

    -- Update wave message
    self:UpdateWaveMessage()
end

-- Add a function to validate and cleanup problematic templates
function DynamicBVRMission:ValidateAndCleanupTemplates()
    env.info("Validating and cleaning up template groups...")

    for direction, spawners in pairs(self.Spawners) do
        for _, spawner in ipairs(spawners) do
            local templateName = spawner.TemplateGroupName
            if templateName then
                local templateGroup = Group.getByName(templateName)
                if templateGroup and templateGroup:isExist() and templateGroup:getSize() > 0 then
                    env.warning("[CLEANUP] Found alive template group: " .. templateName .. " - destroying it")
                    templateGroup:destroy()
                end
            end
        end
    end

    env.info("Template validation and cleanup complete")
end

function DynamicBVRMission:StartPlayerMonitoring()
    env.info("Starting player monitoring with MOOSE Scheduler...")

    -- Use MOOSE SCHEDULER for periodic checks
    self.PlayerCheckScheduler = SCHEDULER:New(nil, function()
        local currentBluePlayers = self:CountBluePlayers()
        local airborneBluePlayers = self:CountAirborneBluePlayers()

        -- Clean up dead groups first
        self:CleanupDeadGroups()

        local spawnedCount = self.SpawnedRedGroups:Count()

        env.info("Scheduler check - Blue Players: " .. currentBluePlayers .. ", Airborne: " .. airborneBluePlayers ..
                     ", Directions: " .. #self.AvailableDirections .. ", Spawned: " .. spawnedCount)

        -- Only spawn if we have airborne players, available directions, and no RED fighters currently active
        if airborneBluePlayers > 0 and #self.AvailableDirections > 0 and spawnedCount == 0 then
            env.info("Conditions met - airborne players detected, spawning fighters!")
            self:SpawnRedFighters()
        elseif currentBluePlayers == 0 then
            env.info("No blue players detected")
        elseif airborneBluePlayers == 0 and currentBluePlayers > 0 then
            env.info("Blue players online (" .. currentBluePlayers .. ") but none airborne yet")
        elseif #self.AvailableDirections == 0 then
            env.info("No spawn directions available - all waves completed!")
        elseif spawnedCount > 0 then
            env.info("RED fighters already active (" .. spawnedCount .. " groups) - waiting for combat")
        end
    end, {}, 0, 15) -- Start immediately, repeat every 15 seconds

    -- Separate scheduler for wave status updates (once per minute)
    self.WaveMessageScheduler = SCHEDULER:New(nil, function()
        self:UpdateWaveMessage()
    end, {}, 10, 60) -- Start after 10 seconds, repeat every 60 seconds
end

function DynamicBVRMission:Initialize()
    env.info("Initializing Dynamic BVR Mission with MOOSE...")

    -- Initialize spawners
    self:InitializeSpawners()

    -- Show initial wave status
    self:UpdateWaveMessage() -- Start monitoring after a delay to ensure everything is loaded
    TIMER:New(function()
        self:StartPlayerMonitoring()
        self:SetupMissileEventHandler() -- Start missile event tracking
        self:SetupGlobalEventHandlers() -- Start global aircraft destruction tracking
        env.info("Dynamic BVR Mission fully initialized!")
    end):Start(5)
end

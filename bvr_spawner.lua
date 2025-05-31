-- BVR Spawner Module
-- Contains all spawning related functionality
function DynamicBVRMission:InitializeSpawners()
    env.info("Initializing MOOSE Spawners...")

    -- For each direction, find template groups and create MOOSE spawners
    for _, direction in pairs({"North", "Northeast", "East", "Southeast", "South"}) do
        local templatesFound = 0
        local prefix = "Red_" .. direction .. "_"

        -- Create a SET to find all RED groups matching this direction strictly
        local templateSet = SET_GROUP:New():FilterCoalitions("red"):FilterCategoryAirplane():FilterStart()

        templateSet:ForEachGroup(function(templateGroup)
            local groupName = templateGroup:GetName()
            local isAlive = templateGroup:IsAlive()
            -- Only match groups with exact prefix (e.g., Red_North_*)
            if string.sub(groupName, 1, #prefix) == prefix then
                if isAlive == false then
                    local unitCount = templateGroup:GetSize()
                    env.info("[SPAWNER INIT] Found template: " .. groupName .. " | Units: " .. tostring(unitCount))

                    -- Create spawner with improved settings
                    local spawner = SPAWN:New(groupName):InitLimit(10, 0) -- Allow more spawns, auto-clean old ones
                    :InitCleanUp(300) -- Cleanup after 5 minutes
                    :InitDelayOff() -- No spawn delay

                    spawner.TemplateGroupName = groupName
                    table.insert(self.Spawners[direction], spawner)
                    templatesFound = templatesFound + 1
                    env.info("Created spawner for: " .. groupName)
                else
                    env.warning("[SPAWNER INIT] WARNING: Template group '" .. groupName ..
                                    "' is ALIVE at mission start! This will prevent MOOSE from spawning from this template.")

                    -- Try to force destroy the template if it exists but shouldn't be alive
                    local dcsGroup = Group.getByName(groupName)
                    if dcsGroup and dcsGroup:isExist() then
                        env.info("[SPAWNER INIT] Attempting to force destroy alive template: " .. groupName)
                        dcsGroup:destroy()
                        -- Wait a moment and try to create spawner anyway
                        timer.scheduleFunction(function()
                            local spawner = SPAWN:New(groupName):InitLimit(10, 0):InitCleanUp(300):InitDelayOff()

                            spawner.TemplateGroupName = groupName
                            table.insert(self.Spawners[direction], spawner)
                            env.info("Created spawner for previously alive template: " .. groupName)
                        end, nil, timer.getTime() + 1)
                    end
                end
            end
        end)

        env.info("Direction " .. direction .. " has " .. templatesFound .. " spawner templates")
    end
end

-- New helper function for spawn attempts with better error handling
function DynamicBVRMission:AttemptSpawn(spawner, templateName)
    local success = false
    local spawnedGroup = nil

    -- Only use the standard spawn strategy
    local ok, result = pcall(function()
        return spawner:Spawn()
    end)
    if ok and result then
        spawnedGroup = result
        success = true
        env.info("[SPAWNER] Spawn SUCCESS for template: " .. templateName .. " | Spawned group: " ..
                     spawnedGroup:GetName()) -- Add to tracking (no need to setup individual event handlers anymore)
        self.SpawnedRedGroups:AddGroup(spawnedGroup)
    else
        env.warning("[SPAWNER] Spawn FAILED for template: " .. templateName ..
                        (result and (" | Error: " .. tostring(result)) or ""))
    end

    return success, spawnedGroup
end

function DynamicBVRMission:SpawnRedFighters()
    local currentBluePlayers = self:CountBluePlayers()
    local airborneBluePlayers = self:CountAirborneBluePlayers()

    if airborneBluePlayers == 0 then
        env.info("No airborne blue players detected - not spawning")
        return
    end

    if #self.AvailableDirections == 0 then
        env.info("No more spawn directions available")
        return
    end

    -- Randomly select spawn direction
    local randomIndex = math.random(1, #self.AvailableDirections)
    local selectedDirection = self.AvailableDirections[randomIndex]

    env.info("Selected spawn direction: " .. selectedDirection .. " for " .. currentBluePlayers .. " blue clients (" ..
                 airborneBluePlayers .. " airborne)")

    -- Get spawners for this direction
    local availableSpawners = self.Spawners[selectedDirection]

    if #availableSpawners == 0 then
        env.info("No spawners available for direction: " .. selectedDirection)
        table.remove(self.AvailableDirections, randomIndex)
        return
    end

    -- Calculate number of enemy jets based on player count
    -- For solo play, spawn 1-2 enemy jets
    -- For multiplayer, spawn exactly 2 jets per player
    local minJetsPerPlayer = 2
    local maxJetsPerPlayer = 2
    local totalRedJets
    if currentBluePlayers == 1 then
        totalRedJets = math.random(1, 2)
    else
        totalRedJets = currentBluePlayers * 2
    end

    env.info("[SPAWNER] Will attempt to spawn up to " .. totalRedJets .. " red jets from direction " ..
                 selectedDirection)

    -- Improved spawning logic: spawn groups until we reach the jet limit
    local spawnedUnits = 0
    local spawnedGroups = 0
    local spawnerIndices = {}
    for i = 1, #availableSpawners do
        table.insert(spawnerIndices, i)
    end

    -- Shuffle indices for randomness
    for i = #spawnerIndices, 2, -1 do
        local j = math.random(1, i)
        spawnerIndices[i], spawnerIndices[j] = spawnerIndices[j], spawnerIndices[i]
    end

    local spawnsAttempted = 0
    local maxAttempts = #availableSpawners

    for _, idx in ipairs(spawnerIndices) do
        if spawnedUnits >= totalRedJets or spawnsAttempted >= maxAttempts then
            break
        end

        local spawner = availableSpawners[idx]
        local templateName = spawner.TemplateGroupName or "(unknown)"

        -- Pre-spawn validation
        local templateGroup = Group.getByName(templateName)
        local templateExists = templateGroup ~= nil
        local templateAlive = templateExists and templateGroup:isExist() and templateGroup:getSize() > 0

        env.info(
            "[SPAWNER] Pre-spawn check for template: " .. templateName .. " | Exists: " .. tostring(templateExists) ..
                " | Alive: " .. tostring(templateAlive))

        -- If template is unexpectedly alive, try to clean it up first
        if templateAlive then
            env.warning("[SPAWNER] Template is alive when it shouldn't be, attempting cleanup: " .. templateName)
            templateGroup:destroy()
            -- Small delay to let DCS process the destruction
            if spawnedUnits < totalRedJets then
                timer.scheduleFunction(function()
                    if spawnedUnits < totalRedJets then
                        local success, spawnedGroup = self:AttemptSpawn(spawner, templateName)
                        if success and spawnedGroup then
                            local groupSize = spawnedGroup:GetSize()
                            if spawnedUnits + groupSize > totalRedJets then
                                -- Too many, destroy excess units in the group
                                local excess = (spawnedUnits + groupSize) - totalRedJets
                                for u = groupSize, groupSize - excess + 1, -1 do
                                    local unit = spawnedGroup:GetUnit(u)
                                    if unit then
                                        unit:Destroy()
                                    end
                                end
                                groupSize = groupSize - excess
                            end
                            spawnedGroups = spawnedGroups + 1
                            spawnedUnits = spawnedUnits + groupSize
                        end
                    else
                        env.info("[SPAWNER] Skipping delayed spawn as target jet count reached: " .. templateName)
                    end
                end, nil, timer.getTime() + 0.5)
            else
                env.info("[SPAWNER] Skipping delayed spawn as target jet count already reached: " .. templateName)
            end
        else
            -- Attempt spawn immediately
            if spawnedUnits < totalRedJets then
                local success, spawnedGroup = self:AttemptSpawn(spawner, templateName)
                if success and spawnedGroup then
                    local groupSize = spawnedGroup:GetSize()
                    if spawnedUnits + groupSize > totalRedJets then
                        -- Too many, destroy excess units in the group
                        local excess = (spawnedUnits + groupSize) - totalRedJets
                        for u = groupSize, groupSize - excess + 1, -1 do
                            local unit = spawnedGroup:GetUnit(u)
                            if unit then
                                unit:Destroy()
                            end
                        end
                        groupSize = groupSize - excess
                    end
                    spawnedGroups = spawnedGroups + 1
                    spawnedUnits = spawnedUnits + groupSize
                end
            else
                env.info("[SPAWNER] Skipping spawn as target jet count already reached: " .. templateName)
            end
        end

        spawnsAttempted = spawnsAttempted + 1
    end

    env.info("Successfully spawned " .. spawnedGroups .. " groups (" .. spawnedUnits .. " total units) from " ..
                 selectedDirection .. " (attempted " .. spawnsAttempted .. " spawners)")

    -- Remove this direction from available options
    table.remove(self.AvailableDirections, randomIndex)

    -- Update wave counter message
    self:UpdateWaveMessage()

    -- Only announce TAKEOFF for the first wave
    local currentWaveNum = self.TotalWaves - #self.AvailableDirections
    if currentWaveNum == 1 then
        MESSAGE:New("TAKEOFF DETECTED!\nWAVE " .. currentWaveNum .. " INCOMING!\n", 15):ToAll()
    else
        MESSAGE:New("WAVE " .. currentWaveNum .. " INCOMING!\n", 15):ToAll()
    end
end

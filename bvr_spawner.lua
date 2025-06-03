-- Debug version of spawner initialization
-- Add this to your bvr_spawner.lua to troubleshoot
function DynamicBVRMission:InitializeSpawners()
    env.info("=== DEBUG: Starting spawner initialization ===")

    -- Define spawn zones with debugging
    self.SpawnZones = {"BVR_Zone_North", "BVR_Zone_Northeast", "BVR_Zone_East", "BVR_Zone_Southeast", "BVR_Zone_South"}
    env.info("DEBUG: Defined " .. #self.SpawnZones .. " spawn zones")

    -- Check if zones exist
    for i, zoneName in ipairs(self.SpawnZones) do
        local zone = ZONE:FindByName(zoneName)
        if zone then
            env.info("DEBUG: ✓ Found zone: " .. zoneName)
        else
            env.warning("DEBUG: ✗ Missing zone: " .. zoneName)
        end
    end

    -- Define fighter templates with debugging
    self.FighterTemplates = {"Red_MiG29_Single", "Red_MiG29_Pair", "Red_MiG29_3ship", "Red_Su27_Single",
                             "Red_Su27_Pair", "Red_Su27_3ship", "Red_Su33_Single", "Red_Su33_Pair", "Red_Su33_3ship"}
    env.info("DEBUG: Defined " .. #self.FighterTemplates .. " fighter templates")

    -- Check if templates exist
    local validTemplates = {}
    for i, templateName in ipairs(self.FighterTemplates) do
        local templateGroup = GROUP:FindByName(templateName)
        if templateGroup then
            env.info("DEBUG: ✓ Found template: " .. templateName)
            table.insert(validTemplates, templateName)
        else
            env.warning("DEBUG: ✗ Missing template: " .. templateName)
        end
    end

    if #validTemplates == 0 then
        env.error("DEBUG: ✗ NO VALID TEMPLATES FOUND! Cannot create spawner.")
        env.error("DEBUG: Make sure template groups exist and have 'Late Activation' checked")
        return
    end

    env.info("DEBUG: Found " .. #validTemplates .. " valid templates")

    -- Try to create spawner with first valid template
    local baseTemplate = validTemplates[1]
    env.info("DEBUG: Creating spawner with base template: " .. baseTemplate)

    local success, spawner = pcall(function()
        return SPAWN:New(baseTemplate)
    end)

    if not success then
        env.error("DEBUG: ✗ Failed to create base SPAWN object: " .. tostring(spawner))
        return
    end

    env.info("DEBUG: ✓ Base SPAWN object created")

    -- Try to configure spawner
    success, self.RandomSpawner = pcall(function()
        return spawner:InitRandomizeTemplate(validTemplates) -- Only use valid templates
        :InitLimit(6, 3) -- Max 6 spawns, cleanup when 3 left
        :InitCleanUp(600) -- 10 minute cleanup
        :InitDelayOn(5, 15) -- 5-15 second spawn delay
        :InitHeading(0, 360) -- Random heading
        :InitHeight(20000, 40000) -- Random BVR altitude
        :InitAIOnOff(true) -- Ensure AI active
        :InitRepeatOnEngineShutDown() -- Auto-cleanup shutdowns
        :InitRepeatOnLanding() -- Auto-cleanup landings
        :OnSpawnGroup(function(spawnedGroup) -- Callback when spawned
            env.info("DEBUG: Spawn callback triggered for: " .. spawnedGroup:GetName())
            self:OnFighterSpawned(spawnedGroup)
        end)
    end)

    if not success then
        env.error("DEBUG: ✗ Failed to configure spawner: " .. tostring(self.RandomSpawner))
        return
    end

    env.info("DEBUG: ✓ Spawner configured successfully")

    -- Only add zone randomization if zones exist
    if #self.SpawnZones > 0 then
        local zonesExist = false
        for _, zoneName in ipairs(self.SpawnZones) do
            if ZONE:FindByName(zoneName) then
                zonesExist = true
                break
            end
        end

        if zonesExist then
            self.RandomSpawner:InitRandomizeZones(self.SpawnZones)
            env.info("DEBUG: ✓ Zone randomization enabled")
        else
            env.warning("DEBUG: ⚠ No zones found - spawning at template positions")
        end
    end

    env.info("=== DEBUG: Spawner initialization complete ===")
    env.info("DEBUG: Templates: " .. #validTemplates .. ", Zones: " .. #self.SpawnZones)
end

-- Enhanced debugging for spawn attempts
function DynamicBVRMission:SpawnRedFighters()
    env.info("=== DEBUG: SpawnRedFighters called ===")

    local currentBluePlayers = self:CountBluePlayers()
    local airborneBluePlayers = self:CountAirborneBluePlayers()

    env.info("DEBUG: Blue players - Total: " .. currentBluePlayers .. ", Airborne: " .. airborneBluePlayers)

    if airborneBluePlayers == 0 then
        env.info("DEBUG: No airborne blue players - not spawning")
        return
    end

    if not self.RandomSpawner then
        env.error("DEBUG: ✗ RandomSpawner is nil! Cannot spawn.")
        return
    end

    -- Calculate groups to spawn
    local groupsToSpawn = (currentBluePlayers == 1) and math.random(1, 2) or math.min(currentBluePlayers, 4)

    env.info("DEBUG: Attempting to spawn " .. groupsToSpawn .. " groups")

    -- Spawn groups with debugging
    local spawnedCount = 0
    for i = 1, groupsToSpawn do
        env.info("DEBUG: Spawn attempt " .. i .. "/" .. groupsToSpawn)

        local success, spawnedGroup = pcall(function()
            return self.RandomSpawner:Spawn()
        end)

        if success and spawnedGroup then
            spawnedCount = spawnedCount + 1
            env.info("DEBUG: ✓ Spawn " .. i .. " successful: " .. spawnedGroup:GetName())
        else
            env.warning("DEBUG: ✗ Spawn " .. i .. " failed: " .. tostring(spawnedGroup))
        end
    end

    env.info("DEBUG: Spawned " .. spawnedCount .. "/" .. groupsToSpawn .. " groups")

    if spawnedCount > 0 then
        self:UpdatePermanentCostDisplay()
        MESSAGE:New("DEBUG: " .. spawnedCount .. " enemy groups spawned!", 15):ToAll()
    else
        MESSAGE:New("DEBUG: Spawn failed - check DCS log", 15):ToAll()
    end
end

-- Debug player counting
function DynamicBVRMission:CountBluePlayers()
    local count = 0
    local playerNames = {}

    self.BluePlayerSet:ForEachClient(function(client)
        if client:IsAlive() and client:GetPlayerName() then
            count = count + 1
            table.insert(playerNames, client:GetPlayerName())
        end
    end)

    if count > 0 then
        env.info("DEBUG: Found " .. count .. " blue players: " .. table.concat(playerNames, ", "))
    end

    return count
end

function DynamicBVRMission:CountAirborneBluePlayers()
    local count = 0
    local airborneNames = {}

    self.BluePlayerSet:ForEachClient(function(client)
        if client:IsAlive() and client:GetPlayerName() and client:InAir() then
            count = count + 1
            table.insert(airborneNames, client:GetPlayerName())
        end
    end)

    if count > 0 then
        env.info("DEBUG: Found " .. count .. " airborne blue players: " .. table.concat(airborneNames, ", "))
    end

    return count
end

function DynamicBVRMission:SetupGlobalEventHandlers()
    if self.GlobalEventHandler then
        return -- Already created
    end

    env.info("Setting up GlobalEventHandler for aircraft loss events")
    self.GlobalEventHandler = EVENTHANDLER:New()
    self.GlobalEventHandler:HandleEvent(EVENTS.Dead)
    self.GlobalEventHandler:HandleEvent(EVENTS.Crash)
    self.GlobalEventHandler:HandleEvent(EVENTS.PilotDead)

    -- Track processed aircraft to prevent double counting
    self.ProcessedAircraft = {}

    -- Track aircraft types by group name for fallback lookup
    if not self.GroupAircraftTypes then
        self.GroupAircraftTypes = {}
    end

    function self.GlobalEventHandler:OnEventDead(EventData)
        DynamicBVR:HandleAircraftLoss(EventData, "Dead")
    end

    function self.GlobalEventHandler:OnEventCrash(EventData)
        DynamicBVR:HandleAircraftLoss(EventData, "Crash")
    end

    function self.GlobalEventHandler:OnEventPilotDead(EventData)
        DynamicBVR:HandleAircraftLoss(EventData, "PilotDead")
    end
end

function DynamicBVRMission:HandleAircraftLoss(EventData, eventType)
    if not EventData.IniUnit then
        return
    end

    local unitName = EventData.IniUnit:GetName()
    local groupName = EventData.IniGroup and EventData.IniGroup:GetName() or "unknown"
    local objectId = EventData.IniDCSUnit and EventData.IniDCSUnit:getID() or "unknown"

    -- Get the birth time of the aircraft to create a truly unique identifier
    local birthTime = "unknown"
    if EventData.IniDCSUnit and EventData.IniDCSUnit.getLife then
        -- Try to get unique birth time or life data
        local life = EventData.IniDCSUnit:getLife()
        if life then
            -- Use initial life as a pseudo birth time identifier
            birthTime = tostring(life)
        end
    end

    -- If we can't get birth time, use the current mission time when we first see this unit
    if birthTime == "unknown" then
        local currentTime = timer.getTime()
        -- Create a birth time tracking table if it doesn't exist
        if not self.UnitBirthTimes then
            self.UnitBirthTimes = {}
        end

        local unitKey = tostring(objectId) .. "_" .. unitName
        if not self.UnitBirthTimes[unitKey] then
            self.UnitBirthTimes[unitKey] = currentTime
            birthTime = tostring(currentTime)
        else
            birthTime = tostring(self.UnitBirthTimes[unitKey])
        end
    end

    -- Create unique identifier using Object ID + birth identifier
    -- This ensures each aircraft spawn gets a unique ID even if Object ID is reused
    local aircraftId = tostring(objectId) .. "_" .. birthTime

    if self.ProcessedAircraft[aircraftId] then
        env.info("Aircraft with unique ID " .. aircraftId .. " (" .. unitName ..
                     ") already processed for loss, skipping " .. eventType .. " event")
        return
    end

    -- Mark this specific aircraft instance as processed permanently
    self.ProcessedAircraft[aircraftId] = true

    env.info("Processing aircraft loss via " .. eventType .. " event for aircraft: " .. unitName .. " (Unique ID: " ..
                 aircraftId .. ")")

    -- Get unit type and group info
    local unitType = nil
    if EventData.IniUnit.GetTypeName and EventData.IniUnit:GetTypeName() then
        unitType = EventData.IniUnit:GetTypeName()
    elseif EventData.IniUnit.getTypeName and EventData.IniUnit:getTypeName() then
        unitType = EventData.IniUnit:getTypeName()
    end

    -- Check if the destroyed unit belongs to one of our tracked RED groups
    if EventData.IniGroup then
        local deadGroupName = EventData.IniGroup:GetName()

        -- Check if this group is in our spawned set
        local isTrackedGroup = false
        self.SpawnedRedGroups:ForEachGroup(function(trackedGroup)
            if trackedGroup:GetName() == deadGroupName then
                isTrackedGroup = true
            end
        end)

        if isTrackedGroup then
            env.info("RED aircraft lost from tracked group: " .. deadGroupName)

            -- Try multiple ways to get unit type name
            if not unitType then
                -- First try: stored aircraft type (most reliable)
                if self.GroupAircraftTypes and self.GroupAircraftTypes[deadGroupName] then
                    unitType = self.GroupAircraftTypes[deadGroupName]
                    env.info("Got RED aircraft type from stored data: " .. unitType)
                end

                -- Second try: remaining alive units in the group
                if not unitType then
                    local group = Group.getByName(deadGroupName)
                    if group and group:isExist() then
                        local units = group:getUnits()
                        if units and #units > 0 then
                            for i, unit in ipairs(units) do
                                if unit and unit:isExist() then
                                    if unit.getTypeName then
                                        unitType = unit:getTypeName()
                                        env.info("Got RED aircraft type from remaining unit: " .. unitType)
                                        break
                                    elseif unit.GetTypeName then
                                        unitType = unit:GetTypeName()
                                        env.info("Got RED aircraft type from remaining unit (alt): " .. unitType)
                                        break
                                    end
                                end
                            end
                        end
                    end
                end

                -- Third try: MOOSE group object
                if not unitType then
                    self.SpawnedRedGroups:ForEachGroup(function(trackedGroup)
                        if trackedGroup:GetName() == deadGroupName then
                            local firstUnit = trackedGroup:GetFirstUnitAlive()
                            if firstUnit and firstUnit.GetTypeName then
                                unitType = firstUnit:GetTypeName()
                                env.info("Got RED aircraft type from MOOSE group: " .. unitType)
                            end
                        end
                    end)
                end
            end

            if unitType then
                BVR_CostTracker:OnAircraftLost("red", unitType, BVR_COSTS.aircraft)
            else
                env.info("ERROR: Could not determine RED aircraft type for cost tracking")
            end
        end

        -- Check if the entire group is now dead (important: only remove group when ALL units are dead)
        local group = Group.getByName(deadGroupName)
        if not group or not group:isExist() or group:getSize() == 0 then
            if isTrackedGroup then
                env.info("Entire RED group destroyed: " .. deadGroupName)

                -- Remove from our tracking set
                self.SpawnedRedGroups:Remove(deadGroupName, true)

                -- Clean up stored aircraft type data
                if self.GroupAircraftTypes and self.GroupAircraftTypes[deadGroupName] then
                    self.GroupAircraftTypes[deadGroupName] = nil
                end

                -- Update cost display after group destruction
                self:UpdatePermanentCostDisplay()

                -- Check if all RED fighters are destroyed
                local remainingGroups = self.SpawnedRedGroups:Count()

                -- If all RED fighters destroyed and we have more spawn directions, trigger next wave
                if remainingGroups == 0 and #self.AvailableDirections > 0 then
                    env.info("All RED fighters destroyed! Preparing next wave in 30 seconds...")
                    MESSAGE:New("WAVE CLEARED!\nNext wave in 30 seconds...", 25):ToAll()

                    -- Spawn next wave after delay
                    TIMER:New(function()
                        DynamicBVR:SpawnRedFighters()
                    end):Start(30)
                elseif remainingGroups == 0 and #self.AvailableDirections == 0 then
                    env.info("All RED fighters destroyed! No more spawn points available - mission complete!")
                    MESSAGE:New("MISSION COMPLETE!\nAll waves defeated!", 60):ToAll()
                    self:UpdatePermanentCostDisplay()
                end
            end
        else
            -- Group still has remaining units - update display
            if isTrackedGroup then
                local remainingUnits = group:getSize()
                self:UpdatePermanentCostDisplay()
            end
        end
    end

    -- Check for blue aircraft losses (any blue coalition aircraft)
    local unitCoalition = nil
    if EventData.IniUnit then
        -- Safely try to get coalition
        local success1, coalition1 = pcall(function()
            if EventData.IniUnit.GetCoalition then
                return EventData.IniUnit:GetCoalition()
            end
            return nil
        end)

        if success1 and coalition1 then
            unitCoalition = coalition1
        else
            -- Try fallback method
            local success2, coalition2 = pcall(function()
                if EventData.IniUnit.getCoalition then
                    return EventData.IniUnit:getCoalition()
                end
                return nil
            end)
            if success2 and coalition2 then
                unitCoalition = coalition2
            end
        end
    end

    -- Check if it's a blue coalition aircraft (coalition 2 = blue)
    if unitCoalition == 2 then
        if unitType then
            env.info(
                "BLUE aircraft lost: " .. unitType .. " (Player: " .. (EventData.IniUnit:GetPlayerName() or "AI") .. ")")
            BVR_CostTracker:OnAircraftLost("blue", unitType, BVR_COSTS.aircraft)
        end
    end
end

-- Helper function to store aircraft type when groups are spawned
function DynamicBVRMission:StoreGroupAircraftType(groupName, aircraftType)
    if not self.GroupAircraftTypes then
        self.GroupAircraftTypes = {}
    end
    self.GroupAircraftTypes[groupName] = aircraftType
end

-- Function to clear processed aircraft tracking and birth times (call when mission resets)
function DynamicBVRMission:ClearProcessedAircraft()
    env.info("Clearing processed aircraft tracking for fresh mission start")
    self.ProcessedAircraft = {}
    self.UnitBirthTimes = {}
end

-- Initialize birth time tracking in the constructor
function DynamicBVRMission:InitializeLossTracking()
    if not self.ProcessedAircraft then
        self.ProcessedAircraft = {}
    end
    if not self.UnitBirthTimes then
        self.UnitBirthTimes = {}
    end
end

-- Helper function to store aircraft type when groups are spawned
function DynamicBVRMission:StoreGroupAircraftType(groupName, aircraftType)
    if not self.GroupAircraftTypes then
        self.GroupAircraftTypes = {}
    end
    self.GroupAircraftTypes[groupName] = aircraftType
end

function DynamicBVRMission:SetupMissileEventHandler()
    if self.MissileEventHandler then
        return -- Only one handler
    end

    -- Add missile tracking to prevent duplicates
    self.TrackedMissiles = {}

    -- Cleanup tracked missiles periodically to prevent memory buildup
    self.MissileCleanupScheduler = SCHEDULER:New(nil, function()
        local count = 0
        for _ in pairs(DynamicBVR.TrackedMissiles) do
            count = count + 1
        end
        if count > 100 then -- Clean up if we have more than 100 tracked missiles
            DynamicBVR.TrackedMissiles = {}
            env.info("Cleaned up tracked missiles list (" .. count .. " entries)")
        end
    end, {}, 60, 300) -- Start after 1 minute, repeat every 5 minutes

    self.MissileEventHandler = EVENTHANDLER:New()
    self.MissileEventHandler:HandleEvent(EVENTS.Shot)

    function self.MissileEventHandler:OnEventShot(EventData)
        if not EventData.Weapon or not EventData.IniUnit then
            return
        end

        -- Create unique missile identifier to prevent duplicate counting
        local missileId = tostring(EventData.Weapon)
        if DynamicBVR.TrackedMissiles[missileId] then
            return -- Already counted this missile
        end
        DynamicBVR.TrackedMissiles[missileId] = true

        -- Safely get weapon type name
        local weaponType = nil
        if EventData.Weapon and type(EventData.Weapon.GetTypeName) == "function" then
            weaponType = EventData.Weapon:GetTypeName()
        elseif EventData.Weapon and type(EventData.Weapon.getTypeName) == "function" then
            weaponType = EventData.Weapon:getTypeName()
        end

        if not weaponType then
            return
        end

        local shooter = EventData.IniUnit
        local shooterCoalition = shooter:GetCoalition()
        if not shooterCoalition then
            return
        end

        local coalitionSide = (shooterCoalition == 2) and "blue" or "red"

        -- Normalize missile name (convert underscores to dashes for cost lookup)
        local normalizedWeaponType = string.gsub(weaponType, "_", "-")

        env.info("Missile fired: " .. coalitionSide .. " " .. weaponType)
        BVR_CostTracker:OnMissileFired(coalitionSide, normalizedWeaponType, BVR_COSTS.missile)
    end
end

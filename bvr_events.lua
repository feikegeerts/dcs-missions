-- BVR Events Module
-- Contains event handling logic
function DynamicBVRMission:SetupGlobalEventHandlers()
    -- Create a single global event handler for all aircraft destruction events
    if self.GlobalEventHandler then
        env.info("[BVR DEBUG] GlobalEventHandler already exists - skipping setup")
        return -- Already created
    end

    env.info("[BVR DEBUG] Setting up GlobalEventHandler for aircraft loss events")
    self.GlobalEventHandler = EVENTHANDLER:New()
    self.GlobalEventHandler:HandleEvent(EVENTS.Dead)
    self.GlobalEventHandler:HandleEvent(EVENTS.Crash)
    self.GlobalEventHandler:HandleEvent(EVENTS.PilotDead)
    env.info("[BVR DEBUG] Event handlers registered for Dead, Crash, and PilotDead events")

    -- Track processed aircraft to prevent double counting
    self.ProcessedAircraft = {}

    -- Track aircraft types by group name for fallback lookup
    if not self.GroupAircraftTypes then
        self.GroupAircraftTypes = {}
    end

    function self.GlobalEventHandler:OnEventDead(EventData)
        env.info("[BVR DEBUG] OnEventDead triggered - calling HandleAircraftLoss")
        DynamicBVR:HandleAircraftLoss(EventData, "Dead")
    end

    function self.GlobalEventHandler:OnEventCrash(EventData)
        env.info("[BVR DEBUG] OnEventCrash triggered - calling HandleAircraftLoss")
        DynamicBVR:HandleAircraftLoss(EventData, "Crash")
    end

    function self.GlobalEventHandler:OnEventPilotDead(EventData)
        env.info("[BVR DEBUG] OnEventPilotDead triggered - calling HandleAircraftLoss")
        DynamicBVR:HandleAircraftLoss(EventData, "PilotDead")
    end

    env.info("[BVR DEBUG] GlobalEventHandler setup completed")
end

function DynamicBVRMission:HandleAircraftLoss(EventData, eventType)
    -- Add comprehensive debugging at the very start
    env.info("[BVR DEBUG] ======= AIRCRAFT LOSS EVENT TRIGGERED =======")
    env.info("[BVR DEBUG] Event Type: " .. tostring(eventType))
    env.info("[BVR DEBUG] EventData exists: " .. tostring(EventData ~= nil))

    if EventData then
        env.info("[BVR DEBUG] EventData.IniUnit exists: " .. tostring(EventData.IniUnit ~= nil))
        env.info("[BVR DEBUG] EventData.IniGroup exists: " .. tostring(EventData.IniGroup ~= nil))
        env.info("[BVR DEBUG] EventData.IniDCSUnit exists: " .. tostring(EventData.IniDCSUnit ~= nil))
        env.info("[BVR DEBUG] EventData.IniDCSGroup exists: " .. tostring(EventData.IniDCSGroup ~= nil))

        -- Try to get unit info from any available source
        local unitInfo = "UNKNOWN"
        if EventData.IniUnit and EventData.IniUnit.GetTypeName then
            local success, typeName = pcall(function()
                return EventData.IniUnit:GetTypeName()
            end)
            if success and typeName then
                unitInfo = typeName
            end
        end
        env.info("[BVR DEBUG] Unit type: " .. tostring(unitInfo))

        -- Try to get group info from any available source
        local groupInfo = "UNKNOWN"
        if EventData.IniGroup and EventData.IniGroup.GetName then
            local success, groupName = pcall(function()
                return EventData.IniGroup:GetName()
            end)
            if success and groupName then
                groupInfo = groupName
            end
        end
        env.info("[BVR DEBUG] Group name: " .. tostring(groupInfo))
    end

    if not EventData.IniUnit then
        env.info("[BVR DEBUG] No IniUnit found - exiting function")
        return
    end

    -- Create unique identifier to prevent double counting the same aircraft
    local aircraftId = tostring(EventData.IniUnit)
    if self.ProcessedAircraft[aircraftId] then
        env.info("Aircraft " .. aircraftId .. " already processed for loss, skipping " .. eventType .. " event")
        return
    end
    self.ProcessedAircraft[aircraftId] = true

    env.info("Processing aircraft loss via " .. eventType .. " event for aircraft: " .. aircraftId)

    env.info("[BVR DEBUG] Event: Aircraft loss fired. EventType: " .. tostring(eventType) .. ", AircraftId: " ..
                 tostring(aircraftId))
    if EventData.IniUnit and EventData.IniUnit.GetTypeName and EventData.IniUnit:GetTypeName() then
        env.info("[BVR DEBUG] Aircraft type: " .. tostring(EventData.IniUnit:GetTypeName()))
    end
    if EventData.IniGroup then
        env.info("[BVR DEBUG] Aircraft group: " .. tostring(EventData.IniGroup:GetName()))
    end -- Check if the destroyed unit belongs to one of our tracked groups
    if EventData.IniGroup then
        local deadGroupName = EventData.IniGroup:GetName()

        -- Debug: Show all currently tracked RED groups
        env.info("[BVR DEBUG] Currently tracked RED groups:")
        local trackedGroupCount = 0
        self.SpawnedRedGroups:ForEachGroup(function(trackedGroup)
            trackedGroupCount = trackedGroupCount + 1
            env.info("[BVR DEBUG]   - " .. trackedGroup:GetName())
        end)
        env.info("[BVR DEBUG] Total tracked RED groups: " .. trackedGroupCount)
        env.info("[BVR DEBUG] Dead group name: " .. deadGroupName)

        -- Check if this group is in our spawned set
        local isTrackedGroup = false
        self.SpawnedRedGroups:ForEachGroup(function(trackedGroup)
            if trackedGroup:GetName() == deadGroupName then
                isTrackedGroup = true
            end
        end)
        if isTrackedGroup then
            env.info("[BVR DEBUG] RED group is tracked: " .. deadGroupName)
            env.info("[BVR DEBUG] Calling CostTracker:OnAircraftLost for RED: group=" .. deadGroupName)
            -- Cost tracking for RED aircraft lost
            local coalitionStr = "red"

            -- Try multiple ways to get unit type name
            local unitType = nil
            if EventData.IniUnit then
                if EventData.IniUnit.GetTypeName and EventData.IniUnit:GetTypeName() then
                    unitType = EventData.IniUnit:GetTypeName()
                    env.info("[BVR DEBUG] Got RED aircraft type via GetTypeName: " .. tostring(unitType))
                elseif EventData.IniUnit.getTypeName and EventData.IniUnit:getTypeName() then
                    unitType = EventData.IniUnit:getTypeName()
                    env.info("[BVR DEBUG] Got RED aircraft type via getTypeName: " .. tostring(unitType))
                else
                    env.info(
                        "[BVR DEBUG] Could not get RED aircraft type from EventData.IniUnit - trying alternative methods")
                end
            else
                env.info("[BVR DEBUG] EventData.IniUnit is nil for RED aircraft")
            end

            -- If we couldn't get type from the dead unit, try to get it from remaining alive units in the group
            if not unitType then
                env.info("[BVR DEBUG] Attempting to get aircraft type from remaining units in group...")
                local group = Group.getByName(deadGroupName)
                if group and group:isExist() then
                    local units = group:getUnits()
                    if units and #units > 0 then
                        for i, unit in ipairs(units) do
                            if unit and unit:isExist() then
                                if unit.getTypeName then
                                    unitType = unit:getTypeName()
                                    env.info("[BVR DEBUG] Got RED aircraft type from remaining unit " .. i .. ": " ..
                                                 tostring(unitType))
                                    break
                                elseif unit.GetTypeName then
                                    unitType = unit:GetTypeName()
                                    env.info("[BVR DEBUG] Got RED aircraft type from remaining unit " .. i ..
                                                 " (alt method): " .. tostring(unitType))
                                    break
                                end
                            end
                        end
                    end
                end

                -- If still no type and this is the last unit, try to get from MOOSE group object
                if not unitType then
                    env.info("[BVR DEBUG] Attempting to get aircraft type from MOOSE group object...")
                    self.SpawnedRedGroups:ForEachGroup(function(trackedGroup)
                        if trackedGroup:GetName() == deadGroupName then
                            local firstUnit = trackedGroup:GetFirstUnitAlive()
                            if firstUnit then
                                if firstUnit.GetTypeName then
                                    unitType = firstUnit:GetTypeName()
                                    env.info("[BVR DEBUG] Got RED aircraft type from MOOSE group first unit: " ..
                                                 tostring(unitType))
                                end
                            end
                        end
                    end)
                end
            end

            -- NEW: Fallback to stored aircraft type if all other methods failed
            if not unitType and self.GroupAircraftTypes and self.GroupAircraftTypes[deadGroupName] then
                unitType = self.GroupAircraftTypes[deadGroupName]
                env.info("[BVR DEBUG] Got RED aircraft type from stored group data: " .. tostring(unitType))
            end

            if unitType then
                -- Debug check before calling
                env.info("[BVR DEBUG] About to call BVR_CostTracker:OnAircraftLost for RED with type: " .. unitType)
                env.info("[BVR DEBUG] BVR_CostTracker exists: " .. tostring(BVR_CostTracker ~= nil))
                env.info("[BVR DEBUG] BVR_CostTracker type: " .. tostring(type(BVR_CostTracker)))
                if BVR_CostTracker and BVR_CostTracker.OnAircraftLost then
                    env.info("[BVR DEBUG] OnAircraftLost method exists: " ..
                                 tostring(type(BVR_CostTracker.OnAircraftLost)))
                    -- Only call the cost tracker, do not do any cost lookup or debug here
                    BVR_CostTracker:OnAircraftLost(coalitionStr, unitType, BVR_COSTS.aircraft)
                    env.info("[BVR DEBUG] RED OnAircraftLost call completed")
                else
                    env.info("[BVR DEBUG] ERROR: BVR_CostTracker or OnAircraftLost method not available!")
                end
            else
                env.info(
                    "[BVR DEBUG] ERROR: Could not determine RED aircraft type using any method - skipping cost tracking")
            end
        else
            env.info("[BVR DEBUG] RED group is NOT tracked: " .. deadGroupName ..
                         ". Skipping cost tracking for this loss.")
        end

        -- Check if the entire group is now dead
        local group = Group.getByName(deadGroupName)
        if not group or not group:isExist() or group:getSize() == 0 then
            env.info("Entire RED group destroyed: " .. deadGroupName)

            -- Remove from our tracking set
            self.SpawnedRedGroups:Remove(deadGroupName, true)

            -- Clean up stored aircraft type data
            if self.GroupAircraftTypes and self.GroupAircraftTypes[deadGroupName] then
                self.GroupAircraftTypes[deadGroupName] = nil
                env.info("[BVR DEBUG] Cleaned up stored aircraft type for group: " .. deadGroupName)
            end

            -- Update wave counter after group destruction
            self:UpdateWaveMessage()

            -- Check if all RED fighters are destroyed
            local remainingGroups = self.SpawnedRedGroups:Count()
            env.info("Remaining RED groups after destruction: " .. remainingGroups)

            -- If all RED fighters destroyed and we have more spawn directions, trigger next wave
            if remainingGroups == 0 and #self.AvailableDirections > 0 then
                env.info("All RED fighters destroyed! Preparing next wave in 30 seconds...")

                MESSAGE:New("WAVE CLEARED!\nNext wave in 30 seconds...", 25):ToAll()

                -- Spawn next wave after delay
                TIMER:New(function()
                    env.info("Spawning next wave of RED fighters!")
                    DynamicBVR:SpawnRedFighters()
                end):Start(30)
            elseif remainingGroups == 0 and #self.AvailableDirections == 0 then
                env.info("All RED fighters destroyed! No more spawn points available - mission complete!")

                MESSAGE:New("MISSION COMPLETE!\nAll waves defeated!", 60):ToAll()
                self:UpdateWaveMessage()
            end
        else
            -- Group still has remaining units
            local remainingUnits = group:getSize()
            env.info("Group " .. deadGroupName .. " still has " .. remainingUnits .. " units remaining")
            self:UpdateWaveMessage()
        end
    end -- Also check for blue aircraft losses (any blue coalition aircraft)
    local unitCoalition = nil
    if EventData.IniUnit then
        -- Safely try to get coalition - protect against debris objects
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
            else
                env.info("[BVR DEBUG] Could not get coalition for unit - likely debris or invalid object")
            end
        end
    end

    -- Check if it's a blue coalition aircraft (coalition 2 = blue)
    if unitCoalition == 2 then
        local coalitionStr = "blue"
        local unitType = nil

        if EventData.IniUnit.GetTypeName and EventData.IniUnit:GetTypeName() then
            unitType = EventData.IniUnit:GetTypeName()
        elseif EventData.IniUnit.getTypeName and EventData.IniUnit:getTypeName() then
            unitType = EventData.IniUnit:getTypeName()
        end
        if unitType then
            env.info("[BVR DEBUG] About to call BVR_CostTracker:OnAircraftLost for BLUE")
            env.info("[BVR DEBUG] BVR_CostTracker exists: " .. tostring(BVR_CostTracker ~= nil))
            if BVR_CostTracker and BVR_CostTracker.OnAircraftLost then
                env.info("[BVR DEBUG] OnAircraftLost method exists for BLUE call")
                -- Only call the cost tracker, do not do any cost lookup or debug here
                BVR_CostTracker:OnAircraftLost(coalitionStr, unitType, BVR_COSTS.aircraft)
                env.info("[BVR DEBUG] BLUE OnAircraftLost call completed")
                env.info("BLUE aircraft lost - Type: " .. unitType)
            else
                env.info("[BVR DEBUG] ERROR: BVR_CostTracker or OnAircraftLost method not available for BLUE!")
            end
        end
    end
end

-- NEW: Helper function to store aircraft type when groups are spawned
function DynamicBVRMission:StoreGroupAircraftType(groupName, aircraftType)
    if not self.GroupAircraftTypes then
        self.GroupAircraftTypes = {}
    end
    self.GroupAircraftTypes[groupName] = aircraftType
    env.info("[BVR DEBUG] Stored aircraft type for group " .. groupName .. ": " .. aircraftType)
end

function DynamicBVRMission:SetupMissileEventHandler()
    -- Handles missile launch events for cost tracking
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
            -- Already counted this missile
            return
        end
        DynamicBVR.TrackedMissiles[missileId] = true

        -- Safely get weapon type name with nil checks
        local weaponType = nil
        if EventData.Weapon and type(EventData.Weapon.GetTypeName) == "function" then
            weaponType = EventData.Weapon:GetTypeName()
        elseif EventData.Weapon and type(EventData.Weapon.getTypeName) == "function" then
            -- Fallback for DCS native objects
            weaponType = EventData.Weapon:getTypeName()
        end
        if not weaponType then
            env.info("Warning: Could not get weapon type name for missile event")
            return
        end

        env.info("Missile fired - Type: " .. tostring(weaponType))

        -- Normalize missile name (convert underscores to dashes for cost lookup)
        local normalizedWeaponType = string.gsub(weaponType, "_", "-")

        -- Check if missile type exists in cost table and use normalized version if needed
        local missileCost = BVR_COSTS.missile[normalizedWeaponType] or BVR_COSTS.missile[weaponType]
        if not missileCost then
            env.info("WARNING: No cost found for missile type: " .. weaponType .. " or " .. normalizedWeaponType)
        end

        local shooter = EventData.IniUnit
        if not shooter then
            env.info("Warning: No shooter unit found for missile event")
            return
        end

        local shooterCoalition = shooter:GetCoalition()
        if not shooterCoalition then
            env.info("Warning: Could not get coalition for shooter")
            return
        end

        local coalitionSide = (shooterCoalition == 2) and "blue" or "red" -- DCS coalition.side.BLUE = 2
        env.info("Shooter coalition: " .. tostring(coalitionSide))

        if weaponType and coalitionSide and normalizedWeaponType then
            -- Only call the cost tracker, do not do any cost lookup or debug here
            BVR_CostTracker:OnMissileFired(coalitionSide, normalizedWeaponType, BVR_COSTS.missile)
        else
            env.info("Warning: Missing required parameters for cost tracking - weaponType: " .. tostring(weaponType) ..
                         ", coalitionSide: " .. tostring(coalitionSide) .. ", normalizedWeaponType: " ..
                         tostring(normalizedWeaponType))
        end
    end
end

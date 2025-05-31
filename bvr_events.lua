-- BVR Events Module
-- Contains event handling logic
function DynamicBVRMission:SetupGroupEventHandlers(group)
    -- Create event handler for when units in this group are destroyed
    local unitDestroyedHandler = EVENTHANDLER:New()
    unitDestroyedHandler:HandleEvent(EVENTS.Dead)

    function unitDestroyedHandler:OnEventDead(EventData)
        -- Check if the destroyed unit belongs to one of our tracked groups
        if EventData.IniUnit and EventData.IniGroup then
            local deadGroupName = EventData.IniGroup:GetName()

            -- Check if this group is in our spawned set
            local isTrackedGroup = false
            DynamicBVR.SpawnedRedGroups:ForEachGroup(function(trackedGroup)
                if trackedGroup:GetName() == deadGroupName then
                    isTrackedGroup = true
                end
            end)

            if isTrackedGroup then
                env.info("RED unit destroyed in group: " .. deadGroupName)

                -- Check if the entire group is now dead
                local group = Group.getByName(deadGroupName)
                if not group or not group:isExist() or group:getSize() == 0 then
                    env.info("Entire RED group destroyed: " .. deadGroupName)

                    -- Remove from our tracking set
                    DynamicBVR.SpawnedRedGroups:Remove(deadGroupName, true)

                    -- Update wave counter after group destruction
                    DynamicBVR:UpdateWaveMessage()

                    -- Check if all RED fighters are destroyed
                    local remainingGroups = DynamicBVR.SpawnedRedGroups:Count()
                    env.info("Remaining RED groups after destruction: " .. remainingGroups)

                    -- If all RED fighters destroyed and we have more spawn directions, trigger next wave
                    if remainingGroups == 0 and #DynamicBVR.AvailableDirections > 0 then
                        env.info("All RED fighters destroyed! Preparing next wave in 30 seconds...")

                        MESSAGE:New("WAVE CLEARED!\nNext wave in 30 seconds...", 25):ToAll()

                        -- Spawn next wave after delay
                        TIMER:New(function()
                            env.info("Spawning next wave of RED fighters!")
                            DynamicBVR:SpawnRedFighters()
                        end):Start(30)
                    elseif remainingGroups == 0 and #DynamicBVR.AvailableDirections == 0 then
                        env.info("All RED fighters destroyed! No more spawn points available - mission complete!")

                        MESSAGE:New("MISSION COMPLETE!\nAll waves defeated!", 60):ToAll()
                        DynamicBVR:UpdateWaveMessage()
                    end
                else
                    -- Group still has remaining units
                    local remainingUnits = group:getSize()
                    env.info("Group " .. deadGroupName .. " still has " .. remainingUnits .. " units remaining")
                    DynamicBVR:UpdateWaveMessage()
                end
            end
        end
    end
end

-- BVR Menu Module
-- Contains menu commands and UI functionality
-- Create mission menu and commands
function SetupMissionMenu()
    -- Add MOOSE-powered reload menu option (no lfs or package support in DCS)
    MENU_MISSION_COMMAND:New("Reload Mission Script", nil, function()
        env.info("Reloading BVR mission script...")
        ReloadBVRMissionScript()
    end)

    MENU_MISSION_COMMAND:New("Force Next Wave", nil, function()
        if DynamicBVR and #DynamicBVR.AvailableDirections > 0 then
            env.info("Manually forcing next wave...")
            -- Clean up first to ensure accurate count
            DynamicBVR:CleanupDeadGroups()
            DynamicBVR:SpawnRedFighters()
        else
            env.info("Cannot force wave - no directions available")
        end
    end)

    MENU_MISSION_COMMAND:New("Cleanup RED Fighters", nil, function()
        if DynamicBVR then
            DynamicBVR:CleanupSpawnedGroups()
        end
    end)
end

-- Function to reload the BVR mission script
function ReloadBVRMissionScript()
    env.info("Reloading BVR mission script modules...")

    -- Stop existing scheduler
    if DynamicBVR and DynamicBVR.PlayerCheckScheduler then
        DynamicBVR.PlayerCheckScheduler:Stop()
    end
    if DynamicBVR and DynamicBVR.WaveMessageScheduler then
        DynamicBVR.WaveMessageScheduler:Stop()
    end

    -- Cleanup existing groups
    if DynamicBVR then
        DynamicBVR:CleanupSpawnedGroups()
    end

    -- Clear global variables that might hold references
    DynamicBVR = nil
    -- Do NOT set DynamicBVRMission = nil, keep the class definition

    -- Force garbage collection to clean up old references
    collectgarbage("collect")

    -- Remove all mission submenus and commands to avoid duplicates
    if MENU_MISSION and MENU_MISSION.RemoveSubMenus then
        MENU_MISSION:RemoveSubMenus()
    end

    -- Reload all the script modules
    local scriptPath = "C:\\Users\\g_for\\Saved Games\\DCS\\Missions\\BVR training\\Moose BVR\\"
    dofile(scriptPath .. "bvr_mission_core.lua")
    dofile(scriptPath .. "bvr_spawner.lua")
    dofile(scriptPath .. "bvr_events.lua")
    dofile(scriptPath .. "bvr_menu.lua")
    dofile(scriptPath .. "bvr_main.lua")

    env.info("BVR mission script modules reloaded!")
end

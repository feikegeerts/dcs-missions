-- BVR Main Module
-- Contains the main entry point and initialization
env.info("Starting MOOSE Dynamic BVR Mission...")

-- Load all modules
local scriptPath = "C:\\Users\\g_for\\Saved Games\\DCS\\Missions\\BVR training\\Moose BVR\\"
dofile(scriptPath .. "bvr_mission_core.lua")
dofile(scriptPath .. "bvr_spawner.lua")
dofile(scriptPath .. "bvr_events.lua")
dofile(scriptPath .. "bvr_menu.lua")

-- Create global instance
DynamicBVR = DynamicBVRMission:New()

-- Setup mission menu
SetupMissionMenu()

-- Start the mission with a delay and proper error handling
TIMER:New(function()
    env.info("Timer callback executing - initializing DynamicBVR...")
    if DynamicBVR and DynamicBVR.Initialize then
        DynamicBVR:Initialize()
    else
        env.info("ERROR: DynamicBVR or Initialize method not found!")
        if DynamicBVR then
            env.info("DynamicBVR exists but Initialize method is missing")
        else
            env.info("DynamicBVR is nil - creating new instance")
            DynamicBVR = DynamicBVRMission:New()
            if DynamicBVR.Initialize then
                DynamicBVR:Initialize()
            else
                env.info("ERROR: Even after creating new instance, Initialize is missing!")
            end
        end
    end
end):Start(5)

env.info("MOOSE Dynamic BVR Mission Script Loaded!")

-- BVR-specific entry. Add BVR-only rules here, not to the telemetry library.
local ROOT = assert(_G.MY_SCRIPTS_ROOT, "bootstrap must supply the source root")
local config = dofile(ROOT .. "missions/duel-dynamic-bvr/config.lua")
assert(loadfile(ROOT .. "gameplay/package-waves.lua"))(config)

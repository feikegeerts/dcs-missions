-- Legacy mission entry; preserve its historical telemetry identity.
local ROOT = assert(_G.MY_SCRIPTS_ROOT, "bootstrap must supply the source root")
local config = dofile(ROOT .. "missions/duel-dynamic/config.lua")
assert(loadfile(ROOT .. "gameplay/package-waves.lua"))(config)

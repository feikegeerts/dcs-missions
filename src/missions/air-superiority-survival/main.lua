-- Survival-specific entry. Aircraft allowance and escalation use shared defaults.
local ROOT = assert(_G.MY_SCRIPTS_ROOT, "bootstrap must supply the source root")
local config = dofile(ROOT .. "missions/air-superiority-survival/config.lua")
assert(loadfile(ROOT .. "gameplay/package-waves.lua"))(config)

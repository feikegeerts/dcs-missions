-- Compatibility guard: testing remains the safe default.
assert(not arg[3], "Use run-hidden-passage-layout-artifact.lua for explicit layouts")
dofile("tests/lua/run-hidden-passage-layout-artifact.lua")

-- Behavioural verification of the generated shipping payload.
--
-- The mission-file verifier proves the payload text survives the rewrite; this
-- proves the payload actually *runs* - with no source tree and no loadfile
-- available - and brings the range up. It runs the generated payload against
-- the same DCS mocks as the development simulation tests, then flies a landing
-- and a troop lift through it.
--
-- usage: lua5.1 tests/lua/run-helicopter-training-shipped.lua <payload-file>

local payloadPath = ...
assert(payloadPath, "usage: run-helicopter-training-shipped.lua <payload-file>")

local Mocks = dofile("tests/lua/htg-mocks.lua")

local count = 0
local function test(name, fn)
  local ok, message = pcall(fn)
  assert(ok, name .. ": " .. tostring(message))
  count = count + 1
end

-- The shipped payload must not need a source tree. Make any filesystem access
-- loud instead of silent: loadfile is the only loader the range has, and the
-- build strips its uses.
local real_loadfile = loadfile
loadfile = function(path)
  error("shipped payload tried to load from disk: " .. tostring(path))
end
_G.MY_SCRIPTS_ROOT = nil

local ctx = Mocks.install()
local payload = real_loadfile(payloadPath)
assert(payload, "cannot load the payload")
payload()
ctx.capture_tick()

-- Let the loop come up before the tests start flying, as it would in a mission.
for _ = 1, 3 do
  ctx.step()
end

loadfile = real_loadfile

local htg = _G.helicopter_training
assert(htg and htg.progress, "the shipped payload did not expose the range handle")
local config = htg.config
local sites = htg.sites
local progress = htg.progress

test("the payload brought the range up with no source tree", function()
  assert(ctx.log_contains("range ready"), "no 'range ready' log line")
  assert(ctx.statics_created >= #config.cargo, "statics: " .. ctx.statics_created)
  assert(ctx.groups_created >= 2, "groups: " .. ctx.groups_created)
  assert(#ctx.smokes == 0, "the shipped payload should not create smoke columns at startup")
  for _, load in ipairs(htg.exercises.cargo) do
    assert(load.name:find("HTG_LOAD_", 1, true), "cargo picker name is not descriptive")
  end
end)

test("sites resolved from the shipped config", function()
  assert(sites.cargo_yard and sites.troop_lz and sites.pad_bravo, "sites missing")
  assert(ctx.log_contains("site pad_bravo"), "site resolution log missing")
end)

test("a landing flown against the shipped payload scores", function()
  local record = ctx.make_player("Rotary-2-1", "UH-60L")
  ctx.fly(record, sites.pad_alpha.x, sites.pad_alpha.y, 12, 0, 4)
  assert(progress:get("Feike", "land_alpha").count == 1, "landing not scored")
end)

test("a troop lift flown against the shipped payload scores", function()
  local record = ctx.make_player("Rotary-2-1", "UH-60L")
  ctx.fly(record, sites.troop_pickup.x, sites.troop_pickup.y, 12, 0, 5)
  assert(record.internal_cargo == 11 * config.troop_mass_kg, "load " .. tostring(record.internal_cargo))
  ctx.fly(record, sites.troop_lz.x, sites.troop_lz.y, 12, 0, 5)
  assert(progress:get("Feike", "troops").count == 1, "troop delivery not scored")
end)

test("the shipped payload logged no warnings or errors", function()
  for _, line in ipairs(ctx.logs) do
    assert(not line:find("WARN", 1, true), "warning: " .. line)
    assert(not line:find("ERROR", 1, true), "error: " .. line)
  end
end)

print("helicopter training range shipped-payload tests: " .. count .. " passed")

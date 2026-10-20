-- Simulation tests for the helicopter training range (source modules, dev mode).
--
-- Stubs the DCS scripting API (see tests/lua/htg-mocks.lua) just far enough to
-- load src/missions/helicopter-training/main.lua and drive its 1 Hz evaluation
-- loop against a scripted aircraft. This is what proves the exercise state
-- machines (landing hold, hover hold, cargo delivery, troop load/unload,
-- autorotation) actually fire - reading the source does not.
--
-- Run from the repository root: lua5.1 tests/lua/run-helicopter-training-sim.lua

_G.MY_SCRIPTS_ROOT = "src/"

local Mocks = dofile("tests/lua/htg-mocks.lua")

local count = 0
local function test(name, fn)
  local ok, message = pcall(fn)
  assert(ok, name .. ": " .. tostring(message))
  count = count + 1
end

local function near(a, b, tolerance)
  return math.abs(a - b) <= (tolerance or 1e-6)
end

local ctx = Mocks.install()
assert(loadfile("src/missions/helicopter-training/main.lua"))()
ctx.capture_tick()

local config = dofile("src/missions/helicopter-training/config.lua")
local htg = _G.helicopter_training
assert(htg and htg.progress, "main.lua must expose the range handle for tests")
local sites = config.sites
local progress = htg.progress

-- Boot: run the loop once so the range is live before the tests start.
ctx.fly(ctx.make_player("Rotary-1-1", "CH-47Fbl1"), sites.cargo_yard.x, sites.cargo_yard.y, 10, 0, 3)

-- ------------------------------------------------------------------- the tests

test("setup spawns the configured cargo, squad and targets", function()
  assert(ctx.statics_created >= #config.cargo, "statics: " .. ctx.statics_created)
  assert(ctx.groups_created >= 2, "groups: " .. ctx.groups_created)
  assert(ctx.log_contains("range ready"), "no 'range ready' log line")
end)

test("range sites start with map marks but no active smoke columns", function()
  assert(#ctx.marks > 0, "site map markers were not created")
  assert(#ctx.smokes == 0, "smoke should be player-activated, not spawned at startup")
end)

test("a site smoke command marks only its selected site", function()
  local before = #ctx.smokes
  assert(ctx.run_command("Site: PAD ALPHA (open)"), "site smoke menu item missing")
  assert(#ctx.smokes == before + 1, "one menu selection should create one smoke column")
  local smoke = ctx.smokes[#ctx.smokes]
  assert(smoke.point.x == sites.pad_alpha.x and smoke.point.z == sites.pad_alpha.y)
  assert(smoke.color == trigger.smokeColor.Green)
end)

test("cargo names and individual smoke commands identify each load", function()
  local names = {}
  for _, load in ipairs(htg.exercises.cargo) do
    assert(load.name:find("HTG_LOAD_", 1, true), "cargo object name lacks readable load prefix")
    assert(load.name:find(load.entry.class:upper(), 1, true), "cargo object name lacks its weight class")
    assert(not names[load.name], "duplicate cargo object name: " .. load.name)
    names[load.name] = true

    assert(ctx.run_command("Load: " .. load.menu_label), "missing smoke command for " .. load.menu_label)
    local smoke = ctx.smokes[#ctx.smokes]
    local spawned = ctx.statics[load.name]
    assert(
      smoke.point.x == spawned.pos.x and smoke.point.z == spawned.pos.z,
      "smoke did not identify the selected load"
    )
    assert(smoke.color == trigger.smokeColor.White)
  end
end)

test("sites resolve to the configured coordinates on flat ground", function()
  assert(ctx.log_contains("site cargo_yard") and ctx.log_contains("h=10.0"), "site resolution line missing")
end)

test("a landing on a pad only counts after the hold time", function()
  local record = ctx.make_player("Rotary-2-1", "UH-60L")
  ctx.fly(record, sites.pad_alpha.x, sites.pad_alpha.y, 12, 0, 2)
  assert(progress:get("Feike", "land_alpha").count == 0, "counted too early")
  ctx.fly(record, sites.pad_alpha.x, sites.pad_alpha.y, 12, 0, 3)
  assert(progress:get("Feike", "land_alpha").count == 1, "landing never counted")
end)

test("a fast low pass over a pad is not a landing", function()
  local record = ctx.make_player("Rotary-2-1", "UH-60L")
  -- Break contact first: the previous test left the aircraft parked on the pad.
  ctx.fly(record, sites.pad_alpha.x + 3000, sites.pad_alpha.y, 200, 40, 2)
  local before = progress:get("Feike", "land_alpha").count
  ctx.fly(record, sites.pad_alpha.x, sites.pad_alpha.y, 12, 40, 6)
  assert(progress:get("Feike", "land_alpha").count == before, "a fast pass counted as a landing")
end)

test("a hover above a pad is not a landing", function()
  local record = ctx.make_player("Rotary-2-1", "UH-60L")
  ctx.fly(record, sites.pad_alpha.x + 3000, sites.pad_alpha.y, 200, 40, 2)
  local before = progress:get("Feike", "land_alpha").count
  ctx.fly(record, sites.pad_alpha.x, sites.pad_alpha.y, 30, 0, 6)
  assert(progress:get("Feike", "land_alpha").count == before, "a 20 m hover counted as a landing")
end)

test("leaving and returning to a pad counts again", function()
  local record = ctx.make_player("Rotary-2-1", "UH-60L")
  local before = progress:get("Feike", "land_alpha").count
  ctx.fly(record, sites.pad_alpha.x + 3000, sites.pad_alpha.y, 200, 40, 2)
  ctx.fly(record, sites.pad_alpha.x, sites.pad_alpha.y, 12, 0, 4)
  assert(progress:get("Feike", "land_alpha").count == before + 1, "repeat landing not counted")
end)

test("the hover drill needs the full hold inside the box", function()
  local record = ctx.make_player("Rotary-2-1", "UH-60L")
  ctx.fly(record, sites.hover_pad.x + 2000, sites.hover_pad.y, 100, 30, 2)
  ctx.fly(record, sites.hover_pad.x, sites.hover_pad.y, 16, 0, 20)
  assert(progress:get("Feike", "hover").count == 0, "hover counted before 45 s")
  ctx.fly(record, sites.hover_pad.x + 4, sites.hover_pad.y + 3, 16, 0, 30)
  local entry = progress:get("Feike", "hover")
  assert(entry.count == 1, "hover never completed")
  assert(entry.best and entry.best <= 5, "drift " .. tostring(entry.best))
end)

test("drifting out of the hover box restarts the hold", function()
  local record = ctx.make_player("Rotary-2-1", "UH-60L")
  local before = progress:get("Feike", "hover").count
  -- Out of the box for a moment, then back in for less than the hold time.
  ctx.fly(record, sites.hover_pad.x + 400, sites.hover_pad.y, 16, 0, 3)
  ctx.fly(record, sites.hover_pad.x, sites.hover_pad.y, 16, 0, 20)
  assert(progress:get("Feike", "hover").count == before, "the hold timer was not reset by the drift")
  -- Now hold properly and confirm the drill still completes.
  ctx.fly(record, sites.hover_pad.x, sites.hover_pad.y, 16, 0, 30)
  assert(progress:get("Feike", "hover").count == before + 1, "hover never completed after a drift")
end)

test("a hover that is too high does not count", function()
  local record = ctx.make_player("Rotary-2-1", "UH-60L")
  ctx.fly(record, sites.hover_pad.x + 2000, sites.hover_pad.y, 100, 30, 2)
  local before = progress:get("Feike", "hover").count
  ctx.fly(record, sites.hover_pad.x, sites.hover_pad.y, 60, 0, 50)
  assert(progress:get("Feike", "hover").count == before, "an out-of-band hover counted")
end)

test("a sling load scores only when the load reaches a pad", function()
  local record = ctx.make_player("Rotary-1-1", "CH-47Fbl1")
  ctx.fly(record, sites.cargo_yard.x, sites.cargo_yard.y, 10, 0, 2)

  -- Find a spawned load and lift it clear of the ground.
  local load_name, load
  for name, spawned in pairs(ctx.statics) do
    if name:find("HTG_LOAD_", 1, true) then
      load_name, load = name, spawned
      break
    end
  end
  assert(load_name, "no cargo spawned")
  load.pos.y = 40
  ctx.fly(record, sites.cargo_yard.x + 200, sites.cargo_yard.y, 40, 0, 2)
  assert(progress:get("Feike", "sling").count == 0, "scored without a delivery")

  -- Set it down on Pad Alpha, with the aircraft nearby so it gets the credit.
  load.pos.x = sites.pad_alpha.x
  load.pos.z = sites.pad_alpha.y
  load.pos.y = 10
  ctx.fly(record, sites.pad_alpha.x + 100, sites.pad_alpha.y, 12, 0, 2)
  assert(progress:get("Feike", "sling").count == 1, "delivery not scored")
end)

test("a destroyed load is reported instead of scored", function()
  local record = ctx.make_player("Rotary-1-1", "CH-47Fbl1")
  local load
  for name, spawned in pairs(ctx.statics) do
    if name:find("HTG_LOAD_", 1, true) and not spawned.destroyed then
      load = spawned
      break
    end
  end
  assert(load, "no load left to destroy")
  load.destroyed = true
  local before = #ctx.logs
  ctx.fly(record, sites.cargo_yard.x, sites.cargo_yard.y, 10, 0, 2)
  local reported = false
  for index = before, #ctx.logs do
    if ctx.logs[index] and ctx.logs[index]:find("destroyed", 1, true) then
      reported = true
    end
  end
  assert(reported, "load loss not reported")
end)

test("troops load at the staging area and are delivered at the LZ", function()
  local record = ctx.make_player("Rotary-2-1", "UH-60L")
  ctx.fly(record, sites.troop_pickup.x, sites.troop_pickup.y, 12, 0, 5)
  assert(record.internal_cargo and record.internal_cargo > 0, "no load taken aboard")
  assert(near(record.internal_cargo, 11 * config.troop_mass_kg), "load " .. tostring(record.internal_cargo))

  ctx.fly(record, sites.troop_lz.x, sites.troop_lz.y, 12, 0, 5)
  assert(progress:get("Feike", "troops").count == 1, "troop delivery not scored")
  assert(record.internal_cargo == 0, "load not cleared after disembarking")
end)

test("the UH-60L is limited to 11 pax and the Chinook is not", function()
  -- The UH-60L load above was capacity-limited; a Chinook against a fresh
  -- 12-person squad should take all twelve.
  htg.exercises:reset_world()
  local chinook = ctx.make_player("Rotary-1-1", "CH-47Fbl1")
  ctx.fly(chinook, sites.troop_pickup.x, sites.troop_pickup.y, 12, 0, 5)
  assert(near(chinook.internal_cargo, 12 * config.troop_mass_kg), "Chinook load " .. tostring(chinook.internal_cargo))
  assert(config.troop_capacity["CH-47Fbl1"] == 31)
end)

test("autorotation scores from the gate to the pad", function()
  local record = ctx.make_player("Rotary-2-1", "UH-60L")
  -- Above the gate, fast enough, for the confirmation hold.
  ctx.fly(record, sites.auto_gate.x, sites.auto_gate.y, 400, 55, 3)
  assert(progress:get("Feike", "auto").count == 0, "scored before landing")
  ctx.fly(record, sites.auto_pad.x, sites.auto_pad.y, 12, 0, 3)
  local entry = progress:get("Feike", "auto")
  assert(entry.count == 1, "autorotation not scored")
  assert(entry.best and entry.best >= 1, "no elapsed time recorded")
end)

test("a kill on the target field scores a gunner hit", function()
  assert(ctx.handler, "no event handler installed")
  local shooter = ctx.make_player("Rotary-2-1", "UH-60L")
  local victim = ctx.make_unit("HTG_TGT-1", "Infantry AK")
  local before = progress:get("Feike", "gunnery").count
  ctx.handler.onEvent({
    id = world.event.S_EVENT_KILL,
    initiator = ctx.stub_object(shooter),
    target = ctx.stub_object(victim),
  })
  assert(progress:get("Feike", "gunnery").count == before + 1, "kill not credited")
end)

test("a kill by a non-player is not credited", function()
  local ai = ctx.make_unit("Rotary-5-1", "UH-1H")
  local victim = ctx.make_unit("HTG_TGT-2", "Infantry AK")
  local before = progress:get("Feike", "gunnery").count
  ctx.handler.onEvent({
    id = world.event.S_EVENT_KILL,
    initiator = ctx.stub_object(ai),
    target = ctx.stub_object(victim),
  })
  assert(progress:get("Feike", "gunnery").count == before, "AI kill was credited to a player")
end)

test("the status report lists what has been flown", function()
  local text = progress:report(function(s)
    return tostring(s)
  end)
  assert(text:find("Feike:", 1, true), text)
  assert(text:find("Landing: Pad Alpha", 1, true), text)
  assert(text:find("Troop lift", 1, true), text)
end)

test("no tick raised a warning", function()
  for _, line in ipairs(ctx.logs) do
    assert(not line:find("WARN", 1, true), "warning logged: " .. line)
    assert(not line:find("ERROR", 1, true), "error logged: " .. line)
  end
end)

print("helicopter training range simulation tests: " .. count .. " passed")

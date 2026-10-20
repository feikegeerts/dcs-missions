-- Offline tests for the helicopter training range's pure logic.
-- Run from the repository root: lua5.1 tests/lua/run-helicopter-training.lua

_G.MY_SCRIPTS_ROOT = "src/"

local Geo = dofile("src/missions/helicopter-training/geo.lua")
local Progress = dofile("src/missions/helicopter-training/progress.lua")
local Terrain = dofile("src/missions/helicopter-training/terrain.lua")
local config = dofile("src/missions/helicopter-training/config.lua")

local count = 0
local function test(name, fn)
  local ok, message = pcall(fn)
  assert(ok, name .. ": " .. tostring(message))
  count = count + 1
end

local function near(a, b, tolerance)
  return math.abs(a - b) <= (tolerance or 1e-6)
end

-- ------------------------------------------------------------------- geometry

test("bearing and distance measure a due-north offset", function()
  local bearing, distance = Geo.bearing_distance(0, 0, 0, 1000)
  assert(near(bearing, 0, 1e-9), "bearing " .. tostring(bearing))
  assert(near(distance, 1000, 1e-9))
end)

test("bearing and distance measure a due-east offset", function()
  local bearing = Geo.bearing_distance(0, 0, 1000, 0)
  assert(near(bearing, 90, 1e-9), "bearing " .. tostring(bearing))
end)

test("bearing wraps into 0-360", function()
  local bearing = Geo.bearing_distance(0, 0, 0, -500)
  assert(near(bearing, 180, 1e-9), "bearing " .. tostring(bearing))
  bearing = Geo.bearing_distance(0, 0, -100, -100)
  assert(near(bearing, 225, 1e-9), "bearing " .. tostring(bearing))
end)

test("offset inverts bearing_distance", function()
  for _, bearing in ipairs({ 0, 45, 90, 180, 247, 359 }) do
    local x, y = Geo.offset(1000, -2000, bearing, 4321)
    local measured, distance = Geo.bearing_distance(1000, -2000, x, y)
    assert(near(measured, bearing, 1e-6), "bearing " .. bearing .. " -> " .. measured)
    assert(near(distance, 4321, 1e-6), "distance " .. distance)
  end
end)

test("bearing_delta takes the short way round", function()
  assert(near(Geo.bearing_delta(350, 10), 20))
  assert(near(Geo.bearing_delta(10, 350), 20))
  assert(near(Geo.bearing_delta(0, 180), 180))
  assert(near(Geo.bearing_delta(90, 90), 0))
end)

test("cardinal names the eight sectors", function()
  assert(Geo.cardinal(0) == "N")
  assert(Geo.cardinal(89) == "E")
  assert(Geo.cardinal(200) == "S")
  assert(Geo.cardinal(300) == "NW")
end)

test("relief reports min, max and spread", function()
  local min, max, spread = Geo.relief({ 12, 30, 5, 17 })
  assert(min == 5 and max == 30 and spread == 25)
  local empty_min, empty_max, empty_spread = Geo.relief({})
  assert(empty_min == 0 and empty_max == 0 and empty_spread == 0)
end)

test("duration formats minutes and seconds", function()
  assert(Geo.duration(45) == "45s")
  assert(Geo.duration(83) == "1m 23s")
  assert(Geo.duration(nil) == "-")
end)

test("describe quotes range, cardinal and bearing from the reference", function()
  local reference = { name = "Batumi", x = 0, y = 0 }
  local text = Geo.describe(0, 2500, reference)
  assert(text:find("2.5 km", 1, true), text)
  assert(text:find("N (000)", 1, true), text)
  assert(text:find("Batumi", 1, true), text)
end)

-- ------------------------------------------------------------------- progress

test("progress records counts, firsts and bests", function()
  local p = Progress.new()
  p:register("sling", "External load", "time")
  local n1, first1, best1 = p:record("Feike", "sling", 120)
  local n2, first2, best2 = p:record("Feike", "sling", 90)
  local n3, _, best3 = p:record("Feike", "sling", 100)
  assert(n1 == 1 and first1 and best1)
  assert(n2 == 2 and not first2 and best2)
  assert(n3 == 3 and not best3)
  assert(p:get("Feike", "sling").best == 90)
end)

test("progress keeps pilots apart and totals across them", function()
  local p = Progress.new()
  p:register("sling", "External load", "time")
  p:record("A", "sling", 60)
  p:record("B", "sling", 50)
  p:record("B", "sling", 55)
  assert(p:get("A", "sling").count == 1)
  assert(p:get("B", "sling").count == 2)
  assert(p:totals().sling == 3)
end)

test("progress records attempts without a time", function()
  local p = Progress.new()
  p:register("land_alpha", "Landing: Pad Alpha", "count")
  p:record("A", "land_alpha")
  p:record("A", "land_alpha")
  local entry = p:get("A", "land_alpha")
  assert(entry.count == 2 and entry.best == nil)
end)

test("report formats metrics according to the registered metric", function()
  local p = Progress.new()
  p:register("hover", "Precision hover", "metres")
  p:register("land_alpha", "Landing: Pad Alpha", "count")
  p:register("auto", "Autorotation", "time")
  p:record("Feike", "hover", 2.44, "2.4 m")
  p:record("Feike", "land_alpha")
  p:record("Feike", "auto", 63)
  local report = p:report(Geo.duration)
  assert(report:find("Feike:", 1, true), report)
  assert(report:find("best 2.4 m", 1, true), report)
  assert(report:find("best 1m 03s", 1, true), report)
  assert(report:find("Landing: Pad Alpha", 1, true), report)
end)

test("report says so when nothing has been flown", function()
  local p = Progress.new()
  p:register("sling", "External load", "time")
  assert(p:report():find("No attempts recorded yet", 1, true))
end)

test("reset clears one pilot or everyone", function()
  local p = Progress.new()
  p:register("sling", "External load", "time")
  p:record("A", "sling", 10)
  p:record("B", "sling", 10)
  p:reset("A")
  assert(p:get("A", "sling").count == 0)
  assert(p:get("B", "sling").count == 1)
  p:reset()
  assert(p:get("B", "sling").count == 0)
end)

-- -------------------------------------------------------------------- terrain

local function candidate(x, y, elevation, relief, wide_relief, distance)
  return {
    x = x,
    y = y,
    elevation = elevation,
    relief = relief,
    wide_relief = wide_relief or relief,
    distance = distance or 0,
    bearing = 0,
  }
end

test("classify separates flat ground from hill benches", function()
  local flat, hill = Terrain.classify({
    candidate(0, 0, 10, 0.5, 1.0), -- flat, low
    candidate(1000, 0, 200, 1.0, 40.0), -- flat bench on a hill
    candidate(2000, 0, 300, 9.0, 60.0), -- too rough to land on
  }, { max_flat_relief_m = 3.0, min_hill_elevation_m = 120, min_hill_relief_m = 25 })
  assert(#flat == 2, "#flat " .. #flat)
  assert(#hill == 1, "#hill " .. #hill)
  assert(hill[1].elevation == 200)
end)

test("select ranks hills by elevation and keeps sites apart", function()
  local result = Terrain.select({
    candidate(0, 0, 100, 0.5, 1.0),
    candidate(500, 0, 250, 1.0, 40.0), -- high, but only 500 m from the next
    candidate(520, 20, 240, 1.0, 35.0),
    candidate(4000, 0, 300, 1.5, 50.0), -- highest
  }, {
    max_flat_relief_m = 3.0,
    min_hill_elevation_m = 120,
    min_hill_relief_m = 25,
    min_separation_m = 1200,
    report_count = 4,
  })
  assert(#result.hill == 2, "#hill " .. #result.hill)
  assert(result.hill[1].elevation == 300)
  assert(result.hill[2].elevation == 250)
  assert(result.candidates == 4)
end)

test("select returns nothing when the terrain offers nothing usable", function()
  local result = Terrain.select({
    candidate(0, 0, 5, 12.0, 30.0),
  }, { max_flat_relief_m = 3.0 })
  assert(#result.flat == 0 and #result.hill == 0)
end)

test("resolve_search picks the nearest acceptable candidate", function()
  local best, distance = Terrain.resolve_search({
    { x = 1000, y = 0, ok = false },
    { x = 300, y = 400, ok = true },
    { x = 900, y = 0, ok = true },
  }, 0, 0)
  assert(best.x == 300 and near(distance, 500, 1e-6), tostring(distance))
end)

-- --------------------------------------------------------------------- config

test("config names the mission and the base", function()
  assert(config.mission_name == "helicopter-training")
  assert(config.coalition == 2 and config.country_id == 2)
  assert(config.base.airbase_id == 22)
end)

test("every configured site has coordinates, a radius and a label", function()
  local seen = 0
  for key, site in pairs(config.sites) do
    assert(type(site.x) == "number" and type(site.y) == "number", key)
    assert(type(site.radius) == "number" and site.radius > 0, key)
    assert(type(site.label) == "string" and #site.label > 0, key)
    seen = seen + 1
  end
  assert(seen >= 12, "sites: " .. seen)
end)

test("every cargo entry has a verified type and shape name", function()
  assert(#config.cargo >= 4)
  local classes = {}
  for _, entry in ipairs(config.cargo) do
    assert(type(entry.type) == "string" and #entry.type > 0)
    assert(type(entry.shape_name) == "string" and #entry.shape_name > 0)
    assert(config.cargo_points[entry.class], "missing points for class " .. tostring(entry.class))
    classes[entry.class] = true
  end
  assert(classes.light and classes.medium and classes.heavy, "load classes are not covered")
end)

test("troop capacity matches the shipped campaign figures", function()
  assert(config.troop_capacity["CH-47Fbl1"] == 31)
  assert(config.troop_capacity["UH-60L"] == 11)
end)

test("landing and hover thresholds are sane", function()
  assert(config.landing.hold_seconds >= 1 and config.landing.speed_max_ms <= 5)
  assert(config.hover.agl_min_m < config.hover.agl_max_m)
  assert(config.hover.hold_seconds > 0)
  assert(config.autorotation.entry_agl_min_m > 100)
end)

test("confined pad obstacles leave a gap and a usable clearing", function()
  local ring = config.obstacle_ring
  assert(ring.gap_deg > 30, "no gap means no way in")
  local arc = (360 - ring.gap_deg) / ring.count
  local spacing = ring.radius * arc * math.pi / 180
  assert(spacing > 4, "obstacles overlap at " .. string.format("%.1f m", spacing))
end)

print("helicopter training range tests: " .. count .. " passed")

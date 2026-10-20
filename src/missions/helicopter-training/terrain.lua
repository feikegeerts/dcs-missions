-- Terrain access, site resolution and the landing-zone probe.
--
-- Two halves:
--   * DCS-facing: height/is_land/sample_patch/resolve_site/scan (call land.*).
--   * Pure: Terrain.classify/select/resolve_search - no DCS calls, unit-tested.
--
-- The range uses this to turn config coordinates (intentions) into positions
-- that are actually on flat, dry ground, and to find hill benches for
-- off-field landing practice without a human reading the map.

local Terrain = {}
Terrain.__index = Terrain

-- Modules resolve through _G.HTG_PRELOADED when the shipping build has
-- pre-assembled them, and from disk otherwise. The dev-only branch is stripped
-- by build/pack-helicopter-training-miz.ps1.
local function load_relative(name)
  local preloaded = rawget(_G, "HTG_PRELOADED")
  if preloaded and preloaded[name] then
    return preloaded[name]
  end
  -- HTG:DEV-ONLY-BEGIN
  local root = rawget(_G, "MY_SCRIPTS_ROOT") or ""
  local chunk = loadfile(root .. "missions/helicopter-training/" .. name)
  assert(chunk, "cannot load " .. name)
  return chunk()
  -- HTG:DEV-ONLY-END
end

local Geo
local function geo()
  if not Geo then
    Geo = load_relative("geo.lua")
  end
  return Geo
end

-- ---------------------------------------------------------------- DCS facing

function Terrain.new()
  local self = setmetatable({}, Terrain)
  self.calls = 0
  return self
end

--- Terrain height (m ASL) or nil when the point cannot be queried.
function Terrain:height(x, y)
  self.calls = self.calls + 1
  local ok, h = pcall(land.getHeight, { x = x, y = y })
  if not ok or type(h) ~= "number" then
    return nil
  end
  return h
end

--- True when the point is dry land. Falls back to a height test if the
--- surface-type API is unavailable.
function Terrain:is_land(x, y)
  if land.SurfaceType then
    local ok, surface = pcall(land.getSurfaceType, { x = x, y = y })
    if ok and surface ~= nil then
      return surface == land.SurfaceType.LAND, surface
    end
  end
  local h = self:height(x, y)
  return (h ~= nil and h > 0.5), h
end

--- Sample the centre plus a ring of points; returns heights, nil entries skipped.
function Terrain:sample_patch(x, y, radius, points)
  points = points or 8
  local heights = {}
  local centre = self:height(x, y)
  if centre then
    heights[#heights + 1] = centre
  end
  for i = 1, points do
    local bearing = (i - 1) * (360 / points)
    local px, py = geo().offset(x, y, bearing, radius)
    local h = self:height(px, py)
    if h then
      heights[#heights + 1] = h
    end
  end
  return heights
end

--- Resolve a config site to usable ground.
-- Returns a table: x, y, height, relief, moved_m, ok, reason.
function Terrain:resolve_site(site, opts)
  opts = opts or {}
  local patch_radius = opts.flat_patch_radius_m or 40
  local max_relief = opts.max_flat_relief_m or 3.0
  local max_search = opts.max_search_m or 1500
  local step = opts.search_step_m or 100

  local function evaluate(x, y)
    local is_land = self:is_land(x, y)
    if not is_land then
      return nil, "water"
    end
    local heights = self:sample_patch(x, y, patch_radius, 8)
    if #heights == 0 then
      return nil, "unreadable"
    end
    local _, _, relief = geo().relief(heights)
    if relief > max_relief then
      return nil, string.format("relief %.1f m", relief)
    end
    return { x = x, y = y, height = heights[1], relief = relief }
  end

  local resolved, reason = evaluate(site.x, site.y)
  if resolved then
    resolved.ok = true
    resolved.moved_m = 0
    return resolved
  end

  -- Walk outward in rings looking for the nearest usable ground.
  local radius = step
  while radius <= max_search do
    for i = 0, 11 do
      local bearing = i * 30
      local px, py = geo().offset(site.x, site.y, bearing, radius)
      local candidate = evaluate(px, py)
      if candidate then
        candidate.ok = true
        candidate.moved_m = radius
        candidate.reason = reason
        return candidate
      end
    end
    radius = radius + step
  end

  return {
    x = site.x,
    y = site.y,
    height = self:height(site.x, site.y) or 0,
    relief = 0,
    ok = false,
    moved_m = 0,
    reason = reason or "unsuitable",
  }
end

--- Scan rings around a centre for flat ground and hill benches.
-- Returns a table with `flat` and `hill` lists, each entry carrying
-- x, y, elevation, relief, wide_relief, distance, bearing.
function Terrain:scan(centre, cfg)
  cfg = cfg or {}
  local bearings = cfg.bearings or 24
  local steps = cfg.steps or 8
  local min_m = cfg.ring_min_m or 2500
  local max_m = cfg.ring_max_m or 9000
  local flat_radius = cfg.flat_patch_radius_m or 40
  local bench_radius = cfg.bench_patch_radius_m or 120

  local candidates = {}
  for i = 0, bearings - 1 do
    local bearing = i * (360 / bearings)
    for s = 1, steps do
      local distance = min_m + (max_m - min_m) * (s - 1) / math.max(steps - 1, 1)
      local x, y = geo().offset(centre.x, centre.y, bearing, distance)
      if self:is_land(x, y) then
        local flat = self:sample_patch(x, y, flat_radius, 8)
        local wide = self:sample_patch(x, y, bench_radius, 8)
        if #flat > 0 and #wide > 0 then
          local _, _, flat_relief = geo().relief(flat)
          local _, wide_max, wide_relief = geo().relief(wide)
          candidates[#candidates + 1] = {
            x = x,
            y = y,
            bearing = bearing,
            distance = distance,
            elevation = flat[1],
            relief = flat_relief,
            wide_relief = wide_relief,
            wide_max = wide_max,
          }
        end
      end
    end
  end
  return Terrain.select(candidates, cfg)
end

-- -------------------------------------------------------------------- Pure

--- Split sampled candidates into flat-ground and hill-bench lists.
function Terrain.classify(candidates, cfg)
  cfg = cfg or {}
  local max_flat_relief = cfg.max_flat_relief_m or 3.0
  local min_elevation = cfg.min_hill_elevation_m or 120
  local min_relief = cfg.min_hill_relief_m or 25

  local flat, hill = {}, {}
  for _, c in ipairs(candidates) do
    if c.relief <= max_flat_relief then
      flat[#flat + 1] = c
      if c.elevation >= min_elevation and c.wide_relief >= min_relief then
        hill[#hill + 1] = c
      end
    end
  end
  return flat, hill
end

--- Rank and de-duplicate candidates. Flat ground is ranked by smoothness then
--- closeness; hills by elevation then relief.
function Terrain.select(candidates, cfg)
  cfg = cfg or {}
  local flat, hill = Terrain.classify(candidates, cfg)
  local min_separation = cfg.min_separation_m or 1200
  local count = cfg.report_count or 4

  table.sort(flat, function(a, b)
    if a.relief ~= b.relief then
      return a.relief < b.relief
    end
    return a.distance < b.distance
  end)
  table.sort(hill, function(a, b)
    if a.elevation ~= b.elevation then
      return a.elevation > b.elevation
    end
    return a.wide_relief > b.wide_relief
  end)

  local function take(list)
    local chosen = {}
    for _, c in ipairs(list) do
      local far_enough = true
      for _, other in ipairs(chosen) do
        local _, d = geo().bearing_distance(c.x, c.y, other.x, other.y)
        if d < min_separation then
          far_enough = false
          break
        end
      end
      if far_enough then
        chosen[#chosen + 1] = c
        if #chosen >= count then
          break
        end
      end
    end
    return chosen
  end

  return { flat = take(flat), hill = take(hill), candidates = #candidates }
end

--- Nearest acceptable site from a list of already-evaluated candidates.
-- Pure helper used by tests; the DCS path in resolve_site does the same job
-- against live terrain.
function Terrain.resolve_search(candidates, centre_x, centre_y)
  local best, best_distance
  for _, c in ipairs(candidates) do
    if c.ok then
      local _, d = geo().bearing_distance(centre_x, centre_y, c.x, c.y)
      if not best_distance or d < best_distance then
        best, best_distance = c, d
      end
    end
  end
  return best, best_distance
end

return Terrain

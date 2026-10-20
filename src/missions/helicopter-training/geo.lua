-- Pure geometry and formatting helpers for the training range.
--
-- No DCS API calls anywhere in this file: it is loadable and testable under
-- plain Lua 5.1 (see tests/lua/run-helicopter-training.lua).

local Geo = {}

local function to_rad(deg)
  return deg * math.pi / 180
end

local function to_deg(rad)
  return rad * 180 / math.pi
end

--- Grid bearing and distance from (x1, y1) to (x2, y2).
-- Bearing is degrees clockwise from +y, matching DCS headings.
function Geo.bearing_distance(x1, y1, x2, y2)
  local dx, dy = x2 - x1, y2 - y1
  local distance = math.sqrt(dx * dx + dy * dy)
  local bearing = (to_deg(math.atan2(dx, dy)) + 360) % 360
  return bearing, distance
end

--- Point offset from (x, y) along a bearing for a distance.
function Geo.offset(x, y, bearing, distance)
  local r = to_rad(bearing)
  return x + distance * math.sin(r), y + distance * math.cos(r)
end

--- Smallest absolute difference between two bearings, in degrees (0-180).
function Geo.bearing_delta(a, b)
  local d = math.abs(((a - b) % 360 + 360) % 360)
  if d > 180 then
    d = 360 - d
  end
  return d
end

--- Compass label for a bearing.
function Geo.cardinal(bearing)
  local points = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
  local index = math.floor((((bearing % 360) + 22.5) % 360) / 45) + 1
  return points[index]
end

--- Human-readable position relative to a reference point.
-- e.g. "2.4 km SW (247) of Batumi".
function Geo.describe(x, y, ref)
  local bearing, distance = Geo.bearing_distance(ref.x, ref.y, x, y)
  local range
  if distance < 1000 then
    range = string.format("%d m", math.floor(distance / 10 + 0.5) * 10)
  else
    range = string.format("%.1f km", distance / 1000)
  end
  return string.format("%s %s (%03d) of %s", range, Geo.cardinal(bearing), math.floor(bearing + 0.5), ref.name)
end

--- Min, max and total relief of a list of sampled heights.
function Geo.relief(samples)
  if #samples == 0 then
    return 0, 0, 0
  end
  local min, max = samples[1], samples[1]
  for _, h in ipairs(samples) do
    if h < min then
      min = h
    end
    if h > max then
      max = h
    end
  end
  return min, max, max - min
end

--- Average of a list of numbers (0 for an empty list).
function Geo.mean(values)
  if #values == 0 then
    return 0
  end
  local total = 0
  for _, v in ipairs(values) do
    total = total + v
  end
  return total / #values
end

--- Format a duration in seconds as "1m 23s".
function Geo.duration(seconds)
  if not seconds then
    return "-"
  end
  seconds = math.floor(seconds + 0.5)
  local minutes = math.floor(seconds / 60)
  local rest = seconds % 60
  if minutes == 0 then
    return string.format("%ds", rest)
  end
  return string.format("%dm %02ds", minutes, rest)
end

--- MGRS-style rounding of a coordinate pair for log lines.
function Geo.coord(x, y)
  return string.format("x=%.0f y=%.0f", x, y)
end

return Geo

-- Per-pilot progress and scoring for the training range.
--
-- Pure Lua 5.1 with no DCS API calls, so it is unit-testable outside the game.
-- Time is always "seconds spent on the attempt"; lower is better.

local Progress = {}
Progress.__index = Progress

function Progress.new()
  local self = setmetatable({}, Progress)
  self.pilots = {} -- [pilot] = { [exercise] = { count, best, last, detail } }
  self.labels = {} -- [exercise] = display label
  self.metrics = {} -- [exercise] = "time" | "metres" | "count"
  self.order = {} -- exercise ids in registration order
  return self
end

--- Register an exercise so it appears in reports even before anyone flies it.
-- `metric` is "time" (seconds, lower better), "metres" (lower better) or
-- "count" (no value recorded).
function Progress:register(exercise, label, metric)
  if not self.labels[exercise] then
    self.labels[exercise] = label or exercise
    self.metrics[exercise] = metric or "time"
    self.order[#self.order + 1] = exercise
  end
end

--- Record a completed attempt. Returns count, is_first, is_best.
function Progress:record(pilot, exercise, seconds, detail)
  if not pilot or pilot == "" then
    pilot = "unknown"
  end
  local for_pilot = self.pilots[pilot]
  if not for_pilot then
    for_pilot = {}
    self.pilots[pilot] = for_pilot
  end
  local entry = for_pilot[exercise]
  if not entry then
    entry = { count = 0, best = nil, last = nil, detail = nil }
    for_pilot[exercise] = entry
  end
  entry.count = entry.count + 1
  local is_first = entry.count == 1
  local is_best = false
  if seconds then
    entry.last = seconds
    if entry.best == nil or seconds < entry.best then
      entry.best = seconds
      is_best = true
    end
  end
  if detail then
    entry.detail = detail
  end
  return entry.count, is_first, is_best
end

--- Entry for one pilot and exercise (never nil).
function Progress:get(pilot, exercise)
  local for_pilot = self.pilots[pilot]
  return (for_pilot and for_pilot[exercise]) or { count = 0 }
end

--- Total completions per exercise across all pilots.
function Progress:totals()
  local totals = {}
  for _, exercise in ipairs(self.order) do
    totals[exercise] = 0
  end
  for _, for_pilot in pairs(self.pilots) do
    for exercise, entry in pairs(for_pilot) do
      totals[exercise] = (totals[exercise] or 0) + entry.count
    end
  end
  return totals
end

function Progress:reset(pilot)
  if pilot then
    self.pilots[pilot] = nil
  else
    self.pilots = {}
  end
end

--- Multi-line status report. `format_duration` is injected so this file stays
--- free of formatting policy.
function Progress:report(format_duration)
  format_duration = format_duration or function(s)
    return tostring(s)
  end
  local names = {}
  for pilot in pairs(self.pilots) do
    names[#names + 1] = pilot
  end
  table.sort(names)

  local lines = {}
  if #names == 0 then
    lines[#lines + 1] = "No attempts recorded yet."
  end
  for _, pilot in ipairs(names) do
    lines[#lines + 1] = pilot .. ":"
    local for_pilot = self.pilots[pilot]
    for _, exercise in ipairs(self.order) do
      local entry = for_pilot[exercise]
      if entry and entry.count > 0 then
        local metric = self.metrics[exercise] or "time"
        local best = "-"
        if entry.best then
          if metric == "metres" then
            best = string.format("%.1f m", entry.best)
          else
            best = format_duration(entry.best)
          end
        end
        local suffix = entry.detail and ("  [" .. entry.detail .. "]") or ""
        lines[#lines + 1] =
          string.format("  %-28s x%d  best %s%s", self.labels[exercise] or exercise, entry.count, best, suffix)
      end
    end
  end
  return table.concat(lines, "\n")
end

return Progress

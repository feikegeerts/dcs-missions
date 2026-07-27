-- src/missions/duel-1v1/score.lua — pure-logic kill counter.
-- No DCS API calls: takes a string (player name), returns nothing.
-- Stays testable in luaunit/busted with plain strings (see docs/dev-setup.md §7.7).

env.info("[duel-1v1] score module loaded")

local Tracker = {}
Tracker.kills = {} -- [playerName] = count
Tracker.total = 0

function Tracker:record(playerName)
  if not playerName or playerName == "" then
    return
  end
  self.kills[playerName] = (self.kills[playerName] or 0) + 1
  self.total = self.total + 1
end

function Tracker:reset()
  self.kills = {}
  self.total = 0
end

function Tracker:format()
  if self.total == 0 then
    return "Kills: 0"
  end
  local lines = { string.format("Kills: %d", self.total) }
  local names = {}
  for n, _ in pairs(self.kills) do
    names[#names + 1] = n
  end
  table.sort(names)
  for _, n in ipairs(names) do
    lines[#lines + 1] = string.format("  %s: %d", n, self.kills[n])
  end
  return table.concat(lines, "\n")
end

_G.duel_tracker = Tracker

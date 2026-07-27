std = "lua51"
ignore = [
  "lib/moose-src",
  "lib/mist",
  "src/lib",
  "out",
  "missions",
  "Saved Games",
]

read_globals = {
  -- DCS env scripting API
  "env",
  "timer",
  "trigger",
  "world",
  "coalition",
  "country",
  "land",
  "missionCommands",
  "lfs",
  "mist",

  -- MOOSE (class names used as globals)
  "SPAWN",
  "SPAWNSTATIC",
  "ZONE",
  "ZONE_AIRBASE",
  "ZONE_GROUP",
  "SET_GROUP",
  "SET_UNIT",
  "SET_CLIENT",
  "MESSAGE",
  "MENU_COALITION",
  "MENU_COALITION_COMMAND",
  "TIMER",
  "EVENTS",
  "BASE",
  "AUFTRAG",
  "FLIGHTGROUP",
  "ARMYGROUP",
  "SCORING",
  "_DATABASE",
  "_SETTINGS",
}

-- DCS Lua 5.1.5 — these are absent even though lua51 std knows them
stds.max_line_length = 160

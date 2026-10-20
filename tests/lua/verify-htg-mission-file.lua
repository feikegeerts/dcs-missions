-- Structural verification of a mission file rewritten by
-- build/pack-helicopter-training-miz.ps1.
--
-- Proves, by loading the mission file as Lua and decoding the trigger text back
-- out, that:
--   * the mission file still parses;
--   * the MISSION START trigger carries the payload exactly (both the compiled
--     `trig.actions` form, decoded twice, and the editor-facing `trigrules`
--     form, decoded once);
--   * the mission's own content - slots, weather, theatre - is untouched.
--
-- usage: lua5.1 tests/lua/verify-htg-mission-file.lua <mission-file> <payload-file>

local missionPath, payloadPath = ...
assert(missionPath and payloadPath, "usage: verify-htg-mission-file.lua <mission-file> <payload-file>")

local function read(path)
  local handle = assert(io.open(path, "rb"))
  local text = handle:read("*a")
  handle:close()
  return text
end

local function fail(message)
  io.stderr:write("FAIL: " .. message .. "\n")
  os.exit(1)
end

-- Load the mission file exactly as DCS does: it assigns the global `mission`.
local chunk = assert(loadfile(missionPath), "mission file does not parse")
chunk()
assert(type(mission) == "table", "mission file did not define a mission table")

local payload = read(payloadPath):gsub("\r\n", "\n"):gsub("\n+$", "")

-- The compiled action is a_do_script("<script>"); - decode the inner literal.
local action = mission.trig and mission.trig.actions and mission.trig.actions[1]
if type(action) ~= "string" then
  fail("mission.trig.actions[1] is missing or not a string")
end
local prefix = 'a_do_script("'
if action:sub(1, #prefix) ~= prefix then
  fail('trig.actions[1] does not start with a_do_script(": ' .. action:sub(1, 40))
end
if action:sub(-3) ~= '");' then
  fail('trig.actions[1] does not end with ");')
end
local innerLiteral = action:sub(#prefix, #action - 2) -- includes the closing quote
local decoded = assert(loadstring("return " .. innerLiteral), "trig.actions[1] does not contain a valid Lua string")()
decoded = decoded:gsub("\r\n", "\n"):gsub("\n+$", "")
if decoded ~= payload then
  -- Point at the first difference rather than dumping 60 KiB.
  local limit = math.min(#decoded, #payload)
  local at = limit + 1
  for i = 1, limit do
    if decoded:sub(i, i) ~= payload:sub(i, i) then
      at = i
      break
    end
  end
  fail(
    string.format(
      "payload mismatch in trig.actions[1] at byte %d (decoded %d bytes, payload %d bytes): %q vs %q",
      at,
      #decoded,
      #payload,
      decoded:sub(at, at + 40),
      payload:sub(at, at + 40)
    )
  )
end

-- The editor-facing rule carries the same script, escaped once.
local rule = mission.trigrules and mission.trigrules[1]
if type(rule) ~= "table" then
  fail("mission.trigrules[1] is missing")
end
if rule.predicate ~= "triggerStart" then
  fail("trigrules[1].predicate is " .. tostring(rule.predicate) .. ", expected triggerStart")
end
if rule.eventlist ~= "" then
  fail("trigrules[1].eventlist is " .. tostring(rule.eventlist) .. ", expected an empty (mission start) event list")
end
local ruleAction = rule.actions and rule.actions[1]
if not ruleAction or ruleAction.predicate ~= "a_do_script" then
  fail("trigrules[1].actions[1] is not an a_do_script action")
end
local ruleText = (ruleAction.text or ""):gsub("\r\n", "\n"):gsub("\n+$", "")
if ruleText ~= payload then
  fail(string.format("payload mismatch in trigrules[1].actions[1].text (%d bytes vs %d bytes)", #ruleText, #payload))
end

-- The compiled trigger must actually be wired to run at mission start.
if mission.trig.conditions[1] ~= "return(true)" then
  fail("trig.conditions[1] is not return(true)")
end
if mission.trig.funcStartup[1] ~= "if mission.trig.conditions[1]() then mission.trig.actions[1]() end" then
  fail("trig.funcStartup[1] does not invoke the action at mission start")
end
if mission.trig.flag[1] ~= true then
  fail("trig.flag[1] is not set")
end

-- The mission's own content must survive the rewrite.
local blue = mission.coalition and mission.coalition.blue
local country = blue and blue.country and blue.country[1]
local helicopter = country and country.helicopter
if type(helicopter) ~= "table" then
  fail("the blue coalition's helicopter groups are missing")
end
local groups = helicopter.group or {}
if #groups ~= 6 then
  fail("expected 6 helicopter groups, found " .. #groups)
end
local players = 0
for _, group in pairs(groups) do
  for _, unit in pairs(group.units or {}) do
    if unit.skill == "Client" then
      players = players + 1
    end
  end
end
if players ~= 2 then
  fail("expected 2 client slots, found " .. players)
end
if mission.theatre ~= "Caucasus" then
  fail("theatre is " .. tostring(mission.theatre))
end
if type(mission.weather) ~= "table" or type(mission.start_time) ~= "number" then
  fail("weather or start_time is missing")
end

print(
  string.format(
    "OK - trigger payload %d bytes round-trips, %d helicopter groups, %d client slots, theatre %s",
    #payload,
    #groups,
    players,
    mission.theatre
  )
)

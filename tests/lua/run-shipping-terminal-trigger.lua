-- Verify the actual generated native trigger, including its condition and
-- Blue winner. This deliberately does not mock an invented SSE endMission API.
local path = assert(arg[1], "usage: lua5.1 tests/lua/run-shipping-terminal-trigger.lua <staged mission>")
dofile(path)
local found
for index, source in pairs(mission.trig.conditions) do
  if source:find("DUEL_SURVIVAL_END", 1, true) then
    assert(not found, "duplicate terminal trigger")
    found = index
  end
end
assert(found, "native terminal trigger missing")
local flag, calls = false, 0
local scope = {
  mission = { trig = { conditions = {}, actions = {}, func = {} } },
  c_flag_is_true = function(name)
    assert(name == "DUEL_SURVIVAL_END")
    return flag
  end,
  a_end_mission = function(winner, text, delay)
    assert(winner == "blue", "wrong winner")
  assert(text == "MISSION ENDED" and delay == 10)
    calls = calls + 1
  end,
}
local function compile(source)
  return setfenv(assert(loadstring(source)), scope)
end
scope.mission.trig.conditions[found] = compile(mission.trig.conditions[found])
scope.mission.trig.actions[found] = compile(mission.trig.actions[found])
scope.mission.trig.func[found] = compile(mission.trig.func[found])
scope.mission.trig.func[found]()
assert(calls == 0, "mission ended before terminal flag")
flag = true
scope.mission.trig.func[found]()
assert(calls == 1 and scope.mission.trig.func[found] == nil, "end action not one-shot")
local modern = mission.trigrules[#mission.trigrules]
assert(modern.predicate == "triggerOnce")
assert(modern.rules[1].flag == "DUEL_SURVIVAL_END")
assert(
  modern.actions[1].predicate == "a_end_mission"
    and modern.actions[1].winner == "blue"
    and modern.actions[1].text == "MISSION ENDED"
    and modern.actions[1].start_delay == 10
)
print("shipping terminal trigger: native Blue end action verified")

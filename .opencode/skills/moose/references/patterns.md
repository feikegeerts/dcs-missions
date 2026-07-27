# MOOSE Canonical Patterns

Verified, widely-used patterns. Conventions: constructors are `CLASS:New(...)`, finders are `CLASS:FindByName(name)`, event handlers are `obj:HandleEvent(EVENTS.X)` + `function obj:OnEventX(EventData)`. For any signature beyond these, check the class doc page before writing code.

## Spawning (SPAWN) — the core of this project

Template = a **group placed in the Mission Editor** (usually Late Activation / hidden) whose name is the template name.

```lua
-- Minimal
local spawner = SPAWN:New("Bandit-Flight")
local group = spawner:Spawn()                     -- returns Wrapper.Group or nil

-- With alias (names become "Bandit-Alpha#001" etc. — remember the #NNN suffix when matching names)
local spawnerAlias = SPAWN:NewWithAlias("Bandit-Flight", "Bandit-Alpha")

-- Spawn into a zone / at a coordinate
local group2 = spawner:SpawnInZone(ZONE:New("BanditZone"), true)   -- randomize position
local group3 = spawner:SpawnFromVec3(zone:GetVec3())

-- Limits: max 4 alive from this spawner, 20 total spawns ever
spawner:InitLimit(4, 20)

-- Recurring spawn: every 120–360 s (0.5 = 50% randomization of the 300 s base interval)
spawner:SpawnScheduled(300, 0.5)
spawner:SpawnScheduleStop()

-- Respawn destroyed groups automatically
spawner:InitRepeat()            -- or InitRepeatOnLanding() / InitRepeatOnEngineShutDown()

-- Per-spawn hook
function spawner:OnAfterSpawned(From, Event, To, SpawnedGroup)
  self:I("Spawned " .. SpawnedGroup:GetName())
end
```

Wave pattern (spawn on demand, e.g. from a menu command or score condition):

```lua
local wave = 0
local banditSpawner = SPAWN:NewWithAlias("Bandit-Flight", "Bandit-Wave"):InitLimit(4, 100)
local function spawnWave()
  wave = wave + 1
  banditSpawner:Spawn()
  MESSAGE:New("Wave " .. wave .. " airborne", 15):ToAll()
end
```

## Zones

```lua
local zone     = ZONE:New("Killzone")                        -- ME trigger zone by name
local airbaseZ = ZONE_AIRBASE:New("Kutaisi", 5000)           -- radius around airbase
local movingZ  = ZONE_GROUP:New("ConvoyZone", GROUP:FindByName("Convoy-1"), 500)  -- follows group
local b, u = zone:Get2DDistance(coord1, coord2)              -- helpers live on COORDINATE mostly
zone:IsVec2InZone(someVec2)
```

## Sets (SET_*) — filtered collections

```lua
local redSAMs = SET_GROUP:New():FilterCoalitions("red"):FilterPrefixes("SA-"):FilterActive(true):FilterStart()
redSAMs:ForEachGroupAlive(function(g)
  -- do something
end)
local n = redSAMs:CountAlive()
```

## Events

Prefer MOOSE event handling over `world.addEventHandler` inside MOOSE code.

```lua
-- Attach to any class instance (SPAWN used here, but any object works)
local watcher = BASE:New()
watcher:HandleEvent(EVENTS.Dead)
function watcher:OnEventDead(EventData)
  local group = EventData.IniGroup          -- Wrapper.Group of the "initiator"
  if group and group:GetCoalition() == coalition.side.RED then
    -- award score, trigger respawn, ...
  end
end
```

Common events: `EVENTS.Birth`, `.Dead`, `.Crash`, `.Hit`, `.Shot`, `.Takeoff`, `.Land`, `.PlayerEnterUnit`, `.PlayerLeaveUnit`, `.MarkAdded`, `.MarkChange`. EventData fields: `IniUnit`, `IniGroup`, `IniUnitName`, `IniPlayerName` (player events), `TgtUnit`, `Weapon`, ... — check `Core.Event` docs.

## Timers / scheduling

```lua
-- One-shot after 30 s
TIMER:New(spawnWave):Start(30)

-- Every 60 s, starting in 10 s; stop with timer:Stop()
local t = TIMER:New(function() redSAMs:ForEachGroupAlive(function(g) end) end):Start(10, 60)
```

Never use `timer.scheduleFunction` directly in MOOSE code unless MOOSE has no equivalent; never `while true` loops.

## F10 menus

```lua
local menuSpawn = MENU_COALITION:New(coalition.side.BLUE, "Bandit Control")
MENU_COALITION_COMMAND:New(coalition.side.BLUE, "Spawn next wave", menuSpawn, spawnWave)
-- Group-scoped variant: MENU_GROUP_COMMAND:New(playerGroup, "Text", parentMenu, func, args)
```

## Messaging / logging

```lua
MESSAGE:New("Bandits inbound", 20):ToAll()
MESSAGE:New("Blues only", 10):ToCoalition(coalition.side.BLUE)
MESSAGE:New("audit line", 0):ToLog()          -- goes to dcs.log
self:I("state dump: %s", mist.utils.tableShow(state))   -- on class instances; ToLog style
env.info("[myMission] " .. msg)               -- always lands in dcs.log
```

## OPS tasking (AUFTRAG + FLIGHTGROUP)

Pattern: create an AUFTRAG (order) → add to an OPS group → the group executes with built-in RTB/fuel/ammo logic.

```lua
local fg = FLIGHTGROUP:New("CAP-Flight-1")              -- ME group name (or spawned group)
local capZone = ZONE:New("CAPZone")
local mission = AUFTRAG:NewCAP(capZone, 25000, 350)     -- zone, altitude ft, speed kn
fg:AddMission(mission)
-- Observe execution:
function fg:OnAfterMissionStart(From, Event, To, Mission) self:I("CAP started") end
```

Other order constructors: `AUFTRAG:NewCAS(zone, alt, speed)`, `:NewSEAD(zone, alt, speed)`, `:NewSTRIKE(target, alt)`, `:NewTANKER(...)`, `:NewORBIT(...)`. **Parameter lists differ per order type — always confirm on the `Ops.Auftrag` doc page.** Army/navy equivalents: `ARMYGROUP:New(...)`, `NAVYGROUP:New(...)`.

For hands-off A2A/A2G defense networks, `EasyGCICAP:New(...)` / `EasyAG:New(...)` wire airbases + EWR + CAP zones in one call — check the class pages; they replace the archived `AI_A2*_Dispatcher` classes.

## Score tracking (Functional.Scoring)

```lua
local score = SCORING:New("Range Campaign")
score:AddScoreGroup(playerGroup, 100)        -- per-group score values
-- Events (hit/kill) update scores; query per player; SCORING can persist to CSV (needs de-sanitized io)
```

For custom scoring (this project has its own `src/score/` logic), the idiomatic base is `HandleEvent(EVENTS.Dead/.Hit)` + your own tables, using SCORING only if its model fits. Keep custom score logic free of DCS API calls where possible so it stays unit-testable outside the game.

## Debugging

```lua
BASE:TraceOn()                  -- or mySpawner:TraceOn():TraceLevel(2)
-- remember: tracing is OFF by default in the static Moose_.lua build
-- verify load: dcs.log must contain "*** MOOSE INCLUDE END ***"
```

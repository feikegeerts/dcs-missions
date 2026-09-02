# Mission spec: duel-dynamic

Current active mission (`.current-mission = duel-dynamic`). **1–4 player slots vs
matching 1–4 aircraft AI package waves**. Each wave is one multi-aircraft DCS
group spawned in close formation 60+ statute miles from the blue-player
centroid. It receives a shared MOOSE CAP task so multiplayer produces one
package fight rather than unrelated paired duels.

This is a test bed for the dynamic-spawn pipeline. It supersedes `duel-1v1`
(see §10).

**Shipping status:** the self-contained `.miz` is built and verified on a stock,
sanitized dedicated server. See `docs/shipping-duel-dynamic.md`.

---

## 1. What's in the repo

```
src/
  bootstrap.lua                       # dispatcher (shared, never mission-specific)
  lib/Moose_.lua                      # pinned MOOSE build
  missions/
    duel-dynamic/
      main.lua                        # entry: events, F10 menu, AI tasking, init poll
      score.lua                       # pure-logic kill counter (_G.duel_tracker)
  .current-mission                   # contains the string "duel-dynamic"
```

Both `.miz` files (`duel-1v1.miz` and `duel-dynamic.miz`) currently share the
same generic loader trigger. Only the contents of `missions/<name>/` differ.
Switch active mission by editing `.current-mission` and restarting.

---

## 2. Roster and template model

| Role | Mission Editor groups |
|---|---|
| Blue player roster | `Aerial-1`, `Aerial-2`, `Aerial-3`, `Aerial-4` |
| Active red wave template | `Bandit-1` (one aircraft, Late Activation) |
| Retained legacy templates | `Bandit-2`, `Bandit-3` (not spawned by the package-wave lifecycle) |

The player slots are normal client slots. The red groups are **Late Activation
✓**. `SPAWN:InitGrouping(1|2|3|4)` clones the `Bandit-1` aircraft into one true
multi-unit DCS group, while `InitSetUnitRelativePositions` lays out the group in
a compact wedge.

`PLAYER_GROUP_NAMES` defines the available blue roster. `BANDIT_GROUP_NAMES`
remains the telemetry allow-list; `BANDIT_GROUP_NAMES[1]` is the active wave
template. Update the mission archive, source arrays, telemetry tests, and this
spec together if these names change.

---

## 3. Behaviour

### 3.1 Spawn rules

- **Initial spawn.** The init poll catches all occupied slots, then waits a
  three-second assembly window. One red DCS group is spawned with one aircraft
  per live blue aircraft.
- **Placement.** The red lead spawns 60–72 statute miles from the arithmetic
  blue centroid. Wingmen are about 1.5 NM laterally and 0.5 NM in trail, all
  facing back toward blue.
- **Tasking.** The package receives one `AUFTRAG:NewCAP` over a 150 km zone
  centered on the blue package, plus immediate `WEAPON_FREE`, `RED` alarm, and
  `EVADE_FIRE` options.
- **Player enters during a live wave.** The current DCS group is not mutated or
  reset. The joiner is included in the next wave. DCS cannot add an aircraft to
  an already spawned group.
- **Player leaves or dies.** The current red package remains available to the
  other players. If every blue slot becomes empty, a one-second delayed cleanup
  destroys the package and cancels pending wave work.
- **Bandit is killed.** The individual loss is counted, but no replacement
  spawns while any aircraft from that wave remains alive.
- **Whole wave is killed.** The 30-second timer begins after the final red loss.
  The next wave is spawned as one package sized from the live blue aircraft at
  callback time.

### 3.2 Distance rule

```
MIN_SEPARATION_M    = 60 * 1609.344   # 60 statute miles ≈ 52 nm
RANDOM_DIST_MIN_M   = MIN_SEPARATION_M
RANDOM_DIST_MAX_M   = MIN_SEPARATION_M + 20000  # 60–72 sm
SPAWN_ALTITUDE_M    = 15000 * 0.3048  # 15 000 ft
```

Statute miles, not nautical. `60 sm ≈ 52 nm`. Logging reports the lead's
distance from the blue centroid in nautical miles.

### 3.3 Aggression knobs

All at the top of `main.lua` (search for `-- Bandit AI tasking`). Reload after
editing (mission restart; no repack needed).

| Setting | Default | Effect |
|---|---|---|
| `BANDIT_TASK` | `"CAP"` | `"CAP"` gives the complete package a shared engagement area. `"INTERCEPT"` focuses the package on the first live player and is retained for testing. |
| `BANDIT_ROE` | `"WEAPON_FREE"` | `"WEAPON_FREE"` = fire on any detected. `"OPEN_FIRE"` = hostile-only. `"HOLD"` = never. |
| `BANDIT_ROT` | `"EVADE_FIRE"` | Defensive break when fired on. |
| `BANDIT_ALARM` | `"RED"` | `"RED"` = engage on detection. `"AUTO"` = smart. `"GREEN"` = manual. |
| `BANDIT_ALT_FT` | `25000` | Working altitude in feet. |
| `BANDIT_SPEED_KT` | `450` | Cruise speed in knots. |
| `BANDIT_CAP_RADIUS_M` | `150000` | CAP zone radius in metres (CAP mode only). Contains the complete red spawn ring. |

The aggression settings are applied *directly* to the live DCS group first
(`OptionROEOpenFireWeaponFree`, `OptionAlarmStateRed`, `OptionROTEvadeFire`)
and also written onto the AUFTRAG (`mission.optionROE`,
`mission.optionAlarm`). Both layers because the live options take effect
immediately, and the AUFTRAG options ensure the mission task is built
correctly.

### 3.4 F10 menu

Coalition-scoped (blue-only). Available from MISSION START.

- **Show kills** — `MESSAGE:New(Tracker:format(), 10):ToCoalition(BLUE)`
- **Reset kills** — `Tracker:reset()`
- **Respawn bandit wave** — explicitly destroys the current package and
  immediately spawns one replacement package sized to the live blue aircraft.

---

## 4. Implementation notes

### 4.1 Custom RNG

DCS's mission sandbox disables `math.randomseed`. A tiny LCG is used
instead (Glibc-style constants):

```lua
local _rngState = (os.time() % 2147483648)
local function randInt(min, max)
  _rngState = (_rngState * 1103515245 + 12345) % 2147483648
  return min + (_rngState % (max - min + 1))
end
```

Adequate for a duel (not cryptographically random). Seeded from `os.time()`
at MISSION START, so it changes every run.

### 4.2 The init poll loop

`SCHEDULER:New(nil, fn, {}, INIT_DELAY, INIT_POLL_INTERVAL, 0, INIT_TIMEOUT)`
uses `INIT_DELAY=1`, `INIT_POLL_INTERVAL=1`, and `INIT_TIMEOUT=0`. MOOSE treats
a stop value of zero as no timeout. Every second the function checks whether
any group in `PLAYER_GROUP_NAMES` is alive. When one is, it runs `doInit()`
(builds spawners, randomises headings, and catches every already-occupied
slot) and returns `false` to stop the scheduler cleanly.

**Why a poll instead of a one-shot delay?** On a busy MP server the
`DATABASE.AddPlayer` event for the joining client can fire 2–3 s *after*
`simResume`. A fixed 1 s delay would race. A dedicated server can also run
headless for minutes before its first player arrives. The poll therefore has
no wall-clock timeout and accepts the first occupied Aerial slot, not only
`Aerial-1`. The catch pass records every live slot, and the three-second
assembly callback creates one package from the resulting roster.

### 4.3 Kill handler details

`banditWatcher` listens on `EVENTS.Dead` and `EVENTS.Crash`. It filters by red
coalition and the exact current wave group name. `countedBanditUnits` dedupes
on `IniDCSUnitName`/`IniUnitName`, so separate aircraft in the same DCS group
score separately while duplicate Dead/Crash reports do not. The 30-second
schedule is created only when `currentWaveAlive` reaches zero.

### 4.4 Wave scheduling and cancellation

Only one wave spawn can be pending. A monotonically increasing token makes
stale scheduler callbacks harmless after an F10 reset or empty-server cleanup.
Player deaths have no mission-specific watcher and do not reset red aircraft.

---

## 5. Mission Editor setup (one-time per .miz)

### 5.1 Map, coalitions, weather

Caucasus (small, fast load). Daytime, scattered clouds, visibility > 9 km.
Both Blue and Red coalitions active.

### 5.2 Player slots

Four blue player/client groups, country = any blue country,
**not** late-activated. Place airborne at 15 000 ft. Names **must be
exactly** `Aerial-1`, `Aerial-2`, `Aerial-3`, `Aerial-4`. The current archive
contains three `FA-18C_hornet` slots and one `F-16C_50` slot.

### 5.3 Bandit SPAWN templates

Three one-aircraft red AI groups currently exist, named `Bandit-1`, `Bandit-2`,
and `Bandit-3`, with **Late Activation ✓**. The current wave spawner uses
`Bandit-1` and MOOSE `InitGrouping` to create a 1–4 aircraft group. `Bandit-2`
and `Bandit-3` are retained for compatibility with historical telemetry and
older builds, but the package-wave lifecycle does not spawn them.

### 5.4 Trigger

Exactly one MISSION START trigger, **no conditions**, action `DO SCRIPT`
with the standard loader (identical across all missions):

```lua
local ok, err = pcall(function()
  assert(loadfile([[C:\Projects\dcs-missions\src\bootstrap.lua]]))()
end)
if not ok then env.error("[myMission] bootstrap: " .. tostring(err)) end
```

Save to `Saved Games\DCS.dcs_serverrelease\Missions\duel-dynamic.miz`
(adjust for the channel you're testing on). Add to the server's mission
list via the WebGUI.

---

## 6. Known limitations (DCS-imposed)

### 6.1 `setPosition` on a client-controlled player slot is a no-op in MP

`Unit:setPosition(Vec3, heading)` is called with the current position and a
random heading. The **heading** is applied to the client (you can see it in
the HSI). The **position** is silently ignored — the client stays locked to
the ME slot position. Confirmed on ED forums: "Player slots can't be made
or moved after mission start" (Kanelbolle, 2022; corroborated by Grimes, ED
Beta Tester).

Implication: player aircraft remain tied to their ME slots. Every red wave gets
a fresh random package position, but the mission does not move human aircraft.

### 6.2 `GROUP:Teleport` on a dead group ignores the new zone

MOOSE's `GROUP:Teleport(coord)` calls `Respawn(nil, false)`. The
`Respawn` source has an `if self:IsAlive() then … end` guard around the
position-update logic — when the group is dead, the guard fails and the
new group is spawned at the **ME template position**, not at `coord`.
Symptom: a "ghost" blue group at the original airbase plus the intended new
group at the target position. The package-wave lifecycle has no player-death
reset handler and does not call `Teleport`.

The proper way to respawn a player at a new coord is
`mist.teleportToPoint({ groupName, point, action = "respawn" })`. MIST is
not currently loaded by `bootstrap.lua`; add it to the bootstrap if you
need true random player respawns. (See `docs/PROJECT-STATUS.md` §4.)

### 6.3 `SET_GROUP:FilterActive()` rejects player groups

`SET_GROUP:New():FilterActive()` is gated on `UNIT:IsActive()`, which
returns `false` for a player-controlled aircraft that hasn't yet started
its task. Use `GROUP:FindByName(name):IsAlive()` directly instead. The
project's `getPlayerCoord` already does this.

### 6.4 Spawn callbacks fire before the unit has a name

MOOSE's `SPAWN:OnSpawnGroup` callback fires asynchronously on the next
simulation frame. Inside the callback the group is alive but the
`OnSpawnGroup` registration itself works fine; just don't rely on
`grp:GetName()` returning a specific format until after one frame.

### 6.5 Multiplayer messages and attribution

The obsolete coalition-wide “You died” and player-respawn messages were
removed with the player-death reset handler. Bandit kill popups explicitly say
`Team kills` and show the remaining red-package count. The victim-side event
still cannot authoritatively identify the killer; individual attribution is
deferred to telemetry Slice 14.

---

## 7. What success looks like

In `Saved Games\DCS.dcs_serverrelease\Logs\dcs.log`, after a fresh mission
start with a player in `Aerial-1`:

```
*** MOOSE INCLUDE END ***
[bootstrap] loading missions/duel-dynamic/main.lua
[duel-dynamic] main start
[duel-dynamic] MOOSE loaded
[duel-dynamic] score module loaded
[duel-dynamic] main done (init pending)
[bootstrap] done
-- (init poll retries until at least one player aircraft is alive)
[duel-dynamic] init: no player group alive yet, retrying...
[duel-dynamic] Aerial-1 heading randomized to 080 (pos kept at ME)
[duel-dynamic] Aerial-1 already occupied at init — adding to first package roster
[duel-dynamic] package wave scheduled in 3s (initial player package assembled)
[duel-dynamic] init done — package-wave lifecycle active
[duel-dynamic] spawning 1-ship package 59.5 nm from blue centroid, heading 080 (...)
[duel-dynamic] package spawned: Bandit-1#001 at x=-141498 z=165369 alt=4569m
[duel-dynamic] tasked Bandit-1#001 → CAP on blue package centroid (1 players) (...)
```

Then after the kill:

```
[duel-dynamic] wave 1 defeated — next package in 30s
-- 30 s later:
[duel-dynamic] spawning 1-ship package 58.3 nm from blue centroid, heading ...
[duel-dynamic] package spawned: Bandit-1#002 at …
```

If a package does not appear within a few seconds after entering a slot, check
for `init done`, `package wave scheduled`, and `spawning N-ship package` in
`dcs.log`. Also check that `Bandit-1` exists in the ME with Late Activation ✓.
The first `SCRIPTING ERROR` line names the file and line.

---

## 8. Testing the count-matching (1 / 2 / 3 / 4 players)

- **1 live player:** one `Bandit-1#NNN` group containing one aircraft.
- **2 live players during assembly:** one group containing two aircraft in
  close formation.
- **3 live players during assembly:** one group containing three aircraft.
- **4 live players during assembly:** one compact group containing four
  aircraft.
- **Join during combat:** no immediate reset or second group; the next wave
  uses the new live-player count.
- **First red loss in a multi-ship wave:** no respawn timer yet.
- **Final red loss:** one 30-second timer, followed by one complete new group.
- **All players leave:** the current group is destroyed after the one-second
  slot-switch grace period.

To test mid-mission, use the WebGUI "force slot" / "kick to slot"
controls, or have the player eject and switch slots in the in-mission
slot selector.

---

## 9. Verifying AI behaviour in Tacview

Recommended. Records spawn positions/timing, routes, weapon events. The
Caucasus missions generate ~1 MB of `.acmi` per minute.

- **Default location:** `%USERPROFILE%\Documents\Tacview\`
- **Dedicated server:** install/enable it for the active
  `Saved Games\DCS.dcs_serverrelease` profile and verify that profile's
  `Config\options.lua`/export settings (see `dev-setup.md §7.5`).
- **What to look for:** the red lead should be 60+ sm from the blue centroid;
  red wingmen should be within a few NM in one formation and maneuver as one
  DCS group. No replacement should appear after a partial red loss. The next
  complete group should appear 30 seconds after the final red loss.

---

## 10. Superseded mission: duel-1v1

`src/missions/duel-1v1/` is the original 1-vs-1 test mission. It still
exists in the repo for reference, but it is **incomplete** — see
`docs/PROJECT-STATUS.md` §3. Don't switch back to it without first
finishing the cleanup; the spec at `docs/spec-duel-1v1.md` describes
the old single-bandit design.

`duel-dynamic` is the mission that's actively developed and tested.

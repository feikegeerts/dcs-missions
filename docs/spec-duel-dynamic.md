# Mission spec: duel-dynamic

Current active mission (`.current-mission = duel-dynamic`). **1–4 player slots vs
progressively larger AI package waves**. Each wave picks a uniform-random
donor from the ten `Bandit-1`..`Bandit-10` ME groups and spawns one
multi-aircraft DCS group in close formation 55–85 statute miles from the
blue-player centroid, with a per-wave random altitude/speed profile. It
receives a shared MOOSE CAP task so multiplayer produces one package fight
rather than unrelated paired duels. Group options (ROE, alarm state,
reaction-on-threat) defer to the per-donor ME settings.

This is the active test bed for the dynamic-spawn pipeline.

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

The active `.miz` uses the generic loader trigger. Switch the active source
mission by editing `.current-mission` and restarting. Mission archives are
environment artifacts, not tracked source files in this repository.

---

## 2. Roster and template model

| Role | Mission Editor groups |
|---|---|
| Blue player roster | `Aerial-1`, `Aerial-2`, `Aerial-3`, `Aerial-4` |
| Red wave donors (all active) | `Bandit-1` .. `Bandit-10` (one aircraft each, Late Activation) |

The player slots are normal client slots. The red groups are **Late Activation
✓**. Each wave picks one donor uniformly at random; `SPAWN:InitGrouping(1|2|3|4)`
clones the chosen donor aircraft into one true multi-unit DCS group, while
`InitSetUnitRelativePositions` lays out the group in a compact wedge. Spawns
copy the donor's airframe, payload, skill, and route options; DCS
auto-suffixes the spawned group name with `#NNN`.

`PLAYER_GROUP_NAMES` defines the available blue roster. Each player identity
has three lives by default for one mission run; players with no lives remaining
are excluded when the next package is sized. `BANDIT_GROUP_NAMES`
(all ten names, ascending) is both the donor list and the telemetry
allow-list; the actual chosen donor name is passed as the configured name
when a spawned wave is registered with telemetry.

### Donor table (2026-09-13 mission file)

All donors: ROE=WEAPON_FREE route option, per-unit skill Excellent,
late-activated, task CAP. Loadouts/skill/chaff/flare are ME-owned — the code
never touches them.

| Donor | Airframe | Chaff / flare | Loadout | MISSILE_ATTACK |
|---|---|---|---|---|
| Bandit-1 | FA-18C_hornet | 60 / 60 | 4x AIM-120C + 2x AIM-9 | max-range |
| Bandit-2 | FA-18C_hornet | 60 / 60 | 4x AIM-120C + 2x AIM-9 | threat-estimate |
| Bandit-3 | MiG-29S | 30 / 30 | 2x R-73 + 2x R-27ER + 2x R-60 | threat-estimate |
| Bandit-4 | F-16C_50 | 60 / 60 | 4x AAM | threat-estimate |
| Bandit-5 | F-16C_50 | 60 / 60 | 4x AAM | max-range |
| Bandit-6 | MiG-29S | 30 / 30 | 2x R-73 + 2x R-27ER + 2x R-60 | max-range |
| Bandit-7 | F-5E-3 | 30 / 15 | AIM-9 short-range only | threat-estimate |
| Bandit-8 | Su-33 | 48 / 48 | R-73 + R-27ER + R-60 mix | max-range |
| Bandit-9 | Su-33 | 48 / 48 | R-73 + R-27ER + R-60 mix | max-range |
| Bandit-10 | MiG-21Bis | 18 / 40 | 2x R-3S + 2x R-3R + ASO-2 pod | threat-estimate |

Note: the Su-33 module is not installed on the test server, so `SPAWN:New`
for Bandit-8/Bandit-9 may fail there. Init logs the failure per donor and
continues with the survivors; if no donor can be created, init is not marked
done and the poll retries.

---

## 3. Behaviour

### 3.1 Spawn rules

- **Initial spawn.** The init poll catches all occupied slots, then waits a
  three-second assembly window. One red DCS group is spawned with one aircraft
  per live blue aircraft, cloned from a uniform-random `Bandit-N` donor.
- **Progressive difficulty.** The first three waves match the eligible live
  blue package. Every three waves already spawned adds one bandit to the next
  package: waves 4–6 get +1, waves 7–9 get +2, and so on. Package size is
  capped at eight. The knobs are `WAVE_ESCALATION_EVERY=3` and
  `MAX_PACKAGE_SIZE=8`.
- **Placement.** The red lead spawns 55–85 statute miles from the arithmetic
  blue centroid, at a per-wave random 15,000–25,000 ft. Wingmen are about
  1.5 NM laterally and 0.5 NM in trail, all facing back toward blue.
- **Tasking.** The package receives one `AUFTRAG:NewCAP` over a 150 km zone
  centered on the blue package, with a per-wave random working altitude of
  15,000–30,000 ft and cruise speed of 350–550 kt. Group options are not
  force-set: ROE, alarm state, and reaction-on-threat defer to the donor's
  ME settings (see §3.3).
- **Player enters during a live wave.** The current DCS group is not mutated or
  reset. The joiner is included in the next wave. DCS cannot add an aircraft to
  an already spawned group.
- **Player leaves.** Remaining lives are retained and the current red package
  remains available to the other players. If every blue slot becomes empty, a
  one-second delayed cleanup destroys the package and cancels pending wave work.
- **Player aircraft is lost.** `playerDeathWatcher` deduplicates `Dead` and
  `Crash` by unit name and removes one life. Identity is the non-empty player
  UCID when DCS supplies it, otherwise the slot group name with a one-time
  warning. A missing lives entry discovered on a verified loss is initialized
  to the configured `LIVES_PER_PLAYER=3` default before decrementing. Rejoining
  with the same UCID, including in another slot, retains the remaining lives.
- **Player reaches zero lives.** That identity remains tracked but is excluded
  from package sizing. If every tracked identity reaches zero, the mission
  enters terminal state once and announces `All pilots down — mission over.`
  The current red wave is not despawned. New scheduled and F10 wave requests
  are refused; there is no forced-respawn loop or scripted DCS mission end.
- **Bandit is killed.** The individual loss is counted, but no replacement
  spawns while any aircraft from that wave remains alive.
- **Whole wave is killed.** The 30-second timer begins after the final red loss.
  The next wave is spawned as one package sized from the live blue aircraft at
  callback time.

### 3.2 Distance rule

```
RANDOM_DIST_MIN_M   = 55 * 1609.344  # 55 statute miles ≈ 48 nm
RANDOM_DIST_MAX_M   = 85 * 1609.344  # 85 statute miles ≈ 74 nm
SPAWN_ALTITUDE_M    = 15000 * 0.3048 # 15 000 ft floor (TEST_COMBAT default)
SPAWN_ALT_MIN_FT    = 15000
SPAWN_ALT_MAX_FT    = 25000          # per-wave spawn altitude
CAP_ALT_MIN_FT      = 15000
CAP_ALT_MAX_FT      = 30000          # per-wave CAP working altitude
CAP_SPEED_MIN_KT    = 350
CAP_SPEED_MAX_KT    = 550            # per-wave CAP cruise speed
```

Statute miles, not nautical. `55 sm ≈ 48 nm`, `85 sm ≈ 74 nm`.
Distances always use 1609.344 m per statute mile, and the spawn log reports
the lead's distance from the blue centroid in statute miles ("mi"). (An
older build logged nautical miles; the distances were always statute.)

### 3.3 Aggression knobs

Code owns only the task plus the CAP radius. ROE, alarm state,
reaction-on-threat, and missile launch mode are per-donor ME settings the
user varies in the mission editor (all donors ROE=WEAPON_FREE;
MISSILE_ATTACK max-range on Bandit-1/5/6/8/9 vs threat-estimate on
Bandit-2/3/4/7/10 — see the donor table in §2).

| Setting | Default | Effect |
|---|---|---|
| `BANDIT_TASK` | `"CAP"` | `"CAP"` gives the complete package a shared engagement area. `"INTERCEPT"` focuses the package on the first live player and is retained for testing. |
| `BANDIT_CAP_RADIUS_M` | `150000` | CAP zone radius in metres (CAP mode only). Contains the complete red spawn ring. |

Defer-to-ME mechanism, in one sentence: the script never calls the
`OptionROE*`/`OptionAlarmState*`/`OptionROT*` setters on the spawned group,
and it sets the `optionROE`/`optionROT`/`optionAlarm` fields that
`AUFTRAG:NewCAP` bakes onto the mission object back to `nil`, which MOOSE's
`OPSGROUP:_SetMissionOptions` skips (it only applies truthy options) — so
the donor's ME values carry through untouched. The per-wave CAP altitude and
speed are still passed to `NewCAP`; they are tasking parameters, not group
options.

### 3.4 F10 menu

Coalition-scoped (blue-only). Available from MISSION START.

- **Show kills** — displays `Team kills: N`, followed by the existing
  per-counter lines.
- **Reset kills** — resets the tracker and announces `Kills reset.`
- **Respawn bandit wave** — explicitly destroys the current package and
  immediately spawns one replacement package sized to eligible live blue
  aircraft plus the current escalation. It announces `New bandit wave inbound.`,
  `No players in the air.`, `Not ready yet — try again in a second.`, or
  `Mission over — no more waves.` as applicable.
- **Show lives** — displays `Lives:` followed by each tracked display name and
  remaining lives, or `No players yet.` before anyone has been tracked.

Wave and loss calls use the same concise briefing voice: `Wave N — N hostile(s)
inbound`, `Bandit down — team N, N hostile(s) left`, `Aircraft lost — N lives
left.`, `Aircraft lost — 1 life left.`, and `Aircraft lost — out of lives.`

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
Player deaths do not reset red aircraft. Terminal state blocks both newly
requested schedules and callbacks from schedules created before the last life
was lost.

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

Ten one-aircraft red AI groups named `Bandit-1` .. `Bandit-10`, all with
**Late Activation ✓** and per-unit skill Excellent. Each wave clones one
uniform-random donor via MOOSE `InitGrouping` into a 1–4 aircraft group
(see the donor table in §2 for airframes, loadouts, chaff/flare, and the
per-donor MISSILE_ATTACK variation). All ten names must stay in
`BANDIT_GROUP_NAMES` in `main.lua` and in the telemetry allow-list; update
the mission archive, source arrays, telemetry tests, and this spec together
if these names change.

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
group at the target position. The lives handler does not respawn or teleport
player aircraft.

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

All player-facing messages are coalition-wide because this mission uses
`MESSAGE:ToCoalition(BLUE)`; a loss notice cannot be restricted reliably to the
affected human with the current mission API surface. Bandit kill popups label
the team total and show the remaining hostile count. The victim-side event
still cannot authoritatively identify the killer; individual attribution is
deferred to telemetry Slice 14.

### 6.6 DCS-native player respawn cannot be blocked per identity

The script cannot prevent DCS from respawning a human whose tracked identity
has zero lives. A zero-life identity that re-enters any slot is announced with
`Out of lives — excluded from the package.` and remains excluded from package
sizing; the slot itself is not blocked or forcibly removed.

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
[duel-dynamic] spawning 1-ship package 62.4 mi from blue centroid, heading 080 (initial player package assembled, donor Bandit-6, alt 18200 ft, speed 431 kt)
[duel-dynamic] package spawned: Bandit-6#001 (donor Bandit-6) at x=-141498 z=165369 alt=5551m
[duel-dynamic] tasked Bandit-6#001 → CAP on blue package centroid (1 players) (group options defer to the ME donor settings)
```

Then after the kill:

```
[duel-dynamic] wave 1 defeated — next package in 30s
-- 30 s later:
[duel-dynamic] spawning 1-ship package 62.1 mi from blue centroid, heading ...
[duel-dynamic] package spawned: Bandit-4#002 (donor Bandit-4) at …
```

If a package does not appear within a few seconds after entering a slot, check
for `init done`, `package wave scheduled`, and `spawning N-ship package` in
`dcs.log`. Also check that all ten `Bandit-N` groups exist in the ME with Late Activation ✓.
The first `SCRIPTING ERROR` line names the file and line.

---

## 8. Testing the count-matching (1 / 2 / 3 / 4 players)

- **1 live player:** waves 1–3 contain one bandit; wave 4 contains two.
- **2 live players during assembly:** one group containing two aircraft in
  close formation before escalation.
- **3 live players during assembly:** one group containing three aircraft
  before escalation.
- **4 live players during assembly:** one compact group containing four
  aircraft before escalation; later waves grow to the eight-aircraft cap.
- **Join during combat:** no immediate reset or second group; the next wave
  uses the new live-player count.
- **First red loss in a multi-ship wave:** no respawn timer yet.
- **Final red loss:** one 30-second timer, followed by one complete new group.
- **Player loss:** one life removed per aircraft despite a Dead/Crash pair;
  zero-life identities do not contribute to the next package size.
- **All tracked identities at zero:** one terminal announcement, no further
  package spawn, and no forced despawn of the current red wave.
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
- **What to look for:** the red lead should be 55–85 sm from the blue centroid;
  red wingmen should be within a few NM in one formation and maneuver as one
  DCS group. No replacement should appear after a partial red loss. The next
  complete group should appear 30 seconds after the final red loss.

---

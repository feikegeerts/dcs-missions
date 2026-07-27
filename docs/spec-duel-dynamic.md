# Mission spec: duel-dynamic

Current active mission (`.current-mission = duel-dynamic`). **1–3 player slots vs
1–3 AI bandits**, paired 1:1 by index. Each blue player slot has a matching
red bandit SPAWN template; a player entering spawns their paired bandit 60+ mi
away in a random direction; a player leaving despawns it. Bandits engage the
player via MOOSE `AUFTRAG:NewINTERCEPT`.

This is a test bed for the dynamic-spawn pipeline. It supersedes `duel-1v1`
(see §10).

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

## 2. Pairing model

| Index | Blue slot (player, ME) | Red bandit (SPAWN template, ME) |
|------:|---|---|
| 1 | `Aerial-1` | `Bandit-1` |
| 2 | `Aerial-2` | `Bandit-2` |
| 3 | `Aerial-3` | `Bandit-3` |

Only the bandit groups must be **Late Activation ✓** in the ME (they're SPAWN
templates). The player slots are normal client slots — they spawn at mission
start and persist.

The code uses `BANDIT_GROUP_NAMES[i]` and `PLAYER_GROUP_NAMES[i]` as parallel
arrays. If you add or rename a pair, update both arrays at the top of
`missions/duel-dynamic/main.lua` (search for `-- Pairing config`).

---

## 3. Behaviour

### 3.1 Spawn rules

- **Initial spawn.** The first-round `init` runs in a poll loop (see §4.2).
  When the world is ready, it builds the bandit `SPAWN` objects and randomises
  each player slot's **heading** (the position part is a no-op on a
  client-controlled player slot in MP; see §6). The player stays at the ME
  position for round 1.
- **Player enters a slot.** A `PlayerEnterUnit` event spawns the paired
  bandit 60+ mi from the live player position, in a random heading.
  The bandit is given an `INTERCEPT` task on the player's group and immediate
  aggressive options (`WEAPON_FREE` ROE, `RED` alarm, `EVADE_FIRE` ROT).
- **Player leaves.** A `PlayerLeaveUnit` event despawns the paired bandit.
- **Bandit is killed.** A 30 s respawn timer fires; on fire, the bandit is
  re-spawned 60+ mi from the live player in a fresh random direction.
- **Player is killed.** A 30 s respawn timer fires; on fire, the *old* bandit
  is despawned and a *fresh* bandit is spawned 60+ mi from the player's
  current group position. **The player group itself is not teleported** (see
  §6.1). The player rejoins the same slot at the death location.

### 3.2 Distance rule

```
MIN_SEPARATION_M    = 60 * 1609.344   # 60 statute miles ≈ 52 nm
RANDOM_DIST_MIN_M   = MIN_SEPARATION_M
RANDOM_DIST_MAX_M   = MIN_SEPARATION_M + 20000  # 60–72 sm
SPAWN_ALTITUDE_M    = 15000 * 0.3048  # 15 000 ft
```

Statute miles, not nautical. `60 sm ≈ 52 nm`. Logging reports in nm
(`"spawning Bandit-1 59.5 nm from Aerial-1"`).

### 3.3 Aggression knobs

All at the top of `main.lua` (search for `-- Bandit AI tasking`). Reload after
editing (mission restart; no repack needed).

| Setting | Default | Effect |
|---|---|---|
| `BANDIT_TASK` | `"INTERCEPT"` | `"INTERCEPT"` chases the player directly. `"CAP"` orbits a zone; uses `BANDIT_CAP_RADIUS_M`. |
| `BANDIT_ROE` | `"WEAPON_FREE"` | `"WEAPON_FREE"` = fire on any detected. `"OPEN_FIRE"` = hostile-only. `"HOLD"` = never. |
| `BANDIT_ROT` | `"EVADE_FIRE"` | Defensive break when fired on. |
| `BANDIT_ALARM` | `"RED"` | `"RED"` = engage on detection. `"AUTO"` = smart. `"GREEN"` = manual. |
| `BANDIT_ALT_FT` | `25000` | Working altitude in feet. |
| `BANDIT_SPEED_KT` | `450` | Cruise speed in knots. |
| `BANDIT_CAP_RADIUS_M` | `100000` | CAP zone radius in metres (CAP mode only). |

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
- **Respawn all bandits** — spawns a fresh bandit for every pair (one per
  bandit index), regardless of whether a player is in the slot. Useful for
  shake-downs.

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
with `INIT_DELAY=1`, `INIT_POLL_INTERVAL=1`, `INIT_TIMEOUT=30`. Every second
the function checks `GROUP:FindByName(PLAYER_GROUP_NAMES[1]):IsAlive()`.
When the world is finally populated it runs `doInit()` (builds spawners,
randomises headings, catches any already-occupied slot) and calls
`initMaster:Stop(initScheduleID)` to cancel the poll.

**Why a poll instead of a one-shot delay?** On a busy MP server the
`DATABASE.AddPlayer` event for the joining client can fire 2–3 s *after*
`simResume`. A fixed 1 s delay would race. The poll guarantees the init only
fires when `Aerial-1` is actually findable and alive.

### 4.3 Kill handler details

`banditWatcher` listens on `EVENTS.Dead` and `EVENTS.Crash`. It filters by
`EventData.IniCoalition == coalition.side.RED` (more reliable than
`victim:GetCoalition()` on dead wrappers) and by `^Bandit-N` group name
prefix. A `countedGroups[gname]` table dedupes — each bandit group only
counts once per death, so duplicate Dead/Crash events for the same kill
don't double-count. The kill fires a `SCHEDULER` for `RESPAWN_DELAY` (30 s)
that re-spawns the bandit only if the paired player slot is still occupied.

### 4.4 Death handler details

`playerDeathWatcher` listens on `EVENTS.Dead`, `EVENTS.Crash`,
`EVENTS.PilotDead`. Same coalition + name + dedup pattern. The death
fires a `SCHEDULER` for `PLAYER_RESPAWN_DELAY` (30 s) that:
1. Reads the player's current group position (`GROUP:FindByName(pname)`)
   — this is the *slot* position (where the player died), not the dying
   group, because the dying group may be destroyed by the time the
   scheduler fires.
2. Despawns the old bandit.
3. Spawns a fresh bandit 60+ mi from the player-anchor via
   `spawnBanditAt(idx, playerAnchor)`.

The player is not teleported (see §6.1). They rejoin the same slot at
the death position.

---

## 5. Mission Editor setup (one-time per .miz)

### 5.1 Map, coalitions, weather

Caucasus (small, fast load). Daytime, scattered clouds, visibility > 9 km.
Both Blue and Red coalitions active.

### 5.2 Player slots

Three blue client groups, skill = Player, country = any blue country,
**not** late-activated. Place airborne at 15 000 ft. Names **must be
exactly** `Aerial-1`, `Aerial-2`, `Aerial-3`.

### 5.3 Bandit SPAWN templates

Three red AI groups, skill = Good (or Client for the dumbest bandits),
country = any red country. Names **must be exactly** `Bandit-1`, `Bandit-2`,
`Bandit-3`. **Late Activation ✓ on each** — this is critical; the bandit
must not auto-spawn at mission start, otherwise you get static enemies
alongside the SPAWNed ones.

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

Implication: round 1 always starts at the ME position. Round N+1 randomises
the **bandit's** position (visible) but the **player's** slot stays where
they last died (also visible — they rejoin into the existing slot).

### 6.2 `GROUP:Teleport` on a dead group ignores the new zone

MOOSE's `GROUP:Teleport(coord)` calls `Respawn(nil, false)`. The
`Respawn` source has an `if self:IsAlive() then … end` guard around the
position-update logic — when the group is dead, the guard fails and the
new group is spawned at the **ME template position**, not at `coord`.
Symptom: a "ghost" blue group at the original airbase plus the intended
new group at the target position. The current `handlePlayerDeath` does
*not* call `Teleport` for this reason — it only respawns the bandit.
The player rejoins into the existing (death-position) slot.

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
-- (1–30 s of init poll retries; the very last batch should be: )
[duel-dynamic] init: world not ready, retrying...
[duel-dynamic] Aerial-1 heading randomized to 080 (pos kept at ME)
[duel-dynamic] Aerial-1 already occupied at init — spawning paired bandit now
[duel-dynamic] spawning Bandit-1 59.5 nm from Aerial-1
[duel-dynamic] tasked Bandit-1#001 → INTERCEPT on Aerial-1 (ROE=WEAPON_FREE, ROT=EVADE_FIRE, alarm=RED)
[duel-dynamic] init done — player-enter events will now spawn bandits
[duel-dynamic] Bandit-1 spawned: Bandit-1#001 at x=-141498 z=165369 alt=4569m
```

Then after the kill:

```
[duel-dynamic] Bandit-1 killed — respawn scheduled in 30s after Bandit-1#001
-- 30 s later:
[duel-dynamic] spawning Bandit-1 58.3 nm from Aerial-1
[duel-dynamic] Bandit-1 spawned: Bandit-1#002 at …
```

If a bandit does not appear within INIT_TIMEOUT (30 s), check that all
three bandit groups are present in the ME and Late Activation is ✓. The
first `SCRIPTING ERROR` line names the file and line.

---

## 8. Testing the count-matching (1 / 2 / 3 players)

- **1 player** in `Aerial-1`: only `Bandit-1` spawns.
- **2 players** in `Aerial-1` and `Aerial-2`: `Bandit-1` and `Bandit-2` both
  spawn, each 60+ mi from their respective player.
- **3 players**: all three bandits.
- **Player in `Aerial-1` then `Aerial-2`**: leaving `Aerial-1` despawns
  `Bandit-1`; entering `Aerial-2` spawns `Bandit-2`.

To test mid-mission, use the WebGUI "force slot" / "kick to slot"
controls, or have the player eject and switch slots in the in-mission
slot selector.

---

## 9. Verifying AI behaviour in Tacview

Recommended. Records spawn positions/timing, routes, weapon events. The
Caucasus missions generate ~1 MB of `.acmi` per minute.

- **Default location:** `%USERPROFILE%\Documents\Tacview\`
- **Dedicated server:** enable via `Saved Games\DCS.server\Config\options.lua`
  → `["Tacview"]` block (see `dev-setup.md §7.5`).
- **What to look for:** the bandit should be 60+ sm from the player at
  spawn, then turn toward the player and close. Heading should change
  between rounds. The player slot should stay at the death position
  across rounds (see §6.1).

---

## 10. Superseded mission: duel-1v1

`src/missions/duel-1v1/` is the original 1-vs-1 test mission. It still
exists in the repo for reference, but it is **incomplete** — see
`docs/PROJECT-STATUS.md` §3. Don't switch back to it without first
finishing the cleanup; the spec at `docs/spec-duel-1v1.md` describes
the old single-bandit design.

`duel-dynamic` is the mission that's actively developed and tested.

# Test-Combat Block — Option A Implementation Plan

Status: **implemented + live-verified (2026-09-02)** — `run-20260902T181007Z-7b3ea067`
Decided: 2026-09-02
Supersedes: the A/B question in `docs/telemetry/unattended-test-loop.md` §Ordnance.

## Final design (implemented + live-verified; supersedes everything below)

Supersedes the `createGroupOnMap` and `_DATABASE:Spawn(Aerial-1 copy)`
approaches. The first live run showed `Aerial-1..4` are **player/client slots**
(`skill = "Player"`/`"Client"` in the ME) and DCS refuses to materialize a
client group via `coalition.addGroup` (it raises a table error). The 4
`skill = "Excellent"` groups are the spawnable AI bandits. The final design
builds the blue AI from the **spawnable `Bandit-1` template** and recolors it
blue:

- **Blue AI source**:
  `SPAWN:NewFromTemplate(_DATABASE.Templates.Groups["Bandit-1"].Template,
  "TestCombat-Blue")` — reuses the spawnable AI F/A-18C (real A/A weapons:
  AIM-120C, AIM-9) — recolors it blue with `InitCoalition(coalition.side.BLUE)`
  + `InitCountry(blueCountryID)` + `InitGrouping(1)`. The custom
  `TestCombat-Blue` prefix keeps the name distinct from the real bandit (no
  `Bandit-1#NNN` collision); `_Prepare` reassigns the STN (no datalink clash).
- **Blue country id**: `coalition.addGroup`'s first arg is the **country id**
  (not the side) — in this mission blue = `80` (CJTF Blue), red = `81`
  (CJTF Red). `blueCountryID` is read from the Aerial-1 template's `CountryID`
  rather than hardcoded.
- **Blue reference coordinate**: the Aerial-1 ME slot position
  (`aerialTemplate.x`/`.y`, `SPAWN_ALTITUDE_M`) — always available unattended.
  The blue AI spawns there, headed toward the bandit.
- **Bandit wave**: the existing `waveSpawner` (Bandit-1 template), 1 ship, at
  **15 nm** from the blue (not 60+ nm, so the two merge and launch within the
  hook's 400 s auto-stop budget), headed toward the blue.
- **Both sides carry A/A weapons** (both F/A-18C with AIM-120C + AIM-9) →
  guaranteed missile launches.
- **Accepted `ordnance.fired` initiator**: the telemetry roster accepts
  `Aerial-1..4` (player) and `Bandit-*#NNN` (bandit). The blue AI is
  `TestCombat-Blue#NNN` (not in the roster), so the **bandit's** shot is the
  captured `ordnance.fired` (≥1 is enough).
- **Packager also reverts the init-bypass line** (see Files to modify §3c).

Everything else (gate flag, SCHEDULER self-arm, INTERCEPT tasking, ROE/alarm,
wave-state updates, acceptance criteria) is unchanged from the original plan.

**Live-verified** (`run-20260902T181007Z-7b3ea067`): blue AI
(`TestCombat-Blue#001`) + bandit wave (`Bandit-1#001`) spawned, both tasked
INTERCEPT, both fired AIM-120C at t≈14 s, mutual kills at t≈45 s.
`ordnance.fired` captured at sequence 2 (initiator `Bandit-1#001-01`, weapon
`AIM_120C`, known location/time); sequence gapless `1 → 16` through
`mission.ended`; collector spooled it with `duplicates: 0`.

## Original design (superseded — kept for history)

## Objective

Add a dev-gated test-combat block to `duel-dynamic` that, on an unattended
dedicated server (no player, no WebGUI), spawns a blue AI fighter and a bandit
wave, tasks them against each other, and produces valid `ordnance.fired`
telemetry events. This closes the ordnance-evidence gap identified in Slice 6.

## Design (final)

- **Gate**: `_G.TEST_COMBAT_ENABLED` — set by the dev bootstrap or a temporary
  hook. Never set in the shipping build (same pattern as
  `_G.TELEMETRY_DEVELOPMENT_ENABLED`).
- **Trigger**: a SCHEDULER that self-arms at T+N after `initDone` becomes
  true. No F10 click needed (unattended = no one to click).
- **Blue AI**: spawned via `trigger.action.outland.createGroupOnMap` (1×
  F/A-18C Hornet) near the Aerial-1 ME slot. No new ME template needed —
  fully self-contained in `main.lua`.
- **Bandit wave**: uses the existing `waveSpawner` (Bandit-1 ME template,
  already initialised by `doInit`). Spawns 1-ship package at 60+ nm from the
  blue AI.
- **Tasking**: `AUFTRAG:NewINTERCEPT(blueAiGroup)` on the bandit (not CAP —
  CAP orbits and may not guarantee weapons engagement). The blue AI gets a
  matching INTERCEPT on the bandit group so both sides actively pursue.
  ROE: `OpenFireWeaponFree` + alarm `Red` on both sides.
- **Init bypass**: when `_G.TEST_COMBAT_ENABLED` is true, the init SCHEDULER
  skips the `anyPlayerGroupAlive()` wait and runs `doInit` immediately after
  `INIT_DELAY`. `doInit` is safe without players: the catch-pass finds no
  occupied slots (harmless), and `scheduleWave` fails gracefully (no
  occupied slots → no wave).
- **Kill / respawn**: the existing bandit-kill handler works unchanged — when
  the blue AI kills the bandit, `currentWaveAlive` reaches 0 and
  `scheduleWave(RESPAWN_DELAY, ...)` fires. However, `scheduleWave` calls
  `spawnWave` which checks `livePlayerPackage()` → will find no occupied
  slots → no respawn. This is acceptable for a single engagement; the test
  only needs ≥1 valid `ordnance.fired` event. (If multiple waves are needed
  later, the test-combat block can re-arm its own SCHEDULER.)

## Files to modify

### 1. `src/missions/duel-dynamic/main.lua`

**a) Init SCHEDULER bypass** (line ~691):

Current:
```lua
SCHEDULER:New(nil, function()
  if initDone then
    return false
  end
  if not anyPlayerGroupAlive() then
    env.info("[duel-dynamic] init: no player group alive yet, retrying...")
    return nil -- keep polling
  end
  doInit()
  return false
end, {}, INIT_DELAY, INIT_POLL_INTERVAL, 0, INIT_TIMEOUT)
```

Change the wait condition to also skip when test-combat is enabled:
```lua
  if not anyPlayerGroupAlive() and not _G.TEST_COMBAT_ENABLED then
```

**b) Test-combat block** — add after the init SCHEDULER (before the final
`env.info("[duel-dynamic] main done ...")` line), gated by
`_G.TEST_COMBAT_ENABLED`:

```lua
-- =====================================================================
-- Dev-only: unattended test combat (ordnance evidence).
-- Gated by _G.TEST_COMBAT_ENABLED (set by bootstrap or a dev hook).
-- Never set in the shipping build; the packager strips this block and
-- asserts no TEST_COMBAT strings survive.
-- =====================================================================
if _G.TEST_COMBAT_ENABLED then
  SCHEDULER:New(nil, function()
    if not initDone then
      return nil -- wait for doInit (skips the player-wait when TEST_COMBAT)
    end
    -- 1. Spawn a blue AI fighter by reusing the Aerial-1 ME template.
    --    Aerial-1 is a blue F/A-18C with real A/A weapons (AIM-120C, AIM-9).
    --    Deep-copy the template, rename it + its unit, and materialize it via
    --    the same mechanism MOOSE's SPAWN uses (_DATABASE:Spawn ->
    --    coalition.addGroup). The original Aerial-1 player slot is untouched.
    local template = _DATABASE
      and _DATABASE.Templates
      and _DATABASE.Templates.Groups
      and _DATABASE.Templates.Groups["Aerial-1"]
      and _DATABASE.Templates.Groups["Aerial-1"].Template
    if not template then
      env.error("[duel-dynamic][test-combat] Aerial-1 template not found in _DATABASE")
      return false
    end
    local copy = UTILS.DeepCopy(template)
    copy.name = "TestCombat-Blue"
    copy.lateActivation = false
    if copy.units and copy.units[1] then
      copy.units[1].name = "TestCombat-Blue-1"
    end
    local blueGrp
    local okSpawn, spawnErr = pcall(function()
      return _DATABASE:Spawn(copy)
    end)
    if not okSpawn or not blueGrp then
      env.error("[duel-dynamic][test-combat] failed to spawn blue AI: " .. tostring(spawnErr))
      return false
    end
    env.info("[duel-dynamic][test-combat] blue AI spawned: " .. blueGrp:GetName())

    -- 2. Spawn a 1-ship bandit wave 60+ nm from the blue AI. Use the
    --    template's stored position as the reference (the Aerial-1 slot may
    --    not be alive unattended, so GROUP:FindByName("Aerial-1") is
    --    unreliable here).
    local blueSpawnAlt = (copy.route and copy.route.points[1] and copy.route.points[1].alt) or SPAWN_ALTITUDE_M
    local blueRefCoord = COORDINATE:New(copy.x, blueSpawnAlt, copy.y)
    local banditCoord, bearing = randomOffsetCoord(blueRefCoord, RANDOM_DIST_MIN_M, RANDOM_DIST_MAX_M)
    local heading = (bearing + 180) % 360
    waveSpawner:InitGrouping(1)
    waveSpawner:InitSetUnitRelativePositions(formationPositions(1, heading))
    waveSpawner:InitHeading(heading)
    local banditGrp = waveSpawner:SpawnFromCoordinate(banditCoord)
    if not banditGrp then
      env.error("[duel-dynamic][test-combat] failed to spawn bandit wave")
      return false
    end
    waveNumber = waveNumber + 1
    currentWaveGroup = banditGrp
    currentWaveGroupName = banditGrp:GetName()
    currentWaveAlive = 1
    env.info(string.format("[duel-dynamic][test-combat] bandit wave %d spawned at %s", waveNumber, coordStr(banditCoord)))

    -- 3. Task both sides: INTERCEPT + WEAPON_FREE + RED alarm.
    local function taskIntercept(grp, targetGrp, label)
      if not grp or not targetGrp then return end
      pcall(function() grp:OptionROEOpenFireWeaponFree() end)
      pcall(function() grp:OptionAlarmStateRed() end)
      local fg = FLIGHTGROUP:New(grp)
      local mission = AUFTRAG:NewINTERCEPT(targetGrp)
      mission.optionROE = ENUMS.ROE.OpenFireWeaponFree
      mission.optionAlarm = ENUMS.AlarmState.Red
      fg:AddMission(mission)
      env.info(string.format("[duel-dynamic][test-combat] %s tasked INTERCEPT -> %s", label, targetGrp:GetName()))
    end
    taskIntercept(banditGrp, blueGrp, "bandit")
    taskIntercept(blueGrp, banditGrp, "blue AI")

    -- 4. Stop the SCHEDULER (one-shot).
    return false
  end, {}, 5, 1) -- wait for initDone, poll every 1 s
end
-- <<TEST_COMBAT_BLOCK_END>>
```

The block is delimited by a header comment (the `-- ====` line followed by
`-- Dev-only unattended test combat`) and the `-- <<TEST_COMBAT_BLOCK_END>>`
marker so the packager can strip it unambiguously (see Files to modify §3).

Notes on the code above:
- The blue AI is spawned via `_DATABASE:Spawn(copy)` — the same mechanism
  MOOSE's `SPAWN` class uses internally (`coalition.addGroup`). `copy` is a
  deep copy of the Aerial-1 ME template, so it carries the real F/A-18C with
  AIM-120C ×4 + AIM-9 ×2. `UTILS.DeepCopy` is the static MOOSE helper
  (dot-call). `lateActivation = false` ensures the group actually materializes
  (the Aerial-1 template itself is a player slot; we want our copy to be a
  normal active group).
- The unit is renamed to `TestCombat-Blue-1` to avoid a name collision with
  the live Aerial-1-1 unit (Aerial-1 may be an active group even unattended).
- The reference coordinate comes from the template's stored position
  (`copy.x`, `copy.y`, `copy.route.points[1].alt`), NOT from
  `GROUP:FindByName("Aerial-1"):GetCoordinate()` (unreliable unattended).
  `COORDINATE:New(x, y, z)` takes (mapX, altitude, mapZ) — the mission file's
  `x`/`y` map to COORDINATE's `x`/`z`, with altitude as the middle arg
  (see `coordStr` which treats `coord.y` as altitude).
- `formationPositions(1, heading)` returns a single-element table (the loop at
  line 276 only runs for `i >= 2`). This is correct for a 1-ship package.
- The blue AI and bandit are both F/A-18C with identical A/A weapons, so both
  sides will launch missiles → valid `ordnance.fired` events.

### 2. `src/bootstrap.lua`

Add `_G.TEST_COMBAT_ENABLED = true` next to the existing
`_G.TELEMETRY_DEVELOPMENT_ENABLED = true` (line 34). This enables test
combat in all dev runs. To disable for a specific dev run, comment it out.

### 3. `build/pack-shipping-miz.ps1`

**a) Strip the test-combat block** — add a regex strip after the existing
telemetry/score strips (around line 313, before the `os.time()` replacement):

```powershell
# Strip the dev-only test-combat block (gated by _G.TEST_COMBAT_ENABLED).
# Anchored on the section header (the "-- ====" line followed by the
# "Dev-only unattended test combat" line) through the unique end marker.
$testCombatPattern = '(?ms)^-- =+\r?\n-- Dev-only unattended test combat[\s\S]*?^-- <<TEST_COMBAT_BLOCK_END>>\r?\n'
$devMainText = [regex]::Replace($devMainText, $testCombatPattern, '')
```

**b) Revert the init-bypass line.** The dev main.lua changes the init wait to
`if not anyPlayerGroupAlive() and not _G.TEST_COMBAT_ENABLED then`. Remove the
dev-only clause so shipping keeps the original player-wait:

```powershell
# Revert the dev-only init bypass (shipping must keep the player wait).
$devMainText = $devMainText -replace ' and not _G\.TEST_COMBAT_ENABLED', ''
```

**c) Add `TEST_COMBAT` to the banned-patterns assertion** (line ~323):

```powershell
$banned = @('TraceOn', 'TraceLevel', 'os\.', 'io\.open', 'lfs\.', 'TEST_COMBAT')
```

This ensures the build fails if any `TEST_COMBAT` string survives the strip +
revert in a non-comment line. (Both the block and the init-bypass line
contain `TEST_COMBAT`, so both are covered by this assertion.)

## Acceptance criteria

1. **Unattended live run** (dedicated server, no player, de-sanitized
   `MissionScripting.lua`):
   - `dcs.log` shows: `test-combat] blue AI spawned`, `test-combat] bandit
     wave 1 spawned`, `test-combat] bandit tasked INTERCEPT`, `test-combat]
     blue AI tasked INTERCEPT`.
   - `dcs.log` shows at least one `ordnance.fired` telemetry event (grep
     the telemetry NDJSON file).
   - Telemetry sequence is gapless from 1 through `mission.ended`.
   - Collector two-pass: pass 2 spools 0, duplicates 0.
2. **Shipping build**:
   - `build/pack-shipping-miz.ps1` completes without error.
   - The shipping `main.lua` in `out/duel-dynamic-build/` contains no
     `TEST_COMBAT` string (grep).
   - The banned-patterns assertion passes (i.e., the strip worked).
3. **Dev run with test-combat disabled** (comment out
   `_G.TEST_COMBAT_ENABLED` in bootstrap): mission behaves exactly as before
   (no blue AI, no bandit wave until a player joins).

## Out of scope (for now)

- Multiple waves / respawn loop for test combat (single engagement is
  sufficient for ordnance evidence).
- F10 menu command to toggle test combat (the SCHEDULER self-arming is the
  unattended path; F10 would be an interactive convenience, not needed).
- CAP tasking for the bandit in test-combat mode (INTERCEPT is used for
  guaranteed engagement).

## Verification steps (after implementation)

1. `luacheck src/missions/duel-dynamic/main.lua` — no new warnings.
2. `npm --prefix collector run check` — still green (no changes expected).
3. Run the packager: `powershell -File build/pack-shipping-miz.ps1` — verify
   it completes and the shipping `main.lua` has no `TEST_COMBAT`.
4. Unattended live run per `docs/telemetry/unattended-test-loop.md`:
   - De-sanitize `MissionScripting.lua` (server).
   - Start `DCS_server.exe`.
   - Load the dev `.miz` via `net.load_mission` hook.
   - `Sim.setPause(false)` to resume model time.
   - Wait ~120 s, collect telemetry NDJSON.
   - Grep for `ordnance.fired` — expect ≥1.
   - Run collector two-pass — expect duplicates: 0.
   - Restore `MissionScripting.lua` to stock, stop server.
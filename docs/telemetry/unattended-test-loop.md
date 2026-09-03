# Unattended live-test loop (no player, no WebGUI)

**Validated:** 2026-09-02 (Slice 6 live tail, see
`slice-6-collector-evidence.md`).

Runs a full mission + telemetry pass on the dedicated server with **zero
human input**: no client connects, no WebGUI click, no in-game action. The
whole loop is driven by a temporary server hook plus collector CLI passes.

## What this proves / when to use it

- Mission lifecycle telemetry unattended: `mission.started`, heartbeats,
  clean `mission.ended`.
- Collector crash/cursor/idempotency behavior against a *live* appending
  producer (the only condition the unit tests cannot reproduce).
- Any mission behavior that needs model time but not a player (AI tasking
  runs, timers, wave assembly) — see "Unattended ordnance testing" below
  for the known gap.

## Environment facts (verified 2026-09-02)

These were discovered the hard way; they shape every step below.

1. **The server auto-loads its last mission-list entry at startup.** The
   WebGUI choice is remembered, so a boot may start the v3 shipping test
   instead of the dev loader. The hook must check and correct this.
2. **Hooks load at process start, before the network comes up.**
   `$WRITE_DIR\Scripts\Hooks\*.lua` run in the server hook environment with
   `DCS.setUserCallbacks` (also `Sim.setUserCallbacks`), `net.*`, `log.*`,
   `lfs.*`. `net.load_mission` is available there (server only).
3. **No player → simulation is `ssPaused`.** Model time does not advance, so
   model-time schedulers (the 30 s telemetry heartbeat, wave timers) never
   fire. `Sim.setPause(false)` resumes model time without any player.
4. **`onSimulationFrame` ticks even while paused**, so a real-time-based
   auto-stop (`Sim.getRealTime`) works in both paused and running states.
5. **The dev mission needs a de-sanitized `MissionScripting.lua` in the
   server install** (`io` is required by the dev bootstrap/telemetry sink).
   The 13:04 UTC run on 2026-09-02 failed exactly this: `[bootstrap]:
   attempt to index global 'io' (a nil value)` with the stock file in place.
6. **Mission start event fires from the MISSION START trigger**, not from a
   player join; the dev loader's `loadfile` bootstrap runs without anyone
   connected.

## Procedure

### 1. De-sanitize the server install (dev window opens)

```powershell
# stock file stays as the restore source
Copy-Item "D:\DCS World Server\Scripts\MissionScripting.lua.telemetry-dev-backup" `
  "D:\DCS World Server\Scripts\MissionScripting.lua" -Force
# verify: the three sanitizeModule lines are commented out
```

(If no `.telemetry-dev-backup` exists, create it from a stock
`MissionScripting.lua` with the `os`/`io`/`lfs` lines commented out, per
`docs/dev-setup.md` §2. The `.orig` file is the stock backup.)

### 2. Install the temporary hook

Write to
`C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Scripts\Hooks\zz-dev-telemetry-load.lua`
(name prefix `zz-` sorts last so it doesn't disturb the Tacview hook):

```lua
-- TEMPORARY hook for unattended dev-mission runs. REMOVE after the test.
do
	local targetMissionPath = [[C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Missions\duel-dynamic.miz]]
	local targetBaseName = 'duel-dynamic.miz'
	local stopAfterSeconds = 120  -- 0 disables auto-stop (manual teardown)

	local startedAtRealTime = nil
	local stopped = false

	local function logInfo(m) log.write('DEV-TELEMETRY', log.INFO, m) end

	local function controlTable()
		if type(DCS) == 'table' and type(DCS.setUserCallbacks) == 'function' then
			return DCS
		end
		if type(Sim) == 'table' and type(Sim.setUserCallbacks) == 'function' then
			return Sim
		end
		return nil
	end

	local function isTargetMission()
		local ctl = controlTable()
		if ctl == nil or type(ctl.getMissionFilename) ~= 'function' then
			return false
		end
		local ok, filename = pcall(ctl.getMissionFilename)
		if not ok or type(filename) ~= 'string' then
			return false
		end
		local name = filename:match('[/\\]([^/\\]+)$') or filename
		return name:lower() == targetBaseName
	end

	local function realTime()
		local ctl = controlTable()
		if ctl == nil or type(ctl.getRealTime) ~= 'function' then
			return nil
		end
		local ok, v = pcall(ctl.getRealTime)
		return ok and v or nil
	end

	local function loadTargetMission()
		if type(net) ~= 'table' or type(net.load_mission) ~= 'function' then
			logInfo('net.load_mission unavailable')
			return
		end
		local ok, err = pcall(net.load_mission, targetMissionPath)
		logInfo(ok and ('requested dev mission load: ' .. targetMissionPath)
			or ('net.load_mission failed: ' .. tostring(err)))
	end

	local function resumeSimulation()
		local ctl = controlTable()
		if ctl == nil or type(ctl.setPause) ~= 'function' then
			logInfo('setPause unavailable; leaving simulation as-is')
			return
		end
		local ok, err = pcall(ctl.setPause, false)
		logInfo('setPause(false) ok=' .. tostring(ok) .. ' err=' .. tostring(err))
	end

	local function stopMission()
		if stopped then return end
		stopped = true
		local ctl = controlTable()
		if ctl == nil or type(ctl.stopMission) ~= 'function' then
			logInfo('stopMission unavailable')
			return
		end
		local ok, err = pcall(ctl.stopMission)
		logInfo('stopMission called ok=' .. tostring(ok) .. ' err=' .. tostring(err))
	end

	local callbacks = {}

	function callbacks.onMissionLoadEnd()
		if isTargetMission() then
			if startedAtRealTime == nil then
				startedAtRealTime = realTime()
				logInfo('dev mission loaded; auto-stop in ' .. tostring(stopAfterSeconds)
					.. ' s (realTime=' .. tostring(startedAtRealTime) .. ')')
				if stopAfterSeconds > 0 then
					resumeSimulation()
				end
			end
		else
			logInfo('non-dev mission loaded; loading dev mission instead')
			loadTargetMission()
		end
	end

	function callbacks.onSimulationFrame()
		if startedAtRealTime ~= nil and stopAfterSeconds > 0 and not stopped then
			local now = realTime()
			if now ~= nil and now - startedAtRealTime >= stopAfterSeconds then
				stopMission()
			end
		end
	end

	local ctl = controlTable()
	if ctl ~= nil then
		ctl.setUserCallbacks(callbacks)
		logInfo('temporary dev-telemetry hook active')
	else
		logInfo('ERROR: no control table (DCS/Sim) with setUserCallbacks found')
	end
end
```

Notes:

- `stopAfterSeconds` should exceed the mission behavior window you want to
  observe (telemetry heartbeats need 2×30 s; a clean `mission.ended` comes
  from the stop, not from timeout).
- `net.load_mission` overrides the mission list *temporarily* — the
  remembered last-mission entry is unchanged, so the next plain boot still
  loads it.

### 3. (Re)start the server

```powershell
Stop-Process -Name DCS_server -Force
Start-Process "D:\DCS World Server\bin\DCS_server.exe"   # exact original cmdline, no args
```

### 4. Verify the mission came up (wait ~60 s)

```powershell
Get-Content "C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\dcs.log" -Tail 200 `
  | Select-String -Pattern "DEV-TELEMETRY|bootstrap|MOOSE INCLUDE|telemetry\] started"
```

Accept:

- `DEV-TELEMETRY (Main): dev mission loaded; auto-stop in ...`
- `DEV-TELEMETRY (Main): setPause(false) ok=true`
- `*** MOOSE INCLUDE END ***`
- `[duel-dynamic][telemetry] started producer=... run=run-... sequence=1 path=...`

Reject: `[myMission] bootstrap: ... attempt to index global 'io'` →
step 1 was not done; `non-dev mission loaded` never followed by `dev
mission loaded` → `net.load_mission` failed (check the path).

### 5. Collector passes

One state dir for the whole test (cursors survive across separate CLI
processes, which is the point of the test):

```powershell
$state = "C:\Users\g_for\AppData\Local\Temp\opencode\slice6-live-state"
node "collector\dist\src\cli.js" `
  --input "C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry" `
  --state $state
```

| Pass | When | Expect |
|---|---|---|
| A | mission live, shortly after start | historical lines + new run's `mission.started`; `duplicates: 0` |
| B | ~30–60 s later | heartbeats spool as they land (each ≥30 s of model time apart); `duplicates: 0` |
| C | after the auto-stop | `mission.ended` is the run's last sequence; sequence stays gapless from 1 |
| D | immediate repeat | `complete_lines: 0`, `spooled: 0`, `duplicates: 0` — fully quiescent |

Also verify the run table: every run gapless `minimum_sequence: 1` with
`next_deliverable_sequence: 1` (nothing acknowledged yet), and the live run
ending in `mission.ended`.

Optional delivery/ack drill on a **copy** of the state dir (never ack the
evidence copy in place):

```powershell
node -e "const {DurableSpool}=require('C:/Projects/dcs-missions/collector/dist/src/spool.js');const s=new DurableSpool('<copy>/collector.sqlite3');let n=s.nextDeliverable('<pid>','<run>');while(n){console.log(n.event.event_sequence,n.event.event_type);s.acknowledge(n.event.event_id);n=s.nextDeliverable('<pid>','<run>')}s.close()"
```

Accept: first deliverable is `mission.started`, in-order acknowledgements,
`null` after the last sequence, re-ack of sequence 1 → `duplicate`.

### 6. Teardown (always, even on failure)

```powershell
# 1. remove the hook
Remove-Item "C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Scripts\Hooks\zz-dev-telemetry-load.lua" -Force
# 2. stop the server
Stop-Process -Name DCS_server -Force
# 3. restore stock MissionScripting.lua and verify by hash
Copy-Item "D:\DCS World Server\Scripts\MissionScripting.lua.orig" "D:\DCS World Server\Scripts\MissionScripting.lua" -Force
(Compare-Object (Get-FileHash "D:\DCS World Server\Scripts\MissionScripting.lua").Hash (Get-FileHash "D:\DCS World Server\Scripts\MissionScripting.lua.orig").Hash)
# 4. remove the state dir if the run is not needed as evidence
```

## Unattended ordnance testing (implemented + verified)

Goal: produce `ordnance.fired` events with no human, so Slice 5-style
capture checks (and later Slice 8 end-to-end) can run unattended.

**Status:** implemented and verified 2026-09-02 in
`run-20260902T181007Z-7b3ea067`. An empty dedicated server spawned a blue AI
+ a bandit wave that fought and produced a captured `ordnance.fired`
(sequence 2: initiator `Bandit-1#001-01`, weapon `AIM_120C`), with a gapless
sequence `1 → 16` ending in `mission.ended` and `duplicates: 0`.

**The real blocker** (corrects the earlier hypothesis): it was *not*
`occupiedPlayerSlots`. `Aerial-1..4` are **player/client slots**
(`skill = "Player"` / `"Client"` in the ME), and DCS refuses to materialize
a client group via `coalition.addGroup` — cloning the blue ME template and
calling `_DATABASE:Spawn` raises a table error. The 4 `skill = "Excellent"`
groups are the spawnable AI bandits. So the blue AI is built from the
**spawnable `Bandit-1` AI template** (an F/A-18C with real A/A weapons:
AIM-120C, AIM-9) and **recolored to blue**, not from the blue ME template.

**How it works** (the implemented design, in `main.lua`):

1. `_G.TEST_COMBAT_ENABLED` gate (set by `bootstrap.lua`; never set in
   shipping; the packager strips it). Same pattern as
   `_G.TELEMETRY_DEVELOPMENT_ENABLED`.
2. The init `SCHEDULER` skips the `anyPlayerGroupAlive()` wait when the flag
   is set, so `doInit` runs unattended (the shipping build keeps the wait —
   the packager reverts that clause).
3. A dev-only one-shot `SCHEDULER` at T+5 s (polling every 1 s until
   `initDone`) that:
   - Spawns the **blue AI** from the `Bandit-1` template via the proven
     MOOSE path: `SPAWN:NewFromTemplate(blueTemplate, "TestCombat-Blue")`
     + `InitCoalition(coalition.side.BLUE)` +
     `InitCountry(<blue country id>)` + `InitGrouping(1)`, positioned at the
     Aerial-1 slot location and headed toward the bandit. The custom
     `TestCombat-Blue` prefix keeps its name distinct from the real bandit
     (no `Bandit-1#NNN` collision); `_Prepare` reassigns the STN so there is
     no datalink clash.
   - Spawns a **1-ship bandit wave** 15 nm away via the existing
     `waveSpawner` (`SPAWN:New("Bandit-1")`), headed toward the blue.
   - Tasks **both** `INTERCEPT` + `WEAPON_FREE` + RED alarm.

**Why the bandit is the accepted initiator:** the telemetry roster accepts
`Aerial-1..4` (player) or `Bandit-*#NNN` (bandit). The blue AI is named
`TestCombat-Blue#NNN` (not in the roster), so only the **bandit's** shots
are captured as `ordnance.fired`. That is fine — the acceptance bar is
≥1, and the bandit reliably fires (it is the `Bandit-1#001` the normal wave
pipeline already tracks).

**Key gotchas discovered:**

- `Aerial-1..4` are client slots → cannot be spawned via `addGroup`. Build
  the blue AI from the `Bandit-1` template and flip the coalition.
- `coalition.addGroup`'s first argument is the **country ID**, not the side:
  in this mission blue = `80` (CJTF Blue), red = `81` (CJTF Red). The blue
  country id is read from the Aerial-1 template's `CountryID` rather than
  hardcoded.
- 15 nm is short enough to merge + launch within the hook's 400 s auto-stop
  budget; the normal 60+ nm wave distance would take many minutes.

**How it triggers unattended (the key design point, confirmed):** not an
F10 command (no one clicks in unattended mode). Mission-internal
`SCHEDULER`s fire once model time runs — proven by the 30 s telemetry
heartbeat firing with zero players because the hook's `setPause(false)`
resumes model time. The test-combat `SCHEDULER` self-arms at T+5 s under the
dev flag. The hook does exactly what it already does (load the mission,
`setPause(false)`, stop after the budget) — no new hook capability and no
`net.dostring_in`/`a_do_script` bridge (obsolete/unsafe with version-specific
return-value bugs per AGENTS.md).

**Kept out of the shipping build:** the block is delimited by a header and a
`-- <<TEST_COMBAT_BLOCK_END>>` marker. `build\pack-shipping-miz.ps1` strips
the whole block, reverts the init `SCHEDULER`'s player-wait clause, strips
the `-- [TEST_COMBAT]` comment line, and asserts no `TEST_COMBAT` string
survives in the synthesized shipping `main.lua`.

**Acceptance criteria (unattended ordnance run) — all met 2026-09-02:**

- No player connected; mission + telemetry start via the hook, and the test
  combat starts on its own from the mission-internal `SCHEDULER` at T+N
  (no F10, no WebGUI, no `dostring_in`).
- ≥1 `ordnance.fired` event from an accepted initiator with a valid envelope
  (distinct `event_id`, gapless sequence, correct weapon) — captured at
  sequence 2 (`Bandit-1#001-01`, `AIM_120C`).
- Collector pass spools it with `duplicates: 0`; sequence stays gapless
  through the whole run including `mission.ended` (1 → 16).

## Deterministic single-shot loadout + weapon-identity verification (2026-09-03)

Goal: make the unattended ordnance count **assertable** (exactly one
`ordnance.fired` per run) and verify **which weapon** the bandit actually
fires, so a fixed loadout can be pinned per run (AIM-120C vs AIM-9X).

**Status:** implemented and verified 2026-09-03. Both weapons produce
exactly one `ordnance.fired` with the correct `weapon_dcs_type`.

### Design (in the dev-only test-combat block of `main.lua`)

- `TEST_COMBAT_MISSILE` knob (`"AIM-120C"` or `"AIM-9X"`), flipped per run.
- `testCombatPayload()` builds a mission-file-shaped payload: exactly ONE
  AAM pylon, `gun = 0` (the M61 is removed so the bandit cannot add gun
  shots), fuel/flare/chaff/ammo_type preserved.
- `setTemplatePayload()` overwrites `units[n].payload` on the spawner's
  template copy. The bandit gets one AAM + no gun; the blue target gets no
  weapons at all (it cannot kill the bandit, so the bandit is always the
  accepted initiator).
- With one AAM and no gun, a successful engagement yields **exactly one**
  `ordnance.fired` event, so the count is assertable and the weapon
  identity is the loadout.

### Root cause of the earlier "AIM-9X fired an AIM-120C" bug

The first AIM-9X run still reported `weapon=AIM_120C`. The payload was
correct (the AIM-9X CLSID `{5CE2FF2A-645A-4197-B48D-8720AC69394F}` is
confirmed in `CoreMods\aircraft\AircraftWeaponPack\aim9_family.lua`, and
`MDRN_M_A_AIM9` is only a visual GUI preset), so the problem was that the
payload **was never applied to the spawned bandit**:

- The bandit is spawned by `waveSpawner = SPAWN:New("Bandit-1")`, which sets
  `TweakedTemplate = false` (`Core/Spawn.lua`, `SPAWN:New`).
- In `SPAWN:_Prepare`, when `TweakedTemplate` is **not** true, MOOSE
  re-fetches a fresh deep copy of the template via
  `self:_GetTemplate(prefix)` (from the shared `_DATABASE`) and **ignores
  the spawner's own `SpawnTemplate`** — so the `units[n].payload` overwrite
  was silently discarded and the bandit flew the default loadout
  (4×AIM-120C + 2×AIM-9X + gun). The AI's first BVR launch is an AIM-120C,
  so both runs captured `AIM_120C`.
- The blue spawner used `SPAWN:NewFromTemplate`, which sets
  `TweakedTemplate = true`, so its "no weapons" override *was* applied —
  consistent with the blue never firing back.

**Fix:** set `waveSpawner.TweakedTemplate = true` inside the dev-only block
before applying the payload. That routes `_Prepare` to the "tweaked
template" branch, which uses the spawner's own (overwritten)
`SpawnTemplate` and hands it to `coalition.addGroup` via `DATABASE:Spawn`
(no extra copy). This is MOOSE's documented "user made template" path.

**Naming side effect (benign here):** the tweaked branch names the group via
`SpawnGroupName()` (no index) when `MooseNameing` is nil (the case for
`SPAWN:New`), so the bandit loses the `#NNN` suffix — unit `Bandit-1-01`
instead of `Bandit-1#001-01`. This does not affect the telemetry roster
(exact `Bandit-1` still matches via `group_name == configured_name`, so the
initiator stays `known`) and does not affect the count/weapon assertion. It
is benign because the block is dev-only (stripped for shipping) and the
unattended flow spawns a single bandit wave — but do **not** reuse
`TweakedTemplate = true` on a shared spawner for multi-wave spawns, where
every wave would be named `Bandit-1` and collide.

### Evidence (2026-09-03)

| run | missile knob | ordnance.fired | weapon_dcs_type | seq | sequence | ended |
|---|---|---|---|---|---|---|
| `run-20260903T033512Z-21af9d3f` | AIM-120C | 1 | `AIM_120C` | 4 | 1→16 gapless | `mission.ended` |
| `run-20260903T040817Z-745fc0db` | AIM-9X | 1 | `AIM_9X` | 4 | 1→16 gapless | `mission.ended` |

Both runs: no player, started + auto-stopped by the temporary hook,
`duplicates: 0` in the collector, red bandit initiator, `weapon_status=known`.
Log line `fixed loadout: bandit 1x<missile> gun=0, blue no weapons` present.
NDJSON ground truth in
`Saved Games\DCS.dcs_serverrelease\Logs\telemetry\`.

### Web ingest + Neon verification (Slice 7, same runs)

`web/scripts/dev-ingest-run.mjs` ingests each run's NDJSON into the local web
app's `POST /api/telemetry/ingest` (Bearer token, `telemetry_batch_v1`
batches ≤100, one producer+run, contiguous sequence). Verified against the
live Neon env:

- First pass: both runs `accepted=16` (32 total).
- Second pass (idempotency): both runs `duplicate=16` (32 total), no errors.
- `mission_runs`: both `status=ended`, `event_count=16`, seq 1–16.
- `telemetry_events`: exactly one `ordnance.fired` per run with the correct
  `weapon_dcs_type` (`AIM_120C`, `AIM_9X`).

**Auth gotcha (fixed):** the `TELEMETRY_INGEST_TOKEN` in `web/.env.local`
contains a `#`. Next's dotenv parser treats an unquoted `#` as the start of
an inline comment, so the server loaded only the 20 chars before the `#`
while the ingest script read the full 48-char value → `401 unauthorized`.
Fix: **wrap the token in double quotes** in `.env.local` (quoted values are
not subject to inline-comment truncation). No token rotation was needed.
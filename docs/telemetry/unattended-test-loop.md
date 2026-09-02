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

## Unattended ordnance testing (known gap + design)

Goal: produce `ordnance.fired` events with no human, so Slice 5-style
capture checks (and later Slice 8 end-to-end) can run unattended.

**Why it does not work today** (verified in `main.lua` on 2026-09-02):

- `ordnance.fired` capture accepts initiators from the `Aerial-1..4`
  player roster or `Bandit-*#NNN` SPAWN groups. AI-vs-AI shots would be
  captured **if** the groups are right.
- But bandit waves only spawn after a **human** `EVENTS.PlayerEnterUnit`
  marks a slot occupied (`occupiedPlayerSlots`), and `spawnWave` refuses to
  run without an occupied, alive player group. A blue AI parked in
  `Aerial-1` makes the group *alive* (so deferred init completes) but never
  marks the slot *occupied*, so no wave spawns and nothing fights.
- Even with a wave, the default bandit tasking is CAP around the blue
  centroid; CAP does not guarantee a weapons engagement.

**What a "test combat" path needs:**

1. A dev-only blue AI aircraft with air-to-air weapons and an engage/Fight
   tasking (or a dedicated blue test group, if we keep it out of the
   player slot).
2. A way for the wave logic to accept it (mark the slot occupied, or a
   separate test spawn path that bypasses the player-join requirement).
3. Bandit tasking switched to INTERCEPT/attack on the blue group so a
   weapons engagement actually happens (CAP is insufficient).
4. A dev-only gate **and** a shipping-packager strip:
   `build\pack-shipping-miz.ps1` synthesizes the shipping `main.lua` by
   stripping dev blocks; anything test-combat must be added to that strip
   list so end users never see the test command/AI.

**How it triggers unattended (the key design point):** not an F10 command
(an F10 command needs a click, and unattended mode has no one to click).
Mission-internal `SCHEDULER`s fire unattended once model time runs — this is
already proven: the 30 s telemetry heartbeat fired in
`run-20260902T172154Z-3169883c` with zero players, purely because the hook's
`setPause(false)` resumed model time. So the trigger is a dev-gated
`SCHEDULER:New(...)` in `main.lua` that calls a dev-only `startTestCombat()`
at T+N model-time seconds when a dev flag is set (same gate pattern as
`_G.TELEMETRY_DEVELOPMENT_ENABLED` set by `bootstrap.lua`; the shipping
`main.lua` never runs with the flag). The hook then does exactly what it
already does: load the mission, `setPause(false)`, stop after the budget —
no new hook capability and no `net.dostring_in`/`a_do_script` bridge (that
path is obsolete/unsafe with version-specific return-value bugs per
AGENTS.md).

**Design options (decision needed before implementation):**

- **A. Dev-gated test-combat block in `duel-dynamic`**: a
  `_G.TEST_COMBAT_ENABLED`-guarded block that (1) spawns a blue AI aircraft
  with air-to-air weapons and an engage tasking, (2) sets
  `occupiedPlayerSlots[idx] = true` directly (bypassing the human
  `PlayerEnterUnit` requirement — the actual blocker), and (3) spawns one
  INTERCEPT-tasked wave; armed automatically by the `SCHEDULER` at T+N.
  An F10 command calling the same `startTestCombat()` is an *optional
  interactive* convenience only — it is not the unattended path. Pros: one
  mission, exercises the real wave pipeline end to end. Cons: touches
  shipping-mission code; packager must strip the whole block; AI death can
  interact with player-death/respawn logic and needs checking.
- **B. Separate test mission** (e.g. `ordnance-test`): blue AI group +
  red bandits with a dedicated shot-capture roster; `.current-mission`
  switched for the test. Same scheduler self-arming pattern, no shipping
  risk. Cons: a second mission to maintain; less end-to-end (bypasses the
  wave pipeline).

**Open questions to verify in whichever option is chosen:**

- Does AI-vs-AI air combat reliably produce shots in this theatre (AI
  weapons employment, engagement ranges, time to first shot)?
- Time bound: the hook auto-stop caps the run; an unattended dogfight can
  run many minutes before the first shot. Budget for it or task both sides
  tightly (INTERCEPT on a fixed corridor).
- Does a blue AI death trigger any player-death/respawn behavior that
  mutates mission state we don't want in the evidence?
- Wave size counting: if the test aircraft counts as a "player", waves
  spawn at size 1 — fine, but verify `InitGrouping(1)` + INTERCEPT on it.

**Acceptance criteria (unattended ordnance run):**

- No player connected; mission + telemetry start via the hook, and the
  test combat starts on its own from the mission-internal `SCHEDULER` at
  T+N (no F10, no WebGUI, no `dostring_in`).
- ≥1 `ordnance.fired` event from an accepted initiator with a valid
  envelope (distinct `event_id`s, gapless sequences, correct weapon).
- Collector pass spools them with `duplicates: 0`; sequence stays gapless
  through the whole run including `mission.ended`.
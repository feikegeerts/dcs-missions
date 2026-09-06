# Slice 13 live loss-capture evidence (S13-live)

**Validated:** 2026-09-05
**DCS:** 2.9.29.27278 dedicated server (`D:\DCS World Server\bin\DCS_server.exe`)
**Mission:** `duel-dynamic` (dev loader, dynamic-from-disk bootstrap)
**Source:** `C:\Projects\dcs-missions\src\` main worktree,
`HEAD = origin/main = main = 36f8252` (untracked deliverables from
S13-p1/S13-p2 present; no commits made by this item)
**Run key:** `run-20260905T205019Z-24cb9efc` (producer
`dcs-dev-68eb93a7`)
**NDJSON:** `C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry\run-20260905T205019Z-24cb9efc.ndjson`

## Result

The live, unattended, AI-vs-AI run captured a **real AIM-120C missile kill**
and the mission emitted **exactly one `asset.dead`** for the victim's tracked
incarnation, then retired it. Core acceptance met:

- One `asset.dead` for `testcombat-blue-001.u1.g1` (the killed blue AI),
  correct `asset_key` (generation `g1`), `source=moose-mission`, known
  location, no weapon block (the loss event itself does not attribute the
  killer; attribution lives in `ordnance.fired` + `asset.dead`).
- The killer (`bandit-1.u1.g1`) **survived** — no loss event for it.
- **No spurious `asset.despawned`** for the dead incarnation (bandit/asset
  death retires without scripted cleanup), no `asset.crashed`, no `pilot.*`
  (AI deaths fire no pilot events; pilot outcomes are player-only and remain
  covered by the offline `run-asset` suite).
- **Gapless `event_sequence` 1..19**, terminal `mission.ended` at seq 19.
- `dcs.log` confirms the emission path and retirement:
  `asset capture: emitted asset.dead asset=testcombat-blue-001.u1.g1` and
  `asset capture: retired testcombat-blue-001.u1.g1 (unit-lost)` (20:51:20.459Z
  — the resolved signal was the **`UnitLost` → `asset.dead`** mapping; the
  `Dead`/`Crash` mappings stay offline-verified).

## Run configuration

Default `TEST_COMBAT` block (no `main.lua` change for this run): bandit
`FA-18C` with 1× `AIM-120C`, no gun; blue AI `TestCombat-Blue` `FA-18C` with no
AAM; both tasked `INTERCEPT` / `WEAPON_FREE`. Both the bandit and the blue AI
are tracked assets (blue via `extend_player_roster` + `register_player_group`).
Procedure per `docs/telemetry/unattended-test-loop.md`: de-sanitized
`D:\DCS World Server\Scripts\MissionScripting.lua` (SHA-1
`33977AAD2B3FE7A39E15374839C813E164BF0929`, from `.telemetry-dev-backup`),
temporary hook `zz-dev-telemetry-load.lua` (400 s auto-stop), server started
`20:49:23Z`.

## Timeline (UTC)

| time (Z) | event |
|---|---|
| 20:49:23 | `DCS_server` process started (PID 17272) |
| 20:49:47 | hook `zz-dev-telemetry-load.lua` loaded |
| 20:50:18.860 | dev mission loaded; auto-stop in 400 s; `setPause(false) ok=true` |
| 20:50:18.590 | `[duel-dynamic][telemetry] started` run `run-20260905T205019Z-24cb9efc`, sequence=1 |
| 20:50:24 | `asset.spawned testcombat-blue-001.u1.g1` (blue), then `bandit-1.u1.g1` (red) |
| 20:51:20.459 | **`asset.dead testcombat-blue-001.u1.g1` emitted + retired (unit-lost)** |
| 20:56:58.872 | `stopMission called ok=true` (400 s auto-stop) |
| 20:56:58.895 | `mission.ended sequence=19` persisted |

## Event stream (NDJSON, all 19 events)

| seq | event_type | asset (asset_key) | notes |
|---|---|---|---|
| 1 | `mission.started` | — | run key set |
| 2 | `asset.spawned` | `testcombat-blue-001.u1.g1` (blue) | `TestCombat-Blue#001-01`, `FA-18C_hornet` |
| 3 | `asset.spawned` | `bandit-1.u1.g1` (red) | `Bandit-1-01`, `FA-18C_hornet` |
| 4 | `mission.heartbeat` | — | |
| 5 | `ordnance.fired` | `bandit-1.u1.g1` (red) | weapon `AIM_120C`, `sim_time=43.841 s` |
| 6 | `mission.heartbeat` | — | |
| **7** | **`asset.dead`** | **`testcombat-blue-001.u1.g1` (blue)** | **`sim_time=61.061 s`, location known** |
| 8–18 | `mission.heartbeat` ×11 | — | |
| 19 | `mission.ended` | — | clean terminal event |

Missile in flight ≈ 17 s (fired sim 43.841 s → kill sim 61.061 s).

Key event bodies (abridged to the loss-relevant fields):

```json
{
  "event_id": "dcs-dev-68eb93a7:run-20260905T205019Z-24cb9efc:5",
  "event_sequence": 5,
  "event_type": "ordnance.fired",
  "sim_time": 43.841,
  "source": "moose-mission",
  "coalition": "red",
  "asset": {
    "asset_key": "bandit-1.u1.g1",
    "dcs_name": "Bandit-1-01",
    "dcs_type": "FA-18C_hornet",
    "kind": "aircraft",
    "status": "known"
  },
  "weapon": { "category": "missile", "dcs_type": "AIM_120C", "status": "known" },
  "location": { "coordinate_system": "dcs-local", "status": "known", "x": -114744.55, "y": 4561.91, "z": 59264.12 },
  "payload": { "dcs_event_name": "shot" }
}
```

```json
{
  "event_id": "dcs-dev-68eb93a7:run-20260905T205019Z-24cb9efc:7",
  "event_sequence": 7,
  "event_type": "asset.dead",
  "sim_time": 61.061,
  "source": "moose-mission",
  "coalition": "blue",
  "asset": {
    "asset_key": "testcombat-blue-001.u1.g1",
    "dcs_name": "TestCombat-Blue#001-01",
    "dcs_type": "FA-18C_hornet",
    "kind": "aircraft",
    "status": "known"
  },
  "weapon": null,
  "location": { "coordinate_system": "dcs-local", "status": "known", "x": -125242.29, "y": 2040.80, "z": 64176.50 },
  "payload": {}
}
```

## Verification (all run 2026-09-05)

- NDJSON: 19 lines; `event_sequence` gapless 1..19 (checked programmatically);
  terminal event `mission.ended` at seq 19.
- Counts: `asset.dead`=1, `asset.spawned`=2, `ordnance.fired`=1
  (AIM_120C), `asset.despawned`=0, `asset.crashed`=0, `pilot.*`=0,
  `mission.heartbeat`=11, `mission.started`=1, `mission.ended`=1.
- `dcs.log`: `[duel-dynamic][telemetry] started … run=run-20260905T205019Z-24cb9efc`;
  `*** MOOSE INCLUDE END ***`; `emit asset.dead` + `retired … (unit-lost)`;
  `DEV-TELEMETRY` hook lines incl. `stopMission called ok=true`.
- No `SCRIPTING` error/`attempt to index` lines attributable to the mission;
  the recurring `EVENTMETA … event ID=61` lines are known-benign MOOSE noise.

## Teardown (verified)

- `Stop-Process` on `DCS_server` (PID 17272); no `DCS_server`/`DCS` process
  remains.
- Hook `zz-dev-telemetry-load.lua` removed from the server hooks directory.
- `D:\DCS World Server\Scripts\MissionScripting.lua` restored from
  `.orig`; SHA-1 **`FB54471ECE4DB968AED4A55A1806B25EA5116452`** (stock)
  verified; `sanitizeModule('os')` line active (L16, uncommented).
- No commit/push/publish; no Neon DB writes; no daemon left running.

## Residual / not exercised live

- `EVENTS.Dead` → `asset.dead` and `EVENTS.Crash` → `asset.crashed` mappings
  were not the signals DCS emitted this run (the kill resolved through
  `UnitLost`); they remain covered by the offline `run-asset` suite (23 tests,
  green).
- `pilot.dead` / `pilot.ejected` are player-incarnation-only; no player
  joined this run, so they remain offline-verified (by design).
- `asset.crashed` (ground-impact/structure failure path) not exercised.
- Backend/ingest wiring (Slice 13 part 3, owner-gated) is the next consumer of
  these source events.
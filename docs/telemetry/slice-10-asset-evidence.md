# Slice 10 tracked aircraft instance evidence

**Validated:** 2026-09-03

**DCS:** 2.9.29.27278 dedicated server
**Mission:** `duel-dynamic`
**Branch:** `slice-10-tracked-instances` (worktree
`C:\Projects\dcs-missions-slice-10`, base `20ee3a7`)

## Result

Slice 10 is complete for the approved implementation and unattended gate. The
development runtime now tracks spawned aircraft instances and emits
contract-normalized `asset.spawned` events for roster wave and player groups,
and resolves `ordnance.fired` to the firing instance with an `asset_key` of
the form `{roster-token}.u{unit_index}.g{generation}` (e.g. `bandit-1.u1.g1`).
The generation counter increments on group-name reuse, so incarnations that
reuse a name keep distinct identities. When identity cannot be established,
both the `initiator` and `asset` references degrade to explicit unknowns with
the reason `instance-identity-unavailable`. Intentional wave cleanup emits
`asset.despawned` with `reason="intentional"`.

Registration is pcall-isolated at the MOOSE `OnSpawnGroup` callback for waves
and at init for already-occupied player slots; every unit field is read
behind `pcall`. No contract, collector, web, or gameplay behavior changed:
web ingest already persists `asset.asset_key`, and the asset key pattern is
the contract's token grammar.

## Integration notes

- **The first unattended attempt ran the wrong source tree.** Run A
  (`run-20260903T143500Z-219fda7c`) was loaded by a bootstrap that resolved
  to the main worktree's root — `dcs.log` records
  `[bootstrap] root: C:\Projects\dcs-missions\src\` — because the
  worktree's copy of `bootstrap.lua` inherits the main project path as the
  hardcoded `resolveRoot()` fallback. It therefore ran the committed Slice 9
  code: no `asset.spawned` exists, and the `ordnance.fired` event carries the
  Slice 9 static unknown-asset block. That NDJSON is a valid Slice 9 run
  (recorded below) and is not Slice 10 evidence. Run B, the accepted run,
  resolved `[bootstrap] root: C:\Projects\dcs-missions-slice-10\src\` and ran
  the branch code. Operational rule: after loading any worktree miz, check the
  `[bootstrap] root:` line in `dcs.log` to confirm which `src/` tree actually
  executed.
- **Silent adapter-missing path hardened.** The two registration helpers
  previously no-op'd without a trace when the telemetry runtime was missing
  (e.g. after a failed telemetry init). During integration review they now
  emit `env.warning` when the asset adapter is unavailable while
  `TELEMETRY_DEVELOPMENT_ENABLED` is set; the shipping build stays silent.

## Automated verification

All required commands were run from the worktree root and passed. Outputs
were:

```text
> lua5.1 tests/lua/telemetry/run.lua
telemetry Lua tests: 20 passed
> lua5.1 tests/lua/telemetry/run-lifecycle.lua
telemetry lifecycle tests: 8 passed
> lua5.1 tests/lua/telemetry/run-shot.lua
telemetry shot tests: 7 passed
> lua5.1 tests/lua/telemetry/run-json-sink.lua
JSON/sink Lua tests: 11 passed
> lua5.1 tests/lua/telemetry/run-participant.lua
telemetry participant tests: 8 passed
> lua5.1 tests/lua/telemetry/run-asset.lua
telemetry asset tests: 5 passed
> lua5.1 tests/lua/run-duel-shared-bandits.lua
duel-dynamic package-wave tests: 11 passed
```

```text
> stylua --check src tests
(no output; exit 0)
```

The worktree checkout was physically LF (git `core.autocrlf=input` writes
blobs as-is on checkout), while the repository working-tree standard — and
`.stylua.toml`'s `line_endings = "Windows"` — is CRLF. After normalizing the
worktree's on-disk line endings to CRLF (byte-identical after git
normalization; `git status` shows only the six branch files), the check
passed.

```text
> npm run typecheck && npm run lint && npm test   (web/)

 Test Files  4 passed (4)
      Tests  23 passed (23)
```

```text
> npm run check   (collector/)

 Test Files  3 passed (3)
      Tests  37 passed (37)
```

Both NDJSON runs were validated through the production web ingest validator
(`web/src/telemetry/validate.ts`: Ajv 2020 strict + ajv-formats + event_id
consistency) via a temporary tsx harness:

```text
run-20260903T143500Z-219fda7c.ndjson: events=5 contiguous=true producer=dcs-dev-68eb93a7 run=run-20260903T143500Z-219fda7c allValid=true [1:mission.started:ok 2:ordnance.fired:ok 3:mission.heartbeat:ok 4:mission.heartbeat:ok 5:mission.ended:ok]
run-20260903T144033Z-02cce3c2.ndjson: events=6 contiguous=true producer=dcs-dev-68eb93a7 run=run-20260903T144033Z-02cce3c2 allValid=true [1:mission.started:ok 2:asset.spawned:ok 3:mission.heartbeat:ok 4:ordnance.fired:ok 5:mission.heartbeat:ok 6:mission.ended:ok]
```

The new asset harness covers roster building and distinct-token guards,
spawned-group name matching, unit-index and generation allocation across name
reuse, player-side registration, despawn emission, and the unknown fallback
for unregistered units.

## Unattended dedicated-server evidence

The accepted run (run B) is `run-20260903T144033Z-02cce3c2`:

```text
path=C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry\run-20260903T144033Z-02cce3c2.ndjson
run_key=run-20260903T144033Z-02cce3c2
event_count=6
1 mission.started
2 asset.spawned
3 mission.heartbeat
4 ordnance.fired
5 mission.heartbeat
6 mission.ended
mission_started_standard_payload={"map_name":"Syria","mission_name":"duel-dynamic","mission_version":"1","run_classification":"test"}
heartbeat_count=2
participant.entered=0
participant.left=0
asset.spawned=1
asset.despawned=0
ordnance.fired=1
gapless=true
asset_spawned: seq=2 asset_key=bandit-1.u1.g1 dcs_name=Bandit-1-01 dcs_type=FA-18C_hornet coalition=red sim_time=5.302 location=known
ordnance_attribution: seq=4 initiator.asset_key=bandit-1.u1.g1 asset.asset_key=bandit-1.u1.g1 callsign=Springfield11 weapon=AIM_120C sim_time=48.361
last_event=mission.ended reason=mission-end-observed
ASSERTIONS=PASS
```

Zero `participant.*` events is by design: the unattended blue is the
`TestCombat-Blue` AI group, which is deliberately not in the telemetry roster.
`asset.despawned` is 0 because the wave was still engaged at the 90-second
auto-stop; intentional despawn emission is unit-tested (`run-asset.lua`) and
remains a live-drill item (see below).

The retained `dcs.log` excerpt (UTC timestamps) is:

```text
2026-09-03 14:40:31.314 INFO    SCRIPTING (Main): [bootstrap] root: C:\Projects\dcs-missions-slice-10\src\
2026-09-03 14:40:32.314 INFO    SCRIPTING (Main): [duel-dynamic][telemetry] started producer=dcs-dev-68eb93a7 run=run-20260903T144033Z-02cce3c2 sequence=1 path=C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs/telemetry/run-20260903T144033Z-02cce3c2.ndjson
2026-09-03 14:40:32.577 INFO    DEV-TELEMETRY (Main): Slice 10 mission loaded; auto-stop in 90 s (realTime=65.5770111)
2026-09-03 14:40:32.577 INFO    DEV-TELEMETRY (Main): setPause(false) ok=true err=nil
2026-09-03 14:40:38.391 INFO    SCRIPTING (Main): [duel-dynamic][telemetry] asset capture: emitted asset.spawned asset=bandit-1.u1.g1
2026-09-03 14:40:38.391 INFO    SCRIPTING (Main): [duel-dynamic] package spawned: Bandit-1 at x=-154001 z=57300 alt=4569m
2026-09-03 14:41:03.105 INFO    SCRIPTING (Main): [duel-dynamic][telemetry] persisted mission.heartbeat sequence=3
2026-09-03 14:41:33.127 INFO    SCRIPTING (Main): [duel-dynamic][telemetry] persisted mission.heartbeat sequence=5
2026-09-03 14:42:02.585 INFO    DEV-TELEMETRY (Main): stopMission called ok=true err=nil
2026-09-03 14:42:02.608 INFO    SCRIPTING (Main): [duel-dynamic][telemetry] persisted mission.ended sequence=6
SCRIPTING_ERROR_WARNING_COUNT=0
ASSET_CAPTURE_LOG_COUNT=1
```

The first attempt, run A, is retained as
`run-20260903T143500Z-219fda7c.ndjson` with log `dcs-20260903-143631.log`. It
ran the main worktree's Slice 9 code (see the integration notes) and is
recorded here for completeness:

```text
path=C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry\run-20260903T143500Z-219fda7c.ndjson
loaded_root=C:\Projects\dcs-missions\src\ (main worktree — Slice 9 code, not branch code)
event_count=5
1 mission.started
2 ordnance.fired   (asset status=unknown reason=instance-identity-unavailable — Slice 9 static behavior)
3 mission.heartbeat
4 mission.heartbeat
5 mission.ended
gapless=true
asset.spawned=0   (Slice 9 code has no asset adapter)
last_event=mission.ended reason=mission-end-observed
CONTRACT_VALIDATION=PASS (production web validator, all 5 events)
```

## Cleanup

Re-verified after the run:

```text
stock_sha1=FB54471ECE4DB968AED4A55A1806B25EA5116452
stock_sha1_match=True
hook_present=False
hooks_dir_contents=TacviewGameGUI.lua
dcs_server_process_count=0
port_3000_tcp_listeners=0
port_10308_tcp_listeners=0
port_10308_udp_endpoints=0
slice10_miz_present=False
dev_miz_sha1=7AB609EEC3398EEFD4A5EC6D12CB9768EB2136E9 (unchanged)
```

The accepted NDJSON and the run's `dcs.log` remain under the dedicated server
`Logs` directory. The install is stock-sanitized and the temporary hook and
temporary miz are removed.

## Remaining live validation

The unattended run proves instance registration, spawn capture, ordnance
attribution, and unknown fallback with no human present. It cannot prove the
multiplayer field availability on the player side. The follow-up
human-in-seat session (combined with the Slice 9 participant drill) must
confirm:

- `asset.spawned` for a player's Aerial slot with the player-side asset key
  and participant linkage.
- `ordnance.fired` attribution to a known player asset key.
- Rejoin / slot change / mission restart producing fresh incarnations
  (generation increment on name reuse) and a clean registry.
- Intentional `asset.despawned` (`reason="intentional"`) on wave cleanup
  (F10 "Respawn bandit wave").
# Slice 9 participant and sortie evidence

**Validated:** 2026-09-03

**DCS:** 2.9.29.27278 dedicated server
**Mission:** `duel-dynamic`

## Result

Slice 9 is complete for the approved implementation and unattended gate. The
development runtime now subscribes a dedicated MOOSE `BASE` watcher to
`EVENTS.PlayerEnterUnit` and `EVENTS.PlayerLeaveUnit`, filters observations to
the exact configured blue player groups, and emits contract-normalized
`participant.entered` and `participant.left` events through the existing
lifecycle controller and NDJSON sink.

Each raw DCS unit capability is read behind `pcall`. The adapter retains stable
multiplayer UCID when available, snapshots display name and callsign, and uses
explicit unknown references when DCS cannot provide data. Per-slot snapshots
preserve identity on a leave whose live unit no longer exposes its UCID. Asset
incarnation identity remains unavailable until Slice 10.

The pure web module pairs sorties by slot and sequence. It closes matched
enter/leave periods, marks an open period `replaced` when a later enter recovers
from a missing leave, ignores unmatched leaves and unresolved slots, and never
invents participant or sortie identity. No database, route, page, collector,
contract, or gameplay code changed.

## Automated verification

All required commands passed. Outputs were:

```text
> lua5.1 tests/lua/telemetry/run-participant.lua
telemetry participant tests: 8 passed
```

```text
> lua5.1 tests/lua/telemetry/run.lua
telemetry Lua tests: 20 passed
> lua5.1 tests/lua/telemetry/run-lifecycle.lua
telemetry lifecycle tests: 8 passed
> lua5.1 tests/lua/telemetry/run-shot.lua
telemetry shot tests: 7 passed
> lua5.1 tests/lua/telemetry/run-json-sink.lua
JSON/sink Lua tests: 11 passed
```

```text
> stylua --check src tests
(no output; exit 0)
```

```text
> npm run typecheck

> typecheck
> tsc --noEmit
```

```text
> npm run lint

> lint
> eslint .
```

```text
> npm test

> test
> vitest run

 RUN  v4.1.11 C:/Projects/dcs-missions/web

 Test Files  4 passed (4)
      Tests  23 passed (23)
   Start at  15:13:23
   Duration  1.22s (transform 94ms, setup 0ms, import 2.12s, tests 57ms, environment 1ms)
```

```text
> npm run check

> check
> npm run format:check && npm run lint && npm run typecheck && npm test

> format:check
> prettier --check .

Checking formatting...
All matched files use Prettier code style!

> lint
> eslint .

> typecheck
> tsc -p tsconfig.json --noEmit

> test
> vitest run

 RUN  v4.1.11 C:/Projects/dcs-missions/collector

 Test Files  3 passed (3)
      Tests  37 passed (37)
   Start at  15:13:31
   Duration  1.61s (transform 160ms, setup 0ms, import 437ms, tests 2.58s, environment 0ms)
```

The participant harness covers watcher cleanup, complete known references, raw
method order, unavailable and absent `getPlayerUCID`, warning logs, exact
roster/coalition/category guards, explicit unknown degradation, leave snapshot
fallback, and missing-unit handling. Nine Vitest cases cover every approved
sortie-pairing rule.

## Unattended dedicated-server evidence

The accepted no-player regression run is
`run-20260903T131923Z-29aa49a0`:

```text
path=C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry\run-20260903T131923Z-29aa49a0.ndjson
run_key=run-20260903T131923Z-29aa49a0
event_count=5
1 mission.started
2 mission.heartbeat
3 ordnance.fired
4 mission.heartbeat
5 mission.ended
mission_started_standard_payload={"map_name":"Syria","mission_name":"duel-dynamic","mission_version":"1","run_classification":"test"}
heartbeat_count=2
participant.entered=0
participant.left=0
ordnance.fired=1
gapless=true
last_event=mission.ended reason=mission-end-observed
ASSERTIONS=PASS
```

The retained `dcs.log` excerpt is:

```text
2026-09-03 13:19:18.509 INFO    SCRIPTING (Main): *** MOOSE INCLUDE END ***
2026-09-03 13:19:23.747 INFO    SCRIPTING (Main): *** MOOSE INCLUDE END ***
2026-09-03 13:19:23.760 INFO    SCRIPTING (Main): [duel-dynamic][telemetry] started producer=dcs-dev-68eb93a7 run=run-20260903T131923Z-29aa49a0 sequence=1 path=C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs/telemetry/run-20260903T131923Z-29aa49a0.ndjson
2026-09-03 13:19:24.026 INFO    DEV-TELEMETRY (Main): dev mission loaded; auto-stop in 90 s (realTime=63.026231)
2026-09-03 13:19:24.026 INFO    DEV-TELEMETRY (Main): setPause(false) ok=true err=nil
2026-09-03 13:19:54.550 INFO    SCRIPTING (Main): [duel-dynamic][telemetry] persisted mission.heartbeat sequence=2
2026-09-03 13:20:24.552 INFO    SCRIPTING (Main): [duel-dynamic][telemetry] persisted mission.heartbeat sequence=4
2026-09-03 13:20:54.032 INFO    DEV-TELEMETRY (Main): stopMission called ok=true err=nil
2026-09-03 13:20:54.054 INFO    SCRIPTING (Main): [duel-dynamic][telemetry] persisted mission.ended sequence=5
SCRIPTING_ERROR_WARNING_COUNT=0
PARTICIPANT_CAPTURE_LOG_COUNT=0
```

The first attempt, retained as
`run-20260903T131549Z-6e92c319.ndjson` with archived log
`dcs-20260903-131719.log`, had zero participant events and a gapless clean end,
but DCS produced two authoritative AIM-120C shot events despite the dev-only
single-shot setup. It did not meet this task's at-most-one-ordnance assertion.
The clean retry above produced one shot and passed every unattended assertion.
This is existing test-combat nondeterminism, not participant capture behavior,
but it remains visible rather than being discarded.

## Cleanup

```text
stock_sha1=FB54471ECE4DB968AED4A55A1806B25EA5116452
stock_sha1_match=True
hook_present=False
dcs_server_process_count=0
port_3000_tcp_listeners=0
port_10308_tcp_listeners=0
port_10308_udp_endpoints=0
```

The accepted NDJSON and successful run's `dcs.log` remain under the dedicated
server `Logs` directory. The install is stock-sanitized and the temporary hook
is removed.

## Remaining live validation

The unattended run proves the watcher produces no false participant events and
leaks no participant state when no human is present. It cannot prove DCS's
multiplayer field availability. A follow-up human-in-seat run must still enter,
leave, rejoin, change slots, and restart the mission, then confirm runtime
`getGroupName`, `getPlayerUCID`, and callsign behavior; stable UCID retention on
late leave; distinct sortie boundaries; and fresh snapshot state after restart.

# Slice 4 mission lifecycle evidence

**Validated:** 2026-08-31  
**DCS:** 2.9.29.27278 dedicated server  
**Mission:** `duel-dynamic`

## Result

Slice 4 is complete. The mission creates stable development producer identity,
a fresh run key for each mission generation, gapless event sequence state, and
contract-valid lifecycle events. The development sink writes one append-only
NDJSON file per run and verifies each append after closing the file.

The production GameGUI bridge remains deferred to Slice 17. The Slice 4 sink
requires development de-sanitization and is removed by the shipping packager.

## Implementation

- `telemetry/development.lua`: DCS/MOOSE adapter, run context, heartbeat
  scheduler, and `EVENTS.MissionEnd` watcher.
- `telemetry/lifecycle.lua`: fail-closed lifecycle state machine and
  pending-envelope retry.
- `telemetry/json.lua`: strict Lua 5.1 JSON encoder.
- `telemetry/ndjson_sink.lua`: append, flush, close, reopen, and readback
  verification. DCS file handles do not expose `seek`, so the sink has a
  tested full-file verification fallback.
- `bootstrap.lua` and `main.lua`: development-only initialization retained for
  the mission generation lifetime.

Policies verified by tests and DCS:

- Sequence 1 is exactly `mission.started`.
- `producer_id` is stable for the dedicated-server write directory.
- Every mission generation gets a fresh `run_key`.
- Heartbeats are emitted every 30 seconds of model time.
- `mission.ended` is best-effort and idempotent.
- A failed write faults telemetry without aborting gameplay.
- Retry reuses the already-built envelope and sequence number.

## Automated verification

All commands passed:

```text
lua5.1 tests/lua/telemetry/run.lua             20 passed
lua5.1 tests/lua/telemetry/run-json-sink.lua   11 passed
lua5.1 tests/lua/telemetry/run-lifecycle.lua    7 passed
npm --prefix contracts run check               32 passed
stylua --check src/missions/duel-dynamic/main.lua
git diff --check
```

`build/pack-shipping-miz.ps1` also passed. The synthesized
`out/duel-dynamic-build/Scripts/main.lua` contains no telemetry or NDJSON
references and parses under Lua 5.1.

## Dedicated-server evidence

The first DCS attempt exposed an actual host incompatibility:

```text
NDJSON sink faulted: seek is not available on the file handle
```

Telemetry faulted closed and gameplay initialization continued. Evidence is
archived at:

```text
Saved Games\DCS.dcs_serverrelease\Logs\telemetry.slice4-failed-no-seek.20260831-205302-069
Saved Games\DCS.dcs_serverrelease\Logs\dcs.log.slice4-failed-no-seek.20260831-205302-075
```

After adding full-file verification, real DCS produced:

| Run key | Evidence |
|---|---|
| `run-20260831T185951Z-6b3cabc1` | Two gapless records: `mission.started`, then clean `mission.ended` |
| `run-20260831T185956Z-5a35aab3` | `mission.started` plus consecutive 30-second heartbeats through sequence 53 before the controlled server restart |
| `run-20260831T192730Z-7487a07d` | Fresh sequence-1 start after restart and consecutive heartbeats; the final 24-record archive passed schema, event-ID, run-consistency, and gapless-sequence validation |

The producer stayed `dcs-dev-68eb93a7` across all three generations while the
run key changed each time.

## Gameplay regression found by the gate

The initial player smoke test exposed a pre-existing dedicated-server bug. The
mission stopped its world-init poll after 30 seconds, but a headless server can
wait much longer for its first player. A later player-enter event was therefore
ignored while `initDone` remained false.

The poll now waits without a timeout and accepts any occupied Aerial slot. A
post-restart late join produced this server sequence:

```text
19:31:07 Aerial-1 already occupied at init — spawning paired bandit now
19:31:07 spawning Bandit-1 59.7 nm from Aerial-1
19:31:07 tasked Bandit-1#001 → INTERCEPT on Aerial-1
19:31:07 init done — player-enter events will now spawn bandits
19:35:40 AIM-120C kill credited to James V
19:35:44 Bandit-1 killed — respawn scheduled in 30s
19:36:14 spawning and tasking Bandit-1#002
```

The player also confirmed the F10 menu. No `ERROR SCRIPTING`, timer error, or
telemetry failure occurred during this run.

Final evidence was archived after player disconnect and server shutdown:

```text
Saved Games\DCS.dcs_serverrelease\Logs\dcs.log.slice4-complete.20260831-214307-007
Saved Games\DCS.dcs_serverrelease\Logs\telemetry.slice4-complete.20260831-214307-007
```

All three archived NDJSON files passed a final validation after they were
closed: 2, 53, and 24 gapless records respectively. The dedicated-server and
full-client `MissionScripting.lua` files were then restored from their stock
`.orig` copies and verified by SHA-256. The dedicated server was left stopped.

The first client load took about 117 seconds from connection to control handoff.
The client log spent that time in Syria terrain, metashader, preload, and slot
resource loading; the dedicated mission and telemetry were already healthy.

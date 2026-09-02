# Slice 5 ordnance capture evidence

**Validated:** 2026-09-01

**DCS:** 2.9.29.27278 dedicated server
**Mission:** `duel-dynamic`

## Result

Slice 5 is complete. The development telemetry runtime subscribes through
MOOSE `BASE:HandleEvent(EVENTS.Shot)`, filters initiators to the configured
`Aerial-*` player groups and spawned `Bandit-*#NNN` groups, and writes one
contract-valid `ordnance.fired` source event for each accepted DCS shot.

The adapter captures runtime weapon type and category, firing aircraft,
coalition, DCS-local position, simulation time, and stable participant identity
when MOOSE supplies the multiplayer UCID. Asset incarnation identity remains
explicitly unavailable until Slice 10. Machine-gun start/end streams are not
subscribed.

## Automated verification

All commands passed:

```text
lua5.1 tests/lua/telemetry/run.lua             20 passed
lua5.1 tests/lua/telemetry/run-json-sink.lua   11 passed
lua5.1 tests/lua/telemetry/run-lifecycle.lua    8 passed
lua5.1 tests/lua/telemetry/run-shot.lua         7 passed
npm --prefix contracts run check               32 passed
stylua --check src/missions/duel-dynamic/main.lua \
  src/missions/duel-dynamic/telemetry tests/lua/telemetry
git diff --check
```

`build/pack-shipping-miz.ps1` also passed. Its staged shipping `main.lua`
contains no telemetry, NDJSON, `EVENTS.Shot`, or `ordnance.fired` references and
parses under Lua 5.1.

Tests cover exact roster matching, rejection of similarly prefixed and
out-of-roster groups, player and AI shots, known and unavailable participant
identity, missing/throwing DCS fields, exact event-time preservation, distinct
identity for equal-time shots, pending-envelope retry after sink failure, and
Shot watcher lifetime and cleanup.

## Dedicated-server evidence

### Controlled two-shot run

Run `run-20260901T183707Z-2276b81a` contained exactly:

1. `mission.started`, sequence 1.
2. James V firing AIM-120C, sequence 2, simulation time `12.331`.
3. James V firing AIM-120C, sequence 3, simulation time `22.074`.

Both shot records had distinct event IDs, the same new run key, known blue
participant and aircraft snapshots, missile category, DCS-local location, and
an explicit unknown asset with reason `instance-identity-unavailable`. All
three records passed the JSON Schema, event-ID, run-consistency, and gapless
sequence checks.

An earlier run produced three telemetry records after DCS itself reported three
separate player Shot events. This confirmed that the adapter was not duplicating
callbacks: telemetry count matched the authoritative DCS event log exactly.

### Two-player multiplayer run

Run `run-20260901T194822Z-3652ad24` validated the configured roster with two
human players and their paired AI bandits:

| Source | AIM-120C shots |
|---|---:|
| James V (`Aerial-1`) | 2 |
| Jazpero (`Aerial-3`) | 5 |
| Paired red AI bandits | 8 |
| **Total** | **15** |

The stream contained 51 events when validated. Every complete record passed
the version-one schema, event-ID construction, run consistency, and gapless
sequence checks. The two human participants retained distinct names, callsigns,
and UCIDs; AI shots correctly used a null participant. Logs also showed both
paired bandits spawning and tasking, several bandit kill/30-second respawn
cycles, player deaths, and player-leave despawns.

No telemetry fault, normalization error, sink error, or new telemetry-related
`SCRIPTING ERROR` occurred.

Evidence is archived at:

```text
Saved Games\DCS.dcs_serverrelease\Logs\telemetry.slice5-complete.20260901-214634-688
Saved Games\DCS.dcs_serverrelease\Logs\telemetry.slice5-multiplayer.20260901-220842-786
```

## Gameplay follow-ups exposed by multiplayer

These are existing duel mission issues, not failures of Shot capture:

- The immediate bandit-kill popup shows `Tracker.total`, a coalition-wide team
  total, while its wording can be read as the current player's total. Reliable
  attacker attribution remains deferred to the planned kill-attribution slice.
- Player death and respawn messages use `ToCoalition(BLUE)`, so both players see
  “You died” and “Respawn ready” when only one player died.
- “Respawning in 30s” is misleading. The script resets the paired bandit after
  30 seconds; the player must manually rejoin the slot.
- One `Aerial-1` death reached its 30-second callback without a live player or
  bandit coordinate and logged `no anchor for Bandit-1 respawn — aborting`.
  Another player reset completed at the expected 30-second mark.

These follow-ups should be fixed and re-tested as a separate mission-behavior
change rather than folded into telemetry Slice 5.

## Cleanup

The dedicated server was stopped after evidence capture. Both the dedicated
server and full-client `MissionScripting.lua` files were restored to their
stock `.orig` content and verified with SHA-256
`39066C8CED213B447B03AF5A25ECA63BF15BE71179D53A14EB13312DE07A542D`.

# Slice 17 Part 2: Production GameGUI Hook Evidence

## Scope

S17-p2 adds the project-owned production GameGUI telemetry hook and an offline
three-state mock that loads the real hook against the real S17-p1 mission bridge.
It does not run DCS, install a hook, build or package a `.miz`, change the
mission-side contract, or modify collector behavior.

## Implemented transport and protocol

The hook uses only the Slice 3 nested route:

```text
hook state -> net.dostring_in("mission", wrapper)
trigger state wrapper -> a_do_script(inner)
mission state inner -> _G.duel_telemetry_bridge
```

The inner chunk serializes its return values into one NUL-free tagged string
using the proven tags (`0` nil, `1` number, `2` boolean, `3` string, `4`
unsupported type) and returns a dummy second value. The trigger wrapper checks
both return positions, supporting the installed shifted/drop-last mapping and a
future fixed mapping. Producer and run values are validated tokens before they
are interpolated into mission source, so they cannot contain quotes or
backslashes.

For every mission load, the hook follows `idle -> handshaking -> draining ->
stopping -> idle`:

1. It creates a fresh `run-<UTC>-<fingerprint>` key and calls
   `bridge:begin(producer_id, run_key)` before mission sequence 1.
2. It peeks from `last_acked_sequence + 1`. A `frame-too-large` result halves
   the requested frame count immediately, down to the configured minimum.
3. It validates the complete frame with a behavior-identical inlined copy of
   the pinned `DDBRIDGE1` codec.
4. It appends every decoded JSON line plus LF, closes the spool, reopens it in
   binary mode, reads the complete file, and byte-compares it with the expected
   cumulative content. Falsey DCS file-method return values are not treated as
   failures; only the reopened bytes establish acceptance.
5. Only after exact verification does it acknowledge the frame's highest
   contiguous sequence. Failed acknowledgement leaves the mission cursor
   unchanged; retry can append byte-identical duplicates, which retain the same
   `event_id` for collector deduplication.

A corrupt or unverifiable spool and an oversized single frame make that
generation stuck, preventing unsafe acknowledgement or further append. Missing
bridge runtimes are retried no faster than eight polling intervals. An absent
or raising `net.dostring_in` is logged once per generation and is not
retry-stormed. Callback bodies are protected with `pcall` and do not raise into
DCS.

`onSimulationStop` runs exactly one best-effort final drain cycle when possible,
then writes a stop summary. This does not eliminate the accepted risk of events
remaining only in mission memory when the mission or process crashes.

## Files and persistence layout

All paths are based on hook-state `lfs.writedir()` and are created on demand:

```text
<writedir>/Logs/telemetry/<run_key>.ndjson
<writedir>/Logs/telemetry-bridge/producer-id
```

The producer file contains a stable `dcs-server-<8-hex-fingerprint>` token and
is reused across DCS restarts. Each mission generation gets a new run key and a
new spool file; an earlier generation's file is never reopened by a later
generation.

The production configuration defaults are the pinned `max_frames=32`,
`min_frames=1`, `poll_interval_s=0.25`, `max_backoff_s=4.0`, directory names,
producer filename, and `TELEMETRY_BRIDGE_HOOK` log tag. The offline mock uses
two additional test-only callback seams, `test_export` and
`test_spool_verify_mutator`, to inspect private state/codec behavior and inject
post-close corruption. They are absent from production configuration and do not
change production defaults or the mission protocol. No frame-size override was
added; the real codec's pinned 65536-byte cap is exercised directly.

## Log catalog and privacy

The hook uses `log.write(<tag>, log.INFO, ...)`, which writes to `dcs.log`.
Examples contain operational metadata only:

```text
TELEMETRY_BRIDGE_HOOK START producer=dcs-server-12ab34cd producer-file=C:/Saved Games/DCS/Logs/telemetry-bridge/producer-id
TELEMETRY_BRIDGE_HOOK LOAD callback-api=Sim
TELEMETRY_BRIDGE_HOOK fatal category=callback-api-unavailable
TELEMETRY_BRIDGE_HOOK fatal category=producer-identity-unavailable
TELEMETRY_BRIDGE_HOOK handshake-ok generation=1 run=run-20260907T000000Z-89abcdef producer=dcs-server-12ab34cd
TELEMETRY_BRIDGE_HOOK bridge-runtime-missing generation=1
TELEMETRY_BRIDGE_HOOK transport-unavailable generation=1 category=transport-unavailable
TELEMETRY_BRIDGE_HOOK handshake-failed generation=1 error=redacted bytes=24
TELEMETRY_BRIDGE_HOOK hook-error transport generation=1 category=mission-eval-failed
TELEMETRY_BRIDGE_HOOK peek-failed generation=1 error=redacted bytes=18
TELEMETRY_BRIDGE_HOOK frame-invalid generation=1 from=4 failures=1 bytes=512
TELEMETRY_BRIDGE_HOOK frame-stuck generation=1 at-sequence=4
TELEMETRY_BRIDGE_HOOK spool-verify-failed generation=1 at-sequence=4..6 bytes=2048
TELEMETRY_BRIDGE_HOOK ack-failed generation=1 at-sequence=6 category=redacted
TELEMETRY_BRIDGE_HOOK drained generation=1 from=4..6 count=3 bytes=1980 spool=C:/Saved Games/DCS/Logs/telemetry/run-20260907T000000Z-89abcdef.ndjson
TELEMETRY_BRIDGE_HOOK STOP generation=1 spooled=6 spool=C:/Saved Games/DCS/Logs/telemetry/run-20260907T000000Z-89abcdef.ndjson failures=0 stuck=false unspooled=0
```

No log record contains decoded events, player names, callsigns, UCIDs (raw or
fingerprinted), addresses, or other event payloads. Full normalized event JSON
belongs only in the NDJSON ledger. Mission error text is categorized or
redacted rather than echoed.

## Owner-gated S17-p4 installation

This item did not perform installation. For the live dedicated-server gate:

1. Keep the dedicated server's install-level `MissionScripting.lua` stock.
   The production bridge must work under stock mission sanitization; do not add
   an `autoexec.cfg` unsafe-API exception.
2. Copy `hooks/duel-dynamic-telemetry.lua` to:

   ```text
   C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Scripts\Hooks\duel-dynamic-telemetry.lua
   ```

   No numeric filename prefix is required. The file must coexist with the
   existing `TacviewGameGUI.lua`; do not replace or modify Tacview's hook.
3. A passing `dcs.log` must show one `START`, a successful `LOAD` identifying
   `Sim` or `DCS`, `handshake-ok` for the loaded shipping mission, one or more
   monotonic `drained` ranges as events arrive, and a clean `STOP` summary. It
   must not show a hook `fatal`, `transport-unavailable`, `frame-stuck`,
   `spool-verify-failed`, or callback `hook-error` attributable to this hook.
4. Verify the resulting NDJSON path and byte content through the existing
   collector ingest without exposing event payloads in log evidence.

## Files added

- `hooks/duel-dynamic-telemetry.lua`
- `tests/dcs/run-telemetry-bridge-prod-mock.lua`
- `docs/telemetry/slice-17-part2-hook-evidence.md`

No existing file was modified.

## Acceptance outputs

Production hook mock, with all 26 scenario checks run under both mappings:

```text
> lua5.1 tests/dcs/run-telemetry-bridge-prod-mock.lua
telemetry bridge production mock (shifted): 26 passed, 0 failed
telemetry bridge production mock (fixed): 26 passed, 0 failed
telemetry bridge production mock: 52 checks passed across both mappings
```

Existing DCS mocks:

```text
> lua5.1 tests/dcs/run-telemetry-bridge-probe-mock.lua
telemetry bridge probe mock: passed
> lua5.1 tests/dcs/run-telemetry-bridge-api-discovery-mock.lua
telemetry bridge API discovery mock: passed
```

All nine mission-side runners remain green (144 tests total):

```text
> lua5.1 tests/lua/run-duel-shared-bandits.lua
duel-dynamic package-wave tests: 12 passed
> lua5.1 tests/lua/telemetry/run.lua
telemetry Lua tests: 20 passed
> lua5.1 tests/lua/telemetry/run-lifecycle.lua
telemetry lifecycle tests: 8 passed
> lua5.1 tests/lua/telemetry/run-shot.lua
telemetry shot tests: 10 passed
> lua5.1 tests/lua/telemetry/run-json-sink.lua
JSON/sink Lua tests: 11 passed
> lua5.1 tests/lua/telemetry/run-participant.lua
telemetry participant tests: 9 passed
> lua5.1 tests/lua/telemetry/run-asset.lua
telemetry asset tests: 23 passed
> lua5.1 tests/lua/telemetry/run-combat.lua
telemetry combat tests: 11 passed
> lua5.1 tests/lua/telemetry/run-bridge.lua
telemetry bridge tests: 40 passed
```

Whole-repository formatting produced no output and exited 0:

```text
> stylua --check .
```

## Residual risk

Not verified here: execution in the real DCS 2.9.29.x GameGUI runtime, the
owner-gated stock dedicated-server run, shipping `.miz` packaging/integration,
or multi-client multiplayer identity correlation. Packaging remains S17-p3/p4
work; identity/authentication and later correlation belong to the separately
planned Slice 19/18 scope. Mission-crash loss before hook acceptance remains the
explicitly accepted bridge limitation.

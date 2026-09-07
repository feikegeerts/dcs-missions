# Slice 17 Part 1: Mission Telemetry Bridge Evidence

## Scope

This item implements only the stock-sanitized mission-side bridge in pure Lua
5.1: a bounded in-memory event-line queue, the `DDBRIDGE1` frame codec, the
handshake-driven production composition, and its unit-test runner. It does not
implement a GameGUI hook, packaging, collector or database behavior, or a live
DCS test.

## Pinned frame format

Every frame is NUL-free and no larger than 65536 bytes. The first bytes are the
ASCII header (the final LF is byte `0A`):

```text
DDBRIDGE1|<producer_id>|<run_key>|<first_sequence>|<last_sequence>|<count>|<payload_bytes>\n
```

The header has exactly seven fields. `payload_bytes` is the sum of the byte
lengths of the JSON event strings and excludes record prefixes. It is followed
immediately by `count` records:

```text
<decimal byte length>|<exactly that many payload bytes>
```

There is no delimiter after a payload. The next record starts at the byte after
the preceding length-delimited payload. The complete frame ends at the final
payload byte with no trailing newline or other data. Producer and run values use
the `event_id` token grammar. Sequence, count, payload, record-length, exact-end,
NUL, and total-frame-size checks are performed by both sides of the codec as
applicable.

## Queue and hook protocol semantics

- Queue indexes are one-based lifetime indexes. Queue line index N maps directly
  to envelope `event_sequence` N; the queue itself has no run or producer
  knowledge.
- The queue is bounded by pending line count. Overflow never drops an event: it
  returns the stable hard error `bridge queue overflow: maximum pending lines N
  reached`. The lifecycle faults and retains the already-built pending envelope;
  retry remains faulted while the full condition remains.
- Peeks are bounded, contiguous, non-destructive, and repeatable. A stale start
  is rejected. Acknowledgement removes only the contiguous prefix through the
  supplied highest safely-spooled sequence; stale and beyond-pending
  acknowledgements are rejected.
- `start` installs the same runtime table at `_G.duel_telemetry_bridge` and
  `_G.duel_telemetry_runtime`, but leaves it in `waiting` with no event
  subscriptions, scheduler, adapters, or allocated sequence. This lets the
  mission run normally when no hook handshakes.
- `begin(producer_id, run_key)` validates hook-injected tokens before sequence 1
  and performs the full lifecycle/adapters start. Mission-side code never
  derives either identifier from a clock.
- `peek` returns `""` as the drained success marker. If encoding the requested
  range would exceed 65536 bytes, it returns `nil, "frame-too-large"` without
  splitting; the hook must retry with a smaller `max_frames`.
- `ack` remains available in active, ended, and faulted lifecycle states so
  already-captured events can still be drained.
- Mission wall time is always the envelope JSON-null sentinel and therefore
  serializes as JSON `null`; no later stage may treat receipt time as source
  capture time.
- The runtime `path` compatibility field is the hook-injected `run_key`; there
  is no mission-side production file path.

## Files added

- `src/missions/duel-dynamic/telemetry/bridge_queue.lua`
- `src/missions/duel-dynamic/telemetry/bridge_frame.lua`
- `src/missions/duel-dynamic/telemetry/bridge.lua`
- `tests/lua/telemetry/run-bridge.lua`
- `docs/telemetry/slice-17-part1-mission-bridge-evidence.md`

No existing file was modified by this item. In particular, the pre-existing
working-tree modification to `src/missions/duel-dynamic/main.lua` was left
untouched. Other pre-existing collector, web, and documentation work also
remains present and untouched.

## Acceptance outputs

New runner:

```text
> lua5.1 tests/lua/telemetry/run-bridge.lua
telemetry bridge tests: 40 passed
```

Existing runners (104 baseline tests):

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
```

Total: 104 baseline + 40 bridge = 144 passing tests.

Formatting checks produced no output and exited 0:

```text
> stylua --check src/missions/duel-dynamic/telemetry
> stylua --check tests/lua/telemetry
```

The final `git status --porcelain` output is recorded verbatim below. The five
S17-p1 untracked files are mixed with pre-existing unrelated working-tree work:

```text
 M collector/src/delivery-cli.ts
 M collector/src/delivery.ts
 M collector/src/spool.ts
 M collector/tests/delivery.test.ts
 M collector/tests/spool.test.ts
 M docs/PROJECT-STATUS.md
 M src/missions/duel-dynamic/main.lua
 M web/package.json
 M web/src/app/api/telemetry/runs/[runId]/events/route.ts
 M web/src/app/globals.css
 M web/src/app/page.tsx
 M web/src/telemetry/export.ts
 M web/src/telemetry/ingest.ts
 M web/src/telemetry/run-status.ts
 M web/src/telemetry/store.ts
 M web/tests/export.test.ts
 M web/tests/ingest.test.ts
 M web/tests/run-status.test.ts
?? collector/tests/delivery-cli.test.ts
?? docs/telemetry/slice-16-part1-run-status-evidence.md
?? docs/telemetry/slice-16-part2-export-replay-evidence.md
?? docs/telemetry/slice-16-part3-ingest-metrics-evidence.md
?? docs/telemetry/slice-16-part4a-delivery-retry-evidence.md
?? docs/telemetry/slice-16-part4b-health-prune-evidence.md
?? docs/telemetry/slice-17-part1-mission-bridge-evidence.md
?? src/missions/duel-dynamic/telemetry/bridge.lua
?? src/missions/duel-dynamic/telemetry/bridge_frame.lua
?? src/missions/duel-dynamic/telemetry/bridge_queue.lua
?? tests/lua/telemetry/run-bridge.lua
?? web/scripts/dev-replay-run.ts
?? web/src/telemetry/ingest-metrics.ts
?? web/src/telemetry/replay.ts
?? web/tests/ingest-metrics.test.ts
?? web/tests/replay.test.ts
```

## Residual risk

Not verified in this item: the real nested DCS transport, the S17-p2 GameGUI
hook and durable spool implementation, shipping `.miz` packaging, or the
owner-gated stock-sanitized live dedicated-server run. Mission-crash loss before
hook acceptance remains the explicitly accepted in-memory bridge limitation.

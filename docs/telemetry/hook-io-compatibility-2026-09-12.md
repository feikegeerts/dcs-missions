# Stock DCS hook I/O compatibility fix — 2026-09-12

## Observed failure and root cause

The collector service was running with zero backlog, but the original run
`run-20260912T180014Z-3124ce98` contained only `mission.started`. DCS logged
participant, shot, hit, kill and loss capture internally. The hook stopped on
`spool-write-failed generation=1 at-sequence=1..1`, despite that complete event
being present on disk. The installed hook matched the September 8 repository
version; it was not an outdated deployment.

A temporary hook probed a separate ten-byte file in `Logs/telemetry-bridge`.
Actual stock GameGUI behavior (18:29 and 18:31 UTC):

- `pcall(file.write, ...)`, `flush` and `close` returned **only `true`**:
  the operations themselves returned no values.
- `file.seek` was **nil**, not a standard Lua seek method.
- `file.read(2)` returned `01`, then `23` on the next call.
- `require("io")` returned the same restricted table; it did not provide seek.

The first candidate fixed write results but still failed with
`spool-read-failed`. Accepting absent seek return values was also insufficient:
the method did not exist. These failed intermediate runs are not acceptance
evidence. The production mock previously supplied a standard seekable file API
and therefore missed this incompatibility.

## Fix

`hooks/duel-dynamic-telemetry.lua` now:

1. Accepts no-return write/flush/close calls, but rejects exceptions, explicit
   `false`, and returned error values. All three operations are attempted so a
   failure does not skip closing the handle.
2. Retains append/close/reopen, size, bounded prefix and exact append-byte
   verification before acknowledging the mission queue.
3. Detects absent seek and uses bounded sequential reads instead. On seek-less
   DCS each physical segment is at most **65,536 bytes**, rotating before the
   next append would exceed that limit. A callback reads at most three segment
   bounds for verification; it never rereads an unbounded lifetime spool.
4. Keeps the initial canonical `run-....ndjson` path and uses subsequent files
   named `run-....ndjson.part-000000001.ndjson`, etc. The canonical path remains
   in STOP evidence so existing run-key extraction is unchanged. Event IDs,
   sequence numbers and producer/run identity do not change across segments.
5. Leaves the original seek-based bounded read path intact where available.

The collector already discovers all `.ndjson` files and derives run identity
from event contents, with a cursor per physical file. No collector runtime,
database, mission archive, credential, or service configuration change was
needed. Preserve **all** segments when archiving or recovering a run, not just
its canonical file.

## Verification

- New tests first reproduced the no-return write failure and the previous
  acceptance of explicit flush/close errors.
- Production hook mock: **98 checks pass**, across both DCS return mappings.
  Includes real-DCS-like no-return I/O/no seek, continued draining, explicit
  write/flush/close/seek errors, corruption, short writes, and a **2,001-event**
  multi-segment run with exact event count, no duplicate lines, bounded reads,
  and truthful clean stop.
- Mission bridge: **41 tests pass**; bridge probe and API-discovery mocks pass.
- Collector `npm run check`: format, lint, typecheck and **122 tests pass**.
  Added a segment test covering one logical run, restart, a partial appended
  record, independent file cursors, clear source tails and idempotent re-scan.
- StyLua check for both changed Lua files and `git diff --check` pass.
- Installed server hook compared equal to the repository hook ignoring line
  endings. Temporary probe hook removed before the final restart.

## Live acceptance

Owner explicitly approved server restart, then joined and fired a missile.
Server restarts were graceful. No collector-state reset or database cleanup
was performed. The original run's unexported in-memory events were not
recovered; do not infer completeness for the failed runs.

Final run: `run-20260912T183548Z-1491cbb8`, producer
`dcs-server-3cd14b8a`.

Hook log (UTC):

| Time | Evidence |
|---|---|
| 18:36:11.994 | Handshake successful |
| 18:36:12.257 | Sequence 1 drained and acknowledged |
| 18:37:49.760 | Sequences 2–3 drained (player aircraft / participant) |
| 18:37:53.164 | Sequence 4 drained (bandit aircraft) |
| 18:38:18.816 | Sequence 5 drained (heartbeat) |
| 18:38:37.110 | Sequence 6 drained (player ordnance) |

Production reads from `https://dcs-missions.vercel.app/api/telemetry/runs/`:

- Run listing advanced to sequence 7 / 7 events, updated at
  `2026-09-12T18:38:51.896Z`.
- Subsequent events API returned gapless sequences **1–8**:
  mission start, aircraft, participant, aircraft, heartbeat, ordnance,
  heartbeat, heartbeat.
- Expenditures API returned sequence **6**, `AIM_120C`, blue
  `aerial-1.u1.g1`, cost **105,000,000 cents ($1.05M score estimate)**.
- Continued observation around 18:41 UTC returned three AIM-120C expenditures
  (blue sequences 6 and 12, red sequence 11), one hit, one kill report, and one
  aircraft-death event. The kills API attributed the blue aircraft loss to the
  red bandit (killing-blow sequence 15); the losses API returned the blue
  FA-18C loss from sequence 16, **2,900,000,000 cents ($29M score estimate)**.
  Both projections were persisted at `2026-09-12T18:41:04Z`.

This is live-append DCS → hook → collector → production API evidence, not a
closed-file replay. Browser rendering/refresh was not directly observed by the
assistant. Large segment rollover is regression-tested, not live stress-tested;
this run does not establish a full shutdown/kill/recovery acceptance matrix.

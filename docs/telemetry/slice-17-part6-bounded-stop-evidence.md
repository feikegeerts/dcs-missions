# Slice 17 part 6: bounded hook work and truthful stop

Date: 2026-09-08. Authority: the owner-approved near-live plan,
`docs/telemetry/slice-18-5-near-live-plan.md`, section 4 (lines 216-233), and
the S17-p5 handoff in
`docs/telemetry/slice-17-part5-ack-reconciliation-evidence.md:146-159`.

## Scope and verified pre-state

This change is limited to the production GameGUI hook, the smallest required
mission bridge health helper, offline production mocks, and packaging
verification. It does not change source events, gameplay/business rules, event
identity, the development NDJSON sink, collector code, or contracts.

Before this change, the hook retained `state.spool_content` and constructed a
new lifetime-sized expected string for every append; `write_and_verify` then
reread the whole file. STOP performed one forced cycle and rendered nil known
tail state as zero. The p5 handoff identifies those residuals at lines 148-153.
`clock_now` used `os.clock()` with a literal-zero fallback. Baseline verification
before editing passed: bridge 41, production mock 60 (30 per return mapping),
StyLua, web 200, and collector 109 plus format/lint/typecheck. `luacheck` was not
installed.

## Design

### Bounded append verification and compatibility

`hooks/duel-dynamic-telemetry.lua:414-474` implements append-region
verification:

1. Read the pre-append size through guarded `lfs.attributes(path, "size")` and
   require it to equal the scalar `state.spool_size` (zero permits a new file).
2. Read and retain only the final `VERIFY_PREFIX_BYTES` (256) bytes before the
   append boundary as a bounded seam guard.
3. Open in `ab`, write, flush, and close, checking both protected calls and
   their return values.
4. Require post-size to equal `pre_size + #appended`; require the bounded old
   seam to be unchanged; seek to `pre_size`, read exactly `#appended`, and
   compare byte-for-byte with `appended`.
5. Only then update `state.spool_size` and `spool_verified_sequence`
   (`:717-733`). ACK remains after this operation.

No lifetime spool string remains in hook state. Per append, retained memory is
the bounded seam plus the current bounded frame/NDJSON append. Reads are at
most 256 bytes for either seam read and `#appended` bytes for the append read;
there is no whole-spool operation in the normal spool path. The pre-size check
catches historical truncation/extension, and the seam guard catches
same-length corruption immediately before the new append; arbitrary
same-length mutation farther back in already-written history is deliberately
outside append-region verification and cannot be exhaustively detected without
unbounded rereading or a filesystem integrity primitive.

The output remains one append-only, newline-terminated NDJSON file at the same
per-run path. There is no rotation, segmentation, truncation, or rewrite, so
the collector's persisted byte cursor remains compatible.

### Callback and memory budgets

Named constants are at hook lines 18-21 and exported only to the offline mock
at `:1011-1018`:

- `MAX_SPOOL_BYTES_PER_CYCLE = 65536`: one wire frame is decoded per cycle and
  the NDJSON append is no larger than the wire frame cap.
- `MAX_MISSION_EVALS_PER_CYCLE = 3`: one peek, one ACK, and only on ambiguity
  one status reconciliation. Frame-cap halving now returns and retries on a
  later callback rather than issuing an unbounded series of peeks in one
  callback (`:783-810`).
- `VERIFY_PREFIX_BYTES = 256`: bounded historical seam reads.
- `STOP_MAX_CYCLES = 32`: the forced stop-loop cap.

The frame string, decoded line array (at most the configured 32 records and
65,536 wire bytes), append string, and verification read are released per
cycle. Per-generation hook state is scalars and fixed metadata; it is O(1) in
lifetime event count. The mission queue remains separately capped at 8192
lines.

### Truthful bounded STOP

At `hooks/duel-dynamic-telemetry.lua:950-986`, STOP invalidates any prior empty
observation and runs at most 32 forced cycles. It exits earlier when a peek
returns the mission-authoritative empty frame or the hook becomes stuck. Every
cycle is bounded as above. After budget exhaustion it performs one bounded p5
status reconciliation to obtain a pending count if transport still works.
Thus it terminates for success, repeated errors, unavailable transport,
frame-cap retries, and stuck storage.

The fixed STOP fields and order are unchanged. `unspooled` means:

- `0` only after an empty frame was observed during this STOP drain;
- a positive integer only when the final successful bridge status establishes
  that many mission events beyond the verified spool frontier;
- `unknown` when stuck, transport/status cannot establish the tail, or a budget
  is exhausted without a known positive count.

There is no nil-to-zero default. A successful ACK is progress, not proof that
the queue is empty; another peek is required.

The p5 stop fixture changed in one substantive place: “lost ACK response at
stop” previously asserted mission/hook cursor 1, pending/unspooled 1 after the
single cycle. It now asserts cursor 2, pending zero, and `unspooled=0` because
the bounded loop reconciles the applied ACK, drains sequence 2, and performs an
empty peek. The ordinary final-drain fixture now additionally asserts verified
zero. The existing transport-gone fixture remains `unknown`.

### Overflow and disk health

The queue already returned a distinct overflow string, so
`bridge_queue.lua` required no change. The minimal bridge helper latches an
actual sink overflow and makes subsequent peek return the stable transport
health signal `bridge queue overflow`
(`src/missions/duel-dynamic/telemetry/bridge.lua:180-182,264-273`). The hook maps
that signal to `queue-overflow category=bridge-queue-overflow`, increments
failures, and sets `stuck=true` (`hooks/...:818-823`). It does not claim that
the rejected event was delivered.

Storage failures map to explicit `spool-open-failed`, `spool-write-failed`,
`spool-size-failed`, `spool-read-failed`, or `spool-verify-failed`. Every such
result increments failures, sets `stuck=true`, and occurs before ACK. STOP then
reports `unspooled=unknown`. All callbacks, including the bounded stop loop,
remain under `protect_callback`.

### Collector STOP compatibility finding

The collector regex and field order remain compatible. Its corroborating STOP
parser calls a tail clear only for `failures="0"`, `stuck="nil"`, and
`unspooled="0"`. The hook intentionally continues to render the boolean as
`stuck=false`, not `nil`; therefore a real hook STOP line is never independently
classified clear. Collector clean-end determination continues to rest on the
spooled `mission.ended` event. All non-clear STOP combinations remain
conservative, and this slice does not alter the frozen collector.

## Clock audit and S17-p7 live procedure

`clock_now` remains `pcall(os.clock)` with fallback zero
(`hooks/duel-dynamic-telemetry.lua:523-526`). Lua 5.1 `os.clock` is process CPU
time, not elapsed wall time. On an idle or paused server, 0.25 CPU seconds can
take much longer than 0.25 wall seconds, stretching polling and backoff. If the
call fails, the constant-zero fallback allows the initial due action but then
pins `now` below a positive `next_poll_at`, suppressing all later non-forced
polls. No offline clock swap was made: `os.time` is only one-second resolution,
and the installed GameGUI environment and lifecycle behavior must be measured
before changing a 0.25-second scheduler.

S17-p7 procedure:

1. On the installed dedicated-server build, first inventory and protected-call
   each candidate available in the server-hook environment (`os.clock`,
   `os.time`, and any documented DCS/Sim wall or model-time source). Record
   build number and availability; do not assume mission-environment clocks are
   visible in GameGUI.
2. With temporary diagnostic logging, sample paired `os.clock()` and `os.time()`
   values plus the DCS log's external wall timestamp every five wall seconds.
   Record each actual poll-cycle timestamp and outcome so requested 0.25-second
   cadence can be compared with wall time. Keep diagnostic payload free of
   player identity.
3. Measure separately for at least: ten minutes with the server process idle/no
   active mission; fifteen minutes of active mission play; ten minutes paused;
   ten minutes after resume; and a continuous run of at least two hours with a
   burst followed by idle periods. Include CPU load and callback/poll counts.
4. For each interval calculate `delta(os.clock)/delta(wall)` and poll wall-time
   percentiles/max gap. Exercise failure backoff too. Confirm whether pause is
   expected to suspend callbacks independently of the selected clock.
5. Reject `os.clock` if it advances by less than 50% of wall time during active
   play, stalls for more than five wall seconds while callbacks/process remain
   alive, regresses, or causes poll gaps inconsistent with callback cadence.
   Select a replacement only from a source proven monotonic and advancing while
   the relevant callbacks run during idle, pause/resume, and long-run cases.
   If only one-second `os.time` is available, redesign/test the 0.25-second
   cadence explicitly rather than silently substituting it. Repeat the burst,
   backoff, pause/resume, and long-run measurements after any selection.

## Offline test inventory

The production mock instruments numeric reads (`read_operations`, total bytes,
and maximum single read), seek behavior, file sizes, and write return values.
New fixtures run under both known `a_do_script` return mappings:

- append-open exception/result failure, write exception, short-write disk-full
  analog, partial append, post-size mismatch, tail-byte corruption, and
  prior-boundary-byte corruption;
- a 2,001-event large spool proving no state `spool_content`, exact scalar size,
  maximum read below the lifetime file, and total read below twice spool bytes;
- a small-cap burst that overflows rather than growing without bound and emits
  explicit hook health failure;
- stop from empty, healthy pending drain, lost-ACK reconciliation, unavailable
  transport, backlog beyond a two-cycle budget, and already-stuck storage;
- protected-callback assertions for disk, overflow, transport, and existing
  injected callback exceptions.

Counts: mission bridge remains 41 tests. Production mock increased from 60
(30+30) to 80 (40+40). No source-event fixtures changed.

## Changed files and packaging

- `hooks/duel-dynamic-telemetry.lua`
- `src/missions/duel-dynamic/telemetry/bridge.lua` (required only to surface a
  latched, actual queue overflow to the hook)
- `tests/dcs/run-telemetry-bridge-prod-mock.lua`
- this evidence document

`bridge_queue.lua`, collector, web, contracts, build scripts, and the dev `.miz`
were not changed. Because `bridge.lua` is mission-side, the shipping staging
build was regenerated with `build\pack-shipping-miz.ps1`; syntax and banned
pattern gates passed, and the generated `out/.../l10n/DEFAULT/main.lua` contains
the new `queue_overflow_error` latch and peek signal. `out/` is gitignored.

## Acceptance results

All commands ran from `C:\Projects\dcs-missions` and were offline:

| Command | Exit | Result |
|---|---:|---|
| `lua5.1 tests\lua\telemetry\run-bridge.lua` | 0 | 41 passed |
| `lua5.1 tests\dcs\run-telemetry-bridge-prod-mock.lua` | 0 | 80 passed: 40 shifted + 40 fixed |
| `stylua --check .` | 0 | clean after formatting the changed Lua files |
| `Get-Command luacheck` | 1 | command not found; skipped as directed |
| `npm --prefix web run test` | 0 | 22 files, 200 tests passed |
| `npm --prefix collector run check` | 0 | format, lint, typecheck, 9 files/109 tests passed |
| `git diff --check` | 0 | no whitespace errors; Git emitted only existing CRLF normalization warnings |
| `build\pack-shipping-miz.ps1` | 0 | synthesis, banned-pattern gate, and Lua syntax gate passed |

The generated shipping `main.lua` was searched and contains all three added
overflow-latch/signal sites. Final `git status --porcelain` contains eight
lines: five modified and three untracked. Relative to the seven-line p5
baseline, only this new evidence file was added; the p6 code changes extend the
already-modified whitelisted hook, bridge, and production-mock files. The
pre-existing `.gitignore`, p5 bridge test, p5 evidence, and live evidence were
not changed by p6.

## Residuals for S17-p7

- Perform the installed-build clock measurements and select/change a clock only
  if the decision rule requires it.
- Measure real callback duration, read/write latency, burst drain behavior,
  pause/resume behavior, and multi-hour memory/spool growth.
- Run the owner-approved stock/sanitized live gate with exact artifact and hook
  hashes. No DCS, network, database, deployment, or live API action occurred in
  S17-p6.

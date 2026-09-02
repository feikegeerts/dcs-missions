# Slice 6 local collector and durable spool evidence

**Validated:** 2026-09-02

**Environment:** Node `v24.4.0`, npm `11.14.1`, Windows host running the
dedicated server, `better-sqlite3` 13, AJV 8 (JSON Schema 2020).

## Result

Slice 6 is complete. `collector/` is a local TypeScript package that tails
per-run append-only NDJSON files from the telemetry directory, validates every
complete line against `contracts/telemetry-event-v1.schema.json` plus the
semantic `event_id` rule, and inserts events into a durable SQLite spool
idempotently by `event_id`. The package makes no network calls and exposes a
`--dry-run` summary. Delivery and acknowledgement are spool-side: each run is
deliverable strictly in sequence order, and sequence 1 (`mission.started`)
must be acknowledged before any later event of that run.

## Crash consistency

Per complete line the collector orders two durability steps:

1. Spool insert (or quarantine insert) commits first. SQLite runs with
   `journal_mode = WAL`, `synchronous = FULL`, `foreign_keys = ON`, and
   `busy_timeout = 5000`.
2. The file-identity-aware byte cursor advances only after step 1 is durable.

Quarantine inserts are idempotent by a SHA-256 `quarantine_id` over the file
identity, byte offsets, and raw line bytes (`INSERT OR IGNORE`), so replaying
an already-quarantined line never duplicates the record.

Crash windows and recovery:

| Crash point | Durable state | Recovery |
|---|---|---|
| Before spool insert | nothing | full replay, no loss |
| Between spool insert and cursor advance | event | replay, deduplicated by `event_id` |
| After cursor advance | event + cursor | no replay |
| Between quarantine insert and cursor advance | quarantine row | replay, deduplicated by `quarantine_id` |

Cursor reset policy:

- The cursor stores the file `device`, `inode`, and `birthtime_ns`. A stored
  cursor whose identity does not match the file at the same path is an
  identity reset (the file was replaced); the offset returns to zero.
- If the stored offset is beyond the current file size, that is a truncation
  reset; the offset returns to zero and any replayed events deduplicate.
- One source file may contain one producer and one run. A later line from a
  different run is quarantined with code `source-run-mismatch` and the cursor
  advances (explicit cursor policy for invalid lines: quarantine, then
  advance, never stall the file).

Partial final lines are never consumed: the cursor stops at the last newline
and the remainder is re-read once its newline arrives. Lines are decoded as
UTF-8 in fatal mode, so an invalid UTF-8 line is quarantined with code
`invalid-utf8` rather than crashing the run.

Spool schema (created by `DurableSpool`):

- `spool_events` — `event_id` primary key plus
  `UNIQUE (producer_id, run_key, event_sequence)`; canonical JSON stored.
- `source_cursors` — identity, byte offset, and the pinned producer/run per
  source path.
- `quarantine` — identity, byte offsets, raw line, error code/message/details.
- `acknowledgements` — per-sequence ack rows, foreign key to `spool_events`.
- `run_delivery_state` — `acknowledged_through` per producer/run.

An event that already exists with different canonical content is a conflict
(quarantined with code `spool-identity-conflict`), never a silent overwrite;
a sequence collision under a different `event_id` is also a conflict.

## Automated verification

All commands passed on 2026-09-02:

```text
npm --prefix collector run check    Prettier, ESLint, tsc, 20 Vitest tests
npm --prefix contracts run check    32 passed (contract regression)
```

The 20 collector/spool tests cover the plan's required matrix:

- Idempotent tailing of a valid run with the cursor advanced to EOF.
- Resume from the durable cursor after a process restart.
- Partial final line left unread until its newline arrives.
- New run files handled independently.
- Truncation detected, cursor reset, replayed events deduplicated.
- Persisted identity mismatch forces a reset.
- Invalid complete line quarantined, cursor advanced, gap buffered in the
  spool until both sides exist.
- Structural (`schema-invalid`) and semantic (`semantic-invalid`) contract
  violations quarantined.
- Invalid UTF-8 line quarantined.
- A second run inside a one-run source file quarantined.
- Simulated crash before spool persistence: nothing durable, nothing
  advanced.
- Simulated crash between spool and cursor durability: replayed once,
  deduplicated as `event_id` duplicate.
- Simulated crash between quarantine and cursor durability: quarantine
  deduplicated.
- Simulated crash after cursor durability: no replay.
- Dry run reports `would_spool` / `would_quarantine` without writing spool,
  cursor, or quarantine rows.
- A changed retry of a spooled event is quarantined, not accepted as a
  duplicate.
- Out-of-order spool attempts buffer until sequence 1 exists, and
  acknowledging a non-`mission.started` sequence 1 is rejected.
- Idempotence by `event_id`, conflict on changed content, and persistence of
  events and acknowledgement state across spool restart.

## Real-data verification

Input: `C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry`
(7 files, producer `dcs-dev-68eb93a7`), consumed into a temporary state
directory that was deleted afterward. The input files were opened read-only.

- Dry run: 7 files, 145 complete lines, `would_spool: 145`,
  `would_quarantine: 0`, zero spool/cursor/quarantine mutation.
- Real pass 1: `spooled: 145`, `quarantined: 0`, 145 cursor advances.
  Per-run sequences are gapless from 1: event counts
  2, 53, 24, 9, 2, 3, 52 — exactly 145.
- Real pass 2: `complete_lines: 0`, `spooled: 0`, `duplicates: 0`,
  `cursor_advances: 0`; the per-run spool summary is byte-identical to pass 1.

Repeated consumption therefore caused neither event loss nor duplicate spool
records on real producer output.

## Known limitations (v1)

- Single collector process is assumed. Two concurrent collectors could race
  between the spool inspection and insert; the unique constraints make that a
  hard error rather than corruption, and a re-run deduplicates.
- `--dry-run` creates an empty state database when none exists, but never
  writes rows; it reports outcomes against the current spool content.
- One durable cursor commit per processed line. Fine at current file sizes;
  batchable per file if runs grow.
- A source file deleted while a pass is in flight aborts that pass with an
  error; the next pass resumes from the durable cursor without loss.

## Not included (later slices)

No network access, no API credential, and no delivery transport. Slice 7
builds the web shell and raw-event persistence; Slice 8 delivers spool
records to the API and acknowledges them per event.
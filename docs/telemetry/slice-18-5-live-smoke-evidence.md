# Slice 18.5 — live smoke evidence (real hook → spool → service → production)

Date: 2026-09-08 (all timestamps UTC; local on this host is UTC+2). Scope:
the owner-authorized S18.5-a live smoke — a real stock dedicated server with
the S17 production telemetry hook producing NDJSON into the real spool dir,
collected by the persistent collector service (S18.5-a, 5 s cadence),
delivered over authenticated HTTPS to the production ingest API
(`https://dcs-missions.vercel.app`), then owner-approved cleanup of the test
run from Neon. Performed by the local orchestrator session only (credential
holder); no worker involvement; no credentials passed to any worker, prompt,
repo file, or log.

Authorizations (2026-09-07, recorded in
`docs/telemetry/slice-18-5-near-live-plan.md`): dedicated server MAY be used
for live testing; production ingest of live test runs approved; test-run
database cleanup after testing approved. No deployment, no commit/push, no
other database write, and no change to `MissionScripting.lua` (hook works in
the stock sanitized environment — see preconditions).

## Preconditions (verified before the run)

- Active hook in `C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Scripts\Hooks\`
  = the S17 **production** hook `duel-dynamic-telemetry.lua` (bridges via
  `a_do_script`; the other two project hooks are present only as
  `.disabled-*` copies). It requires **no** de-sanitized environment.
- Server `D:\DCS World Server\Scripts\MissionScripting.lua` confirmed **stock**
  (the `sanitizeModule('os'|'io'|'lfs')` lines active). The smoke started and
  finished with that file byte-untouched; the backups
  (`.orig` / `.telemetry-dev-backup`) were not created or modified by this
  smoke.
- `TELEMETRY_INGEST_TOKEN` present in `web/.env.local` (48-char value,
  double-quoted in the file because the value contains `#` — see
  `docs/telemetry/unattended-test-loop.md` § "Auth gotcha (fixed)").
- Dedicated server running (`D:\DCS World Server\bin\DCS_server.exe`, no
  args; WebGUI port 8088).

## Mission run (real dedicated server + production hook)

A temporary controller hook `zz-s18-5-live-smoke-load.lua` (S17-p4 pattern)
was installed and the server restarted (old PID 12636 → new PID 41616). On
startup the controller loaded `C:\Projects\dcs-missions\out\duel-dynamic.miz`
(the self-contained shipping artifact) via `net.load_mission`, called
`setPause(false)`, and self-stopped the mission after 300 s.

| Time (UTC) | Event |
|---|---|
| 06:33:57Z | Server restarted; it auto-restored its previous mission (`duel-dynamic-shipping-test.miz`) before the controller hook ran. That generation-1 side run produced `run-20260908T063357Z-7f527fa9.ndjson` (1 event, no clean end — it was superseded mid-run by `net.load_mission`). It was **not** part of the smoke input (see below) and remains in the local spool dir as local data. |
| 06:34:25Z | Controller hook loaded the shipping mission (`net.load_mission`) + `setPause(false)`. Target run `run-20260908T063421Z-73faa7a1` started. |
| 06:34:21Z | Target run file first timestamp (run key). |
| 06:39:25Z | Controller's 300 s `stopMission` fired; the hook emitted `mission.ended` (reason `mission-end-observed`) and the STOP health line (`failures=0`, `stuck=false`, `unspooled=0`) — a clean stop. |

Target run file (real spool dir
`C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry\`):

- `run-20260908T063421Z-73faa7a1.ndjson`, producer `dcs-server-3cd14b8a`
- 5,087 bytes, 11 newline-terminated events, `event_sequence` 1..11 with no
  gaps: `mission.started` + 9 × `mission.heartbeat` + `mission.ended`
- SHA-256 `E0473003545245E6E6314BF39606591368400A78B22AF8F424810B30A32EF1E1`
- Map Syria, mission `duel-dynamic` (shipping artifact identity).

## Delivery — attempt 1: 401 incident (S18.5-b circuit exercised live)

Setup: an **isolated temp input dir**
(`C:\Users\g_for\AppData\Local\Temp\opencode\s18-5-live-smoke\input`) received
a byte-identical copy of the target run file (SHA-256 match verified), so
exactly the one authorized test run could reach production — the generation-1
side run was never a delivery candidate. Fresh isolated state dir. Service:
`node collector/dist/src/service.js --input <inDir> --state <stateDir>
--url https://dcs-missions.vercel.app`, token via `TELEMETRY_INGEST_TOKEN`
env only (never a CLI argument, never printed).

Attempt 1 started 06:45:25Z. Collection on the first pass: 11 events spooled,
cursor advanced to 5087/5087, tail state `clear`. Delivery then failed twice
with `HTTP 401: authorization rejected`. **Root cause:** the first smoke
script parsed `web/.env.local` and passed the raw quoted value (including the
surrounding double quotes) as the bearer token. The value is quoted in the
file (required for Next's dotenv inline-`#` handling), so any other consumer
must strip the quotes. This is a parser bug in the smoke script, not a
service or API defect.

The S18.5-b delivery-wide circuit behaved exactly as specified under the live
401s — persisted state recovered from the SQLite WAL page images of the smoke
state dir (`state\collector.sqlite3-wal`, kept as evidence):

- Circuit singleton row: opened 06:45:25.949Z; persisted
  `next_probe_at` 06:46:34.187Z; after the second 401 (a half-open probe
  fired at 06:46:35.910Z, past its deadline, and also received 401) the
  deadline doubled to 06:48:22.314Z; `last_error` =
  `HTTP 401: authorization rejected`.
- Per-run retry-state row (producer + run key): `last_attempt_at`
  06:45:25.950Z, then 06:46:35.910Z, with the same redactable 401 error —
  two attempts total, transient (not a permanent rejection).
- `acknowledged_through` stayed 0; no event was partially acknowledged.
- **Collection continued on every ~5 s pass during the circuit**
  (files seen, zero re-spooling, zero duplicates) and the service status
  honestly reported the open circuit and the undelivered prefix — the
  pinned S18.5-b requirement that a 401/403 blocks delivery delivery-wide
  while collection never stops.

Note on log retention: attempt 1's stdout was not separately preserved —
attempt 2 was launched onto the same log path and truncated it. The 401
evidence above is the persisted WAL content, not a log quote.

## Delivery — attempt 2: half-open recovery, full acceptance

The smoke script was fixed (quote-strip before exporting the env token;
`service-smoke.ps1` in the evidence dir) and the service restarted at
06:49:18.571Z (PID 40768 per `owner.json`) **against the same input and
state dirs** — no spool rebuild, no data re-spooling. The circuit was still
open with `next_probe_at` 06:48:22.314Z (already in the past), so the first
delivery pass issued exactly one half-open probe:

- HTTP 200, one batch seq 1..11: **11/11 accepted, 0 duplicates, 0 rejected**;
  `acknowledged_through` = 11; circuit **closed** (`probe_attempted: true`,
  `open: false`, probe deadline cleared).
- Subsequent delivery passes had nothing to deliver (`attempts: 0`);
  collection passes confirmed the run complete (11/11 acked,
  `next_deliverable_sequence: null`).
- Time from attempt-2 start to production-acknowledged delivery: ~5.1 s
  (one delivery cycle).

Final service status (`status-final.json`, captured before stopping the
service): lock port 33713 held (PID 40768; canonical input/state/schema
bound); spool run 11/11 acknowledged; `delivery_health.lastSuccessAt`
06:49:23.675Z with `lastError: null`; `delivery_retry_state: []`;
`delivery_circuit: null`; `lifecycle_outbox: []`; source tail `clear`
(observed 5087 = durable 5087).

## Production verification

`GET /api/telemetry/runs` (public read) then
`GET /api/telemetry/runs/run-20260908T063421Z-73faa7a1` (detail;
`prod-run-detail.json`):

- `status: ended`, `eventCount: 11`, `firstSequence: 1`, `lastSequence: 11`
- `missionName: duel-dynamic`, `missionVersion: 1`, `mapName: Syria`
- `runClassification: historical`, `valuationCatalogue: ordnance` v1
- `createdAt` / `updatedAt` 2026-09-08T06:49:20.471Z

No other production runs were touched (baseline before delivery: count=2).

## Cleanup (owner-approved)

The production API has no DELETE endpoint (`runs/[runId]` exposes GET +
POST-abort only), so the test run was removed directly from Neon — the
owner-approved path. `cleanup-prod-run.cjs` (kept as evidence) used
`@neondatabase/serverless` v1.1.0 with the quote-stripped `DATABASE_URL`, a
fixed table whitelist, and **one** `sql.transaction` over:
`telemetry_events`, `mission_runs`, `run_participants`,
`ordnance_expenditures`, `asset_losses`, `kill_attributions`,
`assist_attributions` (all keyed `producer_id` + `run_key`).

- Before: `telemetry_events` 11, `mission_runs` 1, all projections 0.
- After: all 0 for the producer/run pair; `mission_runs` total back to 2.
- API verified: `/api/telemetry/runs` count=2 (only the two pre-existing
  baseline runs `run-20260907T174608Z-39c240d0` and
  `run-20260907T185621Z-2732b025`), and the deleted run's detail now returns
  404.

## Teardown (verified)

- Temporary controller hook `zz-s18-5-live-smoke-load.lua` removed; the hooks
  dir is back to its 4 pre-smoke files (`duel-dynamic-telemetry.lua`, the two
  `.disabled-*` copies, `TacviewGameGUI.lua`).
- `MissionScripting.lua` still stock (verified after teardown).
- Dedicated server left running (PID 41616, WebGUI 8088), no active mission.
  State change to report: the server's "last mission" is now
  `C:\Projects\dcs-missions\out\duel-dynamic.miz` (stopped) instead of the
  prior `duel-dynamic-shipping-test.miz` (stopped) — a restart auto-restores
  the new one.
- The smoke service process was hard-stopped after all work was confirmed
  (acceptable for the smoke; the graceful bounded SIGINT path is covered by
  the offline S18.5-a tests). The isolated temp input/state dirs and all
  logs/scripts are kept under
  `C:\Users\g_for\AppData\Local\Temp\opencode\s18-5-live-smoke\` (input copy,
  state dir + `collector.sqlite3` + WAL, `service-stdout.log`,
  `service-stderr.log`, `status-final.json`, `prod-run-detail.json`,
  `service-smoke.ps1`, `poll-run.ps1`, `probe-driver.cjs`,
  `cleanup-prod-run.cjs`).
- The generation-1 side run file remains in the real spool dir. Per the
  recorded S18.5-b assumption (manual prune requires a clean end or a sent
  clear-tail lifecycle record) it is intentionally left un-prunable, matching
  the owner's unbounded-retention decision.

## Acceptance table

| Exit concern | Evidence |
|---|---|
| Real production hook works in the stock sanitized environment | Target run file + clean STOP health line, with `MissionScripting.lua` verified stock before and after |
| NDJSON spool + contract compliance | 11 events, gapless seq 1..11, SHA-256 recorded; production ingest accepted all 11 with 0 rejections |
| Persistent single-owner service, ~5 s cadence (S18.5-a) | Service stdout collection/delivery lines; ownership lock port 33713 held for the process lifetime; isolated input/state binding in `owner.json` |
| Fair + durable delivery, honest state under auth failure (S18.5-b) | WAL-persisted circuit row (open 06:45:25.949Z → probe 06:46:34.187Z → doubled 06:48:22.314Z) + per-run retry rows; `acknowledged_through` 0 throughout; collection continued; no partial acknowledgment |
| Half-open recovery on restart against the same state | Attempt 2 first pass: single probe, 11/11 accepted, 0 duplicates, circuit closed (`probe_attempted: true`) |
| Production ingest end-to-end | `prod-run-detail.json` (status ended, 11 events, seq 1..11); ~5.1 s from attempt-2 start to acknowledged delivery |
| No loss / no duplication on the failure path | Exactly 11 rows existed in production at cleanup time (before-counts); 0 duplicates on delivery |
| Cleanup + baseline restored | One-transaction delete, before/after counts, API count=2 + run detail 404 |

## Residuals (documented, not failures)

- **Live-append tail not exercised live:** the target file was complete
  before the service started, so the smoke validated delivery of a closed
  run. The incremental-append path (partial-line cursor behavior, tail state
  transitions under a live writer) remains covered by the offline S18.5-a /
  S18.5-b test suites (partial-write, bounded read-window, tail-state tests),
  not by this live run.
- **Browser/dashboard freshness chain** (S18.5-d) was not live-verified in a
  browser here; live-browser acceptance is S18.5-e (owner-gated).
- **Service install / operation** (S18.5-c: resident service identity, state
  dir ownership, any Neon-side work) and the full acceptance pass (S18.5-e,
  incl. p50/p95 healthy-lag agreement) remain owner-gated.
- **No DELETE API:** test-run cleanup required a direct (approved) Neon
  write; an owner-gated API-level delete could be a follow-up if future
  cleanup is expected to be routine.
- **Server last-mission state** changed from
  `duel-dynamic-shipping-test.miz` to `out\duel-dynamic.miz` (both stopped);
  next server restart auto-restores the shipping artifact.
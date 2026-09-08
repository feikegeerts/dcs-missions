# Dev-AI live test — full record (TEST_COMBAT dev mission → spool → collector → production → cleanup)

Date: 2026-09-08 (all timestamps UTC; local on this host is UTC+2). Scope: the
owner-authorized (2026-09-08: "approve you spinning up the dev server to do a
live test with AI bots so you can also slot in the chain wherever you see
fit") dev-server AI-bot live telemetry run, slotted between the S18.5 live
smoke and the S17-p5/p6 implementation chain. Two-phase collector service
against the **real** spool dir: phase A drains the historical backlog into a
local mock ingest double (live drill of the large-backlog acceptance row);
phase B (same state dir, production URL) delivers the fresh runs to
production, then owner-approved cleanup of the test runs from Neon.
Performed by the local orchestrator session only (credential holder); no
worker involvement; no credentials in any worker prompt, repo file, or log.

Authorizations (cumulative, recorded in
`docs/telemetry/slice-18-5-near-live-plan.md`): ~5 s collection cadence;
dedicated server for live testing; production ingest of live test runs;
post-test DB cleanup of test runs; unbounded local spool retention (no
auto-prune).

## Preconditions (verified before the run)

- Dev `.miz` loader in place:
  `C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Missions\duel-dynamic.miz`
  (13 KB; MISSION START →
  `assert(loadfile([[C:\Projects\dcs-missions\src\bootstrap.lua]]))()`).
  `src/bootstrap.lua` sets `_G.TELEMETRY_DEVELOPMENT_ENABLED=true` +
  `_G.TEST_COMBAT_ENABLED=true`.
- `D:\DCS World Server\Scripts\MissionScripting.lua` hash-verified **stock**
  (`39066C8CED213B447B03AF5A25ECA63BF15BE71179D53A14EB13312DE07A542D`) before
  the swap; dev backup (`.telemetry-dev-backup`,
  `60D78C47957984632F042F3810A1F68B6BFFF0F0833492769EFBC2A39E9912A2`)
  hash-verified, then installed (dev .miz needs os/io/lfs de-sanitized:
  `loadfile` + `io.open` + `lfs.writedir` in bootstrap). Restored to stock in
  teardown (verified, see below).
- Production hook `duel-dynamic-telemetry.lua` active in
  `C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Scripts\Hooks\` (the other
  two project hooks present only as `.disabled-*` copies).
- `TELEMETRY_INGEST_TOKEN` in `web/.env.local` (48-char value, double-quoted
  because it contains `#`; every consumer strips the quotes — the smoke's 401
  root cause; this test stripped them, no auth failures occurred).
- Real spool dir
  `C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry\` held 78
  historical run files (unbounded retention from earlier slices).

## Mission run (dev AI combat, unattended)

Temporary controller hook `zz-s18-5-dev-ai-load.lua` (S17-p4 pattern)
installed; `MissionScripting.lua` swapped stock→dev (both hash-verified);
server restarted (PID 9608, 08:05:57Z). On startup the server auto-restored
its last clean-persisted mission, `duel-dynamic-shipping-test.miz` — a
shipping-class artifact — whose production-hook transport wrote the
generation-1 side run.

| Time (UTC) | Event |
|---|---|
| 08:06:31Z | Auto-restored `duel-dynamic-shipping-test.miz`; production hook wrote side run `run-20260908T080631Z-1f99b738` (1 event: `mission.started`, producer `dcs-server-3cd14b8a`, class `historical`). Superseded mid-run by the dev-mission load. |
| 08:06:53Z | Controller loaded the dev `.miz` via `net.load_mission`; the dev mission's **dev file sink** started target run `run-20260908T080653Z-50a9ea69` (producer `dcs-dev-68eb93a7`). The hook logged `bridge-runtime-missing generation=2` for the dev mission (its transport bridge was unused by design in the dev env) and references a phantom run key `run-20260908T080650Z-3ca57da0` with zero events — harmless, honest hook state; the real events went to the file sink. |
| ~48.5 s sim | `ordnance.fired` — AIM-120C by Bandit-1 (`Springfield11`), TEST_COMBAT engagement at 15 nm (both sides F/A-18C). |
| ~66.2 s sim | `asset.hit` on TestCombat-Blue. |
| 67.261 s sim | `asset.kill-reported` (killing blow, event seq 8). |
| ~67.3 s sim | `asset.dead` (TestCombat-Blue#001-01). |
| 08:11:53Z | Controller's 300 s `stopMission`; `mission.ended` (reason `mission-end-observed`, seq 17). Post-stop hook polling lines `hook-error transport ... category=mission-eval-failed` (08:11:55–08:18:44) = hook polling a stopped mission — harmless dev-env noise; useful S17-p6 "truthful stop" evidence. |

No collector service ran while the mission wrote (phase A service had been
stopped before the restart; phase B started ~11 min after the run ended) —
see Residuals.

Target run file (real spool dir):

- `run-20260908T080653Z-50a9ea69.ndjson`, 10,926 bytes, producer
  `dcs-dev-68eb93a7`
- 17 newline-terminated events, `event_sequence` 1..17 gapless:
  `mission.started` (map Syria, mission `duel-dynamic` v1,
  `run_classification: "test"`) + 2 × `asset.spawned` + 9 ×
  `mission.heartbeat` + `ordnance.fired` + `asset.hit` +
  `asset.kill-reported` + `asset.dead` + `mission.ended`
- **First live run with the full S12–S14 telemetry stack** (expenditures +
  hits/kills + losses).

## Contract checks (against `contracts/telemetry-event-v1.schema.json`)

- All 8 event types present in the run are members of the contract
  `event_type` enum (14 allowed values).
- `producer_id` = `$ref #/$defs/token` (pattern
  `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`) — `dcs-dev-68eb93a7` matches.
- `payload` is a free-form object, so `run_classification: "test"` is valid.
- Live enforcement: production ingest accepted all 17 events with 0
  rejections (and all 1,155 phase-A events).

## Phase A — 78-run historical backlog drained into a local mock

Mock ingest double `mock-ingest.cjs` on 127.0.0.1:8089 (faithful 200 contract
`{results:[{event_id,status,reason?}],summary:{accepted,duplicates,rejected}}`,
event_id dedupe; ignores auth). Service
`node collector/dist/src/service.js --input <real spool> --state <fresh
state dir> --url http://127.0.0.1:8089`, **dummy** token (env only).

- 78 runs / 1,155 events spooled and delivered; mock log: 79 POSTs, all
  accepted, 0 duplicates, 0 rejected.
- Acknowledged 1,150/1,155 at 10:03:17 local → **1,155/1,155 at 10:03:22
  local**; circuit closed throughout; 0 node processes left.
- Live drill of the S18.5-b acceptance row "large historical backlog, fair
  current-run delivery": the backlog drained without starvation artifacts;
  the state dir now acks every historical run, so phase B (same state dir)
  can deliver **only** new runs to production.

## Phase B — fresh runs delivered to production

Service `node collector/dist/src/service.js --input <real spool> --state
<same state dir> --url https://dcs-missions.vercel.app`, real token
quote-stripped into `TELEMETRY_INGEST_TOKEN` env only (length 48; never a CLI
argument, never printed). Started 08:22:49Z (PID 13492).

- Production baseline before delivery: count=2 (the two pre-existing runs
  `run-20260907T174608Z-39c240d0`, `run-20260907T185621Z-2732b025`).
- First delivery pass (08:22:56Z): target run `acknowledged_through` 17/17
  (`delivery_health.lastSuccessAt` 08:22:56.222Z); side run 1/1
  (08:22:56.228Z). Production count 2 → 4.
- Final service status (captured before hard-stop): both new runs fully
  acknowledged; source tails `clear` (durable offset = observed size);
  0 quarantined, 0 incidents; delivery circuit closed; `delivery_retry_state`
  empty; `lifecycle_outbox` empty; 0 abort signals; last delivery pass
  totals: 72 runs complete / 8 incomplete (incomplete = runs lacking a
  clean-end or clear-tail observation — by design not prunable, retained per
  unbounded retention). 0 node processes left.
- Lifecycle note (honest behavior, live-observed): the service was not bound
  to `dcs.log` (`TELEMETRY_DCS_LOG` unset; `defaultDcsLogTextProvider`
  returns `""`), so no STOP/handshake observations were recorded and no
  clear-tail lifecycle POST was sent. The side run (1 event, no
  `mission.ended`) therefore stayed `status=active` in production — absence
  of evidence did not fabricate a clean end (S16-p8/S18.5-b requirement,
  now live-observed in the negative case).

## Production verification (public read API)

Target run detail (`GET /api/telemetry/runs/run-20260908T080653Z-50a9ea69`):

- `status: ended`, `eventCount: 17`, `firstSequence: 1`, `lastSequence: 17`
- `missionName: duel-dynamic`, `missionVersion: "1"`, `mapName: Syria`
- `runClassification: test`, `valuationCatalogue: ordnance` v1
- `startedAt 2026-09-08T08:06:53.000Z`, `endedAt 2026-09-08T08:11:54.000Z`,
  `createdAt/updatedAt 2026-09-08T08:22:53.923Z`

`/events` (17 rows, types as listed above). Projections:

- **`/kills`** — 1 kill, 0 assists: killer `Bandit-1-01` (red,
  `FA-18C_hornet`, asset key `bandit-1.u1.g1`) → target
  `TestCombat-Blue#001-01` (blue, `FA-18C_hornet`,
  `testcombat-blue-001.u1.g1`); weapon `AIM_120C`;
  `killingBlowSimTime 67.261`; killing blow = event seq 8 (first
  `asset.kill-reported` for the incarnation); the only `asset.hit` (seq 7)
  was by the primary killer, so per the owner-approved S14 assist rule it is
  excluded — assists correctly empty.
- **`/losses`** — count 1: `testcombat-blue-001.u1.g1`, `FA-18C_hornet`,
  blue, catalogue `ordnance` v1, `unitCostCents 2900000000` ($29 M), source
  seq 9 (`asset.dead`).
- **`/expenditures`** — count 1: `AIM_120C`, `unitCostCents 105000000`
  ($1.05 M), participant callsign `Springfield11` (Bandit-1, red
  `FA-18C_hornet`), source seq 5 (`ordnance.fired`).

Side run detail: 1 event, `status: active`, class `historical` (see
lifecycle note). The first side-run detail fetch inside the delivery script
returned a transient 404 (read-after-write race immediately after the POST
commit); the re-fetch returned 200 — recorded, not a defect.

## Cleanup (owner-approved)

No DELETE API exists, so the two test runs were removed directly from Neon —
the owner-approved path (same pattern as the smoke). `cleanup-prod-runs.cjs`
(kept as evidence) used `@neondatabase/serverless` v1.1.0 with the
quote-stripped `DATABASE_URL`, a fixed 7-table whitelist
(`telemetry_events`, `mission_runs`, `run_participants`,
`ordnance_expenditures`, `asset_losses`, `kill_attributions`,
`assist_attributions`), and **one** `sql.transaction` over both
producer/run pairs.

- Before: target run 17 `telemetry_events` + 1 `mission_runs` + 1
  `ordnance_expenditures` + 1 `asset_losses` + 1 `kill_attributions`; side
  run 1 event + 1 run row. All other tables 0 for both.
- After: 0 leftover rows for both pairs; `mission_runs` total back to **2**.
  (Neon `DELETE` affected-row counts come back empty — known quirk;
  before/after counts are authoritative.)
- API verified: `/api/telemetry/runs` count=2 (only the two pre-existing
  baseline runs); both deleted run details return 404.

## Teardown (verified)

- `MissionScripting.lua` restored to **stock** from `.orig`; hash re-verified
  `39066C8...542D` after restore and again after the final restart.
- Controller hook `zz-s18-5-dev-ai-load.lua` removed.
- Server's last mission restored: the server auto-restores its last
  clean-persisted mission on restart, and the test's force-kills had left
  that persisted value at `duel-dynamic-shipping-test.miz` (an earlier
  shipping-class artifact — it works in the stock env; two auto-restore side
  runs prove its hook transport). A temporary `zz-s18-5-restore-load.lua`
  controller (S17-p4 pattern, 90 s) loaded `C:\Projects\dcs-missions\out\duel-dynamic.miz`
  (the shipping artifact) on the restarted server (old PID 9608 → new PID
  11688, 08:29:40Z) and cleanly stopped it at 08:32:06Z. That restore run is
  an extra stock-env data point: `run-20260908T083033Z-6be5bd40` (4 gapless
  events, `mission.ended` reason `mission-end-observed`) with hook STOP line
  `STOP generation=2 spooled=4 failures=0 stuck=false unspooled=0`. The
  auto-restore side run of that restart is
  `run-20260908T083013Z-5e361c16` (1 event). The restore controller was then
  removed.
- Hooks dir back to its 4 pre-test files
  (`duel-dynamic-telemetry.lua`, the two `.disabled-*` copies,
  `TacviewGameGUI.lua`).
- Dedicated server left running (PID 11688, WebGUI 8088), no active mission;
  in-process last mission = `out\duel-dynamic.miz` (stopped). The persisted
  config value follows the next clean server shutdown; both candidate
  auto-restore missions are shipping-class and verified working in the stock
  environment.
- 0 node processes left. All scripts/logs/state kept under
  `C:\Users\g_for\AppData\Local\Temp\opencode\s18-5-dev-ai-test\`
  (`phase-a.ps1`, `phase-a-result.log`, `phase-b-restart.ps1`,
  `phase-b-deliver.ps1`, `phase-b-deliver.log`, `mock-ingest.cjs` + log,
  `service-a/b-stdout.log`, `status-b-final.json`, `prod-*.json`,
  `cleanup-prod-runs.cjs`, the `state` dir with all 80 runs acked,
  controller hook source).

## Acceptance table

| Exit concern | Evidence |
|---|---|
| First live run with the full S12–S14 combat stack | 17-event target run (fired/hit/kill-reported/dead) + production projections: 1 kill (correct killer/victim/weapon/killing-blow seq, 0 assists per S14 rule), 1 loss ($29 M F-18C, source seq 9), 1 expenditure ($1.05 M AIM-120C, Springfield11, source seq 5) |
| `run_classification: "test"` end-to-end | mission.started payload → production run detail `runClassification: test` |
| Dev producer identity + dev file sink transport | producer `dcs-dev-68eb93a7` accepted by contract token pattern + production ingest (0 rejections) |
| Large historical backlog, fair delivery (S18.5-b row) | Phase A: 78 runs / 1,155 events drained to mock, 79 POSTs all accepted, 1,155/1,155 acked, circuit closed |
| Same-state-dir isolation of new runs | Phase B baseline count=2; only the 2 new runs reached production |
| No false clean end (S16-p8/S18.5-b) | Side run stayed `active` with no lifecycle evidence (outbox empty, no `TELEMETRY_DCS_LOG` binding) |
| Contract compliance | Schema probe (event-type enum, token pattern, free-form payload) + live 0-rejection ingest |
| Cleanup + baseline restored | One-transaction delete, before/after counts, API count=2 + both details 404 |
| Teardown to pre-test resting state | Stock `MissionScripting.lua` (hash-verified), hooks dir = 4 pre-test files, shipping-class last mission, clean hook STOP line from the restore run, 0 stray processes |

## Residuals (documented, not failures)

- **Live-append tail still not exercised live:** both live deliveries (smoke +
  this test) were closed-form (run file complete before the service
  started). The incremental-append path (partial-line cursor, tail-state
  transitions under a live writer) remains covered by the offline S18.5-a /
  S18.5-b suites, not by a live run.
- **S16-p8 lifecycle clear-tail POST not exercised live:** no `dcs.log`
  binding in this service run (outbox stayed empty). The negative case
  (no evidence → no abort) was live-observed; the positive case (STOP line →
  clear-tail POST → run abort) needs a service run with `TELEMETRY_DCS_LOG`
  bound — fold into S17-p7 or S18.5-e.
- **Spool/state interaction (operator note):** the two cleaned test runs'
  spool files remain locally (unbounded retention). The Phase A/B state dir
  acks all 80 pre-restore runs, so a service continued on that state dir
  will deliver only new runs. A service started with a **fresh** state dir
  would re-ingest the whole spool — including the two cleaned test runs
  (whose production rows were deleted and would be recreated) and the two
  teardown by-product runs (`run-20260908T083013Z-5e361c16`,
  `run-20260908T083033Z-6be5bd40`, class `historical`, currently local-only
  and unacked anywhere). The S18.5-c production service should continue on
  the existing state dir (or a migration of it); owner decision if the two
  teardown by-product runs should be kept or cleaned once delivered.
- **Dev-env hook noise:** gen-2 `bridge-runtime-missing` phantom run key +
  post-stop `mission-eval-failed` polling lines are harmless in the dev env
  (file sink is the designed transport) and are evidence input for
  S17-p5/p6 (ambiguous-ACK reconciliation, truthful stop).
- **S17-p4 gate** (stock + shipping + client participation) remains
  waiting-owner for the client part; the "AI package behavior" residual is
  addressed by this unattended AI-vs-AI run (dev env).
- **Browser/dashboard chain** (S18.5-d) not live-verified in a browser
  (S18.5-e, owner-gated, needs p50/p95 agreement).
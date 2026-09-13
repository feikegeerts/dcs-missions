# Slice 18.5-e integrated telemetry acceptance evidence

**Validated:** 2026-09-13 (local 23:08–23:35 / 21:08–21:35 UTC)

**Environment:** DCS World dedicated server `2.9.29.27278`
(`D:\DCS World Server`), Windows host, persistent
`DcsTelemetryCollector` Windows service (automatic start, 5000 ms poll
interval, lock port 24317, state under `C:\Users\g_for\dcs-telemetry-service\`),
production `https://dcs-missions.vercel.app` (Neon).

**Method:** two unattended legs per `unattended-test-loop.md`, with the
documented Slice-6 collector CLI passes **replaced by the already-running
persistent service** — no manual `collector/cli.js` pass was made at any
point. Both legs were torn down afterwards and the production test runs were
deleted (see "Production cleanup").

## Result

Slice 18.5-e acceptance passes:

1. **Dev leg** — dev writer path: 18 gapless events spooled by the mission,
   auto-collected and auto-delivered to production by the persistent service;
   derived projections (kills, losses, expenditures) materialized
   server-side with no manual intervention; per-event source→production lag
   p50 7.670 s / p95 8.962 s / max 9.148 s.
2. **Hook (shipping) leg** — production path under a **stock**
   `MissionScripting.lua`: the GameGUI bridge hook completed a full
   generation — `handshake-ok`, 11 `drained` lines (one per sequence),
   bounded stop-drain ending `STOP ... unspooled=0` (mission-authoritative
   empty peek) — and the run reached production complete and `ended`.
3. Production was restored to the owner's exact 2-run baseline.

## Production baseline (before)

Exactly two runs, both `ended`, both producer `dcs-dev-68eb93a7`:

| runKey | events | window (UTC) |
|---|---|---|
| `run-20260913T193734Z-725dd339` | 76 | 19:37:34 → 19:59:25 |
| `run-20260913T193654Z-338553fb` | 2 | 19:36:54 → 19:37:16 |

## Leg 1 — dev writer path (`run-20260913T210928Z-3af96fc8`)

**Setup:** `TEST_COMBAT_ENABLED = true` in `src/bootstrap.lua`; de-sanitized
`MissionScripting.lua` (hash `60D78C47…`, the `.orig` stock file untouched);
temporary `zz-dev-telemetry-load.lua` hook with `stopAfterSeconds = 300`;
server started with the exact original command line.

**Acceptance lines (dcs.log, UTC):**

```
21:09:27.415  *** MOOSE INCLUDE END ***
21:09:27.428  [duel-dynamic][telemetry] started producer=dcs-dev-68eb93a7
              run=run-20260913T210928Z-3af96fc8 sequence=1
21:09:27.693  DEV-TELEMETRY: dev mission loaded; auto-stop in 300 s
21:09:27.693  DEV-TELEMETRY: setPause(false) ok=true
21:14:27.694  DEV-TELEMETRY: stopMission called ok=true   (exactly +300.0 s)
21:14:27.717  [duel-dynamic][telemetry] persisted mission.ended sequence=18
```

**Events (production, 18/18, gapless 1–18):** `mission.started` (1), 2×
`asset.spawned` (2–3), `ordnance.fired` (4), `mission.heartbeat` (5),
`asset.hit` (6), `ordnance.fired` (7), `asset.kill-reported` (8),
`asset.dead` (9), `mission.heartbeat` ×7 (10–17), `mission.ended` (18).
Local spool file: 11 955 B, exactly 18 lines, last line `mission.ended`.

**Derived projections (public API, no manual passes):**

- kills: 1 attribution — `Bandit-1-01` (red, FA-18C) killed
  `TestCombat-Blue#001-01` (blue, FA-18C), weapon `AIM_120C`, killing blow
  sim 51.081 s, source event 8; assists: 0.
- losses: 1 — `testcombat-blue-001.u1.g1`, FA-18C, catalogue
  `ordnance` v2, $29 000 000.00 (29 000 000 000 cents), source event 9.
- expenditures: 2 — AIM-120C AMRAAM @ $1 050 000.00 each (catalogue
  `ordnance` v2), source events 4 and 7.

All three are consistent with the raw event stream.

**Source→production lag** (`createdAt − wallTime`, all 18 events):

| n | min | p50 | p95 | max |
|---|---|---|---|---|
| 18 | 4.352 s | 7.670 s | 8.962 s | 9.148 s |

Consistent with the service's 5000 ms poll interval plus Vercel ingest
latency.

**Log observations:** no `frame-stuck`, `queue-overflow`,
`handshake-failed`, or `transport-unavailable`. Two expected entries:
`bridge-runtime-missing generation=1` (dev mode —
`initShippingTelemetry` is disabled while development telemetry is enabled,
so `_G.duel_telemetry_bridge` never exists; the hook retries by design and
logs once) and one shutdown-time `hook-error transport
category=mission-eval-failed` at 21:14:28.944 (final mission eval during
environment teardown — same transient the owner's own baseline run logged).

## Leg 2 — production hook path (`run-20260913T211704Z-4c0c584b`)

**Setup:** stock `MissionScripting.lua` restored and hash-verified
(`39066C8C…`) **before** this leg; temporary hook targeting the owner's
shipping artifact `duel-dynamic-shipping.miz` (SHA `1B15303E637A2404…`,
in-mission code verified: `TELEMETRY_SHIPPING_ENABLED = true`, no
`TELEMETRY_DEVELOPMENT_ENABLED`, zero `TEST_COMBAT` occurrences, `Team
kills:` header present). `stopAfterSeconds = 300`.

This leg exercises the production configuration: sanitized mission
environment, so the mission cannot write files — the bridge queue
(`_G.duel_telemetry_bridge`) plus the GameGUI hook are the **only** spool
path.

**Acceptance lines (dcs.log, UTC):**

```
21:17:02.260  DEV-TELEMETRY: non-target mission loaded; loading shipping
              mission instead        (boot auto-loaded the dev loader miz)
21:17:02.506  TELEMETRY_BRIDGE_HOOK: bridge-runtime-missing generation=1
21:17:02.506  TELEMETRY_BRIDGE_HOOK: STOP generation=1 spooled=0 ... stuck=false
              (dev loader is a no-op under stock scripting: loadfile-based
               bootstrap cannot run; generation closed cleanly, 0 spooled)
21:17:07.020  *** MOOSE INCLUDE END ***
21:17:07.272  DEV-TELEMETRY: shipping mission loaded; auto-stop in 300 s
21:17:07.272  DEV-TELEMETRY: setPause(false) ok=true
21:17:07.279  TELEMETRY_BRIDGE_HOOK: handshake-ok generation=2
              run=run-20260913T211704Z-4c0c584b producer=dcs-server-3cd14b8a
21:17:07.534  TELEMETRY_BRIDGE_HOOK: drained generation=2 from=1..1 count=1
21:22:07.275  DEV-TELEMETRY: stopMission called ok=true   (exactly +300.0 s)
21:22:07.291  [duel-dynamic][telemetry] persisted mission.ended sequence=11
21:22:07.332  TELEMETRY_BRIDGE_HOOK: drained generation=2 from=11..11 count=1
21:22:07.332  TELEMETRY_BRIDGE_HOOK: STOP generation=2 spooled=11 ...
              failures=0 stuck=false unspooled=0
```

Eleven `drained` lines, one per sequence 1–11 (gapless), zero budget
violations. `unspooled=0` is the mission-authoritative empty-peek
verification the hook's bounded stop-drain is designed to reach.

**Events (production, 11/11, gapless 1–11):** `mission.started` (sim 0), 9×
`mission.heartbeat` at exact 30 s model intervals (sim 30 001 … 270 009 ms),
`mission.ended` (sim 299 499 ms — consistent with the 300 s real-time
stop). No player slots were used and no units spawned, as expected for the
unattended shipping mission.

**Collector-side lag:** final event spooled 21:22:07.332 (hook log) →
production `createdAt` 21:22:13.366, `updatedAt` 21:22:13.854 — **6.5 s**,
one service cycle. Run status flipped to `ended` automatically.

**Known limitation (by design):** shipping-mode events carry
`wall_time = null` — the sanitized mission environment has no `os`, and the
bridge's `wall_time` provider explicitly returns JSON null
(`telemetry/bridge.lua`, `wall_time = function() return
config.envelope.JSON_NULL end`). The envelope contract allows null.
Consequences for hook-path runs: per-event *source*→production lag cannot be
measured from the event itself (only `createdAt` exists; the hook's
timestamped `drained` lines in dcs.log bound the spool side), and
`mission_runs.started_at`/`ended_at` (derived from wall time) are null. A
future improvement could have the hook stamp wall time on drained batches;
that is a schema/contract change and out of scope for this slice.

## Production cleanup

One Postgres transaction (Neon direct connection via
`@neondatabase/serverless` `Client`), expectation-guarded: pre-count of all
seven per-run tables verified against the observed production state before
any delete; mismatch would have rolled back. Deletion order respected the
RESTRICT FK `ordnance_expenditures.source_event_id → telemetry_events`
(child fact tables first, then events, then runs):

| table | found | deleted |
|---|---|---|
| kill_attributions | 1 | 1 |
| assist_attributions | 0 | 0 |
| asset_losses | 1 | 1 |
| ordnance_expenditures | 2 | 2 |
| run_participants | 0 | 0 |
| telemetry_events | 29 | 29 |
| mission_runs | 2 | 2 |

`COMMIT` ok. Post-cleanup production check: exactly the two baseline runs
remain (verified via `/api/telemetry/runs`).

## Host teardown state (verified)

- `D:\DCS World Server\Scripts\MissionScripting.lua` = stock
  (SHA-256 prefix `39066C8C…`, matches `.orig`).
- Both temporary `zz-dev-telemetry-load.lua` hooks removed.
- No `DCS_server` process; the only remaining process is the persistent
  collector service (left installed and running per the owner's S18.5-c
  default).
- `src/bootstrap.lua` `TEST_COMBAT_ENABLED` reverted to `false`.
- The hook never created its own spool file in dev mode (`spooled=0`
  generations); no stray run files.

## Residual items

- `wall_time` null on hook-path runs (see Leg 2) — recorded, no action
  taken (contract change required).
- Shutdown-time `mission-eval-failed` transient — known, expected, benign.
- §6.4 lives/escalation/message work remains "implemented +
  offline-verified, live human-in-seat parked" (`s64-live-verification` in
  the agent queue) — this slice's TEST_COMBAT leg does not use player slots
  and cannot validate it.
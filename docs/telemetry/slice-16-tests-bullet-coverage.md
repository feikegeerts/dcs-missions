# Slice 16 — "Tests" bullet + exit criteria — offline test coverage map

**Date:** 2026-09-07 (iter 49). **Status:** evidence-only (no code changed).
**Uncommitted** (commit/push owner-gated).

## What this document is

Slice 16's plan scope (line 1053) names a live-invalidation requirement, and
its exit criteria (line 1057) name two properties. Under the offline-only loop
constraint the **live** "kill X independently" runs are owner-gated (they
require a live DCS / Neon / deployed API and are folded into S17-p4). This
document records the **offline (scripted-fake) equivalents** that prove the
same invariants without a live environment, and cites the exact passing tests
that carry each claim. This is what the iter-44..47 "offline equivalents
covered" shorthand was asserting — now mapped to concrete tests.

Plan text (verbatim, `docs/telemetry-implementation-plan.md`):

- **Tests (line 1053):** "Kill the collector, API, database connection, and
  DCS process independently. Verify no event loss, no double charging, no
  false completion, and correct eventual abort classification."
- **Exit criteria (line 1057):** "A damaged projection is rebuildable and
  interrupted runs are classified without treating a temporary network outage
  as a mission abort."

All cited tests are in the standard offline battery (web vitest, collector
vitest) and were re-run green at 2026-09-07 02:22 (web 17 files/147 tests,
collector 5 files/77 tests, all exit 0). Test names below are exact
`it("...")` / `describe("...")` labels.

## Scenario A — kill the collector (process crash / restart)

Durable byte cursor + on-disk spool mean a collector restart neither loses nor
duplicates events.

- `collector/tests/collector.test.ts` — "resumes from the durable cursor after
  process restart" (no re-read / loss).
- `collector/tests/collector.test.ts` — "does not advance when it crashes
  before spool persistence" + "replays idempotently after a crash between
  spool and cursor durability" + "deduplicates quarantine after a crash before
  cursor durability" + "does not replay after a crash following cursor
  durability" (at-least-once; crash window never loses and never doubles).
- `collector/tests/spool.test.ts` — "persists events and acknowledgement state
  across restart" (spool + ack durability).

→ **no event loss** (and no double) across a collector death.

## Scenario B — kill the API (server down / timeout / 5xx)

The delivery layer retries transient failures with backoff and only
acknowledges a batch on a fully-valid 200; the spool retains everything until
then.

- `collector/tests/delivery.test.ts` — "retries a timeout and a 500 before
  delivering successfully", "retries HTTP 5xx before delivering successfully",
  "retries HTTP 429 before delivering successfully", "stops after exhausting
  transient network retries" (bounded backoff; the S16-p6 429 is here — a
  throttled burst is retried, never dropped).
- `collector/tests/delivery.test.ts` — "reposts safely after a mid-batch
  server crash" (crash mid-delivery → safe repost, no loss).
- `collector/tests/delivery.test.ts` — "acks nothing when a 200 response omits
  one event result" (no partial acknowledgement → no silent loss).
- `collector/tests/delivery.test.ts` — "fails HTTP 400 immediately without a
  retry delay", "fails HTTP 401 immediately without retrying authentication",
  "reports a 401 body without exposing the ingest token or acknowledging"
  (permanent errors are not retried; no token leakage).

→ **no event loss** under API failure (retry + durable spool + no partial ack).

## Scenario C — kill the database connection (server-side persistence down)

A DB-down window loses nothing: events stay in the on-disk spool until a
validated 200 ack. When the DB recovers and the collector retries, idempotency
by `event_id` guarantees the retries are treated as duplicates (no double
charge).

- `collector/tests/spool.test.ts` — "is idempotent by event ID and rejects
  changed retry content" (spool-level dedup).
- `collector/tests/delivery.test.ts` — "does not fetch on a second pass after
  a complete run is acknowledged", "acknowledges a fresh spool when every
  server result is duplicate" (no re-delivery / re-ack).
- `web/tests/ingest.test.ts` — "acknowledges a resend as duplicates without
  increasing persistence" (a re-ingested batch → all `duplicate`, persistence
  unchanged).

→ **no event loss + no double charging** when the DB recovers and retries land.

## Scenario D — kill the DCS process

Abort is triggered **only** by explicit, validated signals (DCS process gone,
or a matching mission STOP line) — never by a mere absence of traffic — which
is what keeps a network/API outage from being misread as an abort.

- `collector/tests/delivery.test.ts` — "posts an abort when the DCS process is
  not running", "does not abort an active run while the DCS process is
  running", "does not abort a run whose spool contains mission.ended", "posts
  a simulation-stop abort for a matching STOP line", "keeps delivery
  successful when the abort POST fails" (best-effort; delivery is not gated on
  the abort signal), "does not evaluate or post abort signals during a dry
  run".
- `collector/tests/abort-signal.test.ts` — `describe("abort signal decision")`
  + `describe("STOP line parsing")` (the conservative gate: only a confirmed
  no-run-remains-active after reconnecting fires the abort).
- `web/tests/ingest.test.ts` — "aborts a prior active run when its producer
  starts a new run", "ratchets an aborted run to ended on a later ended
  upsert", "keeps an aborted run terminal when late events and duplicates
  arrive" (abort is a sticky, correct terminal classification on the web side).

→ **correct eventual abort classification** from explicit signals only.

## The four named invariants (plan line 1053)

1. **No event loss** → Scenarios A + B + C above.
2. **No double charging** → `web/tests/ingest.test.ts` — "acknowledges a
   resend as duplicates without increasing persistence", "repairs a missing
   projection on replay **without double-charging**", "reconciles repeated
   aircraft loss signals into one persisted charge", "evolves one loss across
   batch boundaries and remains stable on replay"; `collector/tests/spool.
   test.ts` — "is idempotent by event ID and rejects changed retry content";
   `web/tests/replay.test.ts` — "is idempotent when the same run is replayed
   twice" (byte-identical stored facts).
3. **No false completion** → a run is `ended` **only** from an explicit
   `mission.ended`: `web/tests/ingest.test.ts` — "marks a run ended and
   records the ending wall time" (the explicit signal) + "keeps runs active
   without an explicit mission ended event" (never completes on its own);
   `web/tests/run-status.test.ts` — "keeps ended runs ended regardless of
   age" (sticky, never downgraded).
4. **Correct eventual abort classification** → Scenario D + `web/tests/
   run-status.test.ts` (below).

## Exit criteria (plan line 1057)

- **"A damaged projection is rebuildable"** → the derived facts (expenditure,
  loss, kill/assist attribution, participants) are recomputed from the raw
  event stream by the **same** projection functions ingest uses, so a corrupt
  or missing projection can be rebuilt from the raw source:
  `web/tests/replay.test.ts` — "reuses the ingest projection functions for a
  mixed full-run stream" (reproduces identical derived facts from raw events),
  "rebuilds one evolved loss from dead and later crashed observations" (one
  fact from two observations), "is idempotent when the same run is replayed
  twice". The raw source itself is exportable: `web/tests/export.test.ts` —
  `describe("telemetry NDJSON export")` + `describe("telemetry CSV export")`.
- **"interrupted runs are classified without treating a temporary network
  outage as a mission abort"** → a run whose heartbeat goes silent (the exact
  signature of a transient API/network outage at the web boundary) is
  displayed **`stale`**, never `aborted`: `web/tests/run-status.test.ts` —
  "marks active runs with no recent heartbeat stale", "treats the threshold
  boundary as still active", "keeps freshly heartbeating runs active",
  "keeps ended runs ended regardless of age", "keeps aborted runs aborted
  regardless of age". An actual abort requires an **explicit** signal (DCS
  process gone / STOP line) per Scenario D — so outage ⇒ stale, not abort.

## Live (owner-gated) residual

The offline tests above exercise the same invariants with scripted fakes
(fake store, fake clock, mocked fetch/log, prod-mock transport). The **live**
"kill the collector / API / DB / DCS process independently" runs — a real
dedicated server, real Neon, real deployed API — remain the owner-gated S17-p4
gate (stock dedicated-server run; procedure in
`docs/shipping-duel-dynamic.md` + the S17-p2/p3 evidence docs). Nothing in
this document is a claim that the live runs have been performed.
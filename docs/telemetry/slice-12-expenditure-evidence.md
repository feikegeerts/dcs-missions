# Slice 12: ordnance expenditure and participant drilldown — evidence

**Date:** 2026-09-05. **Status:** implemented + offline-verified. **Not
live-validated, not migrated, not deployed.**

## Scope (per plan + approved decisions)

- One expenditure per `ordnance.fired`, priced from the run's pinned
  catalogue value with the catalogue name/version recorded per row.
- Group by participant, aircraft incarnation, airframe type, and
  coalition, with a minimal run-page drilldown.
- Latest participant name observed in the run labels current summaries;
  every source event keeps its own name/callsign snapshot.
- Existing historical runs stay unassigned and unpriced — no retroactive
  catalogue assignment, here or ever via these code paths.
- Money is exact integer cents end to end; no floating-point totals, no
  `db.transaction`.

## Files

- `web/src/telemetry/expenditures.ts` (new): pure projection
  (`deriveExpenditure`, `participantObservation`,
  `latestParticipantLabels`, `aggregateExpenditures`), exact-cent money
  helpers, `currentOrdnanceAssignment` (v1 pin for new runs),
  `catalogueForAssignment` (unknown pins project nothing rather than
  mispricing).
- `web/src/db/schema.ts`: `ordnance_expenditures` (PK `source_event_id`,
  FKs to source event / run / catalogue version, positive-or-null cost
  check), `run_participants` (PK producer/run/participant, per-field
  label sequences, monotonic latest sequence), `mission_runs` gains
  nullable `valuation_catalogue` + `valuation_catalogue_version` with an
  all-or-nothing check and an FK to the catalogue version.
- `web/drizzle/0002_flaky_makkari.sql` (new, generated locally with
  `drizzle-kit generate`, **not applied anywhere**).
- `web/src/telemetry/store.ts`: idempotent `insertExpenditure`
  (`ON CONFLICT DO NOTHING` on the source event id),
  sequence-guarded `upsertRunParticipant` (replays and out-of-order
  observations never overwrite newer labels or clear known ones),
  catalogue assignment pinned at run creation via
  `COALESCE(existing, EXCLUDED)` (existing pins, including
  unassigned, are never rewritten), plus
  `listExpenditures` / `listRunParticipants` reads.
- `web/src/telemetry/ingest.ts`: assigns the current catalogue only to
  runs that do not exist yet; prices each batch with the run's own pin;
  projects expenditures and participant observations for accepted
  **and** duplicate source events (duplicate re-pass repairs a failed
  projection; inserts stay idempotent, so replays never double-charge).
- `web/src/app/runs/[runId]/page.tsx`: expenditure section (catalogue
  pin, shot count, known subtotal, partial marker, per-group drilldown
  by participant/incarnation/airframe/coalition); unassigned runs render
  an explicit unpriced notice.
- `web/tests/expenditures.test.ts` (new, 11 tests),
  `web/tests/ingest.test.ts` (+4 tests: assignment, repair, no-double,
  historical-preserved, label advance).

## Acceptance results (offline)

- Two `AIM_120C` + one `AIM_9X` → 3 expenditures, known subtotal
  **$2,547,093.00** (254,709,300¢), unpriced 0, partial false.
- A fired weapon with no target outcome still costs (every
  `ordnance.fired` projects).
- Unknown weapon (`FUTURE_MISSILE_X`, null) → `unitCostCents` null,
  unpriced +1 each, totals marked partial.
- Legacy long-form keys (`weapons.missiles.AIM_120C`) are **not** aliased
  to catalogue entries — they stay unpriced by design; only exact
  DCS-emitted keys resolve.
- Null assignment (historical) and unknown catalogue pins project
  nothing.
- Ingest replay: missing projection repaired, row count stable across
  replays; pre-existing unassigned run stays unassigned with zero
  expenditures; participant labels advance to the latest sequence.

## Verification (all local, no DB connection, no network)

- `npm test --prefix web`: 6 files, **57 tests passed**.
- `npm run typecheck --prefix web`: clean.
- `npm run lint --prefix web`: clean.
- `npm run format:check --prefix web`: clean.
- `npm run build --prefix web`: compiles, static pages generated
  (pre-existing Next.js ESLint-plugin notice only).
- `git diff --check`: clean.

## Explicitly not done

- Migration `0002` has **not** been applied to any database (local or
  Neon) — that is a separate production-migration approval.
- No live ingest against the new projection (staging or production).
- The drilldown UI has not been viewed against a real database.
- No commit, push, or deployment performed in this pass.
- Slice 13+ semantics (losses, kill/assist attribution) are untouched.

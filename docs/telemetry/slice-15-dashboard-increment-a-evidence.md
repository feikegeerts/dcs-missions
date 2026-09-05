# Dashboard increment A (toward Slice 15) — evidence

**Date:** 2026-09-05. **Status:** implemented + offline-verified. **Not
viewed against a live database, not deployed.** Kill/loss/cost-efficiency
views remain parked behind Slices 13–14.

## Scope

Only views backed by tables that exist today (runs, events,
expenditures, participants). Nothing here assumes loss, kill, or assist
metrics.

- Home page: `?status=` filter (all/active/ended), `?mission=`
  substring filter, and a fleet ordnance-expenditure summary (shots,
  known subtotal, unpriced count with partial marker) aggregated from
  already-projected per-run rows. Per-run fan-out is noted in code;
  revisit with a summary table if run volume ever makes it expensive.
- Export: `GET /api/telemetry/runs/[runId]/expenditures` (JSON default,
  `?format=csv` download) and `?format=csv` on the existing events
  endpoint. CSV builders are pure functions with quoting, empty-cell,
  and exact-dollar rules covered by tests.
- Per-run export links on the home page.

## Files

- `web/src/telemetry/export.ts` (new) + `web/tests/export.test.ts`
  (new, 3 tests).
- `web/src/app/api/telemetry/runs/[runId]/expenditures/route.ts` (new).
- `web/src/app/api/telemetry/runs/[runId]/events/route.ts` (+CSV).
- `web/src/app/page.tsx` (filters, fleet summary, export links).

## Verification (all local, no DB connection, no network)

- `npm test`: 7 files, **60 tests passed**.
- `tsc --noEmit`, `eslint`, `prettier --check`: clean.
- `npm run build`: compiles, static pages generated.

## Explicitly not done

- No viewing against staging or production data; no deployment.
- No kill/loss/efficiency views (need Slices 13–14).
- No commit, push, or migration beyond the already-applied 0002.

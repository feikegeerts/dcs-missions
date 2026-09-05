# Dashboard increment C (Slice 15) — evidence

**Date:** 2026-09-06 (night shift, free-mode: Muse Spark direct, no paid
builders). **Status:** implemented + offline-verified. **Uncommitted, not
deployed, not viewed against a live database.** Kill/loss/efficiency views
remain parked behind Slices 13–14.

## Scope

Views-only; no ingest, schema, or migration changes. Store/API changes are
additive read paths (`listRuns` gains optional `offset` + `classification`).

- Runs-list pagination: `GET /api/telemetry/runs` accepts `limit` (1–100) /
  `offset` and returns `{runs, limit, offset, count}`; home table pages at 20
  runs via `?runsPage=` with Prev/Next preserving all filters. Fleet totals
  and scope counts still cover every matching run (≤100, the pre-existing
  list cap), so paging the table never shrinks the theater numbers.
- Classification filter: `?classification=test|historical|all` (default all,
  unchanged behavior) as chips next to the status chips; applied at the DB
  query and re-checked in the page. Values come from the contract: mission
  wiring only emits `test`/`historical`; pre-classification null rows match
  `all` only. Covers the plan's test-data-filtering requirement.
- Crew sorties: run page derives sortie periods from all participant
  enter/leave events in the run (bounded 1000-event read, documented) via the
  existing pure `deriveSorties`, with an honest empty state when a run has no
  crew events (all three current demo runs show it). New pure bridge
  `eventRowToSortieInput` maps stored rows through `eventJson` without new
  store methods or import cycles.

## Files

- `web/src/telemetry/run-filters.ts` (new) + `web/tests/run-filters.test.ts`
  (new): `parseClassificationFilter`, `matchesClassification`,
  `parsePageNumber`.
- `web/src/telemetry/store.ts`: `listRuns(limit, offset, classification)`.
- `web/src/app/api/telemetry/runs/route.ts`: limit/offset/classification.
- `web/src/app/page.tsx`: classification chips, runs pager, fleet-over-scope.
- `web/src/telemetry/sorties.ts` (+`eventRowToSortieInput`),
  `web/tests/sorties.test.ts` (+2 mapping tests),
  `web/src/app/runs/[runId]/page.tsx` (Crew sorties panel).

## Verification (all local, no DB connection, no network)

- `npm test`: 9 files, **71 tests passed**.
- `tsc --noEmit`, `eslint`, `prettier --check`: clean.
- `npm run build`: compiles, static pages generated.
- `git diff --check`: clean.

## Explicitly not done

- No commit, push, or deployment in this pass (left for morning review).
- No live-DB viewing of the new chips/pager/sortie panel.
- No kill/loss/efficiency, authoritative abort, replay, auth, bridge, or
  architecture work (parked SOL slices 13/14/16/17/18/19).

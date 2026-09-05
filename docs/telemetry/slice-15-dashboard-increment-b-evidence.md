# Dashboard increment B + HUD reskin (Slice 15) — evidence

**Date:** 2026-09-06. **Status:** implemented + offline-verified, committed
`d8d901b`, pushed to `origin/main`. **Not viewed against a live database at
commit time; no deployment performed in this pass** (push to `main`
auto-deploys via the git-integrated Vercel project — verify the production
URL separately). Kill/loss/cost-efficiency views remain parked behind
Slices 13–14.

## Scope

Only views backed by tables that exist today (runs, events, expenditures,
participants). No schema, ingest, or API-contract changes except additive
display logic.

- Ordnance by type: pure `aggregateByWeapon` rollup (exact-cent addition over
  already-projected rows; unknown weapons group under null and mark totals
  partial), shown as fleet table on `/` and per-run table on `/runs/[runId]`.
- Visible update time: fleet `max(updatedAt)` on `/`, per-run `updatedAt` on
  `/runs/[runId]`.
- Event pagination UI: `?eventsPage=` (50/page, Prev/Next) on the run page;
  the `limit`/`offset` API already supported it.
- HUD reskin: global `globals.css` command theme (dark ops-room, cyan/amber
  status colors, panel grid, responsive collapse under 800px), shared shell in
  `layout.tsx`, tables replacing raw lists on both pages. Presentation only.
- Demo seed: `web/scripts/seed-slice15-demo.mjs` generates three contract-valid
  NDJSON runs into gitignored `out/slice15-demo/` for view testing without
  flying (`demo-blue-ahead` ended 5 ev/3 shots $2,547,093.00; `demo-unpriced`
  active partial 1 priced + 2 unpriced; `demo-pagination` 61 events).
  Two generator bugs were found by ingest rejection and fixed before commit:
  known locations require `x/y/z`, and unknown weapons require the full
  `{status, reason: type-not-reported, dcs_type: null, display_name: null,
  category: unknown}` shape.

## Files

- `web/src/telemetry/expenditures.ts` (+`WeaponRollup`/`WeaponSummary`,
  `aggregateByWeapon`).
- `web/src/app/page.tsx`, `web/src/app/runs/[runId]/page.tsx`
  (by-type tables, timestamps, event pager).
- `web/src/app/globals.css` (new), `web/src/app/layout.tsx` (shell),
  `web/src/css.d.ts` (new, CSS import for `tsc`).
- `web/tests/expenditures.test.ts` (+2 by-weapon tests incl.
  blue-spending-more-while-ahead).
- `web/scripts/seed-slice15-demo.mjs` (new, local-only output).

## Verification (all local, no DB connection, no network)

- `npm test`: 8 files, **66 tests passed**.
- `tsc --noEmit`, `eslint`, `prettier --check`: clean.
- `npm run build`: compiles, static pages generated.
- `git diff --check`: clean.
- Demo NDJSON validated schema-clean with Ajv before ingest; `--dry-run`
  chunking verified (5 + 4 + 61 events, 1 batch each).

## Explicitly not done

- No live-DB viewing at commit time (demo ingest to Neon happened after,
  verified separately: all 3 runs complete with correct subtotals).
- No kill/loss/efficiency views (need Slices 13–14).
- No runs-list pagination, classification filter, or sortie timeline
  (Increment C — separate change set).

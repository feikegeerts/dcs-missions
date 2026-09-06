# Slice 13 part 3: aircraft loss persistence and dashboard — evidence

**Date:** 2026-09-06. **Status:** implemented + offline-verified. **Not
migrated, not deployed, not live-validated.**

## Scope (per plan + pinned loss semantics)

- Reconcile the full retained run event stream with the frozen
  `reconcileAssetLosts` projection after each assigned-run ingest.
- Persist exactly one current loss row per producer/run/`asset_key`
  incarnation while allowing its canonical fact ID and supporting event IDs to
  evolve as later loss signals arrive.
- Keep historical/unassigned runs without projected loss rows. Preserve exact
  integer cents, the run's catalogue pin, and every supporting source event ID.
- Expose loss rows through a public run endpoint and show catalogue, row costs,
  exact known subtotal, unpriced count, partial status, and empty/unassigned
  states on the run page.
- No transaction is used; accepted source events remain the repairable source
  of truth.

## Files

- `web/src/db/schema.ts`: additive `asset_losses` schema and `AssetLossRow`.
  The producer/run/asset primary key is the stable incarnation identity;
  `fact_id` is separately unique and can evolve.
- `web/drizzle/0003_lazy_cyclops.sql` and generated Drizzle metadata: local
  additive migration, generated but not applied.
- `web/src/telemetry/store.ts`: full-run ordered event read, incarnation-keyed
  single-statement loss upsert, and run-scoped loss read. The upsert only lets a
  projection with at least as many supporting events replace the current row,
  preventing a smaller stale snapshot from regressing it.
- `web/src/telemetry/ingest.ts`: after existing expenditure and participant
  projection, assigned runs are reconciled from all retained events and each
  current loss fact is upserted.
- `web/src/app/api/telemetry/runs/[runId]/losses/route.ts`: public JSON loss
  endpoint with the existing run lookup/error conventions.
- `web/src/app/runs/[runId]/page.tsx`: aircraft loss costs section and view
  states, using `aggregateAssetLosts` rather than reimplementing totals.
- `web/tests/ingest.test.ts`: ingest-level repeated-signal, non-loss,
  incarnation, unassigned-run, batch-boundary, and replay coverage.
- `web/tests/losses-route.test.ts`: public JSON response and shared 404 shape,
  using a mocked store and no database.

## Acceptance results (offline)

- `asset.dead` + `asset.crashed` + a UnitLost-style repeated `asset.dead`
  produce **1 row**, **1 charge**, 3 ordered supporting IDs, and a known
  subtotal of **$29,000,000.00** (2,900,000,000¢).
- Intentional `asset.despawned`, `pilot.dead`, and `pilot.ejected` alone produce
  **0 loss rows**. Ejection followed by `asset.dead` produces **1 loss row**.
- Two same-named aircraft with distinct `asset_key` incarnations produce **2
  rows** and **$58,000,000.00** (5,800,000,000¢).
- A pre-existing unassigned run retains its source event but produces **0 loss
  rows**.
- A dead signal in batch 1 followed by a crash signal in batch 2 leaves **1
  row** and **1 charge**; the fact ID changes and supporting IDs grow from one
  to two. Replaying both batches leaves row count and totals unchanged.
- The unchanged pure loss tests verify view-summary behavior: unpriced aircraft
  remain explicit, increment the unpriced count, and mark the known subtotal
  partial; empty losses produce zero counts and a non-partial subtotal.
- Generated migration inspection confirms it creates only `asset_losses`, its
  two foreign keys, checks, unique/primary constraints, and two indexes. It
  contains no changes to existing tables.
- The losses endpoint test verifies one persisted row is returned with its
  exact 2,900,000,000¢ amount and supporting IDs, while a missing run returns
  the shared 404 shape without querying loss rows.

## Verification (all local, no DB connection, no network)

- `npm run db:generate --prefix web`: generated
  `drizzle/0003_lazy_cyclops.sql` from the local schema snapshot.
- `npm test --prefix web`: **11 files, 87 tests passed**.
- `npm run typecheck --prefix web`: exit 0, clean.
- `npm run lint --prefix web`: exit 0, clean.
- `npm run format:check --prefix web`: exit 0, all files matched Prettier.
- `npm run build --prefix web`: exit 0, compiled successfully; the losses API
  route and dynamic run page are present (pre-existing Next.js ESLint-plugin
  notice only).

## Explicitly not done (offline pass, 2026-09-06)

- Migration `0003` has **not** been applied to any database (local or Neon).
- No live ingest was performed.
- The UI was not viewed against a real database.
- No commit, push, deployment, or publication was performed.

## Migration 0003 applied to Neon + live-ingest verification (owner-approved, 2026-09-06)

Owner approval (2026-09-06 morning): apply `0003` to Neon and live-ingest
verify the S13-live loss run (`run-20260905T205019Z-24cb9efc`). Performed by
the orchestrator (no worker had DB access); no commit/push in this step.

### Environment findings (material)

- The production Neon DB held the 0000–0002 schema **without a
  `drizzle-migrations` journal** (prior setup applied without drizzle-kit
  bookkeeping). A blind `drizzle-kit migrate` would have attempted to re-apply
  `0000` against the live database; the apply therefore used the reviewed
  additive `0003` statements directly plus a verified journal backfill.
- `@neondatabase/serverless@1.1.0`: `sql.unsafe(text)` returns a
  composition-only `UnsafeRawSql` holder; awaiting it is a silent no-op. Raw
  execution is `sql.query(text, params?)` or tagged templates. The first apply
  attempt (built on `unsafe()`) executed nothing — caught by DDL/DML
  persistence probes (self-deleting probe row in `mission_runs`, cleaned up
  and verified) **before** anything was trusted; the production DB was
  untouched by that attempt.

### Apply + verification steps (all run and verified 2026-09-06)

1. Pre-checks: target DB had 23 `mission_runs` / 471 `telemetry_events`
   (the real telemetry DB), no `asset_losses`, no journal, no probe leftovers.
2. Applied the 5 statements of `web/drizzle/0003_lazy_cyclops.sql` via
   `sql.query()`: `asset_losses` (12 columns, 15 constraints, 4 indexes) and
   the `drizzle-migrations` journal backfilled with the sha256 of each of
   `0000`–`0003` (4 rows).
3. `drizzle-kit migrate` (unpooled URL) afterward added nothing — journal
   hashes (`a0bd3210`, `579851c6`, `34e1c32c`, `336139ce`) match the local
   migration files byte-for-byte, i.e. the backfill is exactly the state
   drizzle-kit expects.
4. `npm run db:generate`: "No schema changes, nothing to migrate" (no drift).
5. Live ingest of the S13-live run via `scripts/dev-ingest-run.mjs` against a
   local `next dev` (Next auto-loads `.env.local`; Bearer token from the same
   file):
   - dry-run: 19 events, 1 contiguous batch (seq 1–19).
   - first POST: `accepted=19 duplicates=0 rejected=0 failed=0`.
   - re-run (idempotency acceptance): `accepted=0 duplicates=19 rejected=0
     failed=0`.
6. Read-back DB state:
   - `mission_runs`: 24 rows; the new row
     `dcs-dev-68eb93a7 / run-20260905T205019Z-24cb9efc` is `status=ended`,
     `event_count=19`, `first/last_sequence=1/19`,
     `valuation_catalogue=ordnance v1`, `run_classification=test`.
   - `telemetry_events` for the run: `mission.started=1`,
     `mission.heartbeat=13`, `asset.spawned=2`, `ordnance.fired=1`,
     `asset.dead=1`, `mission.ended=1` — 19 total, gapless seq 1–19.
   - `ordnance_expenditures`: 1 row for the run.
   - **`asset_losses`: exactly 1 row** — `testcombat-blue-001.u1.g1`,
     `FA-18C_hornet`, `blue`, `ordnance v1`, `unit_cost_cents=2900000000`,
     `source_event_ids=["dcs-dev-68eb93a7:run-20260905T205019Z-24cb9efc:7"]`
     (the seq-7 `asset.dead`) — exactly the projection the offline acceptance
     results predict for one `asset.dead`.
7. Teardown: dev server stopped (killed by PID; port 3000 released, no
   leftover node processes). All throwaway verification scripts removed from
   `web/scripts/` before this note was written.

### Residual after this step

- No commit/push/deploy; the S13-p3 + S14-p1 code remains uncommitted
  (push/deploy stays owner-gated; Vercel deploys from git).
- UI not visually inspected in this step — the owner morning-review item
  "view B/C against the live DB" remains open.
- Migration `0004` (kill/assist attributions, Slice 14 part 2) does not exist
  yet; its apply will be a new owner-approval item after S14-p2 completes.

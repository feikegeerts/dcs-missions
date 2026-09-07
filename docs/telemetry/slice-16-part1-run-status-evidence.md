# Slice 16 part 1 — authoritative run-status lifecycle — evidence

**Date:** 2026-09-06. **Status:** complete-offline (sol-worker,
orchestrator re-verified). **Uncommitted** (commit/push owner-gated).
No DB writes, no migrations, no contract changes, no Lua changes.

## Scope

The run-status half of plan §Slice 16 ("Make the system trustworthy after
interruptions and logic changes"):

1. **Completed only from explicit `mission.ended`** — already the behavior
   (the ingest `status` field is `ended ? "ended" : "active"` and the
   upsert ratchet is one-way to `ended`); pinned by regression tests.
2. **Stored `aborted` status + replacement-run rule** — a new run for a
   producer authoritatively marks its previous active run(s) aborted.
3. **Stale remains display-only** — the existing 10-minute heartbeat-age
   label (`STALE_AFTER_MS`, `displayRunStatus`) is unchanged in value and
   in display-only semantics; it now also passes stored `aborted` through
   as-is.
4. **Out of scope (explicit):** the "no active run remains after
   reconnecting" abort path (needs the Slice 17 bridge/collector);
   ingest metrics/limits (S16-p3); collector reliability (S16-p4); any
   schema change (not needed — `mission_runs.status` is a free-text
   column).

## Pinned semantics (as implemented)

- Stored values: `active | aborted | ended`. Only `mission.ended` produces
  `ended`; only the replacement rule produces `aborted`.
- Replacement rule (ingest): when the ingested batch is the first for a
  new run_key (`getRunByRunKey` returns null — contractually that batch
  always contains the seq-1 `mission.started`), `abortSupersededRuns(
  producerId, newRunKey)` runs BEFORE the run upsert: `UPDATE mission_runs
  SET status='aborted', updated_at=now() WHERE producer_id=$1 AND run_key<>$2
  AND status='active'`. Continuation batches, duplicate re-passes, and the
  same run's own seq-1 re-ingest never abort (the guard makes them no-ops).
  If a producer has multiple active runs (shouldn't happen), all of them
  abort.
- Terminal statuses: the upsert ratchet
  `CASE WHEN EXCLUDED.status='ended' THEN 'ended' ELSE <existing> END`
  (pre-existing, unchanged) protects `ended`; it equally protects
  `aborted`, because ingest only ever passes `active` or `ended` — a late
  event or duplicate for an aborted run cannot resurrect it to `active`.
- Display: `displayRunStatus` returns `ended`/`aborted` as-is (aborted
  never displays stale, regardless of age); `active` keeps the existing
  10-minute heartbeat-age rule. `STALE_AFTER_MS` unchanged.

## Files

- `web/src/telemetry/store.ts` — `abortSupersededRuns(producerId,
  newRunKey): Promise<number>` on the `TelemetryStore` interface +
  `NeonTelemetryStore` (guarded drizzle update, returns affected count).
- `web/src/telemetry/ingest.ts` — the replacement-abort call site (new run
  only, before `upsertRun`).
- `web/src/telemetry/run-status.ts` — `StoredRunStatus`/`DisplayRunStatus`
  gain `"aborted"`; pass-through; doc comment updated (aborted is now
  authoritative storage; stale remains display-only).
- `web/src/app/page.tsx` — `ALL_STATUSES` + `?status=` filter + display
  mapping handle `aborted`; stale-Slice-16 comment corrected.
- `web/src/app/globals.css` — `status-aborted` (muted orange, HUD theme).
- `web/tests/ingest.test.ts` — `MemoryStore` fixed to mirror the
  production status ratchet (previously a bare `{...existing, ...run}`
  merge could demote terminal statuses) + `abortSupersededRuns` fake with
  call log; 7 new lifecycle tests: prior-active aborted (call + affected
  assertion), prior-ended untouched, no abort on continuation/duplicate
  re-pass, aborted terminal under late events, all-superseded-abort (2),
  active-without-mission.ended (heartbeat + shot batch).
- `web/tests/run-status.test.ts` — aborted displays aborted regardless of
  age (existing 4 tests unchanged).

Run detail page needed no change: it already renders the stored status via
`status-${run.status}`.

## Acceptance (orchestrator re-ran all, 2026-09-06)

- `npm test` (web/): **13 files / 113 tests passed** (baseline before the
  item: 13 files / 106).
- `npm run typecheck` exit 0; `npm run lint` exit 0; `npm run format:check`
  exit 0; `npm run build` exit 0 (route table unchanged).
- `stylua --check .` and `stylua --check src/missions/duel-dynamic` exit 0
  (no Lua touched; the uncommitted `main.lua` STYLUA-CRLF fix preserved —
  `git diff --stat` for it identical before/after the dispatch).
- `git status`: exactly the 7 allowed web files + the pre-existing
  uncommitted `docs/PROJECT-STATUS.md` / `src/missions/duel-dynamic/main.lua`.
  No schema/`drizzle/`/`contracts/`/`src/`/`collector/` changes. No
  commits (`HEAD` = `origin/main`).

## Residual risk (NOT verified by this item)

- **Live-DB behavior of `abortSupersededRuns`** — verified by code review
  and the in-memory fake; no Neon/DB access was performed (offline-only
  loop constraint). First live exercise happens on the next real
  replacement-run ingest.
- The reconnect-based abort path (plan §Slice 16, last scope bullet)
  remains unimplemented by design — it belongs to the Slice 17
  bridge/collector work.
- Ingest metrics/batch limits (S16-p3) and collector health/retry/spool
  (S16-p4) remain queued.
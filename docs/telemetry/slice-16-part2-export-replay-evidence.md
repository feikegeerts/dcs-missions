# Slice 16 part 2 — raw NDJSON export + derived-fact replay — evidence

**Date:** 2026-09-06. **Status:** complete-offline (sol-worker,
orchestrator re-verified). **Uncommitted** (commit/push owner-gated).
No DB writes, no migrations, no contract changes, no Lua changes.

## Scope

Plan §Slice 16 scope bullets "Raw event export and a derived-fact replay
command" and exit criterion "A damaged projection is rebuildable":

1. **Raw event export:** `GET /api/telemetry/runs/[runId]/events?format=ndjson`
   returns the **complete** run's raw `event_json` as NDJSON (one
   `JSON.stringify` per line, `event_sequence` order), download headers,
   `content-type: application/x-ndjson`. Existing JSON (paginated) and CSV
   (page-scoped) behavior unchanged. Safety cap: > 10 000 events → HTTP
   413 `{error: "run-too-large", count}` (engineered bound, not a product
   knob).
2. **Derived-fact replay:** `web/src/telemetry/replay.ts`
   - `reconcileRunProjections(events, assignment)` — pure; reuses the
     EXACT ingest pipeline functions (`deriveExpenditure`,
     `reconcileAssetLosts`, `reconcileKillAttributions`,
     `reconcileAssistAttributions`, `participantObservation`) so replay and
     ingest cannot diverge. Same catalogue gate as ingest: unassigned runs
     project no expenditures/losses but DO project kills/assists/
     participants.
   - `replayRun(store, runKey)` — reads the run row (pinned catalogue
     assignment, exactly like `processIngest`), one `listRunEvents` read,
     reconciles, upserts every fact through the store's existing
     idempotent/guarded upserts. Throws `ReplayRunNotFoundError` for
     unknown run keys (before any read/write). **Never touches
     `mission_runs`** (no `upsertRun`, no `abortSupersededRuns` — a replay
     is not a new run).
   - `web/scripts/dev-replay-run.ts` + npm script `db:replay`
     (`tsx scripts/dev-replay-run.ts <runKey>`): env from
     `POSTGRES_URL`/`DATABASE_URL` or `web/.env.local` (same convention as
     `seed-catalogue-v1.ts`); prints status/catalogue, event count +
     sequence span, and per-family fact counts; exit 1 + message for
     unknown run keys.

## Pinned semantics (as implemented)

- Replay output = what `processIngest` produces for the same retained
  stream + same pinned assignment (same functions, same gate).
- Idempotent: replay twice → identical stored facts (guarded upserts; no
  double-charge).
- Snapshot-safe: a dead-then-crashed incarnation across batch boundaries
  replays as ONE evolved loss fact with both source event ids.
- NDJSON export is the raw `event_json` — no re-derivation, no reordering.

## Files

- `web/src/telemetry/export.ts` — `eventsToNdjson` (pure; module stays
  DB-free).
- `web/src/telemetry/replay.ts` (new) — pure reconciliation + `replayRun`
  orchestration + `ReplayRunNotFoundError` + `ReplayStore` (7-method Pick
  of `TelemetryStore`, keeps the test fake minimal).
- `web/src/app/api/telemetry/runs/[runId]/events/route.ts` — `?format=ndjson`
  branch (complete run via `listRunEvents`, 10 000-event 413 cap).
- `web/scripts/dev-replay-run.ts` (new) — replay CLI.
- `web/package.json` — `db:replay` script entry only (no dependency
  changes).
- `web/tests/export.test.ts` — 3 NDJSON tests (round-trip order + trailing
  newline; empty → empty string; full contract-shaped event round-trip).
- `web/tests/replay.test.ts` (new) — 6 tests over a minimal
  `ReplayMemoryStore` mirroring the guarded-upsert semantics: mixed-stream
  projection identity vs the ingest functions (counts + fact ids),
  unassigned-run catalogue gate, dead+crashed evolved single loss,
  double-replay idempotency (identical summary + stored facts), unknown
  run → typed error with zero reads/writes, run row untouched
  (`upsertRun` never called).

## Acceptance (orchestrator re-ran all, 2026-09-06)

- `npm test` (web/): **14 files / 122 tests passed** (baseline before the
  item: 13 files / 113 — the S16-p1 state).
- `npm run typecheck` exit 0; `npm run lint` exit 0;
  `npm run format:check` exit 0; `npm run build` exit 0.
- `stylua --check .` (repo root) exit 0 (no Lua touched; the uncommitted
  `main.lua` STYLUA-CRLF fix preserved).
- `git status`: only the S16-p1 files + the 7 S16-p2 files (3 new
  untracked: `replay.ts`, `dev-replay-run.ts`, `replay.test.ts`). No
  schema/`drizzle/`/`contracts/`/`src/`/`collector/` changes. No commits
  (HEAD = `f1608cc` = origin/main).

## Residual risk (NOT verified by this item)

- **Live-DB replay** — the CLI and `replayRun` SQL path were not exercised
  against Neon (offline-only loop constraint; no DB access). First live
  exercise is an owner-gated step (`npm run db:replay -- <runKey>`).
- The NDJSON HTTP endpoint and the 413 cap compiled and are unit-covered
  at the builder level, but were not exercised through a running
  Next.js server in this item.
- No live concurrency test (two simultaneous replays / replay racing
  ingest) — the guarded `setWhere` upserts are the protection, already
  relied on by the ingest path.
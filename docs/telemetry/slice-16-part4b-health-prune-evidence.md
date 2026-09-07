# Slice 16 part 4b — delivery health + spool pruning — evidence

**Date:** 2026-09-06. **Status:** complete-offline (sol-worker,
orchestrator re-verified). **Uncommitted** (commit/push owner-gated).
Collector-only; no web/, src/, contract, or deploy changes. With this
item, **all of Slice 16 is complete-offline**.

## Scope

Plan §Slice 16 scope bullet "Collector health, last successful delivery,
retry/backoff, and spool cleanup" — the **health + spool cleanup** half
(retry/backoff was S16-p4a).

### 1. Durable health (`collector/src/spool.ts`)

- Additive migration `CREATE TABLE IF NOT EXISTS delivery_health
  (producer_id, run_key, last_attempt_at TEXT NOT NULL,
  last_success_at TEXT, last_error TEXT, PRIMARY KEY
  (producer_id, run_key))` — safe on existing spools (no data
  migration).
- `recordDeliveryAttempt({producerId, runKey, at, success, error})` —
  upsert: `last_attempt_at` always updated; success →
  `last_success_at = at`, `last_error = NULL`; failure →
  `last_error = error`, `last_success_at` preserved. Callers pass
  ISO-8601 UTC strings (no clock inside the spool).
- `getDeliveryHealth()` — all rows, ordered by producer_id, run_key.
- `pruneDeliveredRuns(dryRun)` — deletes spooled events + their
  acknowledgements for runs that are **fully acknowledged**
  (`run_delivery_state.acknowledged_through` = max spooled sequence;
  runs without a state row are never prunable). ONE transaction:
  `acknowledgements` first (FK child of `spool_events`), then
  `spool_events`. **Preserved by design:** `run_delivery_state` (ack
  cursor — keeps a run deliverable if it later receives more
  contiguous events), `delivery_health`, `source_cursors`,
  `quarantine`. Dry-run returns the identical shape without deleting.

### 2. Health recording in the delivery flow (`collector/src/delivery.ts`)

- Optional `nowProvider?: () => string` (default
  `() => new Date().toISOString()`).
- ONE health row per run per `deliver` invocation, after
  `deliverRun` completes (dry-run records nothing — it returns before
  the loop):
  - success for `complete` / `incomplete` / `empty`;
  - failure for `error` (message = already-redacted `result.error`)
    and `blocked` (message = `blocked at sequence N[: reason]`).
- `DeliverySummary` shape and all other deliver behavior unchanged.

### 3. CLI modes (`collector/src/delivery-cli.ts`)

- New optional first-positional subcommands; the existing
  flag-only delivery invocation is unchanged.
- `status --state <dir>` — no token, no network, never mutates
  (`--dry-run` rejected). Prints: `mode`, `spool_path`,
  `generated_at`, `runs` (`listRuns()` + left-joined health fields,
  null when never attempted), `totals { runs, events_spooled,
  quarantined }`, `latest { last_attempt_at, last_success_at }` (max
  over health rows).
- `prune --state <dir> [--dry-run]` — no token, no network. Prints
  `mode`, `dry_run`, `pruned_runs`, `total_events_pruned`. `--url` is
  rejected outside delivery mode; unknown positionals → usage error.
- Testable seam: exported `parseCliArguments` / `runStatus` /
  `runPrune` / `runCli(argv, { token, webUrl, print, nowProvider })`
  (returns the exit code; `print` capturable). The direct-execution
  entry point is now guarded by a `process.argv[1] === import.meta.url`
  check so importing the module in tests has no side effects. Token
  redaction on thrown errors preserved.

## Files

- `collector/src/spool.ts` — migration + `recordDeliveryAttempt` /
  `getDeliveryHealth` / `pruneDeliveredRuns` + exported result types.
- `collector/src/delivery.ts` — per-run health recording +
  `deliveryFailureMessage` + `nowProvider` option.
- `collector/src/delivery-cli.ts` — `status` / `prune` modes, usage
  errors, exported seams, direct-execution guard.
- `collector/tests/spool.test.ts` (+2): health upsert/ordering
  semantics (success clears error, failure preserves prior success);
  prune only fully-acknowledged runs, preserves health/cursor rows,
  dry-run no-op.
- `collector/tests/delivery.test.ts` (+5): success records a health row
  with the exact `nowProvider` timestamp; failure records the redacted
  error; blocked records the blocked-at-sequence message; dry-run
  records nothing.
- `collector/tests/delivery-cli.test.ts` (new, +5): status on empty
  spool (exact JSON), status health join + `latest`, prune dry-run
  (reports, `eventCount` unchanged after reopen), prune (events gone
  after reopen), arg validation (unknown command; `status --dry-run`
  rejected).

## Acceptance (orchestrator re-ran all, 2026-09-06)

- `npm test` (collector/): **4 files / 59 tests passed** (baseline
  before the item: 3 files / 47 — the S16-p4a state).
- `npm run typecheck` exit 0; `npm run lint` exit 0;
  `npm run format:check` exit 0; `npm run build` exit 0 (tsc emit to
  gitignored `dist/` — no dist files in `git status`).
- `stylua --check .` (repo root) exit 0 (no Lua touched).
- `git status`: exactly the 6 allowed collector files (5 modified +
  1 new untracked test file); the pre-existing uncommitted web/ +
  `main.lua` + docs diffs preserved. No commits (HEAD = `f1608cc` =
  origin/main).

## Residual risk / follow-ups

- `status`/`prune` are covered via the exported seams — not exercised
  through the real `node dist` binary in tests (the binary path is the
  thin guard shown in the diff).
- Health timestamps are wall-clock via the `nowProvider` default.
- Pruning is an explicit operator action — no automatic cleanup
  schedule (an unattended-test-loop integration is a possible later
  item; nothing in this loop's constraints allows a live run anyway).
- Live end-to-end (real mission → collector → web) remains the
  owner-gated verification for all Slice 16 collector work.
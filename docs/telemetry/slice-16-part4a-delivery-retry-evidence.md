# Slice 16 part 4a — delivery retry with backoff — evidence

**Date:** 2026-09-06. **Status:** complete-offline (sol-worker,
orchestrator re-verified). **Uncommitted** (commit/push owner-gated).
Collector-only; no web/, src/, contract, or schema changes.

## Scope

Plan §Slice 16 scope bullet "Collector health, last successful delivery,
retry/backoff, and spool cleanup" — the **retry/backoff** half (health +
cleanup are S16-p4b).

**Pinned semantics (as implemented):**

- **Retry unit** = one batch POST. The per-run batch loop is unchanged; a
  failed run still stops after its failing batch.
- **Retryable (transient):** fetch throws (network error, including the
  abort-driven `RequestTimeoutError`); HTTP 429; HTTP 5xx (500–599).
- **Fail immediately (permanent, exactly 1 attempt, no delay):** any
  other HTTP status (4xx other than 429 — 400/401/413/…); HTTP 200 whose
  body fails `validateResponse` ("unexpected response shape");
  `spool.acknowledge` throwing (today's handling, untouched). Blocked /
  rejected-event behavior untouched.
- **Budget / backoff:** `DeliveryOptions.maxAttempts` (default 3 =
  initial + 2 retries; validated integer ≥1), `DeliveryOptions
  .retryDelaysMs` (default `[1000, 2000]`; validated non-empty array of
  non-negative integers; delay before retry *i* = `retryDelaysMs[i-1]`,
  last entry repeated when the list is short), `DeliveryOptions
  .sleepImpl` (test seam; default real `setTimeout` sleep). Options are
  optional → `delivery-cli.ts` unchanged, no new CLI flags.
- **Exhaustion message:** last attempt's error (existing format,
  token-redacted via `safeErrorMessage`) + ` (after ${maxAttempts}
  attempts)`. Permanent failures keep today's exact message (no suffix).
- **New additive field** `RunDeliveryResult.attempts: number` — TOTAL
  batch POST attempts for the run across all batches (batches that
  succeeded first-try count 1 each). Flows through the existing summary /
  CLI JSON output (additive key; no consumer validates strict keys).
- **Retry safety** (unchanged invariants that make it correct): identical
  body re-POSTed; the web API dedupes by `event_id` (duplicate =
  successful idempotent ack); the spool acknowledgement cursor advances
  only after a fully validated 200 — so a re-POST of a batch the server
  already accepted yields `duplicate` outcomes and advances the cursor
  exactly once. A client-side timeout that the server did receive is
  recovered the same way.

## Files

- `collector/src/delivery.ts` — per-batch attempt loop inside
  `deliverRun`; `isRetryableStatus` (429 ∪ 5xx); `sleep` default;
  option resolution + validation; `attempts` counter + result field.
  `had_failure`, totals, dry-run, `blocked`, acknowledgement, and
  response-shape handling unchanged.
- `collector/tests/delivery.test.ts` — +10 tests (scripted fake fetch +
  recording `sleepImpl`; one uses `vi.useFakeTimers` + the abort signal
  to exercise the real timeout path): timeout+500-then-success (3
  attempts, delays `[1000,2000]`, identical body re-POSTed, cursor
  advanced); network exhaustion (error `… (after 3 attempts)`, cursor
  not advanced); 429 retry; 503 retry; 400 fail-fast (no delay, message
  unchanged); 401 fail-fast (auth never retried — 1 call); invalid 200
  fail-fast; `maxAttempts: 1` (no retry, `(after 1 attempts)`); short
  delay list `[500]` → `[500, 500]`; clean delivery (1 attempt, no
  sleep). One pre-existing failing-delivery test was pinned to
  `maxAttempts: 1` so its single-attempt assertions keep their original
  meaning under the new default (no assertion weakened).

## Acceptance (orchestrator re-ran all, 2026-09-06)

- `npm test` (collector/): **3 files / 47 tests passed** (baseline before
  the item: 3 files / 37).
- `npm run typecheck` exit 0; `npm run lint` exit 0;
  `npm run format:check` exit 0; `npm run build` exit 0 (tsc emit to
  gitignored `dist/` — no dist files in `git status`).
- `stylua --check .` (repo root) exit 0 (no Lua touched).
- `git status`: only `collector/src/delivery.ts` +
  `collector/tests/delivery.test.ts` changed in the collector; the
  pre-existing uncommitted web/ + `main.lua` + docs diffs preserved. No
  commits (HEAD = `f1608cc` = origin/main).

## Residual risk / follow-ups

- Retry behavior is covered by scripted-fake tests only — not exercised
  against a live web server or live Neon in this offline loop.
- Backoff constants are API defaults; no `--max-attempts` /
  `--retry-delays` CLI flags in this item (possible follow-up).
- Health (last successful delivery, per-run health state) and spool
  cleanup remain — that is S16-p4b.
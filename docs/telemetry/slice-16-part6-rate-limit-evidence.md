# Slice 16 part 6 — per-producer ingest rate limit — evidence

**Date:** 2026-09-07. **Status:** complete-offline (sol-worker).
**Uncommitted** (commit/push owner-gated). No database, dependency, collector,
contract, route, or Lua changes.

## Scope and design

This completes the rate-limit half of the Slice 16 "API batch/rate limits"
scope. The existing batch limits remain unchanged: more than 1 MiB returns 400
`batch-too-large`, and more than 100 events returns 400
`invalid-batch-envelope`.

The implementation is an epoch-aligned, in-memory fixed-window limiter keyed by
validated `producer_id`:

- `currentWindow = Math.floor(now() / windowMs)`.
- A producer's count increments in the same window and restarts at one in a new
  window. Denied attempts are counted.
- A valid request acquires quota immediately after `validateBatch` succeeds and
  before any store interaction. A denial returns exactly HTTP 429 with
  `{ "error": "rate-limited" }`; no threshold, count, or remaining quota is
  disclosed. Existing 200 and 400 response bodies are unchanged, and invalid
  batches return before acquisition, so 400 responses consume no quota.
- State is capped at 4,096 producer keys. Before adding a new key at the cap,
  the map is cleared and the new producer starts at count one. This bounds
  memory under attacker-crafted producer IDs; 4,096 is far above the expected
  one-producer-per-mission-run-host population.
- Production uses one module-level `FixedWindowRateLimiter` singleton. Tests
  inject independent limiters with fake clocks through the optional third
  `processIngest` argument; the existing route and callers remain unchanged.

## Defaults and rationale

The owner-pinned defaults are **300 batches per 60,000 ms per producer**, with
at most **4,096 tracked producers**. The tuning points are the three exports in
`web/src/telemetry/rate-limit.ts`:

- `DEFAULT_MAX_BATCHES_PER_WINDOW = 300`
- `DEFAULT_WINDOW_MS = 60_000`
- `DEFAULT_MAX_TRACKED_PRODUCERS = 4096`

This allows an average five accepted batches per second per producer, or up to
30,000 events per minute when every batch reaches the collector's 100-event
default (`collector/src/delivery.ts:12,200-205`). That is deliberately far
above normal single-mission collector delivery volume while still catching a
tight-loop bug or flood. The collector drains healthy batches sequentially. On
a transient response it makes at most three attempts by default and waits
1,000 ms and then 2,000 ms before retries
(`collector/src/delivery.ts:15-16,231-272,471-476`). A very large backlog can be
throttled, but remains safely queued for later delivery.

## Safety

HTTP 429 cannot lose telemetry data. Events remain in the durable spool until
the collector validates a successful 200 response and acknowledges them. The
collector explicitly treats 429 as retryable alongside 5xx
(`collector/src/delivery.ts:593-594`), retries with backoff, and preserves the
existing at-least-once delivery path. The worst outcome is delayed delivery;
an accepted retry is idempotent by `event_id`.

The limiter runs before every store call, so a denied batch cannot be partially
ingested. Tests assert zero fake-store calls for the denied request.

## Limitations and residual risk

- Vercel serverless module state is per isolate. Cold starts reset the limiter,
  and concurrent instances split producer traffic. Across `N` active isolates,
  the effective cap can therefore be `N x 300` requests per window. This is
  weaker strictness, not weaker telemetry safety, and is accepted for the
  current single-token, one-collector-per-mission-run threat model.
- Epoch-aligned fixed windows permit a boundary burst: up to twice the
  threshold can arrive across the end of one window and start of the next.
- 400 and 401 floods are not rate-limited. Authentication remains the route's
  cheap padded `timingSafeEqual` comparison
  (`web/src/app/api/telemetry/ingest/route.ts:10-22`), and validation failures
  return before any database interaction or quota acquisition.
- The limiter was verified offline with fake clocks and a fake store, not on a
  deployed multi-instance Vercel service or against live Neon.

If owner requirements later demand strict cross-instance enforcement, the
owner-optional follow-up is a shared limiter backed by Neon or Redis. That is
intentionally not part of this best-effort implementation.

## Files

- `web/src/telemetry/rate-limit.ts` — pure fixed-window limiter, tunable
  constants, memory cap, and production singleton.
- `web/src/telemetry/ingest.ts` — optional injected limiter and pre-store 429
  gate after successful validation.
- `web/tests/rate-limit.test.ts` — nine tests covering limit/denial, rollover,
  producer isolation, non-cumulative windows, memory-cap clearing, ingest/store
  behavior, 400 quota exclusion, exact 429 shape, and production defaults.

## Acceptance results

All required commands passed on 2026-09-07:

- `npm test` (web/): **17 files / 147 tests passed**; the new suite contributed
  **9 tests**.
- `npm run typecheck` (web/) exit 0.
- `npm run lint` (web/) exit 0.
- `npm run format:check` (web/) exit 0.
- `stylua --check .` (repo root) exit 0.
- Lua suites: duel shared bandits **12 passed**; telemetry core **20**;
  lifecycle **8**; shot **10**; JSON/sink **11**; participant **9**; asset
  **23**; combat **11**; bridge **40**; production bridge mock **52 checks
  across both mappings**; probe mock **passed**. Every command exited 0.

Final repository invariants were also checked: `git status --porcelain` has 50
lines (22 modified, 28 untracked), HEAD remains `f1608cc Ignore local session
metadata`, and `git stash list` is empty.

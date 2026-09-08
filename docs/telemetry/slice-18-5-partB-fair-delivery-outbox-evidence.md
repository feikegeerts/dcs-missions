# Slice 18.5 part B — fair delivery and durable lifecycle outbox evidence

Date: 2026-09-07. Scope: collector-owned SQLite delivery state, scheduling,
lifecycle evidence, status, pruning guards, and offline tests. No web, mission,
hook, contract, dependency, credential, network, DCS, deployment, or hosted
database change was made.

## Mechanism and reasoning

### Fair contiguous-prefix passes

`deliver()` takes one stable snapshot from `DurableSpool.listRuns()`. Its order
is the existing deterministic SQL order, `(producer_id, run_key)` ascending.
Every due, unblocked run receives at most one body-capped batch of at most 100
contiguous events. The scheduler awaits an injectable event-loop yield between
runs. A run whose persisted deadline is in the future is reported as deferred
without changing that deadline, and a blocked run is reported without another
request. Thus a historical run can consume only one batch before the active run
is visited.

The old in-pass retry/sleep loop was deliberately replaced. `maxAttempts`,
`retryDelaysMs`, and `sleepImpl` remain accepted in `DeliveryOptions` for source
compatibility, but durable one-attempt-per-pass scheduling is authoritative.
This pinned change required updating tests that asserted full-run drain or
multiple sleeps inside one call.

### Durable retry and blockers

`run_retry_state` stores attempt count, next deadline, last classification and
redacted error, plus a permanent blocker sequence/event/reason. A successful
batch resets retry stage; a permanent rejection remains blocked. A natural
sequence gap or missing `mission.started` is also persisted as a blocker. ACKs
still advance only in exact sequence for server-confirmed accepted/duplicate
results; malformed/lost responses ACK nothing and replay the same retained
canonical events.

Final status mapping:

| Outcome | Collector classification/action |
|---|---|
| HTTP 200, valid per-event result | ACK accepted/duplicate events in order; first rejected event becomes a durable permanent blocker |
| HTTP 200, malformed response | retryable `invalid-response`; ACK nothing |
| HTTP 400 | permanent batch rejection; block at the first event in the unsatisfied contiguous prefix |
| HTTP 404 | retryable `remote-run-missing` |
| HTTP 401/403 | open the persisted destination-wide authorization circuit; stop later destination requests |
| HTTP 429 or 5xx | retryable, preserving the prior `isRetryableStatus` set |
| Other non-200 | permanent batch rejection at the first unsatisfied event |
| Network loss/timeout | retryable; ACK nothing |

Normal retry backoff is base 1,000 ms, factor 2, uniform multiplicative jitter
from 0.75 through 1.25, and a final 300,000 ms cap. Clock and RNG are injectable.
A valid `Retry-After` integer-seconds value or HTTP-date overrides exponential
backoff and is clamped to 1,000–600,000 ms. Missing/malformed values fall back to
backoff. Persisting the computed ISO deadline before returning prevents restart
storms.

### Authorization circuit

`delivery_circuit` is a singleton durable record containing open-since, probe
deadline, stage, and a bounded redacted status. While it is open and not due,
event and lifecycle destination requests are suppressed; collection remains on
the independent S18.5-a timer. Status from both CLIs exposes the circuit.

The recorded half-open assumption is implemented as pinned: 60,000 ms base,
factor 2, ±25% jitter, and a final 900,000 ms cap. Once due, exactly one probe
uses the smallest currently eligible event batch; equal sizes retain
`listRuns()` order. Another 401/403 or response loss advances the persisted
stage/deadline. Any received non-401/403 response closes the circuit; ordinary
per-run mapping then handles that response, and normal fair scheduling resumes
on the next pass. This next-pass resumption keeps the half-open pass itself to
exactly one destination probe.

### Durable lifecycle outbox and source-tail honesty

The collector parses a matched producer/run/generation handshake and STOP. It
hashes canonical producer, run, hook/process binding, reason, and exact evidence
identity into a deduplication key and inserts `lifecycle_outbox` before any
lifecycle request. STOP health is `clear` only for `failures=0`, `stuck=nil`,
and `unspooled=0`. `source_tail_state`, written after each non-dry collection
scan, additionally prevents a nominally clear STOP from hiding a partial final
line. Process-disappearance evidence has an unknown tail and remains pending.

Each request outcome is appended transactionally to `lifecycle_attempts` while
the outbox row records state, attempt count, deadline, classification, redacted
terminal/last error, and sent time. Lifecycle retry uses the normal durable
backoff and `Retry-After` rules. A 404 remains pending. A send is eligible only
after the currently known run maximum is acknowledged, with no prefix blocker
and a clear tail. A later retained `mission.ended` suppresses an unsent abort as
`superseded-by-clean-end`; STOP/process evidence is never converted into a
synthetic clean end.

Web compatibility was inspected without modification. The run route targets
the composite producer/run pair and returns 404 before that row exists. It does
not expose a separate observation-key field, so replay uses the same semantic
request; `markRunAborted` updates only `active` rows. A response-loss replay is
therefore a web-side no-op (`aborted: 0`) after the first committed update.

Status exposes retry deadlines/stages/blockers, lifecycle rows and pending
counts, source tails, and circuit state. Manual prune now requires every event
ACKed and either retained `mission.ended` or a sent clear-tail lifecycle record;
pending lifecycle, unknown/partial tails, active runs, and blocked prefixes are
not prunable.

## Additive schema evolution and recovery

The migration adds only `CREATE TABLE/INDEX IF NOT EXISTS` objects:

- `run_retry_state`
- `delivery_circuit`
- `lifecycle_outbox`
- `lifecycle_attempts`
- `source_tail_state`

No existing column/table is dropped or altered. Writable startup retains WAL,
`synchronous=FULL`, foreign keys, and busy timeout, then idempotently creates any
missing new object. Reopening after interruption repeats the declarations;
SQLite/`better-sqlite3` performs WAL recovery. Read-only status probes test for
new-table existence and return empty additive sections for a pre-evolution
file. The migration fixture constructs the old six-table schema, retains an
event and cursor, opens it with new code, and proves the event remains a
duplicate rather than a second fact.

## Offline test-to-exit map

| Exit scenario | Evidence |
|---|---|
| API outage/recovery | durable deadline tests; service keeps collecting; retained canonical replay ACKs only the later accepted/duplicate response |
| Restart mid-backlog | spool reopen preserves retry attempt/deadline and suppresses an early request |
| Response loss after commit | event duplicate convergence test plus lifecycle `aborted: 0` replay test |
| Permanent rejection | durable content-conflict blocker test; peer run completes and blocked run is not retried |
| Old run/lifecycle 404→200 | clear STOP row survives reopen and sends after its event prefix exists/is ACKed |
| Blocked/unknown/partial tail | lifecycle readiness refuses blockers and durable partial/unknown tails; prune returns zero |
| 401/403 circuit | authorization fixture proves one request, restart persistence, one half-open probe, doubled deadline, closure on non-auth response; service collection continues |
| Fairness | 205-event historical run and growing active run each receive one batch in stable order per eligible pass |
| Pre-evolution recovery | old-schema fixture retains cursor and exactly one event while new tables start empty |
| S18.5-a/CLI regressions | complete collector suite, ownership process fixtures, bounded service collection, partial-line, large-backlog, status, prune, and CLI binding tests |

## Per-file change summary

- `collector/src/delivery.ts` — fair one-batch scheduler, durable retries,
  response classification, half-open circuit, lifecycle observation/outbox
  processing, injectable clock/RNG/yield.
- `collector/src/spool.ts` — additive schema and typed persistence APIs;
  lifecycle outcome history; retry/block/circuit/source-tail state; prune guards.
- `collector/src/abort-signal.ts` — detailed STOP evidence parsing while
  preserving the prior public compact parser.
- `collector/src/delivery-cli.ts` — additive durable status fields.
- `collector/src/service.ts` — additive read-only service status sections; the
  independent collection/delivery scheduler and shutdown behavior are unchanged.
- `collector/src/collector.ts` — the only frozen-source exception: one additive
  post-scan persistence call records clear/partial source-tail state. Read window,
  cursor, event, summary, and `maxBytesPerPass ?? Infinity` semantics are
  unchanged. This minimal change is forced by the pinned requirement that
  partial/unknown tails remain durable and visible after log rotation.
- `collector/tests/{collector,delivery,delivery-cli,spool,service}.test.ts` —
  pinned expectation updates and tail/status/circuit regression coverage.
- `collector/tests/durable-delivery.test.ts` — deterministic exit matrix and
  pre-evolution migration fixture.
- this evidence document.

## File-set audit

The final full `git status --porcelain` is recorded after the acceptance battery
below. The workspace already contained S18.5-a/S18.5-d and other orchestrator
changes; this task preserved them. No frozen web, mission, hook, contract,
build, package manifest, or lockfile was changed by this task.

## Acceptance results

The complete battery ran from `C:\Projects\dcs-missions` on 2026-09-07:

1. `npm --prefix collector run check` — exit 0; format, ESLint, TypeScript,
   and **9 files / 109 tests passed**. Node printed the existing DEP0190 warning
   from the ownership test's shell-based child process.
2. `npm --prefix collector run build` — exit 0; `tsc -p tsconfig.json`.
3. `npm --prefix web run test` — exit 0; **22 files / 200 tests passed**.
4. `npm --prefix web run typecheck` — exit 0; `tsc --noEmit`.
5. `npm --prefix web run lint` — exit 0; `eslint .`.
6. `npm --prefix web run format:check` — exit 0; all files matched Prettier.
7. `npm --prefix web run build` — exit 0; Next.js 15.5.25 compiled, checked
   types, generated 4/4 static pages, and emitted its existing warning that the
   Next.js ESLint plugin was not detected.
8. `lua5.1 tests\lua\telemetry\run-bridge.lua` — exit 0; **40 passed**.
9. `lua5.1 tests\dcs\run-telemetry-bridge-prod-mock.lua` — exit 0;
   **26 shifted + 26 fixed = 52 checks passed**.
10. `stylua --check .` — exit 0, no output.
11. `git diff --check` — recorded below after this document update.
12. `git status --porcelain` — full output recorded below after this document
    update.

`git diff --check` exited 0 with no output. Full file-set audit:

```text
 M .gitignore
 M collector/package.json
 M collector/src/abort-signal.ts
 M collector/src/cli.ts
 M collector/src/collector.ts
 M collector/src/delivery-cli.ts
 M collector/src/delivery.ts
 M collector/src/spool.ts
 M collector/tests/collector.test.ts
 M collector/tests/delivery-cli.test.ts
 M collector/tests/delivery.test.ts
 M collector/tests/spool.test.ts
 M docs/telemetry/slice-18-5-near-live-plan.md
 M web/src/app/missions/[missionName]/page.tsx
 M web/src/app/page.tsx
 M web/src/app/players/[playerId]/page.tsx
 M web/src/app/players/page.tsx
 M web/src/app/runs/[runId]/page.tsx
 M web/src/telemetry/expenditures.ts
 M web/tests/expenditures.test.ts
?? collector/src/ownership.ts
?? collector/src/service.ts
?? collector/tests/durable-delivery.test.ts
?? collector/tests/ownership.test.ts
?? collector/tests/service-collection.test.ts
?? collector/tests/service.test.ts
?? docs/telemetry/slice-18-5-partA-persistent-collection-evidence.md
?? docs/telemetry/slice-18-5-partB-fair-delivery-outbox-evidence.md
?? docs/telemetry/slice-18-5-partD-browser-refresh-evidence.md
?? web/src/components/auto-refresh.tsx
?? web/src/telemetry/refresh-schedule.ts
?? web/tests/home-refresh-query-cost.test.ts
?? web/tests/refresh-schedule.test.ts
```

The lines outside the part-B file summary above were present orchestration work
and were not edited by this task. `collector/src/service.ts` and its existing
tests were untracked S18.5-a files on entry; part B made the scoped additive
status/circuit-test changes described above.

## Residual risks and S18.5-e live leftovers

- Offline fetch/process/filesystem fixtures cannot prove hosted route timing,
  Windows service identity behavior, real DCS final-drain ordering, actual WAL
  recovery after power loss, or production network response-loss behavior.
- The web route's idempotency is semantic (active-only status transition), not a
  persisted web observation-key ledger. Changing that contract would require a
  separately approved web/schema slice.
- A process-disappearance observation cannot prove the unspooled source tail;
  it intentionally stays lifecycle-pending instead of risking a false clean or
  premature abort. Operator resolution of permanently unknown tails is future
  policy, not silent automation here.
- Numeric live latency, backlog-drain rate, disk pressure, and real kill/rotation
  drills remain S18.5-e/owner-authorized work.

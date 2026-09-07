# Slice 16 part 7 — ingest identity and partial-failure repair — evidence

**Date:** 2026-09-07. **Status:** complete-offline (sol-worker).
**Uncommitted** (commit/push owner-gated). No schema, migration, contract,
collector, route, Lua, hook, or deployment changes.

## Authority and scope

This implements the owner-approved near-live plan §4, **S16-p7 — Ingest
identity and partial-failure repair**
(`slice-18-5-near-live-plan.md:112-137`) and the master Slice 16 near-live
follow-up (`telemetry-implementation-plan.md:1096-1109`). The implementation is
limited to ingest/store/replay orchestration and in-memory tests.

## Verified pre-state

Before this part:

- `web/src/telemetry/store.ts:180-196` inserted with
  `onConflictDoNothing(event_id)` and classified an empty `returning` result as
  `duplicate` without comparing content. The frozen schema retains the complete
  event in `event_json` (`web/src/db/schema.ts:52`) and separately enforces
  `(producer_id, run_key, event_sequence)` uniqueness
  (`web/src/db/schema.ts:58-62`); non-`event_id` `23505` violations already
  mapped to rejection.
- `web/src/telemetry/ingest.ts:109-194` derived the run summary,
  expenditures, and participants from the request batch. Only the later
  losses/kills/assists reconciliation used `listRunEvents` retained truth
  (`web/src/telemetry/ingest.ts:196-212`). `eventCount` was an accepted-event
  increment in `web/src/telemetry/store.ts:246,256`.
- `web/src/telemetry/replay.ts:61-111` replayed additive facts from retained
  events but deliberately did not repair `mission_runs`.

## Design and pinned semantics

1. **Canonical event identity.** `canonicalJson` recursively sorts object keys,
   preserves array order, and then uses JSON serialization
   (`web/src/telemetry/replay.ts:41-67`). After an `event_id` no-op insert,
   `NeonTelemetryStore.insertEvent` reads back that row's `event_json` and
   compares canonical full-event content (`web/src/telemetry/store.ts:181-204`).
   Equal content is `duplicate`; changed content is the internal permanent
   `content-conflict` outcome. Existing `23505` handling remains `rejected`.
2. **Additive conflict reason only.** Ingest maps a content conflict to the
   existing per-event `status: "rejected"` shape with new additive
   `reason: "content-conflict"` and still returns the normal HTTP 200 batch ACK
   (`web/src/telemetry/ingest.ts:12-18,64-69`). This avoids permanent-conflict
   retries while preserving all response fields.
3. **One retained-truth persistence path.** `reconcileRunSummary` and
   `persistRunFromRetainedEvents` compute and synchronously persist the run row
   and all five projection families from one retained stream
   (`web/src/telemetry/replay.ts:96-159`). Both ingest
   (`web/src/telemetry/ingest.ts:99-109`) and replay
   (`web/src/telemetry/replay.ts:162-182`) call this path. Request events remain
   inputs only to validation, insert attempts, per-request results, and the
   intentionally per-request ingest metrics report.
4. **Absolute summary repair.** The retained event count is passed as an
   absolute `eventCount`, and SQL sets `event_count = EXCLUDED.event_count`
   rather than incrementing (`web/src/telemetry/store.ts:29-44,254-273`).
   Mission metadata/timestamps come only from retained sequence-1
   `mission.started` and retained `mission.ended`; existing non-null values win
   through `COALESCE`. A retained end ratchets status to `ended`; otherwise the
   existing active/aborted/ended value remains.
5. **Catalogue and write ordering.** Existing runs retain their pinned
   catalogue assignment, including `null` for historical runs. Unassigned runs
   project no expenditures/losses but still project participants, kills, and
   assists. The run upsert is awaited before every projection write, and each
   projection family is awaited before moving to the next family or returning.
6. **Replay repair remains additive.** `replayRun` now repairs the run summary
   with the same retained-truth path, while fact upserts retain their existing
   additive/idempotent behavior. `ReplayRunNotFoundError` is unchanged.

## Changed files

- `web/src/telemetry/store.ts:29-60,181-204,254-285` — absolute run-count
  contract/SQL, canonical duplicate readback, conflict outcome, and
  first-non-null summary fields.
- `web/src/telemetry/ingest.ts:12-18,52-109` — additive conflict reason and
  retained-event call into the shared synchronous persistence path; per-request
  metrics left unchanged.
- `web/src/telemetry/replay.ts:23-182` — exported canonical JSON, retained run
  summary reconciliation, shared summary/fact persistence, and replay summary
  repair.
- `web/tests/ingest.test.ts:123-441,446-475,1111-1320` — production-like
  canonical identity, absolute summaries, retained accessors, one-shot failure
  injection, and convergence scenarios.
- `web/tests/replay.test.ts:139-250,356-408` — replay-store summary writes and
  missing-summary repair while proving stale facts are not deleted.

`web/scripts/dev-replay-run.ts` required no change and continues to compile.

## Test inventory

The S16-p7 additions contribute 13 test cases:

- `canonical JSON ignores recursive object key order but preserves array order`
  pins canonical content.
- `one-shot raw insert failure leaves no retained state and accepts retry`
  pins the raw-stage injector and clean retry.
- `identical duplicate retry reconverges every projection and run summary`
  pins all-duplicate ACKs, no additional facts, and identical retained summary.
- `content conflict is rejected without mutating retained truth or projections`
  pins the additive reason, byte-identical in-memory retained JSON, ordinary
  duplicates in the same batch, and exclusion of conflicting mission and
  participant content.
- `failure between raw insert and summary update is repaired by an identical
retry` pins accepted/duplicate behavior and absolute retained event count.
- Parameterized `failure before %s projection is repaired exactly once by
retry` covers expenditures, participants, losses, kills, and assists against
  `reconcileRunProjections` expectations.
- `commit-before-response-loss for a whole batch converges all projections`
  pins raw+summary commit followed by failure before the first projection and
  complete retry convergence without double counts.
- `aborted-run ratchet is preserved until retained mission ended takes
precedence` pins lifecycle status precedence.
- `unassigned-catalogue run gates costs but still repairs combat facts` pins
  catalogue gating.
- Replay's `repairs the run summary from retained truth while keeping fact
replay additive` pins zero/missing summary repair and no stale-fact deletion.

## Offline acceptance

All commands ran from `C:\Projects\dcs-missions` on 2026-09-07 and exited 0:

- `npm --prefix web run test` — **17 files / 160 tests passed** (verified
  pre-part evidence: 147; S16-p7 adds 13 cases).
- `npm --prefix web run typecheck` — passed.
- `npm --prefix web run lint` — passed.
- `npm --prefix web run format:check` — passed.
- `npm --prefix web run build` — production build passed; all routes compiled.
- `npm --prefix collector run check` — format/lint/typecheck plus **5 files / 77
  tests passed**.
- `lua5.1 tests\lua\telemetry\run-bridge.lua` — **40 passed**.
- `lua5.1 tests\dcs\run-telemetry-bridge-prod-mock.lua` — **52 checks passed
  across shifted/fixed mappings**.
- `stylua --check .` — passed.
- `git diff --check` — passed (only pre-existing CRLF conversion warnings for
  unrelated baseline files).

## Repository invariant and residuals

- Baseline `git status --porcelain`: **51 lines = 22 modified + 29 untracked**.
  S16-p7 modifies five already-modified/untracked web files and adds this one
  evidence file, so the expected final invariant is **52 lines = 22 modified +
  30 untracked**. No commit, push, stash, restore, migration, or external access
  occurred.
- Pre-fix stale additive facts are not automatically deleted. Correcting those
  requires an owner-approved manual rebuild/destructive procedure.
- The API is additively extended with per-event reason value
  `"content-conflict"`; no response field or HTTP-success shape changed.
- No conflict was observed in the recorded production runs. Conflict handling
  and SQL readback were verified offline through the production-like in-memory
  store; no Neon/DB, network, DCS, or deployment test was performed.

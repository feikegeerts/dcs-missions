# Slice 16 part 8 — authoritative lifecycle ordering and write targeting — evidence

**Date:** 2026-09-07. **Status:** complete-offline (sol-worker).
**Uncommitted** (commit/push owner-gated). No schema, migration, contract, spool,
Lua, hook, database, network, DCS, deployment, or credential change.

## Authority and scope

This implements the owner-approved near-live plan §4 **S16-p8 — Authoritative
lifecycle order and write targeting**
(`slice-18-5-near-live-plan.md:139-160`), its §5 lifecycle/schema direction
(`:333-334`), assigned §6 rows (`:343`, `:347-348`, `:358`), and the master
Slice 16 near-live follow-up (`telemetry-implementation-plan.md:1102-1108`).
S16-p7 retained-truth ingest and repair behavior is the unchanged foundation.

Work is limited to the whitelisted web ingest/store/lifecycle route, collector
lifecycle decision/wiring/CLI, tests, and this evidence document. S18.5-b's
durable outbox is specified below but deliberately not implemented.

## Verified pre-state

Before this part, the worktree had **52 status lines = 22 modified + 30
untracked**, no stashes, and HEAD `f1549e680002155c1b0bc3554043159ea765b2b9`.
The requested baseline passed: web **17 files / 160 tests**, collector **5 files
/ 77 tests**, Lua bridge **40 passed**, production hook mock **52 checks**, and
`stylua --check .`.

The inspected implementation confirmed:

- first ingest of an unseen run called `abortSupersededRuns`, making HTTP
  arrival order lifecycle authority;
- lifecycle POST resolved only by run key, then used the row's producer;
- STOP parsing discarded `generation=N`;
- process detection was image-name-only and represented ambiguity, query
  failure, and non-Windows platforms as `true` rather than honest unknown;
- failed lifecycle requests were best-effort/non-throwing but had no durable
  retry state.

## Control-plane design

### Run and process-generation evidence contract

Run keys such as `run-<ts>-<rand>` are opaque identities. Their timestamp-like
text is never ordering evidence. The source identity tuple is:

1. the hook-written producer identity from
   `<profile>/Logs/telemetry-bridge/producer-id`;
2. the spool basename/run key;
3. the hook generation captured from both
   `handshake-ok generation=N run=<run> producer=<producer>` and
   `STOP generation=N ... spool=<run>.ndjson`.

The collector sends a STOP abort only when the producer identity file equals
the spool producer and the handshake and STOP agree on run key and generation
(`collector/src/abort-signal.ts:95-140,211-267`). This prevents a STOP for an
old generation from targeting a newer run.

A process observation has exactly three states: `known-running`,
`known-not-running`, or `unknown` (`collector/src/abort-signal.ts:7-39`). A
process binding is all-or-none and contains PID, process creation timestamp,
run key, hook generation, expected image, a literal command-line scope marker,
configured profile path, and configured telemetry input path. The run/generation
must also match the hook handshake before process state can affect that run.

On Windows, the provider invokes non-interactive Windows PowerShell and queries
`Win32_Process` by the bound PID through CIM, returning PID, UTC creation time,
image, and command line (`collector/src/abort-signal.ts:173-209`). A matching
PID + creation time + image + command-line scope is `known-running`. An absent
bound PID or a different creation time (PID reuse) is `known-not-running`.
Missing command-line access, image/scope mismatch, malformed output, command
failure, missing binding, and every non-Windows platform are `unknown`. Unknown
never aborts. This preserves the old fail-safe outcome without claiming a
process is running when it was actually unobservable.

The manual CLI exposes the complete binding through `--dcs-pid`,
`--dcs-created-at`, `--dcs-run-key`, `--hook-generation`, `--dcs-image`,
`--dcs-process-scope`, `--dcs-profile`, and `--telemetry-input`; partial
bindings are rejected. `--producer-id-file` supplies hook identity
(`collector/src/delivery-cli.ts:12-188,249-306`). With no owner-provided scope,
the process state is honestly unknown. This is only an injectable/manual hint;
canonical path ownership and automatic binding belong to S18.5-a.

### Write targeting, credential scope, and compatibility

The approved credential remains Bearer `TELEMETRY_INGEST_TOKEN`; there is no
user login and no second credential. In the approved single-token,
single-collector threat model, that token authorizes telemetry ingest and
lifecycle writes for collector-owned producers. The collector proves the
specific producer/run target by sending additive `producer_id` and, for STOP,
`generation` fields. It never logs the token and retains error redaction.

The route resolves new requests by the composite `(producer_id, run_key)` and
then calls the existing active-only composite update
(`web/src/app/api/telemetry/runs/[runId]/route.ts:65-108`;
`web/src/telemetry/store.ts:212-244`). A producer mismatch is concealed as the
existing 404 `run-not-found`. Existing S16-p5 callers that send only `{reason}`
still use run-key lookup and keep the exact 200/400/401/404 response shapes.
This additive fallback avoids breaking deployed callers; the updated collector
always uses the composite form. No migration is required.

### Ordering, failure, and terminal semantics

- Ingest no longer performs cross-run writes. `abortSupersededRuns` was removed
  from the interface and production store; first arrival, delayed backlog, and
  run-key text do not establish order (`web/src/telemetry/ingest.ts:73-90`).
- Decisions use only matched STOP evidence or matched `known-not-running`
  process evidence. Remote heartbeat state is deliberately non-authoritative;
  running, unknown, and heartbeat absence do not abort
  (`collector/src/abort-signal.ts:66-93`).
- A lifecycle HTTP error or timeout cannot mutate local spool/run state. It is
  returned as `posted: false`, redacted `error`, and `retryRequired: true`; 200
  alone clears the retry-required indication. Delivery remains best-effort and
  non-throwing (`collector/src/abort-signal.ts:268-315`).
- Existing late-fact behavior remains explicit: aborted runs continue accepting
  and projecting retained events; absent a retained `mission.ended`, status
  stays aborted. A retained genuine `mission.ended` ratchets aborted to ended
  (`web/src/telemetry/store.ts:272`; `web/tests/ingest.test.ts:712-728,1253-1280`).
  Neither side fabricates `mission.ended`. STOP/process death means incomplete
  or unknown tail, not clean completion.

## Requirements handed to S18.5-b (definition only)

S18.5-b must add a durable lifecycle outbox in collector-owned persistence. It
must:

1. persist a deduplicated observation key containing producer, run key, hook
   generation/process binding, reason, and evidence identity before attempting
   the lifecycle request;
2. persist every request outcome, classification, attempt count, retry deadline,
   bounded backoff/jitter, and redacted terminal error so log rotation and
   service restart cannot lose or storm retries;
3. retain evidence observed before the remote run exists (including 404) and
   retry it after the run's deliverable prefix creates that composite remote
   row; response loss must converge idempotently;
4. order lifecycle send after all known complete source lines/prefixes for that
   run are durably collected and delivered, while continuing collection after
   DCS exits;
5. keep sequence gaps, blocked prefixes, partial final lines, unspooled/unknown
   tails, and lifecycle-pending state visible. It must never silently skip a gap,
   synthesize bytes, convert unknown to death, or report a clean end without a
   retained source `mission.ended`;
6. preserve pending lifecycle evidence through spool/log rotation and prevent
   pruning while a run is active, tail-uncertain, or lifecycle-pending.

The current `retryRequired` summary is intentionally ephemeral evidence for the
offline fixture, not the S18.5-b durable implementation.

## Changed files

- `web/src/telemetry/ingest.ts` — removed first-arrival supersession.
- `web/src/telemetry/store.ts` — removed supersession SQL; added composite run
  lookup while preserving guarded abort and status ratchet.
- `web/src/app/api/telemetry/runs/[runId]/route.ts` — additive composite target
  and generation handling with legacy fallback.
- `web/tests/ingest.test.ts` — replaced arrival-order fixtures and preserved
  explicit abort/late/end behavior.
- `web/tests/abort-signal.test.ts` — legacy and composite route fixtures.
- `collector/src/abort-signal.ts` — source generation parsing, tri-state scoped
  process evidence, composite request, and retry-required outcomes.
- `collector/src/delivery.ts` — lifecycle evidence-provider wiring only.
- `collector/src/delivery-cli.ts` — optional all-or-none evidence flags and
  producer identity file.
- `collector/tests/abort-signal.test.ts`, `collector/tests/delivery.test.ts`,
  `collector/tests/delivery-cli.test.ts` — lifecycle decision, ordering, outage,
  and CLI fixtures.
- this evidence document.

`web/tests/replay.test.ts` required no change. No file outside the whitelist was
written.

## Test inventory and arrival-order replacement

The arrival-order-pinning ingest tests were handled as follows:

- `aborts a prior active run...` became rapid-restart isolation with late old
  bytes accepted;
- `does not abort a prior ended run...` became old delayed first-delivery after
  a newer active run;
- matching active-only/idempotent abort remained unchanged;
- continuation/duplicate test was renamed to state its non-abort outcome;
- late facts now begin with an explicit abort rather than an inferred
  replacement abort;
- `aborts every active run superseded...` became proof that ingesting a third
  run changes neither active peer.

Additional fixtures cover composite route success/mismatch and legacy fallback;
handshake/STOP generation capture; exact PID/creation/image/scope matching;
unknown on missing scope, detection failure, and non-Windows; heartbeat absence;
rapid restart with only the stopped generation targeted and both spools fully
delivered; lifecycle network failure and timeout with retry indication and no
delivery-state flip; complete CLI binding and rejection of partial binding.

## Offline acceptance

All final acceptance commands ran from `C:\Projects\dcs-missions` on
2026-09-07 and exited 0:

1. `npm --prefix web run test` — **17 files / 162 tests passed** (160 →
   162).
2. `npm --prefix web run typecheck` — passed.
3. `npm --prefix web run lint` — passed.
4. `npm --prefix web run format:check` — passed.
5. `npm --prefix web run build` — production build passed; lifecycle route and
   `web/scripts/dev-replay-run.ts` compiled.
6. `npm --prefix collector run check` — format, lint, typecheck, and **5 files /
   87 tests passed** (77 → 87).
7. `lua5.1 tests\lua\telemetry\run-bridge.lua` — **40 passed**.
8. `lua5.1 tests\dcs\run-telemetry-bridge-prod-mock.lua` — **52 checks passed
   across shifted/fixed mappings**.
9. `stylua --check .` — passed.
10. `git diff --check` — passed; only the two pre-existing CRLF conversion
    warnings for `docs/shipping-duel-dynamic.md` and
    `src/missions/duel-dynamic/main.lua` appeared.
11. `git status --porcelain` — **53 lines = 22 modified + 31 untracked**, exactly
    the 52-line baseline plus this evidence document.

The first collector-check attempt exposed one lint-only forbidden inline type
import in the new test (exit 1). It was replaced with a top-level type-only
import; the complete collector check was rerun and exited 0 as recorded above.

## Residuals and owner-gated items

- CIM/process and hook correlation are unit-tested offline but require S17-p7's
  owner-authorized real Windows/DCS kill gate. No live process was queried here.
- The owner/S18.5-a must supply canonical profile/input/log/producer paths and
  capture the correct PID, creation time, run key, hook generation, image, and
  command-line scope. Missing or contradictory data remains unknown.
- Durable lifecycle deduplication/retry, pre-run evidence retention, fair
  delivery, restart recovery, and pruning guards remain S18.5-b; they require a
  separately reviewed SQLite evolution/recovery design.
- Legacy reason-only writes cannot express producer scope. They remain solely
  for backward compatibility under the same trusted collector token; all new
  collector calls are composite. Removing fallback is a future compatibility
  decision.
- No Neon/DB, network, DCS, deployment, migration, or credential operation was
  performed.

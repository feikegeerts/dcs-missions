# Slice 16 part 5 — reconnect-based abort signal — evidence

**Date:** 2026-09-07. **Status:** complete-offline (sol-worker,
orchestrator re-verified 2026-09-07T01:45). **Uncommitted** (commit/push
owner-gated). Design: **Option C with the recommended defaults** per
`docs/telemetry/slice-16-part5-reconnect-abort-options.md` (owner-approved
"C with the defaults"). No schema migration, no contract event change — the
signal is a new guarded web control path + additive collector summary field.

## Scope

Plan §Slice 16, last scope bullet — the **second half** ("when the validated
bridge/collector confirms that no run remains active after reconnecting"):

> Mark the previous run aborted when the same producer starts a replacement
> run, **or when the validated bridge/collector confirms that no run remains
> active after reconnecting**.

The first half (replacement-run rule, `abortSupersededRuns`) landed in
S16-p1. This item implements the collector-validated host-side signal so the
Slice 16 exit criterion holds:

> interrupted runs are classified **without treating a temporary network
> outage as a mission abort**

## Pinned gate semantics (as implemented)

Per run, a signal is sent **only** from validated host-side evidence:

| `mission.ended` spooled | DCS process running | STOP line for run | Signal |
|---|---|---|---|
| yes | * | * | **none** (ended runs never aborted) |
| no | yes | yes | `simulation-stop-observed` (clean stop; stop line takes precedence) |
| no | no | yes | `simulation-stop-observed` |
| no | no | no | `dcs-process-not-running` (crash case — the only signal no other option covers) |
| no | yes | no | **none** (pure outage / active mission — exit criterion holds) |

- Evidence sources (either sufficient; both host-validated): (1) no
  `DCS_server` process in the host process list; (2) a
  `TELEMETRY_BRIDGE_HOOK STOP … spool=<path>` line in `dcs.log` whose spool
  basename (minus `.ndjson`) is the run key — format pinned from the hook
  source (options doc §Option C, evidence #2).
- "After reconnecting" in the current manual-CLI model = "on the next
  `deliver` invocation" (no live poller; the Slice 18.5 auto-poller is
  notes-only/deferred). The gate is re-evaluated on every `deliver`, so a
  missed or failed signal self-heals on the next invocation.
- **Outage safety:** a pure API/network outage leaves the DCS process
  running and no STOP line → no signal, the run stays stored `active`
  (display `stale`), and it is never misclassified as `aborted`.
- **Ratchet preserved:** the web update is guarded to `status='active'`, so
  a late `mission.ended` batch still upgrades `aborted` → `ended` (a signal
  racing the final event self-heals to the correct terminal status); a late
  `active` batch can never resurrect `aborted`/`ended`.

## Files — web half

- `web/src/telemetry/store.ts` — `markRunAborted(producerId, runKey)`
  (interface + `NeonTelemetryStore`): guarded update
  `SET status='aborted', updated_at=now() WHERE producer_id AND run_key AND
  status='active'`, returns affected row count. No migration (`status` is a
  free-text column).
- `web/src/app/api/telemetry/runs/[runId]/route.ts` — additive `POST` export
  in the **existing** route file (method-dispatched; default #2). Behavior,
  in order: token not configured → **500** `ingest-token-not-configured`
  (fail closed); `Bearer` token compared via padded `timingSafeEqual`
  (constant-time + length check) → **401** `unauthorized`; `reason` must be
  exactly `dcs-process-not-running` or `simulation-stop-observed`, validated
  **before** any store read → **400** `invalid-reason`; unknown run →
  **404** `run-not-found`; otherwise `markRunAborted` + one structured
  request-log line `{action: "telemetry-run-abort", producer, run, reason,
  aborted}` (default #3: log-only, no persistence) → **200** `{aborted}`.
  The URL `runId` is the run key; the store re-derives the producer, so the
  guarded update double-checks producer + run key + status.
- `web/tests/abort-signal.test.ts` (new) — 5 tests: valid abort (200,
  `{aborted: 1}`, store called with producer+run, log emitted); invalid
  reason rejected before the store is read; 404 unknown run (store update
  never called); 401 for wrong/missing token; 500 fail-closed with no token
  configured.
- `web/tests/ingest.test.ts` — `MemoryStore` gains a `markRunAborted` fake
  (guarded, records calls) + 3 new tests: only the matching active run is
  aborted and the call is idempotent (second call affects 0); an `ended`
  run is never aborted; an `aborted` run ratchets to `ended` on a later
  ended upsert.

## Files — collector half

- `collector/src/abort-signal.ts` (new) —
  - `decideAbortSignal({producerId, runKey, hasMissionEnded,
    processRunning, hasStopLine})`: pure gate implementing the table above.
  - `stopRunKeys(dcsLogText)`: parses the pinned STOP-line format with
    `/TELEMETRY_BRIDGE_HOOK STOP generation=\d+ spooled=\d+ spool=(.*?)
    failures=\S+ stuck=\S+ unspooled=\S+/g`; run key = spool-path basename
    minus `.ndjson`; handles `/` and `\` separators; other tags (e.g.
    `OTHER STOP …`) do not match.
  - `defaultProcessRunningProvider()`: conservative default — non-win32,
    empty/ambiguous `tasklist /FI "IMAGENAME eq DCS_server.exe"` output
    (5 s timeout, `windowsHide`), or any exception → **true** (assume
    running → no abort signal); only the explicit
    `INFO: No tasks are running which match` → false. The exact live
    process-name check is folded into owner-gated S17-p4.
  - `sendAbortSignals({baseUrl, token, fetchImpl, timeoutMs, spool,
    dcsLogText, processRunning, runs})`: STOP lines parsed **once** per
    invocation; per-run decision (per-run `spool.hasMissionEnded`); each
    decided run gets a POST to
    `${baseUrl}/api/telemetry/runs/<runKey>` with the same Bearer token as
    delivery, an `AbortController` timeout, 200 → `posted: true`, other
    status → `error: "HTTP <status>"`. **Best-effort:** fetch errors are
    recorded (`posted: false`, message token-redacted, timeout detected via
    the abort signal) and never thrown — a failed abort signal cannot fail
    the delivery.
- `collector/src/spool.ts` — `hasMissionEnded(producerId, runKey)`:
  `SELECT 1 FROM spool_events WHERE … event_type='mission.ended' LIMIT 1`.
- `collector/src/delivery.ts` — additive wiring only: new optional
  `processRunningProvider` / `dcsLogTextProvider` seams (defaults: the
  tasklist provider; `defaultDcsLogTextProvider` reading
  `TELEMETRY_DCS_LOG`, `""` on missing/unreadable); after the per-run
  delivery loop, abort signals are evaluated and sent for `initialRuns`;
  additive `abort_signals?: AbortSignalSummary[]` on both
  `ActiveDeliverySummary` and `DryRunDeliverySummary`. **Dry run:** returns
  `abort_signals: []` and never calls either provider (no side effects).
  **Isolation:** `had_failure` is derived only from delivery outcomes —
  abort POST failures do not affect it or the CLI exit code.
- `collector/src/delivery-cli.ts` — `--dcs-log <path>` flag, **deliver mode
  only** (`status`/`prune` reject it with usage text); resolved path,
  falling back to `TELEMETRY_DCS_LOG`; `readLogText` returns `""` for
  missing/unreadable files. (The file's cumulative diff vs HEAD also
  contains the S16-p4b `status`/`prune` modes — pre-existing uncommitted
  baseline, not part of this item.)
- `collector/tests/abort-signal.test.ts` (new) — 8 decision-table cases
  covering the full gate (including the outage-safety row and the stop-line
  precedence row) + 3 STOP-parse tests (tag-precision, backslash spool
  path, empty text).
- `collector/tests/delivery.test.ts` — 6 new tests: process-dead abort POST
  (exact URL, `content-type`/`authorization` headers, body
  `{"reason":"dcs-process-not-running"}`, summary `posted: true, status:
  200`); process running → no abort call, `abort_signals: []`; spooled
  `mission.ended` → no abort even with the process dead; matching STOP line
  → `simulation-stop-observed`; failing abort POST → `had_failure` stays
  `false` and the error message is token-redacted; dry run → no fetch,
  providers never called, `abort_signals: []`. Plus the `isAbortCall`
  helper and default test seams (`processRunningProvider: () => true`,
  `dcsLogTextProvider: () => ""`) in the shared options helper so existing
  delivery tests stay isolated from host state.
- `collector/tests/spool.test.ts` — 1 new test: `hasMissionEnded` is true
  only for the run whose spooled events contain the event.

## Acceptance (orchestrator re-ran all, 2026-09-07T01:45)

- `npm test` (web/): **16 files / 138 tests passed**; `npm run typecheck`
  exit 0; `npm run lint` exit 0; `npm run format:check` exit 0.
- `npm test` (collector/): **5 files / 77 tests passed**; `npm run
  typecheck` exit 0; `npm run lint` exit 0; `npm run format:check` exit 0.
- `lua5.1` runners (repo root): run-duel-shared-bandits 12, run 20,
  run-lifecycle 8, run-shot 10, run-json-sink 11, run-participant 9,
  run-asset 23, run-combat 11, run-bridge 40 — **144/144**;
  `run-telemetry-bridge-prod-mock` 52 checks; `run-telemetry-bridge-probe-mock`
  + `run-telemetry-bridge-api-discovery-mock` passed; `stylua --check .`
  exit 0 (no Lua touched by this item).
- `git status`: HEAD `f1608cc`, 46 lines (21 M + 25 ??). This item's diff
  is confined to: collector `delivery.ts` / `spool.ts` / `delivery-cli.ts` /
  `delivery.test.ts` / `spool.test.ts` + new `abort-signal.ts` /
  `abort-signal.test.ts`; web `store.ts` / `runs/[runId]/route.ts` /
  `ingest.test.ts` + new `abort-signal.test.ts`. No mission-Lua, hook, S16
  p1–p4, or S17 file was modified (mtimes checked 01:40); the `main.lua`
  STYLUA-CRLF fix is preserved. No commits.

## Residual risk / follow-ups

- **Live checks folded into owner-gated S17-p4:** (a) confirm at runtime
  that the dedicated-server process name is exactly `DCS_server` (no
  launcher rename/indirection) — the offline-verified executable is
  `D:\DCS World Server\bin\DCS_server.exe`; (b) end-to-end: real hook STOP
  line + real `tasklist` + real web POST against the running stack.
- Abort POST is best-effort by design: a failed signal is recorded in
  `abort_signals[].error` without failing the delivery; the run stays
  `active`/`stale` until the next `deliver` re-evaluates (it always does).
- `dcs.log` is read in full on each `deliver` (`readFileSync`); fine at
  current sizes — a tail-only/size-capped read is a follow-up if logs grow
  large.
- The reason enum is pinned to the two values on both sides; adding a
  reason requires changing the web validator and the collector
  `AbortReason` type together.
- Commit/push is owner-gated.
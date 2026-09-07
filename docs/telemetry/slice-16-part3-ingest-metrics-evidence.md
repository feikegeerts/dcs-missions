# Slice 16 part 3 — ingest observability metrics — evidence

**Date:** 2026-09-06. **Status:** complete-offline (sol-worker,
orchestrator re-verified). **Uncommitted** (commit/push owner-gated).
No DB writes, no migrations, no contract/collector changes, no Lua changes.

## Scope

Plan §Slice 16 scope bullet "API batch/rate limits and metrics for
rejected, duplicate, unpriced, and unknown events".

**Batch limits — already satisfied, verified, unchanged.** The ingest API
already enforces the contract-documented batch size limits (contract
§Batch contract: 1–100 events, ≤ 1,048,576 bytes): >100 events → 400
`invalid-batch-envelope`, >1 MiB → 400 `batch-too-large`
(`web/src/telemetry/validate.ts`), both regression-tested in
`web/tests/validate.test.ts`, and the delivery client clamps
`maxEventsPerBatch` to ≤100 (`collector/src/delivery.ts`). This item
adds no new limits. (Rate limiting — per-producer throttling — is a
separate, larger feature and is NOT in this item; recorded as an open
follow-up below.)

**Metrics — implemented.** The 200 ingest response body gains an
additive `metrics` object (batch-scoped):

```json
{
  "results": [ /* unchanged per-event outcomes */ ],
  "summary": { "accepted": n, "duplicates": n, "rejected": n },
  "metrics": { "unpriced": n, "unknown": n }
}
```

### Pinned semantics (as implemented)

- **`unpriced`** — valid events whose outcome is `accepted` or
  `duplicate`, with `event_type === "ordnance.fired"`, in a
  catalogue-assigned run (`catalogueForAssignment(assignment) !== null`),
  whose `deriveExpenditure` projection has `unitCostCents === null`
  (weapon reference `status !== "known"`, or known `dcs_type` absent from
  the pinned catalogue). Same catalogue gate as the projection pipeline:
  unassigned runs count 0 — unassigned runs project no expenditures at
  all, and the metric counts what the pipeline did, not what it could
  have done. Computed by deterministic re-derivation with the SAME pure
  `deriveExpenditure` the projection uses — cannot drift.
- **`unknown`** — valid events whose outcome is `accepted` or
  `duplicate` and whose `event_type` ∈ `UNMODELED_EVENT_TYPES` =
  { `mission.heartbeat`, `asset.spawned`, `asset.despawned`,
  `pilot.dead`, `pilot.ejected` } — the v1 taxonomy types that are
  accepted + retained but not yet modeled by any projection. A
  taxonomy-partition drift-guard test pins this set against the frozen
  14-value v1 enum (no overlap with the modeled set, no omission).
- Rejected events (any reason) are excluded from both metrics;
  duplicates are included (same treatment as the projection pipeline).
- 400 validation-failure responses are unchanged (no `metrics` key —
  nothing was processed).
- Compatibility: `collector/src/delivery.ts` `validateResponse` checks
  the `results`/`summary` shape and tolerates additional top-level keys,
  so the existing collector accepts the new body unchanged (verified by
  inspection; the collector is frozen for this item).

## Files

- `web/src/telemetry/ingest-metrics.ts` (new) — `UNMODELED_EVENT_TYPES`,
  `IngestMetrics`, pure `computeIngestMetrics(events, outcomes,
  assignment)` (no store, no I/O).
- `web/src/telemetry/ingest.ts` — computes `metrics` after the
  catalogue assignment is resolved and adds it to the 200 body after
  `summary` (uses the existing index alignment of `results` with
  `validation.events`).
- `web/tests/ingest-metrics.test.ts` (new) — 6 pure tests: all-modeled
  priced batch → 0/0; each unmodeled type counted (5 → unknown 5);
  unknown-weapon / uncatalogued-known-weapon / priced-weapon → 1/1/0;
  unassigned gate (unpriced 0, unknown still counted); rejected excluded
  + duplicate included; 14-type taxonomy partition guard.
- `web/tests/ingest.test.ts` — pipeline test: mixed batch (priced fire +
  unknown-weapon fire + heartbeat + schema-invalid event) → 200 with
  exact `summary {accepted:3, duplicates:0, rejected:1}` (shape
  unchanged) and `metrics {unpriced:1, unknown:1}`.

## Acceptance (orchestrator re-ran all, 2026-09-06)

- `npm test` (web/): **15 files / 129 tests passed** (baseline before the
  item: 14 files / 122 — the S16-p2 state; +1 suite / +7 tests).
- `npm run typecheck` exit 0; `npm run lint` exit 0;
  `npm run format:check` exit 0; `npm run build` exit 0.
- `stylua --check .` (repo root) exit 0 (no Lua touched; the uncommitted
  `main.lua` STYLUA-CRLF fix preserved).
- `git status`: only the S16-p1/p2 files + exactly 4 S16-p3 files
  (2 new untracked: `ingest-metrics.ts`, `ingest-metrics.test.ts`). No
  schema/`drizzle/`/`contracts/`/`collector/`/`src/`/`web/package.json`
  changes. No commits (HEAD = `f1608cc` = origin/main).

## Residual risk / open follow-ups (NOT verified by this item)

- **Per-batch only** — metrics are computed per ingest request; there is
  no persisted per-run cumulative view. That requires a schema migration
  (new columns or a metrics table) = owner-gated follow-up.
- **Rate limiting** (per-producer throttling) is not implemented —
  out of scope for this item by pinning; the contract-documented batch
  size limits remain the only API-side limits.
- The metrics path is unit/pipeline-covered but not exercised through a
  running Next.js server or a live collector delivery in this offline
  loop (collector compatibility verified by code inspection only).
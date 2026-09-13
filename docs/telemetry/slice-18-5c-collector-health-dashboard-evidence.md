# Slice 18.5-c collector health dashboard evidence

Date: 2026-09-13. Scope: offline implementation and test doubles only. No
production request, credential use, database connection, migration application,
service installation, or DCS operation was performed.

## Design record

The collector derives an instance identity as the first 16 lowercase hexadecimal
characters of SHA-256 over its canonical input path. The path itself is never in
the payload. The payload allowlist is `identity`, `generated_at`, `status`,
`backlog`, `last_successful_delivery`, `next_retry_deadline`,
`quarantine_count`, `blocks`, `lifecycle_pending`, `source_tail_uncertain`,
`disk_free_mb`, and `collector_version`. It excludes source/state paths, lock and
owner data, process IDs, producer IDs, tokens, quarantine contents, and detailed
source-tail rows. Block entries omit producer and event identity; path-like text
in block labels/reasons is replaced before posting. The web route reconstructs
the stored summary from the same allowlist, ignores unknown top-level fields,
and rejects path-like text in allowlisted values.

Status precedence is: `blocked` when the delivery circuit is open or a run block
exists; otherwise `degraded` when quarantine count or source-tail uncertainty is
nonzero; otherwise `ok`. The collector caps blocks at 16, field lengths at the
recorded limits, and removes trailing block entries if needed to remain within
the 4096-byte body limit.

`POST /api/telemetry/collector-health` copies the ingest route's padded
`timingSafeEqual` Bearer-token check. Missing configuration returns
`500 ingest-token-not-configured`; missing/wrong authorization returns
`401 unauthorized`. The route reads at most the specified payload contract,
returns specific 400 reasons for malformed JSON, size, required-field, type,
length, array-bound, timestamp, and private-path failures, then performs one
identity-keyed `INSERT ... ON CONFLICT DO UPDATE`. Conflict updates replace
status/summary and set `updated_at = now()` while retaining `first_seen_at`.

Public `GET /api/telemetry/collector-health` returns only identity, status, the
stored compact summary, `first_seen_at`, `updated_at`, and a fresh `server_time`.
It returns `404 no-collector-status` when empty. The home page uses the same
store read and renders an honest empty state, report age relative to server time,
all compact metrics, and at most four block lines plus an ellipsis.

The service starts the health work only after a delivery promise settles. It is
not awaited by or allowed to reject into collection/delivery scheduling. Empty
tokens retain the existing single `delivery-skipped` log and perform no POST.
Failures log only a stable result reason/status, never the token or payload.
Authenticated redirects and response-URL drift are rejected. Production uses
global fetch; injected delivery-only doubles remain isolated unless an explicit
`healthFetchImpl` is supplied.

## Recorded assumptions for owner review

1. The plan's proposed authenticated POST plus identity-keyed compact table and
   public read is accepted as the reporting mechanism; there is no external
   alerting.
2. A collector identity is exactly the first 16 hex characters of SHA-256 over
   the canonical input path. It is stable for that canonical location and does
   not reveal the location.
3. Run keys and bounded operational block reasons are not participant identity.
   Known absolute-path forms are redacted collector-side and rejected web-side;
   no producer ID, source path, owner, PID, token, or raw quarantined data is
   admitted.
4. Decimal MB means `floor(stateAvailableBytes / 1,000,000)`; an unavailable or
   unsafe byte count is reported as `null`.
5. The table retains one current row per collector identity. Public reads select
   the most recently updated row, limited to one, if more than one collector
   identity has reported.
6. Health methods on the broad ingest `TelemetryStore` interface are optional so
   existing focused ingest fakes do not acquire unrelated responsibilities. The
   Neon implementation and the dedicated in-memory health store implement both
   methods concretely.

## Validation and test matrix

| Area                        | Offline evidence                                                                                                                                                                     |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Identity/privacy            | Deterministic hash assertion; payload absence of input/state/lock; block-path redaction; route ignores unknown private fields and rejects an absolute path in an allowlisted reason. |
| Status mapping              | `ok`, source-tail `degraded`, and circuit/block `blocked` precedence covered.                                                                                                        |
| Bounds                      | 4096-byte route and client checks, 16-block route rejection/capping, string limits, required fields, nonnegative integer fields, status and timestamps covered.                      |
| Authentication              | Correct Bearer accepted; missing/wrong token 401; absent server token 500; no store call on auth failure.                                                                            |
| Persistence                 | In-memory identity upsert preserves first-seen and advances updated-at; route verifies allowlisted summary passed to the store.                                                      |
| Public response             | Exact response-key assertion proves no extra database row property/path reaches GET; empty 404 covered.                                                                              |
| Dashboard                   | Full metric render, age, four-line block truncation/ellipsis, and no-status state covered.                                                                                           |
| Collector failure isolation | Injected network, HTTP, redirect, and oversize failures resolve typed failures; scheduler test proves repeated failed health calls do not stop collection.                           |

## Migration

`npm run db:generate` generated `web/drizzle/0005_wakeful_redwing.sql` from the
Drizzle schema. Inspection shows that it creates only `collector_health`, its
five recorded columns, primary key, defaults, and status check. It was **written
but not applied**. No local or remote database command was run. Drizzle metadata
generated as a tool side effect was restored/removed to honor the task's
allowed-file boundary; the generated SQL is the review artifact requested by
this slice.

## Honest limits

- No live collector-to-web POST, production authentication, Vercel deployment,
  Neon query, or migration was exercised.
- There is no external alerting, notification escalation, or uptime monitor.
- Public freshness is report freshness, not proof that DCS or a mission is alive.
- Path-pattern filtering is defense in depth, not a general PII classifier. The
  compact allowlist and omission of participant/source metadata remain the
  primary privacy boundary.

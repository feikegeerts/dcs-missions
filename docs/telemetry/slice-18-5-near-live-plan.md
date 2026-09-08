# Near-live telemetry: Slice 16/17 follow-ups and Slice 18.5

**Status — 2026-09-07:** Owner-approved architecture and slice-plan
incorporation. All new parts below are **planned, not implemented**. This
document is not authorization to start DCS, provision credentials, install a
service, modify databases, deploy, commit/push, or start/extend an overnight
Loop. Applicable Gate E checkpoints in the
[master plan](../telemetry-implementation-plan.md) still apply.

**Owner deployment decisions — 2026-09-07 (after live test runs):**
(1) Collection cadence: **~5 seconds**, not ~1 second (owner: 1 s is too
often; 5 s is fine). (2) Dashboard refresh must **not** be a full-page
reload (reaffirming §3), and the aggressive cadence applies **only while a
mission is active**; active detection uses existing public reads (stored run
status + `displayRunStatus` heartbeat staleness, unchanged 10-minute
`STALE_AFTER_MS`) — no new backend. (3) Delivery destination: **production**
origin (`dcs-missions.vercel.app`). (4) Secret provisioning: handled by the
**local orchestrator session (Qwen 3.8)**; cloud workers (spark/luna/sol)
must never receive credentials. (5) Retention: **unbounded for now** (owner
has TB-scale storage); no auto-prune remains a non-goal. (6) Alerts: owner
proposes a **dashboard section** for collector health — mechanism sketched in
§5 item 4, pending owner confirmation. (7) Latency: owner accepts
**~5-second-class healthy latency**; with the 5 s scan the worst-case healthy
lag is ~8 s (5 s collection + 2 s refresh); exact p50/p95 agreed before
S18.5-e. (8) Spool input path confirmed from the hook source:
`C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry\` (the hook
spools under `Logs\telemetry` from `lfs.writedir()`; the producer file lives
under `Logs\telemetry-bridge`). Collector state dir and service identity
remain owner choices for S18.5-c; they do not block offline S18.5-a/b/d
(paths are collector configuration). Still **not** authorized by this
document: installing a service, modifying databases, deploying, commit/push,
or starting/extending an overnight Loop.

**Owner runtime authorization — 2026-09-07 (during the overnight Loop):**
the owner expanded the Loop's hard limits for validation purposes:
(1) the dedicated server may be started/used for live testing of Slice 18.5
work; (2) ingesting live test runs to the **production** stack is approved;
(3) test runs may be cleaned up from the production database after all
testing is complete. Live validation is performed by the orchestrator
session (it holds the credential path); cloud workers remain offline and
receive no credentials. S18.5-c service installation and any Neon migration
application remain owner-gated checkpoints.

## 1. Outcome and unchanged boundaries

Start a mission; source-derived shots, costs, losses, kills, assists, and status
appear automatically while it runs. An API outage delays delivery without
losing retained events or falsely aborting a mission. After stop, all available
spooled facts and supported lifecycle state eventually arrive automatically.

```text
Stock mission: source events → bounded RAM queue
    ↓ nested GameGUI peek/ack, NUL-free DDBRIDGE1 frames ≤64 KiB
Hook: append local NDJSON → flush/close/byte-verify → acknowledge
    ↓
External Windows collector: bounded tail → validation → durable SQLite
    ↓ independent fair delivery scheduler, authenticated HTTPS
Existing API → retained raw events + idempotent/recoverable projections → Neon
    ↑ request-driven public reads
Browser: periodic refresh, immediate focus/reconnect refresh
```

- No mission-side file I/O for shipping, HTTP, socket, or database access.
- No HTTP or executable launch from a DCS callback; no token in DCS, hook,
  `.miz`, browser, repository, command arguments, or logs.
- Source events remain the mission's only facts; the web application derives
  costs, losses, primary kills, assists, participants, sorties, and standing.
- Retain raw events and the at-least-once/idempotent collector boundary.
- Preserve manual CLI commands as a controlled fallback, not a competing writer.
- Slice 18 login/access-control product work remains deferred. Slice 19's
  mission-agnostic study is independent; do not turn this into a telemetry rewrite.

**Limits:** Network-outage retention assumes healthy storage with sufficient
capacity. Hard DCS termination can lose events still in mission RAM. A partial
final line may be unrecoverable. Flush/close/readback is not an fsync or
power-loss guarantee. Hook-local I/O can stall on unhealthy storage; bounded
callback work and measured simulation impact are required, not a claim that
all local I/O is asynchronous.

## 2. Evidence baseline (do not conflate these categories)

| Category | Evidence and limits |
|---|---|
| Implemented offline | S17-p1 queue/frame/bridge, p2 production hook, p3 shipping packaging; existing collector cursor/SQLite/delivery and web tests. See `slice-17-part1-mission-bridge-evidence.md`, `slice-17-part2-hook-evidence.md`, `slice-17-part3-packaging-evidence.md`. |
| Previously proven feasibility | `bridge-notes.md`: stock client-host and dedicated-server nested transport on DCS 2.9.29.27278, shifted return recovery, NUL truncation, capped text frames, local readback before ACK. Not proof of every production failure path. |
| Recorded partial production live pass | `../../progress.md`, 2026-09-07 addendum: shipping hook/handshake/spool, five gapless lifecycle events and local collector ingestion. No client joined; no API delivery. This record was read, not rerun, during planning. |
| Still requiring live validation | Player/combat-dependent shipping behavior; hard-kill and multi-frame stop; post-hardening bridge behavior and long-run callback cost; complete automatic collector/API/browser chain. |
| Not yet implemented | Every new part in §4, including persistent collection/delivery, service supervision, browser refresh, and the identified correctness corrections. |

Earlier development-path live-ingest/outage evidence is useful but does not
substitute for shipping end-to-end acceptance. Existing recorded test counts
are historical evidence, not tests executed by this planning update.

## 3. Selected mechanisms and operating defaults

| Option | Decision |
|---|---|
| External directory polling | Initial collection mechanism, inside one persistent Node process; avoid spawning CLIs every second. |
| Filesystem notifications + reconciliation | Optional later latency hint. Notifications can be missed/coalesced; periodic scanning remains authoritative. |
| Hook-to-local IPC | No supported nonblocking mechanism established. Not required or authorized; never replace durable spooling. |
| Browser polling | Initial near-live presentation. Request existing dynamic pages/public reads; preserve UI state. |
| Full-page reload | Manual/temporary fallback only; avoid disrupting pagination/scroll. Owner reaffirmed 2026-09-07: the automatic refresh must not be a full-page reload |
| SSE | Possible later one-way fan-out after measuring load and hosted connection limits. Still needs durable catch-up. |
| WebSockets / managed realtime | Not initially needed; additional infrastructure, connection lifecycle and publication failure boundaries. |
| Neon polling / LISTEN-NOTIFY | No separate database poller/listener. Browser requests cause normal server-side queries. Notifications would not be a durable queue. |
| Other DCS paths | Existing callbacks/nested bridge are the selected path. DCS-gRPC, Tacview realtime and export/log alternatives are not established substitutes for these normalized peek/ack events. |

Starting settings (owner-adjusted 2026-09-07): collection every ~5 seconds
(owner: 1 second is too often; 5 seconds is fine), prompt delivery of
available partial batches, one HTTP request at a time, visible active-page
refresh ~2 seconds. Keep existing 100-event/1 MiB request bounds unless
separately reviewed. Never wait for 100 events, a stable file, or mission
end. Optional notification mode must retain a bounded periodic
reconciliation interval (initially 5–10 seconds). Polling-only mode
continues its ~5-second scan.

Healthy event-to-screen target: roughly **5–8 seconds** worst case with the
5-second scan (owner-accepted 2026-09-07 as ~5-second-class acceptable
latency; exact p50/p95 target agreed before S18.5-e), not a verified SLA.
Budget approximately 0.5–1 second for the hook (pending clock validation), up to
5 seconds for collection, measured HTTP/projection time, and up to 2 seconds for
browser refresh. Cold starts, backlog and outages extend it. Measure with
correlated test markers and wall-clock observations; shipping event wall time
may be null, so do not subtract simulation time from server wall time.

Keep heartbeat production cadence separate from browser polling. A refreshed
page does not prove fresh source telemetry or a connected collector. Show view
refresh time, latest source observation and stored run status separately; do
not reinterpret the existing ten-minute stale threshold without explicit review.

## 4. Bounded slice parts and dependencies

Sol owns correctness, concurrency, security, lifecycle, schema/API changes and
framework lifecycle work below. Routine isolated fixtures/formatting follow the
active orchestrator's ordinary-builder policy: exact
`opencode/muse-spark-1.3-contributor-free` while the promotion is confirmed,
one Luna fallback after transient outage; no downgrade of Sol-required work.
These are task routing requirements, not permission to change agent config.

Each part needs a standalone handoff with exact allowed files, commands and stop
conditions. The file lists below establish boundaries, not permission for broad
refactors. One writer at a time; do not delegate credential handling.

Recommended first implementation handoff: **S16-p7**. Then S16-p8 and S17-p5/p6
close the correctness/transport prerequisites; a/b/c build the collector path;
d can be implemented independently against existing reads. S17-p7 and e are
owner-gated live acceptance, not reasons to block unrelated approved offline
work. This dependency order is a roadmap, not a running task queue.

### S16-p7 — Ingest identity and partial-failure repair

**Boundary:** `web/src/telemetry/{ingest,store,replay}.ts`, relevant web tests;
schema/migration files only after a reviewed compatibility decision.

Confirmed inspection findings: `store.insertEvent()` currently maps event-ID
conflict to duplicate without content comparison; ingest derives some facts
from duplicate request bodies. Raw inserts, run-summary updates and projections
are separate writes. Existing replay includes additive repair, not necessarily
exact removal/rebuild of every obsolete fact.

- Define identical duplicate as equality of canonical retained content; reject
  changed content under the same ID without altering raw history or projections.
- Recover projections from persisted truth, including participant observations
  and expenditures; do not trust conflicting retry bodies.
- Test failures between raw insert, summary update and each projection stage;
  retries must repair counts and facts, not merely avoid duplicate rows.
- Keep synchronous required projection completion before successful ACK for the
  initial implementation. If changed to async, durable replay work must exist
  before ACK; no untracked background promise.
- Preserve catalogue assignments and historical pricing. Any repair migration,
  API response change or destructive rebuild needs explicit review/approval.

**Exit:** Identical retries and commit-before-response-loss converge; conflicts
are permanent integrity failures; summaries/costs/kills/losses/assists match
retained-source expectations after injected failures.

### S16-p8 — Authoritative lifecycle order and write targeting

**Boundary:** web ingest/store, `web/src/app/api/telemetry/runs/[runId]/route.ts`,
`collector/src/abort-signal.ts`, related tests and reviewed control-plane design.

- First delivery of an unseen run currently aborts other active runs from the
  producer. Replace arrival-order inference: old backlog cannot abort a newer
  run. Do not guess generation order from API arrival time or run-key text.
- Specify trustworthy producer/run/process-generation evidence; bind process
  observations to PID + creation time + configured profile/input scope. Retain
  unknown on ambiguous/failed detection; image-name-only detection is inadequate.
- Lifecycle writes must target the intended composite producer/run and enforce
  the approved collector credential's scope. Resolve backward compatibility
  before changing the current run-key route; no user-login requirement.
- API failure or remote heartbeat absence alone must never abort a run. A pause
  may stop heartbeats. Accept late facts after abort; genuine `mission.ended`
  takes precedence for clean ending. No synthesized clean-end source event.
- Define persistence/order requirements consumed by S18.5-b, including evidence
  observed before the remote run exists and sequence-gap/unknown-tail cases.

**Exit:** Ordering and lifecycle fixtures establish these rules, including rapid
restart, old delayed run, unknown process state and temporary API outage.

### S17-p5 — Ambiguous hook ACK reconciliation

**Boundary:** `hooks/duel-dynamic-telemetry.lua`, telemetry `bridge.lua`,
`bridge_queue.lua`, frame code only if needed, Lua/production-hook mock tests.

- Test mission ACK execution followed by lost/mangled response. Current hook
  cursor can remain behind while the queue discards the prefix, causing stale
  peeks; this failure path is not established live evidence.
- Reconcile mission cursor with the verified-spool frontier before advancing or
  reappending. Existing `runtime:status()` exposes ACK/pending information.
- Define safe idempotent ACK retry behavior without acknowledging unverified
  bytes. Preserve text-only frame caps/sentinel recovery.

**Exit:** Lost-response tests recover both during normal drain and stop, with no
permanent stale-peek loop, unsafe ACK, or changed event identity.

### S17-p6 — Bounded hook work and truthful stop

**Boundary:** production hook, affected bridge helpers/mock tests and packaging
verification. No source-event/business-rule redesign.

- Current append verification retains/rereads the whole lifetime spool. Design
  bounded append-region verification or segmentation, with integrity and
  collector compatibility checks; retain byte-verify-before-ACK.
- Bound callback work and memory. No unbounded stop drain. Current one-cycle
  stop cannot prove an empty queue and must not report zero merely because the
  hook is not stuck. Report verified empty, pending, or unknown tail accurately.
- Verify `os.clock()` scheduling behavior in the installed build, including idle,
  pause/resume and long runs; select a verified clock if needed.
- Queue overflow/disk faults must produce explicit telemetry health failure,
  not silent data loss or an uncaught exception destabilizing mission logic.

**Exit:** Offline burst/large-spool/partial-write/failure tests pass; callback
budget and live measurement procedure are specified for S17-p7.

### S17-p7 — Post-hardening stock live gate

**Depends on:** p5/p6 and rebuilt packaging; owner approval and player/manual
participation. Preserve S17-p4's partial pass as historical evidence.

Record installed DCS build, stock `MissionScripting.lua` verification, exact
shipping artifact/hook hashes, callback registration and coexistence with
Tacview, nested return mapping/cap behavior, real queue/spool/collector results,
player/combat mission behavior, fresh run on restart, multi-frame stop and
long-run callback timing. Inject ambiguous returns safely where supported; do
not present mock-only fault evidence as a real DCS test. Preserve the dev loader.

**Exit:** Required stock mission and transport gates pass on the hardened
artifact, with hard-kill limitations documented. API/browser gate is S18.5-e.

### S18.5-a — Persistent single-owner collection

**Boundary:** `collector/src/{collector,spool,cli}.ts`, a bounded service-mode
entry point/ownership module, collector tests/package scripts as needed.

- Reuse existing parser/SQLite semantics; bounded read windows and partial-line
  size handling replace whole-remainder allocation. Yield between bounded work.
- Persist insertion/quarantine before advancing cursor. Preserve incomplete
  final lines; do not manufacture missing bytes. Detect file identity/truncation
  and report source-integrity incidents rather than silently concealing them.
- One persistent process with independent collection and delivery scheduling;
  HTTP waits/backoff must not block local collection. Bounded synchronous SQLite
  work must not monopolize the event loop.
- Acquire a real OS-held mutex/lock before mutable work, covering canonical state
  and input/profile ownership, including Windows case/reparse aliases. Restrict
  access to the lock; PID files and scheduler no-overlap are not sufficient.
- Mutating collect/deliver/prune commands respect ownership; read-only status
  remains usable. A second state directory must not bypass source ownership.

**Exit:** Restart/partial-write/large-backlog and Windows duplicate-owner tests
pass; manual fallback remains available when the service is stopped.

### S18.5-b — Fair delivery and durable lifecycle outbox

**Depends on:** a + S16-p7/p8. **Boundary:** collector delivery/spool/abort modules,
service scheduler and tests; SQLite evolution requires reviewed migration/recovery.

- Deliver available contiguous prefixes in bounded batches, fair across all
  eligible runs. A historical backlog cannot starve the active run.
- Persist retry deadlines, bounded exponential backoff/jitter, parsed valid
  `Retry-After`, permanent rejections and sequence-gap blockers. Prevent retry
  storms across restarts. 401/403 opens a delivery-wide circuit and alert while
  collection continues; event-specific blocked runs do not block others.
- Persist deduplicated lifecycle observations, request outcomes and retry state,
  surviving log rotation and service restart. Retry evidence arriving before the
  remote run exists. Send after all known complete source lines/prefixes are
  durably collected/delivered; blocked gaps remain visible, never silently skipped.
- Continue after DCS exits; never wait for `mission.ended` to collect or send.
  An observed stop without clean end carries incomplete/unknown-tail semantics.

**Exit:** Offline API outage/restart/response-loss/rejection/old-run/lifecycle
matrix passes without duplicate facts, lost retained records or false abortion.

### S18.5-c — Windows operation and recovery

**Depends on:** a/b. **Boundary:** collector operational configuration templates,
status/logging tests and runbook, and (if the owner confirmation below holds)
the collector status-POST client + web status route/table/dashboard section
(offline-verifiable); actual installation/secret handling is owner-gated.

- Prefer a WinSW-managed Windows service under a dedicated least-privilege
  identity, at boot independently of DCS, with bounded restart delay, rotating
  logs, fixed paths and bounded graceful shutdown. A boot Scheduled Task is a
  documented fallback, not a per-second process launcher.
- Use service-private ACL-protected secret provisioning/approved Windows secret
  storage, never a global environment inherited by DCS or plaintext readable by
  other identities. Do not propagate token-bearing environments to subprocesses.
- Pin approved HTTPS origin; reject authenticated redirects. Keep DB credentials
  solely in the web backend and public read responses free of private metadata.
- Report backlog count/bytes/age, disk space, last successful delivery, next retry,
  quarantine/block reason, lifecycle pending state and source-tail uncertainty.
  Destination (owner proposal 2026-09-07, mechanism pending owner
  confirmation): a dashboard "Collector health" section fed by a compact
  status POST from the collector to a new token-authenticated web route
  (existing Bearer ingest token), persisted as a small single-row-upserted
  table; schema/API change ⇒ Sol + owner-gated migration. No external
  alerting for now.
- Retain NDJSON and SQLite; **no automatic prune**. Existing prune eligibility
  only means currently acknowledged, not terminal: prevent cleanup of active or
  lifecycle-pending runs. Any later retention policy needs terminal/ACK/lifecycle
  checks and preserved cursor/dedup/tombstone evidence.
- On startup lock, recover SQLite/cursors/deadlines, reconcile files, then resume.
  Distinguish network outage, disk exhaustion and capture failure in logs/alerts.

**Exit:** Windows boot/restart/duplicate startup/restricted-identity tests and an
operator recovery runbook pass; no credentials enter source, artifacts or logs.

### S18.5-d — Browser polling and honest freshness

**Independent offline work:** existing public reads suffice; no Slice 18 login.
**Boundary:** web home/run pages, a small refresh client component and web tests.
Sol owns Next.js/React request/lifecycle correctness, not just visual formatting.

- Start with `router.refresh()` or equivalent existing public requests on visible
  active views (~2 seconds), single-flight and with cleanup on navigation/unmount.
  Preserve search/filter/pagination/scroll; refresh immediately on focus/reconnect.
  Active-mission gate (owner decision 2026-09-07): the aggressive cadence runs
  only while the displayed run (or the latest run on the home/mission index
  pages) has display status `active` per the existing `displayRunStatus`
  derivation (stored `active` + heartbeat within the unchanged 10-minute
  `STALE_AFTER_MS`); detection needs no new backend. On `stale`/`ended`/
  `aborted` fall to a slow cadence (initially 30–60 s) plus focus/reconnect
  refresh; never stop entirely (a stale run may resume, and late final facts
  must still arrive).
- Back off failures, retain last good content, slow hidden/ended views, and keep
  eventual checks for late final facts. Do not stop forever on the first abort.
- Separate browser connection/view freshness from latest source observation and
  stored mission status. Existing `force-dynamic` pages alone do not auto-refresh.
- Measure query count and render cost (2 seconds means ~30 refreshes/minute per
  visible browser). Avoid overlapping requests and duplicate timers. Verify
  browser/API caching behavior, not only server-page settings.
- No dedicated snapshot API initially. If needed after measurement, separately
  scope compact reads/cache/revisions covering projections as well as raw events.
  No SSE/WebSocket/Neon listener as an incidental UI dependency.

**Exit:** Browser disconnect/focus/navigation/slow-request/late-final tests pass;
last good data remains readable and query-cost measurements are recorded.

### S18.5-e — Integrated acceptance and latency measurement

**Depends on:** a–d + S17-p5/p6/p7. Offline tests can be prepared before the live
gate; execution against DCS/hosted API requires separate owner authorization.

Run §6, record timings/backlog drain/load and exact versions/artifacts. A live
mission must reach the browser without manual collect/deliver invocations.
Measure p50/p95/max lag and hook callback duration under healthy and recovery
load; agree the numeric acceptance target before declaring completion. Preserve
source IDs/sequences and aggregate reconciliation evidence, with private data
redacted. Do not claim a timeout or missing heartbeat is proof of mission death.

## 5. Operational decisions and authorization gates

Approved design direction: collector on the DCS host, all unacknowledged backlog,
one owner, persistent service, ~5-second collection/~2-second visible refresh
(owner-adjusted 2026-09-07). Deployment gates, with 2026-09-07 owner
resolutions:

1. Exact server/profile/input/state paths and service identity — **partially
   resolved 2026-09-07:** spool input confirmed as
   `C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry\` (hook
   `lfs.writedir()`-derived; no guessing among the other Saved Games profiles).
   Collector state directory and service identity remain owner choices for
   S18.5-c; they do not block offline S18.5-a/b/d (paths are collector
   configuration).
2. Test versus production HTTPS destination and permission for API/DB writes —
   **resolved 2026-09-07:** production origin (`dcs-missions.vercel.app`).
3. Secret provisioning and service installation mechanism — **resolved
   2026-09-07:** handled by the local orchestrator session (Qwen 3.8); cloud
   workers must never receive credentials (consistent with the existing
   never-delegate-secrets rule).
4. Available disk/retention capacity and alert destination; no silent eviction —
   **retention resolved 2026-09-07:** unbounded for now (owner storage),
   no auto-prune unchanged. **Alert destination (owner proposal 2026-09-07,
   mechanism pending owner confirmation):** a dashboard "Collector health"
   section fed by a compact status POST from the collector to a new
   token-authenticated web route (existing Bearer ingest token), persisted as a
   small single-row-upserted table; see the S18.5-c reporting bullet. No
   external alerting for now.
5. Expected public audience/query budget and measured latency/callback acceptance —
   **latency partially resolved 2026-09-07:** owner accepts ~5-second-class
   healthy latency; with the 5 s collection scan the worst-case healthy lag is
   ~8 s (5 s collection + 2 s refresh). Exact p50/p95 target and public query
   budget to be agreed before S18.5-e. Public live tactical visibility and
   participant-label exposure remain risks; do not expand public fields or
   claim user privacy controls exist.

Missing deployment choices block deployment, not unrelated approved offline
fixtures/UI planning. Resolve genuine lifecycle/schema decisions in S16-p8;
do not invent a process-generation contract during watcher implementation.

## 6. Acceptance matrix

| Scenario | Required observation | Owner part / evidence |
|---|---|---|
| Clean live run | Automatic source facts/derived totals and final state; measured healthy lag, no manual CLI passes | S17-p7 + 18.5-e; real stock DCS/API/browser |
| API temporarily unavailable | Collection continues, durable backlog grows, bounded retries recover without duplicate facts | 18.5-b/e; offline injection + live drill |
| Collector restart | Cursors/events/ACKs/lifecycle/deadlines recover without skip or retry storm | 18.5-a/b/c |
| DCS process termination | All complete spooled records delivered; trustworthy run-scoped stop; unspooled/partial tail disclosed | S16-p8, S17-p7, 18.5-e; real kill gate |
| Browser disconnect/reconnect | Backend continues; immediate catch-up, stable pagination and no duplicate display rows | 18.5-d/e |
| Duplicate watcher startup | Second writer rejected, including same-input/different-state and canonical path aliases | 18.5-a/c; Windows integration |
| Partial NDJSON writes | No premature parse/cursor advancement; completed line eventually ingested once | 18.5-a |
| New run key on mission restart | Runs isolated; old backlog never aborts new run; final old bytes still collected | S16-p8, 18.5-b/e |
| No false abort during API outage | Healthy or paused DCS not aborted from remote silence/HTTP failure | S16-p8, 18.5-b/e |
| API commits then response disappears | Replay converges raw counts, summaries, expenditures/losses/kills/assists | S16-p7, 18.5-b |
| Same ID with different content | Permanent conflict, no mutation of retained raw event or projections | S16-p7 |
| Crash between raw/summary/projection writes | Retry repairs all required state without double charging or stale count | S16-p7 |
| ACK executes then return disappears | Reconciled cursor, no stale-peek stall or ACK beyond verified spool | S17-p5/p7; mock and live distinctions explicit |
| Stop with multiple pending frames | Bounded callback; no false zero-tail report; pending/unknown visible | S17-p6/p7 |
| Lost filesystem notification | Reconciliation finds data regardless | 18.5-a if notifications added |
| 401/403 or permanent event rejection | Correct circuit/block scope; collection continues; actionable redacted status | 18.5-b/c |
| Disk full / failed byte verification | No unsafe hook ACK, no silent prune, explicit capture fault and measured sim impact | S17-p6/p7, 18.5-c; controlled fault test |
| Long run / large historical backlog | Bounded memory/callback effort, fair current-run delivery, measured query cost | S17-p7, 18.5-a/b/d/e |
| Lifecycle POST fails / log rotates | Durable evidence retries after restart; not lost before run creation | 18.5-b |
| Navigation/hidden tab/slow refresh | Timer cleanup, single flight, reduced hidden load and eventual late-final refresh | 18.5-d |

Automated baseline commands for affected scopes (not run by this planning edit):

```text
npm --prefix collector run check
npm --prefix collector run build
npm --prefix web run test
npm --prefix web run typecheck
npm --prefix web run lint
npm --prefix web run format:check
npm --prefix web run build
lua5.1 tests/lua/telemetry/run-bridge.lua
lua5.1 tests/dcs/run-telemetry-bridge-prod-mock.lua
stylua --check src/missions/duel-dynamic/telemetry hooks tests/lua/telemetry tests/dcs
```

Use the repository's configured Lua 5.1 runner/environment if the executable is
not on PATH; report unavailable tooling rather than claiming a pass. Add exact
new service/browser test commands to each handoff when those harnesses exist.
Shipping build and real deployment commands remain the documented owner-gated
procedures, not implicit side effects of these test commands.

## 7. Explicit non-goals and completion rule

No user accounts, multi-host active-active collectors, automatic pruning,
subsecond SLA, hook networking/IPC, shipping de-sanitization, hosted realtime,
database listener, broad source-contract redesign, new tracked asset categories,
or recovery promise for unspooled/power-loss data.

Completion requires the relevant tests and real acceptance evidence, final diff
review and owner checkpoint. Label each part offline-complete, feasibility-only,
live-partial, live-passed or not implemented accurately. Neither a successful
mock nor the recorded five-event lifecycle run closes the complete near-live
dashboard contract.

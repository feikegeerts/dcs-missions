# Slice 18.5-c Windows collector runbook

## Boundary and fixed state

These are owner-gated instructions. This slice does not install a service,
register a task, acquire WinSW, or provision a credential. Prefer WinSW; use the
Scheduled Task only when a service is not approved. Never make it a repeating or
per-second launcher.

The confirmed input path is
`C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\telemetry\`. The owner
must choose one fixed local state directory. Reuse it across upgrades and
restarts: SQLite/WAL, cursors, retry and circuit deadlines, lifecycle outbox,
source tails, and ownership metadata are recovery state. A normal restart must
never select or initialize a fresh state directory.

## WinSW installation design (owner/admin)

1. Build with Node 22+ and stage `collector/dist`, runtime dependencies, and the
   telemetry schema at fixed paths outside a mutable checkout.
2. In an approved network session, obtain a reviewed WinSW binary and verify its
   publisher/hash. Binary acquisition is intentionally not automated.
3. Create a dedicated non-administrator identity with no interactive login and
   “Log on as a service”. Grant only read/execute on Node and collector files,
   read on the schema and input, and modify on fixed state/log directories.
4. Render `collector/ops/dcs-telemetry-collector.xml.template` outside the repo.
   Replace every placeholder with an absolute path, fixed lock port, and the
   dedicated identity. Keep the URL exactly
   `https://dcs-missions.vercel.app`. The 30-second WinSW stop timeout exceeds
   the collector's 15-second bounded shutdown. Recovery waits 10 seconds and
   logs rotate at 10 MiB with ten files retained.
5. Install/start WinSW only in the approved admin window. Confirm Automatic
   (Delayed Start), the restricted log-on identity, recovery delay, fixed paths,
   and stop timeout in Services. This runbook does not use `sc.exe`.

### Service-private token

Copy `collector/ops/collector-service-settings.template` to
`{{SERVICE_SETTINGS_FILE}}` outside the repo. **Before populating it**, disable
inherited ACLs and grant read only to Administrators, SYSTEM, and the dedicated
collector identity. The owner then replaces `{{TELEMETRY_INGEST_TOKEN}}` without
printing it. The rendered file must not enter source, artifacts, tickets, logs,
or broadly readable backups.

The template wraps the token value in double quotes and the owner pastes the raw
token between the existing quotes (no added quotes). This is required, not
cosmetic: WinSW and the boot task both start Node with Node's `--env-file`,
which uses dotenv-style parsing where `#` starts an inline comment, so an
unquoted token containing `#` is truncated at the first `#` and the ingest
endpoint rejects the request with HTTP 401. Keep the quotes.

Never define the token globally at machine or user scope: DCS must not inherit
it. WinSW starts Node with Node's `--env-file`, so the wrapper has no token-bearing
environment. The collector starts exactly one helper subprocess: the lifecycle
CIM query (`powershell.exe`, short-lived, non-interactive). It runs with a
token-stripped environment: `childProcessEnv` in `collector/src/abort-signal.ts`
removes `TELEMETRY_INGEST_TOKEN` and other obviously secret-named variables
before the call. Do not add token-inheriting shell wrappers, hooks, uploaders,
or diagnostics; any new subprocess must run through `childProcessEnv`.
Restrict the rendered XML too.

## Boot Scheduled Task fallback

If WinSW cannot be approved, render and import
`collector/ops/dcs-telemetry-collector-task.xml.template` through Task Scheduler
under the same restricted identity. It has one delayed boot trigger, starts Node
directly with the private settings file, ignores overlap, and permits only three
restarts one minute apart. It has no repeating trigger. Never enable it while
WinSW is enabled.

## Restricted-identity acceptance procedure

During an owner-approved local window:

1. Verify the identity has the narrow accesses above and cannot read unrelated
   user data.
2. Start once. After the first bounded reconciliation pass, expect one JSON
   `kind: "recovery"` line with lock, run/backlog, circuit, and lifecycle state.
3. Start a second process with identical input/state/port. It must exit 3 via
   `OwnershipConflictError` without changing state.
4. Stop through the manager. Normal stop performs a final bounded pass and exits
   zero. A delivery still running after 15 seconds yields exit 1; WinSW allows
   30 seconds before terminating it.
5. Reboot with DCS stopped. Confirm the collector starts independently, then
   starts collecting when DCS later writes telemetry.

Live install/boot/restart/duplicate/restricted-identity checks remain owner-gated.

## `--status` field guide

Run the staged service entry point without loading the token file:

`node <service.js> --status --input <input> --state <state> --schema <schema> --url https://dcs-missions.vercel.app --lock-port <port>`

Existing fields remain unchanged: `lock`, `spool_runs`, `delivery_health`,
`delivery_retry_state`, `delivery_circuit`, `lifecycle_outbox`, and
`source_tails`. Additive `operational_status` contains:

- `backlog.runs`: undelivered count, UTF-8 JSON bytes, oldest time, and age per
  run; `backlog.aggregate` totals them.
- `disk.input` / `disk.state`: decimal-string available/free/total bytes, or
  nulls plus an inspection error.
- `last_successful_delivery` and `next_retry_deadline` (run, lifecycle, or
  circuit deadline).
- `quarantine.reasons` and `blocks` with operator-visible reasons.
- `lifecycle.pending`, `pending_unknown_tail`, and `source_tail.uncertain`.

Status is lock-free/read-only and never includes the token. A corruption/read
error is a failed status command, not an empty healthy spool.

## Recovery scenarios

### Network outage or authentication failure

Keep the service running: collection continues while `network-failure` logs and
durable backoff/circuit deadlines remain visible. A 401/403 circuit survives
restart; fix the private token through the owner procedure and await its probe.
Do not edit deadlines or delete SQLite. Authenticated redirects are never
followed and retry later. Only the pinned HTTPS origin is production-approved;
HTTP(S) numeric loopback is reserved for the offline injected test double.

### Disk exhaustion or capture failure

OS/SQLite full-disk failures log `kind: "disk-exhaustion"` with collection as
the component. Passes remain bounded and the process does not intentionally
crash-loop, but capture is halted until durable writes succeed. Free space
without deleting state/input, check both disk fields, and observe cursor/backlog
progress. Missing, unreadable, or otherwise failed source capture logs
`kind: "capture-failure"`. Error strings are token-redacted.

### Suspected SQLite corruption

Stop the service. Preserve the complete ACL-restricted state directory,
including `-wal` and `-shm`, and record the honest status error. Perform an
owner-approved SQLite integrity/recovery procedure on a copy. Never prune or
silently create fresh state. Resume with a verified recovered database, or only
after an explicit documented owner data-loss decision preserving abandoned
cursor/dedup/lifecycle evidence.

## Logs, retention, and uninstall

WinSW captures JSON stdout/stderr under `{{LOG_DIR}}` with configured rotation.
Stable operational kinds include `recovery`, `network-failure`,
`disk-exhaustion`, and `capture-failure`. Restrict logs and never dump the
settings file or process environment.

NDJSON and SQLite retention is unbounded. No automatic prune exists.
`delivery prune` remains manual and refuses active, lifecycle-pending, and
blocked runs.

To uninstall, stop WinSW (or disable/stop the task), verify lock release, then
use WinSW's approved uninstall operation or delete the task in Task Scheduler.
Revoke service-logon rights and retire the private settings only after review.
Preserve state/input with restricted ACLs; uninstall never implies deletion or
prune.

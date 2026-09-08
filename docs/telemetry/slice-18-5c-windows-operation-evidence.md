# Slice 18.5-c Windows operation evidence

Date: 2026-09-08. Scope: offline collector operation/recovery only. No service,
task, DCS, network, credential, web route, database migration, or remote database
operation was performed.

## Changed-file map

- `collector/src/delivery.ts`: canonical origin allowlist, production HTTPS
  requirement, and manual authenticated redirect/final-URL checks shared by
  ingest and lifecycle POSTs.
- `collector/src/service.ts`: configuration-time URL validation, startup
  recovery summary, stable operational error kinds with whole-log string
  redaction, and additive local `--status` fields.
- `collector/src/spool.ts`: read-only backlog-byte/age source query and grouped
  quarantine reason query. No table, schema, migration, or PRAGMA changed.
- `collector/tests/delivery.test.ts`: origin, loopback, redirect, URL-drift, and
  lifecycle redirect coverage. Existing fake destination moved to numeric
  loopback to satisfy the allowlist.
- `collector/tests/durable-delivery.test.ts`: existing fake destination moved to
  numeric loopback; retry/circuit behavior assertions are unchanged.
- `collector/tests/service.test.ts`: recovery summary and stable/redacted
  network, disk, and capture log taxonomy.
- `collector/tests/spool.test.ts`: explicit pending-lifecycle, blocked, and
  active-run prune guards.
- `collector/tests/windows-operation.test.ts`: complete additive operational
  status shape, disk inspection, and token-absence test.
- `collector/ops/dcs-telemetry-collector.xml.template`: fixed-path WinSW
  template with dedicated identity, automatic delayed start, 10-second failure
  restart, 30-second stop timeout, and rolling logs.
- `collector/ops/dcs-telemetry-collector-task.xml.template`: boot-only fallback
  with no repeating trigger, overlap guard, and bounded restart count/delay.
- `collector/ops/collector-service-settings.template`: fake token placeholder
  for an ACL-restricted file rendered outside the repository.
- `collector/ops/README.md`: template/runbook pointer.
- `docs/telemetry/slice-18-5c-windows-runbook.md`: owner-gated install, secret,
  boot, verification, status, recovery, retention, logs, and uninstall guide.
- This evidence document.

`collector/src/cli.ts` was not changed; one-shot collection behavior remains
covered by the existing collector CLI tests.

## Requirement-to-test map

| Requirement                         | Automated/offline evidence                                                                                                                                                                                                                                                      |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WinSW lifecycle/template            | Template inspection; 30 s stop exceeds the tested existing 15 s service shutdown. Live installation remains gated.                                                                                                                                                              |
| Secret-private design and redaction | `service.test.ts` “classifies disk exhaustion and capture failures with redaction”; `windows-operation.test.ts` status serialization excludes `dummy-test-token`; inert settings placeholder inspection.                                                                        |
| HTTPS/origin/redirect hardening     | `delivery.test.ts` “allows the documented HTTP loopback…”, “rejects non-HTTPS production and non-allowlisted origins…”, two 302 cases with/without `Location`, final URL drift, and lifecycle 307. Existing delivery tests continue to verify status/backoff/circuit semantics. |
| Status fields                       | `windows-operation.test.ts` verifies per-run/aggregate backlog count/bytes, disk free space, last success, next retry, quarantine/block reasons, lifecycle pending/unknown tail, source-tail uncertainty, and no token.                                                         |
| Logging taxonomy                    | `service.test.ts` verifies `network-failure`, `disk-exhaustion`, `capture-failure`, and redaction.                                                                                                                                                                              |
| No automatic prune                  | Source search finds `pruneDeliveredRuns` only in `DurableSpool` and manual `delivery-cli.ts` prune mode. `spool.test.ts` verifies pending, blocked, and active fully acknowledged runs are retained.                                                                            |
| Startup recovery                    | `service.test.ts` verifies one post-reconciliation `recovery` line with lock/run/backlog/circuit/lifecycle fields. Existing `durable-delivery.test.ts` verifies restart persistence for retries, circuit, and lifecycle; existing `ownership.test.ts` verifies cursor restart.  |
| Duplicate startup                   | Existing `ownership.test.ts` verifies same ownership rejection and mutable CLI exit 3 while read-only status remains available.                                                                                                                                                 |
| Runbook/recovery                    | Runbook inspection covers restricted identity, boot independence, fallback, outage, disk, corruption, rotation, status, no prune, and uninstall.                                                                                                                                |

## Acceptance battery

- Baseline before edits: `npm run check` in `collector/` — 9 files / 109 tests
  passed, exit 0.
- Final `npm run check` in `collector/` — format, lint, typecheck, and 10 files /
  **119 tests passed**, exit 0.
- `git diff --check` — exit 0.
- `git diff --stat HEAD -- web src hooks contracts build` produced only the
  pre-existing `hooks/` and `src/` diff, not empty, because those frozen changes
  were present before this slice. A before/after path audit confirms this slice
  did not change those files; see “File-set audit”.
- No network command, package install, remote DB access, DCS operation, WinSW,
  `sc.exe`, or Scheduled Task command was run.

## File-set audit

The pre-change porcelain baseline contained `.gitignore`, two hook/mission
files, two Lua test files, and three untracked earlier evidence documents. The
final status adds only the whitelisted collector source/tests/ops files and the
two Slice 18.5-c documents listed above. No `web/**`, `contracts/**`, `build/**`,
`out/**`, existing docs, package manifest/lockfile, hook, or mission file was
changed by this work.

The requested frozen-tree command cannot literally be empty against `HEAD`:
the supplied baseline already had changes under `src/` and `hooks/`. Its output
is unchanged from the baseline (315/12-line tracked-file stats shown before
implementation). This is recorded rather than erasing another writer's work.

## Recorded assumptions for owner review

1. The production allowlist is exactly
   `https://dcs-missions.vercel.app`. Numeric `127.0.0.1` and `[::1]`, with HTTP
   or HTTPS and an explicit test port, are the only offline test-double
   exceptions. `localhost` and every other host are rejected.
2. Native Node fetch supplies `Response.url`; production therefore requires an
   exact match with the authenticated request URL. Injected synthetic `Response`
   objects may have an empty URL, interpreted as the test double reporting no
   drift. Tests separately inject a non-empty changed URL and prove rejection.
3. Disk byte values are decimal strings to avoid JSON precision loss.
4. The owner must validate the rendered templates against the acquired WinSW
   version and chosen account type before installation. No binary was acquired.
5. The production state path, service identity, lock port, and installation/log
   roots remain explicit owner choices; the input path is owner-confirmed.

## Residual risks / owner-gated evidence

- Actual WinSW install, boot, stop/restart, duplicate-start attempt,
  restricted-identity ACL test, log rotation, and uninstall were not executed.
- WinSW acquisition/hash review is an owner-gated network step.
- Secret creation and ACL provisioning were not performed. A rendered settings
  file is sensitive even though the repository template contains only
  `{{TELEMETRY_INGEST_TOKEN}}`.
- Scheduled Task import/start/recovery behavior was not exercised.
- No real network outage, disk-full volume, or corrupt production SQLite file
  was created. Those destructive/live drills remain owner-gated; offline tests
  cover classification and durable state semantics.
- The dashboard Collector Health POST/web mechanism, schema/API migration,
  latency targets, and query budget remain explicitly out of scope pending owner
  decisions.

## Orchestrator verification addendum (2026-09-08)

Independent re-verification by the orchestrator (worker confidence not
trusted): fresh `npm run check` green (10 files / 119 tests at the time of this
addendum, see final count below); frozen trees `web/` `contracts/` `build/`
untouched; the uncommitted S17-p5/p6 mission-Lua diff preserved byte-identical;
no `collector/package.json` / `package-lock.json` change; HEAD `c60df3f`;
dev `.miz` unchanged.

Subprocess finding + fix (orchestrator-performed, within this item's
"do not propagate token-bearing environments to subprocesses" bullet):
`defaultProcessObservationProvider` (S16-p5/p8) calls `execFileSync(
"powershell.exe", ...)` for the lifecycle CIM query WITHOUT an `env` option,
so the child inherited the full service environment, including
`TELEMETRY_INGEST_TOKEN` when the service runs with `--env-file`. Fixed by
adding exported `childProcessEnv` (strips `TELEMETRY_INGEST_TOKEN` plus
obviously secret-named variables: `*(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|
APIKEY|CREDENTIALS?)` suffixes) and passing `env: childProcessEnv()` to the
CIM call. Two new tests in `collector/tests/abort-signal.test.ts` (provider
path: captured child env has no token but keeps `PATH`; helper unit: secret
names stripped, source not mutated). The runbook's "the collector starts no
subprocesses" sentence was factually wrong and has been corrected to document
the single CIM helper subprocess and the token-stripped environment.
Final battery after this addendum: `npm run check` green (10 files / 121
tests), `git diff --check` 0.

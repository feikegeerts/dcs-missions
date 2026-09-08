# Slice 18.5 part A — persistent collection evidence

Date: 2026-09-07. Scope: persistent single-owner collection only. No S18.5-b
fairness, durable retry deadline, lifecycle outbox, or authentication-circuit
work is included.

## Mechanism and reasoning

### Ownership

`collector/src/ownership.ts` canonicalizes existing input, state, and schema
paths with `realpathSync.native`; it creates the state directory first. On
Windows, canonical paths are lower-cased after realpath resolution because the
host filesystem is case-insensitive while Node preserves the caller's path
casing. This makes drive-letter/directory case variants select the same lock.

The owner binds an exclusive Node TCP server to `127.0.0.1`. The default port
is computed by 32-bit FNV-1a over the canonical input path's UTF-8 bytes, using
the offset basis `0x811c9dc5` and `Math.imul(hash, 0x01000193)`, then mapped as:

```text
20000 + (unsigned_hash % 20000)
```

`--lock-port` can override that value. The listening socket is the authority;
the kernel releases it after clean exit, crash, or hard kill, so there is no
stale lock to steal or clean up. `owner.json` is a best-effort, single-line
diagnostic record and is deliberately retained on release. A failed bind is
never stolen. If the requested state contains matching diagnostics, the error
identifies PID, port, state, and acquisition time. Missing, unreadable, or
malformed diagnostics produce the honest unknown-process rejection.

The resident service holds the socket for its lifetime. Non-dry-run collection
and delivery/prune fallback commands acquire it before opening a mutable spool;
conflicts exit 3. Collection dry-run and both status paths do not acquire it.
Collection dry-run opens an existing spool read-only or uses an in-memory empty
spool, and service status opens an existing SQLite file read-only. Delivery and
prune accept `--input` for explicit source binding. For backward compatibility
with the prior state-only delivery CLI, they otherwise use the lifecycle-bound
input, retained `owner.json` input, or finally the state directory. Operators
should pass `--input` for a state that has never been owned by collection.

### Bounded collection

`CollectorOptions.maxBytesPerPass` defaults to `Infinity`. That default retains
the one-shot fallback's whole-remainder allocation and one-pass drain. A finite
service budget is shared across sorted files and charged by bytes actually read.
Each visited file allocates at most the remaining pass budget, processes only
newline-terminated records, and advances the durable cursor only after event or
quarantine persistence. Bytes after the last newline in the window remain
behind the cursor for a later pass. Existing UTF-8, CRLF, JSON/schema,
one-run-per-file, identity, truncation, crash-ordering, and dry-run semantics are
unchanged. Summaries add `bytes_read` and explicit identity/truncation incident
records without changing existing fields.

The service default is 2 MiB per cycle. Thus one collection callback performs
at most 2,097,152 bytes of synchronous file parsing plus the persistence work
for complete lines contained in those bytes; shutdown also performs only one
such bounded pass. There is no synchronous backlog drain loop. After each pass,
control returns to Node so delivery continuations and process signals can run.

### Scheduler and shutdown

`ServiceController` owns two independent recursive timers, both defaulting to
5,000 ms. Collection is one synchronous bounded pass per tick. Delivery is an
independent async call to the existing `deliver()` implementation; an in-flight
guard prevents stacked delivery passes while allowing collection ticks to
continue during an awaited fetch. The service defaults to
`https://dcs-missions.vercel.app`, reads the token only from
`TELEMETRY_INGEST_TOKEN`, skips delivery without stopping collection when it is
absent, and redacts it from caught errors.

SIGINT/SIGTERM cancels both timers, runs one final bounded collection pass,
waits for an existing delivery pass, closes SQLite, and releases the socket.
The command force-exits 1 if the 15-second shutdown bound expires; normal
shutdown emits/exits 0.

## Test-to-exit map

| Exit concern | Evidence |
| --- | --- |
| Windows duplicate owner | `ownership.test.ts`: same owner, case alias, second state, independent sources, status while held, mutable CLI exit 3/read-only CLI access, and child hard-kill release |
| Partial write | `service-collection.test.ts`: cursor stops at the final newline and appending the remainder spools exactly once |
| Large backlog | `service-collection.test.ts`: a two-file backlog drains over repeated 1,500-byte passes with every pass at or below budget and zero duplicates |
| Integrity reporting | `service-collection.test.ts`: replacement and truncation produce incidents and safe replay/deduplication |
| Independent schedules | `service.test.ts`: a pending fetch spans another collection tick without concurrent delivery passes |
| Missing token / delivery error | `service.test.ts`: collection continues, missing-token decision is logged once, later delivery ticks retry, and synthetic token text is absent from logs |
| Graceful stop | `service.test.ts`: final bounded pass, spool close, exit event 0, and immediate reacquisition |
| Restart persistence | `ownership.test.ts`: built service process stops mid-line, restarts against the same state, and persists exactly the remaining line |
| Manual fallback | Existing 87 tests remain unchanged and green; the new unbounded assertion drains a complete file in one default pass; CLI ownership tests show fallback works only when ownership is available |

The 15 new tests bring the collector suite from 5 files / 87 tests to 8 files /
102 tests. The existing 87 tests were not edited.

## Acceptance results

| Check | Baseline | Final |
| --- | --- | --- |
| `npm --prefix collector run check` | 5 files / 87 tests | exit 0; 8 files / 102 tests |
| `npm --prefix collector run build` | exit 0 | exit 0 |
| `npm --prefix web run test` | 20 files / 187 tests | exit 0; 20 files / 187 tests |
| web typecheck / lint / format check | exit 0 | all exit 0 |
| Lua telemetry bridge | 40 passed | 40 passed |
| production bridge mock | 52 checks | 52 checks across both mappings |
| `stylua --check .` | exit 0 | exit 0 |
| `git diff --check` | exit 0 | exit 0 |

No test used a real network endpoint; service HTTP behavior used injected
`fetchImpl` stubs. No DCS/server operation or credential access occurred.

## File-set audit

Final `git status --porcelain`:

```text
 M .gitignore
 M collector/package.json
 M collector/src/cli.ts
 M collector/src/collector.ts
 M collector/src/delivery-cli.ts
 M collector/src/spool.ts
 M docs/telemetry/slice-18-5-near-live-plan.md
 M web/src/telemetry/expenditures.ts
 M web/tests/expenditures.test.ts
?? collector/src/ownership.ts
?? collector/src/service.ts
?? collector/tests/ownership.test.ts
?? collector/tests/service-collection.test.ts
?? collector/tests/service.test.ts
?? docs/telemetry/slice-18-5-partA-persistent-collection-evidence.md
```

The pre-existing owner/orchestrator changes in `.gitignore`, the near-live plan,
and the two web expenditure files were preserved. No other frozen path changed.
`collector/package-lock.json` is unchanged. `spool.ts` has only an additive
read-only-open option; migration SQL and PRAGMAs for mutable opens are unchanged.

## Residual risks and deferred work

- FNV-1a can map distinct inputs to the same port. The second owner is rejected
  safely. With a different state directory its local `owner.json` cannot name
  the first owner, so the required unknown-process conflict is reported.
- A state-only legacy delivery/prune invocation with neither lifecycle input nor
  retained owner diagnostics cannot infer source ownership. It locks the state;
  use the added `--input` option for canonical source exclusion.
- The bounded collector intentionally retains a cursor before an incomplete
  line. A single line larger than the configured cycle-byte cap cannot complete
  under that cap; the 2 MiB service default is above normal schema-valid event
  sizes, and operators can raise `--max-cycle-bytes` if needed.
- Integrity incidents are pass summaries/log records, not separately persisted
  incident history. Expanded health persistence/alerting remains later scope.
- Delivery fairness, persisted retry deadlines/backoff, lifecycle outbox, and
  401/403 circuit behavior remain explicitly deferred to S18.5-b.
- The unbounded one-shot collection pass remains intentionally available as the
  controlled manual fallback after the resident service stops.

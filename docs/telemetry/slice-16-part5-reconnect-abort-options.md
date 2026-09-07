# Slice 16 Part 5 (options): reconnect-based abort — design options

**Date:** 2026-09-07. **Status: design options only — NO implementation, NO
decision.** This document exists so the owner can decide the one remaining
half of Slice 16 without guessing. It contains no code changes and no
schema changes.

## The open item

Plan §Slice 16, last scope bullet:

> Mark the previous run aborted when the same producer starts a
> replacement run, **or when the validated bridge/collector confirms that
> no run remains active after reconnecting**.

First half (replacement run) is implemented and verified (S16-p1:
`abortSupersededRuns`, called when the ingested batch is the first for a
new `run_key`). The second half — "no run remains active after
reconnecting" — was explicitly deferred by S16-p1 to "the Slice 17
bridge/collector work", but S17 was scoped as mission bridge / hook /
packaging only, so it was never a discrete S17 part. Its precondition (a
production bridge that spools runs) is now met by S17.

The governing constraint is the Slice 16 exit criterion:

> interrupted runs are classified **without treating a temporary network
> outage as a mission abort**

and the companion scope bullet: heartbeat age shows a run as `stale`
(display-only) "because an API outage is indistinguishable from a stopped
mission **at the web boundary**."

## What the system already does (verified, no change)

- Stored statuses: `active | aborted | ended`. Only `mission.ended`
  produces `ended`; only the replacement rule produces `aborted` today.
- Display: `displayRunStatus` — `active` older than `STALE_AFTER_MS`
  (10 min) shows `stale`; stored `aborted`/`ended` pass through as-is
  (`web/src/telemetry/run-status.ts`).
- Upsert ratchet (`web/src/telemetry/store.ts:243`):
  `CASE WHEN EXCLUDED.status = 'ended' THEN 'ended' ELSE <existing> END`.
  Consequences that any design must preserve:
  - a late `mission.ended` batch **can** upgrade a stored `aborted` to
    `ended` (self-heals a premature abort when the final event arrives
      after an abort signal);
  - a late `active` batch can **never** resurrect `aborted` or `ended`.
- The web's only write endpoint is `POST /api/telemetry/ingest`
  (`web/src/app/api/telemetry/ingest/route.ts`); every other API route is
  read-only.

## Signal sources a "validated" observer actually has

The plan's phrase "validated bridge/collector" is key: the source must be
able to distinguish a stopped mission from an outage. Available signals:

| Source | What it can observe | Fires on |
|---|---|---|
| Mission-side bridge (`bridge.lua` / `lifecycle.lua`) | DCS `OnEventMissionEnd` | **clean mission end only** (emits `mission.ended`, reason `mission-end-observed`). A crashed/dead process emits nothing. |
| GameGUI hook (host-side, unsanitized) | `onSimulationStop` → writes `TELEMETRY_BRIDGE_HOOK STOP generation=N …` to `dcs.log` | **clean simulation stop only** (WebGUI stop, end-of-day). Not on process crash. Also confirms the final best-effort drain ran. |
| Collector (host-side standalone CLI) | its own spool (full event stream incl. whether `mission.ended` is present), `dcs.log` on the host filesystem, and — being a host process — whether the DCS server process is running | runs when the operator invokes `collect`/`deliver`. "After reconnecting" in the current manual-CLI model means "on the next `deliver` invocation" (the Slice 18.5 auto-poller is notes-only/deferred, so there is no live poller yet). |
| Web boundary | ingested events + stored state only | **cannot validate** — the outage/stop ambiguity the plan forbids resolving here. |

A crash leaves **no in-mission signal at all**; the only post-crash
evidence is host-side (process gone; or, for a clean stop, the hook's
`STOP` line in `dcs.log`).

## Options

### Option A — web-side stored abort after heartbeat age

After a long threshold (e.g. 15 min without events), the web marks the
run `aborted` in storage.

- **Rejected.** This is exactly the failure the exit criterion forbids:
  a 15-minute collector/network outage produces a stored `aborted` even
  though the mission is fine. The late `mission.ended` ratchet self-heals
  some cases (→ `ended`), but a pure outage followed by a normal run
  still gets misclassified for its duration, and the display would show
  `aborted` (authoritative styling) for what was an outage. The plan
  already rejected this inference *at the display layer*; storing it does
  not remove the information-theoretic ambiguity.

### Option B — mission-side explicit abort event

Add a new protocol event (e.g. `mission.aborted`) emitted by the bridge.

- **Rejected (redundant).** The mission can only emit it while alive. A
  clean end already emits `mission.ended` (run → `ended`, the better
  classification). The crash case — the only one that needs `aborted` —
  is precisely when the emitting process is dead. No mission-side signal
  can cover the target case.

### Option C — collector-validated host-side signal (recommended)

The collector — a host-side process with access to the DCS host — confirms
"no run remains active" and tells the web.

**Evidence (either is sufficient, both are validated host-side facts):**

1. **DCS process not running** (host process check from the collector;
   the `DCS_server` process, see Recommended defaults #1). Covers
   process crash/kill — the case no other option covers. A crashed
   process emits no `STOP` line, so this is the *only* crash-case gate.
2. **Hook `STOP` line present in `dcs.log`** for the current generation
   (clean stop; also proves the hook's final drain ran). Covers the
   WebGUI-stop case without relying on `mission.ended` surviving the
   final seconds. **Format pinned from the hook source (2026-09-07):**
   `log.write("TELEMETRY_BRIDGE_HOOK", INFO, ...)` (hook line 22–24,
   tag at line 13), emitted by `onSimulationStop` (hook lines 765–783):
   `TELEMETRY_BRIDGE_HOOK STOP generation=N spooled=M spool=<absolute
   spool path> failures=F stuck=<s|nil> unspooled=<u|0>` (example line
   in `slice-17-part2-hook-evidence.md` line 101). The `spool=` field
   embeds the run's spool path (`<writedir>Logs\telemetry\<run_key>
   .ndjson`), so the basename is the `run_key` — the collector maps a
   STOP line to a run directly, with no generation→run table.
   `failures`/`stuck`/`unspooled` report final-drain health; a spooled
   `mission.ended` supersedes the abort signal entirely (the guarded
   web update is a no-op on non-`active` runs).

   **Gate semantics (refined 2026-09-07):** the signal is sent per run
   only when (a) the `DCS_server` process is not running AND the run's
   last spooled event is not `mission.ended` (crash OR clean stop where
   the final drain missed the end batch), OR (b) a STOP line for that
   run's spool path exists (clean stop, even if the process has not
   fully exited yet). While the process is running and no STOP line
   exists for the run — the pure outage / active-mission case — no
   signal is ever sent.

**Mechanics (sketch, not implementation):**

- **Collector side:** at `deliver` time, for each run in the spool whose
  last event is not `mission.ended`, evaluate the two evidence sources;
  if confirmed, include a run-control signal for that run in the delivery
  (e.g. additive field on the existing ingest batch, or a small separate
  call). Idempotent: the signal is a no-op once the run is no longer
  `active`. **Insertion point pinned from `collector/src/delivery.ts`
  (2026-09-07):** `deliver()` reads the spooled run list
  (`initialRuns`) and iterates it per run (the `for (const run of
  initialRuns)` loop, line 125; per-run work in `deliverRun`, line
  151). The abort-signal evaluation slots in around that loop (run list
  already in hand; spool access available), with the STOP-line scan +
  process check done once per `deliver` invocation (not per run).
- **Web side:** a guarded, idempotent update mirroring the
  `abortSupersededRuns` pattern:
  `UPDATE mission_runs SET status = 'aborted', updated_at = now() WHERE
  producer_id = $1 AND run_key = $2 AND status = 'active'`. No schema
  migration needed (`status` is a free-text column); a reason enum
  (e.g. `dcs-process-not-running`, `simulation-stop-observed`) is
  additive in the request body and can be logged/stored as needed.
- **Ratchet preserved:** a late `mission.ended` still upgrades
  `aborted` → `ended`, so a signal that races the final event (clean stop
  observed just before the last `mission.ended` batch lands) self-heals to
  the correct terminal status.
- **Outage safety:** a pure API/network outage leaves the DCS process
  running and no `STOP` line — no signal is sent, the run stays
  `active`/`stale` display, and the exit criterion holds.

**Offline-verifiable:** the web guarded-update handler is testable with the
existing `MemoryStore` fake (same style as the S16-p1 abort tests); the
collector detector is testable with a fake process list + fake `dcs.log`
text + the in-memory spool (same style as S16-p4a/b fakes). No live DCS
needed to verify the logic; a live dedicated-server run would still be the
owner-gated end-to-end check (alongside S17-p4).

**Scope:** collector (`delivery.ts`/`spool.ts` + CLI) + one web control
path + docs; no migration; no contract event change if carried as an
additive ingest field.

**Open sub-decisions the owner would make under C:**

1. Process-detection details: which process name / DCS channel to check on
   this host (dedicated server channel name can vary — confirm the exact
   executable/process pattern before implementing).
2. Endpoint shape: additive field on `POST /api/telemetry/ingest` vs a
   new `POST /api/telemetry/runs/[runId]/status` control route.
3. Where the signal is recorded: request-log only, or persisted
   (e.g. `delivery_health` column / new `run_control` table).
4. Whether the collector should also send the signal for runs it knows
   were superseded (redundant with the replacement rule but harmless if
   guarded).

**Recommended defaults (owner to confirm — NOT a decision, NOT
implementation):** if the owner picks **C**, the four sub-decisions above
default to the following so the item can be approved in one line ("C with
the defaults") and queued as "S16-p5":

1. **Process detection** — "no `DCS_server` process in the host process
   list" = process-not-running evidence. **Verified offline 2026-09-07:**
   the dedicated-server main executable is `D:\DCS World Server\bin\
   DCS_server.exe` (26.6 MB); the same install's `Scripts\MissionScripting
   .lua` is the stock 636 B file the live teardowns reference, confirming
   this is the exact live-run install. The running process name is the exe
   base name, `DCS_server`. Helper executables also live in `bin\`
   (`DCS_updater`, `edCefCrashpadProcess`, `edCefRenderProcess`,
   `edm_tool`, `luae`, `ModelViewer2`) — the authoritative "server is
   running" check is specifically `DCS_server`, not the CEF/updater
   helpers. Key the `dcs.log` read off the dedicated-server write dir
   `C:\Users\g_for\Saved Games\DCS.dcs_serverrelease`. *Remaining live
   check (S17-p4):* confirm at runtime that the process name matches the
   exe base name (no launcher rename/indirection).
2. **Endpoint shape** — a `POST` handler on the **existing**
   `web/src/app/api/telemetry/runs/[runId]/route.ts` (additive body
   `{ reason, ... }`), mirroring the `abortSupersededRuns` guarded
   update. **Pinned 2026-09-07:** that route file already exists and
   exports only `GET` (lines 7–21); a `POST` export in the same file is
   method-dispatched by Next.js — **no new route file needed**, and the
   existing `getRunByRunKey` + 404/error conventions are directly
   reusable. (Variant: a separate `runs/[runId]/status/route.ts`
   sub-route if the owner prefers a distinct URL.) Rationale: keeps the
   hot `ingest` path pure and makes the control action explicit +
   independently unit-testable.
3. **Persistence** — structured **request-log only** for v1 (one line with
   `producer` / `run` / `reason` / affected-count), **no schema
   migration**. A persisted `run_control` log is a follow-up only if the
   owner wants auditability beyond the log.
4. **Redundancy with the replacement rule** — **do not** send the signal
   for already-superseded runs: the web update is guarded to `status='active'`
   so it would be a no-op anyway, but there is no reason to double-send when
   the replacement rule already marks those `aborted`.

These defaults are deliberately minimal (no migration, one control route)
and offline-verifiable (MemoryStore fake for the web guard; fake process
list + fake `dcs.log` + in-memory spool for the collector detector). They do
**not** choose between C and D and do **not** authorize implementation —
the owner still makes the C/D call.

### Option D — minimal interpretation: close the bullet as display-only

Interpret "classified" in the exit criterion as satisfied by the existing
display-only `stale` label plus the replacement-run rule; stored
`aborted` stays reserved for authoritative cases only. Document this
interpretation in the spec; implement nothing.

- Crashed runs remain stored `active` (shown `stale`) until the same
  producer's next run aborts them. No new API surface, no false-abort
  risk, zero code.
- Cost: the letter of the second half of the bullet is unimplemented;
  crashed runs are only discoverable via the display filter, and a
  producer that never runs again leaves a permanently-stale row.

## Comparison

| | False-abort on outage | Covers crash case | New API surface | Scope |
|---|---|---|---|---|
| A (web-side age) | **Yes — violates exit criterion** | No (indistinguishable) | none | tiny |
| B (mission-side event) | No | **No — dead process emits nothing** | contract event | small |
| C (collector host signal) | **No (host-validated evidence only)** | **Yes** | one guarded control path | medium (collector + web) |
| D (display-only closure) | No | No (by design) | none | none (doc only) |

**Recommendation:** **C** — it is the only option that matches the plan's
own wording ("validated bridge/collector confirms") and satisfies the exit
criterion for the crash case. **D** is the acceptable fallback if the
owner wants zero new surface and accepts stale-display as the final
classification for crashed runs.

## Decision required (owner)

Pick one: **C** (with the four sub-decisions above), **D**, or a variant.
Until then this item stays parked; nothing here is an implementation or a
contract change. If C is chosen, it becomes a new bounded queue item
("S16-p5 reconnect-abort signal") split into a web half and a collector
half, both offline-verifiable, with the live end-to-end check folded into
the owner-gated S17-p4 run.
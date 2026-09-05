# Slice 18.5 notes: live push vs automatic delivery on mission stop

**Status:** Notes only, pre-slice. Not approved, not scoped, no implementation.
Recorded 2026-09-05 from the owner's question: "is a live mission-to-Neon
connection possible, or at least automatic push when the server stops a
mission, instead of the manual step?"

Related: `docs/telemetry/bridge-notes.md` (Slice 3 stock bridge spike),
`docs/telemetry/slice-4-lifecycle-evidence.md` (lifecycle + best-effort
`mission.ended`), `docs/telemetry/unattended-test-loop.md` (Slice 8 delivery
+ network-interrupt drill), `docs/telemetry-implementation-plan.md`
Slices 16/17/18/19.

## Current pipeline (what exists today)

1. **Mission → disk (immediate).** `src/missions/duel-dynamic/telemetry/ndjson_sink.lua:write()`
   appends one JSON line per event with `flush()` + `close()` + readback
   verification. "As soon as something happens it's on disk" is already true.
2. **Disk → spool (manual poll).** `collector/src/collector.ts` + `collector/src/cli.ts`
   (`collect --input <telemetry-dir> --state <state-dir>`). Tails `*.ndjson`,
   handles partial lines, validates against
   `contracts/telemetry-event-v1.schema.json`, inserts into
   `collector.sqlite3` via `collector/src/spool.ts`. Runs once and exits —
   there is **no watch mode / daemon**.
3. **Spool → Neon (manual batch POST).** `collector/src/delivery.ts` +
   `collector/src/delivery-cli.ts` (`deliver --state ... --url ...`, token from
   `TELEMETRY_INGEST_TOKEN`). Batches ≤100 events to
   `POST /api/telemetry/ingest` (`web/src/app/api/telemetry/ingest/route.ts`,
   Bearer auth, idempotent on `event_id`).

The manual step the owner wants gone is steps 2–3 (unattended-test-loop
passes A–D + the throwaway `deliver-run.mjs` wrapper).

Fixed plan constraints still apply
(`docs/telemetry-implementation-plan.md` §1): the mission never connects
directly to Vercel/Neon/HTTP; a local collector is the boundary; at-least-once
delivery with idempotent ingestion.

## Is per-event live push possible?

**From mission Lua: no, and we should not try.**

- Stock mission env has no `io`/`os`/`lfs`, no socket, no HTTP client
  (bridge-notes `CHECK stock_mission_sandbox PASS`). There is nothing to POST with.
- Dev (de-sanitized) could `os.execute("curl ...")` per event, but that blocks
  the sim, puts the ingest token in the `.miz`, breaks the shipping build
  (which strips all telemetry), and throws away the Slice 8 durability
  (spool + retry + idempotency). Rejected.

**Via the stock bridge (Slice 3 proven, Slice 17 deferred): still not live DB push.**

- Slice 3 proved the transport: `net.dostring_in("mission", "a_do_script(...)")`
  peeks a mission in-memory queue in 64 KiB NUL-free frames (shifted-return bug
  + sentinel/padding recovery, callable during `onSimulationStop`).
- But the production bridge does not exist yet (deferred to Slice 17), and even
  with it the hook has `io`/`os` but no documented HTTP client — it would still
  be hook-spool-to-disk + an external POST. The bridge solves *stock capture*,
  not *live push*.

**Practical near-live: external watcher on the server box.** A process beside
DCS tails `Logs/telemetry/*.ndjson` and runs the existing collect + deliver
loop every N seconds. Latency is seconds, not milliseconds, and all Slice 8
guarantees are kept. This is the only option that needs no DCS API change and
works with both the dev sink and (later) the Slice 17 bridge spool.

## Automatic push on mission stop (owner's "doesn't have to be live")

Two variants considered:

### A) Hook calls `os.execute(collector)` on `onSimulationStop` / `onMissionLoadEnd`

- Pro: tied to lifecycle, no extra process to install.
- Con: runs *inside* the DCS process — a slow POST blocks a sim callback;
  token lives next to hooks; DCS-version fragile; hard to observe/debug.
- Not recommended.

### B) Standalone poller (recommended shape for 18.5)

- A small loop outside DCS (PowerShell loop / scheduled task / NSSM service):
  every N seconds run `collect()`, then `deliver()`. Treat `mission.ended` as a
  *hint to hurry*, never as a gate.
- Pro: crash-safe, no `MissionScripting.lua` change, reuses the proven CLI,
  survives web outages via the spool (Slice 8 drill: attempt #1 `error`, 0 acks;
  attempt #2 `16/16 accepted`, Neon holds exactly 16 rows, not 32).
- Con: one more process to install/supervise on the server box; needs the token
  in server env and log rotation.

## Load-bearing caveat: `mission.ended` is best-effort

`src/missions/duel-dynamic/telemetry/development.lua` finishes the lifecycle on
`EVENTS.MissionEnd` (`lifecycle.lua:finish()`, idempotent). A killed server
never emits it — Slice 8 already carries 6 such `incomplete` runs that are
still fully delivered (`delivery.ts:finishRunWithoutDeliverables` distinguishes
`complete` from `incomplete`). So the auto-trigger **must deliver regardless of
`ended`**: fire on file-stable-for-N-seconds OR `mission.ended` seen OR
simulation-stop observed; never wait for `ended`.

## Security / scope notes for the future slice

- Token only from server env (never repo, hook file, or `.miz`);
  `delivery-cli.ts` already redacts it from errors.
- No contract/schema change; no mission Lua change expected.
- Manual CLI stays as fallback.
- Suggested acceptance (when scoped): unattended 2-run gate — one clean
  auto-delivery, one web-down-then-up with no loss/dup and zero manual CLI
  invocations — plus no double-delivery on watcher restart.

## Open owner decisions (unanswered 2026-09-05)

1. Watcher host: same box as `DCS_server` always, or dev PC sometimes?
2. Target URL: Vercel production directly, or local `web` dev server during tests?
3. Token storage: env var / server-side `.env` acceptable (never in repo)?
4. Lag target: poll every ~10–15 s during the mission + immediate on stop,
   or strictly only on stop?
5. Backlog policy: deliver all unacked runs, or only the just-finished run?

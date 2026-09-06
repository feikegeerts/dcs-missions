# Slice 14 part 3 evidence

**Date:** 2026-09-06. **Status:** implemented + offline-verified. **Not
live-validated, not committed.**

## Scope

Per-run "Kills & assists" scoreboard view on the run-detail page, built on the
Slice 14 part 2 attacker-based derived facts. Display correctness per the
Slice 14 exit criteria: kills show the actual primary attacker; when the
attacker was not identified the row shows an explicit `unknown — not reported`
— never the victim/target name and never a team total. Presentational only:
one file changed, no new logic, API route, schema, or store method.

### Scope resolution (why not the Lua scoreboard)

Read-only inspection before dispatch confirmed the "current victim-name
fallback" named in the plan's Slice 14 exit criteria is the **in-mission**
kill credit: `score.lua` (`duel_tracker`) with `main.lua` `handleBanditKill`
crediting kills to the string `"Team"` off the victim's `Dead`/`Crash` event
(dedup on the victim unit name). PROJECT-STATUS §6.4 records this explicitly:
kills are "honestly label[led] ... as team totals. Individual attribution
remains planned for telemetry Slice 14." Rewriting that credit to use
attacker attribution would touch frozen `src/` mission code, change live
gameplay messaging, and require an owner-gated live-DCS validation run — out
of scope for the offline UI slice. The fleet/coalition combat scoreboard on
the theater overview is Slice 15 scope (not yet queued). This part therefore
delivers the per-run display that stops attributing kills by victim-name
fallback in the telemetry UI, using the attacker-based `kill_attributions` /
`assist_attributions` facts already produced at ingest. The in-mission team
total remains as-is and is a parked follow-up (owner-gated).

## Files

- `web/src/app/runs/[runId]/page.tsx` — the only changed file.
  - Two new store reads next to the existing `listAssetLosses` read:
    `store.listKillAttributions` / `store.listAssistAttributions`
    (both pre-existed from part 2; queried directly, not via the `/kills`
    HTTP route).
  - Derived display values: `knownKillerCount` (kills with non-null
    `killerAssetKey`), `unknownKillerCount` (the remainder), and
    `sortedKills` / `sortedAssists` sorted ascending by `killingBlowSimTime` /
    `representativeHitSimTime` on **copied arrays** (no store-data mutation).
  - New `<section className="hud-panel col-12">` "Kills &amp; assists" placed
    directly after "Aircraft loss costs" and before "Crew sorties".
    **Not catalogue-gated** (unlike losses): combat attribution carries no
    cost facts, so the section renders regardless of
    `run.valuationCatalogue`.
  - Summary line: `N kills · X known attacker · Y unknown · Z assists`.
  - KILLS table (Target / Killer / Weapon / Sim time): target =
    `targetAssetKey` + `targetDcsType ?? "unknown"`; killer =
    `killerDcsName ?? killerDcsType ?? "unknown"` + `killerCoalition`, or
    literally `unknown — not reported` when `killerAssetKey === null`;
    weapon = `weaponDcsType ?? "—"`; sim time = `killingBlowSimTime`.
  - ASSISTS sub-table (Target / Assisting attacker / Sim time): attacker =
    `attackerDcsName ?? attackerDcsType ?? "unknown"` + `attackerCoalition`;
    sim time = `representativeHitSimTime`.
  - Empty states: "No kills recorded in this run." / "No assists recorded in
    this run."
  - Styling reuses the existing HUD classes (`hud-panel`, `col-12`,
    `hud-subtitle`, `hud-table expandable`, `hud-mono`) to match the loss
    section.

## Hard limits (held)

- Web-only; exactly one file changed (`web/src/app/runs/[runId]/page.tsx`).
- No changes to `contracts/`, any Lua under `src/` (including
  `score.lua`/`main.lua`), `web/src/db/schema.ts`, any `web/drizzle/`
  migration, `store.ts`, `combat-facts.ts`, the `/kills` route, or any other
  file.
- No new store methods, API routes, or queries beyond the two existing
  `list*` methods; no database writes; migration 0004 still NOT applied.
- No commit or push.

## Verification (orchestrator re-ran 2026-09-06; worker report not trusted)

- `git diff -- web/src/app/runs/[runId]/page.tsx` — +161 lines, reviewed
  line-by-line; matches the contract above; unknown-killer branch renders the
  explicit unknown text and no victim/team fallback exists in the new JSX.
- `git status` — S14-p3 adds no files beyond the run page; all other dirty
  paths are the pre-existing S13-p3 / S14-p1 / S14-p2 work (unchanged).
- `npm run typecheck` — exit 0.
- `npm run lint` — exit 0.
- `npm run format:check` — clean (worker ran `format` to normalize; check
  passes).
- `npm run db:generate` — "No schema changes, nothing to migrate" (no drift).
- `npm run build` — exit 0; route table shows `ƒ /runs/[runId]` and
  `ƒ /api/telemetry/runs/[runId]/kills`.
- `npm test` (vitest) — **13 files / 106 tests passed**; identical to the
  S14-p2 baseline (no new tests — the repo has no page-render harness;
  presentational JSX is covered by typecheck/build).
- `git rev-parse HEAD` — `3ff363b`, unchanged; **no commits**.

## Explicitly not done / residual

- **No visual check of populated data** — migration 0004 is not applied and
  no run with `asset.hit` / `asset.kill-reported` events has been ingested,
  so the tables render empty states today. Verifying a populated
  kills/assists view requires the owner-gated 0004 apply + a live-DCS
  hit/kill run (both new approval items).
- In-mission Lua team-credit scoreboard unchanged (parked follow-up,
  owner-gated live validation).
- Fleet/coalition combat scoreboard (theater overview) remains Slice 15.
- No commit or push; all S13/S14 code stays uncommitted in the workspace.
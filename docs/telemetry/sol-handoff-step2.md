# SOL handoff — Step 2: capabilities, wave milestones, mission-scoped history, migration reconciliation

**Historical handoff — completed and merged 2026-09-14.** This file records the
implementation prompt and acceptance criteria that were used for Step 2. Do
not dispatch it again or treat the branch/worktree instructions below as the
current repository state. Current status and remaining live gates are in
`docs/PROJECT-STATUS.md` and
`docs/telemetry/multi-mission-implementation.md`.

The resulting source is merged to `main`; production telemetry acceptance was
performed later under the owner-authorized Slice 18.5 window.

--- COPY BELOW ---

## Goal

Finish multi-mission Step 2 on branch `feature/telemetry-decoupling` (worktree: `C:\Projects\dcs-missions\worktrees\telemetry-decoupling`):

1. Optional reporting capabilities + explicit wave milestones across event contract, mission capture, collector ingest, backend projections, and tests. Preserve legacy runs.
2. Mission-scoped run-history filtering in the database (before pagination), replacing filter-after-global-limit on the mission dossier page.
3. Reconcile Drizzle 0005 metadata gap before generating/applying any migration. No blind reapply of production SQL.

Out of scope: BVR/ACM/Survival gameplay tuning (owner said defaults are fine for now), live DCS validation (separate owner-authorized step), any hook/collector reinstall, any production writes without explicit owner approval.

## Starting state (do not assume — re-verify)

- Branch `feature/telemetry-decoupling` was cut from `8acb82a`. Main has since moved to `83d465e` ("Fix player lives for reused DCS aircraft names"). Rebase or merge main first and resolve conflicts; do not lose the lives fix or the decoupling work.
- Increments 1–4 are done and verified in the worktree (uncommitted):
  - Inc 1: shared telemetry library `src/lib/telemetry/` (14 modules), mission identity in `src/missions/*/config.lua`, shipping packager uses shared location.
  - Inc 2: `src/lib/telemetry/integration.lua` API v1 (register player/opposing, report cleanup, status), failure-safe, hook ABI preserved (`duel_telemetry_bridge`, `duel_telemetry_runtime`, `DDBRIDGE1`).
  - Inc 3: independent entries `src/missions/duel-dynamic(-bvr|-acm)/`, `src/missions/air-superiority-survival/`, shared gameplay `src/gameplay/package-waves.lua` + `package-wave-config.lua` + `score.lua`, explicit `-MissionName` shipping builds with template validation, named dev loading in `src/bootstrap.lua`.
  - Inc 4 (free track): dashboard catalogue + `isWaveMission()` gate generalized to all four package-wave identities, no contract/schema change. Web suite green.
- Full details: `docs/telemetry/multi-mission-implementation.md`, `docs/multi-mission-development.md`.
- Source archives (READ-ONLY, never overwrite): `C:\Users\g_for\Saved Games\DCS\Missions\Telemetry\duel-dynamic-bvr.miz`, `duel-dynamic-acm.miz`, `air-superiority-survival.miz`. All load the main-checkout bootstrap; they have NOT been rebound.
- Known gap: `web/drizzle/meta/_journal.json` has no 0005 entry/snapshot even though 0005 was applied to production directly. Reconcile metadata before any migration work.
- Current dashboard limitation (why Step 2 exists): `summarizeRunWaves` derives waves from `asset.spawned`/`asset.dead| crashed` red events, and the dossier page enables it via mission-key allowlist. There are no explicit wave lifecycle events. The dossier page fetches a global run limit then filters by mission, so a busy mission can hide another mission's history.

## Constraints (hard)

- Lua 5.1 (DCS 5.1.5): no `string.pack`, `goto`, `//`, `table.unpack` (use `unpack`).
- StyLua (`syntax = "Lua51"`) clean on changed Lua; `git diff --check` clean.
- Telemetry disabled/missing/throwing must never stop gameplay (covered by existing failure-isolation tests — keep them green).
- Preserve hook wire compat (`DDBRIDGE1`, bridge globals, source-version value) unless you coordinate a hook+mission rollout explicitly with the owner.
- No secrets/tokens in prompts, logs, or the queue. No production DB writes, deploys, service changes, or mission-archive overwrites without explicit owner approval.
- Keep `duel-dynamic` legacy runs rendering unchanged. Records stay mission-scoped; do not build a cross-mission leaderboard.
- Distinguish "not applicable" (non-wave mission) from "missing telemetry" (wave mission with no wave facts). Distinguish gameplay-over from session-ended.

## Tasks

### A. Capabilities + explicit wave milestones (contract-preserving rollout)

1. Propose additive optional fields only (e.g. run capabilities declared at `mission.started`, optional wave milestone events). Missing = legacy behavior, never a silent zero.
2. Update in order, with tests at each layer:
   - `src/lib/telemetry/envelope.lua` validation (accept legacy + new, reject malformed)
   - capture adapters + `integration.lua` (opt-in mission calls; non-wave missions must not import wave code)
   - collector validation/spool/delivery compatibility (idempotent, in-order, no loss/dup across mission switch)
   - `web` ingest (AJV/contract), projections (`store.ts`, `dashboard.ts`, `replay.ts` as applicable), dossier/run/player pages
3. Keep legacy derivation for old runs; new explicit milestones must not rewrite history.

### B. Mission-scoped history (no silent truncation)

1. Replace dossier-page fetch-then-filter with a mission-filtered, paginated store query (plus high-score completeness handling).
2. Add regression: one busy mission cannot push another mission's valid history out of the window; empty mission shows honest "no runs" state.

### C. Migration reconciliation (before any migration)

1. Inspect `web/drizzle/` + `meta/_journal.json` vs Neon. Reconcile 0005 metadata without reapplying production SQL blindly.
2. Only then generate/apply any new migration the above requires, with owner approval, plus backfill policy (default: no backfill of historical runs).

## Acceptance

- [ ] New capability/wave facts validated end-to-end by contract + Lua + collector + web tests; legacy fixtures still pass unchanged.
- [ ] All four package-wave missions show correct isolated histories, wave summaries, and records; non-wave fixture renders baseline without wave section (not zeros).
- [ ] Busy-mission pagination regression passes; dossier paging + status filters work per mission.
- [ ] Drizzle journal/snapshot consistent; any migration applies cleanly to a fresh shadow DB before touching Neon.
- [ ] Full verification green from the worktree root + `web/`:
  - `python tests/test_telemetry_boundaries.py`
  - `lua5.1 tests/lua/telemetry/run.lua`, `run-json-sink.lua`, `run-lifecycle.lua`, `run-asset.lua`, `run-shot.lua`, `run-participant.lua`, `run-combat.lua`, `run-bridge.lua`, `run-integration.lua`
  - `lua5.1 tests/dcs/run-telemetry-bridge-prod-mock.lua`
  - `lua5.1 tests/lua/run-duel-shared-bandits.lua`, `run-bootstrap-selection.lua`, `run-package-wave-config.lua`
  - `lua5.1 tests/lua/telemetry/run-shipping-integration.lua out/<mission>-build/l10n/DEFAULT/main.lua <mission>` for each built mission
  - `& build/pack-shipping-miz.ps1 -MissionName <each of the 3> -Zip` + `& tests/test-mission-build-selection.ps1`
  - `stylua --check` on changed Lua, `git diff --check`
  - web: `npx vitest run`, `npx tsc --noEmit`, `npm run lint`
- [ ] Final diff inspection; no credentials, no stray `out/*.miz` committed, no source-archive modifications, no service/hook/production changes unless owner-approved.

## Return

Changed files, commands run with results, residual risks, and anything you deliberately left for live validation (BVR → ACM → Survival → BVR rotation, outage across switch, real player capture) — with exact run keys/evidence paths, not confidence statements.

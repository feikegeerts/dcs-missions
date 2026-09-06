# Slice 14 part 1: hit/kill source-event capture — evidence

**Date:** 2026-09-06. **Status:** implemented + offline-verified. **Not
live-validated, not committed.**

## Scope

- Subscribe to MOOSE `EVENTS.Hit` and `EVENTS.Kill` in the duel-dynamic
  telemetry layer and emit the two source event types the **frozen**
  telemetry contract v1 already defines: `asset.hit` and
  `asset.kill-reported`.
- Pinned semantics (plan §4/§7 + contract + fixture 05): tracked-victim
  scope only; attacker = known tracked reference, known untracked aircraft
  (no fabricated `asset_key`/participant), or unknown
  (`"not-reported"` / `"unresolved"` per contract `reason` enum);
  top-level `coalition` follows the **attacker** (or `"unknown"` — pinned by
  `contracts/fixtures/valid/05-unknown-attacker.json`); weapon nullable;
  location = victim, dcs-local; friendly fire retained; kills and losses stay
  separate observations; the existing victim-name kill handler is untouched.

## Files

- `src/missions/duel-dynamic/telemetry/combat.lua` (new): Hit/Kill capture.
  Every DCS object access is pcall-wrapped. Victim resolves against the
  tracked-asset registry (`resolve_unit`, same API as loss capture); an
  untracked victim suppresses emission entirely. Attacker representation:
  tracked → known with `asset_key` (+ `participant_id` for players);
  real-but-untracked aircraft → known with observed labels and
  `asset_key: null` (never fabricated, never a participant for AI);
  nothing reported → unknown `"not-reported"`; something reported but
  unresolvable → unknown `"unresolved"`. Ground/ship categories
  (`Unit.Category` not 0/1) are not claimed as aircraft. `Kill` registers
  only when `EVENTS.Kill` is usable (`S_EVENT_KILL or -1` in the pinned
  MOOSE build); a failed Kill registration rolls back the Hit registration.
  Emission goes through the existing lifecycle `record` path
  (sequence/event-id/sink/logging unchanged).
- `src/missions/duel-dynamic/telemetry/development.lua`: start/stop wiring
  mirroring the shot adapter (pcall-isolated create/start/stop,
  warning-only degradation when the adapter is missing or fails,
  `MY_SCRIPTS_ROOT` development fallback, `runtime.combat` registration).
- `tests/lua/telemetry/run-combat.lua` (new, 11 tests, standalone
  `lua5.1` runner; no central runner list exists in the repo — standalone
  execution is the pattern):
  1. Hit + optional Kill subscriptions retained and removed (incl.
     `Kill = -1` → hit-only, and Kill-registration failure → rollback).
  2. Tracked player killer + tracked victim → contract-shaped `asset.hit`
     and `asset.kill-reported` (initiator `asset_key` + `participant_id`,
     target/asset victim keys, top-level coalition, weapon, payload names).
  3. Not-reported killer → **exactly** the fixture-05 shape (all unknown
     reference fields null, `reason:"not-reported"`, top-level
     `coalition:"unknown"`, weapon null).
  4. Untracked victim → no emission (tracked attacker irrelevant).
  5. Untracked real AI attacker on tracked victim → known aircraft with
     `asset_key: null`, `participant_id: null`, observed labels.
  6. Friendly fire (blue-on-blue, red-on-red) retained with both role
     coalitions.
  7. Repeated hits then one kill → 3 `asset.hit` + exactly 1
     `asset.kill-reported` (separate source observations).
  8. Kill emits no loss event and does not mutate the asset loss state
     (contract: loss observations carry no attacker; attribution comes from
     kill-reported/hit history).
  9. Same victim `dcs_name` across two incarnations → distinct `g1`/`g2`
     `asset_key`s.
  10. Nil/partial attacker or projectile objects (incl. raising methods)
      degrade to unknown `"unresolved"` / unknown location / null weapon
      without raising; errors logged.
  11. Missing runtime config fails construction; raising persistence fails
      closed through pcall isolation with a logged error.

The tests exercise the **real** `envelope`/`lifecycle`/`event_id` modules,
so both event types pass the mission-side taxonomy validation (envelope
L17–18, L1003 — already present; no envelope change).

## MOOSE payload findings (pinned build, `lib\moose-src`)

- `EVENTS.Hit` = `world.event.S_EVENT_HIT` (always present), dispatch name
  `OnEventHit`. `EVENTS.Kill` = `world.event.S_EVENT_KILL or -1`, dispatch
  name `OnEventKill` — version-conditional, hence the optional registration.
- Fields: `IniDCSUnit`/`TgtDCSUnit` (DCS units), `Ini*Name`/`Tgt*Name`,
  `IniGroupName`/`TgtGroupName`, `IniTypeName`/`TgtTypeName`,
  `IniCoalition`/`TgtCoalition`, `IniPlayerName`/`TgtPlayerName`,
  `IniPlayerUCID`/`TgtPlayerUCID`, plus `Weapon`/`WeaponName`.

## Verification (all local, no DCS, no network; orchestrator re-ran 2026-09-06)

- `lua5.1` runners: run.lua 20, run-lifecycle 8, run-shot 10,
  run-json-sink 11, run-participant 9, run-asset 23,
  run-duel-shared-bandits 12, **run-combat 11** = **104 passed** (baseline
  93 + 11 new).
- `stylua --check` on the three task files: clean. `git diff --check`: clean.
- `git status`: exactly three Lua files belong to this item; no contract,
  web, collector, or `main.lua`/`score.lua` changes; no commits.

## Explicitly not done

- No live DCS validation (Hit/Kill events not yet observed from a real
  simulation; `dcs.log` emission lines unverified).
- `Kill` dispatch is version-conditional; on DCS builds without
  `S_EVENT_KILL` only `asset.hit` flows (graceful by design).
- Assist derivation (part 2) awaits the owner's assist rule; no
  kill/assist derived facts are produced by this part.
- No commit or push.
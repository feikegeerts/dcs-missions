# Rejoin lifecycle fix — evidence

**Date:** 2026-09-04. **Commits:** `f4d35f3` (fix) + `d1ec6d3` (docs) on
`main`, pushed to `origin` 2026-09-04. **Status:** code merged and pushed;
**live validation parked** (no human-in-seat drill time this week).

## 1. Failure (live drill, 2026-09-03)

Run `run-20260903T184502Z-0758ed75` — two human players in Aerial-1 and
Aerial-2, dedicated server, de-sanitized dev environment. The run closed
cleanly with 105 gapless events (delivered to production in two passes:
92 + 13, final state `ended`). Observed behavior:

- **Zero `participant.entered` events for either player**, including the
  initial join. Player assets were still registered because `main.lua`'s
  deferred init catches players already seated in roster slots at
  initialization (`aerial-1.u1.g1`, `aerial-2.u1.g1`), which is why player
  ordnance resolved to `asset_key`s early in the run.
- Player 2 disconnected at 19:05:57 UTC and rejoined the same slot at
  19:06:36 UTC. The rejoin produced **no `participant.entered` and no new
  `asset.spawned`** (no second-generation incarnation). DCS recreates the
  unit object on rejoin, so the registry no longer recognized the aircraft.
- Player 2's later shots (seq 81 and 84) therefore carried unknown
  `asset_key` references.
- Bandit waves g1–g5 and all bandit ordnance attribution worked throughout
  (AI units do not depend on the player-entry events).

Raw evidence (PII — local archive only, not in the repo):
`C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Logs\evidence\slice-10-live-drill-20260903-run-184502\`
(final NDJSON, DCS log snapshot, host Tacview recording, README).

## 2. Root cause (verified against the pinned MOOSE build)

1. **Wrong event.** The mission subscribed gameplay and telemetry watchers
   to `EVENTS.PlayerEnterUnit`. The pinned MOOSE documents that event as
   *"Not Mulitplayer safe. Use PlayerEnterAircraft."*
   (`src/lib/Moose.lua:9635`). On a dedicated MP server the raw enter event
   does not deliver usable data to mission scripts, so **no player entry
   event ever fired** — not on initial join, not on rejoin.
2. **The event that does fire is synthesized.** MOOSE's
   `DATABASE:_EventOnPlayerEnterUnit` handler reads
   `Event.IniUnit:GetPlayerName()` and, when a human is in the seat,
   schedules `CreateEventPlayerEnterAircraft(IniUnit)` one second later
   (`src/lib/Moose.lua:23460–23497`). `CreateEventPlayerEnterAircraft`
   (`Moose_.lua:6290`) plus the `EVENT:onEvent` enrichment
   (`Moose_.lua:8463–8488`) populate the real fields: `IniDCSUnit`,
   `IniDCSUnitName`, `IniDCSGroupName`/`IniGroupName`, `IniTypeName`,
   `IniCoalition`, `IniCategory` (via `getDesc().category`),
   `IniPlayerName`, and `IniPlayerUCID` (via
   `net.get_player_info(..., 'ucid')`).
3. **Mock-only normalization.** The telemetry adapters read identity from
   raw unit methods (`getGroupName`, `getPlayerUCID`, …) that exist in the
   test mocks but not on real DCS units, and used `AIR_CATEGORY = 2` —
   DCS `Unit.Category.GROUND_UNIT` (airplane = 0, helicopter = 1). Tests
   passed while real aircraft would mis-normalize or be rejected.
4. **Weakly retained gameplay watchers.** MOOSE stores event subscribers in
   weak-key tables (`setmetatable({}, {__mode="k"})`,
   `Moose_.lua:8213`); the `main.lua` gameplay watchers were referenced
   only by top-level locals and were GC-eligible after the chunk returned.
5. **Hard-disconnect leave is a DCS limitation.** `EVENT:onEvent`
   dispatches events with a nil initiator *except* `PlayerLeaveUnit`
   (`Moose_.lua:8427`), so a hard disconnect can never emit
   `participant.left`. This is not fixable in mission code.

## 3. Fix (commit `a3aa01f`)

- `src/missions/duel-dynamic/main.lua` — gameplay player watcher now
  subscribes to `EVENTS.PlayerEnterAircraft` (`PlayerLeaveUnit` retained
  for graceful leaves); slot resolution reads `IniGroupName` /
  `IniDCSGroupName` with a protected `IniGroup:GetName()` fallback;
  watchers strongly retained in `_G.duel_gameplay_watchers` (weak-key GC
  fix).
- `src/missions/duel-dynamic/telemetry/participant.lua` — subscribes
  `PlayerEnterAircraft` + `PlayerLeaveUnit`; normalizes MOOSE `Ini*` fields
  first with protected raw-DCS fallbacks only for position and callsign;
  `participant_id` strictly from `IniPlayerUCID` (never manufactured);
  accepts airplane (0) and helicopter (1), rejects ground (2); the
  hard-disconnect limitation is documented at the leave handler.
- `src/missions/duel-dynamic/telemetry/asset.lua` — entry lifecycle on
  `PlayerEnterAircraft` (subscribe/unsubscribe both directions); same
  `Ini*`-first normalization, now also capturing `category`,
  `display_name`, `participant_id`, `callsign` in the observation; category
  guard added; incarnation/generation semantics unchanged (same unit object
  → same generation, distinct object → new generation).
- `src/missions/duel-dynamic/telemetry/development.lua` — pre-Slice-10
  harness compatibility shims updated to the new event names.
- Tests — `run-participant.lua` (8), `run-asset.lua` (8),
  `run-duel-shared-bandits.lua` (12). Notable new coverage:
  subscription/cleanup against the real event constant; `Ini*`
  normalization winning over raw unit values; category acceptance (0/1) and
  rejection (2); **the exact drill failure** — same-object re-entry keeps
  the generation, a replacement object advances to `g2`, and later
  ordnance resolves to the `g2` `asset_key` while the stale object no
  longer resolves; gameplay watcher retention via
  `_G.duel_gameplay_watchers`. The mock units no longer expose the old
  `getGroupName`/`getPlayerUCID` shapes, so the tests can no longer pass by
  re-encoding the old assumption.

Contract, web, collector, and gameplay semantics are unchanged; the
telemetry event contract is untouched.

## 4. Verification

- 74 pure-Lua tests pass across the 7 suites (20 + 8 + 7 + 11 + 8 + 8 + 12),
  run from the worktree root with `lua5.1`.
- `stylua --check src tests` exit 0 (CRLF on disk per `.stylua.toml`).
- `git diff HEAD` = exactly the 7 files above (367+/162−); no
  contracts/web/collector changes.
- Every MOOSE source claim in §2 was re-verified directly against the
  pinned build before the commit (line references above).

## 5. Residual limitations

- **Hard-disconnect leave remains unobservable** (root cause 5). Graceful
  leaves still emit `participant.left`; hard disconnects emit nothing.
  The web sortie derivation (Slice 9) already tolerates missing leaves.
- The fix is validated by pure-Lua tests using realistic MOOSE event
  tables, not yet by a live human-in-seat session.

## 6. Manual validation (human-in-seat, needed before this counts as done)

> **Parked 2026-09-04:** pushed to `origin/main`; the drill is deferred
> until a two-player window opens. The checklist is unchanged and remains
> the gate before distribution (the shipped gameplay code is the same path).

1. Start the dedicated server and load the dev `duel-dynamic` mission
   (dev loader → `C:\Projects\dcs-missions\src\bootstrap.lua`; the main
   worktree already contains the fix).
2. Two players join Aerial-1/Aerial-2. Expect, per player:
   `participant.entered` (with real UCID) **and** `asset.spawned`
   `aerial-N.u1.g1` within a couple of seconds of joining.
3. One player hard-disconnects (close the client) and rejoins the same
   slot. Expect: a fresh `participant.entered`, a new `asset.spawned` with
   generation `g2` for that slot, and subsequent `ordnance.fired` from
   that player resolving to the `g2` `asset_key` (no unknown references).
4. Optional: a graceful client exit should still emit
   `participant.left`; a hard disconnect should not (known limitation).
5. Collect + deliver the drill run; confirm it reaches `ended` on the
   production site (`https://dcs-missions.vercel.app/`).
6. Open the 2026-09-03 host Tacview recording from the local archive
   (`Tacview-20260903-204549-DCS-Host-duel-dynamic.zip.acmi`) and visually
   sanity-check the engagement (bandit waves, player rejoin path).
7. Environment safety: `D:\DCS World Server\Scripts\MissionScripting.lua`
   is currently **de-sanitized** for dev. Restore it from its `.orig`
   backup (SHA-1 `FB54471ECE4DB968AED4A55A1806B25EA5116452`) before any
   shipping build or joining untrusted servers.
8. Once validated, rebuild the shipping `.miz`
   (`build/pack-shipping-miz.ps1`) — the current shipping build predates
   the telemetry work and this lifecycle fix — and run the stock-runtime
   check per `docs/shipping-duel-dynamic.md`.
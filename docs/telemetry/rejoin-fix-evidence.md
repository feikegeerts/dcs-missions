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

## 3. Fix (commit `f4d35f3`)

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

> **2026-09-05 update:** single-player drill completed (run
> `run-20260905T133232Z-386fd81f`, 37 events gapless 1–37, closed with
> `mission.ended` via WebUI Stop). Graceful path fully validated; death +
> hard-disconnect path reproduced the unknown-asset residual. A second
> drill (run `run-20260905T140319Z-2751cc40`, §8) reproduced it again and
> pinned the true root cause; the working-tree fix below supersedes the
> liveness-only attempt. Live re-validation of the corrected fix is still
> required. See §7–§8.

1. Start the dedicated server and load the dev `duel-dynamic` mission
   (dev loader → `C:\Projects\dcs-missions\src\bootstrap.lua`; the main
   worktree already contains the fix).
2. Two players join Aerial-1/Aerial-2. Expect, per player:
   `participant.entered` (with real UCID) **and** `asset.spawned`
   `aerial-N.u1.g1` within a couple of seconds of joining.
   (Single-player counts: the 2026-09-05 solo drill proved the same code
   path — see §7.)
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

## 7. Live drill 2026-09-05 (single-player, dev window open)

Solo adaptation of the §6 checklist: one player (`James V`,
UCID `3e0d02bb…`, `Enfield11`) in `Aerial-1`. `TEST_COMBAT_ENABLED` was
temporarily disabled in `src/bootstrap.lua` for the human session.
Tacview host recording:
`Tacview-20260905-153632-DCS-Host-duel-dynamic.zip.acmi`.

- ✅ Initial join: `asset.spawned aerial-1.u1.g1` (seq 2) +
  `participant.entered` with the real UCID (seq 3); 1-ship package
  `bandit-1.u1.g1` spawned 54.5 nm out and CAP-tasked. The 2026-09-03
  failure (zero `participant.entered`) is fixed.
- ✅ Graceful leave/rejoin: `participant.left` (seq 9) → empty-server
  cleanup → `asset.despawned bandit-1.u1.g1` (seq 10); rejoin produced a
  fresh `participant.entered` (seq 17, same UCID), a new package
  `Bandit-1#002` (`bandit-1.u1.g2`), and an `ordnance.fired` AIM-120C
  (seq 20) fully attributed to `aerial-1.u1.g1` — no unknown references.
- ❌ Death + hard disconnect/rejoin: the aircraft crashed while the
  operator was alt-tabbed (pilot dead + crash 13:43:28Z), the client was
  hard-killed (disconnect 13:44:28Z with **no** `participant.left` —
  the documented limitation), and the rejoin emitted a fresh
  `participant.entered` (seq 31) but **no player `asset.spawned g2`**;
  the next player shot (seq 34) carried an **unknown** `asset_key`
  (participant still known) — the Sept-3 seq 81/84 failure reproduced.
  Root cause: MOOSE recycles the unit wrapper per unit name and runtime
  IDs are reused (`initiator_object_id=16777474` before and after), so
  object/id comparison alone mistook the recreated aircraft for the same
  incarnation and the entry was silently dropped
  (`replacement identity is unavailable` had no log line).
- ✅ Run closed cleanly: graceful `participant.left` (seq 36) +
  `mission.ended` (seq 37) via WebUI Stop. No scripting errors.

Fix (working tree, not yet committed): `telemetry/asset.lua` now checks
incarnation liveness first — a dead previous incarnation always advances
the generation even when the wrapper/IDs are recycled — and the dropped
path logs a warning. Regression test added to
`tests/lua/telemetry/run-asset.lua` mirroring the live sequence
(live re-entry keeps `g1`, post-crash re-entry emits `g2`); it fails on
the pre-fix code and passes with the fix. Full suites green
(20 + 11 + 8 + 8 + 11 + 9 + 12), `stylua --check src tests` exit 0.
Live re-validation of the `g2` path is the remaining gate (dev window
kept open for it).

## 8. Live drill 2026-09-05, round 2 (death-retirement fix)

Same solo setup, new run `run-20260905T140319Z-2751cc40` with the §7
liveness fix loaded. Operational note: the mission loaded `ssPaused`
and stayed paused after join (no init, no entry synthesis — all
model-time); WebGUI Resume was required before anything fired. Worth
remembering for future drills: if the log shows the join but no
`init done` within seconds, check the pause toggle first.

- ✅ Initial join after Resume: `asset.spawned aerial-1.u1.g1` (seq 2) +
  `participant.entered` with the real UCID (seq 3); bandit `g1` (seq 4).
- ❌ Death (pilot dead + crash) + client hard-kill (disconnect with no
  `participant.left`) + rejoin: fresh `participant.entered` (seq 17,
  still `g1`-linked) but **no player `asset.spawned g2`** and no
  `advancing generation` warning — the next player AIM-120C (seq 18)
  went **unknown** again, while the bandit's reply (seq 20) attributed
  correctly to `bandit-1.u1.g1`.
- Root cause, corrected: the liveness check could not fire because the
  recycled wrapper reports itself alive (or exposes no death state) —
  wrapper/object/id comparison is fundamentally blind to the
  replacement. The signal that fires reliably in both runs is the death
  itself, so the fix retires the tracked incarnation on `EVENTS.Dead` /
  `EVENTS.Crash` inside a tracked player group instead of detecting the
  replacement at entry time.
- Fix (working tree, supersedes §7): `telemetry/asset.lua` subscribes
  `Dead` + `Crash`, retires the matching active player incarnation with
  an info log (no `asset.despawned` — death is not scripted cleanup;
  sortie pairing uses participant events), and requires both events in
  config validation. The liveness-first check from §7 is retained as
  defense in depth. Regression test added for the exact live shape
  (death retires `g1`, same-wrapper re-entry opens `g2`, bandit deaths
  retire nothing); negative control via `git stash` fails 3 tests on
  pre-fix code, 12/12 pass with the fix. Full suites green
  (20 + 11 + 8 + 8 + 12 + 9 + 12), `stylua --check src tests` exit 0.
- Clarification from the drill: quitting the client to desktop — even
  neatly via the menu — tears down the connection without a slot-leave
  event, so no `participant.left` is the *correct* behavior (documented
  limitation), not a second bug. A `left` fires only when leaving the
  slot while staying connected (back to lobby/spectators, as in round 1
  seq 9). Live re-validation of the death-retirement `g2` path needs a
  mission restart (dev loader reads `src/` at mission start) plus one
  more die → hard-kill → rejoin → shoot cycle.

## 9. Live drill 2026-09-05, round 3 (death-retirement validated, resolve gap found)

New run `run-20260905T142246Z-0f43ce41` with the §8 fix loaded
(mission was restarted after round 2; the previous run closed with
`mission.ended`).

- ✅ Death retired the incarnation live: `pilot dead` + `crash` →
  `retired aerial-1.u1.g1 (crashed)` in `dcs.log`, the exact line the
  fix was built to produce.
- ✅ Rejoin opened the new generation: `asset.spawned aerial-1.u1.g2`
  (seq 16) + `participant.entered` linked to `g2` (seq 17, same UCID).
- ❌ The very next player AIM-120C (seq 18) still went **unknown**
  (`instance-identity-unavailable`, participant known) while the
  bandit's reply attributed correctly. Root cause, one layer deeper:
  the shot resolves through `IniUnit` while entry registers
  `IniDCSUnit` — different recycled objects — and `resolve_unit` only
  consulted the ID map when no DCS object was present at all, so the
  fresh shot object matched nothing even though DCS reuses the runtime
  ID across the respawn (`initiator_object_id=16777474` in every
  session).
- Fix (working tree): entry registers **every** unit representation in
  the event (`IniDCSUnit`, `initiator`, `IniUnit`) as identity aliases,
  and `resolve_unit` falls back to the runtime-ID map for fully unknown
  objects (still requiring a live incarnation; a reference that hits a
  *retired* incarnation stays dead and is never re-resolved by ID).
  Regression test added for the exact seq16–18 shape plus stale-dead
  checks; stash negative control fails 6/13 on pre-fix code, 13/13
  passes with the fix. Full suites green
  (20 + 11 + 8 + 8 + 13 + 9 + 12), `stylua --check src tests` exit 0.
  Live re-validation needs one more restart + die → hard-kill → rejoin
  → shoot cycle.

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
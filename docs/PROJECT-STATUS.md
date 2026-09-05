# Project status

**Last updated:** 2026-09-05 (Slice 11 local catalogue checkpoint implemented;
database migration and seed intentionally not run remotely). Read this first
when coming back.

This is a snapshot of where the project is, what's known to work, what's
known to be broken, and what still needs to happen before the mission
is shippable. If you change anything, update the relevant section.

---

## 0. Do this first (2026-09-04)

1. **Pushed:** `main` == `origin/main` @ `d1ec6d3` (includes the
   multiplayer rejoin lifecycle fix `f4d35f3` and the worktrees
   convention). The live human-in-seat rejoin drill is **parked**
   (no time this week) — its checklist is unchanged at
   `docs/telemetry/rejoin-fix-evidence.md` §6. Run it before
   distributing the mission; it validates the same gameplay code path
   the shipping build embeds.
2. **The DCS env is DE-SANITIZED again** (see §2) — restore stock before
   shipping or untrusted servers.

---

## 1. Active mission

`src/.current-mission` = **`duel-dynamic`**. Don't change this without
checking the spec at `docs/spec-duel-dynamic.md`.

`.miz` files in the server's Missions folder:
- `Saved Games\DCS.dcs_serverrelease\Missions\duel-dynamic.miz`
- `Saved Games\DCS.dcs_serverrelease\Missions\duel-1v1.miz` (legacy)

Both `.miz` files contain the same generic loader trigger; only the
`missions/<name>/main.lua` they load differs.

---

## 2. Environment status

> **DCS environment is currently STOCK** (restored 2026-09-04 after the
> Slice 11 ordnance-matrix run). The dedicated-server install
> (`D:\DCS World Server`) `MissionScripting.lua` is the stock file (live
> SHA-1 `FB54471ECE4DB968AED4A55A1806B25EA5116452`, identical to the
> `MissionScripting.lua.orig` backup); the dev-window de-sanitized variant
> is preserved as `MissionScripting.lua.telemetry-dev-backup` (SHA-1
> `33977AAD2B3FE7A39E15374839C813E164BF0929`; the exact live de-sanitized
> file used during the Slice 11 dev window had SHA-1
> `D0069384E34331079A2513D84AE474C9BF5A8843`). `DCS_server` is stopped.
>
> To re-enter dev mode (required for the dynamic `src/` dev loader): patch
> the file again per `docs/dev-setup.md §2`. Keep it stock before any
> shipping build and before flying/joining untrusted missions.

Server config: `Saved Games\DCS.dcs_serverrelease\Config\autoexec.cfg`
has the no-render / no-track / silent-crash settings. Don't lose it.

Tacview `1.9.4.200` is installed and configured in the active dedicated-server
profile. Recording is enabled for all host-visible multiplayer data; real-time
telemetry and remote control are disabled. Host and client playback delay is
set to zero for immediate training review. The pre-install `options.lua` is at
`Saved Games\DCS.dcs_serverrelease\Backups\Tacview-setup-20260902\options.lua`.
Host and client `.acmi` creation was runtime-verified on 2026-09-02.

---

## 3. Repo state

```
C:\Projects\dcs-missions\
├── CLAUDE.md                           # main conventions, read first
├── src\
│   ├── bootstrap.lua                   # dispatcher (shared, stable)
│   ├── .current-mission                # "duel-dynamic"
│   ├── lib\
│   │   ├── Moose.lua                   # full annotated MOOSE (for IDE)
│   │   └── Moose_.lua                  # comment-stripped build (what ships)
│   └── missions\
│       ├── duel-dynamic\
│       │   ├── main.lua                # ★ active, well-tested
│       │   └── score.lua               # ★ active
│       └── duel-1v1\
│           ├── main.lua                # ⚠ INCOMPLETE — has duplicate top-level
│           │                           #   code from a half-done edit. Don't
│           │                           #   switch .current-mission to this
│           │                           #   without cleanup first.
│           └── score.lua               # ⚠ still logs "[duel-1v1] score module loaded"
├── lib\moose-src\                       # MOOSE source tree (for IDE only)
├── build\pack-miz.ps1                  # zips missions\<name>\ → out\<name>.miz
├── docs\
│   ├── dev-setup.md                    # ★ read first, very thorough
│   ├── mission-loader.md               # dev loader pattern
│   ├── spec-duel-1v1.md                # ⚠ superseded — see spec-duel-dynamic.md
│   ├── spec-duel-dynamic.md            # ★ current mission spec
│   ├── PROJECT-STATUS.md               # ★ this file
│   └── shipping-duel-dynamic.md        # ★ packaging checklist (see §6 below)
├── .luarc.json, .luacheckrc            # editor / lint config
└── .stylua.toml, .styluaignore         # formatter config
```

---

## 4. What's known to work

Verified end-to-end on the dedicated server (logs from 2026-07-26 session):

- ✅ Bootstrap dispatcher reads `.current-mission`, loads MOOSE, loads
  the right mission's `main.lua`.
- ✅ MOOSE builds (both `Moose.lua` and `Moose_.lua`) are in sync and
  load without errors.
- ✅ Init poll loop: world not ready → retry → world ready → init.
  Verified by both successful and "init done" log lines.
- ✅ Historical per-pair spawn/kill/leave behavior was dedicated-server
  validated in the July and Slice 5 runs. It was superseded on 2026-09-01 by
  the package-wave model below.
- 🧪 Package waves are implemented and plain-Lua tested: one multi-aircraft
  DCS group sized to the live blue roster, compact formation 60+ sm from the
  blue centroid, shared CAP task, no partial-wave respawn, and one complete
  replacement 30 seconds after the final red loss. Real-DCS validation is
  still required.
- 🧪 Player death/leave no longer resets an engaged red aircraft. Partial
  player leave preserves the current package; all-blue-empty cleanup removes
  it. Mid-wave joiners are included in the next package because DCS cannot add
  units to an already spawned group.
- 🧪 F10 menu now uses **Respawn bandit wave** as an explicit forced package
  reset. Kill messages label the total as `Team kills`.
- ✅ Score counter increments, displays via F10 message, resets.
- ✅ Round 1 heading randomization on player slot (visible in HSI).
- ✅ `stylua --check` passes on both missions.
- ✅ Dedicated server: WebGUI restart reloads from disk with no repack.
- ✅ A headless dedicated server can wait indefinitely for its first player;
  joining any Aerial slot reaches mission initialization. This replaced the old
  30-second init timeout. The new package spawn after that init still needs its
  first real-DCS validation.
- ✅ Telemetry Slice 4: stable producer identity, fresh per-generation run
  keys, `mission.started`, 30-second heartbeats, best-effort
  `mission.ended`, and verified per-run NDJSON. Dedicated-server evidence is
  in `docs/telemetry/slice-4-lifecycle-evidence.md`.
- ✅ Telemetry Slice 5: roster-filtered MOOSE `EVENTS.Shot` capture produces
  contract-valid `ordnance.fired` records for players and paired AI bandits.
  Controlled two-shot and two-player dedicated-server evidence is in
  `docs/telemetry/slice-5-ordnance-evidence.md`.
- ✅ Telemetry Slice 6: local TypeScript collector (`collector/`) — NDJSON
  tailing with partial-line handling, contract validation, durable SQLite
  spool with idempotent inserts, file-identity cursors, in-order
  delivery/ack, dry-run. No network calls; two-pass real-data idempotency
  (145 events, zero loss/dup) + unattended live dedicated-server tail.
  Evidence: `docs/telemetry/slice-6-collector-evidence.md`.
- ✅ Telemetry Slice 7: web shell + raw event persistence (`web/`, Next.js
  App Router + Drizzle + `@neondatabase/serverless`). Protected idempotent
  ingest `POST /api/telemetry/ingest` (AJV against the normative contract,
  per-event accepted/duplicate/rejected acks, no `db.transaction`,
  `ON CONFLICT (event_id) DO NOTHING`), run/event query routes, list + detail
  pages. Committed `86e5f5a`; pushed and deployed by Slice 8.
  Verified end-to-end
  against the live Neon env with two real unattended runs: 32 events
  `accepted` on first pass, 32 `duplicate` on re-pass (idempotency), and
  `mission_runs`/`telemetry_events` rows correct.
- ✅ Telemetry Slice 8 (deploy scope): first production deploy of `web/`.
  Vercel project `dcs-missions` (git-integrated, `rootDirectory` fixed to
  `web` — the repo-root default was why the first three deploys died in
  seconds), Neon `POSTGRES_URL`/`DATABASE_URL` + `TELEMETRY_INGEST_TOKEN`
  set for Production and Preview. `main` pushed
  (`920b4bc..52fae57`); production deploy `dcs-missions-brg0iiry4` READY
  from `52fae57`. Verified live: `GET /` 200, runs/run-detail/events APIs
  return both runs (16 events each, seq 1–16, exactly one
  `ordnance.fired` with the correct `weaponDcsType`), an idempotent ingest
  re-pass against the production URL returned 32/32 `duplicate`, and the
  401 negatives are the app's own Bearer auth. Vercel SSO deployment
  protection is disabled (owner decision; ingest authenticates with the
  app-level token).
- ✅ Deterministic single-shot unattended ordnance: a dev-only
  `TEST_COMBAT_MISSILE` knob pins the bandit to exactly one AAM + no gun so
  the `ordnance.fired` count is assertable and the weapon identity is the
  loadout. Verified for both AIM-120C and AIM-9X (one `ordnance.fired` each,
  correct `weapon_dcs_type`). Root cause of the earlier mislabel
  (`waveSpawner.TweakedTemplate` defaulting to false so the payload
  overwrite was ignored by `SPAWN:_Prepare`) is documented in
  `docs/telemetry/unattended-test-loop.md`.
- ✅ Telemetry Slice 8 (delivery scope, complete 2026-09-03): the collector
  delivery client (`collector/src/delivery.ts`, `879f41c`) was exercised
  live on two unattended deterministic runs. Run A
  (`run-20260903T110437Z-63460841`) delivered cleanly (16/16 `accepted`,
  historical runs 194 accepted + 32 `duplicate` — idempotency held). Run B
  (`run-20260903T111858Z-13744ac8`) is the **network-interrupt drill**: web
  down while the run spooled → delivery attempt #1 failed with connection
  refused and acked **nothing** (spool stayed 16/0, NDJSON untouched) → web
  restored → attempt #2 delivered 16/16 `accepted`, and Neon holds exactly
  16 rows for Run B (`eventCount=16`, not 32 — the no-duplication proof),
  13/13 page/API checks passed. Full evidence:
  `docs/telemetry/unattended-test-loop.md` § "Slice 8 delivery +
  network-interrupt drill".
- ✅ Telemetry Slice 9: exact-roster `participant.entered` / `participant.left`
  capture now retains stable UCID plus name/callsign snapshots, including
  per-slot identity fallback on late leave. Pure web sortie derivation pairs
  control periods and recovers from missing leaves without inventing identity.
  Lua, web, collector, and unattended no-player gates passed; the human-in-seat
multiplayer drill remains the explicit follow-up. Evidence:
   `docs/telemetry/slice-9-participant-evidence.md`.
- ✅ Telemetry Slice 10 (branch `slice-10-tracked-instances`, committed
   `efa5621` and pushed to `origin/main` on 2026-09-04): tracked aircraft
   instance identity. The dev runtime emits `asset.spawned` for roster wave
   and player groups, and resolves `ordnance.fired` to the firing instance
   with a generation-based `asset_key`
   (`{roster-token}.u{unit_index}.g{generation}`), degrading to explicit
   unknown references when identity is unavailable. Unattended
   dedicated-server evidence: one `asset.spawned` and one attributed
   `ordnance.fired` in a gapless 6-event run with zero participant events
   and no scripting errors. The first attempt silently ran the main
   worktree's Slice 9 code because the worktree's `bootstrap.lua` fallback
   root is the main project path — the `[bootstrap] root:` line in
   `dcs.log` is the authoritative check of which `src/` tree a worktree
   miz loaded. Evidence: `docs/telemetry/slice-10-asset-evidence.md`.
- 🧪 Multiplayer rejoin lifecycle fix (**open point**: merged to `main` as
   commit `f4d35f3`, pushed, live validation pending):
   the 2026-09-03 two-player live drill produced **no
   `participant.entered` at all** (initial or rejoin) because gameplay and
   telemetry watchers subscribed to `EVENTS.PlayerEnterUnit`, which the
   pinned MOOSE documents as not multiplayer-safe; MOOSE instead
   synthesizes `EVENTS.PlayerEnterAircraft` one second after a human
   enters an aircraft, with the real `Ini*` fields. The fix switches
   gameplay + participant + asset lifecycle to `PlayerEnterAircraft`,
   normalizes the MOOSE `Ini*` event fields (with protected raw-DCS
   fallbacks), corrects the aircraft category constants
   (airplane=0/helicopter=1 accepted, ground=2 rejected), stops
   manufacturing participant identity from mock-only unit methods
   (`IniPlayerUCID` only), and strongly retains the gameplay watchers
   (MOOSE keeps subscribers in weak-key tables). A hard disconnect still
   cannot emit `participant.left` (DCS drops leave events without an
   initiator) — documented limitation. 74 pure-Lua tests + stylua pass;
   live human-in-seat validation pending (checklist:
   `docs/telemetry/rejoin-fix-evidence.md` §6).
- ✅ Telemetry Slice 11 local catalogue checkpoint: the completed unattended
  AAM/airframe matrix now feeds immutable `ordnance` catalogue version 1 with
  exactly 24 scoped keys (16 missiles, 8 aircraft). Unknown keys stay
  unpriced. AIM-9X uses the FY 2026 Navy recurring AUR unit-cost field; all
  other missiles and all aircraft are explicitly labeled score estimates.
  Drizzle schema/migration adds composite-versioned `valuation_catalogues` and
  `valuation_items`; the seed prefers existing process configuration and falls
  back to the same local `web/.env.local` convention as existing scripts. It
  inserts missing rows but rejects any attempt to rewrite an existing version.
  Local web tests,
  typecheck, lint, formatting, migration generation, and `git diff --check`
  pass. No migration or seed was run against Neon. Research and limits:
  `docs/telemetry/ordnance-catalogue-v1-research.md`; runtime evidence:
  `docs/telemetry/slice-11-ordnance-matrix.md`.

## 5. What's known to be broken / limited

These are DCS-imposed limitations, not bugs in the Lua. Documented in
`spec-duel-dynamic.md §6`.

- ❌ **Round 1 player position is the ME position.** `setPosition` on a
  client-controlled player slot is silently ignored in MP. Heading
  randomization works; position does not. Round N+1 is fine because
  the player rejoins into the existing slot at the death position and
  the bandit is in a new location.
- ❌ **Player is not teleported to a new position on respawn.** MOOSE's
  `GROUP:Teleport` on a dead group spawns at the ME template position
  (because of an `if self:IsAlive()` guard in `Respawn`), not at the
  new coord. The current package-wave lifecycle has no player-death handler and
  does not call `Teleport`. Workaround: load MIST and use
  `mist.teleportToPoint({action="respawn"})` — see §6.
- ⚠️ **`duel-1v1` is in a broken intermediate state.** Has duplicate
  top-level code from a half-done edit. Do not switch
  `.current-mission` back to it without cleanup. See spec §10.
- ⚠️ **Package-wave behavior is not yet real-DCS validated.** The plain-Lua
  regression test verifies the lifecycle and MOOSE calls, but Tacview must
  confirm that `SPAWN:InitGrouping` produces the intended 2/3/4-ship formation
  and that the shared CAP task yields the desired 2v2/3v3/4v4 behavior.

## 6. What's still to do (post-PTO)

### 6.1 Nice-to-have: MIST integration for true random player respawns

This was explicitly deprioritized on 2026-09-02. Continue telemetry work first;
revisit MIST after the telemetry path is established unless player respawning
becomes a blocker.

To get the player teleporting to a new position on death, we need
`mist.teleportToPoint`. Steps:

1. Download `mist.lua` (MissionScriptingTools release).
2. Drop it into `src/lib/`.
3. In `bootstrap.lua`, `dofile` it after Moose_ but before the mission
   main, so `_G.mist` is available.
4. Add a separate player-respawn handler without changing the package-wave
   roster or red-wave state. A possible MIST call is:
   ```lua
   local newPos, _ = randomOffsetCoord(playerAnchor, RANDOM_DIST_MIN_M, RANDOM_DIST_MAX_M)
   mist.teleportToPoint({ groupName = pname, point = newPos, action = "respawn" })
   ```
5. Test that the player rejoins into the respawned group at the new
   position, not the ME position.
6. Update `spec-duel-dynamic.md §6.2` to reflect the new behaviour.

### 6.2 Clean up `duel-1v1`

Decide whether to:
- (a) delete it, or
- (b) fix the duplicate top-level code (lines 152–189 and 203–225 of
  `missions/duel-1v1/main.lua` are duplicates of the inner SCHEDULER
  block at lines 97–150; delete the duplicates and the file should
  work again).

The original 1v1 mission was used to prove the bootstrap → MOOSE → F10
menu → event pipeline; with `duel-dynamic` covering that and more,
deleting is probably the right call. Verify with the user first.

### 6.3 Ship the mission (static mode)

Status: **built and stock-runtime verified** (2026-09-02).
`build/pack-shipping-miz.ps1`
assembles `out/duel-dynamic.miz` (~840 KB, self-contained) from the
dev `.miz` and `src/`. The generated mission, mapResource, MOOSE, and shipping
main script parse as Lua 5.1.

- [x] Build a self-contained `.miz` that loads via `DO SCRIPT FILE` —
      `build/pack-shipping-miz.ps1` writes to `out/duel-dynamic.miz`
      and `out/duel-dynamic-build/` (staging dir, left in place for
      inspection when `-Zip` is not passed).
- [x] `-Zip` packaging and entry listing re-verified 2026-09-02. The
      PowerShell case-insensitive `$Zip`/`$zip` variable collision was fixed,
      and the packager now writes ZIP entry names with DCS-compatible forward
      slashes and rejects backslash entries.
- [x] Strip all `:TraceOn()` / `BASE:TraceOn()` calls. Sanity check
      in the packager; current `src/` has none.
- [x] `os.time()` → `math.floor(timer.getTime() * 1000)` for the LCG
      seed (stock DCS nils `os`).
- [x] `score.lua` inlined into `l10n/DEFAULT/main.lua` (no `dofile()` in
      stock DCS — CWD is the DCS install dir, not the .miz).
- [x] `MissionScripting.lua` restored to stock on both installs
      (2026-07-28). `os`/`io`/`lfs` are nilled again. The `.orig`
      backups were the source.
- [x] Lua syntax of patched mission file validated with `lua5.1
      -e "loadfile(...)"`.
- [x] Verify it runs on a stock (sanitized) DCS install. The user
      (2026-07-28) hit one Lua parse error on first attempt — the
      packager used `""` for inner quotes (Lua adjacent-string
      concat) instead of `\"` (escaped quote), so the .miz wouldn't
      load. **Fixed** in the packager; re-built .miz parses cleanly.
      A 2026-09-02 retry exposed a second packager bug: DO SCRIPT FILE actions
      used literal `Scripts/...` paths, so DCS silently skipped both scripts.
      The packager now embeds scripts under `l10n/DEFAULT`, registers resource
      keys in `mapResource`, and patches the legacy startup callback to invoke
      both actions. The first resource-key build (`shipping-test-v2`) exposed a
      third Windows-only bug: `.NET ZipFile.CreateFromDirectory()` stored
      resource member names with backslashes, while editor-authored missions
      use `l10n/DEFAULT/...` forward-slash names. The packager now creates ZIP
      entries explicitly with forward slashes and validates the archive layout.
      `duel-dynamic-shipping-test-v3.miz` was loaded on the stock server on
      2026-09-02. The log confirmed `MOOSE INCLUDE END`, shipping/main init,
      a tasked 1-ship package, a mutual player/bandit kill, the 30-second
      replacement schedule, and wave 2 spawning exactly 30 seconds later.
      Tacview recorded the run with playback delay zero.
- [ ] Final QA on a fresh dedicated server install.

See `docs/shipping-duel-dynamic.md` for what the packager does and
how to verify, and `docs/dev-setup.md §8` for the build/QA loop.

### 6.4 Smaller polish

- [x] Remove coalition-wide player death/respawn notices and label bandit kill
      totals honestly as team totals. Individual attribution remains planned
      for telemetry Slice 14.
- [x] Replace per-player bandit resets with whole-package waves. Partial red
      losses are held; the 30-second timer starts after the final red loss.
- [ ] Validate 1v1, 2v2, 3v3, and 4v4 package geometry/tasking on the dedicated
      server and inspect the result in Tacview.
- [x] Install/configure Tacview for
      `Saved Games\DCS.dcs_serverrelease` before that validation run.
      Tacview `1.9.4.200`, its export and hook scripts, a minimal `Export.lua`,
      and host-recording options were installed on 2026-09-02. Lua syntax,
      copied-file hashes, and host/client `.acmi` output were verified. Playback
      delay is disabled; the v2 mission-load log confirmed
      `tacviewPlaybackDelay=0` at runtime. Use the `DCS-Host-...` recording for
      package analysis: it contains both bandit waves. The `DCS-Client-...`
      recording omits bandits because this server deliberately has
      `allow_object_export=false` for multiplayer clients.
- [ ] Pick a real map / theatre. Caucasus is the test default. Decide
      if the production mission uses a different map and update both
      the ME and the spec.
- [ ] Decide on the production aircraft. The current test uses
      FA-18C + Su-33. Pick the final pair and update the ME / spec.

### 6.5 Telemetry

Slices 1–10 are complete. Slice 5 was validated with controlled and two-player
dedicated-server runs, and the development environment was restored to stock
afterward. Slice 6 added the local TypeScript collector
(`collector/`): NDJSON tailing with partial-line handling, contract
validation, a durable SQLite spool with idempotent inserts, file-identity
cursors with truncation/replacement resets, quarantine for invalid lines,
in-order delivery/acknowledgement, and a dry-run summary. It made no network
calls and passed a two-pass real-data idempotency check
(145 events, zero loss, zero duplicates), plus an unattended live
dedicated-server tail (two live runs, four collector passes, no player).
Evidence: `docs/telemetry/slice-6-collector-evidence.md`. The unattended
test loop itself (hook-driven mission load, no player/WebGUI) is documented
in `docs/telemetry/unattended-test-loop.md`; unattended ordnance testing
(blue AI engagement) is implemented and live-verified in that doc (run
`run-20260902T181007Z-7b3ea067`), with the design and evidence in
`docs/test-combat-plan.md`. The same doc now covers the deterministic
single-shot loadout and the `TweakedTemplate` weapon-identity root cause
(2026-09-03, runs `…21af9d3f` AIM-120C and `…745fc0db` AIM-9X).

Slice 7 added the web shell + raw event persistence (`web/`), committed
`86e5f5a`, verified end-to-end against the live Neon env with two real
unattended runs (idempotent ingest, correct `mission_runs`/
`telemetry_events` rows). See §4.

Slice 8 (approved 2026-09-03) is **complete**: the deploy scope (Vercel
project `dcs-missions` with `rootDirectory` fixed from repo root to `web` —
the cause of three instant failed deploys; Neon + `TELEMETRY_INGEST_TOKEN`
env for Production and Preview; `main` pushed; git-integrated production
deploy READY from `52fae57`) was live-verified (site + run/event APIs
correct for both runs, idempotent ingest re-pass against the production URL
32/32 `duplicate`, 401 negatives from the app's own auth). The delivery scope
(delivery client `879f41c` + the network-interrupt drill) was completed the
same day: see the §4 Slice 8 delivery bullet and
`docs/telemetry/unattended-test-loop.md` § "Slice 8 delivery +
network-interrupt drill" for the Run A/B evidence.

Slice 9 (approved and completed 2026-09-03) added exact-roster participant
enter/leave source capture with stable UCID and historical label snapshots,
per-slot leave fallback, and pure sortie pairing. Automated Lua/web/collector
checks and a 90-second unattended dedicated-server run passed with zero false
participant events and no scripting errors. A real participant still needs to
exercise enter, leave, rejoin, slot change, and mission restart to validate the
   known multiplayer event/field limitations. Evidence:
   `docs/telemetry/slice-9-participant-evidence.md`.

Slice 10 (approved and completed 2026-09-03 on branch
 `slice-10-tracked-instances`, committed `efa5621` and pushed 2026-09-04)
 added tracked aircraft
 instances: `asset.spawned` capture for roster wave and player groups,
 generation-based `asset_key` identity that survives group-name reuse,
 `ordnance.fired` attribution through the asset registry, and intentional
 `asset.despawned` emission on wave cleanup. Automated Lua/web/collector gates
 and a 90-second unattended dedicated-server run passed with one
 `asset.spawned` and one attributed `ordnance.fired` in a gapless 6-event run,
 zero participant events, and no scripting errors. The human-in-seat
 validation (player asset identity, incarnation generation across rejoin and
 restart, and intentional despawn) is the combined follow-up with Slice 9.
 Evidence: `docs/telemetry/slice-10-asset-evidence.md`.

 The first two-player live drill (2026-09-03, run
 `run-20260903T184502Z-0758ed75`, 105 events delivered, run `ended` in
 production) validated the Slice 10 bandit side (waves g1–g5, full bandit
 ordnance attribution) but exposed the multiplayer participant/asset
 lifecycle gap: no `participant.entered` for either player (initial or
 rejoin) and no new asset incarnation on a hard-disconnect/rejoin, leaving
 the rejoining player's later shots unresolved. The root cause and fix are
documented in `docs/telemetry/rejoin-fix-evidence.md` (merged to `main` as
  commit `f4d35f3`, pushed; live validation still pending):
 `PlayerEnterUnit` is not multiplayer-safe in the pinned MOOSE; the
 multiplayer-safe `PlayerEnterAircraft` (synthesized with real `Ini*`
 fields) is what the fix subscribes to, with `Ini*`-first normalization,
 corrected aircraft categories, `IniPlayerUCID`-only participant identity,
 and strong retention of the gameplay watchers. 74 pure-Lua tests + stylua
 pass; the live human-in-seat rejoin drill is the outstanding gate (same doc,
 §6). Raw drill evidence is archived locally (PII, not in the repo).

 Slice 11 was re-scoped (2026-09-04, user decision) from "valuation
 catalogue for the configured loadouts" to **loadout and ordnance type
 coverage**: telemetry must be robust to any type DCS can emit — player
 rearm at airbases, swapped planes, future bandit airframe/loadout
 changes — so a broad in-game matrix (all blue and red AAM variants, A/G
 samples, guns policy, swap-in bandit airframes) is established first via
 the deterministic unattended knobs, keyed on the exact `dcs_type` strings
 DCS emits; the versioned catalogue (name/category/value/source) absorbs
 the old Slice 11 scope and gates Slice 12. New **Slice 19** (last in the
 plan): a Sol study on decoupling telemetry from the mission — shared
 mission-side library vs DCS MOD vs server-side collection — with a probe
 MOD feasibility spike. Mission identity (`mission_name`/`missionVersion`)
 is already in the contract and the run store; the dashboard mission
 filter is a Slice 15 view. The scoped AAM/airframe matrix and local immutable
 catalogue checkpoint were completed on 2026-09-05. The generated database
 migration and seed have not been run remotely; Slice 12 still requires human
 approval.

Telemetry now has priority over the optional MIST respawn work.

---

## 7. Re-entering the project

1. Pull / read the project, read this file and
   `docs/spec-duel-dynamic.md`.
2. Verify the env: see §2 — `MissionScripting.lua` on the dedicated-server
   install is currently **stock** (restored 2026-09-04 after the Slice 11
   matrix run). To re-enter dev mode (dynamic `src/` loading), patch per
   `docs/dev-setup.md §2`; keep it stock before any shipping build or
   before flying/joining untrusted missions/servers.
3. Start the dedicated server, WebGUI → Restart `duel-dynamic`.
4. Sanity check: the log shows the init sequence from
   `spec-duel-dynamic.md §7`. The bandit spawns. F10 menu works.
5. For telemetry, review the Slice 11 matrix and catalogue research, then
   explicitly approve Slice 12 before implementation. The Slice 11 database
   migration/seed also remains a separate manual deployment action. Other work
   remains in §6.1, §6.2, and §6.4. §6.3 builds a self-contained `.miz`; final
   QA on a stock install remains.

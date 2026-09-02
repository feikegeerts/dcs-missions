# Project status

**Last updated:** 2026-09-01. Read this first when coming back.

This is a snapshot of where the project is, what's known to work, what's
known to be broken, and what still needs to happen before the mission
is shippable. If you change anything, update the relevant section.

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

> **DCS environment is currently STOCK** (verified 2026-08-31). Both
> installs (`C:\Program Files (x86)\Steam\steamapps\common\DCSWorld`
> and `D:\DCS World Server`) have `MissionScripting.lua` restored from
> the `.orig` backups with matching SHA-256 hashes — `os`/`io`/`lfs` are nilled. This is what
> you need to verify the shipping `.miz` works.
>
> To re-enter dev mode: patch the file again per `docs/dev-setup.md §2`.
> Before flying any untrusted mission or joining an unknown server,
> restore the stock file.

Server config: `Saved Games\DCS.dcs_serverrelease\Config\autoexec.cfg`
has the no-render / no-track / silent-crash settings. Don't lose it.

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
  confirm that `SPAWN:InitGrouping` produces the intended 2/3-ship formation
  and that the shared CAP task yields the desired 2v2/3v3 behavior.

## 6. What's still to do (post-PTO)

### 6.1 MIST integration (for true random player respawns)

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

Status: **built** (2026-07-28). `build/pack-shipping-miz.ps1`
assembles `out/duel-dynamic.miz` (~840 KB, self-contained) from the
dev `.miz` and `src/`. Mission file parses as Lua 5.1, the inner
shipping `main.lua` parses as Lua 5.1 (gets to `env.info` on line 20
before failing on `env` being nil, which DCS injects at runtime).

- [x] Build a self-contained `.miz` that loads via `DO SCRIPT FILE` —
      `build/pack-shipping-miz.ps1` writes to `out/duel-dynamic.miz`
      and `out/duel-dynamic-build/` (staging dir, left in place for
      inspection when `-Zip` is not passed).
- [x] `-Zip` packaging and entry listing re-verified 2026-09-01. The
      PowerShell case-insensitive `$Zip`/`$zip` variable collision was fixed.
- [x] Strip all `:TraceOn()` / `BASE:TraceOn()` calls. Sanity check
      in the packager; current `src/` has none.
- [x] `os.time()` → `math.floor(timer.getTime() * 1000)` for the LCG
      seed (stock DCS nils `os`).
- [x] `score.lua` inlined into `Scripts/main.lua` (no `dofile()` in
      stock DCS — CWD is the DCS install dir, not the .miz).
- [x] `MissionScripting.lua` restored to stock on both installs
      (2026-07-28). `os`/`io`/`lfs` are nilled again. The `.orig`
      backups were the source.
- [x] Lua syntax of patched mission file validated with `lua5.1
      -e "loadfile(...)"`.
- [ ] Verify it runs on a stock (sanitized) DCS install. The user
      (2026-07-28) hit one Lua parse error on first attempt — the
      packager used `""` for inner quotes (Lua adjacent-string
      concat) instead of `\"` (escaped quote), so the .miz wouldn't
      load. **Fixed** in the packager; re-built .miz parses cleanly.
      User to retry.
- [ ] Final QA on a fresh dedicated server install.

See `docs/shipping-duel-dynamic.md` for what the packager does and
how to verify, and `docs/dev-setup.md §8` for the build/QA loop.

### 6.4 Smaller polish

- [x] Remove coalition-wide player death/respawn notices and label bandit kill
      totals honestly as team totals. Individual attribution remains planned
      for telemetry Slice 14.
- [x] Replace per-player bandit resets with whole-package waves. Partial red
      losses are held; the 30-second timer starts after the final red loss.
- [ ] Validate 1v1, 2v2, and 3v3 package geometry/tasking on the dedicated
      server and inspect the result in Tacview.
- [ ] Install/configure Tacview for
      `Saved Games\DCS.dcs_serverrelease` before that validation run.
      Inspection on 2026-09-01 found Tacview `1.9.4.200` installed only under
      the full-client `Saved Games\DCS` profile. The server profile currently
      has no `Mods\tech\Tacview`, `Scripts\TacviewGameExport.lua`,
      `Scripts\Hooks\TacviewGameGUI.lua`, `Scripts\Export.lua`, or Tacview
      plugin options. Preserve/merge any future `Export.lua`; do not overwrite
      unrelated export integrations.
- [ ] Pick a real map / theatre. Caucasus is the test default. Decide
      if the production mission uses a different map and update both
      the ME and the spec.
- [ ] Decide on the production aircraft. The current test uses
      FA-18C + Su-33. Pick the final pair and update the ME / spec.

### 6.5 Telemetry

Slices 1–5 are complete. Slice 5 was validated with controlled and two-player
dedicated-server runs, and the development environment was restored to stock
afterward. The next planned telemetry work is Slice 6, the local collector
parser and durable spool, but Gate E approval is required before it starts.

---

## 7. Re-entering the project

1. Pull / read the project, read this file and
   `docs/spec-duel-dynamic.md`.
2. Verify the env: `MissionScripting.lua` is **stock** in both
   installs (verified 2026-08-31; both have
   `MissionScripting.lua.orig` backups for verification). If you
   want to re-enter dev mode, patch it per `docs/dev-setup.md §2`.
3. Start the dedicated server, WebGUI → Restart `duel-dynamic`.
4. Sanity check: the log shows the init sequence from
   `spec-duel-dynamic.md §7`. The bandit spawns. F10 menu works.
5. For telemetry, review Slice 5 evidence and approve Slice 6 explicitly before
   implementation. Other work
   remains in §6.1, §6.2, and §6.4. §6.3 builds a self-contained `.miz`;
   final QA on a stock install remains.

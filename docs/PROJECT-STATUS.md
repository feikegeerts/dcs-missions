# Project status — pre-PTO snapshot

**Last updated:** 2026-07-27 (pre-PTO handoff). Read this first when
coming back.

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

> **DCS environment is currently STOCK** (as of 2026-07-28). Both
> installs (`C:\Program Files (x86)\Steam\steamapps\common\DCSWorld`
> and `D:\DCS World Server`) have `MissionScripting.lua` restored from
> the `.orig` backups — `os`/`io`/`lfs` are nilled. This is what
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
- ✅ `SPAWN:New("Bandit-N")` succeeds for all three bandit groups (the
  earlier "no group declared" error was caused by the .miz only
  containing `Bandit-1`; this is now fixed in the .miz in the server
  Missions folder).
- ✅ Player-enter spawns the paired bandit 60+ sm away, in a random
  direction, with INTERCEPT task and aggressive options.
- ✅ Bandit kill → 30 s timer → fresh bandit 60+ sm from live player.
- ✅ Player leave → despawn paired bandit.
- ✅ Player kill → 30 s timer → despawn old bandit + spawn fresh bandit
  60+ sm from the player's slot position.
- ✅ F10 menu (Show kills / Reset kills / Respawn all bandits) works.
- ✅ Score counter increments, displays via F10 message, resets.
- ✅ Round 1 heading randomization on player slot (visible in HSI).
- ✅ `stylua --check` passes on both missions.
- ✅ Dedicated server: WebGUI restart reloads from disk with no repack.

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
  new coord. The current `handlePlayerDeath` does *not* call `Teleport`
  for this reason. Workaround: load MIST and use
  `mist.teleportToPoint({action="respawn"})` — see §6.
- ⚠️ **`duel-1v1` is in a broken intermediate state.** Has duplicate
  top-level code from a half-done edit. Do not switch
  `.current-mission` back to it without cleanup. See spec §10.

## 6. What's still to do (post-PTO)

### 6.1 MIST integration (for true random player respawns)

To get the player teleporting to a new position on death, we need
`mist.teleportToPoint`. Steps:

1. Download `mist.lua` (MissionScriptingTools release).
2. Drop it into `src/lib/`.
3. In `bootstrap.lua`, `dofile` it after Moose_ but before the mission
   main, so `_G.mist` is available.
4. Replace the death handler's "despawnBandit + spawnBanditAt" with:
   ```lua
   local newPos, _ = randomOffsetCoord(playerAnchor, RANDOM_DIST_MIN_M, RANDOM_DIST_MAX_M)
   mist.teleportToPoint({ groupName = pname, point = newPos, action = "respawn" })
   despawnBandit(idx)
   spawnBanditAt(idx, newPos)
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

- [ ] `missions/duel-dynamic/score.lua` rename — `Tracker:format()` is
      a stub. Implement a per-player breakdown ("James V: 3, Bob: 1")
      or a kill list. Not blocking, but useful.
- [ ] Pick a real map / theatre. Caucasus is the test default. Decide
      if the production mission uses a different map and update both
      the ME and the spec.
- [ ] Decide on the production aircraft. The current test uses
      FA-18C + Su-33. Pick the final pair and update the ME / spec.

---

## 7. Re-entering the project

1. Pull / read the project, read this file and
   `docs/spec-duel-dynamic.md`.
2. Verify the env: `MissionScripting.lua` is **stock** in both
   installs (default state as of 2026-07-28; both have
   `MissionScripting.lua.orig` backups for verification). If you
   want to re-enter dev mode, patch it per `docs/dev-setup.md §2`.
3. Start the dedicated server, WebGUI → Restart `duel-dynamic`.
4. Sanity check: the log shows the init sequence from
   `spec-duel-dynamic.md §7`. The bandit spawns. F10 menu works.
5. Pick up at §6.1, §6.2, or §6.4 depending on what you want to do
   next. §6.3 is done (build produces a self-contained .miz; final
   QA on a stock install is the only remaining step there).

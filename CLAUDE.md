# DCS Mission Project

Custom DCS World missions with complex spawn logic and score tracking. Developed outside the in-game mission editor as much as possible.

## Stack

- **Lua 5.1** (DCS embeds 5.1.5 — no `string.pack`, no 5.2+ APIs, `newproxy` exists)
- **MOOSE** framework — `https://flightcontrol-master.github.io/MOOSE/`
  - Modern classes: **OPS** (`AUFTRAG`, `FlightGroup`, `EasyGCICAP`, `EasyAG`, `Airboss`...), Core (`SPAWN`, `ZONE`, `SCORE`...), Functional, Sound, Utilities
  - Old `AI_*` / Tasking / Cargo classes are **archived** — use OPS/AUFTRAG for new code
  - MOOSE now ships native `Ops.CTLD` and IADS-ish classes (`Mantis`, `Shorad`) — evaluate before adding external CTLD/Skynet
  - Discord: `https://discord.gg/gj68fm969S`
- **MIST**, **CTLD**, **Skynet-IADS** as needed (interoperate with MOOSE)
- **Tacview** for replay — `.acmi` files default to `%USERPROFILE%\Documents\Tacview\`; works on dedicated servers via `Saved Games\DCS.server\Config\options.lua`

## Project layout

```
C:\Projects\dcs-missions\
  src\                          # Lua source, edited in VSCode
    bootstrap.lua               # dispatcher (shared, never mission-specific)
    .current-mission            # one line: the active mission's name
    lib\Moose_.lua              # pinned MOOSE build (comment-stripped)
    missions\<name>\            # one folder per mission
      main.lua                  # entry point
      score.lua                 # siblings
  lib\moose-src\                # MOOSE source tree (for IDE only)
  build\pack-miz.ps1            # re-zips missions\<name>\ → out\<name>.miz
  out\                          # generated .miz files
  docs\                         # see "Documentation" below
```

**Documentation:**

- `docs/dev-setup.md` — full env setup, dev loop, debugging, troubleshooting.
- `docs/mission-loader.md` — the dev loader pattern (why the .miz is a dumb loader).
- `docs/spec-duel-dynamic.md` — **active mission spec** (1–3 vs 1–3 dynamic spawn). Read this for the current state of the code.
- `docs/PROJECT-STATUS.md` — pre-PTO snapshot: what's done, what's broken, what's left to ship. Read this first when coming back.
- `docs/shipping-duel-dynamic.md` — checklist for packaging the mission for distribution (self-contained .miz, sanitized DCS).
- `docs/spec-duel-1v1.md` — **superseded** (do not switch to this mission without cleanup).

## Key technical decisions

### 1. De-sanitize the Lua environment (required for dev)

Edit **`<DCS install>\Scripts\MissionScripting.lua`** — same file/path for stable AND open beta (there is no beta-specific `Scripting.lua`; `Scripts\ScriptingSystem.lua` is a different file that MissionScripting.lua itself loads).

Comment out the `sanitizeModule('os' | 'io' | 'lfs')` lines; also un-nil `require` / `package` / `loadlib` if needed. `dofile` is never sanitized. **Re-apply after every DCS update or repair** — the updater restores the file.

Both the **client** AND the **dedicated server** install need this (the dev `.miz` lives in `Saved Games\DCS.dcs_serverrelease\Missions\`). Does not affect MP joining or server scripts. See "Safety".

### 2. Hot-reload from disk instead of re-zipping

Mission bootstrap loads scripts from `Saved Games\DCS\MyMissions\scripts\` via `dofile(lfs.writedir() .. ...)`. An absolute `assert(loadfile(path))()` (VEAF pattern) also works. Gate static-vs-dynamic behind a flag: **dynamic from disk for dev, statically embedded for shipping** — never ship a .miz that requires a de-sanitized env. This project uses the absolute `assert(loadfile([[C:\Projects\dcs-missions\src\bootstrap.lua]]))()` pattern; `bootstrap.lua` reads `.current-mission` and dispatches to the active mission's `main.lua`. The dispatch pattern is documented in `docs/mission-loader.md`.

### 3. Local dedicated server for the test loop

Use the modular **"DCS World Dedicated Server"** installer (no textures/sound, WebGUI-only). Facts:

- Write dir: `Saved Games\DCS.server` → logs at `Saved Games\DCS.server\Logs\dcs.log`
- Ports: 10308 TCP/UDP (game), 8088 TCP (local WebGUI)
- **There is no console and no `loadmission` command.** Restart via WebGUI, or call `net.load_mission(path)` — a **server-environment** Lua function (2.5.0+), reachable from hook scripts in `Saved Games\DCS.server\Scripts\Hooks\` or via DCS-gRPC / DCSServerBot. Not available in the mission scripting env.
- Single-player quick iteration: `LeftShift+R` restarts the mission. Reserve SP for final QA only if server loop is working. This project's dev `.miz` is on `Saved Games\DCS.dcs_serverrelease` (the channel name can vary — confirm with `Get-ChildItem $env:USERPROFILE\Saved Games -Directory`).

### 4. .miz is just a zip

Required entries: `mission`, `options`, `warehouses`, `l10n\DEFAULT\dictionary`. Optional: `l10n\DEFAULT\mapResource` + embedded payloads referenced by ResKeys. DCS writes slightly non-standard zips — 7-Zip's benign `Headers Error` warning when extracting editor-saved files is normal.

Repack with `build\pack-miz.ps1` — never re-zip manually in the editor mid-dev. Proven alternatives: **pydcs** (Python lib, generates complete .miz), **VEAF-mission-converter** (git-versioned unpacked-mission pattern).

## Development loop

1. Edit Lua in `src\` with VSCode
2. Dynamic mode: restart mission (WebGUI / `net.load_mission` / LShift+R) — no repack
3. Otherwise: `build\pack-miz.ps1 <mission-name>`, drop in server `Missions\`
4. Test on dedicated server; tail `Saved Games\DCS.server\Logs\dcs.log`
5. Sanity-check spawn logic visually in Tacview

## Editor tooling

- **VSCode + LuaLS** (`sumneko.lua` extension). `.luarc.json`:
  - `runtime.version = "Lua 5.1"`
  - `diagnostics.globals`: `env`, `timer`, `trigger`, `world`, `coalition`, `country`, `land`, `missionCommands`, `lfs`, MOOSE classes, `mist`, ...
  - `workspace.library`: `dcs-world-schema` stub (github.com/YoloWingPixie/dcs-world-schema — only published DCS API annotation set; disable its `deprecated` diagnostic per its README), the MOOSE source tree (`Moose Development/Moose`), `mist.lua`
  - Caveat: MOOSE/MIST use LDoc, not LuaCATS — you get completion/hover, not typed signatures
- **StyLua** (`syntax = "Lua51"`) for formatting; **luacheck** with `.luacheckrc` (`std = "lua51"` + `read_globals` for DCS/MOOSE globals — MOOSE's own `.luacheckrc` is a good reference)
- **Unit tests**: no community standard; proven pattern is luaunit/busted + hand-rolled DCS API mocks (see Skynet-IADS `unit-tests/`). Great fit for pure logic like score tracking — keep game-dependent code thin.
- **In-mission REPL**: `flying-dice/dcs-fiddle` (browser Lua REPL in a running mission) or DCS-gRPC. Debugger: `Reousa/VSCode-DCS-Debugger`.

## Safety

- De-sanitizing `MissionScripting.lua` has **no known IC/anti-cheat consequences**; the whole persistence ecosystem (Liberation, DSMC, DCT, DCSServerBot, MOOSE CSAR) requires it. No official ED policy exists either way.
- The real risk is **to you**: de-sanitized, any mission you fly or server you join can run arbitrary file/OS code on your machine. Restore the file (or repair) before flying untrusted missions/servers.
- Things that *do* get you banned: patching `DCS.exe`, memory injection, network protocol mods, pirated copies.
- Keep backups of the original `MissionScripting.lua` for clean MP tests.

## DCS API gotchas (non-obvious)

- Lua **5.1.5**. Don't assume `string.pack` / `table.create` / 5.2+ APIs exist.
- Most things are in the env scripting API (`trigger.action.*`, `world.addEventHandler`, `mist.*`), not the in-game editor trigger API. Prefer env scripting over triggers.
- `coalition` IDs: 0 = neutral, 1 = red, 2 = blue. Mix these up and nothing fires.
- `timer.scheduleFunction(fn, arg, modelTime)` — return the next model time to reschedule, `nil` to stop. Errors inside scheduled functions are trapped and **silently kill the schedule**. Don't busy-loop with `while true`.
- `env.info` / `env.warning` / `env.error` always write to `dcs.log`. There is no scripting log-verbosity switch.
- The `net` singleton differs by environment: mission env (chat/kick/slot) vs server env (`net.load_mission`, `net.dostring_in`).
- Spawned units are gone forever when destroyed. For waves/respawn use MOOSE `SPAWN` — don't roll your own.

## MOOSE conventions

- Get `Moose_.lua` (comment-stripped) or `Moose.lua` from the **MOOSE_INCLUDE** repo; repo default branch is `master-ng` (stable), `develop` has the newest classes. Pin an embedded static copy per mission for production; the dynamic loader (`Moose_Include_Dynamic`) is for MOOSE developers only.
- Load order: `MISSION START` trigger with **no conditions** (a conditioned MISSION START never fires) for Moose_.lua, then mission scripts.
- Verify load: grep `dcs.log` for `*** MOOSE INCLUDE END ***`; check `SCRIPTING` WARNING/ERROR lines (ignore non-SCRIPTING noise).
- Tracing: `BASE:TraceOn()` / `:TraceLevel(n)` / `:TraceAll()` on any class — but **off by default in static builds**; enable for debugging only.
- Class docs index: `https://flightcontrol-master.github.io/MOOSE_DOCS/Documentation/index.html` (the site root is just a portal). `MOOSE_DOCS_DEVELOP` covers the develop branch — if a class 404s in stable docs, it's probably develop-only.
- Canonical usage examples live in `MOOSE_MISSIONS_UNPACKED` / `MOOSE_Demos` repos — often better than the written guides (old guides are archived and describe legacy `AI_*` APIs).
- Don't fight MOOSE. Vanilla `trigger.action.*` calls inside a MOOSE mission usually mean you're doing it wrong.

## References

- **MOOSE agent skill**: `.opencode/skills/moose/` — class map, canonical patterns, gotchas. Use it for all MOOSE scripting work.
- **Setup manual**: `docs/dev-setup.md` — full env setup, dev loop, debugging, shipping, troubleshooting.
- **Active mission spec**: `docs/spec-duel-dynamic.md` — current mission behaviour, knobs, and known limitations.
- **Project status**: `docs/PROJECT-STATUS.md` — pre-PTO snapshot, what's done / broken / next.
- **Shipping checklist**: `docs/shipping-duel-dynamic.md` — how to package the mission for distribution.
- Hoggit wiki (canonical DCS scripting API ref): `https://wiki.hoggitworld.com`
- MOOSE docs: `https://flightcontrol-master.github.io/MOOSE/` · class API: `.../MOOSE_DOCS/Documentation/index.html` (develop: `.../MOOSE_DOCS_DEVELOP/Documentation/index.html`) · includes: `github.com/FlightControl-Master/MOOSE_INCLUDE` · source: `github.com/FlightControl-Master/MOOSE` (`master-ng`) · examples: `MOOSE_MISSIONS_UNPACKED` / `MOOSE_Demos` · Discord: `https://discord.gg/gj68fm969S`
- awesome-dcs-world (tooling index): `github.com/DaKerboul/awesome-dcs-world`
- pydcs: `github.com/pydcs/dcs` · VEAF-mission-converter: `github.com/VEAF/VEAF-mission-converter`
- ED official SSE docs: digitalcombatsimulator.com → Support → FAQ → "DCS: World Scripting Engine" (old wiki.eagle.ru is dead)
- Tacview docs: `raia-software-inc.gitbook.io/tacview`

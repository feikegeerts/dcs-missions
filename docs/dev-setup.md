# DCS Mission Dev Environment — Setup & Operations Manual

How to set up and run the development loop for this project. Read `CLAUDE.md` for
conventions; this doc is the step-by-step setup + daily operations + debugging guide.

Everything is Windows/PowerShell-flavored. Paths assume a default DCS install;
adjust for your machine.

---

## 0. What you're building

```
VSCode (edit src/*.lua)
      │
      ▼  save
DCS mission starts ──► bootstrap trigger in .miz ──► loadfile() your Lua from disk
      │                                                (no repack, no editor)
      ▼
Saved Games\...\Logs\dcs.log  +  Tacview  ──►  you read results, iterate
```

The `.miz` is a **dumb loader** during development: it contains one trigger that
loads `src\bootstrap.lua` from disk. All real code lives in this repo. Restarting
the mission re-reads the files — that is the entire iteration cycle.

Only when shipping do you pack scripts *into* the .miz (static mode).

---

## 1. Prerequisites

| Thing | Where | Notes |
|---|---|---|
| DCS World (client) | installed | stable or open beta, either works |
| **DCS World Dedicated Server** (modular installer) | `digitalcombatsimulator.com/en/downloads/world/server/` | separate install, no textures/sound, WebGUI-only |
| VSCode | installed | plus extensions in §4 |
| Git | installed | |
| 7-Zip (optional) | installed | for inspecting .miz files |

Log into the dedicated server with your ED account (same as the game). Install the
terrain module(s) your mission needs on the server too — terrains do **not** need
activation in no-render server mode.

---

## 2. De-sanitize the Lua environment (required, both installs)

DCS ships with `os`/`io`/`lfs`/`require` nil'd in mission scripts. Hot-reload and
any file persistence need them back.

**File (same name in stable AND open beta, client AND server install):**

```
<DCS install>\Scripts\MissionScripting.lua
```

1. Back it up first: copy to `MissionScripting.lua.orig`.
2. Open in an editor (as admin if under Program Files), find the block:

```lua
do
	sanitizeModule('os')
	sanitizeModule('io')
	sanitizeModule('lfs')
	_G['require'] = nil
	_G['loadlib'] = nil
	_G['package'] = nil
end
```

3. Comment out at least the three `sanitizeModule(...)` lines (and the `_G[...]` lines
   if you want `require`/`package`):

```lua
do
	--sanitizeModule('os')
	--sanitizeModule('io')
	--sanitizeModule('lfs')
	_G['require'] = nil
	_G['loadlib'] = nil
	_G['package'] = nil
end
```

4. **Re-apply after every DCS update or repair** — the updater detects the modified
   file and restores the stock one. Symptom of forgetting: missions that load files
   suddenly fail with `attempt to index ... nil` on `lfs`/`os`/`io`.

Do this for **both** the client install and the dedicated server install.

> Security: a de-sanitized install lets any mission you fly (incl. downloaded ones /
> MP server missions) run arbitrary file/OS code on your machine. Restore the stock
> file (or run a repair) before flying untrusted missions/servers. See §9.

---

## 3. Dedicated server setup

1. Install via the modular installer. Default write dir: **`Saved Games\DCS.server`**.
2. Start it once; open the local WebGUI (desktop link "Local Web GUI", or
   `http://localhost:8088`).
3. Ports (forward only if you want external players; not needed for local dev):
   - `10308` TCP+UDP — game traffic
   - `8088` TCP — local WebGUI
4. Put dev .miz files in `Saved Games\DCS.server\Missions\`, add to the mission list
   in the WebGUI.
5. Recommended hardening — create `Saved Games\DCS.server\Config\autoexec.cfg`:

```lua
options.graphics.render3D = false
options.graphics.maxfps = 30
crash_report_mode = "silent"
disable_write_track = true
```

Facts to remember:
- There is **no console** and no `loadmission` command. Control = WebGUI
  (start/stop/restart buttons).
- Programmatic restart is possible via the **server-env** function
  `net.load_mission(path)` from a hook script in
  `Saved Games\DCS.server\Scripts\Hooks\` (how DCSServerBot/DCS-gRPC do it).
  Optional quality-of-life; the WebGUI button is fine to start.
- Server log: `Saved Games\DCS.server\Logs\dcs.log`.

---

## 4. VSCode setup

Extensions:

- **Lua** (`sumneko.lua`) — language server, the important one
- **StyLua** (`JohnnyMorganz.stylua`) — formatting (optional)

Get reference material for IntelliSense (into `C:\Projects\dcs-missions\lib\`):

```
lib\
  Moose.lua            # from github.com/FlightControl-Master/MOOSE_INCLUDE (branch master, Moose_Include_Static)
  Moose_.lua           # comment-stripped build — this is what ships in missions
  moose-src\           # (optional) github.com/FlightControl-Master/MOOSE, branch master-ng,
                       #   folder "Moose Development/Moose" — richer hover/completion
  mist.lua             # (optional) github.com/mrSkortch/MissionScriptingTools
  dcs-world-schema\    # (optional) github.com/YoloWingPixie/dcs-world-schema — DCS API annotations
```

`.luarc.json` in the repo root:

```json
{
  "runtime.version": "Lua 5.1",
  "diagnostics.globals": [
    "env", "timer", "trigger", "world", "coalition", "country", "land",
    "missionCommands", "lfs", "mist",
    "SPAWN", "SPAWNSTATIC", "ZONE", "ZONE_AIRBASE", "ZONE_GROUP", "SET_GROUP",
    "SET_UNIT", "SET_CLIENT", "MESSAGE", "MENU_COALITION", "MENU_COALITION_COMMAND",
    "TIMER", "EVENTS", "BASE", "AUFTRAG", "FLIGHTGROUP", "ARMYGROUP", "SCORING",
    "_DATABASE", "_SETTINGS"
  ],
  "workspace.library": ["lib/dcs-world-schema", "lib/moose-src", "lib"],
  "diagnostics.disable": ["deprecated"]
}
```

(`dcs-world-schema` currently marks everything deprecated — its README recommends
disabling that diagnostic. MOOSE/MIST use LDoc, not LuaCATS: you get
completion/hover, not typed signatures.)

Linting (optional): `luacheck` with a `.luacheckrc` — `std = "lua51"` plus the same
globals as `read_globals`. MOOSE's own repo `.luacheckrc` is a good reference.

---

## 5. Project scaffolding

### 5.1 Layout

```
C:\Projects\dcs-missions\
  src\
    bootstrap.lua        # entry point loaded by the .miz trigger
    lib\Moose_.lua       # pinned MOOSE build (per mission, deliberate upgrades)
    spawn\ score\ ...    # your modules
  build\pack-miz.ps1     # packs missions\<name>\ → out\<name>.miz (shipping only)
  missions\<name>\       # unpacked .miz tree (gitignored, derived)
  out\                   # packed .miz files
  docs\                  # this manual
```

### 5.2 Multi-mission layout

The repo holds any number of missions; only one is "active" (in edit mode) at a time.
Each mission lives in its own subfolder; the dispatcher and framework are shared.

```
src/
  bootstrap.lua                          # dispatcher — never mission-specific
  lib/Moose_.lua                         # framework (one pinned build, shared)
  missions/
    <mission-name>/
      main.lua                           # entry point
      ...                                # siblings (score.lua, spawn.lua, ...)
  .current-mission                       # one line: the active mission's name
```

`bootstrap.lua` reads `.current-mission` to decide which mission to load. Switching
missions = edit that one line, restart. No git branch, no repack, no editor.

### 5.3 Mission skeleton (in the Mission Editor)

Create the mission with the things that are painful in code:

- Map, date/time, weather, both coalitions
- Player/client slots
- **Template groups** for every SPAWN template — set **Late Activation** so the
  template itself never spawns. The group **name** is what `SPAWN:New("name")` uses.
- Trigger **zones** for spawn/kill zones (referenced by `ZONE:New("name")`)
- Exactly **one** trigger:

```
TYPE: MISSION START   (NO conditions — a conditioned MISSION START never fires)
ACTION: DO SCRIPT (paste the loader below)
```

```lua
-- Dev loader: the same code for every .miz. The dispatcher (src/bootstrap.lua)
-- reads .current-mission to know which mission to load.
local ok, err = pcall(function()
  assert(loadfile([[C:\Projects\dcs-missions\src\bootstrap.lua]]))()
end)
if not ok then env.error("[myMission] bootstrap: " .. tostring(err)) end
```

Save as `<name>.miz` via the editor and place it in the Saved Games folder for
the channel you're testing on. Most dev is on the dedicated server:

```
%USERPROFILE%\Saved Games\DCS.dcs_serverrelease\Missions\<name>.miz
```

(Stable: `DCS.dcs_serverrelease`; open beta: `DCS.dcs_serveropenbeta`. Confirm
with `Get-ChildItem $env:USERPROFILE\Saved Games -Directory`.)

You won't touch the editor again unless templates/zones/weather/slots change.
The project's `missions/` folder is only used by `build\pack-miz.ps1` for
shipping — not part of the dev loop.

### 5.4 bootstrap.lua (the dispatcher — in `src/`)

Already in the repo at `src/bootstrap.lua`. Reads `.current-mission`, sets
`_G.MY_SCRIPTS_ROOT` for mission code to find siblings, loads MOOSE, then loads
`missions/<name>/main.lua`. Don't edit it for a new mission — just add a folder
under `src/missions/<name>/`.

### 5.5 Mission main.lua (in `src/missions/<name>/`)

Each mission's entry point. Example skeleton:

```lua
env.info("[<mission-name>] main start")

if not _G.MOOSE then
  env.error("[<mission-name>] MOOSE not loaded — check src/lib/Moose_.lua")
  return
end

-- Load siblings (set by bootstrap)
local ROOT = _G.MY_SCRIPTS_ROOT
local DIR  = ROOT .. "missions/<mission-name>/"
dofile(DIR .. "score.lua")

-- ... mission setup: F10 menus, event handlers, spawn templates, ...
env.info("[<mission-name>] main done")
```

> Shipping (static mode) swaps the trigger for `DO SCRIPT FILE` entries embedding
> Moose_.lua + the mission scripts into the .miz, so the shipped file needs no
> de-sanitized environment. Static-mode packaging from `build/pack-miz.ps1` is
> not implemented yet — see `docs/mission-loader.md`.

---

## 6. The daily dev loop

```
1. Edit src\*.lua in VSCode, save
2. Restart the mission:
     SP test client : LeftShift+R            (~2 s, fastest — use this most)
     Dedicated srv  : WebGUI → Restart        (realistic MP behavior)
3. Read results:
     dcs.log tail (see §7.1), Tacview replay (§7.5)
4. Repeat
```

No repack, no editor, no copy steps — the loader re-reads from `src\` every start.

Only when **templates/zones/weather/client slots** change do you edit the .miz in the
Mission Editor (and re-copy it to both Missions folders).

---

## 7. Debugging toolkit

### 7.1 dcs.log (primary)

```powershell
# SP client:
Get-Content -Wait -Tail 30 "$env:USERPROFILE\Saved Games\DCS\Logs\dcs.log"
# dedicated server:
Get-Content -Wait -Tail 30 "$env:USERPROFILE\Saved Games\DCS.server\Logs\dcs.log"
```

What to look for, in order:

1. `*** MOOSE INCLUDE END ***` — MOOSE loaded at all?
2. `[bootstrap] ... ERROR` / `SCRIPTING ... ERROR` — the **first** error line names
   `file:line`. A syntax error in any module aborts the whole bootstrap; "nothing
   works" almost always means this.
3. Your own breadcrumbs: `env.info("[myMission] ...")` — always printed; no
   verbosity switch exists.

### 7.2 MOOSE tracing

On any class while testing:

```lua
mySpawner:TraceOn():TraceLevel(2)   -- method entry/exit + state → dcs.log
-- or globally: BASE:TraceOn()
```

Off by default in static builds (good for production). **Strip before shipping.**

### 7.3 Silent timer deaths

Errors inside `TIMER` callbacks / `timer.scheduleFunction` are **swallowed** — the
schedule just dies, no log line. During development, wrap non-trivial callbacks:

```lua
TIMER:New(function()
  local ok, err = pcall(updateWaves)
  if not ok then env.error("[waves] " .. tostring(err)) end
end):Start(5, 30)
```

### 7.4 In-mission REPL

**dcs-fiddle** (`github.com/flying-dice/dcs-fiddle`) — browser Lua REPL attached to a
running mission. Inspect live globals (`mySpawner`, `_DATABASE`), call functions,
spawn things without restarting. Best tool for "why is this table empty".
Alternative: DCS-gRPC (works against the dedicated server too).

### 7.5 Tacview (behavioral verification)

Records everything your scripts did — spawn positions/timing, group composition,
routes, deaths. Default folder: `%USERPROFILE%\Documents\Tacview\`. Use it to verify
spawn/wave logic actually behaves as designed; catches geometry and timing bugs that
logs can't show. Works on the dedicated server too
(`Saved Games\DCS.server\Config\options.lua` → `["Tacview"]` block).

### 7.6 Breakpoint debugging (optional)

`Reousa/VSCode-DCS-Debugger` — real breakpoints/step-through in VSCode. Setup is
fiddly; worth it for gnarly state machines. Most work is faster via log + REPL.

### 7.7 Unit tests outside the game

Keep pure logic (score tracking is ideal) free of direct DCS API calls — pass in
plain data (names, coalition ids, timestamps). Then test with luaunit/busted + small
mocks of `Unit`/`Group`/`timer` (pattern: Skynet-IADS `unit-tests/`). Bugs caught
here never cost a DCS restart.

---

## 8. Shipping a mission (static mode)

1. Remove/disable all `TraceOn()`.
2. Switch the mission trigger from the dev `DO SCRIPT` loader to `DO SCRIPT FILE`
   entries (embed `Moose_.lua`, then your modules in order) — or pack via
   `build\pack-miz.ps1`, which assembles `missions\<name>\` (including embedded
   scripts) into `out\<name>.miz`.
3. The shipped .miz must run on a **stock** (sanitized) DCS — no `lfs`/`io`/`os`
   dependencies in shipping code paths.
4. Final QA: load the packed .miz on the dedicated server from a clean copy, fly it,
   check dcs.log, watch the Tacview.

.miz trivia: it's a zip with required entries `mission`, `options`, `warehouses`,
`l10n\DEFAULT\dictionary` (+ optional `mapResource` and payloads). Editor-saved zips
have slightly non-standard headers — 7-Zip's "Headers Error" warning on extract is
benign.

---

## 9. Safety & multiplayer

- De-sanitizing `MissionScripting.lua`: no known IC/anti-cheat consequences; the
  entire persistence ecosystem (Liberation, DSMC, DCT, DCSServerBot, MOOSE CSAR)
  depends on it. No official ED policy exists either way.
- The real risk is to **your machine**: de-sanitized, any mission you fly or server
  you join can run arbitrary file/OS code. **Restore `MissionScripting.lua.orig`
  (or repair DCS) before flying untrusted missions/servers.**
- Actually bannable: patching `DCS.exe`, memory injection, network protocol mods,
  pirated copies.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Nothing runs, no log lines from your code | Syntax error aborting bootstrap | First `SCRIPTING ERROR` line in dcs.log names `file:line` |
| `*** MOOSE INCLUDE END ***` missing | MOOSE didn't load | Check loader path/trigger; check dcs.log around mission start |
| Your edits have no effect | Mission loading embedded (static) scripts; forgot LShift+R; ME re-embedded stale file | Confirm dev trigger is `DO SCRIPT` loader; restart mission |
| `attempt to index nil` on `lfs`/`os`/`io` | DCS update restored `MissionScripting.lua` | Re-apply §2 |
| Logic starts then silently stops | Error swallowed inside TIMER/scheduled callback | §7.3 pcall wrapper |
| Server doesn't list the mission | Wrong folder / not in mission list | `Saved Games\DCS.server\Missions\`, add via WebGUI |
| `SPAWN` returns nil | Template group name typo / not late-activated / wrong coalition | Template name must match ME group name exactly |
| Group name comparisons fail | Alias suffix: spawned groups are `Name#NNN` | Prefix-match: `name:find("^Bandit%-Alpha")` |
| MOOSE class "doesn't exist" | Develop-only class, or legacy `AI_*` from an old guide | Check class against your pinned Moose_.lua (`findstr`) and stable docs |
| 7-Zip warns "Headers Error" extracting .miz | DCS writes non-standard zip headers | Benign — ignore |

---

## 11. Links

- Hoggit wiki (canonical DCS API ref): `https://wiki.hoggitworld.com`
- MOOSE docs: `https://flightcontrol-master.github.io/MOOSE/`
- MOOSE class index: `.../MOOSE_DOCS/Documentation/index.html` (+ `MOOSE_DOCS_DEVELOP`)
- MOOSE includes: `github.com/FlightControl-Master/MOOSE_INCLUDE` · source: `.../MOOSE` (branch `master-ng`)
- MOOSE Discord: `https://discord.gg/gj68fm969S`
- Dedicated server download: `digitalcombatsimulator.com/en/downloads/world/server/`
- dcs-fiddle: `github.com/flying-dice/dcs-fiddle` · debugger: `github.com/Reousa/VSCode-DCS-Debugger`
- dcs-world-schema: `github.com/YoloWingPixie/dcs-world-schema`
- MOOSE agent skill (this repo): `.opencode/skills/moose/`

# Helicopter Training Grounds

A training range built on top of the hand-made `Helicopter Training Grounds.miz`
(Batumi, Caucasus; CH-47F and UH-60L player slots). The `.miz` supplies the map,
the slots and the weather; everything else — cargo, pads, troops, targets,
markers, scoring and the F10 menu — is spawned and driven by the source in
`src/missions/helicopter-training/`.

## Why the range is not in the .miz

Objects placed in the editor cannot be tuned without opening the editor, cannot
be scored, and cannot be reset mid-flight. Spawning them from Lua gives:

* one file to edit for every site, radius and threshold (`config.lua`);
* a range that rebuilds itself after a reset or a restart;
* detection and scoring for every exercise (did the load land on the pad, was
  the hover inside the box, how long did the autorotation take).

## Loading it

### Launch the shipped mission (what players do)

```powershell
pwsh -File build/pack-helicopter-training-miz.ps1 -Install
```

Then in DCS: **MISSION → My Missions → Helicopter Training Grounds → Fly**.
No source tree, no de-sanitized environment, nothing else to install. The range
boots itself from the mission's own MISSION START trigger.

Friends need the **UH-60L mod** for the Blackhawk slot: the `.miz` lists it in
`requiredModules`, and DCS refuses to load the mission without it. To let someone
fly only the Chinook, build with `-DropRequiredModules` (the UH-60L slot is then
simply unavailable to them).

To fly it together, copy the built `.miz` to the dedicated server's Missions
folder and add it in the WebGUI:

```powershell
Copy-Item out\helicopter-training.miz "$env:USERPROFILE\Saved Games\DCS.dcs_serverrelease\Missions\"
# then http://localhost:8088 -> mission list -> Add -> Helicopter Training Grounds
```

### Development loader (live editing, no repack)

For iterating on the range code, add **one** MISSION START trigger to the
mission (`MISSION START`, no conditions, `DO SCRIPT`) with:

```lua
local root = [[C:\Users\g_for\orca\workspaces\dcs-missions\helicopter-testing-flight-mission\src\]]
local ok, err = pcall(function()
  _G.MY_SCRIPTS_ROOT = root
  assert(loadfile(root .. "missions/helicopter-training/main.lua"))()
end)
if not ok then env.error("[helicopter-training] " .. tostring(err)) end
```

After this branch is merged, the path becomes `C:\Projects\dcs-missions\src\`.
Restart with `LeftShift+R` (single player) or the WebGUI restart button (server)
after editing anything under `src/missions/helicopter-training/`. No repack.

Two notes on that snippet:

* **No de-sanitized environment needed.** `MissionScripting.lua` sanitization
  removes `os`, `io`, `lfs`, `require`, `package` and `loadlib`; it does not
  touch `loadfile` or `dofile`. The range uses only `loadfile`, so a stock
  client can run it. (The repository's other missions go through
  `src/bootstrap.lua`, which needs `io.open` for `.current-mission` unless it is
  called with the named-loader arguments. That path is available too, and is the
  right one if you want MOOSE loaded in the same mission.)
* The range deliberately has **no MOOSE dependency**. It uses the plain DCS
  scripting API, which keeps start-up instant and keeps the shipped payload
  small.

## What gets built

Sites come from `config.lua` and are resolved against real terrain at mission
start: each one is sampled, and if it lands in water or on ground that is too
rough it is moved outward to the nearest acceptable spot. Every site is logged
with its final position, height, local relief and how far it moved:

```
[helicopter-training] site pad_bravo     x=-356463 y=617644  h=8.0 m relief=0.6 m
[helicopter-training] site hill_east     x=-352400 y=619700  h=41.2 m relief=1.1 m  moved 300 m (relief 4.8 m)
```

| Exercise | Site | What counts as done |
|---|---|---|
| External load | cargo yard, pads Alpha/Bravo/Charlie | a load is lifted off the ground and set down within the pad radius |
| Troop lift | staging area, field LZ | squad embarked (mass fed to the flight model), landed and disembarked at the LZ |
| Confined landings | six pads incl. the obstacle ring | wheels/skids on the ground, < 3 m/s, inside the radius, held 3 s |
| Precision hover | hover pad | 45 s inside 10 m, 4-9 m AGL, heading within 20 deg |
| Autorotation | gate + orange pad | cross the gate above 300 m AGL at 100+ km/h, then land on the pad |
| Door gunner | gun line + target field | hits on the target field; targets respawn when cleared |

Scoreboard and controls live in the F10 menu under `RANGE`: `Status`,
`Briefing`, `Reset range` (respawn loads/squad/targets), `Clear scores`,
`Terrain scan`. The menu is per group, so each pilot gets their own.

## Scoring

`progress.lua` keeps per-pilot counts, best time and last detail. Metrics are
per exercise: external load and troop lift are scored on time from hook-up to
set-down, hover on maximum drift in metres (lower is better), landings on
repetitions, gunnery on hits. External loads are credited to the pilot nearest
the load at hook-up; loads are also marked with a map marker and coloured smoke
so they can be found without the F10 map.

## The coordinate problem (read this before trusting a site)

Batumi's surroundings are **not** reliably derivable from real-world geography.
The DCS Caucasus map's own beacons place Kobuleti 40 km from Batumi at a grid
bearing of 72 deg where the real-world bearing is 32 deg, while the map's own
runway headings are self-consistent — so converting real lat/lon through the
map's own anchors gives positions that disagree with the map's layout. The
sites in `config.lua` are therefore anchored on objects that shipped missions
already placed on this map:

| Evidence | Position | Meaning |
|---|---|---|
| FARP + two Humvees (UH-60L mod mission) | 700 m, bearing 214 deg from the apron | verified flat, usable land |
| M-109 battery ("Black Guard" campaign) | 6.15 km, bearing 247 deg | verified land |
| Moored dry-cargo ship (UH-60L mod mission) | 6.08 km, bearing 118 deg | verified water |

Everything in the 200-250 deg corridor is placed on that evidence; the 90-180
deg sector beyond ~3 km is sea and is left alone.

The two off-field pads (`hill_north`, `hill_east`) have **no** verified terrain
behind them. They are search centres: the resolver will relocate them if the
ground is unusable, and the `Terrain scan` menu item (and the automatic probe
8 s after mission start) samples 24 bearings x 8 distances and logs the best
flat ground and hill benches it finds. The intended loop is:

1. Run the mission once, unoccupied.
2. Read the `probe hill` / `probe flat` lines from `dcs.log`.
3. Freeze the winners into `config.sites` and set `probe.enabled = false`.

## Known limitations

* **No rescue hoist.** DCS models external sling load, not a winching hoist.
  The "hoist" exercises are sling load: the CH-47F picks loads from its own
  cargo menu, the UH-60L uses the standard external cargo hook binding. Both
  are native DCS systems; the range only supplies the loads and scores the
  delivery.
* **Troop transport is range-owned.** The CH-47F has its own native troop
  system (mission-editor infantry with an embark task); it cannot be scored and
  would not cover the UH-60L, so the range runs one system for both. Its
  capacity figures (31 / 11) come from the shipped "Long Lift" campaign.
* **Off-field pads are provisional** until the probe results are frozen in.
* **The four AI helicopters in the .miz** (`Rotary-3` UH-60L, `Rotary-4` OH-58D,
  `Rotary-5` UH-1H, `Rotary-6` SA342L) are parked hot with tasks, so they start
  up and fly off on their own. On a training range that is noise — and
  `Rotary-6` has a CAS task, so it will attack the gunnery targets. Recommended
  editor change: set those four groups to `Uncontrolled` (or delete them).

## Shipping

```powershell
pwsh -File build/pack-helicopter-training-miz.ps1                  # out\helicopter-training.miz
pwsh -File build/pack-helicopter-training-miz.ps1 -Install         # and copy it into the client's Missions folder
pwsh -File build/pack-helicopter-training-miz.ps1 -DropRequiredModules
```

The source `.miz` is never modified. The build:

1. reads the eight modules and strips the `HTG:DEV-ONLY-BEGIN/END` blocks (the
   `loadfile` fallbacks), so the payload touches no filesystem at all;
2. wraps each module as a local, builds the `_G.HTG_PRELOADED` table and appends
   `main.lua` — one self-contained payload (~66 KiB);
3. gates that payload against `os.`, `io.`, `lfs.`, `require(`, `dofile(`,
   `loadfile(`, `loadstring(`, `MY_SCRIPTS_ROOT` and any surviving dev markers;
4. rewrites the mission file's MISSION START trigger into a single
   `a_do_script("<payload>")` action, in both the compiled form
   (`trig.actions` + `funcStartup`) and the editor-facing form (`trigrules`),
   matching the shape the mission editor itself writes;
5. re-zips to `out/helicopter-training.miz`, with `out/helicopter-training-build/`
   as a staging directory that mirrors the archive and
   `out/helicopter-training-build-artifacts/` holding the payload, the
   pre-rewrite mission copy, and the re-extraction used for verification.

Every build must pass all five checks before it is written out:

| Check | Proves |
|---|---|
| payload gate | the shipped code has no filesystem access |
| payload syntax | it parses under Lua 5.1 |
| mission-file verification (`tests/lua/verify-htg-mission-file.lua`) | the trigger text round-trips byte-for-byte through both escaping levels, the trigger is wired to run at mission start, and the mission's own content (6 helicopter groups, 2 client slots, theatre, weather) is intact |
| mission diff (`tests/test-htg-mission-diff.ps1`) | nothing outside the two trigger blocks changed — head, mission content and tail are byte-identical to the source |
| shipped payload behaviour (`tests/lua/run-helicopter-training-shipped.lua`) | the payload boots the range with `loadfile` disabled and scores a landing and a troop lift |

What none of that proves: that DCS itself loads the mission. That is the first
in-game check.

## Verification

```powershell
lua5.1 tests/lua/run-helicopter-training.lua        # 25 pure-logic tests
lua5.1 tests/lua/run-helicopter-training-sim.lua    # 18 exercise state-machine tests
pwsh -File build/pack-helicopter-training-miz.ps1   # build + the five shipping checks
lua5.1 tests/lua/check-globals.lua src/missions/helicopter-training/*.lua
stylua --check src/missions/helicopter-training/    # formatting
```

The simulation suite stubs the DCS API just far enough to load `main.lua` and
drive its 1 Hz loop against a scripted aircraft, so it proves the state machines
actually fire: a landing only counts after the 3 s hold, a 20 m hover over a pad
is not a landing, a load only scores when it reaches a pad, troops load with the
right mass per airframe and are delivered at the LZ, and the autorotation timer
runs from the gate to the pad. Mutating a threshold in `config.lua` (for
example `speed_max_ms = 3.0` to `300.0`, or `hold_seconds = 3` to `0`) makes the
relevant test fail — worth re-checking when adding tests, since a test that
passes on stale state is worse than no test.

`check-globals.lua` stands in for luacheck, whose `luafilesystem` dependency
does not build on this machine. It prints every global a file touches; compare
that list with `read_globals` in `.luacheckrc` — anything extra is a typo or a
missing declaration.

Nothing in the offline suite proves the range runs inside DCS. The first in-game
check is: load the mission, confirm the `[helicopter-training] site ...` lines
and `range ready` in `dcs.log`, and confirm the smoke and F10 marks appear.

## Inspecting a live range

`main.lua` exposes its internals at `_G.helicopter_training` (config, resolved
sites, progress, exercises, terrain, range, troops). With `dcs-fiddle` or
DCS-gRPC attached to a running mission:

```lua
_G.helicopter_training.progress:report(function(s) return tostring(s) end)
_G.helicopter_training.terrain:scan(_G.helicopter_training.config.base, _G.helicopter_training.config.probe)
_G.helicopter_training.exercises:reset_world()
```


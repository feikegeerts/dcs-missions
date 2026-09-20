# Mission loader (dev) — paste into the Mission Editor

The .miz is a **dumb loader** during development. It contains a single trigger
that calls `src/bootstrap.lua` on each mission start. The dispatcher reads
`.current-mission` to know which mission is active, then loads the framework and
that mission's `main.lua`. No repack, no editor trips for Lua changes, no
git branch per mission.

## File layout (repo side)

```
src/
  bootstrap.lua              # dispatcher — never mission-specific
  lib/Moose_.lua             # framework (one pinned build, shared)
  missions/
    <mission-name>/
      main.lua               # independent entry point
      config.lua             # mission identity, roster, gameplay overrides
  gameplay/
      package-waves.lua      # shared optional wave behavior
  lib/telemetry/             # shared telemetry integration
      ...
  .current-mission           # one line: the active mission's name
```

Each `.miz` in `Saved Games\...\Missions\` calls the same loader. Switching
missions = change `.current-mission` (one line) and restart.

## Steps (one-time per mission)

1. In the DCS Mission Editor, create the parts that are painful in code:
   - Map, date/time, weather, both coalitions
   - Player/client slots
   - **Template groups** for every SPAWN template — set **Late Activation** so the
     template itself never spawns. The group's **name** is what `SPAWN:New("name")` uses.
   - **Trigger zones** for spawn/kill zones (referenced by `ZONE:New("name")`).
2. Create exactly **one** trigger:

   ```
   TYPE:    MISSION START
   CONDITION: <none> — a conditioned MISSION START never fires
   ACTION:  DO SCRIPT   (paste the loader below)
   ```

3. Paste the loader (Windows backslashes inside `[[...]]`, exactly one line of
   meaningful code; the rest is just pcall for log clarity):

   ```lua
   local ok, err = pcall(function()
     assert(loadfile([[C:\Projects\dcs-missions\src\bootstrap.lua]]))()
   end)
   if not ok then env.error("[myMission] bootstrap: " .. tostring(err)) end
   ```

   The same trigger code is used by every .miz. The dispatcher
   (`src/bootstrap.lua`) reads `.current-mission` and loads the right mission.

4. Save the mission to the Saved Games folder for the channel you're testing on.
   Most development happens on the dedicated server:

   ```
   %USERPROFILE%\Saved Games\DCS.dcs_serverrelease\Missions\<name>.miz
   ```

   On stable that's `DCS.dcs_serverrelease`; on open beta it's
   `DCS.dcs_serveropenbeta`. Confirm the exact name with
   `Get-ChildItem $env:USERPROFILE\Saved Games -Directory`.

   Only drop the `.miz` in `Saved Games\DCS\Missions\` too if you're also testing
   on the SP client. The Lua source in `src\` is identical — only the ME
   artefacts (map, slots, triggers) need to be in the right folder.

5. On the dedicated server, add the mission via the WebGUI
   (`http://localhost:8088`) → mission list → Add.

The source `src/missions/` folder is part of the dev loop and is also consumed
by `build\pack-shipping-miz.ps1`; generated archive staging lives under `out/`.

You won't touch the editor again unless templates/zones/weather/client slots change.

## Adding a new mission

1. Create `src/missions/<name>/main.lua` (and any sibling files it loads).
2. Write `<name>` to `src/.current-mission` (one line, no quotes).
3. Create a new .miz in the ME for that mission (map, slots, AI, trigger), save
   it to `missions\<name>.miz`, copy into both Saved Games folders, add to
   server's mission list.
4. Switch to it: `src/.current-mission` = `<name>`, restart the mission.

The dispatcher, framework, and loader code are shared. Nothing in
`src/bootstrap.lua` or `src/lib/` needs to change.

## Daily loop

1. Edit `src\missions\<active>\*.lua` in VSCode, save.
2. Restart the mission:
   - SP: **LeftShift+R** (~2 s, fastest)
   - Dedicated server: WebGUI → **Restart** (`http://localhost:8088`)
3. Read `Saved Games\DCS\Logs\dcs.log` (client) or
   `Saved Games\DCS.dcs_serverrelease\Logs\dcs.log` (server) for
   `*** MOOSE INCLUDE END ***`, the `[bootstrap] ...` lines, and your own
   `[<mission-name>] ...` breadcrumbs.

## Switching missions (no restart of the server, no editor trip)

Edit `src/.current-mission` (one line, e.g. `duel-dynamic` → `<another-mission>`), save, restart
the running mission. The .miz file itself doesn't change. The trigger code
inside it doesn't change. Only the pointer file does.

## Shipping (static mode)

For a shipped mission that must work on a stock (sanitized) DCS, run the
repository packager from the project root:

```powershell
pwsh -File build\pack-shipping-miz.ps1 -MissionName duel-dynamic-bvr -Zip
pwsh -File build\pack-shipping-miz.ps1 -MissionName duel-dynamic-acm -Zip
pwsh -File build\pack-shipping-miz.ps1 -MissionName air-superiority-survival -Zip
```

The packager rewrites the Mission Start trigger, embeds MOOSE and the selected
entry/config plus shared gameplay and telemetry as resource-backed `DO SCRIPT
FILE` payloads, adds the native Survival terminal trigger, and rejects stock-
incompatible filesystem APIs. See `docs/shipping-duel-dynamic.md` for the
validation and live-acceptance checklist. Shipping missions do not read
`.current-mission` and do not require a de-sanitized `MissionScripting.lua`.

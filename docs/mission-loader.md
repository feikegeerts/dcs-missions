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
      main.lua               # entry point for that mission
      score.lua              # any sibling files (load via _G.MY_SCRIPTS_ROOT)
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

The project's `missions/` folder is **not part of the dev loop** — it's only
read by `build\pack-miz.ps1` when building a shippable `.miz`. Leave it alone
during dev.

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

For a shipped mission that must work on a stock (sanitized) DCS:

1. Disable all `:TraceOn()` calls.
2. Switch the trigger to multiple `DO SCRIPT FILE` entries — order matters:
   - `lib\Moose_.lua`
   - `bootstrap.lua` (modified to not read from disk — chains in-memory)
   - `missions\<name>\main.lua` (and its siblings)
3. Or, extend `build\pack-miz.ps1` to assemble the .miz with embedded scripts.
   (Current `pack-miz.ps1` only re-zips an existing unpacked tree — it does
   not yet rewrite the trigger or embed scripts. Dev .mizs require the
   de-sanitized env, see `docs/dev-setup.md §2`.)
4. The shipped .miz must not depend on `lfs`/`io`/`os` — its only
   file-system interaction is `loadfile()` from within the .miz itself,
   which doesn't need the unsanitized env.

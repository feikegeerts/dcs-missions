# Mission spec: duel-1v1 — **SUPERSEDED**

> **This spec describes the original 1-vs-1 test mission. It is
> superseded by `duel-dynamic` (see `spec-duel-dynamic.md`).**
>
> The code in `src/missions/duel-1v1/` is in an **incomplete, broken
> state** — duplicate top-level blocks from a half-finished edit. Do
> not switch `src/.current-mission` to `duel-1v1` without first
> cleaning it up. The mission was kept in the repo for reference
> while `duel-dynamic` was developed; see `PROJECT-STATUS.md §6.2`
> for the cleanup decision.
>
> Everything below this line is the **original** spec, kept for
> historical context. Don't follow it.

---

## Original spec

Test mission for the dev loop. Goal: prove the bootstrap → MOOSE → F10 menu → event pipeline
works end-to-end with a single flyable mission. **1 player (blue) vs 1 AI bandit (red)**, no
respawn, no spawning logic.

**Code (already in repo, dispatched by `src/bootstrap.lua`):**
- `src/bootstrap.lua` — dispatcher (reads `.current-mission`, loads Moose + mission main)
- `src/missions/duel-1v1/main.lua` — F10 menu (Show kills / Reset kills) + dead-event handler
- `src/missions/duel-1v1/score.lua` — pure-logic kill counter (`_G.duel_tracker`)
- `src/.current-mission` — contains the string `duel-1v1` (set to `duel-dynamic` now)

**Other missions you add later** live in `src/missions/<name>/` as their own subfolders. To
work on a different one, change `.current-mission` to its name and restart. No editor, no
git branch, no repack.

---

## 1. Open the editor, create a new mission

**File → New mission.** Pick:
- **Map:** Caucasus (small, fast load, ships with DCS)
- **Date / time:** any daytime, default 12:00 — clearer for a first test
- **Weather:** clear, scattered clouds (visibility > 9 km)

Coalition side: keep both Blue and Red active (default).

---

## 2. Pick your aircraft

Use whatever jets you own. If you want a freebie-friendly combo:

| Side | Aircraft | Type | Notes |
|---|---|---|---|
| Blue (player) | **L-39ZA** | trainer/light jet | Free with DCS, no module needed |
| Red (AI) | **Su-25T** | attack jet | Free with DCS |

Or any other common pair: F-16C vs Su-27, F-15C vs MiG-29, etc. — the Lua doesn't care.

---

## 3. Place the player slot

1. **Blue coalition → Add new group → Aircraft → [your pick]**
2. Set **Skill:** Player
3. Set **Country:** USA (or anything in Blue)
4. On the **Advanced** tab:
   - **Player slot** ✓ (so you can take the slot in MP/editor preview)
   - **Uncontrolled** ✗
5. Place the aircraft **airborne** at roughly:
   - Altitude: **15 000 ft**
   - Speed: ~300 kts
   - Heading: 360° (north)
   - Position: somewhere over western Georgia, e.g. near Sukhumi (`lat ~42.85, lon ~41.10`)
6. Give it a single waypoint ~50 NM north of the spawn (the AI will be flying roughly south toward you).

---

## 4. Place the AI bandit (SPAWN template)

1. **Red coalition → Add new group → Aircraft → [your pick]**
2. Set **Skill:** Average (or Good if you want a fight)
3. Set **Country:** Russia (or any Red country)
4. **Do NOT mark it as a player slot.**
5. On the **Advanced** tab, tick **Late Activation** ✓ — this makes the group a SPAWN
   template. The bandit won't appear at mission start; the Lua's `SPAWN:New("Bandit-1")`
   controls when it spawns. The respawn on kill is wired manually in
   `src/missions/duel-1v1/main.lua` (the `kill handler` block fires
   `BanditSpawner:Spawn()` after the first Dead/Crash event per group), since
   MOOSE's `InitRepeat` only triggers on landing / engine shutdown, not on
   destruction.
6. Place it **airborne**, ~30 NM north of the player, similar altitude and opposite heading:
   - Altitude: **15 000 ft**
   - Speed: ~300 kts
   - Heading: 180° (south, toward the player)
   - Position: ~50 km north of the player spawn
7. Give it one waypoint roughly **over the player** (so it flies into a head-on merge).
8. **Important — name the group exactly `Bandit-1`.** Must match `SPAWN:New("Bandit-1")`
   exactly (case-sensitive); a typo means the spawn silently fails.

---

## 5. Add the one and only trigger

**Triggers → Add**

| Field | Value |
|---|---|
| **Type** | `MISSION START` |
| **Condition** | `<none>` (a conditioned MISSION START never fires — leave the condition list empty) |
| **Action** | `DO SCRIPT` (NOT `DO SCRIPT FILE` — that's the static-mode variant) |

In the script box, paste exactly:

```lua
local ok, err = pcall(function()
  assert(loadfile([[C:\Projects\dcs-missions\src\bootstrap.lua]]))()
end)
if not ok then env.error("[myMission] bootstrap: " .. tostring(err)) end
```

`bootstrap.lua` reads `.current-mission`, loads MOOSE, then loads
`missions/duel-1v1/main.lua` — which in turn loads its sibling `score.lua`. The same
trigger code works for every mission; only `.current-mission` changes.

---

## 6. Save and place the .miz

1. **File → Save As** → name it `duel-1v1.miz`
2. **Server-only for now** (skip the SP folder until you actually need it):
   `%USERPROFILE%\Saved Games\DCS.dcs_serverrelease\Missions\duel-1v1.miz`
3. On the server, add it via WebGUI (`http://localhost:8088`) → mission list → Add.

When you eventually want SP testing too, add the same `.miz` to
`%USERPROFILE%\Saved Games\DCS\Missions\duel-1v1.miz`. (For the project `missions/`
folder: only used by `build\pack-miz.ps1` when shipping — not needed for dev.)

---

## 7. Run it

- **SP:** start the mission from the ME, or pick `duel-1v1` in the game's mission list.
- **Server:** start from the WebGUI (no console, no `loadmission` — the WebGUI button is the
  one true way).

The mission start trigger fires; the loader reads `src\*.lua` from disk; MOOSE loads; the
F10 menu appears.

---

## 8. What success looks like

In `Saved Games\DCS\Logs\dcs.log` (or `Saved Games\DCS.dcs_serverrelease\Logs\dcs.log` for
the dedicated server) you should see **all** of these, in order:

```
SCRIPTING: *** MOOSE INCLUDE END ***
[bootstrap] start
[bootstrap] root: C:\Projects\dcs-missions\src\
[bootstrap] mission: duel-1v1
[bootstrap] loading lib/Moose_.lua
[bootstrap] loading missions/duel-1v1/main.lua
[duel-1v1] score module loaded
[duel-1v1] main start
[duel-1v1] MOOSE loaded
[duel-1v1] bandit spawned: Bandit-1#001
[duel-1v1] main done
[bootstrap] done
```

Then in the mission:
- F10 → Other → "Duel 1v1" → **Show kills** prints `Kills: 0` (or current count)
- Take off, engage the bandit, shoot it down
- On kill: `Player down! Kills: 1` flashes 8 s on the blue side
- F10 → Reset kills clears the counter

If any step is missing, the first `SCRIPTING ERROR` line in dcs.log names `file:line` —
that's the bootstrap aborting. See `docs/dev-setup.md §7` and `§10` (troubleshooting
table).

---

## 9. Iterate

You will not touch the editor again unless aircraft, spawn positions, or weather change.
Lua-only changes: edit `src\missions\duel-1v1\*.lua` in VSCode, restart the mission
(`LeftShift+R` in SP, **Restart** in WebGUI on the server). No repack. No copy. That's
the dev loop.

To switch to a different mission, set `src/.current-mission` to its name and restart.
The .miz's trigger code never changes.

When you're ready to ship, see `docs/dev-setup.md §8` and
`build\pack-miz.ps1 -MissionName duel-1v1`. (Static-mode packaging — embedded scripts so
the shipped .miz runs on stock DCS — needs more work; the dev loader requires the
de-sanitized env, see `docs/dev-setup.md §2`.)

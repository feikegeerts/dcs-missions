# Shipping `duel-dynamic` — packaging checklist

The dev `.miz` is a **dumb loader** that does `loadfile` on
`C:\Projects\dcs-missions\src\bootstrap.lua`. This **requires** both:
1. A de-sanitized `MissionScripting.lua` (`os`/`io`/`lfs` un-nilled).
2. The absolute project path `C:\Projects\dcs-missions\src\` to exist.

A downloaded `.miz` from a user forum or a friend has neither. To ship,
the mission must be **self-contained** and run on a stock, sanitized DCS
install.

This doc covers the steps. Until done, the dev `.miz` is the only way
to run `duel-dynamic`.

---

## High-level approach

Two equivalent ways to make a self-contained `.miz`:

1. **`DO SCRIPT FILE` triggers** — multiple triggers, each
   `DO SCRIPT FILE <relative path>` to a file *inside* the `.miz`
   (in `Scripts/` or at the root). DCS runs them in order on
   MISSION START. Files live inside the .miz, so no `lfs`/`io`/`os`
   needed.
2. **One big `DO SCRIPT`** — concatenate the Lua sources into one
   string and paste it into a single trigger. Same effect, just
   harder to maintain.

Option 1 is the canonical DCS pattern and the one to use here. Steps
below assume it.

---

## Step-by-step

### 1. Build a self-contained source tree

In a clean directory (e.g. `out\duel-dynamic-build\`), assemble:

```
Scripts/
  Moose_.lua            # from src/lib/Moose_.lua (the comment-stripped build)
  main.lua              # from src/missions/duel-dynamic/main.lua, with edits:
                        #   - remove all :TraceOn() / BASE:TraceOn()
                        #   - replace assert(loadfile(...)) with assert(loadfile([[.\Scripts\main.lua]]))()
                        #     OR delete bootstrap.lua and inline the dispatcher here
  score.lua             # from src/missions/duel-dynamic/score.lua
  bootstrap.lua         # (optional) the dispatcher, modified to load from
                        # relative paths instead of the hardcoded C:\... path
```

The dispatcher needs adapting — its `resolveRoot()` falls back to the
hardcoded `C:\Projects\dcs-missions\src\`. For shipping:

```lua
-- In the shipped bootstrap.lua, replace resolveRoot() with:
local function resolveRoot()
  -- All scripts live in Scripts/ inside the .miz; use current working
  -- dir or a known relative path. dcs.scriptdir is set by DCS to the
  -- mission's directory at load time in some builds, but the safest
  -- is to do everything via dofile with relative paths and not call
  -- io.open at all.
  return ""
end
```

The trick: don't `io.open(.current-mission)` in shipping. Instead,
hardcode the active mission name into `bootstrap.lua` (or a sibling
config) at build time. Example:

```lua
-- bootstrap.lua (shipping)
local MISSION_NAME = "duel-dynamic"   -- baked in at build time

local ROOT = ""  -- all paths relative to mission root
local function loadRel(rel)
  local path = ROOT .. rel
  local ok, err = pcall(function()
    assert(loadfile(path))()
  end)
  if not ok then env.error("[bootstrap] " .. rel .. ": " .. tostring(err)) end
  return ok
end

if not loadRel("Scripts/Moose_.lua") then return end
if not loadRel("Scripts/main.lua") then return end
```

(You'll need to test the actual relative path; DCS sometimes prefixes
it with a backslash. `.\Scripts\main.lua` may also work.)

### 2. Add the triggers in the Mission Editor

In `duel-dynamic.miz`, replace the single dev `DO SCRIPT` trigger with
**four** MISSION START triggers, **no conditions**, in this order:

| # | Action | Path |
|---|---|---|
| 1 | `DO SCRIPT FILE` | `Scripts/Moose_.lua` |
| 2 | `DO SCRIPT FILE` | `Scripts/bootstrap.lua` |
| 3 | `DO SCRIPT FILE` | `Scripts/main.lua` (or whatever your mission entry is) |
| 4 | `DO SCRIPT FILE` | `Scripts/score.lua` (only if main.lua doesn't dofile it itself; ours does, so skip) |

> `DO SCRIPT FILE` resolves relative to the mission's directory inside
> the `.miz`. So `Scripts/Moose_.lua` means
> `<miz-root>/Scripts/Moose_.lua`. Drop the files into the right
> places via 7-Zip or by editing the unpacked `.miz` tree.

### 3. Strip everything dev-only

Grep the source for and remove:

- `:TraceOn()` / `:TraceLevel(N)` / `BASE:TraceOn()` calls
- `env.info` lines that are dev breadcrumbs (keep error/warn ones)
- Any `io.open`, `lfs.*`, `os.*` calls — these won't work on a
  sanitized install. **None** of the current `duel-dynamic` source
  uses them in shipping code paths (the only `os.time` is in the RNG
  seed; if shipping needs a real random seed, the LCG can be
  re-seeded from `timer.getTime()`).

### 4. Build the `.miz`

`build\pack-miz.ps1` only re-zips an existing tree; it doesn't
embed scripts. Two options:

- **Manual:** create the `.miz` structure in `missions\duel-dynamic\`
  with the standard `mission` / `options` / `warehouses` / `l10n\`
  entries (copy from the dev .miz) plus the `Scripts/` directory
  holding the shipping source. Run
  `pwsh -File build\pack-miz.ps1 -MissionName duel-dynamic`.

- **Automated:** write a `build\pack-shipping-miz.ps1` that copies
  the dev `.miz` → strips the dev `DO SCRIPT` trigger → adds the four
  shipping triggers → embeds `Scripts/*` → re-zips. Not done yet.

### 5. Verify on a stock DCS

This is the real test. Without this, you don't know if it works.

1. **Restore** `MissionScripting.lua` (or use a fresh DCS install in
   a different folder). Confirm `os`/`io`/`lfs` are nilled.
2. Drop the shipping `.miz` into a stock `Saved Games\DCS\Missions\`
   (or the dedicated server's `Saved Games\DCS.server\Missions\`).
3. Start the mission from the editor (or via WebGUI on the server).
4. Watch `dcs.log`:
   - Should NOT see any `os`/`io`/`lfs` "attempt to index nil" errors.
   - Should see `*** MOOSE INCLUDE END ***` followed by
     `[bootstrap] ...` and `[duel-dynamic] ...` breadcrumbs.
   - Bandit should spawn, F10 menu should work.
5. Spawn 2-3 player slots, fly a few rounds, confirm kill and death
   cycles still work.
6. Tacview-check: bandits engage player, no AI wandering.

### 6. Update the docs

After the shipping build is verified:

- Update `docs/dev-setup.md §8` to describe the now-working shipping
  process (remove the "not implemented yet" note).
- Update `docs/PROJECT-STATUS.md §6.3` to check off the box.
- Add a short note at the top of `docs/spec-duel-dynamic.md`
  ("Shipping status: dev only" or "Shipping status: built, see …").

---

## Edge cases & gotchas

### `loadfile` and relative paths

`loadfile` with a relative path resolves against the current working
directory of the DCS process, which is the DCS install directory —
*not* the mission directory. `loadfile([[Scripts\main.lua]])` will
fail. Workarounds:

- Use `DO SCRIPT FILE` triggers (DCS handles the path resolution).
- Use the `lfs` module to find the mission dir — but `lfs` is nilled
  in stock DCS, so this requires a sanitized env. **Don't do this
  for shipping.**

### `loadfile` from inside `MOOSE`

MOOSE itself doesn't `loadfile` anything, so the framework is safe
to embed. If you add packages that do (`require`-style), they need
to be self-contained too.

### `setPosition` on a player slot

Already a known limitation (see `spec-duel-dynamic.md §6.1`). The
shipping build has the same behaviour as the dev build.

### MIST integration

If you add MIST for true random player respawns (see
`PROJECT-STATUS.md §6.1`), `mist.lua` needs to ship in the `.miz`
too. It's standalone Lua and runs in sanitized DCS (it doesn't use
`os`/`io`/`lfs` — it uses MOOSE wrappers around DCS API).

### MOOSE version pin

The dev build uses `src/lib/Moose_.lua` which is pinned. The shipping
build embeds the *same* file. If you upgrade MOOSE later, rebuild the
shipping `.miz` too — don't ship a `.miz` with a stale MOOSE.

---

## Quick summary (TL;DR)

1. Create `Scripts/` inside the `.miz` with `Moose_.lua`,
   `main.lua`, `score.lua`, and a shipping-only `bootstrap.lua`
   that doesn't read `.current-mission`.
2. Replace the dev `DO SCRIPT` trigger with four `DO SCRIPT FILE`
   triggers in the order Moose → bootstrap → main → score.
3. Strip all `:TraceOn()` and any `os`/`io`/`lfs` calls from the
   shipping sources.
4. Re-zip as `out/duel-dynamic.miz`.
5. Verify on a **stock, sanitized** DCS install before distributing.

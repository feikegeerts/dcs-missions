# Shipping `duel-dynamic` — packaging checklist

The dev `.miz` is a **dumb loader** that does `loadfile` on
`C:\Projects\dcs-missions\src\bootstrap.lua`. This **requires** both:
1. A de-sanitized `MissionScripting.lua` (`os`/`io`/`lfs` un-nilled).
2. The absolute project path `C:\Projects\dcs-missions\src\` to exist.

A downloaded `.miz` from a user forum or a friend has neither. To ship,
the mission must be **self-contained** and run on a stock, sanitized DCS
install.

This doc covers the steps. The mission-only self-contained build was verified
on the stock, sanitized dedicated server on 2026-09-02. The newly packaged
production telemetry bridge still requires the owner-gated S17-p4 live test;
the dev `.miz` remains the normal hot-reload workflow.

---

## High-level approach

Two equivalent ways to make a self-contained `.miz`:

1. **`DO SCRIPT FILE` triggers** — multiple actions, each referencing a DCS
   resource key registered by `l10n/DEFAULT/mapResource`. Payload files live
   under `l10n/DEFAULT/`. DCS runs them in order on MISSION START, with no
   `lfs`/`io`/`os` needed.
2. **One big `DO SCRIPT`** — concatenate the Lua sources into one
   string and paste it into a single trigger. Same effect, just
   harder to maintain.

Option 1 is the canonical DCS pattern and the one used here.
Implementation lives in `build/pack-shipping-miz.ps1`.

---

## Step-by-step

All steps are automated in `build/pack-shipping-miz.ps1`. To build a
shipping `.miz`:

```powershell
powershell -File build\pack-shipping-miz.ps1 -Zip
```

What the packager does:

1. **Extracts the dev `.miz`** into `out/duel-dynamic-build/` (a
   persistent staging directory, wiped on each run). The dev `.miz`
   is at `$env:USERPROFILE\Saved Games\DCS.dcs_serverrelease\Missions\duel-dynamic.miz`
   by default; override with `-DevMizPath`.

2. **Rewrites the MISSION START trigger in four places** in the
   `mission` file:
   - The **trigrules** (modern) block's `triggerStart` entry: the
     single `a_do_script` action is replaced with two
     `a_do_script_file` actions, pointed at the MOOSE and main resource keys.
     The match is a regex
     `(?s)\[1\]\s*=\s*\{\s*\["text"\]\s*=\s*"..."\s*,\s*\["predicate"\]\s*=\s*"a_do_script",?\s*\}\s*,\s*-- end of \[1\]`
     — the Lua-string pattern `"(?:[^"\\]|\\.)*"` handles the escaped
     quotes in the dev's `loadfile` string.
   - The **trig** (legacy) block's `actions[1]`: the dev's
     `a_do_script("...");` string literal is replaced with two
      `a_do_script_file(getValueResourceByKey(...))` strings. The match is anchored on the
     unique suffix `end\");",` (the close of the dev's loadfile
     call).
   - The **trig.flag** block: a single `[1] = true` becomes
     `[1] = true, [2] = true,` so both actions are enabled.
   - The **trig.funcStartup** block: its legacy startup callback is extended
     to invoke both actions rather than only action 1.

3. **Registers resources** in `l10n/DEFAULT/mapResource` for `Moose_.lua`
   and `main.lua`. Literal archive paths are not valid DO SCRIPT FILE resource
   references and are silently ignored by stock DCS.

4. **Synthesizes `l10n/DEFAULT/main.lua`** from `src/missions/duel-dynamic/main.lua`:
   - Inlines `src/missions/duel-dynamic/score.lua` at the top.
   - Strips the dev-only `MY_SCRIPTS_ROOT` lookup, the complete
     `initDevelopmentTelemetry` function and call, and the development
     `dofile(DIR .. "score.lua")` line. These are exact, anchored,
     fail-loud rewrites rather than optional substitutions.
   - Inlines the 11 pure telemetry modules (`event_id`, `envelope`, `json`,
     `lifecycle`, `bridge`, `bridge_frame`, `bridge_queue`, `asset`, `shot`,
     `combat`, and `participant`) as IIFE locals before the mission body. It
     keeps `initShippingTelemetry`, rewrites each of its 11 `dofile` lines to
     the corresponding inlined local, and injects
     `_G.TELEMETRY_SHIPPING_ENABLED = true` immediately before the shipping
     init call. The bridge uses historical run classification and an in-memory
     queue; it performs no mission-side file writes.
   - Replaces `os.time()` (nilled in stock DCS) with
     `math.floor(timer.getTime() * 1000)` for the LCG seed.
   - Adds a `main.lua — SHIPPING BUILD` header explaining
     the diff.
   - Refuses to build if any `TraceOn`, `TraceLevel`, `os.*`, `io.open`,
     `lfs.*`, `TEST_COMBAT`, `dofile(`, `require(`, `loadfile(`, or
     `loadstring(` reference is found in a non-comment line anywhere in the
     full synthesized artifact.
   - Runs a compile-only `lua5.1` syntax gate on the staged artifact. It uses
     `loadfile` only from the external check process and never executes the
     DCS-dependent chunk.

5. **Copies `l10n/DEFAULT/Moose_.lua`** from `src/lib/Moose_.lua`.

6. **Re-zips** `out/duel-dynamic-build/` into `out/duel-dynamic.miz`
   (only if `-Zip` is passed; otherwise the staging dir is left
   intact for inspection). The packager creates every ZIP member with `/`
   separators and fails if the archive contains a Windows-style `\` member or
   lacks either script resource. DCS silently fails to resolve resource members
   stored as `l10n\DEFAULT\...`.

Do not re-zip the staging tree with `Compress-Archive` or
`.NET ZipFile.CreateFromDirectory()` on Windows. Both can produce backslash
member names that are valid ZIP but unusable for DCS resources. Make changes in
`src/` and re-run the packager with `-Zip`.

### Production telemetry hook

The shipping mission does not need the hook to run. Without it, telemetry
events remain in the bounded mission-memory queue and no spool file appears.
The production GameGUI hook is what handshakes with the bridge and makes those
events durable and deliverable.

Copy the repository hook:

```text
hooks/duel-dynamic-telemetry.lua
```

to:

```text
C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Scripts\Hooks\duel-dynamic-telemetry.lua
```

No numeric filename prefix is needed. It must coexist with the existing
`TacviewGameGUI.lua`; never replace or modify Tacview's hook.

The hook creates these paths from its own unsanitized GameGUI state:

```text
<writedir>\Logs\telemetry\<run_key>.ndjson
<writedir>\Logs\telemetry-bridge\producer-id
```

The producer ID is persisted and reused across restarts. The spool layout is
the same layout used by the development sink, so existing collector ingest
works unchanged. All file I/O belongs to the hook state, not the sanitized
mission state.

### Verifying on a stock DCS

This is the owner-gated S17-p4 test and is not run by the automated packaging
loop. Without it, shipping telemetry has not been proven in the live DCS
runtime.

**Important live-test distinction:** starting the dedicated server by itself is
enough to validate the stock shipping load, bridge handshake, lifecycle events,
hook spool, and collector capture, but it does **not** exercise the mission's
AI package behavior. The mission intentionally waits for an occupied
`Aerial-1`–`Aerial-4` client slot before `init done` and bandit-wave spawning.
For the full S17-p4 mission gate, a DCS client must connect to the local server
and occupy at least one `Aerial-*` slot. Do not enable `TEST_COMBAT` or alter
the shipping artifact to bypass this gate; that would test the development path
instead of the shipped mission.

1. Keep the dedicated server's install-level `MissionScripting.lua` **stock**.
   Do not add an `autoexec.cfg` unsafe-API exception. Confirm mission-state
   `os`/`io`/`lfs` remain nilled.
2. Install `hooks/duel-dynamic-telemetry.lua` as described above, alongside
   `TacviewGameGUI.lua`.
3. Test the shipping `.miz` from a stock profile. On this machine the active
   dedicated-server profile is `Saved Games\DCS.dcs_serverrelease`. Preserve
   the small development loader before replacing or renaming anything.
4. Start the mission via WebGUI (or from the editor on SP), then connect a DCS
   client to the local server at `127.0.0.1:10308` and occupy one or more
   `Aerial-*` slots. Wait for the mission's `init done` and package-spawn log
   lines before checking AI behavior.
5. Watch `Saved Games\DCS.dcs_serverrelease\Logs\dcs.log`:
   - Should NOT see any `os`/`io`/`lfs` "attempt to index nil" errors.
   - Should see `*** MOOSE INCLUDE END ***` followed by
     `[duel-dynamic] shipping build start`, `[duel-dynamic] MOOSE loaded`,
     and `[duel-dynamic] init done` (once a player joins).
   - Should show one `TELEMETRY_BRIDGE_HOOK START`, a
     `TELEMETRY_BRIDGE_HOOK LOAD callback-api=Sim` (or `DCS`),
     `handshake-ok` for the loaded mission, one or more monotonic `drained`
     ranges, and a clean `STOP` summary.
   - Must not show a `TELEMETRY_BRIDGE_HOOK` `fatal`,
     `transport-unavailable`, `frame-stuck`, `spool-verify-failed`, or callback
     `hook-error`.
   - One package-sized bandit group should spawn and the F10 menu should work.
6. Spawn 2–4 player slots. Confirm one close, equally sized red group appears, a
   partial red loss does not respawn, and one complete replacement appears 30
   seconds after the final red loss.
7. Tacview-check: red aircraft remain a package and engage the blue package;
   no split-map spawns or AI wandering.
8. Verify the resulting NDJSON with the existing collector ingest. Record only
   operational checks in log evidence; do not expose event payloads.

The dev `.miz` is NEVER overwritten. To re-enter dev mode, restore
the de-sanitized `MissionScripting.lua` and continue editing `src/`.

### 6. Update the docs

After future shipping-build behavior changes are verified:

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
*not* the mission directory. `loadfile([[main.lua]])` will fail inside the
embedded `main.lua`. That's why the shipping build uses resource-key-backed
`DO SCRIPT FILE` triggers (DCS handles extraction and path resolution) and
inlines `score.lua` into `main.lua` instead of `dofile`-ing it.

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

### Re-running the packager

The dev `.miz` is NEVER modified. The packager extracts it into
`out/duel-dynamic-build/`, which is wiped at the start of each run.
Re-running the packager always produces a fresh, consistent shipping
artifact. If you edit `src/` (e.g., tweak `main.lua`), re-run
`build/pack-shipping-miz.ps1` to pick up the changes.

### Editing the staged build

If `-Zip` is NOT passed, `out/duel-dynamic-build/` is left in place
after the packager runs for inspection. Make durable changes in `src/`; the next
packager run wipes the staging tree. Do not manually re-zip it with Windows ZIP
helpers because they can reintroduce invalid backslash resource member names.

---

## Quick summary (TL;DR)

1. `powershell -File build\pack-shipping-miz.ps1 -Zip` (run from the
   project root) — produces `out/duel-dynamic.miz` and
   `out/duel-dynamic-build/` (the staging tree).
2. The dev `.miz` and `src/` are NEVER modified.
3. The shipping mission artifact is self-contained: no `os`/`io`/`lfs`
   dependencies, module loaders, absolute paths, or dev dispatcher. Its pure
   telemetry stack queues in memory; all durable file I/O is performed by the
   separately installed GameGUI hook in unsanitized hook state.
4. **Verify on a stock, sanitized DCS install before distributing.**
   See "Verifying on a stock DCS" above.

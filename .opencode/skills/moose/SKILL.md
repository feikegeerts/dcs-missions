---
name: moose
description: Use when writing, reviewing, or debugging DCS World mission scripts with the MOOSE framework (Lua). Covers SPAWN, ZONE, SET_GROUP, AUFTRAG/FlightGroup OPS classes, event handling, F10 menus, timers, scoring, spawn/wave logic, and MOOSE-vs-vanilla-DCS decisions. Triggers on MOOSE class names, .miz mission scripting, or Moose.lua.
metadata:
  project: dcs-missions
---

# MOOSE Mission Scripting

Expert guidance for writing DCS World mission scripts with the MOOSE framework. This project uses **Lua 5.1.5** (DCS embedded), the **MOOSE stable branch (`master-ng`)**, and a disk hot-reload dev loop (see `CLAUDE.md`).

## Ground rules (this project's conventions)

1. **OPS over legacy.** Use `Ops.*` classes (`AUFTRAG`, `FlightGroup`, `ArmyGroup`, `EasyGCICAP`, `EasyAG`, `OpsZone`...) for AI tasking. The old `AI_*`, Tasking and Cargo classes are archived in MOOSE stable — never write new code with them. If a solution on the internet uses `AI_A2A_Dispatcher` etc., translate it to the OPS equivalent.
2. **Don't fight MOOSE.** If MOOSE has a class for it, use it. Raw `trigger.action.*` / `coalition.addGroup` calls in MOOSE code are a smell. Exceptions: things MOOSE genuinely doesn't cover — then isolate vanilla API calls in a small helper module.
3. **Lua 5.1 only.** No `string.pack`, no `goto`, no `//`, no `table.unpack` (use `unpack`). See `references/gotchas.md`.
4. **Log, don't crash.** `env.info()` for breadcrumbs, MOOSE `:I()`/`:E()` on class instances. An uncaught error inside a scheduled/timer function silently kills that schedule in DCS.
5. **Verify against real docs before inventing signatures.** Class page URL pattern: `https://flightcontrol-master.github.io/MOOSE_DOCS/Documentation/<Module>.<Class>.html` (e.g. `.../Core.Spawn.html`). If a class 404s there, it may be develop-only — check `MOOSE_DOCS_DEVELOP`. Never guess parameter order for anything beyond the canonical patterns in `references/patterns.md`; fetch the class page.

## Workflow

1. **Pick the class** from `references/class-map.md` (condensed from the official index).
2. **Confirm the API** on the class doc page if you use anything beyond the patterns file.
3. **Write the code** following `references/patterns.md` conventions (constructor style, `:OnEvent*` handlers, `TIMER`/`SCHEDULER`, menus).
4. **Debug**: enable `BASE:TraceOn()`/`:TraceLevel(2)` on the involved classes while testing (off by default in static builds — remember to remove). Check `Saved Games\DCS.server\Logs\dcs.log` for `SCRIPTING` ERROR/WARNING lines and the `*** MOOSE INCLUDE END ***` sentinel.

## Reference files

- `references/class-map.md` — every MOOSE class by category with a one-line purpose; start here to find the right tool.
- `references/patterns.md` — verified canonical code patterns: spawning (incl. waves/limits), zones, sets, events, timers, menus, AUFTRAG/FlightGroup, messaging, scoring.
- `references/gotchas.md` — DCS Lua 5.1 quirks, MOOSE pitfalls (templates, tracing, event data, scheduled-function error swallowing), coalition IDs, coordinate system.

## Authoritative sources (in order of trust)

1. MOOSE source + LDoc docs: `https://flightcontrol-master.github.io/MOOSE_DOCS/Documentation/index.html`
2. Example missions: `github.com/FlightControl-Master/MOOSE_MISSIONS_UNPACKED` and `MOOSE_Demos` — canonical real usage, better than written guides.
3. `Moose_.lua` on disk (if present in the project) — grep it for exact signatures.
4. Hoggit wiki (`https://wiki.hoggitworld.com`) for the underlying DCS API.
5. MOOSE Discord `https://discord.gg/gj68fm969S` for anything ambiguous.

Note: much of the written guide material on the MOOSE site is **archived** and describes legacy APIs — prefer class docs and demo missions over narrative guides.

# DCS + MOOSE Gotchas

## Lua environment (5.1.5)

- No `string.pack`/`string.unpack`, no `goto`, no integer division `//`, no bitwise ops, no `table.unpack` — use global `unpack`.
- `newproxy()` exists (MOOSE uses it).
- `#t` on tables with nil holes is undefined — track counts explicitly in your own tables.
- `os`/`io`/`lfs`/`require`/`package` are **nil** in stock DCS (sanitized by `Scripts\MissionScripting.lua`). Dev loop assumes de-sanitized env (see `CLAUDE.md`); shipped missions must not.
- `dofile` is NOT sanitized — hot-reload bootstrap works even without require.

## DCS API

- `coalition.side`: **0 neutral, 1 red, 2 blue**. Mixing these up silently breaks everything.
- DCS Vec3: `x` = north, `y` = altitude (up), `z` = east. Most MOOSE code should use `COORDINATE` instead of raw Vec3 math.
- `timer.scheduleFunction(fn, arg, modelTime)`: return next model time to reschedule, `nil` to stop. **Errors inside scheduled functions are trapped and silently kill the schedule** — same for MOOSE `TIMER` callbacks. Prefer pcall + `env.info` in non-trivial callbacks while developing.
- `timer.getTime()` = mission time (s), `timer.getAbsTime()` = time of day, `timer.getTime0()` = mission start.
- `env.info`/`env.warning`/`env.error` always write to `dcs.log`; there is no verbosity switch to discover.
- The `net` singleton is environment-dependent: mission env (chat/kick/slots) vs server env (`net.load_mission`, `net.dostring_in`). Server-only functions don't exist in mission scripts.
- Spawned units are permanently gone when destroyed — respawn via SPAWN, not bookkeeping of dead objects.
- Event "initiator" objects in DCS events can be nil or already-dead — always nil-check `EventData.IniUnit`/`IniGroup` and prefer wrapper `IsAlive()` checks.

## MOOSE specifics

- **Load order**: `Moose_.lua` in a `MISSION START` trigger with **no conditions** (a conditioned MISSION START never fires), before any mission script.
- **Templates**: `SPAWN:New("name")` needs a ME group with exactly that name (recommend Late Activation so the template never flies). Typo'd template names fail at spawn time, not load time.
- **Aliases**: spawned group names get a `#NNN` suffix (`"Bandit-Alpha#001"`). `string.match(name, "^Bandit%-Alpha")` style prefix matching, never equality.
- **Static builds have tracing OFF by default** — `BASE:TraceOn()` works but remember to strip it for production; tracing also enables `BASE.Debug` overhead.
- **EventData uses Ini* prefix**: `IniUnit`, `IniGroup`, `IniUnitName`, `IniPlayerName`, `IniCoalition`, `TgtUnit`, `Weapon`. These are MOOSE **wrapper objects** (UNIT/GROUP), not raw DCS objects.
- **`_SETTINGS`** global: MOOSE auto-adds player settings F10 menus; `_SETTINGS:SetPlayerMenuOff()` to suppress; defaults like `_SETTINGS:SetA2G_MGRS()`, `:SetMetric()`, `:SetEraModern()`.
- **`_DATABASE`** global holds every registered object — useful for lookups (`_DATABASE:FindGroup(name)`), but prefer typed finders (`GROUP:FindByName`).
- **FSM callbacks**: `:OnAfterX(from, event, to, ...)` / `:OnBeforeX` / `:OnEnterX` — return `false` from `OnBefore` to veto. Misspelled callback names silently never fire.
- **Schedulers**: `TIMER` for plain functions; class methods wanting per-object scheduling inherit `:ScheduleOnce()`/`:ScheduleRepeat()` from BASE.
- **Develop vs stable docs**: a class page 404 on `MOOSE_DOCS` usually means develop-only → check `MOOSE_DOCS_DEVELOP`. Don't copy demo-mission code using classes your pinned `Moose_.lua` doesn't contain — grep the include file to confirm.
- **Old guides lie**: archived MOOSE guides reference `AI_*`/Tasking/Cargo classes that don't exist in stable. Translate to OPS equivalents.
- **MESSAGE duration**: `:ToAll()` etc. default ~10–30 s depending on settings; important lines should also `:ToLog()`.

## Project-specific (dcs-missions)

- Dev loop loads scripts from disk (`dofile(lfs.writedir() .. ...)`); a syntax error in any loaded file aborts the whole bootstrap — check `dcs.log` first when "nothing works".
- Restart loop: WebGUI restart / `net.load_mission` hook / SP `LeftShift+R`. No `loadmission` console exists.
- Server log: `Saved Games\DCS.server\Logs\dcs.log`.

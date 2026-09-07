# Slice 17 Part 3: Shipping Packaging Evidence

## Scope

S17-p3 wires the frozen S17-p1 mission bridge into `main.lua`, synthesizes a
self-contained shipping `main.lua` containing the complete pure telemetry
stack, adds fail-loud packaging and syntax gates, and documents installation of
the frozen S17-p2 GameGUI hook. This item was offline only: it did not run DCS,
install the hook, access a database, or alter telemetry event semantics.

## Packaging and wiring changes

`src/missions/duel-dynamic/main.lua` now has the pinned
`initShippingTelemetry()` wrapper immediately after
`initDevelopmentTelemetry()`. Development remains the default: the shipping
wrapper returns unless `_G.TELEMETRY_SHIPPING_ENABLED == true`, rejects a
simultaneously enabled development runtime, loads all 11 pure modules in the
development source path, explicitly passes `combat`, starts the deferred bridge
with `run_classification = "historical"`, and strongly roots the returned
runtime. The existing development init body and call were not changed.

`build/pack-shipping-miz.ps1` performs these transformations before composing
the artifact:

1. The lookup strip is anchored from the exact `-- Load siblings. Bootstrap
   set ...` line through the exact column-zero `local DIR = ROOT ..
   "missions/duel-dynamic/"` line. The regex is
   `(?ms)^-- Load siblings\. Bootstrap ...\r?\n[\s\S]*?^local DIR = ROOT
   \.\. "missions/duel-dynamic/"\r?\n`; its match count must be exactly one.
2. `initDevelopmentTelemetry` is stripped with
   `(?ms)^local function initDevelopmentTelemetry\(\)\r?\n.*?^end\r?\n`.
   Because nested ends are indented, the first subsequent column-zero `end` is
   the function close. The standalone development-init call is separately
   anchored and must occur exactly once.
3. The standalone `dofile(DIR .. "score.lua")` line is separately anchored and
   must occur exactly once.
4. The shipping function and call remain. Each exact telemetry dofile line is
   matched once and rewritten to its corresponding local:
   `TelemetryEventId`, `TelemetryEnvelope`, `TelemetryJson`,
   `TelemetryLifecycle`, `TelemetryBridge`, `TelemetryBridgeFrame`,
   `TelemetryBridgeQueue`, `TelemetryAsset`, `TelemetryShot`,
   `TelemetryCombat`, and `TelemetryParticipant`.
5. `_G.TELEMETRY_SHIPPING_ENABLED = true` is injected immediately before the
   exactly-once `initShippingTelemetry()` call.
6. In the declared order above, each frozen UTF-8 telemetry source is inserted
   verbatim inside `local Telemetry<Name> = (function() ... end)()` after the
   inlined score-module end marker and before the mission body. Neither
   `development.lua` nor `ndjson_sink.lua` is included.
7. The full synthesized text is checked on non-comment lines for `TraceOn`,
   `TraceLevel`, `os\.`, `io\.open`, `lfs\.`, `TEST_COMBAT`, `dofile\(`,
   `require\(`, `loadfile\(`, and `loadstring\(` before it is written.
8. After staging, external `lua5.1 -e` calls `loadfile([[<artifact>]])` only to
   compile the chunk and raises if compilation returns nil. The artifact is
   never executed by this check.

The first development run of the new strip reported zero lookup matches. The
cause was Windows PowerShell 5.1 decoding a non-ASCII em dash embedded in the
script's regex literal differently from the UTF-8 `main.lua`. The final strip
uses the required unique ASCII start and end anchors, still requires exactly
one bounded match, and the successful acceptance run below proves that shape.
No banned-pattern exception or frozen-module edit was needed.

## Staged artifact verification

Inspected artifact:
`out/duel-dynamic-build/l10n/DEFAULT/main.lua` (209810 bytes).

- **PASS — no loaders or development path tokens:** case-sensitive whole-file
  checks found no `dofile(`, `require(`, `loadfile(`, `loadstring(`, `DIR`, or
  `ROOT` token.
- **PASS — complete inline stack:** all 11 `local Telemetry... = (function()`
  declarations and all 11 `-- Inlined telemetry module:` markers are present.
  The inlined score marker and tracker implementation remain present.
- **PASS — production composition:** the shipping function binds
  `bridge = TelemetryBridge`, `combat = TelemetryCombat`, calls
  `bridge.start`, passes `combat = combat`, and specifies
  `run_classification = "historical"`. It has no `io`, `lfs`, or `os` config
  key.
- **PASS — enablement order:** `_G.TELEMETRY_SHIPPING_ENABLED = true` is on the
  line immediately preceding `initShippingTelemetry()`.
- **PASS — dev-only material absent:** there is no
  `initDevelopmentTelemetry` or `TEST_COMBAT` remnant.
- **PASS — gameplay body retained:** `local Tracker = _G.duel_tracker`, the
  indefinite player-wait init (`every INIT_POLL_INTERVAL until ANY player group
  becomes alive`), `spawnWave = function(reason)`, and the remaining package
  wave body are present.
- **PASS — input integrity:** the dev `.miz` SHA-256, size, and UTC last-write
  time were identical before and after packaging:
  `7BF2F472F651BE45F3733AF5B866ED4BADBBC90C9B1130352869537E15F80695`,
  `13391` bytes, `2026-07-27T20:16:49.3733378Z`.

The checklist command reported:

```text
no dofile(: PASS
no require(: PASS
no loadfile(: PASS
no loadstring(: PASS
no DIR token: PASS
no ROOT token: PASS
11 module local markers: PASS
score marker: PASS
historical classification: PASS
combat local passed: PASS
shipping flag immediately before call: PASS
no development init: PASS
tracker body: PASS
player-wait init: PASS
spawn-wave body: PASS
no TEST_COMBAT: PASS
no io config key: PASS
no lfs config key: PASS
no os config key: PASS
module-marker-count=11
bytes=209810
```

## Acceptance outputs

Dev input before packaging:

```text
BEFORE path=C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Missions\duel-dynamic.miz
BEFORE sha256=7BF2F472F651BE45F3733AF5B866ED4BADBBC90C9B1130352869537E15F80695
BEFORE size=13391 lastWriteUtc=2026-07-27T20:16:49.3733378Z
```

Final packager run:

```text
> powershell -File build\pack-shipping-miz.ps1
Cleaning previous build at C:\Projects\dcs-missions\out\duel-dynamic-build ...
Build dir: C:\Projects\dcs-missions\out\duel-dynamic-build
Extracting C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Missions\duel-dynamic.miz ...
Patched trigrules block (modern)
Patched trig block (legacy) actions
Patched trig.flag block
Patched trig.funcStartup block
Registered embedded scripts in mapResource
Wrote modified mission file
Synthesizing l10n/DEFAULT/main.lua ...
Banned-pattern gate: OK (full synthesized main.lua)
  wrote C:\Projects\dcs-missions\out\duel-dynamic-build\l10n\DEFAULT\main.lua (209810 bytes)
Syntax gate: OK (C:\Projects\dcs-missions\out\duel-dynamic-build\l10n\DEFAULT\main.lua)
Copying l10n/DEFAULT/Moose_.lua ...
  wrote C:\Projects\dcs-missions\out\duel-dynamic-build\l10n\DEFAULT\Moose_.lua (4393412 bytes)

Build tree left at: C:\Projects\dcs-missions\out\duel-dynamic-build
Inspect / edit it, then re-zip with:
  pwsh -File build\pack-shipping-miz.ps1 -Zip  # to re-run + auto-zip
  Re-run this command with -Zip after making source changes. Do not use Compress-Archive;
  on Windows it can create backslash entry names that DCS cannot resolve as resources.

Next steps:
  1. Test on a STOCK (sanitized) DCS install. See docs/shipping-duel-dynamic.md section 5.
  2. Drop the .miz into Saved Games\DCS.dcs_serverrelease\Missions\ on the server.
  3. Watch Saved Games\DCS.dcs_serverrelease\Logs\dcs.log for 'MOOSE INCLUDE END' and
     '[duel-dynamic] ...' breadcrumbs.
```

Dev input after packaging:

```text
FINAL-AFTER sha256=7BF2F472F651BE45F3733AF5B866ED4BADBBC90C9B1130352869537E15F80695
FINAL-AFTER size=13391 lastWriteUtc=2026-07-27T20:16:49.3733378Z
```

Formatting:

```text
> stylua --check .
(no output; exit 0)
```

Lua mission and telemetry runners:

```text
> lua5.1 tests\lua\run-duel-shared-bandits.lua
duel-dynamic package-wave tests: 12 passed
> lua5.1 tests\lua\telemetry\run.lua
telemetry Lua tests: 20 passed
> lua5.1 tests\lua\telemetry\run-lifecycle.lua
telemetry lifecycle tests: 8 passed
> lua5.1 tests\lua\telemetry\run-shot.lua
telemetry shot tests: 10 passed
> lua5.1 tests\lua\telemetry\run-json-sink.lua
JSON/sink Lua tests: 11 passed
> lua5.1 tests\lua\telemetry\run-participant.lua
telemetry participant tests: 9 passed
> lua5.1 tests\lua\telemetry\run-asset.lua
telemetry asset tests: 23 passed
> lua5.1 tests\lua\telemetry\run-combat.lua
telemetry combat tests: 11 passed
> lua5.1 tests\lua\telemetry\run-bridge.lua
telemetry bridge tests: 40 passed
```

DCS hook and transport mocks:

```text
> lua5.1 tests\dcs\run-telemetry-bridge-prod-mock.lua
telemetry bridge production mock (shifted): 26 passed, 0 failed
telemetry bridge production mock (fixed): 26 passed, 0 failed
telemetry bridge production mock: 52 checks passed across both mappings
> lua5.1 tests\dcs\run-telemetry-bridge-probe-mock.lua
telemetry bridge probe mock: passed
> lua5.1 tests\dcs\run-telemetry-bridge-api-discovery-mock.lua
telemetry bridge API discovery mock: passed
```

`git diff --check` produced no findings. `git diff` for `main.lua` contains only
the pre-existing six StyLua formatting areas plus the new shipping-init function
and call. A byte check reported `1202` CRLF endings, zero bare LF endings, and no
UTF-8 BOM for `main.lua`.

Final worktree status (the three modified and one new S17-p3 files are present
on top of the pre-existing work enumerated in the task):

```text
> git status --porcelain
 M build/pack-shipping-miz.ps1
 M collector/src/delivery-cli.ts
 M collector/src/delivery.ts
 M collector/src/spool.ts
 M collector/tests/delivery.test.ts
 M collector/tests/spool.test.ts
 M docs/PROJECT-STATUS.md
 M docs/shipping-duel-dynamic.md
 M src/missions/duel-dynamic/main.lua
 M web/package.json
 M web/src/app/api/telemetry/runs/[runId]/events/route.ts
 M web/src/app/globals.css
 M web/src/app/page.tsx
 M web/src/telemetry/export.ts
 M web/src/telemetry/ingest.ts
 M web/src/telemetry/run-status.ts
 M web/src/telemetry/store.ts
 M web/tests/export.test.ts
 M web/tests/ingest.test.ts
 M web/tests/run-status.test.ts
?? collector/tests/delivery-cli.test.ts
?? docs/telemetry/slice-16-part1-run-status-evidence.md
?? docs/telemetry/slice-16-part2-export-replay-evidence.md
?? docs/telemetry/slice-16-part3-ingest-metrics-evidence.md
?? docs/telemetry/slice-16-part4a-delivery-retry-evidence.md
?? docs/telemetry/slice-16-part4b-health-prune-evidence.md
?? docs/telemetry/slice-17-part1-mission-bridge-evidence.md
?? docs/telemetry/slice-17-part2-hook-evidence.md
?? docs/telemetry/slice-17-part3-packaging-evidence.md
?? hooks/
?? src/missions/duel-dynamic/telemetry/bridge.lua
?? src/missions/duel-dynamic/telemetry/bridge_frame.lua
?? src/missions/duel-dynamic/telemetry/bridge_queue.lua
?? tests/dcs/run-telemetry-bridge-prod-mock.lua
?? tests/lua/telemetry/run-bridge.lua
?? web/scripts/dev-replay-run.ts
?? web/src/telemetry/ingest-metrics.ts
?? web/src/telemetry/replay.ts
?? web/tests/ingest-metrics.test.ts
?? web/tests/replay.test.ts
```

## Residual risk

- Real execution of the shipping `.miz` under stock-sanitized DCS and the live
  production hook are not verified here. They remain the owner-gated S17-p4
  gate documented in `docs/shipping-duel-dynamic.md`.
- The hook's `os.clock` polling/throttle nuance carried from S17-p2 is unchanged
  and still requires observation in the live runtime.
- This item did not exercise the development mission with
  `TELEMETRY_SHIPPING_ENABLED`; normal development leaves that flag unset, so
  the new function is a no-op by construction.
- Events remain vulnerable to mission/process loss before hook acceptance, as
  documented for the in-memory bridge.

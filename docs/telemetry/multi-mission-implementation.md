# Multi-mission telemetry implementation

## Working branch and scope

Started 2026-09-14 in `worktrees/telemetry-decoupling`, branch
`feature/telemetry-decoupling`. This is an incremental implementation, not a
completed three-mission rollout. No installed mission, hook, service, database,
or deployment is changed by this work.

Target: separate mission entry scripts and configuration, optional shared
gameplay helpers, one shared telemetry library, and one existing delivery
pipeline. Wave reporting must be optional; non-wave missions must not inherit
wave gameplay. A future installer/mod is explicitly outside this phase.

## Read-only inventory

`build/inspect-mission-telemetry.py` inspected the three source archives in
`C:\Users\g_for\Saved Games\DCS\Missions\Telemetry`:

- `duel-dynamic-bvr.miz`
- `duel-dynamic-acm.miz`
- `air-superiority-survival.miz`

All three contain bootstrap references to
`C:\Projects\dcs-missions\src\bootstrap.lua`; no embedded Lua file entries were
found. Their different filenames therefore do not select separate source scripts.
The observed filenames establish `duel`, not `dual`, as the spelling.
Template inspection is complete in increment 3: BVR has four human slots;
ACM and Survival have five. The nine red donors match across the three archives.
The inventory tool prints hashes and never extracts or writes to the source directory.

## Increment 1: shared-library extraction

- Moved all 13 telemetry modules from the legacy mission directory to
  `src/lib/telemetry/`. Tests and the shipping packager use the shared location.
- Removed the development runtime's hidden lookup into the mission's source
  folder. The mission now injects the combat adapter explicitly, just as the
  shipping path does.
- Shared runtime diagnostics use `[telemetry]`, not a scenario name.
- Moved the existing mission identity/version into
  `src/missions/duel-dynamic/config.lua`; both transports read the same values.
  The packager embeds this configuration with an exact-match guard and includes
  it in the existing whole-artifact syntax/banned-API checks.
- Explicit empty bandit rosters are now accepted by asset and shot adapters.
  Player rosters remain required. This supports baseline lifecycle capture for
  a non-wave patrol fixture, not automatic capture of every DCS object.
- Added regression coverage for multiple mission identities, repeated mission
  loads with distinct caller-supplied run keys, independent pending queues,
  and a non-wave scenario with no opposing roster.
- Added static dependency checks preventing shared modules from importing
  mission files, hard-coding rosters/mission identity, or loading modules from disk.

Compatibility intentionally retained: the `duel_telemetry_bridge` and
`duel_telemetry_runtime` globals, `DDBRIDGE1` wire format, development run-counter
key, and existing source-version value. These are compatibility identifiers,
not mission identity. Renaming the installed hook protocol in an extraction
would require a coordinated deployment and is unnecessary here.

## Increment 2: failure-safe mission interface

`src/lib/telemetry/integration.lua` provides API version 1. Normal gameplay now
uses only its registration/cleanup methods; startup dependencies, driver
selection, classification defaults, and adapter error handling are shared.
The existing dev-only combat harness retains raw runtime access for its special
AI roster extension; that harness is stripped from shipping and is not the
public mission integration interface.

The library has 14 modules in total. Twelve are embedded for shipping; the
development driver and file sink are deliberately absent from the static build.

### Interface

`integration.new(options, resolve_module)` returns a client. The resolver is
injected; it maps module names to module tables. Shared code performs no file
loading. In development the mission's small resolver loads shared modules from
disk. The shipping packager replaces this one resolver with a table lookup.

Options contain `mode` (`disabled`, `development`, or `shipping`), explicit
`mission_name` and `mission_version`, player/opposing roster configuration,
DCS/MOOSE dependencies, and the mission-local state table. Unsupported or
conflicting transport selection starts neither driver. The disabled mode loads
no dependencies. Both mission flags being false also skips loading the interface
itself. Module loading and interface construction are protected at the mission
boundary, so a missing interface cannot prevent gameplay startup.

Client methods:

- `register_player_group(group)` reports an occupied player group.
- `register_opposing_group(group, template_name)` registers the spawned group
  against its configured template. The existing internal adapter still calls
  this role `bandit`; the public method does not imply a wave.
- `despawn_group(group)` reports intentional cleanup. It never destroys the
  group; gameplay performs destruction separately even when reporting fails.
- `status()` returns interface API version, selected mode, and startup state.
  `started` means the driver was created, **not** that the shipping handshake or
network delivery succeeded. Existing bridge/collector health remains the
  authority for transport health.

Operations return the adapter's result on success, or `nil` plus a bounded
category (`disabled`, `unavailable`, `failed`). Exceptions and returned errors
from adapters are contained. Diagnostics are emitted once per operation/category,
omit raw exception text, and tolerate a failing logger. A shipping client created
before handshake can register later when its runtime acquires an asset adapter;
operations made before then return `unavailable`, not fabricated success.

The client retains the runtime strongly for MOOSE subscriptions. Compatibility
aliases are published in the supplied state table. The source assembly no longer
contains separate development/shipping startup functions or accesses the raw
runtime during normal gameplay.

## Increment 3: independent entries and explicit packaging

The three missions now have independent entry scripts and configurations. The
legacy entry retains `duel-dynamic` identity. Shared wave gameplay, score, and
settings/template validation live under `src/gameplay/`, outside telemetry.
`-MissionName` selects the actual entry/config and a distinct artifact; named
development requests bind both mission and source root. See
[`../multi-mission-development.md`](../multi-mission-development.md) for build
commands, configurable settings, safeguards, and the original-loader limitation.

Gameplay defaults are unchanged except for the observed roster sizes and
scenario-specific F10 titles. Requested BVR/ACM-specific behavior adjustments
still await the owner's values/rules. The originals remain unmodified.

Increment-3 evidence: **309 Lua checks and three architecture checks passed**;
all three named builds plus a legacy regression build passed the shipping
syntax/banned-API gates and generated-script sandbox handshake/identity/ACK
checks. Three negative build-selection cases passed without producing an
invalid shipping artifact. Formatting and `git diff --check` passed. No live
server or production acceptance is claimed.

## Dashboard finding (still open)

The current `summarizeRunWaves` derives package completion from aircraft
spawn/loss events. There are no explicit wave lifecycle events in the current
shared event contract. The mission page additionally enables this calculation
only for `duel-dynamic`.

Do not silently treat every red group in every future mission as a wave. Preserve
the legacy derivation for old runs, and introduce explicit optional capabilities
and scenario milestones with contract/projection tests before generalizing the
dashboard. Gameplay termination and DCS session termination remain distinct.

## Verification

Increment-1 results: 264 Lua checks passed across the ten commands below,
including 43 bridge checks and 98 production-hook checks across both DCS return
mappings; three Python architecture checks passed. StyLua passed on all changed
Lua modules/tests and `git diff --check` passed. The shipping smoke build passed
the Lua 5.1 syntax and whole-artifact banned-API gates and produced a ZIP with
forward-slash resource paths. These are offline/build results only.

Increment 2 adds 14 interface checks and four gameplay failure-isolation cases
(disabled, missing module, driver exception, adapter exception). It also executes
the **generated shipping Lua** in a whitelisted Lua 5.1 sandbox without `io`,
`os`, `lfs`, or filesystem loaders, exercising real embedded startup, handshake,
mission identity/classification, and ACK/drain behavior. This supplements rather
than replaces a live stock-DCS test.

Final increment-2 verification: **282 Lua checks + three architecture checks
passed**, together with the generated shipping sandbox, the shipping build's
syntax/banned-API gates, StyLua on changed Lua files, and `git diff --check`.

Run from this worktree, not the main checkout:

```powershell
python tests/test_telemetry_boundaries.py
lua5.1 tests/lua/telemetry/run.lua
lua5.1 tests/lua/telemetry/run-json-sink.lua
lua5.1 tests/lua/telemetry/run-lifecycle.lua
lua5.1 tests/lua/telemetry/run-asset.lua
lua5.1 tests/lua/telemetry/run-shot.lua
lua5.1 tests/lua/telemetry/run-participant.lua
lua5.1 tests/lua/telemetry/run-combat.lua
lua5.1 tests/lua/telemetry/run-bridge.lua
lua5.1 tests/lua/telemetry/run-integration.lua
lua5.1 tests/dcs/run-telemetry-bridge-prod-mock.lua
lua5.1 tests/lua/run-duel-shared-bandits.lua
```

The smoke build uses the Survival source archive with the **legacy** gameplay
and identity. It is only a packaging regression artifact, not the new Survival
release. Output is contained in the worktree:

```powershell
& build/pack-shipping-miz.ps1 -MissionName duel-dynamic -DevMizPath "C:\Users\g_for\Saved Games\DCS\Missions\Telemetry\air-superiority-survival.miz" -BuildName "shared-telemetry-smoke" -OutName "shared-telemetry-smoke.miz" -Zip
lua5.1 tests/lua/telemetry/run-shipping-integration.lua out/shared-telemetry-smoke/l10n/DEFAULT/main.lua
```

Do not deploy that smoke artifact as one of the new mission identities.
Offline runtime-isolation tests do not prove live mission switching or collector
outage recovery. No live acceptance is claimed.

## Increment 4: dashboard catalogue generalization (no contract/schema change)

Completed 2026-09-14 in the same worktree on the free track. The dashboard now
recognizes all four package-wave identities with explicit titles/descriptions
and replaces the `duel-dynamic`-only wave-report gate with `isWaveMission()`.
Legacy `duel-dynamic` derivation (`summarizeRunWaves` from spawn/loss events)
is reused unchanged for the three new missions because they share the same
package-wave implementation. No event-contract, ingest, projection, or database
change is included. Records remain mission-scoped by exact mission key; no
cross-mission leaderboard was added.

Verification: `web` full suite 237 passed before the change; dashboard suite
20 passed after (including new catalogue/wave-mission checks); `tsc --noEmit`
and `eslint` clean.

## Remaining implementation sequence

1. **Completed in increment 2:** thin, failure-safe integration API; shared
   transport dependency assembly, explicit registration/cleanup, retained
   subscriptions, disabled/failure gameplay tests, and shipping sandbox execution.
2. **Source separation completed in increment 3:** inspected templates, independent
   entries/configs, shared gameplay. Owner-specific gameplay adjustments remain.
3. **Completed in increment 3:** explicit packaging selection, template checks,
   and named development loading. Original no-argument loaders remain unchanged
   and selector-based until explicitly rebound; they are not silently upgraded.
4. **Completed in increment 4 (free track):** dashboard catalogue + wave-page
   gate generalized without contract/schema changes.
5. **Completed in the Step-2 session (this worktree, uncommitted):**
   optional reporting capabilities and explicit wave milestones across the
   event contract, capture, ingest, and projections; mission-scoped database
   pagination before the global run limit; Drizzle 0005 metadata
   reconciliation (no new migration required, none applied). Details in
   "Step 2" below.
6. Validate BVR → ACM → Survival → BVR with the existing collector service,
   including delivery interruption across a switch, then real player capture.
   Live DCS/production steps remain owner-authorized; offline evidence does not
   claim live acceptance.

Any database migration requires first reconciling the existing 0005 Drizzle
metadata gap; production writes and deployment remain separate owner actions.

## Step 2: capabilities, explicit wave milestones, mission-scoped history

Completed 2026-09-14 in the same worktree on branch
`feature/telemetry-decoupling` (uncommitted). Main had moved to `83d465e`
("Fix player lives for reused DCS aircraft names"); the branch was
fast-forwarded to it and the one conflict
(`src/missions/duel-dynamic/main.lua`, now a 4-line entry) was resolved
toward the new architecture, with the lives fix ported into
`src/gameplay/package-waves.lua` (`countedPlayerAircraft` keyed by unit
name + DCS object ID). No decoupling work was lost.

### A. Capabilities + explicit wave milestones (additive only)

`mission.started` carries an optional `capabilities` object, currently
`{ wave_milestones = 1, gameplay_outcome = 1 }`. Missing means a legacy
producer: consumers fall back to derivation and never read a silent zero.
Three new milestone event types carry no entity roles (all `null`, like
mission lifecycle events) and consume ordinary sequence numbers:

- `wave.spawned` (`wave_number`, `wave_size`, optional `donor`, `tier`,
  `reason`) on every package launch;
- `wave.cleared` (`wave_number`, optional `wave_size`, `reason`) only when a
  complete package is defeated — intentional despawns (F10 reset,
  empty-server cleanup) never emit it;
- `gameplay.ended` (`reason`, e.g. `all-aircraft-lost`) for the scenario
  outcome, distinct from DCS session termination (`mission.ended`).

Layering, each with tests: `envelope.lua` validation (legacy + new accepted,
malformed rejected); `development.lua`/`bridge.lua` capabilities
passthrough; `integration.lua` API v1 additions (`report_wave_spawned`,
`report_wave_cleared`, `report_gameplay_over`, all failure-safe with
bounded `disabled`/`unavailable`/`failed` and never throwing) with
capabilities validation; `package-waves.lua` declares capabilities and
emits milestones behind `if telemetry` guards (non-wave missions simply
never call them and link no wave code); contract schema + doc updated in
`contracts/` and synced to `web/`; collector accepts the new events through
the existing schema path (spool idempotency, in-order delivery, and
mission-switch isolation covered); web ingest needs no code change
(schema-driven); projections resolve explicit-first with legacy fallback
(`resolveRunWaves`: `explicit` / `derived` / `missing` / `not-applicable`)
and read the gameplay outcome separately. `summarizeRunWaves` is byte-
unchanged, so legacy runs render exactly as before and history is never
rewritten. Hook wire compat (`DDBRIDGE1`, bridge globals, source-version)
is untouched.

### B. Mission-scoped history

`TelemetryStore.listMissionRuns` filters by mission in the database BEFORE
the scope limit (the `unknown` bucket matches null/empty mission names);
the dossier page uses it instead of fetch-then-filter, so a busy mission
can no longer push another mission's history out of the window. Status
filtering and paging still apply over the mission scope, and the high
score still evaluates all ended non-test runs in that scope. Records stay
mission-scoped; no cross-mission leaderboard. Regression coverage locks
the filter-before-limit contract, paging slices, the honest empty state,
and unknown-bucket separation.

### C. Drizzle 0005 reconciliation (no production writes)

`web/drizzle/0005_wakeful_redwing.sql` existed with matching `schema.ts`
but `meta/_journal.json` and snapshots stopped at 0004. Reconciliation
regenerated the metadata with drizzle-kit itself: the regenerated
`0005_wakeful_redwing.sql` is byte-identical to the production-applied
file, so the journal entry and `meta/0005_snapshot.json` now reflect the
already-applied production state — nothing was reapplied. A follow-up
`generate` reports no schema changes, and the full journal (0000–0005)
was applied to a fresh throwaway postgres:16 container (all 10 tables
including `collector_health`, 6 history rows), then the container was
removed. Step 2 needs no schema change, so no new migration was
generated; backfill policy stands (no backfill — capabilities live in
event payloads, legacy runs keep derived summaries).

### Step-2 verification (all green, offline only)

- Lua: `run.lua` 23, `run-json-sink` 11, `run-lifecycle` 8, `run-asset`
  23, `run-shot` 10, `run-participant` 9, `run-combat` 11, `run-bridge`
  43, `run-integration` 20; prod-mock bridge 98; shared bandits 40;
  bootstrap selection 9; package-wave config 14; boundaries OK.
- Shipping: BVR/ACM/Survival `-MissionName` builds pass syntax +
  banned-API gates; all three generated payloads pass the no-filesystem
  sandbox (startup, handshake, identity incl. capabilities frame, ACK);
  build-selection 3/3 rejections pass (packager now scopes
  `ErrorActionPreference` around the validator call so the wrapper
  message survives PowerShell 5.1 native-stderr handling).
- Contracts: `npm run check` 34 passed. Collector: 131 passed (incl. 3
  new milestone tests), typecheck/lint/prettier clean. Web: 246 passed,
  `tsc --noEmit` and `eslint` clean.
- `git diff --check` clean. Changed Lua is StyLua-clean except for the
  repo-wide pre-existing LF-vs-`line_endings=Windows` drift (untouched
  files fail identically; with Unix endings the changed files pass).

Live DCS rotation (BVR → ACM → Survival → BVR), outage across a mission
switch, and real-player capture remain owner-authorized live validation;
nothing here claims live acceptance. No hook/collector reinstall, no
production writes, no source-archive modifications.

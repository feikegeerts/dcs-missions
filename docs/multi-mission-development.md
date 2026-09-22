# Independent mission scripts and builds

The multi-mission refactor was merged to `main` on 2026-09-14 and is included
in the current `main`/`origin/main` tree. BVR, ACM, and Survival have separate
entries and configurations, while gameplay and telemetry remain shared where
that is intentional. Named builds and the generated no-filesystem shipping
sandbox are verified offline. Live mission rotation and real-player acceptance
are still pending; do not treat the named builds as final releases yet.

The original `.miz` files remain generic development loaders. They still load
the main-checkout bootstrap and do not identify their scenario from the
filename. Use explicit named builds or named development-loader arguments when
testing a specific mission.

## Source boundaries

```text
src/
  bootstrap.lua
  lib/telemetry/                   shared capture and delivery integration
  gameplay/
    package-waves.lua             optional shared wave implementation
    package-wave-config.lua       pure settings/template validation
    score.lua                     shared gameplay kill counter
  missions/
    duel-dynamic/                 preserved legacy identity
    duel-dynamic-bvr/
    duel-dynamic-acm/
    air-superiority-survival/
      main.lua                   independent entry script in EACH folder
      config.lua                 identity, title, rosters, gameplay settings
```

Every entry loads its own configuration and invokes the shared wave chunk with
that configuration. State is local to that invocation, not a global configuration
override. The build embeds the selected entry itself, including entry-specific
code; it does not discard that script and merely substitute a mission name.

The three new missions inherit the previous gameplay defaults until the owner
specifies their desired differences. ACM now overrides only the spawn distance
to a fixed 20 statute miles; its package lifecycle, two-aircraft-per-player
shared pool, 20-second replacement delay, escalation, donor tiers, altitude,
speed, and CAP tasking remain the shared defaults used by Survival. BVR has
four player slots, while ACM and Survival each have five, matching read-only
inspection of the supplied archives. All three use the same nine
late-activated red donor names. ME loadouts and options remain in their
respective archives and are preserved by packaging.

Telemetry does not import any of this gameplay code. A future non-wave entry
can use `lib/telemetry/integration.lua` without the wave implementation. The
current shipping recipe still targets these package-wave entries; supporting a
different gameplay implementation will need an explicit build recipe, not a
telemetry rewrite.

## Build a selected shipping mission

From the worktree root:

```powershell
& build/pack-shipping-miz.ps1 -MissionName duel-dynamic-bvr -Zip
& build/pack-shipping-miz.ps1 -MissionName duel-dynamic-acm -Zip
& build/pack-shipping-miz.ps1 -MissionName air-superiority-survival -Zip
```

These select matching source archives from
`C:\Users\g_for\Saved Games\DCS\Missions\Telemetry` and produce distinct `.miz`
files plus inspectable `*-build` staging directories under this worktree's
`out/`. `-DevMizPath` can select another source archive, but it must be paired
with explicit `-MissionName` unless its basename is the legacy `duel-dynamic`.
The no-argument legacy build retains its dedicated-server input default.

Validation rejects unknown mission source folders, mismatched configuration
identity, invalid settings, missing/duplicate player groups, untracked human
slots, and missing/non-late-activated/non-AI donors. Template compatibility is
not proof of scenario identity: ACM and Survival share rosters, so the caller
must still select the intended source archive. No automatic renaming or
historical reclassification occurs.

The entry must retain one configuration load and one shared gameplay invocation
in the current supported shape. Additional runtime file loads fail the shipping
banned-API gate until their dependencies are explicitly added to packaging.
The selected identity is also asserted when the embedded entry invokes gameplay.

Shipping outputs contain no runtime disk dependency and do not read
`.current-mission`. They are offline-verified candidates, not live-accepted
releases. Candidate archives may be deployed for an owner-approved test
window, but do not replace the development loaders or call a mission released
until the live rotation and player gates pass.

## Mission-specific adjustments

Edit a mission's `config.lua` for values and its `main.lua` for distinct rules.
The optional `gameplay` table accepts:

- `aircraft_per_player` (legacy `lives_per_player` is still accepted),
  `wave_escalation_every`, `wave_tier_every`,
  `max_package_size`, `respawn_delay_s`;
- `spawn_distance_min_sm`, `spawn_distance_max_sm` (statute miles);
- `spawn_alt_min_ft`, `spawn_alt_max_ft`, `cap_alt_min_ft`, `cap_alt_max_ft`;
- `cap_speed_min_kt`, `cap_speed_max_kt`;
- `bandit_task` (`CAP` or `INTERCEPT`), `wave_donor_tiers`.

The ACM configuration currently sets `spawn_distance_min_sm` and
`spawn_distance_max_sm` to `20`, plus the same explicit two-aircraft allowance
and 20-second replacement delay as Survival. Other gameplay values continue to
come from the shared defaults.

Omitted values retain the existing defaults. Unknown keys, invalid numbers,
reversed ranges, invalid cadences, and untracked tier donors reject before
telemetry/gameplay subscriptions are installed. Donor tiers belong to gameplay;
they are not telemetry configuration. Increment the mission version deliberately
when changing a scenario. Existing runs retain their recorded identity/version.

## Named development loading

The three original archives still call the main-checkout bootstrap without
arguments. **They have not been rebound to this worktree.** Their old behavior
continues to follow the main checkout's `.current-mission`.

For a separately prepared development loader, bind both the source tree and
mission explicitly in its startup action, for example:

```lua
assert(loadfile([[C:\Projects\dcs-missions\worktrees\telemetry-decoupling\src\bootstrap.lua]]))({
  mission_name = "duel-dynamic-acm",
  scripts_root = [[C:\Projects\dcs-missions\worktrees\telemetry-decoupling\src\]],
})
```

A named request requires an explicit root and ignores `.current-mission`.
Invalid/path-traversing names reject before loading MOOSE. An optional
`expected_mission` field guards callers that intentionally use the selector.
Legacy no-argument loaders remain supported; they cannot magically identify
which archive called them. The source root is logged as the authoritative check.
Gameplay also logs `[mission] <mission_name> version <mission_version>`;
older `[duel-dynamic]` gameplay breadcrumbs are retained for compatibility.
Development still requires the de-sanitized environment; shipping does not.

## Verification

- All three named configurations match the real source templates.
- Each named shipping build and the legacy regression build passes syntax,
  banned-API, and forward-slash archive checks.
- Each generated shipping Lua payload runs in the no-filesystem sandbox,
  handshakes with its expected mission identity, and ACKs/drains its first event.
- Regression tests exercise all three source entries, isolated per-mission
  overrides, and unchanged legacy gameplay/failure behavior.
- Negative build tests reject implicit named selection, an unknown mission,
  and ACM configuration paired with the four-slot BVR archive.
- Dashboard recognizes all four package-wave identities and applies the same
  wave-report derivation to each; web dashboard suite passes including new
  catalogue/wave-mission checks.

Additional commands:

```powershell
lua5.1 tests/lua/run-bootstrap-selection.lua
lua5.1 tests/lua/run-package-wave-config.lua
& tests/test-mission-build-selection.ps1
lua5.1 tests/lua/telemetry/run-shipping-integration.lua out/duel-dynamic-bvr-build/l10n/DEFAULT/main.lua duel-dynamic-bvr
```

Completed since the original implementation notes: optional capability/wave
reporting, explicit wave milestones, mission-scoped database pagination, and
Drizzle 0005 metadata reconciliation. The remaining work is owner-specific
BVR/ACM tuning (their configs currently preserve shared defaults), followed by
live BVR → ACM → Survival → BVR switching, outage recovery, and real-player
capture. The collector service is already installed and running; service
health-post deployment still needs verification if the installed distribution
predates the current source build. See
`docs/telemetry/multi-mission-implementation.md` for evidence and boundaries.

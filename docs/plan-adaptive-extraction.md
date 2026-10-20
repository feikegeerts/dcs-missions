# Adaptive cooperative extraction mission — implementation plan

Status: **Full adaptive combat remains a draft. Dual CH-47F/UH-60L transport
testing is owner-accepted and its port to the 33 NM operational mission is
approved.** The short archive is retained as **Operation Hidden Passage - Testing**
for future improvements. Pickup is automatic after safe landed/stopped checks;
unloading is manual by explicit owner decision. Full operational-route, remote
multicrew and dedicated-server acceptance remain separate gates. Current transport
behaviour and workflow: `docs/hidden-passage.md`.
See `docs/hidden-passage-transport-test.md`.
After the first hosted test, revision 2 addresses landing/party separation,
focused menus, smoke access and failure feedback. The user explicitly chose
**mission restart**, not an in-mission reset command or reset mechanism.
Date: 2026-10-20

Planning update: the user selected **Syria** and saved the initial Chinook at
**Hatay**. Caucasus remains a fallback for later scenario design. The A-10 is
not installed locally; friends have now confirmed **A-10C II Tank Killer**.
The user also proposed a SAM-defended enemy base and a terrain-masked helicopter
approach, and requested inspection of installed Chinook mission scripting.
The user has now chosen a concealed pickup **near**, not inside, the enemy base.
First prove transport with one Chinook and two nearby points at a friendly base;
defer the operational pickup location and combat until that core loop works.

This document separates the agreed direction, observations, and proposals.
It does not start an execution queue or assign work to agents. The initial
transport authorization covered ground support and a nearby Chinook pickup;
later requests extended the same objective to the user-added UH-60L slot and
approved the operational port after testing. No installed mod or DCS configuration
change is part of that implementation.

## 1. Goal and agreed direction

Create a new cooperative mission type alongside the existing air-to-air
missions. All human-controlled aircraft belong to Blue. A helicopter completes
one main extraction objective; optional fixed-wing support changes the enemy
opposition and provides meaningful supporting tasks.

Desired aircraft:

- CH-47F and the group's existing UH-60 Black Hawk mod for transport.
- High-fidelity official A-10, plus Su-25T, for ground attack.
- F/A-18C and F-16C for fighter/multirole support.

The reconnaissance-team/high-value-person extraction proposal was accepted
as the direction. Exact story, location, rules, and balance remain proposals.
The theatre must be either Caucasus or Syria, selected for a suitable site.
Plan before coding; keep future work packages small and independently testable
to control model-context costs and enable later parallel implementation.

## 2. Machine observations

Read-only checks on 2026-10-20:

| Item | Observation | Consequence |
|---|---|---|
| Black Hawk | `C:\Users\g_for\Saved Games\DCS\Mods\aircraft\uh60l\entry.lua` declares `UH-60L`, developer `Kinkku`, version `2.1.5`; the flyable transport type is `UH-60L`. | Target this installed mod, not an unspecified Black Hawk implementation or the armed DAP variant. |
| Mod version ambiguity | The same folder's `version.txt` contains `1.5`; a v2 guide is present. | Record both values. Before multiplayer acceptance, compare the installed package/files with the friends' installation; metadata alone does not prove an exact release match. Do not upgrade the mod as part of mission development. |
| Dedicated-server mod | `C:\Users\g_for\Saved Games\DCS.dcs_serverrelease\Mods\aircraft` does not exist. | Black Hawk server loading is an explicit compatibility gate. Confirm the required installation location and dependencies before an owner-approved install. |
| A-10 | No local A-10 install. Friends have now confirmed **A-10C II Tank Killer**. | Use A-10C II for the later aircraft roster, not original A-10C or simplified A-10A. No A-10 slot is included in the current Chinook-only probe. |
| Other requested aircraft | Full-client aircraft folders include `CH-47F`, `F-16C`, `FA-18C`, and `Su-25T`. | Files are present; entitlement and multiplayer flyability still need live checks. |
| Terrain | Caucasus and Syria directories exist in both the full-client install and `D:\DCS World Server\Mods\terrains`. | Both are local candidates; folder presence is not a live terrain-load or group-ownership check. |
| Pinned MOOSE | `src/lib/Moose_.lua` includes CTLD aircraft entries for `UH-60L` and `CH-47Fbl1`. | Evaluate native CTLD first. These entries are evidence of intended support, not proof that this mod version's pickup/unload path works. |

Full-client install: `C:\Program Files (x86)\Steam\steamapps\common\DCSWorld`.
The observed dedicated-server install is `D:\DCS World Server`.

## 3. Proposed first playable operation

A friendly reconnaissance team is sheltering with a high-value person in a
hostile valley. Blue retrieves the complete objective party and returns it to
a designated friendly receiving area. Either supported helicopter can do this;
both are not required.

Proposed phases:

1. **Preparation:** occupy slots, select support roles, receive the briefing.
2. **Ingress:** explicitly start the operation; approach the pickup area.
3. **Pickup:** land within the designated area and load the objective party.
4. **Return:** transport the party to the friendly receiving area.
5. **Complete:** unload the correct party there; record success once.

The phase sequence is a planning model, not a commitment to a particular FSM
implementation. Landing/loading conditions, boarding time, start authority,
failure conditions, and mission-end timing require agreement before coding.

### Adaptive opposition

| Participating capability | Proposed opposition / supporting task |
|---|---|
| Transport only | A credible low-threat extraction route; no advanced enemy fighters and no heavy armour that requires absent support. |
| Ground attack | A roadblock or approaching armoured reinforcement that support aircraft can neutralize before it threatens pickup. |
| Air cover | A bounded enemy interception/patrol, such as MiG-29 or Su-33, with warning and time for Blue to react. |
| Both support capabilities | Both branches, coordinated around the same extraction rather than unrelated target waves. |

Support must create useful work without becoming a punishment for joining.
Threats need credible origins, bounded numbers, and response time. Do not spawn
fighters close to the helicopter simply because someone entered an F-16 slot.
Destroying all enemies is not the main victory condition.

### Defended base and terrain masking

New user proposal: an enemy base protected by SAM sites, with hills providing
cover so the helicopter must navigate a low-level approach to the target.

Recommended design, subject to site validation:

- Treat the defended base as a persistent part of the setting, not a target
  that suddenly appears when support joins. Separate baseline area air defence
  from optional air/ground reinforcement branches.
- Give the base effective coverage of exposed/high approaches, while a tested
  route behind intervening ridges permits helicopter-only completion.
- Do not assume a drawn SAM range circle equals actual coverage. Verify radar
  line of sight, detection and engagement behavior with the selected DCS units,
  including the complete radar/launcher system where required.
- Avoid putting short-range or infrared defences where they eliminate the
  supposedly viable masked route or pickup area. Terrain hiding radar does not
  make the helicopter immune to nearby visual/infrared threats.
- Optional SEAD/strike support could open an exposed or more direct route;
  destroying the SAM system must not become mandatory if jets remain optional.
- Test the return as well as ingress, and any pickup hover: a safe valley leg
  does not prove the helicopter can safely climb, land, or hold position there.

**Agreed:** the pickup is concealed near the enemy base, not inside its defended
perimeter. Helicopter-only crews must not need to destroy its SAMs to extract.

The user additionally proposed an adaptive SAM position/coverage that threatens
the pickup when suitable friendly support participates, requiring suppression
or destruction before ingress. Treat this as a separate optional threat variant,
not a reason to close the helicopter-only route.

Recommended guardrails, not yet approved: enable that variant only for explicitly
committed, suitably equipped SEAD/strike support, not merely the presence of any
fixed-wing aircraft. Choose the variant at operation start and brief it; do not
unexpectedly activate a launcher covering a helicopter already on final. Define
what happens if the supporting crew disconnects or loses its aircraft, since an
already active SAM may otherwise make completion impossible. This extends the
earlier optional-SEAD idea: in this variant neutralizing the pickup-covering
threat is required, while the baseline still has a terrain-masked solution.

Recommended initial rules, **not yet approved**:

- A helicopter-only crew can succeed; optional support does not become an
  implicit prerequisite. Fixed-wing-only crews cannot complete the objective.
- Distinguish aircraft type from operational role. Initially use clearly
  labelled slot roles; F-16/F/A-18 can have separate air-cover and ground-attack
  slots. Avoid automatic weapon-by-weapon capability inference in version one.
- Snapshot occupied roles at explicit operation start. Do not count empty
  client templates or spectator slot browsing.
- Late support joins can enable a future, not-yet-launched threat branch at a
  safe phase boundary. Repeated joins must not accumulate enemies.
- Support departure stops future escalation; it does not erase engaged enemies.
- Threat activation is bounded and idempotent, not an endless wave system.

## 4. Location decision

**User-selected theatre/base: Syria, Hatay.** The user-authored seed contains
one Blue client Chinook there. The original test pickup was approximately 3.05 NM
northeast of its parking. After successful transport acceptance, the user moved
the pickup approximately 33.06 NM south to a village in the intended enemy area.
That placement is approved for the next Chinook flight; terrain-masked ingress,
return and any enemy/SAM positions still need validation. Separate friendly staging from hostile approaches;
do not assume real-world territorial control determines the coalition layout.

**Caucasus fallback:** Kobuleti and an inland valley, or Batumi/inland valleys.
On either theatre, a forward helicopter staging point can shorten the transport
leg without forcing fast jets onto the same start location.

These are search areas, not validated sites. No exact coordinates, landing
surface, convoy path, or flight time has been verified. Select one theatre for
the first release; supporting both at once adds authoring and acceptance work.

Site acceptance checklist:

- A landing area usable by both the CH-47F and UH-60L, checked in DCS.
- Terrain masking and a navigable low-level ingress/return route.
- A candidate defended-base location and radar/launcher placement that make
  exposed approaches dangerous without closing every helicopter route. Confirm
  in DCS; neither the site nor a radar-shadow corridor is verified yet.
- Target roughly 10–15 minutes per helicopter leg, then adjust from measured
  flight time rather than assuming map distance equals play time.
- A working road approach for enemy reinforcements, sufficiently separated
  from the landing area to permit warning and intervention.
- Space and distance for believable fighter arrivals, without instant contact.
- Suitable fixed-wing parking/runways, helicopter staging, and return zones.
- Daylight/good-weather first acceptance; no requirement for an unowned theatre.

The user should approve the theatre and candidate site after scouting, before
the final archive and scenario-specific coordinates are built around them.

### Immediate priority: Chinook transport proof at one friendly base

User-requested sequence: create one Chinook at the intended friendly base and
test extraction over a short flight to another part of that same base before
moving the objective to its operational location.

**Subsequent approved adjustment:** the user saved `Operation Hidden Passage`
at Hatay and requested a pickup a few miles away plus Blue ground support. That
prototype is now implemented; the earlier 500–1,000 m same-base proposal below
is superseded for this test. See `docs/hidden-passage-transport-test.md` for the
actual layout, build, flight instructions and remaining verification.

Prepare a **separate development/probe mission**, not a modification of an
existing air-to-air loader or shipping artifact:

1. Open a new Syria mission and choose the candidate friendly base. Set the
   required airfield coalition for the Blue slot.
2. Place one Blue CH-47F client slot on suitable parking. Recommend a hot start
   initially so transport debugging does not require repeating startup.
3. Select two clear, separated pickup/delivery areas on the base, roughly
   500–1,000 m apart if the layout permits; avoid the runway and taxi traffic.
4. Prove landed pickup of an identifiable test party, onboard ownership, a short
   flight, and unloading at the receiving area. Hoist behavior is a later probe
   unless explicitly selected as the initial interaction.
5. Confirm one successful delivery only, no success at the wrong location, no
   duplicate party, and no false success after carrier loss or mission restart.
6. Repeat the core loop on the dedicated server; a single-player pass alone
   does not prove multiplayer behavior. Then test the UH-60L separately.

Use the approved narrow MOOSE transport approach after checking compatibility;
installed campaign scripts remain references, not an assumed dependency.
No SAMs, enemy aircraft, adaptive opposition, telemetry expansion, or operational
route work is needed to establish this first transport proof.

Freeze only the minimal probe contract first: named helicopter slot, pickup and
return areas, objective-party identity, selected transport interaction, and its
observable success conditions. Use what the probe teaches to finalize the wider
P0 contracts. The broader parallel work packages remain deferred; do not spend
context or implementation effort on all branches before the transport gate.

## 5. Fit with the existing repository

Keep `src/bootstrap.lua` as the shared dispatcher. Add an independent entry
under `src/missions/<agreed-name>/`; do not route this operation through
`src/gameplay/package-waves.lua` or add extraction switches to that module.

Proposed mission-local modules:

```text
src/missions/<agreed-name>/
  main.lua             composition, loading, runtime ownership
  config.lua           identity, slots/roles, zones, templates, tuning
  operation.lua        pure phase/objective rules and bounded decisions
  roster.lua           occupied-slot/role observation, join/leave reconciliation
  transport.lua        pickup/unload/loss adapter; evaluate native CTLD first
  opposition.lua       MOOSE spawning, routes and OPS tasking
```

Names and file count are provisional. Keep mission-specific code local; only
extract another shared gameplay system when there is a real second consumer.

The shipping packager currently embeds and validates package-wave entries.
Add an explicit recipe for the new implementation, retaining the existing
wave recipe and its checks. Do not build a general dependency resolver or
rewrite packaging around this one mission.

### Shared boundary contract to agree before parallel implementation

- **Configuration:** stable mission identity; exact supported aircraft types;
  explicit slot-to-role mapping; named zones and AI templates; tuning units.
- **Inputs:** occupied roster snapshot, operation-start request, pickup receipt,
  delivery receipt, objective-carrier loss, and scheduled phase evaluations.
- **Pickup/delivery receipt:** identifies the objective party and the actual
  carrier incarnation, not just an aircraft/group name that can be reused.
- **Outputs:** current phase, bounded opposition requests with unique request
  IDs, player-facing notices, and terminal outcome with reason.
- **Ownership:** operation logic owns objective progress; transport owns
  observed loading state; opposition owns spawned groups and scheduled work;
  main retains runtime references and coordinates cleanup.
- **Safety:** duplicate/late events cannot duplicate the party, spawn another
  branch, or turn an already failed operation into a success.

Agree actual Lua table/function shapes and fixtures in the first work package;
do not have separate implementers independently invent these interfaces.

### Telemetry boundary

Reuse `src/lib/telemetry/integration.lua`; do not import wave gameplay. Existing
aircraft tracking accepts airplane and helicopter categories, but actual
multiplayer capture of these helicopters still needs verification.

Use existing lifecycle, aircraft/participant capture, and supported gameplay
outcome reporting where applicable. Keep the mission playable if telemetry
fails. Verify dashboard registration for the new identity without claiming wave
milestones or a wave leaderboard.

Ground-asset tracking, new objective-event schemas, ground-kill statistics,
valuation expansion, and a custom extraction dashboard are **not implied by
this mission plan**. Discuss separately if required; do not make them hidden
prerequisites for the first playable extraction.

### Installed Chinook mission references — inspected read-only

Location: `C:\Users\g_for\Saved Games\DCS\Missions\CH-47`.
Found `The Long Lift Campaign` and `OP_Inherent_Resolve_MEDEVAC.miz`.
The latter archive's `mission` declares Syria; its archive listing did not
contain standalone `.lua` files. That does not establish whether its other
triggers use embedded script actions.

Inspected selected embedded files directly from these Long Lift archives,
without extracting or executing their scripts:

- `Mission 1 - Operation New Clay.miz` — troop transport.
- `Mission 3 - Operation Noble Home.miz` — CSAR/hover pickup and event wiring.
- `Mission 6 - Operation Unbroken Dagger.miz` — script inventory.

Findings:

- `TransportManager.lua` and `triggers/Transport.lua` implement boarding,
  an onboard troop roster, unloading, and objective completion. The capacity
  table includes `UH-60L` and `CH-47Fbl1`. Scripted boarding removes the ground
  entities and unloading recreates them through MIST; this is not proof of
  visible native cabin occupancy or animation.
- The transport trigger offers F10 embark/disembark commands and explicitly
  handles `UH-60L` as a non-native transport on landing. It does not prove that
  every native Chinook embarkation path is observed; the event script itself
  contains a TODO about observing DCS-radio boarding.
- `missionFeatures/CSAR.lua` identifies itself as Ciribob CSAR 1.9.2 (2018),
  requiring MIST. Its aircraft table includes both helicopters. Its hover
  pickup branch uses a proximity check below 8 m, height relative to the
  rescued person no greater than 20 m, and a nominal ten-second countdown.
  Completion records the person onboard and removes the ground group.
- That is **simulated winching**, not evidence of a deployed cable, animated
  rescuer, or native hoist control. The countdown's live timing and compatibility
  have not been tested. These example thresholds are not our mission settings.
- The surrounding scripts use `briefingRoom` tables and MIST, not the project's
  MOOSE transport integration. Some semantics conflict with proposed rules:
  the general transport event handler assumes passengers survive a crash and
  recreates them at the aircraft location.

Use these as behavioral references. Do not import the campaign framework or
assets into this repository by default; any actual code reuse needs a license
and dependency review. Prefer testing native MOOSE CTLD/CSAR capabilities first.
The operation core should receive the same objective pickup receipt whether a
future adapter uses landed boarding or simulated hover pickup.

Hoist-style pickup is now an option to evaluate, **not an approved requirement**.
Choose landed boarding, simulated hover pickup, or both before finalizing P3.
Physical/animated hoisting is a separate feasibility question, not promised by
the installed script examples.

## 6. Work packages and parallel boundaries

These are future handoff units, not agent assignments. Each implementation
package must include its own tests and a concise evidence/handoff summary.

| Package | Scope and owned files | Depends on | Done when |
|---|---|---|---|
| Probe — base-local Chinook transport | Separate minimal development archive and narrow transport compatibility test, following section 4. No operational threats. | Candidate base; minimal probe contract and pickup-mode agreement | One Chinook completes the same-base pickup/return loop offline and on the dedicated server, with duplicate/wrong-location checks. |
| P0 — decisions and contracts | Resolve section 8, freeze module interfaces, configuration and event fixtures; inventory compatibility prerequisites. | User decisions; transport probe findings | No consequential rules or cross-module table shapes left for implementers to guess. |
| P1 — site and mission template | Scout Syria first; evaluate base/SAM positions and masked routes, then author approved source `.miz`, slots, zones, donor templates, routes and briefing. Own template/site notes, not runtime Lua. | P0; site approval before final authoring | Both helicopters fit the pickup area, masked ingress/return and SAM behavior pass live checks, convoy route works, names match the contract, selected module slots load. |
| P2 — operation core | Mission-local pure phase/objective logic and Lua 5.1 tests; no DCS calls. | P0 | Success/failure, duplicates, ordering, empty roster, and role/phase decisions pass deterministic tests. |
| P3 — transport adapter | Use the installed campaign findings as references; probe MOOSE CTLD/CSAR for the agreed landed/hover interaction, then implement a narrow adapter and mocked tests. No framework transplant. | P0; a minimal probe archive; pickup-mode decision | Agreed pickup, unload and carrier-loss signals work for both helicopters; wrong cargo/location cannot complete the objective; simulated versus physical behavior is documented. |
| P4 — roster and opposition | Occupied-role reconciliation, bounded spawn decisions, MOOSE adapters and tests. Own roster/opposition modules. | P0; P1 names/routes for live verification | Composition cases work; late/repeated joins do not multiply threats; leaving does not remove engaged enemies. |
| P5 — entry, build and telemetry wiring | Sole owner of `main.lua`, final `config.lua`, shared build-script changes, identity registration, integration and shipping tests. | P0 for skeleton; P1–P4 for completion | Named self-contained build runs without runtime disk APIs; existing builds regress cleanly. |
| P6 — live acceptance and tuning | Dedicated-server test matrix, Tacview inspection, concise evidence and defect fixes through relevant owners. | P5; compatibility/environment gates | Agreed scenarios pass on real DCS, including friends' mod package. |

First complete the minimal transport probe. Parallel layout after the subsequent
P0 contract freeze:

```text
             +-- P1 site/template -------------------+
P0 contracts +-- P2 pure operation core -------------+--> P5 integration --> P6
             +-- P3 transport proof/adapter ---------+
             +-- P4 roster/opposition with mocks ----+
```

P3 live proof needs a tiny probe template; coordinate that artifact with P1.
P5 may prepare the explicit build recipe early using contract fixtures, but
cannot claim integrated success until real dependencies arrive.

### Keep context and merge costs down

- Give each package only this plan's relevant sections, the frozen contract,
  owned files, and the exact tests it must run; avoid rereading the full
  telemetry history or huge MOOSE build.
- One owner per file. P1 proposes configuration values; P5 applies them to
  `config.lua`. Only P5 changes shared packaging/registration.
- Prove helicopter transport before investing heavily in combat polish.
- Run focused package tests first, then one consolidated regression/integration
  pass. Parallelize independent components, not competing architectural designs.
- Use mocks to unblock development, but label mock-only results honestly.
- No autonomous agent launches or background implementation are authorized by
  this document. Parallel execution is a later decision in a permitted setup.

## 7. Verification and release gates

Offline:

- Lua 5.1 parsing, formatting, pure-core and adapter tests.
- Validate archive theatre, supported client slots, role mappings, zones,
  late-activated AI templates, required mod declarations, and selected identity.
- Generated shipping payload runs in the no-filesystem sandbox with mocked DCS.
- All legacy/named wave builds and relevant telemetry tests remain green.

Live, in increasing cost order:

1. Confirm mod compatibility, aircraft/terrain availability, and server loading.
2. UH-60L alone completes pickup and return; repeat with CH-47F alone.
3. Wrong return location, unloaded/wrong party, duplicate load signals, and
   reused aircraft names cannot produce false success.
4. Transport + ground attack; transport + air cover; then the full combination.
5. Fixed-wing only: no false extraction success; clear missing-transport status.
6. Late join, role switch, support departure, disconnect/rejoin, and carrier
   loss after pickup follow the approved rules.
7. Two transports cannot both own or deliver the same objective party.
8. Restart clears operation state and scheduled work; native terminal behavior
   matches the agreed result; stock-scripting shipping build works.
9. Tacview confirms sensible spawn distances, routes, warning time and threat
   separation. Basic telemetry is correct and its outage cannot break gameplay.
10. SAM trials prove a viable masked ingress, pickup and return with each
    helicopter, plus a representative exposed approach that is detected/engaged.
    Verify any proposed hover pickup does not invalidate terrain cover. These
    trials establish intended behavior, not a guarantee against every threat.

No installed hooks, services, sanitization settings, development loader, or
existing mission artifacts are changed without an explicit test/deployment
window. Package the mod as a documented external prerequisite, not inside the
shipping mission.

## 8. Decisions before implementation

1. **A-10 — resolved:** friends use **A-10C II Tank Killer**. Local installation
   is still absent; the current prototype deliberately remains Chinook-only.
2. **Theatre/base — resolved for the probe:** Syria, Hatay. Approve the operational
   concealed pickup and route later, after transport works and terrain/SAM
   scouting is complete. The nearby test field is not the final objective site.
3. **Start and adaptation:** approve explicit start, role-labelled slots,
   occupied-role snapshot and phase-boundary handling of late support joins.
4. **Objective and recovery:** one objective party transported together? Does
   carrier destruction after pickup end the operation, or create a rescue?
   Recommend terminal failure first; recovery is a separate expansion.
5. **Multiplayer scope:** expected simultaneous crew size/slot counts, whether
   multicrew is needed in version one, and the desired operation duration.
6. **Loss/retry policy:** respawn rules before pickup, empty-server behavior,
   and whether success/failure ends the DCS mission or permits an explicit reset.
   For the current transport prototype, this is resolved: a failed/completed
   attempt is retried by restarting the mission; do not implement an in-mission
   reset. Wider adaptive-mission terminal behavior remains a separate decision.
7. **Adaptive SAM rule:** concealed pickup near, not inside, the enemy base is
   agreed. Decide which support role/equipment enables the optional pickup-covering
   SAM variant, when that selection locks, and the contingency for support loss.
   Baseline helicopter-only completion must remain viable.
8. **Pickup mode:** landed boarding, simulated hover/winch pickup, or both?
   The inspected scripts demonstrate the simulated approach only; physical
   hoisting remains unverified. This choice affects site clearance and exposure.

Recommended first scope: one theatre, one pickup, one return area, either
transport, two optional threat branches, daylight, landed loading/unloading,
no insertion leg, no sling loading, no dynamic campaign, no rescue sub-mission,
no automatic replay loop, and no new scoring/dashboard project.
This remains the recommended baseline, not a rejection of the new hoist idea;
resolve the pickup-mode decision before changing its implementation scope.

Next action is a Chinook pickup/return at the user's new southern site. The full
adaptive mission still requires the unresolved decisions above; prototype
implementation does not authorize the later combat/aircraft branches.

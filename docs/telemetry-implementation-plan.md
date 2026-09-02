# DCS Telemetry Implementation Plan

**Status:** Implementation in progress. Slices 1–6 are complete; every later
slice still requires its own Gate E approval.

This plan turns the duel-dynamic mission into a telemetry producer and adds a
public read-only dashboard backed by a protected ingestion API. Work is split
into small vertical slices. Every slice has a narrow scope, automated tests,
manual DCS validation, and a stop point. An agent must not continue into the
next slice without the previous slice passing its gate.

The domain vocabulary in [`CONTEXT.md`](../CONTEXT.md) is authoritative. If a
future implementation request conflicts with that vocabulary, stop and resolve
the language before changing code.

## 1. Fixed Decisions

These decisions came from the design discussion and are not open for agents to
reinterpret:

- The initial historical unit is a `mission run`, one DCS mission load.
- A DCS restart creates a new mission run with fresh state and a new history
  entry.
- Version one tracks the configured blue player aircraft, the red AI package
  aircraft spawned by `duel-dynamic`, and every discrete ordnance item fired by
  those aircraft.
- Ground units, ships, statics, scenery, environmental effects, and unrelated
  mission entities are outside version-one scope.
- Discrete ordnance is charged when it is fired, not when it hits.
- Machine-gun round counting is not a version one requirement.
- An aircraft crash or destruction incurs aircraft replacement cost even if the
  pilot ejects and survives.
- A human participant is identified by stable multiplayer identity, with name
  and callsign retained as historical labels.
- Values are estimated in USD using one selected number per ordnance or asset.
- The valuation catalogue is versioned per mission run.
- Unknown prices remain visible as unpriced and do not receive guessed values.
- Cost, kills, losses, and combat standing are separate scoreboard dimensions.
- The mission never stops because one side is ahead or behind.
- The initial duel standing uses aircraft kill differential and is provisional.
- A cleanly ended run is `completed`; an interrupted run is `aborted`.
- Test runs and historical runs are both retained and can be filtered.
- The dashboard is publicly readable in version one.
- User authentication is deferred.
- Mission-data writes require a collector-only credential.
- MOOSE is the primary mission scripting framework.
- Raw DCS APIs are allowed only in small isolated adapters where MOOSE does
  not provide the required capability.
- New mission code uses MOOSE `EVENTS`, `BASE:HandleEvent`, `SPAWN`,
  `SCHEDULER`, and related current classes rather than archived `AI_*` APIs.
- The mission does not connect directly to Vercel, Neon, or any external HTTP
  service.
- A local collector is the boundary between mission Lua and the web system.
- Source events are retained even when several source events become one
  derived fact.
- The implementation uses at-least-once delivery and idempotent ingestion.
- The mission emits source events only. Losses, attributed kills, assists, and
  costs are derived by the web system and remain rebuildable from source events.

## 2. Goals And Non-Goals

### Goals

- Record enough event history to calculate ordnance expenditure, aircraft
  losses, kills, assists, and coalition costs.
- Attribute events to human participants, AI assets, and coalitions where the
  source data supports attribution.
- Keep unknown attribution explicit instead of inventing a player or weapon.
- Show live coalition standing and cost while the mission is still running.
- Retain completed and aborted mission runs for historical analysis.
- Make the event history replayable so derived metrics can improve later.
- Reuse the Meal Maestro stack and conventions for the web application.
- Make the first end-to-end path small enough to validate in DCS before adding
  more event types.
- Keep the tracked-asset boundary explicit so broader mission coverage can be
  added later without requiring generic world discovery in version one.

### Non-goals for version one

- Exact machine-gun bullet counts.
- Fuel burn, maintenance, rescue, or pilot replacement economics.
- Sensor detection, radar track, or detailed damage telemetry.
- A terminal match condition or mission auto-stop.
- User accounts, player login, or per-player privacy controls.
- A fully online multiplayer product with tenant isolation.
- Assets outside the configured `duel-dynamic` player and bandit aircraft.
- Direct HTTP or database access from mission Lua.
- A single blended score that hides the difference between effectiveness and
  cost.

## 3. Target Architecture

```text
DCS mission
  MOOSE event handlers and spawn callbacks
        |
        v
Lua telemetry normalizer
  versioned event envelope
        |
        v
Development file sink / future DCS bridge
        |
        v
Local TypeScript collector
  tail, validate, spool, retry, batch, deduplicate
        |
        | HTTPS with collector credential
        v
Vercel Next.js application
  public read API and protected ingest API
        |
        v
Neon PostgreSQL via Drizzle
  source events, run data, projections, valuation catalogue
        |
        v
Public dashboard
  live standing, costs, ordnance, losses, timeline, history
```

### Repository layout

The existing Lua project remains the owner of the mission and the telemetry
producer. New concerns are separated by directory:

```text
src/
  bootstrap.lua
  lib/
  missions/
    duel-dynamic/
      main.lua
      score.lua
      telemetry/
        -- mission-side event normalization and sinks

contracts/
  telemetry-event-v1.md
  telemetry-event-v1.schema.json
  fixtures/

collector/
  -- local TypeScript process and tests

web/
  -- Next.js App Router application
  src/db/
  src/app/api/
  src/lib/telemetry/
  src/components/
  drizzle/

tests/
  lua/
  integration/

docs/
  telemetry-implementation-plan.md
  telemetry/
    -- test evidence, price research, bridge notes
```

The `web/` directory should be configured as the Vercel Root Directory. It is
not a reason to turn the Lua project into a JavaScript monorepo immediately.
Keep package managers and build commands independent until there is a concrete
need for shared tooling.

### Concern ownership

| Concern | Owner | Must not own |
|---|---|---|
| Mission events and DCS identity | MOOSE Lua telemetry module | Database schema or web UI |
| Wire event validation | `contracts/` | DCS-specific lifecycle logic |
| File tailing and delivery | `collector/` | Business cost rules |
| HTTP validation and persistence | `web/src/app/api/` plus services | DCS event registration |
| Cost and derived facts | `web/src/lib/telemetry/` | React rendering |
| Database schema and migrations | `web/src/db/` | Mission Lua |
| Dashboard views | `web/src/components/` and routes | Direct database credentials |
| Ordnance price research | `docs/telemetry/` and catalogue seed data | Runtime event attribution |

## 4. MOOSE-First Mission Design

MOOSE is the default integration layer for the mission. The existing mission
already depends on MOOSE for spawn management, event dispatch, tasking, menus,
and scheduling. Telemetry should extend that design instead of installing a
second event system.

### MOOSE capabilities to use

- `BASE:HandleEvent` and MOOSE `EVENTS` for mission event subscriptions.
- `EVENTS.Shot` for discrete weapon firing.
- `EVENTS.Hit` for hit attribution and future assist derivation.
- `EVENTS.Kill` for primary killer attribution when the DCS version exposes it.
- `EVENTS.Dead`, `EVENTS.Crash`, `EVENTS.PilotDead`, and `EVENTS.UnitLost` for
  loss signals and reconciliation.
- `EVENTS.Ejection` where the event payload is available and useful.
- `EVENTS.PlayerEnterAircraft` and the appropriate leave event for participant
  and sortie lifecycle. The current `PlayerEnterUnit` behavior should not be
  copied blindly because MOOSE documents multiplayer limitations for it.
- `SPAWN:OnSpawnGroup` for AI asset instance registration.
- MOOSE group and unit wrappers for names, types, coalition, player name, and
  position where available.
- `SCHEDULER` only for bounded retry, low-frequency heartbeat, or flush work. A
  scheduled callback must return safely and must not hide errors.

### Version-one tracked roster

The mission script's pairing configuration is the version-one asset boundary:

- Blue aircraft belong to `PLAYER_GROUP_NAMES`: `Aerial-1`, `Aerial-2`,
  `Aerial-3`, and `Aerial-4`.
- Red aircraft belong to the `BANDIT_GROUP_NAMES` allow-list: `Bandit-1`,
  `Bandit-2`, and `Bandit-3`, including MOOSE's spawned-name suffixes. The
  current package-wave lifecycle clones `Bandit-1` into a multi-unit group;
  `Bandit-2` and `Bandit-3` remain accepted for historical runs.
- An asset instance represents an individual aircraft incarnation, even though
  the current configured groups contain one aircraft each.
- A discrete weapon event is in scope only when its initiator resolves to one
  of these aircraft instances.
- Capture uses the runtime DCS weapon type. Catalogue research inventories the
  configured mission loadouts and observed runtime identifiers; it does not
  attempt to catalogue every weapon supported by the aircraft module.

Adding or renaming a configured pair changes the tracked roster. It does not
authorize generic discovery of other coalition assets.

### Isolated vanilla DCS usage

Raw DCS access is acceptable only behind small adapters for capabilities MOOSE
does not cover, such as:

- Writing the development NDJSON sink through the de-sanitized development
  environment.
- Reading a missing event field from the underlying DCS event object.
- Accessing a server or bridge capability that is not part of mission-side
  MOOSE.

Each raw access must have a comment naming the MOOSE capability that was
checked and explaining why the fallback is necessary. Do not spread raw
`world`, `coalition`, or file operations throughout the mission handlers.

### Existing score module

Do not delete or replace `score.lua` in the first telemetry slices. The current
F10 kill counter is a working mission feature and provides a useful regression
signal. The telemetry ledger becomes the long-term source of truth only after
its event capture and dashboard path have been validated. A later slice can
make the F10 display read from derived telemetry if that remains useful.

## 5. Event Contract

The contract is a wire-level domain contract, not a database schema. It must be
stable enough for a Lua producer and TypeScript consumer to evolve
independently.

### Event envelope

The first contract should contain these conceptual fields:

| Field | Purpose |
|---|---|
| `schema_version` | Version of the wire contract |
| `event_id` | Stable source-event identity, assigned once at capture |
| `source` | Producer name, initially `moose-mission` |
| `producer_id` | Stable identifier for the DCS server or producer installation |
| `source_version` | Mission or telemetry producer version |
| `run_key` | Producer-side mission-run key before database assignment |
| `event_sequence` | Monotonic source-event sequence within one mission run |
| `event_type` | Canonical event name |
| `sim_time` | DCS model time when the event occurred |
| `wall_time` | Producer wall-clock time when available |
| `initiator` | Actor reference, if any |
| `target` | Target reference, if any |
| `participant` | Human participant reference, if any |
| `asset` | Asset reference, if any |
| `weapon` | Discrete weapon reference, if any |
| `coalition` | Actor or asset coalition, if known |
| `location` | Position snapshot when available and useful |
| `payload` | Source-specific fields retained for later analysis |

The contract must distinguish missing, unknown, and not-applicable values. A
missing attacker is not the same as the string `Player`, and an unknown weapon
must not be treated as a known generic weapon.

### Actor and asset references

References should carry stable fields where available and descriptive fields as
snapshots:

- `participant_id`: stable multiplayer identity for human pilots.
- `display_name`: name at the time of the event.
- `callsign`: callsign at the time of the event.
- `asset_key`: producer-side key for one asset instance.
- `dcs_name`: DCS group or unit name when available.
- `dcs_type`: canonical DCS type name when available.
- `kind`: participant, aircraft, or unknown in version one.
- `coalition`: blue, red, neutral, or unknown.

The precise JSON shape is a deliverable of Slice 1. Agents must not invent a
second shape in the collector or web application.

### Initial source-event taxonomy

The canonical event names should be stable and lower-case, with a dot between
the subject and action:

| Event type | Meaning | Initial use |
|---|---|---|
| `mission.started` | A new DCS mission run begins | Run creation |
| `mission.ended` | A clean mission end is observed | Run completion |
| `mission.heartbeat` | A run is still active | Interrupted-run detection |
| `participant.entered` | A human enters an aircraft | Participant/sortie |
| `participant.left` | A human leaves an aircraft | Sortie lifecycle |
| `asset.spawned` | An asset becomes active | Asset instance |
| `asset.despawned` | An asset leaves active play | Asset lifecycle |
| `ordnance.fired` | A discrete weapon is fired | Expenditure |
| `asset.hit` | An asset receives a hit | Effectiveness |
| `asset.kill-reported` | DCS reports destruction with killer data | Kill derivation |
| `asset.dead` | DCS reports an asset dead | Loss reconciliation |
| `asset.crashed` | DCS reports an aircraft crash | Loss reconciliation |
| `pilot.dead` | DCS reports pilot death | Pilot statistics |
| `pilot.ejected` | DCS reports ejection | Pilot statistics |

All entries in this table are mission-emitted source observations. The mission
does not emit canonical loss, kill, assist, expenditure, or cost facts.
Machine-gun start/end events, fuel events, sensor events, and damage details are
explicitly deferred.

### Initial derived-fact taxonomy

Derived facts are created only by replayable backend projections:

| Fact type | Meaning |
|---|---|
| `ordnance.expenditure` | One discrete firing valued at its selected catalogue value |
| `asset.lost` | One aircraft loss reconciled from one or more source signals |
| `kill.attributed` | One destruction attributed to a primary attacker or unknown |
| `assist.attributed` | One qualifying contribution under the documented assist rule |

Every derived fact records the source event IDs that support it. Rebuilding the
same source stream must recreate the same fact identities and totals.

### Event identity and deduplication

The implementation must follow this policy:

1. The telemetry producer assigns a monotonically increasing `event_sequence`
   to every emitted source event in a mission run.
2. `event_id` is formed from `producer_id`, `run_key`, and `event_sequence` and
   is assigned once. Collector and API retries preserve it unchanged.
3. Do not treat the DCS/MOOSE event `id` as an occurrence ID; it identifies the
   event type.
4. Do not use event content as the primary identity. Two legitimate shots can
   otherwise collide when they share a simulation tick, initiator, and weapon.
5. Preserve all received source events, including repeated loss signals.
6. Derive one canonical fact from repeated signals when they describe one
   lifecycle occurrence.
7. Charge one aircraft cost for one aircraft loss, never once per loss signal.
8. Make reprocessing the same event stream produce the same derived totals.

Sequence assignment and event-ID construction belong in one pure testable Lua
module. Derived-fact identity belongs in one pure backend module and is based on
fact type plus the supporting source event IDs.

## 6. Domain And Database Shape

The event ledger is the source of truth. Query-friendly tables and projections
are derived data and must be rebuildable from retained source events.

### Core tables

The final model is expected to contain these concepts. Add them incrementally;
do not create every table in the first migration.

| Table/concept | Responsibility |
|---|---|
| `mission_runs` | Run key, mission name/version, map, status, timestamps, test flag, catalogue version |
| `participants` | Stable human identity and durable identity metadata |
| `run_participants` | Participant presence, coalition, display name, and callsign in one run |
| `asset_instances` | One incarnation of a tracked player or bandit aircraft |
| `sorties` | Participant control period for an asset |
| `telemetry_events` | Immutable normalized source events and source payload |
| `derived_facts` | Idempotent canonical kills, assists, losses, and other facts |
| `cost_entries` | One explainable cost charge linked to its source fact/event |
| `valuation_catalogues` | Versioned sets of estimated USD values |
| `valuation_items` | One value for one canonical DCS asset or ordnance type |

### Database rules

- Use PostgreSQL numeric/decimal values for money, never floating point money
  arithmetic.
- Store the catalogue version and selected unit value with each cost entry so
  historical totals do not change when a future catalogue is edited.
- Enforce uniqueness for producer, run, and event sequence as well as
  `event_id`.
- Index run, event type, simulation time, initiator, target, coalition, and
  weapon fields needed by the first dashboard queries.
- Retain source-specific event payloads as JSON for later interpretation.
- Keep raw source events immutable from the application path.
- Make derived rows safe to upsert or rebuild.
- Use `on conflict do nothing` or an equivalent idempotent insert for ingest.
- Do not assume Neon HTTP transactions are available. Avoid
  `db.transaction()` with the Neon HTTP driver used by Meal Maestro.
- If multiple writes cannot be made atomic, accept the source event first and
  repair/replay derived rows from it.

### API shape

The initial API should remain small:

- `POST /api/telemetry/ingest`: authenticated collector batch write.
- `GET /api/telemetry/runs`: public run list with status and summary fields.
- `GET /api/telemetry/runs/:runId`: public run detail.
- `GET /api/telemetry/runs/:runId/scoreboard`: public coalition and participant
  metrics.
- `GET /api/telemetry/runs/:runId/events`: public paginated event timeline.
- `GET /api/telemetry/catalogue`: public catalogue read endpoint if needed by
  the UI.

The dashboard may query the database from server components following the Meal
Maestro pattern where that is simpler. Do not create internal HTTP calls from
server components merely to reuse a route handler. Route handlers remain thin;
validation and business logic belong in `web/src/lib/telemetry/`.

No user authentication is planned. The ingest route still checks a server-side
collector credential such as `TELEMETRY_INGEST_TOKEN`; this protects data
integrity rather than protecting user data.

## 7. Accounting Rules

### Ordnance

- One `ordnance.fired` event produces one expenditure for a discrete weapon.
- The cost is charged at firing time.
- The expenditure is not removed if the weapon misses.
- A later hit or kill is a separate effectiveness fact.
- The weapon key is the canonical DCS type name where available.
- An unknown weapon remains visible and unpriced.
- Unpriced does not mean zero-cost. Totals show a known subtotal plus an
  unpriced-item count and are labelled partial while unpriced items exist.
- Machine-gun round counts are not calculated in version one.

### Aircraft loss

- A crash or destruction of an aircraft produces one `asset.lost` derived fact.
- Pilot ejection does not cancel aircraft loss cost.
- Pilot death or ejection remains a separate participant statistic.
- `Dead`, `Crash`, `PilotDead`, and `UnitLost` signals are reconciled rather
  than charged independently.
- A repeated loss signal for the same asset instance produces no second charge.
- Aircraft replacement value is selected from the catalogue assigned to the
  mission run.

### Kills and assists

- Prefer MOOSE/DCS `Kill` data for primary killer attribution.
- Use `Hit` data to derive assists only under an explicit tested rule.
- A target can have one primary killer and zero or more assists.
- An unidentified attacker is recorded as unknown, never as `Player`.
- Friendly fire is retained with both attacker and target coalitions.
- Kill and cost calculations remain separate so a side can win the engagement
  while spending more.

### Live combat standing

The initial duel standing is calculated per coalition as:

```text
aircraft primary kills - own aircraft losses
```

The dashboard may display `ahead`, `behind`, `tied`, or `undetermined`. This is
not a terminal winner, does not stop DCS, and does not prevent respawns.

## 8. Valuation Catalogue Plan

Price research is a separate concern from runtime telemetry. A research agent
may search public sources for best estimates, but must not change attribution or
event logic.

### Catalogue requirements

- One selected USD number per ordnance or asset type.
- Canonical DCS type name as the lookup key.
- Human-readable display name.
- Version-one category: missile, bomb, rocket, or aircraft.
- Source URL or note explaining the estimate.
- Catalogue version and effective date.
- No confidence score, range, or automatic market-price claim.

### Research workflow

1. Inventory DCS type names observed in the active mission and its aircraft
   loadouts.
2. Expand the inventory to every discrete ordnance type present in the tracked
   aircraft's configured mission loadouts.
3. Research one estimate per item using publicly available sources.
4. Record the selected number and source in a reviewable data file.
5. Review names that map to multiple DCS identifiers before seeding the
   catalogue.
6. Leave unsupported or ambiguous items visible as unpriced.
7. Load the catalogue through a versioned seed or migration.

Do not block event capture on completing the full price inventory. Telemetry can
arrive first and receive a cost later through replay.

## 9. Vertical Implementation Slices

Every slice below is independently testable. The listed files are boundaries,
not permission to refactor adjacent areas. Each agent stops after its own exit
criteria and reports evidence.

### Model assignment policy

- **GPT-5.6 SOL High** owns work with unresolved domain semantics, ambiguous DCS
  behavior, lifecycle reconciliation, cross-system failure modes, security
  decisions, or architectural consequences.
- **GPT-5.6 Luna Xhigh** owns narrow contract-driven implementation, fixtures,
  migrations, catalogue data, and UI work whose behavior and acceptance tests
  are already specified.
- A Luna Xhigh task must stop and escalate to SOL High rather than changing the
  event contract, tracked-asset boundary, run semantics, or bridge architecture.
- A SOL High task should leave exact fixtures, interfaces, and acceptance
  evidence so a later Luna Xhigh task does not need to repeat design work.
- Model assignment does not replace Gate E. The human owner still approves each
  slice before the next begins.

### Slice 0: Planning and repository guardrails

**Recommended model:** GPT-5.6 SOL High, advisory to the human owner.

**Purpose:** Establish the contract and handoff process.

**Deliverables:**

- This plan.
- `CONTEXT.md` glossary.
- Proposed architecture decision record after approval, if desired.
- Empty concern directories only if the next slice needs them.

**Validation:** Human review of scope, terminology, and slice boundaries.

**Stop point:** No implementation begins until this plan is approved.

### Slice 1: Version one event contract

**Recommended model:** GPT-5.6 SOL High.

**Why:** This fixes cross-language domain semantics, source-versus-derived
ownership, identity, ordering, and compatibility constraints used by every
later slice.

**Purpose:** Define one wire format before Lua, collector, or database code
exists.

**Likely files:**

- `contracts/telemetry-event-v1.md`
- `contracts/telemetry-event-v1.schema.json`
- `contracts/fixtures/*.json`
- Contract validation tests

**Scope:**

- Envelope fields.
- Actor, target, asset, weapon, coalition, and time references.
- Event taxonomy.
- Source event versus derived fact distinction.
- Idempotency key requirements.
- Per-run ordering: sequence one is `mission.started`, and later events retain
  producer order through collection.
- Batch format and size limits.

**Tests:**

- Valid `mission.started` fixture.
- Valid `ordnance.fired` fixture.
- Valid loss-signal fixture.
- Valid unknown-attacker fixture.
- Rejection of missing producer ID, run key, event sequence, event type, or
  schema version.
- Rejection of malformed actor and weapon structures.

**Exit criteria:** Lua and TypeScript agents can implement against the same
fixtures without inventing fields.

### Slice 2: Pure Lua envelopes and event identity

**Recommended model:** GPT-5.6 Luna Xhigh.

**Why:** The contract and identity algorithm are fixed by Slice 1; this is a
narrow Lua 5.1 implementation with deterministic unit tests.

**Purpose:** Build contract-compatible source events without loading DCS or
MOOSE.

**Likely files:**

- `src/missions/duel-dynamic/telemetry/envelope.lua`
- `src/missions/duel-dynamic/telemetry/event_id.lua`
- `tests/lua/telemetry/*.lua`

**Scope:**

- Build envelopes from plain Lua adapter input.
- Assign a monotonic event sequence within a run.
- Construct `event_id` from producer, run, and sequence.
- Normalize absent attacker, target, and weapon correctly.
- Keep Lua 5.1 compatibility and avoid filesystem or MOOSE side effects.

**Tests:** Sequences increase without gaps, two otherwise identical shots get
different IDs, retries preserve an already-built envelope, nil player names do
not become `Player`, coalition IDs map correctly, and numeric positions and
simulation times survive normalization.

**Exit criteria:** Pure Lua tests pass and no content fingerprint is required to
distinguish legitimate repeated events.

### Slice 3: Stock bridge feasibility spike

**Recommended model:** GPT-5.6 SOL High.

**Why:** DCS execution-environment boundaries and server-hook capabilities are
uncertain and can invalidate the architecture if misunderstood.

**Purpose:** Retire the highest-risk environment assumption before downstream
systems depend on it.

**Scope:** Research and test a server hook, DCS-gRPC, or another supported local
bridge. Prove that the target dedicated-server channel can expose mission-run
lifecycle, stable multiplayer identity where available, and framed telemetry
without requiring mission-side `io`, `os`, or `lfs`. Record payload and size
constraints. Do not implement the production bridge or change mission logic.

**Exit criteria:** `docs/telemetry/bridge-notes.md` names one viable approach,
shows test evidence, and identifies any contract constraints. Stop if no
supported path is proven.

### Slice 4: Mission-run lifecycle and development sink

**Status:** Complete on 2026-08-31. See
`docs/telemetry/slice-4-lifecycle-evidence.md` for automated, shipping, and
dedicated-server evidence.

**Recommended model:** GPT-5.6 SOL High.

**Why:** Mission-start timing, clean shutdown, heartbeat behavior, run-key
uniqueness, and scheduled-callback failures require DCS-specific judgment.

**Purpose:** Establish run context before any combat event is emitted.

**Scope:**

- Create `producer_id`, a fresh collision-resistant `run_key` following the
  Slice 3 bridge constraints, and event sequence state. Simulation time alone is
  not a valid run key.
- Emit `mission.started` explicitly during telemetry initialization. Do not wait
  for `EVENTS.MissionStart`, because the mission script is loaded from a MISSION
  START action and may register after that event.
- Observe `EVENTS.MissionEnd` and emit `mission.ended` when possible.
- Emit a low-frequency `mission.heartbeat` through a bounded scheduler.
- Write one append-only NDJSON file per run through an isolated development
  sink; each complete record is flushed and closed before returning.
- Keep the existing F10 score and bandit behavior unchanged.

**DCS validation:** Start, restart, and cleanly stop the mission. Verify a fresh
run key, sequence starting at one, one `mission.started`, periodic heartbeats,
and `mission.ended` when DCS reports a clean end.

**Exit criteria:** Every later source event has valid run context and the
development sink contains contract-valid lifecycle records.

### Slice 5: Capture one MOOSE ordnance event

**Status:** Complete on 2026-09-01. See
`docs/telemetry/slice-5-ordnance-evidence.md` for automated, controlled-shot,
and two-player dedicated-server evidence.

**Recommended model:** GPT-5.6 Luna Xhigh.

**Why:** After run context and the sink exist, this is one bounded MOOSE event
adapter with explicit DCS acceptance steps.

**Purpose:** Prove mission-side combat capture with one discrete weapon.

**Scope:** Register `EVENTS.Shot`, accept only initiators belonging to the
configured blue player aircraft or allowed red bandit groups, normalize the event, and
write it through the Slice 4 sink. Do not capture machine-gun start/end events.

**DCS validation:** Fire two discrete weapons. Verify exactly two
`ordnance.fired` records with distinct sequences and IDs, plus correct weapon,
participant where applicable, coalition, simulation time, and run key. Restart
and verify a new run key. Preserve existing duel behavior and clean logs.

**Exit criteria:** A real DCS shot produces one valid record without changing
spawn, respawn, or F10 score behavior.

### Slice 6: Local collector parser and durable spool

**Status:** Complete on 2026-09-02. See
`docs/telemetry/slice-6-collector-evidence.md` for the crash-consistency
design, the automated test matrix, and real-data idempotency evidence.

**Recommended model:** GPT-5.6 SOL High.

**Why:** Cursor/spool crash consistency, partial records, ordering, and recovery
contain distributed-systems failure modes despite the small code footprint.

**Purpose:** Read mission records safely without involving Neon.

**Scope:**

- Tail per-run append-only NDJSON files and handle partial final lines.
- Validate records against the contract.
- Insert into a durable spool idempotently by `event_id`.
- Advance a file-identity-aware cursor only after the spool insert is durable.
- Deliver each run in sequence order and acknowledge `mission.started` before
  later events for that run.
- Quarantine invalid complete lines with an error and explicit cursor policy.
- Expose a local dry-run summary.

**Tests:** Cover duplicate input, partial lines, new run files, truncation,
restart from cursor, invalid records, out-of-order spool attempts, and simulated
crashes before and after spool persistence and cursor advancement.

**Exit criteria:** Repeated fixture consumption causes neither event loss nor
duplicate spool records. No real API is called.

### Slice 7: Web shell and raw event persistence

**Recommended model:** GPT-5.6 Luna Xhigh.

**Why:** Schema, authentication boundary, idempotency behavior, and per-event
acknowledgements are already specified and can be fixture-driven.

**Purpose:** Establish the Meal Maestro-style web application and persist only
source events.

**Scope:** Next.js App Router, Neon serverless driver, Drizzle, initial
`mission_runs` and `telemetry_events` tables, Zod contract validation, protected
batch ingest, and idempotent inserts. The response reports accepted, duplicate,
and rejected event IDs so the collector acknowledges individual spool records.
No derived facts or full dashboard are included.

**Tests:** Reject bad credentials and payloads, accept valid batches, return
per-event outcomes, and persist repeated events once. Mock database imports in
unit tests and verify the migration in the configured Neon environment.

**Exit criteria:** A fixture batch is persisted and queried back with an
unambiguous acknowledgement for every event.

### Slice 8: First end-to-end ordnance path

**Recommended model:** GPT-5.6 SOL High.

**Why:** This is the first cross-boundary integration and is expected to expose
incorrect assumptions in mission capture, collector ordering, or API ingest.

**Purpose:** Prove one real shot from DCS to the public web system.

**Scope:** Deliver collector spool records to the API, create the run from
`mission.started`, acknowledge individual events, and display a minimal public
run event list.

**Validation:** Fire a weapon, verify it once in Neon and the page, interrupt
the API or network, fire another weapon, restore connectivity, and verify
eventual delivery without duplication or premature spool deletion.

**Exit criteria:** The complete source-event path works before additional
combat categories are added.

### Slice 9: Participants and sorties

**Recommended model:** GPT-5.6 SOL High.

**Why:** Multiplayer event behavior, stable identity availability, leave/rejoin
semantics, and sortie boundaries are DCS-specific and potentially ambiguous.

**Purpose:** Add human identity and control-period context.

**Scope:** Capture participant enter and leave with MOOSE's multiplayer-safe
event where available, retain stable multiplayer identity plus display-name and
callsign snapshots, and derive sortie start/end. Isolate any server fallback for
missing fields. Do not register generic world assets.

**DCS validation:** One participant enters, leaves, rejoins, changes slot, and
restarts the mission. Verify stable identity, distinct sorties, and no state
leak across runs.

**Exit criteria:** Human-fired events can resolve to a participant and sortie
when DCS supplies the relationship.

### Slice 10: Tracked aircraft instances

**Recommended model:** GPT-5.6 SOL High.

**Why:** Correct incarnation identity and the distinction between re-entry,
replacement, scripted despawn, and combat loss are core domain semantics.

**Purpose:** Register only the aircraft that version one intentionally covers.

**Scope:**

- Treat each tracked aircraft incarnation as one asset instance.
- Register configured blue player aircraft when mission initialization or a
  confirmed lifecycle event first observes the incarnation.
- Register every aircraft unit in each red package through the package
  `SPAWN` callback; one callback can now contain 1–4 unit incarnations.
- Increment instance identity when a slot or bandit name is reused for a new
  incarnation; never use the DCS name alone as the asset key.
- Emit `asset.despawned` before an intentional scripted bandit removal so it is
  not charged as a combat loss.
- Associate `ordnance.fired` only with these tracked instances.

**Tests:** Cover repeated bandit names, player re-entry without a new aircraft,
a confirmed player-aircraft replacement, and scripted despawn versus loss.

**Exit criteria:** Every in-scope shot and loss can resolve to one tracked
aircraft incarnation. Ground, ship, static, and unrelated aircraft discovery is
not required.

### Slice 11: Valuation catalogue and research data

**Recommended model:** GPT-5.6 Luna Xhigh, with human review of selected values.

**Why:** Inventory and source collection are structured, mechanical work once
the tracked loadouts and catalogue shape are fixed.

**Purpose:** Introduce versioned estimated USD values without coupling them to
capture.

**Scope:** Inventory the configured aircraft and every discrete ordnance type in
their configured mission loadouts, research one value per supported type,
create catalogue tables or seed data, retain source notes, and leave unknown
types unpriced.

**Tests:** A known item resolves to one value, an unknown item remains unpriced,
and a new catalogue does not alter an existing run's catalogue.

**Exit criteria:** Catalogue versions can change without changing historical
cost entries.

### Slice 12: Ordnance expenditure and participant drilldown

**Recommended model:** GPT-5.6 Luna Xhigh.

**Why:** This is a deterministic projection from `ordnance.fired`, catalogue
lookups, and already-defined partial-total rules.

**Purpose:** Turn `ordnance.fired` into the first cost metric.

**Scope:** Derive one expenditure per firing, select the run's catalogue value,
record the selected value and catalogue version, group by participant, aircraft,
and coalition, and add a minimal drilldown.

**Tests:** Two AIM-120C and one AIM-9X produce three expenditures and the correct
known subtotal; a miss still costs the weapon; an unknown value remains null,
increments the unpriced count, and marks the displayed total partial; replay
does not double cost.

**Exit criteria:** The dashboard can explain which participant fired what, the
known subtotal, and any unpriced remainder.

### Slice 13: Aircraft losses and deduplicated loss costs

**Recommended model:** GPT-5.6 SOL High.

**Why:** Several DCS loss signals must be reconciled without merging separate
incarnations or charging intentional despawns.

**Purpose:** Charge one replacement cost for one tracked aircraft loss.

**Scope:** Capture `Dead`, `Crash`, `PilotDead`, `UnitLost`, and ejection where
available; correlate signals to a tracked incarnation; derive one `asset.lost`;
charge even after ejection; and keep pilot outcomes separate. Intentional
`asset.despawned` is not a loss.

**Tests:** Dead plus Crash plus UnitLost gives one charge; ejection plus later
destruction still gives one charge; repeated names across incarnations do not
suppress later losses; intentional bandit despawn gives no charge.

**DCS validation:** Eject, crash, destroy, and script-despawn tracked aircraft.
Inspect source events and totals without breaking normal respawn behavior.

**Exit criteria:** One lost tracked aircraft is charged exactly once.

### Slice 14: Hits, kills, assists, and unknown attribution

**Recommended model:** GPT-5.6 SOL High.

**Why:** Killer attribution and assist derivation require explicit interpretation
of incomplete and potentially contradictory DCS events.

**Purpose:** Produce trusted combat effectiveness metrics.

**Scope:** Subscribe to MOOSE `Hit` and `Kill`, emit source hit and
`asset.kill-reported` observations, derive primary kills and qualifying assists,
represent unknown attackers, preserve friendly fire, and never use victim
`Dead` data as the attacker.

**Tests:** Cover explicit killer, qualifying assist, missing killer, repeated
kill/dead signals, friendly fire, and out-of-scope targets without inventing
tracked asset instances.

**DCS validation:** Run participant and AI kills, a multi-hit kill, and a loss
without identifiable attacker. Compare with Tacview and `dcs.log`.

**Exit criteria:** The scoreboard no longer uses the current victim-name
fallback for kill attribution.

### Slice 15: Public dashboard version one

**Recommended model:** GPT-5.6 Luna Xhigh.

**Why:** The metrics, states, visibility, and responsive acceptance criteria are
already fixed. Escalate only if the UI exposes a missing query or domain rule.

**Purpose:** Deliver the agreed usable dashboard.

**Views:** Live coalition standing; coalition kills, losses, known expenditure,
unpriced counts, and cost efficiency; participant drilldown; ordnance by type;
aircraft loss costs; source-event and derived-fact timeline; run history and
status filters; and JSON/CSV export.

**UI constraints:** Public reads, no login, responsive desktop/mobile layout,
visible unknown and unpriced values, partial-total labels, visible update time,
and paginated event queries.

**Tests:** Cover blue spending more while remaining ahead, test-data filtering,
empty/active/aborted/no-result runs, unpriced partial totals, and pagination.

**Exit criteria:** The dashboard answers the original duel example without
manual database queries.

### Slice 16: Replay, run status, and operational reliability

**Recommended model:** GPT-5.6 SOL High.

**Why:** Stale-versus-aborted decisions, replay safety, and independent service
failures require system-level reasoning.

**Purpose:** Make the system trustworthy after interruptions and logic changes.

**Scope:**

- Collector health, last successful delivery, retry/backoff, and spool cleanup.
- API batch/rate limits and metrics for rejected, duplicate, unpriced, and
  unknown events.
- Raw event export and a derived-fact replay command.
- Mark a run completed only from explicit `mission.ended`.
- Use heartbeat age to show a run as stale, not immediately aborted, because an
  API outage is indistinguishable from a stopped mission at the web boundary.
- Mark the previous run aborted when the same producer starts a replacement
  run, or when the validated bridge/collector confirms that no run remains
  active after reconnecting.

**Tests:** Kill the collector, API, database connection, and DCS process
independently. Verify no event loss, no double charging, no false completion,
and correct eventual abort classification.

**Exit criteria:** A damaged projection is rebuildable and interrupted runs are
classified without treating a temporary network outage as a mission abort.

### Slice 17: Stock-sanitized shipping bridge

**Recommended model:** GPT-5.6 SOL High.

**Why:** Even with Slice 3 evidence, this changes the DCS/server boundary and
shipping path, where failures can silently disable mission telemetry.

**Purpose:** Implement the bridge proven in Slice 3.

**Scope:** Implement the selected server hook, DCS-gRPC integration, or other
validated local path; remove mission-side `io`, `os`, and `lfs` requirements;
update shipping packaging for telemetry modules; and test the self-contained
`.miz` with stock sanitization.

**Constraint:** Do not redesign mission event semantics in this slice. If the
Slice 3 assumptions no longer hold, stop and update the bridge decision first.

**Exit criteria:** Mission behavior and telemetry both work on a stock dedicated
server without the development file sink.

### Slice 18: Authentication and access control later

**Recommended model:** GPT-5.6 SOL High when this slice is authorized.

**Why:** Authentication and authorization policy is security-sensitive and must
be designed before any mechanical implementation is delegated.

**Purpose:** Add user accounts only when public exposure creates a real need.

**Scope:** Deferred. Candidate future work includes Neon Auth, admin roles,
private runs, participant views, and protected catalogue editing.

**Constraint:** Do not allow this deferred slice to complicate version-one
ingestion or dashboard work.

### Post-version-one expansion

**Recommended model:** GPT-5.6 SOL High for each new asset category's design;
delegate fixture and adapter implementation to GPT-5.6 Luna Xhigh only after
the lifecycle rules are approved.

Generic discovery of ground units, ships, statics, unrelated aircraft, and
future mission entity types is deliberately deferred. Add those categories only
with explicit use cases, lifecycle rules, fixtures, and DCS validation. The
version-one contract should remain extensible, but version one is not required
to scan or ledger the full DCS world.

## 10. Agent Handoff Protocol

Every handoff should be a standalone task containing the following information.

```text
Objective:
One sentence describing the single slice outcome.

Read first:
Exact docs and source files that establish current behavior.

Allowed files:
The smallest explicit file set the agent may create or change.

Do not touch:
Unrelated modules, generated .miz files, secrets, or later slices.

Contract:
The event/schema/API behavior that must not be invented or changed.

Automated acceptance:
Exact test commands and expected assertions.

DCS acceptance:
Exact mission action, expected log/event output, and environment mode.

Evidence required:
Test output, relevant log excerpt, sample payload, or screenshot.

Stop condition:
Stop after acceptance. Report blockers instead of expanding scope.
```

### Agent sequencing rules

- Use one agent at a time for files that overlap.
- Research agents may work in parallel with code agents only when they touch
  separate output files.
- The contract must land before Lua and TypeScript consumers.
- Pure logic must be tested before DCS integration.
- A DCS integration agent must not also design database tables.
- A web agent must not infer DCS event semantics from UI requirements.
- A database agent must not change the event contract without stopping.
- A price research agent must not make runtime guesses for unknown items.
- Agents must not commit, push, or modify secrets unless explicitly instructed.
- Agents must report files changed and commands run.

### Recommended agent work packages

| Package | Model | Agent profile | Depends on | Output |
|---|---|---|---|---|
| Contract fixtures | SOL High | TypeScript/schema agent | None | Contract and valid/invalid fixtures |
| Lua normalizer | Luna Xhigh | Lua agent | Contract | Pure Lua normalization and tests |
| Shipping bridge research | SOL High | DCS integration agent | Contract | Validated bridge recommendation |
| Run lifecycle | SOL High | MOOSE/Lua agent | Lua normalizer and bridge research | Run context and lifecycle NDJSON |
| MOOSE shot capture | Luna Xhigh | MOOSE agent | Run lifecycle | One real shot in NDJSON |
| Collector spool | SOL High | TypeScript agent | Contract | Crash-safe durable tailer |
| Raw ingest | Luna Xhigh | Next.js/Drizzle agent | Contract | Protected idempotent API and migration |
| First end-to-end path | SOL High | Integration agent | Shot capture, spool, and raw ingest | Validated DCS-to-web event path |
| Participants and sorties | SOL High | MOOSE agent | End-to-end path | Stable participant and sortie context |
| Aircraft roster | SOL High | MOOSE agent | Run lifecycle | Version-one aircraft instances |
| Price research | Luna Xhigh | Research-only agent | Type inventory | Human-reviewed catalogue data |
| Cost projection | Luna Xhigh | Backend agent | Raw ingest and catalogue | Ordnance cost facts and tests |
| Loss reconciliation | SOL High | MOOSE/backend pair | Aircraft roster and catalogue | One aircraft loss charge |
| Kill attribution | SOL High | MOOSE/backend pair | Hit and raw event paths | Kills, assists, unknowns |
| Dashboard | Luna Xhigh | Next.js UI agent | Read queries and fixtures | Public responsive views |
| Operational reliability | SOL High | Integration/backend agent | Complete event path | Replay and interruption recovery |
| Shipping bridge implementation | SOL High | DCS integration agent | Bridge research and stable event path | Stock-sanitized telemetry |

## 11. Validation Gates

No slice is complete because its code compiles. It is complete only when its
applicable gates pass:

### Gate A: Static and unit validation

- Lua parses under Lua 5.1.
- Pure Lua tests pass.
- TypeScript type check passes.
- ESLint/format checks pass.
- Vitest tests pass.
- No secrets appear in source, fixtures, or logs.

### Gate B: Contract validation

- Every emitted event validates against the versioned schema.
- Unknown values remain explicit.
- Replaying fixtures is deterministic.
- Event identity is stable across retries.
- Distinct source events always receive distinct sequences even when their
  content and simulation time are equal.

### Gate C: DCS validation

- Mission starts on the dedicated server.
- `*** MOOSE INCLUDE END ***` appears in the log.
- No new `SCRIPTING ERROR` or `SCRIPTING WARNING` is introduced.
- Existing duel spawn, respawn, leave, and F10 behavior still works.
- The documented manual action produces the expected event count and fields.
- Mission restart creates a new run key.

### Gate D: Persistence validation

- Ingest rejects unauthorized writes.
- Repeated batches are idempotent.
- The dashboard reads the persisted result.
- Network interruption does not lose events.
- Historical run data is unchanged by a later catalogue version.

### Gate E: Review checkpoint

The human owner reviews the evidence and explicitly approves the next slice.
Agents must not chain slices because the next task appears obvious.

## 12. Risks And Guardrails

### DCS event ambiguity

The same real-world occurrence may produce different signals by aircraft,
server version, or event path. Preserve source events and test derived-fact
rules against fixtures and real logs.

### Current kill attribution bug

The existing bandit death handler observes the victim, not necessarily the
attacker. It must not be reused as authoritative kill attribution. Use MOOSE
`Kill` when available and explicitly represent unknown attackers.

### Mission sandbox restrictions

Development file output depends on the de-sanitized environment. A shipping
mission must not depend on that path. Keep the sink behind an adapter, validate
the bridge assumption in Slice 3, and implement only that proven approach in
Slice 17.

### Public write abuse

Public reads are intentional, but public unauthenticated writes would corrupt
the scoreboard. Keep the collector token separate from future user auth and do
not expose it to browser code.

### Neon HTTP transaction limitation

Do not use transaction APIs unsupported by the Meal Maestro Neon HTTP driver.
Treat raw events as accepted source truth and make derived projections
replayable when related writes cannot be atomic.

### Scope creep

Version one covers only the configured blue player aircraft, package-wave red
bandits, and their discrete ordnance. Do not add generic world scanning or new
asset categories merely because DCS exposes them. Broader coverage requires an
explicit post-version-one use case and validation scenario.

### Cost false precision

A single USD value is a practical estimate, not a claim of accounting truth.
Keep the estimate explainable and versioned. Never silently assign a missing
price or change historical totals in place.

## 13. Definition Of Done For Version One

Version one is ready when all of the following are true:

- A DCS mission run creates a new historical run entry.
- A discrete missile/bomb/rocket firing is recorded with participant, asset,
  coalition, weapon, and time where available.
- The same firing survives retry without duplicate cost.
- Ordnance counts and costs are visible by participant and coalition.
- Known cost subtotals and unpriced-item counts are visible without treating an
  unknown value as zero.
- Aircraft crash/destruction creates one aircraft cost even after ejection.
- Repeated DCS loss signals do not multiply the cost.
- Primary kills, assists, and unknown attribution are distinct.
- Live standing is visible without stopping the mission or preventing respawn.
- Test, active, completed, and aborted runs are distinguishable.
- Raw source events and derived facts can be exported or replayed.
- Public reads work without user authentication.
- Writes require the collector credential.
- The local collector recovers from network/API interruption.
- The dashboard works on desktop and mobile.
- Existing duel-dynamic behavior remains intact.
- Only the configured player aircraft, package-wave bandits, and their discrete
  ordnance are required to appear in the version-one ledger.
- Stock-sanitized shipping behavior and telemetry are validated through the
  bridge proven in Slice 3.

## 14. First Authorized Implementation Task

After this plan is approved, the first coding task should be Slice 1 only:

> Define `telemetry-event-v1` and its fixtures. Do not touch DCS mission Lua,
> the collector, the web application, database migrations, or the UI.

The Slice 1 agent must stop after contract tests pass and return the exact
fixtures that Slice 2 and Slice 6 will consume.

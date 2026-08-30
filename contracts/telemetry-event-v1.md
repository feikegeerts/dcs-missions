# Telemetry Source Event Contract Version 1

This document and [`telemetry-event-v1.schema.json`](telemetry-event-v1.schema.json)
define the version-one wire contract between the DCS mission telemetry producer,
the local collector, and the ingestion API. The JSON Schema is normative for
structure. This document is normative for identity, ordering, batching, and
compatibility rules that JSON Schema cannot express.

The domain vocabulary in [`../CONTEXT.md`](../CONTEXT.md) is authoritative.
Every value described here is a **Source Event** observation. A producer MUST
NOT emit a canonical loss, kill, assist, expenditure, or cost as a source event;
those are replayable **Derived Facts** owned by the web system.

## Version and compatibility

- `schema_version` is the integer `1`.
- `source` is `moose-mission` in version one.
- Producers MUST emit every envelope field, including fields whose value is
  `null` or an explicit unknown reference.
- Consumers MUST reject an unsupported `schema_version` rather than guessing a
  compatible shape.
- Version-one objects are closed except for `payload`: unknown envelope or
  reference properties are invalid. Event-specific source observations may be
  retained in `payload` without changing the envelope.
- A change that removes or renames a field, changes its meaning, makes a valid
  value invalid, or changes identity or ordering rules requires a new schema
  version. Adding a new optional `payload` property does not.

## Missing, unknown, and not applicable

The three states are distinct:

| State | Encoding | Meaning |
|---|---|---|
| Missing | Property omitted | Invalid producer output; reject it |
| Unknown | Reference object with `status: "unknown"`, or coalition `"unknown"` | The role applies, but the source could not identify the value |
| Not applicable | `null` | The role does not apply to this event type |

For example, an `asset.kill-reported` event whose attacker is not reported uses
an unknown `initiator`; it does not use `null` and does not invent `Player`. A
`mission.heartbeat` has no initiator, so `initiator` is `null`.

Nullable descriptive fields inside a known or unknown reference mean that the
source did not provide that snapshot attribute. They do not change whether the
referenced entity itself is known.

## Event envelope

| Field | Type | Rule |
|---|---|---|
| `schema_version` | integer | Exactly `1` |
| `event_id` | string | Identity format defined below |
| `source` | string | Exactly `moose-mission` |
| `producer_id` | token | Stable identifier for one producer installation |
| `source_version` | string | Mission/telemetry producer version |
| `run_key` | token | Collision-resistant producer-side Mission Run key |
| `event_sequence` | integer | Monotonic sequence in `[1, 2^53 - 1]` |
| `event_type` | enum | One canonical Source Event name |
| `sim_time` | number | Non-negative DCS model time in seconds |
| `wall_time` | RFC 3339 string or `null` | Producer wall time when available |
| `initiator` | actor reference or `null` | Actor that initiated the observation |
| `target` | actor reference or `null` | Actor against which the observation occurred |
| `participant` | participant reference or `null` | Human Participant associated with the observation |
| `asset` | asset reference or `null` | Subject Asset Instance; for firing this is the firing aircraft |
| `weapon` | weapon reference or `null` | Discrete ordnance involved in the observation |
| `coalition` | coalition or `null` | Initiator coalition, or subject asset coalition when there is no initiator |
| `location` | location reference or `null` | Observation position; shot origin or subject position |
| `payload` | object | Source-specific observations not promoted into the envelope |

Tokens are 1-128 ASCII letters, digits, dots, underscores, or hyphens, start
with a letter or digit, and contain no colons. This restriction makes event IDs
unambiguous without escaping. A producer installation MUST retain its
`producer_id` across Mission Runs. Run-key generation is a producer concern but
MUST be collision-resistant; simulation time alone is not sufficient.

`event_sequence` is capped at `2^53 - 1` so Lua 5.1 numbers and JavaScript
numbers represent every permitted sequence exactly.

## Event identity and ordering

The producer owns source-event identity. For an event with sequence `N`:

```text
event_id = producer_id + ":" + run_key + ":" + base-10(N)
```

The decimal sequence has no leading zero. For example:

```text
dcs-server-alpha:run-20260830T120000Z-a1b2c3:2
```

The following rules are mandatory:

1. Sequence `1` is exactly one `mission.started` event.
2. Each later captured Source Event increments the sequence by one. Producers
   MUST NOT reuse or skip a sequence after they have chosen to emit an event.
3. An event is assigned its sequence and `event_id` once. File, collector, and
   HTTP retries preserve the complete event unchanged.
4. Event content, DCS/MOOSE event IDs, simulation time, and wall time are not
   occurrence identities.
5. Two real observations with identical content and time still receive distinct
   consecutive sequences and event IDs.
6. A collector retains producer order within a Mission Run and does not
   acknowledge or deliver an event from that run before `mission.started`.
7. Consumers deduplicate retries by `event_id`. They also enforce uniqueness of
   `(producer_id, run_key, event_sequence)` and verify that it agrees with the
   event ID.
8. Repeated DCS loss signals remain distinct Source Events. Event Deduplication
   happens only while deriving one canonical fact.

Lua producers MUST use an explicit JSON-null sentinel or equivalent serializer
support. A Lua `nil` table value that silently omits a required property does not
encode `null` and produces an invalid event.

## References

All references are closed objects and must match the JSON Schema exactly.

### Actor

An actor is a Participant or aircraft observed in an initiator/target role. A
known Participant actor has a `participant_id`. A known aircraft actor has at
least one of `asset_key`, `dcs_name`, or `dcs_type`; it need not be a tracked
Asset Instance merely because DCS described it. This preserves observations of
out-of-scope targets without expanding the Tracked Asset Scope.

An unknown actor uses `kind: "unknown"`, a reason of `not-reported` or
`unresolved`, null stable IDs, and any descriptive labels that were actually
reported.

### Participant

A known Participant reference has the stable multiplayer `participant_id` plus
historical display-name and callsign snapshots when supplied. When a human is
observed but the stable identity is unavailable, the reference is unknown with
reason `stable-identity-unavailable`; a display name does not become a stable
identity.

### Asset

A known asset reference identifies one aircraft incarnation with `asset_key`.
DCS name reuse does not reuse this key. Before incarnation identity can be
resolved, an applicable asset role uses an unknown asset reference with reason
`instance-identity-unavailable` or `unresolved` and retains observed DCS labels.
An out-of-scope aircraft is not registered as an Asset Instance.

### Weapon

A known weapon reference has its runtime canonical DCS type and a category of
`missile`, `bomb`, `rocket`, `other-discrete`, or `unknown`. `unknown` category
means the discrete item was observed but not classified; it does not make the
weapon type unknown. If the runtime type itself is absent or unresolved, use an
unknown weapon reference. Machine-gun streams are outside version one.

### Coalition and location

Coalition is `blue`, `red`, `neutral`, or `unknown`. Numeric DCS coalition IDs
never appear on the wire. A known location uses DCS local Cartesian coordinates
`x`, `y`, and `z` with `coordinate_system: "dcs-local"`. An applicable but
unavailable location is an unknown location reference.

## Event taxonomy and roles

`asset` is the subject of `asset.*` and `pilot.*` observations. For
`ordnance.fired`, it is the firing aircraft. `participant` is the associated
human, when applicable; it is never a placeholder for AI.

| Event type | Required applicable roles | Required payload fields |
|---|---|---|
| `mission.started` | No entity roles; sequence `1` | `mission_name`, `mission_version`, `map_name`, `run_classification` |
| `mission.ended` | No entity roles | `reason: "mission-end-observed"` |
| `mission.heartbeat` | No entity roles | None |
| `participant.entered` | Participant, asset, coalition, location | None |
| `participant.left` | Participant, asset, coalition, location | None |
| `asset.spawned` | Asset, coalition, location | None |
| `asset.despawned` | Asset, coalition, location | `reason: "intentional"` or `"unknown"` |
| `ordnance.fired` | Initiator, asset, weapon, coalition, location | None |
| `asset.hit` | Initiator, target, subject asset, coalition, location | None |
| `asset.kill-reported` | Initiator, target, subject asset, coalition, location | None |
| `asset.dead` | Subject asset, coalition, location | None |
| `asset.crashed` | Subject asset, coalition, location | None |
| `pilot.dead` | Subject asset, coalition, location | None |
| `pilot.ejected` | Subject asset, coalition, location | None |

An applicable role may be a structurally valid unknown reference. A role marked
as having no entity role is `null`. `weapon` may be `null` for hit/kill reports
that do not contain a weapon. Loss observations do not carry an attacker:
attacker attribution comes from `asset.kill-reported` and hit history, not from
the victim's dead/crash event.

`run_classification` is `test` or `historical`; it is independent of Mission Run
Status. Catalogue assignment is backend projection state, not a mission-emitted
source observation.

## Batch contract

The ingestion wire request is the `telemetry_batch_v1` definition at JSON
Pointer `#/$defs/telemetry_batch_v1`:

```json
{
  "batch_schema_version": 1,
  "events": []
}
```

Batch rules:

- A batch contains 1-100 events and is at most 1,048,576 bytes of UTF-8 JSON,
  including the envelope. The measured value is the final uncompressed request
  body; serializer whitespace and multi-byte characters count as transmitted.
- One batch contains events from exactly one `producer_id` and `run_key`.
- Events are a contiguous sequence in strictly increasing `event_sequence`
  order with no gap, duplicate sequence, or duplicate `event_id` inside the
  batch.
- A batch need not start at sequence `1`, but the collector MUST deliver and
  receive acknowledgement for `mission.started` and every earlier sequence
  before delivering a later batch for that run. A collector buffers a later
  sequence until the missing sequence is available; it does not skip the gap.
- Retrying an HTTP request preserves every event unchanged. The API reports an
  outcome for each `event_id`; a duplicate outcome is a successful idempotent
  acknowledgement, not a new Source Event.
- Transport compression does not change the uncompressed byte limit.

The byte limit, same-run rule, ordering rule, and event-ID consistency require
application checks in addition to JSON Schema validation.

## Fixtures and validation

Files under `fixtures/valid/` are one ordered Mission Run stream. In particular,
the two ordnance fixtures intentionally have equal event content and simulation
time except for identity fields. Files under `fixtures/invalid/` each violate a
structural contract rule. Files under `fixtures/invalid-semantic/` are
structurally valid JSON Schema instances that violate identity, ordering, or
batching rules requiring application-level validation.

Run the contract gate from the repository root:

```powershell
npm --prefix contracts run check
```

# Slice 18.5: earlier automatic-delivery notes (superseded)

The 2026-09-05 notes-only proposal was superseded on 2026-09-07 when the owner
approved incorporating the reviewed near-live architecture into the slices.

Use [Near-live delivery implementation plan](slice-18-5-near-live-plan.md) for
scope, dependencies, operational decisions, evidence distinctions, and tests.
The [master slice plan](../telemetry-implementation-plan.md) assigns the
correctness prerequisites to Slice 16, transport hardening to Slice 17, and
automatic collector delivery/browser refresh to Slice 18.5. Slice 18 user
authentication remains deferred and is not a dependency.

Corrections to the old notes:

- Production Slice 17 queue/hook/packaging now exist with offline evidence and
  a partial stock-server live pass through local collection. Full player/combat
  and API delivery acceptance is still outstanding.
- Shipping embeds telemetry; it does not depend on mission-side file access.
- Capture is not instant durable disk persistence: events first enter mission
  RAM, then the hook spools them. Hard termination can lose that unspooled tail.
- The collector will be a persistent process with independent collection and
  delivery scheduling, not a serial collect-then-wait-for-HTTP loop.
- Collection must not wait for a stable file or `mission.ended`.
- Polling/refresh defaults and all-backlog delivery are now proposed explicitly;
  real service provisioning and live/API operations remain owner-gated.

No mission HTTP, hook subprocess delivery, embedded credential, new IPC, or
shipping de-sanitization is authorized by either document. Automatic collection
and browser refresh are **planned, not implemented**.

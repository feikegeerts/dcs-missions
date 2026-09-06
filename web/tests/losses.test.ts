import { describe, expect, it } from "vitest";

import {
  aggregateAssetLosts,
  currentOrdnanceAssignment,
  reconcileAssetLosts,
} from "../src/telemetry/losses";
import type { TelemetryEvent } from "../src/telemetry/types";

const PRODUCER = "dcs-server-alpha";
const RUN = "run-slice13-acceptance";
const ASSIGNMENT = currentOrdnanceAssignment();

function event(options: {
  sequence: number;
  eventType: string;
  assetKey?: string;
  dcsType?: string | null;
  dcsName?: string;
  payload?: Record<string, unknown>;
}): TelemetryEvent {
  return {
    schema_version: 1,
    event_id: `${PRODUCER}:${RUN}:${options.sequence}`,
    source: "moose-mission",
    producer_id: PRODUCER,
    source_version: "duel-dynamic-telemetry-v1",
    run_key: RUN,
    event_sequence: options.sequence,
    event_type: options.eventType,
    sim_time: options.sequence * 10,
    wall_time: "2026-09-05T12:00:00Z",
    initiator: null,
    target: null,
    participant: null,
    asset: {
      status: "known",
      kind: "aircraft",
      asset_key: options.assetKey ?? "aerial-1.u1.g1",
      dcs_name: options.dcsName ?? "Aerial-1-1",
      dcs_type:
        options.dcsType === undefined ? "FA-18C_hornet" : options.dcsType,
      coalition: "blue",
    },
    weapon: null,
    coalition: "blue",
    location: { status: "known", coordinate_system: "dcs-local" },
    payload: options.payload ?? {},
  };
}

describe("aircraft loss reconciliation", () => {
  it("reconciles dead, crash, and repeated dead signals into one charge", () => {
    const events = [
      event({ sequence: 1, eventType: "asset.dead" }),
      event({ sequence: 2, eventType: "asset.crashed" }),
      event({ sequence: 3, eventType: "asset.dead" }),
    ];

    const losses = reconcileAssetLosts(events, ASSIGNMENT);

    expect(losses).toHaveLength(1);
    expect(losses[0]).toMatchObject({
      producerId: PRODUCER,
      runKey: RUN,
      assetKey: "aerial-1.u1.g1",
      dcsType: "FA-18C_hornet",
      coalition: "blue",
      catalogue: ASSIGNMENT.catalogue,
      catalogueVersion: ASSIGNMENT.version,
      unitCostCents: 2_900_000_000,
      sourceEventIds: events.map((source) => source.event_id),
    });
    expect(aggregateAssetLosts(losses)).toEqual({
      lossCount: 1,
      knownSubtotalCents: 2_900_000_000,
      unpricedCount: 0,
      partial: false,
    });
  });

  it("does not let ejection cancel a later aircraft loss", () => {
    const losses = reconcileAssetLosts(
      [
        event({ sequence: 1, eventType: "pilot.ejected" }),
        event({ sequence: 2, eventType: "asset.dead" }),
        event({ sequence: 3, eventType: "asset.crashed" }),
      ],
      ASSIGNMENT,
    );

    expect(losses).toHaveLength(1);
    expect(losses[0]?.sourceEventIds).toEqual([
      `${PRODUCER}:${RUN}:2`,
      `${PRODUCER}:${RUN}:3`,
    ]);
    expect(aggregateAssetLosts(losses).knownSubtotalCents).toBe(2_900_000_000);
  });

  it("keeps same-named aircraft incarnations distinct by asset key", () => {
    const losses = reconcileAssetLosts(
      [
        event({
          sequence: 1,
          eventType: "asset.dead",
          assetKey: "aerial-1.u1.g1",
          dcsName: "Aerial-1-1",
        }),
        event({
          sequence: 2,
          eventType: "asset.dead",
          assetKey: "aerial-1.u1.g2",
          dcsName: "Aerial-1-1",
        }),
      ],
      ASSIGNMENT,
    );

    expect(losses.map((loss) => loss.assetKey)).toEqual([
      "aerial-1.u1.g1",
      "aerial-1.u1.g2",
    ]);
    expect(new Set(losses.map((loss) => loss.factId)).size).toBe(2);
    expect(aggregateAssetLosts(losses)).toMatchObject({
      lossCount: 2,
      knownSubtotalCents: 5_800_000_000,
      partial: false,
    });
  });

  it("never treats intentional or plain despawns as losses", () => {
    const losses = reconcileAssetLosts(
      [
        event({
          sequence: 1,
          eventType: "asset.despawned",
          payload: { reason: "intentional" },
        }),
        event({ sequence: 2, eventType: "asset.despawned" }),
      ],
      ASSIGNMENT,
    );

    expect(losses).toEqual([]);
    expect(aggregateAssetLosts(losses)).toEqual({
      lossCount: 0,
      knownSubtotalCents: 0,
      unpricedCount: 0,
      partial: false,
    });
  });

  it("keeps unknown aircraft types unpriced and marks totals partial", () => {
    const losses = reconcileAssetLosts(
      [
        event({
          sequence: 1,
          eventType: "asset.dead",
          dcsType: "FUTURE_AIRCRAFT_X",
        }),
      ],
      ASSIGNMENT,
    );

    expect(losses).toHaveLength(1);
    expect(losses[0]?.unitCostCents).toBeNull();
    expect(aggregateAssetLosts(losses)).toEqual({
      lossCount: 1,
      knownSubtotalCents: 0,
      unpricedCount: 1,
      partial: true,
    });
  });

  it("replays the same ordered stream with identical identities and totals", () => {
    const events = [
      event({ sequence: 1, eventType: "asset.dead" }),
      event({ sequence: 2, eventType: "asset.crashed" }),
      event({
        sequence: 3,
        eventType: "asset.dead",
        assetKey: "aerial-1.u1.g2",
        dcsType: "F-16C_50",
      }),
    ];

    const first = reconcileAssetLosts(events, ASSIGNMENT);
    const replay = reconcileAssetLosts(events, ASSIGNMENT);

    expect(replay.map((loss) => loss.factId)).toEqual(
      first.map((loss) => loss.factId),
    );
    expect(aggregateAssetLosts(replay)).toEqual(aggregateAssetLosts(first));
  });

  it("yields an identical fact id regardless of source-event arrival order", () => {
    const events = [
      event({ sequence: 1, eventType: "asset.dead" }),
      event({ sequence: 2, eventType: "asset.crashed" }),
    ];
    const forward = reconcileAssetLosts(events, ASSIGNMENT);
    const reversed = reconcileAssetLosts([...events].reverse(), ASSIGNMENT);

    expect(reversed.map((loss) => loss.factId)).toEqual(
      forward.map((loss) => loss.factId),
    );
    expect(reversed[0]?.sourceEventIds).toEqual([
      `${PRODUCER}:${RUN}:1`,
      `${PRODUCER}:${RUN}:2`,
    ]);
  });

  it("projects no facts for an unassigned run", () => {
    expect(
      reconcileAssetLosts(
        [event({ sequence: 1, eventType: "asset.dead" })],
        null,
      ),
    ).toEqual([]);
  });

  it("keeps pilot death separate from aircraft loss", () => {
    expect(
      reconcileAssetLosts(
        [event({ sequence: 1, eventType: "pilot.dead" })],
        ASSIGNMENT,
      ),
    ).toEqual([]);
  });
});

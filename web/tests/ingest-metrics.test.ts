import { describe, expect, it } from "vitest";

import { currentOrdnanceAssignment } from "../src/telemetry/expenditures";
import {
  computeIngestMetrics,
  UNMODELED_EVENT_TYPES,
} from "../src/telemetry/ingest-metrics";
import type { TelemetryEvent } from "../src/telemetry/types";

const ASSIGNMENT = currentOrdnanceAssignment();

function event(sequence: number, eventType: string): TelemetryEvent {
  return {
    schema_version: 1,
    event_id: `dcs-server-alpha:run-ingest-metrics:${sequence}`,
    source: "moose-mission",
    producer_id: "dcs-server-alpha",
    source_version: "duel-dynamic-telemetry-v1",
    run_key: "run-ingest-metrics",
    event_sequence: sequence,
    event_type: eventType,
    sim_time: sequence * 10,
    wall_time: "2026-09-06T12:00:00Z",
    initiator: null,
    target: null,
    participant: null,
    asset: null,
    weapon: null,
    coalition: null,
    location: null,
    payload: {},
  };
}

function firedEvent(
  sequence: number,
  weapon:
    | {
        status: "unknown";
        reason: "type-not-reported" | "unresolved";
        dcs_type: null;
        display_name: string | null;
        category: "unknown";
      }
    | {
        status: "known";
        dcs_type: string;
        display_name: string;
        category: "missile";
      },
): TelemetryEvent {
  return {
    ...event(sequence, "ordnance.fired"),
    initiator: {
      status: "known",
      kind: "aircraft",
      participant_id: "ucid-viper-1",
      asset_key: "aerial-1.u1.g1",
      display_name: "Viper",
      callsign: "Aerial 1-1",
      dcs_name: "Aerial-1-1",
      dcs_type: "FA-18C_hornet",
      coalition: "blue",
    },
    asset: {
      status: "known",
      kind: "aircraft",
      asset_key: "aerial-1.u1.g1",
      dcs_name: "Aerial-1-1",
      dcs_type: "FA-18C_hornet",
      coalition: "blue",
    },
    weapon,
    coalition: "blue",
    location: {
      status: "known",
      coordinate_system: "dcs-local",
      x: 1,
      y: 2,
      z: 3,
    },
  };
}

function unmodeledEvent(sequence: number, eventType: string): TelemetryEvent {
  const value = event(sequence, eventType);
  if (eventType === "mission.heartbeat") {
    return value;
  }
  value.asset = {
    status: "known",
    kind: "aircraft",
    asset_key: "aerial-1.u1.g1",
    dcs_name: "Aerial-1-1",
    dcs_type: "FA-18C_hornet",
    coalition: "blue",
  };
  value.coalition = "blue";
  value.location = {
    status: "known",
    coordinate_system: "dcs-local",
    x: 1,
    y: 2,
    z: 3,
  };
  if (eventType === "asset.despawned") {
    value.payload = { reason: "intentional" };
  }
  return value;
}

describe("ingest metrics", () => {
  it("reports zero for an all-modeled priced batch", () => {
    const events = [
      {
        ...event(1, "mission.started"),
        payload: {
          mission_name: "duel-dynamic",
          mission_version: "1",
          map_name: "Caucasus",
          run_classification: "test",
        },
      },
      firedEvent(2, {
        status: "known",
        dcs_type: "AIM_120C",
        display_name: "AIM-120C",
        category: "missile",
      }),
      {
        ...event(3, "mission.ended"),
        payload: { reason: "mission-end-observed" },
      },
    ];

    expect(
      computeIngestMetrics(
        events,
        ["accepted", "accepted", "accepted"],
        ASSIGNMENT,
      ),
    ).toEqual({ unpriced: 0, unknown: 0 });
  });

  it("counts every accepted unmodeled v1 event type", () => {
    const events = [...UNMODELED_EVENT_TYPES].map((eventType, index) =>
      unmodeledEvent(index + 10, eventType),
    );

    expect(
      computeIngestMetrics(
        events,
        events.map(() => "accepted"),
        ASSIGNMENT,
      ),
    ).toEqual({ unpriced: 0, unknown: 5 });
  });

  it("counts unknown and uncatalogued weapons but not priced weapons", () => {
    const unknownWeapon = firedEvent(10, {
      status: "unknown",
      reason: "type-not-reported",
      dcs_type: null,
      display_name: null,
      category: "unknown",
    });
    const uncataloguedWeapon = firedEvent(11, {
      status: "known",
      dcs_type: "FUTURE_MISSILE_X",
      display_name: "Future missile",
      category: "missile",
    });
    const pricedWeapon = firedEvent(12, {
      status: "known",
      dcs_type: "AIM_120C",
      display_name: "AIM-120C",
      category: "missile",
    });

    expect(
      computeIngestMetrics([unknownWeapon], ["accepted"], ASSIGNMENT),
    ).toEqual({ unpriced: 1, unknown: 0 });
    expect(
      computeIngestMetrics([uncataloguedWeapon], ["accepted"], ASSIGNMENT),
    ).toEqual({ unpriced: 1, unknown: 0 });
    expect(
      computeIngestMetrics([pricedWeapon], ["accepted"], ASSIGNMENT),
    ).toEqual({ unpriced: 0, unknown: 0 });
  });

  it("gates unpriced counts on catalogue assignment without gating unknowns", () => {
    const events = [
      firedEvent(10, {
        status: "unknown",
        reason: "type-not-reported",
        dcs_type: null,
        display_name: null,
        category: "unknown",
      }),
      unmodeledEvent(11, "mission.heartbeat"),
    ];

    expect(
      computeIngestMetrics(events, ["accepted", "accepted"], null),
    ).toEqual({ unpriced: 0, unknown: 1 });
  });

  it("excludes rejected outcomes and includes duplicate outcomes", () => {
    const events = [
      firedEvent(10, {
        status: "unknown",
        reason: "type-not-reported",
        dcs_type: null,
        display_name: null,
        category: "unknown",
      }),
      unmodeledEvent(11, "mission.heartbeat"),
      firedEvent(12, {
        status: "unknown",
        reason: "type-not-reported",
        dcs_type: null,
        display_name: null,
        category: "unknown",
      }),
      unmodeledEvent(13, "pilot.ejected"),
    ];

    expect(
      computeIngestMetrics(
        events,
        ["rejected", "rejected", "duplicate", "duplicate"],
        ASSIGNMENT,
      ),
    ).toEqual({ unpriced: 1, unknown: 1 });
  });

  it("partitions the frozen v1 taxonomy without overlap or omission", () => {
    const v1EventTypes = new Set([
      "mission.started",
      "mission.ended",
      "mission.heartbeat",
      "participant.entered",
      "participant.left",
      "asset.spawned",
      "asset.despawned",
      "ordnance.fired",
      "asset.hit",
      "asset.kill-reported",
      "asset.dead",
      "asset.crashed",
      "pilot.dead",
      "pilot.ejected",
    ]);
    const modeledEventTypes = new Set([
      "mission.started",
      "mission.ended",
      "ordnance.fired",
      "asset.hit",
      "asset.kill-reported",
      "asset.dead",
      "asset.crashed",
      "participant.entered",
      "participant.left",
    ]);
    const overlap = [...UNMODELED_EVENT_TYPES].filter((eventType) =>
      modeledEventTypes.has(eventType),
    );
    const partition = new Set([...UNMODELED_EVENT_TYPES, ...modeledEventTypes]);

    expect(overlap).toEqual([]);
    expect([...partition].sort()).toEqual([...v1EventTypes].sort());
  });
});

import { describe, expect, it } from "vitest";

import {
  eventsToCsv,
  eventsToNdjson,
  expendituresToCsv,
} from "../src/telemetry/export";
import type { TelemetryEvent } from "../src/telemetry/types";

function event(sequence: number): TelemetryEvent {
  return {
    schema_version: 1,
    event_id: `mission-server:run-export:${sequence}`,
    source: "moose-mission",
    producer_id: "mission-server",
    source_version: "telemetry-v1",
    run_key: "run-export",
    event_sequence: sequence,
    event_type: "mission.heartbeat",
    sim_time: sequence * 10,
    wall_time: null,
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

describe("telemetry NDJSON export", () => {
  it("preserves event order and round-trips one event per line", () => {
    const events = [event(2), event(1)];

    const ndjson = eventsToNdjson(events);
    const lines = ndjson.trimEnd().split("\n");

    expect(ndjson.endsWith("\n")).toBe(true);
    expect(lines.map((line) => JSON.parse(line))).toEqual(events);
  });

  it("returns an empty string for an empty input", () => {
    expect(eventsToNdjson([])).toBe("");
  });

  it("round-trips a full contract-shaped event exactly", () => {
    const fullEvent: TelemetryEvent = {
      ...event(7),
      event_type: "ordnance.fired",
      sim_time: 125.75,
      wall_time: "2026-09-06T20:15:30.000Z",
      initiator: {
        status: "known",
        kind: "aircraft",
        participant_id: "ucid-viper-1",
        asset_key: "aerial-1.u1.g1",
        dcs_name: "Aerial-1-1",
        dcs_type: "FA-18C_hornet",
        coalition: "blue",
      },
      target: { status: "unknown", reason: "not-observed" },
      participant: {
        status: "known",
        participant_id: "ucid-viper-1",
        display_name: "Viper",
        callsign: "Aerial 1-1",
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
      weapon: {
        status: "known",
        dcs_type: "AIM_120C",
        display_name: "AIM-120C AMRAAM",
        category: "missile",
      },
      coalition: "blue",
      location: { status: "known", x: 1250.5, y: 3400, z: -875.25 },
      payload: { dcs_event_name: "S_EVENT_SHOT", nested: { count: 1 } },
    };

    expect(JSON.parse(eventsToNdjson([fullEvent]).trimEnd())).toEqual(
      fullEvent,
    );
  });
});

describe("telemetry CSV export", () => {
  it("renders events with a header and one row per event", () => {
    expect(
      eventsToCsv([
        {
          eventSequence: 2,
          eventType: "ordnance.fired",
          simTime: 125.5,
          weaponDcsType: "AIM_120C",
          initiatorParticipantId: "ucid-viper-1",
          coalition: "blue",
        },
      ]),
    ).toBe(
      "event_sequence,event_type,sim_time,weapon_dcs_type,initiator_participant_id,coalition\r\n" +
        "2,ordnance.fired,125.5,AIM_120C,ucid-viper-1,blue\r\n",
    );
  });

  it("renders empty cells for unknown values and quotes embedded commas", () => {
    expect(
      eventsToCsv([
        {
          eventSequence: 3,
          eventType: "ordnance.fired",
          simTime: null,
          weaponDcsType: null,
          initiatorParticipantId: null,
          coalition: "blue",
        },
      ]),
    ).toBe(
      "event_sequence,event_type,sim_time,weapon_dcs_type,initiator_participant_id,coalition\r\n" +
        "3,ordnance.fired,,,,blue\r\n",
    );
    expect(
      expendituresToCsv([
        {
          eventSequence: 1,
          participantDisplayName: 'Viper, "actual"',
          participantCallsign: "Aerial 1-1",
          assetKey: "aerial-1.u1.g1",
          aircraftDcsType: "FA-18C_hornet",
          coalition: "blue",
          weaponDisplayName: "AIM-120C AMRAAM",
          weaponDcsType: "AIM_120C",
          unitCostCents: 105000000,
          catalogue: "ordnance",
          catalogueVersion: 1,
        },
      ]).split("\r\n")[1],
    ).toBe(
      '1,"Viper, ""actual""",Aerial 1-1,aerial-1.u1.g1,FA-18C_hornet,blue,AIM-120C AMRAAM,AIM_120C,1050000.00,ordnance,1',
    );
  });

  it("renders unpriced expenditures with an empty amount", () => {
    const [, row] = expendituresToCsv([
      {
        eventSequence: 4,
        participantDisplayName: "Viper",
        participantCallsign: null,
        assetKey: null,
        aircraftDcsType: null,
        coalition: "blue",
        weaponDisplayName: null,
        weaponDcsType: "FUTURE_MISSILE_X",
        unitCostCents: null,
        catalogue: "ordnance",
        catalogueVersion: 1,
      },
    ]).split("\r\n");
    expect(row?.split(",")[8]).toBe("");
  });
});

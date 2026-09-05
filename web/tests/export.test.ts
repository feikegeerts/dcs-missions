import { describe, expect, it } from "vitest";

import { eventsToCsv, expendituresToCsv } from "../src/telemetry/export";

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

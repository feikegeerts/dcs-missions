import { describe, expect, it } from "vitest";

import { ordnanceCatalogueV1 } from "../src/telemetry/catalogue";
import { buildAiCallsigns } from "../src/telemetry/ai-names";
import {
  aggregateByWeapon,
  aggregateExpenditures,
  catalogueForAssignment,
  currentOrdnanceAssignment,
  decimalUsdToCents,
  deriveExpenditure,
  latestParticipantLabels,
  type CatalogueAssignment,
  type ExpenditureProjection,
} from "../src/telemetry/expenditures";
import type { TelemetryEvent } from "../src/telemetry/types";

const ASSIGNMENT: CatalogueAssignment = currentOrdnanceAssignment();
const PRODUCER = "dcs-server-alpha";
const RUN = "run-slice12-acceptance";

function firedEvent(options: {
  sequence: number;
  weaponDcsType: string | null;
  weaponStatus?: string;
  participantId?: string | null;
  displayName?: string | null;
  callsign?: string | null;
  assetKey?: string | null;
  aircraftDcsType?: string | null;
  coalition?: string | null;
  withTarget?: boolean;
}): TelemetryEvent {
  const participantId =
    options.participantId === undefined
      ? "ucid-viper-1"
      : options.participantId;
  const displayName =
    options.displayName === undefined ? "Viper" : options.displayName;
  const callsign =
    options.callsign === undefined ? "Aerial 1-1" : options.callsign;
  const weapon =
    options.weaponDcsType === null
      ? { status: "unknown", reason: "instance-identity-unavailable" }
      : {
          status: options.weaponStatus ?? "known",
          dcs_type: options.weaponDcsType,
          display_name: options.weaponDcsType,
          category: "missile",
        };
  return {
    schema_version: 1,
    event_id: `${PRODUCER}:${RUN}:${options.sequence}`,
    source: "moose-mission",
    producer_id: PRODUCER,
    source_version: "duel-dynamic-telemetry-v1",
    run_key: RUN,
    event_sequence: options.sequence,
    event_type: "ordnance.fired",
    sim_time: options.sequence * 10,
    wall_time: "2026-09-05T12:00:00Z",
    initiator: {
      status: "known",
      kind: "aircraft",
      participant_id: participantId,
      asset_key: options.assetKey ?? "aerial-1.u1.g1",
      display_name: displayName,
      callsign,
      dcs_name: "Aerial-1-1",
      dcs_type: options.aircraftDcsType ?? "FA-18C_hornet",
      coalition: options.coalition ?? "blue",
    },
    target: options.withTarget ? null : null,
    participant: {
      status: "known",
      kind: "participant",
      participant_id: participantId,
      display_name: displayName,
      callsign,
      coalition: options.coalition ?? "blue",
    },
    asset: {
      status: "known",
      kind: "aircraft",
      asset_key: options.assetKey ?? "aerial-1.u1.g1",
      dcs_name: "Aerial-1-1",
      dcs_type: options.aircraftDcsType ?? "FA-18C_hornet",
      coalition: options.coalition ?? "blue",
    },
    weapon,
    coalition: options.coalition ?? "blue",
    location: { status: "known", coordinate_system: "dcs-local" },
    payload: { dcs_event_name: "shot" },
  };
}

function projections(
  events: TelemetryEvent[],
  assignment: CatalogueAssignment | null = ASSIGNMENT,
): ExpenditureProjection[] {
  return events.flatMap((event) => {
    const projection = deriveExpenditure(event, assignment);
    return projection === null ? [] : [projection];
  });
}

describe("ordnance expenditure projection", () => {
  it("prices two AIM-120C and one AIM-9X to the acceptance subtotal", () => {
    const events = [
      firedEvent({ sequence: 1, weaponDcsType: "AIM_120C" }),
      firedEvent({ sequence: 2, weaponDcsType: "AIM_120C" }),
      firedEvent({ sequence: 3, weaponDcsType: "AIM_9X" }),
    ];
    const expenditure = projections(events);
    expect(expenditure).toHaveLength(3);
    expect(expenditure.map((item) => item.unitCostCents)).toEqual([
      105000000, 105000000, 44709300,
    ]);
    const drilldown = aggregateExpenditures(expenditure);
    expect(drilldown.expenditureCount).toBe(3);
    expect(drilldown.knownSubtotalCents).toBe(254709300);
    expect(drilldown.unpricedCount).toBe(0);
    expect(drilldown.partial).toBe(false);
  });

  it("costs a fired weapon even when the shot has no target outcome yet", () => {
    const expenditure = projections([
      firedEvent({ sequence: 1, weaponDcsType: "AIM_120C" }),
    ]);
    expect(expenditure).toHaveLength(1);
    expect(expenditure[0]?.unitCostCents).toBe(105000000);
  });

  it("leaves unknown weapons unpriced and marks totals partial", () => {
    const expenditure = projections([
      firedEvent({ sequence: 1, weaponDcsType: "AIM_120C" }),
      firedEvent({ sequence: 2, weaponDcsType: "FUTURE_MISSILE_X" }),
      firedEvent({ sequence: 3, weaponDcsType: null }),
    ]);
    expect(expenditure).toHaveLength(3);
    expect(expenditure[1]?.unitCostCents).toBeNull();
    expect(expenditure[2]?.unitCostCents).toBeNull();
    const drilldown = aggregateExpenditures(expenditure);
    expect(drilldown.expenditureCount).toBe(3);
    expect(drilldown.knownSubtotalCents).toBe(105000000);
    expect(drilldown.unpricedCount).toBe(2);
    expect(drilldown.partial).toBe(true);
  });

  it("does not alias legacy long-form weapon keys to catalogue entries", () => {
    const expenditure = projections([
      firedEvent({ sequence: 1, weaponDcsType: "weapons.missiles.AIM_120C" }),
    ]);
    expect(expenditure).toHaveLength(1);
    expect(expenditure[0]?.weaponDcsType).toBe("weapons.missiles.AIM_120C");
    expect(expenditure[0]?.unitCostCents).toBeNull();
  });

  it("projects nothing for unassigned historical runs", () => {
    expect(
      deriveExpenditure(
        firedEvent({ sequence: 1, weaponDcsType: "AIM_120C" }),
        null,
      ),
    ).toBeNull();
  });

  it("projects nothing for non-ordnance events", () => {
    const event = firedEvent({ sequence: 1, weaponDcsType: "AIM_120C" });
    event.event_type = "mission.heartbeat";
    expect(deriveExpenditure(event, ASSIGNMENT)).toBeNull();
  });

  it("pins the catalogue name and version on every expenditure", () => {
    const expenditure = projections([
      firedEvent({ sequence: 1, weaponDcsType: "AIM_120C" }),
    ]);
    expect(expenditure[0]).toMatchObject({
      catalogue: ordnanceCatalogueV1.catalogue,
      catalogueVersion: ordnanceCatalogueV1.version,
    });
  });

  it("rejects unknown catalogue pins instead of mispricing", () => {
    const event = firedEvent({ sequence: 1, weaponDcsType: "AIM_120C" });
    expect(
      deriveExpenditure(event, { catalogue: "ordnance", version: 999 }),
    ).toBeNull();
    expect(catalogueForAssignment(null)).toBeNull();
  });
});

describe("expenditure drilldown", () => {
  it("uses the deterministic AI callsign when no participant is known", () => {
    const expenditure = projections([
      firedEvent({
        sequence: 1,
        weaponDcsType: "AIM_120C",
        participantId: null,
        displayName: null,
        callsign: null,
        assetKey: "bandit-1.u1.g1",
        aircraftDcsType: "Su-33",
        coalition: "red",
      }),
    ]);
    const expected = buildAiCallsigns(RUN, ["bandit-1.u1.g1"]).get(
      "bandit-1.u1.g1",
    );

    const drilldown = aggregateExpenditures(expenditure);

    expect(drilldown.groups[0]?.participantDisplayName).toBe(expected);
    expect(drilldown.groups[0]?.participantDisplayName).not.toBe(
      "Unknown shooter",
    );
  });

  it("groups by participant, incarnation, airframe, and coalition", () => {
    const expenditure = projections([
      firedEvent({
        sequence: 1,
        weaponDcsType: "AIM_120C",
        assetKey: "aerial-1.u1.g1",
      }),
      firedEvent({
        sequence: 2,
        weaponDcsType: "AIM_120C",
        assetKey: "aerial-1.u1.g2",
      }),
      firedEvent({
        sequence: 3,
        weaponDcsType: "AIM_9X",
        participantId: "ucid-bandit-ops",
        displayName: "BanditOps",
        assetKey: "bandit-1.u1.g1",
        aircraftDcsType: "Su-33",
        coalition: "red",
      }),
    ]);
    const drilldown = aggregateExpenditures(expenditure);
    expect(drilldown.groups).toHaveLength(3);
    expect(
      drilldown.groups.map((group) => [
        group.assetKey,
        group.aircraftDcsType,
        group.coalition,
        group.expenditureCount,
        group.knownSubtotalCents,
      ]),
    ).toEqual([
      ["aerial-1.u1.g1", "FA-18C_hornet", "blue", 1, 105000000],
      ["aerial-1.u1.g2", "FA-18C_hornet", "blue", 1, 105000000],
      ["bandit-1.u1.g1", "Su-33", "red", 1, 44709300],
    ]);
  });

  it("uses the latest participant name while preserving event snapshots", () => {
    const events = [
      firedEvent({
        sequence: 1,
        weaponDcsType: "AIM_120C",
        displayName: "Viper",
        callsign: "Aerial 1-1",
      }),
      firedEvent({
        sequence: 2,
        weaponDcsType: "AIM_120C",
        displayName: "Viper-actual",
        callsign: "Aerial 1-1",
      }),
    ];
    const expenditure = projections(events);
    expect(expenditure[0]?.participantDisplayName).toBe("Viper");
    expect(expenditure[1]?.participantDisplayName).toBe("Viper-actual");
    const labels = latestParticipantLabels(events);
    const drilldown = aggregateExpenditures(expenditure, labels);
    expect(drilldown.groups).toHaveLength(1);
    expect(drilldown.groups[0]?.participantDisplayName).toBe("Viper-actual");
  });
});

describe("ordnance by weapon", () => {
  it("rolls shots up by weapon type with exact subtotals", () => {
    const expenditure = projections([
      firedEvent({ sequence: 1, weaponDcsType: "AIM_120C" }),
      firedEvent({ sequence: 2, weaponDcsType: "AIM_120C" }),
      firedEvent({ sequence: 3, weaponDcsType: "AIM_9X" }),
      firedEvent({ sequence: 4, weaponDcsType: "FUTURE_MISSILE_X" }),
    ]);
    const summary = aggregateByWeapon(expenditure);
    expect(summary.expenditureCount).toBe(4);
    expect(summary.knownSubtotalCents).toBe(254709300);
    expect(summary.unpricedCount).toBe(1);
    expect(summary.partial).toBe(true);
    expect(
      summary.weapons.map((weapon) => [
        weapon.weaponDcsType,
        weapon.expenditureCount,
        weapon.knownSubtotalCents,
        weapon.unpricedCount,
      ]),
    ).toEqual([
      ["AIM_120C", 2, 210000000, 0],
      ["AIM_9X", 1, 44709300, 0],
      ["FUTURE_MISSILE_X", 1, 0, 1],
    ]);
  });

  it("covers blue spending more while remaining ahead", () => {
    const expenditure = projections([
      firedEvent({
        sequence: 1,
        weaponDcsType: "AIM_120C",
        participantId: "ucid-blue-1",
        coalition: "blue",
      }),
      firedEvent({
        sequence: 2,
        weaponDcsType: "AIM_120C",
        participantId: "ucid-blue-1",
        coalition: "blue",
      }),
      firedEvent({
        sequence: 3,
        weaponDcsType: "AIM_9X",
        participantId: "ucid-red-1",
        displayName: "BanditOps",
        coalition: "red",
      }),
    ]);
    const summary = aggregateByWeapon(expenditure);
    expect(summary.expenditureCount).toBe(3);
    // Blue fired the expensive pair; the view must still show both sides.
    expect(summary.knownSubtotalCents).toBe(254709300);
    expect(summary.weapons).toHaveLength(2);
  });
});

describe("expenditure money handling", () => {
  it("converts catalogue decimals to exact cents", () => {
    expect(decimalUsdToCents("1050000")).toBe(105000000);
    expect(decimalUsdToCents("447093.00")).toBe(44709300);
    expect(() => decimalUsdToCents("10.999")).toThrow();
    expect(() => decimalUsdToCents("free")).toThrow();
  });
});

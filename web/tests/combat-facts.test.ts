import { describe, expect, it } from "vitest";

import {
  reconcileAssistAttributions,
  reconcileKillAttributions,
} from "../src/telemetry/combat-facts";
import type { TelemetryEvent } from "../src/telemetry/types";

const PRODUCER = "dcs-server-alpha";
const RUN = "run-combat-facts";
const TARGET = "bandit.u1.g1";
const KILLER = "aerial-1.u1.g1";

function actor(assetKey: string | null, coalition = "blue") {
  return assetKey === null
    ? {
        status: "unknown",
        kind: "unknown",
        asset_key: null,
        dcs_name: null,
        dcs_type: null,
        coalition: "unknown",
      }
    : {
        status: "known",
        kind: "aircraft",
        asset_key: assetKey,
        dcs_name: `${assetKey}-name`,
        dcs_type: "FA-18C_hornet",
        coalition,
      };
}

function target(assetKey: string | null = TARGET) {
  return {
    status: assetKey === null ? "unknown" : "known",
    kind: "aircraft",
    asset_key: assetKey,
    dcs_name: assetKey === null ? null : "Bandit-1-1",
    dcs_type: assetKey === null ? null : "Su-33",
    coalition: "red",
  };
}

function combatEvent(options: {
  sequence: number;
  type: "asset.hit" | "asset.kill-reported" | "asset.dead";
  simTime: number;
  attacker?: string | null;
  target?: string | null;
  idSuffix?: string;
}): TelemetryEvent {
  return {
    schema_version: 1,
    event_id: `${PRODUCER}:${RUN}:${options.sequence}${options.idSuffix ?? ""}`,
    source: "moose-mission",
    producer_id: PRODUCER,
    source_version: "duel-dynamic-telemetry-v1",
    run_key: RUN,
    event_sequence: options.sequence,
    event_type: options.type,
    sim_time: options.simTime,
    wall_time: null,
    initiator: actor(
      options.attacker === undefined ? KILLER : options.attacker,
    ),
    target: target(options.target === undefined ? TARGET : options.target),
    participant: null,
    asset: null,
    weapon:
      options.type === "asset.kill-reported"
        ? { status: "known", dcs_type: "AIM_120C", category: "missile" }
        : null,
    coalition: "blue",
    location: null,
    payload: {},
  };
}

function kill(attacker: string | null = KILLER) {
  return combatEvent({
    sequence: 100,
    type: "asset.kill-reported",
    simTime: 100,
    attacker,
  });
}

function hit(
  simTime: number,
  attacker: string | null = "wingman.u1.g1",
  sequence = 90,
  targetAssetKey: string | null = TARGET,
) {
  return combatEvent({
    sequence,
    type: "asset.hit",
    simTime,
    attacker,
    target: targetAssetKey,
  });
}

describe("combat fact reconciliation", () => {
  it("1. attributes one tracked attacker hit within the window", () => {
    expect(reconcileAssistAttributions([hit(80), kill()])).toHaveLength(1);
  });

  it("2. includes a hit exactly at T_kill", () => {
    expect(reconcileAssistAttributions([hit(100), kill()])).toHaveLength(1);
  });

  it("3. includes a hit exactly at T_kill - 30", () => {
    expect(reconcileAssistAttributions([hit(70), kill()])).toHaveLength(1);
  });

  it("4. excludes a hit just before T_kill - 30", () => {
    expect(reconcileAssistAttributions([hit(69.999), kill()])).toEqual([]);
  });

  it("5. excludes a hit after T_kill", () => {
    expect(reconcileAssistAttributions([hit(100.001), kill()])).toEqual([]);
  });

  it("6. excludes the known primary killer from assists", () => {
    expect(reconcileAssistAttributions([hit(90, KILLER), kill()])).toEqual([]);
  });

  it("7. retains an assist without promoting it when the killer is unknown", () => {
    const events = [hit(90), kill(null)];
    const kills = reconcileKillAttributions(events);
    expect(reconcileAssistAttributions(events)).toHaveLength(1);
    expect(kills).toHaveLength(1);
    expect(kills[0]).toMatchObject({
      killerAssetKey: null,
      killerDcsName: null,
      killerDcsType: null,
      killerCoalition: null,
    });
  });

  it("8. attributes two distinct tracked attackers", () => {
    const assists = reconcileAssistAttributions([
      hit(80, "wingman-1", 80),
      hit(90, "wingman-2", 90),
      kill(),
    ]);
    expect(assists.map((assist) => assist.attackerAssetKey)).toEqual([
      "wingman-1",
      "wingman-2",
    ]);
  });

  it("9. collapses two hits by one attacker and uses the earliest sequence", () => {
    const laterSequence = hit(75, "wingman-1", 95);
    const earlierSequence = hit(90, "wingman-1", 80);
    const assists = reconcileAssistAttributions([
      laterSequence,
      kill(),
      earlierSequence,
    ]);
    expect(assists).toHaveLength(1);
    expect(assists[0]).toMatchObject({
      representativeHitEventId: earlierSequence.event_id,
      representativeHitSimTime: 90,
      sourceEventIds: [earlierSequence.event_id, laterSequence.event_id],
    });
  });

  it("10. excludes an untracked attacker", () => {
    expect(reconcileAssistAttributions([hit(90, null), kill()])).toEqual([]);
  });

  it("11. excludes a hit on a different target", () => {
    expect(
      reconcileAssistAttributions([
        hit(90, "wingman-1", 90, "other-target"),
        kill(),
      ]),
    ).toEqual([]);
  });

  it("12. produces neither kills nor assists from hits alone", () => {
    const events = [hit(90)];
    expect(reconcileKillAttributions(events)).toEqual([]);
    expect(reconcileAssistAttributions(events)).toEqual([]);
  });

  it("13. is order-independent for fact ids, counts, and complete rows", () => {
    const events = [
      hit(80, "wingman-1", 80),
      hit(90, "wingman-1", 90),
      hit(85, "wingman-2", 85),
      kill(),
      combatEvent({
        sequence: 101,
        type: "asset.kill-reported",
        simTime: 101,
        attacker: "later-reporter",
      }),
    ];
    expect(reconcileKillAttributions([...events].reverse())).toEqual(
      reconcileKillAttributions(events),
    );
    expect(reconcileAssistAttributions([...events].reverse())).toEqual(
      reconcileAssistAttributions(events),
    );
  });

  it("14. skips a kill-reported event with a null target asset key", () => {
    const invalidKill = combatEvent({
      sequence: 100,
      type: "asset.kill-reported",
      simTime: 100,
      target: null,
    });
    expect(reconcileKillAttributions([invalidKill])).toEqual([]);
    expect(reconcileAssistAttributions([hit(90), invalidKill])).toEqual([]);
  });

  it("uses the first kill-reported event and never derives a kill from death", () => {
    const first = kill();
    const repeated = combatEvent({
      sequence: 101,
      type: "asset.kill-reported",
      simTime: 101,
      attacker: "later-reporter",
    });
    const dead = combatEvent({
      sequence: 99,
      type: "asset.dead",
      simTime: 99,
      attacker: "fabricated-killer",
    });
    const facts = reconcileKillAttributions([repeated, dead, first]);
    expect(facts).toHaveLength(1);
    expect(facts[0]).toMatchObject({
      killerAssetKey: KILLER,
      killingBlowEventId: first.event_id,
      killingBlowSimTime: 100,
      weaponDcsType: "AIM_120C",
      weaponCategory: "missile",
      sourceEventIds: [first.event_id, repeated.event_id],
    });
  });
});

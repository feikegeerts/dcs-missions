import { describe, expect, it } from "vitest";

import {
  aggregatePlayerCareer,
  buildRunScoreboard,
  extractAssetSnapshots,
  formatCostCents,
  formatPartialCost,
  formatWholeUsd,
  groupRunsByMission,
  missionCatalogEntry,
  normalizeCoalition,
  publicPlayerIdFor,
  summarizeRunCombat,
  type BuildScoreboardInput,
  type PlayerRunEntry,
} from "../src/telemetry/dashboard";
import type { TelemetryEvent } from "../src/telemetry/types";

function baseInput(
  overrides: Partial<BuildScoreboardInput> = {},
): BuildScoreboardInput {
  return {
    participants: [],
    expenditures: [],
    losses: [],
    kills: [],
    assists: [],
    assets: [],
    sorties: [],
    ...overrides,
  };
}

function scoreboardEvent(
  sequence: number,
  eventType: string,
  overrides: Partial<TelemetryEvent> = {},
): TelemetryEvent {
  return {
    schema_version: 1,
    event_id: `dashboard-test:${sequence}`,
    source: "moose-mission",
    producer_id: "test-producer",
    source_version: "telemetry-v1",
    run_key: "run-dashboard",
    event_sequence: sequence,
    event_type: eventType,
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
    ...overrides,
  };
}

describe("whole-dollar formatting", () => {
  it("rounds exact cents to whole dollars", () => {
    expect(formatWholeUsd(1_245_000)).toBe("$12,450");
    expect(formatWholeUsd(0)).toBe("$0");
    expect(formatWholeUsd(49)).toBe("$0");
    expect(formatWholeUsd(50)).toBe("$1");
  });

  it("reports missing prices as unavailable, never $0", () => {
    expect(formatCostCents(null)).toBe("unavailable");
    expect(formatCostCents(2_900_000_000)).toBe("$29,000,000");
  });

  it("marks partial totals and fully unpriced buckets", () => {
    expect(formatPartialCost(1_245_000, 0)).toBe("$12,450");
    expect(formatPartialCost(1_245_000, 2)).toBe("$12,450 + 2 unpriced");
    expect(formatPartialCost(0, 3)).toBe("3 unpriced · value unavailable");
    expect(formatPartialCost(0, 0)).toBe("$0");
  });
});

describe("normalizeCoalition", () => {
  it("passes blue/red through and buckets everything else", () => {
    expect(normalizeCoalition("blue")).toBe("blue");
    expect(normalizeCoalition("red")).toBe("red");
    expect(normalizeCoalition("neutral")).toBeNull();
    expect(normalizeCoalition(null)).toBeNull();
    expect(normalizeCoalition(undefined)).toBeNull();
    expect(normalizeCoalition("BLUE")).toBeNull();
  });
});

describe("mission catalog", () => {
  it("describes duel-dynamic and falls back for unknown missions", () => {
    expect(missionCatalogEntry("duel-dynamic").title).toBe("Duel Dynamic");
    expect(missionCatalogEntry("night-ops").title).toBe("Night Ops");
    expect(missionCatalogEntry(null).key).toBe("unknown");
  });

  it("groups runs by exact mission name, newest activity first", () => {
    const groups = groupRunsByMission([
      { missionName: "duel-dynamic", updatedAt: "2026-09-03T00:00:00Z" },
      { missionName: null, updatedAt: "2026-09-04T00:00:00Z" },
      { missionName: "duel-dynamic", updatedAt: "2026-09-05T00:00:00Z" },
    ]);
    expect(groups.map((group) => group.entry.key)).toEqual([
      "duel-dynamic",
      "unknown",
    ]);
    expect(groups[0]?.runs).toHaveLength(2);
  });
});

describe("player identity", () => {
  it("maps a UCID to a stable opaque id that hides the raw value", () => {
    const first = publicPlayerIdFor("abc123");
    expect(first).toBe(publicPlayerIdFor("abc123"));
    expect(first).not.toContain("abc123");
    expect(publicPlayerIdFor("different")).not.toBe(first);
    expect(first.startsWith("p-")).toBe(true);
  });
});

describe("buildRunScoreboard", () => {
  it("attributes kills, losses, assists, and costs to humans and AI assets", () => {
    const board = buildRunScoreboard(
      baseInput({
        participants: [
          {
            participantId: "ucid-james",
            displayName: "James V",
            callsign: "Aerial 1-1",
            coalition: "blue",
          },
        ],
        assets: [
          {
            assetKey: "aerial-1.u1.g1",
            dcsName: "Aerial-1-1",
            dcsType: "FA-18C_hornet",
            coalition: "blue",
          },
          {
            assetKey: "bandit-1.u1.g1",
            dcsName: "Bandit-1-1",
            dcsType: "MiG-29A",
            coalition: "red",
          },
        ],
        expenditures: [
          {
            participantId: "ucid-james",
            participantDisplayName: "James V",
            assetKey: "aerial-1.u1.g1",
            aircraftDcsType: "FA-18C_hornet",
            coalition: "blue",
            unitCostCents: 50_000,
          },
          {
            participantId: null,
            participantDisplayName: null,
            assetKey: "bandit-1.u1.g1",
            aircraftDcsType: "MiG-29A",
            coalition: "red",
            unitCostCents: 30_000,
          },
        ],
        losses: [
          {
            assetKey: "bandit-1.u1.g1",
            aircraftDcsType: "MiG-29A",
            coalition: "red",
            unitCostCents: 5_000_000,
          },
        ],
        kills: [
          {
            targetAssetKey: "bandit-1.u1.g1",
            targetCoalition: "red",
            targetDcsName: "Bandit-1-1",
            targetDcsType: "MiG-29A",
            killerAssetKey: "aerial-1.u1.g1",
            killerCoalition: "blue",
            killerDcsName: "Aerial-1-1",
            killerDcsType: "FA-18C_hornet",
          },
        ],
        assists: [
          {
            targetAssetKey: "bandit-1.u1.g1",
            attackerAssetKey: "aerial-1.u1.g1",
            attackerCoalition: "blue",
            attackerDcsName: "Aerial-1-1",
            attackerDcsType: "FA-18C_hornet",
          },
        ],
      }),
    );

    expect(board.blue.kills).toBe(1);
    expect(board.red.losses).toBe(1);
    expect(board.humans).toHaveLength(1);
    expect(board.humans[0]).toMatchObject({
      displayName: "James V",
      kills: 1,
      losses: 0,
      assists: 1,
      shots: 1,
      ordnanceCostCents: 50_000,
    });
    expect(board.humans[0]?.publicPlayerId).toBe(
      publicPlayerIdFor("ucid-james"),
    );
    expect(board.ai).toHaveLength(1);
    expect(board.ai[0]).toMatchObject({
      displayName: "Bandit-1-1",
      losses: 1,
      shots: 1,
      aircraftLossCents: 5_000_000,
    });
    expect(board.unresolved).toHaveLength(0);
  });

  it("keeps zero-action combatants on the roster", () => {
    const board = buildRunScoreboard(
      baseInput({
        participants: [
          {
            participantId: "ucid-quiet",
            displayName: "Quiet Pilot",
            callsign: null,
            coalition: "blue",
          },
        ],
        assets: [
          {
            assetKey: "bandit-9.u1.g1",
            dcsName: "Bandit-9-1",
            dcsType: "MiG-29A",
            coalition: "red",
          },
        ],
      }),
    );
    expect(board.humans.map((row) => row.displayName)).toEqual(["Quiet Pilot"]);
    expect(board.ai.map((row) => row.displayName)).toEqual(["Bandit-9-1"]);
  });

  it("counts unknown killers without assigning them to a combatant", () => {
    const board = buildRunScoreboard(
      baseInput({
        assets: [
          {
            assetKey: "aerial-1.u1.g1",
            dcsName: "Aerial-1-1",
            dcsType: "FA-18C_hornet",
            coalition: "blue",
          },
        ],
        losses: [
          {
            assetKey: "aerial-1.u1.g1",
            aircraftDcsType: "FA-18C_hornet",
            coalition: "blue",
            unitCostCents: 29_000_000_00,
          },
        ],
        kills: [
          {
            targetAssetKey: "aerial-1.u1.g1",
            targetCoalition: "blue",
            targetDcsName: "Aerial-1-1",
            targetDcsType: "FA-18C_hornet",
            killerAssetKey: null,
            killerCoalition: null,
            killerDcsName: null,
            killerDcsType: null,
          },
        ],
      }),
    );
    expect(board.unattributedKills).toBe(1);
    expect(board.blue.losses).toBe(1);
    expect(board.humans).toHaveLength(0);
    expect(board.ai).toHaveLength(1);
    expect(board.ai[0]?.kills).toBe(0);
  });

  it("flags friendly fire instead of reading it as hostile success", () => {
    const board = buildRunScoreboard(
      baseInput({
        participants: [
          {
            participantId: "ucid-blue",
            displayName: "Blue One",
            callsign: null,
            coalition: "blue",
          },
        ],
        expenditures: [
          {
            participantId: "ucid-blue",
            participantDisplayName: "Blue One",
            assetKey: "aerial-1.u1.g1",
            aircraftDcsType: "FA-18C_hornet",
            coalition: "blue",
            unitCostCents: 10_000,
          },
        ],
        kills: [
          {
            targetAssetKey: "aerial-2.u1.g1",
            targetCoalition: "blue",
            targetDcsName: "Aerial-2-1",
            targetDcsType: "FA-18C_hornet",
            killerAssetKey: "aerial-1.u1.g1",
            killerCoalition: "blue",
            killerDcsName: "Aerial-1-1",
            killerDcsType: "FA-18C_hornet",
          },
        ],
      }),
    );
    expect(board.blue.kills).toBe(1);
    expect(board.blue.friendlyKills).toBe(1);
    expect(board.humans[0]?.friendlyKills).toBe(1);
  });

  it("keeps named-but-unresolved shooters visible and out of career ids", () => {
    const board = buildRunScoreboard(
      baseInput({
        expenditures: [
          {
            participantId: null,
            participantDisplayName: "Mystery Pilot",
            assetKey: null,
            aircraftDcsType: null,
            coalition: "blue",
            unitCostCents: null,
          },
        ],
      }),
    );
    expect(board.unresolved).toHaveLength(1);
    expect(board.unresolved[0]).toMatchObject({
      displayName: "Mystery Pilot",
      shots: 1,
      participantId: null,
      publicPlayerId: null,
    });
    expect(board.unresolved[0]?.partial).toBe(true);
  });

  it("splits a side switch into one row per coalition", () => {
    const board = buildRunScoreboard(
      baseInput({
        participants: [
          {
            participantId: "ucid-switch",
            displayName: "Switcher",
            callsign: null,
            coalition: "blue",
          },
        ],
        expenditures: [
          {
            participantId: "ucid-switch",
            participantDisplayName: "Switcher",
            assetKey: "aerial-1.u1.g1",
            aircraftDcsType: "FA-18C_hornet",
            coalition: "blue",
            unitCostCents: 10_000,
          },
          {
            participantId: "ucid-switch",
            participantDisplayName: "Switcher",
            assetKey: "bandit-1.u1.g1",
            aircraftDcsType: "MiG-29A",
            coalition: "red",
            unitCostCents: 20_000,
          },
        ],
      }),
    );
    expect(board.humans).toHaveLength(2);
    expect(
      board.humans.map((row) => `${row.coalition}:${row.shots}`).sort(),
    ).toEqual(["blue:1", "red:1"]);
  });

  it("attributes a loss through a single-occupant slot but not a shared one", () => {
    const loss = {
      assetKey: "aerial-1.u1.g1",
      aircraftDcsType: "FA-18C_hornet",
      coalition: "blue",
      unitCostCents: 100_000,
    };
    const single = buildRunScoreboard(
      baseInput({
        participants: [
          {
            participantId: "ucid-solo",
            displayName: "Solo",
            callsign: null,
            coalition: "blue",
          },
        ],
        assets: [
          {
            assetKey: "aerial-1.u1.g1",
            dcsName: "Aerial-1-1",
            dcsType: "FA-18C_hornet",
            coalition: "blue",
          },
        ],
        sorties: [{ participantId: "ucid-solo", slotDcsName: "Aerial-1-1" }],
        losses: [loss],
      }),
    );
    expect(single.humans[0]?.losses).toBe(1);

    const shared = buildRunScoreboard(
      baseInput({
        participants: [
          {
            participantId: "ucid-a",
            displayName: "Alpha",
            callsign: null,
            coalition: "blue",
          },
          {
            participantId: "ucid-b",
            displayName: "Bravo",
            callsign: null,
            coalition: "blue",
          },
        ],
        assets: [
          {
            assetKey: "aerial-1.u1.g1",
            dcsName: "Aerial-1-1",
            dcsType: "FA-18C_hornet",
            coalition: "blue",
          },
        ],
        sorties: [
          { participantId: "ucid-a", slotDcsName: "Aerial-1-1" },
          { participantId: "ucid-b", slotDcsName: "Aerial-1-1" },
        ],
        losses: [loss],
      }),
    );
    expect(shared.humans.every((row) => row.losses === 0)).toBe(true);
    expect(shared.ai.find((row) => row.losses === 1)?.displayName).toBe(
      "Aerial-1-1",
    );
  });
});

describe("summarizeRunCombat", () => {
  it("rolls coalition kills and exact-cent costs without roster inference", () => {
    const summary = summarizeRunCombat({
      expenditures: [
        {
          participantId: "ucid-james",
          participantDisplayName: "James V",
          assetKey: "aerial-1.u1.g1",
          aircraftDcsType: "FA-18C_hornet",
          coalition: "blue",
          unitCostCents: 50_000,
        },
        {
          participantId: null,
          participantDisplayName: null,
          assetKey: "bandit-1.u1.g1",
          aircraftDcsType: "MiG-29A",
          coalition: "red",
          unitCostCents: null,
        },
      ],
      losses: [
        {
          assetKey: "bandit-1.u1.g1",
          aircraftDcsType: "MiG-29A",
          coalition: "red",
          unitCostCents: 5_000_000,
        },
      ],
      kills: [
        {
          targetAssetKey: "bandit-1.u1.g1",
          targetCoalition: "red",
          targetDcsName: "Bandit-1-1",
          targetDcsType: "MiG-29A",
          killerAssetKey: "aerial-1.u1.g1",
          killerCoalition: "blue",
          killerDcsName: "Aerial-1-1",
          killerDcsType: "FA-18C_hornet",
        },
      ],
    });
    expect(summary).toMatchObject({
      blueKills: 1,
      redKills: 0,
      shots: 2,
      totalCents: 5_050_000,
      partial: true,
    });
  });
});

describe("aggregatePlayerCareer", () => {
  function entry(
    runKey: string,
    missionName: string | null,
    kills: number,
    losses: number,
  ): PlayerRunEntry {
    return {
      runKey,
      missionName,
      mapName: "Caucasus",
      startedAt: `${runKey}T00:00:00Z`,
      status: "ended",
      row: {
        kind: "human",
        key: "ucid-james|blue",
        participantId: "ucid-james",
        publicPlayerId: publicPlayerIdFor("ucid-james"),
        displayName: "James V",
        callsign: null,
        coalition: "blue",
        aircraft: "FA-18C_hornet",
        assetKeys: [],
        kills,
        friendlyKills: 0,
        losses,
        assists: 1,
        shots: 2,
        ordnanceCostCents: 50_000,
        ordnanceUnpriced: 0,
        aircraftLossCents: losses === 0 ? 0 : 29_000_000_00,
        aircraftUnpriced: 0,
        totalCents: losses === 0 ? 50_000 : 2_900_005_000_0,
        totalUnpriced: 0,
        partial: false,
      },
    };
  }

  it("sums runs across missions with history and mission splits", () => {
    const career = aggregatePlayerCareer("ucid-james", [
      entry("run-b", "duel-dynamic", 2, 1),
      entry("run-a", "duel-dynamic", 1, 0),
    ]);
    expect(career).toMatchObject({
      displayName: "James V",
      runs: 2,
      kills: 3,
      losses: 1,
      assists: 2,
    });
    expect(career.killLossRatio).toBe(3);
    expect(career.byMission).toHaveLength(1);
    expect(career.byMission[0]).toMatchObject({
      runs: 2,
      kills: 3,
    });
    expect(career.history.map((item) => item.runKey)).toEqual([
      "run-a",
      "run-b",
    ]);
  });
});

describe("extractAssetSnapshots", () => {
  it("keeps only asset.spawned incarnations with identity", () => {
    const snapshots = extractAssetSnapshots([
      scoreboardEvent(1, "asset.spawned", {
        asset: {
          status: "known",
          asset_key: "bandit-1.u1.g1",
          dcs_name: "Bandit-1-1",
          dcs_type: "MiG-29A",
          coalition: "red",
        },
        coalition: "red",
      }),
      scoreboardEvent(2, "ordnance.fired", { coalition: "blue" }),
      scoreboardEvent(3, "asset.spawned", { asset: null }),
    ]);
    expect(snapshots).toEqual([
      {
        assetKey: "bandit-1.u1.g1",
        dcsName: "Bandit-1-1",
        dcsType: "MiG-29A",
        coalition: "red",
      },
    ]);
  });
});

import { describe, expect, it } from "vitest";

import {
  reconcileAssistAttributions,
  reconcileKillAttributions,
  type AssistAttributionFact,
  type KillAttributionFact,
} from "../src/telemetry/combat-facts";
import {
  currentOrdnanceAssignment,
  deriveExpenditure,
  participantObservation,
  type ExpenditureProjection,
} from "../src/telemetry/expenditures";
import {
  reconcileAssetLosts,
  type AssetLostFact,
} from "../src/telemetry/losses";
import {
  reconcileRunProjections,
  replayRun,
  ReplayRunNotFoundError,
  type ReplayStore,
} from "../src/telemetry/replay";
import type {
  RunParticipantUpsert,
  RunRow,
  RunUpsertInput,
} from "../src/telemetry/store";
import type { TelemetryEvent } from "../src/telemetry/types";

const assignment = currentOrdnanceAssignment();

function event(
  sequence: number,
  eventType: string,
  overrides: Partial<TelemetryEvent> = {},
): TelemetryEvent {
  return {
    schema_version: 1,
    event_id: `mission-server:run-replay:${sequence}`,
    source: "moose-mission",
    producer_id: "mission-server",
    source_version: "telemetry-v1",
    run_key: "run-replay",
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

function aircraft(assetKey: string, coalition: string) {
  return {
    status: "known",
    kind: "aircraft",
    participant_id: null,
    asset_key: assetKey,
    display_name: null,
    callsign: null,
    dcs_name: assetKey,
    dcs_type: coalition === "blue" ? "FA-18C_hornet" : "MiG-29A",
    coalition,
  };
}

function mixedStream(): TelemetryEvent[] {
  const bandit = aircraft("bandit.u1.g1", "red");
  return [
    event(1, "mission.started", {
      payload: { mission_name: "Replay Test" },
    }),
    event(2, "mission.heartbeat"),
    event(3, "ordnance.fired", {
      initiator: aircraft("viper.u1.g1", "blue"),
      weapon: {
        status: "known",
        dcs_type: "AIM_120C",
        display_name: "AIM-120C AMRAAM",
        category: "missile",
      },
      coalition: "blue",
    }),
    event(4, "ordnance.fired", {
      initiator: aircraft("viper.u1.g1", "blue"),
      weapon: { status: "unknown", reason: "not-observed" },
      coalition: "blue",
    }),
    event(5, "participant.entered", {
      participant: {
        status: "known",
        participant_id: "ucid-viper-1",
        display_name: "Viper",
        callsign: "Viper 1-1",
        coalition: "blue",
      },
      coalition: "blue",
    }),
    event(6, "asset.spawned", { asset: bandit, coalition: "red" }),
    event(7, "asset.dead", { asset: bandit, coalition: "red" }),
    event(8, "asset.hit", {
      sim_time: 90,
      initiator: aircraft("wingman.u1.g1", "blue"),
      target: bandit,
      coalition: "blue",
    }),
    event(9, "asset.kill-reported", {
      sim_time: 100,
      initiator: aircraft("viper.u1.g1", "blue"),
      target: bandit,
      weapon: {
        status: "known",
        dcs_type: "AIM_120C",
        category: "missile",
      },
      coalition: "blue",
    }),
  ];
}

function runRow(events: readonly TelemetryEvent[]): RunRow {
  return {
    producerId: events[0]?.producer_id ?? "mission-server",
    runKey: events[0]?.run_key ?? "run-replay",
    valuationCatalogue: assignment.catalogue,
    valuationCatalogueVersion: assignment.version,
    firstSequence: events[0]?.event_sequence ?? 0,
    lastSequence: events.at(-1)?.event_sequence ?? 0,
    eventCount: events.length,
    status: "active",
  } as RunRow;
}

class ReplayMemoryStore implements ReplayStore {
  readonly expenditures = new Map<string, ExpenditureProjection>();
  readonly losses = new Map<string, AssetLostFact>();
  readonly kills = new Map<string, KillAttributionFact>();
  readonly assists = new Map<string, AssistAttributionFact>();
  readonly participants = new Map<string, RunParticipantUpsert>();
  listRunEventsCalls = 0;
  factUpsertCalls = 0;
  runUpsertCalls = 0;
  lastRunUpsert: RunUpsertInput | null = null;

  constructor(
    readonly run: RunRow | null,
    readonly events: readonly TelemetryEvent[],
  ) {}

  async getRunByRunKey(runKey: string): Promise<RunRow | null> {
    return this.run?.runKey === runKey ? this.run : null;
  }

  async listRunEvents(
    producerId: string,
    runKey: string,
  ): Promise<TelemetryEvent[]> {
    this.listRunEventsCalls += 1;
    return this.events
      .filter(
        (item) => item.producer_id === producerId && item.run_key === runKey,
      )
      .sort((left, right) => left.event_sequence - right.event_sequence);
  }

  async insertExpenditure(
    expenditure: ExpenditureProjection,
  ): Promise<"inserted" | "existing"> {
    this.factUpsertCalls += 1;
    if (this.expenditures.has(expenditure.sourceEventId)) {
      return "existing";
    }
    this.expenditures.set(expenditure.sourceEventId, expenditure);
    return "inserted";
  }

  async upsertAssetLoss(loss: AssetLostFact): Promise<void> {
    this.factUpsertCalls += 1;
    const key = `${loss.producerId} ${loss.runKey} ${loss.assetKey}`;
    const current = this.losses.get(key);
    if (
      !current ||
      loss.sourceEventIds.length >= current.sourceEventIds.length
    ) {
      this.losses.set(key, loss);
    }
  }

  async upsertKillAttribution(fact: KillAttributionFact): Promise<void> {
    this.factUpsertCalls += 1;
    const key = `${fact.producerId} ${fact.runKey} ${fact.targetAssetKey}`;
    const current = this.kills.get(key);
    if (
      !current ||
      fact.sourceEventIds.length >= current.sourceEventIds.length
    ) {
      this.kills.set(key, fact);
    }
  }

  async upsertAssistAttribution(fact: AssistAttributionFact): Promise<void> {
    this.factUpsertCalls += 1;
    const key = `${fact.producerId} ${fact.runKey} ${fact.targetAssetKey} ${fact.attackerAssetKey}`;
    const current = this.assists.get(key);
    if (
      !current ||
      fact.sourceEventIds.length >= current.sourceEventIds.length
    ) {
      this.assists.set(key, fact);
    }
  }

  async upsertRunParticipant(participant: RunParticipantUpsert): Promise<void> {
    this.factUpsertCalls += 1;
    const key = `${participant.producerId} ${participant.runKey} ${participant.participantId}`;
    const current = this.participants.get(key);
    if (!current || participant.eventSequence >= current.eventSequence) {
      this.participants.set(key, participant);
    }
  }

  async upsertRun(input: RunUpsertInput): Promise<void> {
    this.runUpsertCalls += 1;
    this.lastRunUpsert = input;
    if (this.run !== null) {
      Object.assign(this.run, {
        missionName: this.run.missionName ?? input.missionName ?? null,
        missionVersion: this.run.missionVersion ?? input.missionVersion ?? null,
        mapName: this.run.mapName ?? input.mapName ?? null,
        runClassification:
          this.run.runClassification ?? input.runClassification ?? null,
        firstSequence: Math.min(this.run.firstSequence, input.firstSequence),
        lastSequence: Math.max(this.run.lastSequence, input.lastSequence),
        eventCount: input.eventCount,
        startedAt:
          this.run.startedAt ??
          (input.startedAt ? new Date(input.startedAt) : null),
        endedAt:
          this.run.endedAt ?? (input.endedAt ? new Date(input.endedAt) : null),
        status: input.status === "ended" ? "ended" : this.run.status,
      });
    }
  }
}

function storedFacts(store: ReplayMemoryStore) {
  return {
    expenditures: [...store.expenditures.values()],
    losses: [...store.losses.values()],
    kills: [...store.kills.values()],
    assists: [...store.assists.values()],
    participants: [...store.participants.values()],
  };
}

describe("derived-fact replay", () => {
  it("reuses the ingest projection functions for a mixed full-run stream", () => {
    const events = mixedStream();
    const projections = reconcileRunProjections(events, assignment);
    const expectedExpenditures = events
      .map((item) => deriveExpenditure(item, assignment))
      .filter((fact) => fact !== null);
    const expectedParticipants = events
      .map(participantObservation)
      .filter((observation) => observation !== null);

    expect(projections.expenditures).toHaveLength(2);
    expect(projections.losses).toHaveLength(1);
    expect(projections.kills).toHaveLength(1);
    expect(projections.assists).toHaveLength(1);
    expect(projections.participants).toHaveLength(1);
    expect(projections.expenditures.map((fact) => fact.sourceEventId)).toEqual(
      expectedExpenditures.map((fact) => fact.sourceEventId),
    );
    expect(projections.losses.map((fact) => fact.factId)).toEqual(
      reconcileAssetLosts(events, assignment).map((fact) => fact.factId),
    );
    expect(projections.kills.map((fact) => fact.factId)).toEqual(
      reconcileKillAttributions(events).map((fact) => fact.factId),
    );
    expect(projections.assists.map((fact) => fact.factId)).toEqual(
      reconcileAssistAttributions(events).map((fact) => fact.factId),
    );
    expect(projections.participants).toEqual(expectedParticipants);
  });

  it("keeps catalogue-independent facts for an unassigned run", () => {
    const projections = reconcileRunProjections(mixedStream(), null);

    expect(projections.expenditures).toEqual([]);
    expect(projections.losses).toEqual([]);
    expect(projections.kills).toHaveLength(1);
    expect(projections.assists).toHaveLength(1);
    expect(projections.participants).toHaveLength(1);
  });

  it("rebuilds one evolved loss from dead and later crashed observations", () => {
    const asset = aircraft("bandit.u1.g1", "red");
    const dead = event(10, "asset.dead", { asset, coalition: "red" });
    const crashed = event(20, "asset.crashed", { asset, coalition: "red" });

    const projections = reconcileRunProjections([dead, crashed], assignment);

    expect(projections.losses).toHaveLength(1);
    expect(projections.losses[0]?.sourceEventIds).toEqual([
      dead.event_id,
      crashed.event_id,
    ]);
  });

  it("is idempotent when the same run is replayed twice", async () => {
    const events = mixedStream();
    const store = new ReplayMemoryStore(runRow(events), events);

    const firstSummary = await replayRun(store, "run-replay");
    const firstFacts = structuredClone(storedFacts(store));
    const secondSummary = await replayRun(store, "run-replay");

    expect(secondSummary).toEqual(firstSummary);
    expect(storedFacts(store)).toEqual(firstFacts);
    expect(firstSummary).toMatchObject({
      eventCount: events.length,
      sequenceSpan: { first: 1, last: 9 },
      expenditures: 2,
      losses: 1,
      kills: 1,
      assists: 1,
      participants: 1,
    });
  });

  it("throws for an unknown run without reading events or writing facts", async () => {
    const store = new ReplayMemoryStore(null, mixedStream());
    const replay = replayRun(store, "missing-run");

    await expect(replay).rejects.toBeInstanceOf(ReplayRunNotFoundError);
    await expect(replay).rejects.toEqual(
      expect.objectContaining({
        name: "ReplayRunNotFoundError",
        runKey: "missing-run",
      }),
    );
    expect(store.listRunEventsCalls).toBe(0);
    expect(store.factUpsertCalls).toBe(0);
  });

  it("repairs the run summary from retained truth while keeping fact replay additive", async () => {
    const events = mixedStream();
    events[0]!.wall_time = "2026-09-07T10:00:00Z";
    events[0]!.payload = {
      mission_name: "Replay Test",
      mission_version: "2",
      map_name: "Caucasus",
      run_classification: "test",
    };
    const run = runRow(events);
    run.eventCount = 0;
    run.startedAt = null;
    run.missionName = null;
    const store = new ReplayMemoryStore(run, events);
    store.kills.set("stale additive fact", {
      factId: "stale",
      producerId: run.producerId,
      runKey: run.runKey,
      targetAssetKey: "stale-target",
      targetDcsName: null,
      targetDcsType: null,
      targetCoalition: null,
      killerAssetKey: null,
      killerDcsName: null,
      killerDcsType: null,
      killerCoalition: null,
      killingBlowSimTime: 1,
      killingBlowEventId: "stale-source",
      weaponDcsType: null,
      weaponCategory: null,
      sourceEventIds: ["stale-source"],
    });

    await replayRun(store, run.runKey);

    expect(store.runUpsertCalls).toBe(1);
    expect(store.lastRunUpsert).toMatchObject({
      eventCount: events.length,
      firstSequence: 1,
      lastSequence: 9,
      missionName: "Replay Test",
      missionVersion: "2",
      mapName: "Caucasus",
      runClassification: "test",
      startedAt: "2026-09-07T10:00:00Z",
      status: "active",
    });
    expect(run.eventCount).toBe(events.length);
    expect(run.startedAt).toEqual(new Date("2026-09-07T10:00:00Z"));
    expect(run.missionName).toBe("Replay Test");
    expect(store.kills.has("stale additive fact")).toBe(true);
  });
});

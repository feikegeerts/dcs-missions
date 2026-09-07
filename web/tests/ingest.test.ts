import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import type {
  AssistAttributionRow,
  AssetLossRow,
  EventRow,
  ExpenditureRow,
  KillAttributionRow,
  RunParticipantRow,
  RunParticipantUpsert,
  RunRow,
  RunUpsertInput,
  TelemetryStore,
} from "../src/telemetry/store";
import type {
  AssistAttributionFact,
  KillAttributionFact,
} from "../src/telemetry/combat-facts";
import type { ExpenditureProjection } from "../src/telemetry/expenditures";
import { processIngest } from "../src/telemetry/ingest";
import {
  canonicalJson,
  reconcileRunProjections,
} from "../src/telemetry/replay";
import {
  aggregateAssetLosts,
  type AssetLostFact,
} from "../src/telemetry/losses";
import type { TelemetryEvent } from "../src/telemetry/types";

const contractRoot = resolve(process.cwd(), "..", "contracts");

function readJson(path: string): TelemetryEvent {
  return JSON.parse(readFileSync(path, "utf8")) as TelemetryEvent;
}

const validEvents = readdirSync(resolve(contractRoot, "fixtures/valid"))
  .filter((name) => name.endsWith(".json"))
  .sort()
  .map((name) => readJson(resolve(contractRoot, "fixtures/valid", name)));

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

function body(events: TelemetryEvent[]): string {
  return JSON.stringify({ batch_schema_version: 1, events });
}

function runEvent(
  template: TelemetryEvent,
  runKey: string,
  sequence: number,
): TelemetryEvent {
  const event = clone(template);
  event.run_key = runKey;
  event.event_sequence = sequence;
  event.event_id = `${event.producer_id}:${runKey}:${sequence}`;
  return event;
}

function storedRun(
  event: TelemetryEvent,
  status: FakeRun["status"] = "active",
): FakeRun {
  return {
    producerId: event.producer_id,
    runKey: event.run_key,
    valuationCatalogue: "ordnance",
    valuationCatalogueVersion: 1,
    firstSequence: 1,
    lastSequence: event.event_sequence,
    eventCount: event.event_sequence,
    status,
  };
}

function lossEvent(options: {
  runKey: string;
  sequence: number;
  eventType: string;
  assetKey?: string;
  dcsName?: string;
  payload?: Record<string, unknown>;
}): TelemetryEvent {
  const event = clone(validEvents[1]);
  event.run_key = options.runKey;
  event.event_sequence = options.sequence;
  event.event_id = `${event.producer_id}:${event.run_key}:${options.sequence}`;
  event.event_type = options.eventType;
  event.initiator = null;
  event.target = null;
  event.participant = null;
  event.weapon = null;
  event.asset = {
    status: "known",
    kind: "aircraft",
    asset_key: options.assetKey ?? "aerial-1.u1.g1",
    dcs_name: options.dcsName ?? "Aerial-1-1",
    dcs_type: "FA-18C_hornet",
    coalition: "blue",
  };
  event.coalition = "blue";
  event.payload = options.payload ?? {};
  return event;
}

type FakeRun = Omit<RunUpsertInput, "status"> & {
  status: "active" | "aborted" | "ended";
};

type MarkAbortedCall = {
  producerId: string;
  runKey: string;
  affected: number;
};

class MemoryStore implements TelemetryStore {
  readonly events = new Map<string, TelemetryEvent>();
  readonly runs = new Map<string, FakeRun>();
  readonly runUpserts: RunUpsertInput[] = [];
  readonly markAbortedCalls: MarkAbortedCall[] = [];
  readonly expenditures = new Map<string, ExpenditureProjection>();
  readonly losses = new Map<string, AssetLostFact>();
  readonly kills = new Map<string, KillAttributionFact>();
  readonly assists = new Map<string, AssistAttributionFact>();
  runEventReads = 0;
  readonly participants = new Map<string, FakeParticipant>();
  private failureStage: FailureStage | null = null;

  failNext(stage: FailureStage): void {
    this.failureStage = stage;
  }

  private maybeFail(stage: FailureStage): void {
    if (this.failureStage === stage) {
      this.failureStage = null;
      throw new Error(`injected-${stage}-failure`);
    }
  }

  async insertEvent(
    event: TelemetryEvent,
  ): Promise<"accepted" | "duplicate" | "rejected" | "content-conflict"> {
    this.maybeFail("raw");
    const retained = this.events.get(event.event_id);
    if (retained !== undefined) {
      return canonicalJson(retained) === canonicalJson(event)
        ? "duplicate"
        : "content-conflict";
    }
    this.events.set(event.event_id, clone(event));
    return "accepted";
  }

  async upsertRun(run: RunUpsertInput): Promise<void> {
    this.maybeFail("summary");
    this.runUpserts.push(run);
    const key = `${run.producerId} ${run.runKey}`;
    const existing = this.runs.get(key);
    if (!existing) {
      this.runs.set(key, { ...run });
      return;
    }
    // Mirror the production COALESCE rule: an existing catalogue
    // assignment is never rewritten, and unassigned runs stay unassigned
    // unless the upsert carries an assignment for a row that has none.
    this.runs.set(key, {
      ...existing,
      ...run,
      missionName: existing.missionName ?? run.missionName ?? null,
      missionVersion: existing.missionVersion ?? run.missionVersion ?? null,
      mapName: existing.mapName ?? run.mapName ?? null,
      runClassification:
        existing.runClassification ?? run.runClassification ?? null,
      startedAt: existing.startedAt ?? run.startedAt ?? null,
      endedAt: existing.endedAt ?? run.endedAt ?? null,
      valuationCatalogue:
        existing.valuationCatalogue ?? run.valuationCatalogue ?? null,
      valuationCatalogueVersion:
        existing.valuationCatalogueVersion ??
        run.valuationCatalogueVersion ??
        null,
      firstSequence: Math.min(existing.firstSequence, run.firstSequence),
      lastSequence: Math.max(existing.lastSequence, run.lastSequence),
      eventCount: run.eventCount,
      status: run.status === "ended" ? "ended" : existing.status,
    });
  }

  async markRunAborted(producerId: string, runKey: string): Promise<number> {
    let affected = 0;
    for (const [key, run] of this.runs) {
      if (
        run.producerId === producerId &&
        run.runKey === runKey &&
        run.status === "active"
      ) {
        this.runs.set(key, { ...run, status: "aborted" });
        affected += 1;
      }
    }
    this.markAbortedCalls.push({ producerId, runKey, affected });
    return affected;
  }

  async insertExpenditure(
    expenditure: ExpenditureProjection,
  ): Promise<"inserted" | "existing"> {
    this.maybeFail("expenditures");
    if (this.expenditures.has(expenditure.sourceEventId)) {
      return "existing";
    }
    this.expenditures.set(expenditure.sourceEventId, expenditure);
    return "inserted";
  }

  async upsertAssetLoss(loss: AssetLostFact): Promise<void> {
    this.maybeFail("losses");
    const key = `${loss.producerId} ${loss.runKey} ${loss.assetKey}`;
    const existing = this.losses.get(key);
    if (
      existing === undefined ||
      loss.sourceEventIds.length >= existing.sourceEventIds.length
    ) {
      this.losses.set(key, loss);
    }
  }

  async upsertKillAttribution(attribution: KillAttributionFact): Promise<void> {
    this.maybeFail("kills");
    const key = `${attribution.producerId} ${attribution.runKey} ${attribution.targetAssetKey}`;
    const existing = this.kills.get(key);
    if (
      existing === undefined ||
      attribution.sourceEventIds.length >= existing.sourceEventIds.length
    ) {
      this.kills.set(key, attribution);
    }
  }

  async upsertAssistAttribution(
    attribution: AssistAttributionFact,
  ): Promise<void> {
    this.maybeFail("assists");
    const key = `${attribution.producerId} ${attribution.runKey} ${attribution.targetAssetKey} ${attribution.attackerAssetKey}`;
    const existing = this.assists.get(key);
    if (
      existing === undefined ||
      attribution.sourceEventIds.length >= existing.sourceEventIds.length
    ) {
      this.assists.set(key, attribution);
    }
  }

  async upsertRunParticipant(participant: RunParticipantUpsert): Promise<void> {
    this.maybeFail("participants");
    const key = `${participant.producerId} ${participant.runKey} ${participant.participantId}`;
    const existing = this.participants.get(key);
    if (!existing) {
      this.participants.set(key, {
        ...participant,
        displayNameSequence:
          participant.displayName !== null ? participant.eventSequence : null,
        callsignSequence:
          participant.callsign !== null ? participant.eventSequence : null,
      });
      return;
    }
    const next: FakeParticipant = { ...existing };
    if (
      participant.displayName !== null &&
      (next.displayNameSequence === null ||
        participant.eventSequence >= next.displayNameSequence)
    ) {
      next.displayName = participant.displayName;
      next.displayNameSequence = participant.eventSequence;
    }
    if (
      participant.callsign !== null &&
      (next.callsignSequence === null ||
        participant.eventSequence >= next.callsignSequence)
    ) {
      next.callsign = participant.callsign;
      next.callsignSequence = participant.eventSequence;
    }
    next.coalition = participant.coalition ?? next.coalition;
    next.eventSequence = Math.max(
      next.eventSequence,
      participant.eventSequence,
    );
    this.participants.set(key, next);
  }

  async listRuns(): Promise<RunRow[]> {
    return [];
  }

  async getRunByRunKey(runKey: string): Promise<RunRow | null> {
    for (const run of this.runs.values()) {
      if (run.runKey === runKey) {
        return run as unknown as RunRow;
      }
    }
    return null;
  }

  async listEvents(): Promise<EventRow[]> {
    return [];
  }

  async listRunEvents(
    producerId: string,
    runKey: string,
  ): Promise<TelemetryEvent[]> {
    this.runEventReads += 1;
    return [...this.events.values()]
      .filter(
        (event) => event.producer_id === producerId && event.run_key === runKey,
      )
      .sort((left, right) => left.event_sequence - right.event_sequence);
  }

  async listExpenditures(): Promise<ExpenditureRow[]> {
    return [];
  }

  async listAssetLosses(): Promise<AssetLossRow[]> {
    return [...this.losses.values()] as unknown as AssetLossRow[];
  }

  async listKillAttributions(): Promise<KillAttributionRow[]> {
    return [...this.kills.values()] as unknown as KillAttributionRow[];
  }

  async listAssistAttributions(): Promise<AssistAttributionRow[]> {
    return [...this.assists.values()] as unknown as AssistAttributionRow[];
  }

  async listRunParticipants(): Promise<RunParticipantRow[]> {
    return [];
  }
}

type FakeParticipant = RunParticipantUpsert & {
  displayNameSequence: number | null;
  callsignSequence: number | null;
};

type FailureStage =
  | "raw"
  | "summary"
  | "expenditures"
  | "participants"
  | "losses"
  | "kills"
  | "assists";

function repairStream(runKey: string): TelemetryEvent[] {
  const started = runEvent(validEvents[0], runKey, 1);
  const fired = runEvent(validEvents[1], runKey, 2);
  fired.weapon = {
    status: "known",
    dcs_type: "AIM_120C",
    display_name: "AIM-120C",
    category: "missile",
  };
  const crashed = runEvent(validEvents[3], runKey, 3);
  const killed = runEvent(validEvents[4], runKey, 5);
  killed.initiator = clone(fired.initiator);
  const hit = clone(killed);
  hit.event_sequence = 4;
  hit.event_id = `${hit.producer_id}:${runKey}:4`;
  hit.event_type = "asset.hit";
  hit.sim_time = killed.sim_time - 10;
  hit.initiator = {
    ...(hit.initiator as Record<string, unknown>),
    asset_key: "wingman.u1.g1",
    dcs_name: "Wingman-1-1",
  } as TelemetryEvent["initiator"];
  return [started, fired, crashed, hit, killed];
}

function expectReconciledState(
  store: MemoryStore,
  events: readonly TelemetryEvent[],
): void {
  const expected = reconcileRunProjections(events, {
    catalogue: "ordnance",
    version: 1,
  });
  expect([...store.expenditures.keys()].sort()).toEqual(
    expected.expenditures.map((fact) => fact.sourceEventId).sort(),
  );
  expect([...store.losses.values()].map((fact) => fact.factId).sort()).toEqual(
    expected.losses.map((fact) => fact.factId).sort(),
  );
  expect([...store.kills.values()].map((fact) => fact.factId).sort()).toEqual(
    expected.kills.map((fact) => fact.factId).sort(),
  );
  expect([...store.assists.values()].map((fact) => fact.factId).sort()).toEqual(
    expected.assists.map((fact) => fact.factId).sort(),
  );
  expect([...store.participants.keys()].sort()).toEqual(
    [
      ...new Set(
        expected.participants.map(
          (participant) =>
            `${participant.producerId} ${participant.runKey} ${participant.participantId}`,
        ),
      ),
    ].sort(),
  );
}

describe("telemetry ingest", () => {
  it("canonical JSON ignores recursive object key order but preserves array order", () => {
    expect(
      canonicalJson({ z: 1, nested: { b: 2, a: [3, { d: 4, c: 5 }] } }),
    ).toBe(canonicalJson({ nested: { a: [3, { c: 5, d: 4 }], b: 2 }, z: 1 }));
    expect(canonicalJson({ values: [1, 2] })).not.toBe(
      canonicalJson({ values: [2, 1] }),
    );
  });

  it("one-shot raw insert failure leaves no retained state and accepts retry", async () => {
    const event = runEvent(validEvents[0], "run-s16-p7-raw-failure", 1);
    const store = new MemoryStore();
    store.failNext("raw");

    await expect(processIngest(body([event]), store)).rejects.toThrow(
      "injected-raw-failure",
    );
    expect(store.events.size).toBe(0);

    const retry = await processIngest(body([event]), store);
    expect(retry.body).toMatchObject({
      summary: { accepted: 1, duplicates: 0, rejected: 0 },
    });
    expect(store.events.size).toBe(1);
  });

  it("accepts events and upserts the run summary", async () => {
    const store = new MemoryStore();
    const result = await processIngest(body(validEvents), store);

    expect(result).toMatchObject({ httpStatus: 200 });
    expect(result.body).toMatchObject({
      summary: { accepted: validEvents.length, duplicates: 0, rejected: 0 },
    });
    expect(store.events.size).toBe(validEvents.length);
    expect(store.runUpserts[0]).toMatchObject({
      firstSequence: 1,
      lastSequence: 5,
      eventCount: 5,
      status: "active",
    });
  });

  it("acknowledges a resend as duplicates without increasing persistence", async () => {
    const store = new MemoryStore();
    await processIngest(body(validEvents), store);
    const result = await processIngest(body(validEvents), store);

    expect(result.body).toMatchObject({
      summary: { accepted: 0, duplicates: validEvents.length, rejected: 0 },
    });
    expect(store.events.size).toBe(validEvents.length);
    expect(store.runUpserts[1]?.eventCount).toBe(validEvents.length);
  });

  it("reports valid and schema-invalid events independently", async () => {
    const invalid = clone(validEvents[1]);
    invalid.event_type = "not-an-event";
    const store = new MemoryStore();
    const result = await processIngest(body([validEvents[0], invalid]), store);

    expect(result.body).toMatchObject({
      summary: { accepted: 1, duplicates: 0, rejected: 1 },
      results: [
        { event_id: validEvents[0].event_id, status: "accepted" },
        {
          event_id: invalid.event_id,
          status: "rejected",
          reason: "schema-invalid",
        },
      ],
    });
  });

  it("reports exact per-batch metrics without changing the summary shape", async () => {
    const runKey = "run-slice16-ingest-metrics";
    const priced = runEvent(validEvents[1], runKey, 10);
    priced.weapon = {
      status: "known",
      dcs_type: "AIM_120C",
      display_name: "AIM-120C",
      category: "missile",
    };
    const unpriced = runEvent(validEvents[1], runKey, 11);
    unpriced.weapon = {
      status: "unknown",
      reason: "type-not-reported",
      dcs_type: null,
      display_name: null,
      category: "unknown",
    };
    const unmodeled = runEvent(validEvents[0], runKey, 12);
    unmodeled.event_type = "mission.heartbeat";
    unmodeled.payload = {};
    const invalid = runEvent(validEvents[0], runKey, 13);
    invalid.event_type = "not-an-event";
    const store = new MemoryStore();

    const result = await processIngest(
      body([priced, unpriced, unmodeled, invalid]),
      store,
    );
    const response = result.body as {
      summary: Record<string, number>;
      metrics: { unpriced: number; unknown: number };
    };

    expect(result.httpStatus).toBe(200);
    expect(response.summary).toEqual({
      accepted: 3,
      duplicates: 0,
      rejected: 1,
    });
    expect(response.metrics).toEqual({ unpriced: 1, unknown: 1 });
  });

  it("returns one result per event in input order", async () => {
    const store = new MemoryStore();
    const result = await processIngest(body(validEvents), store);
    const response = result.body as {
      results: { event_id: string }[];
    };

    expect(response.results.map((event) => event.event_id)).toEqual(
      validEvents.map((event) => event.event_id),
    );
  });

  it("marks a run ended and records the ending wall time", async () => {
    const ended = clone(validEvents[0]);
    ended.event_sequence = 6;
    ended.event_type = "mission.ended";
    ended.event_id = `${ended.producer_id}:${ended.run_key}:6`;
    ended.wall_time = "2026-08-30T12:10:00Z";
    ended.payload = { reason: "mission-end-observed" };
    const store = new MemoryStore();

    await processIngest(body([ended]), store);

    expect(store.runUpserts[0]).toMatchObject({
      firstSequence: 6,
      lastSequence: 6,
      status: "ended",
      endedAt: ended.wall_time,
    });

    await processIngest(body([ended]), store);
    expect(
      store.runs.get(`${ended.producer_id} ${ended.run_key}`)?.status,
    ).toBe("ended");
  });

  it("keeps rapid-restart runs isolated and accepts final old bytes", async () => {
    const prior = runEvent(validEvents[0], "run-slice16-prior", 1);
    const replacement = runEvent(validEvents[0], "run-slice16-replacement", 1);
    const latePrior = runEvent(validEvents[1], prior.run_key, 2);
    const store = new MemoryStore();
    await processIngest(body([prior]), store);
    await processIngest(body([replacement]), store);
    const lateResult = await processIngest(body([latePrior]), store);

    expect(lateResult.body).toMatchObject({
      summary: { accepted: 1, duplicates: 0, rejected: 0 },
    });
    expect(
      store.runs.get(`${prior.producer_id} ${prior.run_key}`)?.status,
    ).toBe("active");
    expect(
      store.runs.get(`${replacement.producer_id} ${replacement.run_key}`)
        ?.status,
    ).toBe("active");
    expect(store.events.has(latePrior.event_id)).toBe(true);
  });

  it("does not let an old delayed run's first delivery abort a newer active run", async () => {
    const newer = runEvent(validEvents[0], "run-slice16-newer-first", 1);
    const delayedOld = runEvent(validEvents[0], "run-slice16-delayed-old", 1);
    const store = new MemoryStore();

    await processIngest(body([newer]), store);
    await processIngest(body([delayedOld]), store);

    expect(
      store.runs.get(`${newer.producer_id} ${newer.run_key}`)?.status,
    ).toBe("active");
    expect(
      store.runs.get(`${delayedOld.producer_id} ${delayedOld.run_key}`)?.status,
    ).toBe("active");
  });

  it("marks only the matching active run aborted and is idempotent", async () => {
    const target = runEvent(validEvents[0], "run-slice16-abort-target", 1);
    const otherRun = runEvent(validEvents[0], "run-slice16-abort-other", 1);
    const otherProducer = runEvent(
      validEvents[0],
      "run-slice16-abort-target",
      1,
    );
    otherProducer.producer_id = "other-producer";
    const store = new MemoryStore();
    store.runs.set(
      `${target.producer_id} ${target.run_key}`,
      storedRun(target),
    );
    store.runs.set(
      `${otherRun.producer_id} ${otherRun.run_key}`,
      storedRun(otherRun),
    );
    store.runs.set(
      `${otherProducer.producer_id} ${otherProducer.run_key}`,
      storedRun(otherProducer),
    );

    expect(await store.markRunAborted(target.producer_id, target.run_key)).toBe(
      1,
    );
    expect(
      store.runs.get(`${target.producer_id} ${target.run_key}`)?.status,
    ).toBe("aborted");
    expect(
      store.runs.get(`${otherRun.producer_id} ${otherRun.run_key}`)?.status,
    ).toBe("active");
    expect(
      store.runs.get(`${otherProducer.producer_id} ${otherProducer.run_key}`)
        ?.status,
    ).toBe("active");

    expect(await store.markRunAborted(target.producer_id, target.run_key)).toBe(
      0,
    );
    expect(store.markAbortedCalls).toEqual([
      {
        producerId: target.producer_id,
        runKey: target.run_key,
        affected: 1,
      },
      {
        producerId: target.producer_id,
        runKey: target.run_key,
        affected: 0,
      },
    ]);
  });

  it("does not abort an ended run", async () => {
    const ended = runEvent(validEvents[0], "run-slice16-abort-ended", 1);
    const store = new MemoryStore();
    store.runs.set(
      `${ended.producer_id} ${ended.run_key}`,
      storedRun(ended, "ended"),
    );

    expect(await store.markRunAborted(ended.producer_id, ended.run_key)).toBe(
      0,
    );
    expect(
      store.runs.get(`${ended.producer_id} ${ended.run_key}`)?.status,
    ).toBe("ended");
  });

  it("ratchets an aborted run to ended on a later ended upsert", async () => {
    const event = runEvent(validEvents[0], "run-slice16-abort-ratchet", 1);
    const store = new MemoryStore();
    const run = storedRun(event);
    store.runs.set(`${event.producer_id} ${event.run_key}`, run);
    await store.markRunAborted(event.producer_id, event.run_key);

    await store.upsertRun({
      ...run,
      eventCount: 1,
      endedAt: "2026-09-07T00:00:00Z",
      status: "ended",
    });

    expect(
      store.runs.get(`${event.producer_id} ${event.run_key}`)?.status,
    ).toBe("ended");
  });

  it("keeps a run active for continuation batches and duplicate re-passes", async () => {
    const started = runEvent(validEvents[0], "run-slice16-continuing", 1);
    const continuation = runEvent(validEvents[1], started.run_key, 2);
    const store = new MemoryStore();
    await processIngest(body([started]), store);
    await processIngest(body([continuation]), store);
    await processIngest(body([started, continuation]), store);

    expect(
      store.runs.get(`${started.producer_id} ${started.run_key}`)?.status,
    ).toBe("active");
  });

  it("keeps an aborted run terminal when late events and duplicates arrive", async () => {
    const prior = runEvent(validEvents[0], "run-slice16-late-prior", 1);
    const replacement = runEvent(validEvents[0], "run-slice16-late-new", 1);
    const late = runEvent(validEvents[1], prior.run_key, 2);
    const store = new MemoryStore();
    await processIngest(body([prior]), store);
    await store.markRunAborted(prior.producer_id, prior.run_key);
    await processIngest(body([replacement]), store);

    await processIngest(body([late]), store);
    await processIngest(body([late]), store);

    expect(
      store.runs.get(`${prior.producer_id} ${prior.run_key}`)?.status,
    ).toBe("aborted");
  });

  it("never changes other active runs when a third run is ingested", async () => {
    const first = runEvent(validEvents[0], "run-slice16-active-one", 1);
    const second = runEvent(validEvents[0], "run-slice16-active-two", 1);
    const replacement = runEvent(validEvents[0], "run-slice16-active-three", 1);
    const store = new MemoryStore();
    store.runs.set(`${first.producer_id} ${first.run_key}`, storedRun(first));
    store.runs.set(
      `${second.producer_id} ${second.run_key}`,
      storedRun(second),
    );

    await processIngest(body([replacement]), store);

    expect(
      store.runs.get(`${first.producer_id} ${first.run_key}`)?.status,
    ).toBe("active");
    expect(
      store.runs.get(`${second.producer_id} ${second.run_key}`)?.status,
    ).toBe("active");
    expect(
      store.runs.get(`${replacement.producer_id} ${replacement.run_key}`)
        ?.status,
    ).toBe("active");
  });

  it("keeps runs active without an explicit mission ended event", async () => {
    const started = runEvent(validEvents[0], "run-slice16-no-end", 1);
    const heartbeat = runEvent(validEvents[0], started.run_key, 2);
    heartbeat.event_type = "mission.heartbeat";
    heartbeat.payload = {};
    const shot = runEvent(validEvents[1], started.run_key, 3);
    const store = new MemoryStore();

    await processIngest(body([started, heartbeat, shot]), store);

    expect(
      store.runs.get(`${started.producer_id} ${started.run_key}`)?.status,
    ).toBe("active");
  });

  it("assigns new runs the current catalogue and projects expenditures", async () => {
    const first = clone(validEvents[1]);
    first.run_key = "run-slice12-new";
    first.event_sequence = 10;
    first.event_id = `${first.producer_id}:${first.run_key}:10`;
    first.weapon = {
      status: "known",
      dcs_type: "AIM_120C",
      display_name: "AIM-120C",
      category: "missile",
    };
    const second = clone(first);
    second.event_sequence = 11;
    second.event_id = `${first.producer_id}:${first.run_key}:11`;
    second.weapon = {
      status: "known",
      dcs_type: "AIM_9X",
      display_name: "AIM-9X",
      category: "missile",
    };
    const store = new MemoryStore();

    const result = await processIngest(body([first, second]), store);

    expect(result.body).toMatchObject({
      summary: { accepted: 2, duplicates: 0, rejected: 0 },
    });
    expect(store.runUpserts[0]).toMatchObject({
      valuationCatalogue: "ordnance",
      valuationCatalogueVersion: 1,
    });
    expect(store.expenditures.size).toBe(2);
    expect(
      [...store.expenditures.values()].map((item) => item.unitCostCents),
    ).toEqual([105000000, 44709300]);
  });

  it("repairs a missing projection on replay without double-charging", async () => {
    const event = clone(validEvents[1]);
    event.run_key = "run-slice12-repair";
    event.event_sequence = 10;
    event.event_id = `${event.producer_id}:${event.run_key}:10`;
    event.weapon = {
      status: "known",
      dcs_type: "AIM_120C",
      display_name: "AIM-120C",
      category: "missile",
    };
    const store = new MemoryStore();
    await processIngest(body([event]), store);
    expect(store.expenditures.size).toBe(1);

    store.expenditures.clear();
    const replay = await processIngest(body([event]), store);

    expect(replay.body).toMatchObject({
      summary: { accepted: 0, duplicates: 1, rejected: 0 },
    });
    expect(store.expenditures.size).toBe(1);
    const third = await processIngest(body([event]), store);
    expect(third.body).toMatchObject({
      summary: { accepted: 0, duplicates: 1, rejected: 0 },
    });
    expect(store.expenditures.size).toBe(1);
  });

  it("leaves pre-existing unassigned runs unpriced", async () => {
    const event = clone(validEvents[1]);
    event.run_key = "run-slice12-historical";
    event.event_sequence = 10;
    event.event_id = `${event.producer_id}:${event.run_key}:10`;
    event.weapon = {
      status: "known",
      dcs_type: "AIM_120C",
      display_name: "AIM-120C",
      category: "missile",
    };
    const store = new MemoryStore();
    store.runs.set(`${event.producer_id} ${event.run_key}`, {
      producerId: event.producer_id,
      runKey: event.run_key,
      valuationCatalogue: null,
      valuationCatalogueVersion: null,
      firstSequence: 1,
      lastSequence: 9,
      eventCount: 9,
      status: "active",
    });

    await processIngest(body([event]), store);

    const merged = store.runs.get(`${event.producer_id} ${event.run_key}`);
    expect(merged?.valuationCatalogue ?? null).toBeNull();
    expect(merged?.valuationCatalogueVersion ?? null).toBeNull();
    expect(store.expenditures.size).toBe(0);
    expect(store.losses.size).toBe(0);
    expect(store.runEventReads).toBe(1);
  });

  it("projects combat facts for an unassigned historical run without a second run read", async () => {
    const runKey = "run-slice14-historical";
    const source = clone(validEvents[4]);
    source.run_key = runKey;
    source.event_sequence = 10;
    source.event_id = `${source.producer_id}:${runKey}:10`;
    const sourceTarget = source.target as Record<string, unknown>;
    sourceTarget.asset_key = "bandit.u1.g1";
    const assistHit = clone(source);
    assistHit.event_sequence = 9;
    assistHit.event_id = `${source.producer_id}:${runKey}:9`;
    assistHit.event_type = "asset.hit";
    assistHit.sim_time = source.sim_time - 10;
    assistHit.initiator = {
      status: "known",
      kind: "aircraft",
      participant_id: null,
      asset_key: "wingman.u1.g1",
      display_name: null,
      callsign: null,
      dcs_name: "Wingman-1-1",
      dcs_type: "FA-18C_hornet",
      coalition: "blue",
    };
    const store = new MemoryStore();
    store.runs.set(`${source.producer_id} ${runKey}`, {
      producerId: source.producer_id,
      runKey,
      valuationCatalogue: null,
      valuationCatalogueVersion: null,
      firstSequence: 1,
      lastSequence: 8,
      eventCount: 8,
      status: "active",
    });

    await processIngest(body([assistHit, source]), store);

    expect(store.losses.size).toBe(0);
    expect(store.kills.size).toBe(1);
    expect(store.assists.size).toBe(1);
    expect(store.runEventReads).toBe(1);
  });

  it("advances participant labels by event sequence", async () => {
    const first = clone(validEvents[1]);
    first.run_key = "run-slice12-labels";
    first.event_sequence = 10;
    first.event_id = `${first.producer_id}:${first.run_key}:10`;
    const second = clone(first);
    second.event_sequence = 11;
    second.event_id = `${first.producer_id}:${first.run_key}:11`;
    second.participant = {
      ...(first.participant as Record<string, unknown>),
      display_name: "Viper-actual",
    };
    const store = new MemoryStore();

    await processIngest(body([first, second]), store);

    const participant = store.participants.get(
      `${first.producer_id} ${first.run_key} ucid-0123456789abcdef`,
    );
    expect(participant?.displayName).toBe("Viper-actual");
    expect(participant?.eventSequence).toBe(11);
  });

  it("reconciles repeated aircraft loss signals into one persisted charge", async () => {
    const runKey = "run-slice13-repeated";
    const events = [
      lossEvent({ runKey, sequence: 10, eventType: "asset.dead" }),
      lossEvent({ runKey, sequence: 11, eventType: "asset.crashed" }),
      lossEvent({
        runKey,
        sequence: 12,
        eventType: "asset.dead",
        payload: { dcs_event_name: "UnitLost" },
      }),
    ];
    const store = new MemoryStore();

    await processIngest(body(events), store);

    expect(store.losses.size).toBe(1);
    const persisted = [...store.losses.values()];
    expect(persisted[0]?.sourceEventIds).toEqual(
      events.map((event) => event.event_id),
    );
    expect(aggregateAssetLosts(persisted)).toEqual({
      lossCount: 1,
      knownSubtotalCents: 2_900_000_000,
      unpricedCount: 0,
      partial: false,
    });
  });

  it("ignores despawn and pilot outcomes while ejection does not cancel loss", async () => {
    const runKey = "run-slice13-non-loss";
    const events = [
      lossEvent({
        runKey,
        sequence: 10,
        eventType: "asset.despawned",
        payload: { reason: "intentional" },
      }),
      lossEvent({ runKey, sequence: 11, eventType: "pilot.dead" }),
      lossEvent({ runKey, sequence: 12, eventType: "pilot.ejected" }),
      lossEvent({ runKey, sequence: 13, eventType: "asset.dead" }),
    ];
    const store = new MemoryStore();

    await processIngest(body(events.slice(0, 3)), store);
    expect(store.losses.size).toBe(0);
    await processIngest(body([events[3]]), store);

    expect(store.losses.size).toBe(1);
    expect([...store.losses.values()][0]?.sourceEventIds).toEqual([
      events[3].event_id,
    ]);
  });

  it("does not project losses for a pre-existing unassigned run", async () => {
    const event = lossEvent({
      runKey: "run-slice13-historical",
      sequence: 10,
      eventType: "asset.dead",
    });
    const store = new MemoryStore();
    store.runs.set(`${event.producer_id} ${event.run_key}`, {
      producerId: event.producer_id,
      runKey: event.run_key,
      valuationCatalogue: null,
      valuationCatalogueVersion: null,
      firstSequence: 1,
      lastSequence: 9,
      eventCount: 9,
      status: "active",
    });

    await processIngest(body([event]), store);

    expect(store.events.size).toBe(1);
    expect(store.losses.size).toBe(0);
  });

  it("charges same-named distinct asset incarnations separately", async () => {
    const runKey = "run-slice13-incarnations";
    const store = new MemoryStore();
    await processIngest(
      body([
        lossEvent({
          runKey,
          sequence: 10,
          eventType: "asset.dead",
          assetKey: "aerial-1.u1.g1",
          dcsName: "Aerial-1-1",
        }),
        lossEvent({
          runKey,
          sequence: 11,
          eventType: "asset.dead",
          assetKey: "aerial-1.u1.g2",
          dcsName: "Aerial-1-1",
        }),
      ]),
      store,
    );

    expect(store.losses.size).toBe(2);
    expect(aggregateAssetLosts([...store.losses.values()])).toMatchObject({
      lossCount: 2,
      knownSubtotalCents: 5_800_000_000,
      partial: false,
    });
  });

  it("evolves one loss across batch boundaries and remains stable on replay", async () => {
    const runKey = "run-slice13-batches";
    const dead = lossEvent({
      runKey,
      sequence: 10,
      eventType: "asset.dead",
    });
    const crashed = lossEvent({
      runKey,
      sequence: 11,
      eventType: "asset.crashed",
    });
    const store = new MemoryStore();

    await processIngest(body([dead]), store);
    const initialFactId = [...store.losses.values()][0]?.factId;
    await processIngest(body([crashed]), store);

    expect(store.losses.size).toBe(1);
    const afterSecondBatch = [...store.losses.values()];
    expect(afterSecondBatch[0]?.factId).not.toBe(initialFactId);
    expect(afterSecondBatch[0]?.sourceEventIds).toEqual([
      dead.event_id,
      crashed.event_id,
    ]);
    const totals = aggregateAssetLosts(afterSecondBatch);
    expect(totals.knownSubtotalCents).toBe(2_900_000_000);

    await processIngest(body([dead]), store);
    await processIngest(body([crashed]), store);
    expect(store.losses.size).toBe(1);
    expect(aggregateAssetLosts([...store.losses.values()])).toEqual(totals);
    expect([...store.losses.values()][0]?.sourceEventIds).toEqual([
      dead.event_id,
      crashed.event_id,
    ]);
  });

  it("identical duplicate retry reconverges every projection and run summary", async () => {
    const events = repairStream("run-s16-p7-identical");
    const store = new MemoryStore();
    await processIngest(body(events), store);
    const before = {
      run: structuredClone(
        store.runs.get(`${events[0]?.producer_id} ${events[0]?.run_key}`),
      ),
      expenditures: clone([...store.expenditures.values()]),
      losses: clone([...store.losses.values()]),
      kills: clone([...store.kills.values()]),
      assists: clone([...store.assists.values()]),
      participants: clone([...store.participants.values()]),
    };

    const retry = await processIngest(body(events), store);

    expect(retry.body).toMatchObject({
      summary: { accepted: 0, duplicates: events.length, rejected: 0 },
    });
    expect({
      run: store.runs.get(`${events[0]?.producer_id} ${events[0]?.run_key}`),
      expenditures: [...store.expenditures.values()],
      losses: [...store.losses.values()],
      kills: [...store.kills.values()],
      assists: [...store.assists.values()],
      participants: [...store.participants.values()],
    }).toEqual(before);
    expectReconciledState(store, events);
  });

  it("content conflict is rejected without mutating retained truth or projections", async () => {
    const events = repairStream("run-s16-p7-conflict");
    const store = new MemoryStore();
    await processIngest(body(events), store);
    const retainedBefore = [...store.events.values()].map((event) =>
      JSON.stringify(event),
    );
    const conflictingStarted = clone(events[0]!);
    conflictingStarted.payload.mission_name = "conflicting-mission";
    const conflictingFired = clone(events[1]!);
    (conflictingFired.participant as Record<string, unknown>).display_name =
      "Conflicting Pilot";
    conflictingFired.payload = { injected: "not-retained" };

    const result = await processIngest(
      body([conflictingStarted, conflictingFired, ...events.slice(2)]),
      store,
    );

    expect(result.body).toMatchObject({
      results: [
        {
          event_id: conflictingStarted.event_id,
          status: "rejected",
          reason: "content-conflict",
        },
        {
          event_id: conflictingFired.event_id,
          status: "rejected",
          reason: "content-conflict",
        },
        ...events.slice(2).map((event) => ({
          event_id: event.event_id,
          status: "duplicate",
        })),
      ],
      summary: { accepted: 0, duplicates: 3, rejected: 2 },
    });
    expect(
      [...store.events.values()].map((event) => JSON.stringify(event)),
    ).toEqual(retainedBefore);
    const run = store.runs.get(
      `${events[0]?.producer_id} ${events[0]?.run_key}`,
    );
    expect(run?.missionName).toBe("duel-dynamic");
    expect([...store.participants.values()][0]?.displayName).toBe("Viper");
    expectReconciledState(store, events);
  });

  it("failure between raw insert and summary update is repaired by an identical retry", async () => {
    const events = repairStream("run-s16-p7-summary-failure");
    const store = new MemoryStore();
    store.failNext("summary");

    await expect(processIngest(body(events), store)).rejects.toThrow(
      "injected-summary-failure",
    );
    expect(store.events.size).toBe(events.length);
    expect(store.runs.size).toBe(0);

    const retry = await processIngest(body(events), store);

    expect(retry.body).toMatchObject({
      summary: { accepted: 0, duplicates: events.length, rejected: 0 },
    });
    expect(
      store.runs.get(`${events[0]?.producer_id} ${events[0]?.run_key}`),
    ).toMatchObject({
      eventCount: events.length,
      firstSequence: 1,
      lastSequence: 5,
      startedAt: events[0]?.wall_time,
    });
    expectReconciledState(store, events);
  });

  it.each([
    "expenditures",
    "participants",
    "losses",
    "kills",
    "assists",
  ] as const)(
    "failure before %s projection is repaired exactly once by retry",
    async (stage) => {
      const events = repairStream(`run-s16-p7-${stage}-failure`);
      const store = new MemoryStore();
      store.failNext(stage);

      await expect(processIngest(body(events), store)).rejects.toThrow(
        `injected-${stage}-failure`,
      );
      await processIngest(body(events), store);
      const repaired = {
        expenditures: store.expenditures.size,
        participants: store.participants.size,
        losses: store.losses.size,
        kills: store.kills.size,
        assists: store.assists.size,
      };
      await processIngest(body(events), store);

      expect({
        expenditures: store.expenditures.size,
        participants: store.participants.size,
        losses: store.losses.size,
        kills: store.kills.size,
        assists: store.assists.size,
      }).toEqual(repaired);
      expectReconciledState(store, events);
    },
  );

  it("commit-before-response-loss for a whole batch converges all projections", async () => {
    const events = repairStream("run-s16-p7-response-loss");
    const store = new MemoryStore();
    store.failNext("expenditures");

    await expect(processIngest(body(events), store)).rejects.toThrow(
      "injected-expenditures-failure",
    );
    expect(store.events.size).toBe(events.length);
    expect(
      store.runs.get(`${events[0]?.producer_id} ${events[0]?.run_key}`)
        ?.eventCount,
    ).toBe(events.length);
    expect(store.expenditures.size).toBe(0);
    expect(store.participants.size).toBe(0);
    expect(store.losses.size).toBe(0);
    expect(store.kills.size).toBe(0);
    expect(store.assists.size).toBe(0);

    const retry = await processIngest(body(events), store);

    expect(retry.body).toMatchObject({
      summary: { accepted: 0, duplicates: events.length, rejected: 0 },
    });
    expectReconciledState(store, events);
  });

  it("aborted-run ratchet is preserved until retained mission ended takes precedence", async () => {
    const events = repairStream("run-s16-p7-aborted-ratchet");
    const store = new MemoryStore();
    await processIngest(body(events), store);
    await store.markRunAborted(events[0]!.producer_id, events[0]!.run_key);

    await processIngest(body(events), store);
    expect(
      store.runs.get(`${events[0]?.producer_id} ${events[0]?.run_key}`)?.status,
    ).toBe("aborted");

    const ended = runEvent(validEvents[0], events[0]!.run_key, 6);
    ended.event_type = "mission.ended";
    ended.payload = { reason: "mission-end-observed" };
    await processIngest(body([ended]), store);
    expect(
      store.runs.get(`${events[0]?.producer_id} ${events[0]?.run_key}`)?.status,
    ).toBe("ended");
  });

  it("unassigned-catalogue run gates costs but still repairs combat facts", async () => {
    const events = repairStream("run-s16-p7-unassigned");
    const store = new MemoryStore();
    store.runs.set(`${events[0]?.producer_id} ${events[0]?.run_key}`, {
      ...storedRun(events[0]!),
      valuationCatalogue: null,
      valuationCatalogueVersion: null,
      eventCount: 0,
    });

    await processIngest(body(events), store);

    expect(store.expenditures.size).toBe(0);
    expect(store.losses.size).toBe(0);
    expect(store.kills.size).toBe(1);
    expect(store.assists.size).toBe(1);
    expect(store.participants.size).toBe(1);
  });
});

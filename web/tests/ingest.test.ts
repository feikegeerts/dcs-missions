import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import type {
  EventRow,
  ExpenditureRow,
  RunParticipantRow,
  RunParticipantUpsert,
  RunRow,
  RunUpsertInput,
  TelemetryStore,
} from "../src/telemetry/store";
import type { ExpenditureProjection } from "../src/telemetry/expenditures";
import { processIngest } from "../src/telemetry/ingest";
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

class MemoryStore implements TelemetryStore {
  readonly events = new Map<string, TelemetryEvent>();
  readonly runs = new Map<string, RunUpsertInput>();
  readonly runUpserts: RunUpsertInput[] = [];
  readonly expenditures = new Map<string, ExpenditureProjection>();
  readonly participants = new Map<string, FakeParticipant>();

  async insertEvent(
    event: TelemetryEvent,
  ): Promise<"accepted" | "duplicate" | "rejected"> {
    if (this.events.has(event.event_id)) {
      return "duplicate";
    }
    this.events.set(event.event_id, event);
    return "accepted";
  }

  async upsertRun(run: RunUpsertInput): Promise<void> {
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
      valuationCatalogue:
        existing.valuationCatalogue ?? run.valuationCatalogue ?? null,
      valuationCatalogueVersion:
        existing.valuationCatalogueVersion ??
        run.valuationCatalogueVersion ??
        null,
      acceptedDelta: existing.acceptedDelta + run.acceptedDelta,
    });
  }

  async insertExpenditure(
    expenditure: ExpenditureProjection,
  ): Promise<"inserted" | "existing"> {
    if (this.expenditures.has(expenditure.sourceEventId)) {
      return "existing";
    }
    this.expenditures.set(expenditure.sourceEventId, expenditure);
    return "inserted";
  }

  async upsertRunParticipant(participant: RunParticipantUpsert): Promise<void> {
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

  async listExpenditures(): Promise<ExpenditureRow[]> {
    return [];
  }

  async listRunParticipants(): Promise<RunParticipantRow[]> {
    return [];
  }
}

type FakeParticipant = RunParticipantUpsert & {
  displayNameSequence: number | null;
  callsignSequence: number | null;
};

describe("telemetry ingest", () => {
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
      acceptedDelta: 5,
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
    expect(store.runUpserts[1]?.acceptedDelta).toBe(0);
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
      acceptedDelta: 9,
      status: "active",
    });

    await processIngest(body([event]), store);

    const merged = store.runs.get(`${event.producer_id} ${event.run_key}`);
    expect(merged?.valuationCatalogue ?? null).toBeNull();
    expect(merged?.valuationCatalogueVersion ?? null).toBeNull();
    expect(store.expenditures.size).toBe(0);
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
});

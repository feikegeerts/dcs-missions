import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import type {
  EventRow,
  RunRow,
  RunUpsertInput,
  TelemetryStore,
} from "../src/telemetry/store";
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
  readonly runs: RunUpsertInput[] = [];

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
    this.runs.push(run);
  }

  async listRuns(): Promise<RunRow[]> {
    return [];
  }

  async getRunByRunKey(): Promise<RunRow | null> {
    return null;
  }

  async listEvents(): Promise<EventRow[]> {
    return [];
  }
}

describe("telemetry ingest", () => {
  it("accepts events and upserts the run summary", async () => {
    const store = new MemoryStore();
    const result = await processIngest(body(validEvents), store);

    expect(result).toMatchObject({ httpStatus: 200 });
    expect(result.body).toMatchObject({
      summary: { accepted: validEvents.length, duplicates: 0, rejected: 0 },
    });
    expect(store.events.size).toBe(validEvents.length);
    expect(store.runs[0]).toMatchObject({
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
    expect(store.runs[1]?.acceptedDelta).toBe(0);
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

    expect(store.runs[0]).toMatchObject({
      firstSequence: 6,
      lastSequence: 6,
      status: "ended",
      endedAt: ended.wall_time,
    });
  });
});

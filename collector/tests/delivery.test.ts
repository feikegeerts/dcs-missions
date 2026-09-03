import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { Collector } from "../src/collector.js";
import { deliver } from "../src/delivery.js";
import type { DeliveryOptions } from "../src/delivery.js";
import { DurableSpool } from "../src/spool.js";
import type { TelemetryEvent } from "../src/types.js";
import { createEventValidator } from "../src/validator.js";
import {
  cloneEvent,
  createWorkspace,
  fixture,
  forRun,
  schemaPath,
  type TestWorkspace,
  writeRun,
} from "./helpers.js";

type IngestStatus = "accepted" | "duplicate" | "rejected";

interface FetchCall {
  input: Parameters<typeof fetch>[0];
  init: Parameters<typeof fetch>[1];
}

interface FetchRecorder {
  calls: FetchCall[];
  fetchImpl: typeof fetch;
}

const baseUrl = "https://telemetry.invalid";
const testToken = "delivery-test-token-never-print";

describe("spool delivery", () => {
  let workspace: TestWorkspace | undefined;
  let spool: DurableSpool | undefined;

  afterEach(() => {
    spool?.close();
    workspace?.cleanup();
    spool = undefined;
    workspace = undefined;
  });

  function setup(runs: TelemetryEvent[][]): DurableSpool {
    workspace = createWorkspace();
    spool = new DurableSpool(join(workspace.state, "collector.sqlite3"));
    runs.forEach((events, index) => {
      writeRun(workspace!.input, `run-${index}.ndjson`, events);
    });
    const collected = new Collector({
      inputDirectory: workspace.input,
      spool,
      validator: createEventValidator(schemaPath),
    }).collect();
    expect(collected.spooled).toBe(
      runs.reduce((sum, run) => sum + run.length, 0),
    );
    return spool;
  }

  function deliveryOptions(
    database: DurableSpool,
    recorder: FetchRecorder,
    overrides: Partial<DeliveryOptions> = {},
  ): DeliveryOptions {
    return {
      spool: database,
      baseUrl,
      token: testToken,
      fetchImpl: recorder.fetchImpl,
      ...overrides,
    };
  }

  it("delivers a complete 16-event run with exact canonical event bytes", async () => {
    const events = makeRun(16, "run-happy", "delivery-producer", true, true);
    const database = setup([events]);
    const canonical = database
      .listDeliverable(events[0]!.producer_id, events[0]!.run_key, 100)
      .map((item) => item.canonical_json);
    const recorder = recordFetch((call) => acceptedResponse(bodyFrom(call)));

    const summary = await deliver(deliveryOptions(database, recorder));

    expect(recorder.calls).toHaveLength(1);
    recorder.calls.forEach((call) => {
      const body = bodyFrom(call);
      const envelope = JSON.parse(body) as Record<string, unknown>;
      expect(Object.keys(envelope).sort()).toEqual([
        "batch_schema_version",
        "events",
      ]);
      const posted = eventsFrom(call);
      expect(new Set(posted.map((event) => event.producer_id)).size).toBe(1);
      expect(new Set(posted.map((event) => event.run_key)).size).toBe(1);
      expect(posted.map((event) => event.event_sequence)).toEqual(
        contiguous(posted[0]!.event_sequence, posted.length),
      );
    });
    expect(bodyFrom(recorder.calls[0]!)).toBe(bodyForCanonicals(canonical));
    expect(summary).toMatchObject({
      dry_run: false,
      had_failure: false,
      totals: { batches_posted: 1, events_posted: 16, accepted: 16 },
      runs: [
        {
          state: "complete",
          acknowledged_through: 16,
          batches: [{ seq_start: 1, seq_end: 16, event_count: 16 }],
        },
      ],
    });
    expect(database.listRuns()[0]?.acknowledged_through).toBe(16);
  });

  it("does not fetch on a second pass after a complete run is acknowledged", async () => {
    const events = makeRun(16, "run-second-pass");
    const database = setup([events]);
    const first = recordFetch((call) => acceptedResponse(bodyFrom(call)));
    await deliver(deliveryOptions(database, first));
    const second = recordFetch(() => {
      throw new Error("second pass must not fetch");
    });

    const summary = await deliver(deliveryOptions(database, second));

    expect(second.calls).toHaveLength(0);
    expect(summary).toMatchObject({
      had_failure: false,
      totals: { batches_posted: 0, events_posted: 0, runs_complete: 1 },
      runs: [{ state: "complete", acknowledged_through: 16, batches: [] }],
    });
  });

  it("acknowledges a fresh spool when every server result is duplicate", async () => {
    const events = makeRun(16, "run-server-duplicates");
    const database = setup([events]);
    const recorder = recordFetch((call) =>
      resultResponse(bodyFrom(call), () => "duplicate"),
    );

    const summary = await deliver(deliveryOptions(database, recorder));

    expect(summary).toMatchObject({
      had_failure: false,
      totals: { accepted: 0, duplicates: 16, events_posted: 16 },
      runs: [{ state: "complete", acknowledged_through: 16 }],
    });
    expect(database.listRuns()[0]?.acknowledged_through).toBe(16);
  });

  it("reposts safely after a mid-batch server crash", async () => {
    const events = makeRun(16, "run-server-crash");
    const database = setup([events]);
    const recorder = recordFetch((call, index) => {
      if (index === 0) {
        throw new Error("simulated connection loss");
      }
      return resultResponse(bodyFrom(call), (event) =>
        event.event_sequence <= 3 ? "duplicate" : "accepted",
      );
    });

    const first = await deliver(deliveryOptions(database, recorder));
    expect(first).toMatchObject({
      had_failure: true,
      totals: { batches_posted: 1, events_posted: 16 },
      runs: [{ state: "error", acknowledged_through: 0 }],
    });
    expect(database.listRuns()[0]?.acknowledged_through).toBe(0);

    const second = await deliver(deliveryOptions(database, recorder));
    expect(second).toMatchObject({
      had_failure: false,
      totals: { accepted: 13, duplicates: 3, events_posted: 16 },
      runs: [{ state: "complete", acknowledged_through: 16 }],
    });
    expect(recorder.calls).toHaveLength(2);
    expect(eventsFrom(recorder.calls[1]!)).toHaveLength(16);
    expect(database.listRuns()[0]?.acknowledged_through).toBe(16);
  });

  it("blocks at a rejected event while independently draining another run", async () => {
    const blockedEvents = makeRun(16, "run-a-blocked");
    const completeEvents = makeRun(16, "run-b-complete");
    const database = setup([blockedEvents, completeEvents]);
    const recorder = recordFetch((call) =>
      resultResponse(bodyFrom(call), (event) =>
        event.run_key === "run-a-blocked" && event.event_sequence === 5
          ? "rejected"
          : "accepted",
      ),
    );

    const first = await deliver(deliveryOptions(database, recorder));
    expect(first.had_failure).toBe(true);
    expect(first.runs).toEqual([
      expect.objectContaining({
        run_key: "run-a-blocked",
        state: "blocked",
        acknowledged_through: 4,
        blocked_at_sequence: 5,
        blocked_event_id: `${blockedEvents[0]!.producer_id}:run-a-blocked:5`,
        blocked_reason: "schema-invalid",
      }),
      expect.objectContaining({
        run_key: "run-b-complete",
        state: "complete",
        acknowledged_through: 16,
      }),
    ]);
    expect(first.totals).toMatchObject({
      runs_blocked: 1,
      runs_complete: 1,
      rejected: 1,
    });

    recorder.calls.length = 0;
    const second = await deliver(deliveryOptions(database, recorder));
    expect(recorder.calls).toHaveLength(1);
    expect(eventsFrom(recorder.calls[0]!)[0]?.event_sequence).toBe(5);
    expect(second.runs[0]).toMatchObject({
      state: "blocked",
      acknowledged_through: 4,
      blocked_at_sequence: 5,
    });
    expect(second.runs[1]).toMatchObject({ state: "complete" });
  });

  it("splits a 150-event run at the 100-event boundary", async () => {
    const events = makeRun(150, "run-batch-limit");
    const database = setup([events]);
    const recorder = recordFetch((call) => acceptedResponse(bodyFrom(call)));

    const summary = await deliver(deliveryOptions(database, recorder));

    expect(recorder.calls).toHaveLength(2);
    expect(
      recorder.calls.map((call) =>
        eventsFrom(call).map((event) => event.event_sequence),
      ),
    ).toEqual([contiguous(1, 100), contiguous(101, 50)]);
    expect(summary).toMatchObject({
      totals: { batches_posted: 2, events_posted: 150, accepted: 150 },
      runs: [
        {
          state: "complete",
          acknowledged_through: 150,
          batches: [
            { seq_start: 1, seq_end: 100, event_count: 100 },
            { seq_start: 101, seq_end: 150, event_count: 50 },
          ],
        },
      ],
    });
  });

  it("splits batches at the exact UTF-8 body cap", async () => {
    const events = makeRun(16, "run-byte-cap");
    const database = setup([events]);
    const deliverable = database.listDeliverable(
      events[0]!.producer_id,
      events[0]!.run_key,
      100,
    );
    const fourEventSizes = [0, 4, 8, 12].map((start) =>
      Buffer.byteLength(
        bodyForCanonicals(
          deliverable
            .slice(start, start + 4)
            .map((item) => item.canonical_json),
        ),
      ),
    );
    const fiveEventSizes = [0, 4, 8].map((start) =>
      Buffer.byteLength(
        bodyForCanonicals(
          deliverable
            .slice(start, start + 5)
            .map((item) => item.canonical_json),
        ),
      ),
    );
    const maxBodyBytes = Math.max(...fourEventSizes);
    expect(maxBodyBytes).toBeLessThan(Math.min(...fiveEventSizes));
    const recorder = recordFetch((call) => acceptedResponse(bodyFrom(call)));

    const summary = await deliver(
      deliveryOptions(database, recorder, { maxBodyBytes }),
    );

    expect(recorder.calls).toHaveLength(4);
    expect(
      recorder.calls.map((call) =>
        eventsFrom(call).map((event) => event.event_sequence),
      ),
    ).toEqual([
      contiguous(1, 4),
      contiguous(5, 4),
      contiguous(9, 4),
      contiguous(13, 4),
    ]);
    expect(summary).toMatchObject({
      totals: { batches_posted: 4, events_posted: 16 },
      runs: [{ state: "complete", acknowledged_through: 16 }],
    });
  });

  it("reports raw run summaries in dry-run mode without fetching or mutation", async () => {
    const events = makeRun(16, "run-dry");
    const database = setup([events]);
    const before = database.listRuns();
    const recorder = recordFetch(() => {
      throw new Error("dry run must not fetch");
    });

    const summary = await deliver(
      deliveryOptions(database, recorder, { dryRun: true }),
    );

    expect(recorder.calls).toHaveLength(0);
    expect(summary).toEqual({
      dry_run: true,
      url: baseUrl,
      runs: before,
      totals: {
        batches_posted: 0,
        events_posted: 0,
        accepted: 0,
        duplicates: 0,
        rejected: 0,
        runs_complete: 0,
        runs_incomplete: 0,
        runs_blocked: 0,
        runs_error: 0,
      },
      had_failure: false,
    });
    expect(database.listRuns()[0]?.acknowledged_through).toBe(0);
  });

  it("acks nothing when a 200 response omits one event result", async () => {
    const events = makeRun(16, "run-bad-response");
    const database = setup([events]);
    const recorder = recordFetch((call) => {
      const response = responsePayload(bodyFrom(call), () => "accepted");
      response.results.pop();
      response.summary.accepted -= 1;
      return jsonResponse(response);
    });

    const summary = await deliver(deliveryOptions(database, recorder));

    expect(summary).toMatchObject({
      had_failure: true,
      runs: [
        {
          state: "error",
          error: "unexpected response shape",
          acknowledged_through: 0,
        },
      ],
    });
    expect(database.listRuns()[0]?.acknowledged_through).toBe(0);
  });

  it("reports a 401 body without exposing the ingest token or acknowledging", async () => {
    const events = makeRun(16, "run-unauthorized");
    const database = setup([events]);
    const recorder = recordFetch(
      () =>
        new Response('{"error":"unauthorized"}', {
          status: 401,
          headers: { "content-type": "application/json" },
        }),
    );

    const summary = await deliver(deliveryOptions(database, recorder));
    const serialized = JSON.stringify(summary);

    expect(summary).toMatchObject({
      had_failure: true,
      runs: [
        {
          state: "error",
          acknowledged_through: 0,
          error: expect.stringContaining('{"error":"unauthorized"}'),
        },
      ],
    });
    expect(serialized.includes(testToken)).toBe(false);
    expect(database.listRuns()[0]?.acknowledged_through).toBe(0);
  });
});

function makeRun(
  count: number,
  runKey: string,
  producerId = "delivery-producer",
  complete = true,
  includeOrdnance = false,
): TelemetryEvent[] {
  return Array.from({ length: count }, (_, index) => {
    const sequence = index + 1;
    let event: TelemetryEvent;
    if (sequence === 1) {
      event = forRun(fixture("01-mission-started.json"), runKey, producerId);
    } else if (sequence === 2 && includeOrdnance) {
      event = forRun(fixture("02-ordnance-fired.json"), runKey, producerId);
    } else {
      event = forRun(
        cloneEvent(fixture("01-mission-started.json")),
        runKey,
        producerId,
      );
      event.event_type = "mission.heartbeat";
      event.payload = { heartbeat: sequence };
    }
    event.event_sequence = sequence;
    event.event_id = `${producerId}:${runKey}:${sequence}`;
    event.sim_time = sequence;
    if (complete && sequence === count) {
      event.event_type = "mission.ended";
      event.initiator = null;
      event.target = null;
      event.participant = null;
      event.asset = null;
      event.weapon = null;
      event.coalition = null;
      event.location = null;
      event.payload = { reason: "mission-end-observed" };
    }
    return event;
  });
}

function recordFetch(
  handler: (call: FetchCall, index: number) => Response | Promise<Response>,
): FetchRecorder {
  const calls: FetchCall[] = [];
  const fetchImpl = (async (input, init) => {
    const call = { input, init };
    calls.push(call);
    return handler(call, calls.length - 1);
  }) as typeof fetch;
  return { calls, fetchImpl };
}

function bodyFrom(call: FetchCall): string {
  if (typeof call.init?.body !== "string") {
    throw new Error("expected a string request body");
  }
  return call.init.body;
}

function eventsFrom(call: FetchCall): TelemetryEvent[] {
  const parsed = JSON.parse(bodyFrom(call)) as { events: TelemetryEvent[] };
  return parsed.events;
}

function acceptedResponse(body: string): Response {
  return resultResponse(body, () => "accepted");
}

function resultResponse(
  body: string,
  statusFor: (event: TelemetryEvent) => IngestStatus,
): Response {
  return jsonResponse(responsePayload(body, statusFor));
}

function responsePayload(
  body: string,
  statusFor: (event: TelemetryEvent) => IngestStatus,
): {
  results: Array<{ event_id: string; status: IngestStatus; reason?: string }>;
  summary: { accepted: number; duplicates: number; rejected: number };
} {
  const events = (JSON.parse(body) as { events: TelemetryEvent[] }).events;
  const summary = { accepted: 0, duplicates: 0, rejected: 0 };
  const results = events.map((event) => {
    const status = statusFor(event);
    if (status === "accepted") {
      summary.accepted += 1;
    } else if (status === "duplicate") {
      summary.duplicates += 1;
    } else {
      summary.rejected += 1;
    }
    return {
      event_id: event.event_id,
      status,
      ...(status === "rejected" ? { reason: "schema-invalid" } : {}),
    };
  });
  return { results, summary };
}

function jsonResponse(value: unknown): Response {
  return new Response(JSON.stringify(value), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

function bodyForCanonicals(canonicals: string[]): string {
  return `{"batch_schema_version":1,"events":[${canonicals.join(",")}]}`;
}

function contiguous(start: number, count: number): number[] {
  return Array.from({ length: count }, (_, index) => start + index);
}

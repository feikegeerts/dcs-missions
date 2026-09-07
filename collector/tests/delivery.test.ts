import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

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
      processObservationProvider: () => ({ state: "known-running" }),
      dcsProducerIdProvider: () => "delivery-producer",
      dcsLogTextProvider: () => "",
      ...overrides,
    };
  }

  function boundProcessObservation(
    runKey: string,
    state: "known-running" | "known-not-running" | "unknown",
    hookGeneration = 9,
  ) {
    return {
      state,
      pid: 4242,
      creationTime: "2026-09-07T10:00:00.000Z",
      runKey,
      hookGeneration,
      profilePath: "C:/Saved Games/DCS.dcs_serverrelease",
      inputPath: "C:/Saved Games/DCS.dcs_serverrelease/Logs/telemetry",
    } as const;
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

    const first = await deliver(
      deliveryOptions(database, recorder, { maxAttempts: 1 }),
    );
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
      abort_signals: [],
    });
    expect(database.listRuns()[0]?.acknowledged_through).toBe(0);
    expect(database.getDeliveryHealth()).toEqual([]);
  });

  it("posts an abort when the DCS process is not running", async () => {
    const events = makeRun(2, "run-process-dead", undefined, false);
    const database = setup([events]);
    const recorder = recordFetch((call) =>
      isAbortCall(call)
        ? jsonResponse({ aborted: 1 })
        : acceptedResponse(bodyFrom(call)),
    );

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        processObservationProvider: () =>
          boundProcessObservation("run-process-dead", "known-not-running"),
        dcsLogTextProvider: () =>
          "TELEMETRY_BRIDGE_HOOK handshake-ok generation=9 run=run-process-dead producer=delivery-producer",
      }),
    );
    const abortCalls = recorder.calls.filter(isAbortCall);

    expect(abortCalls).toHaveLength(1);
    expect(String(abortCalls[0]!.input)).toBe(
      `${baseUrl}/api/telemetry/runs/run-process-dead`,
    );
    expect(abortCalls[0]!.init?.headers).toEqual({
      "content-type": "application/json",
      authorization: `Bearer ${testToken}`,
    });
    expect(bodyFrom(abortCalls[0]!)).toBe(
      '{"reason":"dcs-process-not-running","producer_id":"delivery-producer"}',
    );
    expect(summary.abort_signals).toEqual([
      {
        producerId: "delivery-producer",
        runKey: "run-process-dead",
        reason: "dcs-process-not-running",
        posted: true,
        retryRequired: false,
        status: 200,
      },
    ]);
  });

  it("does not abort an active run while the DCS process is running", async () => {
    const events = makeRun(2, "run-process-running", undefined, false);
    const database = setup([events]);
    const recorder = recordFetch((call) => acceptedResponse(bodyFrom(call)));

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        processObservationProvider: () =>
          boundProcessObservation("run-process-running", "known-running"),
        dcsLogTextProvider: () =>
          "TELEMETRY_BRIDGE_HOOK handshake-ok generation=9 run=run-process-running producer=delivery-producer",
      }),
    );

    expect(recorder.calls.filter(isAbortCall)).toEqual([]);
    expect(summary.abort_signals).toEqual([]);
  });

  it("does not abort when process detection is unknown", async () => {
    const events = makeRun(2, "run-process-unknown", undefined, false);
    const database = setup([events]);
    const recorder = recordFetch((call) => acceptedResponse(bodyFrom(call)));

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        processObservationProvider: () =>
          boundProcessObservation("run-process-unknown", "unknown"),
        dcsLogTextProvider: () =>
          "TELEMETRY_BRIDGE_HOOK handshake-ok generation=9 run=run-process-unknown producer=delivery-producer",
      }),
    );

    expect(recorder.calls.filter(isAbortCall)).toEqual([]);
    expect(summary.abort_signals).toEqual([]);
    expect(summary.runs[0]).toMatchObject({
      state: "incomplete",
      acknowledged_through: 2,
    });
  });

  it("isolates rapid-restart runs and targets only the stopped generation", async () => {
    const oldEvents = makeRun(3, "run-rapid-old", undefined, false);
    const newEvents = makeRun(2, "run-rapid-new", undefined, false);
    const database = setup([oldEvents, newEvents]);
    const recorder = recordFetch((call) =>
      isAbortCall(call)
        ? jsonResponse({ aborted: 1 })
        : acceptedResponse(bodyFrom(call)),
    );

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        dcsLogTextProvider: () =>
          "TELEMETRY_BRIDGE_HOOK handshake-ok generation=11 run=run-rapid-old producer=delivery-producer\nTELEMETRY_BRIDGE_HOOK STOP generation=11 spooled=3 spool=C:/Saved Games/DCS/Logs/telemetry/run-rapid-old.ndjson failures=0 stuck=nil unspooled=unknown",
      }),
    );
    const abortCalls = recorder.calls.filter(isAbortCall);

    expect(abortCalls).toHaveLength(1);
    expect(String(abortCalls[0]!.input)).toContain("/run-rapid-old");
    expect(bodyFrom(abortCalls[0]!)).toBe(
      '{"reason":"simulation-stop-observed","producer_id":"delivery-producer","generation":11}',
    );
    expect(summary.runs).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          run_key: "run-rapid-old",
          acknowledged_through: 3,
        }),
        expect.objectContaining({
          run_key: "run-rapid-new",
          acknowledged_through: 2,
        }),
      ]),
    );
  });

  it("does not abort a run whose spool contains mission.ended", async () => {
    const events = makeRun(2, "run-ended", undefined, true);
    const database = setup([events]);
    const recorder = recordFetch((call) => acceptedResponse(bodyFrom(call)));

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        processObservationProvider: () =>
          boundProcessObservation("run-ended", "known-not-running"),
        dcsLogTextProvider: () =>
          "TELEMETRY_BRIDGE_HOOK handshake-ok generation=9 run=run-ended producer=delivery-producer",
      }),
    );

    expect(recorder.calls.filter(isAbortCall)).toEqual([]);
    expect(summary.abort_signals).toEqual([]);
  });

  it("posts a simulation-stop abort for a matching STOP line", async () => {
    const events = makeRun(2, "run-clean-stop", undefined, false);
    const database = setup([events]);
    const recorder = recordFetch((call) =>
      isAbortCall(call)
        ? jsonResponse({ aborted: 1 })
        : acceptedResponse(bodyFrom(call)),
    );

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        dcsLogTextProvider: () =>
          "TELEMETRY_BRIDGE_HOOK handshake-ok generation=9 run=run-clean-stop producer=delivery-producer\nTELEMETRY_BRIDGE_HOOK STOP generation=9 spooled=2 spool=C:/Saved Games/DCS/Logs/telemetry/run-clean-stop.ndjson failures=0 stuck=nil unspooled=0",
      }),
    );
    const abortCalls = recorder.calls.filter(isAbortCall);

    expect(abortCalls).toHaveLength(1);
    expect(bodyFrom(abortCalls[0]!)).toBe(
      '{"reason":"simulation-stop-observed","producer_id":"delivery-producer","generation":9}',
    );
    expect(summary.abort_signals).toEqual([
      expect.objectContaining({
        reason: "simulation-stop-observed",
        generation: 9,
        posted: true,
        retryRequired: false,
      }),
    ]);
  });

  it("records a temporary lifecycle API outage for retry without a state flip", async () => {
    const events = makeRun(2, "run-abort-fails", undefined, false);
    const database = setup([events]);
    const recorder = recordFetch((call) => {
      if (isAbortCall(call)) {
        throw new Error(`abort failed with ${testToken}`);
      }
      return acceptedResponse(bodyFrom(call));
    });

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        processObservationProvider: () =>
          boundProcessObservation("run-abort-fails", "known-not-running"),
        dcsLogTextProvider: () =>
          "TELEMETRY_BRIDGE_HOOK handshake-ok generation=9 run=run-abort-fails producer=delivery-producer",
      }),
    );

    expect(summary.had_failure).toBe(false);
    expect(summary.runs[0]).toMatchObject({ state: "incomplete" });
    expect(summary.abort_signals).toEqual([
      expect.objectContaining({
        posted: false,
        retryRequired: true,
        error: "abort failed with [REDACTED]",
      }),
    ]);
  });

  it("records a lifecycle POST timeout for retry without changing delivery state", async () => {
    const events = makeRun(2, "run-abort-timeout", undefined, false);
    const database = setup([events]);
    const recorder = recordFetch((call) => {
      if (!isAbortCall(call)) {
        return acceptedResponse(bodyFrom(call));
      }
      return new Promise<Response>((_resolve, reject) => {
        call.init?.signal?.addEventListener("abort", () =>
          reject(new Error("aborted")),
        );
      });
    });

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        timeoutMs: 1,
        processObservationProvider: () =>
          boundProcessObservation("run-abort-timeout", "known-not-running"),
        dcsLogTextProvider: () =>
          "TELEMETRY_BRIDGE_HOOK handshake-ok generation=9 run=run-abort-timeout producer=delivery-producer",
      }),
    );

    expect(summary.had_failure).toBe(false);
    expect(summary.runs[0]).toMatchObject({
      state: "incomplete",
      acknowledged_through: 2,
    });
    expect(summary.abort_signals).toEqual([
      expect.objectContaining({
        posted: false,
        retryRequired: true,
        error: "request timed out after 1 ms",
      }),
    ]);
  });

  it("does not evaluate or post abort signals during a dry run", async () => {
    const events = makeRun(2, "run-dry-abort", undefined, false);
    const database = setup([events]);
    const recorder = recordFetch(() => {
      throw new Error("dry run must not fetch");
    });
    const processObservationProvider = vi.fn(() => ({
      state: "known-not-running" as const,
    }));
    const dcsLogTextProvider = vi.fn(() => "STOP");

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        dryRun: true,
        processObservationProvider,
        dcsLogTextProvider,
      }),
    );

    expect(recorder.calls).toEqual([]);
    expect(processObservationProvider).not.toHaveBeenCalled();
    expect(dcsLogTextProvider).not.toHaveBeenCalled();
    expect(summary.abort_signals).toEqual([]);
  });

  it("records successful delivery health with the injected timestamp", async () => {
    const events = makeRun(16, "run-health-success");
    const database = setup([events]);
    const recorder = recordFetch((call) => acceptedResponse(bodyFrom(call)));

    await deliver(
      deliveryOptions(database, recorder, {
        nowProvider: () => "2026-09-06T00:00:00.000Z",
      }),
    );

    expect(database.getDeliveryHealth()).toEqual([
      {
        producerId: "delivery-producer",
        runKey: "run-health-success",
        lastAttemptAt: "2026-09-06T00:00:00.000Z",
        lastSuccessAt: "2026-09-06T00:00:00.000Z",
        lastError: null,
      },
    ]);
  });

  it("records redacted failure health while preserving prior success", async () => {
    const events = makeRun(16, "run-health-failure");
    const database = setup([events]);
    database.recordDeliveryAttempt({
      producerId: "delivery-producer",
      runKey: "run-health-failure",
      at: "2026-09-05T00:00:00.000Z",
      success: true,
      error: null,
    });
    const recorder = recordFetch(
      () => new Response(`invalid ${testToken}`, { status: 400 }),
    );

    await deliver(
      deliveryOptions(database, recorder, {
        nowProvider: () => "2026-09-06T00:00:00.000Z",
      }),
    );

    expect(database.getDeliveryHealth()).toEqual([
      {
        producerId: "delivery-producer",
        runKey: "run-health-failure",
        lastAttemptAt: "2026-09-06T00:00:00.000Z",
        lastSuccessAt: "2026-09-05T00:00:00.000Z",
        lastError: "HTTP 400: invalid [REDACTED]",
      },
    ]);
  });

  it("records blocked delivery health with sequence and redacted reason", async () => {
    const events = makeRun(16, "run-health-blocked");
    const database = setup([events]);
    const recorder = recordFetch((call) => {
      const response = responsePayload(bodyFrom(call), (event) =>
        event.event_sequence === 5 ? "rejected" : "accepted",
      );
      response.results[4]!.reason = `invalid ${testToken}`;
      return jsonResponse(response);
    });

    await deliver(
      deliveryOptions(database, recorder, {
        nowProvider: () => "2026-09-06T00:00:00.000Z",
      }),
    );

    expect(database.getDeliveryHealth()[0]).toEqual({
      producerId: "delivery-producer",
      runKey: "run-health-blocked",
      lastAttemptAt: "2026-09-06T00:00:00.000Z",
      lastSuccessAt: null,
      lastError: "blocked at sequence 5: invalid [REDACTED]",
    });
  });

  it("retries a timeout and a 500 before delivering successfully", async () => {
    const events = makeRun(16, "run-transient-success");
    const database = setup([events]);
    const delays: number[] = [];
    const recorder = recordFetch((call, index) => {
      if (index === 0) {
        return new Promise<Response>((_resolve, reject) => {
          call.init?.signal?.addEventListener(
            "abort",
            () => reject(new Error("aborted by timeout")),
            { once: true },
          );
        });
      }
      if (index === 1) {
        return new Response("temporary server error", { status: 500 });
      }
      return acceptedResponse(bodyFrom(call));
    });
    vi.useFakeTimers();

    try {
      const delivery = deliver(
        deliveryOptions(database, recorder, {
          timeoutMs: 10,
          sleepImpl: async (ms) => {
            delays.push(ms);
          },
        }),
      );
      await vi.advanceTimersByTimeAsync(10);
      const summary = await delivery;

      expect(recorder.calls).toHaveLength(3);
      expect(recorder.calls.map(bodyFrom)).toEqual([
        bodyFrom(recorder.calls[0]!),
        bodyFrom(recorder.calls[0]!),
        bodyFrom(recorder.calls[0]!),
      ]);
      expect(delays).toEqual([1000, 2000]);
      expect(summary).toMatchObject({
        had_failure: false,
        runs: [
          {
            state: "complete",
            attempts: 3,
            acknowledged_through: 16,
          },
        ],
      });
      expect(summary.runs[0]).not.toHaveProperty("error");
      expect(database.listRuns()[0]?.acknowledged_through).toBe(16);
    } finally {
      vi.useRealTimers();
    }
  });

  it("stops after exhausting transient network retries", async () => {
    const events = makeRun(16, "run-transient-exhausted");
    const database = setup([events]);
    const delays: number[] = [];
    const recorder = recordFetch((_call, index) => {
      throw new Error(`network down ${index + 1}`);
    });

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        sleepImpl: async (ms) => {
          delays.push(ms);
        },
      }),
    );

    expect(recorder.calls).toHaveLength(3);
    expect(delays).toEqual([1000, 2000]);
    expect(summary).toMatchObject({
      had_failure: true,
      runs: [
        {
          state: "error",
          attempts: 3,
          acknowledged_through: 0,
          error: "network error: network down 3 (after 3 attempts)",
        },
      ],
    });
    expect(database.listRuns()[0]?.acknowledged_through).toBe(0);
  });

  it("retries HTTP 429 before delivering successfully", async () => {
    const events = makeRun(16, "run-rate-limited");
    const database = setup([events]);
    const delays: number[] = [];
    const recorder = recordFetch((call, index) =>
      index === 0
        ? new Response("rate limited", { status: 429 })
        : acceptedResponse(bodyFrom(call)),
    );

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        sleepImpl: async (ms) => {
          delays.push(ms);
        },
      }),
    );

    expect(summary.runs[0]).toMatchObject({ state: "complete", attempts: 2 });
    expect(delays).toEqual([1000]);
  });

  it("retries HTTP 5xx before delivering successfully", async () => {
    const events = makeRun(16, "run-service-unavailable");
    const database = setup([events]);
    const delays: number[] = [];
    const recorder = recordFetch((call, index) =>
      index === 0
        ? new Response("service unavailable", { status: 503 })
        : acceptedResponse(bodyFrom(call)),
    );

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        sleepImpl: async (ms) => {
          delays.push(ms);
        },
      }),
    );

    expect(summary.runs[0]).toMatchObject({ state: "complete", attempts: 2 });
    expect(delays).toEqual([1000]);
  });

  it("fails HTTP 400 immediately without a retry delay", async () => {
    const events = makeRun(16, "run-bad-request");
    const database = setup([events]);
    const delays: number[] = [];
    const recorder = recordFetch(() =>
      Promise.resolve(new Response("bad request", { status: 400 })),
    );

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        sleepImpl: async (ms) => {
          delays.push(ms);
        },
      }),
    );

    expect(summary.runs[0]).toMatchObject({
      state: "error",
      attempts: 1,
      error: "HTTP 400: bad request",
    });
    expect(delays).toEqual([]);
  });

  it("fails HTTP 401 immediately without retrying authentication", async () => {
    const events = makeRun(16, "run-auth-failure");
    const database = setup([events]);
    const delays: number[] = [];
    const recorder = recordFetch(() =>
      Promise.resolve(new Response("unauthorized", { status: 401 })),
    );

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        sleepImpl: async (ms) => {
          delays.push(ms);
        },
      }),
    );

    expect(recorder.calls).toHaveLength(1);
    expect(summary.runs[0]).toMatchObject({ state: "error", attempts: 1 });
    expect(delays).toEqual([]);
  });

  it("fails an invalid 200 response without retrying", async () => {
    const events = makeRun(16, "run-invalid-success");
    const database = setup([events]);
    const delays: number[] = [];
    const recorder = recordFetch(() =>
      Promise.resolve(jsonResponse("garbage")),
    );

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        sleepImpl: async (ms) => {
          delays.push(ms);
        },
      }),
    );

    expect(recorder.calls).toHaveLength(1);
    expect(summary.runs[0]).toMatchObject({
      state: "error",
      attempts: 1,
      error: "unexpected response shape",
    });
    expect(delays).toEqual([]);
  });

  it("makes one transient attempt when maxAttempts is one", async () => {
    const events = makeRun(16, "run-single-attempt");
    const database = setup([events]);
    const delays: number[] = [];
    const recorder = recordFetch(() => {
      throw new Error("offline");
    });

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        maxAttempts: 1,
        sleepImpl: async (ms) => {
          delays.push(ms);
        },
      }),
    );

    expect(recorder.calls).toHaveLength(1);
    expect(summary.runs[0]).toMatchObject({
      state: "error",
      attempts: 1,
      error: "network error: offline (after 1 attempts)",
    });
    expect(delays).toEqual([]);
  });

  it("repeats the last retry delay when the delay list is short", async () => {
    const events = makeRun(16, "run-short-delay-list");
    const database = setup([events]);
    const delays: number[] = [];
    const recorder = recordFetch(() => {
      throw new Error("offline");
    });

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        maxAttempts: 3,
        retryDelaysMs: [500],
        sleepImpl: async (ms) => {
          delays.push(ms);
        },
      }),
    );

    expect(summary.runs[0]).toMatchObject({ state: "error", attempts: 3 });
    expect(delays).toEqual([500, 500]);
  });

  it("records one attempt and no retry delay for a clean delivery", async () => {
    const events = makeRun(16, "run-clean-attempt");
    const database = setup([events]);
    const delays: number[] = [];
    const recorder = recordFetch((call) => acceptedResponse(bodyFrom(call)));

    const summary = await deliver(
      deliveryOptions(database, recorder, {
        sleepImpl: async (ms) => {
          delays.push(ms);
        },
      }),
    );

    expect(summary.runs[0]).toMatchObject({ state: "complete", attempts: 1 });
    expect(delays).toEqual([]);
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

function isAbortCall(call: FetchCall): boolean {
  return String(call.input).includes("/api/telemetry/runs/");
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

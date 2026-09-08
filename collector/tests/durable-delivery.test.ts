import { join } from "node:path";

import Database from "better-sqlite3";
import { afterEach, describe, expect, it } from "vitest";

import { canonicalJson } from "../src/canonical-json.js";
import { deliver } from "../src/delivery.js";
import type { DeliveryOptions } from "../src/delivery.js";
import { DurableSpool } from "../src/spool.js";
import type { TelemetryEvent } from "../src/types.js";
import {
  cloneEvent,
  createWorkspace,
  fixture,
  type TestWorkspace,
} from "./helpers.js";

const baseUrl = "http://127.0.0.1:3000";
const token = "durable-secret";

describe("fair durable delivery and lifecycle outbox", () => {
  let workspace: TestWorkspace | undefined;
  let spool: DurableSpool | undefined;

  afterEach(() => {
    spool?.close();
    workspace?.cleanup();
    spool = undefined;
    workspace = undefined;
  });

  function open(): DurableSpool {
    workspace ??= createWorkspace();
    spool = new DurableSpool(join(workspace.state, "collector.sqlite3"));
    return spool;
  }

  it("gives a historical backlog and active run at most one batch each per pass", async () => {
    const database = open();
    events(205, "run-a-history", true).forEach((event) =>
      database.insertEvent(event),
    );
    events(2, "run-z-active", false).forEach((event) =>
      database.insertEvent(event),
    );
    const posted: TelemetryEvent[][] = [];
    const options = deliveryOptions(database, async (_input, init) => {
      const batch = requestEvents(init);
      posted.push(batch);
      return accepted(batch);
    });

    const first = await deliver(options);
    expect(first.dry_run).toBe(false);
    if (first.dry_run) throw new Error("expected active delivery summary");
    expect(first.runs.map((run) => [run.run_key, run.batches_posted])).toEqual([
      ["run-a-history", 1],
      ["run-z-active", 1],
    ]);
    expect(posted.map((batch) => [batch[0]!.run_key, batch.length])).toEqual([
      ["run-a-history", 100],
      ["run-z-active", 2],
    ]);

    database.insertEvent(event(3, "run-z-active", false));
    posted.length = 0;
    await deliver(options);
    expect(
      posted.map((batch) => [batch[0]!.run_key, batch[0]!.event_sequence]),
    ).toEqual([
      ["run-a-history", 101],
      ["run-z-active", 3],
    ]);
  });

  it("survives restart with attempt count and deadline and does not retry early", async () => {
    let database = open();
    database.insertEvent(event(1, "run-restart", false));
    let now = "2026-09-07T00:00:00.000Z";
    let calls = 0;
    const fetchImpl: typeof fetch = async () => {
      calls += 1;
      throw new Error("offline");
    };
    await deliver(
      deliveryOptions(database, fetchImpl, {
        nowProvider: () => now,
        randomProvider: () => 0.5,
      }),
    );
    database.close();
    spool = undefined;
    database = open();

    await deliver(
      deliveryOptions(database, fetchImpl, {
        nowProvider: () => now,
        randomProvider: () => 0.5,
      }),
    );
    expect(calls).toBe(1);
    expect(database.getRunRetryState("producer", "run-restart")).toMatchObject({
      attemptCount: 1,
      nextAttemptAt: "2026-09-07T00:00:01.000Z",
    });
    now = "2026-09-07T00:00:01.000Z";
    await deliver(
      deliveryOptions(database, fetchImpl, {
        nowProvider: () => now,
        randomProvider: () => 0.5,
      }),
    );
    expect(calls).toBe(2);
    expect(
      database.getRunRetryState("producer", "run-restart")?.attemptCount,
    ).toBe(2);
  });

  it("persists a permanent gap blocker while another run continues", async () => {
    const database = open();
    events(3, "run-a-blocked", false).forEach((item) =>
      database.insertEvent(item),
    );
    events(2, "run-b-ok", true).forEach((item) => database.insertEvent(item));
    let calls = 0;
    const summary = await deliver(
      deliveryOptions(database, async (_input, init) => {
        calls += 1;
        const batch = requestEvents(init);
        return results(batch, (item) =>
          item.run_key === "run-a-blocked" && item.event_sequence === 2
            ? "rejected"
            : "accepted",
        );
      }),
    );
    expect(summary.runs).toEqual([
      expect.objectContaining({
        run_key: "run-a-blocked",
        state: "blocked",
        blocked_at_sequence: 2,
      }),
      expect.objectContaining({ run_key: "run-b-ok", state: "complete" }),
    ]);
    await deliver(
      deliveryOptions(database, async () => {
        calls += 1;
        throw new Error("blocked run must not retry");
      }),
    );
    expect(calls).toBe(2);
    expect(
      database.getRunRetryState("producer", "run-a-blocked"),
    ).toMatchObject({
      blockedAtSequence: 2,
      blockedEventId: "producer:run-a-blocked:2",
    });
  });

  it("persists an auth circuit and permits one half-open probe", async () => {
    let database = open();
    database.insertEvent(event(1, "run-a", false));
    database.insertEvent(event(1, "run-b", false));
    let now = "2026-09-07T00:00:00.000Z";
    let calls = 0;
    const unauthorized: typeof fetch = async () => {
      calls += 1;
      return new Response("secret rejected", { status: 401 });
    };
    const options = () =>
      deliveryOptions(database, unauthorized, {
        nowProvider: () => now,
        randomProvider: () => 0.5,
      });
    await deliver(options());
    expect(calls).toBe(1);
    expect(database.getDeliveryCircuit()).toMatchObject({
      attemptCount: 1,
      nextProbeAt: "2026-09-07T00:01:00.000Z",
      lastStatus: "HTTP 401: authorization rejected",
    });
    database.close();
    spool = undefined;
    database = open();
    await deliver(options());
    expect(calls).toBe(1);
    now = "2026-09-07T00:01:00.000Z";
    await deliver(options());
    expect(calls).toBe(2);
    expect(database.getDeliveryCircuit()).toMatchObject({
      attemptCount: 2,
      nextProbeAt: "2026-09-07T00:03:00.000Z",
    });
    now = "2026-09-07T00:03:00.000Z";
    const beforeProbe = calls;
    await deliver(
      deliveryOptions(
        database,
        async (_input, init) => {
          calls += 1;
          return accepted(requestEvents(init));
        },
        { nowProvider: () => now, randomProvider: () => 0.5 },
      ),
    );
    expect(calls - beforeProbe).toBe(1);
    expect(database.getDeliveryCircuit()).toBeNull();
  });

  it("retains clear STOP evidence through 404 and restart, then converges", async () => {
    let database = open();
    events(2, "run-stop", false).forEach((item) => database.insertEvent(item));
    let now = "2026-09-07T00:00:00.000Z";
    let lifecycleCalls = 0;
    const firstFetch: typeof fetch = async (input, init) => {
      if (String(input).includes("/runs/")) {
        lifecycleCalls += 1;
        return new Response("missing", { status: 404 });
      }
      return accepted(requestEvents(init));
    };
    const lifecycle = {
      dcsProducerIdProvider: () => "producer",
      dcsLogTextProvider: () =>
        "TELEMETRY_BRIDGE_HOOK handshake-ok generation=7 run=run-stop producer=producer\n" +
        "TELEMETRY_BRIDGE_HOOK STOP generation=7 spooled=2 spool=C:/telemetry/run-stop.ndjson failures=0 stuck=nil unspooled=0",
    };
    await deliver(
      deliveryOptions(database, firstFetch, {
        ...lifecycle,
        nowProvider: () => now,
        randomProvider: () => 0.5,
      }),
    );
    expect(lifecycleCalls).toBe(1);
    expect(database.listLifecycleObservations()[0]).toMatchObject({
      state: "pending",
      attemptCount: 1,
      nextAttemptAt: "2026-09-07T00:00:01.000Z",
    });
    database.close();
    spool = undefined;
    database = open();
    now = "2026-09-07T00:00:01.000Z";
    await deliver(
      deliveryOptions(
        database,
        async (input) => {
          expect(String(input)).toContain("/runs/run-stop");
          lifecycleCalls += 1;
          return new Response('{"aborted":1}', { status: 200 });
        },
        { ...lifecycle, nowProvider: () => now, randomProvider: () => 0.5 },
      ),
    );
    expect(lifecycleCalls).toBe(2);
    expect(database.listLifecycleObservations()[0]).toMatchObject({
      state: "sent",
      attemptCount: 2,
    });
  });

  it("keeps unknown-tail lifecycle evidence pending and prevents prune", async () => {
    const database = open();
    events(2, "run-uncertain", false).forEach((item) =>
      database.insertEvent(item),
    );
    database.recordSourceTail({
      sourcePath: "C:/telemetry/run-uncertain.ndjson",
      producerId: "producer",
      runKey: "run-uncertain",
      observedSize: 101,
      durableOffset: 100,
      tailState: "partial",
      observedAt: "2026-09-07T00:00:00.000Z",
    });
    let calls = 0;
    await deliver(
      deliveryOptions(
        database,
        async (_input, init) => {
          calls += 1;
          return accepted(requestEvents(init));
        },
        {
          dcsProducerIdProvider: () => "producer",
          dcsLogTextProvider: () =>
            "TELEMETRY_BRIDGE_HOOK handshake-ok generation=8 run=run-uncertain producer=producer\n" +
            "TELEMETRY_BRIDGE_HOOK STOP generation=8 spooled=2 spool=C:/telemetry/run-uncertain.ndjson failures=0 stuck=nil unspooled=0",
        },
      ),
    );
    expect(calls).toBe(1);
    expect(database.listLifecycleObservations()[0]).toMatchObject({
      state: "pending",
      tailState: "unknown",
      attemptCount: 0,
    });
    expect(database.pruneDeliveredRuns(false).totalEventsPruned).toBe(0);
  });

  it("reposts a lifecycle observation after response loss and converges idempotently", async () => {
    const database = open();
    events(2, "run-response-loss", false).forEach((item) =>
      database.insertEvent(item),
    );
    let now = "2026-09-07T00:00:00.000Z";
    let lifecycleCalls = 0;
    const observationOptions = {
      dcsProducerIdProvider: () => "producer",
      dcsLogTextProvider: () =>
        "TELEMETRY_BRIDGE_HOOK handshake-ok generation=9 run=run-response-loss producer=producer\n" +
        "TELEMETRY_BRIDGE_HOOK STOP generation=9 spooled=2 spool=C:/telemetry/run-response-loss.ndjson failures=0 stuck=nil unspooled=0",
      nowProvider: () => now,
      randomProvider: () => 0.5,
    };
    await deliver(
      deliveryOptions(
        database,
        async (input, init) => {
          if (!String(input).includes("/runs/")) {
            return accepted(requestEvents(init));
          }
          lifecycleCalls += 1;
          throw new Error("response disappeared after commit");
        },
        observationOptions,
      ),
    );
    expect(database.listLifecycleObservations()[0]).toMatchObject({
      state: "pending",
      attemptCount: 1,
    });
    now = "2026-09-07T00:00:01.000Z";
    await deliver(
      deliveryOptions(
        database,
        async (input) => {
          expect(String(input)).toContain("/runs/run-response-loss");
          lifecycleCalls += 1;
          return new Response('{"aborted":0}', { status: 200 });
        },
        observationOptions,
      ),
    );
    expect(lifecycleCalls).toBe(2);
    expect(database.listLifecycleObservations()[0]).toMatchObject({
      state: "sent",
      attemptCount: 2,
    });
  });

  it("opens an old schema database additively and preserves facts and cursors", () => {
    workspace = createWorkspace();
    const path = join(workspace.state, "collector.sqlite3");
    const old = new Database(path);
    old.exec(`
      CREATE TABLE spool_events (
        event_id TEXT PRIMARY KEY, producer_id TEXT NOT NULL, run_key TEXT NOT NULL,
        event_sequence INTEGER NOT NULL, event_type TEXT NOT NULL, event_json TEXT NOT NULL,
        inserted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        UNIQUE (producer_id, run_key, event_sequence));
      CREATE TABLE source_cursors (
        source_path TEXT PRIMARY KEY, file_device TEXT NOT NULL, file_inode TEXT NOT NULL,
        file_birthtime_ns TEXT NOT NULL, byte_offset INTEGER NOT NULL,
        producer_id TEXT, run_key TEXT);
      CREATE TABLE quarantine (
        quarantine_id TEXT PRIMARY KEY, source_path TEXT NOT NULL, file_device TEXT NOT NULL,
        file_inode TEXT NOT NULL, file_birthtime_ns TEXT NOT NULL, start_offset INTEGER NOT NULL,
        end_offset INTEGER NOT NULL, raw_line BLOB NOT NULL, error_code TEXT NOT NULL,
        error_message TEXT NOT NULL, error_details_json TEXT NOT NULL,
        quarantined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
      CREATE TABLE acknowledgements (
        producer_id TEXT NOT NULL, run_key TEXT NOT NULL, event_sequence INTEGER NOT NULL,
        event_id TEXT NOT NULL UNIQUE, acknowledged_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (producer_id, run_key, event_sequence));
      CREATE TABLE run_delivery_state (
        producer_id TEXT NOT NULL, run_key TEXT NOT NULL, acknowledged_through INTEGER NOT NULL,
        PRIMARY KEY (producer_id, run_key));
      CREATE TABLE delivery_health (
        producer_id TEXT NOT NULL, run_key TEXT NOT NULL, last_attempt_at TEXT NOT NULL,
        last_success_at TEXT, last_error TEXT, PRIMARY KEY (producer_id, run_key));
    `);
    const retained = event(1, "run-old", false);
    old
      .prepare(
        "INSERT INTO spool_events (event_id, producer_id, run_key, event_sequence, event_type, event_json) VALUES (?, ?, ?, ?, ?, ?)",
      )
      .run(
        retained.event_id,
        retained.producer_id,
        retained.run_key,
        retained.event_sequence,
        retained.event_type,
        canonicalJson(retained),
      );
    old
      .prepare("INSERT INTO source_cursors VALUES (?, ?, ?, ?, ?, ?, ?)")
      .run("old.ndjson", "1", "2", "3", 42, "producer", "run-old");
    old.close();

    spool = new DurableSpool(path);
    expect(spool.eventCount()).toBe(1);
    expect(spool.getCursor("old.ndjson")?.offset).toBe(42);
    expect(spool.insertEvent(cloneEvent(retained))).toEqual({
      status: "duplicate",
    });
    expect(spool.listRunRetryStates()).toEqual([]);
    expect(spool.listLifecycleObservations()).toEqual([]);
  });
});

function deliveryOptions(
  spool: DurableSpool,
  fetchImpl: typeof fetch,
  overrides: Partial<DeliveryOptions> = {},
): DeliveryOptions {
  return {
    spool,
    baseUrl,
    token,
    fetchImpl,
    nowProvider: () => "2026-09-07T00:00:00.000Z",
    randomProvider: () => 0.5,
    yieldImpl: async () => {},
    processObservationProvider: () => ({ state: "unknown" }),
    dcsProducerIdProvider: () => null,
    dcsLogTextProvider: () => "",
    ...overrides,
  };
}

function events(
  count: number,
  runKey: string,
  complete: boolean,
): TelemetryEvent[] {
  return Array.from({ length: count }, (_, index) =>
    event(index + 1, runKey, complete && index + 1 === count),
  );
}

function event(
  sequence: number,
  runKey: string,
  ended: boolean,
): TelemetryEvent {
  const value = cloneEvent(fixture("01-mission-started.json"));
  value.producer_id = "producer";
  value.run_key = runKey;
  value.event_sequence = sequence;
  value.event_id = `producer:${runKey}:${sequence}`;
  value.event_type =
    sequence === 1
      ? "mission.started"
      : ended
        ? "mission.ended"
        : "mission.heartbeat";
  value.sim_time = sequence;
  value.payload = ended ? { reason: "mission-end-observed" } : { sequence };
  return value;
}

function requestEvents(init: RequestInit | undefined): TelemetryEvent[] {
  return (JSON.parse(String(init?.body)) as { events: TelemetryEvent[] })
    .events;
}

function accepted(events: TelemetryEvent[]): Response {
  return results(events, () => "accepted");
}

function results(
  events: TelemetryEvent[],
  statusFor: (event: TelemetryEvent) => "accepted" | "duplicate" | "rejected",
): Response {
  const summary = { accepted: 0, duplicates: 0, rejected: 0 };
  const responseResults = events.map((item) => {
    const status = statusFor(item);
    if (status === "accepted") summary.accepted += 1;
    else if (status === "duplicate") summary.duplicates += 1;
    else summary.rejected += 1;
    return {
      event_id: item.event_id,
      status,
      ...(status === "rejected" ? { reason: "content-conflict" } : {}),
    };
  });
  return new Response(JSON.stringify({ results: responseResults, summary }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

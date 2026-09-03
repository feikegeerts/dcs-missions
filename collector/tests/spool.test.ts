import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { canonicalJson } from "../src/canonical-json.js";
import { DurableSpool } from "../src/spool.js";
import type { TelemetryEvent } from "../src/types.js";
import {
  cloneEvent,
  createWorkspace,
  fixture,
  type TestWorkspace,
} from "./helpers.js";

describe("durable spool ordering", () => {
  let workspace: TestWorkspace | undefined;
  let spool: DurableSpool | undefined;

  afterEach(() => {
    spool?.close();
    workspace?.cleanup();
    spool = undefined;
    workspace = undefined;
  });

  function openSpool(): DurableSpool {
    workspace = createWorkspace();
    spool = new DurableSpool(join(workspace.state, "collector.sqlite3"));
    return spool;
  }

  function eventAt(
    sequence: number,
    runKey = "run-list-deliverable",
    producerId = "test-producer",
    eventType = sequence === 1 ? "mission.started" : "mission.heartbeat",
  ): TelemetryEvent {
    const event = cloneEvent(fixture("01-mission-started.json"));
    event.producer_id = producerId;
    event.run_key = runKey;
    event.event_sequence = sequence;
    event.event_id = `${producerId}:${runKey}:${sequence}`;
    event.event_type = eventType;
    event.sim_time = sequence;
    event.payload =
      eventType === "mission.started"
        ? event.payload
        : eventType === "mission.ended"
          ? { reason: "mission-end-observed" }
          : { heartbeat: sequence };
    return event;
  }

  it("buffers out-of-order events and requires mission.started acknowledgement", () => {
    const database = openSpool();
    const started = fixture("01-mission-started.json");
    const fired = fixture("02-ordnance-fired.json");

    expect(database.insertEvent(fired)).toEqual({ status: "inserted" });
    expect(
      database.nextDeliverable(fired.producer_id, fired.run_key),
    ).toBeNull();
    expect(() => database.acknowledge(fired.event_id)).toThrow("expected 1");

    expect(database.insertEvent(started)).toEqual({ status: "inserted" });
    expect(
      database.nextDeliverable(started.producer_id, started.run_key)?.event
        .event_id,
    ).toBe(started.event_id);
    expect(database.acknowledge(started.event_id)).toBe("acknowledged");
    expect(
      database.nextDeliverable(fired.producer_id, fired.run_key)?.event
        .event_id,
    ).toBe(fired.event_id);
    expect(database.acknowledge(fired.event_id)).toBe("acknowledged");
    expect(database.acknowledge(fired.event_id)).toBe("duplicate");
  });

  it("is idempotent by event ID and rejects changed retry content", () => {
    const database = openSpool();
    const started = fixture("01-mission-started.json");
    expect(database.insertEvent(started)).toEqual({ status: "inserted" });
    expect(database.insertEvent(cloneEvent(started))).toEqual({
      status: "duplicate",
    });

    const changed = cloneEvent(started);
    changed.payload = { ...changed.payload, map_name: "Syria" };
    expect(database.insertEvent(changed)).toMatchObject({ status: "conflict" });
    expect(database.eventCount()).toBe(1);
  });

  it("persists events and acknowledgement state across restart", () => {
    const database = openSpool();
    const databasePath = database.databasePath;
    const started = fixture("01-mission-started.json");
    database.insertEvent(started);
    database.acknowledge(started.event_id);
    database.close();
    spool = new DurableSpool(databasePath);

    expect(spool.eventCount()).toBe(1);
    expect(spool.acknowledge(started.event_id)).toBe("duplicate");
    expect(spool.listRuns()).toEqual([
      expect.objectContaining({
        producer_id: started.producer_id,
        run_key: started.run_key,
        acknowledged_through: 1,
      }),
    ]);
  });

  it("rejects a sequence collision even when the event ID differs", () => {
    const database = openSpool();
    const started = fixture("01-mission-started.json");
    database.insertEvent(started);
    const collision = cloneEvent(started) as TelemetryEvent;
    collision.event_id = `${collision.producer_id}:${collision.run_key}:99`;
    expect(database.insertEvent(collision)).toMatchObject({
      status: "conflict",
    });
  });

  it("lists an empty deliverable prefix when the spool or remaining run is empty", () => {
    const database = openSpool();
    expect(database.listDeliverable("missing", "missing", 100)).toEqual([]);

    const only = eventAt(1);
    database.insertEvent(only);
    database.acknowledge(only.event_id);
    expect(
      database.listDeliverable(only.producer_id, only.run_key, 100),
    ).toEqual([]);
  });

  it("lists a contiguous prefix in order up to the limit without mutation", () => {
    const database = openSpool();
    const events = Array.from({ length: 16 }, (_, index) => eventAt(index + 1));
    for (const event of events) {
      database.insertEvent(event);
    }
    const before = database.listRuns();
    const nextBefore = database.nextDeliverable(
      events[0]!.producer_id,
      events[0]!.run_key,
    );

    expect(
      database
        .listDeliverable(events[0]!.producer_id, events[0]!.run_key, 5)
        .map(({ event }) => event.event_sequence),
    ).toEqual([1, 2, 3, 4, 5]);
    expect(database.listRuns()).toEqual(before);
    expect(
      database.nextDeliverable(events[0]!.producer_id, events[0]!.run_key),
    ).toEqual(nextBefore);
  });

  it("stops a deliverable prefix at the first sequence gap", () => {
    const database = openSpool();
    for (const sequence of [1, 2, 3, 4, 6, 7, 8]) {
      database.insertEvent(eventAt(sequence));
    }

    expect(
      database
        .listDeliverable("test-producer", "run-list-deliverable", 100)
        .map(({ event }) => event.event_sequence),
    ).toEqual([1, 2, 3, 4]);
  });

  it("starts the contiguous prefix after the acknowledgement cursor", () => {
    const database = openSpool();
    const events = Array.from({ length: 8 }, (_, index) => eventAt(index + 1));
    for (const event of events) {
      database.insertEvent(event);
    }
    for (const event of events.slice(0, 4)) {
      database.acknowledge(event.event_id);
    }

    expect(
      database
        .listDeliverable("test-producer", "run-list-deliverable", 100)
        .map(({ event }) => event.event_sequence),
    ).toEqual([5, 6, 7, 8]);
  });

  it("refuses a run whose sequence one is not mission.started", () => {
    const database = openSpool();
    const invalidStart = eventAt(1, undefined, undefined, "mission.heartbeat");
    database.insertEvent(invalidStart);
    database.insertEvent(eventAt(2));

    expect(
      database.listDeliverable(
        invalidStart.producer_id,
        invalidStart.run_key,
        100,
      ),
    ).toEqual([]);
  });

  it("keeps nextDeliverable equivalent to a one-event list on mixed runs", () => {
    const database = openSpool();
    for (const sequence of [1, 2, 4]) {
      database.insertEvent(eventAt(sequence));
    }
    database.insertEvent(eventAt(1, "other-run"));

    const producerId = "test-producer";
    const runKey = "run-list-deliverable";
    expect(database.nextDeliverable(producerId, runKey)).toEqual(
      database.listDeliverable(producerId, runKey, 1)[0] ?? null,
    );
    database.acknowledge(eventAt(1).event_id);
    expect(database.nextDeliverable(producerId, runKey)).toEqual(
      database.listDeliverable(producerId, runKey, 1)[0] ?? null,
    );
  });

  it("looks up exact events without changing acknowledgement state", () => {
    const database = openSpool();
    const event = eventAt(1);
    database.insertEvent(event);
    const before = database.listRuns();
    const nextBefore = database.nextDeliverable(
      event.producer_id,
      event.run_key,
    );

    expect(database.getEvent(event.producer_id, event.run_key, 1)).toEqual({
      event,
      canonical_json: canonicalJson(event),
    });
    expect(database.getEvent(event.producer_id, event.run_key, 2)).toBeNull();
    expect(database.getEvent("wrong", event.run_key, 1)).toBeNull();
    expect(database.getEvent(event.producer_id, "wrong", 1)).toBeNull();
    expect(database.listRuns()).toEqual(before);
    expect(database.nextDeliverable(event.producer_id, event.run_key)).toEqual(
      nextBefore,
    );
  });
});

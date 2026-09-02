import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

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
});

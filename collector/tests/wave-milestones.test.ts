import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { Collector } from "../src/collector.js";
import { DurableSpool } from "../src/spool.js";
import { createEventValidator } from "../src/validator.js";
import type { TelemetryEvent } from "../src/types.js";
import {
  cloneEvent,
  createWorkspace,
  fixture,
  schemaPath,
  type TestWorkspace,
  writeRun,
} from "./helpers.js";

function milestone(
  template: TelemetryEvent,
  eventType: string,
  sequence: number,
  payload: Record<string, unknown>,
  runKey: string = template.run_key,
  producerId: string = template.producer_id,
  simTime: number = sequence,
): TelemetryEvent {
  const event = cloneEvent(template);
  event.producer_id = producerId;
  event.run_key = runKey;
  event.event_sequence = sequence;
  event.event_id = `${producerId}:${runKey}:${sequence}`;
  event.event_type = eventType;
  event.sim_time = simTime;
  event.wall_time = null;
  event.initiator = null;
  event.target = null;
  event.participant = null;
  event.asset = null;
  event.weapon = null;
  event.coalition = null;
  event.location = null;
  event.payload = payload;
  return event;
}

function capableStarted(
  runKey: string,
  missionName: string,
  producerId = "dcs-server-alpha",
): TelemetryEvent {
  const started = cloneEvent(fixture("01-mission-started.json"));
  started.producer_id = producerId;
  started.run_key = runKey;
  started.event_sequence = 1;
  started.event_id = `${producerId}:${runKey}:1`;
  started.payload = {
    mission_name: missionName,
    mission_version: "1",
    map_name: "Caucasus",
    run_classification: "historical",
    capabilities: { wave_milestones: 1, gameplay_outcome: 1 },
  };
  return started;
}

function capableStream(runKey: string, missionName: string): TelemetryEvent[] {
  const started = capableStarted(runKey, missionName);
  return [
    started,
    participantEntered(started, 2),
    milestone(started, "wave.spawned", 3, {
      wave_number: 1,
      wave_size: 2,
      donor: "Bandit-1",
      tier: 1,
    }),
    milestone(started, "wave.cleared", 4, { wave_number: 1, wave_size: 2 }),
    milestone(started, "gameplay.ended", 5, { reason: "all-aircraft-lost" }),
    milestone(started, "mission.ended", 6, {
      reason: "mission-end-observed",
    }),
  ];
}

function participantEntered(
  template: TelemetryEvent,
  sequence: number,
): TelemetryEvent {
  const event = cloneEvent(fixture("02-ordnance-fired.json"));
  event.producer_id = template.producer_id;
  event.run_key = template.run_key;
  event.event_sequence = sequence;
  event.event_id = `${template.producer_id}:${template.run_key}:${sequence}`;
  event.event_type = "participant.entered";
  event.initiator = null;
  event.target = null;
  event.weapon = null;
  event.coalition = "blue";
  event.payload = {};
  return event;
}

describe("explicit wave milestones and capabilities", () => {
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

  it("validates capable runs and milestones while keeping legacy runs valid", () => {
    const validator = createEventValidator(schemaPath);
    const started = capableStarted("run-capable", "duel-dynamic-bvr");

    for (const event of capableStream("run-capable", "duel-dynamic-bvr")) {
      expect(validator.validate(event)).toMatchObject({ ok: true });
    }
    expect(
      validator.validate(fixture("01-mission-started.json")),
    ).toMatchObject({
      ok: true,
    });

    const missingNumber = milestone(started, "wave.spawned", 9, {
      wave_size: 2,
    });
    expect(validator.validate(missingNumber)).toMatchObject({
      ok: false,
      code: "schema-invalid",
    });
    expect(
      validator.validate(milestone(started, "wave.cleared", 9, {})),
    ).toMatchObject({ ok: false, code: "schema-invalid" });
    expect(
      validator.validate(milestone(started, "gameplay.ended", 9, {})),
    ).toMatchObject({ ok: false, code: "schema-invalid" });

    const badCapabilities = cloneEvent(started);
    badCapabilities.payload = {
      ...started.payload,
      capabilities: { wave_milestones: 2 },
    };
    expect(validator.validate(badCapabilities)).toMatchObject({
      ok: false,
      code: "schema-invalid",
    });

    const withAsset = milestone(started, "wave.spawned", 9, {
      wave_number: 1,
      wave_size: 1,
    });
    withAsset.asset = cloneEvent(fixture("02-ordnance-fired.json")).asset;
    expect(validator.validate(withAsset)).toMatchObject({
      ok: false,
      code: "schema-invalid",
    });
  });

  it("spools a capable run idempotently with in-order delivery", () => {
    const database = openSpool();
    const stream = capableStream("run-capable-order", "duel-dynamic-acm");
    for (const event of stream) {
      expect(database.insertEvent(event)).toEqual({ status: "inserted" });
    }
    for (const event of stream) {
      expect(database.insertEvent(cloneEvent(event))).toEqual({
        status: "duplicate",
      });
    }
    const changed = cloneEvent(stream[1]!);
    changed.payload = { ...changed.payload, wave_size: 4 };
    expect(database.insertEvent(changed)).toMatchObject({
      status: "conflict",
    });

    const next = database.nextDeliverable(
      stream[0]!.producer_id,
      stream[0]!.run_key,
    );
    expect(next?.event.event_type).toBe("mission.started");
    for (const event of stream) {
      expect(
        database.nextDeliverable(event.producer_id, event.run_key)?.event
          .event_id,
      ).toBe(event.event_id);
      expect(database.acknowledge(event.event_id)).toBe("acknowledged");
    }
    expect(
      database.nextDeliverable(stream[0]!.producer_id, stream[0]!.run_key),
    ).toBeNull();
  });

  it("keeps two mission runs isolated across a mission switch", () => {
    workspace = createWorkspace();
    spool = new DurableSpool(join(workspace.state, "collector.sqlite3"));
    const validator = createEventValidator(schemaPath);
    const collect = (): ReturnType<Collector["collect"]> =>
      new Collector({
        inputDirectory: workspace!.input,
        spool: spool!,
        validator,
      }).collect();

    const bvr = capableStream("run-switch-bvr", "duel-dynamic-bvr");
    const acm = capableStream("run-switch-acm", "duel-dynamic-acm");
    writeRun(workspace.input, "run-switch-bvr.ndjson", bvr);
    writeRun(workspace.input, "run-switch-acm.ndjson", acm);

    expect(collect()).toMatchObject({
      spooled: 12,
      duplicates: 0,
      quarantined: 0,
    });
    expect(spool.eventCount()).toBe(12);
    const runs = spool.listRuns();
    expect(runs).toHaveLength(2);
    expect(runs.map((run) => run.run_key).sort()).toEqual([
      "run-switch-acm",
      "run-switch-bvr",
    ]);

    for (const event of [...bvr, ...acm]) {
      expect(
        spool.nextDeliverable(event.producer_id, event.run_key)?.event.event_id,
      ).toBe(event.event_id);
      expect(spool.acknowledge(event.event_id)).toBe("acknowledged");
    }
    expect(collect()).toMatchObject({ spooled: 0, quarantined: 0 });
    expect(spool.eventCount()).toBe(12);
  });
});

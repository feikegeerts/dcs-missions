import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { describe, expect, it } from "vitest";

const contractRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const schema = readJson(join(contractRoot, "telemetry-event-v1.schema.json"));
const validFixtures = readFixtureDirectory("valid");
const invalidFixtures = readFixtureDirectory("invalid");
const mismatchedEventId = readJson(
  join(contractRoot, "fixtures", "invalid-semantic", "mismatched-event-id.json"),
);
const sequenceGapBatch = readJson(
  join(contractRoot, "fixtures", "invalid-semantic", "batch-sequence-gap.json"),
);

const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
ajv.addSchema(schema);

const validateEvent = ajv.getSchema("urn:dcs-missions:telemetry-event-v1");
const validateBatch = ajv.getSchema(
  "urn:dcs-missions:telemetry-event-v1#/$defs/telemetry_batch_v1",
);

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function readFixtureDirectory(kind) {
  const directory = join(contractRoot, "fixtures", kind);

  return readdirSync(directory)
    .filter((name) => name.endsWith(".json"))
    .sort()
    .map((name) => ({ name, event: readJson(join(directory, name)) }));
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function expectedEventId(event) {
  return `${event.producer_id}:${event.run_key}:${event.event_sequence}`;
}

function withIdentity(template, eventType, eventSequence, overrides = {}) {
  const event = Object.assign(clone(template), overrides, {
    event_type: eventType,
    event_sequence: eventSequence,
  });
  event.event_id = expectedEventId(event);
  return event;
}

function semanticEventErrors(event) {
  const errors = [];

  if (event.event_id !== expectedEventId(event)) {
    errors.push("event ID does not agree with producer, run, and sequence");
  }

  return errors;
}

function semanticBatchErrors(batch) {
  const errors = [];
  const encodedSize = Buffer.byteLength(JSON.stringify(batch), "utf8");

  if (encodedSize > 1_048_576) {
    errors.push("batch exceeds 1,048,576 UTF-8 bytes");
  }

  const first = batch.events[0];
  const eventIds = new Set();
  let previousSequence = null;

  for (const event of batch.events) {
    if (
      event.producer_id !== first.producer_id ||
      event.run_key !== first.run_key
    ) {
      errors.push("batch contains more than one producer or run");
    }

    if (
      previousSequence !== null &&
      event.event_sequence !== previousSequence + 1
    ) {
      errors.push("event sequences are not contiguous and increasing");
    }
    previousSequence = event.event_sequence;

    errors.push(...semanticEventErrors(event));

    if (eventIds.has(event.event_id)) {
      errors.push("batch contains a duplicate event ID");
    }
    eventIds.add(event.event_id);
  }

  return errors;
}

describe("telemetry-event-v1 JSON Schema", () => {
  it.each(validFixtures)("accepts $name", ({ event }) => {
    expect(validateEvent(event), JSON.stringify(validateEvent.errors)).toBe(true);
  });

  it.each(invalidFixtures)("rejects $name", ({ event }) => {
    expect(validateEvent(event)).toBe(false);
  });

  it.each([
    ["missing-schema-version.json", "schema_version"],
    ["missing-producer-id.json", "producer_id"],
    ["missing-run-key.json", "run_key"],
    ["missing-event-sequence.json", "event_sequence"],
    ["missing-event-type.json", "event_type"],
  ])("rejects %s because %s is required", (fixtureName, missingProperty) => {
    const fixture = invalidFixtures.find(({ name }) => name === fixtureName);

    validateEvent(fixture.event);

    expect(validateEvent.errors).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          keyword: "required",
          params: { missingProperty },
        }),
      ]),
    );
  });

  it("rejects malformed actor and weapon structures for ordnance", () => {
    for (const fixtureName of ["malformed-actor.json", "malformed-weapon.json"]) {
      const fixture = invalidFixtures.find(({ name }) => name === fixtureName);
      expect(validateEvent(fixture.event), fixtureName).toBe(false);
    }
  });

  it("accepts a structurally complete example of every event type", () => {
    const started = validFixtures[0].event;
    const shot = validFixtures[1].event;
    const crash = validFixtures[3].event;
    const kill = validFixtures[4].event;
    const lifecycle = (type, sequence, payload = {}) =>
      withIdentity(started, type, sequence, { payload });
    const participant = (type, sequence) =>
      withIdentity(crash, type, sequence);
    const assetLifecycle = (type, sequence, payload = {}) =>
      withIdentity(crash, type, sequence, { participant: null, payload });

    const examples = [
      started,
      lifecycle("mission.ended", 6, { reason: "mission-end-observed" }),
      lifecycle("mission.heartbeat", 7),
      participant("participant.entered", 8),
      participant("participant.left", 9),
      assetLifecycle("asset.spawned", 10),
      assetLifecycle("asset.despawned", 11, { reason: "intentional" }),
      shot,
      withIdentity(kill, "asset.hit", 12),
      kill,
      withIdentity(crash, "asset.dead", 13),
      crash,
      withIdentity(crash, "pilot.dead", 14),
      withIdentity(crash, "pilot.ejected", 15),
    ];

    for (const event of examples) {
      expect(validateEvent(event), `${event.event_type}: ${JSON.stringify(validateEvent.errors)}`).toBe(true);
    }
  });
});

describe("source-event identity and ordering", () => {
  const stream = validFixtures.map(({ event }) => event);

  it("starts with mission.started at sequence one and has no sequence gaps", () => {
    expect(stream[0]).toMatchObject({
      event_type: "mission.started",
      event_sequence: 1,
    });

    expect(stream.map(({ event_sequence }) => event_sequence)).toEqual([
      1, 2, 3, 4, 5,
    ]);
  });

  it("constructs every event ID from producer, run, and sequence", () => {
    for (const event of stream) {
      expect(event.event_id).toBe(expectedEventId(event));
      expect(semanticEventErrors(event)).toEqual([]);
    }
  });

  it("rejects a structurally valid event whose ID contradicts its sequence", () => {
    expect(validateEvent(mismatchedEventId)).toBe(true);
    expect(semanticEventErrors(mismatchedEventId)).toContain(
      "event ID does not agree with producer, run, and sequence",
    );
  });

  it("gives otherwise identical same-tick shots distinct identities", () => {
    const firstShot = clone(stream[1]);
    const secondShot = clone(stream[2]);

    expect(firstShot.event_id).not.toBe(secondShot.event_id);
    expect(firstShot.event_sequence).not.toBe(secondShot.event_sequence);

    delete firstShot.event_id;
    delete firstShot.event_sequence;
    delete secondShot.event_id;
    delete secondShot.event_sequence;

    expect(secondShot).toEqual(firstShot);
  });

  it("preserves an already-built event unchanged across a retry", () => {
    const builtEvent = stream[1];
    const retriedEvent = clone(builtEvent);

    expect(validateEvent(retriedEvent)).toBe(true);
    expect(retriedEvent).toEqual(builtEvent);
    expect(retriedEvent.event_id).toBe(builtEvent.event_id);
  });

  it("represents unknown attribution explicitly rather than as Player", () => {
    const unknownAttacker = stream[4].initiator;

    expect(unknownAttacker).toMatchObject({
      status: "unknown",
      kind: "unknown",
      reason: "not-reported",
      participant_id: null,
      asset_key: null,
    });
    expect(JSON.stringify(unknownAttacker)).not.toContain("Player");
  });
});

describe("telemetry batch version 1", () => {
  const batch = {
    batch_schema_version: 1,
    events: validFixtures.map(({ event }) => event),
  };

  it("accepts an ordered single-run fixture batch", () => {
    expect(validateBatch(batch), JSON.stringify(validateBatch.errors)).toBe(true);
    expect(semanticBatchErrors(batch)).toEqual([]);
  });

  it("rejects more than 100 events structurally", () => {
    const oversizedCount = {
      batch_schema_version: 1,
      events: Array.from({ length: 101 }, () => validFixtures[0].event),
    };

    expect(validateBatch(oversizedCount)).toBe(false);
  });

  it("detects mixed runs, out-of-order sequences, and inconsistent IDs", () => {
    const invalid = clone(batch);
    invalid.events[1].run_key = "another-run";
    invalid.events[2].event_sequence = 1;

    expect(semanticBatchErrors(invalid)).toEqual(
      expect.arrayContaining([
        "batch contains more than one producer or run",
        "event sequences are not contiguous and increasing",
        "event ID does not agree with producer, run, and sequence",
      ]),
    );
  });

  it("rejects a structurally valid batch with a sequence gap", () => {
    expect(validateBatch(sequenceGapBatch)).toBe(true);
    expect(semanticBatchErrors(sequenceGapBatch)).toContain(
      "event sequences are not contiguous and increasing",
    );
  });

  it("enforces the exact uncompressed 1 MiB UTF-8 boundary", () => {
    const atLimit = {
      batch_schema_version: 1,
      events: [clone(validFixtures[0].event)],
    };
    atLimit.events[0].payload.padding = "";
    const baseBytes = Buffer.byteLength(JSON.stringify(atLimit), "utf8");
    atLimit.events[0].payload.padding = "x".repeat(1_048_576 - baseBytes);

    expect(Buffer.byteLength(JSON.stringify(atLimit), "utf8")).toBe(1_048_576);
    expect(validateBatch(atLimit)).toBe(true);
    expect(semanticBatchErrors(atLimit)).toEqual([]);

    const tooLarge = clone(atLimit);
    tooLarge.events[0].payload.padding += "é";

    expect(validateBatch(tooLarge)).toBe(true);
    expect(Buffer.byteLength(JSON.stringify(tooLarge), "utf8")).toBe(1_048_578);
    expect(semanticBatchErrors(tooLarge)).toContain(
      "batch exceeds 1,048,576 UTF-8 bytes",
    );
  });
});

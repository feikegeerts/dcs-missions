import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import type { TelemetryEvent } from "../src/telemetry/types";
import { validateBatch } from "../src/telemetry/validate";

const contractRoot = resolve(process.cwd(), "..", "contracts");

function readJson(path: string): Record<string, unknown> {
  return JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
}

function fixtures(directory: string): Record<string, unknown>[] {
  return readdirSync(resolve(contractRoot, "fixtures", directory))
    .filter((name) => name.endsWith(".json"))
    .sort()
    .map((name) =>
      readJson(resolve(contractRoot, "fixtures", directory, name)),
    );
}

function batch(events: Record<string, unknown>[]) {
  return JSON.stringify({ batch_schema_version: 1, events });
}

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

describe("telemetry batch validation", () => {
  it("accepts the ordered valid fixture stream", () => {
    const result = validateBatch(batch(fixtures("valid")));

    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.events).toHaveLength(5);
      expect(result.events.every((event) => event.valid)).toBe(true);
    }
  });

  it("rejects every invalid fixture", () => {
    for (const event of fixtures("invalid")) {
      const result = validateBatch(batch([event]));
      if (result.ok) {
        expect(result.events[0]?.valid, JSON.stringify(event)).toBe(false);
        expect(result.events[0]?.rejectReason).toBe("schema-invalid");
      } else {
        expect(result.code, JSON.stringify(event)).toBe("batch-preflight");
      }
    }
  });

  it("rejects a sequence gap before event validation", () => {
    const result = validateBatch(
      JSON.stringify(
        readJson(
          resolve(
            contractRoot,
            "fixtures/invalid-semantic/batch-sequence-gap.json",
          ),
        ),
      ),
    );

    expect(result).toMatchObject({ ok: false, code: "batch-sequence-gap" });
  });

  it("rejects a mixed-run batch", () => {
    const events = fixtures("valid").slice(0, 2);
    events[1] = { ...events[1], run_key: "another-run" };

    expect(validateBatch(batch(events))).toMatchObject({
      ok: false,
      code: "batch-mixed-run",
    });
  });

  it("rejects an inconsistent event ID per event", () => {
    const event = readJson(
      resolve(
        contractRoot,
        "fixtures/invalid-semantic/mismatched-event-id.json",
      ),
    );
    const result = validateBatch(batch([event]));

    expect(result).toMatchObject({ ok: true });
    if (result.ok) {
      expect(result.events[0]).toMatchObject({
        valid: false,
        rejectReason: "inconsistent-event-id",
      });
    }
  });

  it("rejects batches over 100 events", () => {
    const event = fixtures("valid")[0];
    expect(
      validateBatch(batch(Array.from({ length: 101 }, () => event))),
    ).toMatchObject({
      ok: false,
      code: "invalid-batch-envelope",
    });
  });

  it("rejects a batch over 1 MiB", () => {
    const event = clone(fixtures("valid")[0]);
    event.payload = { padding: "x".repeat(1_048_576) };

    expect(validateBatch(batch([event]))).toMatchObject({
      ok: false,
      code: "batch-too-large",
    });
  });

  it("keeps valid event values typed as telemetry events", () => {
    const result = validateBatch(batch(fixtures("valid")));
    if (result.ok && result.events[0]?.valid) {
      const event: TelemetryEvent = result.events[0].event;
      expect(event.event_sequence).toBe(1);
    }
  });
});

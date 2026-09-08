import {
  appendFileSync,
  renameSync,
  rmSync,
  statSync,
  truncateSync,
  writeFileSync,
} from "node:fs";
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
  forRun,
  ndjson,
  schemaPath,
  type TestWorkspace,
} from "./helpers.js";

describe("bounded collection passes", () => {
  let workspace: TestWorkspace | undefined;
  let spool: DurableSpool | undefined;

  afterEach(() => {
    spool?.close();
    workspace?.cleanup();
  });

  function setup(maxBytesPerPass?: number): {
    workspace: TestWorkspace;
    spool: DurableSpool;
    collector: Collector;
  } {
    workspace = createWorkspace();
    spool = new DurableSpool(join(workspace.state, "collector.sqlite3"));
    return {
      workspace,
      spool,
      collector: new Collector({
        inputDirectory: workspace.input,
        spool,
        validator: createEventValidator(schemaPath),
        maxBytesPerPass,
      }),
    };
  }

  it("stops at a partial line and resumes it without duplication", () => {
    const context = setup(4096);
    const started = fixture("01-mission-started.json");
    const fired = fixture("02-ordnance-fired.json");
    const complete = `${JSON.stringify(started)}\n`;
    const pending = JSON.stringify(fired);
    const split = Math.floor(pending.length / 2);
    const source = join(context.workspace.input, "partial.ndjson");
    writeFileSync(source, complete + pending.slice(0, split));

    const first = context.collector.collect();
    expect(first).toMatchObject({ spooled: 1, partial_files: 1 });
    expect(first.partial_bytes).toBeGreaterThan(0);
    expect(context.spool.getCursor(source)?.offset).toBe(
      Buffer.byteLength(complete),
    );

    appendFileSync(source, `${pending.slice(split)}\n`);
    const second = context.collector.collect();
    expect(second).toMatchObject({ spooled: 1, duplicates: 0 });
    expect(context.spool.eventCount()).toBe(2);
  });

  it("shares the byte budget across files and drains a large backlog", () => {
    const budget = 1500;
    const context = setup(budget);
    const eventsA = runEvents("run-budget-a", 7);
    const eventsB = runEvents("run-budget-b", 7);
    const sourceA = join(context.workspace.input, "a.ndjson");
    const sourceB = join(context.workspace.input, "b.ndjson");
    writeFileSync(sourceA, ndjson(eventsA));
    writeFileSync(sourceB, ndjson(eventsB));

    let spooled = 0;
    let duplicates = 0;
    for (let pass = 0; pass < 20 && spooled < 14; pass += 1) {
      const summary = context.collector.collect();
      expect(summary.bytes_read).toBeLessThanOrEqual(budget);
      spooled += summary.spooled;
      duplicates += summary.duplicates;
    }
    expect({ spooled, duplicates }).toEqual({ spooled: 14, duplicates: 0 });
    expect(context.spool.getCursor(sourceA)?.offset).toBe(
      statSync(sourceA).size,
    );
    expect(context.spool.getCursor(sourceB)?.offset).toBe(
      statSync(sourceB).size,
    );
  });

  it("retains the unbounded one-shot whole-file fallback", () => {
    const context = setup();
    writeFileSync(
      join(context.workspace.input, "whole.ndjson"),
      ndjson(runEvents("run-unbounded", 12)),
    );
    const summary = context.collector.collect();
    expect(summary).toMatchObject({ spooled: 12, duplicates: 0 });
    expect(summary.bytes_read).toBeGreaterThan(1500);
  });

  it("reports identity replacement and truncation incidents", () => {
    const context = setup();
    const source = join(context.workspace.input, "integrity.ndjson");
    const original = runEvents("run-integrity-old", 2);
    writeFileSync(source, ndjson(original));
    context.collector.collect();

    const replacement = join(context.workspace.input, "replacement.tmp");
    writeFileSync(replacement, ndjson(runEvents("run-integrity-new", 1)));
    rmSync(source);
    renameSync(replacement, source);
    const identity = context.collector.collect();
    expect(identity.identity_resets).toBeGreaterThanOrEqual(1);
    expect(identity.incidents).toContainEqual(
      expect.objectContaining({ path: source, kind: "identity-reset" }),
    );
    expect(identity.spooled).toBe(1);

    appendFileSync(source, ndjson(runEvents("run-integrity-new", 2).slice(1)));
    context.collector.collect();
    truncateSync(source, 0);
    const truncation = context.collector.collect();
    expect(truncation.truncation_resets).toBe(1);
    expect(truncation.incidents).toContainEqual(
      expect.objectContaining({ path: source, kind: "truncation" }),
    );
    writeFileSync(source, ndjson(runEvents("run-integrity-new", 1)));
    expect(context.collector.collect()).toMatchObject({
      duplicates: 1,
      spooled: 0,
    });
  });
});

function runEvents(runKey: string, count: number): TelemetryEvent[] {
  const started = forRun(fixture("01-mission-started.json"), runKey);
  const fired = fixture("02-ordnance-fired.json");
  const events = [started];
  for (let sequence = 2; sequence <= count; sequence += 1) {
    const event = forRun(cloneEvent(fired), runKey);
    event.event_sequence = sequence;
    event.event_id = `${event.producer_id}:${runKey}:${sequence}`;
    events.push(event);
  }
  return events;
}

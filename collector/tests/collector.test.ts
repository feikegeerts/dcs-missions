import { appendFileSync, statSync, truncateSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { Collector } from "../src/collector.js";
import { DurableSpool } from "../src/spool.js";
import { createEventValidator } from "../src/validator.js";
import type { CollectorHooks } from "../src/collector.js";
import type { TelemetryEvent } from "../src/types.js";
import {
  cloneEvent,
  createWorkspace,
  fixture,
  forRun,
  invalidFixture,
  ndjson,
  schemaPath,
  type TestWorkspace,
  writeRun,
} from "./helpers.js";

describe("NDJSON collector", () => {
  let workspace: TestWorkspace | undefined;
  let spool: DurableSpool | undefined;

  afterEach(() => {
    spool?.close();
    workspace?.cleanup();
    spool = undefined;
    workspace = undefined;
  });

  function setup(): { workspace: TestWorkspace; spool: DurableSpool } {
    workspace = createWorkspace();
    spool = new DurableSpool(join(workspace.state, "collector.sqlite3"));
    return { workspace, spool };
  }

  function collect(
    hooks: CollectorHooks = {},
    dryRun = false,
  ): ReturnType<Collector["collect"]> {
    if (workspace === undefined || spool === undefined) {
      throw new Error("test collector is not set up");
    }
    return new Collector({
      inputDirectory: workspace.input,
      spool,
      validator: createEventValidator(schemaPath),
      hooks,
      dryRun,
    }).collect();
  }

  it("tails a valid run idempotently and advances its byte cursor", () => {
    const context = setup();
    const events = [
      fixture("01-mission-started.json"),
      fixture("02-ordnance-fired.json"),
    ];
    const source = writeRun(context.workspace.input, "run.ndjson", events);

    const first = collect();
    expect(first).toMatchObject({ spooled: 2, duplicates: 0 });
    expect(context.spool.eventCount()).toBe(2);
    expect(context.spool.getCursor(source)?.offset).toBe(statSync(source).size);

    const second = collect();
    expect(second).toMatchObject({
      complete_lines: 0,
      spooled: 0,
      duplicates: 0,
    });
    expect(context.spool.eventCount()).toBe(2);
  });

  it("resumes from the durable cursor after process restart", () => {
    const context = setup();
    const started = fixture("01-mission-started.json");
    const fired = fixture("02-ordnance-fired.json");
    const source = writeRun(context.workspace.input, "restart.ndjson", [
      started,
    ]);
    collect();
    context.spool.close();
    spool = new DurableSpool(
      join(context.workspace.state, "collector.sqlite3"),
    );

    appendFileSync(source, ndjson([fired]), "utf8");
    const resumed = collect();
    expect(resumed).toMatchObject({ complete_lines: 1, spooled: 1 });
    expect(spool.eventCount()).toBe(2);
  });

  it("leaves a partial final line unread until its newline arrives", () => {
    const context = setup();
    const started = fixture("01-mission-started.json");
    const fired = fixture("02-ordnance-fired.json");
    const complete = `${JSON.stringify(started)}\n`;
    const second = JSON.stringify(fired);
    const split = Math.floor(second.length / 2);
    const source = join(context.workspace.input, "partial.ndjson");
    writeFileSync(source, complete + second.slice(0, split), "utf8");

    const first = collect();
    expect(first).toMatchObject({
      spooled: 1,
      partial_files: 1,
      partial_bytes: split,
    });
    expect(context.spool.getCursor(source)?.offset).toBe(
      Buffer.byteLength(complete),
    );

    appendFileSync(source, `${second.slice(split)}\n`, "utf8");
    const secondPass = collect();
    expect(secondPass).toMatchObject({ spooled: 1, partial_files: 0 });
    expect(context.spool.eventCount()).toBe(2);
  });

  it("handles new run files independently", () => {
    const context = setup();
    const started = fixture("01-mission-started.json");
    const secondRun = forRun(started, "run-20260902T170000Z-abcdef12");
    writeRun(context.workspace.input, "a.ndjson", [started]);
    writeRun(context.workspace.input, "b.ndjson", [secondRun]);

    expect(collect()).toMatchObject({ files_seen: 2, spooled: 2 });
    expect(context.spool.listRuns()).toHaveLength(2);
  });

  it("detects truncation, resets safely, and deduplicates replayed events", () => {
    const context = setup();
    const started = fixture("01-mission-started.json");
    const source = writeRun(context.workspace.input, "truncated.ndjson", [
      started,
    ]);
    collect();
    truncateSync(source, 0);

    const reset = collect();
    expect(reset.truncation_resets).toBe(1);
    expect(context.spool.getCursor(source)?.offset).toBe(0);

    writeFileSync(source, ndjson([started]), "utf8");
    const replay = collect();
    expect(replay).toMatchObject({ duplicates: 1, spooled: 0 });
    expect(context.spool.eventCount()).toBe(1);
  });

  it("resets when the persisted file identity does not match", () => {
    const context = setup();
    const started = fixture("01-mission-started.json");
    const source = writeRun(context.workspace.input, "identity.ndjson", [
      started,
    ]);
    context.spool.setCursor({
      source_path: source,
      identity: { device: "wrong", inode: "wrong", birthtime_ns: "wrong" },
      offset: 999,
      producer_id: "old",
      run_key: "old",
    });

    const summary = collect();
    expect(summary).toMatchObject({ identity_resets: 1, spooled: 1 });
    expect(context.spool.getCursor(source)?.producer_id).toBe(
      started.producer_id,
    );
  });

  it("quarantines invalid complete lines, advances, and buffers the gap", () => {
    const context = setup();
    const started = fixture("01-mission-started.json");
    const sequenceThree = fixture("03-ordnance-fired-repeat.json");
    const source = join(context.workspace.input, "invalid.ndjson");
    writeFileSync(
      source,
      `${JSON.stringify(started)}\n{not-json}\n${JSON.stringify(sequenceThree)}\n`,
      "utf8",
    );

    const summary = collect();
    expect(summary).toMatchObject({ spooled: 2, quarantined: 1 });
    expect(context.spool.quarantineCount()).toBe(1);
    expect(context.spool.acknowledge(started.event_id)).toBe("acknowledged");
    expect(
      context.spool.nextDeliverable(started.producer_id, started.run_key),
    ).toBeNull();
    expect(context.spool.getCursor(source)?.offset).toBe(statSync(source).size);
  });

  it("quarantines structural and semantic contract violations", () => {
    const context = setup();
    writeRun(context.workspace.input, "structural.ndjson", [
      invalidFixture("invalid", "missing-schema-version.json"),
    ]);
    writeRun(context.workspace.input, "semantic.ndjson", [
      invalidFixture("invalid-semantic", "mismatched-event-id.json"),
    ]);

    expect(collect()).toMatchObject({ quarantined: 2, spooled: 0 });
    expect(context.spool.quarantineCount()).toBe(2);
  });

  it("quarantines invalid UTF-8 in a complete line", () => {
    const context = setup();
    writeFileSync(
      join(context.workspace.input, "invalid-utf8.ndjson"),
      Buffer.from([0xff, 0x0a]),
    );

    expect(collect()).toMatchObject({ quarantined: 1, spooled: 0 });
    expect(context.spool.quarantineCount()).toBe(1);
  });

  it("quarantines a second run found in one per-run source file", () => {
    const context = setup();
    const started = fixture("01-mission-started.json");
    const otherRun = forRun(started, "run-20260902T180000Z-abcdef12");
    writeRun(context.workspace.input, "mixed.ndjson", [started, otherRun]);

    expect(collect()).toMatchObject({ spooled: 1, quarantined: 1 });
  });

  it("does not advance when it crashes before spool persistence", () => {
    const context = setup();
    writeRun(context.workspace.input, "crash-before.ndjson", [
      fixture("01-mission-started.json"),
    ]);

    expect(() =>
      collect({
        beforeSpoolInsert(): void {
          throw new Error("simulated before spool");
        },
      }),
    ).toThrow("simulated before spool");
    expect(context.spool.eventCount()).toBe(0);
    expect(
      context.spool.getCursor(
        join(context.workspace.input, "crash-before.ndjson"),
      ),
    ).toBeNull();
  });

  it("replays idempotently after a crash between spool and cursor durability", () => {
    const context = setup();
    const source = writeRun(context.workspace.input, "crash-middle.ndjson", [
      fixture("01-mission-started.json"),
    ]);

    expect(() =>
      collect({
        afterSpoolPersisted(): void {
          throw new Error("simulated after spool");
        },
      }),
    ).toThrow("simulated after spool");
    expect(context.spool.eventCount()).toBe(1);
    expect(context.spool.getCursor(source)).toBeNull();

    const recovered = collect();
    expect(recovered).toMatchObject({ duplicates: 1, spooled: 0 });
    expect(context.spool.getCursor(source)?.offset).toBe(statSync(source).size);
  });

  it("deduplicates quarantine after a crash before cursor durability", () => {
    const context = setup();
    const source = join(context.workspace.input, "quarantine-crash.ndjson");
    writeFileSync(source, "not-json\n", "utf8");

    expect(() =>
      collect({
        afterQuarantinePersisted(): void {
          throw new Error("simulated after quarantine");
        },
      }),
    ).toThrow("simulated after quarantine");
    expect(context.spool.quarantineCount()).toBe(1);
    expect(context.spool.getCursor(source)).toBeNull();

    const recovered = collect();
    expect(recovered).toMatchObject({
      duplicate_quarantines: 1,
      quarantined: 0,
    });
    expect(context.spool.getCursor(source)?.offset).toBe(statSync(source).size);
  });

  it("does not replay after a crash following cursor durability", () => {
    const context = setup();
    const source = writeRun(context.workspace.input, "crash-after.ndjson", [
      fixture("01-mission-started.json"),
    ]);

    expect(() =>
      collect({
        afterCursorPersisted(): void {
          throw new Error("simulated after cursor");
        },
      }),
    ).toThrow("simulated after cursor");
    expect(context.spool.eventCount()).toBe(1);
    expect(context.spool.getCursor(source)?.offset).toBe(statSync(source).size);

    expect(collect()).toMatchObject({ complete_lines: 0, spooled: 0 });
  });

  it("reports a dry run without mutating spool, cursor, or quarantine", () => {
    const context = setup();
    const valid = fixture("01-mission-started.json");
    const source = join(context.workspace.input, "dry.ndjson");
    writeFileSync(source, `${JSON.stringify(valid)}\nnot-json\n`, "utf8");

    const summary = collect({}, true);
    expect(summary).toMatchObject({
      dry_run: true,
      would_spool: 1,
      would_quarantine: 1,
      spooled: 0,
      quarantined: 0,
    });
    expect(context.spool.eventCount()).toBe(0);
    expect(context.spool.quarantineCount()).toBe(0);
    expect(context.spool.getCursor(source)).toBeNull();
  });

  it("quarantines a changed retry instead of accepting it as a duplicate", () => {
    const context = setup();
    const started = fixture("01-mission-started.json");
    writeRun(context.workspace.input, "first.ndjson", [started]);
    collect();

    const changed = cloneEvent(started) as TelemetryEvent;
    changed.payload = { ...changed.payload, map_name: "Syria" };
    writeRun(context.workspace.input, "retry.ndjson", [changed]);
    const result = collect();
    expect(result).toMatchObject({ quarantined: 1, spooled: 0 });
    expect(context.spool.eventCount()).toBe(1);
  });
});

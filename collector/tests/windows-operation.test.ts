import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { serviceStatus } from "../src/service.js";
import { DurableSpool } from "../src/spool.js";
import {
  createWorkspace,
  fixture,
  schemaPath,
  type TestWorkspace,
} from "./helpers.js";

describe("Windows operational status", () => {
  let workspace: TestWorkspace | undefined;
  let spool: DurableSpool | undefined;

  afterEach(() => {
    spool?.close();
    workspace?.cleanup();
  });

  it("reports backlog, disk, delivery, retry, block, lifecycle, and tail state without tokens", async () => {
    workspace = createWorkspace();
    spool = new DurableSpool(join(workspace.state, "collector.sqlite3"));
    const event = fixture("01-mission-started.json");
    spool.insertEvent(event);
    spool.recordDeliveryAttempt({
      producerId: event.producer_id,
      runKey: event.run_key,
      at: "2026-09-08T10:00:00.000Z",
      success: true,
      error: null,
    });
    spool.recordRunRetry({
      producerId: event.producer_id,
      runKey: event.run_key,
      attemptCount: 1,
      nextAttemptAt: "2026-09-08T10:01:00.000Z",
      classification: "network",
      error: "offline",
    });
    spool.blockRun({
      producerId: "blocked-producer",
      runKey: "blocked-run",
      sequence: 4,
      eventId: null,
      reason: "operator review required",
      classification: "permanent-batch-rejection",
    });
    spool.insertLifecycleObservation({
      observationKey: "pending-lifecycle",
      producerId: event.producer_id,
      runKey: event.run_key,
      hookGeneration: 2,
      processBinding: {},
      reason: "dcs-process-not-running",
      evidenceIdentity: "evidence",
      tailState: "unknown",
      observedAt: "2026-09-08T10:00:10.000Z",
    });
    spool.recordSourceTail({
      sourcePath: join(workspace.input, "partial.ndjson"),
      producerId: event.producer_id,
      runKey: event.run_key,
      observedSize: 11,
      durableOffset: 10,
      tailState: "partial",
      observedAt: "2026-09-08T10:00:10.000Z",
    });
    spool.quarantine({
      quarantine_id: "status-quarantine",
      source_path: join(workspace.input, "bad.ndjson"),
      identity: { device: "1", inode: "2", birthtime_ns: "3" },
      start_offset: 0,
      end_offset: 1,
      raw_line: Buffer.from("{"),
      error_code: "invalid-json",
      error_message: "invalid JSON",
      error_details: {},
    });
    spool.close();
    spool = undefined;

    const status = (await serviceStatus({
      input: workspace.input,
      state: workspace.state,
      schema: schemaPath,
      intervalMs: 5000,
      maxCycleBytes: 4096,
      url: "https://dcs-missions.vercel.app",
      token: "dummy-test-token",
    })) as OperationalStatus;

    expect(status.operational_status.backlog.aggregate).toMatchObject({
      run_count: 1,
      count: 1,
    });
    expect(status.operational_status.backlog.runs[0]).toMatchObject({
      producer_id: event.producer_id,
      run_key: event.run_key,
      count: 1,
    });
    expect(status.operational_status.backlog.runs[0]!.bytes).toBeGreaterThan(0);
    expect(status.operational_status.disk.input.available_bytes).toMatch(
      /^\d+$/,
    );
    expect(status.operational_status.disk.state.available_bytes).toMatch(
      /^\d+$/,
    );
    expect(status.operational_status.last_successful_delivery).toBe(
      "2026-09-08T10:00:00.000Z",
    );
    expect(status.operational_status.next_retry_deadline).toBe(
      "2026-09-08T10:01:00.000Z",
    );
    expect(status.operational_status.quarantine).toEqual({
      count: 1,
      reasons: [{ reason: "invalid-json", count: 1 }],
    });
    expect(status.operational_status.blocks).toEqual([
      expect.objectContaining({ reason: "operator review required" }),
    ]);
    expect(status.operational_status.lifecycle).toEqual({
      pending: 1,
      pending_unknown_tail: 1,
    });
    expect(status.operational_status.source_tail.uncertain).toBe(1);
    expect(JSON.stringify(status)).not.toContain("dummy-test-token");
  });
});

interface OperationalStatus {
  operational_status: {
    backlog: {
      runs: Array<{
        producer_id: string;
        run_key: string;
        count: number;
        bytes: number;
      }>;
      aggregate: { run_count: number; count: number };
    };
    disk: {
      input: { available_bytes: string | null };
      state: { available_bytes: string | null };
    };
    last_successful_delivery: string | null;
    next_retry_deadline: string | null;
    quarantine: { count: number; reasons: unknown[] };
    blocks: Array<{ reason: string | null }>;
    lifecycle: { pending: number; pending_unknown_tail: number };
    source_tail: { uncertain: number };
  };
}

import { join, resolve } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { parseCliArguments, runCli, runStatus } from "../src/delivery-cli.js";
import { DurableSpool } from "../src/spool.js";
import { cloneEvent, createWorkspace, fixture } from "./helpers.js";
import type { TestWorkspace } from "./helpers.js";

describe("delivery CLI status and prune modes", () => {
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

  it("prints empty status totals and null latest health timestamps", async () => {
    const database = openSpool();
    database.close();
    spool = undefined;
    const printed: string[] = [];

    expect(
      await runCli(["status", "--state", workspace!.state], {
        token: "",
        nowProvider: () => "2026-09-06T01:00:00.000Z",
        print: (message) => printed.push(message),
      }),
    ).toBe(0);
    expect(JSON.parse(printed[0]!) as unknown).toEqual({
      mode: "status",
      spool_path: join(workspace!.state, "collector.sqlite3"),
      generated_at: "2026-09-06T01:00:00.000Z",
      runs: [],
      totals: { runs: 0, events_spooled: 0, quarantined: 0 },
      latest: { last_attempt_at: null, last_success_at: null },
      circuit: {
        open: false,
        open_since: null,
        next_probe_at: null,
        attempt_count: 0,
        last_status: null,
      },
      lifecycle_outbox: [],
      source_tails: [],
    });
  });

  it("joins status health onto runs and calculates latest timestamps", () => {
    const database = openSpool();
    const event = cloneEvent(fixture("01-mission-started.json"));
    database.insertEvent(event);
    expect(runStatus(database).runs[0]).toMatchObject({
      last_attempt_at: null,
      last_success_at: null,
      last_error: null,
    });
    database.recordDeliveryAttempt({
      producerId: event.producer_id,
      runKey: event.run_key,
      at: "2026-09-06T02:00:00.000Z",
      success: true,
      error: null,
    });

    const status = runStatus(database, () => "2026-09-06T03:00:00.000Z");
    expect(status.runs[0]).toMatchObject({
      producer_id: event.producer_id,
      run_key: event.run_key,
      event_count: 1,
      last_attempt_at: "2026-09-06T02:00:00.000Z",
      last_success_at: "2026-09-06T02:00:00.000Z",
      last_error: null,
    });
    expect(status.latest).toEqual({
      last_attempt_at: "2026-09-06T02:00:00.000Z",
      last_success_at: "2026-09-06T02:00:00.000Z",
    });
  });

  it("shows durable circuit, retry blocker, lifecycle, and tail state", () => {
    const database = openSpool();
    const event = cloneEvent(fixture("01-mission-started.json"));
    database.insertEvent(event);
    database.recordRunRetry({
      producerId: event.producer_id,
      runKey: event.run_key,
      attemptCount: 2,
      nextAttemptAt: "2026-09-06T03:02:00.000Z",
      classification: "http-503",
      error: "HTTP 503",
    });
    database.openDeliveryCircuit({
      at: "2026-09-06T03:00:00.000Z",
      nextProbeAt: "2026-09-06T03:01:00.000Z",
      attemptCount: 1,
      status: "HTTP 401: authorization rejected",
    });
    database.recordSourceTail({
      sourcePath: "run.ndjson",
      producerId: event.producer_id,
      runKey: event.run_key,
      observedSize: 10,
      durableOffset: 9,
      tailState: "partial",
      observedAt: "2026-09-06T03:00:00.000Z",
    });

    const status = runStatus(database);
    expect(status.runs[0]).toMatchObject({
      retry_attempt_count: 2,
      next_retry_at: "2026-09-06T03:02:00.000Z",
      tail_uncertain: true,
    });
    expect(status.circuit).toMatchObject({
      open: true,
      next_probe_at: "2026-09-06T03:01:00.000Z",
      last_status: "HTTP 401: authorization rejected",
    });
    expect(status.source_tails[0]?.tailState).toBe("partial");
  });

  it("prints prune dry-run output without mutation", async () => {
    const database = openSpool();
    const event = cloneEvent(fixture("01-mission-started.json"));
    const ended = cloneEvent(event);
    ended.event_id = `${event.event_id}:ended`;
    ended.event_sequence = 2;
    ended.event_type = "mission.ended";
    database.insertEvent(event);
    database.insertEvent(ended);
    database.acknowledge(event.event_id);
    database.acknowledge(ended.event_id);
    database.close();
    spool = undefined;
    const printed: string[] = [];

    expect(
      await runCli(["prune", "--state", workspace!.state, "--dry-run"], {
        print: (message) => printed.push(message),
      }),
    ).toBe(0);
    expect(JSON.parse(printed[0]!) as unknown).toEqual({
      mode: "prune",
      dry_run: true,
      pruned_runs: [
        {
          producerId: event.producer_id,
          runKey: event.run_key,
          eventCount: 2,
        },
      ],
      total_events_pruned: 2,
    });
    spool = new DurableSpool(join(workspace!.state, "collector.sqlite3"));
    expect(spool.eventCount()).toBe(2);
  });

  it("prints prune output and removes delivered events", async () => {
    const database = openSpool();
    const event = cloneEvent(fixture("01-mission-started.json"));
    const ended = cloneEvent(event);
    ended.event_id = `${event.event_id}:ended`;
    ended.event_sequence = 2;
    ended.event_type = "mission.ended";
    database.insertEvent(event);
    database.insertEvent(ended);
    database.acknowledge(event.event_id);
    database.acknowledge(ended.event_id);
    database.close();
    spool = undefined;
    const printed: string[] = [];

    expect(
      await runCli(["prune", "--state", workspace!.state], {
        print: (message) => printed.push(message),
      }),
    ).toBe(0);
    expect(JSON.parse(printed[0]!) as Record<string, unknown>).toMatchObject({
      mode: "prune",
      dry_run: false,
      total_events_pruned: 2,
    });
    spool = new DurableSpool(join(workspace!.state, "collector.sqlite3"));
    expect(spool.eventCount()).toBe(0);
  });

  it("rejects unknown positional commands and dry-run status", () => {
    expect(() => parseCliArguments(["unknown", "--state", "state"])).toThrow(
      "unknown command: unknown",
    );
    expect(() =>
      parseCliArguments(["status", "--state", "state", "--dry-run"]),
    ).toThrow("--dry-run is not valid for status");
  });

  it("parses a complete PID, creation-time, profile, and input binding", () => {
    const parsed = parseCliArguments([
      "--state",
      "state",
      "--producer-id-file",
      "profile/Logs/telemetry-bridge/producer-id",
      "--dcs-pid",
      "4242",
      "--dcs-created-at",
      "2026-09-07T10:00:00.000Z",
      "--dcs-run-key",
      "run-bound",
      "--hook-generation",
      "12",
      "--dcs-image",
      "DCS_server.exe",
      "--dcs-process-scope",
      "DCS.dcs_serverrelease",
      "--dcs-profile",
      "profile",
      "--telemetry-input",
      "profile/Logs/telemetry",
    ]);

    expect(parsed.producerIdFile).toBe(
      resolve("profile/Logs/telemetry-bridge/producer-id"),
    );
    expect(parsed.processBinding).toEqual({
      pid: 4242,
      creationTime: "2026-09-07T10:00:00.000Z",
      runKey: "run-bound",
      hookGeneration: 12,
      expectedImage: "DCS_server.exe",
      commandLineScope: "DCS.dcs_serverrelease",
      profilePath: resolve("profile"),
      inputPath: resolve("profile/Logs/telemetry"),
    });
  });

  it("rejects a partial process binding instead of guessing", () => {
    expect(() =>
      parseCliArguments([
        "--state",
        "state",
        "--dcs-pid",
        "4242",
        "--dcs-image",
        "DCS_server.exe",
      ]),
    ).toThrow("all DCS process binding options are required");
  });
});

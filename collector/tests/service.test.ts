import { appendFileSync } from "node:fs";
import { afterEach, describe, expect, it, vi } from "vitest";

import { acquireOwnership, releaseOwnership } from "../src/ownership.js";
import { ServiceController } from "../src/service.js";
import type { ServiceOptions } from "../src/service.js";
import {
  createWorkspace,
  fixture,
  ndjson,
  schemaPath,
  type TestWorkspace,
  writeRun,
} from "./helpers.js";

describe("persistent service scheduler", () => {
  let workspace: TestWorkspace | undefined;
  let controller: ServiceController | undefined;

  afterEach(async () => {
    if (controller !== undefined) {
      await controller.stop();
    }
    vi.useRealTimers();
    workspace?.cleanup();
    controller = undefined;
  });

  function options(token = ""): ServiceOptions {
    workspace = createWorkspace();
    return {
      input: workspace.input,
      state: workspace.state,
      schema: schemaPath,
      intervalMs: 100,
      maxCycleBytes: 4096,
      url: "https://example.invalid",
      token,
    };
  }

  it("runs and logs one bounded collection pass per interval", async () => {
    vi.useFakeTimers();
    const configuration = options();
    const logs: string[] = [];
    controller = await ServiceController.create(configuration, {
      print: (line) => logs.push(line),
    });
    controller.start();
    await vi.advanceTimersByTimeAsync(300);
    expect(collectionLogs(logs, "scheduled")).toHaveLength(4);
  });

  it("continues collection while one delivery pass is pending", async () => {
    vi.useFakeTimers();
    const configuration = options("service-test-token");
    const source = writeRun(workspace!.input, "run.ndjson", [
      fixture("01-mission-started.json"),
    ]);
    const logs: string[] = [];
    let releaseFirst: (() => void) | undefined;
    let calls = 0;
    let active = 0;
    let maximumActive = 0;
    const fetchImpl: typeof fetch = async (_input, init) => {
      calls += 1;
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      if (calls === 1) {
        await new Promise<void>((resolvePromise) => {
          releaseFirst = resolvePromise;
        });
      }
      const body = JSON.parse(String(init?.body)) as {
        events: Array<{ event_id: string }>;
      };
      active -= 1;
      return acceptedResponse(body.events);
    };
    controller = await ServiceController.create(configuration, {
      fetchImpl,
      print: (line) => logs.push(line),
      deliveryOptions: { maxAttempts: 1 },
    });
    controller.start();
    appendFileSync(source, ndjson([fixture("02-ordnance-fired.json")]));
    await vi.advanceTimersByTimeAsync(100);
    expect(collectionLogs(logs, "scheduled")).toHaveLength(2);
    expect(calls).toBe(1);
    releaseFirst?.();
    await vi.advanceTimersByTimeAsync(101);
    expect(maximumActive).toBe(1);
    expect(calls).toBeGreaterThanOrEqual(2);
  });

  it("keeps collecting and logs one operational skip when the token is absent", async () => {
    vi.useFakeTimers();
    const configuration = options();
    const logs: string[] = [];
    const fetchImpl = vi.fn<typeof fetch>();
    controller = await ServiceController.create(configuration, {
      fetchImpl,
      print: (line) => logs.push(line),
    });
    controller.start();
    await vi.advanceTimersByTimeAsync(300);
    expect(collectionLogs(logs, "scheduled")).toHaveLength(4);
    expect(fetchImpl).not.toHaveBeenCalled();
    expect(
      logs.filter((line) => line.includes("delivery-skipped")),
    ).toHaveLength(1);
  });

  it("redacts delivery failures and retries on a later tick", async () => {
    vi.useFakeTimers();
    const token = "service-test-token";
    const configuration = options(token);
    writeRun(workspace!.input, "run.ndjson", [
      fixture("01-mission-started.json"),
    ]);
    const logs: string[] = [];
    const fetchImpl = vi
      .fn<typeof fetch>()
      .mockRejectedValue(new Error(`failed ${token}`));
    controller = await ServiceController.create(configuration, {
      fetchImpl,
      print: (line) => logs.push(line),
      deliveryOptions: { maxAttempts: 1, randomProvider: () => 0.5 },
    });
    controller.start();
    await vi.advanceTimersByTimeAsync(1250);
    expect(collectionLogs(logs, "scheduled").length).toBeGreaterThanOrEqual(3);
    expect(fetchImpl.mock.calls.length).toBeGreaterThanOrEqual(2);
    expect(logs.join("\n")).not.toContain(token);
    expect(logs.join("\n")).toContain("[REDACTED]");
  });

  it("continues collection while an authorization circuit is open", async () => {
    vi.useFakeTimers();
    const configuration = options("bad-token");
    writeRun(workspace!.input, "run.ndjson", [
      fixture("01-mission-started.json"),
    ]);
    const logs: string[] = [];
    const fetchImpl = vi
      .fn<typeof fetch>()
      .mockResolvedValue(new Response("unauthorized", { status: 401 }));
    controller = await ServiceController.create(configuration, {
      fetchImpl,
      print: (line) => logs.push(line),
      deliveryOptions: { randomProvider: () => 0.5 },
    });
    controller.start();
    await vi.advanceTimersByTimeAsync(350);
    expect(collectionLogs(logs, "scheduled").length).toBeGreaterThanOrEqual(4);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(logs.join("\n")).toContain('"open":true');
  });

  it("runs one final bounded pass, closes, releases, and emits exit zero", async () => {
    const configuration = options();
    const logs: string[] = [];
    controller = await ServiceController.create(configuration, {
      print: (line) => logs.push(line),
    });
    controller.start();
    writeRun(workspace!.input, "shutdown.ndjson", [
      fixture("01-mission-started.json"),
    ]);
    const exits: number[] = [];
    controller.on("exit", (code) => exits.push(code as number));
    expect(await controller.stop()).toBe(0);
    controller = undefined;
    expect(exits).toEqual([0]);
    expect(collectionLogs(logs, "shutdown")).toHaveLength(1);
    const next = await acquireOwnership({
      input: configuration.input,
      state: configuration.state,
      schema: configuration.schema,
    });
    await releaseOwnership(next);
  });
});

function collectionLogs(logs: string[], phase: string): object[] {
  return logs
    .map((line) => JSON.parse(line) as { kind?: string; phase?: string })
    .filter((line) => line.kind === "collection" && line.phase === phase);
}

function acceptedResponse(events: Array<{ event_id: string }>): Response {
  return new Response(
    JSON.stringify({
      results: events.map((event) => ({
        event_id: event.event_id,
        status: "accepted",
      })),
      summary: { accepted: events.length, duplicates: 0, rejected: 0 },
    }),
    { status: 200 },
  );
}

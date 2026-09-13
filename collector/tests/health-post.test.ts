import { createHash } from "node:crypto";

import { afterEach, describe, expect, it, vi } from "vitest";

import { buildHealthStatus, postHealthStatus } from "../src/health-post.js";
import { ServiceController } from "../src/service.js";
import { createWorkspace, schemaPath, type TestWorkspace } from "./helpers.js";

function operational(overrides: Record<string, unknown> = {}) {
  return {
    generated_at: "2026-09-13T10:00:00.000Z",
    backlog: { aggregate: { run_count: 2, count: 3, bytes: 400 } },
    last_successful_delivery: "2026-09-13T09:59:00.000Z",
    next_retry_deadline: null,
    quarantine: { count: 0 },
    lifecycle: { pending: 1 },
    source_tail: { uncertain: 0 },
    ...overrides,
  };
}

describe("collector health payload", () => {
  it("hashes identity and maps only compact allowlisted operational data", () => {
    const canonicalInput = "C:\\private\\DCS\\telemetry";
    const status = buildHealthStatus({
      canonicalInput,
      operationalStatus: operational(),
      circuit: null,
      blocked: [],
      diskFreeBytesState: 2_500_000_000,
      collectorVersion: "1.2.3",
    });

    expect(status).toEqual({
      identity: createHash("sha256")
        .update(canonicalInput)
        .digest("hex")
        .slice(0, 16),
      generated_at: "2026-09-13T10:00:00.000Z",
      status: "ok",
      backlog: { runs: 2, events: 3, bytes: 400 },
      last_successful_delivery: "2026-09-13T09:59:00.000Z",
      next_retry_deadline: null,
      quarantine_count: 0,
      blocks: [],
      lifecycle_pending: 1,
      source_tail_uncertain: 0,
      disk_free_mb: 2500,
      collector_version: "1.2.3",
    });
    expect(JSON.stringify(status)).not.toContain(canonicalInput);
    expect(status).not.toHaveProperty("input");
    expect(status).not.toHaveProperty("state");
    expect(status).not.toHaveProperty("lock");
  });

  it("derives blocked before degraded and redacts paths from block text", () => {
    const blocked = buildHealthStatus({
      canonicalInput: "C:\\private\\input",
      operationalStatus: operational({
        quarantine: { count: 3 },
        source_tail: { uncertain: 2 },
      }),
      circuit: { open: true },
      blocked: [
        {
          runKey: "run-safe",
          blockedAtSequence: 4,
          blockedReason: "failed at C:\\private\\input\\run.ndjson",
        },
      ],
      diskFreeBytesState: null,
    });
    expect(blocked.status).toBe("blocked");
    expect(blocked.blocks?.[0]).toEqual({
      run_key: "run-safe",
      sequence: 4,
      reason: "failed at [REDACTED_PATH]",
    });
    expect(JSON.stringify(blocked)).not.toContain("C:\\private");

    const degraded = buildHealthStatus({
      canonicalInput: "input",
      operationalStatus: operational({ source_tail: { uncertain: 1 } }),
      circuit: null,
      blocked: [],
      diskFreeBytesState: null,
    });
    expect(degraded.status).toBe("degraded");
  });

  it("caps blocks and the serialized body", () => {
    const status = buildHealthStatus({
      canonicalInput: "input",
      operationalStatus: operational(),
      circuit: null,
      blocked: Array.from({ length: 20 }, (_, index) => ({
        runKey: `run-${index}-${"r".repeat(128)}`,
        blockedAtSequence: index + 1,
        blockedReason: "x".repeat(300),
      })),
      diskFreeBytesState: null,
    });
    expect(status.blocks!.length).toBeLessThanOrEqual(16);
    expect(
      Buffer.byteLength(JSON.stringify(status), "utf8"),
    ).toBeLessThanOrEqual(4096);
  });
});

describe("collector health POST", () => {
  it("posts JSON with bearer authorization through an injected fetch", async () => {
    const fetchImpl = vi
      .fn<typeof fetch>()
      .mockResolvedValue(new Response("accepted", { status: 200 }));
    const result = await postHealthStatus({
      url: "https://example.invalid/api/telemetry/collector-health",
      token: "dummy-token",
      fetchImpl,
      status: { identity: "0123456789abcdef" },
    });
    expect(result).toEqual({ ok: true, httpStatus: 200 });
    expect(fetchImpl).toHaveBeenCalledWith(
      "https://example.invalid/api/telemetry/collector-health",
      expect.objectContaining({
        method: "POST",
        redirect: "manual",
        headers: expect.objectContaining({
          authorization: "Bearer dummy-token",
        }),
      }),
    );
  });

  it("never throws for network, HTTP, redirect, or oversized failures", async () => {
    await expect(
      postHealthStatus({
        url: "https://example.invalid/health",
        token: "dummy-token",
        fetchImpl: vi
          .fn<typeof fetch>()
          .mockRejectedValue(new Error("offline")),
        status: {},
      }),
    ).resolves.toEqual({ ok: false, reason: "network-error" });
    await expect(
      postHealthStatus({
        url: "https://example.invalid/health",
        token: "dummy-token",
        fetchImpl: vi
          .fn<typeof fetch>()
          .mockResolvedValue(new Response("no", { status: 503 })),
        status: {},
      }),
    ).resolves.toEqual({ ok: false, httpStatus: 503, reason: "http-error" });
    await expect(
      postHealthStatus({
        url: "https://example.invalid/health",
        token: "dummy-token",
        fetchImpl: vi
          .fn<typeof fetch>()
          .mockResolvedValue(new Response("move", { status: 307 })),
        status: {},
      }),
    ).resolves.toEqual({
      ok: false,
      httpStatus: 307,
      reason: "authenticated-redirect-rejected",
    });
    await expect(
      postHealthStatus({
        url: "https://example.invalid/health",
        token: "dummy-token",
        fetchImpl: vi.fn<typeof fetch>(),
        status: { value: "x".repeat(4097) },
      }),
    ).resolves.toEqual({ ok: false, reason: "payload-too-large" });
  });
});

describe("service health wiring", () => {
  let workspace: TestWorkspace | undefined;
  let controller: ServiceController | undefined;

  afterEach(async () => {
    if (controller !== undefined) await controller.stop();
    vi.useRealTimers();
    workspace?.cleanup();
  });

  it("keeps collection running when every health POST fails", async () => {
    vi.useFakeTimers();
    workspace = createWorkspace();
    const logs: string[] = [];
    const healthFetchImpl = vi
      .fn<typeof fetch>()
      .mockRejectedValue(new Error("offline"));
    controller = await ServiceController.create(
      {
        input: workspace.input,
        state: workspace.state,
        schema: schemaPath,
        intervalMs: 100,
        maxCycleBytes: 4096,
        url: "http://127.0.0.1:3000",
        token: "dummy-token",
      },
      {
        fetchImpl: vi.fn<typeof fetch>(),
        healthFetchImpl,
        print: (message) => logs.push(message),
      },
    );
    controller.start();
    await vi.advanceTimersByTimeAsync(350);

    expect(
      logs.filter((line) => JSON.parse(line).kind === "collection").length,
    ).toBeGreaterThanOrEqual(4);
    expect(healthFetchImpl).toHaveBeenCalled();
    expect(logs.join("\n")).toContain("collector-health-post-failure");
  });
});

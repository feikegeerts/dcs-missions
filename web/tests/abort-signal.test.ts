import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const storeMocks = vi.hoisted(() => ({
  getRunByRunKey: vi.fn(),
  getRunByProducerAndRunKey: vi.fn(),
  markRunAborted: vi.fn(),
}));

vi.mock("@/telemetry/store", () => ({
  NeonTelemetryStore: class {
    getRunByRunKey = storeMocks.getRunByRunKey;
    getRunByProducerAndRunKey = storeMocks.getRunByProducerAndRunKey;
    markRunAborted = storeMocks.markRunAborted;
  },
}));

import { POST } from "../src/app/api/telemetry/runs/[runId]/route";

const token = "abort-signal-test-token";

function request(
  reason: unknown,
  authorization = `Bearer ${token}`,
  lifecycle: Record<string, unknown> = {},
): Request {
  return new Request("http://localhost/api/telemetry/runs/run-abort", {
    method: "POST",
    headers: { authorization, "content-type": "application/json" },
    body: JSON.stringify({ reason, ...lifecycle }),
  });
}

function context(runId = "run-abort") {
  return { params: Promise.resolve({ runId }) };
}

describe("run abort control API", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    process.env.TELEMETRY_INGEST_TOKEN = token;
    vi.spyOn(console, "info").mockImplementation(() => undefined);
  });

  afterEach(() => {
    delete process.env.TELEMETRY_INGEST_TOKEN;
    vi.restoreAllMocks();
  });

  it("keeps the legacy run-key-only request compatible", async () => {
    storeMocks.getRunByRunKey.mockResolvedValue({
      producerId: "dcs-server-alpha",
      runKey: "run-abort",
    });
    storeMocks.markRunAborted.mockResolvedValue(1);

    const response = await POST(request("dcs-process-not-running"), context());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ aborted: 1 });
    expect(storeMocks.markRunAborted).toHaveBeenCalledWith(
      "dcs-server-alpha",
      "run-abort",
    );
    expect(console.info).toHaveBeenCalledOnce();
  });

  it("targets the matching composite producer and run", async () => {
    storeMocks.getRunByProducerAndRunKey.mockResolvedValue({
      producerId: "dcs-server-alpha",
      runKey: "run-abort",
    });
    storeMocks.markRunAborted.mockResolvedValue(1);

    const response = await POST(
      request("simulation-stop-observed", `Bearer ${token}`, {
        producer_id: "dcs-server-alpha",
        generation: 7,
      }),
      context(),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ aborted: 1 });
    expect(storeMocks.markRunAborted).toHaveBeenCalledWith(
      "dcs-server-alpha",
      "run-abort",
    );
    expect(storeMocks.getRunByProducerAndRunKey).toHaveBeenCalledWith(
      "dcs-server-alpha",
      "run-abort",
    );
    expect(storeMocks.getRunByRunKey).not.toHaveBeenCalled();
    expect(console.info).toHaveBeenCalledWith(
      expect.stringContaining('"generation":7'),
    );
  });

  it("conceals a composite producer mismatch as run not found", async () => {
    storeMocks.getRunByProducerAndRunKey.mockResolvedValue(null);

    const response = await POST(
      request("dcs-process-not-running", `Bearer ${token}`, {
        producer_id: "different-producer",
      }),
      context(),
    );

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "run-not-found" });
    expect(storeMocks.markRunAborted).not.toHaveBeenCalled();
  });

  it("rejects an invalid reason before reading the run", async () => {
    const response = await POST(request("network-timeout"), context());

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid-reason" });
    expect(storeMocks.getRunByRunKey).not.toHaveBeenCalled();
  });

  it("returns not found for an unknown run", async () => {
    storeMocks.getRunByRunKey.mockResolvedValue(null);

    const response = await POST(
      request("simulation-stop-observed"),
      context("missing"),
    );

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "run-not-found" });
    expect(storeMocks.markRunAborted).not.toHaveBeenCalled();
  });

  it.each(["Bearer wrong-token", ""])(
    "rejects invalid authorization %#",
    async (authorization) => {
      const response = await POST(
        request("dcs-process-not-running", authorization),
        context(),
      );

      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "unauthorized" });
      expect(storeMocks.getRunByRunKey).not.toHaveBeenCalled();
    },
  );

  it("fails closed when the ingest token is not configured", async () => {
    delete process.env.TELEMETRY_INGEST_TOKEN;

    const response = await POST(request("dcs-process-not-running"), context());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "ingest-token-not-configured",
    });
  });
});

import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { CollectorHealth } from "../src/components/collector-health";
import { InMemoryCollectorHealthStore } from "../src/telemetry/store";
import type * as TelemetryStoreModule from "../src/telemetry/store";

const storeMocks = vi.hoisted(() => ({
  upsertCollectorHealth: vi.fn(),
  getCollectorHealth: vi.fn(),
}));

vi.mock("@/telemetry/store", async (importOriginal) => {
  const original = await importOriginal<typeof TelemetryStoreModule>();
  return {
    ...original,
    NeonTelemetryStore: class {
      upsertCollectorHealth = storeMocks.upsertCollectorHealth;
      getCollectorHealth = storeMocks.getCollectorHealth;
    },
  };
});

import { GET, POST } from "../src/app/api/telemetry/collector-health/route";

const token = "collector-health-dummy-token";
const validPayload = {
  identity: "0123456789abcdef",
  generated_at: "2026-09-13T10:00:00.000Z",
  status: "degraded",
  backlog: { runs: 2, events: 3, bytes: 400 },
  last_successful_delivery: null,
  next_retry_deadline: "2026-09-13T10:01:00.000Z",
  quarantine_count: 1,
  blocks: [{ run_key: "run-safe", sequence: 2, reason: "sequence gap" }],
  lifecycle_pending: 1,
  source_tail_uncertain: 1,
  disk_free_mb: 2048,
  collector_version: "1.0.0",
};

function request(payload: unknown, authorization = `Bearer ${token}`): Request {
  return new Request("http://localhost/api/telemetry/collector-health", {
    method: "POST",
    headers: { authorization, "content-type": "application/json" },
    body: typeof payload === "string" ? payload : JSON.stringify(payload),
  });
}

describe("collector health route", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    process.env.TELEMETRY_INGEST_TOKEN = token;
  });

  afterEach(() => {
    delete process.env.TELEMETRY_INGEST_TOKEN;
  });

  it("authenticates, ignores unknown fields, and upserts the allowlisted summary", async () => {
    const response = await POST(
      request({
        ...validPayload,
        backlog: { ...validPayload.backlog, owner: "private-user" },
        blocks: [
          {
            ...validPayload.blocks[0],
            source_path: "C:\\private\\telemetry",
          },
        ],
        absolute_input_path: "C:\\private\\telemetry",
        owner: "private-user",
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "accepted" });
    expect(storeMocks.upsertCollectorHealth).toHaveBeenCalledWith(
      validPayload.identity,
      validPayload.status,
      expect.not.objectContaining({ absolute_input_path: expect.anything() }),
    );
    expect(
      storeMocks.upsertCollectorHealth.mock.calls[0]?.[2],
    ).not.toHaveProperty("owner");
    expect(
      storeMocks.upsertCollectorHealth.mock.calls[0]?.[2].backlog,
    ).not.toHaveProperty("owner");
    expect(
      storeMocks.upsertCollectorHealth.mock.calls[0]?.[2].blocks[0],
    ).not.toHaveProperty("source_path");
  });

  it.each(["", "Bearer wrong-token"])(
    "rejects missing or incorrect authorization %#",
    async (authorization) => {
      const response = await POST(request(validPayload, authorization));
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "unauthorized" });
      expect(storeMocks.upsertCollectorHealth).not.toHaveBeenCalled();
    },
  );

  it("fails closed without a configured token", async () => {
    delete process.env.TELEMETRY_INGEST_TOKEN;
    const response = await POST(request(validPayload));
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "ingest-token-not-configured",
    });
  });

  it.each([
    [{ ...validPayload, identity: "not-hex" }, "invalid-identity"],
    [{ ...validPayload, generated_at: "yesterday" }, "invalid-generated-at"],
    [{ ...validPayload, status: "offline" }, "invalid-status"],
    [
      { ...validPayload, backlog: { runs: -1, events: 0, bytes: 0 } },
      "invalid-backlog",
    ],
    [
      {
        ...validPayload,
        blocks: Array.from({ length: 17 }, () => validPayload.blocks[0]),
      },
      "invalid-blocks",
    ],
    [
      {
        ...validPayload,
        blocks: [
          { run_key: "run", sequence: 1, reason: "at C:\\private\\file" },
        ],
      },
      "private-data-not-allowed",
    ],
  ])("rejects invalid bounded payload %#", async (payload, error) => {
    const response = await POST(request(payload));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error });
  });

  it("rejects invalid JSON and bodies over 4096 bytes", async () => {
    const invalid = await POST(request("{"));
    expect(invalid.status).toBe(400);
    expect(await invalid.json()).toEqual({ error: "invalid-json" });

    const oversized = await POST(request("x".repeat(4097)));
    expect(oversized.status).toBe(400);
    expect(await oversized.json()).toEqual({ error: "payload-too-large" });
  });

  it("returns only compact stored fields and server timestamps publicly", async () => {
    storeMocks.getCollectorHealth.mockResolvedValue([
      {
        identity: validPayload.identity,
        status: validPayload.status,
        summary: {
          generated_at: validPayload.generated_at,
          backlog: validPayload.backlog,
        },
        firstSeenAt: new Date("2026-09-13T09:00:00.000Z"),
        updatedAt: new Date("2026-09-13T10:00:01.000Z"),
        ignoredPrivateField: "C:\\private\\state",
      },
    ]);
    const response = await GET();
    const body = (await response.json()) as Record<string, unknown>;
    expect(response.status).toBe(200);
    expect(Object.keys(body).sort()).toEqual(
      [
        "backlog",
        "first_seen_at",
        "generated_at",
        "identity",
        "server_time",
        "status",
        "updated_at",
      ].sort(),
    );
    expect(JSON.stringify(body)).not.toContain("private");
  });

  it("returns an honest public no-status response", async () => {
    storeMocks.getCollectorHealth.mockResolvedValue([]);
    const response = await GET();
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "no-collector-status" });
  });
});

describe("collector health store and dashboard", () => {
  it("upserts by identity while preserving first seen", async () => {
    const times = [
      new Date("2026-09-13T09:00:00.000Z"),
      new Date("2026-09-13T10:00:00.000Z"),
    ];
    const store = new InMemoryCollectorHealthStore(() => times.shift()!);
    await store.upsertCollectorHealth("01234567", "ok", {
      generated_at: "2026-09-13T09:00:00.000Z",
    });
    await store.upsertCollectorHealth("01234567", "blocked", {
      generated_at: "2026-09-13T10:00:00.000Z",
    });
    const row = (await store.getCollectorHealth())[0]!;
    expect(row.status).toBe("blocked");
    expect(row.firstSeenAt.toISOString()).toBe("2026-09-13T09:00:00.000Z");
    expect(row.updatedAt.toISOString()).toBe("2026-09-13T10:00:00.000Z");
  });

  it("renders every compact metric, truncates blocks, and handles no row", () => {
    const html = renderToStaticMarkup(
      createElement(CollectorHealth, {
        record: {
          identity: validPayload.identity,
          status: "blocked",
          summary: {
            ...validPayload,
            blocks: Array.from({ length: 5 }, (_, index) => ({
              run_key: `run-${index}`,
              sequence: index + 1,
              reason: "gap",
            })),
          },
          firstSeenAt: new Date(),
          updatedAt: new Date(),
        },
        serverTime: new Date("2026-09-13T10:01:05.000Z"),
      }),
    );
    expect(html).toContain("Collector health");
    expect(html).toContain("blocked");
    expect(html).toContain("1m ago");
    expect(html).toContain("run-3");
    expect(html).not.toContain("run-4");
    expect(html).toContain("…");

    const empty = renderToStaticMarkup(
      createElement(CollectorHealth, { record: null, serverTime: new Date() }),
    );
    expect(empty).toContain("No collector status received yet.");
  });
});

import { beforeEach, describe, expect, it, vi } from "vitest";

const storeMocks = vi.hoisted(() => ({
  getRunByRunKey: vi.fn(),
  listKillAttributions: vi.fn(),
  listAssistAttributions: vi.fn(),
}));

vi.mock("@/telemetry/store", () => ({
  NeonTelemetryStore: class {
    getRunByRunKey = storeMocks.getRunByRunKey;
    listKillAttributions = storeMocks.listKillAttributions;
    listAssistAttributions = storeMocks.listAssistAttributions;
  },
}));

import { GET } from "../src/app/api/telemetry/runs/[runId]/kills/route";

describe("kills read API", () => {
  beforeEach(() => {
    vi.resetAllMocks();
  });

  it("returns the run's persisted kill and assist rows", async () => {
    storeMocks.getRunByRunKey.mockResolvedValue({
      producerId: "dcs-server-alpha",
      runKey: "run-kills-api",
    });
    storeMocks.listKillAttributions.mockResolvedValue([
      { targetAssetKey: "target-1", killerAssetKey: "killer-1" },
    ]);
    storeMocks.listAssistAttributions.mockResolvedValue([
      { targetAssetKey: "target-1", attackerAssetKey: "wingman-1" },
    ]);

    const response = await GET(new Request("http://localhost/kills"), {
      params: Promise.resolve({ runId: "run-kills-api" }),
    });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      runId: "run-kills-api",
      kills: [{ targetAssetKey: "target-1", killerAssetKey: "killer-1" }],
      assists: [{ targetAssetKey: "target-1", attackerAssetKey: "wingman-1" }],
    });
    expect(storeMocks.listKillAttributions).toHaveBeenCalledWith(
      "dcs-server-alpha",
      "run-kills-api",
    );
    expect(storeMocks.listAssistAttributions).toHaveBeenCalledWith(
      "dcs-server-alpha",
      "run-kills-api",
    );
  });

  it("returns the shared not-found shape without listing facts", async () => {
    storeMocks.getRunByRunKey.mockResolvedValue(null);

    const response = await GET(new Request("http://localhost/kills"), {
      params: Promise.resolve({ runId: "missing" }),
    });

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "run-not-found" });
    expect(storeMocks.listKillAttributions).not.toHaveBeenCalled();
    expect(storeMocks.listAssistAttributions).not.toHaveBeenCalled();
  });

  it("returns the shared internal-error shape", async () => {
    storeMocks.getRunByRunKey.mockRejectedValue(new Error("offline"));

    const response = await GET(new Request("http://localhost/kills"), {
      params: Promise.resolve({ runId: "broken" }),
    });

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "internal" });
  });
});

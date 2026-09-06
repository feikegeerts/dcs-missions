import { beforeEach, describe, expect, it, vi } from "vitest";

const storeMocks = vi.hoisted(() => ({
  getRunByRunKey: vi.fn(),
  listAssetLosses: vi.fn(),
}));

vi.mock("@/telemetry/store", () => ({
  NeonTelemetryStore: class {
    getRunByRunKey = storeMocks.getRunByRunKey;
    listAssetLosses = storeMocks.listAssetLosses;
  },
}));

import { GET } from "../src/app/api/telemetry/runs/[runId]/losses/route";

describe("losses read API", () => {
  beforeEach(() => {
    vi.resetAllMocks();
  });

  it("returns the run's persisted loss rows", async () => {
    storeMocks.getRunByRunKey.mockResolvedValue({
      producerId: "dcs-server-alpha",
      runKey: "run-loss-api",
    });
    storeMocks.listAssetLosses.mockResolvedValue([
      {
        factId: '["asset.lost","dcs-server-alpha","run-loss-api","a1",["e1"]]',
        producerId: "dcs-server-alpha",
        runKey: "run-loss-api",
        assetKey: "a1",
        aircraftDcsType: "FA-18C_hornet",
        coalition: "blue",
        catalogue: "ordnance",
        catalogueVersion: 1,
        unitCostCents: 2_900_000_000,
        sourceEventIds: ["e1"],
      },
    ]);

    const response = await GET(new Request("http://localhost/losses"), {
      params: Promise.resolve({ runId: "run-loss-api" }),
    });

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      runId: "run-loss-api",
      count: 1,
      losses: [
        {
          assetKey: "a1",
          unitCostCents: 2_900_000_000,
          sourceEventIds: ["e1"],
        },
      ],
    });
    expect(storeMocks.listAssetLosses).toHaveBeenCalledWith(
      "dcs-server-alpha",
      "run-loss-api",
    );
  });

  it("returns the shared not-found shape without listing losses", async () => {
    storeMocks.getRunByRunKey.mockResolvedValue(null);

    const response = await GET(new Request("http://localhost/losses"), {
      params: Promise.resolve({ runId: "missing" }),
    });

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "run-not-found" });
    expect(storeMocks.listAssetLosses).not.toHaveBeenCalled();
  });
});

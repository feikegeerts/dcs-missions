import { beforeEach, describe, expect, it, vi } from "vitest";

const storeMocks = vi.hoisted(() => ({
  listRuns: vi.fn(),
  getCollectorHealth: vi.fn(),
}));

vi.mock("@/telemetry/store", () => ({
  NeonTelemetryStore: class {
    listRuns = storeMocks.listRuns;
    getCollectorHealth = storeMocks.getCollectorHealth;
  },
}));

import MissionsPage from "../src/app/page";

describe("home refresh query cost", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    storeMocks.listRuns.mockResolvedValue([]);
    storeMocks.getCollectorHealth.mockResolvedValue([]);
  });

  it("keeps collector-health queries off the home render", async () => {
    const props = { searchParams: Promise.resolve({}) };

    await MissionsPage(props);
    expect(storeMocks.listRuns).toHaveBeenCalledTimes(1);
    expect(storeMocks.getCollectorHealth).not.toHaveBeenCalled();

    await MissionsPage(props);
    expect(storeMocks.listRuns).toHaveBeenCalledTimes(2);
    expect(storeMocks.getCollectorHealth).not.toHaveBeenCalled();
  });
});

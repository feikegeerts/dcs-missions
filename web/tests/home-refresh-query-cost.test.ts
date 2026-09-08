import { beforeEach, describe, expect, it, vi } from "vitest";

const storeMocks = vi.hoisted(() => ({
  listRuns: vi.fn(),
}));

vi.mock("@/telemetry/store", () => ({
  NeonTelemetryStore: class {
    listRuns = storeMocks.listRuns;
  },
}));

import MissionsPage from "../src/app/page";

describe("home refresh query cost", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    storeMocks.listRuns.mockResolvedValue([]);
  });

  it("adds no store query beyond the page's one listRuns call per render", async () => {
    const props = { searchParams: Promise.resolve({}) };

    await MissionsPage(props);
    expect(storeMocks.listRuns).toHaveBeenCalledTimes(1);

    await MissionsPage(props);
    expect(storeMocks.listRuns).toHaveBeenCalledTimes(2);
  });
});

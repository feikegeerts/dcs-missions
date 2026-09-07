import { describe, expect, it } from "vitest";

import { displayRunStatus, STALE_AFTER_MS } from "../src/telemetry/run-status";

const NOW = new Date("2026-09-05T18:00:00Z");

describe("run liveness display", () => {
  it("keeps ended runs ended regardless of age", () => {
    expect(
      displayRunStatus("ended", new Date("2026-08-01T00:00:00Z"), NOW),
    ).toBe("ended");
  });

  it("keeps aborted runs aborted regardless of age", () => {
    expect(
      displayRunStatus("aborted", new Date("2026-08-01T00:00:00Z"), NOW),
    ).toBe("aborted");
  });

  it("keeps freshly heartbeating runs active", () => {
    expect(
      displayRunStatus("active", new Date(NOW.getTime() - 30 * 1000), NOW),
    ).toBe("active");
  });

  it("marks active runs with no recent heartbeat stale", () => {
    expect(
      displayRunStatus(
        "active",
        new Date(NOW.getTime() - STALE_AFTER_MS - 1000),
        NOW,
      ),
    ).toBe("stale");
  });

  it("treats the threshold boundary as still active", () => {
    expect(
      displayRunStatus("active", new Date(NOW.getTime() - STALE_AFTER_MS), NOW),
    ).toBe("active");
  });
});

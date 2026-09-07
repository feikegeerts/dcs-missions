import { describe, expect, it } from "vitest";

import {
  DASHBOARD_TIME_ZONE,
  formatDashboardDate,
  formatDashboardDateTime,
  runKeyTimestamp,
  shortRunKey,
} from "../src/telemetry/dates";

describe("dashboard dates", () => {
  it("uses the Amsterdam timezone, including daylight-saving time", () => {
    expect(DASHBOARD_TIME_ZONE).toBe("Europe/Amsterdam");
    expect(formatDashboardDateTime("2026-09-07T17:46:08Z")).toBe(
      "7 Sept 2026, 19:46 CEST",
    );
    expect(formatDashboardDateTime("2026-01-07T17:46:08Z")).toBe(
      "7 Jan 2026, 18:46 CET",
    );
  });

  it("formats date-only values in Amsterdam time", () => {
    expect(formatDashboardDate("2026-09-07T22:30:00Z")).toBe("8 Sept 2026");
  });
});

describe("run references", () => {
  it("recovers generated run timestamps when started_at is missing", () => {
    expect(
      formatDashboardDateTime(
        runKeyTimestamp("run-20260907T174608Z-39c240d0") ?? "",
      ),
    ).toBe("7 Sept 2026, 19:46 CEST");
    expect(runKeyTimestamp("legacy-run")).toBeNull();
  });

  it("keeps only the readable opaque suffix in the secondary label", () => {
    expect(shortRunKey("run-20260907T174608Z-39c240d0")).toBe("39c240d0");
    expect(shortRunKey("legacy-run")).toBe("run");
    expect(shortRunKey("run-without-suffix-")).toBe("run-without-suffix-");
  });
});

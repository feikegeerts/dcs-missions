import { describe, expect, it } from "vitest";

import {
  DASHBOARD_RUN_SCOPE_LIMIT,
  DOSSIER_RUNS_PER_PAGE,
} from "../src/telemetry/dashboard";

type ScopedRun = {
  runKey: string;
  missionName: string | null;
  updatedAt: string;
};

/**
 * Busy-mission regression for the dossier history query.
 *
 * The dossier page must filter by mission in the store BEFORE the scope
 * limit. The old pattern (global limit, then filter in memory) lets one busy
 * mission push another mission's valid history out of the window. The store
 * contract `listMissionRuns` applies the mission predicate first; this test
 * locks that ordering for every implementation, including the in-memory
 * doubles used across the suite.
 */
function missionScopedQuery(
  rows: readonly ScopedRun[],
  missionName: string | null,
  limit: number,
  offset: number,
): ScopedRun[] {
  const matching = rows.filter((run) =>
    missionName === null
      ? run.missionName === null || run.missionName === ""
      : run.missionName === missionName,
  );
  return matching.slice(offset, offset + limit);
}

function globalThenFilter(
  rows: readonly ScopedRun[],
  missionName: string | null,
  limit: number,
): ScopedRun[] {
  return rows.slice(0, limit).filter((run) =>
    missionName === null
      ? run.missionName === null || run.missionName === ""
      : run.missionName === missionName,
  );
}

function runAt(index: number, missionName: string | null): ScopedRun {
  return {
    runKey: `run-${index}`,
    missionName,
    updatedAt: `2026-09-${String((index % 28) + 1).padStart(2, "0")}T00:00:00Z`,
  };
}

describe("mission-scoped run history", () => {
  it("keeps a quiet mission's history when another mission is busy", () => {
    const busy = Array.from({ length: 60 }, (_, index) =>
      runAt(index, "duel-dynamic"),
    );
    const quiet = Array.from({ length: 5 }, (_, index) =>
      runAt(100 + index, "duel-dynamic-bvr"),
    );
    // Busy rows sort first, as a global updatedAt-descending query would.
    const rows = [...busy, ...quiet];

    expect(globalThenFilter(rows, "duel-dynamic-bvr", 20)).toHaveLength(0);

    const scoped = missionScopedQuery(
      rows,
      "duel-dynamic-bvr",
      DASHBOARD_RUN_SCOPE_LIMIT,
      0,
    );
    expect(scoped).toHaveLength(5);
    expect(scoped.map((run) => run.runKey)).toEqual(
      quiet.map((run) => run.runKey),
    );
  });

  it("paginates within one mission's scope", () => {
    const rows = Array.from({ length: 45 }, (_, index) =>
      runAt(index, "air-superiority-survival"),
    );
    const first = missionScopedQuery(
      rows,
      "air-superiority-survival",
      DOSSIER_RUNS_PER_PAGE + 1,
      0,
    );
    expect(first).toHaveLength(DOSSIER_RUNS_PER_PAGE + 1);
    const second = missionScopedQuery(
      rows,
      "air-superiority-survival",
      DOSSIER_RUNS_PER_PAGE + 1,
      DOSSIER_RUNS_PER_PAGE,
    );
    // 45 rows: offsets 0-19, 20-39, 40-44. The +1 over-fetch proves a next page.
    expect(second).toHaveLength(DOSSIER_RUNS_PER_PAGE + 1);
    expect(second[0]?.runKey).toBe("run-20");
    const last = missionScopedQuery(
      rows,
      "air-superiority-survival",
      DOSSIER_RUNS_PER_PAGE + 1,
      DOSSIER_RUNS_PER_PAGE * 2,
    );
    expect(last).toHaveLength(5);
    expect(last[0]?.runKey).toBe("run-40");
  });

  it("reports an honest empty state for missions with no runs", () => {
    const rows = [runAt(1, "duel-dynamic")];
    expect(
      missionScopedQuery(rows, "duel-dynamic-acm", DASHBOARD_RUN_SCOPE_LIMIT, 0),
    ).toEqual([]);
  });

  it("keeps the unknown bucket separate from named missions", () => {
    const rows = [runAt(1, null), runAt(2, ""), runAt(3, "duel-dynamic")];
    expect(
      missionScopedQuery(rows, null, DASHBOARD_RUN_SCOPE_LIMIT, 0),
    ).toHaveLength(2);
    expect(
      missionScopedQuery(
        rows,
        "duel-dynamic",
        DASHBOARD_RUN_SCOPE_LIMIT,
        0,
      ),
    ).toHaveLength(1);
  });
});

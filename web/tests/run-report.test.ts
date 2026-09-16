import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { RunReport } from "../src/components/run-report";
import type { RunReportData } from "../src/telemetry/run-report";

describe("aircraft allowance terminology", () => {
  it("labels coalition loss counters as aircraft losses, not pilot deaths", () => {
    const now = new Date("2026-09-15T07:00:00Z");
    const data: RunReportData = {
      run: {
        producerId: "test-producer",
        runKey: "test-run",
        missionName: "air-superiority-survival",
        missionVersion: "1",
        mapName: "Syria",
        runClassification: "test",
        valuationCatalogue: null,
        valuationCatalogueVersion: null,
        firstSequence: 1,
        lastSequence: 0,
        eventCount: 0,
        startedAt: now,
        endedAt: null,
        status: "active",
        createdAt: now,
        updatedAt: now,
      },
      runEvents: [],
      expenditures: [],
      losses: [],
      kills: [],
      assists: [],
      participants: [],
    };
    const html = renderToStaticMarkup(createElement(RunReport, { data }));
    expect(html.match(/<dt>Aircraft losses<\/dt>/g)).toHaveLength(2);
    expect(html).not.toContain("<dt>Deaths</dt>");
    expect(html).not.toContain("<dt>Losses</dt>");
  });
});

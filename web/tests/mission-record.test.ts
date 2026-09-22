import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { MissionRecord } from "../src/components/mission-record";
import {
  publicPlayerIdFor,
  summarizeRunCombat,
  type HighScoreRun,
} from "../src/telemetry/dashboard";

const record: HighScoreRun = {
  runKey: "record-run",
  producerId: "server",
  startedAt: "2026-09-07T18:56:00Z",
  humans: 2,
  waveSummary: { observed: true, spawnedWaves: 3, clearedWaves: 2 },
  summary: {
    ...summarizeRunCombat({ expenditures: [], losses: [], kills: [] }),
    blueTotalCents: 3845000000,
  },
};

describe("mission record card", () => {
  it("recognizes participants and renders the score, challenge and explicit run link", () => {
    const html = renderToStaticMarkup(
      createElement(MissionRecord, {
        record,
        participants: [
          { participantId: "pilot/one", displayName: "Viper" },
          { participantId: "two", displayName: " " },
        ],
      }),
    );
    for (const text of [
      "Mission record",
      "Viper",
      "Unnamed participant",
      "2 participants",
      "$38,450,000",
      "clear 3+ waves",
      "clear 2 for less than",
      "Run started",
      "View record run",
      "Ranking &amp; eligibility",
      "not an all-time leaderboard",
    ]) {
      expect(html).toContain(text);
    }
    expect(html).toContain(`href="/players/${publicPlayerIdFor("pilot/one")}"`);
    expect(html).toContain('href="/runs/record-run"');
  });

  it("does not challenge players to beat a zero cost or invent missing identities or dates", () => {
    const html = renderToStaticMarkup(
      createElement(MissionRecord, {
        record: {
          ...record,
          humans: 0,
          startedAt: null,
          summary: { ...record.summary, blueTotalCents: 0 },
        },
        participants: [],
      }),
    );
    expect(html).toContain("No participants recorded");
    expect(html).toContain("Run start time unavailable");
    expect(html).not.toContain("for less than");
  });

  it("recovers the run start time from generated run keys", () => {
    const html = renderToStaticMarkup(
      createElement(MissionRecord, {
        record: {
          ...record,
          runKey: "run-20260907T174608Z-39c240d0",
          startedAt: null,
        },
        participants: [],
      }),
    );
    expect(html).toContain("Run started");
    expect(html).not.toContain("Run start time unavailable");
  });

  it("renders an honest empty state and retains eligibility details", () => {
    const html = renderToStaticMarkup(
      createElement(MissionRecord, { record: null, participants: [] }),
    );
    expect(html).toContain("The record is still open.");
    expect(html).toContain("observed wave data");
    expect(html).toContain("1,000 dashboard runs");
    expect(html).not.toContain("View record run");
  });
});

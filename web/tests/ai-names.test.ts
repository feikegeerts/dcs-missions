import { describe, expect, it } from "vitest";

import { AI_CALLSIGNS, buildAiCallsigns } from "../src/telemetry/ai-names";

describe("AI callsigns", () => {
  it("is deterministic for a run and asset order", () => {
    const assets = ["bandit-1.u1.g1", "bandit-1.u2.g1", "bandit-1.u1.g2"];
    const first = buildAiCallsigns("run-a", assets);
    const second = buildAiCallsigns("run-a", assets);

    expect([...first.entries()]).toEqual([...second.entries()]);
    expect(new Set(first.values()).size).toBe(assets.length);
  });

  it("keeps labels unique beyond the base pool size", () => {
    const assets = Array.from(
      { length: AI_CALLSIGNS.length + 10 },
      (_, index) => `bandit-${index}.u1.g1`,
    );
    const labels = buildAiCallsigns("run-many-ai", assets);

    expect(labels.size).toBe(assets.length);
    expect(new Set(labels.values()).size).toBe(assets.length);
    expect([...labels.values()].some((label) => / 2$/.test(label))).toBe(true);
  });
});

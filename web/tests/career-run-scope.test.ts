import { describe, expect, it, vi } from "vitest";

const db = vi.hoisted(() => ({ select: vi.fn() }));
vi.mock("@/db/client", () => ({ getDb: () => db }));

import { NeonTelemetryStore } from "../src/telemetry/store";

describe("career run scope", () => {
  it.each([null, "test", "historical"] as const)(
    "returns more than 1000 runs without a limit for %s",
    async (classification) => {
      const rows = Array.from({ length: 1001 }, (_, i) => ({
        runKey: `run-${i}`,
      }));
      const orderBy = vi.fn().mockResolvedValue(rows);
      const where = vi.fn().mockReturnValue({ orderBy });
      const from = vi.fn().mockReturnValue({ where });
      // No limit/offset methods: adding a cap makes this test fail.
      db.select.mockReturnValue({ from });
      const result = await new NeonTelemetryStore().listCareerRuns(
        classification,
      );
      expect(result).toHaveLength(1001);
      expect(result[1000].runKey).toBe("run-1000");
      if (classification === null) {
        expect(where).toHaveBeenCalledWith(undefined);
      } else {
        expect(where.mock.calls[0][0]).toBeDefined();
      }
    },
  );
});

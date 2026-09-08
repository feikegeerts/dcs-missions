import { describe, expect, it, vi } from "vitest";

import {
  advanceRefreshSchedule,
  AGGRESSIVE_REFRESH_INTERVAL_MS,
  createRefreshSchedule,
  MAX_REFRESH_BACKOFF_MS,
  SLOW_REFRESH_INTERVAL_MS,
  type RefreshClock,
  type RefreshScheduleState,
} from "../src/telemetry/refresh-schedule";
import type { DisplayRunStatus } from "../src/telemetry/run-status";

function fakeClock(initial = 1_000): RefreshClock & { value: number } {
  return {
    value: initial,
    now() {
      return this.value;
    },
  };
}

function started(state: RefreshScheduleState): RefreshScheduleState {
  return { ...state, inFlight: true };
}

describe("refresh schedule", () => {
  it.each([
    ["active", AGGRESSIVE_REFRESH_INTERVAL_MS, "aggressive"],
    ["stale", SLOW_REFRESH_INTERVAL_MS, "slow"],
    ["ended", SLOW_REFRESH_INTERVAL_MS, "slow"],
    ["aborted", SLOW_REFRESH_INTERVAL_MS, "slow"],
    [null, SLOW_REFRESH_INTERVAL_MS, "slow"],
  ] as const)(
    "maps %s status to its owner-tunable cadence",
    (status, delay, tier) => {
      const decision = createRefreshSchedule(status, "visible", fakeClock());

      expect(decision.nextDelayMs).toBe(delay);
      expect(decision.cadenceTier).toBe(tier);
      expect(decision.scheduleTimer).toBe(true);
    },
  );

  it("suppresses the aggressive hidden tick and refreshes on visibility restore", () => {
    const clock = fakeClock();
    const active = createRefreshSchedule("active", "visible", clock);
    clock.value += 500;
    const hidden = advanceRefreshSchedule(
      active.state,
      { type: "visibility", visibility: "hidden" },
      clock,
    );

    expect(hidden.refreshNow).toBe(false);
    expect(hidden.nextDelayMs).toBe(SLOW_REFRESH_INTERVAL_MS);
    expect(hidden.cadenceTier).toBe("slow");

    clock.value += AGGRESSIVE_REFRESH_INTERVAL_MS;
    const oldAggressiveTick = advanceRefreshSchedule(
      hidden.state,
      { type: "timer" },
      clock,
    );
    expect(oldAggressiveTick.refreshNow).toBe(false);

    const visible = advanceRefreshSchedule(
      oldAggressiveTick.state,
      { type: "visibility", visibility: "visible" },
      clock,
    );
    expect(visible.refreshNow).toBe(true);
    expect(visible.state.inFlight).toBe(true);
    expect(visible.scheduleTimer).toBe(false);
  });

  it.each(["focus", "online"] as const)(
    "refreshes immediately on %s",
    (type) => {
      const clock = fakeClock();
      const initial = createRefreshSchedule(null, "visible", clock);

      const decision = advanceRefreshSchedule(initial.state, { type }, clock);

      expect(decision.refreshNow).toBe(true);
      expect(decision.state.inFlight).toBe(true);
      expect(decision.scheduleTimer).toBe(false);
    },
  );

  it("never decides on a second refresh while one is in flight", () => {
    const clock = fakeClock();
    const initial = createRefreshSchedule("active", "visible", clock);
    const first = advanceRefreshSchedule(
      initial.state,
      { type: "focus" },
      clock,
    );
    clock.value += AGGRESSIVE_REFRESH_INTERVAL_MS;

    for (const event of [
      { type: "timer" } as const,
      { type: "focus" } as const,
      { type: "online" } as const,
      { type: "visibility", visibility: "visible" } as const,
    ]) {
      const duplicate = advanceRefreshSchedule(first.state, event, clock);
      expect(duplicate.refreshNow).toBe(false);
      expect(duplicate.scheduleTimer).toBe(false);
    }
  });

  it("backs off failures to 60 seconds, always reschedules, and resets on success", () => {
    const clock = fakeClock();
    let state = createRefreshSchedule("active", "visible", clock).state;
    const delays: number[] = [];

    for (let failure = 0; failure < 6; failure += 1) {
      const outcome = advanceRefreshSchedule(
        started(state),
        { type: "settled", succeeded: false },
        clock,
      );
      delays.push(outcome.nextDelayMs);
      expect(outcome.nextDelayMs).toBeGreaterThan(0);
      expect(outcome.scheduleTimer).toBe(true);
      state = outcome.state;
    }

    expect(delays).toEqual([4_000, 8_000, 16_000, 32_000, 60_000, 60_000]);
    expect(delays.at(-1)).toBe(MAX_REFRESH_BACKOFF_MS);

    const recovered = advanceRefreshSchedule(
      started(state),
      { type: "settled", succeeded: true },
      clock,
    );
    expect(recovered.state.failureCount).toBe(0);
    expect(recovered.nextDelayMs).toBe(AGGRESSIVE_REFRESH_INTERVAL_MS);
    expect(recovered.cadenceTier).toBe("aggressive");
  });

  it("reschedules once from now when cadence tiers change", () => {
    const clock = fakeClock();
    const active = createRefreshSchedule("active", "visible", clock);
    clock.value += 750;
    const stale = advanceRefreshSchedule(
      active.state,
      { type: "status", displayStatus: "stale" },
      clock,
    );
    expect(stale.nextDelayMs).toBe(SLOW_REFRESH_INTERVAL_MS);
    expect(stale.scheduleTimer).toBe(true);
    expect(stale.cadenceTier).toBe("slow");

    clock.value += 500;
    const activeAgain = advanceRefreshSchedule(
      stale.state,
      { type: "status", displayStatus: "active" },
      clock,
    );
    expect(activeAgain.nextDelayMs).toBe(AGGRESSIVE_REFRESH_INTERVAL_MS);
    expect(activeAgain.scheduleTimer).toBe(true);
    expect(activeAgain.cadenceTier).toBe("aggressive");
  });

  it("uses only the injected clock", () => {
    const dateNow = vi.spyOn(Date, "now").mockImplementation(() => {
      throw new Error("ambient clock used");
    });
    const clock = fakeClock(42_000);

    const initial = createRefreshSchedule(
      "active" satisfies DisplayRunStatus,
      "visible",
      clock,
    );
    clock.value += AGGRESSIVE_REFRESH_INTERVAL_MS;
    const due = advanceRefreshSchedule(initial.state, { type: "timer" }, clock);

    expect(due.refreshNow).toBe(true);
    expect(dateNow).not.toHaveBeenCalled();
  });
});

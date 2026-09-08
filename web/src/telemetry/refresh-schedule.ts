import type { DisplayRunStatus } from "./run-status";

export const AGGRESSIVE_REFRESH_INTERVAL_MS = 2_000;
export const SLOW_REFRESH_INTERVAL_MS = 30_000;
export const MAX_REFRESH_BACKOFF_MS = 60_000;

export type RefreshVisibility = "visible" | "hidden";
export type RefreshCadenceTier = "aggressive" | "slow" | "backoff";

export interface RefreshClock {
  now(): number;
}

export interface RefreshScheduleState {
  displayStatus: DisplayRunStatus | null;
  visibility: RefreshVisibility;
  failureCount: number;
  inFlight: boolean;
  nextRefreshAt: number;
}

export type RefreshScheduleEvent =
  | { type: "status"; displayStatus: DisplayRunStatus | null }
  | { type: "visibility"; visibility: RefreshVisibility }
  | { type: "focus" | "online" | "timer" }
  | { type: "settled"; succeeded: boolean };

export interface RefreshScheduleDecision {
  state: RefreshScheduleState;
  refreshNow: boolean;
  scheduleTimer: boolean;
  nextDelayMs: number;
  cadenceTier: RefreshCadenceTier;
}

function baseDelay(state: RefreshScheduleState): number {
  return state.displayStatus === "active" && state.visibility === "visible"
    ? AGGRESSIVE_REFRESH_INTERVAL_MS
    : SLOW_REFRESH_INTERVAL_MS;
}

function effectiveDelay(state: RefreshScheduleState): number {
  const base = baseDelay(state);
  if (state.failureCount === 0) {
    return base;
  }
  const multiplier = 2 ** Math.min(state.failureCount, 10);
  return Math.min(MAX_REFRESH_BACKOFF_MS, base * multiplier);
}

function cadenceTier(state: RefreshScheduleState): RefreshCadenceTier {
  if (state.failureCount > 0) {
    return "backoff";
  }
  return baseDelay(state) === AGGRESSIVE_REFRESH_INTERVAL_MS
    ? "aggressive"
    : "slow";
}

function decision(
  state: RefreshScheduleState,
  refreshNow: boolean,
  now: number,
): RefreshScheduleDecision {
  return {
    state,
    refreshNow,
    scheduleTimer: !state.inFlight,
    nextDelayMs: Math.max(0, state.nextRefreshAt - now),
    cadenceTier: cadenceTier(state),
  };
}

export function createRefreshSchedule(
  displayStatus: DisplayRunStatus | null,
  visibility: RefreshVisibility,
  clock: RefreshClock,
): RefreshScheduleDecision {
  const now = clock.now();
  const state: RefreshScheduleState = {
    displayStatus,
    visibility,
    failureCount: 0,
    inFlight: false,
    nextRefreshAt: now,
  };
  state.nextRefreshAt = now + effectiveDelay(state);
  return decision(state, false, now);
}

export function advanceRefreshSchedule(
  previous: RefreshScheduleState,
  event: RefreshScheduleEvent,
  clock: RefreshClock,
): RefreshScheduleDecision {
  const now = clock.now();
  const state = { ...previous };
  let refreshNow = false;

  if (event.type === "status") {
    state.displayStatus = event.displayStatus;
    state.nextRefreshAt = now + effectiveDelay(state);
  } else if (event.type === "visibility") {
    const becameVisible =
      state.visibility === "hidden" && event.visibility === "visible";
    state.visibility = event.visibility;
    if (becameVisible && !state.inFlight) {
      state.inFlight = true;
      refreshNow = true;
    } else {
      state.nextRefreshAt = now + effectiveDelay(state);
    }
  } else if (event.type === "focus" || event.type === "online") {
    if (!state.inFlight) {
      state.inFlight = true;
      refreshNow = true;
    }
  } else if (event.type === "timer") {
    if (!state.inFlight && now >= state.nextRefreshAt) {
      state.inFlight = true;
      refreshNow = true;
    }
  } else if (event.type === "settled" && state.inFlight) {
    state.inFlight = false;
    state.failureCount = event.succeeded ? 0 : state.failureCount + 1;
    state.nextRefreshAt = now + effectiveDelay(state);
  }

  return decision(state, refreshNow, now);
}

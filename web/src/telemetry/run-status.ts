/**
 * Display-only run liveness.
 *
 * A run stays `active` in storage until an explicit `mission.ended`
 * arrives, so missions that die without ending (killed DCS process,
 * stopped server) read as active forever. This module derives a
 * presentation label from heartbeat age without mutating anything:
 * authoritative stale/aborted classification is Slice 16 Sol work and
 * remains parked.
 *
 * A run showing `active` with no heartbeat for longer than
 * STALE_AFTER_MS is displayed as `stale`. The threshold is deliberately
 * generous (twenty missed 30-second heartbeats): a paused simulation
 * also stops heartbeating, and labelling that "stale" is honest — no new
 * events can arrive until it resumes.
 */

export const STALE_AFTER_MS = 10 * 60 * 1000;

export type StoredRunStatus = "active" | "ended";

export type DisplayRunStatus = "active" | "stale" | "ended";

export function displayRunStatus(
  storedStatus: StoredRunStatus,
  updatedAt: Date,
  now: Date = new Date(),
): DisplayRunStatus {
  if (storedStatus === "ended") {
    return "ended";
  }
  if (now.getTime() - updatedAt.getTime() > STALE_AFTER_MS) {
    return "stale";
  }
  return "active";
}

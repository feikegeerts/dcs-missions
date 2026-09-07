/**
 * Display-only run liveness.
 *
 * A run stays `active` in storage until an explicit `mission.ended` arrives
 * or a replacement run from the same producer authoritatively marks it
 * `aborted`. This module derives a stale presentation label from heartbeat
 * age without mutating storage. Stored `aborted` and `ended` statuses are
 * terminal and always displayed as-is.
 *
 * A run showing `active` with no heartbeat for longer than
 * STALE_AFTER_MS is displayed as `stale`. The threshold is deliberately
 * generous (twenty missed 30-second heartbeats): a paused simulation
 * also stops heartbeating, and labelling that "stale" is honest — no new
 * events can arrive until it resumes.
 */

export const STALE_AFTER_MS = 10 * 60 * 1000;

export type StoredRunStatus = "active" | "aborted" | "ended";

export type DisplayRunStatus = "active" | "stale" | "aborted" | "ended";

export function displayRunStatus(
  storedStatus: StoredRunStatus,
  updatedAt: Date,
  now: Date = new Date(),
): DisplayRunStatus {
  if (storedStatus === "ended" || storedStatus === "aborted") {
    return storedStatus;
  }
  if (now.getTime() - updatedAt.getTime() > STALE_AFTER_MS) {
    return "stale";
  }
  return "active";
}

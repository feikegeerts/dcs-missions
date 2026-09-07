/**
 * Rebuild derived facts from a run's retained raw event stream.
 *
 * `replayRun` throws `ReplayRunNotFoundError` when the run key is unknown.
 * It repairs the mission run summary and writes facts through the store's
 * idempotent, snapshot-safe projection methods.
 */

import {
  reconcileAssistAttributions,
  reconcileKillAttributions,
} from "./combat-facts";
import {
  catalogueForAssignment,
  deriveExpenditure,
  participantObservation,
  type CatalogueAssignment,
} from "./expenditures";
import { reconcileAssetLosts } from "./losses";
import type { TelemetryStore } from "./store";
import type { TelemetryEvent } from "./types";

export type ReplayStore = Pick<
  TelemetryStore,
  | "getRunByRunKey"
  | "listRunEvents"
  | "upsertRun"
  | "insertExpenditure"
  | "upsertAssetLoss"
  | "upsertKillAttribution"
  | "upsertAssistAttribution"
  | "upsertRunParticipant"
>;

export class ReplayRunNotFoundError extends Error {
  constructor(readonly runKey: string) {
    super(`Telemetry run not found: ${runKey}`);
    this.name = "ReplayRunNotFoundError";
  }
}

function canonicalValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(canonicalValue);
  }
  if (typeof value === "object" && value !== null) {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [
          key,
          canonicalValue((value as Record<string, unknown>)[key]),
        ]),
    );
  }
  return value;
}

/** Serialize JSON content deterministically by recursively sorting object keys. */
export function canonicalJson(value: unknown): string {
  const serialized = JSON.stringify(canonicalValue(value));
  if (serialized === undefined) {
    throw new TypeError("Value is not JSON-serializable");
  }
  return serialized;
}

export function reconcileRunProjections(
  events: readonly TelemetryEvent[],
  assignment: CatalogueAssignment | null,
) {
  const catalogueAssigned = catalogueForAssignment(assignment) !== null;
  return {
    expenditures: catalogueAssigned
      ? events
          .map((event) => deriveExpenditure(event, assignment))
          .filter((fact) => fact !== null)
      : [],
    losses: catalogueAssigned ? reconcileAssetLosts(events, assignment) : [],
    kills: reconcileKillAttributions(events),
    assists: reconcileAssistAttributions(events),
    participants: events
      .map(participantObservation)
      .filter((observation) => observation !== null),
  };
}

function stringField(
  payload: Record<string, unknown>,
  field: string,
): string | null {
  const value = payload[field];
  return typeof value === "string" && value.length > 0 ? value : null;
}

export function reconcileRunSummary(events: readonly TelemetryEvent[]) {
  if (events.length === 0) {
    return null;
  }
  const started = events.find(
    (event) =>
      event.event_sequence === 1 && event.event_type === "mission.started",
  );
  const ended = events.find((event) => event.event_type === "mission.ended");
  return {
    firstSequence: Math.min(...events.map((event) => event.event_sequence)),
    lastSequence: Math.max(...events.map((event) => event.event_sequence)),
    eventCount: events.length,
    missionName: started ? stringField(started.payload, "mission_name") : null,
    missionVersion: started
      ? stringField(started.payload, "mission_version")
      : null,
    mapName: started ? stringField(started.payload, "map_name") : null,
    runClassification: started
      ? stringField(started.payload, "run_classification")
      : null,
    startedAt: started?.wall_time ?? null,
    endedAt: ended?.wall_time ?? null,
    status: ended ? ("ended" as const) : ("active" as const),
  };
}

export async function persistRunFromRetainedEvents(
  store: ReplayStore,
  producerId: string,
  runKey: string,
  events: readonly TelemetryEvent[],
  assignment: CatalogueAssignment | null,
): Promise<ReturnType<typeof reconcileRunProjections>> {
  const summary = reconcileRunSummary(events);
  if (summary === null) {
    return reconcileRunProjections(events, assignment);
  }

  await store.upsertRun({
    producerId,
    runKey,
    ...summary,
    valuationCatalogue: assignment?.catalogue ?? null,
    valuationCatalogueVersion: assignment?.version ?? null,
  });

  const projections = reconcileRunProjections(events, assignment);
  for (const expenditure of projections.expenditures) {
    await store.insertExpenditure(expenditure);
  }
  for (const participant of projections.participants) {
    await store.upsertRunParticipant(participant);
  }
  for (const loss of projections.losses) {
    await store.upsertAssetLoss(loss);
  }
  for (const kill of projections.kills) {
    await store.upsertKillAttribution(kill);
  }
  for (const assist of projections.assists) {
    await store.upsertAssistAttribution(assist);
  }
  return projections;
}

export async function replayRun(store: ReplayStore, runKey: string) {
  const run = await store.getRunByRunKey(runKey);
  if (run === null) {
    throw new ReplayRunNotFoundError(runKey);
  }

  const assignment: CatalogueAssignment | null =
    run.valuationCatalogue != null && run.valuationCatalogueVersion != null
      ? {
          catalogue: run.valuationCatalogue,
          version: run.valuationCatalogueVersion,
        }
      : null;
  const events = await store.listRunEvents(run.producerId, run.runKey);
  const projections = await persistRunFromRetainedEvents(
    store,
    run.producerId,
    run.runKey,
    events,
    assignment,
  );

  const firstEvent = events[0];
  const lastEvent = events[events.length - 1];
  return {
    runKey: run.runKey,
    eventCount: events.length,
    sequenceSpan:
      firstEvent && lastEvent
        ? {
            first: firstEvent.event_sequence,
            last: lastEvent.event_sequence,
          }
        : null,
    catalogue: assignment,
    expenditures: projections.expenditures.length,
    losses: projections.losses.length,
    kills: projections.kills.length,
    assists: projections.assists.length,
    participants: projections.participants.length,
  };
}

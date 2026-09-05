import type { TelemetryStore } from "./store";
import type { TelemetryEvent } from "./types";
import {
  catalogueForAssignment,
  currentOrdnanceAssignment,
  deriveExpenditure,
  participantObservation,
  type CatalogueAssignment,
} from "./expenditures";
import { validateBatch } from "./validate";

type IngestResult = {
  event_id: string;
  status: "accepted" | "duplicate" | "rejected";
  reason?: "schema-invalid" | "inconsistent-event-id" | "db-conflict";
};

function stringField(
  payload: Record<string, unknown>,
  field: string,
): string | null {
  const value = payload[field];
  return typeof value === "string" && value.length > 0 ? value : null;
}

function runFields(events: TelemetryEvent[]) {
  const firstEvent = events[0];
  const lastEvent = events[events.length - 1];
  const started = events.find(
    (event) =>
      event.event_sequence === 1 && event.event_type === "mission.started",
  );
  const ended = events.find((event) => event.event_type === "mission.ended");

  return {
    firstSequence: Math.min(...events.map((event) => event.event_sequence)),
    lastSequence: Math.max(...events.map((event) => event.event_sequence)),
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
    firstEvent,
    lastEvent,
  };
}

export async function processIngest(
  rawBodyText: string,
  store: TelemetryStore,
): Promise<{ httpStatus: number; body: unknown }> {
  const validation = validateBatch(rawBodyText);
  if (!validation.ok) {
    return {
      httpStatus: 400,
      body: { error: validation.code, message: validation.message },
    };
  }

  const results: IngestResult[] = [];
  let accepted = 0;
  let duplicates = 0;
  let rejected = 0;

  for (const result of validation.events) {
    if (!result.valid) {
      rejected += 1;
      results.push({
        event_id: result.event.event_id,
        status: "rejected",
        reason: result.rejectReason,
      });
      continue;
    }

    const outcome = await store.insertEvent(result.event);
    if (outcome === "accepted") {
      accepted += 1;
    } else if (outcome === "duplicate") {
      duplicates += 1;
    } else {
      rejected += 1;
    }
    results.push({
      event_id: result.event.event_id,
      status: outcome,
      ...(outcome === "rejected" ? { reason: "db-conflict" as const } : {}),
    });
  }

  const events = validation.events.map(({ event }) => event);
  const fields = runFields(events);

  // Catalogue assignment is pinned at run creation: a run row that does
  // not exist yet is explicitly assigned the current catalogue, while a
  // pre-existing row keeps whatever it has (including nothing — historical
  // runs are never retroactively priced). The same assignment prices every
  // expenditure projected from this batch, so a run can never mix versions.
  const preExistingRun = await store.getRunByRunKey(validation.runKey);
  const assignment: CatalogueAssignment | null = preExistingRun
    ? preExistingRun.valuationCatalogue != null &&
      preExistingRun.valuationCatalogueVersion != null
      ? {
          catalogue: preExistingRun.valuationCatalogue,
          version: preExistingRun.valuationCatalogueVersion,
        }
      : null
    : currentOrdnanceAssignment();

  await store.upsertRun({
    producerId: validation.producerId,
    runKey: validation.runKey,
    missionName: fields.missionName,
    missionVersion: fields.missionVersion,
    mapName: fields.mapName,
    runClassification: fields.runClassification,
    valuationCatalogue: assignment?.catalogue ?? null,
    valuationCatalogueVersion: assignment?.version ?? null,
    firstSequence: fields.firstSequence,
    lastSequence: fields.lastSequence,
    acceptedDelta: accepted,
    startedAt: fields.startedAt,
    endedAt: fields.endedAt,
    status: fields.status,
  });

  // Derived facts are projected after the run row exists (foreign keys).
  // Both newly accepted and duplicate source events are projected: a
  // duplicate re-pass repairs a projection that failed to persist, and
  // every projection insert is idempotent, so replays never double-charge.
  if (catalogueForAssignment(assignment) !== null) {
    for (let index = 0; index < validation.events.length; index += 1) {
      const result = validation.events[index];
      if (!result.valid) {
        continue;
      }
      const outcome = results[index]?.status;
      if (outcome !== "accepted" && outcome !== "duplicate") {
        continue;
      }
      const expenditure = deriveExpenditure(result.event, assignment);
      if (expenditure !== null) {
        await store.insertExpenditure(expenditure);
      }
    }
  }
  for (let index = 0; index < validation.events.length; index += 1) {
    const result = validation.events[index];
    if (!result.valid) {
      continue;
    }
    const outcome = results[index]?.status;
    if (outcome !== "accepted" && outcome !== "duplicate") {
      continue;
    }
    const observation = participantObservation(result.event);
    if (observation !== null) {
      await store.upsertRunParticipant({
        producerId: observation.producerId,
        runKey: observation.runKey,
        participantId: observation.participantId,
        displayName: observation.displayName,
        callsign: observation.callsign,
        coalition: observation.coalition,
        eventSequence: observation.eventSequence,
      });
    }
  }

  return {
    httpStatus: 200,
    body: {
      results,
      summary: { accepted, duplicates, rejected },
    },
  };
}

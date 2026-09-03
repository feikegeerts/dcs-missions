import type { TelemetryStore } from "./store";
import type { TelemetryEvent } from "./types";
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
  await store.upsertRun({
    producerId: validation.producerId,
    runKey: validation.runKey,
    missionName: fields.missionName,
    missionVersion: fields.missionVersion,
    mapName: fields.mapName,
    runClassification: fields.runClassification,
    firstSequence: fields.firstSequence,
    lastSequence: fields.lastSequence,
    acceptedDelta: accepted,
    startedAt: fields.startedAt,
    endedAt: fields.endedAt,
    status: fields.status,
  });

  return {
    httpStatus: 200,
    body: {
      results,
      summary: { accepted, duplicates, rejected },
    },
  };
}

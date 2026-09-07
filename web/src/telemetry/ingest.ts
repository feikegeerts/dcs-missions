import type { TelemetryStore } from "./store";
import {
  currentOrdnanceAssignment,
  type CatalogueAssignment,
} from "./expenditures";
import { validateBatch } from "./validate";
import { computeIngestMetrics } from "./ingest-metrics";
import { defaultRateLimiter, type FixedWindowRateLimiter } from "./rate-limit";
import { persistRunFromRetainedEvents } from "./replay";

type IngestResult = {
  event_id: string;
  status: "accepted" | "duplicate" | "rejected";
  reason?:
    | "schema-invalid"
    | "inconsistent-event-id"
    | "db-conflict"
    | "content-conflict";
};

export async function processIngest(
  rawBodyText: string,
  store: TelemetryStore,
  rateLimiter: FixedWindowRateLimiter = defaultRateLimiter,
): Promise<{ httpStatus: number; body: unknown }> {
  const validation = validateBatch(rawBodyText);
  if (!validation.ok) {
    return {
      httpStatus: 400,
      body: { error: validation.code, message: validation.message },
    };
  }

  if (!rateLimiter.tryAcquire(validation.producerId)) {
    return { httpStatus: 429, body: { error: "rate-limited" } };
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
      status: outcome === "content-conflict" ? "rejected" : outcome,
      ...(outcome === "rejected"
        ? { reason: "db-conflict" as const }
        : outcome === "content-conflict"
          ? { reason: "content-conflict" as const }
          : {}),
    });
  }

  const events = validation.events.map(({ event }) => event);

  // Catalogue assignment is pinned at run creation: a run row that does
  // not exist yet is explicitly assigned the current catalogue, while a
  // pre-existing row keeps whatever it has (including nothing — historical
  // runs are never retroactively priced). The same assignment prices every
  // expenditure projected from retained run truth, so a run cannot mix versions.
  // This lookup is not lifecycle evidence: ingest never changes another run.
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
  const metrics = computeIngestMetrics(
    events,
    results.map((result) => result.status),
    assignment,
  );

  const retainedEvents = await store.listRunEvents(
    validation.producerId,
    validation.runKey,
  );
  await persistRunFromRetainedEvents(
    store,
    validation.producerId,
    validation.runKey,
    retainedEvents,
    assignment,
  );

  return {
    httpStatus: 200,
    body: {
      results,
      summary: { accepted, duplicates, rejected },
      metrics,
    },
  };
}

import {
  catalogueForAssignment,
  deriveExpenditure,
  type CatalogueAssignment,
} from "./expenditures";
import type { TelemetryEvent } from "./types";

/**
 * v1 taxonomy types that are accepted and retained but not yet modeled by any
 * projection. When a projection is added for one, remove it here.
 */
export const UNMODELED_EVENT_TYPES: ReadonlySet<string> = new Set([
  "mission.heartbeat",
  "asset.spawned",
  "asset.despawned",
  "pilot.dead",
  "pilot.ejected",
]);

export type IngestMetrics = {
  unpriced: number;
  unknown: number;
};

export function computeIngestMetrics(
  events: readonly TelemetryEvent[],
  outcomes: readonly ("accepted" | "duplicate" | "rejected")[],
  assignment: CatalogueAssignment | null,
): IngestMetrics {
  const hasCatalogue = catalogueForAssignment(assignment) !== null;
  let unpriced = 0;
  let unknown = 0;

  events.forEach((event, index) => {
    const outcome = outcomes[index];
    if (outcome !== "accepted" && outcome !== "duplicate") {
      return;
    }
    if (UNMODELED_EVENT_TYPES.has(event.event_type)) {
      unknown += 1;
    }
    if (hasCatalogue && event.event_type === "ordnance.fired") {
      const expenditure = deriveExpenditure(event, assignment);
      if (expenditure?.unitCostCents === null) {
        unpriced += 1;
      }
    }
  });

  return { unpriced, unknown };
}

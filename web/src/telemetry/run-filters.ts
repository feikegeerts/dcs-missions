/**
 * Pure dashboard query helpers for the Slice 15 runs views.
 * No I/O, no store access — safe to unit test offline.
 */

export type ClassificationFilter = "all" | "test" | "historical";

/** Parse `?classification=`; anything unknown falls back to "all". */
export function parseClassificationFilter(
  value: string | null | undefined,
): ClassificationFilter {
  return value === "test" || value === "historical" ? value : "all";
}

/**
 * Match a stored run_classification against the filter. Null/empty stored
 * values (pre-classification rows) only match "all": they are neither
 * asserted test nor historical data.
 */
export function matchesClassification(
  stored: string | null | undefined,
  filter: ClassificationFilter,
): boolean {
  if (filter === "all") {
    return true;
  }
  return stored === filter;
}

/** Parse 1-based `?runsPage=` / `?eventsPage=`; garbage becomes page 1. */
export function parsePageNumber(value: string | null | undefined): number {
  const parsed = Number(value ?? "1");
  return Number.isInteger(parsed) && parsed >= 1 ? parsed : 1;
}

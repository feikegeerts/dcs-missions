/**
 * Dashboard date presentation.
 *
 * Timestamps remain UTC in the database and telemetry contract. The dashboard
 * deliberately presents them in the mission-control team's timezone.
 */
export const DASHBOARD_TIME_ZONE = "Europe/Amsterdam";

const dateTimeFormatter = new Intl.DateTimeFormat("en-GB", {
  timeZone: DASHBOARD_TIME_ZONE,
  year: "numeric",
  month: "short",
  day: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  timeZoneName: "short",
});

const dateFormatter = new Intl.DateTimeFormat("en-GB", {
  timeZone: DASHBOARD_TIME_ZONE,
  year: "numeric",
  month: "short",
  day: "numeric",
});

function asDate(value: string | Date): Date {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw new Error("Cannot format an invalid dashboard date");
  }
  return date;
}

export function formatDashboardDateTime(value: string | Date): string {
  return dateTimeFormatter.format(asDate(value));
}

export function formatDashboardDate(value: string | Date): string {
  return dateFormatter.format(asDate(value));
}

/**
 * Recover the timestamp from the project's generated run-key format. This is
 * only a display fallback for older rows that have no started_at value; the
 * stored timestamp remains the source of truth whenever it is available.
 */
export function runKeyTimestamp(runKey: string): Date | null {
  const match = /^run-(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z-/.exec(
    runKey,
  );
  if (!match) {
    return null;
  }

  const [, year, month, day, hour, minute, second] = match;
  const date = new Date(
    Date.UTC(
      Number(year),
      Number(month) - 1,
      Number(day),
      Number(hour),
      Number(minute),
      Number(second),
    ),
  );
  return Number.isNaN(date.getTime()) ? null : date;
}

/** Keep the opaque run key available without making it the primary label. */
export function shortRunKey(runKey: string): string {
  const separator = runKey.lastIndexOf("-");
  return separator >= 0 && separator < runKey.length - 1
    ? runKey.slice(separator + 1)
    : runKey;
}

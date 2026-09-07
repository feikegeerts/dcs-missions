import Link from "next/link";

import {
  formatDashboardDateTime,
  runKeyTimestamp,
  shortRunKey,
} from "@/telemetry/dates";

export function RunLink({
  runKey,
  startedAt,
}: {
  runKey: string;
  startedAt: string | Date | null;
}) {
  const displayDate = startedAt ?? runKeyTimestamp(runKey);
  const dateLabel = displayDate
    ? formatDashboardDateTime(displayDate)
    : "Start time unavailable";

  return (
    <Link
      className="run-link"
      href={`/runs/${encodeURIComponent(runKey)}`}
      title={`Full run key: ${runKey}`}
      aria-label={`${dateLabel}; run ${runKey}`}
    >
      <span className="run-label">{dateLabel}</span>
      <span className="run-reference">RUN {shortRunKey(runKey)}</span>
    </Link>
  );
}

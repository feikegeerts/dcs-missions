import { formatDashboardDateTime } from "@/telemetry/dates";
import type { CollectorHealthRecord } from "@/telemetry/store";

export function CollectorHealth({
  record,
  serverTime,
}: {
  record: CollectorHealthRecord | null;
  serverTime: Date;
}) {
  if (record === null) {
    return (
      <section className="hud-panel col-12" aria-labelledby="collector-health">
        <h2 id="collector-health">Collector health</h2>
        <p className="hud-empty">No collector status received yet.</p>
      </section>
    );
  }

  const summary = record.summary;
  const reportTime = new Date(summary.generated_at);
  const ageSeconds = Math.max(
    0,
    Math.floor((serverTime.getTime() - reportTime.getTime()) / 1000),
  );
  const blocks = summary.blocks ?? [];
  return (
    <section className="hud-panel col-12" aria-labelledby="collector-health">
      <h2 id="collector-health">Collector health</h2>
      <p>
        <span className={`status-${record.status}`}>{record.status}</span>
        {" · last report "}
        <strong>{formatDashboardDateTime(reportTime)}</strong>
        {` · ${formatAge(ageSeconds)} ago`}
      </p>
      <div className="mission-meta">
        <span>
          backlog: <strong>{summary.backlog?.runs ?? "—"}</strong> runs /{" "}
          <strong>{summary.backlog?.events ?? "—"}</strong> events /{" "}
          <strong>{formatBytes(summary.backlog?.bytes)}</strong>
        </span>
        <span>
          last delivery:{" "}
          <strong>{formatTimestamp(summary.last_successful_delivery)}</strong>
        </span>
        <span>
          next retry:{" "}
          <strong>{formatTimestamp(summary.next_retry_deadline)}</strong>
        </span>
      </div>
      <div className="mission-meta">
        <span>
          quarantine: <strong>{summary.quarantine_count ?? "—"}</strong>
        </span>
        <span>
          lifecycle pending: <strong>{summary.lifecycle_pending ?? "—"}</strong>
        </span>
        <span>
          source-tail uncertainty:{" "}
          <strong>{summary.source_tail_uncertain ?? "—"}</strong>
        </span>
        <span>
          disk free:{" "}
          <strong>
            {summary.disk_free_mb === null || summary.disk_free_mb === undefined
              ? "unavailable"
              : `${summary.disk_free_mb.toLocaleString("en-GB")} MB`}
          </strong>
        </span>
      </div>
      {blocks.length > 0 && (
        <div>
          <h3>Blocks</h3>
          <ul className="hud-mono">
            {blocks.slice(0, 4).map((block) => (
              <li key={`${block.run_key}:${block.sequence}`}>
                {block.run_key} · sequence {block.sequence} · {block.reason}
              </li>
            ))}
            {blocks.length > 4 && <li aria-label="More blocks">…</li>}
          </ul>
        </div>
      )}
    </section>
  );
}

function formatTimestamp(value: string | null | undefined): string {
  return value == null ? "none" : formatDashboardDateTime(value);
}

function formatBytes(value: number | undefined): string {
  return value === undefined ? "—" : `${value.toLocaleString("en-GB")} bytes`;
}

function formatAge(seconds: number): string {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86_400)}d`;
}

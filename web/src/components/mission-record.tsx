import Link from "next/link";

import {
  DASHBOARD_RUN_SCOPE_LIMIT,
  formatPartialCost,
  publicPlayerIdFor,
  type HighScoreRun,
} from "@/telemetry/dashboard";
import { formatDashboardDateTime, runKeyTimestamp } from "@/telemetry/dates";

type RecordParticipant = {
  participantId: string;
  displayName: string | null;
};

export function MissionRecord({
  record,
  participants,
}: {
  record: HighScoreRun | null;
  participants: readonly RecordParticipant[];
}) {
  const cost = record
    ? formatPartialCost(record.summary.blueTotalCents, 0)
    : null;
  const startedAt = record
    ? (record.startedAt ?? runKeyTimestamp(record.runKey))
    : null;
  return (
    <section
      className="mission-record col-12"
      aria-labelledby="mission-record-title"
    >
      <header className="mission-record-header">
        <h2 id="mission-record-title">
          <span aria-hidden="true">◇</span> Mission record
        </h2>
        <span className="mission-record-scope">Best in loaded history</span>
      </header>
      {record ? (
        <>
          <div className="mission-record-body">
            <div className="mission-record-achievement">
              <strong>{record.waveSummary.clearedWaves}</strong>
              <span>Waves cleared</span>
            </div>
            <div className="mission-record-holders">
              <h3>Record holders</h3>
              {participants.length > 0 ? (
                <ul>
                  {participants.map((participant) => (
                    <li key={participant.participantId}>
                      <Link
                        href={`/players/${encodeURIComponent(publicPlayerIdFor(participant.participantId))}`}
                      >
                        {participant.displayName?.trim() ||
                          "Unnamed participant"}
                      </Link>
                    </li>
                  ))}
                </ul>
              ) : (
                <p>No participants recorded</p>
              )}
              <p className="mission-record-meta">
                {record.humans}{" "}
                {record.humans === 1 ? "participant" : "participants"} ·
                Completed run
              </p>
            </div>
            <div className="mission-record-cost">
              <h3>Blue coalition cost</h3>
              <strong>{cost}</strong>
              <p className="mission-record-meta">
                Ordnance expended + aircraft losses
              </p>
              <span className="mission-record-meta">
                Lower cost wins tied wave counts
              </span>
            </div>
          </div>
          <div className="mission-record-footer">
            <span>
              {startedAt
                ? `Run started ${formatDashboardDateTime(startedAt)}`
                : "Run start time unavailable"}
            </span>
            <Link
              className="mission-record-link"
              href={`/runs/${encodeURIComponent(record.runKey)}`}
            >
              View record run <span aria-hidden="true">→</span>
            </Link>
          </div>
          <p className="mission-record-challenge">
            <strong>Beat this:</strong> clear{" "}
            {record.waveSummary.clearedWaves + 1}+ waves
            {record.summary.blueTotalCents > 0
              ? `, or clear ${record.waveSummary.clearedWaves} for less than ${cost}`
              : ""}
            .
          </p>
        </>
      ) : (
        <div className="mission-record-empty">
          <h3>The record is still open.</h3>
          <p>
            Complete a run with observed wave data and fully priced blue-side
            costs to set the first eligible record in loaded history.
          </p>
        </div>
      )}
      <details className="mission-record-rules">
        <summary>Ranking & eligibility</summary>
        <p>
          Most cleared waves wins, then lowest blue coalition cost. Exact ties
          keep the earliest run. Only ended, non-test runs with observed wave
          data and no unpriced blue-side costs qualify. Zero cleared waves and
          runs without recorded participants can qualify.
        </p>
        <p>
          This record is selected from this mission’s runs within the latest{" "}
          {DASHBOARD_RUN_SCOPE_LIMIT.toLocaleString("en-US")} dashboard runs,
          independently of the history filters. Older runs may fall outside this
          scope; this is not an all-time leaderboard.
        </p>
      </details>
    </section>
  );
}

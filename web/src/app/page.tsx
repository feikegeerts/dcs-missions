import Link from "next/link";

import { formatDashboardDate } from "@/telemetry/dates";
import {
  DASHBOARD_RUN_SCOPE_LIMIT,
  groupRunsByMission,
} from "@/telemetry/dashboard";
import {
  matchesClassification,
  parseClassificationFilter,
  type ClassificationFilter,
} from "@/telemetry/run-filters";
import { displayRunStatus } from "@/telemetry/run-status";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

const ALL_CLASSIFICATIONS: readonly ClassificationFilter[] = [
  "all",
  "test",
  "historical",
];

function formatFreshness(updatedAt: Date, now: Date): string {
  const seconds = Math.max(
    0,
    Math.round((now.getTime() - updatedAt.getTime()) / 1000),
  );
  if (seconds < 60) {
    return `${seconds} second${seconds === 1 ? "" : "s"} ago`;
  }
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) {
    return `${minutes} minute${minutes === 1 ? "" : "s"} ago`;
  }
  const hours = Math.floor(minutes / 60);
  if (hours < 48) {
    return `${hours} hour${hours === 1 ? "" : "s"} ago`;
  }
  const days = Math.floor(hours / 24);
  return `${days} day${days === 1 ? "" : "s"} ago`;
}

export default async function MissionsPage({
  searchParams,
}: {
  searchParams: Promise<{ classification?: string }>;
}) {
  try {
    const params = await searchParams;
    const classificationFilter = parseClassificationFilter(
      params.classification,
    );
    const store = new NeonTelemetryStore();
    const now = new Date();
    const allRuns = await store.listRuns(
      DASHBOARD_RUN_SCOPE_LIMIT,
      0,
      classificationFilter === "all" ? null : classificationFilter,
    );
    const runs = allRuns.filter((run) =>
      matchesClassification(run.runClassification, classificationFilter),
    );
    const groups = groupRunsByMission(runs);
    const latest =
      runs.length === 0
        ? null
        : runs.reduce((a, b) =>
            new Date(a.updatedAt).getTime() >= new Date(b.updatedAt).getTime()
              ? a
              : b,
          );
    const latestDisplay =
      latest === null ||
      (latest.status !== "active" &&
        latest.status !== "aborted" &&
        latest.status !== "ended")
        ? null
        : displayRunStatus(latest.status, new Date(latest.updatedAt), now);

    const classificationHref = (classification: string) =>
      classification === "all" ? "/" : `/?classification=${classification}`;

    return (
      <main>
        <h1 className="hud-title">Missions</h1>
        <p className="hud-subtitle">
          Mission types recorded on this server · {runs.length} run
          {runs.length === 1 ? "" : "s"} in scope
        </p>

        <div className="hud-grid" style={{ marginTop: "1rem" }}>
          <section className="hud-panel col-12">
            <h2>Data scope</h2>
            <div className="hud-filters">
              {ALL_CLASSIFICATIONS.map((classification) =>
                classification === classificationFilter ? (
                  <span
                    key={classification}
                    className="hud-chip hud-chip-active"
                  >
                    {classification === "all" ? "all data" : classification}
                  </span>
                ) : (
                  <Link
                    key={classification}
                    className="hud-chip"
                    href={classificationHref(classification)}
                  >
                    {classification === "all" ? "all data" : classification}
                  </Link>
                ),
              )}
            </div>
          </section>

          {latest && (
            <div className="col-12">
              <div className="current-run">
                <div>
                  <strong>{latest.missionName ?? "Unknown mission"}</strong>
                  {" · "}
                  {latest.mapName ?? "unknown map"}
                  {" · "}
                  <span className="hud-mono">
                    last telemetry{" "}
                    {formatFreshness(new Date(latest.updatedAt), now)}
                  </span>
                </div>
                <div>
                  {latestDisplay !== null && (
                    <span className={`status-${latestDisplay}`}>
                      {latestDisplay}
                      {latestDisplay === "stale" ? " ◌" : ""}
                    </span>
                  )}{" "}
                  <Link href={`/runs/${encodeURIComponent(latest.runKey)}`}>
                    {latestDisplay === "active" ? "Open run →" : "Latest run →"}
                  </Link>
                </div>
              </div>
            </div>
          )}

          {groups.length === 0 ? (
            <section className="hud-panel col-12">
              <div className="hud-empty">NO RUNS IN THIS SCOPE</div>
            </section>
          ) : (
            groups.map(({ entry, runs: groupRuns, latestUpdatedAt }) => {
              const maps = [
                ...new Set(
                  groupRuns
                    .map((run) => run.mapName)
                    .filter((map): map is string => map !== null),
                ),
              ];
              const latestRun = groupRuns.reduce((a, b) =>
                new Date(a.updatedAt).getTime() >=
                new Date(b.updatedAt).getTime()
                  ? a
                  : b,
              );
              return (
                <section key={entry.key} className="hud-panel col-6">
                  <div className="mission-card">
                    <h3>
                      <Link href={`/missions/${encodeURIComponent(entry.key)}`}>
                        {entry.title}
                      </Link>
                    </h3>
                    <p>{entry.description}</p>
                    <div className="mission-meta">
                      <span>
                        <strong>{groupRuns.length}</strong> run
                        {groupRuns.length === 1 ? "" : "s"}
                      </span>
                      {maps.length > 0 && (
                        <span>
                          maps: <strong>{maps.join(", ")}</strong>
                        </span>
                      )}
                      {latestUpdatedAt !== null && (
                        <span>
                          latest:{" "}
                          <strong>
                            {formatDashboardDate(latestUpdatedAt)}
                          </strong>
                        </span>
                      )}
                    </div>
                    <div className="mission-meta">
                      <Link href={`/missions/${encodeURIComponent(entry.key)}`}>
                        View runs →
                      </Link>
                      <Link
                        href={`/runs/${encodeURIComponent(latestRun.runKey)}`}
                      >
                        Latest run →
                      </Link>
                    </div>
                  </div>
                </section>
              );
            })
          )}
        </div>
      </main>
    );
  } catch {
    return (
      <main>
        <h1 className="hud-title">Missions</h1>
        <div className="hud-empty">TELEMETRY DATABASE UNAVAILABLE</div>
      </main>
    );
  }
}

import Link from "next/link";

import { AutoRefresh } from "@/components/auto-refresh";
import { formatDashboardDateTime } from "@/telemetry/dates";
import { latestHumanLabel, publicPlayerIdFor } from "@/telemetry/dashboard";
import {
  matchesClassification,
  parseClassificationFilter,
  type ClassificationFilter,
} from "@/telemetry/run-filters";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

const ALL_CLASSIFICATIONS: readonly ClassificationFilter[] = [
  "all",
  "test",
  "historical",
];

export default async function PlayersPage({
  searchParams,
}: {
  searchParams: Promise<{ classification?: string; q?: string }>;
}) {
  const renderToken = Date.now();
  try {
    const params = await searchParams;
    const classificationFilter = parseClassificationFilter(
      params.classification,
    );
    const query = (params.q ?? "").trim().toLowerCase();
    const store = new NeonTelemetryStore();
    const runs = (
      await store.listCareerRuns(
        classificationFilter === "all" ? null : classificationFilter,
      )
    ).filter((run) =>
      matchesClassification(run.runClassification, classificationFilter),
    );

    // Directory scope covers every run in the selected classification. At
    // single-server volumes this fan-out is one small indexed query per run;
    // revisit with a summary table if participant volume ever grows.
    const participantsByRun = await Promise.all(
      runs.map(async (run) => ({
        run,
        participants: await store.listRunParticipants(
          run.producerId,
          run.runKey,
        ),
      })),
    );

    const directory = new Map<
      string,
      {
        participantId: string;
        runKeys: Set<string>;
        lastSeen: string;
        rows: Array<{
          participantId: string;
          displayName: string | null;
          latestEventSequence?: number;
        }>;
      }
    >();
    for (const { run, participants } of participantsByRun) {
      for (const participant of participants) {
        let entry = directory.get(participant.participantId);
        if (!entry) {
          entry = {
            participantId: participant.participantId,
            runKeys: new Set<string>(),
            lastSeen: new Date(run.updatedAt).toISOString(),
            rows: [],
          };
          directory.set(participant.participantId, entry);
        }
        entry.runKeys.add(run.runKey);
        entry.rows.push(participant);
        const seen = new Date(run.updatedAt).toISOString();
        if (seen > entry.lastSeen) {
          entry.lastSeen = seen;
        }
      }
    }

    const players = [...directory.values()]
      .map((entry) => ({
        participantId: entry.participantId,
        publicPlayerId: publicPlayerIdFor(entry.participantId),
        displayName:
          latestHumanLabel(entry.rows, entry.participantId) ??
          entry.participantId,
        runs: entry.runKeys.size,
        lastSeen: entry.lastSeen,
      }))
      .filter(
        (player) =>
          query === "" || player.displayName.toLowerCase().includes(query),
      )
      .sort((left, right) => right.lastSeen.localeCompare(left.lastSeen));

    const classificationHref = (classification: string) => {
      const search = new URLSearchParams();
      if (classification !== "all") {
        search.set("classification", classification);
      }
      if (query !== "") {
        search.set("q", query);
      }
      const queryString = search.toString();
      return queryString === "" ? "/players" : `/players?${queryString}`;
    };

    return (
      <main>
        <AutoRefresh displayStatus={null} renderToken={renderToken} />
        <p className="hud-crumbs">
          <span>Players</span>
        </p>
        <h1 className="hud-title">Players</h1>
        <p className="hud-subtitle">
          {players.length} pilot{players.length === 1 ? "" : "s"} recorded ·
          human identities only — AI combatants appear on run scoreboards, not
          here
        </p>

        <div className="hud-grid" style={{ marginTop: "1rem" }}>
          <section className="hud-panel col-12">
            <h2>Scope</h2>
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
              <form
                method="get"
                action="/players"
                style={{ display: "inline" }}
              >
                {classificationFilter !== "all" && (
                  <input
                    type="hidden"
                    name="classification"
                    value={classificationFilter}
                  />
                )}
                <input
                  type="search"
                  name="q"
                  defaultValue={params.q ?? ""}
                  placeholder="Search pilots…"
                  aria-label="Search pilots"
                />
              </form>
            </div>
          </section>

          <section className="hud-panel col-12">
            <h2>Personnel</h2>
            {players.length === 0 ? (
              <div className="hud-empty">NO PILOTS MATCH THIS SCOPE</div>
            ) : (
              <div className="table-scroll">
                <table className="hud-table">
                  <thead>
                    <tr>
                      <th>Pilot</th>
                      <th>Runs</th>
                      <th>Last seen</th>
                    </tr>
                  </thead>
                  <tbody>
                    {players.map((player) => (
                      <tr key={player.participantId}>
                        <td>
                          <Link href={`/players/${player.publicPlayerId}`}>
                            {player.displayName}
                          </Link>
                        </td>
                        <td className="stat-number">{player.runs}</td>
                        <td>{formatDashboardDateTime(player.lastSeen)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
        </div>
      </main>
    );
  } catch (error) {
    throw error;
  }
}

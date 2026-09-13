import Link from "next/link";

import { AutoRefresh } from "@/components/auto-refresh";
import { RunLink } from "@/components/run-link";
import {
  DASHBOARD_RUN_SCOPE_LIMIT,
  DOSSIER_RUNS_PER_PAGE,
  formatPartialCost,
  missionCatalogEntry,
  selectHighScore,
  summarizeRunCombat,
  summarizeRunWaves,
} from "@/telemetry/dashboard";
import { parsePageNumber } from "@/telemetry/run-filters";
import {
  displayRunStatus,
  type DisplayRunStatus,
} from "@/telemetry/run-status";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

const ALL_STATUSES = ["all", "active", "stale", "ended"] as const;

type StatusFilter = (typeof ALL_STATUSES)[number];

export default async function MissionDossierPage({
  params,
  searchParams,
}: {
  params: Promise<{ missionName: string }>;
  searchParams: Promise<{
    status?: string;
    runsPage?: string;
  }>;
}) {
  try {
    const { missionName: encodedMission } = await params;
    const query = await searchParams;
    const missionKey = decodeURIComponent(encodedMission);
    const isDuelDynamic = missionKey === "duel-dynamic";
    const entry = missionCatalogEntry(
      missionKey === "unknown" ? null : missionKey,
    );
    const statusFilter: StatusFilter =
      query.status === "active" ||
      query.status === "stale" ||
      query.status === "ended"
        ? query.status
        : "all";
    const runsPage = parsePageNumber(query.runsPage);
    const runsOffset = (runsPage - 1) * DOSSIER_RUNS_PER_PAGE;

    const store = new NeonTelemetryStore();
    const now = new Date();
    const scoped = (
      await store.listRuns(DASHBOARD_RUN_SCOPE_LIMIT, 0, null)
    ).filter((run) =>
      missionKey === "unknown"
        ? run.missionName === null || run.missionName === ""
        : run.missionName === missionKey,
    );
    const withDisplay = scoped.map((run) => ({
      run,
      display:
        run.status === "active" ||
        run.status === "aborted" ||
        run.status === "ended"
          ? displayRunStatus(run.status, new Date(run.updatedAt), now)
          : ("active" as DisplayRunStatus),
    }));
    const latestDisplay = withDisplay[0]?.display ?? null;
    const matching = withDisplay.filter(
      ({ display }) => statusFilter === "all" || display === statusFilter,
    );

    // The high score is independent of the status filter: a stale or active
    // run should not hide the best completed historical run. Facts for the
    // displayed rows are loaded as before; ended non-test runs are added for
    // high-score evaluation when a status filter hides them.
    const highScoreCandidates = isDuelDynamic
      ? scoped.filter(
          (run) => run.status === "ended" && run.runClassification !== "test",
        )
      : [];
    const runsForFacts = [
      ...new Map(
        [...matching.map(({ run }) => run), ...highScoreCandidates].map(
          (run) => [run.runKey, run],
        ),
      ).values(),
    ];
    const facts = await Promise.all(
      runsForFacts.map(async (run) => {
        const [expenditures, losses, kills, participants, events] =
          await Promise.all([
            store.listExpenditures(run.producerId, run.runKey),
            store.listAssetLosses(run.producerId, run.runKey),
            store.listKillAttributions(run.producerId, run.runKey),
            store.listRunParticipants(run.producerId, run.runKey),
            isDuelDynamic &&
            run.status === "ended" &&
            run.runClassification !== "test"
              ? store.listRunEvents(run.producerId, run.runKey)
              : Promise.resolve([]),
          ]);
        return {
          run,
          runKey: run.runKey,
          summary: summarizeRunCombat({
            expenditures: expenditures.map((item) => ({
              participantId: item.participantId,
              participantDisplayName: item.participantDisplayName,
              assetKey: item.assetKey,
              aircraftDcsType: item.aircraftDcsType,
              coalition: item.coalition,
              unitCostCents: item.unitCostCents,
            })),
            losses: losses.map((loss) => ({
              assetKey: loss.assetKey,
              aircraftDcsType: loss.aircraftDcsType,
              coalition: loss.coalition,
              unitCostCents: loss.unitCostCents,
            })),
            kills: kills.map((kill) => ({
              targetAssetKey: kill.targetAssetKey,
              targetCoalition: kill.targetCoalition,
              targetDcsName: kill.targetDcsName,
              targetDcsType: kill.targetDcsType,
              killerAssetKey: kill.killerAssetKey,
              killerCoalition: kill.killerCoalition,
              killerDcsName: kill.killerDcsName,
              killerDcsType: kill.killerDcsType,
            })),
          }),
          humans: participants.length,
          waveSummary: summarizeRunWaves(events),
        };
      }),
    );
    const factsByRun = new Map(facts.map((item) => [item.runKey, item]));
    const highScore = isDuelDynamic
      ? selectHighScore(
          facts.map((item) => ({
            ...item.run,
            startedAt: item.run.startedAt,
            humans: item.humans,
            summary: item.summary,
            waveSummary: item.waveSummary,
          })),
        )
      : null;

    const pageWindow = matching.slice(
      runsOffset,
      runsOffset + DOSSIER_RUNS_PER_PAGE + 1,
    );
    const hasNextPage = pageWindow.length > DOSSIER_RUNS_PER_PAGE;
    const pageRuns = hasNextPage
      ? pageWindow.slice(0, DOSSIER_RUNS_PER_PAGE)
      : pageWindow;

    const buildHref = (overrides: { status?: string; runsPage?: number }) => {
      const search = new URLSearchParams();
      const status = overrides.status ?? statusFilter;
      const page = overrides.runsPage ?? 1;
      if (status !== "all") {
        search.set("status", status);
      }
      if (page > 1) {
        search.set("runsPage", String(page));
      }
      const queryString = search.toString();
      return queryString === ""
        ? `/missions/${encodeURIComponent(missionKey)}`
        : `/missions/${encodeURIComponent(missionKey)}?${queryString}`;
    };

    return (
      <main>
        <AutoRefresh
          displayStatus={latestDisplay}
          renderToken={now.getTime()}
        />
        <p className="hud-crumbs">
          <Link href="/">Missions</Link>
          <span className="sep">/</span>
          <span>{entry.title}</span>
        </p>
        <h1 className="hud-title">{entry.title}</h1>
        <p className="hud-subtitle">{entry.description}</p>

        <div className="hud-grid" style={{ marginTop: "1rem" }}>
          {isDuelDynamic && (
            <section className="hud-panel col-12">
              <h2>HIGH SCORE</h2>
              {highScore === null ? (
                <div className="hud-empty">
                  NO ELIGIBLE HIGH SCORE — NEEDS A COMPLETED RUN WITH OBSERVED
                  CLEARED WAVES AND FULL BLUE-SIDE PRICING
                </div>
              ) : (
                <>
                  <dl className="score-figures">
                    <div className="figure figure-primary">
                      <dt>Waves cleared</dt>
                      <dd>{highScore.waveSummary.clearedWaves}</dd>
                    </div>
                    <div className="figure figure-cost">
                      <dt>Blue cost</dt>
                      <dd>
                        {formatPartialCost(highScore.summary.blueTotalCents, 0)}
                      </dd>
                    </div>
                    <div className="figure">
                      <dt>Players</dt>
                      <dd>{highScore.humans}</dd>
                    </div>
                    <div className="figure">
                      <dt>Run</dt>
                      <dd>
                        <RunLink
                          runKey={highScore.runKey}
                          startedAt={highScore.startedAt}
                        />
                      </dd>
                    </div>
                  </dl>
                  <p className="score-note">
                    Ranked by most cleared waves, then lowest blue coalition
                    cost. Exact ties keep the earliest run.
                  </p>
                </>
              )}
            </section>
          )}

          <section className="hud-panel col-12">
            <h2>Filters</h2>
            <div className="hud-filters">
              {ALL_STATUSES.map((status) =>
                status === statusFilter ? (
                  <span key={status} className="hud-chip hud-chip-active">
                    {status}
                  </span>
                ) : (
                  <Link
                    key={status}
                    className="hud-chip"
                    href={buildHref({ status })}
                  >
                    {status}
                  </Link>
                ),
              )}
            </div>
          </section>

          <section className="hud-panel col-12">
            <h2>Run history</h2>
            <div className="hud-pager" style={{ marginBottom: "0.6rem" }}>
              <span>
                Page {runsPage} · {pageRuns.length} of {matching.length} in
                scope
              </span>
              {runsPage > 1 && (
                <Link href={buildHref({ runsPage: runsPage - 1 })}>← Prev</Link>
              )}
              {hasNextPage && (
                <Link href={buildHref({ runsPage: runsPage + 1 })}>Next →</Link>
              )}
            </div>
            {matching.length === 0 ? (
              <div className="hud-empty">NO RUNS MATCH THESE FILTERS</div>
            ) : (
              <div className="table-scroll">
                <table className="hud-table">
                  <thead>
                    <tr>
                      <th>Run</th>
                      <th>Map</th>
                      <th>Status</th>
                      <th>Humans</th>
                      <th>Blue : Red</th>
                      <th>Blue cost</th>
                    </tr>
                  </thead>
                  <tbody>
                    {pageRuns.map(({ run, display }) => {
                      const item = factsByRun.get(run.runKey);
                      const summary = item?.summary;
                      return (
                        <tr key={`${run.producerId}:${run.runKey}`}>
                          <td>
                            <RunLink
                              runKey={run.runKey}
                              startedAt={run.startedAt}
                            />
                          </td>
                          <td>{run.mapName ?? "unknown"}</td>
                          <td>
                            <span className={`status-${display}`}>
                              {display}
                              {display === "stale" ? " ◌" : ""}
                            </span>
                          </td>
                          <td className="stat-number">{item?.humans ?? "—"}</td>
                          <td className="stat-number">
                            {summary ? (
                              <>
                                <span className="coalition-name-blue">
                                  {summary.blueKills}
                                </span>
                                {" : "}
                                <span className="coalition-name-red">
                                  {summary.redKills}
                                </span>
                              </>
                            ) : (
                              "—"
                            )}
                          </td>
                          <td className="stat-number">
                            {summary
                              ? formatPartialCost(
                                  summary.blueTotalCents,
                                  summary.blueUnpriced,
                                )
                              : "—"}
                          </td>
                        </tr>
                      );
                    })}
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

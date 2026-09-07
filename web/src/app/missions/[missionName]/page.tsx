import Link from "next/link";

import { RunLink } from "@/components/run-link";
import {
  DASHBOARD_RUN_SCOPE_LIMIT,
  DOSSIER_RUNS_PER_PAGE,
  formatPartialCost,
  missionCatalogEntry,
  summarizeRunCombat,
} from "@/telemetry/dashboard";
import {
  matchesClassification,
  parseClassificationFilter,
  parsePageNumber,
  type ClassificationFilter,
} from "@/telemetry/run-filters";
import {
  displayRunStatus,
  type DisplayRunStatus,
} from "@/telemetry/run-status";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

const ALL_STATUSES = ["all", "active", "stale", "aborted", "ended"] as const;

type StatusFilter = (typeof ALL_STATUSES)[number];

const ALL_CLASSIFICATIONS: readonly ClassificationFilter[] = [
  "all",
  "test",
  "historical",
];

export default async function MissionDossierPage({
  params,
  searchParams,
}: {
  params: Promise<{ missionName: string }>;
  searchParams: Promise<{
    status?: string;
    classification?: string;
    runsPage?: string;
  }>;
}) {
  try {
    const { missionName: encodedMission } = await params;
    const query = await searchParams;
    const missionKey = decodeURIComponent(encodedMission);
    const entry = missionCatalogEntry(
      missionKey === "unknown" ? null : missionKey,
    );
    const statusFilter: StatusFilter =
      query.status === "active" ||
      query.status === "stale" ||
      query.status === "aborted" ||
      query.status === "ended"
        ? query.status
        : "all";
    const classificationFilter = parseClassificationFilter(
      query.classification,
    );
    const runsPage = parsePageNumber(query.runsPage);
    const runsOffset = (runsPage - 1) * DOSSIER_RUNS_PER_PAGE;

    const store = new NeonTelemetryStore();
    const now = new Date();
    const scoped = (
      await store.listRuns(
        DASHBOARD_RUN_SCOPE_LIMIT,
        0,
        classificationFilter === "all" ? null : classificationFilter,
      )
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
    const matching = withDisplay.filter(
      ({ run, display }) =>
        (statusFilter === "all" || display === statusFilter) &&
        matchesClassification(run.runClassification, classificationFilter),
    );

    // Per-run combat facts fan out over this mission's runs only — totals
    // below cover the full filtered scope, never just the displayed page.
    const facts = await Promise.all(
      matching.map(async ({ run }) => {
        const [expenditures, losses, kills, participants] = await Promise.all([
          store.listExpenditures(run.producerId, run.runKey),
          store.listAssetLosses(run.producerId, run.runKey),
          store.listKillAttributions(run.producerId, run.runKey),
          store.listRunParticipants(run.producerId, run.runKey),
        ]);
        return {
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
        };
      }),
    );
    const factsByRun = new Map(facts.map((item) => [item.runKey, item]));
    const totals = facts.reduce(
      (acc, item) => ({
        blueKills: acc.blueKills + item.summary.blueKills,
        redKills: acc.redKills + item.summary.redKills,
        losses: acc.losses + item.summary.lossCount,
        ordnanceCents: acc.ordnanceCents + item.summary.ordnanceCents,
        aircraftCents: acc.aircraftCents + item.summary.aircraftCents,
        unpriced:
          acc.unpriced +
          item.summary.ordnanceUnpriced +
          item.summary.aircraftUnpriced,
      }),
      {
        blueKills: 0,
        redKills: 0,
        losses: 0,
        ordnanceCents: 0,
        aircraftCents: 0,
        unpriced: 0,
      },
    );
    const knownCents = totals.ordnanceCents + totals.aircraftCents;

    const pageWindow = matching.slice(
      runsOffset,
      runsOffset + DOSSIER_RUNS_PER_PAGE + 1,
    );
    const hasNextPage = pageWindow.length > DOSSIER_RUNS_PER_PAGE;
    const pageRuns = hasNextPage
      ? pageWindow.slice(0, DOSSIER_RUNS_PER_PAGE)
      : pageWindow;

    const buildHref = (overrides: {
      status?: string;
      classification?: string;
      runsPage?: number;
    }) => {
      const search = new URLSearchParams();
      const status = overrides.status ?? statusFilter;
      const classification = overrides.classification ?? classificationFilter;
      const page = overrides.runsPage ?? 1;
      if (status !== "all") {
        search.set("status", status);
      }
      if (classification !== "all") {
        search.set("classification", classification);
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
        <p className="hud-crumbs">
          <Link href="/">Missions</Link>
          <span className="sep">/</span>
          <span>{entry.title}</span>
        </p>
        <h1 className="hud-title">{entry.title}</h1>
        <p className="hud-subtitle">{entry.description}</p>

        <div className="hud-grid" style={{ marginTop: "1rem" }}>
          <section className="hud-panel col-4">
            <h2>Runs in scope</h2>
            <div className="hud-stat">{matching.length}</div>
            <div className="hud-stat-sub">
              {classificationFilter === "all"
                ? "all data"
                : classificationFilter}
              {statusFilter === "all" ? "" : ` · ${statusFilter}`}
            </div>
          </section>
          <section className="hud-panel col-4">
            <h2>Coalition kills</h2>
            <div className="hud-stat">
              <span className="coalition-name-blue">{totals.blueKills}</span>
              {" : "}
              <span className="coalition-name-red">{totals.redKills}</span>
            </div>
            <div className="hud-stat-sub">
              blue : red · {totals.losses} aircraft lost
            </div>
          </section>
          <section className="hud-panel col-4">
            <h2>Mission cost</h2>
            <div className="hud-stat">
              {formatPartialCost(knownCents, totals.unpriced)}
            </div>
            <div className="hud-stat-sub">
              {totals.unpriced > 0 ? (
                <span className="hud-warning">
                  known subtotal — pricing incomplete
                </span>
              ) : (
                "ordnance + aircraft replacement"
              )}
            </div>
          </section>

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
                    href={buildHref({ classification })}
                  >
                    {classification === "all" ? "all data" : classification}
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
                      <th>Cost</th>
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
                                  summary.totalCents,
                                  summary.ordnanceUnpriced +
                                    summary.aircraftUnpriced,
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
  } catch {
    return (
      <main>
        <h1 className="hud-title">Mission unavailable</h1>
        <div className="hud-empty">TELEMETRY DATABASE UNAVAILABLE</div>
      </main>
    );
  }
}

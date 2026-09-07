import Link from "next/link";

import {
  aggregateByWeapon,
  aggregateExpenditures,
} from "@/telemetry/expenditures";
import {
  displayRunStatus,
  type DisplayRunStatus,
} from "@/telemetry/run-status";
import {
  matchesClassification,
  parseClassificationFilter,
  parsePageNumber,
  type ClassificationFilter,
} from "@/telemetry/run-filters";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

function formatUsd(cents: number): string {
  return `$${(cents / 100).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

const ALL_STATUSES = ["all", "active", "stale", "aborted", "ended"] as const;

type StatusFilter = (typeof ALL_STATUSES)[number];

const ALL_CLASSIFICATIONS: readonly ClassificationFilter[] = [
  "all",
  "test",
  "historical",
];

const RUNS_PER_PAGE = 20;

export default async function HomePage({
  searchParams,
}: {
  searchParams: Promise<{
    status?: string;
    mission?: string;
    classification?: string;
    runsPage?: string;
  }>;
}) {
  try {
    const params = await searchParams;
    const statusFilter: StatusFilter =
      params.status === "active" ||
      params.status === "stale" ||
      params.status === "aborted" ||
      params.status === "ended"
        ? params.status
        : "all";
    const missionFilter = (params.mission ?? "").trim().toLowerCase();
    const classificationFilter = parseClassificationFilter(
      params.classification,
    );
    const runsPage = parsePageNumber(params.runsPage);
    const runsOffset = (runsPage - 1) * RUNS_PER_PAGE;

    const store = new NeonTelemetryStore();
    const now = new Date();
    // Staleness is display-only. Storage keeps a run `active` until an
    // explicit `mission.ended` or a replacement run marks it `aborted`.
    // Active runs with no recent heartbeat render `stale`.
    // Fleet + scope counts cover every matching run (capped at 100, the
    // pre-existing list limit); only the runs table itself is paged.
    const matching = (
      await store.listRuns(
        100,
        0,
        classificationFilter === "all" ? null : classificationFilter,
      )
    )
      .map((run) => ({
        run,
        display:
          run.status === "active" ||
          run.status === "aborted" ||
          run.status === "ended"
            ? displayRunStatus(run.status, run.updatedAt, now)
            : ("active" as DisplayRunStatus),
      }))
      .filter(
        ({ run, display }) =>
          (statusFilter === "all" || display === statusFilter) &&
          (missionFilter === "" ||
            (run.missionName ?? "").toLowerCase().includes(missionFilter)) &&
          matchesClassification(run.runClassification, classificationFilter),
      );
    const runs = matching;
    const pageWindow = matching.slice(
      runsOffset,
      runsOffset + RUNS_PER_PAGE + 1,
    );
    const hasNextRunsPage = pageWindow.length > RUNS_PER_PAGE;
    const pageRuns = hasNextRunsPage
      ? pageWindow.slice(0, RUNS_PER_PAGE)
      : pageWindow;

    // Fleet totals aggregate per-run expenditure rows already projected at
    // ingest; no new queries beyond the existing per-run reads. At current
    // run counts this is a handful of indexed queries; revisit with a
    // summary table if run volume ever makes the fan-out expensive.
    const fleetExpenditures = (
      await Promise.all(
        runs.map(({ run }) =>
          store.listExpenditures(run.producerId, run.runKey),
        ),
      )
    ).flat();
    const fleet = aggregateExpenditures(
      fleetExpenditures.map((expenditure) => ({
        sourceEventId: expenditure.sourceEventId,
        producerId: expenditure.producerId,
        runKey: expenditure.runKey,
        eventSequence: expenditure.eventSequence,
        participantId: expenditure.participantId,
        participantDisplayName: expenditure.participantDisplayName,
        participantCallsign: expenditure.participantCallsign,
        assetKey: expenditure.assetKey,
        aircraftDcsType: expenditure.aircraftDcsType,
        coalition: expenditure.coalition,
        weaponDcsType: expenditure.weaponDcsType,
        weaponDisplayName: expenditure.weaponDisplayName,
        catalogue: expenditure.catalogue,
        catalogueVersion: expenditure.catalogueVersion,
        unitCostCents: expenditure.unitCostCents,
      })),
    );
    const fleetByWeapon = aggregateByWeapon(
      fleetExpenditures.map((expenditure) => ({
        sourceEventId: expenditure.sourceEventId,
        producerId: expenditure.producerId,
        runKey: expenditure.runKey,
        eventSequence: expenditure.eventSequence,
        participantId: expenditure.participantId,
        participantDisplayName: expenditure.participantDisplayName,
        participantCallsign: expenditure.participantCallsign,
        assetKey: expenditure.assetKey,
        aircraftDcsType: expenditure.aircraftDcsType,
        coalition: expenditure.coalition,
        weaponDcsType: expenditure.weaponDcsType,
        weaponDisplayName: expenditure.weaponDisplayName,
        catalogue: expenditure.catalogue,
        catalogueVersion: expenditure.catalogueVersion,
        unitCostCents: expenditure.unitCostCents,
      })),
    );
    const fleetUpdatedAt =
      runs.length === 0
        ? null
        : new Date(
            Math.max(
              ...runs.map(({ run }) => new Date(run.updatedAt).getTime()),
            ),
          );

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
      if (missionFilter !== "") {
        search.set("mission", missionFilter);
      }
      if (classification !== "all") {
        search.set("classification", classification);
      }
      if (page > 1) {
        search.set("runsPage", String(page));
      }
      const query = search.toString();
      return query === "" ? "/" : `/?${query}`;
    };

    const filterHref = (status: string) => buildHref({ status });
    const classificationHref = (classification: string) =>
      buildHref({ classification });
    const runsHref = (page: number) => buildHref({ runsPage: page });

    return (
      <main>
        <h1 className="hud-title">Theater overview</h1>
        <p className="hud-subtitle">
          {runs.length} run{runs.length === 1 ? "" : "s"} in scope
          {fleetUpdatedAt !== null
            ? ` · updated ${fleetUpdatedAt.toISOString()}`
            : ""}
        </p>
        <div className="hud-grid" style={{ marginTop: "1rem" }}>
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
                    href={filterHref(status)}
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
                    href={classificationHref(classification)}
                  >
                    {classification === "all" ? "all data" : classification}
                  </Link>
                ),
              )}
              {missionFilter !== "" && (
                <span className="hud-stat-sub">
                  mission ∋ “{missionFilter}” (
                  <Link href={filterHref(statusFilter)}>clear</Link>)
                </span>
              )}
            </div>
          </section>
          <section className="hud-panel col-4">
            <h2>Fleet shots</h2>
            <div className="hud-stat">{fleet.expenditureCount}</div>
            <div className="hud-stat-sub">
              {fleet.partial ? (
                <span className="hud-warning">
                  {fleet.unpricedCount} unpriced — total partial
                </span>
              ) : (
                "all priced"
              )}
            </div>
          </section>
          <section className="hud-panel col-4">
            <h2>Known subtotal</h2>
            <div className="hud-stat">
              {formatUsd(fleet.knownSubtotalCents)}
            </div>
            <div className="hud-stat-sub">exact cents, no rounding</div>
          </section>
          <section className="hud-panel col-4">
            <h2>Coverage</h2>
            <div className="hud-stat">{fleetByWeapon.weapons.length}</div>
            <div className="hud-stat-sub">weapon types tracked</div>
          </section>
          {fleetByWeapon.weapons.length > 0 && (
            <section className="hud-panel col-4">
              <h2>Ordnance by type // fleet</h2>
              <table className="hud-table">
                <thead>
                  <tr>
                    <th>Weapon</th>
                    <th>Shots</th>
                    <th>Value</th>
                  </tr>
                </thead>
                <tbody>
                  {fleetByWeapon.weapons.map((weapon) => (
                    <tr key={weapon.weaponDcsType ?? "unknown"}>
                      <td className="hud-mono">
                        {weapon.weaponDisplayName ??
                          weapon.weaponDcsType ??
                          "unknown"}
                      </td>
                      <td className="hud-mono">{weapon.expenditureCount}</td>
                      <td className="hud-mono">
                        {weapon.unpricedCount === 0
                          ? formatUsd(weapon.knownSubtotalCents)
                          : `${formatUsd(weapon.knownSubtotalCents)} + ${weapon.unpricedCount} unpriced`}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </section>
          )}
          <section className="hud-panel col-8">
            <h2>Runs</h2>
            <div className="hud-pager" style={{ marginBottom: "0.6rem" }}>
              <span>
                Page {runsPage} · {pageRuns.length} of {runs.length} in scope
              </span>
              {runsPage > 1 && (
                <Link href={runsHref(runsPage - 1)}>← Prev</Link>
              )}
              {hasNextRunsPage && (
                <Link href={runsHref(runsPage + 1)}>Next →</Link>
              )}
            </div>
            {runs.length === 0 ? (
              <div className="hud-empty">NO RUNS MATCH THESE FILTERS</div>
            ) : (
              <table className="hud-table">
                <thead>
                  <tr>
                    <th>Run</th>
                    <th>Mission</th>
                    <th>Status</th>
                    <th>Events</th>
                    <th>Export</th>
                  </tr>
                </thead>
                <tbody>
                  {pageRuns.map(({ run, display }) => (
                    <tr key={`${run.producerId}:${run.runKey}`}>
                      <td className="hud-mono">
                        <Link href={`/runs/${encodeURIComponent(run.runKey)}`}>
                          {run.runKey}
                        </Link>
                      </td>
                      <td>{run.missionName ?? "unknown"}</td>
                      <td>
                        <span className={`status-${display}`}>
                          {display}
                          {display === "stale" ? " ◌" : ""}
                        </span>
                      </td>
                      <td className="hud-mono">
                        {run.eventCount} ev · #{run.lastSequence}
                      </td>
                      <td className="hud-mono">
                        <a
                          href={`/api/telemetry/runs/${encodeURIComponent(run.runKey)}/events?format=csv`}
                        >
                          events
                        </a>{" "}
                        <a
                          href={`/api/telemetry/runs/${encodeURIComponent(run.runKey)}/expenditures?format=csv`}
                        >
                          costs
                        </a>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </section>
        </div>
      </main>
    );
  } catch {
    return (
      <main>
        <h1 className="hud-title">Theater overview</h1>
        <div className="hud-empty">TELEMETRY DATABASE UNAVAILABLE</div>
      </main>
    );
  }
}

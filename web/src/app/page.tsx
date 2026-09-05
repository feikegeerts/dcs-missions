import Link from "next/link";

import {
  aggregateByWeapon,
  aggregateExpenditures,
} from "@/telemetry/expenditures";
import {
  displayRunStatus,
  type DisplayRunStatus,
} from "@/telemetry/run-status";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

function formatUsd(cents: number): string {
  return `$${(cents / 100).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

const ALL_STATUSES = ["all", "active", "stale", "ended"] as const;

type StatusFilter = (typeof ALL_STATUSES)[number];

export default async function HomePage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; mission?: string }>;
}) {
  try {
    const params = await searchParams;
    const statusFilter: StatusFilter =
      params.status === "active" ||
      params.status === "stale" ||
      params.status === "ended"
        ? params.status
        : "all";
    const missionFilter = (params.mission ?? "").trim().toLowerCase();

    const store = new NeonTelemetryStore();
    const now = new Date();
    // Liveness is display-only: storage keeps `active` until an explicit
    // `mission.ended`, and authoritative stale/aborted classification is
    // parked Slice 16 work. Runs with no recent heartbeat render `stale`.
    const runs = (await store.listRuns(100))
      .map((run) => ({
        run,
        display:
          run.status === "active" || run.status === "ended"
            ? displayRunStatus(run.status, run.updatedAt, now)
            : ("active" as DisplayRunStatus),
      }))
      .filter(
        ({ run, display }) =>
          (statusFilter === "all" || display === statusFilter) &&
          (missionFilter === "" ||
            (run.missionName ?? "").toLowerCase().includes(missionFilter)),
      );

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

    const filterHref = (status: string) => {
      const search = new URLSearchParams();
      if (status !== "all") {
        search.set("status", status);
      }
      if (missionFilter !== "") {
        search.set("mission", missionFilter);
      }
      const query = search.toString();
      return query === "" ? "/" : `/?${query}`;
    };

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
                  {runs.map(({ run, display }) => (
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

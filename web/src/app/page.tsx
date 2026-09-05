import Link from "next/link";

import { aggregateExpenditures } from "@/telemetry/expenditures";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

function formatUsd(cents: number): string {
  return `$${(cents / 100).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

const ALL_STATUSES = ["all", "active", "ended"] as const;

export default async function HomePage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; mission?: string }>;
}) {
  try {
    const params = await searchParams;
    const statusFilter =
      params.status === "active" || params.status === "ended"
        ? params.status
        : "all";
    const missionFilter = (params.mission ?? "").trim().toLowerCase();

    const store = new NeonTelemetryStore();
    const runs = (await store.listRuns(100)).filter(
      (run) =>
        (statusFilter === "all" || run.status === statusFilter) &&
        (missionFilter === "" ||
          (run.missionName ?? "").toLowerCase().includes(missionFilter)),
    );

    // Fleet totals aggregate per-run expenditure rows already projected at
    // ingest; no new queries beyond the existing per-run reads. At current
    // run counts this is a handful of indexed queries; revisit with a
    // summary table if run volume ever makes the fan-out expensive.
    const fleetExpenditures = (
      await Promise.all(
        runs.map((run) => store.listExpenditures(run.producerId, run.runKey)),
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
        <h1>DCS telemetry runs</h1>
        <p>
          Status:{" "}
          {ALL_STATUSES.map((status, index) => (
            <span key={status}>
              {index > 0 ? " | " : ""}
              {status === statusFilter ? (
                <strong>{status}</strong>
              ) : (
                <Link href={filterHref(status)}>{status}</Link>
              )}
            </span>
          ))}
          {missionFilter !== "" && (
            <>
              {" "}
              | mission contains “{missionFilter}” (
              <Link href={filterHref(statusFilter)}>clear</Link>)
            </>
          )}
        </p>
        <h2>Fleet ordnance expenditure</h2>
        <p>
          Shots: {fleet.expenditureCount}; known subtotal:{" "}
          {formatUsd(fleet.knownSubtotalCents)}
          {fleet.partial
            ? `; ${fleet.unpricedCount} unpriced — total partial`
            : ""}
        </p>
        {runs.length === 0 ? (
          <p>No runs match these filters.</p>
        ) : (
          <ul>
            {runs.map((run) => (
              <li key={`${run.producerId}:${run.runKey}`}>
                <Link href={`/runs/${encodeURIComponent(run.runKey)}`}>
                  {run.runKey}
                </Link>{" "}
                — {run.missionName ?? "unknown mission"}, {run.status},{" "}
                {run.eventCount} events, last sequence {run.lastSequence} (
                <a
                  href={`/api/telemetry/runs/${encodeURIComponent(run.runKey)}/events?format=csv`}
                >
                  events CSV
                </a>{" "}
                |{" "}
                <a
                  href={`/api/telemetry/runs/${encodeURIComponent(run.runKey)}/expenditures?format=csv`}
                >
                  expenditures CSV
                </a>
                )
              </li>
            ))}
          </ul>
        )}
      </main>
    );
  } catch {
    return (
      <main>
        <h1>DCS telemetry runs</h1>
        <p>The telemetry database is currently unavailable.</p>
      </main>
    );
  }
}

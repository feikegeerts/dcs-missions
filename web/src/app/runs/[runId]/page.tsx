import Link from "next/link";

import {
  aggregateExpenditures,
  type ParticipantLabel,
} from "@/telemetry/expenditures";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

function formatUsd(cents: number): string {
  return `$${(cents / 100).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

export default async function RunPage({
  params,
}: {
  params: Promise<{ runId: string }>;
}) {
  try {
    const { runId } = await params;
    const store = new NeonTelemetryStore();
    const run = await store.getRunByRunKey(runId);
    if (!run) {
      return (
        <main>
          <p>
            <Link href="/">Back to runs</Link>
          </p>
          <h1>Run not found</h1>
        </main>
      );
    }
    const events = await store.listEvents(run.producerId, run.runKey, 100, 0);
    const expenditures = await store.listExpenditures(
      run.producerId,
      run.runKey,
    );
    const participants = await store.listRunParticipants(
      run.producerId,
      run.runKey,
    );
    const labels = new Map<string, ParticipantLabel>(
      participants.map((participant) => [
        participant.participantId,
        {
          participantId: participant.participantId,
          displayName: participant.displayName,
          callsign: participant.callsign,
        },
      ]),
    );
    const drilldown = aggregateExpenditures(
      expenditures.map((expenditure) => ({
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
      labels,
    );
    return (
      <main>
        <p>
          <Link href="/">Back to runs</Link>
        </p>
        <h1>{run.runKey}</h1>
        <p>
          Mission: {run.missionName ?? "unknown"}; status: {run.status}; events:{" "}
          {run.eventCount}; last sequence: {run.lastSequence}
        </p>
        <h2>Ordnance expenditure</h2>
        {run.valuationCatalogue == null ? (
          <p>
            This run predates catalogue assignment and is unpriced. Only runs
            assigned a valuation catalogue at creation project expenditures.
          </p>
        ) : (
          <>
            <p>
              Catalogue: {run.valuationCatalogue} v
              {run.valuationCatalogueVersion}; shots:{" "}
              {drilldown.expenditureCount}; known subtotal:{" "}
              {formatUsd(drilldown.knownSubtotalCents)}
              {drilldown.partial
                ? `; ${drilldown.unpricedCount} unpriced — total partial`
                : ""}
            </p>
            <ol>
              {drilldown.groups.map((group) => (
                <li
                  key={`${group.participantId ?? "unknown"}|${group.assetKey ?? "none"}|${group.weaponDcsType ?? "none"}`}
                >
                  {group.participantDisplayName ?? "Unknown shooter"}
                  {group.assetKey ? ` (${group.assetKey})` : ""} fired{" "}
                  {group.expenditureCount}×{" "}
                  {group.weaponDisplayName ?? group.weaponDcsType ?? "unknown"}:{" "}
                  {group.unpricedCount === 0
                    ? formatUsd(group.knownSubtotalCents)
                    : `${formatUsd(group.knownSubtotalCents)} known + ${group.unpricedCount} unpriced`}
                </li>
              ))}
            </ol>
          </>
        )}
        <h2>Events</h2>
        <ol>
          {events.map((event) => (
            <li key={event.eventId}>
              {event.eventSequence}: {event.eventType}; weapon:{" "}
              {event.weaponDcsType ?? "none"}; sim time: {event.simTime}
            </li>
          ))}
        </ol>
      </main>
    );
  } catch {
    return (
      <main>
        <h1>Run unavailable</h1>
        <p>The telemetry database is currently unavailable.</p>
      </main>
    );
  }
}

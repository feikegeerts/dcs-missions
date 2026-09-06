import Link from "next/link";

import {
  aggregateByWeapon,
  aggregateExpenditures,
  type ParticipantLabel,
} from "@/telemetry/expenditures";
import { aggregateAssetLosts } from "@/telemetry/losses";
import { deriveSorties, eventRowToSortieInput } from "@/telemetry/sorties";
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
  searchParams,
}: {
  params: Promise<{ runId: string }>;
  searchParams: Promise<{ eventsPage?: string }>;
}) {
  try {
    const { runId } = await params;
    const { eventsPage } = await searchParams;
    const parsedPage = Number(eventsPage ?? "1");
    const currentPage =
      Number.isInteger(parsedPage) && parsedPage >= 1 ? parsedPage : 1;
    const EVENTS_PER_PAGE = 50;
    const eventsOffset = (currentPage - 1) * EVENTS_PER_PAGE;
    const store = new NeonTelemetryStore();
    const run = await store.getRunByRunKey(runId);
    if (!run) {
      return (
        <main>
          <p className="hud-back">
            <Link href="/">← Theater overview</Link>
          </p>
          <h1 className="hud-title">Run not found</h1>
        </main>
      );
    }
    const events = await store.listEvents(
      run.producerId,
      run.runKey,
      EVENTS_PER_PAGE + 1,
      eventsOffset,
    );
    const hasNextPage = events.length > EVENTS_PER_PAGE;
    const pageEvents = hasNextPage ? events.slice(0, EVENTS_PER_PAGE) : events;
    const expenditures = await store.listExpenditures(
      run.producerId,
      run.runKey,
    );
    const losses = await store.listAssetLosses(run.producerId, run.runKey);
    const kills = await store.listKillAttributions(run.producerId, run.runKey);
    const assists = await store.listAssistAttributions(
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
    const byWeapon = aggregateByWeapon(
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
    );
    const lossSummary = aggregateAssetLosts(
      losses.map((loss) => ({
        factId: loss.factId,
        producerId: loss.producerId,
        runKey: loss.runKey,
        assetKey: loss.assetKey,
        dcsType: loss.aircraftDcsType,
        coalition: loss.coalition,
        catalogue: loss.catalogue,
        catalogueVersion: loss.catalogueVersion,
        unitCostCents: loss.unitCostCents,
        sourceEventIds: loss.sourceEventIds,
      })),
    );
    const eventsHref = (page: number) =>
      page <= 1
        ? `/runs/${encodeURIComponent(run.runKey)}`
        : `/runs/${encodeURIComponent(run.runKey)}?eventsPage=${page}`;
    // Crew sorties derive from every participant enter/leave observation in
    // the run, not just the timeline page above: a sortie opened on another
    // page must still resolve. Bounded at 1000 events; revisit with a
    // server-side event-type query if runs ever grow past that.
    const sortieInputs = (
      await store.listEvents(run.producerId, run.runKey, 1000, 0)
    ).flatMap((event) => {
      const input = eventRowToSortieInput({
        eventSequence: event.eventSequence,
        eventType: event.eventType,
        simTime: event.simTime,
        eventJson: event.eventJson,
      });
      return input === null ? [] : [input];
    });
    const sorties = deriveSorties(sortieInputs);
    const knownKillerCount = kills.filter(
      (kill) => kill.killerAssetKey !== null,
    ).length;
    const unknownKillerCount = kills.length - knownKillerCount;
    const sortedKills = [...kills].sort(
      (a, b) => a.killingBlowSimTime - b.killingBlowSimTime,
    );
    const sortedAssists = [...assists].sort(
      (a, b) => a.representativeHitSimTime - b.representativeHitSimTime,
    );
    return (
      <main>
        <p className="hud-back">
          <Link href="/">← Theater overview</Link>
        </p>
        <h1 className="hud-title hud-mono">{run.runKey}</h1>
        <p className="hud-subtitle">
          {run.missionName ?? "unknown mission"} ·{" "}
          <span className={`status-${run.status}`}>{run.status}</span> ·{" "}
          {run.eventCount} events · last #{run.lastSequence} · updated{" "}
          {new Date(run.updatedAt).toISOString()}
        </p>
        <div className="hud-grid" style={{ marginTop: "1rem" }}>
          <section className="hud-panel col-4">
            <h2>Shots</h2>
            <div className="hud-stat">{drilldown.expenditureCount}</div>
            <div className="hud-stat-sub">
              {run.valuationCatalogue == null
                ? "unpriced run (pre-catalogue)"
                : `catalogue ${run.valuationCatalogue} v${run.valuationCatalogueVersion}`}
            </div>
          </section>
          <section className="hud-panel col-4">
            <h2>Known subtotal</h2>
            <div className="hud-stat">
              {formatUsd(drilldown.knownSubtotalCents)}
            </div>
            <div className="hud-stat-sub">
              {drilldown.partial ? (
                <span className="hud-warning">
                  {drilldown.unpricedCount} unpriced — total partial
                </span>
              ) : (
                "all priced"
              )}
            </div>
          </section>
          <section className="hud-panel col-4">
            <h2>Export</h2>
            <div className="hud-stat-sub" style={{ marginBottom: "0.4rem" }}>
              <a
                href={`/api/telemetry/runs/${encodeURIComponent(run.runKey)}/events?format=csv`}
              >
                events CSV
              </a>
            </div>
            <div className="hud-stat-sub">
              <a
                href={`/api/telemetry/runs/${encodeURIComponent(run.runKey)}/expenditures?format=csv`}
              >
                expenditures CSV
              </a>
            </div>
          </section>
          {run.valuationCatalogue == null ? (
            <section className="hud-panel col-12">
              <h2>Ordnance expenditure</h2>
              <p className="hud-subtitle">
                This run predates catalogue assignment and is unpriced. Only
                runs assigned a valuation catalogue at creation project
                expenditures.
              </p>
            </section>
          ) : (
            <>
              <section className="hud-panel col-8">
                <h2>Expenditure by shooter</h2>
                <table className="hud-table expandable">
                  <thead>
                    <tr>
                      <th>Shooter</th>
                      <th>Asset</th>
                      <th>Weapon</th>
                      <th>Shots</th>
                      <th>Value</th>
                    </tr>
                  </thead>
                  <tbody>
                    {drilldown.groups.map((group) => (
                      <tr
                        key={`${group.participantId ?? "unknown"}|${group.assetKey ?? "none"}|${group.weaponDcsType ?? "none"}`}
                      >
                        <td>
                          {group.participantDisplayName ?? "Unknown shooter"}
                        </td>
                        <td className="hud-mono">{group.assetKey ?? "—"}</td>
                        <td className="hud-mono">
                          {group.weaponDisplayName ??
                            group.weaponDcsType ??
                            "unknown"}
                        </td>
                        <td className="hud-mono">{group.expenditureCount}×</td>
                        <td className="hud-mono">
                          {group.unpricedCount === 0
                            ? formatUsd(group.knownSubtotalCents)
                            : `${formatUsd(group.knownSubtotalCents)} + ${group.unpricedCount} unpriced`}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </section>
              {byWeapon.weapons.length > 0 && (
                <section className="hud-panel col-4">
                  <h2>Ordnance by type</h2>
                  <table className="hud-table">
                    <thead>
                      <tr>
                        <th>Weapon</th>
                        <th>Shots</th>
                        <th>Value</th>
                      </tr>
                    </thead>
                    <tbody>
                      {byWeapon.weapons.map((weapon) => (
                        <tr key={weapon.weaponDcsType ?? "unknown"}>
                          <td className="hud-mono">
                            {weapon.weaponDisplayName ??
                              weapon.weaponDcsType ??
                              "unknown"}
                          </td>
                          <td className="hud-mono">
                            {weapon.expenditureCount}
                          </td>
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
            </>
          )}
          <section className="hud-panel col-12">
            <h2>Aircraft loss costs</h2>
            {run.valuationCatalogue == null ? (
              <p className="hud-subtitle">
                This run predates catalogue assignment and is unpriced. Only
                runs assigned a valuation catalogue at creation project aircraft
                losses.
              </p>
            ) : losses.length === 0 ? (
              <p className="hud-subtitle">
                No aircraft losses recorded in this run.
              </p>
            ) : (
              <>
                <p className="hud-subtitle">
                  Catalogue {run.valuationCatalogue} v
                  {run.valuationCatalogueVersion} · {lossSummary.lossCount} loss
                  {lossSummary.lossCount === 1 ? "" : "es"} · known subtotal{" "}
                  {formatUsd(lossSummary.knownSubtotalCents)} ·{" "}
                  {lossSummary.unpricedCount} unpriced
                  {lossSummary.partial ? " — total partial" : " — all priced"}
                </p>
                <table className="hud-table expandable">
                  <thead>
                    <tr>
                      <th>Asset</th>
                      <th>Aircraft</th>
                      <th>Coalition</th>
                      <th>Replacement cost</th>
                    </tr>
                  </thead>
                  <tbody>
                    {losses.map((loss) => (
                      <tr key={loss.factId}>
                        <td className="hud-mono">{loss.assetKey}</td>
                        <td className="hud-mono">
                          {loss.aircraftDcsType ?? "unknown"}
                        </td>
                        <td>{loss.coalition ?? "unknown"}</td>
                        <td className="hud-mono">
                          {loss.unitCostCents === null
                            ? "unpriced"
                            : formatUsd(loss.unitCostCents)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </>
            )}
          </section>
          <section className="hud-panel col-12">
            <h2>Kills &amp; assists</h2>
            <p className="hud-subtitle">
              {kills.length} kill{kills.length === 1 ? "" : "s"} ·{" "}
              {knownKillerCount} known attacker · {unknownKillerCount} unknown ·{" "}
              {assists.length} assist{assists.length === 1 ? "" : "s"}
            </p>
            {kills.length === 0 ? (
              <p className="hud-subtitle">No kills recorded in this run.</p>
            ) : (
              <table className="hud-table expandable">
                <thead>
                  <tr>
                    <th>Target</th>
                    <th>Killer</th>
                    <th>Weapon</th>
                    <th>Sim time</th>
                  </tr>
                </thead>
                <tbody>
                  {sortedKills.map((kill) => (
                    <tr key={kill.factId}>
                      <td className="hud-mono">
                        {kill.targetAssetKey} ({kill.targetDcsType ?? "unknown"}
                        )
                      </td>
                      <td>
                        {kill.killerAssetKey === null ? (
                          <>unknown — not reported</>
                        ) : (
                          <>
                            {kill.killerDcsName ??
                              kill.killerDcsType ??
                              "unknown"}{" "}
                            ({kill.killerCoalition ?? "unknown"})
                          </>
                        )}
                      </td>
                      <td className="hud-mono">{kill.weaponDcsType ?? "—"}</td>
                      <td className="hud-mono">{kill.killingBlowSimTime}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
            <h3>Assists</h3>
            {assists.length === 0 ? (
              <p className="hud-subtitle">No assists recorded in this run.</p>
            ) : (
              <table className="hud-table expandable">
                <thead>
                  <tr>
                    <th>Target</th>
                    <th>Assisting attacker</th>
                    <th>Sim time</th>
                  </tr>
                </thead>
                <tbody>
                  {sortedAssists.map((assist) => (
                    <tr key={assist.factId}>
                      <td className="hud-mono">
                        {assist.targetAssetKey} (
                        {assist.targetDcsType ?? "unknown"})
                      </td>
                      <td>
                        {assist.attackerDcsName ??
                          assist.attackerDcsType ??
                          "unknown"}{" "}
                        ({assist.attackerCoalition ?? "unknown"})
                      </td>
                      <td className="hud-mono">
                        {assist.representativeHitSimTime}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </section>
          <section className="hud-panel col-12">
            <h2>Crew sorties</h2>
            {sorties.length === 0 ? (
              <p className="hud-subtitle">
                No participant enter/leave events in this run yet — sorties
                appear once crew occupy slots.
              </p>
            ) : (
              <table className="hud-table expandable">
                <thead>
                  <tr>
                    <th>Slot</th>
                    <th>Participant</th>
                    <th>Entered</th>
                    <th>Left</th>
                    <th>Sim window</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  {sorties.map((sortie) => (
                    <tr
                      key={`${sortie.slot_dcs_name}|${sortie.entered_sequence}`}
                    >
                      <td className="hud-mono">{sortie.slot_dcs_name}</td>
                      <td className="hud-mono">
                        {sortie.participant_id ?? "unknown"}
                      </td>
                      <td className="hud-mono">#{sortie.entered_sequence}</td>
                      <td className="hud-mono">
                        {sortie.left_sequence === null
                          ? "—"
                          : `#${sortie.left_sequence}`}
                      </td>
                      <td className="hud-mono">
                        {sortie.sim_ended === null
                          ? `${sortie.sim_started} → …`
                          : `${sortie.sim_started} → ${sortie.sim_ended}`}
                      </td>
                      <td className="hud-mono">{sortie.status}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </section>
          <section className="hud-panel col-12">
            <h2>Event timeline</h2>
            <div className="hud-pager" style={{ marginBottom: "0.6rem" }}>
              <span>
                Page {currentPage} · {pageEvents.length} events
              </span>
              {currentPage > 1 && (
                <Link href={eventsHref(currentPage - 1)}>← Prev</Link>
              )}
              {hasNextPage && (
                <Link href={eventsHref(currentPage + 1)}>Next →</Link>
              )}
            </div>
            <table className="hud-table expandable">
              <thead>
                <tr>
                  <th>Seq</th>
                  <th>Event</th>
                  <th>Weapon</th>
                  <th>Sim time</th>
                </tr>
              </thead>
              <tbody>
                {pageEvents.map((event) => (
                  <tr key={event.eventId}>
                    <td className="hud-mono">#{event.eventSequence}</td>
                    <td className="hud-mono">{event.eventType}</td>
                    <td className="hud-mono">{event.weaponDcsType ?? "—"}</td>
                    <td className="hud-mono">{event.simTime}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>
        </div>
      </main>
    );
  } catch {
    return (
      <main>
        <h1 className="hud-title">Run unavailable</h1>
        <div className="hud-empty">TELEMETRY DATABASE UNAVAILABLE</div>
      </main>
    );
  }
}

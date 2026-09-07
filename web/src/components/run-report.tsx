import Link from "next/link";

import {
  aggregateByWeapon,
  aggregateExpenditures,
  type ParticipantLabel,
} from "@/telemetry/expenditures";
import { aggregateAssetLosts } from "@/telemetry/losses";
import { deriveSorties, eventRowToSortieInput } from "@/telemetry/sorties";
import { buildAiCallsigns } from "@/telemetry/ai-names";
import {
  buildRunScoreboard,
  extractAssetSnapshots,
  extractSortieOwners,
  formatPartialCost,
  formatWholeUsd,
  missionCatalogEntry,
  type ScoreboardRow,
} from "@/telemetry/dashboard";
import { timelinePage, type RunReportData } from "@/telemetry/run-report";

function CoalitionPanel({
  side,
  kills,
  friendlyKills,
  losses,
  assists,
  cost,
  costNote,
}: {
  side: "blue" | "red";
  kills: number;
  friendlyKills: number;
  losses: number;
  assists: number;
  cost: string;
  costNote: string;
}) {
  return (
    <section className={`hud-panel coalition-${side}`}>
      <h2 className={`coalition-name-${side}`}>
        {side === "blue" ? "Blue coalition" : "Red coalition"}
      </h2>
      <dl className="score-figures">
        <div className="figure figure-primary">
          <dt>Kills</dt>
          <dd>{kills}</dd>
        </div>
        <div className="figure">
          <dt>Losses</dt>
          <dd>{losses}</dd>
        </div>
        <div className="figure">
          <dt>Assists</dt>
          <dd>{assists}</dd>
        </div>
        <div className="figure figure-cost">
          <dt>Total cost</dt>
          <dd>{cost}</dd>
        </div>
      </dl>
      <p className="score-note">
        {friendlyKills > 0
          ? `Includes ${friendlyKills} friendly-fire kill${friendlyKills === 1 ? "" : "s"}. `
          : ""}
        {costNote}
      </p>
    </section>
  );
}

function RosterTable({ rows }: { rows: readonly ScoreboardRow[] }) {
  return (
    <div
      className="table-scroll"
      tabIndex={0}
      role="region"
      aria-label="Combatant statistics"
    >
      <table className="hud-table scoreboard-table">
        <thead>
          <tr>
            <th scope="col">Player / AI</th>
            <th scope="col">Aircraft</th>
            <th scope="col">Kills</th>
            <th scope="col">Losses</th>
            <th scope="col">Assists</th>
            <th scope="col">Shots</th>
            <th scope="col">Ordnance</th>
            <th scope="col">Total</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.key}>
              <td className="combatant-name">
                {row.kind === "human" && row.publicPlayerId !== null ? (
                  <Link href={`/players/${row.publicPlayerId}`}>
                    {row.displayName}
                  </Link>
                ) : (
                  row.displayName
                )}
                {row.kind === "ai" && (
                  <span className="badge badge-ai">AI</span>
                )}
                {row.kind === "human" && (
                  <span className="badge badge-human">Pilot</span>
                )}
                {row.kind === "unresolved" && (
                  <span className="badge badge-unresolved">Unresolved</span>
                )}
                {row.friendlyKills > 0 && (
                  <span className="hud-stat-sub">
                    {" "}
                    ({row.friendlyKills} friendly)
                  </span>
                )}
              </td>
              <td className="aircraft-type">{row.aircraft ?? "—"}</td>
              <td className="stat-number">{row.kills}</td>
              <td className="stat-number">{row.losses}</td>
              <td className="stat-number">{row.assists}</td>
              <td className="stat-number">{row.shots}</td>
              <td className="stat-number">
                {formatPartialCost(row.ordnanceCostCents, row.ordnanceUnpriced)}
              </td>
              <td className="stat-number">
                {formatPartialCost(row.totalCents, row.totalUnpriced)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function RunReport({
  data,
  page = 1,
}: {
  data: RunReportData;
  page?: number;
}) {
  const { run, runEvents, expenditures, losses, kills, assists, participants } =
    data;
  const { currentPage, hasNextPage, pageEvents } = timelinePage(
    runEvents,
    page,
  );
  const entry = missionCatalogEntry(run.missionName);
  const missionHref =
    run.missionName === null || run.missionName === ""
      ? "/missions/unknown"
      : `/missions/${encodeURIComponent(run.missionName)}`;
  const priced = run.valuationCatalogue !== null;

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
  const expenditureInputs = expenditures.map((expenditure) => ({
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
  }));
  const assets = extractAssetSnapshots(runEvents);
  const aiCallsigns = buildAiCallsigns(run.runKey, [
    ...assets.map((asset) => asset.assetKey),
    ...expenditureInputs.flatMap((expenditure) =>
      expenditure.assetKey === null ? [] : [expenditure.assetKey],
    ),
  ]);
  const drilldown = aggregateExpenditures(
    expenditureInputs,
    labels,
    aiCallsigns,
  );
  const byWeapon = aggregateByWeapon(expenditureInputs);
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

  const scoreboard = buildRunScoreboard({
    runKey: run.runKey,
    aiCallsigns,
    participants: participants.map((participant) => ({
      participantId: participant.participantId,
      displayName: participant.displayName,
      callsign: participant.callsign,
      coalition: participant.coalition,
    })),
    expenditures: expenditures.map((expenditure) => ({
      participantId: expenditure.participantId,
      participantDisplayName: expenditure.participantDisplayName,
      assetKey: expenditure.assetKey,
      aircraftDcsType: expenditure.aircraftDcsType,
      coalition: expenditure.coalition,
      unitCostCents: expenditure.unitCostCents,
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
    assists: assists.map((assist) => ({
      targetAssetKey: assist.targetAssetKey,
      attackerAssetKey: assist.attackerAssetKey,
      attackerCoalition: assist.attackerCoalition,
      attackerDcsName: assist.attackerDcsName,
      attackerDcsType: assist.attackerDcsType,
    })),
    assets,
    sorties: extractSortieOwners(runEvents),
  });

  const blueRoster = [
    ...scoreboard.humans.filter((row) => row.coalition === "blue"),
    ...scoreboard.ai.filter((row) => row.coalition === "blue"),
  ];
  const redRoster = [
    ...scoreboard.humans.filter((row) => row.coalition === "red"),
    ...scoreboard.ai.filter((row) => row.coalition === "red"),
  ];
  const otherRoster = [
    ...scoreboard.humans.filter(
      (row) => row.coalition !== "blue" && row.coalition !== "red",
    ),
    ...scoreboard.ai.filter(
      (row) => row.coalition !== "blue" && row.coalition !== "red",
    ),
    ...scoreboard.unresolved,
  ];

  const eventsHref = (page: number) =>
    page <= 1
      ? `/runs/${encodeURIComponent(run.runKey)}`
      : `/runs/${encodeURIComponent(run.runKey)}?eventsPage=${page}`;
  const sortieInputs = runEvents.flatMap((event) => {
    const input = eventRowToSortieInput({
      eventSequence: event.event_sequence,
      eventType: event.event_type,
      simTime: event.sim_time,
      eventJson: event,
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
  const costNote = priced
    ? "Ordnance expenditure + aircraft replacement, whole dollars."
    : "This run predates catalogue assignment and is unpriced.";
  const blueCost = priced
    ? formatPartialCost(
        scoreboard.blue.totalCents,
        scoreboard.blue.ordnanceUnpriced + scoreboard.blue.aircraftUnpriced,
      )
    : "unpriced";
  const redCost = priced
    ? formatPartialCost(
        scoreboard.red.totalCents,
        scoreboard.red.ordnanceUnpriced + scoreboard.red.aircraftUnpriced,
      )
    : "unpriced";

  return (
    <main>
      <p className="hud-crumbs">
        <Link href="/">Missions</Link>
        <span className="sep">/</span>
        <Link href={missionHref}>{entry.title}</Link>
        <span className="sep">/</span>
        <span>Run</span>
      </p>
      <h1 className="hud-title">{entry.title}</h1>
      <p className="hud-subtitle">
        {run.startedAt
          ? `${new Date(run.startedAt).toISOString().slice(0, 16).replace("T", " ")} UTC`
          : run.runKey}{" "}
        · {run.mapName ?? "unknown map"} ·{" "}
        <span className={`status-${run.status}`}>{run.status}</span> ·{" "}
        {run.eventCount} events · last #{run.lastSequence} · updated{" "}
        {new Date(run.updatedAt).toISOString()}
      </p>

      <div className="hud-grid" style={{ marginTop: "1rem" }}>
        <div className="col-12">
          <div className="coalition-grid">
            <CoalitionPanel
              side="blue"
              kills={scoreboard.blue.kills}
              friendlyKills={scoreboard.blue.friendlyKills}
              losses={scoreboard.blue.losses}
              assists={scoreboard.blue.assists}
              cost={blueCost}
              costNote={costNote}
            />
            <CoalitionPanel
              side="red"
              kills={scoreboard.red.kills}
              friendlyKills={scoreboard.red.friendlyKills}
              losses={scoreboard.red.losses}
              assists={scoreboard.red.assists}
              cost={redCost}
              costNote={costNote}
            />
          </div>
          {(scoreboard.unattributedKills > 0 ||
            scoreboard.unattributedLosses > 0) && (
            <p className="score-note">
              {scoreboard.unattributedKills > 0 &&
                `${scoreboard.unattributedKills} kill${scoreboard.unattributedKills === 1 ? "" : "s"} with unknown attacker. `}
              {scoreboard.unattributedLosses > 0 &&
                `${scoreboard.unattributedLosses} loss${scoreboard.unattributedLosses === 1 ? "" : "es"} outside blue/red attribution. `}
              Unknown attribution is recorded as-is — never assigned to a
              combatant.
            </p>
          )}
        </div>

        <section className="hud-panel col-12 roster roster-blue">
          <h2 className="coalition-name-blue">Blue coalition</h2>
          {blueRoster.length === 0 ? (
            <p className="hud-subtitle">No blue combatants tracked.</p>
          ) : (
            <RosterTable rows={blueRoster} />
          )}
        </section>

        <section className="hud-panel col-12 roster roster-red">
          <h2 className="coalition-name-red">Red coalition</h2>
          {redRoster.length === 0 ? (
            <p className="hud-subtitle">No red combatants tracked.</p>
          ) : (
            <RosterTable rows={redRoster} />
          )}
        </section>

        {otherRoster.length > 0 && (
          <section className="hud-panel col-12 roster">
            <h2>Other / unresolved</h2>
            <p className="hud-subtitle">
              Neutral-coalition entries and named shooters without a stable
              identity. Shown here, never merged into career profiles.
            </p>
            <RosterTable rows={otherRoster} />
          </section>
        )}

        <section className="hud-panel col-4">
          <h2>Shots</h2>
          <div className="hud-stat">{drilldown.expenditureCount}</div>
          <div className="hud-stat-sub">
            {priced
              ? `catalogue ${run.valuationCatalogue} v${run.valuationCatalogueVersion}`
              : "unpriced run (pre-catalogue)"}
          </div>
        </section>
        <section className="hud-panel col-4">
          <h2>Known subtotal</h2>
          <div className="hud-stat">
            {priced
              ? formatPartialCost(
                  drilldown.knownSubtotalCents,
                  drilldown.unpricedCount,
                )
              : "unpriced"}
          </div>
          <div className="hud-stat-sub">
            {priced ? (
              drilldown.partial ? (
                <span className="hud-warning">
                  {drilldown.unpricedCount} unpriced — total partial
                </span>
              ) : (
                "all priced"
              )
            ) : (
              "no catalogue assigned"
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

        {!priced ? (
          <section className="hud-panel col-12">
            <h2>Ordnance expenditure</h2>
            <p className="hud-subtitle">
              This run predates catalogue assignment and is unpriced. Only runs
              assigned a valuation catalogue at creation project expenditures.
            </p>
          </section>
        ) : (
          <>
            <section className="hud-panel col-8">
              <h2>Expenditure by shooter</h2>
              <div className="table-scroll">
                <table className="hud-table">
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
                        <td className="stat-number">
                          {group.expenditureCount}×
                        </td>
                        <td className="stat-number">
                          {formatPartialCost(
                            group.knownSubtotalCents,
                            group.unpricedCount,
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </section>
            {byWeapon.weapons.length > 0 && (
              <section className="hud-panel col-4">
                <h2>Ordnance by type</h2>
                <div className="table-scroll">
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
                          <td className="stat-number">
                            {weapon.expenditureCount}
                          </td>
                          <td className="stat-number">
                            {formatPartialCost(
                              weapon.knownSubtotalCents,
                              weapon.unpricedCount,
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </section>
            )}
          </>
        )}

        <section className="hud-panel col-12">
          <h2>Aircraft loss costs</h2>
          {!priced ? (
            <p className="hud-subtitle">
              This run predates catalogue assignment and is unpriced. Only runs
              assigned a valuation catalogue at creation project aircraft
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
                {formatWholeUsd(lossSummary.knownSubtotalCents)} ·{" "}
                {lossSummary.unpricedCount} unpriced
                {lossSummary.partial ? " — total partial" : " — all priced"}
              </p>
              <div className="table-scroll">
                <table className="hud-table">
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
                        <td className="stat-number">
                          {loss.unitCostCents === null
                            ? "unpriced"
                            : formatWholeUsd(loss.unitCostCents)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
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
            <div className="table-scroll">
              <table className="hud-table">
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
            </div>
          )}
          <h3>Assists</h3>
          {assists.length === 0 ? (
            <p className="hud-subtitle">No assists recorded in this run.</p>
          ) : (
            <div className="table-scroll">
              <table className="hud-table">
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
            </div>
          )}
        </section>

        <section className="hud-panel col-12">
          <h2>Crew sorties</h2>
          {sorties.length === 0 ? (
            <p className="hud-subtitle">
              No participant enter/leave events in this run yet — sorties appear
              once crew occupy slots.
            </p>
          ) : (
            <div className="table-scroll">
              <table className="hud-table">
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
                      <td>
                        {sortie.participant_id === null
                          ? "unknown"
                          : (labels.get(sortie.participant_id)?.displayName ??
                            "pilot")}
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
            </div>
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
          <div className="table-scroll">
            <table className="hud-table">
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
          </div>
        </section>
      </div>
    </main>
  );
}

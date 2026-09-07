import Link from "next/link";

import {
  aggregatePlayerCareer,
  buildRunScoreboard,
  DASHBOARD_RUN_SCOPE_LIMIT,
  extractAssetSnapshots,
  extractSortieOwners,
  formatPartialCost,
  latestHumanLabel,
  missionCatalogEntry,
  publicPlayerIdFor,
  type PlayerRunEntry,
} from "@/telemetry/dashboard";
import {
  matchesClassification,
  parseClassificationFilter,
} from "@/telemetry/run-filters";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

export default async function PlayerProfilePage({
  params,
  searchParams,
}: {
  params: Promise<{ playerId: string }>;
  searchParams: Promise<{ classification?: string }>;
}) {
  try {
    const { playerId } = await params;
    const query = await searchParams;
    const classificationFilter = parseClassificationFilter(
      query.classification,
    );
    const store = new NeonTelemetryStore();
    const runs = (
      await store.listRuns(
        DASHBOARD_RUN_SCOPE_LIMIT,
        0,
        classificationFilter === "all" ? null : classificationFilter,
      )
    ).filter((run) =>
      matchesClassification(run.runClassification, classificationFilter),
    );

    // Resolve the opaque profile id back to its UCID by scanning the same
    // participant scope as the directory. No raw UCID ever appears in markup.
    const participantsByRun = await Promise.all(
      runs.map(async (run) => ({
        run,
        participants: await store.listRunParticipants(
          run.producerId,
          run.runKey,
        ),
      })),
    );
    let participantId: string | null = null;
    const labelRows: Array<{
      participantId: string;
      displayName: string | null;
      latestEventSequence?: number;
    }> = [];
    for (const { participants } of participantsByRun) {
      for (const participant of participants) {
        labelRows.push(participant);
        if (publicPlayerIdFor(participant.participantId) === playerId) {
          participantId = participant.participantId;
        }
      }
    }

    if (participantId === null) {
      return (
        <main>
          <p className="hud-crumbs">
            <Link href="/players">Players</Link>
          </p>
          <h1 className="hud-title">Pilot not found</h1>
          <p className="hud-subtitle">
            No recorded pilot matches this profile in the selected scope.
          </p>
        </main>
      );
    }

    const resolvedId: string = participantId;
    const runsWithPilot = participantsByRun.filter(({ participants }) =>
      participants.some((row) => row.participantId === resolvedId),
    );

    // Per-run scoreboards resolve this pilot's kills, losses, assists, and
    // costs through asset ownership — never through a latest-occupant guess.
    const entries: PlayerRunEntry[] = [];
    for (const { run } of runsWithPilot) {
      const [runEvents, expenditures, losses, kills, assists, participants] =
        await Promise.all([
          store.listRunEvents(run.producerId, run.runKey),
          store.listExpenditures(run.producerId, run.runKey),
          store.listAssetLosses(run.producerId, run.runKey),
          store.listKillAttributions(run.producerId, run.runKey),
          store.listAssistAttributions(run.producerId, run.runKey),
          store.listRunParticipants(run.producerId, run.runKey),
        ]);
      const scoreboard = buildRunScoreboard({
        participants: participants.map((row) => ({
          participantId: row.participantId,
          displayName: row.displayName,
          callsign: row.callsign,
          coalition: row.coalition,
        })),
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
        assists: assists.map((assist) => ({
          targetAssetKey: assist.targetAssetKey,
          attackerAssetKey: assist.attackerAssetKey,
          attackerCoalition: assist.attackerCoalition,
          attackerDcsName: assist.attackerDcsName,
          attackerDcsType: assist.attackerDcsType,
        })),
        assets: extractAssetSnapshots(runEvents),
        sorties: extractSortieOwners(runEvents),
      });
      for (const row of scoreboard.humans) {
        if (row.participantId !== resolvedId) {
          continue;
        }
        entries.push({
          runKey: run.runKey,
          missionName: run.missionName,
          mapName: run.mapName,
          startedAt: run.startedAt
            ? new Date(run.startedAt).toISOString()
            : null,
          status: run.status,
          row,
        });
      }
    }

    const career = aggregatePlayerCareer(
      resolvedId,
      entries,
      latestHumanLabel(labelRows, resolvedId),
    );
    const kd =
      career.killLossRatio === null
        ? "—"
        : career.killLossRatio === Number.POSITIVE_INFINITY
          ? "∞"
          : career.killLossRatio.toFixed(2);

    return (
      <main>
        <p className="hud-crumbs">
          <Link href="/players">Players</Link>
          <span className="sep">/</span>
          <span>{career.displayName}</span>
        </p>
        <h1 className="hud-title">{career.displayName}</h1>
        <p className="hud-subtitle">
          {career.runs} run{career.runs === 1 ? "" : "s"} in scope
          {career.otherNames.length > 0 &&
            ` · also recorded as ${career.otherNames.join(", ")}`}
        </p>

        <div className="hud-grid" style={{ marginTop: "1rem" }}>
          <section className="hud-panel col-4">
            <h2>Combat record</h2>
            <div className="hud-stat">
              {career.kills}K · {career.losses}L · {career.assists}A
            </div>
            <div className="hud-stat-sub">
              kill/loss ratio {kd}
              {career.friendlyKills > 0 &&
                ` · includes ${career.friendlyKills} friendly-fire`}
            </div>
          </section>
          <section className="hud-panel col-4">
            <h2>Ordnance</h2>
            <div className="hud-stat">{career.shots} shots</div>
            <div className="hud-stat-sub">
              {formatPartialCost(career.ordnanceCents, 0)}
              {career.totalUnpriced > 0 ? " · career cost partial" : ""}
            </div>
          </section>
          <section className="hud-panel col-4">
            <h2>Career cost</h2>
            <div className="hud-stat">
              {formatPartialCost(career.totalCents, career.totalUnpriced)}
            </div>
            <div className="hud-stat-sub">
              {career.partial ? (
                <span className="hud-warning">
                  known subtotal — pricing incomplete
                </span>
              ) : (
                "ordnance + aircraft replacement"
              )}
            </div>
          </section>

          <section className="hud-panel col-12">
            <h2>By mission</h2>
            <div className="table-scroll">
              <table className="hud-table">
                <thead>
                  <tr>
                    <th>Mission</th>
                    <th>Runs</th>
                    <th>K</th>
                    <th>L</th>
                    <th>A</th>
                    <th>Cost</th>
                  </tr>
                </thead>
                <tbody>
                  {career.byMission.map((item) => (
                    <tr key={item.mission.key}>
                      <td>
                        <Link
                          href={`/missions/${encodeURIComponent(item.mission.key)}`}
                        >
                          {item.mission.title}
                        </Link>
                      </td>
                      <td className="stat-number">{item.runs}</td>
                      <td className="stat-number">{item.kills}</td>
                      <td className="stat-number">{item.losses}</td>
                      <td className="stat-number">{item.assists}</td>
                      <td className="stat-number">
                        {formatPartialCost(item.totalCents, item.totalUnpriced)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>

          <section className="hud-panel col-12">
            <h2>Run history</h2>
            <div className="table-scroll">
              <table className="hud-table">
                <thead>
                  <tr>
                    <th>Run</th>
                    <th>Mission</th>
                    <th>K</th>
                    <th>L</th>
                    <th>A</th>
                    <th>Cost</th>
                  </tr>
                </thead>
                <tbody>
                  {career.history.map((item) => (
                    <tr key={`${item.runKey}|${item.row.key}`}>
                      <td className="hud-mono">
                        <Link href={`/runs/${encodeURIComponent(item.runKey)}`}>
                          {item.startedAt
                            ? item.startedAt.slice(0, 16).replace("T", " ")
                            : item.runKey}
                        </Link>
                      </td>
                      <td>{missionCatalogEntry(item.missionName).title}</td>
                      <td className="stat-number">{item.row.kills}</td>
                      <td className="stat-number">{item.row.losses}</td>
                      <td className="stat-number">{item.row.assists}</td>
                      <td className="stat-number">
                        {formatPartialCost(
                          item.row.totalCents,
                          item.row.totalUnpriced,
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>
        </div>
      </main>
    );
  } catch {
    return (
      <main>
        <h1 className="hud-title">Pilot unavailable</h1>
        <div className="hud-empty">TELEMETRY DATABASE UNAVAILABLE</div>
      </main>
    );
  }
}

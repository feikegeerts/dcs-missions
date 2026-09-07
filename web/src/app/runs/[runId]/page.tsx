import Link from "next/link";

import { RunReport } from "@/components/run-report";
import { parsePageNumber } from "@/telemetry/run-filters";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

export default async function RunPage({
  params,
  searchParams,
}: {
  params: Promise<{ runId: string }>;
  searchParams: Promise<{ eventsPage?: string }>;
}) {
  const { runId } = await params;
  const { eventsPage } = await searchParams;
  const store = new NeonTelemetryStore();
  try {
    const run = await store.getRunByRunKey(runId);
    if (!run) {
      return (
        <main>
          <p>
            <Link href="/">← Missions</Link>
          </p>
          <h1>Run not found</h1>
        </main>
      );
    }
    const [runEvents, expenditures, losses, kills, assists, participants] =
      await Promise.all([
        store.listRunEvents(run.producerId, run.runKey),
        store.listExpenditures(run.producerId, run.runKey),
        store.listAssetLosses(run.producerId, run.runKey),
        store.listKillAttributions(run.producerId, run.runKey),
        store.listAssistAttributions(run.producerId, run.runKey),
        store.listRunParticipants(run.producerId, run.runKey),
      ]);
    return (
      <RunReport
        data={{
          run,
          runEvents,
          expenditures,
          losses,
          kills,
          assists,
          participants,
        }}
        page={parsePageNumber(eventsPage)}
      />
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

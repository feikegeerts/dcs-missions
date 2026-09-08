import Link from "next/link";

import { AutoRefresh } from "@/components/auto-refresh";
import { RunReport } from "@/components/run-report";
import { parsePageNumber } from "@/telemetry/run-filters";
import { displayRunStatus } from "@/telemetry/run-status";
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
  const now = new Date();
  try {
    const run = await store.getRunByRunKey(runId);
    if (!run) {
      return (
        <main>
          <AutoRefresh displayStatus={null} renderToken={now.getTime()} />
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
    const runDisplayStatus =
      run.status === "active" ||
      run.status === "aborted" ||
      run.status === "ended"
        ? displayRunStatus(run.status, new Date(run.updatedAt), now)
        : null;
    return (
      <>
        <AutoRefresh
          displayStatus={runDisplayStatus}
          renderToken={now.getTime()}
        />
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
      </>
    );
  } catch (error) {
    throw error;
  }
}

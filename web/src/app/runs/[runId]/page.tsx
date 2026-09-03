import Link from "next/link";

import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

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

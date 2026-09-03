import Link from "next/link";

import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

export default async function HomePage() {
  try {
    const runs = await new NeonTelemetryStore().listRuns(100);
    return (
      <main>
        <h1>DCS telemetry runs</h1>
        {runs.length === 0 ? (
          <p>No runs have been ingested yet.</p>
        ) : (
          <ul>
            {runs.map((run) => (
              <li key={`${run.producerId}:${run.runKey}`}>
                <Link href={`/runs/${encodeURIComponent(run.runKey)}`}>
                  {run.runKey}
                </Link>{" "}
                — {run.missionName ?? "unknown mission"}, {run.status},{" "}
                {run.eventCount} events, last sequence {run.lastSequence}
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

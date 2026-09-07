import { NextResponse } from "next/server";

import { eventsToCsv, eventsToNdjson } from "@/telemetry/export";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

function queryNumber(
  searchParams: URLSearchParams,
  name: string,
  fallback: number,
): number {
  const rawValue = searchParams.get(name);
  if (rawValue === null) {
    return fallback;
  }
  const value = Number(rawValue);
  return Number.isFinite(value) && Number.isInteger(value) ? value : fallback;
}

export async function GET(
  req: Request,
  { params }: { params: Promise<{ runId: string }> },
) {
  try {
    const { runId } = await params;
    const store = new NeonTelemetryStore();
    const run = await store.getRunByRunKey(runId);
    if (!run) {
      return NextResponse.json({ error: "run-not-found" }, { status: 404 });
    }

    const searchParams = new URL(req.url).searchParams;
    if (searchParams.get("format") === "ndjson") {
      const runEvents = await store.listRunEvents(run.producerId, run.runKey);
      if (runEvents.length > 10_000) {
        return NextResponse.json(
          { error: "run-too-large", count: runEvents.length },
          { status: 413 },
        );
      }
      return new NextResponse(eventsToNdjson(runEvents), {
        headers: {
          "content-type": "application/x-ndjson; charset=utf-8",
          "content-disposition": `attachment; filename="${run.runKey}-events.ndjson"`,
        },
      });
    }
    const requestedLimit = queryNumber(searchParams, "limit", 50);
    const requestedOffset = queryNumber(searchParams, "offset", 0);
    const limit = Math.min(Math.max(requestedLimit, 1), 100);
    const offset = Math.max(requestedOffset, 0);
    const events = await store.listEvents(
      run.producerId,
      run.runKey,
      limit,
      offset,
    );
    if (searchParams.get("format") === "csv") {
      return new NextResponse(
        eventsToCsv(
          events.map((event) => ({
            eventSequence: event.eventSequence,
            eventType: event.eventType,
            simTime: event.simTime,
            weaponDcsType: event.weaponDcsType,
            initiatorParticipantId: event.initiatorParticipantId,
            coalition: event.coalition,
          })),
        ),
        {
          headers: {
            "content-type": "text/csv; charset=utf-8",
            "content-disposition": `attachment; filename="${run.runKey}-events.csv"`,
          },
        },
      );
    }
    return NextResponse.json({
      runId,
      limit,
      offset,
      count: events.length,
      events,
    });
  } catch {
    return NextResponse.json({ error: "internal" }, { status: 500 });
  }
}

import { NextResponse } from "next/server";

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

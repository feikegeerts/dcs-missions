import { NextResponse } from "next/server";

import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

export async function GET(
  _req: Request,
  { params }: { params: Promise<{ runId: string }> },
) {
  try {
    const { runId } = await params;
    const store = new NeonTelemetryStore();
    const run = await store.getRunByRunKey(runId);
    if (!run) {
      return NextResponse.json({ error: "run-not-found" }, { status: 404 });
    }
    const losses = await store.listAssetLosses(run.producerId, run.runKey);
    return NextResponse.json({ runId, count: losses.length, losses });
  } catch {
    return NextResponse.json({ error: "internal" }, { status: 500 });
  }
}

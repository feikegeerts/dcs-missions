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
    const [kills, assists] = await Promise.all([
      store.listKillAttributions(run.producerId, run.runKey),
      store.listAssistAttributions(run.producerId, run.runKey),
    ]);
    return NextResponse.json({ runId, kills, assists });
  } catch {
    return NextResponse.json({ error: "internal" }, { status: 500 });
  }
}

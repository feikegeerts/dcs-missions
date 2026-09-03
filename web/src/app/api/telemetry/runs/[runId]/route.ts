import { NextResponse } from "next/server";

import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

export async function GET(
  _req: Request,
  { params }: { params: Promise<{ runId: string }> },
) {
  try {
    const { runId } = await params;
    const run = await new NeonTelemetryStore().getRunByRunKey(runId);
    if (!run) {
      return NextResponse.json({ error: "run-not-found" }, { status: 404 });
    }
    return NextResponse.json({ run });
  } catch {
    return NextResponse.json({ error: "internal" }, { status: 500 });
  }
}

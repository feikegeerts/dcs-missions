import { NextResponse } from "next/server";

import { getDb } from "@/db/client";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const store = new NeonTelemetryStore();
    getDb();
    return NextResponse.json({ runs: await store.listRuns(100) });
  } catch {
    return NextResponse.json({ error: "internal" }, { status: 500 });
  }
}

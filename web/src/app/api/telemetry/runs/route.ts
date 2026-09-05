import { NextResponse } from "next/server";

import { getDb } from "@/db/client";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

export async function GET(req: Request) {
  try {
    const store = new NeonTelemetryStore();
    getDb();
    const searchParams = new URL(req.url).searchParams;
    const rawLimit = Number(searchParams.get("limit") ?? "100");
    const rawOffset = Number(searchParams.get("offset") ?? "0");
    const limit =
      Number.isInteger(rawLimit) && rawLimit >= 1
        ? Math.min(rawLimit, 100)
        : 100;
    const offset =
      Number.isInteger(rawOffset) && rawOffset >= 0 ? rawOffset : 0;
    const rawClassification = searchParams.get("classification");
    const classification =
      rawClassification === "test" || rawClassification === "historical"
        ? rawClassification
        : null;
    const runs = await store.listRuns(limit, offset, classification);
    return NextResponse.json({ runs, limit, offset, count: runs.length });
  } catch {
    return NextResponse.json({ error: "internal" }, { status: 500 });
  }
}

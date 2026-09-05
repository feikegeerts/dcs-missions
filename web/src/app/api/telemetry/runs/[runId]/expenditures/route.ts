import { NextResponse } from "next/server";

import { expendituresToCsv } from "@/telemetry/export";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

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
    const expenditures = await store.listExpenditures(
      run.producerId,
      run.runKey,
    );
    const format = new URL(req.url).searchParams.get("format");
    if (format === "csv") {
      return new NextResponse(
        expendituresToCsv(
          expenditures.map((expenditure) => ({
            eventSequence: expenditure.eventSequence,
            participantDisplayName: expenditure.participantDisplayName,
            participantCallsign: expenditure.participantCallsign,
            assetKey: expenditure.assetKey,
            aircraftDcsType: expenditure.aircraftDcsType,
            coalition: expenditure.coalition,
            weaponDisplayName: expenditure.weaponDisplayName,
            weaponDcsType: expenditure.weaponDcsType,
            unitCostCents: expenditure.unitCostCents,
            catalogue: expenditure.catalogue,
            catalogueVersion: expenditure.catalogueVersion,
          })),
        ),
        {
          headers: {
            "content-type": "text/csv; charset=utf-8",
            "content-disposition": `attachment; filename="${run.runKey}-expenditures.csv"`,
          },
        },
      );
    }
    return NextResponse.json({
      runId,
      count: expenditures.length,
      expenditures,
    });
  } catch {
    return NextResponse.json({ error: "internal" }, { status: 500 });
  }
}

import { timingSafeEqual } from "node:crypto";

import { NextResponse } from "next/server";

import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

function tokenMatches(provided: string, expected: string): boolean {
  const providedBytes = Buffer.from(provided, "utf8");
  const expectedBytes = Buffer.from(expected, "utf8");
  const size = Math.max(providedBytes.length, expectedBytes.length);
  const providedPadded = Buffer.alloc(size);
  const expectedPadded = Buffer.alloc(size);
  providedBytes.copy(providedPadded);
  expectedBytes.copy(expectedPadded);

  return (
    timingSafeEqual(providedPadded, expectedPadded) &&
    providedBytes.length === expectedBytes.length
  );
}

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

export async function POST(
  req: Request,
  { params }: { params: Promise<{ runId: string }> },
) {
  try {
    const configuredToken = process.env.TELEMETRY_INGEST_TOKEN;
    if (!configuredToken) {
      return NextResponse.json(
        { error: "ingest-token-not-configured" },
        { status: 500 },
      );
    }

    const authorization = req.headers.get("authorization");
    const providedToken =
      authorization?.startsWith("Bearer ") === true
        ? authorization.slice("Bearer ".length)
        : "";
    if (
      !authorization?.startsWith("Bearer ") ||
      !tokenMatches(providedToken, configuredToken)
    ) {
      return NextResponse.json({ error: "unauthorized" }, { status: 401 });
    }

    const body = (await req.json()) as {
      reason?: unknown;
      producer_id?: unknown;
      generation?: unknown;
    };
    if (
      body.reason !== "dcs-process-not-running" &&
      body.reason !== "simulation-stop-observed"
    ) {
      return NextResponse.json({ error: "invalid-reason" }, { status: 400 });
    }

    const { runId } = await params;
    const store = new NeonTelemetryStore();
    const run =
      typeof body.producer_id === "string"
        ? await store.getRunByProducerAndRunKey(body.producer_id, runId)
        : body.producer_id === undefined
          ? await store.getRunByRunKey(runId)
          : null;
    if (!run) {
      return NextResponse.json({ error: "run-not-found" }, { status: 404 });
    }
    if (
      body.generation !== undefined &&
      (!Number.isSafeInteger(body.generation) ||
        (body.generation as number) < 1)
    ) {
      return NextResponse.json({ error: "invalid-reason" }, { status: 400 });
    }
    const aborted = await store.markRunAborted(run.producerId, run.runKey);
    console.info(
      JSON.stringify({
        action: "telemetry-run-abort",
        producer: run.producerId,
        run: run.runKey,
        ...(body.generation === undefined
          ? {}
          : { generation: body.generation }),
        reason: body.reason,
        aborted,
      }),
    );
    return NextResponse.json({ aborted }, { status: 200 });
  } catch {
    return NextResponse.json({ error: "internal" }, { status: 500 });
  }
}

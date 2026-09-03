import { timingSafeEqual } from "node:crypto";

import { NextResponse } from "next/server";

import { processIngest } from "@/telemetry/ingest";
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

export async function POST(req: Request) {
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

    const result = await processIngest(
      await req.text(),
      new NeonTelemetryStore(),
    );
    return NextResponse.json(result.body, { status: result.httpStatus });
  } catch {
    return NextResponse.json({ error: "internal" }, { status: 500 });
  }
}

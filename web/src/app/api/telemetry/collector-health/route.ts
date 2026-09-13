import { timingSafeEqual } from "node:crypto";

import { NextResponse } from "next/server";

import { NeonTelemetryStore } from "@/telemetry/store";
import type {
  CollectorHealthStatus,
  CollectorHealthSummary,
} from "@/telemetry/store";

export const dynamic = "force-dynamic";

const MAX_BODY_BYTES = 4096;

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

    const body = await req.text();
    if (Buffer.byteLength(body, "utf8") > MAX_BODY_BYTES) {
      return NextResponse.json({ error: "payload-too-large" }, { status: 400 });
    }
    let value: unknown;
    try {
      value = JSON.parse(body) as unknown;
    } catch {
      return NextResponse.json({ error: "invalid-json" }, { status: 400 });
    }
    const validated = validatePayload(value);
    if ("error" in validated) {
      return NextResponse.json({ error: validated.error }, { status: 400 });
    }

    await new NeonTelemetryStore().upsertCollectorHealth(
      validated.identity,
      validated.status,
      validated.summary,
    );
    return NextResponse.json({ status: "accepted" });
  } catch {
    return NextResponse.json({ error: "internal" }, { status: 500 });
  }
}

export async function GET() {
  try {
    const rows = await new NeonTelemetryStore().getCollectorHealth();
    const row = rows[0];
    if (row === undefined) {
      return NextResponse.json(
        { error: "no-collector-status" },
        { status: 404 },
      );
    }
    return NextResponse.json({
      identity: row.identity,
      status: row.status,
      ...row.summary,
      first_seen_at: row.firstSeenAt.toISOString(),
      updated_at: row.updatedAt.toISOString(),
      server_time: new Date().toISOString(),
    });
  } catch {
    return NextResponse.json({ error: "internal" }, { status: 500 });
  }
}

type ValidationResult =
  | {
      identity: string;
      status: CollectorHealthStatus;
      summary: CollectorHealthSummary;
    }
  | { error: string };

function validatePayload(value: unknown): ValidationResult {
  if (!isRecord(value)) return { error: "invalid-payload" };
  if (
    typeof value.identity !== "string" ||
    !/^[0-9a-fA-F]{8,64}$/.test(value.identity)
  ) {
    return { error: "invalid-identity" };
  }
  if (!isIsoTimestamp(value.generated_at)) {
    return { error: "invalid-generated-at" };
  }
  if (!isStatus(value.status)) return { error: "invalid-status" };
  if (value.backlog !== undefined && !isBacklog(value.backlog)) {
    return { error: "invalid-backlog" };
  }
  if (!isOptionalNullableTimestamp(value.last_successful_delivery)) {
    return { error: "invalid-last-successful-delivery" };
  }
  if (!isOptionalNullableTimestamp(value.next_retry_deadline)) {
    return { error: "invalid-next-retry-deadline" };
  }
  for (const field of [
    "quarantine_count",
    "lifecycle_pending",
    "source_tail_uncertain",
  ] as const) {
    if (value[field] !== undefined && !isNonnegativeInteger(value[field])) {
      return { error: `invalid-${field.replaceAll("_", "-")}` };
    }
  }
  if (
    value.disk_free_mb !== undefined &&
    value.disk_free_mb !== null &&
    !isNonnegativeInteger(value.disk_free_mb)
  ) {
    return { error: "invalid-disk-free-mb" };
  }
  if (
    value.collector_version !== undefined &&
    (typeof value.collector_version !== "string" ||
      value.collector_version.length > 32)
  ) {
    return { error: "invalid-collector-version" };
  }
  if (value.blocks !== undefined && !isBlocks(value.blocks)) {
    return { error: "invalid-blocks" };
  }

  const summary: Record<string, unknown> = { generated_at: value.generated_at };
  if (value.backlog !== undefined) {
    const backlog = value.backlog as Record<string, unknown>;
    summary.backlog = {
      runs: backlog.runs,
      events: backlog.events,
      bytes: backlog.bytes,
    };
  }
  if (value.blocks !== undefined) {
    summary.blocks = (value.blocks as Array<Record<string, unknown>>).map(
      (block) => ({
        run_key: block.run_key,
        sequence: block.sequence,
        reason: block.reason,
      }),
    );
  }
  copyDefined(summary, value, [
    "last_successful_delivery",
    "next_retry_deadline",
    "quarantine_count",
    "lifecycle_pending",
    "source_tail_uncertain",
    "disk_free_mb",
    "collector_version",
  ]);
  if (containsAbsolutePath(summary)) {
    return { error: "private-data-not-allowed" };
  }
  return {
    identity: value.identity.toLowerCase(),
    status: value.status,
    summary: summary as unknown as CollectorHealthSummary,
  };
}

function copyDefined(
  target: Record<string, unknown>,
  source: Record<string, unknown>,
  fields: string[],
): void {
  for (const field of fields) {
    if (source[field] !== undefined) target[field] = source[field];
  }
}

function isBacklog(value: unknown): boolean {
  return (
    isRecord(value) &&
    isNonnegativeInteger(value.runs) &&
    isNonnegativeInteger(value.events) &&
    isNonnegativeInteger(value.bytes)
  );
}

function isBlocks(value: unknown): boolean {
  return (
    Array.isArray(value) &&
    value.length <= 16 &&
    value.every(
      (block) =>
        isRecord(block) &&
        typeof block.run_key === "string" &&
        block.run_key.length <= 128 &&
        Number.isInteger(block.sequence) &&
        (block.sequence as number) >= 1 &&
        typeof block.reason === "string" &&
        block.reason.length <= 200,
    )
  );
}

function isOptionalNullableTimestamp(value: unknown): boolean {
  return value === undefined || value === null || isIsoTimestamp(value);
}

function isIsoTimestamp(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(
      value,
    ) &&
    Number.isFinite(Date.parse(value))
  );
}

function isStatus(value: unknown): value is CollectorHealthStatus {
  return value === "ok" || value === "degraded" || value === "blocked";
}

function isNonnegativeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0;
}

function containsAbsolutePath(value: unknown): boolean {
  if (typeof value === "string") {
    return /(?:^|\s)(?:[A-Za-z]:[\\/]|\\\\|\/(?:Users|home|var|tmp|etc)\/)/.test(
      value,
    );
  }
  if (Array.isArray(value)) return value.some(containsAbsolutePath);
  return isRecord(value) && Object.values(value).some(containsAbsolutePath);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

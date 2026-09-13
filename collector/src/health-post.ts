import { createHash } from "node:crypto";

export interface HealthStatus {
  identity: string;
  generated_at: string;
  status: "ok" | "degraded" | "blocked";
  backlog?: { runs: number; events: number; bytes: number };
  last_successful_delivery?: string | null;
  next_retry_deadline?: string | null;
  quarantine_count?: number;
  blocks?: Array<{ run_key: string; sequence: number; reason: string }>;
  lifecycle_pending?: number;
  source_tail_uncertain?: number;
  disk_free_mb?: number | null;
  collector_version?: string;
}

export function buildHealthStatus(input: {
  canonicalInput: string;
  operationalStatus: object;
  circuit: { open: boolean } | null;
  blocked: Array<{
    runKey: string;
    blockedAtSequence: number;
    blockedReason: string;
  }>;
  diskFreeBytesState: number | null;
  collectorVersion?: string;
}): HealthStatus {
  const operational = asRecord(input.operationalStatus);
  const aggregate = asRecord(asRecord(operational.backlog).aggregate);
  const quarantineCount = nonnegativeInteger(
    asRecord(operational.quarantine).count,
  );
  const sourceTailUncertain = nonnegativeInteger(
    asRecord(operational.source_tail).uncertain,
  );
  const blocks = input.blocked.slice(0, 16).map((block) => ({
    run_key: safeOperationalText(block.runKey, 128),
    sequence: Math.max(1, Math.floor(block.blockedAtSequence)),
    reason: safeOperationalText(block.blockedReason, 200),
  }));
  const status =
    input.circuit?.open === true || blocks.length > 0
      ? "blocked"
      : quarantineCount > 0 || sourceTailUncertain > 0
        ? "degraded"
        : "ok";
  const result: HealthStatus = {
    identity: createHash("sha256")
      .update(input.canonicalInput)
      .digest("hex")
      .slice(0, 16),
    generated_at: stringOrNow(operational.generated_at),
    status,
    backlog: {
      runs: nonnegativeInteger(aggregate.run_count),
      events: nonnegativeInteger(aggregate.count),
      bytes: nonnegativeInteger(aggregate.bytes),
    },
    last_successful_delivery: nullableString(
      operational.last_successful_delivery,
    ),
    next_retry_deadline: nullableString(operational.next_retry_deadline),
    quarantine_count: quarantineCount,
    blocks,
    lifecycle_pending: nonnegativeInteger(
      asRecord(operational.lifecycle).pending,
    ),
    source_tail_uncertain: sourceTailUncertain,
    disk_free_mb:
      input.diskFreeBytesState === null
        ? null
        : Math.max(0, Math.floor(input.diskFreeBytesState / 1_000_000)),
    collector_version: safeOperationalText(
      input.collectorVersion ?? "unknown",
      32,
    ),
  };
  while (Buffer.byteLength(JSON.stringify(result), "utf8") > 4096) {
    if ((result.blocks?.length ?? 0) === 0) break;
    result.blocks!.pop();
  }
  return result;
}

export async function postHealthStatus(options: {
  url: string;
  token: string;
  fetchImpl?: typeof fetch;
  status: object;
}): Promise<{ ok: boolean; httpStatus?: number; reason?: string }> {
  try {
    const body = JSON.stringify(options.status);
    if (Buffer.byteLength(body, "utf8") > 4096) {
      return { ok: false, reason: "payload-too-large" };
    }
    const response = await (options.fetchImpl ?? fetch)(options.url, {
      method: "POST",
      redirect: "manual",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${options.token}`,
      },
      body,
    });
    if (response.status >= 300 && response.status <= 399) {
      return {
        ok: false,
        httpStatus: response.status,
        reason: "authenticated-redirect-rejected",
      };
    }
    if (response.url !== "" && response.url !== options.url) {
      return { ok: false, reason: "authenticated-response-url-drift" };
    }
    return response.status === 200
      ? { ok: true, httpStatus: 200 }
      : { ok: false, httpStatus: response.status, reason: "http-error" };
  } catch {
    return { ok: false, reason: "network-error" };
  }
}

function safeOperationalText(value: string, maximum: number): string {
  const withoutPaths = value
    .replace(/[A-Za-z]:[\\/][^\s,;]*/g, "[REDACTED_PATH]")
    .replace(/\\\\[^\s,;]*/g, "[REDACTED_PATH]")
    .replace(/\/(?:Users|home|var|tmp|etc)\/[^\s,;]*/g, "[REDACTED_PATH]");
  return withoutPaths.slice(0, maximum);
}

function nonnegativeInteger(value: unknown): number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : 0;
}

function nullableString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function stringOrNow(value: unknown): string {
  return typeof value === "string" ? value : new Date().toISOString();
}

function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

import type { RunSpoolSummary } from "./spool.js";
import type { DurableSpool } from "./spool.js";
import type { DeliverableEvent } from "./types.js";

const DEFAULT_MAX_EVENTS = 100;
const DEFAULT_MAX_BODY_BYTES = 1_048_576;
const DEFAULT_TIMEOUT_MS = 30_000;
const ENVELOPE_PREFIX = '{"batch_schema_version":1,"events":[';
const ENVELOPE_SUFFIX = "]}";

export interface DeliveryOptions {
  spool: DurableSpool;
  baseUrl: string;
  token: string;
  fetchImpl?: typeof fetch;
  maxEventsPerBatch?: number;
  maxBodyBytes?: number;
  timeoutMs?: number;
  dryRun?: boolean;
}

export type RunDeliveryState =
  "complete" | "incomplete" | "blocked" | "error" | "empty";

export interface DeliveryBatchSummary {
  seq_start: number;
  seq_end: number;
  event_count: number;
}

export interface RunDeliveryResult {
  producer_id: string;
  run_key: string;
  state: RunDeliveryState;
  batches_posted: number;
  events_posted: number;
  accepted: number;
  duplicates: number;
  rejected: number;
  acknowledged_through: number;
  batches: DeliveryBatchSummary[];
  blocked_at_sequence?: number;
  blocked_event_id?: string;
  blocked_reason?: string;
  error?: string;
}

export interface DeliveryTotals {
  batches_posted: number;
  events_posted: number;
  accepted: number;
  duplicates: number;
  rejected: number;
  runs_complete: number;
  runs_incomplete: number;
  runs_blocked: number;
  runs_error: number;
}

export interface ActiveDeliverySummary {
  dry_run: false;
  url: string;
  runs: RunDeliveryResult[];
  totals: DeliveryTotals;
  had_failure: boolean;
}

export interface DryRunDeliverySummary {
  dry_run: true;
  url: string;
  runs: RunSpoolSummary[];
  totals: DeliveryTotals;
  had_failure: false;
}

export type DeliverySummary = ActiveDeliverySummary | DryRunDeliverySummary;

interface ResolvedOptions {
  spool: DurableSpool;
  baseUrl: string;
  token: string;
  fetchImpl: typeof fetch;
  maxEventsPerBatch: number;
  maxBodyBytes: number;
  timeoutMs: number;
}

interface IngestResult {
  event_id: string;
  status: "accepted" | "duplicate" | "rejected";
  reason?: string;
}

interface ValidatedResponse {
  byEventId: Map<string, IngestResult>;
}

export async function deliver(
  options: DeliveryOptions,
): Promise<DeliverySummary> {
  const resolved = resolveOptions(options);
  const initialRuns = options.spool.listRuns();
  if (options.dryRun === true) {
    return {
      dry_run: true,
      url: options.baseUrl,
      runs: initialRuns,
      totals: emptyTotals(),
      had_failure: false,
    };
  }

  const runs: RunDeliveryResult[] = [];
  for (const run of initialRuns) {
    runs.push(await deliverRun(run, resolved));
  }

  const totals = summarize(runs);
  return {
    dry_run: false,
    url: options.baseUrl,
    runs,
    totals,
    had_failure: totals.runs_blocked > 0 || totals.runs_error > 0,
  };
}

async function deliverRun(
  initial: RunSpoolSummary,
  options: ResolvedOptions,
): Promise<RunDeliveryResult> {
  const result: RunDeliveryResult = {
    producer_id: initial.producer_id,
    run_key: initial.run_key,
    state: "incomplete",
    batches_posted: 0,
    events_posted: 0,
    accepted: 0,
    duplicates: 0,
    rejected: 0,
    acknowledged_through: initial.acknowledged_through,
    batches: [],
  };

  while (true) {
    const candidates = options.spool.listDeliverable(
      initial.producer_id,
      initial.run_key,
      options.maxEventsPerBatch,
    );
    if (candidates.length === 0) {
      finishRunWithoutDeliverables(initial, result, options.spool);
      return result;
    }

    const batch = fitBatch(candidates, options.maxBodyBytes);
    if (batch === null) {
      result.state = "error";
      result.error = "spooled event exceeds the ingest body cap";
      return result;
    }

    const first = batch.events[0];
    const last = batch.events[batch.events.length - 1];
    if (first === undefined || last === undefined) {
      throw new Error("delivery attempted to post an empty batch");
    }
    result.batches_posted += 1;
    result.events_posted += batch.events.length;
    result.batches.push({
      seq_start: first.event.event_sequence,
      seq_end: last.event.event_sequence,
      event_count: batch.events.length,
    });

    let response: Response;
    try {
      response = await fetchWithTimeout(options, batch.body);
    } catch (error: unknown) {
      result.state = "error";
      result.error = safeErrorMessage(
        error instanceof RequestTimeoutError
          ? `request timed out after ${options.timeoutMs} ms`
          : `network error: ${errorMessage(error)}`,
        options.token,
      );
      return result;
    }

    if (response.status !== 200) {
      let serverBody: string;
      try {
        serverBody = await response.text();
      } catch (error: unknown) {
        serverBody = `unable to read response body: ${errorMessage(error)}`;
      }
      result.state = "error";
      result.error = safeErrorMessage(
        `HTTP ${response.status}: ${serverBody}`,
        options.token,
      );
      return result;
    }

    let payload: unknown;
    try {
      payload = JSON.parse(await response.text()) as unknown;
    } catch {
      result.state = "error";
      result.error = "unexpected response shape";
      return result;
    }
    const validated = validateResponse(payload, batch.events);
    if (validated === null) {
      result.state = "error";
      result.error = "unexpected response shape";
      return result;
    }

    for (const event of batch.events) {
      const ingestResult = validated.byEventId.get(event.event.event_id);
      if (ingestResult === undefined) {
        result.state = "error";
        result.error = "unexpected response shape";
        return result;
      }
      if (ingestResult.status === "accepted") {
        result.accepted += 1;
      } else if (ingestResult.status === "duplicate") {
        result.duplicates += 1;
      } else {
        result.rejected += 1;
      }
    }

    for (const event of batch.events) {
      const ingestResult = validated.byEventId.get(event.event.event_id);
      if (ingestResult === undefined) {
        result.state = "error";
        result.error = "unexpected response shape";
        return result;
      }
      if (ingestResult.status === "rejected") {
        result.state = "blocked";
        result.blocked_at_sequence = event.event.event_sequence;
        result.blocked_event_id = event.event.event_id;
        if (ingestResult.reason !== undefined) {
          result.blocked_reason = safeErrorMessage(
            ingestResult.reason,
            options.token,
          );
        }
        return result;
      }
      try {
        options.spool.acknowledge(event.event.event_id);
        result.acknowledged_through = event.event.event_sequence;
      } catch (error: unknown) {
        result.state = "error";
        result.error = safeErrorMessage(
          `spool acknowledgement error: ${errorMessage(error)}`,
          options.token,
        );
        return result;
      }
    }
  }
}

function finishRunWithoutDeliverables(
  initial: RunSpoolSummary,
  result: RunDeliveryResult,
  spool: DurableSpool,
): void {
  if (initial.maximum_sequence > result.acknowledged_through) {
    result.state = "blocked";
    result.blocked_at_sequence = initial.acknowledged_through + 1;
    return;
  }
  if (result.acknowledged_through === 0) {
    result.state = "empty";
    return;
  }

  const last = spool.getEvent(
    initial.producer_id,
    initial.run_key,
    result.acknowledged_through,
  );
  if (last === null) {
    result.state = "error";
    result.error = "spool cursor points at a missing event";
    return;
  }
  result.state =
    last.event.event_type === "mission.ended" ? "complete" : "incomplete";
}

function fitBatch(
  candidates: DeliverableEvent[],
  maxBodyBytes: number,
): { events: DeliverableEvent[]; body: string } | null {
  const events = candidates.slice();
  while (events.length > 0) {
    const body = buildBody(events);
    if (Buffer.byteLength(body, "utf8") <= maxBodyBytes) {
      return { events, body };
    }
    events.pop();
  }
  return null;
}

function buildBody(events: DeliverableEvent[]): string {
  return (
    ENVELOPE_PREFIX +
    events.map((event) => event.canonical_json).join(",") +
    ENVELOPE_SUFFIX
  );
}

async function fetchWithTimeout(
  options: ResolvedOptions,
  body: string,
): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs);
  try {
    return await options.fetchImpl(ingestUrl(options.baseUrl), {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${options.token}`,
      },
      body,
      signal: controller.signal,
    });
  } catch (error: unknown) {
    if (controller.signal.aborted) {
      throw new RequestTimeoutError();
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function validateResponse(
  value: unknown,
  events: DeliverableEvent[],
): ValidatedResponse | null {
  if (!isRecord(value) || !Array.isArray(value.results)) {
    return null;
  }
  if (!isRecord(value.summary)) {
    return null;
  }
  if (value.results.length !== events.length) {
    return null;
  }

  const expectedIds = new Set(events.map((item) => item.event.event_id));
  const byEventId = new Map<string, IngestResult>();
  const counts = { accepted: 0, duplicate: 0, rejected: 0 };
  for (const candidate of value.results) {
    if (
      !isRecord(candidate) ||
      typeof candidate.event_id !== "string" ||
      !expectedIds.has(candidate.event_id) ||
      byEventId.has(candidate.event_id) ||
      !isIngestStatus(candidate.status) ||
      (candidate.reason !== undefined && typeof candidate.reason !== "string")
    ) {
      return null;
    }
    const ingestResult: IngestResult = {
      event_id: candidate.event_id,
      status: candidate.status,
      ...(candidate.reason === undefined ? {} : { reason: candidate.reason }),
    };
    byEventId.set(candidate.event_id, ingestResult);
    counts[candidate.status] += 1;
  }

  if (
    !isNonnegativeInteger(value.summary.accepted) ||
    !isNonnegativeInteger(value.summary.duplicates) ||
    !isNonnegativeInteger(value.summary.rejected) ||
    value.summary.accepted !== counts.accepted ||
    value.summary.duplicates !== counts.duplicate ||
    value.summary.rejected !== counts.rejected
  ) {
    return null;
  }
  return { byEventId };
}

function resolveOptions(options: DeliveryOptions): ResolvedOptions {
  const maxEventsPerBatch = options.maxEventsPerBatch ?? DEFAULT_MAX_EVENTS;
  const maxBodyBytes = options.maxBodyBytes ?? DEFAULT_MAX_BODY_BYTES;
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  if (
    !Number.isInteger(maxEventsPerBatch) ||
    maxEventsPerBatch < 1 ||
    maxEventsPerBatch > 100
  ) {
    throw new Error("maxEventsPerBatch must be an integer from 1 through 100");
  }
  if (!Number.isInteger(maxBodyBytes) || maxBodyBytes < 1) {
    throw new Error("maxBodyBytes must be a positive integer");
  }
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1) {
    throw new Error("timeoutMs must be a positive integer");
  }
  return {
    spool: options.spool,
    baseUrl: options.baseUrl,
    token: options.token,
    fetchImpl: options.fetchImpl ?? fetch,
    maxEventsPerBatch,
    maxBodyBytes,
    timeoutMs,
  };
}

function summarize(runs: RunDeliveryResult[]): DeliveryTotals {
  const totals = emptyTotals();
  for (const run of runs) {
    totals.batches_posted += run.batches_posted;
    totals.events_posted += run.events_posted;
    totals.accepted += run.accepted;
    totals.duplicates += run.duplicates;
    totals.rejected += run.rejected;
    if (run.state === "complete") {
      totals.runs_complete += 1;
    } else if (run.state === "incomplete") {
      totals.runs_incomplete += 1;
    } else if (run.state === "blocked") {
      totals.runs_blocked += 1;
    } else if (run.state === "error") {
      totals.runs_error += 1;
    }
  }
  return totals;
}

function emptyTotals(): DeliveryTotals {
  return {
    batches_posted: 0,
    events_posted: 0,
    accepted: 0,
    duplicates: 0,
    rejected: 0,
    runs_complete: 0,
    runs_incomplete: 0,
    runs_blocked: 0,
    runs_error: 0,
  };
}

function ingestUrl(baseUrl: string): string {
  return `${baseUrl.replace(/\/+$/, "")}/api/telemetry/ingest`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isIngestStatus(value: unknown): value is IngestResult["status"] {
  return value === "accepted" || value === "duplicate" || value === "rejected";
}

function isNonnegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

function safeErrorMessage(message: string, token: string): string {
  const redacted =
    token.length === 0 ? message : message.split(token).join("[REDACTED]");
  return redacted.slice(0, 500);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

class RequestTimeoutError extends Error {}

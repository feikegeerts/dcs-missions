import { readFileSync } from "node:fs";

import {
  defaultProcessObservationProvider,
  sendAbortSignals,
} from "./abort-signal.js";
import type { AbortSignalSummary, ProcessObservation } from "./abort-signal.js";
import type { RunSpoolSummary } from "./spool.js";
import type { DurableSpool } from "./spool.js";
import type { DeliverableEvent } from "./types.js";

const DEFAULT_MAX_EVENTS = 100;
const DEFAULT_MAX_BODY_BYTES = 1_048_576;
const DEFAULT_TIMEOUT_MS = 30_000;
const DEFAULT_MAX_ATTEMPTS = 3;
const DEFAULT_RETRY_DELAYS_MS = [1000, 2000];
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
  maxAttempts?: number;
  retryDelaysMs?: number[];
  sleepImpl?: (ms: number) => Promise<void>;
  nowProvider?: () => string;
  processObservationProvider?: () => ProcessObservation;
  dcsProducerIdProvider?: () => string | null;
  dcsLogTextProvider?: () => string;
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
  attempts: number;
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
  abort_signals?: AbortSignalSummary[];
}

export interface DryRunDeliverySummary {
  dry_run: true;
  url: string;
  runs: RunSpoolSummary[];
  totals: DeliveryTotals;
  had_failure: false;
  abort_signals?: AbortSignalSummary[];
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
  maxAttempts: number;
  retryDelaysMs: number[];
  sleepImpl: (ms: number) => Promise<void>;
  nowProvider: () => string;
  processObservationProvider?: () => ProcessObservation;
  dcsProducerIdProvider?: () => string | null;
  dcsLogTextProvider?: () => string;
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
      abort_signals: [],
    };
  }

  const runs: RunDeliveryResult[] = [];
  for (const run of initialRuns) {
    const result = await deliverRun(run, resolved);
    const success =
      result.state === "complete" ||
      result.state === "incomplete" ||
      result.state === "empty";
    options.spool.recordDeliveryAttempt({
      producerId: result.producer_id,
      runKey: result.run_key,
      at: resolved.nowProvider(),
      success,
      error: success ? null : deliveryFailureMessage(result),
    });
    runs.push(result);
  }

  const dcsLogText = (
    resolved.dcsLogTextProvider ?? defaultDcsLogTextProvider
  )();
  const processObservation = (
    resolved.processObservationProvider ?? defaultProcessObservationProvider
  )();
  const producerId = (resolved.dcsProducerIdProvider ?? (() => null))();
  const abortSignals = await sendAbortSignals({
    baseUrl: resolved.baseUrl,
    token: resolved.token,
    fetchImpl: resolved.fetchImpl,
    timeoutMs: resolved.timeoutMs,
    spool: options.spool,
    dcsLogText,
    processObservation,
    producerId,
    runs: initialRuns,
  });
  const totals = summarize(runs);
  return {
    dry_run: false,
    url: options.baseUrl,
    runs,
    totals,
    had_failure: totals.runs_blocked > 0 || totals.runs_error > 0,
    abort_signals: abortSignals,
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
    attempts: 0,
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

    let response: Response | undefined;
    for (let attempt = 1; attempt <= options.maxAttempts; attempt += 1) {
      result.attempts += 1;
      let transientError: string;
      try {
        const attemptResponse = await fetchWithTimeout(options, batch.body);
        if (attemptResponse.status === 200) {
          response = attemptResponse;
          break;
        }

        let serverBody: string;
        try {
          serverBody = await attemptResponse.text();
        } catch (error: unknown) {
          serverBody = `unable to read response body: ${errorMessage(error)}`;
        }
        const responseError = `HTTP ${attemptResponse.status}: ${serverBody}`;
        if (!isRetryableStatus(attemptResponse.status)) {
          result.state = "error";
          result.error = safeErrorMessage(responseError, options.token);
          return result;
        }
        transientError = responseError;
      } catch (error: unknown) {
        transientError =
          error instanceof RequestTimeoutError
            ? `request timed out after ${options.timeoutMs} ms`
            : `network error: ${errorMessage(error)}`;
      }

      if (attempt === options.maxAttempts) {
        result.state = "error";
        result.error = `${safeErrorMessage(transientError, options.token)} (after ${options.maxAttempts} attempts)`;
        return result;
      }

      await options.sleepImpl(
        options.retryDelaysMs[
          Math.min(attempt - 1, options.retryDelaysMs.length - 1)
        ]!,
      );
    }
    if (response === undefined) {
      throw new Error("delivery retry loop ended without a response");
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
  const maxAttempts = options.maxAttempts ?? DEFAULT_MAX_ATTEMPTS;
  const retryDelaysMs = options.retryDelaysMs ?? DEFAULT_RETRY_DELAYS_MS;
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
  if (!Number.isInteger(maxAttempts) || maxAttempts < 1) {
    throw new Error(
      "maxAttempts must be an integer greater than or equal to 1",
    );
  }
  if (
    !Array.isArray(retryDelaysMs) ||
    retryDelaysMs.length === 0 ||
    retryDelaysMs.some((delay) => !Number.isInteger(delay) || delay < 0)
  ) {
    throw new Error(
      "retryDelaysMs must be a non-empty array of non-negative integers",
    );
  }
  return {
    spool: options.spool,
    baseUrl: options.baseUrl,
    token: options.token,
    fetchImpl: options.fetchImpl ?? fetch,
    maxEventsPerBatch,
    maxBodyBytes,
    timeoutMs,
    maxAttempts,
    retryDelaysMs,
    sleepImpl: options.sleepImpl ?? sleep,
    nowProvider: options.nowProvider ?? (() => new Date().toISOString()),
    processObservationProvider: options.processObservationProvider,
    dcsProducerIdProvider: options.dcsProducerIdProvider,
    dcsLogTextProvider: options.dcsLogTextProvider,
  };
}

function defaultDcsLogTextProvider(): string {
  const path = process.env.TELEMETRY_DCS_LOG;
  if (path === undefined || path.length === 0) {
    return "";
  }
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function deliveryFailureMessage(result: RunDeliveryResult): string {
  return (
    result.error ??
    `blocked at sequence ${result.blocked_at_sequence}${
      result.blocked_reason === undefined ? "" : `: ${result.blocked_reason}`
    }`
  );
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

function isRetryableStatus(status: number): boolean {
  return status === 429 || (status >= 500 && status <= 599);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
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

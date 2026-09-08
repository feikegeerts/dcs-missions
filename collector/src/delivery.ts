import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { setImmediate as yieldImmediate } from "node:timers/promises";

import {
  decideAbortSignal,
  defaultProcessObservationProvider,
  lifecycleStopObservations,
  runObservations,
} from "./abort-signal.js";
import type { AbortSignalSummary, ProcessObservation } from "./abort-signal.js";
import { canonicalJson } from "./canonical-json.js";
import type {
  DeliveryCircuitState,
  DurableSpool,
  LifecycleObservationRecord,
  RunRetryState,
  RunSpoolSummary,
} from "./spool.js";
import type { DeliverableEvent } from "./types.js";

const DEFAULT_MAX_EVENTS = 100;
const DEFAULT_MAX_BODY_BYTES = 1_048_576;
const DEFAULT_TIMEOUT_MS = 30_000;
const RETRY_BASE_MS = 1000;
const RETRY_CAP_MS = 300_000;
const RETRY_AFTER_MIN_MS = 1000;
const RETRY_AFTER_MAX_MS = 600_000;
const CIRCUIT_BASE_MS = 60_000;
const CIRCUIT_CAP_MS = 900_000;
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
  /** Retained for CLI/API compatibility. Durable scheduling performs one attempt per pass. */
  maxAttempts?: number;
  /** Retained for CLI/API compatibility. Durable exponential backoff is authoritative. */
  retryDelaysMs?: number[];
  /** Retained for API compatibility; delivery no longer sleeps inside a pass. */
  sleepImpl?: (ms: number) => Promise<void>;
  nowProvider?: () => string;
  randomProvider?: () => number;
  yieldImpl?: () => Promise<void>;
  processObservationProvider?: () => ProcessObservation;
  dcsProducerIdProvider?: () => string | null;
  dcsLogTextProvider?: () => string;
  dryRun?: boolean;
}

export type RunDeliveryState =
  "complete" | "incomplete" | "blocked" | "error" | "empty" | "deferred";

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
  next_retry_at?: string;
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

export interface CircuitSummary {
  open: boolean;
  open_since: string | null;
  next_probe_at: string | null;
  attempt_count: number;
  last_status: string | null;
  probe_attempted: boolean;
}

export interface ActiveDeliverySummary {
  dry_run: false;
  url: string;
  runs: RunDeliveryResult[];
  totals: DeliveryTotals;
  had_failure: boolean;
  abort_signals?: AbortSignalSummary[];
  circuit: CircuitSummary;
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
  nowProvider: () => string;
  randomProvider: () => number;
  yieldImpl: () => Promise<void>;
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

interface Batch {
  events: DeliverableEvent[];
  body: string;
}

interface AttemptContext {
  isProbe: boolean;
  circuitOpened: boolean;
  responseReceived: boolean;
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

  persistLifecycleObservations(initialRuns, resolved);
  const circuitAtStart = options.spool.getDeliveryCircuit();
  const now = nowMs(resolved);
  const probeDue =
    circuitAtStart !== null && Date.parse(circuitAtStart.nextProbeAt) <= now;
  if (circuitAtStart !== null && !probeDue) {
    const runs = initialRuns.map((run) =>
      deferredResult(run, circuitAtStart.nextProbeAt, "delivery circuit open"),
    );
    return activeSummary(options.baseUrl, runs, [], options.spool, false);
  }

  let scheduledRuns = initialRuns;
  if (probeDue) {
    const probe = smallestEligibleRun(initialRuns, resolved, now);
    scheduledRuns = probe === undefined ? [] : [probe];
  }

  const runs: RunDeliveryResult[] = [];
  let circuitOpened = false;
  let probeAttempted = false;
  for (let index = 0; index < scheduledRuns.length; index += 1) {
    const run = scheduledRuns[index]!;
    const context: AttemptContext = {
      isProbe: probeDue,
      circuitOpened: false,
      responseReceived: false,
    };
    const result = await deliverOneBatch(run, resolved, context);
    probeAttempted ||= context.isProbe && result.attempts > 0;
    circuitOpened ||= context.circuitOpened;
    runs.push(result);
    recordHealth(result, resolved);

    if (context.isProbe && !context.responseReceived && result.attempts > 0) {
      reopenCircuitAfterProbeLoss(
        circuitAtStart!,
        result.error ?? "network error",
        resolved,
      );
      circuitOpened = true;
    }
    if (circuitOpened) {
      for (const remaining of scheduledRuns.slice(index + 1)) {
        const circuit = options.spool.getDeliveryCircuit();
        runs.push(
          deferredResult(
            remaining,
            circuit?.nextProbeAt ?? resolved.nowProvider(),
            "delivery circuit open",
          ),
        );
      }
      break;
    }
    await resolved.yieldImpl();
  }

  if (probeDue && !circuitOpened && probeAttempted) {
    options.spool.closeDeliveryCircuit();
  }

  const circuitBeforeLifecycle = options.spool.getDeliveryCircuit();
  const abortSignals =
    circuitBeforeLifecycle === null
      ? await deliverLifecycleOutbox(resolved)
      : lifecycleSummaries(options.spool.listLifecycleObservations());
  const circuit = options.spool.getDeliveryCircuit();
  const totals = summarize(runs);
  return {
    dry_run: false,
    url: options.baseUrl,
    runs,
    totals,
    had_failure:
      totals.runs_blocked > 0 || totals.runs_error > 0 || circuit !== null,
    abort_signals: abortSignals,
    circuit: circuitSummary(circuit, probeAttempted),
  };
}

async function deliverOneBatch(
  initial: RunSpoolSummary,
  options: ResolvedOptions,
  context: AttemptContext,
): Promise<RunDeliveryResult> {
  const result = baseResult(initial);
  const retry = options.spool.getRunRetryState(
    initial.producer_id,
    initial.run_key,
  );
  if (
    retry?.blockedAtSequence !== null &&
    retry?.blockedAtSequence !== undefined
  ) {
    applyPersistedBlock(result, retry);
    return result;
  }
  const now = nowMs(options);
  if (retry?.nextAttemptAt !== null && retry?.nextAttemptAt !== undefined) {
    if (Date.parse(retry.nextAttemptAt) > now) {
      return deferredResult(
        initial,
        retry.nextAttemptAt,
        "retry deadline pending",
      );
    }
  }

  const candidates = options.spool.listDeliverable(
    initial.producer_id,
    initial.run_key,
    options.maxEventsPerBatch,
  );
  if (candidates.length === 0) {
    finishRunWithoutDeliverables(initial, result, options.spool);
    if (
      result.state === "blocked" &&
      result.blocked_at_sequence !== undefined
    ) {
      options.spool.blockRun({
        producerId: initial.producer_id,
        runKey: initial.run_key,
        sequence: result.blocked_at_sequence,
        eventId: null,
        reason: result.blocked_reason ?? "sequence gap",
        classification: "sequence-gap",
      });
    }
    return result;
  }
  const batch = fitBatch(candidates, options.maxBodyBytes);
  if (batch === null) {
    blockFirstEvent(
      candidates[0]!,
      "spooled event exceeds the ingest body cap",
      result,
      options,
    );
    return result;
  }
  addBatch(result, batch);
  result.attempts = 1;

  let response: Response;
  try {
    response = await fetchWithTimeout(
      options,
      batch.body,
      ingestUrl(options.baseUrl),
    );
    context.responseReceived = true;
  } catch (error: unknown) {
    const message =
      error instanceof RequestTimeoutError
        ? `request timed out after ${options.timeoutMs} ms`
        : `network error: ${errorMessage(error)}`;
    scheduleRunRetry(initial, retry, "network", message, null, result, options);
    return result;
  }

  if (context.isProbe && response.status !== 401 && response.status !== 403) {
    options.spool.closeDeliveryCircuit();
  }
  if (response.status === 401 || response.status === 403) {
    const message = `HTTP ${response.status}: authorization rejected`;
    openCircuit(response.status, message, options);
    context.circuitOpened = true;
    result.state = "error";
    result.error = message;
    return result;
  }
  if (response.status !== 200) {
    const responseError = await safeResponseError(response, options.token);
    if (response.status === 400) {
      blockFirstEvent(batch.events[0]!, responseError, result, options);
      return result;
    }
    if (response.status === 404 || isRetryableStatus(response.status)) {
      scheduleRunRetry(
        initial,
        retry,
        response.status === 404
          ? "remote-run-missing"
          : `http-${response.status}`,
        responseError,
        response.headers.get("retry-after"),
        result,
        options,
      );
      return result;
    }
    blockFirstEvent(batch.events[0]!, responseError, result, options);
    return result;
  }

  let payload: unknown;
  try {
    payload = JSON.parse(await response.text()) as unknown;
  } catch {
    scheduleRunRetry(
      initial,
      retry,
      "invalid-response",
      "unexpected response shape",
      null,
      result,
      options,
    );
    return result;
  }
  const validated = validateResponse(payload, batch.events);
  if (validated === null) {
    scheduleRunRetry(
      initial,
      retry,
      "invalid-response",
      "unexpected response shape",
      null,
      result,
      options,
    );
    return result;
  }

  for (const event of batch.events) {
    const ingestResult = validated.byEventId.get(event.event.event_id)!;
    if (ingestResult.status === "accepted") result.accepted += 1;
    else if (ingestResult.status === "duplicate") result.duplicates += 1;
    else result.rejected += 1;
  }
  for (const event of batch.events) {
    const ingestResult = validated.byEventId.get(event.event.event_id)!;
    if (ingestResult.status === "rejected") {
      const reason = safeErrorMessage(
        ingestResult.reason ?? "permanent event rejection",
        options.token,
      );
      options.spool.blockRun({
        producerId: initial.producer_id,
        runKey: initial.run_key,
        sequence: event.event.event_sequence,
        eventId: event.event.event_id,
        reason,
        classification: "event-rejected",
      });
      result.state = "blocked";
      result.blocked_at_sequence = event.event.event_sequence;
      result.blocked_event_id = event.event.event_id;
      result.blocked_reason = reason;
      return result;
    }
    try {
      options.spool.acknowledge(event.event.event_id);
      result.acknowledged_through = event.event.event_sequence;
    } catch (error: unknown) {
      scheduleRunRetry(
        initial,
        retry,
        "acknowledgement-error",
        safeErrorMessage(
          `spool acknowledgement error: ${errorMessage(error)}`,
          options.token,
        ),
        null,
        result,
        options,
      );
      return result;
    }
  }
  options.spool.clearRunRetry(initial.producer_id, initial.run_key);
  const refreshed = options.spool
    .listRuns()
    .find(
      (run) =>
        run.producer_id === initial.producer_id &&
        run.run_key === initial.run_key,
    );
  if (refreshed !== undefined) {
    finishRunWithoutDeliverables(refreshed, result, options.spool);
    if (refreshed.maximum_sequence > result.acknowledged_through) {
      result.state = "incomplete";
      delete result.blocked_at_sequence;
    }
  }
  return result;
}

function persistLifecycleObservations(
  runs: RunSpoolSummary[],
  options: ResolvedOptions,
): void {
  const producerId = (options.dcsProducerIdProvider ?? (() => null))();
  if (producerId === null) return;
  const text = (options.dcsLogTextProvider ?? defaultDcsLogTextProvider)();
  const observedRuns = runObservations(text);
  const stops = lifecycleStopObservations(text);
  const processObservation = (
    options.processObservationProvider ?? defaultProcessObservationProvider
  )();
  for (const run of runs) {
    if (
      run.producer_id !== producerId ||
      options.spool.hasMissionEnded(producerId, run.run_key)
    ) {
      continue;
    }
    const observedRun = observedRuns.find(
      (candidate) =>
        candidate.producerId === producerId && candidate.runKey === run.run_key,
    );
    if (observedRun === undefined) continue;
    const stop = stops.find(
      (candidate) =>
        candidate.runKey === run.run_key &&
        candidate.generation === observedRun.generation,
    );
    const processState =
      processObservation.runKey === run.run_key &&
      processObservation.hookGeneration === observedRun.generation
        ? processObservation.state
        : "unknown";
    const decision = decideAbortSignal({
      producerId,
      runKey: run.run_key,
      hasMissionEnded: false,
      processState,
      ...(stop === undefined ? {} : { stopGeneration: stop.generation }),
    });
    if (decision.reason === null) continue;
    const binding = {
      generation: observedRun.generation,
      ...(processObservation.pid === undefined
        ? {}
        : { pid: processObservation.pid }),
      ...(processObservation.creationTime === undefined
        ? {}
        : { creationTime: processObservation.creationTime }),
      ...(processObservation.profilePath === undefined
        ? {}
        : { profilePath: processObservation.profilePath }),
      ...(processObservation.inputPath === undefined
        ? {}
        : { inputPath: processObservation.inputPath }),
    };
    const evidenceIdentity =
      stop?.evidenceIdentity ?? canonicalJson({ processState, ...binding });
    const keyMaterial = canonicalJson({
      producerId,
      runKey: run.run_key,
      binding,
      reason: decision.reason,
      evidenceIdentity,
    });
    options.spool.insertLifecycleObservation({
      observationKey: createHash("sha256").update(keyMaterial).digest("hex"),
      producerId,
      runKey: run.run_key,
      hookGeneration: decision.generation ?? observedRun.generation,
      processBinding: binding,
      reason: decision.reason,
      evidenceIdentity,
      tailState:
        stop?.tailState === "clear" &&
        !options.spool.runHasPartialTail(producerId, run.run_key)
          ? "clear"
          : "unknown",
      observedAt: options.nowProvider(),
    });
  }
}

async function deliverLifecycleOutbox(
  options: ResolvedOptions,
): Promise<AbortSignalSummary[]> {
  const summaries: AbortSignalSummary[] = [];
  for (const observation of options.spool.listLifecycleObservations()) {
    if (observation.state !== "pending") continue;
    const run = options.spool
      .listRuns()
      .find(
        (candidate) =>
          candidate.producer_id === observation.producerId &&
          candidate.run_key === observation.runKey,
      );
    if (run === undefined) continue;
    if (
      options.spool.hasMissionEnded(observation.producerId, observation.runKey)
    ) {
      options.spool.resolveLifecycleWithoutRequest(
        observation.observationKey,
        "superseded-by-clean-end",
      );
      continue;
    }
    const retry = options.spool.getRunRetryState(
      observation.producerId,
      observation.runKey,
    );
    const ready =
      observation.tailState === "clear" &&
      retry?.blockedAtSequence == null &&
      run.acknowledged_through === run.maximum_sequence;
    if (!ready) continue;
    if (
      observation.nextAttemptAt !== null &&
      Date.parse(observation.nextAttemptAt) > nowMs(options)
    ) {
      continue;
    }
    const summary = await sendLifecycleObservation(observation, options);
    summaries.push(summary);
    if (options.spool.getDeliveryCircuit() !== null) break;
    await options.yieldImpl();
  }
  return summaries.length > 0
    ? summaries
    : lifecycleSummaries(options.spool.listLifecycleObservations());
}

async function sendLifecycleObservation(
  observation: LifecycleObservationRecord,
  options: ResolvedOptions,
): Promise<AbortSignalSummary> {
  const summary: AbortSignalSummary = {
    producerId: observation.producerId,
    runKey: observation.runKey,
    reason: observation.reason as AbortSignalSummary["reason"],
    ...(observation.hookGeneration === null
      ? {}
      : { generation: observation.hookGeneration }),
    posted: false,
    retryRequired: true,
  };
  const body = JSON.stringify({
    reason: observation.reason,
    producer_id: observation.producerId,
    ...(observation.hookGeneration === null
      ? {}
      : { generation: observation.hookGeneration }),
  });
  let response: Response;
  try {
    response = await fetchWithTimeout(
      options,
      body,
      `${options.baseUrl.replace(/\/+$/, "")}/api/telemetry/runs/${encodeURIComponent(observation.runKey)}`,
    );
  } catch (error: unknown) {
    const message = safeErrorMessage(
      error instanceof RequestTimeoutError
        ? `request timed out after ${options.timeoutMs} ms`
        : `network error: ${errorMessage(error)}`,
      options.token,
    );
    const next = retryDeadline(observation.attemptCount + 1, null, options);
    options.spool.recordLifecycleOutcome({
      observationKey: observation.observationKey,
      at: options.nowProvider(),
      classification: "network",
      statusCode: null,
      error: message,
      state: "pending",
      nextAttemptAt: next,
    });
    summary.error = message;
    return summary;
  }
  summary.status = response.status;
  if (response.status === 200) {
    options.spool.recordLifecycleOutcome({
      observationKey: observation.observationKey,
      at: options.nowProvider(),
      classification: "success",
      statusCode: 200,
      error: null,
      state: "sent",
      nextAttemptAt: null,
    });
    summary.posted = true;
    summary.retryRequired = false;
    return summary;
  }
  if (response.status === 401 || response.status === 403) {
    const message = `HTTP ${response.status}: authorization rejected`;
    options.spool.recordLifecycleOutcome({
      observationKey: observation.observationKey,
      at: options.nowProvider(),
      classification: "authorization",
      statusCode: response.status,
      error: message,
      state: "pending",
      nextAttemptAt: retryDeadline(observation.attemptCount + 1, null, options),
    });
    openCircuit(response.status, message, options);
    summary.error = message;
    return summary;
  }
  const message = await safeResponseError(response, options.token);
  const retryable =
    response.status === 404 || isRetryableStatus(response.status);
  options.spool.recordLifecycleOutcome({
    observationKey: observation.observationKey,
    at: options.nowProvider(),
    classification:
      response.status === 404
        ? "remote-run-missing"
        : `http-${response.status}`,
    statusCode: response.status,
    error: message,
    state: retryable ? "pending" : "terminal",
    nextAttemptAt: retryable
      ? retryDeadline(
          observation.attemptCount + 1,
          response.headers.get("retry-after"),
          options,
        )
      : null,
  });
  summary.error = message;
  summary.retryRequired = retryable;
  return summary;
}

function smallestEligibleRun(
  runs: RunSpoolSummary[],
  options: ResolvedOptions,
  now: number,
): RunSpoolSummary | undefined {
  return runs
    .map((run) => {
      const retry = options.spool.getRunRetryState(
        run.producer_id,
        run.run_key,
      );
      if (
        retry?.blockedAtSequence != null ||
        (retry?.nextAttemptAt != null && Date.parse(retry.nextAttemptAt) > now)
      ) {
        return null;
      }
      const batch = fitBatch(
        options.spool.listDeliverable(
          run.producer_id,
          run.run_key,
          options.maxEventsPerBatch,
        ),
        options.maxBodyBytes,
      );
      return batch === null ? null : { run, size: batch.events.length };
    })
    .filter(
      (candidate): candidate is { run: RunSpoolSummary; size: number } =>
        candidate !== null,
    )
    .sort((left, right) => left.size - right.size)[0]?.run;
}

function scheduleRunRetry(
  run: RunSpoolSummary,
  previous: RunRetryState | null,
  classification: string,
  message: string,
  retryAfter: string | null,
  result: RunDeliveryResult,
  options: ResolvedOptions,
): void {
  const safeMessage = safeErrorMessage(message, options.token);
  const attemptCount = (previous?.attemptCount ?? 0) + 1;
  const nextAttemptAt = retryDeadline(attemptCount, retryAfter, options);
  options.spool.recordRunRetry({
    producerId: run.producer_id,
    runKey: run.run_key,
    attemptCount,
    nextAttemptAt,
    classification,
    error: safeMessage,
  });
  result.state = "error";
  result.error = safeMessage;
  result.next_retry_at = nextAttemptAt;
}

function blockFirstEvent(
  event: DeliverableEvent,
  reason: string,
  result: RunDeliveryResult,
  options: ResolvedOptions,
): void {
  const safeReason = safeErrorMessage(reason, options.token);
  options.spool.blockRun({
    producerId: event.event.producer_id,
    runKey: event.event.run_key,
    sequence: event.event.event_sequence,
    eventId: event.event.event_id,
    reason: safeReason,
    classification: "permanent-batch-rejection",
  });
  result.state = "blocked";
  result.blocked_at_sequence = event.event.event_sequence;
  result.blocked_event_id = event.event.event_id;
  result.blocked_reason = safeReason;
}

function openCircuit(
  status: number,
  message: string,
  options: ResolvedOptions,
): void {
  const existing = options.spool.getDeliveryCircuit();
  const attemptCount = (existing?.attemptCount ?? 0) + 1;
  options.spool.openDeliveryCircuit({
    at: options.nowProvider(),
    nextProbeAt: addMs(
      nowMs(options),
      jitteredExponential(
        attemptCount,
        CIRCUIT_BASE_MS,
        CIRCUIT_CAP_MS,
        options.randomProvider,
      ),
    ),
    attemptCount,
    status: safeErrorMessage(message || `HTTP ${status}`, options.token),
  });
}

function reopenCircuitAfterProbeLoss(
  existing: DeliveryCircuitState,
  message: string,
  options: ResolvedOptions,
): void {
  const attemptCount = existing.attemptCount + 1;
  options.spool.openDeliveryCircuit({
    at: existing.openSince,
    nextProbeAt: addMs(
      nowMs(options),
      jitteredExponential(
        attemptCount,
        CIRCUIT_BASE_MS,
        CIRCUIT_CAP_MS,
        options.randomProvider,
      ),
    ),
    attemptCount,
    status: safeErrorMessage(`probe failed: ${message}`, options.token),
  });
}

function retryDeadline(
  attemptCount: number,
  retryAfter: string | null,
  options: ResolvedOptions,
): string {
  const now = nowMs(options);
  const retryAfterMs = parseRetryAfter(retryAfter, now);
  const delay =
    retryAfterMs ??
    jitteredExponential(
      attemptCount,
      RETRY_BASE_MS,
      RETRY_CAP_MS,
      options.randomProvider,
    );
  return addMs(now, delay);
}

function parseRetryAfter(value: string | null, now: number): number | null {
  if (value === null) return null;
  let delay: number;
  const trimmed = value.trim();
  if (/^\d+$/.test(trimmed)) delay = Number(trimmed) * 1000;
  else {
    const date = Date.parse(trimmed);
    if (!Number.isFinite(date)) return null;
    delay = date - now;
  }
  if (!Number.isFinite(delay)) return null;
  return Math.min(RETRY_AFTER_MAX_MS, Math.max(RETRY_AFTER_MIN_MS, delay));
}

function jitteredExponential(
  attemptCount: number,
  base: number,
  cap: number,
  randomProvider: () => number,
): number {
  const exponential = Math.min(cap, base * 2 ** Math.min(attemptCount - 1, 30));
  return Math.min(
    cap,
    Math.max(1, Math.round(exponential * (0.75 + randomProvider() * 0.5))),
  );
}

function baseResult(initial: RunSpoolSummary): RunDeliveryResult {
  return {
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
}

function deferredResult(
  initial: RunSpoolSummary,
  deadline: string,
  error: string,
): RunDeliveryResult {
  return {
    ...baseResult(initial),
    state: "deferred",
    next_retry_at: deadline,
    error,
  };
}

function applyPersistedBlock(
  result: RunDeliveryResult,
  retry: RunRetryState,
): void {
  result.state = "blocked";
  result.blocked_at_sequence = retry.blockedAtSequence!;
  if (retry.blockedEventId !== null)
    result.blocked_event_id = retry.blockedEventId;
  if (retry.blockedReason !== null) result.blocked_reason = retry.blockedReason;
}

function addBatch(result: RunDeliveryResult, batch: Batch): void {
  const first = batch.events[0]!;
  const last = batch.events[batch.events.length - 1]!;
  result.batches_posted = 1;
  result.events_posted = batch.events.length;
  result.batches.push({
    seq_start: first.event.event_sequence,
    seq_end: last.event.event_sequence,
    event_count: batch.events.length,
  });
}

function finishRunWithoutDeliverables(
  initial: RunSpoolSummary,
  result: RunDeliveryResult,
  spool: DurableSpool,
): void {
  if (initial.maximum_sequence > result.acknowledged_through) {
    result.state = "blocked";
    result.blocked_at_sequence = result.acknowledged_through + 1;
    result.blocked_reason = "sequence gap or missing mission.started";
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
): Batch | null {
  const events = candidates.slice();
  while (events.length > 0) {
    const body =
      ENVELOPE_PREFIX +
      events.map((event) => event.canonical_json).join(",") +
      ENVELOPE_SUFFIX;
    if (Buffer.byteLength(body, "utf8") <= maxBodyBytes)
      return { events, body };
    events.pop();
  }
  return null;
}

async function fetchWithTimeout(
  options: ResolvedOptions,
  body: string,
  url: string,
): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs);
  try {
    return await options.fetchImpl(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${options.token}`,
      },
      body,
      signal: controller.signal,
    });
  } catch (error: unknown) {
    if (controller.signal.aborted) throw new RequestTimeoutError();
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function validateResponse(
  value: unknown,
  events: DeliverableEvent[],
): ValidatedResponse | null {
  if (
    !isRecord(value) ||
    !Array.isArray(value.results) ||
    !isRecord(value.summary)
  )
    return null;
  if (value.results.length !== events.length) return null;
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
    )
      return null;
    byEventId.set(candidate.event_id, {
      event_id: candidate.event_id,
      status: candidate.status,
      ...(candidate.reason === undefined ? {} : { reason: candidate.reason }),
    });
    counts[candidate.status] += 1;
  }
  if (
    !isNonnegativeInteger(value.summary.accepted) ||
    !isNonnegativeInteger(value.summary.duplicates) ||
    !isNonnegativeInteger(value.summary.rejected) ||
    value.summary.accepted !== counts.accepted ||
    value.summary.duplicates !== counts.duplicate ||
    value.summary.rejected !== counts.rejected
  )
    return null;
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
    nowProvider: options.nowProvider ?? (() => new Date().toISOString()),
    randomProvider: options.randomProvider ?? Math.random,
    yieldImpl: options.yieldImpl ?? (async () => void (await yieldImmediate())),
    processObservationProvider: options.processObservationProvider,
    dcsProducerIdProvider: options.dcsProducerIdProvider,
    dcsLogTextProvider: options.dcsLogTextProvider,
  };
}

function recordHealth(
  result: RunDeliveryResult,
  options: ResolvedOptions,
): void {
  if (result.attempts === 0 && result.state === "deferred") return;
  const success =
    result.state === "complete" ||
    result.state === "incomplete" ||
    result.state === "empty";
  options.spool.recordDeliveryAttempt({
    producerId: result.producer_id,
    runKey: result.run_key,
    at: options.nowProvider(),
    success,
    error: success ? null : deliveryFailureMessage(result),
  });
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
    if (run.state === "complete") totals.runs_complete += 1;
    else if (run.state === "incomplete" || run.state === "deferred")
      totals.runs_incomplete += 1;
    else if (run.state === "blocked") totals.runs_blocked += 1;
    else if (run.state === "error") totals.runs_error += 1;
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

function activeSummary(
  url: string,
  runs: RunDeliveryResult[],
  abortSignals: AbortSignalSummary[],
  spool: DurableSpool,
  probeAttempted: boolean,
): ActiveDeliverySummary {
  const totals = summarize(runs);
  const circuit = spool.getDeliveryCircuit();
  return {
    dry_run: false,
    url,
    runs,
    totals,
    had_failure:
      totals.runs_blocked > 0 || totals.runs_error > 0 || circuit !== null,
    abort_signals: abortSignals,
    circuit: circuitSummary(circuit, probeAttempted),
  };
}

function circuitSummary(
  circuit: DeliveryCircuitState | null,
  probeAttempted: boolean,
): CircuitSummary {
  return circuit === null
    ? {
        open: false,
        open_since: null,
        next_probe_at: null,
        attempt_count: 0,
        last_status: null,
        probe_attempted: probeAttempted,
      }
    : {
        open: true,
        open_since: circuit.openSince,
        next_probe_at: circuit.nextProbeAt,
        attempt_count: circuit.attemptCount,
        last_status: circuit.lastStatus,
        probe_attempted: probeAttempted,
      };
}

function lifecycleSummaries(
  rows: LifecycleObservationRecord[],
): AbortSignalSummary[] {
  return rows
    .filter((row) => row.state === "pending")
    .map((row) => ({
      producerId: row.producerId,
      runKey: row.runKey,
      reason: row.reason as AbortSignalSummary["reason"],
      ...(row.hookGeneration === null
        ? {}
        : { generation: row.hookGeneration }),
      posted: false,
      retryRequired: true,
      ...(row.lastError === null ? {} : { error: row.lastError }),
    }));
}

async function safeResponseError(
  response: Response,
  token: string,
): Promise<string> {
  let body: string;
  try {
    body = await response.text();
  } catch (error: unknown) {
    body = `unable to read response body: ${errorMessage(error)}`;
  }
  return safeErrorMessage(`HTTP ${response.status}: ${body}`, token);
}

function defaultDcsLogTextProvider(): string {
  const path = process.env.TELEMETRY_DCS_LOG;
  if (path === undefined || path.length === 0) return "";
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function ingestUrl(baseUrl: string): string {
  return `${baseUrl.replace(/\/+$/, "")}/api/telemetry/ingest`;
}

function isRetryableStatus(status: number): boolean {
  return status === 429 || (status >= 500 && status <= 599);
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

function nowMs(options: ResolvedOptions): number {
  const parsed = Date.parse(options.nowProvider());
  if (!Number.isFinite(parsed))
    throw new Error("nowProvider returned an invalid timestamp");
  return parsed;
}

function addMs(now: number, delay: number): string {
  return new Date(now + delay).toISOString();
}

function safeErrorMessage(message: string, token: string): string {
  return (
    token.length === 0 ? message : message.split(token).join("[REDACTED]")
  ).slice(0, 500);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

class RequestTimeoutError extends Error {}
